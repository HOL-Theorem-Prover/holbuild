val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val tmp = valOf (OS.Process.getEnv "HOLBUILD_PROCESS_TEST_DIR");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";
structure G = HolbuildProcessGroup;

fun assert message condition = if condition then () else raise Fail message;
fun deadline () = Time.+ (Time.now (), Time.fromSeconds 15);
fun wait message condition limit =
  if condition () then ()
  else if Time.>= (Time.now (), limit) then raise Fail message
  else (OS.Process.sleep (Time.fromReal 0.02); wait message condition limit);
fun read path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end;
fun exists path = OS.FileSys.access (path, []) handle OS.SysErr _ => false;

(* Readiness comes from the actual TERM-ignoring helper, which keeps stdout
   open forever. The registered shell's EXIT trap prevents it exec'ing sh. *)
fun helper name =
  "sh -c " ^ HolbuildHash.quote
    ("trap '' TERM; printf helper-ready; echo $$ $PPID > " ^
     HolbuildHash.quote (tmp ^ "/" ^ name) ^ "; while :; do sleep 1; done");
fun helper_pid name = hd (String.tokens Char.isSpace (read (tmp ^ "/" ^ name)));
fun leader_pid name = List.nth (String.tokens Char.isSpace (read (tmp ^ "/" ^ name)), 1);
fun process_alive pid =
  let
    val {status, output} = HolbuildSpawn.run
      {program = "ps", args = ["-o", "stat=", "-p", pid],
       stderr = HolbuildSpawn.Discard}
  in
    HolbuildSpawn.succeeded {status = status, output = output} andalso
    not (String.isSubstring "Z" output)
  end;
fun helper_alive name = process_alive (helper_pid name);
fun ready name = wait (name ^ " never became ready")
  (fn () => exists (tmp ^ "/" ^ name) andalso read (tmp ^ "/" ^ name) <> "") (deadline ());
fun stopped name = wait (name ^ " survived cancellation")
  (fn () => not (helper_alive name)) (deadline ());

fun start run =
  let
    val result = ref NONE
    val worker = Thread.fork
      (fn () => result := SOME ((SOME (run ()), NONE)
                               handle e => (NONE, SOME e)), [])
  in
    (worker, result)
  end;
fun finish name (_, result) =
  (wait (name ^ " output remained blocked after cancellation")
        (fn () => isSome (!result)) (deadline ());
   case valOf (!result) of
       (SOME value, NONE) => value
     | (_, SOME e) => raise e
     | _ => raise Fail "missing worker result");
fun entry worker = valOf (List.find
  (fn ({owner, ...} : G.active_child) => Thread.equal (owner, worker))
  (G.active_child_group_snapshot ()));

val a = start (fn () =>
  let
    val cancelled = G.run_shell_output (helper "scoped-a")
    val later = G.run_shell_output "printf later"
  in
    assert "later call from the cancelled thread failed"
      (OS.Process.isSuccess (#status later) andalso #output later = "later");
    cancelled
  end);
val b = start (fn () => G.run_shell_output (helper "scoped-b"));
val _ = ready "scoped-a";
val _ = ready "scoped-b";
val old_a = entry (#1 a);
val live_b = entry (#1 b);
val _ = G.kill_thread_children (#1 a);
val a_result = finish "scoped-a" a;
val _ = assert "cancelled shell returned success" (not (OS.Process.isSuccess (#status a_result)));
val _ = assert "cancelled helper output was lost" (#output a_result = "helper-ready");
val _ = stopped "scoped-a";
val _ = assert "scoped cancellation stopped another caller" (helper_alive "scoped-b");
val _ = assert "completed entry was not marked reaped" (!(#reaped old_a));
val _ = G.kill_group_forcefully old_a;
(* Model a retired handle whose numeric PID now names live_b. A reaped
   snapshot must never signal the process now at that PID. *)
val retired : G.active_child =
  {id = #id live_b, owner = #owner live_b, process = #process live_b, reaped = ref true};
val _ = G.kill_group_forcefully retired;
val _ = assert "a retired handle signalled a live child" (process_alive (leader_pid "scoped-b"));
val _ = G.kill_thread_children (#1 b);
val _ = finish "scoped-b" b;
val _ = stopped "scoped-b";

val c = start (fn () => G.run_shell_output (helper "global-c"));
val d = start (fn () => G.run_shell_output (helper "global-d"));
val _ = ready "global-c";
val _ = ready "global-d";
val _ = G.kill_active_child_groups ();
val _ = finish "global-c" c;
val _ = finish "global-d" d;
val _ = stopped "global-c";
val _ = stopped "global-d";

val timed = start (fn () => G.run_shell_inheriting_until NONE
  (Time.+ (Time.now (), Time.fromSeconds 5)) (helper "deadline"));
val _ = ready "deadline";
val timed_result = finish "deadline" timed;
val _ = assert "deadline was not reported" (#timed_out timed_result);
val _ = assert "deadline returned success" (not (OS.Process.isSuccess (#status timed_result)));
val _ = stopped "deadline";
val _ = assert "completed children remained registered" (null (G.active_child_group_snapshot ()));
val _ = print "process-group cancellation tests passed\n";
val _ = OS.Process.exit OS.Process.success;
