(* PROTOTYPE: remote-cache HTTP through libcurl via Poly/ML Foreign. *)
structure HolbuildCurl =
struct

local
  open Foreign
  val lib = loadLibrary "libcurl.so.4"
  val libc = loadExecutable ()
  val sym = getSymbol lib
  val csym = getSymbol libc
in
  val global_init = buildCall1 (sym "curl_global_init", cLong, cInt)
  val easy_init = buildCall0 (sym "curl_easy_init", (), cPointer)
  val easy_strerror = buildCall1 (sym "curl_easy_strerror", cInt, cString)
  val setopt_long = buildCall3 (sym "curl_easy_setopt", (cPointer, cInt, cLong), cInt)
  val setopt_ptr = buildCall3 (sym "curl_easy_setopt", (cPointer, cInt, cPointer), cInt)
  val setopt_str = buildCall3 (sym "curl_easy_setopt", (cPointer, cInt, cString), cInt)
  val setopt_fn = buildCall3 (sym "curl_easy_setopt", (cPointer, cInt, cFunction), cInt)
  val getinfo_long = buildCall3 (sym "curl_easy_getinfo", (cPointer, cInt, cStar cLong), cInt)
  val slist_append = buildCall2 (sym "curl_slist_append", (cPointer, cString), cPointer)
  val slist_free_all = buildCall1 (sym "curl_slist_free_all", cPointer, cVoid)
  val multi_init = buildCall0 (sym "curl_multi_init", (), cPointer)
  val multi_add = buildCall2 (sym "curl_multi_add_handle", (cPointer, cPointer), cInt)
  val multi_remove = buildCall2 (sym "curl_multi_remove_handle", (cPointer, cPointer), cInt)
  val multi_perform = buildCall2 (sym "curl_multi_perform", (cPointer, cStar cInt), cInt)
  val multi_poll = buildCall5 (sym "curl_multi_poll", (cPointer, cPointer, cUint, cInt, cStar cInt), cInt)
  val multi_info_read = buildCall2 (sym "curl_multi_info_read", (cPointer, cStar cInt), cPointer)
  val fopen = buildCall2 (csym "fopen", (cString, cString), cPointer)
  val fclose = buildCall1 (csym "fclose", cPointer, cInt)
  val fcntl3 = buildCall3 (csym "fcntl", (cInt, cInt, cInt), cInt)
  val sockopt_cloexec =
    buildCallback3 ((cPointer, cInt, cInt), cInt) (fn (_, fd, _) => (ignore (fcntl3 (fd, 2, 1)); 0))
  val null = Memory.null
  fun get32 (p, i) = Word32.toInt (Memory.get32 (p, i))
end

exception Error of string

fun check what rc = if rc = 0 then () else raise Error (what ^ ": " ^ easy_strerror rc)
fun mcheck what rc = if rc = 0 then () else raise Error (what ^ " failed: " ^ Int.toString rc)

