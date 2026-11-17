structure HolbuildGitCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

fun die msg = raise Error msg

fun quote s = HolbuildHash.quote s

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if path_exists path then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun remove_tree path =
  HolbuildRemoveTree.remove_strict path handle HolbuildRemoveTree.Error msg => die msg

fun is_safe_name name =
  size name > 0 andalso
  List.all (fn c => Char.isAlphaNum c orelse c = #"_" orelse c = #"." orelse c = #"-")
           (String.explode name)

fun validate_name name =
  if is_safe_name name then ()
  else die ("unsafe dependency name for materialization: " ^ name)

fun is_hex c = Char.isDigit c orelse (#"a" <= c andalso c <= #"f")

fun validate_rev rev =
  if size rev = 40 andalso List.all is_hex (String.explode rev) then ()
  else die ("git dependency rev must be a full 40-character lowercase hex commit: " ^ rev)

fun command_output command =
  let
    val tmp = HolbuildTempPath.temporary "git-output"
    val status = OS.Process.system (command ^ " > " ^ quote tmp ^ " 2>&1")
    val input = TextIO.openIn tmp
    val text = TextIO.inputAll input before TextIO.closeIn input
    val _ = FS.remove tmp handle OS.SysErr _ => ()
  in
    if OS.Process.isSuccess status then text
    else die ("command failed: " ^ command ^ "\n" ^ text)
  end
  handle e as Error _ => raise e
       | e as HolbuildProcessGroup.Error _ => raise e
       | e => die ("command failed: " ^ command ^ ": " ^ General.exnMessage e)

fun run command = (ignore (command_output command); ())

fun trim text =
  let
    fun ws c = Char.isSpace c
    val n = size text
    fun left i = if i < n andalso ws (String.sub(text, i)) then left (i + 1) else i
    fun right i = if i >= 0 andalso ws (String.sub(text, i)) then right (i - 1) else i
    val l = left 0
    val r = right (n - 1)
  in
    if r < l then "" else String.substring(text, l, r - l + 1)
  end

fun cache_root () =
  HolbuildCacheConfig.cache_root ()
  handle HolbuildCacheConfig.Error msg => die msg

fun string_byte_reader text (offset, requested) =
  let val count = Int.max(0, Int.min(requested, size text - offset))
  in (Byte.stringToBytes (String.substring(text, offset, count)), offset + count) end

(* A mirror's name only has to be stable. It stays the SHA-1 of the URL, so
   caches keep the mirrors they have rather than cloning every dependency
   again and leaving the old mirrors behind, which gc never collects. *)
fun url_hash git = SHA1_ML.sha1String (string_byte_reader git) 0

fun cache_remote_dir git =
  let
    val root = cache_root ()
    val remotes = Path.concat(Path.concat(root, "git"), "remotes")
  in
    ensure_dir remotes;
    Path.concat(remotes, url_hash git ^ ".git")
  end

fun holder_text path =
  case HolbuildFileLock.lock_holder_pid {path = path} of
      SOME pid => " (pid " ^ pid ^ ")"
    | NONE => ""

(* Says who holds the lock before blocking on it: the holder's git output is
   captured, so without this a long clone elsewhere looks like a hang. *)
fun with_lock path f =
  let
    val lock =
      (case HolbuildFileLock.try_acquire_path {path = path, obsolete_kind = NONE} of
           SOME lock => lock
         | NONE =>
             (TextIO.output(TextIO.stdErr, "holbuild: waiting for another holbuild process" ^
                                           holder_text path ^ " to release " ^ path ^ "\n");
              TextIO.flushOut TextIO.stdErr;
              HolbuildFileLock.acquire_exclusive_path_wait {path = path}))
      handle HolbuildFileLock.Error msg => die msg
  in
    (f () before HolbuildFileLock.release lock)
    handle e => (HolbuildFileLock.release lock; raise e)
  end

fun remove_if_exists path = if path_exists path then remove_tree path else ()

fun list_dir dir =
  let
    val stream = FS.openDir dir
    fun loop acc = case FS.readDir stream of NONE => acc | SOME entry => loop (entry :: acc)
  in
    (loop [] before FS.closeDir stream) handle e => (FS.closeDir stream; raise e)
  end

(* Removes the temporary dirs prefix ^ <pid> in dir. Callers hold the lock
   that every writer of these dirs holds, so each one is left over from a
   killed process. *)
fun remove_temp_dirs {dir, prefix} =
  let
    fun is_temp entry =
      String.isPrefix prefix entry andalso
      let val pid = String.extract(entry, size prefix, NONE)
      in size pid > 0 andalso CharVector.all Char.isDigit pid end
  in
    List.app (fn entry => if is_temp entry then remove_tree (Path.concat(dir, entry)) else ())
             (list_dir dir)
  end

(* Clones into a temporary directory and renames it into place, so a mirror
   path that exists always holds a complete clone. Runs under the mirror lock. *)
fun clone_remote git dir =
  let
    val _ = HolbuildOffline.require_online "clone a dependency mirror"
    val tmp = dir ^ ".tmp-" ^ HolbuildFileLock.current_pid_text ()
  in
    remove_temp_dirs {dir = Path.dir dir, prefix = Path.file dir ^ ".tmp-"};
    (run (HolbuildOffline.git_command () ^ " clone --bare " ^ quote git ^ " " ^ quote tmp);
     let val out = TextIO.openOut (dir ^ ".holbuild-url")
     in TextIO.output(out, git ^ "\n"); TextIO.closeOut out end;
     FS.rename {old = tmp, new = dir})
    handle e => (remove_if_exists tmp; raise e)
  end

fun verify_commit remote rev =
  (run (HolbuildOffline.git_command () ^ " -C " ^ quote remote ^ " cat-file -e " ^ quote (rev ^ "^{commit}"));
   trim (command_output (HolbuildOffline.git_command () ^ " -C " ^ quote remote ^ " rev-parse " ^ quote (rev ^ "^{commit}"))))

fun has_commit remote rev = (ignore (verify_commit remote rev); true) handle Error _ => false

(* Returns the bare mirror of git and the commit rev names in it. The mirror
   is shared by every project under the cache root, so creating it and
   fetching into it are serialized per mirror. *)
fun ensure_commit git rev =
  let
    val remote = cache_remote_dir git
  in
    if path_exists remote andalso has_commit remote rev then ()
    else
      with_lock (remote ^ ".lock")
        (fn () =>
            (HolbuildOffline.require_online ("fetch dependency revision " ^ rev);
             if path_exists remote then () else clone_remote git remote;
             if has_commit remote rev then ()
             else run (HolbuildOffline.git_command () ^ " -C " ^ quote remote ^ " fetch origin " ^ quote rev)));
    (remote, verify_commit remote rev)
  end

(* Shared checkouts: one read-only tree per (dependency URL, commit) under
   git/checkouts, made once from the mirror and linked from each project's
   .holbuild/src/<name>.  A key directory that exists is complete: it is
   renamed into place under the key's lock.  Every process that uses one holds
   its usage lease until exit and rewrites its last-used marker, and cache GC
   removes it once unused for the retention period, as for HOL toolchains.
   Its files are read-only; its directories stay writable so that removing a
   cache with rm -rf still works. *)
fun lexical_absolute path =
  Path.mkCanonical
    (if Path.isAbsolute path then path
     else Path.mkAbsolute {path = path, relativeTo = FS.getDir ()})

fun checkouts_dir () = Path.concat(Path.concat(lexical_absolute (cache_root ()), "git"), "checkouts")
fun checkout_locks_dir () = Path.concat(checkouts_dir (), ".locks")
fun checkout_trash_dir () = Path.concat(checkouts_dir (), ".trash")
fun checkout_key git rev = url_hash git ^ "-" ^ rev
fun checkout_dir k = Path.concat(checkouts_dir (), k)
fun last_used_path k = checkout_dir k ^ ".last-used"
fun usage_lease_path k = Path.concat(checkout_locks_dir (), k ^ ".usage")
fun checkout_lock_path k = Path.concat(checkout_locks_dir (), k ^ ".lock")

(* fcntl locks are dropped when the process closes any descriptor for the
   file, so each key is leased at most once per process and never released. *)
val held_usage_leases = ref ([] : (string * HolbuildFileLock.t) list)

fun holds_usage_lease k = List.exists (fn (held, _) => held = k) (!held_usage_leases)

fun hold_usage_lease k =
  if holds_usage_lease k then ()
  else
    let
      val lease = HolbuildFileLock.acquire_shared_path_wait {path = usage_lease_path k}
                  handle HolbuildFileLock.Error msg => die ("could not acquire dependency checkout usage lease: " ^ msg)
    in
      held_usage_leases := (k, lease) :: !held_usage_leases
    end

(* GC retention is measured from the last-used marker's mtime. *)
fun touch_last_used k =
  TextIO.closeOut (TextIO.openOut (last_used_path k)) handle IO.Io _ => ()

(* Runs under the key's lock. *)
fun create_checkout git rev k =
  let
    val dir = checkout_dir k
    val (remote, commit) = ensure_commit git rev
    val tmp = dir ^ ".tmp-" ^ HolbuildFileLock.current_pid_text ()
    val index = HolbuildTempPath.temporary "checkout-index"
    val git_tree = "GIT_INDEX_FILE=" ^ quote index ^ " " ^ HolbuildOffline.git_command () ^
                   " --git-dir=" ^ quote remote ^ " --work-tree=" ^ quote tmp
    fun remove_index () = FS.remove index handle OS.SysErr _ => ()
  in
    remove_temp_dirs {dir = checkouts_dir (), prefix = k ^ ".tmp-"};
    (FS.mkDir tmp;
     run (git_tree ^ " read-tree " ^ quote commit);
     run (git_tree ^ " checkout-index --all");
     run ("find " ^ quote tmp ^ " -type f -exec chmod a-w {} +");
     FS.rename {old = tmp, new = dir})
    handle e => (remove_index (); remove_if_exists tmp; raise e);
    remove_index ()
  end

(* The shared checkout of dependency name (git at rev), made if missing (or
   collected), leased by this process and marked used. Offline, a missing one
   is not made, as a missing private clone is not. *)
fun shared_checkout name git rev =
  let
    val k = checkout_key git rev
    val dir = checkout_dir k
    fun create () =
      if path_exists dir then ()
      else
        (HolbuildOffline.require_online ("materialize dependency " ^ name ^ " at " ^ rev);
         create_checkout git rev k)
  in
    ensure_dir (checkout_locks_dir ());
    (* Lease before checking, so GC cannot remove the checkout in between. *)
    hold_usage_lease k;
    if path_exists dir then () else with_lock (checkout_lock_path k) create;
    touch_last_used k;
    dir
  end

datatype gc_outcome = GcKept | GcRemoved | GcBusy

fun is_checkout_key name =
  size name = 81 andalso String.sub(name, 40) = #"-" andalso
  CharVector.all is_hex (String.substring(name, 0, 40) ^ String.extract(name, 41, NONE))

fun checkout_keys () = List.filter is_checkout_key (list_dir (checkouts_dir ())) handle OS.SysErr _ => []

(* Leftovers of an interrupted checkout GC; HolbuildCache removes them under
   its GC lock before collecting checkouts. *)
fun checkout_trash () =
  map (fn name => Path.concat(checkout_trash_dir (), name)) (list_dir (checkout_trash_dir ()))
  handle OS.SysErr _ => []

fun last_use_time k =
  SOME (FS.modTime (last_used_path k))
  handle OS.SysErr _ => (SOME (FS.modTime (checkout_dir k)) handle OS.SysErr _ => NONE)

fun checkout_stale cutoff k =
  case last_use_time k of
      SOME time => Time.<(time, cutoff)
    | NONE => false

fun with_try_lock path f =
  case HolbuildFileLock.try_acquire_path {path = path, obsolete_kind = NONE}
       handle HolbuildFileLock.Error msg => die msg of
      NONE => GcBusy
    | SOME lock =>
        (f () before HolbuildFileLock.release lock)
        handle e => (HolbuildFileLock.release lock; raise e)

(* Removes the checkout if it is stale and no process holds its lock or usage
   lease. It is renamed out of checkouts first, so an interrupted GC never
   leaves a half-removed tree at the key. *)
fun gc_checkout cutoff k =
  (* fcntl locks never conflict within one process, so a checkout this process
     uses must be skipped explicitly. *)
  if holds_usage_lease k orelse not (checkout_stale cutoff k) then GcKept
  else
    with_try_lock (checkout_lock_path k) (fn () =>
      with_try_lock (usage_lease_path k) (fn () =>
        if not (checkout_stale cutoff k) then GcKept
        else
          let val trash = Path.concat(checkout_trash_dir (), k ^ "." ^ HolbuildFileLock.current_pid_text ())
          in
            ensure_dir (checkout_trash_dir ());
            remove_if_exists trash;
            FS.rename {old = checkout_dir k, new = trash};
            FS.remove (last_used_path k) handle OS.SysErr _ => ();
            remove_tree trash;
            GcRemoved
          end))

fun materialized_head dest =
  if path_exists dest then
    let
      val run = HolbuildOffline.git_run ["-C", dest, "rev-parse", "HEAD"]
    in
      if HolbuildSpawn.succeeded run then SOME (trim (#output run)) else NONE
    end
  else NONE

fun link_target path = SOME (FS.readLink path) handle OS.SysErr _ => NONE

fun entry_exists path = (ignore (Posix.FileSys.lstat path); true) handle OS.SysErr _ => false

(* A process that has seen a checkout at its pinned commit holds a shared
   lease on it until exit, and replacing a checkout takes the lease
   exclusively, so no process removes a tree another one is reading. fcntl
   locks are dropped when the process closes any descriptor for the file, so
   each lease is held at most once per process. *)
val held_leases = ref ([] : (string * HolbuildFileLock.t) list)

fun hold_lease path =
  if List.exists (fn (held, _) => held = path) (!held_leases) then ()
  else
    let
      val lease = HolbuildFileLock.acquire_shared_path_wait {path = path}
                  handle HolbuildFileLock.Error msg => die msg
    in
      held_leases := (path, lease) :: !held_leases
    end

fun drop_lease path =
  let val (dropped, kept) = List.partition (fn (held, _) => held = path) (!held_leases)
  in List.app (fn (_, lease) => HolbuildFileLock.release lease) dropped; held_leases := kept end

(* Moves a complete checkout or link to dest, replacing an existing one only
   while no other process holds its lease. *)
fun publish_checkout {tmp, dest, lease} =
  if not (entry_exists dest) then FS.rename {old = tmp, new = dest}
  else
    case HolbuildFileLock.try_acquire_path {path = lease, obsolete_kind = NONE}
         handle HolbuildFileLock.Error msg => die msg of
        NONE =>
          die ("cannot replace dependency checkout " ^ dest ^
               ": another holbuild process is using it" ^ holder_text lease)
      | SOME lock =>
          ((remove_tree dest; FS.rename {old = tmp, new = dest}; HolbuildFileLock.release lock)
           handle e => (HolbuildFileLock.release lock; raise e))

fun warn_fallback msg =
  (TextIO.output(TextIO.stdErr, "holbuild: cannot use a shared dependency checkout, cloning instead: " ^ msg ^ "\n");
   TextIO.flushOut TextIO.stdErr)

(* Makes .holbuild/src/<name> hold git at rev. With shared, it links to the
   shared checkout, or, if that cannot be made, falls back to a private clone;
   without, it is a private clone, which a dependency writing into its own
   tree needs. A private clone already at rev is kept either way. *)
fun materialize {name, git, rev, artifact_root, shared} =
  let
    val _ = validate_name name
    val _ = validate_rev rev
    val holbuild_dir = Path.concat(artifact_root, ".holbuild")
    val src_root = Path.concat(holbuild_dir, "src")
    val dest = Path.concat(src_root, name)
    val locks = Path.concat(Path.concat(holbuild_dir, "locks"), "src")
    val lease = Path.concat(locks, name ^ ".lease")
    val tmp_prefix = ".tmp-" ^ name ^ "-"
    val target =
      if not shared then NONE
      else SOME (shared_checkout name git rev)
           handle Error msg => (warn_fallback msg; NONE)
                | OS.SysErr (msg, _) => (warn_fallback msg; NONE)
    fun pinned () =
      case link_target dest of
          SOME link => SOME link = target
        | NONE => materialized_head dest = SOME rev
    fun publish make =
      let val tmp = Path.concat(src_root, tmp_prefix ^ HolbuildFileLock.current_pid_text ())
      in
        remove_temp_dirs {dir = src_root, prefix = tmp_prefix};
        (make tmp; publish_checkout {tmp = tmp, dest = dest, lease = lease})
        handle e => (if entry_exists tmp then remove_tree tmp else (); raise e)
      end
    fun clone tmp =
      let
        val _ = HolbuildOffline.require_online ("materialize dependency " ^ name ^ " at " ^ rev)
        val (remote, commit) = ensure_commit git rev
      in
        run (HolbuildOffline.git_command () ^ " clone " ^ quote remote ^ " " ^ quote tmp);
        run (HolbuildOffline.git_command () ^ " -C " ^ quote tmp ^ " checkout --detach " ^ quote commit)
      end
    (* Runs under the checkout lock. *)
    fun checkout () =
      case target of
          SOME checkout => publish (fn tmp => Posix.FileSys.symlink {old = checkout, new = tmp})
        | NONE => publish clone
  in
    ensure_dir src_root;
    (* The link or HEAD is checked again under the lease: a checkout replaced
       between the first check and the lease is no longer at rev. *)
    if pinned () andalso (hold_lease lease; pinned ()) then dest
    else
      (drop_lease lease;
       with_lock (Path.concat(locks, name ^ ".lock"))
         (fn () => (if pinned () then () else checkout (); hold_lease lease));
       dest)
  end

end
