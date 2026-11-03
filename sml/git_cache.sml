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
    val tmp = FS.tmpName ()
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

fun cache_remote_dir git =
  let
    val root = cache_root ()
    val remotes = Path.concat(Path.concat(root, "git"), "remotes")
    val hash = HolbuildHash.string_sha1 git
  in
    ensure_dir remotes;
    Path.concat(remotes, hash ^ ".git")
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
    val tmp = dir ^ ".tmp-" ^ HolbuildFileLock.current_pid_text ()
  in
    remove_temp_dirs {dir = Path.dir dir, prefix = Path.file dir ^ ".tmp-"};
    (run ("git clone --bare " ^ quote git ^ " " ^ quote tmp);
     let val out = TextIO.openOut (dir ^ ".holbuild-url")
     in TextIO.output(out, git ^ "\n"); TextIO.closeOut out end;
     FS.rename {old = tmp, new = dir})
    handle e => (remove_if_exists tmp; raise e)
  end

fun verify_commit remote rev =
  (run ("git -C " ^ quote remote ^ " cat-file -e " ^ quote (rev ^ "^{commit}"));
   trim (command_output ("git -C " ^ quote remote ^ " rev-parse " ^ quote (rev ^ "^{commit}"))))

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
            (if path_exists remote then () else clone_remote git remote;
             if has_commit remote rev then ()
             else run ("git -C " ^ quote remote ^ " fetch origin " ^ quote rev)));
    (remote, verify_commit remote rev)
  end

fun materialized_head dest =
  if path_exists dest then
    let
      val run = HolbuildSpawn.run {program = "git", args = ["-C", dest, "rev-parse", "HEAD"],
                                   stderr = HolbuildSpawn.Discard}
    in
      if HolbuildSpawn.succeeded run then SOME (trim (#output run)) else NONE
    end
  else NONE

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

(* Moves a complete checkout to dest, replacing an existing tree only while
   no other process holds its lease. *)
fun publish_checkout {tmp, dest, lease} =
  if not (path_exists dest) then FS.rename {old = tmp, new = dest}
  else
    case HolbuildFileLock.try_acquire_path {path = lease, obsolete_kind = NONE}
         handle HolbuildFileLock.Error msg => die msg of
        NONE =>
          die ("cannot replace dependency checkout " ^ dest ^
               ": another holbuild process is using it" ^ holder_text lease)
      | SOME lock =>
          ((remove_tree dest; FS.rename {old = tmp, new = dest}; HolbuildFileLock.release lock)
           handle e => (HolbuildFileLock.release lock; raise e))

fun materialize {name, git, rev, artifact_root} =
  let
    val _ = validate_name name
    val _ = validate_rev rev
    val holbuild_dir = Path.concat(artifact_root, ".holbuild")
    val src_root = Path.concat(holbuild_dir, "src")
    val dest = Path.concat(src_root, name)
    val locks = Path.concat(Path.concat(holbuild_dir, "locks"), "src")
    val lease = Path.concat(locks, name ^ ".lease")
    fun pinned () = materialized_head dest = SOME rev
    (* Runs under the checkout lock. *)
    fun checkout () =
      let
        val (remote, commit) = ensure_commit git rev
        val tmp_prefix = ".tmp-" ^ name ^ "-"
        val tmp = Path.concat(src_root, tmp_prefix ^ HolbuildFileLock.current_pid_text ())
      in
        remove_temp_dirs {dir = src_root, prefix = tmp_prefix};
        (run ("git clone " ^ quote remote ^ " " ^ quote tmp);
         run ("git -C " ^ quote tmp ^ " checkout --detach " ^ quote commit);
         publish_checkout {tmp = tmp, dest = dest, lease = lease})
        handle e => (remove_if_exists tmp; raise e)
      end
  in
    ensure_dir src_root;
    (* HEAD is checked again under the lease: a checkout replaced between the
       first check and the lease is no longer at rev. *)
    if pinned () andalso (hold_lease lease; pinned ()) then dest
    else
      (drop_lease lease;
       with_lock (Path.concat(locks, name ^ ".lock"))
         (fn () => (if pinned () then () else checkout (); hold_lease lease));
       dest)
  end

end
