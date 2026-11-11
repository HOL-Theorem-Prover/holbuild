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

(* Extracts the named members and what is under them; no names extracts all. *)
fun extract_members {archive_path, destination, members} =
  run
    ("umask 022; TAR_OPTIONS= tar -xf " ^ quote archive_path ^ " -C " ^ quote destination ^
     " --no-same-owner --no-same-permissions --delay-directory-restore" ^
     (if null members then ""
      else " --no-wildcards --anchored" ^ String.concat (map (fn member => " " ^ quote member) members)))
    ("could not extract tar archive: " ^ archive_path)

fun extract {archive_path, destination} =
  extract_members {archive_path = archive_path, destination = destination, members = []}

(* A member's type letter and name from one `tar -tv` line, which reads
   `<type+mode> <owner/group> <size> <date> <time> <name>`; a link's name is
   followed by its target. *)
fun parse_listing_line line =
  let
    fun skip_field text =
      Substring.dropl (not o Char.isSpace) (Substring.dropl Char.isSpace text)
    fun skip_fields (0, text) = text
      | skip_fields (n, text) = skip_fields (n - 1, skip_field text)
    val rest = skip_fields (5, Substring.full line)
  in
    if size line = 0 orelse Substring.isEmpty rest then die ("unrecognized tar listing line: " ^ line)
    else (String.sub (line, 0), Substring.string (Substring.triml 1 rest))
  end

fun list_listing archive_path =
  let
    val listing = HolbuildTempPath.near archive_path ".list"
    fun cleanup () = OS.FileSys.remove listing handle OS.SysErr _ => ()
    fun read () =
      let val input = TextIO.openIn listing
      in TextIO.inputAll input before TextIO.closeIn input end
  in
    (run ("TAR_OPTIONS= tar -tvf " ^ quote archive_path ^
          " --numeric-owner --quoting-style=escape > " ^ quote listing)
         ("could not list tar archive: " ^ archive_path);
     read () before cleanup ())
    handle e => (cleanup (); raise e)
  end

fun strip_trailing_slash name =
  if String.isSuffix "/" name then String.substring (name, 0, size name - 1) else name

fun check_member archive_path (kind, name) =
  let
    fun reject why = die ("unsafe tar member in " ^ archive_path ^ ": " ^ name ^ " (" ^ why ^ ")")
  in
    case kind of
        #"-" => ()
      | #"d" => ()
      | #"l" => reject "symbolic link"
      | #"h" => reject "hard link"
      | #"c" => reject "device"
      | #"b" => reject "device"
      | #"p" => reject "FIFO"
      | _ => reject ("not a regular file or directory, type " ^ str kind);
    if String.isPrefix "/" name then reject "absolute path" else ();
    if List.exists (fn component => component = "..") (String.fields (fn c => c = #"/") name)
    then reject "contains .." else ()
  end

(* The member names of an archive of regular files and directories only,
   without `..` or absolute names; any other member is an error naming it. *)
fun checked_names archive_path =
  let
    val lines = List.filter (fn line => line <> "")
                  (String.fields (fn c => c = #"\n") (list_listing archive_path))
    val members = map parse_listing_line lines
    val _ = List.app (check_member archive_path) members
  in
    map (strip_trailing_slash o #2) members
  end

end
