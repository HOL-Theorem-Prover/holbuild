structure HolbuildHash =
struct

fun quote s =
  "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun is_hex c = Char.isDigit c orelse
               (#"a" <= c andalso c <= #"f") orelse
               (#"A" <= c andalso c <= #"F")

fun valid_hex length text = size text = length andalso List.all is_hex (String.explode text)

fun valid_sha1 text = valid_hex 40 text
fun valid_sha256 text = valid_hex 64 text

fun read_all path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input
     handle e => (TextIO.closeIn input; raise e)
  end

fun first_token text =
  case String.tokens Char.isSpace text of
      token :: _ => SOME token
    | [] => NONE

fun remove_quietly path = OS.FileSys.remove path handle OS.SysErr _ => ()

fun external_hash command_name valid path =
  let
    val out = OS.FileSys.tmpName ()
    val command = command_name ^ " " ^ quote path ^ " > " ^ quote out
    val status = OS.Process.system command
    val result =
      if OS.Process.isSuccess status then first_token (read_all out)
      else NONE
    val _ = remove_quietly out
  in
    case result of
        SOME hash => if valid hash then SOME (String.map Char.toLower hash) else NONE
      | NONE => NONE
  end
  handle _ => NONE

fun external_sha1 path = external_hash "sha1sum" valid_sha1 path
fun external_sha256 path = external_hash "sha256sum" valid_sha256 path

val small_file_limit = 196608

fun large_file path =
  (Position.toInt (OS.FileSys.fileSize path) >= small_file_limit)
  handle Overflow => true
       | OS.SysErr _ => false

fun vector_string bytes =
  String.implode
    (List.tabulate (Word8Vector.length bytes,
                    fn i => Char.chr (Word8.toInt (Word8Vector.sub(bytes, i)))))

fun read_binary_all path =
  let
    val input = BinIO.openIn path
    fun loop chunks =
      let val chunk = BinIO.inputN(input, 65536)
      in
        if Word8Vector.length chunk = 0 then String.concat (rev chunks)
        else loop (vector_string chunk :: chunks)
      end
    val text = loop [] handle e => (BinIO.closeIn input; raise e)
  in
    BinIO.closeIn input;
    text
  end

val string_sha1 = HolbuildStringHash.string_sha1
fun string_sha256 text = SHA256.hashStringHex text

(* macOS ships shasum but not sha256sum.  stderr is dropped since every
   failure falls back to the SML implementation. *)
val stdin_sha256_command =
  "if command -v sha256sum >/dev/null 2>&1; then exec sha256sum 2>/dev/null; " ^
  "else exec shasum -a 256 2>/dev/null; fi"

(* Unix.execute leaves the parent's pipe ends inheritable, so this must not
   run while other threads launch children: one could hold the child's stdin
   open.  Poly/ML ignores SIGPIPE, so a child that exits early makes the
   write raise Io, and Unix.reap's close of the closed stdin is a no-op. *)
fun piped_sha256 command text =
  let
    val proc = Unix.execute ("/bin/sh", ["-c", command])
    val input = Unix.textInstreamOf proc
    val output = Unix.textOutstreamOf proc
    val written =
      (TextIO.output (output, text); TextIO.closeOut output; true)
      handle IO.Io _ => (TextIO.closeOut output handle IO.Io _ => (); false)
    val result = TextIO.inputAll input handle IO.Io _ => ""
    val status = Unix.reap proc
  in
    if written andalso OS.Process.isSuccess status then
      case first_token result of
          SOME hash => if valid_sha256 hash then SOME (String.map Char.toLower hash) else NONE
        | NONE => NONE
    else NONE
  end
  handle OS.SysErr _ => NONE

fun string_sha256_large text =
  if size text < small_file_limit then string_sha256 text
  else
    case piped_sha256 stdin_sha256_command text of
        SOME digest => digest
      | NONE => string_sha256 text

fun file_sha1 path =
  if large_file path then
    case external_sha1 path of
        SOME hash => hash
      | NONE => SHA1_ML.sha1_file {filename = path}
  else SHA1_ML.sha1_file {filename = path}

fun file_sha256 path =
  case external_sha256 path of
      SOME hash => hash
    | NONE => string_sha256 (read_binary_all path)

end
