(* Deferring in place, for a theory child whose build proves a theory's
   deferred proofs after its export on several threads (holbuild's
   HOLBUILD_PROOF_THREADS above 1), with proof steps and checkpoints on.
   Loaded after the proof-step runtime and deferred_proofs_runtime.sml. *)
structure HolbuildDeferredInPlace =
struct
  open HolbuildDeferred

  (* A plain build with proof steps that defers its proofs (holbuild's
     HOLBUILD_PROOF_THREADS above 1) proves them here after the export, on
     several threads, each with its own proof-step state.  A proof that is
     not a proof failure (it left a hypothesis, wrote theory data, changed
     the theory) raises Unsupported: the build then runs the theory again
     without deferring. *)
  exception Unsupported of string

  fun unsupported_marker sig_path =
    OS.Path.concat (OS.Path.dir sig_path, "holbuild-deferral-unsupported")

  fun proof_failure name e =
    Fail ("deferred proof of " ^ name ^ " failed: " ^
          (Feedback.exn_to_string e handle Interrupt => "interrupted"))

  (* On this thread, unpinned, with the live context set to the goal's, as
     the script would have run it in place.  It saves no checkpoint: the
     theory is already exported. *)
  fun prove_here types ({k, name, ctxt, goal, make, setup} : item) =
    let
      val state = HolbuildProofRuntime.main_proof_state
      val saves = !(#save_checkpoints_ref state)
      fun run () =
        let
          val _ = Context.restore ctxt
          val initial = thydata_of types
          val th = (Option.app (fn f => f ()) setup;
                    Tactical.prove_goal_in ctxt (goal, make ()))
                   handle e => raise proof_failure name e
        in
          result k (checked goal initial th handle Fail msg => raise Unsupported msg)
        end
    in
      #save_checkpoints_ref state := false;
      (run () before #save_checkpoints_ref state := saves)
      handle e => (#save_checkpoints_ref state := saves; raise e)
    end

  datatype outcome = Proved of int * ((string * int list) list * string list)
                   | Failed of exn * HolbuildProofRuntime.proof_state

  (* Proves ITEMS, in source order, on THREADS threads.  The earliest
     failure decides: a step killed on a timeout (whose thread can hold the
     context's lock) fails the build with that proof's diagnostics; any
     other failure runs that proof again here, where it fails with the
     diagnostics an in-place build prints, or passes (it lost a race on
     some library's cache) and the rest run here too.  Returns the results
     in source order of the proofs that passed, and the exception that
     failed the build, if any. *)
  fun prove_steps threads types items =
    let
      val n = length items
      val slots = Array.array (n, NONE : outcome option)
      val work = Vector.fromList items
      val next = ref 0
      val stop = ref n
      val running = ref 0
      val mutex = Mutex.mutex ()
      val cv = ConditionVar.conditionVar ()
      fun locked f = (Mutex.lock mutex; f () before Mutex.unlock mutex)
                     handle e => (Mutex.unlock mutex; raise e)
      fun take () =
        locked (fn () => if !next < !stop then SOME (!next) before next := !next + 1 else NONE)
      fun attempt i =
        let
          val {k, name, ctxt, goal, make, setup} = Vector.sub (work, i)
          val state = HolbuildProofRuntime.fresh_proof_state ()
          val _ = #save_checkpoints_ref state := false
          val _ = #diagnostic_buffer_ref state := SOME []
          fun prove () =
            Context.with_context ctxt
              (fn () =>
                 let
                   val initial = thydata_of types
                   val th = (Option.app (fn f => f ()) setup;
                             Tactical.prove_goal_in ctxt (goal, make ()))
                            handle e => raise proof_failure name e
                 in
                   result k (checked goal initial th handle Fail msg => raise Unsupported msg)
                 end) ()
          val outcome = Proved (HolbuildProofRuntime.with_proof_state state prove ())
                        handle e => Failed (e, state)
        in
          locked (fn () =>
            (Array.update (slots, i, SOME outcome);
             case outcome of Failed _ => if i < !stop then stop := i else () | _ => ()))
        end
      fun worker () =
        case take () of
            SOME i => (attempt i; worker ())
          | NONE => locked (fn () => (running := !running - 1; ConditionVar.broadcast cv))
      fun wait () = if !running = 0 then () else (ConditionVar.wait (cv, mutex); wait ())
      val count = Int.max (1, Int.min (threads, n))
      val _ = running := count
      val _ = List.app (fn _ => ignore (Thread.fork (worker, []))) (List.tabulate (count, fn i => i))
      val _ = (Mutex.lock mutex; wait (); Mutex.unlock mutex)
      val after_export = Context.snapshot ()
      fun passed_before i =
        List.tabulate (i, fn j => case Array.sub (slots, j) of
                                      SOME (Proved r) => r
                                    | _ => raise Fail "internal error: deferred proof missing")
      fun rest_here from acc =
        if from >= n then (rev acc, NONE)
        else
          (rest_here (from + 1) (prove_here types (Vector.sub (work, from)) :: acc))
          handle e => (rev acc, SOME e)
    in
      if !stop >= n then (passed_before n, NONE)
      else
        case Array.sub (slots, !stop) of
            SOME (Failed (e, state)) =>
              let
                val done = passed_before (!stop)
                val _ = TextIO.flushOut TextIO.stdOut
              in
                case e of
                    Unsupported _ => (done, SOME e)
                  | _ =>
                    if !(#step_killed_ref state) then
                      (HolbuildProofRuntime.flush_diagnostics state; (done, SOME e))
                    else
                      let val (more, failure) = rest_here (!stop) []
                      in Context.restore after_export; (done @ more, failure) end
              end
          | _ => raise Fail "internal error: deferred proof failure missing"
    end

  (* Checkpoints saved while some proof was still deferred, each with the
     goals its heap holds stubs for: it is committed (`.ok` written) once
     they are all proved.  A checkpoint's `.proved` holds what its stubs
     resolve to, written before its `.ok`; a build that resumes from it
     loads them. *)
  val staged = ref ([] : (string * string * int list) list)

  fun proved_text results =
    String.concat
      (map (fn (k, (deps, oracles)) =>
              String.concat
                ["(", Int.toString k, ", ([",
                 String.concatWith ", "
                   (map (fn (t, ns) => "(\"" ^ String.toString t ^ "\", [" ^
                                       String.concatWith ", " (map Int.toString ns) ^ "])") deps),
                 "], [",
                 String.concatWith ", " (map (fn o' => "\"" ^ String.toString o' ^ "\"") oracles),
                 "])) ::\n"])
           results) ^ "[]"

  fun write_proved path needed =
    HolbuildCheckpointSaveRuntime.write_text_atomically (path ^ ".proved")
      ("val _ = HolbuildDeferred.proved := (\n" ^
       proved_text (List.filter (fn (k, _) => List.exists (fn j => j = k) needed) (!proved)) ^ ");\n")

  fun proved_ks () = map #1 (!proved)

  fun commit path ok_text =
    let val needed = map #k (!queue) @ proved_ks ()
    in
      if null (!queue) then
        (write_proved path needed;
         HolbuildCheckpointSaveRuntime.write_text_atomically (HolbuildCheckpointSaveRuntime.ok_path path) ok_text)
      else staged := (path, ok_text, needed) :: !staged
    end

  fun commit_staged () =
    let
      val ks = proved_ks ()
      fun ready (_, _, needed) = List.all (fn k => List.exists (fn j => j = k) ks) needed
      val (now, later) = List.partition ready (!staged)
    in
      staged := later;
      List.app (fn (path, ok_text, needed) =>
                  (write_proved path needed;
                   HolbuildCheckpointSaveRuntime.write_text_atomically
                     (HolbuildCheckpointSaveRuntime.ok_path path) ok_text)
                  handle e => HolbuildCheckpointSaveRuntime.warn_checkpoint_failure "deferred" path e)
               (rev now)
    end

  (* What the checkpoint at PATH, which this build resumed from, resolves
     its stubs to. *)
  fun load_proved path =
    if OS.FileSys.access (path ^ ".proved", []) handle OS.SysErr _ => false
    then HolbuildRuntime.use (path ^ ".proved")
    else proved := []

  fun save_context path ok_text =
    HolbuildCheckpointSaveRuntime.save_checkpoint
      {label = "theorem_context", default_share = false, path = path, ok_text = ok_text,
       depth = length (PolyML.SaveState.showHierarchy ())}

  fun skip_context path = HolbuildCheckpointSaveRuntime.discard_checkpoint path

  (* The exporter of a build that defers in place (see prove_steps): proves
     what is deferred, commits the checkpoints that waited for it, and
     rewrites the exported data with what each stub's proof depends on.
     Writes FINALIZED once nothing in the data names a stub. *)
  fun finish {sig_path, threads, finalized} =
    let
      val types = thydata_types ()
      val items = rev (!queue)
      val change = ref NONE
      fun record delta = if Option.isSome (!change) then () else change := SOME (describe_delta delta)
      val listener = "HolbuildDeferred.finish"
      val live = thydata_of types
      val wall = Timer.startRealTimer ()
      (* A HOL whose pinned threads write to the live context (before
         2026-10) can't keep one proof's writes from the others. *)
      val threads =
        if threads > 1 andalso not (null items) andalso HolbuildTacticCompat.pinned_writes_stay_in_pin ()
        then threads else 1
      val (results, failure) =
        if null items then ([], NONE)
        else
          (Theory.register_hook (listener, record);
           (if threads > 1
            then prove_steps threads types items
            else
              let
                fun here [] acc = (rev acc, NONE)
                  | here (item :: rest) acc =
                      (here rest (prove_here types item :: acc)) handle e => (rev acc, SOME e)
                val after_export = Context.snapshot ()
              in
                here items [] before Context.restore after_export
              end)
           before ignore (Listener.remove_listener Theory.delta_hook listener))
      val failure =
        case (failure, !change, changed_thydata live) of
            (SOME e, _, _) => SOME e
          | (NONE, SOME what, _) => SOME (Unsupported ("a deferred proof changed the theory: " ^ what))
          | (NONE, NONE, SOME ty) => SOME (Unsupported ("a deferred proof wrote theory data of type " ^ ty))
          | (NONE, NONE, NONE) => NONE
      val _ =
        if null items then ()
        else
          (TextIO.output (TextIO.stdOut,
             String.concat ["holbuild: proved ", Int.toString (length results), " deferred proofs of ",
                            Int.toString (length items), " on ", Int.toString threads, " threads in ",
                            Real.fmt (StringCvt.FIX (SOME 3)) (Time.toReal (Timer.checkRealTimer wall)),
                            " s\n"]);
           TextIO.flushOut TextIO.stdOut)
      val _ = proved := results @ !proved
      val _ = queue := []
      val _ = commit_staged ()
      val _ = staged := []
    in
      case failure of
          SOME (e as Unsupported msg) =>
            (HolbuildRuntime.write_text (unsupported_marker sig_path) (msg ^ "\n"); raise e)
        | SOME e => raise e
        | NONE =>
            (if null (!proved) then HolbuildRuntime.normalize_theory_export sig_path
             else
               (if Option.isSome (!marker_data) then ()
                else marker_data := SOME (valOf (HOLsexp.fromString (read_text (OS.Path.base sig_path ^ ".dat"))));
                finalize sig_path);
             if String.isSubstring oracle_prefix (read_text (OS.Path.base sig_path ^ ".dat"))
             then raise Fail "the exported theory data still names a deferred proof"
             else ();
             HolbuildRuntime.write_text finalized "")
    end
end

val _ = HolbuildCheckpointSaveRuntime.commit_ok := HolbuildDeferredInPlace.commit;
