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
  if path = "" orelse path = "." orelse path = "/" then
    die ("refusing to remove unsafe path: " ^ path)
  else
    let val status = OS.Process.system ("rm -rf " ^ quote path)
    in if OS.Process.isSuccess status then () else die ("failed to remove path: " ^ path) end

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

fun ensure_remote git =
  let
    val dir = cache_remote_dir git
    val meta = dir ^ ".holbuild-url"
  in
    if path_exists dir then
      run ("git -C " ^ quote dir ^ " fetch --prune origin")
    else
      (ensure_dir (Path.dir dir);
       run ("git clone --bare " ^ quote git ^ " " ^ quote dir);
       let val out = TextIO.openOut meta
       in TextIO.output(out, git ^ "\n"); TextIO.closeOut out end);
    dir
  end

fun verify_commit remote rev =
  (run ("git -C " ^ quote remote ^ " cat-file -e " ^ quote (rev ^ "^{commit}"));
   trim (command_output ("git -C " ^ quote remote ^ " rev-parse " ^ quote (rev ^ "^{commit}"))))

fun materialized_head dest =
  if path_exists dest then
    SOME (trim (command_output ("git -C " ^ quote dest ^ " rev-parse HEAD")))
    handle Error _ => NONE
  else NONE

fun materialize {name, git, rev, artifact_root} =
  let
    val _ = validate_name name
    val _ = validate_rev rev
    val remote = ensure_remote git
    val commit = verify_commit remote rev
    val src_root = Path.concat(Path.concat(artifact_root, ".holbuild"), "src")
    val dest = Path.concat(src_root, name)
  in
    ensure_dir src_root;
    case materialized_head dest of
        SOME head => if head = commit then dest
                     else (remove_tree dest; materialize {name = name, git = git, rev = rev, artifact_root = artifact_root})
      | NONE =>
          let
            val tmp = Path.concat(src_root, ".tmp-" ^ name ^ "-" ^ HolbuildHash.string_sha1 (name ^ rev ^ Time.toString (Time.now ())))
          in
            if path_exists tmp then remove_tree tmp else ();
            run ("git clone " ^ quote remote ^ " " ^ quote tmp);
            run ("git -C " ^ quote tmp ^ " checkout --detach " ^ quote commit);
            if path_exists dest then remove_tree dest else ();
            FS.rename {old = tmp, new = dest};
            dest
          end
  end

end
