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
  (* Foreign looks a symbol up on its first call and caches the address with
     an unsynchronised byte-by-byte copy, so threads making their first call
     through the same symbol at once can read a half-written address and jump
     to it.  setup resolves every symbol here before any thread starts. *)
  val symbols : symbol list ref = ref []
  fun recorded lookup name =
    let val symbol = lookup name in symbols := symbol :: !symbols; symbol end
  val curl = recorded (getSymbol (loadLibraryIndirect library_name))
  val libc = recorded (getSymbol (loadExecutable ()))

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

  (* The OpenSSL 3 libcurl uses, if it does: not among `symbols`, since
     setup goes on without it. *)
  val crypto = getSymbol (loadLibraryIndirect (fn () => "libcrypto.so.3"))
  val openssl_fetches =
    map (fn name => buildCall3 (crypto name, (cPointer, cPointer, cPointer), cPointer))
      ["EVP_MD_fetch", "EVP_CIPHER_fetch", "EVP_MAC_fetch", "EVP_KDF_fetch", "EVP_RAND_fetch",
       "EVP_KEYMGMT_fetch", "EVP_KEYEXCH_fetch", "EVP_SIGNATURE_fetch", "EVP_ASYM_CIPHER_fetch",
       "EVP_KEM_fetch", "OSSL_DECODER_fetch", "OSSL_ENCODER_fetch", "OSSL_STORE_LOADER_fetch"]
  val openssl_clear_errors = buildCall0 (crypto "ERR_clear_error", (), cVoid)

  fun resolve_symbols () = List.app (ignore o symbolAsAddress) (!symbols)

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
val CURLOPT_LOW_SPEED_LIMIT = 19
val CURLOPT_LOW_SPEED_TIME = 20
val CURLOPT_CONNECTTIMEOUT = 78
val CURLOPT_HTTPHEADER = 10023
val CURLOPT_NOBODY = 44
val CURLOPT_IGNORE_CONTENT_LENGTH = 136
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
val CURLE_PEER_FAILED_VERIFICATION = 60
val CURL_GLOBAL_DEFAULT = 3
val CURL_VERSION_ASYNCHDNS = 0wx80 : Word32.word
val CURL_ERROR_SIZE = 0w256

(* Seconds to wait for a connection, in both remote cache clients. *)
val connect_timeout_seconds = 5

(* The longest any transfer may take, in both remote cache clients, however
   steadily it moves data. *)
val max_transfer_seconds = 1800

val userpwd : string option ref = ref NONE

(* libcurl keeps the CA store it parsed per multi handle (7.87 on), but only
   for connections with no CA directory, and builds such as Debian's set one
   by default.  Without that cache, each new connection parses the whole CA
   bundle again: about 18 ms of CPU, and many times that with dozens of
   threads connecting at once.  So while this holds, new handles clear the
   default CA directory, leaving the CA bundle to name the trusted roots, and
   load it once.  A certificate the bundle alone doesn't verify turns it off
   for the process (request). *)
val clear_ca_directory = ref false

