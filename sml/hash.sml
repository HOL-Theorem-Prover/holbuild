structure HolbuildHash =
struct

fun quote s =
  "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun is_hex c = Char.isDigit c orelse
               (#"a" <= c andalso c <= #"f") orelse
               (#"A" <= c andalso c <= #"F")

fun valid_hex length text = size text = length andalso List.all is_hex (String.explode text)

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
    val run = HolbuildSpawn.run {program = command_name, args = [path],
                                 stderr = HolbuildSpawn.Inherit}
    val result = if HolbuildSpawn.succeeded run then first_token (#output run) else NONE
  in
    case result of
        SOME hash => if valid hash then SOME (String.map Char.toLower hash) else NONE
      | NONE => NONE
  end
  handle _ => NONE

fun external_sha256 path = external_hash "sha256sum" valid_sha256 path

val small_file_limit = 196608

(* Starting sha256sum costs ~0.8ms and HolbuildSha256 hashes ~60 MB/s, so
   hashing in SML is faster for files below ~50 KiB. *)
val external_hash_limit = 65536

fun large_file path =
  (Position.toInt (OS.FileSys.fileSize path) >= external_hash_limit)
  handle Overflow => true
       | OS.SysErr _ => false

fun read_binary_all path =
  let
    val input = BinIO.openIn path
    val text = Byte.bytesToString (BinIO.inputAll input)
               handle e => (BinIO.closeIn input; raise e)
  in
    BinIO.closeIn input;
    text
  end

(* A libcrypto call failed: hash that input the other way. *)
exception Native

(* SHA-256 through OpenSSL 3's libcrypto, bound with Foreign: 10 to 40 times
   the speed of HolbuildSha256, with no process per file like sha256sum.  Both
   give the same digests, so no key depends on which one ran.  It is loaded on
   the first hash; where it can't be, everything here hashes in SML and with
   sha256sum as before. *)
local
  open Foreign

  fun is_darwin () =
    List.exists (fn field => field = ("sysname", "Darwin")) (Posix.ProcEnv.uname ())

  fun file_exists path = OS.FileSys.access (path, []) handle OS.SysErr _ => false

  (* On macOS only Homebrew's OpenSSL 3, by a path that exists: loading the
     system's unversioned libcrypto.dylib aborts the process, and dlopen of a
     missing path can fall back to it. *)
  fun library_name () =
    case OS.Process.getEnv "HOLBUILD_TEST_LIBCRYPTO" of
        SOME name => name
      | NONE =>
          if not (is_darwin ()) then "libcrypto.so.3"
          else
            case List.find file_exists ["/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib",
                                   "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib"] of
                SOME path => path
              | NONE => raise Foreign "no OpenSSL 3 libcrypto"

  (* Foreign looks a symbol up on its first call and caches the address with
     an unsynchronised byte-by-byte copy, so threads making their first call
     through the same symbol at once can read a half-written address and jump
     to it.  load resolves every symbol before any hash calls one. *)
  val symbols : symbol list ref = ref []
  fun recorded lookup name =
    let val symbol = lookup name in symbols := symbol :: !symbols; symbol end
  val crypto = recorded (getSymbol (loadLibraryIndirect library_name))
  val libc = recorded (getSymbol (loadExecutable ()))

  val md_fetch = buildCall3 (crypto "EVP_MD_fetch", (cPointer, cString, cPointer), cPointer)
  val evp_digest =
    buildCall6 (crypto "EVP_Digest",
                (cByteArray, cSize, cPointer, cPointer, cPointer, cPointer), cInt)
  val ctx_new = buildCall0 (crypto "EVP_MD_CTX_new", (), cPointer)
  val ctx_free = buildCall1 (crypto "EVP_MD_CTX_free", cPointer, cVoid)
  val digest_init = buildCall3 (crypto "EVP_DigestInit_ex", (cPointer, cPointer, cPointer), cInt)
  val digest_update = buildCall3 (crypto "EVP_DigestUpdate", (cPointer, cPointer, cSize), cInt)
  val digest_final = buildCall3 (crypto "EVP_DigestFinal_ex", (cPointer, cPointer, cPointer), cInt)
  val read = buildCall3 (libc "read", (cInt, cPointer, cSize), cSsize)

  fun with_memory size f =
    let val p = Memory.malloc size
    in f p before Memory.free p handle e => (Memory.free p; raise e) end

  fun check result = if result = 1 then () else raise Native

  fun hex_digest out =
    CharVector.tabulate (64, fn i =>
      let val byte = Word8.toInt (Memory.get8 (out, Word.fromInt (i div 2)))
      in String.sub ("0123456789abcdef", if i mod 2 = 0 then byte div 16 else byte mod 16) end)

  fun finish f = with_memory 0w32 (fn out => (f out; hex_digest out))

  fun string_digest md text =
    finish (fn out =>
      check (evp_digest (Byte.stringToBytes text, size text, out, Memory.null, md, Memory.null)))

  val chunk_size = 1048576

  (* The file is read into C memory a chunk at a time, never into the heap. *)
  fun file_digest md path =
    let
      val fd = Posix.FileSys.openf (path, Posix.FileSys.O_RDONLY, Posix.FileSys.O.flags [])
               handle OS.SysErr _ => raise Native
      val fd_number = SysWord.toInt (Posix.FileSys.fdToWord fd)
      fun hash ctx buffer =
        let
          fun loop () =
            let val n = read (fd_number, buffer, chunk_size)
            in
              if n > 0 then (check (digest_update (ctx, buffer, n)); loop ())
              else if n = 0 then ()
              else raise Native
            end
        in
          check (digest_init (ctx, md, Memory.null));
          loop ();
          finish (fn out => check (digest_final (ctx, out, Memory.null)))
        end
      fun with_ctx f =
        let val ctx = ctx_new ()
        in
          if ctx = Memory.null then raise Native
          else f ctx before ctx_free ctx handle e => (ctx_free ctx; raise e)
        end
    in
      with_ctx (fn ctx => with_memory (Word.fromInt chunk_size) (hash ctx))
        before Posix.IO.close fd
      handle e => (Posix.IO.close fd; raise e)
    end

  (* Fetching SHA256 once also fills OpenSSL's method store for it before
     any thread hashes; OpenSSL 3 before 3.0.15 adds to that store without
     a lock against readers (see HolbuildHttp). *)
  fun load () =
    let
      val _ = List.app (ignore o symbolAsAddress) (!symbols)
      val md = md_fetch (Memory.null, "SHA256", Memory.null)
      val abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    in
      if md <> Memory.null andalso string_digest md "abc" = abc
      then SOME {string = string_digest md, file = file_digest md}
      else NONE
    end
    handle Foreign _ => NONE
         | Native => NONE

  val lock = Mutex.mutex ()
  val state : {string : string -> string, file : string -> string} option option ref = ref NONE
in
  (* The libcrypto hash functions, or NONE without libcrypto.  The lock also
     makes another thread's load visible to this one. *)
  fun native () =
    let
      val _ = Mutex.lock lock
      val result =
        case !state of
            SOME result => result
          | NONE => let val result = load () in state := SOME result; result end
    in
      Mutex.unlock lock;
      result
    end
    handle e => (Mutex.unlock lock; raise e)
end

fun uses_libcrypto () = Option.isSome (native ())

fun string_sha256 text =
  case native () of
      SOME {string, ...} => (string text handle Native => HolbuildSha256.string_hex text)
    | NONE => HolbuildSha256.string_hex text

fun string_sha256_large text =
  if size text < small_file_limit orelse uses_libcrypto () then string_sha256 text
  else
    let
      val path = HolbuildTempPath.temporary "hash-input"
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

fun fallback_file_sha256 path =
  if large_file path then
    case external_sha256 path of
        SOME hash => hash
      | NONE => string_sha256 (read_binary_all path)
  else string_sha256 (read_binary_all path)

fun file_sha256 path =
  case native () of
      SOME {file, ...} => (file path handle Native => fallback_file_sha256 path)
    | NONE => fallback_file_sha256 path

(* Try one external batch of COMMAND (a GNU *sum tool printing DIGITS hex
   digits per file) without hashing a partially missing batch natively. *)
fun external_files_hash _ _ [] = SOME []
  | external_files_hash command digits paths =
  let
    fun digest line =
      let val hex = if String.isPrefix "\\" line then String.extract(line, 1, NONE) else line
      in
        if size hex >= digits andalso valid_hex digits (String.substring(hex, 0, digits))
        then SOME (String.map Char.toLower (String.substring(hex, 0, digits)))
        else NONE
      end
    val result = HolbuildSpawn.run
      {program = command, args = "--" :: paths, stderr = HolbuildSpawn.Discard}
    val lines =
      if HolbuildSpawn.succeeded result
      then String.tokens (fn c => c = #"\n") (#output result)
      else []
    val digests = List.mapPartial digest lines
  in
    if length digests = length paths andalso length lines = length paths
    then SOME digests
    else NONE
  end
  handle _ => NONE

fun external_files_sha256 paths = external_files_hash "sha256sum" 64 paths

(* Spawning one process per file, or hashing in SML, costs far more than the
   hashing itself, so hash a batch of files with one COMMAND per chunk.  Any
   chunk whose output doesn't give one digest per file is hashed file by file
   with FALLBACK. *)
fun files_hash {command, digits, fallback} paths =
  let
    val chunk_size = 256
    fun hash_chunk chunk =
      case external_files_hash command digits chunk of
          SOME digests => digests
        | NONE => map fallback chunk
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

fun files_sha256 paths =
  if uses_libcrypto () then map file_sha256 paths
  else files_hash {command = "sha256sum", digits = 64, fallback = file_sha256} paths

(* One digest per file, or NONE when any of them can't be hashed. *)
fun all_files_sha256 paths =
  case native () of
      SOME {file, ...} => (SOME (map file paths) handle Native => NONE)
    | NONE => external_files_sha256 paths

end
