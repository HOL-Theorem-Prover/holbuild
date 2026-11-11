structure HolbuildCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val default_retention_days = 7

fun has_prefix prefix s =
  size s >= size prefix andalso String.substring(s, 0, size prefix) = prefix

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun filesystem_cache root = HolbuildFSCacheBackend.filesystem root

fun default_backend () =
  HolbuildFSCacheBackend.default ()
  handle HolbuildFSCacheBackend.Error msg => raise Error msg

fun cache_root () = HolbuildFSCacheBackend.root (default_backend ())

fun actions_dir root = HolbuildFSCacheBackend.actions_dir (filesystem_cache root)
fun blobs_dir root = HolbuildFSCacheBackend.blobs_dir (filesystem_cache root)
fun tmp_dir root = HolbuildFSCacheBackend.tmp_dir (filesystem_cache root)
fun locks_dir root = HolbuildFSCacheBackend.locks_dir (filesystem_cache root)
fun theory_modules_dir root = Path.concat(root, "theory-modules")
fun analysis_dir root = Path.concat(root, "analysis")
fun action_dir root key = HolbuildFSCacheBackend.action_dir (filesystem_cache root) key
fun action_manifest root key = HolbuildFSCacheBackend.action_manifest (filesystem_cache root) key
fun blob_path root hash = HolbuildFSCacheBackend.blob_path (filesystem_cache root) hash

fun touch path = FS.setTime(path, NONE) handle OS.SysErr _ => ()

fun ensure_layout root = HolbuildFSCacheBackend.ensure_layout (filesystem_cache root)

fun get_action root key = HolbuildFSCacheBackend.get_action (filesystem_cache root) key
fun put_action root policy request = HolbuildFSCacheBackend.put_action (filesystem_cache root) policy request
fun write_action root request = HolbuildFSCacheBackend.write_action (filesystem_cache root) request
fun remove_action root key = HolbuildFSCacheBackend.remove_action (filesystem_cache root) key
fun touch_action root key = HolbuildFSCacheBackend.touch_action (filesystem_cache root) key
fun has_blob root hash = HolbuildFSCacheBackend.has_blob (filesystem_cache root) hash
fun verify_blob root hash = HolbuildFSCacheBackend.verify_blob (filesystem_cache root) hash
fun fetch_blob root request = HolbuildFSCacheBackend.fetch_blob (filesystem_cache root) request
fun publish_blob root request = HolbuildFSCacheBackend.publish_blob (filesystem_cache root) request
fun link_or_copy request = HolbuildFSCacheBackend.link_or_copy request

fun children dir =
  if not (path_exists dir) then []
  else
    let
      val stream = FS.openDir dir
      fun loop acc =
        case FS.readDir stream of
            NONE => rev acc
          | SOME name =>
            if name = "." orelse name = ".." then loop acc
            else loop (Path.concat(dir, name) :: acc)
      val result = loop [] handle e => (FS.closeDir stream; raise e)
    in
      FS.closeDir stream;
      result
    end

fun is_dir path = FS.isDir path handle OS.SysErr _ => false

(* A symlink is unlinked, never followed. *)
fun remove_tree path =
  HolbuildRemoveTree.remove_strict path handle HolbuildRemoveTree.Error msg => raise Error msg

(* Progress for long GC stages goes to stderr, leaving stdout to the summary,
   and is off under --quiet. A stage reports only after running for one
   interval, then once per interval: every second on a terminal, every ten
   seconds otherwise. An ANSI terminal gets one line redrawn in place, anything
   else a line per report. *)
datatype progress =
  Progress of {stage : string, total : int, in_place : bool, interval : Time.time,
               started : Time.time, next : Time.time ref, scanned : int ref,
               removed : int ref, shown : bool ref}

fun progress_interval terminal =
  case Option.mapPartial Real.fromString (OS.Process.getEnv "HOLBUILD_TEST_GC_PROGRESS_INTERVAL") of
      SOME seconds => Time.fromReal seconds
    | NONE => Time.fromReal (if terminal then 1.0 else 10.0)

fun start_progress steps_print stage total =
  let
    val terminal = terminal_primitives.strmIsTTY TextIO.stdErr
    val interval = progress_interval terminal
    val now = Time.now ()
  in
    Progress {stage = stage, total = total,
              in_place = terminal andalso terminal_primitives.TERM_isANSI () andalso not steps_print,
              interval = interval, started = now,
              next = ref (Time.+(now, interval)), scanned = ref 0, removed = ref 0,
              shown = ref false}
  end

