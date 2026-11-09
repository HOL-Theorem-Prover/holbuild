structure HolbuildRemoveTree =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

fun lstat path = SOME (Posix.FileSys.lstat path) handle OS.SysErr _ => NONE

(* rm -rf: symlinks are removed, never followed; errors are ignored.  With
   restore, a directory without owner access gets it back first. *)
fun remove_entry restore path =
  (case lstat path of
       NONE => ()
     | SOME st =>
         if Posix.FileSys.ST.isDir st then
           let
             val owner = Posix.FileSys.S.irwxu
             val _ = if not restore orelse Posix.FileSys.S.allSet (owner, Posix.FileSys.ST.mode st) then ()
                     else Posix.FileSys.chmod (path, owner)
             val dir = FS.openDir path
             fun names acc = case FS.readDir dir of NONE => acc | SOME name => names (name :: acc)
             val entries = (names [] handle e => (FS.closeDir dir; raise e)) before FS.closeDir dir
           in
             List.app (fn name => remove_entry restore (Path.concat (path, name))) entries;
             FS.rmDir path
           end
         else FS.remove path)
  handle OS.SysErr _ => ()

fun unsafe path = path = "" orelse path = "." orelse path = "/"

fun remove_with restore path =
  if unsafe path then
    raise Error ("refusing to remove unsafe path: " ^ path)
  else remove_entry restore path

val remove = remove_with false

fun strict remove path =
  (remove path;
   if Option.isSome (lstat path) then raise Error ("failed to remove path: " ^ path) else ())

(* Like remove, but raises if anything is left at path. *)
val remove_strict = strict remove

(* For trees submitted code wrote: it can create a directory without owner
   access, which would otherwise survive removal. *)
val remove_untrusted = remove_with true
val remove_untrusted_strict = strict remove_untrusted

end
