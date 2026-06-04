structure HolbuildHolSharedCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val format_version = "holbuild-hol-toolchain-v1"
val default_canonical_git = "https://github.com/HOL-Theorem-Prover/HOL.git"
val build_args = ""

fun die msg = raise Error msg
fun quote s = HolbuildHash.quote s
fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false
fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false
fun executable path = FS.access(path, [FS.A_READ, FS.A_EXEC]) handle OS.SysErr _ => false

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if path_exists path then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun remove_tree path =
  if path = "" orelse path = "." orelse path = "/" then die ("refusing to remove unsafe path: " ^ path)
  else ignore (OS.Process.system ("rm -rf " ^ quote path))

fun cache_root () =
  case OS.Process.getEnv "HOLBUILD_CACHE" of
      SOME path => path
    | NONE =>
      case OS.Process.getEnv "XDG_CACHE_HOME" of
          SOME base => Path.concat(base, "holbuild")
        | NONE =>
          case OS.Process.getEnv "HOME" of
              SOME home => Path.concat(Path.concat(home, ".cache"), "holbuild")
            | NONE => die "set HOME, XDG_CACHE_HOME, or HOLBUILD_CACHE"

fun canonical_git () = Option.getOpt(OS.Process.getEnv "HOLBUILD_CANONICAL_HOL_GIT", default_canonical_git)

fun validate_git git =
  if git = canonical_git () then ()
  else die ("dependencies.hol.git must be the canonical HOL repository: " ^ canonical_git ())

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

fun run_in_dir dir command =
  let val status = OS.Process.system ("cd " ^ quote dir ^ " && " ^ command)
  in if OS.Process.isSuccess status then () else die ("HOL build command failed in " ^ dir ^ ": " ^ command) end

fun trim text =
  let
    fun ws c = Char.isSpace c
    val n = size text
    fun left i = if i < n andalso ws (String.sub(text, i)) then left (i + 1) else i
    fun right i = if i >= 0 andalso ws (String.sub(text, i)) then right (i - 1) else i
    val l = left 0
    val r = right (n - 1)
  in if r < l then "" else String.substring(text, l, r - l + 1) end

fun poly_command () = Option.getOpt(OS.Process.getEnv "HOLBUILD_POLY", "poly")
fun poly_version () = trim (command_output (quote (poly_command ()) ^ " -v"))

fun key_material {git, rev} =
  let val _ = validate_git git
      val poly = poly_command ()
      val version = poly_version ()
  in
    String.concatWith "\n"
      [format_version, "git=" ^ git, "rev=" ^ rev, "poly=" ^ poly,
       "poly_version=" ^ version, "build_args=" ^ build_args]
  end

fun key req = HolbuildHash.string_sha1 (key_material req)
fun toolchains_dir () = Path.concat(cache_root (), "hol-toolchains")
fun entry_dir_for_key k = Path.concat(toolchains_dir (), k)
fun holdir_for_key k = Path.concat(entry_dir_for_key k, "hol")
fun manifest_for_key k = Path.concat(entry_dir_for_key k, "manifest")
fun ok_for_key k = Path.concat(entry_dir_for_key k, "build.ok")
fun tmp_root () = Path.concat(toolchains_dir (), "tmp")
fun locks_dir () = Path.concat(cache_root (), "locks")
fun lock_dir k = Path.concat(locks_dir (), "hol-toolchain-" ^ k ^ ".lock")

fun holdir_for req = holdir_for_key (key req)

fun built holdir =
  executable (Path.concat(holdir, "bin/hol")) andalso
  executable (Path.concat(holdir, "bin/build")) andalso
  readable (Path.concat(holdir, "bin/hol.state"))

fun dirty_status holdir = trim (command_output ("git -C " ^ quote holdir ^ " status --porcelain --ignored=no"))
fun clean holdir = dirty_status holdir = ""

fun validate_entry req k =
  let val dir = entry_dir_for_key k
      val holdir = holdir_for_key k
  in
    if not (path_exists dir) then false
    else if not (path_exists (ok_for_key k)) then
      die ("incomplete HOL toolchain cache entry: " ^ dir ^ "\nremove it with: rm -rf " ^ quote dir)
    else if not (built holdir) then
      die ("broken HOL toolchain cache entry: " ^ dir ^ "\nremove it with: rm -rf " ^ quote dir)
    else
      let val status = dirty_status holdir
      in
        if status = "" then true
        else die ("dirty HOL toolchain cache entry: " ^ dir ^ "\n" ^ status ^ "\nremove it with: rm -rf " ^ quote dir)
      end
  end

fun acquire_lock k =
  let val l = lock_dir k
  in
    ensure_dir (locks_dir ());
    (FS.mkDir l; l)
    handle OS.SysErr _ => die ("HOL toolchain cache is locked: " ^ l)
  end
fun release_lock l = FS.rmDir l handle OS.SysErr _ => ()

fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun build_entry req k =
  let
    val tmpbase = Path.concat(tmp_root (), k ^ "-" ^ HolbuildHash.string_sha1 (Time.toString (Time.now ())))
    val tmphol = Path.concat(tmpbase, "hol")
    val final = entry_dir_for_key k
    val material = key_material req
    fun build () =
      (ensure_dir (tmp_root ());
       if path_exists tmpbase then remove_tree tmpbase else ();
       run_in_dir (tmp_root ()) ("git clone " ^ quote (#git req) ^ " " ^ quote tmphol);
       run_in_dir tmphol ("git checkout --detach " ^ quote (#rev req));
       run_in_dir tmphol (quote (poly_command ()) ^ " --script tools/smart-configure.sml");
       run_in_dir tmphol "bin/build";
       if built tmphol then () else die ("HOL build did not produce bin/hol, bin/build, and bin/hol.state in " ^ tmphol);
       if clean tmphol then () else die ("HOL build left dirty checkout: " ^ tmphol ^ "\n" ^ dirty_status tmphol);
       write_file (Path.concat(tmpbase, "manifest")) (material ^ "\nkey=" ^ k ^ "\n");
       write_file (Path.concat(tmpbase, "build.ok")) "ok\n";
       if path_exists final then die ("HOL toolchain cache entry appeared during build: " ^ final)
       else FS.rename {old = tmpbase, new = final};
       holdir_for_key k)
  in
    build () handle Error msg => die (msg ^ "\nfailed HOL build left at: " ^ tmpbase)
  end

fun ensure_built req =
  let
    val material = key_material req
    val k = HolbuildHash.string_sha1 material
  in
    if validate_entry req k then holdir_for_key k
    else
      let val l = acquire_lock k
      in
        ((if validate_entry req k then holdir_for_key k else build_entry req k)
         before release_lock l)
        handle e => (release_lock l; raise e)
      end
  end

end
