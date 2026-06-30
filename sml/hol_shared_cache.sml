structure HolbuildHolSharedCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val format_version = "holbuild-hol-toolchain-v1"
val default_canonical_git = "https://github.com/HOL-Theorem-Prover/HOL.git"
val build_args = "--no-helpdocs"
val analyser_format_version = "holbuild-hol-analyser-v1"
val analyser_protocol_version = "1"
val analyser_source_files =
  ["../hash.sml",
   "../../vendor/sml-sha256/lib/from-string.sig",
   "../../vendor/sml-sha256/lib/from-string.sml",
   "../../vendor/sml-sha256/lib/bytestring.sig",
   "../../vendor/sml-sha256/lib/bytestring.sml",
   "../../vendor/sml-sha256/lib/convert-word.sml",
   "../../vendor/sml-sha256/lib/susp.sig",
   "../../vendor/sml-sha256/lib/susp.sml",
   "../../vendor/sml-sha256/lib/stream.sig",
   "../../vendor/sml-sha256/lib/stream.sml",
   "../../vendor/sml-sha256/lib/sha256.sig",
   "../../vendor/sml-sha256/lib/sha256.sml",
   "analysis_protocol.sml",
   "dependency_extract.sml",
   "theory_span_extract.sml",
   "../proof_ir_types.sml",
   "../proof_ir.sml",
   "proof_ir_extract.sml",
   "analyser_main.sml",
   "holbuild-hol-analyser-script.sml"]

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
  HolbuildCacheConfig.cache_root ()
  handle HolbuildCacheConfig.Error msg => die msg

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
fun analysers_dir_for_key k = Path.concat(entry_dir_for_key k, "analysers")
fun analyser_dir_for_key k ak = Path.concat(analysers_dir_for_key k, ak)
fun analyser_bin_for_key k ak = Path.concat(Path.concat(analyser_dir_for_key k ak, "bin"), "holbuild-hol-analyser")
fun analyser_ok_for_key k ak = Path.concat(analyser_dir_for_key k ak, "build.ok")
fun analyser_manifest_for_key k ak = Path.concat(analyser_dir_for_key k ak, "manifest")
fun locks_dir () = Path.concat(toolchains_dir (), ".locks")
fun lock_dir k = Path.concat(locks_dir (), "hol-toolchain-" ^ k ^ ".lock")
fun lock_owner_path lock = lock ^ ".owner"

datatype toolchain_lock = ToolchainLock of HolbuildFileLock.t

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

fun current_lock_owner lock = SOME (HolbuildFileLock.read_text (lock_owner_path lock)) handle _ => NONE

fun lock_owner () =
  String.concatWith "\n"
    ["holbuild-hol-toolchain-lock-v1",
     "command=bootstrap HOL toolchain",
     "pid=" ^ HolbuildFileLock.current_pid_text (),
     "cwd=" ^ FS.getDir (),
     "host=" ^ HolbuildFileLock.current_host (),
     "started=" ^ Time.toString (Time.now ())] ^ "\n"

fun unavailable_lock_owner () =
  String.concatWith "\n"
    ["holbuild-hol-toolchain-lock-v1",
     "command=unknown",
     "pid=unknown",
     "cwd=unknown"] ^ "\n"

fun toolchain_lock_error lock owner =
  Error ("HOL toolchain cache is locked\n" ^
         "lock: " ^ lock ^ "\n" ^
         "owner: " ^ HolbuildFileLock.owner_summary owner)

fun try_acquire_lock_path lock =
  HolbuildFileLock.try_acquire_path {path = lock, obsolete_kind = SOME "HOL toolchain"}
  handle HolbuildFileLock.Error msg => raise Error ("could not acquire HOL toolchain cache lock: " ^ msg)

fun acquire_lock k =
  let
    val lock_path = lock_dir k
    fun acquired lock =
      ((HolbuildFileLock.write_text (lock_owner_path lock_path) (lock_owner ());
        ToolchainLock lock)
       handle e => (HolbuildFileLock.release lock; raise e))
    fun wait 0 =
          let val owner = Option.getOpt(current_lock_owner lock_path, unavailable_lock_owner ())
          in raise toolchain_lock_error lock_path owner end
      | wait n =
          case try_acquire_lock_path lock_path of
              SOME lock => acquired lock
            | NONE => (ignore (OS.Process.system "sleep 1"); wait (n - 1))
  in
    wait 120
  end

