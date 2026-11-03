structure HolbuildCheckpointStore =
struct

structure FS = OS.FileSys

fun ok_path path = path ^ ".ok"

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun file_exists path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun rename_file old new = FS.rename {old = old, new = new}

fun read_text path =
  let
    val input = TextIO.openIn path
    fun close () = TextIO.closeIn input handle _ => ()
    fun loop acc =
      case TextIO.inputLine input of
          NONE => String.concat (rev acc)
        | SOME line => loop (line :: acc)
  in
    (loop [] before close ()) handle e => (close (); raise e)
  end

fun current_metadata path = SOME (read_text path) handle IO.Io _ => NONE

fun remove_checkpoint path =
  (remove_file (ok_path path ^ ".tmp");
   remove_file (path ^ ".tmp");
   remove_file (ok_path path ^ ".bak");
   remove_file (path ^ ".bak");
   remove_file (ok_path path);
   remove_file (path ^ ".meta");
   remove_file (path ^ ".prefix");
   remove_file (path ^ ".steps");
   remove_file path)

fun ok_v1 () = "holbuild-checkpoint-ok-v1\n"

fun ok_text kind fields =
  String.concatWith "\n" (["holbuild-checkpoint-ok-v2", "kind=" ^ kind] @
                          map (fn (key, value) => key ^ "=" ^ value) fields) ^ "\n"

fun metadata_lines text = String.tokens (fn c => c = #"\n") text

fun first_some f values =
  case values of
      [] => NONE
    | x :: xs =>
        case f x of
            SOME y => SOME y
          | NONE => first_some f xs

fun metadata_value key lines =
  let val prefix = key ^ "="
  in
    first_some (fn line =>
                  if String.isPrefix prefix line then
                    SOME (String.extract(line, size prefix, NONE))
                  else NONE)
               lines
  end

fun remove_incomplete_residue warn path =
  if file_exists (ok_path path) andalso not (file_exists path) then
    (warn ("checkpoint metadata exists without checkpoint file; discarding metadata: " ^ path);
     remove_file (ok_path path);
     remove_file (path ^ ".meta");
     remove_file (path ^ ".prefix"))
  else ()

fun metadata_matches_fields fields text =
  let val lines = metadata_lines text
  in
    List.exists (fn line => line = "holbuild-checkpoint-ok-v2") lines andalso
    List.all (fn (key, value) => metadata_value key lines = SOME value) fields
  end

fun current_matches path metadata_matches =
  file_exists path andalso
  (case current_metadata (ok_path path) of
       SOME text => metadata_matches text
     | NONE => false)

fun checkpoint_matches warn path metadata_matches =
  (remove_incomplete_residue warn path;
   current_matches path metadata_matches)

fun ok_text_matches warn path expected_text =
  checkpoint_matches warn path (fn text => text = expected_text)

fun ok_matches warn path fields =
  checkpoint_matches warn path (metadata_matches_fields fields)

(* Read-only counterparts for callers that hold no project lock: incomplete
   residue belongs to a build that may still be running, so leave it alone. *)
fun ok_text_current path expected_text =
  current_matches path (fn text => text = expected_text)

fun ok_current path fields =
  current_matches path (metadata_matches_fields fields)

end
