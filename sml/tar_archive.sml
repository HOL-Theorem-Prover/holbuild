structure HolbuildTar =
struct

exception Error of string

fun die msg = raise Error msg
fun quote text = HolbuildHash.quote text

fun run command failure =
  if OS.Process.isSuccess (OS.Process.system command) then () else die failure

fun source_arguments (directory, members) =
  " -C " ^ quote directory ^
  String.concat (map (fn member => " " ^ quote member) members)

fun exclude_argument pattern = " " ^ quote ("--exclude=" ^ pattern)

fun create {archive_path, sources, excludes, hard_dereference} =
  let
    val command =
      "TAR_OPTIONS= tar --format=pax --pax-option=delete=atime,delete=ctime " ^
      "--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner" ^
      (if hard_dereference then " --hard-dereference" else "") ^
      String.concat (map exclude_argument excludes) ^
      " -cf " ^ quote archive_path ^
      String.concat (map source_arguments sources)
  in
    run command ("could not create tar archive: " ^ archive_path)
  end

fun extract {archive_path, destination} =
  run
    ("umask 022; TAR_OPTIONS= tar -xf " ^ quote archive_path ^ " -C " ^ quote destination ^
     " --no-same-owner --no-same-permissions --delay-directory-restore")
    ("could not extract tar archive: " ^ archive_path)

end
