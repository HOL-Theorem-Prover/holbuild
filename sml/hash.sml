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

fun string_sha256_large text =
  if size text < small_file_limit then string_sha256 text
  else
    let
      val path = OS.FileSys.tmpName ()
      val result =
        (let
           val output = BinIO.openOut path
           val _ = (BinIO.output (output, Byte.stringToBytes text);
                    BinIO.closeOut output)
                   handle e => (BinIO.closeOut output; raise e)
         in
           external_sha256 path
         end)
        handle e => (remove_quietly path; raise e)
      val _ = remove_quietly path
    in
      case result of
          SOME digest => digest
        | NONE => string_sha256 text
    end
    handle _ => string_sha256 text

fun file_sha1 path =
  if large_file path then
    case external_sha1 path of
        SOME hash => hash
      | NONE => SHA1_ML.sha1_file {filename = path}
  else SHA1_ML.sha1_file {filename = path}

(* Spawning one process per file, or hashing in SML, costs far more than the
   hashing itself, so hash a batch of files with one sha1sum per chunk.  Any
   chunk whose output doesn't give one digest per file is hashed file by file. *)
fun files_sha1 paths =
  let
    val chunk_size = 256
    fun digest line =
      let val hex = if String.isPrefix "\\" line then String.extract(line, 1, NONE) else line
      in
        if size hex >= 40 andalso valid_sha1 (String.substring(hex, 0, 40))
        then SOME (String.map Char.toLower (String.substring(hex, 0, 40)))
        else NONE
      end
    fun external chunk =
      let
        val out = OS.FileSys.tmpName ()
        val command =
          "sha1sum -- " ^ String.concatWith " " (map quote chunk) ^
          " > " ^ quote out ^ " 2>/dev/null"
        val status = OS.Process.system command
        val lines =
          if OS.Process.isSuccess status
          then String.tokens (fn c => c = #"\n") (read_all out)
          else []
        val _ = remove_quietly out
        val digests = List.mapPartial digest lines
      in
        if length digests = length chunk andalso length lines = length chunk
        then SOME digests
        else NONE
      end
      handle _ => NONE
    fun hash_chunk chunk =
      case external chunk of
          SOME digests => digests
        | NONE => map file_sha1 chunk
    fun loop [] acc = List.concat (rev acc)
      | loop paths acc =
          let
            val n = Int.min(chunk_size, length paths)
          in
            loop (List.drop(paths, n)) (hash_chunk (List.take(paths, n)) :: acc)
          end
  in
    loop paths []
  end

fun file_sha256 path =
  case external_sha256 path of
      SOME hash => hash
    | NONE => string_sha256 (read_binary_all path)

end
