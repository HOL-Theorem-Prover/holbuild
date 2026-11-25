structure HolbuildHttp =
struct

(* HTTP GET and PUT for the remote cache, through libcurl bound with Foreign.
   Requests share one multi handle, which keeps connections open between
   requests and the CA bundle it parsed, so only a connection's first request
   pays for the TCP connect and TLS handshake, and only the first connection
   for the CA bundle load. *)

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

  (* curl_easy_setopt, curl_easy_getinfo and curl_multi_setopt take their
     third argument through `...`.  x86-64 and Linux arm64 pass it like a fixed third
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
  val setopt_header_fn = variadic (buildCall9 (curl "curl_easy_setopt", variadic_conv cFunction, cInt))
  val getinfo_ptr = variadic (buildCall9 (curl "curl_easy_getinfo", variadic_conv cPointer, cInt))
  val slist_append = buildCall2 (curl "curl_slist_append", (cPointer, cString), cPointer)
  val slist_free_all = buildCall1 (curl "curl_slist_free_all", cPointer, cVoid)
  val multi_init = buildCall0 (curl "curl_multi_init", (), cPointer)
  val multi_setopt_long = variadic (buildCall9 (curl "curl_multi_setopt", variadic_conv cLong, cInt))
  val multi_cleanup = buildCall1 (curl "curl_multi_cleanup", cPointer, cInt)
  val multi_add_handle = buildCall2 (curl "curl_multi_add_handle", (cPointer, cPointer), cInt)
  val multi_remove_handle = buildCall2 (curl "curl_multi_remove_handle", (cPointer, cPointer), cInt)
  val multi_perform = buildCall2 (curl "curl_multi_perform", (cPointer, cStar cInt), cInt)
  val multi_poll =
    buildCall5 (curl "curl_multi_poll", (cPointer, cPointer, cUint, cInt, cStar cInt), cInt)
  val multi_info_read = buildCall2 (curl "curl_multi_info_read", (cPointer, cStar cInt), cPointer)
  val multi_wakeup = buildCall1 (curl "curl_multi_wakeup", cPointer, cInt)
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

  (* Keeps in the byte at data the Content-Encoding of the latest response:
     0 for none (or identity), 1 for zstd, 2 for any other.  Each response,
     a redirect's included, starts with its status line. *)
  val header_encoding =
    buildCallback4 ((cPointer, cSize, cSize, cPointer), cSize)
      (fn (line, item_size, items, data) =>
        let
          val n = item_size * items
          val text = String.map Char.toLower
            (CharVector.tabulate (n, fn i => Byte.byteToChar (Memory.get8 (line, Word.fromInt i))))
          val name = "content-encoding:"
          fun set code = Memory.set8 (data, 0w0, code)
        in
          (if String.isPrefix "http/" text then set 0w0
           else if String.isPrefix name text then
             (case String.tokens (fn c => Char.isSpace c orelse c = #",")
                                 (String.extract (text, size name, NONE)) of
                  [] => set 0w0
                | ["identity"] => set 0w0
                | ["zstd"] => set 0w1
                | _ => set 0w2)
           else ();
           n)
        end
        handle _ => 0)
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
val CURLOPT_HEADERFUNCTION = 20079
val CURLOPT_HEADERDATA = 10029
val CURLINFO_RESPONSE_CODE = 0x200002
val CURLMOPT_MAXCONNECTS = 6
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
    if number < 0x074400 then
      raise Error ("libcurl " ^ version_text number ^ " is older than 7.68")
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

type request_handle = {easy : Foreign.Memory.voidStar, errors : Foreign.Memory.voidStar,
                       no_ca_directory : bool}

fun close ({easy, errors, ...} : request_handle) =
  (if easy = Foreign.Memory.null then () else easy_cleanup easy;
   Foreign.Memory.free errors)

fun new_handle () : request_handle =
  let
    val handle_ as {easy, errors, no_ca_directory} =
      {easy = easy_init (), errors = Foreign.Memory.malloc CURL_ERROR_SIZE,
       no_ca_directory = !clear_ca_directory}
  in
    (if easy = Foreign.Memory.null then raise Error "could not create a libcurl handle" else ();
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
     handle_)
    handle e => (close handle_; raise e)
  end

val pool_mutex = Mutex.mutex ()

(* The most requests in flight at once, and the most idle connections the
   multi handle keeps.  A request holds a socket (two while it reconnects)
   and its files, an idle connection a socket.  Poly/ML waits on streams
   with select(), which aborts the process at a descriptor of 1024 or more,
   so these stay well below that however many threads make requests at
   once. *)
val max_requests = 64

(* The process's one multi handle, while the pump runs.  libcurl keeps the
   parsed CA bundle, DNS answers and idle connections per multi handle, so
   every request shares them: a burst of requests parses the bundle once,
   not once per connection. *)
val multi = ref Foreign.Memory.null

(* The pump thread, while one runs; it is the only thread that calls
   curl_multi_* other than curl_multi_wakeup, since a multi handle isn't
   thread-safe. *)
val pump_thread : Thread.thread option ref = ref NONE

(* Easy handles waiting for the pump to add them. *)
val queued : Foreign.Memory.voidStar list ref = ref []

datatype outcome = Code of int  (* CURLcode *)
                 | Raised of exn

(* Transfers the pump has finished and removed, not yet collected by their
   requests. *)
val finished : (Foreign.Memory.voidStar * outcome) list ref = ref []

(* The requests in flight: queued, running or finished. *)
val in_flight = ref 0

(* Broadcast when a transfer finishes or a request leaves. *)
val pool_changed = ConditionVar.conditionVar ()

(* Signalled when a handle is queued.  An idle pump waits on it rather than
   sleeping: the process exits only once every thread has stopped, and a
   sleeping thread stops only when its sleep ends. *)
val pump_wake = ConditionVar.conditionVar ()

(* How long the pump keeps the multi handle with no request: well below the
   cache server's own idle timeout, so it never holds a connection the
   server has closed (left in CLOSE-WAIT until the process exits), and the
   connections close in quiet stretches, such as a long local build, while
   a burst of requests reuses them. *)
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

(* Drives the transfers on m: adds queued handles, runs them, and hands
   each finished one back to its request.  A foreign call keeps the ML
   heap, so a GC waits for every thread inside one; the poll returns at
   least every 20 ms, and at once when a request queues a handle.  DNS
   can't block here: setup requires an asynchronous resolver.  With no
   transfer for the idle timeout it closes m, and with it the connections,
   and ends. *)
fun pump m =
  let
    val running = ref [] : Foreign.Memory.voidStar list ref
    fun hand_back outcomes =
      with_pool_lock (fn () =>
        (finished := outcomes @ !finished; ConditionVar.broadcast pool_changed))
    fun read_done () =
      let val message = multi_info_read (m, ref 0)
      in
        if message = Foreign.Memory.null then ()
        else
          let
            (* CURLMsg's easy_handle, at byte 8, and data.result, at byte
               16, on 64-bit platforms. *)
            val easy = Foreign.Memory.getAddress (message, 0w1)
            val code = Word32.toInt (Foreign.Memory.get32 (message, 0w4))
          in
            mcheck "curl_multi_remove_handle" (multi_remove_handle (m, easy));
            running := List.filter (fn e => e <> easy) (!running);
            hand_back [(easy, Code code)];
            read_done ()
          end
      end
    fun wait_for_work deadline =
      if not (null (!queued)) then true
      else if Time.>= (Time.now (), deadline) then (multi := Foreign.Memory.null; pump_thread := NONE; false)
      else (ignore (ConditionVar.waitUntil (pump_wake, pool_mutex, deadline)); wait_for_work deadline)
    fun take_queued () =
      with_pool_lock (fn () =>
        if not (null (!running)) orelse wait_for_work (Time.+ (Time.now (), idle_timeout ()))
        then SOME (!queued before queued := [])
        else NONE)
    fun loop () =
      case take_queued () of
          NONE => ignore (multi_cleanup m)
        | SOME added =>
            (* Running before they're added, so a failed add fails the whole
               batch below; removing a handle never added is harmless. *)
            (running := added @ !running;
             List.app (fn easy => mcheck "curl_multi_add_handle" (multi_add_handle (m, easy))) added;
             mcheck "curl_multi_perform" (multi_perform (m, ref 0));
             read_done ();
             if null (!running) then ()
             else mcheck "curl_multi_poll" (multi_poll (m, Foreign.Memory.null, 0, 20, ref 0));
             loop ())
  in
    loop ()
    handle e as Error _ =>
      (* The requests in flight fail with the error, and the next one starts
         a new multi handle. *)
      let
        val failed = with_pool_lock (fn () =>
          (multi := Foreign.Memory.null; pump_thread := NONE; !queued before queued := []))
      in
        List.app (fn easy => ignore (multi_remove_handle (m, easy))) (!running);
        ignore (multi_cleanup m);
        hand_back (map (fn easy => (easy, Raised e)) (!running @ failed))
      end
  end

(* Waits for a place among the requests in flight. *)
fun enter () =
  with_pool_lock (fn () =>
    let
      fun wait () =
        if !in_flight < max_requests then in_flight := !in_flight + 1
        else (ConditionVar.wait (pool_changed, pool_mutex); wait ())
    in
      wait ()
    end)

fun leave () =
  with_pool_lock (fn () => (in_flight := !in_flight - 1; ConditionVar.broadcast pool_changed))

(* The multi handle, starting it and its pump if none runs. *)
fun current_multi () =
  if !multi <> Foreign.Memory.null then !multi
  else
    let
      val m = multi_init ()
    in
      if m = Foreign.Memory.null then raise Error "could not create a libcurl multi handle" else ();
      (mcheck "curl_multi_setopt MAXCONNECTS" (multi_setopt_long (m, CURLMOPT_MAXCONNECTS, max_requests))
       handle e => (ignore (multi_cleanup m); raise e));
      multi := m;
      pump_thread := SOME (Thread.fork (fn () => pump m, []));
      m
    end

(* Runs f with interrupts deferred, so a request can't unwind and free its
   files while the pump still uses them. *)
fun uninterruptible f =
  let
    val saved = Thread.getAttributes ()
    val () = Thread.setAttributes [Thread.InterruptState Thread.InterruptDefer]
  in
    (f () before Thread.setAttributes saved)
    handle e => (Thread.setAttributes saved; raise e)
  end

(* Runs easy's transfer on the shared multi handle and waits for it to
   finish. *)
fun run_transfer easy =
  uninterruptible (fn () => with_pool_lock (fn () =>
    let
      val m = current_multi ()
      fun collect () =
        case List.partition (fn (e, _) => e = easy) (!finished) of
            ([(_, outcome)], others) => (finished := others; outcome)
          | _ => (ConditionVar.wait (pool_changed, pool_mutex); collect ())
    in
      (* Woken first, so a failed wakeup leaves nothing queued; the pump
         takes the queue under this lock, so it can't miss the handle. *)
      mcheck "curl_multi_wakeup" (multi_wakeup m);
      queued := easy :: !queued;
      ConditionVar.signal pump_wake;
      collect ()
    end))

fun c_string_at p =
  let
    fun len i = if Foreign.Memory.get8 (p, Word.fromInt i) = 0w0 then i else len (i + 1)
  in
    CharVector.tabulate (len 0, fn i => Byte.byteToChar (Foreign.Memory.get8 (p, Word.fromInt i)))
  end

(* The result of a finished transfer. *)
fun transfer_result ({easy, errors, no_ca_directory} : request_handle) outcome =
  case outcome of
      Raised e => raise e
    | Code code =>
        if code = CURLE_PEER_FAILED_VERIFICATION andalso no_ca_directory then raise CaDirectoryNeeded
        else if code <> 0 then
          Failed (easy_strerror code ^
                  (case c_string_at errors of "" => "" | detail => ": " ^ detail))
        else
          Foreign.Memory.alloca (0w8, fn status =>
            (check "RESPONSE_CODE" (getinfo_ptr (easy, CURLINFO_RESPONSE_CODE, status));
             Response (SysWord.toInt (Foreign.Memory.get64 (status, 0w0)))))

fun with_file path mode f =
  let val file = fopen (path, mode)
  in
    if file = Foreign.Memory.null then raise Error ("could not open " ^ path)
    else f file before ignore (fclose file) handle e => (ignore (fclose file); raise e)
  end

(* Runs one request on a new easy handle, writing the response body to
   output.  It fails once it has moved no data for timeout seconds, or after
   max_transfer_seconds: a slow transfer that keeps moving, as a large upload
   to a busy server, isn't cut off.  files opens the request's files, then
   runs the transfer with the output and set_options, which sets the
   request's own options.  It opens them only once the request has a place
   in flight, so requests waiting for one hold no descriptors. *)
fun request_once {url, timeout, files} =
  (HolbuildOffline.require_online "send an HTTP request";
   enter ();
   (files (fn {output, set_options} =>
      let
        val handle_ as {easy, ...} = new_handle ()
        val _ =
          (check "TIMEOUT" (setopt_long (easy, CURLOPT_TIMEOUT, max_transfer_seconds));
           check "LOW_SPEED_LIMIT" (setopt_long (easy, CURLOPT_LOW_SPEED_LIMIT, 1));
           check "LOW_SPEED_TIME" (setopt_long (easy, CURLOPT_LOW_SPEED_TIME, timeout));
           check "URL" (setopt_str (easy, CURLOPT_URL, url));
           check "WRITEDATA" (setopt_ptr (easy, CURLOPT_WRITEDATA, output));
           check "IGNORE_CONTENT_LENGTH" (setopt_long (easy, CURLOPT_IGNORE_CONTENT_LENGTH, 0));
           set_options easy)
          handle e => (close handle_; raise e)
      in
        (* run_transfer raises only before the handle is queued or after the
           pump is done with it, so closing it then is safe. *)
        (transfer_result handle_ (run_transfer easy) before close handle_)
        handle e => (close handle_; raise e)
      end)
    before leave ())
   handle e => (leave (); raise e))

fun request args =
  request_once args
  handle CaDirectoryNeeded => (clear_ca_directory := false; request_once args)

(* Downloads url into dst with the given extra request headers, decoding
   any content encoding. *)
fun get_with_headers {url, dst, headers, timeout} =
  request {url = url, timeout = timeout, files = fn run =>
    with_file dst "wb" (fn output =>
      let
        val header_list = List.foldl (fn (h, l) => slist_append (l, h)) Foreign.Memory.null headers
        fun set_options easy =
          (check "HTTPGET" (setopt_long (easy, CURLOPT_HTTPGET, 1));
           check "HTTPHEADER" (setopt_ptr (easy, CURLOPT_HTTPHEADER, header_list)))
      in
        (* The handle is closed before this frees the list. *)
        run {output = output, set_options = set_options}
        before slist_free_all header_list
        handle e => (slist_free_all header_list; raise e)
      end)}

fun get {url, dst, timeout} = get_with_headers {url = url, dst = dst, headers = [], timeout = timeout}

datatype encoding = Identity | Zstd | OtherEncoding

(* Downloads url into dst as the server sends it, asking for zstd, and says
   how the body is encoded: libcurl decodes nothing. *)
fun get_zstd {url, dst, timeout} =
  Foreign.Memory.alloca (0w1, fn encoding =>
    let
      val header_list = slist_append (Foreign.Memory.null, "Accept-Encoding: zstd")
      fun set_options easy =
        (check "HTTPGET" (setopt_long (easy, CURLOPT_HTTPGET, 1));
         check "ACCEPT_ENCODING" (setopt_ptr (easy, CURLOPT_ACCEPT_ENCODING, Foreign.Memory.null));
         check "HTTPHEADER" (setopt_ptr (easy, CURLOPT_HTTPHEADER, header_list));
         check "HEADERFUNCTION" (setopt_header_fn (easy, CURLOPT_HEADERFUNCTION, header_encoding));
         check "HEADERDATA" (setopt_ptr (easy, CURLOPT_HEADERDATA, encoding)))
      val _ = Foreign.Memory.set8 (encoding, 0w0, 0w0)
      (* The handle is closed before this frees the list. *)
      val result =
        request {url = url, timeout = timeout, files = fn run =>
          with_file dst "wb" (fn output => run {output = output, set_options = set_options})}
        handle e => (slist_free_all header_list; raise e)
    in
      slist_free_all header_list;
      (result,
       case Foreign.Memory.get8 (encoding, 0w0) of
           0w0 => Identity
         | 0w1 => Zstd
         | _ => OtherEncoding)
    end)

(* Asks for url with HEAD.  HTTPGET first clears a pooled handle's upload
   from an earlier put, which NOBODY alone leaves in place before libcurl
   7.72; the next get or put, setting HTTPGET or UPLOAD, turns NOBODY off.
   A HEAD's Content-Length is ignored: only the status matters, and
   bazel-remote answers -1 for a blob it has only in its S3 backend, which
   libcurl otherwise rejects. *)
fun head {url, headers, timeout} =
  request {url = url, timeout = timeout, files = fn run =>
    with_file "/dev/null" "wb" (fn sink =>
      let
        val header_list = List.foldl (fn (h, l) => slist_append (l, h)) Foreign.Memory.null headers
        fun set_options easy =
          (check "HTTPGET" (setopt_long (easy, CURLOPT_HTTPGET, 1));
           check "NOBODY" (setopt_long (easy, CURLOPT_NOBODY, 1));
           check "IGNORE_CONTENT_LENGTH" (setopt_long (easy, CURLOPT_IGNORE_CONTENT_LENGTH, 1));
           check "HTTPHEADER" (setopt_ptr (easy, CURLOPT_HTTPHEADER, header_list)))
      in
        (* The handle is closed before this frees the list. *)
        run {output = sink, set_options = set_options}
        before slist_free_all header_list
        handle e => (slist_free_all header_list; raise e)
      end)}

(* Uploads src to url with PUT and the given extra request headers; the
   response body is discarded. *)
fun put {url, src, headers, timeout} =
  request {url = url, timeout = timeout, files = fn run =>
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
        (* run clears HTTPHEADER, or the handle is closed, before this frees the list. *)
        run {output = sink, set_options = set_options}
        before slist_free_all header_list
        handle e => (slist_free_all header_list; raise e)
      end))}

end
