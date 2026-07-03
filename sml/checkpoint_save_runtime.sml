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
   pair stale metadata with partial save bytes. *)
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
        val _ = PolyML.SaveState.saveChild(path, depth)
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
    save ()
    handle e =>
      if checkpoint_io_failure e then
        (discard_checkpoint path; warn_checkpoint_failure label path e)
      else raise e
  end

end
