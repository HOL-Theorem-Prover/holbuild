structure HolbuildHttp =
struct

(* HTTP GET and PUT for the remote cache, through libcurl bound with Foreign.
   Handles are pooled and keep their connection open between requests, so
   only a handle's first request pays for the TCP connect, TLS handshake and
   CA bundle load. *)

exception Error of string

datatype result = Response of int   (* HTTP status *)
                | Failed of string  (* transport error *)

fun is_darwin () =
  List.exists (fn field => field = ("sysname", "Darwin")) (Posix.ProcEnv.uname ())

(* Read when libcurl is first used, so the holbuild binary starts without it. *)
fun library_name () =
  case OS.Process.getEnv "HOLBUILD_TEST_LIBCURL" of
      SOME name => name
    | NONE => if is_darwin () then "/usr/lib/libcurl.4.dylib" else "libcurl.so.4"

local
  open Foreign
  val curl = getSymbol (loadLibraryIndirect library_name)
  val libc = getSymbol (loadExecutable ())

  (* curl_easy_setopt and curl_easy_getinfo take their third argument
     through `...`.  x86-64 and Linux arm64 pass it like a fixed third
     argument, in a register; Apple arm64 passes variadic arguments on the
     stack.  Repeating the value up to the ninth argument, the first stack
     slot, puts it where either convention reads it. *)
  fun variadic call (a, b, v) = call (a, b, v, v, v, v, v, v, v)
  fun variadic_conv c = (cPointer, cInt, c, c, c, c, c, c, c)
in
  val version_info = buildCall1 (curl "curl_version_info", cInt, cPointer)
  val global_init = buildCall1 (curl "curl_global_init", cLong, cInt)
  val easy_init = buildCall0 (curl "curl_easy_init", (), cPointer)
  val easy_cleanup = buildCall1 (curl "curl_easy_cleanup", cPointer, cVoid)
  val easy_strerror = buildCall1 (curl "curl_easy_strerror", cInt, cString)
  val setopt_long = variadic (buildCall9 (curl "curl_easy_setopt", variadic_conv cLong, cInt))
  val setopt_ptr = variadic (buildCall9 (curl "curl_easy_setopt", variadic_conv cPointer, cInt))
  val setopt_str = variadic (buildCall9 (curl "curl_easy_setopt", variadic_conv cString, cInt))
  val setopt_fn = variadic (buildCall9 (curl "curl_easy_setopt", variadic_conv cFunction, cInt))
  val getinfo_ptr = variadic (buildCall9 (curl "curl_easy_getinfo", variadic_conv cPointer, cInt))
  val slist_append = buildCall2 (curl "curl_slist_append", (cPointer, cString), cPointer)
  val slist_free_all = buildCall1 (curl "curl_slist_free_all", cPointer, cVoid)
  val multi_init = buildCall0 (curl "curl_multi_init", (), cPointer)
  val multi_cleanup = buildCall1 (curl "curl_multi_cleanup", cPointer, cInt)
  val multi_add_handle = buildCall2 (curl "curl_multi_add_handle", (cPointer, cPointer), cInt)
  val multi_remove_handle = buildCall2 (curl "curl_multi_remove_handle", (cPointer, cPointer), cInt)
  val multi_perform = buildCall2 (curl "curl_multi_perform", (cPointer, cStar cInt), cInt)
  val multi_poll =
    buildCall5 (curl "curl_multi_poll", (cPointer, cPointer, cUint, cInt, cStar cInt), cInt)
  val multi_info_read = buildCall2 (curl "curl_multi_info_read", (cPointer, cStar cInt), cPointer)
  val fopen = buildCall2 (libc "fopen", (cString, cString), cPointer)
  val fclose = buildCall1 (libc "fclose", cPointer, cInt)

  (* libcurl's connection sockets are not close-on-exec, so without this
     every child holbuild starts would inherit the open connections.  A
     child started between libcurl's socket() and this callback still
     inherits that one socket, and keeps it open until the child exits;
     closing that window would need SOCK_CLOEXEC, which macOS lacks.  (The
     wakeup pipe each multi handle creates is close-on-exec only from libcurl
     8.10; a child holding it keeps no connection open.) *)
  val sockopt_cloexec =
    buildCallback3 ((cPointer, cInt, cInt), cInt)
      (fn (_, fd, _) =>
        (Posix.IO.setfd (Posix.FileSys.wordToFD (SysWord.fromInt fd), Posix.IO.FD.cloexec); 0))
end

val CURLOPT_WRITEDATA = 10001
val CURLOPT_URL = 10002
val CURLOPT_USERPWD = 10005
val CURLOPT_READDATA = 10009
val CURLOPT_ERRORBUFFER = 10010
val CURLOPT_TIMEOUT = 13
val CURLOPT_CONNECTTIMEOUT = 78
val CURLOPT_HTTPHEADER = 10023
val CURLOPT_UPLOAD = 46
val CURLOPT_FOLLOWLOCATION = 52
val CURLOPT_HTTPGET = 80
val CURLOPT_NOSIGNAL = 99
val CURLOPT_ACCEPT_ENCODING = 10102
val CURLOPT_CAINFO = 10065
val CURLOPT_CAPATH = 10097
val CURLOPT_INFILESIZE_LARGE = 30115
val CURLOPT_SOCKOPTFUNCTION = 20148
val CURLINFO_RESPONSE_CODE = 0x200002
val CURL_GLOBAL_DEFAULT = 3
val CURL_VERSION_ASYNCHDNS = 0wx80 : Word32.word
val CURL_ERROR_SIZE = 0w256

