structure HolbuildHolSharedCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val format_version = "holbuild-hol-toolchain-v2"
val theory_toolchain_format = "holbuild-theory-toolchain-v1"
val default_canonical_git = "https://github.com/HOL-Theorem-Prover/HOL.git"
val standard_kernel = HolbuildHolToolchainConfig.StandardKernel

fun toolchain_config kernel_variant = HolbuildHolToolchainConfig.config kernel_variant
val analyser_format_version = "holbuild-hol-analyser-v2"
val analyser_protocol_version = "1"
val analyser_source_files =
  ["../string_hash.sml",
   "../sha256.sml",
   "../spawn.sml",
   "../hash.sml",
   "analysis_protocol.sml",
   "dependency_extract.sml",
   "theory_span_extract.sml",
   "../proof_ir_types.sml",
   "../proof_ir.sml",
   "proof_step_plan_adapter_legacy.sml",
   "proof_step_plan_adapter_shared.sml",
   "tactic_parse_capabilities.sml",
   "tactic_parse_adapter_legacy.sml",
   "tactic_parse_adapter_token_spans.sml",
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

fun remove_tree run_command path =
  if path = "" orelse path = "." orelse path = "/" then die ("refusing to remove unsafe path: " ^ path)
  else ignore (run_command ("rm -rf " ^ quote path))

fun cache_root () =
  HolbuildCacheConfig.cache_root ()
  handle HolbuildCacheConfig.Error msg => die msg

fun canonical_git () = Option.getOpt(OS.Process.getEnv "HOLBUILD_CANONICAL_HOL_GIT", default_canonical_git)

fun validate_git git =
  if git = canonical_git () then ()
  else die ("dependencies.hol.git must be the canonical HOL repository: " ^ canonical_git ())

fun command_output_using run_command command =
  let
    val {status, output = text} = run_command (command ^ " 2>&1")
  in
    if OS.Process.isSuccess status then text
    else die ("command failed: " ^ command ^ "\n" ^ text)
  end
  handle e as Error _ => raise e
       | e as HolbuildProcessGroup.Error _ => raise e
       | e => die ("command failed: " ^ command ^ ": " ^ General.exnMessage e)

fun command_output command =
  command_output_using HolbuildProcessGroup.run_shell_output command

fun run_in_dir run_command dir command =
  let val status = run_command ("cd " ^ quote dir ^ " && " ^ command)
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
fun poly_version () =
  let
    val poly = poly_command ()
    val run = HolbuildSpawn.run {program = poly, args = ["-v"], stderr = HolbuildSpawn.Merge}
  in
    if HolbuildSpawn.succeeded run then trim (#output run)
    else die ("command failed: " ^ quote poly ^ " -v\n" ^ #output run)
  end

fun poly_executable_path () =
  let val path = trim (command_output ("command -v " ^ quote (poly_command ())))
  in FS.fullPath path end

(* poly -v prints "Poly/ML 5.9.2 Release    RTS version: Arm64-5.9.2 (Git
   version v5.9.2)".  release is the text before "RTS version:", without the
   architecture, which does not reach theory output.  rts is the RTS token: the
   release, which Poly/ML checks when it loads an exported heap, and the
   architecture variant (X86_64, compact X86_64_32, Portable), which it does
   not.  An unrecognised line is kept whole. *)
fun poly_version_parts version =
  let val (head, rest) = Substring.position "RTS version:" (Substring.full version)
      val rts =
        if Substring.isEmpty rest then version
        else
          case String.tokens Char.isSpace
                 (Substring.string (Substring.triml (size "RTS version:") rest)) of
              token :: _ => token
            | [] => version
  in
    {release = trim (Substring.string head), rts = rts}
  end

(* The local toolchain key names what a built toolchain depends on:
   - rev: the HOL sources (a full commit; the git URL must be the canonical
     one, so it adds nothing);
   - build_args: the build sequence, helpdocs and kernel;
   - poly_rts: the Poly/ML runtime release and architecture variant that the
     exported heaps need;
   - poly_path: the resolved poly executable, whose install directory HOL's
     configure bakes in and whose lib directory HOL's executables load
     libpolyml from.  Spellings of HOLBUILD_POLY that resolve to one
     executable share a toolchain.
   It is part of the remote archive identity, so nothing here may split on
   differences that leave a restored toolchain working. *)
fun key_material {git, rev, kernel_variant} =
  let val _ = validate_git git
  in
    String.concatWith "\n"
      ([format_version, "rev=" ^ rev,
        "poly_rts=" ^ #rts (poly_version_parts (poly_version ())),
        "poly_path=" ^ poly_executable_path ()] @
       HolbuildHolToolchainConfig.key_material_fields (toolchain_config kernel_variant))
  end

fun key req = HolbuildHash.string_sha1 (key_material req)
fun standard_request {git, rev} = {git = git, rev = rev, kernel_variant = standard_kernel}
fun lexical_absolute path =
  Path.mkCanonical
    (if Path.isAbsolute path then path
     else Path.mkAbsolute {path = path, relativeTo = FS.getDir ()})

fun toolchains_dir () = Path.concat(lexical_absolute (cache_root ()), "hol-toolchains")
fun entry_dir_for_key k = Path.concat(toolchains_dir (), k)
fun holdir_for_key k = Path.concat(entry_dir_for_key k, "hol")
fun manifest_for_key k = Path.concat(entry_dir_for_key k, "manifest")
fun hol_source_manifest_for_key k = Path.concat(entry_dir_for_key k, "hol-source.manifest.toml")
fun hol_source_members_for_key k = Path.concat(entry_dir_for_key k, "hol-source.members")
fun theory_toolchain_for_key k = Path.concat(entry_dir_for_key k, "theory-toolchain")
fun ok_for_key k = Path.concat(entry_dir_for_key k, "build.ok")
fun analysers_dir_for_key k = Path.concat(entry_dir_for_key k, "analysers")
fun analyser_dir_for_key k ak = Path.concat(analysers_dir_for_key k, ak)
fun analyser_bin_for_key k ak = Path.concat(Path.concat(analyser_dir_for_key k ak, "bin"), "holbuild-hol-analyser")
fun analyser_ok_for_key k ak = Path.concat(analyser_dir_for_key k ak, "build.ok")
fun analyser_manifest_for_key k ak = Path.concat(analyser_dir_for_key k ak, "manifest")
fun locks_dir () = Path.concat(toolchains_dir (), ".locks")
fun lock_dir k = Path.concat(locks_dir (), "hol-toolchain-" ^ k ^ ".lock")

fun mutation_lease_path k = lock_dir k ^ ".mutation"
fun usage_lease_path k = lock_dir k ^ ".usage"
fun last_used_for_key k = Path.concat(entry_dir_for_key k, "last-used")
fun trash_dir () = Path.concat(toolchains_dir (), ".trash")

fun run_mutation k script =
  HolbuildProcessGroup.run_shell_with_mutation_lease
    {lease_path = mutation_lease_path k, script = script}

fun run_mutation_output k script =
  HolbuildProcessGroup.run_shell_output_with_mutation_lease
    {lease_path = mutation_lease_path k, script = script}

fun await_mutation_quiescence k =
  if OS.Process.isSuccess (run_mutation k ":") then ()
  else die ("could not acquire HOL toolchain mutation lease: " ^ mutation_lease_path k)
fun lock_owner_path lock = lock ^ ".owner"

datatype toolchain_lock = ToolchainLock of HolbuildFileLock.t

fun holdir_for_with_kernel req = holdir_for_key (key req)
fun holdir_for req = holdir_for_with_kernel (standard_request req)
fun hol_source_manifest_for_holdir holdir = Path.concat(Path.dir holdir, "hol-source.manifest.toml")
fun theory_toolchain_for_holdir holdir = Path.concat(Path.dir holdir, "theory-toolchain")

fun built holdir =
  executable (Path.concat(holdir, "bin/hol")) andalso
  executable (Path.concat(holdir, "bin/Holmake")) andalso
  executable (Path.concat(holdir, "bin/build")) andalso
  readable (Path.concat(holdir, "bin/hol.state"))

fun dirty_status k holdir =
  trim
    (command_output_using (run_mutation_output k)
       ("git -C " ^ quote holdir ^ " status --porcelain --ignored=no"))
fun clean k holdir = dirty_status k holdir = ""

fun effective_build_args kernel_variant holdir =
  let val config = toolchain_config kernel_variant
  in
    case HolbuildHolToolchainConfig.required_sequence_file config of
        NONE => HolbuildHolToolchainConfig.build_args_text config
      | SOME rel =>
          if readable (Path.concat(holdir, rel)) then
            HolbuildHolToolchainConfig.build_args_text config
          else
            (TextIO.output
               (TextIO.stdErr,
                "holbuild: warning: selected HOL revision does not provide " ^ rel ^
                "; falling back to full HOL build\n");
             HolbuildHolToolchainConfig.full_build_args_text config)
  end

fun generate_hol_source_manifest k =
  HolbuildHolSourceManifest.generate
    {holdir = holdir_for_key k,
     manifest_path = hol_source_manifest_for_key k,
     members_path = hol_source_members_for_key k,
     run_command = run_mutation_output k}
  handle HolbuildHolSourceManifest.Error msg => die msg

fun hol_source_manifest_built k =
  let
    val path = hol_source_manifest_for_key k
    val input = TextIO.openIn path
    val first = TextIO.inputLine input
    val _ = TextIO.closeIn input
  in
    first = SOME ("# " ^ HolbuildBuiltinManifests.hol_source_manifest_version ^ "\n")
  end
  handle _ => false

(* The theory toolchain identity names what theory and library actions see of
   a toolchain: the HOL sources, how they were built, and the Poly/ML release.
   Theory objects are a function of these, while bin/hol and hol.state differ
   on every build, so theory action keys use this identity and runnable
   artifacts keep the exact toolchain key. *)

fun hol_source_files holdir =
  let
    fun visit rel acc =
      let val stream = FS.openDir (Path.concat(holdir, rel))
          fun child name = if rel = "" then name else Path.concat(rel, name)
          fun loop acc =
            case FS.readDir stream of
                NONE => acc
              | SOME ".git" => loop acc
              | SOME name =>
                  let val path = Path.concat(holdir, child name)
                  in
                    if not (FS.isLink path) andalso FS.isDir path then loop (visit (child name) acc)
                    else loop (child name :: acc)
                  end
      in
        (loop acc before FS.closeDir stream) handle e => (FS.closeDir stream; raise e)
      end
  in
    visit "" []
  end

(* Legacy only: toolchain entries built before the identity existed hold
   build outputs next to the sources, and their git checkout's file list
   recovers the source set that hol_source_files saw right after the fetch.
   NONE when that fails (not a git checkout, no git); the caller then
   rebuilds the entry.  Nothing else reads the identity from git. *)
fun legacy_hol_source_files k holdir =
  let
    (* Not command_output_using: git's stderr must not mix with the paths. *)
    val {status, output} =
      run_mutation_output k ("git -C " ^ quote holdir ^ " ls-files -z 2>/dev/null")
  in
    if OS.Process.isSuccess status then SOME (String.tokens (fn c => c = #"\000") output)
    else NONE
  end

fun hol_source_identity holdir rels =
  let
    fun is_link rel = FS.isLink (Path.concat(holdir, rel))
    val (links, files) = List.partition is_link rels
    val file_hashes =
      ListPair.zip (files, HolbuildHash.files_sha1 (map (fn rel => Path.concat(holdir, rel)) files))
    val link_hashes =
      map (fn rel => (rel, "symlink:" ^ FS.readLink (Path.concat(holdir, rel)))) links
    val entries =
      List.foldl (fn ((rel, hash), acc) => Binarymap.insert(acc, rel, hash))
                 (Binarymap.mkDict String.compare) (file_hashes @ link_hashes)
  in
    HolbuildHash.string_sha1
      (String.concat (map (fn (rel, hash) => rel ^ "\t" ^ hash ^ "\n") (Binarymap.listItems entries)))
  end
  handle OS.SysErr (msg, _) => die ("could not hash HOL sources in " ^ holdir ^ ": " ^ msg)

fun theory_toolchain_text kernel_variant hol_source =
  let val config = toolchain_config kernel_variant
      val material =
        String.concatWith "\n"
          [theory_toolchain_format,
           "hol_source=" ^ hol_source,
           "build_args=" ^ HolbuildHolToolchainConfig.build_args_text config,
           "kernel_variant=" ^ HolbuildHolToolchainConfig.kernel_variant_name kernel_variant,
           "poly=" ^ #release (poly_version_parts (poly_version ()))] ^ "\n"
  in
    material ^ "key=" ^ HolbuildHash.string_sha1 material ^ "\n"
  end

fun parse_theory_toolchain_key path text =
  case List.find (String.isPrefix "key=") (String.tokens (fn c => c = #"\n") text) of
      SOME line =>
        let val key = String.extract(line, size "key=", NONE)
        in if HolbuildHash.valid_sha1 key then key else die ("malformed theory toolchain key in " ^ path) end
    | NONE => die ("missing theory toolchain key in " ^ path)

fun theory_toolchain_built k =
  (ignore (parse_theory_toolchain_key "" (HolbuildFileLock.read_text (theory_toolchain_for_key k))); true)
  handle _ => false

fun theory_toolchain_key_for_holdir holdir =
  let val path = theory_toolchain_for_holdir holdir
      val text = HolbuildFileLock.read_text path
                 handle IO.Io _ => die ("HOL toolchain has no theory toolchain identity: " ^ path)
  in
    parse_theory_toolchain_key path text
  end

fun validate_entry req k =
  let val dir = entry_dir_for_key k
      val holdir = holdir_for_key k
  in
    if not (path_exists dir) then false
    else if not (path_exists (ok_for_key k)) then false
    else if not (built holdir) then
      die ("broken HOL toolchain cache entry: " ^ dir ^ "\nremove it with: rm -rf " ^ quote dir)
    else
      let
        val {status, output} =
          run_mutation_output k
            ("git -C " ^ quote holdir ^ " status --porcelain --ignored=no 2>/dev/null")
      in
        (* An entry whose tree is not a git checkout is rebuilt. *)
        if not (OS.Process.isSuccess status) then false
        else if trim output = "" then true
        else die ("dirty HOL toolchain cache entry: " ^ dir ^ "\n" ^ trim output ^ "\nremove it with: rm -rf " ^ quote dir)
      end
  end


fun current_lock_owner lock =
  SOME (HolbuildFileLock.read_text (lock_owner_path lock)) handle _ => NONE

fun lock_owner_for command =
  String.concatWith "\n"
    ["holbuild-hol-toolchain-lock-v1",
     "command=" ^ command,
     "pid=" ^ HolbuildFileLock.current_pid_text (),
     "cwd=" ^ FS.getDir (),
     "host=" ^ HolbuildFileLock.current_host (),
     "started=" ^ Time.toString (Time.now ())] ^ "\n"

fun lock_owner () = lock_owner_for "bootstrap HOL toolchain"

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

fun signal_test_lock_event variable =
  case OS.Process.getEnv variable of
      NONE => ()
    | SOME path => HolbuildFileLock.write_text path "observed\n"

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
            | NONE =>
                (signal_test_lock_event "HOLBUILD_TEST_TOOLCHAIN_LOCK_WAITING";
                 ignore (OS.Process.system "sleep 1");
                 wait (n - 1))
  in
    wait 120
  end

fun release_lock (ToolchainLock lock) =
  (HolbuildFileLock.remove_file (lock_owner_path (HolbuildFileLock.path lock));
   HolbuildFileLock.release lock)

fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

(* Every command that uses a toolchain holds a shared usage lease on it until
   the process exits, so toolchain GC never removes an entry in use. fcntl
   locks are dropped when the process closes any descriptor for the lease
   file, so each key is leased at most once per process and never released. *)
val held_usage_leases = ref ([] : (string * HolbuildFileLock.t) list)

fun holds_usage_lease k = List.exists (fn (held, _) => held = k) (!held_usage_leases)

fun hold_usage_lease k =
  if holds_usage_lease k then ()
  else
    let
      val lease = HolbuildFileLock.acquire_shared_path_wait {path = usage_lease_path k}
                  handle HolbuildFileLock.Error msg =>
                    die ("could not acquire HOL toolchain usage lease: " ^ msg)
    in
      held_usage_leases := (k, lease) :: !held_usage_leases
    end

(* GC retention is measured from the last-used marker's mtime. *)
fun touch_last_used k = write_file (last_used_for_key k) "" handle IO.Io _ => ()

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
    val run_command = run_mutation k
    val src = analyser_source_dir ()
    val material = analyser_key_material ()
  in
    if analyser_built k ak then out
    else
      (ensure_dir bindir;
       run_in_dir run_command hol
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
    val run_command = run_mutation k
    fun fetch () =
      (ensure_dir (toolchains_dir ());
       if path_exists final then remove_tree run_command final else ();
       ensure_dir final;
       run_in_dir run_command final ("git clone " ^ quote (#git req) ^ " " ^ quote hol);
       run_in_dir run_command hol ("git checkout --detach " ^ quote (#rev req)))
    fun build () =
      let
        val _ = fetch ()
        val hol_source = hol_source_identity hol (hol_source_files hol)
      in
        run_in_dir run_command hol (quote (poly_command ()) ^ " --script tools/smart-configure.sml");
        run_in_dir run_command hol
          ("bin/build " ^ effective_build_args (#kernel_variant req) hol);
        if built hol then () else die ("HOL build did not produce bin/hol, bin/Holmake, bin/build, and bin/hol.state in " ^ hol);
        generate_hol_source_manifest k;
        if clean k hol then () else die ("HOL build left dirty checkout: " ^ hol ^ "\n" ^ dirty_status k hol);
        write_file (manifest_for_key k) (material ^ "\nkey=" ^ k ^ "\n");
        write_file (theory_toolchain_for_key k) (theory_toolchain_text (#kernel_variant req) hol_source);
        write_file (ok_for_key k) "ok\n";
        hol
      end
  in
    build () handle e => (remove_tree run_command final; raise e)
  end

fun wait_test_gate variable =
  case OS.Process.getEnv variable of
      NONE => ()
    | SOME path => ignore (HolbuildFileLock.read_text path)

fun platform_value command =
  trim (command_output command) handle Error _ => "unavailable"

(* HOL's configure records its build directory as getcwd reports it, with
   symlinks resolved, and bakes it into executables, heaps and sigobj links.
   The archive identity therefore names the physical path, so cache roots
   reached through different symlinks share an archive exactly when their
   toolchains would be installed in the same place. *)
fun physical_holdir_for_key k =
  (ensure_dir (toolchains_dir ());
   Path.concat(Path.concat(FS.fullPath (toolchains_dir ()), k), "hol"))

(* What a restored toolchain must share with the one that was published:
   - toolchain-key: how it was built and against which Poly/ML runtime
     (key_material);
   - holdir: the installation path baked into the build;
   - platform-os, platform-arch: executables and heaps are native code;
   - platform-libc: bin/hol and the Poly/ML runtime link against the host C
     library.
   The restored toolchain runs only the host's libpolyml, never bin/poly, so
   the poly executable's bytes are not part of it.  The analyser is not
   archived: it is rebuilt against the restored toolchain under its own key,
   so analyser changes do not split archives. *)
fun archive_identity k =
  String.concatWith "\n"
    [HolbuildToolchainArchive.archive_format,
     "toolchain-key=" ^ k,
     "holdir=" ^ physical_holdir_for_key k,
     "platform-os=" ^ platform_value "uname -s",
     "platform-arch=" ^ platform_value "uname -m",
     "platform-libc=" ^ platform_value "getconf GNU_LIBC_VERSION"]

fun heap_loads k =
  let
    val holdir = holdir_for_key k
    val hol = Path.concat(holdir, "bin/hol")
    val state = Path.concat(holdir, "bin/hol.state")
    val command =
      quote hol ^ " --noconfig --holstate " ^ quote state ^
      " </dev/null >/dev/null 2>&1"
  in
    OS.Process.isSuccess (OS.Process.system command)
  end

(* What a toolchain archive must hold: a working HOL build.  The source
   manifest is not required, since another holbuild version may have written
   it in a different format; finish_entry regenerates it. *)
fun complete_toolchain_contents k =
  let val holdir = holdir_for_key k
  in
    built holdir andalso
    heap_loads k andalso
    clean k holdir
  end

fun warn_restore message =
  TextIO.output(TextIO.stdErr,
    "holbuild: warning: remote HOL toolchain restore failed; building locally: " ^
    message ^ "\n")

fun warn_publish message =
  TextIO.output(TextIO.stdErr,
    "holbuild: warning: could not publish HOL toolchain to remote cache: " ^
    message ^ "\n")

fun archive_error_message error =
  case error of
      HolbuildToolchainArchive.Error message => message
    | HolbuildToolchainArchive.Rejected message => message
    | HolbuildRemoteCache.Error message => message
    | Error message => message
    | _ => General.exnMessage error

fun cleanup_restore_state k =
  let val final = entry_dir_for_key k
  in
    HolbuildToolchainArchive.cleanup_staging final;
    if path_exists final andalso not (path_exists (Path.concat(final, "build.ok"))) then
      remove_tree (run_mutation k) final
    else ()
  end

(* Rejected: the remote's archive for this identity is bad (see
   HolbuildToolchainArchive.Rejected); a local build then replaces it.
   NotRestored covers no remote, no archive, and failing to fetch one. *)
datatype restore_outcome = Restored | NotRestored | Rejected

fun restore_entry k =
  let
    val final = entry_dir_for_key k
    (* The analyser is not archived; finish_entry builds it for restored and
       locally built entries alike. *)
    fun restore url =
      let val remote = HolbuildRemoteCache.remote url
      in
        if HolbuildToolchainArchive.restore
             {remote = remote, identity = archive_identity k, final_dir = final} then
          (signal_test_lock_event "HOLBUILD_TEST_TOOLCHAIN_RENAMED";
           wait_test_gate "HOLBUILD_TEST_TOOLCHAIN_RENAMED_GATE";
           if complete_toolchain_contents k then
             (write_file (ok_for_key k) "ok\n"; Restored)
           else
             raise HolbuildToolchainArchive.Rejected
                     "restored HOL toolchain failed final validation")
        else NotRestored
      end
  in
    cleanup_restore_state k;
    case HolbuildRemoteCacheConfig.url () of
        NONE => NotRestored
      | SOME url =>
          (restore url
           handle error =>
             (cleanup_restore_state k;
              warn_restore (archive_error_message error);
              case error of
                  HolbuildToolchainArchive.Rejected _ => Rejected
                | _ => NotRestored))
  end

fun publish_entry {replace} k =
  case HolbuildRemoteCacheConfig.url () of
      NONE => ()
    | SOME url =>
        ((if path_exists (ok_for_key k) andalso complete_toolchain_contents k then
            ignore
              (HolbuildToolchainArchive.publish
                 {remote = HolbuildRemoteCache.remote url,
                  identity = archive_identity k,
                  entry_dir = entry_dir_for_key k,
                  replace = replace})
          else die "HOL toolchain is not complete enough to publish")
         handle error => warn_publish (archive_error_message error))

(* false when the legacy entry's sources cannot be listed. *)
fun generate_legacy_theory_toolchain req k =
  let val holdir = holdir_for_key k
  in
    case legacy_hol_source_files k holdir of
        NONE => false
      | SOME rels =>
          (write_file (theory_toolchain_for_key k)
             (theory_toolchain_text (#kernel_variant req) (hol_source_identity holdir rels));
           true)
  end

datatype publication = NoPublication | Publish of {replace : bool}

fun restore_or_build_entry req k =
  case restore_entry k of
      Restored => NoPublication
    | outcome =>
        (signal_test_lock_event "HOLBUILD_TEST_TOOLCHAIN_LOCAL_FALLBACK";
         wait_test_gate "HOLBUILD_TEST_TOOLCHAIN_LOCAL_FALLBACK_GATE";
         ignore (build_entry req k);
         Publish {replace = outcome = Rejected})

fun finish_entry req k =
  let
    val publication =
      if validate_entry req k then
        (signal_test_lock_event "HOLBUILD_TEST_TOOLCHAIN_REVALIDATED";
         NoPublication)
      else restore_or_build_entry req k
    val _ = if hol_source_manifest_built k then () else generate_hol_source_manifest k
    val publication =
      if theory_toolchain_built k orelse generate_legacy_theory_toolchain req k then publication
      else
        (ignore (build_entry req k); Publish {replace = false})
    (* The analyser is not archived, so its build cannot stop publication. *)
    val _ =
      case publication of
          NoPublication => ()
        | Publish replace => publish_entry replace k
    val _ = ignore (build_analyser k)
  in
    holdir_for_key k
  end

fun ensure_built_with_kernel req =
  let
    val k = key req
    val ak = analyser_key ()
    (* Lease before validating, so GC cannot remove the entry in between. *)
    val _ = hold_usage_lease k
    val holdir =
      if validate_entry req k andalso hol_source_manifest_built k andalso
         theory_toolchain_built k andalso analyser_built k ak then holdir_for_key k
      else
        let val lock = acquire_lock k
        in
          (await_mutation_quiescence k;
           finish_entry req k before release_lock lock)
          handle error => (release_lock lock; raise error)
        end
  in
    touch_last_used k;
    holdir
  end

fun ensure_built req = ensure_built_with_kernel (standard_request req)

(* Toolchain GC: installed toolchains are rebuildable cache entries, removed
   when unused for the retention period. An entry being built, restored or
   used by another holbuild process is skipped rather than waited for. *)

fun child_names dir =
  let
    val stream = FS.openDir dir
    fun loop acc =
      case FS.readDir stream of
          NONE => rev acc
        | SOME name => loop (if name = "." orelse name = ".." then acc else name :: acc)
  in
    (loop [] before FS.closeDir stream) handle e => (FS.closeDir stream; raise e)
  end
  handle OS.SysErr _ => []

fun is_toolchain_key name = size name = 40 andalso CharVector.all Char.isHexDigit name

fun remove_unlocked_tree path = remove_tree OS.Process.system path

fun last_use_time k =
  let fun mtime path = SOME (FS.modTime path) handle OS.SysErr _ => NONE
  in
    case mtime (last_used_for_key k) of
        SOME time => SOME time
      | NONE =>
          (* Entries from before last-used existed, or never completed. *)
          case mtime (ok_for_key k) of
              SOME time => SOME time
            | NONE => mtime (entry_dir_for_key k)
  end

fun entry_stale cutoff k =
  case last_use_time k of
      SOME time => Time.<(time, cutoff)
    | NONE => false

(* Renames the entry out of hol-toolchains under a non-blocking mutation lease,
   so an interrupted GC never leaves a half-deleted entry in place and a
   surviving child of a crashed builder keeps the entry busy. *)
fun retire_entry k =
  let
    val trash = Path.concat(trash_dir (), k ^ "." ^ HolbuildFileLock.current_pid_text ())
    val _ = ensure_dir (trash_dir ())
    val _ = if path_exists trash then remove_unlocked_tree trash else ()
    val script =
      String.concatWith "\n"
        ["exec 9>" ^ quote (mutation_lease_path k),
         HolbuildProcessGroup.try_lease_lock () ^ " || exit 0",
         "mv " ^ quote (entry_dir_for_key k) ^ " " ^ quote trash]
    val status = OS.Process.system ("/bin/sh -c " ^ quote script)
  in
    if not (OS.Process.isSuccess status) then
      die ("could not remove HOL toolchain cache entry: " ^ entry_dir_for_key k)
    else if path_exists trash then (remove_unlocked_tree trash; true)
    else false
  end

datatype gc_outcome = GcKept | GcRemoved | GcBusy

fun with_try_lock path f =
  case HolbuildFileLock.try_acquire_path {path = path, obsolete_kind = NONE}
       handle HolbuildFileLock.Error msg => die msg of
      NONE => GcBusy
    | SOME lock =>
        (f () before HolbuildFileLock.release lock)
        handle e => (HolbuildFileLock.release lock; raise e)

fun gc_entry cutoff k =
  (* fcntl locks never conflict within one process, so an entry this process
     uses must be skipped explicitly. *)
  if holds_usage_lease k orelse not (entry_stale cutoff k) then GcKept
  else
    case try_acquire_lock_path (lock_dir k) of
        NONE => GcBusy
      | SOME lock =>
          let
            val build_lock = ToolchainLock lock
            fun sweep () =
              (HolbuildFileLock.write_text (lock_owner_path (lock_dir k)) (lock_owner_for "gc HOL toolchain");
               with_try_lock (usage_lease_path k)
                 (fn () =>
                     if not (entry_stale cutoff k) then GcKept
                     else if retire_entry k then GcRemoved
                     else GcBusy))
          in
            (sweep () before release_lock build_lock)
            handle e => (release_lock build_lock; raise e)
          end

(* Leftovers of an interrupted toolchain GC; HolbuildCache.gc_root removes
   them with remove_unlocked_tree, then runs gc_entry over toolchain_keys. *)
fun toolchain_trash () =
  List.map (fn name => Path.concat(trash_dir (), name)) (child_names (trash_dir ()))

fun toolchain_keys () = List.filter is_toolchain_key (child_names (toolchains_dir ()))

end