fun release_lock (ToolchainLock lock) =
  (HolbuildFileLock.remove_file (lock_owner_path (HolbuildFileLock.path lock));
   HolbuildFileLock.release lock)

fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun analyser_source_dir () =
  case OS.Process.getEnv "HOLBUILD_ANALYSER_SRC" of
      SOME path => path
    | NONE => Path.concat(HolbuildRuntimePaths.source_root, "sml/analyser")

fun analyser_source_path rel = Path.concat(analyser_source_dir (), rel)

fun analyser_source_hash () =
  HolbuildHash.string_sha1
    (String.concatWith "\n"
       (map (fn rel => rel ^ "=" ^ HolbuildHash.file_sha1 (analyser_source_path rel)) analyser_source_files))

fun analyser_key_material () =
  String.concatWith "\n"
    [analyser_format_version,
     "protocol=" ^ analyser_protocol_version,
     "source_hash=" ^ analyser_source_hash ()]

fun analyser_key () = HolbuildHash.string_sha1 (analyser_key_material ())
fun analyser_path_for_toolchain_key k = analyser_bin_for_key k (analyser_key ())
fun analyser_path_for_holdir holdir = analyser_path_for_toolchain_key (Path.file (Path.dir holdir))

fun analyser_built k ak =
  executable (analyser_bin_for_key k ak) andalso path_exists (analyser_ok_for_key k ak)

fun polyc_command () = Option.getOpt(OS.Process.getEnv "HOLBUILD_POLYC", "polyc")

fun build_analyser k =
  let
    val ak = analyser_key ()
    val dir = analyser_dir_for_key k ak
    val bindir = Path.concat(dir, "bin")
    val out = analyser_bin_for_key k ak
    val hol = holdir_for_key k
    val src = analyser_source_dir ()
    val material = analyser_key_material ()
  in
    if analyser_built k ak then out
    else
      (ensure_dir bindir;
       run_in_dir hol
         ("HOLBUILD_HOLDIR=" ^ quote hol ^ " " ^
          "HOLBUILD_ANALYSER_SRC=" ^ quote src ^ " " ^
          quote (polyc_command ()) ^ " -o " ^ quote out ^ " " ^
          quote (Path.concat(src, "holbuild-hol-analyser-script.sml")));
       if executable out then () else die ("analyser build did not produce executable: " ^ out);
       write_file (analyser_manifest_for_key k ak) (material ^ "\nkey=" ^ ak ^ "\n");
       write_file (analyser_ok_for_key k ak) "ok\n";
       out)
  end

fun build_entry req k =
  let
    val final = entry_dir_for_key k
    val hol = holdir_for_key k
    val material = key_material req
    fun build () =
      (ensure_dir (toolchains_dir ());
       if path_exists final then
         die ("incomplete HOL toolchain cache entry: " ^ final ^ "\nremove it with: rm -rf " ^ quote final)
       else ();
       ensure_dir final;
       run_in_dir final ("git clone " ^ quote (#git req) ^ " " ^ quote hol);
       run_in_dir hol ("git checkout --detach " ^ quote (#rev req));
       run_in_dir hol (quote (poly_command ()) ^ " --script tools/smart-configure.sml");
       run_in_dir hol ("bin/build " ^ build_args);
       if built hol then () else die ("HOL build did not produce bin/hol, bin/build, and bin/hol.state in " ^ hol);
       if clean hol then () else die ("HOL build left dirty checkout: " ^ hol ^ "\n" ^ dirty_status hol);
       write_file (manifest_for_key k) (material ^ "\nkey=" ^ k ^ "\n");
       write_file (ok_for_key k) "ok\n";
       hol)
  in
    build () handle Error msg => die (msg ^ "\nfailed HOL build left at: " ^ final)
  end

fun ensure_built req =
  let
    val material = key_material req
    val k = HolbuildHash.string_sha1 material
    val ak = analyser_key ()
  in
    if validate_entry req k andalso analyser_built k ak then holdir_for_key k
    else
      let val l = acquire_lock k
      in
        ((if validate_entry req k then holdir_for_key k else build_entry req k;
          ignore (build_analyser k);
          holdir_for_key k)
         before release_lock l)
        handle e => (release_lock l; raise e)
      end
  end

end
