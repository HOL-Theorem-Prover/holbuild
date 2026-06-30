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

fun large_file path =
  (Position.toInt (OS.FileSys.fileSize path) >= 1048576)
  handle Overflow => true
       | OS.SysErr _ => false

fun string_byte_reader text (offset, requested) =
  let
    val remaining = Int.max(0, size text - offset)
    val count = Int.min(requested, remaining)
    fun byte i = Word8.fromInt (Char.ord (String.sub(text, offset + i)))
  in
    (Word8Vector.tabulate(count, byte), offset + count)
  end

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

fun string_sha1 text = SHA1_ML.sha1String (string_byte_reader text) 0
fun string_sha256 text = SHA256.hashStringHex text

fun file_sha1 path =
  if large_file path then
    case external_sha1 path of
        SOME hash => hash
      | NONE => SHA1_ML.sha1_file {filename = path}
  else SHA1_ML.sha1_file {filename = path}

fun file_sha256 path =
  if large_file path then
    case external_sha256 path of
        SOME hash => hash
      | NONE => string_sha256 (read_binary_all path)
  else
    case external_sha256 path of
        SOME hash => hash
      | NONE => string_sha256 (read_binary_all path)

end
