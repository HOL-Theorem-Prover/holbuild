structure HolbuildProcessGroup =
struct

exception Error of string

type child_process = (TextIO.instream, unit) Unix.proc
type active_child = {id : int, process : child_process}

val active_child_groups = ref ([] : active_child list)
val next_child_id = ref 0
val active_child_mutex = Mutex.mutex ()
val child_output_mutex = Mutex.mutex ()

fun with_active_child_lock f =
  let
    val _ = Mutex.lock active_child_mutex
    val result = f () before Mutex.unlock active_child_mutex
  in
    result
  end
  handle e => (Mutex.unlock active_child_mutex; raise e)

fun register_child_group launch =
  with_active_child_lock
    (fn () =>
        let
          (* Unix.execute briefly owns pipe ends that must not leak through
             another concurrent fork/exec.  Serialize only this short launch
             window, then release the registry lock while the child runs. *)
          val process = launch ()
          val id = !next_child_id
        in
          next_child_id := id + 1;
          active_child_groups := {id = id, process = process} :: !active_child_groups;
          {id = id, process = process}
        end)

fun unregister_child_group id =
  with_active_child_lock
    (fn () => active_child_groups := List.filter (fn {id = active_id, ...} => active_id <> id)
                                                 (!active_child_groups))

fun active_child_group_snapshot () = with_active_child_lock (fn () => !active_child_groups)

fun kill_child signal process = Unix.kill (process, signal) handle OS.SysErr _ => ()

fun kill_group_forcefully ({process, ...} : active_child) =
  (kill_child Posix.Signal.term process;
   OS.Process.sleep (Time.fromReal 0.2);
   kill_child Posix.Signal.kill process)

fun kill_active_child_groups () = List.app kill_group_forcefully (active_child_group_snapshot ())

fun cleanup_active_children () = kill_active_child_groups ()

fun pid_text pid = LargeInt.toString (SysWord.toLargeInt (Posix.Process.pidToWord pid))

(* macOS ships neither setsid(1) nor flock(1).  Perl is part of its base
   system and exposes both primitives, so fall back to it when the utilities
   are absent.  POSIX::setsid reports failure as -1, which is truthy in Perl,
   hence the explicit comparison. *)

fun have_command name =
  OS.Process.isSuccess
    (OS.Process.system ("command -v " ^ HolbuildHash.quote name ^ " >/dev/null 2>&1"))
  handle _ => false

(* Probes are deterministic, so a racing second probe is harmless. *)
fun probed probe =
  let
    val cached = ref NONE
  in
    fn () =>
      case !cached of
          SOME value => value
        | NONE => let val value = probe () in cached := SOME value; value end
  end

val perl_session_leader =
  "perl -MPOSIX -e 'POSIX::setsid() != -1 or die \"setsid: $!\\n\"; " ^
  "exec(\"/bin/sh\", \"-c\", $ARGV[0]) or die \"exec: $!\\n\"' --"

val session_leader = probed (fn () =>
  if have_command "setsid" then "setsid /bin/sh -c"
  else if have_command "perl" then perl_session_leader
  else raise Error ("cannot start a process-group leader: neither setsid " ^
                    "nor perl is available on PATH"))

val perl_lease_lock =
  "perl -MFcntl=:flock -e 'open(my $fh, \">&=9\") or die \"dup: $!\\n\"; " ^
  "flock($fh, LOCK_EX) or die \"flock: $!\\n\"'"

val lease_lock = probed (fn () =>
  if have_command "flock" then "flock -x 9"
  else if have_command "perl" then perl_lease_lock
  else raise Error ("cannot lock a mutation lease: neither flock " ^
                    "nor perl is available on PATH"))

fun mutation_lease_setup NONE = []
  | mutation_lease_setup (SOME path) =
      ["exec 9>" ^ HolbuildHash.quote path,
       lease_lock (),
       "kill -0 \"$holbuild_parent\" 2>/dev/null || exit 125"]

fun parent_watch_script parent_pid mutation_lease script =
  String.concatWith "\n"
    (["holbuild_parent=" ^ pid_text parent_pid] @
     mutation_lease_setup mutation_lease @
     ["holbuild_leader=$$",
      "holbuild_group=$$",
      "( trap '' TERM; while kill -0 \"$holbuild_parent\" 2>/dev/null && kill -0 \"$holbuild_leader\" 2>/dev/null; do sleep 0.1; done; kill -TERM -\"$holbuild_group\" 2>/dev/null; sleep 0.2; kill -KILL -\"$holbuild_group\" 2>/dev/null ) </dev/null >/dev/null 2>&1 &",
      "holbuild_parent_watch=$!",
      "trap 'holbuild_status=$?; kill \"$holbuild_parent_watch\" 2>/dev/null; exit $holbuild_status' EXIT",
      script])

fun copy_child_stdout process =
  let
    val input = Unix.textInstreamOf process
    fun output text =
      (Mutex.lock child_output_mutex;
       (TextIO.output(TextIO.stdOut, text); TextIO.flushOut TextIO.stdOut)
       before Mutex.unlock child_output_mutex)
      handle e => (Mutex.unlock child_output_mutex; raise e)
    fun loop () =
      let val text = TextIO.inputN(input, 8192)
      in if text = "" then () else (output text; loop ()) end
  in
    loop ()
  end

fun launch_shell parent_pid mutation_lease script : child_process =
  let
    (* Poly/ML implements Unix.execute in the runtime so the child reaches
       execve without returning to SML or allocating in a post-fork heap.
       The session leader makes the eventual shell its process-group leader. *)
    val grouped =
      "exec " ^ session_leader () ^ " " ^
      HolbuildHash.quote (parent_watch_script parent_pid mutation_lease script)
  in
    Unix.execute ("/bin/sh", ["-c", grouped])
  end

fun run_shell_process mutation_lease script consume =
  let
    val {id, process} =
      register_child_group
        (fn () => launch_shell (Posix.ProcEnv.getpid ()) mutation_lease script)
    fun cleanup () = unregister_child_group id
    fun abort () =
      (kill_group_forcefully {id = id, process = process};
       ignore (Unix.reap process) handle OS.SysErr _ => ();
       cleanup ())
  in
    (consume process before cleanup ()) handle e => (abort (); raise e)
  end

fun reap_with_output process =
  let
    val output = TextIO.inputAll (Unix.textInstreamOf process)
    val status = Unix.reap process
  in
    {status = status, output = output}
  end

fun run_shell script =
  run_shell_process NONE script
    (fn process => (copy_child_stdout process; Unix.reap process))

fun run_shell_output script = run_shell_process NONE script reap_with_output

fun run_shell_with_mutation_lease {lease_path, script} =
  run_shell_process (SOME lease_path) script
    (fn process => (copy_child_stdout process; Unix.reap process))

fun run_shell_output_with_mutation_lease {lease_path, script} =
  run_shell_process (SOME lease_path) script reap_with_output

end