(* The `user` option of the configured curl config file. *)
fun config_userpwd () =
  case HolbuildRemoteCacheConfig.curl_config () of
      NONE => NONE
    | SOME path =>
        let
          val input = TextIO.openIn path
          val lines = String.tokens (fn c => c = #"\n") (TextIO.inputAll input) before TextIO.closeIn input
          fun strip s = Substring.string (Substring.dropl Char.isSpace (Substring.dropr Char.isSpace (Substring.full s)))
          fun unquote s =
            if size s >= 2 andalso String.sub (s, 0) = #"\"" then String.substring (s, 1, size s - 2) else s
          fun value line =
            let
              val l = strip line
              fun after k = if String.isPrefix k l then SOME (strip (String.extract (l, size k, NONE))) else NONE
              val rest = case after "--user" of SOME r => SOME r | NONE => after "user"
            in
              case rest of
                  NONE => NONE
                | SOME r =>
                    SOME (unquote (if String.isPrefix "=" r orelse String.isPrefix ":" r
                                   then strip (String.extract (r, 1, NONE)) else r))
            end
        in
          case List.mapPartial value lines of v :: _ => SOME v | [] => NONE
        end

val lock = Mutex.mutex ()
val initialized = ref false
val idle : (Foreign.Memory.voidStar * Foreign.Memory.voidStar) list ref = ref []
val userpwd : string option ref = ref NONE

fun locked f =
  (Mutex.lock lock; f () before Mutex.unlock lock)
  handle e => (Mutex.unlock lock; raise e)

fun new_pair () =
  let
    val h = easy_init ()
    val _ = if h = null then raise Error "curl_easy_init failed" else ()
  in
    check "NOSIGNAL" (setopt_long (h, 99, 1));
    check "FOLLOWLOCATION" (setopt_long (h, 52, 1));
    check "ACCEPT_ENCODING" (setopt_str (h, 10102, ""));
    check "SOCKOPTFUNCTION" (setopt_fn (h, 20148, sockopt_cloexec));
    (case !userpwd of SOME u => check "USERPWD" (setopt_str (h, 10005, u)) | NONE => ());
    (multi_init (), h)
  end

fun take () =
  locked (fn () =>
    (if !initialized then ()
     else (check "curl_global_init" (global_init 3); userpwd := config_userpwd (); initialized := true);
     case !idle of
         p :: rest => (idle := rest; p)
       | [] => new_pair ()))

fun give p = locked (fn () => idle := p :: !idle)

(* Runs one transfer to completion; each libcurl call returns within 20 ms so
   the thread keeps reaching ML safe points for the GC. *)
fun drive (m, h) =
  let
    val running = ref 0
    val result = ref 0
    fun drain () =
      let val p = multi_info_read (m, ref 0)
      in if p = null then () else (result := get32 (p, 0w4); drain ()) end
    fun loop () =
      (mcheck "curl_multi_perform" (multi_perform (m, running));
       drain ();
       if !running = 0 then ()
       else (mcheck "curl_multi_poll" (multi_poll (m, null, 0, 20, ref 0)); loop ()))
  in
    mcheck "curl_multi_add_handle" (multi_add (m, h));
    loop ();
    mcheck "curl_multi_remove_handle" (multi_remove (m, h));
    !result
  end

fun response_code h =
  let val r = ref 0 in check "getinfo" (getinfo_long (h, 0x200002, r)); !r end

datatype result = Done of int | Failed of string

fun with_file path mode f =
  let val fp = fopen (path, mode)
  in
    if fp = null then Failed ("could not open " ^ path)
    else f fp before ignore (fclose fp) handle e => (ignore (fclose fp); raise e)
  end

fun perform_with pair f =
  (f pair before give pair) handle e => (give pair; raise e)

fun finish (m, h) =
  let val rc = drive (m, h)
  in if rc = 0 then Done (response_code h) else Failed (easy_strerror rc) end

fun get {url, dst, timeout} =
  perform_with (take ()) (fn (m, h) =>
    with_file dst "wb" (fn fp =>
      (check "HTTPGET" (setopt_long (h, 80, 1));
       check "TIMEOUT" (setopt_long (h, 13, timeout));
       check "URL" (setopt_str (h, 10002, url));
       check "WRITEDATA" (setopt_ptr (h, 10001, fp));
       finish (m, h))))

fun put {url, src, headers, timeout} =
  perform_with (take ()) (fn (m, h) =>
    with_file src "rb" (fn input =>
    with_file "/dev/null" "wb" (fn sink =>
      let
        val slist = List.foldl (fn (s, l) => slist_append (l, s)) null headers
        fun reset () =
          (ignore (setopt_ptr (h, 10023, null)); slist_free_all slist; ignore (setopt_long (h, 46, 0)))
        val size = Position.toInt (OS.FileSys.fileSize src)
      in
        (check "UPLOAD" (setopt_long (h, 46, 1));
         check "TIMEOUT" (setopt_long (h, 13, timeout));
         check "URL" (setopt_str (h, 10002, url));
         check "READDATA" (setopt_ptr (h, 10009, input));
         check "WRITEDATA" (setopt_ptr (h, 10001, sink));
         check "INFILESIZE_LARGE" (setopt_long (h, 30115, size));
         check "HTTPHEADER" (setopt_ptr (h, 10023, slist));
         finish (m, h) before reset ())
        handle e => (reset (); raise e)
      end)))

end
