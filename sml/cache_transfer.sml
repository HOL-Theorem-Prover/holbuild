structure HolbuildCacheTransfer =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

type source =
  { get_action : HolbuildCacheBackend.action_key -> HolbuildCacheBackend.manifest_text option,
    fetch_blob : {hash : HolbuildCacheBackend.blob_hash,
                  dst : HolbuildCacheBackend.local_path} -> HolbuildCacheBackend.fetch_result }

type destination =
  { put_action : HolbuildCacheBackend.action_publish_policy ->
                 {key : HolbuildCacheBackend.action_key,
                  text : HolbuildCacheBackend.manifest_text} -> HolbuildCacheBackend.publish_result,
    publish_blob : {hash : HolbuildCacheBackend.blob_hash,
                    src : HolbuildCacheBackend.local_path} -> HolbuildCacheBackend.publish_result }

type entry_result =
  { key : HolbuildCacheBackend.action_key,
    blobs : int,
    uploaded_blobs : int,
    reused_blobs : int,
    action : HolbuildCacheBackend.publish_result }

fun has_prefix prefix s =
  size s >= size prefix andalso String.substring(s, 0, size prefix) = prefix

fun trim_newline s =
  if size s > 0 andalso String.sub(s, size s - 1) = #"\n" then
    String.substring(s, 0, size s - 1)
  else s

fun take_token s =
  let
    fun loop i =
      if i >= size s then i
      else
        case String.sub(s, i) of
            #" " => i
          | #"\t" => i
          | #"\n" => i
          | _ => loop (i + 1)
    val n = loop 0
  in
    String.substring(s, 0, n)
  end

fun blob_ref line =
  let val clean = trim_newline line
  in
    case String.tokens Char.isSpace clean of
        ["blob", _, hash] => SOME hash
      | _ =>
          if has_prefix "blob=" clean then SOME (take_token (String.extract(clean, 5, NONE)))
          else if has_prefix "blob-sha1=" clean then SOME (take_token (String.extract(clean, 10, NONE)))
          else NONE
  end

