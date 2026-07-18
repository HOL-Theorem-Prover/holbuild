structure HolbuildProcessGroup =
struct

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

fun parent_watch_script parent_pid script =
  String.concatWith "\n"
    ["holbuild_parent=" ^ pid_text parent_pid,
     "holbuild_leader=$$",
     "holbuild_group=$$",
     "( trap '' TERM; while kill -0 \"$holbuild_parent\" 2>/dev/null && kill -0 \"$holbuild_leader\" 2>/dev/null; do sleep 0.1; done; kill -TERM -\"$holbuild_group\" 2>/dev/null; sleep 0.2; kill -KILL -\"$holbuild_group\" 2>/dev/null ) </dev/null >/dev/null 2>&1 &",
     "holbuild_parent_watch=$!",
     "trap 'holbuild_status=$?; kill \"$holbuild_parent_watch\" 2>/dev/null; exit $holbuild_status' EXIT",
     script]

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

fun launch_shell parent_pid script : child_process =
  let
    (* Poly/ML implements Unix.execute in the runtime so the child reaches
       execve without returning to SML or allocating in a post-fork heap.
       setsid makes the eventual shell its process-group leader. *)
    val grouped = "exec setsid /bin/sh -c " ^ HolbuildHash.quote (parent_watch_script parent_pid script)
  in
    Unix.execute ("/bin/sh", ["-c", grouped])
  end

fun run_shell script =
  let
    val {id, process} =
      register_child_group (fn () => launch_shell (Posix.ProcEnv.getpid ()) script)
    fun wait () = (copy_child_stdout process; Unix.reap process)
    fun cleanup () = unregister_child_group id
    fun abort () =
      (kill_group_forcefully {id = id, process = process};
       ignore (Unix.reap process) handle OS.SysErr _ => ();
       cleanup ())
  in
    (wait () before cleanup ()) handle e => (abort (); raise e)
  end

end
