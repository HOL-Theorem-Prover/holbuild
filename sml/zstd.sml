structure HolbuildZstd =
struct

(* Decodes a zstd file made of independent frames on several threads,
   through libzstd bound with Foreign.  bazel-remote's zstd storage sends a
   blob as a skippable seek-table frame followed by one frame per MiB of
   content, each with its content size.  libcurl decodes such a response on
   the one thread that runs its transfers, at about 1.2 GB/s of output, which
   for a restore's deps heap of hundreds of MB takes several times as long as
   the transfer. *)

(* The file can't be decoded here: libzstd is missing, or a frame is not
   valid zstd or doesn't give its content size. *)
exception Error of string

local
  open Foreign

  fun is_darwin () =
    List.exists (fn field => field = ("sysname", "Darwin")) (Posix.ProcEnv.uname ())

  fun file_exists path = OS.FileSys.access (path, []) handle OS.SysErr _ => false

  fun library_name () =
    case OS.Process.getEnv "HOLBUILD_TEST_LIBZSTD" of
        SOME name => name
      | NONE =>
          if not (is_darwin ()) then "libzstd.so.1"
          else
            case List.find file_exists ["/opt/homebrew/opt/zstd/lib/libzstd.1.dylib",
                                        "/usr/local/opt/zstd/lib/libzstd.1.dylib"] of
                SOME path => path
              | NONE => raise Foreign "no libzstd"

  (* Foreign caches a symbol's address on its first call without a lock (see
     HolbuildHash), so load resolves every symbol before any thread decodes. *)
  val symbols : symbol list ref = ref []
  fun recorded lookup name =
    let val symbol = lookup name in symbols := symbol :: !symbols; symbol end
  val zstd = recorded (getSymbol (loadLibraryIndirect library_name))
  val libc = recorded (getSymbol (loadExecutable ()))

  (* libzstd's errors and unknown sizes are the largest 64-bit values,
     beyond int; size_t is 64 bits wherever holbuild runs. *)
  val find_frame_compressed_size =
    buildCall2 (zstd "ZSTD_findFrameCompressedSize", (cPointer, cSize), cUint64Large)
  val get_frame_content_size =
    buildCall2 (zstd "ZSTD_getFrameContentSize", (cPointer, cSize), cUint64Large)
  val decompress =
    buildCall4 (zstd "ZSTD_decompress", (cPointer, cSize, cPointer, cSize), cUint64Large)
  val is_error = buildCall1 (zstd "ZSTD_isError", cUint64Large, cUint)
  val read = buildCall3 (libc "read", (cInt, cPointer, cSize), cSsize)
  val pwrite = buildCall4 (libc "pwrite", (cInt, cPointer, cSize, cInt64), cSsize)

  fun load () =
    (List.app (ignore o symbolAsAddress) (!symbols); true)
    handle Foreign _ => false

  val lock = Mutex.mutex ()
  val loaded : bool option ref = ref NONE

  (* ZSTD_CONTENTSIZE_UNKNOWN and ZSTD_CONTENTSIZE_ERROR are the two largest
     64-bit values. *)
  val content_size_unknown : LargeInt.int = 18446744073709551614

  (* A size libzstd returned, once is_error has ruled out an error code. *)
  fun checked what size =
    if is_error size <> 0 then raise Error what
    else LargeInt.toInt size handle Overflow => raise Error what

  fun at (base, offset) = Memory.++ (base, Word.fromInt offset)

  fun fd_number fd = SysWord.toInt (Posix.FileSys.fdToWord fd)

  fun with_memory size f =
    let val p = Memory.malloc (Word.fromInt (Int.max (size, 1)))
    in f p before Memory.free p handle e => (Memory.free p; raise e) end

  fun with_fd fd f = f (fd_number fd) before Posix.IO.close fd
                     handle e => (Posix.IO.close fd; raise e)

  fun read_into fd buffer size =
    let
      fun loop done =
        if done = size then ()
        else
          let val n = read (fd, at (buffer, done), size - done)
          in
            if n > 0 then loop (done + n)
            else raise Error ("short read of the zstd input after " ^ Int.toString done ^ " bytes")
          end
    in loop 0 end

  fun write_at fd buffer size offset =
    let
      fun loop done =
        if done = size then ()
        else
          let val n = pwrite (fd, at (buffer, done), Int.min (HolbuildBoundedOutput.max_write, size - done), offset + done)
          in
            if n > 0 then loop (done + n)
            else raise OS.SysErr ("could not write the decoded zstd output", NONE)
          end
    in loop 0 end

  fun skippable src =
    let fun byte i = Word.fromLargeWord (Word8.toLargeWord (Memory.get8 (src, Word.fromInt i)))
        val magic = Word.orb (Word.orb (byte 0, Word.<< (byte 1, 0w8)),
                              Word.orb (Word.<< (byte 2, 0w16), Word.<< (byte 3, 0w24)))
    in Word.andb (magic, 0wxFFFFFFF0) = 0wx184D2A50 end

  (* Each data frame's place in the input and the output, in order. *)
  fun frames src size =
    let
      fun loop offset output acc =
        if offset = size then rev acc
        else
          let
            val frame = at (src, offset)
            val length = checked "not a zstd frame" (find_frame_compressed_size (frame, size - offset))
          in
            if skippable frame then loop (offset + length) output acc
            else
              let val content = get_frame_content_size (frame, size - offset)
              in
                if content >= content_size_unknown then
                  raise Error "a zstd frame without its content size"
                else
                  let val content = LargeInt.toInt content
                  in
                    loop (offset + length) (output + content)
                         ({input = offset, length = length, output = output, content = content} :: acc)
                  end
              end
          end
    in loop 0 0 [] end

  (* Runs each of works on its own thread and raises the first failure once
     all have finished.  Interrupts are deferred meanwhile, so the caller
     can't unwind and free the buffers and descriptor the threads still use. *)
  fun run_all works = HolbuildHttp.uninterruptible (fn () =>
    let
      val mutex = Mutex.mutex ()
      val finished = ConditionVar.conditionVar ()
      val running = ref 0
      val failure = ref NONE
      fun finish result =
        (Mutex.lock mutex;
         running := !running - 1;
         (case (result, !failure) of (SOME e, NONE) => failure := SOME e | _ => ());
         ConditionVar.broadcast finished;
         Mutex.unlock mutex)
      fun start work =
        (Mutex.lock mutex; running := !running + 1; Mutex.unlock mutex;
         ignore (Thread.fork (fn () => finish ((work (); NONE) handle e => SOME e), []))
         handle e => (finish (SOME e)))
      fun wait () = if !running > 0 then (ConditionVar.wait (finished, mutex); wait ()) else ()
    in
      List.app start works;
      Mutex.lock mutex; wait (); Mutex.unlock mutex;
      case !failure of SOME e => raise e | NONE => ()
    end)

  fun decode_group src out group () =
    let val capacity = List.foldl (fn ({content, ...}, m) => Int.max (content, m)) 0 group
    in
      with_memory capacity (fn buffer =>
        List.app (fn {input, length, output, content} =>
          let val n = checked "a zstd frame failed to decode" (decompress (buffer, content, at (src, input), length))
          in
            if n <> content then raise Error "a zstd frame failed to decode"
            else write_at out buffer content output
          end) group)
    end

  (* Frame i goes to group i mod count. *)
  fun deal count items =
    List.tabulate (count, fn g =>
      #2 (List.foldr (fn (item, (i, acc)) => (i - 1, if i mod count = g then item :: acc else acc))
                     (length items - 1, []) items))
in
  (* Whether libzstd could be loaded.  The lock also makes another thread's
     load visible to this one. *)
  fun available () =
    let
      val _ = Mutex.lock lock
      val result =
        case !loaded of
            SOME result => result
          | NONE => let val result = load () in loaded := SOME result; result end
    in
      Mutex.unlock lock;
      result
    end
    handle e => (Mutex.unlock lock; raise e)

  (* Writes the content of the zstd file src to dst, its frames split
     between up to threads threads.  Raises Error when it can't decode src;
     dst may then hold part of the content. *)
  fun decode_file {src, dst, threads} =
    if not (available ()) then raise Error "libzstd is not available"
    else
      let
        val size = Position.toInt (OS.FileSys.fileSize src)
        val input = Posix.FileSys.openf (src, Posix.FileSys.O_RDONLY, Posix.FileSys.O.flags [])
        val mode = Posix.FileSys.S.flags
          [Posix.FileSys.S.irusr, Posix.FileSys.S.iwusr, Posix.FileSys.S.irgrp,
           Posix.FileSys.S.iwgrp, Posix.FileSys.S.iroth, Posix.FileSys.S.iwoth]
      in
        with_memory size (fn buffer =>
          (with_fd input (fn fd => read_into fd buffer size);
           let
             val frames = frames buffer size
             val output = Posix.FileSys.createf (dst, Posix.FileSys.O_WRONLY, Posix.FileSys.O.trunc, mode)
             val count = Int.max (1, Int.min (threads, length frames))
           in
             with_fd output (fn out =>
               run_all (map (decode_group buffer out) (List.filter (not o null) (deal count frames))))
           end))
      end
end

end
