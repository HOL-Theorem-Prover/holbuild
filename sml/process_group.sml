structure HolbuildProcessGroup =
struct

exception Error of string

type child_process = (TextIO.instream, unit) Unix.proc
(* owner: the thread that launched the child, so a scheduler can stop the
   children of one piece of work (kill_thread_children).  reaped: set, under
   the registry lock, once the child is reaped; nothing signals it after,
   since its pid may then belong to another process.  It is set after the
   reap, not before, so a child that closed its output but runs on can
   still be stopped while its owner waits for it. *)
type active_child = {id : int, owner : Thread.thread, process : child_process, reaped : bool ref}

val active_child_groups = ref ([] : active_child list)
val next_child_id = ref 0
val active_child_mutex = Mutex.mutex ()
val child_output_mutex = Mutex.mutex ()

(* A token lives across a caller's retries, including gaps with no child.
   Cancellation marks it before taking the children to signal. *)
val cancellation_tokens = ref ([] : (Thread.thread * bool ref) list)

fun with_active_child_lock f =
  let
    val _ = Mutex.lock active_child_mutex
    val result = f () before Mutex.unlock active_child_mutex
  in
    result
  end
  handle e => (Mutex.unlock active_child_mutex; raise e)

fun require_uncancelled_locked NONE = ()
  | require_uncancelled_locked (SOME token) = if !token then raise Thread.Interrupt else ()

fun require_uncancelled token =
  with_active_child_lock (fn () => require_uncancelled_locked (SOME token))

fun with_cancellation_token f =
  let
    val token = ref false
    val _ = with_active_child_lock
      (fn () => cancellation_tokens := (Thread.self (), token) :: !cancellation_tokens)
    fun remove () = with_active_child_lock
      (fn () => cancellation_tokens := List.filter (fn (_, t) => t <> token) (!cancellation_tokens))
  in
    (f token before remove ()) handle e => (remove (); raise e)
  end

fun register_child_group_checked token launch =
  with_active_child_lock
    (fn () =>
        let
          val _ = require_uncancelled_locked token
          (* Unix.execute briefly owns pipe ends that must not leak through
             another concurrent fork/exec.  Serialize only this short launch
             window, then release the registry lock while the child runs. *)
          val process = HolbuildSpawn.with_launch_lock launch
          val id = !next_child_id
          val reaped = ref false
        in
          next_child_id := id + 1;
          active_child_groups := {id = id, owner = Thread.self (), process = process, reaped = reaped} ::
                                 !active_child_groups;
          {id = id, process = process, reaped = reaped}
        end)

fun register_child_group launch = register_child_group_checked NONE launch

fun unregister_child_group id =
  with_active_child_lock
    (fn () => active_child_groups := List.filter (fn {id = active_id, ...} => active_id <> id)
                                                 (!active_child_groups))

fun active_child_group_snapshot () = with_active_child_lock (fn () => !active_child_groups)

fun kill_child signal process = Unix.kill (process, signal) handle OS.SysErr _ => ()

fun kill_process_forcefully process =
  (kill_child Posix.Signal.term process;
   OS.Process.sleep (Time.fromReal 0.2);
   kill_child Posix.Signal.kill process)

(* As kill_process_forcefully, for a registered child that another thread
   reaps: each signal goes only while the child is still unreaped. *)
fun kill_group_forcefully ({process, reaped, ...} : active_child) =
  let fun signal s = with_active_child_lock (fn () => if !reaped then () else kill_child s process)
  in signal Posix.Signal.term; OS.Process.sleep (Time.fromReal 0.2); signal Posix.Signal.kill end

fun cancel_children matches =
  with_active_child_lock
    (fn () =>
        (List.app (fn (owner, token) => if matches owner then token := true else ())
                  (!cancellation_tokens);
         List.filter (fn {owner, ...} => matches owner) (!active_child_groups)))

fun kill_active_child_groups () = List.app kill_group_forcefully (cancel_children (fn _ => true))

(* Stops THREAD's current children and active retry sequences. A new call
   begun after this snapshot gets a new token and may launch children. *)
fun kill_thread_children thread =
  let
    val children =
      cancel_children (fn owner => Thread.equal (owner, thread))
  in
    if null children then ()
    else ignore (Thread.fork (fn () => List.app kill_group_forcefully children, []))
  end

(* Counts cleanups, so code waiting to launch a child (for machine memory)
   can tell that the build stopped while it waited. *)
val cleanups = ref 0

fun cleanup_count () = with_active_child_lock (fn () => !cleanups)

fun cleanup_active_children () =
  (with_active_child_lock (fn () => cleanups := !cleanups + 1);
   kill_active_child_groups ())

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

val perl_try_lease_lock =
  "perl -MFcntl=:flock -e 'open(my $fh, \">&=9\") or die \"dup: $!\\n\"; " ^
  "flock($fh, LOCK_EX | LOCK_NB) or exit 1'"

(* Non-blocking form of lease_lock: the command fails if fd 9 is locked. *)
val try_lease_lock = probed (fn () =>
  if have_command "flock" then "flock -n -x 9"
  else if have_command "perl" then perl_try_lease_lock
  else raise Error ("cannot lock a mutation lease: neither flock " ^
                    "nor perl is available on PATH"))

fun mutation_lease_setup NONE = []
  | mutation_lease_setup (SOME path) =
      ["exec 9>" ^ HolbuildHash.quote path,
       lease_lock (),
       "kill -0 \"$holbuild_parent\" 2>/dev/null || exit 125"]