fun show_progress (Progress {stage, total, in_place, started, scanned, removed, shown, ...}) final =
  let
    val elapsed = Real.fmt (StringCvt.FIX (SOME 1)) (Time.toReal (Time.-(Time.now (), started)))
    val text = "cache gc: " ^ stage ^ ": " ^ Int.toString (!scanned) ^ "/" ^ Int.toString total ^
               " scanned, " ^ Int.toString (!removed) ^ " removed, " ^ elapsed ^ "s"
  in
    shown := true;
    TextIO.output (TextIO.stdErr,
                   if in_place then "\r" ^ text ^ HolbuildStatus.clear_to_eol ^ (if final then "\n" else "")
                   else text ^ "\n");
    TextIO.flushOut TextIO.stdErr
  end

fun tick (progress as Progress {next, interval, scanned, removed, ...}) was_removed =
  let val now = Time.now ()
  in
    scanned := !scanned + 1;
    if was_removed then removed := !removed + 1 else ();
    if Time.>=(now, !next) then (next := Time.+(now, interval); show_progress progress false) else ()
  end

fun finish_progress (progress as Progress {shown, ...}) =
  if !shown then show_progress progress true else ()

(* Folds step over paths as one reported GC stage; step returns the new
   accumulator and whether it removed the entry. When steps_print, steps may
   write to stderr themselves, so each report gets a line of its own rather
   than one redrawn in place that their output would be appended to. *)