(* Seconds to wait for a connection, in both remote cache clients. *)
val connect_timeout_seconds = 10

val userpwd : string option ref = ref NONE

fun version_text number =
  String.concatWith "." (map (fn unit => Int.toString (number div unit mod 256)) [65536, 256, 1])

(* Loads libcurl, checks that it can run transfers without blocking the GC,
   and initialises it.  Must run before the process starts any other
   thread: before libcurl 7.84, curl_global_init is not thread-safe even
   against threads that never use curl.  Raises Error, or Foreign.Foreign if
   libcurl can't be loaded. *)
fun setup {user} =
  let
    (* Fields of curl_version_info_data present since its first version.
       get32's offset counts 32-bit words: version_num is at byte 16 and
       features at byte 32 on 64-bit platforms. *)
    val info = version_info 0
    val number = Word32.toInt (Foreign.Memory.get32 (info, 0w4))
    val features = Foreign.Memory.get32 (info, 0w8)
    val features =
      if Option.isSome (OS.Process.getEnv "HOLBUILD_TEST_LIBCURL_NO_ASYNCHDNS")
      then Word32.andb (features, Word32.notb CURL_VERSION_ASYNCHDNS)
      else features
  in
    if number < 0x074200 then
      raise Error ("libcurl " ^ version_text number ^ " is older than 7.66")
    else if Word32.andb (features, CURL_VERSION_ASYNCHDNS) = 0w0 then
      raise Error ("libcurl " ^ version_text number ^ " has no asynchronous DNS resolver")
    else if global_init CURL_GLOBAL_DEFAULT <> 0 then raise Error "curl_global_init failed"
    else userpwd := user
  end

fun check what code =
  if code = 0 then () else raise Error (what ^ ": " ^ easy_strerror code)

fun mcheck what code =
  if code = 0 then () else raise Error (what ^ " failed with CURLMcode " ^ Int.toString code)

(* The CA options the curl command sets from the environment; libcurl
   doesn't read these variables itself. *)
fun ca_options () =
  case OS.Process.getEnv "CURL_CA_BUNDLE" of
      SOME bundle => [("CAINFO", CURLOPT_CAINFO, bundle)]
    | NONE =>
        List.mapPartial
          (fn (variable, name, option) =>
             Option.map (fn value => (name, option, value)) (OS.Process.getEnv variable))
          [("SSL_CERT_DIR", "CAPATH", CURLOPT_CAPATH), ("SSL_CERT_FILE", "CAINFO", CURLOPT_CAINFO)]

type connection = {easy : Foreign.Memory.voidStar, multi : Foreign.Memory.voidStar,
               errors : Foreign.Memory.voidStar}

fun close ({easy, multi, errors} : connection) =
  (if easy = Foreign.Memory.null then () else easy_cleanup easy;
   if multi = Foreign.Memory.null then () else ignore (multi_cleanup multi);
   Foreign.Memory.free errors)

fun new_connection () : connection =
  let
    val connection as {easy, multi, errors} =
      {easy = easy_init (), multi = multi_init (), errors = Foreign.Memory.malloc CURL_ERROR_SIZE}
  in
    (if easy = Foreign.Memory.null orelse multi = Foreign.Memory.null then
       raise Error "could not create a libcurl handle"
     else ();
     check "NOSIGNAL" (setopt_long (easy, CURLOPT_NOSIGNAL, 1));
     check "CONNECTTIMEOUT" (setopt_long (easy, CURLOPT_CONNECTTIMEOUT, connect_timeout_seconds));
     check "FOLLOWLOCATION" (setopt_long (easy, CURLOPT_FOLLOWLOCATION, 1));
     (* Accept every encoding this libcurl can decode, as curl --compressed. *)
     check "ACCEPT_ENCODING" (setopt_str (easy, CURLOPT_ACCEPT_ENCODING, ""));
     check "SOCKOPTFUNCTION" (setopt_fn (easy, CURLOPT_SOCKOPTFUNCTION, sockopt_cloexec));
     check "ERRORBUFFER" (setopt_ptr (easy, CURLOPT_ERRORBUFFER, errors));
     Option.app (fn user => check "USERPWD" (setopt_str (easy, CURLOPT_USERPWD, user))) (!userpwd);
     List.app (fn (name, option, value) => check name (setopt_str (easy, option, value))) (ca_options ());
     connection)
    handle e => (close connection; raise e)
  end

val pool_mutex = Mutex.mutex ()
val idle : connection list ref = ref []

fun with_pool_lock f =
  let
    val _ = Mutex.lock pool_mutex
  in
    f () before Mutex.unlock pool_mutex
  end
  handle e => (Mutex.unlock pool_mutex; raise e)

fun take () =
  case with_pool_lock (fn () =>
         case !idle of
             connection :: rest => (idle := rest; SOME connection)
           | [] => NONE) of
      SOME connection => connection
    | NONE => new_connection ()

fun give connection = with_pool_lock (fn () => idle := connection :: !idle)

(* A connection whose request raised may be left mid-transfer, so it is
   closed rather than pooled. *)
fun with_handle f =
  let
    val connection = take ()
    val result = f connection handle e => (close connection; raise e)
  in
    give connection; result
  end

fun c_string_at p =
  let
    fun len i = if Foreign.Memory.get8 (p, Word.fromInt i) = 0w0 then i else len (i + 1)
  in
    CharVector.tabulate (len 0, fn i => Byte.byteToChar (Foreign.Memory.get8 (p, Word.fromInt i)))
  end

(* A foreign call keeps the ML heap, so a GC waits for every thread inside
   one.  The transfer is driven through the handle's multi handle, whose
   poll returns at least every 20 ms, rather than by a blocking
   curl_easy_perform.  DNS can't block here: setup requires an asynchronous
   resolver. *)
fun transfer ({easy, multi, errors} : connection) =
  let
    val running = ref 0
    val code = ref 0
    fun read_done () =
      let val message = multi_info_read (multi, ref 0)
      in
        if message = Foreign.Memory.null then ()
        (* CURLMsg's data.result, at byte 16 on 64-bit platforms. *)
        else (code := Word32.toInt (Foreign.Memory.get32 (message, 0w4)); read_done ())
      end
    fun loop () =
      (mcheck "curl_multi_perform" (multi_perform (multi, running));
       read_done ();
       if !running = 0 then ()
       else (mcheck "curl_multi_poll" (multi_poll (multi, Foreign.Memory.null, 0, 20, ref 0));
             loop ()))
    val _ = mcheck "curl_multi_add_handle" (multi_add_handle (multi, easy))
    val _ = loop () handle e => (ignore (multi_remove_handle (multi, easy)); raise e)
    val _ = mcheck "curl_multi_remove_handle" (multi_remove_handle (multi, easy))
  in
    if !code <> 0 then
      Failed (easy_strerror (!code) ^
              (case c_string_at errors of "" => "" | detail => ": " ^ detail))
    else
      Foreign.Memory.alloca (0w8, fn status =>
        (check "RESPONSE_CODE" (getinfo_ptr (easy, CURLINFO_RESPONSE_CODE, status));
         Response (SysWord.toInt (Foreign.Memory.get64 (status, 0w0)))))
  end

fun with_file path mode f =
  let val file = fopen (path, mode)
  in
    if file = Foreign.Memory.null then raise Error ("could not open " ^ path)
    else f file before ignore (fclose file) handle e => (ignore (fclose file); raise e)
  end

(* Runs one request on a pooled connection, writing the response body to
   output.  set_options sets the request's own options; the data pointers
   are cleared afterwards, so the pooled handle keeps none of them. *)
fun request {url, timeout, output, set_options} =
  with_handle (fn connection as {easy, ...} =>
    (check "TIMEOUT" (setopt_long (easy, CURLOPT_TIMEOUT, timeout));
     check "URL" (setopt_str (easy, CURLOPT_URL, url));
     check "WRITEDATA" (setopt_ptr (easy, CURLOPT_WRITEDATA, output));
     set_options easy;
     transfer connection
     before List.app (fn option => ignore (setopt_ptr (easy, option, Foreign.Memory.null)))
              [CURLOPT_WRITEDATA, CURLOPT_READDATA, CURLOPT_HTTPHEADER]))

(* Downloads url into dst, decoding any content encoding. *)
fun get {url, dst, timeout} =
  with_file dst "wb" (fn output =>
    request {url = url, timeout = timeout, output = output,
             set_options = fn easy => check "HTTPGET" (setopt_long (easy, CURLOPT_HTTPGET, 1))})

(* Uploads src to url with PUT and the given extra request headers; the
   response body is discarded. *)
fun put {url, src, headers, timeout} =
  with_file src "rb" (fn input =>
  with_file "/dev/null" "wb" (fn sink =>
    let
      val header_list = List.foldl (fn (h, l) => slist_append (l, h)) Foreign.Memory.null headers
      fun set_options easy =
        (check "UPLOAD" (setopt_long (easy, CURLOPT_UPLOAD, 1));
         check "READDATA" (setopt_ptr (easy, CURLOPT_READDATA, input));
         check "INFILESIZE_LARGE"
           (setopt_long (easy, CURLOPT_INFILESIZE_LARGE, Position.toInt (OS.FileSys.fileSize src)));
         check "HTTPHEADER" (setopt_ptr (easy, CURLOPT_HTTPHEADER, header_list)))
    in
      (* request clears HTTPHEADER, or closes the handle, before this frees the list. *)
      request {url = url, timeout = timeout, output = sink, set_options = set_options}
      before slist_free_all header_list
      handle e => (slist_free_all header_list; raise e)
    end))

end
