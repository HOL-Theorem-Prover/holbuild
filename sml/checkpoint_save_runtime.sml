(* HOL times a theory by this process's CPU clock, from new_theory to
   export_theory.  A process that resumes from a checkpoint saved after
   new_theory doesn't run it again, so HOL would subtract the clock reading
   of the process that saved the checkpoint from its own.  A checkpoint saved
   within a theory carries the theory's CPU time so far instead, here, and a
   process that resumes from one reports the sum.

   carried: NONE while HOL's own timing holds, in the process that began the
   theory; SOME t once the theory took t in earlier processes.
   since: this process's CPU time when its share of the theory began.

   This file is loaded again after a resume, and the state restored from
   the checkpoint must stay the one in use, so it is compiled only once.  A
   saved heap may hold it, so a change to its shape needs a new name. *)
val _ =
  if Option.isSome (#lookupStruct PolyML.globalNameSpace "HolbuildTheoryCpuState") then ()
  else
    let
      val stream =
        TextIO.openString
          (String.concat
             ["structure HolbuildTheoryCpuState = struct ",
              "val carried : Time.time option ref = ref NONE ",
              "val since : Time.time option ref = ref NONE end;"])
    in
      PolyML.compiler (fn () => TextIO.input1 stream, []) ()
    end;

structure HolbuildCheckpointSaveRuntime =
struct

fun env_bool name =
  case OS.Process.getEnv name of
      SOME "1" => SOME true
    | SOME "true" => SOME true
    | SOME "yes" => SOME true
    | SOME "0" => SOME false
    | SOME "false" => SOME false
    | SOME "no" => SOME false
    | _ => NONE

fun bool_text true = "true"
  | bool_text false = "false"

fun seconds (a, b) = Time.toReal (Time.-(b, a))
fun fmt_time t = Real.fmt (StringCvt.FIX (SOME 3)) t

fun remove_file path = OS.FileSys.remove path handle _ => ()
fun file_exists path = OS.FileSys.access(path, [OS.FileSys.A_READ]) handle _ => false
fun rename_file old new = OS.FileSys.rename {old = old, new = new}

fun ok_path path = path ^ ".ok"
fun ok_tmp_path path = ok_path path ^ ".tmp"

fun write_text_atomically path text =
  let
    val tmp = path ^ ".tmp"
    val _ = remove_file tmp
    val out = TextIO.openOut tmp
    fun close () = TextIO.closeOut out handle _ => ()
  in
    (TextIO.output(out, text);
     TextIO.closeOut out;
     rename_file tmp path)
    handle e => (close (); remove_file tmp; raise e)
  end

(* PolyML child heaps record parent-state filenames. The checkpoint .save must
   therefore be created at its final path, not at a temporary path that is later
   renamed. Replacement intentionally drops old metadata before writing the new
   save: an interrupted save may lose this checkpoint, but validation will not
   pair stale metadata with partial save bytes.

   Removing the old file before saveChild writes is also a contract that
   exec-action --share-heaps relies on: an action's checkpoint tree holds hard
   or symbolic links to the host's shared store, and a save that wrote into an
   existing file would rewrite the store's copy, and every other action's. *)
fun begin_replacement path =
  (remove_file (ok_tmp_path path);
   remove_file (ok_path path);
   remove_file path)

fun checkpoint_io_failure e =
  case e of
      IO.Io _ => true
    | OS.SysErr _ => true
    | _ => false

fun warn_checkpoint_failure label path e =
  TextIO.output
    (TextIO.stdErr,
     String.concat ["holbuild: warning: dropping checkpoint kind=", label,
                    " path=", path,
                    " error=", General.exnMessage e, "\n"])

fun discard_checkpoint path =
  (remove_file (ok_tmp_path path);
   remove_file (ok_path path);
   remove_file path)

(* Runs F with only the toolchain's entries on the load path.  HOL adds the
   project's directories (and its external includes) when it starts, so a
   heap saved with them would search this tree from any other tree that
   resumes from it; one that starts from the heap adds its own again. *)
fun with_toolchain_load_path f =
  let
    val path = !Meta.loadPath
    val holdir = Systeml.HOLDIR
    fun toolchain dir = dir = holdir orelse String.isPrefix (holdir ^ "/") dir
  in
    Meta.loadPath := List.filter toolchain path;
    (f () handle e => (Meta.loadPath := path; raise e));
    Meta.loadPath := path
  end

fun process_cpu () =
  let val {usr, sys} = Timer.checkCPUTimer (Timer.totalCPUTimer ())
  in Time.+(usr, sys) end

(* The current theory's CPU time, given CARRIED from earlier processes. *)
fun theory_cpu carried =
  case !HolbuildTheoryCpuState.since of
      SOME since => Time.+(carried, Time.-(process_cpu (), since))
    | NONE => carried

(* Runs F, which saves a checkpoint, with the theory's CPU time so far
   carried in the state it saves. *)
fun with_theory_cpu_carried f =
  case !HolbuildTheoryCpuState.since of
      NONE => f ()
    | SOME _ =>
        let
          val carried = !HolbuildTheoryCpuState.carried
          val since = !HolbuildTheoryCpuState.since
          fun restore () =
            (HolbuildTheoryCpuState.carried := carried;
             HolbuildTheoryCpuState.since := since)
        in
          HolbuildTheoryCpuState.carried :=
            SOME (theory_cpu (Option.getOpt (carried, Time.zeroTime)));
          HolbuildTheoryCpuState.since := NONE;
          (f () handle e => (restore (); raise e));
          restore ()
        end

(* In a resumed process, export_theory would report a time against another
   process's clock: its report is replaced by the carried sum. *)
fun report_resumed_theory_cpu thyname carried =
  let
    val out = !Feedback.MESG_outstream
    val report = "Theory " ^ Lib.quote thyname ^ " took "
    val line = report ^ Lib.time_to_string (theory_cpu carried) ^ " to build\n"
    fun replace text =
      if String.isPrefix report text then (Feedback.MESG_outstream := out; out line)
      else out text
  in
    if Feedback.get_tracefn "report_thy_times" () = 0 then ()
    else Feedback.MESG_outstream := replace
  end

fun theory_cpu_hook (TheoryDelta.NewTheory _) =
      (HolbuildTheoryCpuState.carried := NONE;
       HolbuildTheoryCpuState.since := SOME (process_cpu ()))
  | theory_cpu_hook (TheoryDelta.ExportTheory thyname) =
      (case !HolbuildTheoryCpuState.carried of
           SOME carried => report_resumed_theory_cpu thyname carried
         | NONE => ())
  | theory_cpu_hook _ = ()

(* After a source parse error QUse's error flag is set, and a heap saved then
   keeps it: `hol run` from that heap exits with failure after its first
   declaration, printing nothing.  So no checkpoint is saved once the flag is
   set, and an older one at the same path is removed. *)
fun save_checkpoint ({label, default_share, path, ok_text, depth} :
                     {label : string, default_share : bool, path : string,
                      ok_text : string, depth : int}) =
  let
    fun save () =
      let
        val share = Option.getOpt(env_bool "HOLBUILD_SHARE_COMMON_DATA", default_share)
        val timing = Option.getOpt(env_bool "HOLBUILD_CHECKPOINT_TIMING", false)
        val t0 = Time.now()
        val _ = begin_replacement path
        val _ = if share then PolyML.shareCommonData PolyML.rootFunction else ()
        val t1 = Time.now()
        val _ = with_theory_cpu_carried (fn () => PolyML.SaveState.saveChild(path, depth))
        val t2 = Time.now()
        val _ = write_text_atomically (ok_path path) ok_text
        val _ =
          if timing then
            TextIO.output
              (TextIO.stdErr,
               String.concat ["holbuild checkpoint kind=", label,
                              " share=", bool_text share,
                              " depth=", Int.toString depth,
                              " share_s=", fmt_time (seconds (t0, t1)),
                              " save_s=", fmt_time (seconds (t1, t2)),
                              " size=", Position.toString (OS.FileSys.fileSize path),
                              " path=", path, "\n"])
          else ()
      in
        ()
      end
  in
    if QUse.hadError () then discard_checkpoint path
    else save ()
    handle e =>
      if checkpoint_io_failure e then
        (discard_checkpoint path; warn_checkpoint_failure label path e)
      else raise e
  end

end

val _ =
  (ignore (Listener.remove_listener Theory.delta_hook "HolbuildCheckpointSaveRuntime.theory_cpu");
   Theory.register_hook ("HolbuildCheckpointSaveRuntime.theory_cpu",
                         HolbuildCheckpointSaveRuntime.theory_cpu_hook));

(* A process that resumes from a checkpoint saved within a theory loads this
   file first: its share of the theory's time begins here. *)
val _ =
  if Option.isSome (!HolbuildTheoryCpuState.carried) andalso
     not (Option.isSome (!HolbuildTheoryCpuState.since))
  then HolbuildTheoryCpuState.since := SOME (HolbuildCheckpointSaveRuntime.process_cpu ())
  else ();