fun run_gc_stage steps_print stage paths step init =
  if HolbuildStatus.quiet_mode () orelse HolbuildStatus.json_mode () then
    List.foldl (fn (path, acc) => #1 (step (path, acc))) init paths
  else
    let
      val progress = start_progress steps_print stage (length paths)
      fun one (path, acc) =
        let val (acc, was_removed) = step (path, acc)
        in tick progress was_removed; acc end
    in
      (List.foldl one init paths before finish_progress progress)
      handle e => (finish_progress progress; raise e)
    end

fun gc_stage stage = run_gc_stage false stage

(* Toolchain removal runs `rm -rf` with inherited stderr, and taking an
   entry's lock may warn about an obsolete directory lock. *)
fun gc_toolchain_stage stage = run_gc_stage true stage

fun stale cutoff path =
  Time.<(FS.modTime path, cutoff) handle OS.SysErr _ => false

fun retention_cutoff days =
  if days < 0 then raise Error "retention days must be non-negative"
  else Time.-(Time.now(), Time.fromSeconds (IntInf.fromInt (days * 86400)))

fun empty_blob_set () = Redblackset.empty String.compare

fun add_blob (blob, blobs) = Redblackset.add(blobs, blob)

fun manifest_path action_dir = Path.concat(action_dir, "manifest")

(* Adds the blobs a manifest names; a manifest that is missing adds none. *)
fun add_manifest_blobs (action_dir, live_blobs) =
  case SOME (TextIO.openIn (manifest_path action_dir)) handle IO.Io _ => NONE of
      NONE => live_blobs
    | SOME input =>
        let
          fun loop blobs =
            case TextIO.inputLine input of
                NONE => blobs
              | SOME line =>
                  loop (case HolbuildFSCacheBackend.blob_ref line of
                            NONE => blobs
                          | SOME blob => add_blob (blob, blobs))
        in
          loop live_blobs before TextIO.closeIn input
          handle e => (TextIO.closeIn input; raise e)
        end

fun action_live_blobs action_dir = add_manifest_blobs (action_dir, empty_blob_set ())

(* An action's age is its manifest's, or its directory's when it has none. *)
fun action_modified action_dir =
  SOME (FS.modTime (manifest_path action_dir))
  handle OS.SysErr _ => (SOME (FS.modTime action_dir) handle OS.SysErr _ => NONE)

fun collect_live_actions cutoff actions_dir =
  let
    fun one (action_dir, (live_blobs, removed)) =
      case action_modified action_dir of
          SOME time =>
            if Time.< (time, cutoff) then
              (remove_tree action_dir; ((live_blobs, removed + 1), true))
            else
              ((add_manifest_blobs (action_dir, live_blobs), removed), false)
        | NONE => ((live_blobs, removed), false)
  in
    gc_stage "actions" (children actions_dir) one (empty_blob_set (), 0)
  end

fun remove_stale_children stage cutoff dir =
  gc_stage stage (children dir)
    (fn (path, removed) =>
        if stale cutoff path then (remove_tree path; (removed + 1, true)) else (removed, false))
    0

fun remove_obsolete_action_lock_dirs cutoff dir =
  gc_stage "locks" (children dir)
    (fn (path, removed) =>
        if has_prefix "action-" (Path.file path) andalso is_dir path andalso stale cutoff path then
          (remove_tree path; (removed + 1, true))
        else (removed, false))
    0

fun blob_name path = Path.file path

fun sweep_blobs cutoff live_blobs blobs_dir =
  gc_stage "blobs" (children blobs_dir)
    (fn (path, removed) =>
        if stale cutoff path andalso not (Redblackset.member(live_blobs, blob_name path)) then
          (remove_tree path; (removed + 1, true))
        else (removed, false))
    0

fun gc_toolchains cutoff =
  (gc_toolchain_stage "toolchain-trash" (HolbuildHolSharedCache.toolchain_trash ())
     (fn (path, ()) => (HolbuildHolSharedCache.remove_unlocked_tree path; ((), true)))
     ();
   gc_toolchain_stage "toolchains" (HolbuildHolSharedCache.toolchain_keys ())
     (fn (k, {removed, busy}) =>
         case HolbuildHolSharedCache.gc_entry cutoff k of
             HolbuildHolSharedCache.GcRemoved => ({removed = removed + 1, busy = busy}, true)
           | HolbuildHolSharedCache.GcBusy => ({removed = removed, busy = busy + 1}, false)
           | HolbuildHolSharedCache.GcKept => ({removed = removed, busy = busy}, false))
     {removed = 0, busy = 0})
  handle HolbuildHolSharedCache.Error msg => raise Error msg

fun gc_lock_path root = Path.concat(locks_dir root, "gc.lock")
fun gc_lock_owner_path lock = lock ^ ".owner"

datatype gc_lock = GcLock of HolbuildFileLock.t

fun gc_lock_owner () =
  String.concatWith "\n"
    ["holbuild-cache-gc-lock-v1",
     "command=cache gc",
     "pid=" ^ HolbuildFileLock.current_pid_text (),
     "pid_ns=" ^ HolbuildFileLock.current_pid_namespace (),
     "starttime=" ^ HolbuildFileLock.proc_starttime "self",
     "boot_id=" ^ HolbuildFileLock.current_boot_id (),
     "cwd=" ^ FS.getDir (),
     "host=" ^ HolbuildFileLock.current_host (),
     "started=" ^ Time.toString (Time.now ())] ^ "\n"

fun current_gc_lock_owner lock =
  SOME (HolbuildFileLock.read_text (gc_lock_owner_path lock)) handle _ => NONE

fun unavailable_gc_lock_owner () =
  String.concatWith "\n"
    ["holbuild-cache-gc-lock-v1",
     "command=cache gc",
     "pid=unknown",
     "cwd=unknown"] ^ "\n"

fun cache_gc_lock_error lock owner =
  Error ("cache gc already running\n" ^
         "lock: " ^ lock ^ "\n" ^
         "owner: " ^ HolbuildFileLock.owner_summary owner)

fun try_acquire_lock root =
  let val lock_path = gc_lock_path root
  in
    case HolbuildFileLock.try_acquire_path {path = lock_path, obsolete_kind = SOME "cache gc"} of
        SOME lock =>
          ((HolbuildFileLock.write_text (gc_lock_owner_path lock_path) (gc_lock_owner ());
            SOME (GcLock lock))
           handle e => (HolbuildFileLock.release lock; raise e))
      | NONE => NONE
  end
  handle HolbuildFileLock.Error msg => raise Error ("could not acquire cache gc lock: " ^ msg)

fun acquire_lock root =
  case try_acquire_lock root of
      SOME lock => lock
    | NONE =>
        let
          val lock_path = gc_lock_path root
          val owner = Option.getOpt(current_gc_lock_owner lock_path, unavailable_gc_lock_owner ())
        in raise cache_gc_lock_error lock_path owner end

fun release_gc_lock (GcLock lock) =
  (HolbuildFileLock.remove_file (gc_lock_owner_path (HolbuildFileLock.path lock));
   HolbuildFileLock.release lock)

fun with_gc_lock lock f =
  (f () before release_gc_lock lock)
  handle e => (release_gc_lock lock; raise e)

fun with_lock root f = with_gc_lock (acquire_lock root) f

(* NONE, without running f, while another process holds the lock. *)
fun try_with_lock root f = Option.map (fn lock => with_gc_lock lock f) (try_acquire_lock root)

fun with_action_publish_lock root key publish skip =
  HolbuildFSCacheBackend.with_action_publish_lock (filesystem_cache root) key publish skip

fun with_action_publish_lock_wait root key publish =
  HolbuildFSCacheBackend.with_action_publish_lock_wait (filesystem_cache root) key publish

fun growth_since_gc root = HolbuildFSCacheBackend.growth_since_gc (filesystem_cache root)

type gc_counts =
  {tmp : int, locks : int, actions : int, blobs : int, modules : int, analysis : int,
   toolchains : int, toolchains_busy : int}

(* One full collection; the caller holds the GC lock. Writes made while it runs
   count towards the next automatic GC. *)
fun collect_root root days : gc_counts =
  let
    val cutoff = retention_cutoff days
    val _ = HolbuildFSCacheBackend.reset_growth (filesystem_cache root)
    val tmp = remove_stale_children "tmp" cutoff (tmp_dir root)
    val modules = remove_stale_children "theory modules" cutoff (theory_modules_dir root)
    val analysis = remove_stale_children "analysis" cutoff (analysis_dir root)
    val locks = remove_obsolete_action_lock_dirs cutoff (locks_dir root)
    val (live_blobs, actions) = collect_live_actions cutoff (actions_dir root)
    val blobs = sweep_blobs cutoff live_blobs (blobs_dir root)
    val {removed = toolchains, busy = toolchains_busy} = gc_toolchains cutoff
  in
    {tmp = tmp, locks = locks, actions = actions, blobs = blobs, modules = modules,
     analysis = analysis, toolchains = toolchains, toolchains_busy = toolchains_busy}
  end

fun gc_counts_removed ({tmp, locks, actions, blobs, modules, analysis, toolchains, ...} : gc_counts) =
  tmp + locks + actions + blobs + modules + analysis + toolchains > 0

fun gc_counts_text ({tmp, locks, actions, blobs, modules, analysis, toolchains, toolchains_busy} : gc_counts) =
  "removed tmp=" ^ Int.toString tmp ^
  " locks=" ^ Int.toString locks ^
  " actions=" ^ Int.toString actions ^
  " blobs=" ^ Int.toString blobs ^
  " modules=" ^ Int.toString modules ^
  " analysis=" ^ Int.toString analysis ^
  " toolchains=" ^ Int.toString toolchains ^
  " toolchains-busy=" ^ Int.toString toolchains_busy

fun gc_root root days =
  if not (path_exists root) then
    print ("cache not found: " ^ root ^ "\n")
  else
    with_lock root (fn () => print ("cache gc: " ^ gc_counts_text (collect_root root days) ^ "\n"))

(* Toolchain-only GC: gc_root's lock and toolchain stages, without the tmp,
   locks, actions, or blobs stages. *)
fun gc_toolchains_root root days =
  if not (path_exists root) then
    print ("cache not found: " ^ root ^ "\n")
  else
    with_lock root (fn () =>
      let val {removed, busy} = gc_toolchains (retention_cutoff days)
      in
        print ("cache gc: removed toolchains=" ^ Int.toString removed ^
               " toolchains-busy=" ^ Int.toString busy ^ "\n")
      end)

fun parse_days text =
  case Int.fromString text of
      SOME n => n
    | NONE => raise Error ("invalid retention days: " ^ text)

fun parse_gc_args args =
  let
    fun loop days rest =
      case rest of
          [] => days
        | "--retention-days" :: n :: xs => loop (parse_days n) xs
        | "--days" :: n :: xs => loop (parse_days n) xs
        | arg :: _ => raise Error ("unknown cache gc option: " ^ arg)
  in
    loop default_retention_days args
  end

fun gc args =
  let val days = parse_gc_args args
  in gc_root (cache_root ()) days end

fun dispatch args =
  case args of
      "gc" :: rest => gc rest
    | [] => raise Error "cache command requires subcommand: gc"
    | cmd :: _ => raise Error ("unknown cache command: " ^ cmd ^ HolbuildSuggest.did_you_mean cmd ["gc"])

end