(* A transfer on a handle made with no CA directory failed to verify the
   server's certificate. *)
exception CaDirectoryNeeded

(* OpenSSL 3 before 3.0.15 walks its method stores without a lock while
   another thread may be adding to them (openssl#24672), and parsing any
   certificate walks one, so threads making their first TLS connections at
   once can crash.  A store gains methods only on an operation's first
   fetch, so this fetches each operation once, before any other thread
   starts.  A NULL name finds nothing but constructs all of the operation's
   methods, as OpenSSL's own *_do_all_provided do; the errors those fetches
   leave are cleared.  Without libcrypto.so.3 there is nothing to fill. *)
fun fill_openssl_method_stores () =
  (List.app (fn fetch => ignore (fetch (Foreign.Memory.null, Foreign.Memory.null, Foreign.Memory.null)))
     openssl_fetches;
   openssl_clear_errors ())
  handle Foreign.Foreign _ => ()

fun version_text number =
  String.concatWith "." (map (fn unit => Int.toString (number div unit mod 256)) [65536, 256, 1])

(* Loads libcurl, checks that it can run transfers without blocking the GC,
   and initialises it.  Must run before the process starts any other
   thread: it resolves every foreign symbol this structure calls, fills
   OpenSSL's method stores, and before libcurl 7.84 curl_global_init is not
   thread-safe even against threads that never use curl.  Raises Error, or
   Foreign.Foreign if libcurl can't be loaded. *)
fun setup {user} =
  let
    val _ = HolbuildOffline.require_online "initialize the HTTP client"
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
    else
      (resolve_symbols ();
       if global_init CURL_GLOBAL_DEFAULT <> 0 then raise Error "curl_global_init failed"
       else (fill_openssl_method_stores ();
             userpwd := user; clear_ca_directory := number >= 0x075700))
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

(* The CA options a new handle gets: NONE clears an option.  The default CA
   directory is cleared first, so a directory the environment names stays. *)
fun connection_ca_options no_ca_directory =
  (if no_ca_directory then [("CAPATH", CURLOPT_CAPATH, NONE)] else []) @
  map (fn (name, option, value) => (name, option, SOME value)) (ca_options ())

type connection = {easy : Foreign.Memory.voidStar, multi : Foreign.Memory.voidStar,
               errors : Foreign.Memory.voidStar, no_ca_directory : bool}

fun close ({easy, multi, errors, ...} : connection) =
  (if easy = Foreign.Memory.null then () else easy_cleanup easy;
   if multi = Foreign.Memory.null then () else ignore (multi_cleanup multi);
   Foreign.Memory.free errors)

fun new_connection () : connection =
  let
    val connection as {easy, multi, errors, no_ca_directory} =
      {easy = easy_init (), multi = multi_init (), errors = Foreign.Memory.malloc CURL_ERROR_SIZE,
       no_ca_directory = !clear_ca_directory}
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
     (* A TLS backend without CA directories refuses to clear CAPATH, which
        only leaves the handle without the cached CA store. *)
     List.app (fn (_, option, NONE) => ignore (setopt_ptr (easy, option, Foreign.Memory.null))
                | (name, option, SOME value) => check name (setopt_str (easy, option, value)))
              (connection_ca_options no_ca_directory);
     connection)
    handle e => (close connection; raise e)
  end

val pool_mutex = Mutex.mutex ()

(* The pooled connections no request is using, the most recently returned
   first, each with the time it was returned. *)
val idle : (connection * Time.time) list ref = ref []

(* Whether a reaper thread is running; one runs while idle is non-empty. *)
val reaping = ref false

(* How long a connection stays pooled unused before it is closed: well
   below the cache server's own idle timeout, so the pool never holds a
   connection the server has closed (left in CLOSE-WAIT until the process
   exits), and the pool empties in quiet stretches, such as a long local
   build, while a burst of requests reuses its connections. *)
fun idle_timeout () =
  Time.fromMilliseconds
    (case Option.mapPartial LargeInt.fromString (OS.Process.getEnv "HOLBUILD_TEST_HTTP_IDLE_MS") of
         SOME ms => ms
       | NONE => 30000)

fun with_pool_lock f =
  let
    val _ = Mutex.lock pool_mutex
  in
    f () before Mutex.unlock pool_mutex
  end
  handle e => (Mutex.unlock pool_mutex; raise e)

(* Closes the connections idle for the timeout, then sleeps until the
   oldest left reaches it; ends once the pool is empty. *)
fun reaper () =
  let
    val (expired, wake) = with_pool_lock (fn () =>
      let
        val now = Time.now ()
        val timeout = idle_timeout ()
        val (kept, expired) =
          List.partition (fn (_, since) => Time.< (Time.- (now, since), timeout)) (!idle)
      in
        idle := kept;
        case rev kept of
            [] => (reaping := false; (expired, NONE))
          | (_, oldest) :: _ => (expired, SOME (Time.- (Time.+ (oldest, timeout), now)))
      end)
  in
    List.app (close o #1) expired;
    case wake of
        NONE => ()
      | SOME wait => (OS.Process.sleep wait; reaper ())
  end

fun take () =
  case with_pool_lock (fn () =>
         case !idle of
             (connection, _) :: rest => (idle := rest; SOME connection)
           | [] => NONE) of
      SOME connection =>
        if #no_ca_directory connection andalso not (!clear_ca_directory)
        then (close connection; take ())
        else connection
    | NONE => new_connection ()

fun give connection =
  if with_pool_lock (fn () =>
       (idle := (connection, Time.now ()) :: !idle; not (!reaping) before reaping := true))
  then ignore (Thread.fork (reaper, []))
       handle e =>
         (List.app (close o #1) (with_pool_lock (fn () => (reaping := false; !idle before idle := [])));
          raise e)
  else ()

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
fun transfer ({easy, multi, errors, no_ca_directory} : connection) =
  let
    val _ = HolbuildOffline.require_online "send an HTTP request"
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
    if !code = CURLE_PEER_FAILED_VERIFICATION andalso no_ca_directory then raise CaDirectoryNeeded
    else if !code <> 0 then
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
   output.  It fails once it has moved no data for timeout seconds, or after
   max_transfer_seconds: a slow transfer that keeps moving, as a large upload
   to a busy server, isn't cut off.  set_options sets the request's own
   options; the data pointers are cleared afterwards, so the pooled handle
   keeps none of them. *)
fun request_once {url, timeout, output, set_options} =
  (HolbuildOffline.require_online "send an HTTP request";
  with_handle (fn connection as {easy, ...} =>
    (check "TIMEOUT" (setopt_long (easy, CURLOPT_TIMEOUT, max_transfer_seconds));
     check "LOW_SPEED_LIMIT" (setopt_long (easy, CURLOPT_LOW_SPEED_LIMIT, 1));
     check "LOW_SPEED_TIME" (setopt_long (easy, CURLOPT_LOW_SPEED_TIME, timeout));
     check "URL" (setopt_str (easy, CURLOPT_URL, url));
     check "WRITEDATA" (setopt_ptr (easy, CURLOPT_WRITEDATA, output));
     check "IGNORE_CONTENT_LENGTH" (setopt_long (easy, CURLOPT_IGNORE_CONTENT_LENGTH, 0));
     set_options easy;
     transfer connection
     before List.app (fn option => ignore (setopt_ptr (easy, option, Foreign.Memory.null)))
              [CURLOPT_WRITEDATA, CURLOPT_READDATA, CURLOPT_HTTPHEADER])))

(* Verification fails in the TLS handshake, before any data moves, so the
   request can start again on a handle with libcurl's default CA directory. *)
fun request args =
  request_once args
  handle CaDirectoryNeeded => (clear_ca_directory := false; request_once args)

(* Downloads url into dst, decoding any content encoding. *)
fun get {url, dst, timeout} =
  with_file dst "wb" (fn output =>
    request {url = url, timeout = timeout, output = output,
             set_options = fn easy => check "HTTPGET" (setopt_long (easy, CURLOPT_HTTPGET, 1))})

(* Asks for url with HEAD.  HTTPGET first clears a pooled handle's upload
   from an earlier put, which NOBODY alone leaves in place before libcurl
   7.72; the next get or put, setting HTTPGET or UPLOAD, turns NOBODY off.
   A HEAD's Content-Length is ignored: only the status matters, and
   bazel-remote answers -1 for a blob it has only in its S3 backend, which
   libcurl otherwise rejects. *)
fun head {url, timeout} =
  with_file "/dev/null" "wb" (fn sink =>
    request {url = url, timeout = timeout, output = sink,
             set_options = fn easy => (check "HTTPGET" (setopt_long (easy, CURLOPT_HTTPGET, 1));
                                       check "NOBODY" (setopt_long (easy, CURLOPT_NOBODY, 1));
                                       check "IGNORE_CONTENT_LENGTH"
                                         (setopt_long (easy, CURLOPT_IGNORE_CONTENT_LENGTH, 1)))})

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
