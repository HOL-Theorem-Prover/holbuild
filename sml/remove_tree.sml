structure HolbuildRemoveTree =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

fun lstat path = SOME (Posix.FileSys.lstat path) handle OS.SysErr _ => NONE

(* rm -rf: symlinks are removed, never followed; errors are ignored. *)
fun remove_entry path =
  (case lstat path of
       NONE => ()
     | SOME st =>
         if Posix.FileSys.ST.isDir st then
           let
             val dir = FS.openDir path
             fun names acc = case FS.readDir dir of NONE => acc | SOME name => names (name :: acc)
             val entries = (names [] handle e => (FS.closeDir dir; raise e)) before FS.closeDir dir
           in
             List.app (fn name => remove_entry (Path.concat (path, name))) entries;
             FS.rmDir path
           end
         else FS.remove path)
  handle OS.SysErr _ => ()

fun remove path =
  if path = "" orelse path = "." orelse path = "/" then
    raise Error ("refusing to remove unsafe path: " ^ path)
  else remove_entry path

(* Like remove, but raises if anything is left at path. *)
fun remove_strict path =
  (remove path;
   if Option.isSome (lstat path) then raise Error ("failed to remove path: " ^ path) else ())

end