(* The watcher closes fd 9: it ignores TERM and can outlive the script by a
   few hundred milliseconds, and must not keep holding the mutation lease. *)
(* The EXIT trap keeps this shell alive instead of exec'ing its last command;
   sandbox launchers use that stable shell PID to detect parent death. *)
(* A cancelled leader stays a zombie until its output drains. kill -0 alone
   would keep the watcher waiting while a helper still holds stdout open. *)
fun parent_watch_script parent_pid mutation_lease script =
  String.concatWith "\n"
    (["holbuild_parent=" ^ pid_text parent_pid] @
     mutation_lease_setup mutation_lease @
     ["holbuild_leader=$$",
      "holbuild_group=$$",
      "( trap '' TERM",
      "  while kill -0 \"$holbuild_parent\" 2>/dev/null && kill -0 \"$holbuild_leader\" 2>/dev/null; do",
      "    sleep 0.1",
      "    kill -0 \"$holbuild_leader\" 2>/dev/null || break",
      "    case \"$(ps -o stat= -p \"$holbuild_leader\" 2>/dev/null)\" in *Z*) break ;; esac",
      "  done",
      "  kill -TERM -\"$holbuild_group\" 2>/dev/null",
      "  sleep 0.2",
      "  kill -KILL -\"$holbuild_group\" 2>/dev/null",
      ") </dev/null >/dev/null 2>&1 9>&- &",
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

(* The launch lock is held here, so clearing close-on-exec hands this one
   descriptor to this child and to no child another thread launches through
   HolbuildSpawn.  A fork that bypasses the launch lock (OS.Process.system)
   in this window also gets it, and holds the reservation until it exits. *)
fun with_inherited NONE launch = launch ()
  | with_inherited (SOME fd) launch =
      let
        fun restore () = Posix.IO.setfd (fd, Posix.IO.FD.cloexec)
        val _ = Posix.IO.setfd (fd, Posix.IO.FD.flags [])
      in
        (launch () before restore ()) handle e => (restore (); raise e)
      end

(* Runs SCRIPT and returns CONSUME (process, reap), where reap () reaps the
   child; consumers reap only through it. *)
fun run_shell_process_checked token mutation_lease inherit script consume =
  let
    val {id, process, reaped} =
      register_child_group_checked token
        (fn () => with_inherited inherit
                    (fn () => launch_shell (Posix.ProcEnv.getpid ()) mutation_lease script))
    fun cleanup () = unregister_child_group id
    fun mark_reaped () = with_active_child_lock (fn () => reaped := true)
    fun reap () = (Unix.reap process handle e => (mark_reaped (); raise e)) before mark_reaped ()
    fun abort () =
      (if with_active_child_lock (fn () => !reaped) then () else kill_process_forcefully process;
       ignore (reap ()) handle OS.SysErr _ => ();
       cleanup ())
  in
    (consume (process, reap) before cleanup ()) handle e => (abort (); raise e)
  end

fun run_shell_process mutation_lease inherit script consume =
  run_shell_process_checked NONE mutation_lease inherit script consume

fun reap_with_output (process, reap) =
  let
    val output = TextIO.inputAll (Unix.textInstreamOf process)
    val status = reap ()
  in
    {status = status, output = output}
  end

(* inherit is a descriptor the child keeps open for its whole life, such as
   a machine memory lease. *)
fun run_shell_inheriting inherit script =
  run_shell_process NONE inherit script
    (fn (process, reap) => (copy_child_stdout process; reap ()))

fun run_shell script = run_shell_inheriting NONE script

(* As run_shell_inheriting, but once DEADLINE passes the child's group is
   killed: the shell first, whose parent watch then kills the rest of the
   group.  The shell stays unreaped until its output ends, so its pid can't
   be reused while the watcher may still signal it. *)
fun run_shell_inheriting_until inherit deadline script =
  let
    val mutex = Mutex.mutex ()
    val finished = ref false
    val timed_out = ref false
    fun locked f =
      (Mutex.lock mutex; f () before Mutex.unlock mutex)
      handle e => (Mutex.unlock mutex; raise e)
    fun consume (process, reap) =
      let
        fun watch () =
          if locked (fn () =>
                       !finished orelse
                       (Time.>= (Time.now (), deadline) andalso
                        (timed_out := true;
                         kill_process_forcefully process;
                         true)))
          then ()
          else (OS.Process.sleep (Time.fromReal 0.1); watch ())
        val _ = Thread.fork (watch, [])
        fun finish () = locked (fn () => finished := true)
      in
        (copy_child_stdout process handle e => (finish (); raise e));
        finish ();
        reap ()
      end
    val status = run_shell_process NONE inherit script consume
  in
    {status = status, timed_out = locked (fn () => !timed_out)}
  end

fun run_shell_output script = run_shell_process NONE NONE script reap_with_output

(* The token check and registration share the cancellation snapshot lock. *)
fun run_shell_output_cancellable token script =
  run_shell_process_checked (SOME token) NONE NONE script reap_with_output

fun run_shell_with_mutation_lease {lease_path, script} =
  run_shell_process (SOME lease_path) NONE script
    (fn (process, reap) => (copy_child_stdout process; reap ()))

fun run_shell_output_with_mutation_lease {lease_path, script} =
  run_shell_process (SOME lease_path) NONE script reap_with_output

end