fun unique_blobs manifest_text =
  let
    fun add (hash, hashes) =
      if List.exists (fn existing => existing = hash) hashes then hashes else hash :: hashes
    fun line (text, hashes) =
      case blob_ref text of
          SOME hash => add (hash, hashes)
        | NONE => hashes
  in
    rev (List.foldl line [] (String.tokens (fn c => c = #"\n") manifest_text))
  end

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if FS.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

val temp_blob_counter = ref 0
val temp_blob_mutex = Mutex.mutex ()

fun next_temp_blob_id () =
  (Mutex.lock temp_blob_mutex;
   (temp_blob_counter := !temp_blob_counter + 1; !temp_blob_counter)
   before Mutex.unlock temp_blob_mutex)

(* Unique per copy: concurrent copies of one blob (parallel build workers,
   prefetch, other holbuild processes) share tmp_dir. *)
fun temp_blob_path tmp_dir hash =
  Path.concat(tmp_dir, String.concat ["holbuild-cache-transfer-", hash, "-",
                                      HolbuildFileLock.current_pid_text (), "-",
                                      Int.toString (next_temp_blob_id ()), ".blob"])

fun fetch_blob_or_raise (source : source) hash path =
  case #fetch_blob source {hash = hash, dst = path} of
      HolbuildCacheBackend.Hit => ()
    | HolbuildCacheBackend.Miss => raise Error ("source cache blob missing: " ^ hash)
    | HolbuildCacheBackend.Corrupt detail => raise Error ("source cache blob corrupt: " ^ hash ^ " (" ^ detail ^ ")")

fun publish_blob_or_raise (destination : destination) hash path =
  case #publish_blob destination {hash = hash, src = path} of
      HolbuildCacheBackend.Published => (1, 0)
    | HolbuildCacheBackend.AlreadyPresent => (0, 1)
    | HolbuildCacheBackend.Skipped => (0, 0)
    | HolbuildCacheBackend.Conflict detail => raise Error ("destination cache blob conflict: " ^ hash ^ " (" ^ detail ^ ")")

fun copy_blob {source, destination, tmp_dir} hash =
  let
    val path = temp_blob_path tmp_dir hash
    val counts =
      (fetch_blob_or_raise source hash path;
       publish_blob_or_raise destination hash path)
      handle e => (remove_file path; raise e)
  in
    remove_file path;
    counts
  end

fun put_action_or_raise (destination : destination) key text =
  case #put_action destination HolbuildCacheBackend.PutIfAbsentOrSame {key = key, text = text} of
      result as HolbuildCacheBackend.Published => result
    | result as HolbuildCacheBackend.AlreadyPresent => result
    | result as HolbuildCacheBackend.Skipped => result
    | HolbuildCacheBackend.Conflict detail => raise Error ("destination cache action conflict: " ^ key ^ " (" ^ detail ^ ")")

(* Work that a caller waits on (demand restores, publishes, hbx) runs before
   queued speculative work (prefetch). *)
datatype priority = Urgent | Background

datatype outcome = Copied of entry_result | Missing | Failed of exn

type queue = {front : (unit -> unit) list ref, back : (unit -> unit) list ref}

(* One pool bounds every transfer of a build or command.  Tasks never wait for
   other pool tasks, so any size, 1 included, makes progress: an entry is a
   manifest task that queues one task per blob, and the task that finishes the
   last blob writes the action. *)
type pool =
  {mutex : Mutex.mutex,
   changed : ConditionVar.conditionVar,
   urgent : queue,
   background : queue,
   running : int ref,
   closing : bool ref}

fun with_lock (pool : pool) f =
  (Mutex.lock (#mutex pool); f () before Mutex.unlock (#mutex pool))
  handle e => (Mutex.unlock (#mutex pool); raise e)

fun wait (pool : pool) = ConditionVar.wait (#changed pool, #mutex pool)
fun broadcast (pool : pool) = ConditionVar.broadcast (#changed pool)

fun new_queue () : queue = {front = ref [], back = ref []}

fun queue_of (pool : pool) Urgent = #urgent pool
  | queue_of pool Background = #background pool

fun pop ({front, back} : queue) =
  case !front of
      task :: rest => (front := rest; SOME task)
    | [] =>
        case rev (!back) of
            [] => NONE
          | task :: rest => (back := []; front := rest; SOME task)

fun queue_empty ({front, back} : queue) = null (!front) andalso null (!back)

fun clear_queue ({front, back} : queue) = (front := []; back := [])

(* A closing pool drops background work: nobody waits for it. *)
fun accepts (pool : pool) priority = priority = Urgent orelse not (!(#closing pool))

fun push_back pool priority task =
  with_lock pool (fn () =>
    if accepts pool priority then
      let val {back, ...} = queue_of pool priority
      in back := task :: !back; broadcast pool end
    else ())

(* A started entry's blobs go ahead of entries not yet started, so the pool
   finishes entries rather than starting many. *)
fun push_front pool priority tasks =
  with_lock pool (fn () =>
    if accepts pool priority then
      let val {front, ...} = queue_of pool priority
      in front := tasks @ !front; broadcast pool end
    else ())

fun next_task (pool : pool) () =
  case pop (#urgent pool) of
      SOME task => SOME task
    | NONE =>
        case pop (#background pool) of
            SOME task => SOME task
          | NONE => if !(#closing pool) then NONE else (wait pool; next_task pool ())

fun worker (pool : pool) () =
  case with_lock pool (fn () =>
         case next_task pool () of
             SOME task => (#running pool := !(#running pool) + 1; SOME task)
           | NONE => NONE) of
      NONE => ()
    | SOME task =>
        ((task () handle _ => ());
         with_lock pool (fn () => (#running pool := !(#running pool) - 1; broadcast pool));
         worker pool ())

(** Starts a pool of jobs worker threads. *)
fun create_pool jobs =
  let
    val pool = {mutex = Mutex.mutex (), changed = ConditionVar.conditionVar (),
                urgent = new_queue (), background = new_queue (),
                running = ref 0, closing = ref false}
  in
    List.app (fn _ => ignore (Thread.fork (worker pool, []))) (List.tabulate (jobs, fn i => i));
    pool
  end

(** Drops queued background work, waits for the rest, and stops the workers.
    The pool takes no work afterwards. *)
fun shutdown_pool (pool : pool) =
  with_lock pool (fn () =>
    let
      fun drain () =
        if queue_empty (#urgent pool) andalso !(#running pool) = 0 then ()
        else (wait pool; drain ())
    in
      #closing pool := true;
      clear_queue (#background pool);
      drain ();
      broadcast pool
    end)

(** Runs f with a fresh pool and shuts the pool down afterwards. *)
fun with_pool jobs f =
  let val pool = create_pool jobs
  in
    (f pool before shutdown_pool pool)
    handle e => (shutdown_pool pool; raise e)
  end

(** HOLBUILD_CACHE_TRANSFER_JOBS, else min(32, 4 * build_jobs). *)
fun pool_jobs build_jobs =
  case OS.Process.getEnv "HOLBUILD_CACHE_TRANSFER_JOBS" of
      NONE => Int.min (32, 4 * Int.max (1, build_jobs))
    | SOME text =>
        case Int.fromString text of
            SOME n => if n >= 1 then n
                      else raise Error ("HOLBUILD_CACHE_TRANSFER_JOBS must be at least 1, got " ^ text)
          | NONE => raise Error ("HOLBUILD_CACHE_TRANSFER_JOBS must be an integer, got " ^ text)

(** Queues the copy of one entry and returns at once; finish gets its outcome
    after every blob task the entry started has finished, so nothing is still
    writing into tmp_dir.  A failed blob stops the entry's remaining blobs and
    its action is never written. *)
fun start_entry pool priority (transfer as {source : source, destination : destination, tmp_dir}) key finish =
  let
    fun report outcome = finish outcome handle _ => ()
    fun write_action text blobs uploaded reused =
      report (Copied {key = key, blobs = blobs, uploaded_blobs = uploaded, reused_blobs = reused,
                      action = put_action_or_raise destination key text})
      handle e => report (Failed e)
    fun start_blobs text blobs =
      let
        val remaining = ref (length blobs)
        val failure = ref (NONE : exn option)
        val uploaded = ref 0
        val reused = ref 0
        fun blob_task hash () =
          let
            val skip = with_lock pool (fn () => Option.isSome (!failure))
            val (up, re) =
              if skip then (0, 0)
              else copy_blob transfer hash
                   handle e => (with_lock pool (fn () => if Option.isSome (!failure) then () else failure := SOME e);
                                (0, 0))
            val last =
              with_lock pool (fn () =>
                (uploaded := !uploaded + up; reused := !reused + re;
                 remaining := !remaining - 1; !remaining = 0))
          in
            if not last then ()
            else
              case !failure of
                  SOME e => report (Failed e)
                | NONE => write_action text (length blobs) (!uploaded) (!reused)
          end
      in
        ensure_dir tmp_dir;
        push_front pool priority (map blob_task blobs)
      end
    fun manifest_task () =
      case #get_action source key of
          NONE => report Missing
        | SOME text =>
            case unique_blobs text of
                [] => write_action text 0 0 0
              | blobs => start_blobs text blobs
      handle e => report (Failed e)
  in
    push_back pool priority manifest_task
  end

fun copy_outcomes pool transfer keys =
  let
    val outcomes = Array.array (length keys, NONE : outcome option)
    val pending = ref (length keys)
    fun finish i outcome =
      with_lock pool (fn () =>
        (Array.update (outcomes, i, SOME outcome); pending := !pending - 1; broadcast pool))
    fun await () = if !pending = 0 then () else (wait pool; await ())
  in
    List.foldl (fn (key, i) => (start_entry pool Urgent transfer key (finish i); i + 1)) 0 keys;
    with_lock pool await;
    List.tabulate (length keys, fn i => valOf (Array.sub (outcomes, i)))
  end

(** Copies one entry and waits for it. *)
fun copy_entry pool transfer key = hd (copy_outcomes pool transfer [key])

(** Copies all entries concurrently, waits for all of them, and raises the
    error of the first failed key. *)
fun copy_entries pool transfer keys =
  let
    fun results (key :: keys) (outcome :: outcomes) =
          (case outcome of
               Copied result => result
             | Missing => raise Error ("source cache action missing: " ^ key)
             | Failed e => raise e) :: results keys outcomes
      | results _ _ = []
  in
    results keys (copy_outcomes pool transfer keys)
  end

end
