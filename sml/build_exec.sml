structure HolbuildBuildExec =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string
exception ErrorWithDebugArtifacts of string * HolbuildStatus.debug_artifacts
exception ExecutionPlanPrinted
exception RetryInvalidCheckpoint

fun detail_time_phase name f =
  if HolbuildToolchain.timing_detail_at 1 then HolbuildToolchain.time_phase name f
  else f ()

fun has_suffix suffix s =
  let
    val n = size s
    val m = size suffix
  in
    n >= m andalso String.substring(s, n - m, m) = suffix
  end

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if FS.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

fun temp_near path =
  Path.concat(Path.dir path,
              "." ^ Path.file path ^ "." ^ Path.file (FS.tmpName ()) ^ ".tmp")

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun rename_replace {old, new} =
  FS.rename {old = old, new = new}
  handle OS.SysErr _ =>
    (FS.remove new handle OS.SysErr _ => ();
     FS.rename {old = old, new = new})

fun copy_binary src dst =
  let
    val input = BinIO.openIn src
      handle e => raise Error ("could not read " ^ src ^ ": " ^ General.exnMessage e)
    val _ = ensure_parent dst
    val tmp = temp_near dst
    val output = BinIO.openOut tmp
      handle e => (BinIO.closeIn input; raise Error ("could not write " ^ dst ^ ": " ^ General.exnMessage e))
    fun close_input () = BinIO.closeIn input handle _ => ()
    fun close_output () = BinIO.closeOut output handle _ => ()
    fun loop () =
      let val chunk = BinIO.inputN(input, 65536)
      in
        if Word8Vector.length chunk = 0 then ()
        else (BinIO.output(output, chunk); loop ())
      end
  in
    (loop ();
     BinIO.closeIn input;
     BinIO.closeOut output;
     rename_replace {old = tmp, new = dst})
    handle e => (close_input (); close_output (); remove_file tmp; raise e)
  end

fun read_text path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_text path text =
  let
    val _ = ensure_parent path
    val tmp = temp_near path
    val output = TextIO.openOut tmp
      handle e => raise Error ("could not write " ^ path ^ ": " ^ General.exnMessage e)
    fun close_output () = TextIO.closeOut output handle _ => ()
  in
    (TextIO.output(output, text);
     TextIO.closeOut output;
     rename_replace {old = tmp, new = path})
    handle e => (close_output (); remove_file tmp; raise e)
  end

fun replace_all needle replacement text =
  let
    val needle_len = size needle
    val text_len = size text
    fun loop i acc =
      if i >= text_len then String.concat (rev acc)
      else if i + needle_len <= text_len andalso
              String.substring(text, i, needle_len) = needle then
        loop (i + needle_len) (replacement :: acc)
      else
        loop (i + 1) (String.str (String.sub(text, i)) :: acc)
  in
    if needle = "" then text else loop 0 []
  end

fun rewrite_all replacements text =
  List.foldl (fn ((old_text, new_text), current) => replace_all old_text new_text current)
             text replacements

fun copy_rewriting_path {src, dst, replacements} =
  write_text dst (rewrite_all replacements (read_text src))

fun source_file node = #source_path (HolbuildBuildPlan.source_of node)
fun source_artifacts node = #artifacts (HolbuildBuildPlan.source_of node)
fun source_policy node = #policy (HolbuildBuildPlan.source_of node)
fun source_deps node = HolbuildBuildPlan.deps_of node
fun logical_name node = HolbuildBuildPlan.logical_name node
fun package node = HolbuildBuildPlan.package node
fun cache_enabled node = HolbuildProject.action_cache_enabled (source_policy node)
fun always_reexecute node = HolbuildProject.action_always_reexecute (source_policy node)

fun one_with_suffix suffix paths =
  case List.filter (has_suffix suffix) paths of
      [path] => path
    | [] => raise Error ("missing expected " ^ suffix ^ " output")
    | _ => raise Error ("multiple " ^ suffix ^ " outputs")

fun script_base node =
  let val name = Path.file (source_file node)
  in HolbuildSourceIndex.drop_suffix ".sml" name end

fun write_manifest path lines = write_text path (String.concatWith "\n" lines ^ "\n")

fun hfs_remapped_path path = Path.concat(Path.concat(Path.dir path, ".hol/objs"), Path.file path)

fun write_object_manifest path lines =
  (write_manifest path lines;
   write_manifest (hfs_remapped_path path) lines)

fun dependency_sml dep = one_with_suffix ".sml" (#generated (source_artifacts dep))
fun dependency_sig dep = one_with_suffix ".sig" (#generated (source_artifacts dep))

fun runtime_helper_path () =
  Path.concat(HolbuildRuntimePaths.source_root, "sml/holbuild_runtime.sml")

fun runtime_line () =
  "use " ^ HolbuildToolchain.sml_string (runtime_helper_path ()) ^ ";"

fun load_theory_line name = "HolbuildRuntime.load " ^ HolbuildToolchain.sml_string name ^ ";"

fun use_generated_lines dep =
  ["HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (dependency_sig dep) ^ ";",
   "HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (dependency_sml dep) ^ ";"]

fun drop_suffix suffix path =
  if has_suffix suffix path then String.substring(path, 0, size path - size suffix)
  else raise Error ("expected suffix " ^ suffix ^ " in " ^ path)

fun object_stem_with_suffix suffix dep =
  drop_suffix suffix (one_with_suffix suffix (#objects (source_artifacts dep)))

fun loadable_project_dep dep =
  case #kind (HolbuildBuildPlan.source_of dep) of
      HolbuildSourceIndex.Sig => false
    | _ => true

fun load_stem dep =
  case #kind (HolbuildBuildPlan.source_of dep) of
      HolbuildSourceIndex.TheoryScript =>
        drop_suffix ".uo" (one_with_suffix (HolbuildBuildPlan.logical_name dep ^ ".uo")
                                          (#objects (source_artifacts dep)))
    | HolbuildSourceIndex.Sml => object_stem_with_suffix ".uo" dep
    | HolbuildSourceIndex.Sig => object_stem_with_suffix ".ui" dep

fun add_unique_string (value, values) =
  if List.exists (fn existing => existing = value) values then values else value :: values

fun unique_strings values = rev (List.foldl add_unique_string [] values)

fun project_load_stems deps =
  unique_strings (map load_stem (List.filter loadable_project_dep deps))

fun theory_project_dep dep =
  #kind (HolbuildBuildPlan.source_of dep) = HolbuildSourceIndex.TheoryScript

fun project_theory_load_stems deps =
  unique_strings (map load_stem (List.filter theory_project_dep deps))

fun fakeload_line name = "Meta.fakeload " ^ HolbuildToolchain.sml_string name ^ ";"

fun load_project_line dep = "HolbuildRuntime.load " ^ HolbuildToolchain.sml_string dep ^ ";"

fun project_preload_lines dep =
  case #kind (HolbuildBuildPlan.source_of dep) of
      HolbuildSourceIndex.TheoryScript => [load_project_line (load_stem dep)]
    | HolbuildSourceIndex.Sml => [load_project_line (load_stem dep)]
    | HolbuildSourceIndex.Sig => []

fun checkpoint_ok_path path = HolbuildCheckpointStore.ok_path path

fun remove_checkpoint path = HolbuildCheckpointStore.remove_checkpoint path

fun checkpoint_ok_v1 () = HolbuildCheckpointStore.ok_v1 ()

fun checkpoint_ok_text kind fields = HolbuildCheckpointStore.ok_text kind fields

fun checkpoint_save_runtime_helper_path () =
  Path.concat(HolbuildRuntimePaths.source_root, "sml/checkpoint_save_runtime.sml")

fun checkpoint_save_runtime_line () =
  "HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (checkpoint_save_runtime_helper_path ()) ^ ";"

(* PolyML child heaps remember their parent-chain filenames. The shared runtime
   helper saves checkpoints directly to the final .save path and publishes .ok
   metadata last via an atomic .ok.tmp rename. *)
fun save_heap_line {label, share_common_data, output, ok_text} =
  String.concat
    ["val _ = HolbuildCheckpointSaveRuntime.save_checkpoint {label = ",
     HolbuildToolchain.sml_string label,
     ", default_share = ", if share_common_data then "true" else "false",
     ", path = ", HolbuildToolchain.sml_string output,
     ", ok_text = ", HolbuildToolchain.sml_string ok_text,
     ", depth = HolbuildRuntime.save_hierarchy_depth ()};"]

fun direct_external_loads plan node =
  unique_strings
    (HolbuildBuildPlan.direct_external_theories plan node @
     HolbuildBuildPlan.direct_external_libs plan node)

fun preload_lines plan node =
  let
    val external_deps = HolbuildBuildPlan.direct_external_theories plan node
    val external_libs = HolbuildBuildPlan.direct_external_libs plan node
    val project_deps = HolbuildBuildPlan.direct_project_deps plan node
  in
    map load_theory_line external_deps @
    map load_project_line external_libs @
    List.concat (map project_preload_lines project_deps)
  end

fun write_preload plan node deps_loaded deps_ok path =
  let
    val lines = runtime_line () ::
                (preload_lines plan node @
                 [checkpoint_save_runtime_line (),
                  save_heap_line {label = "deps_loaded", share_common_data = true,
                                  output = deps_loaded, ok_text = deps_ok}])
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

fun write_plain_preload plan node path =
  write_text path (String.concatWith "\n" (runtime_line () :: preload_lines plan node) ^ "\n")

fun generated_metadata_report_lines {theory_name, parents_report, mldeps_report} =
  let
    val parent_lines =
      case parents_report of
          NONE => []
        | SOME report_path =>
            ["val _ = HolbuildRuntime.write_parent_report " ^ HolbuildToolchain.sml_string report_path ^ ";"]
    val mldep_lines =
      case mldeps_report of
          NONE => []
        | SOME report_path =>
            ["val _ = HolbuildRuntime.write_mldeps_report " ^ HolbuildToolchain.sml_string report_path ^ ";"]
  in
    parent_lines @ mldep_lines
  end

fun export_theory_if_needed_line sig_path =
  "val _ = HolbuildRuntime.export_theory_if_needed " ^ HolbuildToolchain.sml_string sig_path ^ ";"

fun write_manifest_line path lines =
  String.concat
    ["val _ = HolbuildRuntime.write_manifest ", HolbuildToolchain.sml_string path,
     " ", HolbuildToolchain.sml_list lines, ";"]

fun hfs_unmapped_path path =
  let
    val {dir, file} = Path.splitDirFile path
    val {dir = parent, file = leaf} = Path.splitDirFile dir
  in
    if leaf = "objs" andalso Path.file parent = ".hol" then
      Path.concat(Path.dir parent, file)
    else path
  end

fun final_context_loader_lines {theory_name, sig_path, sml_path, parents_report, mldeps_report} =
  let
    val load_sig_path = hfs_unmapped_path sig_path
    val load_sml_path = hfs_unmapped_path sml_path
    val stem = drop_suffix ".sml" load_sml_path
    val ui_path = stem ^ ".ui"
    val uo_path = stem ^ ".uo"
  in
    generated_metadata_report_lines {theory_name = theory_name,
                                     parents_report = parents_report,
                                     mldeps_report = mldeps_report} @
    [export_theory_if_needed_line sig_path,
     write_manifest_line ui_path [load_sig_path],
     write_manifest_line uo_path [load_sml_path],
     "HolbuildRuntime.load " ^ HolbuildToolchain.sml_string stem ^ ";"]
  end

fun write_final_context_loader {theory_name, sig_path, sml_path, output, path, parents_report, mldeps_report} =
  let
    val lines = final_context_loader_lines {theory_name = theory_name,
                                            sig_path = sig_path, sml_path = sml_path,
                                            parents_report = parents_report,
                                            mldeps_report = mldeps_report} @
                [checkpoint_save_runtime_line (),
                 save_heap_line {label = "final_context", share_common_data = true,
                                 output = output, ok_text = checkpoint_ok_v1 ()}]
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

fun write_plain_final_context_loader {theory_name, sig_path, sml_path, path, parents_report, mldeps_report} =
  write_text path (String.concatWith "\n"
                     (final_context_loader_lines {theory_name = theory_name,
                                                  sig_path = sig_path, sml_path = sml_path,
                                                  parents_report = parents_report,
                                                  mldeps_report = mldeps_report}) ^ "\n")

fun generated_outputs node =
  let val generated = #generated (source_artifacts node)
  in {sig_path = one_with_suffix ".sig" generated,
      sml_path = one_with_suffix ".sml" generated}
  end

fun theory_outputs node =
  let
    val {sig_path, sml_path, ...} = generated_outputs node
    val data_path = one_with_suffix ".dat" (#theory_data (source_artifacts node))
    val objects = #objects (source_artifacts node)
  in
    {sig_path = sig_path, sml_path = sml_path, data_path = data_path,
     script_uo = one_with_suffix (script_base node ^ ".uo") objects,
     theory_ui = one_with_suffix ".ui" objects,
     theory_uo = one_with_suffix (logical_name node ^ ".uo") objects}
  end

fun project_artifact_root project = HolbuildProject.artifact_root project

fun stage_dir (project : HolbuildProject.t) input_key =
  Path.concat(Path.concat(project_artifact_root project, ".holbuild/stage"), input_key)

fun log_dir (project : HolbuildProject.t) = Path.concat(project_artifact_root project, ".holbuild/logs")

fun current_log_dir project node =
  Path.concat(Path.concat(Path.concat(log_dir project, "current"), package node), logical_name node)

fun current_build_log project node = Path.concat(current_log_dir project node, "build.log")
fun current_checkpoint_failure_log project node = Path.concat(current_log_dir project node, "instrumented-failure.log")
fun current_proof_trace_log project node = Path.concat(current_log_dir project node, "proof-trace.log")

fun staged_theory_file stage node ext = Path.concat(Path.concat(stage, ".hol/objs"), logical_name node ^ ext)
fun staged_dat_reference stage node = Path.concat(stage, logical_name node ^ ".dat")

fun canonical_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun absolute_path path =
  if Path.isAbsolute path then canonical_path path
  else Path.concat(FS.fullPath (Path.dir path), Path.file path) handle _ => path

fun drop_trailing_newline text =
  if size text > 0 andalso String.sub(text, size text - 1) = #"\n" then
    String.substring(text, 0, size text - 1)
  else text

fun has_space text =
  let
    fun loop i = i < size text andalso (Char.isSpace (String.sub(text, i)) orelse loop (i + 1))
  in
    loop 0
  end

fun read_holpath_name dir =
  let
    val path = Path.concat(dir, ".holpath")
    val text = read_text path
    val trimmed = drop_trailing_newline text
  in
    if trimmed = "" orelse has_space trimmed then NONE else SOME trimmed
  end
  handle _ => NONE

fun path_under_dir path dir =
  path <> dir andalso String.isPrefix (dir ^ "/") path

fun holpath_reference path dir name =
  if path_under_dir path dir then
    SOME ("$(" ^ name ^ ")/" ^ String.extract(path, size dir + 1, NONE))
  else NONE

fun holpath_stage_references path =
  let
    val canonical = canonical_path path
    fun loop dir refs =
      let
        val dir' = canonical_path dir
        val refs' =
          case read_holpath_name dir' of
              SOME name =>
                (case holpath_reference canonical dir' name of
                     SOME path_ref => path_ref :: refs
                   | NONE => refs)
            | NONE => refs
        val parent = Path.dir dir'
      in
        if parent = dir' then refs' else loop parent refs'
      end
  in
    loop (Path.dir canonical) []
  end

fun stage_dat_references stage node =
  let val path = staged_dat_reference stage node
  in unique_strings (path :: holpath_stage_references path) end

fun stage_dat_replacements stage node final_dat =
  map (fn path_ref => (path_ref, final_dat)) (stage_dat_references stage node)

fun checkpoint_base (project : HolbuildProject.t) node =
  Path.concat(Path.concat(Path.concat(project_artifact_root project, ".holbuild/checkpoints"),
                          HolbuildBuildPlan.package node),
              HolbuildBuildPlan.relative_path node)

fun deps_checkpoint_root project node = checkpoint_base project node ^ ".deps"

fun deps_loaded_path project node deps_key =
  Path.concat(Path.concat(deps_checkpoint_root project node, deps_key), "deps_loaded.save")

fun theorem_checkpoint_root project node = checkpoint_base project node ^ ".theorems"

fun theorem_checkpoints_for_deps_root project node deps_key =
  Path.concat(theorem_checkpoint_root project node, deps_key)

fun theorem_checkpoint_dir project node deps_key proof_engine prefix_hash =
  Path.concat(Path.concat(theorem_checkpoints_for_deps_root project node deps_key, proof_engine), prefix_hash)

fun declaration_checkpoint_root project node = checkpoint_base project node ^ ".decls"

fun declaration_checkpoints_for_deps_root project node deps_key =
  Path.concat(declaration_checkpoint_root project node, deps_key)

fun declaration_checkpoint_dir project node deps_key proof_engine prefix_hash =
  Path.concat(Path.concat(declaration_checkpoints_for_deps_root project node deps_key, proof_engine), prefix_hash)

fun final_context_path project node = checkpoint_base project node ^ ".final_context.save"

fun remove_legacy_checkpoint_family project node =
  let
    val base = checkpoint_base project node
    val dir = Path.dir base
    val prefix = Path.file base ^ "."
    fun checkpoint_entry name =
      String.isPrefix prefix name andalso
      (has_suffix ".save" name orelse has_suffix ".save.ok" name)
    fun remove_entry name =
      if checkpoint_entry name then remove_file (Path.concat(dir, name)) else ()
    val stream = FS.openDir dir
      handle OS.SysErr _ => raise Fail "holbuild checkpoint directory missing"
    fun close () = FS.closeDir stream handle _ => ()
    fun loop () =
      case FS.readDir stream of
          NONE => ()
        | SOME name => (remove_entry name; loop ())
  in
    (loop (); close ())
    handle e => (close (); raise e)
  end
  handle Fail "holbuild checkpoint directory missing" => ()

fun remove_checkpoint_tree path =
  if FS.access(path, []) handle OS.SysErr _ => false then
    ignore (OS.Process.system ("rm -rf " ^ HolbuildToolchain.quote path))
  else ()

fun remove_theorem_checkpoints_for_deps project node deps_key =
  remove_checkpoint_tree (theorem_checkpoints_for_deps_root project node deps_key)

fun remove_declaration_checkpoints_for_deps project node deps_key =
  remove_checkpoint_tree (declaration_checkpoints_for_deps_root project node deps_key)

fun remove_deps_checkpoint_family project node deps_key deps_loaded =
  (* Delete source-context descendants before deleting/replacing the deps parent.
     A deps heap path is stable for a deps_key, so surviving descendants must
     never outlive deletion of that parent path. *)
  (remove_theorem_checkpoints_for_deps project node deps_key;
   remove_declaration_checkpoints_for_deps project node deps_key;
   remove_checkpoint deps_loaded)

fun remove_checkpoint_family project node =
  (remove_legacy_checkpoint_family project node;
   remove_checkpoint_tree (theorem_checkpoint_root project node);
   remove_checkpoint_tree (declaration_checkpoint_root project node);
   remove_checkpoint_tree (deps_checkpoint_root project node))

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun remove_tree path =
  ignore (OS.Process.system ("rm -rf " ^ HolbuildToolchain.quote path))

fun remove_tree_if_exists path =
  if path_exists path then remove_tree path else ()

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

fun failed_prefix_ok_artifact path =
  has_suffix "_failed_prefix.save.ok" path andalso path_exists (drop_suffix ".ok" path)

fun contains_failed_prefix_ok path =
  if not (path_exists path) then false
  else if FS.isDir path handle OS.SysErr _ => false then
    List.exists contains_failed_prefix_ok (children path)
  else failed_prefix_ok_artifact path

fun node_has_failed_prefix_checkpoint project node =
  contains_failed_prefix_ok (theorem_checkpoint_root project node)

fun stale cutoff path = Time.<(FS.modTime path, cutoff) handle OS.SysErr _ => false

fun retention_cutoff days =
  if days < 0 then raise Error "retention days must be non-negative"
  else Time.-(Time.now(), Time.fromSeconds (IntInf.fromInt (days * 86400)))

fun remove_stale_children cutoff dir =
  List.foldl
    (fn (path, removed) =>
        if stale cutoff path then (remove_tree path; removed + 1) else removed)
    0
    (children dir)

fun env_bool name default =
  case OS.Process.getEnv name of
      SOME "1" => true
    | SOME "true" => true
    | SOME "yes" => true
    | SOME "0" => false
    | SOME "false" => false
    | SOME "no" => false
    | _ => default

fun with_project_lock project command f =
  HolbuildProjectLock.with_lock project command f
  handle HolbuildProjectLock.Error msg => raise Error msg

fun project_state_dir (project : HolbuildProject.t) name =
  Path.concat(Path.concat(project_artifact_root project, ".holbuild"), name)

fun checkpoint_clean_artifact path =
  has_suffix ".save" path orelse has_suffix ".save.ok" path orelse
  has_suffix ".save.tmp" path orelse has_suffix ".save.ok.tmp" path orelse
  has_suffix ".save.bak" path orelse has_suffix ".save.ok.bak" path orelse
  has_suffix ".meta" path

fun remove_empty_dir path = FS.rmDir path handle OS.SysErr _ => ()

fun protected_checkpoint_artifact_roots base =
  [base ^ ".theorems", base ^ ".decls", base ^ ".deps",
   base ^ ".final_context.save"]

fun path_in_or_at_dir path dir =
  path = dir orelse path_under_dir path dir

fun protected_empty_checkpoint_dir protected_bases path =
  List.exists
    (fn base => List.exists (path_in_or_at_dir path)
                            (protected_checkpoint_artifact_roots base))
    protected_bases

fun remove_empty_dirs_excluding protected_bases dir =
  if not (path_exists dir) orelse not (FS.isDir dir handle OS.SysErr _ => false) then ()
  else if protected_empty_checkpoint_dir protected_bases dir then ()
  else
    (List.app (remove_empty_dirs_excluding protected_bases) (children dir);
     if protected_empty_checkpoint_dir protected_bases dir then () else remove_empty_dir dir)

fun remove_empty_dirs dir = remove_empty_dirs_excluding [] dir

fun checkpoint_save_artifact_base path =
  if has_suffix ".save.ok.tmp" path then SOME (drop_suffix ".ok.tmp" path)
  else if has_suffix ".save.ok.bak" path then SOME (drop_suffix ".ok.bak" path)
  else if has_suffix ".save.ok" path then SOME (drop_suffix ".ok" path)
  else if has_suffix ".save.tmp" path then SOME (drop_suffix ".tmp" path)
  else if has_suffix ".save.bak" path then SOME (drop_suffix ".bak" path)
  else if has_suffix ".meta" path then SOME (drop_suffix ".meta" path)
  else if has_suffix ".save" path then SOME path
  else NONE

fun checkpoint_marker_base path =
  let val name = Path.file path
  in
    if has_suffix ".deps" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".deps" name))
    else if has_suffix ".theorems" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".theorems" name))
    else if has_suffix ".decls" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".decls" name))
    else if has_suffix ".final_context.save.ok.tmp" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".final_context.save.ok.tmp" name))
    else if has_suffix ".final_context.save.ok.bak" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".final_context.save.ok.bak" name))
    else if has_suffix ".final_context.save.ok" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".final_context.save.ok" name))
    else if has_suffix ".final_context.save.tmp" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".final_context.save.tmp" name))
    else if has_suffix ".final_context.save.bak" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".final_context.save.bak" name))
    else if has_suffix ".final_context.save.meta" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".final_context.save.meta" name))
    else if has_suffix ".final_context.save.prefix" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".final_context.save.prefix" name))
    else if has_suffix ".final_context.save" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".final_context.save" name))
    else NONE
  end

fun checkpoint_family_base path =
  let
    fun marker_base current =
      case checkpoint_marker_base current of
          SOME base => SOME base
        | NONE =>
            let val parent = Path.dir current
            in if parent = current then NONE else marker_base parent end
  in
    case marker_base path of
        SOME base => SOME base
      | NONE => checkpoint_save_artifact_base path
  end

fun remove_checkpoint_family_base base =
  (remove_checkpoint_tree (base ^ ".theorems");
   remove_checkpoint_tree (base ^ ".decls");
   remove_checkpoint_tree (base ^ ".deps");
   remove_checkpoint (base ^ ".final_context.save");
   remove_checkpoint base)

type checkpoint_family = {base : string, mtime : Time.time, bytes : Position.int}

fun max_time (a, b) = if Time.<(a, b) then b else a

fun file_size path = FS.fileSize path handle OS.SysErr _ => 0

fun note_checkpoint_full_scan () =
  case OS.Process.getEnv "HOLBUILD_CHECKPOINT_SCAN_COUNTER" of
      NONE => ()
    | SOME path =>
        let
          val _ = ensure_parent path
          val out = TextIO.openAppend path
        in
          TextIO.output(out, "scan\n");
          TextIO.closeOut out
        end
        handle _ => ()

fun add_checkpoint_family_artifact (base, mtime, size) families =
  case families of
      [] => [{base = base, mtime = mtime, bytes = size}]
    | ({base = family_base, mtime = family_mtime, bytes = family_bytes} : checkpoint_family) :: rest =>
        if family_base = base then
          {base = family_base, mtime = max_time (family_mtime, mtime), bytes = family_bytes + size} :: rest
        else
          {base = family_base, mtime = family_mtime, bytes = family_bytes} ::
          add_checkpoint_family_artifact (base, mtime, size) rest

fun collect_checkpoint_families_from paths =
  let
    fun collect path families =
      if not (path_exists path) then families
      else if FS.isDir path handle OS.SysErr _ => false then
        List.foldl (fn (child, acc) => collect child acc) families (children path)
      else if checkpoint_clean_artifact path then
        case checkpoint_family_base path of
            SOME base => add_checkpoint_family_artifact
                           (base, FS.modTime path handle OS.SysErr _ => Time.zeroTime, file_size path)
                           families
          | NONE => families
      else families
  in
    List.foldl (fn (path, families) => collect path families) [] paths
  end

fun checkpoint_family_artifact_roots base =
  let val final_context = base ^ ".final_context.save"
  in
    [base ^ ".theorems",
     base ^ ".decls",
     base ^ ".deps",
     final_context,
     final_context ^ ".ok",
     final_context ^ ".tmp",
     final_context ^ ".ok.tmp",
     final_context ^ ".bak",
     final_context ^ ".ok.bak",
     final_context ^ ".meta"]
  end

fun collect_checkpoint_family base =
  List.find (fn ({base = family_base, ...} : checkpoint_family) => family_base = base)
            (collect_checkpoint_families_from (checkpoint_family_artifact_roots base))

fun collect_checkpoint_families dir =
  (note_checkpoint_full_scan ();
   if not (path_exists dir) then [] else collect_checkpoint_families_from [dir])

fun total_checkpoint_bytes families =
  List.foldl (fn ({bytes, ...} : checkpoint_family, total) => total + bytes) (0 : Position.int) families

type checkpoint_index =
  {dir : string,
   families : checkpoint_family list,
   total_bytes : Position.int}

val checkpoint_index_header = "holbuild-checkpoint-index-v1"

fun checkpoint_index_path dir = Path.concat(dir, ".index-v1")

fun checkpoint_index_tmp_path dir = Path.concat(dir, ".index-v1.tmp")

fun checkpoint_index_dirty_path dir = Path.concat(dir, ".index-dirty")

fun checkpoint_index_with_families dir families =
  {dir = dir, families = families, total_bytes = total_checkpoint_bytes families}

fun family_base_exists base families =
  List.exists (fn ({base = family_base, ...} : checkpoint_family) => family_base = base) families

fun sorted_families_by_base families =
  let
    fun insert x [] = [x]
      | insert (x as {base = x_base, ...} : checkpoint_family)
               ((y as {base = y_base, ...} : checkpoint_family) :: rest) =
          if x_base <= y_base then x :: y :: rest else y :: insert x rest
  in
    List.foldl (fn (family, sorted) => insert family sorted) [] families
  end

fun remove_index_family ({dir, families, ...} : checkpoint_index) base =
  checkpoint_index_with_families
    dir
    (List.filter (fn ({base = family_base, ...} : checkpoint_family) => family_base <> base) families)

fun insert_index_family ({dir, families, ...} : checkpoint_index)
                        (family as {base, ...} : checkpoint_family) =
  checkpoint_index_with_families
    dir
    (family :: List.filter (fn ({base = family_base, ...} : checkpoint_family) => family_base <> base) families)

fun checkpoint_family_root_exists base =
  List.exists path_exists (checkpoint_family_artifact_roots base)

fun merge_checkpoint_family_measurements index measurements =
  List.foldl
    (fn ((base, family_opt), acc) =>
        case family_opt of
            NONE => remove_index_family acc base
          | SOME family =>
              if checkpoint_family_root_exists base then insert_index_family acc family
              else remove_index_family acc base)
    index
    measurements

fun parse_index_root line =
  let val prefix = "root="
  in
    if String.isPrefix prefix line then
      String.fromString (String.extract(line, size prefix, NONE))
    else NONE
  end

fun parse_index_family_line line =
  case String.fields (fn c => c = #"\t") line of
      ["family", base_text, mtime_text, bytes_text] =>
        (case (String.fromString base_text,
               IntInf.fromString mtime_text,
               IntInf.fromString bytes_text) of
             (SOME base, SOME mtime_nanos, SOME bytes) =>
               if bytes < 0 then NONE
               else SOME ({base = base, mtime = Time.fromNanoseconds mtime_nanos, bytes = bytes} : checkpoint_family)
           | _ => NONE)
    | _ => NONE

fun read_checkpoint_index dir =
  let
    val lines = String.tokens (fn c => c = #"\n") (read_text (checkpoint_index_path dir))
    fun parse_families rows families =
      case rows of
          [] => SOME (rev families)
        | line :: rest =>
            (case parse_index_family_line line of
                 SOME (family as {base, ...} : checkpoint_family) =>
                   if path_under_dir base dir andalso not (family_base_exists base families) then
                     parse_families rest (family :: families)
                   else NONE
               | NONE => NONE)
  in
    case lines of
        header :: root_line :: rest =>
          if header <> checkpoint_index_header then NONE
          else
            (case parse_index_root root_line of
                 SOME root =>
                   if root <> dir then NONE
                   else
                     let
                       val rows =
                         case rest of
                             created_by :: family_rows =>
                               if String.isPrefix "created_by=" created_by then family_rows else rest
                           | [] => []
                     in
                       Option.map (checkpoint_index_with_families dir) (parse_families rows [])
                     end
               | NONE => NONE)
      | _ => NONE
  end
  handle _ => NONE

fun checkpoint_index_text ({dir, families, ...} : checkpoint_index) =
  let
    fun family_line ({base, mtime, bytes} : checkpoint_family) =
      String.concat
        ["family\t", String.toString base, "\t",
         IntInf.toString (Time.toNanoseconds mtime), "\t",
         IntInf.toString bytes]
  in
    String.concatWith "\n"
      ([checkpoint_index_header,
        "root=" ^ String.toString dir,
        "created_by=holbuild"] @ map family_line (sorted_families_by_base families)) ^ "\n"
  end

fun write_checkpoint_index_atomically (index as {dir, ...} : checkpoint_index) =
  let
    val path = checkpoint_index_path dir
    val tmp = checkpoint_index_tmp_path dir
    val _ = ensure_parent path
    val output = TextIO.openOut tmp
      handle e => raise Error ("could not write " ^ path ^ ": " ^ General.exnMessage e)
    fun close_output () = TextIO.closeOut output handle _ => ()
  in
    (TextIO.output(output, checkpoint_index_text index);
     TextIO.closeOut output;
     rename_replace {old = tmp, new = path})
    handle e => (close_output (); remove_file tmp; raise e)
  end

fun rebuild_checkpoint_index dir =
  checkpoint_index_with_families dir (collect_checkpoint_families dir)

fun load_or_rebuild_checkpoint_index dir =
  case read_checkpoint_index dir of
      SOME index => index
    | NONE =>
        let
          val index = rebuild_checkpoint_index dir
          val _ = write_checkpoint_index_atomically index
        in
          index
        end

fun checkpoint_bytes dir = total_checkpoint_bytes (collect_checkpoint_families dir)

fun bytes_text bytes = IntInf.toString bytes

fun gb_decimal_text bytes =
  let
    val tenths = (bytes * 10 + 536870912) div 1073741824
    val whole = tenths div 10
    val frac = tenths mod 10
  in
    IntInf.toString whole ^ "." ^ IntInf.toString frac
  end

fun sort_families_by_mtime_ascending families =
  let
    fun split xs =
      let
        fun loop left right rest =
          case rest of
              [] => (left, right)
            | [x] => (x :: left, right)
            | x :: y :: more => loop (x :: left) (y :: right) more
      in
        loop [] [] xs
      end
    fun merge left right =
      case (left, right) of
          ([], _) => right
        | (_, []) => left
        | ((x as {mtime = x_mtime, ...} : checkpoint_family) :: xs,
           (y as {mtime = y_mtime, ...} : checkpoint_family) :: ys) =>
            if Time.<=(x_mtime, y_mtime) then x :: merge xs right
            else y :: merge left ys
    fun sort xs =
      case xs of
          [] => []
        | [_] => xs
        | _ =>
            let val (left, right) = split xs
            in merge (sort left) (sort right) end
  in
    sort families
  end

fun remove_stale_checkpoint_families cutoff dir =
  if not (path_exists dir) then 0
  else
    let
      fun remove_if_stale ({base, mtime, ...} : checkpoint_family, removed) =
        if Time.<(mtime, cutoff) then
          (remove_checkpoint_family_base base; removed + 1)
        else removed
      val removed = List.foldl remove_if_stale 0 (collect_checkpoint_families dir)
      val _ = remove_empty_dirs dir
    in
      removed
    end

val default_max_checkpoints_gb = 5

fun gb_to_bytes gb = IntInf.fromInt gb * 1073741824

fun string_member x xs = List.exists (fn y => x = y) xs

type checkpoint_eviction =
  {before_bytes : IntInf.int, after_bytes : IntInf.int,
   max_bytes : IntInf.int, evicted : int}

fun evict_from_index_excluding (index as {dir, families, total_bytes} : checkpoint_index)
                               max_bytes protected_bases =
  let
    val before_bytes = total_bytes
    val evictable = List.filter (fn ({base, ...} : checkpoint_family) =>
                                    not (string_member base protected_bases)) families
    val sorted = sort_families_by_mtime_ascending evictable
    fun evict remaining freed removed removed_bases =
      case remaining of
          [] => (freed, removed, removed_bases)
        | ({base, bytes, ...} : checkpoint_family) :: rest =>
            let
              val freed' = freed + bytes
              val removed' = removed + 1
              val removed_bases' = base :: removed_bases
              val _ = remove_checkpoint_family_base base
            in
              if before_bytes - freed' <= max_bytes then (freed', removed', removed_bases')
              else evict rest freed' removed' removed_bases'
            end
    val over_budget = not (max_bytes <= 0 orelse before_bytes <= max_bytes)
    val (freed, evicted, removed_bases) =
      if over_budget then evict sorted 0 0 [] else (0 : Position.int, 0, [])
    val families' =
      List.filter (fn ({base, ...} : checkpoint_family) => not (string_member base removed_bases)) families
    val after_bytes = before_bytes - freed
    val index' = {dir = dir, families = families', total_bytes = after_bytes}
    val _ = if over_budget then remove_empty_dirs_excluding protected_bases dir else ()
  in
    (index', {before_bytes = before_bytes, after_bytes = after_bytes,
              max_bytes = max_bytes, evicted = evicted})
  end

fun evict_oldest_checkpoints_with_stats_excluding dir max_bytes protected_bases =
  let
    val (_, eviction) =
      evict_from_index_excluding (rebuild_checkpoint_index dir) max_bytes protected_bases
  in
    eviction
  end

fun evict_oldest_checkpoints_with_stats dir max_bytes =
  evict_oldest_checkpoints_with_stats_excluding dir max_bytes []

fun checkpoint_eviction_text ({before_bytes, after_bytes, max_bytes, evicted} : checkpoint_eviction) =
  "checkpoint_gb_before=" ^ gb_decimal_text before_bytes ^
  " checkpoint_gb_after=" ^ gb_decimal_text after_bytes ^
  " checkpoint_max_gb=" ^ gb_decimal_text max_bytes ^
  " checkpoint_bytes_before=" ^ bytes_text before_bytes ^
  " checkpoint_bytes_after=" ^ bytes_text after_bytes ^
  " checkpoint_max_bytes=" ^ bytes_text max_bytes ^
  " evicted=" ^ Int.toString evicted

fun clean_project project days max_checkpoints_gb =
  let
    val cutoff = retention_cutoff days
    val checkpoint_dir = project_state_dir project "checkpoints"
    val checkpoint_bytes_initial = checkpoint_bytes checkpoint_dir
    val stage_removed = remove_stale_children cutoff (project_state_dir project "stage")
    val log_removed = remove_stale_children cutoff (project_state_dir project "logs")
    val checkpoint_removed = remove_stale_checkpoint_families cutoff checkpoint_dir
    val eviction = evict_oldest_checkpoints_with_stats checkpoint_dir (gb_to_bytes max_checkpoints_gb)
    val _ = write_checkpoint_index_atomically (rebuild_checkpoint_index checkpoint_dir)
    val _ = remove_file (checkpoint_index_dirty_path checkpoint_dir)
  in
    print ("project clean: removed stage=" ^ Int.toString stage_removed ^
           " logs=" ^ Int.toString log_removed ^
           " checkpoints=" ^ Int.toString checkpoint_removed ^
           " checkpoint_gb_initial=" ^ gb_decimal_text checkpoint_bytes_initial ^
           " checkpoint_bytes_initial=" ^ bytes_text checkpoint_bytes_initial ^
           " " ^ checkpoint_eviction_text eviction ^ "\n")
  end

fun file_exists path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun checkpoint_exists path = file_exists path andalso file_exists (checkpoint_ok_path path)

fun file_hash path = HolbuildHash.file_sha1 path

type file_hash_cache = {entries : (string, string) Binarymap.dict ref, mutex : Mutex.mutex}

fun new_file_hash_cache () =
  {entries = ref (Binarymap.mkDict String.compare), mutex = Mutex.mutex ()}

fun with_file_hash_cache_lock (cache : file_hash_cache) f =
  (Mutex.lock (#mutex cache); f () before Mutex.unlock (#mutex cache))
  handle e => (Mutex.unlock (#mutex cache); raise e)

(* Only successful hashes are memoized.  A failed hash (missing/unreadable file)
   returns NONE but is not stored, so a transient failure is retried on the next
   lookup rather than poisoning every later up-to-date check of the same path. *)
fun cached_file_hash (cache : file_hash_cache) path =
  case with_file_hash_cache_lock cache
         (fn () => Binarymap.peek (!(#entries cache), path)) of
      SOME hash => SOME hash
    | NONE =>
        (case (SOME (file_hash path) handle _ => NONE) of
             NONE => NONE
           | SOME hash =>
               with_file_hash_cache_lock cache
                 (fn () =>
                     case Binarymap.peek (!(#entries cache), path) of
                         SOME existing => SOME existing
                       | NONE =>
                           (#entries cache := Binarymap.insert (!(#entries cache), path, hash);
                            SOME hash)))

fun invalidate_cached_file_hash (cache : file_hash_cache) path =
  with_file_hash_cache_lock cache
    (fn () =>
        case Binarymap.peek (!(#entries cache), path) of
            NONE => ()
          | SOME _ => #entries cache := #1 (Binarymap.remove (!(#entries cache), path)))

fun normalize_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun is_dir path = FS.isDir path handle OS.SysErr _ => false

fun list_dir path =
  let
    val stream = FS.openDir path
      handle OS.SysErr _ => raise Error ("could not read directory: " ^ path)
    fun loop acc =
      case FS.readDir stream of
          NONE => rev acc before FS.closeDir stream
        | SOME name => loop (name :: acc)
  in
    loop [] handle e => (FS.closeDir stream; raise e)
  end

fun path_has_glob path =
  List.exists (fn c => c = #"*" orelse c = #"?") (String.explode path)

fun join root rel = if rel = "" then root else Path.concat(root, rel)

fun sort_strings xs =
  let
    fun insert x [] = [x]
      | insert x (y :: ys) =
          if String.compare(x, y) = LESS then x :: y :: ys else y :: insert x ys
  in
    List.foldl (fn (x, acc) => insert x acc) [] xs
  end

fun files_under abs rel =
  if is_dir abs then
    List.concat (map (fn name => files_under (Path.concat(abs, name)) (join rel name)) (list_dir abs))
  else if FS.access(abs, [FS.A_READ]) handle OS.SysErr _ => false then [(rel, abs)]
  else []

fun expand_extra_dep base decl =
  if path_has_glob decl then
    List.filter (fn (rel, _) => HolbuildSourceIndex.glob_match decl rel) (files_under base "")
  else
    let val abs = normalize_path (if Path.isAbsolute decl then decl else Path.concat(base, decl))
    in
      if is_dir abs then files_under abs decl
      else if FS.access(abs, [FS.A_READ]) handle OS.SysErr _ => false then [(decl, abs)]
      else raise Error ("extra dependency not found: " ^ abs)
    end

fun extra_dep_lines label base decls =
  let
    fun line decl =
      let val expanded = sort_strings (map (fn (rel, abs) => rel ^ "@" ^ file_hash abs) (expand_extra_dep base decl))
      in (label ^ "_decl=" ^ decl) :: map (fn s => label ^ "=" ^ s) expanded end
  in
    List.concat (map line decls)
  end

fun current_metadata path = SOME (read_text path) handle IO.Io _ => NONE

datatype hol_context = HolState of string

fun hol_context_path (HolState path) = path

fun hol_context_args (HolState path) = ["--holstate", path]

fun validate_hol_context context =
  let val path = hol_context_path context
  in
    if file_exists path then ()
    else
      raise Error
        (String.concat
           ["selected HOL base-state checkpoint is missing\n",
            "checkpoint: ", path, "\n",
            "checkpoint metadata is stale or the checkpoint family was partially removed; remove .holbuild/checkpoints and retry.\n"])
  end

fun tail_text path =
  if not (file_exists path) then ""
  else
    let
      val tmp = FS.tmpName ()
      val _ = OS.Process.system ("tail -n 80 " ^ HolbuildToolchain.quote path ^
                                 " > " ^ HolbuildToolchain.quote tmp ^ " 2>/dev/null")
      val text = read_text tmp handle _ => ""
      val _ = remove_file tmp
    in
      text
    end

fun current_logs_enabled () = not (HolbuildStatus.json_mode ())

fun create_current_log_link src NONE = ()
  | create_current_log_link src (SOME dst) =
      if not (current_logs_enabled ()) then ()
      else
        (ensure_parent dst;
         remove_file dst;
         ignore (OS.Process.system
           ("ln -s " ^ HolbuildToolchain.quote (absolute_path src) ^ " " ^ HolbuildToolchain.quote dst)))
        handle _ => ()

fun finalize_current_log src NONE = src
  | finalize_current_log src (SOME dst) =
      if not (current_logs_enabled ()) then src
      else (copy_binary src dst; dst) handle _ => src

fun child_log_detail path =
  if file_exists path then
    if HolbuildStatus.json_mode () then
      String.concatWith "\n"
        ["--- child log tail ---",
         tail_text path,
         "--- end child log tail ---"]
    else
      String.concatWith "\n"
        ["--- child log tail ---",
         tail_text path,
         "--- end child log tail ---",
         "child log: " ^ path]
  else if HolbuildStatus.json_mode () then
    "child log was not created"
  else
    "child log was not created: " ^ path

fun echo_child_logs () = env_bool "HOLBUILD_ECHO_CHILD_LOGS" false
fun cache_trace_enabled () = env_bool "HOLBUILD_CACHE_TRACE" false

fun cache_trace line =
  if cache_trace_enabled () then HolbuildStatus.message_stdout (line ^ "\n") else ()

fun hol_run_file_arg stage file =
  if canonical_path (Path.dir file) = canonical_path stage then Path.file file else file

fun run_hol_files_to_log tc stage workdir context files log_name current_log error_message =
  let
    val log = Path.concat(stage, log_name)
    val file_args = map (hol_run_file_arg workdir) files
    val _ = ensure_parent log
    val _ = create_current_log_link log current_log
    val status =
      HolbuildToolchain.run_in_dir_to_file workdir
        (HolbuildToolchain.hol_subcommand_argv tc "run" @ ["--noconfig"] @ hol_context_args context @ file_args)
        log
    val detail_log = finalize_current_log log current_log
  in
    if HolbuildToolchain.success status then
      if echo_child_logs () then HolbuildStatus.message_stdout (read_text log handle _ => "") else ()
    else
      raise Error (String.concatWith "\n"
        [error_message,
         child_log_detail detail_log])
  end

fun toolchain_base_context tc = HolState (HolbuildToolchain.base_state tc)

val cache_sml_token = "__HOLBUILD_THEORY_DAT_LOAD__"

fun warn msg = HolbuildStatus.message_stderr ("holbuild: warning: " ^ msg ^ "\n")

fun first_some f values =
  case values of
      [] => NONE
    | x :: xs =>
        case f x of
            SOME y => SOME y
          | NONE => first_some f xs

fun find_substring needle haystack =
  let
    val n = size needle
    val h = size haystack
    fun at i = i + n <= h andalso String.substring(haystack, i, n) = needle
    fun loop i = if i + n > h then NONE else if at i then SOME i else loop (i + 1)
  in
    if n = 0 then NONE else loop 0
  end

fun hol_state_load_failure text =
  Option.isSome (find_substring "Couldn't load HOL base-state" text)

fun selected_hol_state_missing_failure text =
  Option.isSome (find_substring "selected HOL base-state checkpoint is missing" text)

fun holbuild_runtime_missing_failure text =
  Option.isSome (find_substring "Structure (HolbuildRuntime) has not been declared" text)

fun hol_static_error_failure text =
  Option.isSome (find_substring "Static Errors" text)

(* Defensive recovery for already-invalid checkpoint artifacts. Holbuild should
   preserve parent/child heap families atomically; this path is not a substitute
   for that invariant. It keeps old/manual/interrupted artifacts from surfacing
   as source proof failures.  A stale/manual checkpoint can load as a valid
   PolyML heap while still missing holbuild's runtime prelude; retry that case
   from a fresh dependency context too. *)
fun invalid_checkpoint_retryable base_context run_context msg =
  (hol_state_load_failure msg orelse selected_hol_state_missing_failure msg orelse
   holbuild_runtime_missing_failure msg orelse hol_static_error_failure msg) andalso
  hol_context_path run_context <> hol_context_path base_context

fun theorem_context_or_end_path path
      ({context_path, end_of_proof_path, ...} : HolbuildTheoryCheckpoints.checkpoint) =
  path = context_path orelse path = end_of_proof_path

fun theorem_failed_prefix_path path
      ({failed_prefix_path, ...} : HolbuildTheoryCheckpoints.checkpoint) =
  path = failed_prefix_path

fun declaration_context_path_matches path ({context_path, ...} : HolbuildTheoryCheckpoints.declaration_checkpoint) =
  path = context_path

fun remove_source_checkpoints_for_deps project node deps_key =
  (remove_theorem_checkpoints_for_deps project node deps_key;
   remove_declaration_checkpoints_for_deps project node deps_key)

fun remove_loaded_checkpoint_descendants project node deps_key deps_loaded theorem_checkpoints declaration_checkpoints loaded_path =
  if loaded_path = deps_loaded then
    remove_deps_checkpoint_family project node deps_key deps_loaded
  else
    case List.find (theorem_failed_prefix_path loaded_path) theorem_checkpoints of
        SOME checkpoint => remove_checkpoint (#failed_prefix_path checkpoint)
      | NONE =>
          case List.find (theorem_context_or_end_path loaded_path) theorem_checkpoints of
              SOME _ => remove_source_checkpoints_for_deps project node deps_key
            | NONE =>
                case List.find (declaration_context_path_matches loaded_path) declaration_checkpoints of
                    SOME _ => remove_source_checkpoints_for_deps project node deps_key
                  | NONE => remove_checkpoint loaded_path

fun preserve_log src dst =
  if file_exists src then
    (ensure_parent dst; copy_binary src dst; SOME dst)
    handle _ => SOME src
  else NONE

fun preserve_debug_log src dst =
  if file_exists src then
    (ensure_parent dst; copy_binary src dst; SOME dst)
    handle _ => NONE
  else NONE

datatype captured_output = RetainedLog of string | EphemeralSpool of string

fun captured_output_path (RetainedLog path) = path
  | captured_output_path (EphemeralSpool path) = path

fun captured_output_retained (RetainedLog _) = true
  | captured_output_retained (EphemeralSpool _) = false

fun stage_build_output stage = Path.concat(stage, "holbuild-build.log")

fun available_output path = if file_exists path then SOME path else NONE

fun retained_or_ephemeral_output retain src dst =
  if HolbuildStatus.json_mode () then
    if retain then
      case preserve_debug_log src dst of
          SOME path => SOME (RetainedLog path)
        | NONE => Option.map EphemeralSpool (available_output src)
    else Option.map EphemeralSpool (available_output src)
  else Option.map RetainedLog (preserve_log src dst)

fun checkpoint_failure_output project node input_key stage =
  retained_or_ephemeral_output
    (HolbuildStatus.retain_debug_artifacts ())
    (stage_build_output stage)
    (current_checkpoint_failure_log project node)

fun proof_trace_output project node input_key stage =
  retained_or_ephemeral_output
    (HolbuildStatus.retain_debug_artifacts ())
    (stage_build_output stage)
    (current_proof_trace_log project node)

val large_log_warning_threshold = 65536

fun retained_log_is_large path = file_size path > Position.fromInt large_log_warning_threshold

fun retained_log_warning path =
  String.concat ["instrumented log warning: log is ", Position.toString (file_size path),
                 " bytes (>64 KiB); do not read the whole log. Use the summary above; ",
                 "only read targeted ranges if explicitly needed.\n"]

fun retained_log_reference output =
  if HolbuildStatus.json_mode () then ""
  else
    case output of
        SOME (RetainedLog path) =>
          if retained_log_is_large path then
            String.concat [retained_log_warning path, "instrumented log: ", path, "\n"]
          else
            String.concat ["instrumented log: ", path, "\n"]
      | _ => ""

fun captured_output_path_option output = Option.map captured_output_path output

fun captured_output_has_retained_log output =
  not (HolbuildStatus.json_mode ()) andalso
  (case output of SOME captured => captured_output_retained captured | NONE => false)

fun captured_output_debug_artifacts output =
  if not (HolbuildStatus.json_mode ()) then HolbuildStatus.no_debug_artifacts
  else
    case output of
        SOME (RetainedLog path) => {log = SOME path}
      | _ => HolbuildStatus.no_debug_artifacts

fun error_with_captured_output message output =
  let val artifacts = captured_output_debug_artifacts output
  in
    if HolbuildStatus.debug_artifacts_empty artifacts then Error message
    else ErrorWithDebugArtifacts (message, artifacts)
  end

fun cleanup_json_stage stage =
  if HolbuildStatus.json_mode () then remove_tree stage else ()

fun cache_root () = HolbuildCache.cache_root ()

fun timeout_text NONE = "none"
  | timeout_text (SOME seconds) = Real.toString seconds

fun parse_timeout_text text =
  if text = "none" then SOME NONE
  else Option.map SOME (Real.fromString text)

fun timeout_satisfies requested built =
  case requested of
      NONE => true
    | SOME requested_seconds =>
        case built of
            SOME built_seconds => built_seconds <= requested_seconds
          | NONE => false

fun timeout_min (NONE, timeout) = timeout
  | timeout_min (timeout, NONE) = timeout
  | timeout_min (SOME a, SOME b) = SOME (Real.min(a, b))

fun timeout_equal (NONE, NONE) = true
  | timeout_equal (SOME a, SOME b) = Real.== (a, b)
  | timeout_equal _ = false

(* Older cache/checkpoint/action metadata predates explicit proof-timeout
   fields. Those artifacts were produced under the historical CLI default. *)
val legacy_default_proof_timeout = SOME 2.5

fun legacy_proof_timeout lines field_name =
  let
    val prefix = field_name ^ "="
    fun line_timeout line =
      if String.isPrefix prefix line then
        parse_timeout_text (String.extract(line, size prefix, NONE))
      else NONE
  in
    case first_some line_timeout lines of
        SOME timeout => timeout
      | NONE => legacy_default_proof_timeout
  end

fun file_hash_matches path hash =
  file_exists path andalso file_hash path = hash
  handle _ => false

fun cache_blob root path =
  let
    val hash = file_hash path
  in
    case HolbuildCache.publish_blob root {hash = hash, src = path} of
        HolbuildCacheBackend.Published => hash
      | HolbuildCacheBackend.AlreadyPresent => hash
      | HolbuildCacheBackend.Conflict detail => raise Error ("could not publish cache blob " ^ hash ^ ": " ^ detail)
      | HolbuildCacheBackend.Skipped => hash
  end

fun cache_manifest_text {input_key, sig_hash, sml_hash, dat_hash, parents, mldeps, proof_timeout} =
  String.concatWith "\n"
    (["holbuild-cache-action-v3",
      "input_key=" ^ input_key,
      "kind=theory",
      "proof-timeout=" ^ timeout_text proof_timeout,
      "load-metadata-v1"] @
     map (fn parent => "parent " ^ parent) parents @
     map (fn dep => "mldep " ^ dep) mldeps @
     ["blob sig " ^ sig_hash,
      "blob sml " ^ sml_hash,
      "blob dat " ^ dat_hash]) ^ "\n"

fun cache_manifest_lines text = String.tokens (fn c => c = #"\n") text

fun is_hex_digit c =
  (#"0" <= c andalso c <= #"9") orelse
  (#"a" <= c andalso c <= #"f") orelse
  (#"A" <= c andalso c <= #"F")

fun all_chars pred text =
  let
    fun loop i = i >= size text orelse (pred (String.sub(text, i)) andalso loop (i + 1))
  in
    loop 0
  end

fun valid_sha1_text text = size text = 40 andalso all_chars is_hex_digit text

fun require_sha1 role hash =
  if valid_sha1_text hash then hash
  else raise Error ("cache manifest invalid " ^ role ^ " blob hash: " ^ hash)

fun known_blob_role role = role = "sig" orelse role = "sml" orelse role = "sml-template" orelse role = "dat"

fun add_manifest_blob role hash blobs =
  if not (known_blob_role role) then
    raise Error ("cache manifest unknown blob role: " ^ role)
  else if List.exists (fn (role', _) => role' = role) blobs then
    raise Error ("cache manifest duplicate blob role: " ^ role)
  else
    (role, require_sha1 role hash) :: blobs

fun blob_from_manifest role blobs =
  case List.find (fn (role', _) => role' = role) blobs of
      SOME (_, hash) => hash
    | NONE => raise Error ("cache manifest missing blob role: " ^ role)

fun sml_blob_from_manifest blobs =
  case List.find (fn (role, _) => role = "sml") blobs of
      SOME (_, hash) => hash
    | NONE => blob_from_manifest "sml-template" blobs

fun transient_stage_mldep dep = String.isSubstring "/.holbuild/stage/" dep

fun valid_mldep_name dep =
  dep <> "" andalso all_chars (fn c => not (Char.isSpace c)) dep

fun reject_transient_cache_mldeps mldeps =
  case List.find transient_stage_mldep mldeps of
      SOME dep => raise Error ("cache manifest contains transient stage mldep: " ^ dep)
    | NONE => ()

fun transient_stage_mldep_in_manifest text =
  first_some
    (fn line =>
        case String.tokens Char.isSpace line of
            ["mldep", dep] => if transient_stage_mldep dep then SOME dep else NONE
          | _ => NONE)
    (cache_manifest_lines text)

fun drop_cache_manifest_if_unchanged root input_key old_text =
  let
    val dropped = ref false
    fun drop () =
      case HolbuildCache.get_action root input_key of
          SOME current =>
            if current = old_text then
              (HolbuildCache.remove_action root input_key; dropped := true)
            else ()
        | NONE => ()
    val _ = HolbuildCache.with_action_publish_lock root input_key drop (fn () => ())
  in
    !dropped
  end

fun transient_cache_manifest_error root input_key manifest manifest_text dep =
  let
    val dropped = drop_cache_manifest_if_unchanged root input_key manifest_text
    val action = if dropped then "; deleted cache manifest" else "; cache manifest not deleted because action lock is busy or manifest changed"
  in
    raise Error ("cache manifest contains transient stage mldep: " ^ dep ^ action)
  end

fun add_mldep dep deps =
  if not (valid_mldep_name dep) then
    raise Error ("cache manifest invalid mldep: " ^ dep)
  else if List.exists (fn existing => existing = dep) deps then deps
  else dep :: deps

fun add_parent parent parents = add_mldep parent parents

fun parse_cache_manifest_line input_key line (saw_header, saw_input, saw_kind, saw_metadata, blobs, parents, mldeps) =
  if line = "holbuild-cache-action-v3" then
    if saw_header then raise Error "cache manifest duplicate header"
    else (true, saw_input, saw_kind, saw_metadata, blobs, parents, mldeps)
  else if line = "holbuild-cache-action-v2" then
    raise Error "cache manifest missing generated theory load metadata"
  else if line = "input_key=" ^ input_key then
    if saw_input then raise Error "cache manifest duplicate input key"
    else (saw_header, true, saw_kind, saw_metadata, blobs, parents, mldeps)
  else if String.isPrefix "input_key=" line then
    raise Error "cache manifest input key mismatch"
  else if line = "kind=theory" then
    if saw_kind then raise Error "cache manifest duplicate kind"
    else (saw_header, saw_input, true, saw_metadata, blobs, parents, mldeps)
  else if String.isPrefix "kind=" line then
    raise Error "cache manifest unsupported kind"
  else if line = "load-metadata-v1" then
    if saw_metadata then raise Error "cache manifest duplicate load metadata marker"
    else (saw_header, saw_input, saw_kind, true, blobs, parents, mldeps)
  else if line = "mldeps" then
    raise Error "cache manifest missing generated theory load metadata"
  else if String.isPrefix "proof-timeout=" line then
    (saw_header, saw_input, saw_kind, saw_metadata, blobs, parents, mldeps)
  else
    case String.tokens Char.isSpace line of
        ["parent", parent] => (saw_header, saw_input, saw_kind, saw_metadata, blobs, add_parent parent parents, mldeps)
      | ["mldep", dep] => (saw_header, saw_input, saw_kind, saw_metadata, blobs, parents, add_mldep dep mldeps)
      | ["blob", role, hash] => (saw_header, saw_input, saw_kind, saw_metadata, add_manifest_blob role hash blobs, parents, mldeps)
      | _ => raise Error ("cache manifest unknown line: " ^ line)

fun cache_manifest_blobs_from_lines input_key lines =
  let
    val (saw_header, saw_input, saw_kind, saw_metadata, blobs, parents, mldeps) =
      List.foldl (fn (line, state) => parse_cache_manifest_line input_key line state)
                 (false, false, false, false, [], [], []) lines
    val _ = if saw_header then () else raise Error "cache manifest missing header"
    val _ = if saw_input then () else raise Error "cache manifest missing input key"
    val _ = if saw_kind then () else raise Error "cache manifest missing kind"
    val _ = if saw_metadata then () else raise Error "cache manifest missing generated theory load metadata"
  in
    let val stable_mldeps = rev mldeps
        val stable_parents = rev parents
        val _ = reject_transient_cache_mldeps stable_mldeps
    in
      {sig_hash = blob_from_manifest "sig" blobs,
       sml_hash = sml_blob_from_manifest blobs,
       dat_hash = blob_from_manifest "dat" blobs,
       parents = stable_parents,
       mldeps = stable_mldeps}
    end
  end

fun cache_manifest_blobs root input_key =
  case HolbuildCache.get_action root input_key of
      SOME manifest_text => cache_manifest_blobs_from_lines input_key (cache_manifest_lines manifest_text)
    | NONE => raise Error ("cache manifest missing: " ^ input_key)

fun cache_manifest_proof_timeout lines = legacy_proof_timeout lines "proof-timeout"

fun cache_manifest_proof_timeout_text input_key text =
  (cache_manifest_blobs_from_lines input_key (cache_manifest_lines text);
   cache_manifest_proof_timeout (cache_manifest_lines text))

fun cache_manifest_outputs_equal input_key left right =
  let
    val left_blobs = cache_manifest_blobs_from_lines input_key (cache_manifest_lines left)
    val right_blobs = cache_manifest_blobs_from_lines input_key (cache_manifest_lines right)
  in
    #sig_hash left_blobs = #sig_hash right_blobs andalso
    #sml_hash left_blobs = #sml_hash right_blobs andalso
    #dat_hash left_blobs = #dat_hash right_blobs
  end

fun cache_entry_usable root input_key text =
  let
    val {sig_hash, sml_hash, dat_hash, ...} =
      cache_manifest_blobs_from_lines input_key (cache_manifest_lines text)
  in
    HolbuildCache.has_blob root sig_hash andalso
    HolbuildCache.has_blob root sml_hash andalso
    HolbuildCache.has_blob root dat_hash
  end
  handle _ => false

fun cache_manifest_output_summary {sig_hash, sml_hash, dat_hash, parents, mldeps} =
  String.concat
    ["sig=", sig_hash,
     " sml=", sml_hash,
     " dat=", dat_hash,
     " parents=", Int.toString (length parents),
     " mldeps=", Int.toString (length mldeps)]

fun cache_conflict_warning cache_key manifest_path subject old_manifest new_manifest =
  let
    val old_outputs =
      cache_manifest_blobs_from_lines cache_key (cache_manifest_lines old_manifest)
    val new_outputs =
      cache_manifest_blobs_from_lines cache_key (cache_manifest_lines new_manifest)
  in
    warn (String.concat
      ["cache entry already exists with different outputs for ", subject, ": ", cache_key,
       "\n  existing cache entry: ", manifest_path,
       "\n  existing outputs: ", cache_manifest_output_summary old_outputs,
       "\n  new outputs: ", cache_manifest_output_summary new_outputs])
  end
  handle _ =>
    warn ("cache entry already exists with different outputs for " ^ subject ^ ": " ^ cache_key ^
          "\n  existing cache entry: " ^ manifest_path)

fun copy_blob root hash dst =
  case HolbuildCache.fetch_blob root {hash = hash, dst = dst} of
      HolbuildCacheBackend.Hit => ()
    | HolbuildCacheBackend.Miss => raise Error ("cache blob missing: " ^ hash)
    | HolbuildCacheBackend.Corrupt detail => raise Error ("cache blob missing or corrupt: " ^ hash ^ " (" ^ detail ^ ")")

fun fs_cache_source cache : HolbuildCacheTransfer.source =
  {get_action = HolbuildFSCacheBackend.get_action cache,
   fetch_blob = HolbuildFSCacheBackend.fetch_blob cache}

fun fs_cache_destination cache : HolbuildCacheTransfer.destination =
  {put_action = HolbuildFSCacheBackend.put_action cache,
   publish_blob = HolbuildFSCacheBackend.publish_blob cache}

fun remote_cache_destination remote : HolbuildCacheTransfer.destination =
  {put_action = HolbuildRemoteCache.put_action remote,
   publish_blob = HolbuildRemoteCache.publish_blob remote}

fun remote_cache_source_with_action remote key manifest : HolbuildCacheTransfer.source =
  {get_action = fn requested => if requested = key then SOME manifest else HolbuildRemoteCache.get_action remote requested,
   fetch_blob = HolbuildRemoteCache.fetch_blob remote}

fun hydrate_remote_cache_key root key =
  case HolbuildRemoteCacheConfig.url () of
      NONE => false
    | SOME url =>
        let
          val remote = HolbuildRemoteCache.remote url
          val local_cache = HolbuildFSCacheBackend.filesystem root
        in
          case HolbuildRemoteCache.get_action remote key of
              NONE => (cache_trace ("remote cache miss: " ^ key); false)
            | SOME manifest =>
                let
                  val _ = HolbuildFSCacheBackend.ensure_layout local_cache
                  val _ = HolbuildCacheTransfer.copy_entry
                            {source = remote_cache_source_with_action remote key manifest,
                             destination = fs_cache_destination local_cache,
                             tmp_dir = HolbuildFSCacheBackend.tmp_dir local_cache}
                            key
                in
                  cache_trace ("remote cache hydrated: " ^ key);
                  true
                end
        end
        handle e =>
          (warn ("remote cache entry unusable for " ^ key ^ ": " ^ General.exnMessage e);
           false)

fun ensure_local_cache_entry root key =
  case HolbuildCache.get_action root key of
      SOME text => SOME text
    | NONE => if hydrate_remote_cache_key root key then HolbuildCache.get_action root key else NONE

fun publish_remote_cache_key root key =
  case HolbuildRemoteCacheConfig.url () of
      NONE => ()
    | SOME url =>
        let
          val local_cache = HolbuildFSCacheBackend.filesystem root
          val remote = HolbuildRemoteCache.remote url
          val _ = HolbuildCacheTransfer.copy_entry
                    {source = fs_cache_source local_cache,
                     destination = remote_cache_destination remote,
                     tmp_dir = HolbuildFSCacheBackend.tmp_dir local_cache}
                    key
        in
          cache_trace ("remote cache published: " ^ key)
        end
        handle e => warn ("could not publish remote cache entry " ^ key ^ ": " ^ General.exnMessage e)

fun publish_remote_cache_key_if_usable root key =
  case HolbuildCache.get_action root key of
      SOME manifest => if cache_entry_usable root key manifest then publish_remote_cache_key root key else ()
    | NONE => ()

fun file_strings path =
  let
    val tmp = FS.tmpName ()
    fun cleanup () = remove_file tmp
    fun run () =
      let val status = OS.Process.system ("strings -a " ^ HolbuildToolchain.quote path ^
                                          " > " ^ HolbuildToolchain.quote tmp)
      in
        if OS.Process.isSuccess status then read_text tmp else ""
      end
  in
    (run () before cleanup ()) handle e => (cleanup (); "")
  end

fun dat_mentions_stage_key input_key staged_dat =
  let val text = file_strings staged_dat
  in
    String.isSubstring input_key text andalso
    String.isSubstring ".holbuild" text andalso
    String.isSubstring "stage" text
  end

fun path_dependent_cache_key project input_key =
  HolbuildHash.string_sha1
    (String.concatWith "\n"
       ["holbuild-path-dependent-cache-v1",
        "input_key=" ^ input_key,
        "root=" ^ canonical_path (project_artifact_root project)] ^ "\n")

fun direct_project_theory_deps plan node =
  List.filter
    (fn dep => #kind (HolbuildBuildPlan.source_of dep) = HolbuildSourceIndex.TheoryScript)
    (HolbuildBuildPlan.direct_project_deps plan node)

fun parent_output_cache_lines plan node =
  map
    (fn dep =>
        let val {data_path, ...} = theory_outputs dep
        in String.concat ["parent=", HolbuildBuildPlan.package dep, ":",
                          HolbuildBuildPlan.relative_path dep, ":",
                          logical_name dep, "@", file_hash data_path]
        end)
    (direct_project_theory_deps plan node)

fun parent_output_cache_key plan node input_key =
  case parent_output_cache_lines plan node of
      [] => input_key
    | parent_lines =>
        HolbuildHash.string_sha1
          (String.concatWith "\n"
             (["holbuild-parent-output-cache-v1", "input_key=" ^ input_key] @ parent_lines) ^ "\n")

fun theory_cache_keys project plan node input_key =
  let val context_key = parent_output_cache_key plan node input_key
  in unique_strings [context_key, path_dependent_cache_key project context_key] end

fun cache_warning_subject node =
  String.concat [logical_name node, " (", source_file node, ")"]

fun publish_cache_manifest root cache_key subject staged_sig published_sml staged_dat cache_parents cache_mldeps proof_timeout =
  let
    val manifest_path = HolbuildCache.action_manifest root cache_key
    val sig_hash = cache_blob root staged_sig
    val sml_hash = cache_blob root published_sml
    val dat_hash = cache_blob root staged_dat
    fun manifest_with timeout =
      cache_manifest_text {input_key = cache_key, sig_hash = sig_hash,
                           sml_hash = sml_hash,
                           dat_hash = dat_hash,
                           parents = cache_parents,
                           mldeps = cache_mldeps,
                           proof_timeout = timeout}
    val manifest = manifest_with proof_timeout
    val existing = HolbuildCache.get_action root cache_key
    fun write_manifest text = HolbuildCache.write_action root {key = cache_key, text = text}
    fun put_new_manifest text =
      case HolbuildCache.put_action root HolbuildCacheBackend.PutIfAbsentOrSame {key = cache_key, text = text} of
          HolbuildCacheBackend.Published => ()
        | HolbuildCacheBackend.AlreadyPresent => HolbuildCache.touch_action root cache_key
        | HolbuildCacheBackend.Conflict detail => raise Error ("cache manifest publish conflict: " ^ detail)
        | HolbuildCacheBackend.Skipped => ()
    fun publish_same_outputs old =
      let val old_timeout = cache_manifest_proof_timeout_text cache_key old
          val best_timeout = timeout_min (old_timeout, proof_timeout)
      in
        if timeout_equal (old_timeout, best_timeout) then HolbuildCache.touch_action root cache_key
        else write_manifest (manifest_with best_timeout)
      end
  in
    case existing of
        SOME old =>
          if old = manifest then HolbuildCache.touch_action root cache_key
          else if cache_entry_usable root cache_key old then
            if cache_manifest_outputs_equal cache_key old manifest then publish_same_outputs old
            else cache_conflict_warning cache_key manifest_path subject old manifest
          else
            write_manifest manifest
      | NONE => put_new_manifest manifest
  end

fun publish_theory_cache project plan node input_key proof_timeout staged_sig published_sml staged_dat {parents, mldeps} =
  let
    val root = cache_root ()
    val _ = HolbuildCache.ensure_layout root
    val cache_mldeps = List.filter (not o transient_stage_mldep) mldeps
    val cache_parents = parents
    val context_key = parent_output_cache_key plan node input_key
    val path_dependent = List.exists transient_stage_mldep mldeps andalso dat_mentions_stage_key context_key staged_dat
    val cache_key = if path_dependent then path_dependent_cache_key project context_key else context_key
    fun drop_stale_manifest key = HolbuildCache.remove_action root key
    val subject = cache_warning_subject node
    fun publish () =
      publish_cache_manifest root cache_key subject staged_sig published_sml staged_dat cache_parents cache_mldeps proof_timeout
    fun skip_locked_publish () = ()
  in
    ((if cache_key <> input_key then
        HolbuildCache.with_action_publish_lock root input_key (fn () => drop_stale_manifest input_key) skip_locked_publish
      else ());
     (if cache_key <> context_key then
        HolbuildCache.with_action_publish_lock root context_key (fn () => drop_stale_manifest context_key) skip_locked_publish
      else ());
     HolbuildCache.with_action_publish_lock root cache_key publish skip_locked_publish;
     if path_dependent then () else publish_remote_cache_key_if_usable root cache_key)
    handle e => warn ("could not publish cache entry: " ^ General.exnMessage e)
  end

fun project_node_named plan name =
  List.find (fn candidate => HolbuildBuildPlan.logical_name candidate = name)
            (HolbuildBuildPlan.universe_nodes plan)

fun mldep_load_stem plan dep =
  case project_node_named plan dep of
      SOME node => load_stem node
    | NONE => dep

fun mldep_load_stems plan mldeps = unique_strings (map (mldep_load_stem plan) mldeps)

fun stable_generated_mldeps mldeps =
  List.filter (not o transient_stage_mldep) mldeps

fun read_name_report kind path =
  let
    val names = String.tokens (fn c => c = #"\n") (read_text path)
    val _ =
      List.app
        (fn name => if valid_mldep_name name then ()
                    else raise Error ("invalid generated theory " ^ kind ^ ": " ^ name))
        names
  in
    unique_strings names
  end

fun read_generated_load_metadata {parents_report, mldeps_report} =
  {parents = read_name_report "parent" parents_report,
   mldeps = read_name_report "ML dependency" mldeps_report}

fun parent_theory_load_stem plan parent =
  let val theory_name = parent ^ "Theory"
  in
    case project_node_named plan theory_name of
        SOME node => load_stem node
      | NONE => theory_name
  end

fun parent_load_stems plan parents = unique_strings (map (parent_theory_load_stem plan) parents)

fun write_local_theory_manifests plan node {parents, mldeps} =
  let
    val {sig_path, sml_path, script_uo, theory_ui, theory_uo, ...} = theory_outputs node
    val deps = HolbuildBuildPlan.direct_project_deps plan node
    val theory_loads = parent_load_stems plan parents @
                       mldep_load_stems plan (stable_generated_mldeps mldeps)
    val script_loads = direct_external_loads plan node @ project_load_stems deps
  in
    write_object_manifest theory_ui [sig_path];
    write_object_manifest theory_uo (theory_loads @ [sml_path]);
    write_object_manifest script_uo (script_loads @ [source_file node])
  end

fun remove_failed_cache_outputs project node =
  let
    val {sig_path, sml_path, data_path, script_uo, theory_ui, theory_uo} = theory_outputs node
    (* Invalidate HOL load manifests before removing their targets.  If another
       reader observes the artifact directory while we discard a bad cache entry,
       it should see the theory as unavailable, not a .uo that still points at a
       now-missing generated Theory.sml. *)
    val manifest_paths =
      [script_uo, hfs_remapped_path script_uo,
       theory_ui, hfs_remapped_path theory_ui,
       theory_uo, hfs_remapped_path theory_uo]
    val payload_paths =
      [data_path, hfs_remapped_path data_path,
       sig_path, hfs_remapped_path sig_path,
       sml_path, hfs_remapped_path sml_path]
  in
    List.app remove_file (manifest_paths @ payload_paths);
    remove_checkpoint_family project node
  end


fun cache_key_role project plan node input_key cache_key =
  let
    val context_key = parent_output_cache_key plan node input_key
    val path_key = path_dependent_cache_key project context_key
  in
    if cache_key = input_key then "source/dependency key"
    else if cache_key = context_key then "parent-output key"
    else if cache_key = path_key then "path-dependent parent-output key"
    else "cache key"
  end

fun materialize_theory_cache_key project plan input_key requested_timeout cache_key node =
  let
    val root = cache_root ()
    val manifest = HolbuildCache.action_manifest root cache_key
    val role = cache_key_role project plan node input_key cache_key
    val manifest_text =
      case ensure_local_cache_entry root cache_key of
          SOME text => text
        | NONE => (cache_trace ("cache miss: " ^ logical_name node ^ " " ^ role ^ "=" ^ cache_key ^ " (no manifest)");
                   raise Error "cache entry not found")
    val _ =
      case transient_stage_mldep_in_manifest manifest_text of
          SOME dep => transient_cache_manifest_error root cache_key manifest manifest_text dep
        | NONE => ()
    val manifest_lines = cache_manifest_lines manifest_text
    val {sig_hash, sml_hash, dat_hash, parents, mldeps} =
      cache_manifest_blobs_from_lines cache_key manifest_lines
    val proof_timeout = cache_manifest_proof_timeout manifest_lines
    val _ =
      if timeout_satisfies requested_timeout proof_timeout then ()
      else raise Error ("cache entry built with insufficient tactic-timeout contract: built " ^
                        timeout_text proof_timeout ^ ", requested " ^ timeout_text requested_timeout)
    val {sig_path, sml_path, data_path, ...} = theory_outputs node
    fun install () =
      (copy_blob root dat_hash data_path;
       copy_blob root dat_hash (hfs_remapped_path data_path);
       copy_blob root sig_hash sig_path;
       copy_blob root sig_hash (hfs_remapped_path sig_path);
       copy_blob root sml_hash sml_path;
       write_text sml_path (replace_all cache_sml_token data_path (read_text sml_path));
       write_text (hfs_remapped_path sml_path) (read_text sml_path);
       write_local_theory_manifests plan node {parents = parents, mldeps = mldeps};
       HolbuildCache.touch_action root cache_key;
       cache_trace ("cache hit: " ^ logical_name node ^ " " ^ role ^ "=" ^ cache_key);
       true)
  in
    install ()
  end
  handle Error "cache entry not found" => false
       | e => (remove_failed_cache_outputs project node;
               cache_trace ("cache miss: " ^ logical_name node ^ " " ^
                            cache_key_role project plan node input_key cache_key ^ "=" ^ cache_key ^
                            " (" ^ General.exnMessage e ^ ")");
               warn ("cache entry unusable for " ^ logical_name node ^ ": " ^ General.exnMessage e);
               false)

fun materialize_theory_cache _ project plan input_key requested_timeout node =
  List.exists (fn cache_key => materialize_theory_cache_key project plan input_key requested_timeout cache_key node)
              (theory_cache_keys project plan node input_key)

fun metadata_path (project : HolbuildProject.t) node =
  let
    val source = HolbuildBuildPlan.source_of node
    val base = Path.concat(Path.concat(project_artifact_root project, ".holbuild/dep"), #package source)
  in
    Path.concat(base, #relative_path source ^ ".key")
  end

fun clean_theory_node project node =
  (remove_failed_cache_outputs project node;
   remove_file (metadata_path project node);
   remove_file (HolbuildBuildPlan.dependency_cache_path (HolbuildBuildPlan.source_of node)))

fun theorem_context_path project node deps_key proof_engine prefix_hash safe_name =
  Path.concat(theorem_checkpoint_dir project node deps_key proof_engine prefix_hash,
              safe_name ^ "_context.save")

fun theorem_end_of_proof_path project node deps_key proof_engine prefix_hash safe_name =
  Path.concat(theorem_checkpoint_dir project node deps_key proof_engine prefix_hash,
              safe_name ^ "_end_of_proof.save")

fun failed_prefix_checkpoint_dir project node deps_key proof_engine =
  Path.concat(theorem_checkpoint_root project node, Path.concat(Path.concat(deps_key, proof_engine), ".failed"))

fun theorem_failed_prefix_path project node deps_key proof_engine safe_name =
  Path.concat(failed_prefix_checkpoint_dir project node deps_key proof_engine,
              safe_name ^ "_failed_prefix.save")

fun declaration_context_path project node deps_key proof_engine prefix_hash safe_name =
  Path.concat(declaration_checkpoint_dir project node deps_key proof_engine prefix_hash,
              safe_name ^ "_context.save")

fun discover_theorem_boundaries source_path source_text =
  HolbuildTheorySpans.scan source_path source_text

fun discover_theorem_boundaries_recovering source_path source_text =
  HolbuildTheorySpans.scan_with_recovery source_path source_text
  handle HolbuildTheoryCheckpoints.Error msg => raise Error msg

fun discover_theorem_boundaries_strict source_path source_text =
  HolbuildTheorySpans.scan_strict source_path source_text
  handle HolbuildTheoryCheckpoints.Error msg => raise Error msg

fun discover_termination_diagnostics_strict source_path source_text =
  HolbuildTheorySpans.scan_terminations_strict source_path source_text
  handle HolbuildTheoryCheckpoints.Error msg => raise Error msg

fun discover_boundaries_and_terminations source_path source_text =
  HolbuildTheorySpans.scan_boundaries_and_terminations_recovering_strict source_path source_text
  handle HolbuildTheoryCheckpoints.Error msg => raise Error msg

fun theorem_checkpoint_key {kind, name, safe_name, boundary, deps_key, proof_engine, prefix_hash} =
  HolbuildToolchain.hash_text
    (String.concatWith "\n"
       ["holbuild-theorem-checkpoint-key-v2",
        "kind=" ^ kind,
        "name=" ^ name,
        "safe_name=" ^ safe_name,
        "boundary=" ^ Int.toString boundary,
        "deps_key=" ^ deps_key,
        "proof_engine=" ^ proof_engine,
        "prefix_key=" ^ prefix_hash] ^ "\n")

fun declaration_checkpoint_key {name, safe_name, boundary, deps_key, proof_engine, prefix_hash} =
  HolbuildToolchain.hash_text
    (String.concatWith "\n"
       ["holbuild-declaration-checkpoint-key-v1",
        "name=" ^ name,
        "safe_name=" ^ safe_name,
        "boundary=" ^ Int.toString boundary,
        "deps_key=" ^ deps_key,
        "proof_engine=" ^ proof_engine,
        "prefix_key=" ^ prefix_hash] ^ "\n")

fun proof_timeout_field proof_timeout = ("proof_timeout", timeout_text proof_timeout)

fun checkpoint_context_ok kind deps_key proof_engine proof_timeout prefix_hash checkpoint_key =
  checkpoint_ok_text kind
    [("deps_key", deps_key),
     ("proof_engine", proof_engine),
     proof_timeout_field proof_timeout,
     ("prefix_key", prefix_hash),
     ("checkpoint_key", checkpoint_key)]

fun theorem_checkpoint_ok kind deps_key proof_engine proof_timeout prefix_hash checkpoint_key =
  checkpoint_context_ok kind deps_key proof_engine proof_timeout prefix_hash checkpoint_key

fun theorem_header_hash source theorem_start tactic_start =
  HolbuildToolchain.hash_text (String.substring(source, theorem_start, tactic_start - theorem_start))

fun pre_theorem_hash source theorem_start =
  HolbuildToolchain.hash_text (String.substring(source, 0, theorem_start))

fun failed_prefix_diagnostic_key proof_engine = proof_engine ^ ":finish_goal_state_v2"

fun failed_prefix_ok proof_engine proof_timeout deps_key safe_name pre_hash header_hash =
  checkpoint_ok_text "failed_prefix"
    [("deps_key", deps_key),
     ("proof_engine", proof_engine),
     proof_timeout_field proof_timeout,
     ("safe_name", safe_name),
     ("pre_theorem_key", pre_hash),
     ("header_key", header_hash),
     ("failure_diagnostic_key", failed_prefix_diagnostic_key proof_engine)]

fun theorem_checkpoint_specs proof_engine proof_timeout project node deps_key source proof_ir_plans (boundaries : HolbuildTheoryCheckpoints.boundary list) =
  let
    fun pair (boundary, proof_ir_plan) =
      let
        val {kind, name, safe_name, theorem_start, theorem_stop, boundary = boundary_pos, tactic_start,
             tactic_end, tactic_text, has_proof_attrs, prefix_hash} = boundary
        val checkpoint_key = theorem_checkpoint_key {kind = kind, name = name, safe_name = safe_name,
                                                     boundary = boundary_pos, deps_key = deps_key,
                                                     proof_engine = proof_engine,
                                                     prefix_hash = prefix_hash}
        val header_hash = theorem_header_hash source theorem_start tactic_start
        val pre_hash = pre_theorem_hash source theorem_start
      in
        {kind = kind, name = name, safe_name = safe_name, theorem_start = theorem_start,
         theorem_stop = theorem_stop, boundary = boundary_pos,
         tactic_start = tactic_start, tactic_end = tactic_end,
         tactic_text = tactic_text, has_proof_attrs = has_proof_attrs,
         prefix_hash = prefix_hash,
         context_path = theorem_context_path project node deps_key proof_engine prefix_hash safe_name,
         context_ok = theorem_checkpoint_ok "theorem_context" deps_key proof_engine proof_timeout prefix_hash checkpoint_key,
         end_of_proof_path = theorem_end_of_proof_path project node deps_key proof_engine prefix_hash safe_name,
         end_of_proof_ok = theorem_checkpoint_ok "end_of_proof" deps_key proof_engine proof_timeout prefix_hash checkpoint_key,
         failed_prefix_path = theorem_failed_prefix_path project node deps_key proof_engine safe_name,
         failed_prefix_ok = failed_prefix_ok proof_engine proof_timeout deps_key safe_name pre_hash header_hash,
         deps_key = deps_key,
         checkpoint_key = checkpoint_key,
         proof_ir_plan = proof_ir_plan}
      end
  in
    if length proof_ir_plans = length boundaries then ListPair.map pair (boundaries, proof_ir_plans)
    else raise Error "internal error: proof-IR plan count does not match theorem boundary count"
  end

fun declaration_checkpoint_specs proof_engine proof_timeout project node deps_key source terminations =
  map (fn ({name, safe_name, definition_start, boundary, ...} : HolbuildTheoryCheckpoints.termination) =>
          let
            val prefix_hash = HolbuildTheoryCheckpoints.prefix_hash source boundary
            val checkpoint_key = declaration_checkpoint_key {name = name, safe_name = safe_name,
                                                             boundary = boundary, deps_key = deps_key,
                                                             proof_engine = proof_engine,
                                                             prefix_hash = prefix_hash}
          in
            {name = name, safe_name = safe_name,
             definition_start = definition_start, boundary = boundary,
             prefix_hash = prefix_hash,
             context_path = declaration_context_path project node deps_key proof_engine prefix_hash safe_name,
             context_ok = checkpoint_context_ok "definition_context" deps_key proof_engine proof_timeout prefix_hash checkpoint_key,
             deps_key = deps_key,
             checkpoint_key = checkpoint_key}
          end)
      terminations

fun dependency_context_key toolchain_key plan keys node =
  let
    val project_deps = HolbuildBuildPlan.transitive_project_deps plan node
    val external_theories = HolbuildBuildPlan.direct_external_theories plan node
    val external_libs = HolbuildBuildPlan.direct_external_libs plan node
    val project_lines = map (fn dep => "project " ^ HolbuildBuildPlan.key dep ^ " " ^
                                       HolbuildBuildPlan.input_key_for keys dep)
                            project_deps
    val theory_lines = map (fn dep => "external_theory " ^ dep) external_theories
    val lib_lines = map (fn dep => "external_lib " ^ dep) external_libs
  in
    HolbuildToolchain.hash_text
      (String.concatWith "\n"
         (["holbuild-dependency-context-v1",
           "toolchain_key=" ^ toolchain_key] @ project_lines @ theory_lines @ lib_lines) ^ "\n")
  end

fun metadata_lines text = String.tokens (fn c => c = #"\n") text

fun metadata_value key lines =
  let val prefix = key ^ "="
  in
    first_some (fn line =>
                  if String.isPrefix prefix line then
                    SOME (String.extract(line, size prefix, NONE))
                  else NONE)
               lines
  end

fun checkpoint_ok_matches path fields = HolbuildCheckpointStore.ok_matches warn path fields

fun checkpoint_ok_text_matches path expected_text =
  HolbuildCheckpointStore.ok_text_matches warn path expected_text

fun deps_checkpoint_ok_text deps_key =
  checkpoint_ok_text "deps_loaded" [("deps_key", deps_key)]

fun deps_checkpoint_exists path deps_key =
  checkpoint_ok_matches path [("kind", "deps_loaded"), ("deps_key", deps_key)]

fun checkpoint_proof_timeout path =
  case current_metadata (path ^ ".ok") of
      NONE => legacy_default_proof_timeout
    | SOME text => legacy_proof_timeout (metadata_lines text) "proof_timeout"

fun checkpoint_timeout_satisfies requested_timeout path =
  timeout_satisfies requested_timeout (checkpoint_proof_timeout path)

fun theorem_context_checkpoint_exists requested_timeout project node checkpoint =
  let val deps_loaded = deps_loaded_path project node (#deps_key checkpoint)
  in
    deps_checkpoint_exists deps_loaded (#deps_key checkpoint) andalso
    checkpoint_ok_matches (#context_path checkpoint)
      [("kind", "theorem_context"),
       ("deps_key", #deps_key checkpoint),
       ("prefix_key", #prefix_hash checkpoint),
       ("checkpoint_key", #checkpoint_key checkpoint)] andalso
    checkpoint_timeout_satisfies requested_timeout (#context_path checkpoint)
  end

fun declaration_context_checkpoint_exists requested_timeout project node checkpoint =
  let val deps_loaded = deps_loaded_path project node (#deps_key checkpoint)
  in
    deps_checkpoint_exists deps_loaded (#deps_key checkpoint) andalso
    checkpoint_ok_matches (#context_path checkpoint)
      [("kind", "definition_context"),
       ("deps_key", #deps_key checkpoint),
       ("prefix_key", #prefix_hash checkpoint),
       ("checkpoint_key", #checkpoint_key checkpoint)] andalso
    checkpoint_timeout_satisfies requested_timeout (#context_path checkpoint)
  end

fun theorem_replay_failure_checkpoints checkpoint =
  [#context_path checkpoint, #end_of_proof_path checkpoint]

fun theorem_replay_candidates requested_timeout project node checkpoints =
  List.mapPartial
    (fn checkpoint =>
        if theorem_context_checkpoint_exists requested_timeout project node checkpoint then
          SOME {boundary = #boundary checkpoint, path = #context_path checkpoint,
                safe_name = #safe_name checkpoint, kind = "theorem-context",
                failure_checkpoints = theorem_replay_failure_checkpoints checkpoint}
        else NONE)
    checkpoints

fun declaration_replay_candidates requested_timeout project node checkpoints =
  List.mapPartial
    (fn checkpoint =>
        if declaration_context_checkpoint_exists requested_timeout project node checkpoint then
          SOME {boundary = #boundary checkpoint, path = #context_path checkpoint,
                safe_name = #safe_name checkpoint, kind = "definition-context",
                failure_checkpoints = [#context_path checkpoint]}
        else NONE)
    checkpoints

fun replay_candidates requested_timeout project node theorem_checkpoints declaration_checkpoints =
  theorem_replay_candidates requested_timeout project node theorem_checkpoints @
  declaration_replay_candidates requested_timeout project node declaration_checkpoints

fun later_candidate (a, b) = if #boundary a >= #boundary b then a else b

fun best_replay_candidate requested_timeout project node theorem_checkpoints declaration_checkpoints =
  case replay_candidates requested_timeout project node theorem_checkpoints declaration_checkpoints of
      [] => NONE
    | first :: rest => SOME (List.foldl later_candidate first rest)

fun strict_nonnegative_int_text text =
  size text > 0 andalso List.all Char.isDigit (String.explode text)

fun strict_nonnegative_int text =
  if strict_nonnegative_int_text text then Int.fromString text else NONE

fun failed_prefix_metadata path =
  case current_metadata (path ^ ".meta") of
      NONE => NONE
    | SOME text =>
        let val lines = String.tokens (fn c => c = #"\n") text
            fun value key =
              let val prefix = key ^ "="
              in first_some (fn line =>
                   if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE)) else NONE)
                   lines
              end
        in
          case (value "proof_ir_failed_prefix_version", value "step_count", value "prefix_end", value "path", value "focus") of
              (SOME version, SOME step_count_text, SOME _, SOME _, SOME _) =>
                if version = "1" orelse version = "3" then
                  Option.map (fn step_count => {step_count = step_count, metadata_text = text})
                    (strict_nonnegative_int step_count_text)
                else NONE
            | _ => NONE
        end

fun without_proof_timeout text =
  String.concatWith "\n"
    (List.filter (fn line => not (String.isPrefix "proof_timeout=" line))
                 (metadata_lines text)) ^ "\n"

fun checkpoint_ok_text_matches_ordered requested_timeout path expected_text =
  checkpoint_exists path andalso
  (case current_metadata (path ^ ".ok") of
       SOME text => without_proof_timeout text = without_proof_timeout expected_text andalso
                    checkpoint_timeout_satisfies requested_timeout path
     | NONE => false)

fun failed_prefix_checkpoint requested_timeout checkpoint =
  if checkpoint_ok_text_matches_ordered requested_timeout (#failed_prefix_path checkpoint) (#failed_prefix_ok checkpoint) then
    case failed_prefix_metadata (#failed_prefix_path checkpoint) of
        SOME {step_count, metadata_text} =>
          SOME {checkpoint = checkpoint, step_count = step_count, metadata_text = metadata_text}
      | NONE => NONE
  else NONE

fun remove_failed_prefix_checkpoint ({failed_prefix_path, ...} : HolbuildTheoryCheckpoints.checkpoint) =
  remove_checkpoint failed_prefix_path

fun remove_failed_prefix_checkpoints checkpoints =
  List.app remove_failed_prefix_checkpoint checkpoints

fun later_failed_prefix_candidate (a, b) =
  if #boundary (#checkpoint a) >= #boundary (#checkpoint b) then a else b

fun best_failed_prefix_checkpoint requested_timeout checkpoints =
  case List.mapPartial (failed_prefix_checkpoint requested_timeout) checkpoints of
      [] => NONE
    | first :: rest => SOME (List.foldl later_failed_prefix_candidate first rest)

datatype force_level = ForceNone | ForceTargets | ForceProject | ForceAll

type build_options = {use_cache : bool, force : force_level, force_targets : string list, skip_checkpoints : bool, proof_steps : bool, new_ir : bool, node_tactic_timeouts : (string * real option) list, execution_plan : string option, trace_steps : bool, repl_on_failure : bool}

datatype checkpoint_policy =
  CheckpointPolicy of {checkpoint : bool, proof_steps : bool, new_ir : bool, tactic_timeout : real option, execution_plan : string option, trace_steps : bool, repl_on_failure : bool}

val no_checkpoint_policy =
  CheckpointPolicy {checkpoint = false, proof_steps = false, new_ir = false, tactic_timeout = NONE, execution_plan = NONE, trace_steps = false, repl_on_failure = false}

fun checkpoint_enabled (CheckpointPolicy {checkpoint, ...}) = checkpoint
fun proof_steps_enabled (CheckpointPolicy {proof_steps, ...}) = proof_steps
fun proof_ir_enabled (CheckpointPolicy {new_ir, ...}) = new_ir
fun tactic_timeout (CheckpointPolicy {tactic_timeout, ...}) = tactic_timeout
fun execution_plan (CheckpointPolicy {execution_plan, ...}) = execution_plan
fun trace_steps (CheckpointPolicy {trace_steps, ...}) = trace_steps
fun repl_on_failure (CheckpointPolicy {repl_on_failure, ...}) = repl_on_failure

fun execution_plan_only (CheckpointPolicy {execution_plan = SOME _, trace_steps = false, ...}) = true
  | execution_plan_only _ = false

fun bool_text true = "true"
  | bool_text false = "false"

val theory_manifest_version = "1"

(* Final theory artifacts are semantic products of source bytes, resolved deps,
   toolchain, and declared action policy. Execution strategy is deliberately not
   part of this key: proof_steps/checkpoint/tactic-timeout affect inspectability and
   replay/debug behavior, not the identity of the generated .uo/.ui/.dat bundle.
   Checkpoint files carry their own validity in the filesystem and .ok metadata. *)
fun policy_config_lines _ =
  ["theory_manifest_version=" ^ theory_manifest_version]

fun plain_source_from_checkpoint source_text start_offset =
  if start_offset <= 0 then source_text
  else "val _ = HolbuildRuntime.restore_prover();\n" ^ String.extract(source_text, start_offset, NONE)

fun instrumented_source policy timeout_marker plan_only_marker source_text start_offset checkpoints declaration_checkpoints terminations =
  if proof_steps_enabled policy then
    HolbuildTheoryCheckpoints.instrument
      {source = source_text, start_offset = start_offset, checkpoints = checkpoints,
       declaration_checkpoints = if checkpoint_enabled policy then declaration_checkpoints else [],
       terminations = terminations,
       save_checkpoints = checkpoint_enabled policy,
       tactic_timeout = tactic_timeout policy,
       timeout_marker = timeout_marker,
       plan_theorem = execution_plan policy,
       trace_all = trace_steps policy,
       plan_only_marker = plan_only_marker,
       new_ir = proof_ir_enabled policy}
  else plain_source_from_checkpoint source_text start_offset

fun replay_candidate policy project node theorem_checkpoints declaration_checkpoints =
  best_replay_candidate (tactic_timeout policy) project node theorem_checkpoints declaration_checkpoints

fun source_location_text source_path source_text offset =
  let
    val bounded = Int.min(size source_text, Int.max(0, offset))
    val line = HolbuildTheoryDiagnostics.line_number_at source_text bounded
    val col = HolbuildTheoryDiagnostics.column_number_at source_text bounded
  in
    String.concat [source_path, ":", Int.toString line, ":", Int.toString col]
  end

fun checkpoint_resume_message node lines =
  HolbuildStatus.message_stdout
    (String.concat ("resuming " ^ logical_name node ^ "\n" :: map (fn line => "  " ^ line ^ "\n") lines))

fun deps_loaded_resume_message node =
  checkpoint_resume_message node ["from: deps-loaded checkpoint"]

fun source_context_resume_message node source_text kind safe_name boundary =
  checkpoint_resume_message node
    ["from: " ^ kind ^ " checkpoint after " ^ safe_name,
     "continuing at: " ^ source_location_text (source_file node) source_text boundary]

fun failed_prefix_resume_message node source_text checkpoint step_count =
  checkpoint_resume_message node
    ["from: failed-prefix checkpoint in " ^ #safe_name checkpoint,
     "restoring proof-ir prefix with " ^ Int.toString step_count ^ " successful leaf steps"]

fun failed_prefix_resume_source policy timeout_marker plan_only_marker source checkpoints declaration_checkpoints terminations checkpoint metadata_text =
  let
    val runtime_config =
      {checkpoint_enabled = checkpoint_enabled policy,
       tactic_timeout = tactic_timeout policy,
       timeout_marker = SOME timeout_marker,
       plan_theorem = execution_plan policy,
       trace_all = trace_steps policy,
       plan_only_marker = plan_only_marker,
       new_ir = proof_ir_enabled policy}
    val prelude = HolbuildTheoryCheckpoints.runtime_reinstall_prelude runtime_config
    fun source_slice start stop = String.substring(source, start, stop - start)
    val theorem_binding = #safe_name checkpoint
    val finish_failed_prefix_call =
      String.concat
        ["HolbuildProofRuntime.finish_failed_prefix ",
         HolbuildToolchain.sml_string (#name checkpoint), " ",
         HolbuildToolchain.sml_string metadata_text, " ",
         HolbuildToolchain.sml_string (#tactic_text checkpoint),
         " " ^ HolbuildToolchain.sml_string (#failed_prefix_path checkpoint) ^
         " " ^ HolbuildToolchain.sml_string (#failed_prefix_ok checkpoint)]
    val theorem_save_line =
      String.concat
        ["val ", theorem_binding, " = HolbuildRuntime.save_thm(",
         HolbuildToolchain.sml_string (#name checkpoint), ", ",
         finish_failed_prefix_call,
         ");\n"]
    val resume_replay_block =
      String.concat
        [source_slice (#theorem_start checkpoint) (#tactic_start checkpoint),
         "(ACCEPT_TAC (", finish_failed_prefix_call, "))",
         source_slice (#tactic_end checkpoint) (#boundary checkpoint),
         "\n"]
    val plan_line =
      case #proof_ir_plan checkpoint of
          SOME expr => "val _ = HolbuildProofRuntime.set_theorem_plan (SOME (" ^ expr ^ "));\n"
        | NONE => "val _ = HolbuildProofRuntime.set_theorem_plan NONE;\n"
    val replay_block =
      plan_line ^ (if #kind checkpoint = "resume" then resume_replay_block else theorem_save_line)
    val suffix =
      HolbuildTheoryCheckpoints.instrument
        {source = source,
         start_offset = #boundary checkpoint,
         checkpoints = checkpoints,
         declaration_checkpoints = if checkpoint_enabled policy then declaration_checkpoints else [],
         terminations = terminations,
         save_checkpoints = checkpoint_enabled policy,
         tactic_timeout = tactic_timeout policy,
         timeout_marker = SOME timeout_marker,
         plan_theorem = execution_plan policy,
         trace_all = trace_steps policy,
         plan_only_marker = plan_only_marker,
         new_ir = proof_ir_enabled policy}
  in
    prelude ^ replay_block ^ suffix
  end

datatype failure_repl_checkpoint =
  FailedPrefixRepl of HolbuildTheoryCheckpoints.checkpoint * string
| OtherReplCheckpoint of string * string

fun failure_repl_checkpoint policy theorem_checkpoints failure_checkpoints deps_loaded =
  case best_failed_prefix_checkpoint (tactic_timeout policy) theorem_checkpoints of
      SOME {checkpoint, ...} => SOME (FailedPrefixRepl (checkpoint, #failed_prefix_path checkpoint))
    | NONE =>
        case List.find checkpoint_exists failure_checkpoints of
            SOME path => SOME (OtherReplCheckpoint ("checkpoint", path))
          | NONE => if checkpoint_exists deps_loaded then SOME (OtherReplCheckpoint ("deps-loaded", deps_loaded)) else NONE

fun failure_repl_checkpoint_kind (FailedPrefixRepl _) = "failed-prefix"
  | failure_repl_checkpoint_kind (OtherReplCheckpoint (kind, _)) = kind

fun failure_repl_checkpoint_path (FailedPrefixRepl (_, path)) = path
  | failure_repl_checkpoint_path (OtherReplCheckpoint (_, path)) = path

fun proof_ir_failed_prefix_repl_bootstrap () =
  String.concatWith "\n"
    ["val _ =",
     "  (HolbuildProofRuntime.install_repl_proof_state();",
     "   HolbuildRuntime.print \"holbuild: failed proof state loaded; run p(); or proofManagerLib.p(); to inspect it.\\n\")",
     "  handle e =>",
     "    HolbuildRuntime.print (\"holbuild: could not install failed proof state in proof manager: \" ^ General.exnMessage e ^ \"\\n\");"] ^ "\n"

fun failure_repl_bootstrap_source policy checkpoint =
  case checkpoint of
      FailedPrefixRepl _ => proof_ir_failed_prefix_repl_bootstrap ()
    | OtherReplCheckpoint _ =>
        "val _ = HolbuildRuntime.print \"holbuild: loaded checkpoint has no active proof state.\\n\";\n"

fun write_failure_repl_bootstrap stage policy checkpoint =
  let val path = Path.concat(stage, "holbuild-failure-repl.sml")
  in
    write_text path (failure_repl_bootstrap_source policy checkpoint);
    path
  end

fun run_failure_repl tc policy theorem_checkpoints failure_checkpoints deps_loaded stage =
  if not (repl_on_failure policy) then ()
  else
    case failure_repl_checkpoint policy theorem_checkpoints failure_checkpoints deps_loaded of
        NONE => HolbuildStatus.message_stderr "holbuild: --repl-on-failure requested, but no valid checkpoint is available\n"
      | SOME checkpoint =>
          let
            val kind = failure_repl_checkpoint_kind checkpoint
            val path = failure_repl_checkpoint_path checkpoint
            val bootstrap = write_failure_repl_bootstrap stage policy checkpoint
            val argv = HolbuildToolchain.hol_subcommand_argv tc "repl" @ ["--noconfig", "--holstate", path, bootstrap]
            val _ = HolbuildStatus.message_stderr
                      (String.concat ["holbuild: starting HOL repl from ", kind,
                                      " checkpoint\ncheckpoint: ", path, "\n"])
          in
            ignore (HolbuildToolchain.run_interactive argv)
          end

fun write_theory_script policy project base_context plan keys input_key toolchain_key node source_text checkpoints declaration_checkpoints terminations staged_script preload timeout_marker plan_only_marker =
  if not (checkpoint_enabled policy) then
    (write_plain_preload plan node preload;
     write_text staged_script (instrumented_source policy (SOME timeout_marker) plan_only_marker source_text 0 checkpoints [] terminations);
     {context = base_context, files = [preload, staged_script], failure_checkpoints = [], failed_prefix_context = NONE})
  else
    let
      val deps_key = dependency_context_key toolchain_key plan keys node
      val deps_loaded = deps_loaded_path project node deps_key
      val deps_ok = deps_checkpoint_ok_text deps_key
      fun ensure_source_checkpoint_parents () =
        (List.app (fn {context_path, end_of_proof_path, failed_prefix_path, ...} =>
                     (ensure_parent context_path; ensure_parent end_of_proof_path; ensure_parent failed_prefix_path))
                  checkpoints;
         List.app (fn {context_path, ...} => ensure_parent context_path) declaration_checkpoints)
      fun run_from_deps_checkpoint () =
        (ensure_source_checkpoint_parents ();
         write_text staged_script (instrumented_source policy (SOME timeout_marker) plan_only_marker source_text 0 checkpoints declaration_checkpoints terminations);
         deps_loaded_resume_message node;
         {context = HolState deps_loaded, files = [staged_script], failure_checkpoints = [deps_loaded], failed_prefix_context = NONE})
      fun run_from_fresh_preload () =
        (remove_theorem_checkpoints_for_deps project node deps_key;
         remove_declaration_checkpoints_for_deps project node deps_key;
         ensure_source_checkpoint_parents ();
         write_preload plan node deps_loaded deps_ok preload;
         write_text staged_script (instrumented_source policy (SOME timeout_marker) plan_only_marker source_text 0 checkpoints declaration_checkpoints terminations);
         {context = base_context, files = [preload, staged_script], failure_checkpoints = [], failed_prefix_context = NONE})
      fun run_from_failed_prefix {checkpoint, step_count, metadata_text} =
        let
          val path = #failed_prefix_path checkpoint
          val _ = ensure_source_checkpoint_parents ()
          val _ = write_text staged_script (failed_prefix_resume_source policy timeout_marker plan_only_marker source_text checkpoints declaration_checkpoints terminations checkpoint metadata_text)
          val _ = failed_prefix_resume_message node source_text checkpoint step_count
        in
          {context = HolState path, files = [staged_script], failure_checkpoints = [path, deps_loaded], failed_prefix_context = SOME (path, step_count)}
        end
      fun run_from_replay {boundary, path, safe_name, kind, failure_checkpoints} =
        let
          val _ = ensure_source_checkpoint_parents ()
          val _ = write_text staged_script (instrumented_source policy (SOME timeout_marker) plan_only_marker source_text boundary checkpoints declaration_checkpoints terminations)
          val _ = source_context_resume_message node source_text kind safe_name boundary
        in
          {context = HolState path, files = [staged_script], failure_checkpoints = failure_checkpoints @ [deps_loaded], failed_prefix_context = NONE}
        end
      fun failed_prefix_at_least_as_late failed NONE = true
        | failed_prefix_at_least_as_late failed (SOME replay) =
            #boundary (#checkpoint failed) >= #boundary replay
      val failed_prefix = if proof_steps_enabled policy then best_failed_prefix_checkpoint (tactic_timeout policy) checkpoints else NONE
      val replay = replay_candidate policy project node checkpoints declaration_checkpoints
    in
      case failed_prefix of
          SOME failed =>
            if failed_prefix_at_least_as_late failed replay then run_from_failed_prefix failed
            else (case replay of SOME replay' => run_from_replay replay' | NONE => run_from_failed_prefix failed)
        | NONE =>
            case replay of
                SOME replay' => run_from_replay replay'
              | NONE =>
                  if deps_checkpoint_exists deps_loaded deps_key then run_from_deps_checkpoint ()
                  else run_from_fresh_preload ()
    end

fun build_theory cache_allowed policy tc project base_context plan keys toolchain_key node source_text theorem_checkpoints declaration_checkpoints termination_diagnostics =
  let
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val stage = stage_dir project input_key
    val staged_script = Path.concat(stage, Path.file (source_file node))
    val preload = Path.concat(stage, "holbuild-preload.sml")
    val final_loader = Path.concat(stage, "holbuild-save-final-context.sml")
    val parents_report = Path.concat(stage, "holbuild-theory-parents.txt")
    val mldeps_report = Path.concat(stage, "holbuild-theory-mldeps.txt")
    val timeout_marker = Path.concat(stage, "holbuild-tactic-timeout.txt")
    val plan_only_marker = Path.concat(stage, "holbuild-proof-ir-plan.txt")
    val deps_key = dependency_context_key toolchain_key plan keys node
    val deps_loaded = deps_loaded_path project node deps_key
    val deps_ok = deps_checkpoint_ok_text deps_key
    val final_context = final_context_path project node
    val {sig_path, sml_path, data_path, script_uo, theory_ui, theory_uo} = theory_outputs node
    val staged_sig = staged_theory_file stage node ".sig"
    val staged_sml = staged_theory_file stage node ".sml"
    val staged_dat = staged_theory_file stage node ".dat"
    val _ = remove_tree stage
    val _ = ensure_dir stage
    val _ = if checkpoint_enabled policy then ensure_parent deps_loaded else ()
    val _ = if checkpoint_enabled policy then ensure_parent final_context else ()
    val _ =
      if checkpoint_enabled policy then
        List.app (fn {context_path, end_of_proof_path, failed_prefix_path, ...} =>
                    (ensure_parent context_path; ensure_parent end_of_proof_path; ensure_parent failed_prefix_path))
                 theorem_checkpoints
      else ()
    val _ =
      if checkpoint_enabled policy then
        write_final_context_loader
          {theory_name = logical_name node,
           sig_path = staged_sig, sml_path = staged_sml,
           output = final_context, path = final_loader,
           parents_report = SOME parents_report,
           mldeps_report = SOME mldeps_report}
      else
        write_plain_final_context_loader
          {theory_name = logical_name node,
           sig_path = staged_sig, sml_path = staged_sml,
           path = final_loader,
           parents_report = SOME parents_report,
           mldeps_report = SOME mldeps_report}
    val _ = remove_file timeout_marker
    val _ = remove_file plan_only_marker
    val run_spec = write_theory_script policy project base_context plan keys input_key toolchain_key node
                                    source_text theorem_checkpoints declaration_checkpoints termination_diagnostics staged_script preload timeout_marker
                                    (if execution_plan_only policy then SOME plan_only_marker else NONE)
    fun tactic_timeout_error () =
      let
        val words = String.tokens Char.isSpace (read_text timeout_marker)
        val failure_output = checkpoint_failure_output project node input_key stage
        val failure_output_path = captured_output_path_option failure_output
        val source_context =
          Option.mapPartial
            (HolbuildTheoryDiagnostics.summarize_failed_fragment_source
               (source_file node) source_text theorem_checkpoints)
            failure_output_path
        val goal_state =
          Option.mapPartial
            (HolbuildTheoryDiagnostics.summarize_goal_state_with_log_reference
               (captured_output_has_retained_log failure_output))
            failure_output_path
        val plan_position = Option.mapPartial HolbuildTheoryDiagnostics.plan_position_summary failure_output_path
        val child_failure = Option.mapPartial HolbuildTheoryDiagnostics.child_failure_summary failure_output_path
        val detail =
          String.concat
            [case source_context of NONE => "" | SOME text => text,
             case plan_position of NONE => "" | SOME text => text,
             case goal_state of NONE => "" | SOME text => text,
             case child_failure of NONE => "" | SOME text => text,
             retained_log_reference failure_output]
        fun with_detail heading = heading ^ (if detail = "" then "" else "\n" ^ detail)
      in
        case rev words of
            seconds :: rev_label_words =>
              error_with_captured_output
                (with_detail ("tactic timed out after " ^ seconds ^ "s while building " ^
                              logical_name node ^ ": " ^ String.concatWith " " (rev rev_label_words)))
                failure_output
          | [] =>
              error_with_captured_output
                (with_detail ("tactic timed out while building " ^ logical_name node))
                failure_output
      end
    fun discard_loaded_checkpoint_after_load_failure () =
      remove_loaded_checkpoint_descendants project node deps_key deps_loaded theorem_checkpoints declaration_checkpoints
        (hol_context_path (#context run_spec))
    fun discard_failed_prefix_after_resume_failure msg =
      case #failed_prefix_context run_spec of
          NONE => false
        | SOME (path, _) =>
            let
              val failure_output = checkpoint_failure_output project node input_key stage
              val output_text =
                case captured_output_path_option failure_output of
                    NONE => ""
                  | SOME output_path => read_text output_path handle _ => ""
              val failure_text = msg ^ "\n" ^ output_text
            in
              if List.exists (fn marker => String.isSubstring marker failure_text)
                   ["failed-prefix checkpoint cannot rewind",
                    "failed-prefix proof path is not present in current proof-ir plan",
                    "invalid proof-ir failed-prefix metadata",
                    "proof-ir dynamic replay mismatch"] then
                (remove_checkpoint path;
                 warn ("discarding failed-prefix checkpoint after failed resume: " ^ path);
                 true)
              else false
            end
    fun checkpoint_failure_error msg =
      let
        val failure_output = checkpoint_failure_output project node input_key stage
        val failure_output_path = captured_output_path_option failure_output
        val goal_state =
          Option.mapPartial
            (HolbuildTheoryDiagnostics.summarize_goal_state_with_log_reference
               (captured_output_has_retained_log failure_output))
            failure_output_path
        val plan_position = Option.mapPartial HolbuildTheoryDiagnostics.plan_position_summary failure_output_path
        val trace_context = if trace_steps policy then Option.mapPartial HolbuildTheoryDiagnostics.summarize_trace_steps failure_output_path else NONE
        val static_error = Option.mapPartial (fn path => HolbuildTheoryDiagnostics.static_error_summary (source_file node) source_text (String.fields (fn c => c = #"\n") (read_text path))) failure_output_path
        val source_context = Option.mapPartial (HolbuildTheoryDiagnostics.summarize_failed_fragment_source (source_file node) source_text theorem_checkpoints) failure_output_path
        val termination_context =
          Option.mapPartial
            (HolbuildTheoryDiagnostics.summarize_termination_goal_source
               (source_file node) source_text termination_diagnostics)
            failure_output_path
        val child_failure =
          if Option.isSome static_error then NONE
          else Option.mapPartial HolbuildTheoryDiagnostics.child_failure_summary failure_output_path
        val fallback =
          if Option.isSome child_failure then ""
          else
            case String.fields (fn c => c = #"\n") msg of
                [] => "hol run failed while building theory script\n"
              | first :: _ => first ^ "\n"
        val detail =
          String.concat
            [case trace_context of NONE => "" | SOME text => text,
             case static_error of NONE => "" | SOME text => text,
             case source_context of NONE => "" | SOME text => text,
             case termination_context of NONE => "" | SOME text => text,
             case plan_position of NONE => "" | SOME text => text,
             case goal_state of NONE => "" | SOME text => text,
             case child_failure of NONE => fallback | SOME text => text,
             retained_log_reference failure_output]
      in
        error_with_captured_output detail failure_output
      end
    fun stage_source_extra_dep decl =
      List.app (fn (rel, abs) =>
          let val dst = normalize_path (if Path.isAbsolute rel then rel else Path.concat(stage, rel))
          in ensure_parent dst; copy_binary abs dst end)
        (expand_extra_dep (Path.dir (source_file node)) decl)
    val _ = List.app stage_source_extra_dep (#extra_deps (source_deps node))
    val build_log = Path.concat(stage, "holbuild-build.log")
    val _ =
      (validate_hol_context (#context run_spec);
       detail_time_phase "build.exec.node.child_run"
         (fn () =>
             run_hol_files_to_log tc stage stage
               (#context run_spec)
               (#files run_spec @ [final_loader])
               "holbuild-build.log"
               (SOME (current_build_log project node))
               "hol run failed while building theory script"))
      handle Error msg =>
        if invalid_checkpoint_retryable base_context (#context run_spec) msg then
          let
            val invalid = hol_context_path (#context run_spec)
            val _ = discard_loaded_checkpoint_after_load_failure ()
            val _ = warn ("discarding invalid checkpoint after HOL state load failure: " ^ invalid)
          in
            raise RetryInvalidCheckpoint
          end
        else if discard_failed_prefix_after_resume_failure msg then
          raise RetryInvalidCheckpoint
        else
          let
            val failure_output = checkpoint_failure_output project node input_key stage
            val failure_output_path = captured_output_path_option failure_output
            val static_error =
              Option.mapPartial
                (fn path => HolbuildTheoryDiagnostics.static_error_summary
                              (source_file node) source_text
                              (String.fields (fn c => c = #"\n") (read_text path)))
                failure_output_path
          in
            if Option.isSome static_error andalso hol_context_path (#context run_spec) <> hol_context_path base_context then
              let
                val invalid = hol_context_path (#context run_spec)
                val _ = discard_loaded_checkpoint_after_load_failure ()
                val _ = warn ("discarding invalid checkpoint after HOL state load failure: " ^ invalid)
              in
                raise RetryInvalidCheckpoint
              end
            else
              let
                val failure_error =
                  if file_exists timeout_marker then tactic_timeout_error ()
                  else if null theorem_checkpoints andalso null termination_diagnostics then Error msg
                  else checkpoint_failure_error msg
                val _ = run_failure_repl tc policy theorem_checkpoints (#failure_checkpoints run_spec) deps_loaded stage
                val _ = cleanup_json_stage stage
              in
                raise failure_error
              end
          end
    val _ =
      if execution_plan_only policy andalso file_exists plan_only_marker then
        (HolbuildStatus.message_stdout (read_text build_log handle _ => "");
         raise ExecutionPlanPrinted)
      else if Option.isSome (execution_plan policy) then
        HolbuildStatus.message_stdout (read_text build_log handle _ => "")
      else if trace_steps policy then
        if HolbuildStatus.json_mode () then
          HolbuildStatus.message_stdout (read_text build_log handle _ => "")
        else
          (case proof_trace_output project node input_key stage of
               NONE => ()
             | SOME output => HolbuildStatus.message_stdout ("proof step trace log: " ^ captured_output_path output ^ "\n"))
      else ()
    val _ = copy_binary staged_dat data_path
    val _ = copy_binary staged_dat (hfs_remapped_path data_path)
    val _ = copy_binary staged_sig sig_path
    val _ = copy_binary staged_sig (hfs_remapped_path sig_path)
    val dat_replacements = stage_dat_replacements stage node data_path
    val _ = copy_rewriting_path {src = staged_sml, dst = sml_path,
                                 replacements = dat_replacements}
    val _ = copy_binary sml_path (hfs_remapped_path sml_path)
    val generated_metadata = read_generated_load_metadata {parents_report = parents_report,
                                                           mldeps_report = mldeps_report}
    val _ =
      if cache_allowed then
        detail_time_phase "build.exec.publish_cache"
          (fn () => publish_theory_cache project plan node input_key (tactic_timeout policy)
                                      staged_sig sml_path staged_dat generated_metadata)
      else ()
  in
    write_local_theory_manifests plan node generated_metadata;
    remove_tree stage
  end

fun same_package_logical a b =
  HolbuildBuildPlan.package a = HolbuildBuildPlan.package b andalso
  HolbuildBuildPlan.logical_name a = HolbuildBuildPlan.logical_name b

fun has_signature_companion plan node =
  List.exists
    (fn candidate => same_package_logical candidate node andalso
                     #kind (HolbuildBuildPlan.source_of candidate) = HolbuildSourceIndex.Sig)
    (HolbuildBuildPlan.universe_nodes plan)

fun write_empty_ui_if_needed plan node =
  if has_signature_companion plan node then ()
  else write_object_manifest (one_with_suffix ".ui" (#objects (source_artifacts node))) []

fun build_sml_like plan node output_suffix =
  let
    val output = one_with_suffix output_suffix (#objects (source_artifacts node))
    val deps = HolbuildBuildPlan.direct_project_deps plan node
    val external_loads = direct_external_loads plan node
  in
    write_object_manifest output (external_loads @ project_load_stems deps @ [source_file node]);
    if output_suffix = ".uo" then write_empty_ui_if_needed plan node else ()
  end

fun output_paths _ _ node =
  let
    val artifacts = source_artifacts node
    val generated_paths = #generated artifacts
    val object_paths = #objects artifacts
    val data_paths = #theory_data artifacts
  in
    generated_paths @ map hfs_remapped_path generated_paths @
    object_paths @ map hfs_remapped_path object_paths @
    data_paths @ map hfs_remapped_path data_paths
  end

fun output_hash_line path = "output-sha1=" ^ path ^ " " ^ file_hash path

fun checkpoint_lines _ _ _ = []

fun dependency_context_lines plan keys toolchain_key node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        ["dependency_context_key=" ^ dependency_context_key toolchain_key plan keys node]
    | _ => []

fun action_policy_lines node =
  let
    val policy = source_policy node
    val declared_dep_lines =
      map (fn dep => "declared_dep=" ^ dep) (HolbuildProject.action_deps policy)
    val declared_load_lines =
      map (fn dep => "declared_load=" ^ dep) (HolbuildProject.action_loads policy)
    fun extra_input_root input =
      let
        val rel = HolbuildProject.extra_input_path input
        val abs = HolbuildProject.extra_input_absolute_path input
        val n = size abs - size rel
      in
        if n > 0 then String.substring(abs, 0, n) else Path.dir abs
      end
    val extra_inputs = HolbuildProject.action_extra_inputs policy
    val extra_lines =
      List.concat (map (fn input =>
        extra_dep_lines "extra_dep" (extra_input_root input) [HolbuildProject.extra_input_path input]) extra_inputs)
    val source_extra_lines =
      extra_dep_lines "source_extra_dep" (Path.dir (source_file node)) (#extra_deps (source_deps node))
  in
    ["cache=" ^ bool_text (HolbuildProject.action_cache_enabled policy),
     "always_reexecute=" ^ bool_text (HolbuildProject.action_always_reexecute policy)] @
    declared_dep_lines @
    declared_load_lines @
    extra_lines @
    source_extra_lines
  end

fun theorem_boundary_line ({safe_name, prefix_hash, context_path, end_of_proof_path, ...} : HolbuildTheoryCheckpoints.checkpoint) =
  "theorem_boundary " ^ safe_name ^ " " ^ prefix_hash ^ " " ^
  context_path ^ " " ^ end_of_proof_path

fun theorem_boundary_lines theorem_checkpoints =
  map theorem_boundary_line theorem_checkpoints

fun proof_timeout_lines checkpoint_policy node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => ["proof_timeout=" ^ timeout_text (tactic_timeout checkpoint_policy)]
    | _ => []

fun metadata_core_lines checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints =
  let
    val source = HolbuildBuildPlan.source_of node
  in
    ["holbuild-action-metadata-v1",
     "input_key=" ^ input_key,
     "toolchain_key=" ^ toolchain_key,
     "kind=" ^ HolbuildSourceIndex.kind_string (#kind source),
     "package=" ^ #package source,
     "logical=" ^ #logical_name source,
     "source=" ^ #relative_path source] @
    dependency_context_lines plan keys toolchain_key node @
    proof_timeout_lines checkpoint_policy node @
    action_policy_lines node @
    checkpoint_lines checkpoint_policy project node @
    theorem_boundary_lines theorem_checkpoints
  end

fun lines_text lines = String.concatWith "\n" lines ^ "\n"

fun metadata_core_text checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints =
  lines_text (metadata_core_lines checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints)

fun metadata_text checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints =
  lines_text
    (metadata_core_lines checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints @
     map output_hash_line (output_paths checkpoint_policy project node))

fun semantic_metadata_text text =
  lines_text (List.filter (fn line => not (String.isPrefix "output-sha1=" line))
                          (metadata_lines text))

fun metadata_input_key_matches input_key text =
  case metadata_value "input_key" (metadata_lines text) of
      SOME old_key => old_key = input_key
    | NONE => false

fun metadata_proof_timeout text = legacy_proof_timeout (metadata_lines text) "proof_timeout"

fun metadata_timeout_satisfies policy node text =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        timeout_satisfies (tactic_timeout policy) (metadata_proof_timeout text)
    | _ => true

(* Up-to-date is intentionally a cheap semantic check. The input_key already
   commits to source hash, dependency keys, toolchain key, and declared action
   policy, so do not rebuild full diagnostic metadata here; doing so recomputes
   dependency-context closures for every unchanged node. *)
fun file_nonempty path = file_exists path andalso OS.FileSys.fileSize path > 0

fun output_exists_for_node node path =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => file_nonempty path
    | _ => file_exists path

fun theory_name_from_logical logical =
  if has_suffix "Theory" logical then drop_suffix "Theory" logical else logical

fun theory_dat_parent_hash dat_text parent_name =
  let
    val marker = "(\"" ^ parent_name ^ "\""
    val n = size dat_text
    fun whitespace c = c = #" " orelse c = #"\n" orelse c = #"\t" orelse c = #"\r"
    fun skip_ws i = if i < n andalso whitespace (String.sub(dat_text, i)) then skip_ws (i + 1) else i
    fun parse_hash start =
      let
        val dot = skip_ws (start + size marker)
        val quote = skip_ws (dot + 1)
      in
        if dot < n andalso String.sub(dat_text, dot) = #"." andalso
           quote < n andalso String.sub(dat_text, quote) = #"\"" andalso
           quote + 41 <= n then
          let val hash = String.substring(dat_text, quote + 1, 40)
          in if valid_sha1_text hash then SOME hash else NONE end
        else NONE
      end
  in
    case find_substring marker dat_text of
        NONE => NONE
      | SOME start => parse_hash start
  end

fun project_theory_deps plan node =
  List.filter
    (fn dep => #kind (HolbuildBuildPlan.source_of dep) = HolbuildSourceIndex.TheoryScript)
    (HolbuildBuildPlan.direct_project_deps plan node)

fun theory_parent_hash_matches dat_hash_cache dat_text dep =
  let
    val parent_name = theory_name_from_logical (logical_name dep)
  in
    (* A parent whose data file cannot be hashed (missing/unreadable) makes the
       node not up to date, matching the old eager-hash behaviour.  Only a
       readable parent lets a missing recorded hash count as a match. *)
    case cached_file_hash dat_hash_cache (#data_path (theory_outputs dep)) of
        NONE => false
      | SOME parent_hash =>
          (case theory_dat_parent_hash dat_text parent_name of
               NONE => true
             | SOME recorded_hash => recorded_hash = parent_hash)
  end

fun theory_parent_hashes_match dat_hash_cache plan node =
  detail_time_phase "build.exec.node.parent_hash_check"
    (fn () =>
        (case #kind (HolbuildBuildPlan.source_of node) of
             HolbuildSourceIndex.TheoryScript =>
               let val dat_text = read_text (#data_path (theory_outputs node))
               in List.all (theory_parent_hash_matches dat_hash_cache dat_text)
                           (project_theory_deps plan node) end
           | _ => true)
        handle _ => false)

fun up_to_date dat_hash_cache checkpoint_policy project plan _ input_key _ node _ =
  detail_time_phase "build.exec.node.up_to_date"
    (fn () =>
        List.all (output_exists_for_node node) (output_paths checkpoint_policy project node) andalso
        (case current_metadata (metadata_path project node) of
             SOME text => metadata_input_key_matches input_key text andalso
                          metadata_timeout_satisfies checkpoint_policy node text
           | NONE => false) andalso
        theory_parent_hashes_match dat_hash_cache plan node)

fun write_metadata checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints =
  write_text (metadata_path project node)
             (metadata_text checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints)

fun root_package_name project =
  HolbuildProject.package_name (HolbuildProject.project_package project)

fun root_package_node project node =
  HolbuildBuildPlan.package node = root_package_name project

fun force_target_node targets node =
  List.exists (fn target => target = HolbuildBuildPlan.logical_name node) targets

fun force_node ({force, force_targets, ...} : build_options) project node =
  case force of
      ForceNone => false
    | ForceTargets => force_target_node force_targets node
    | ForceProject => root_package_node project node
    | ForceAll => true

fun assoc_timeout _ [] = NONE
  | assoc_timeout node_key ((key, timeout) :: rest) =
      if key = node_key then timeout else assoc_timeout node_key rest

fun effective_tactic_timeout proof_steps node_timeout =
  if proof_steps then node_timeout else NONE

fun checkpoint_policy_for_node ({skip_checkpoints, proof_steps, new_ir, node_tactic_timeouts, execution_plan, trace_steps, repl_on_failure, ...} : build_options) project node =
  CheckpointPolicy {checkpoint = not skip_checkpoints,
                    proof_steps = proof_steps,
                    new_ir = new_ir,
                    tactic_timeout = effective_tactic_timeout proof_steps
                                      (assoc_timeout (HolbuildBuildPlan.key node) node_tactic_timeouts),
                    execution_plan = if proof_steps then execution_plan else NONE,
                    trace_steps = proof_steps andalso trace_steps,
                    repl_on_failure = repl_on_failure}

fun proof_engine (CheckpointPolicy {proof_steps = false, ...}) = "plain_v1"
  | proof_engine (CheckpointPolicy {new_ir = true, ...}) = "proof_ir_v3"
  | proof_engine _ = "proof_steps_failed_fragment_span_v6"

fun build_config_lines_for_node options project node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => policy_config_lines (checkpoint_policy_for_node options project node)
    | HolbuildSourceIndex.Sml => policy_config_lines no_checkpoint_policy
    | HolbuildSourceIndex.Sig => policy_config_lines no_checkpoint_policy

fun write_temp_text path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun analyser_proof_ir_plan_sml_for_boundaries (boundaries : HolbuildTheoryCheckpoints.boundary list) =
  case HolbuildDependencies.current_analyser_path () of
      NONE => raise Error "internal error: HOL analyser is not configured"
    | SOME analyser =>
        let
          fun theorem_line (i, {name, tactic_start, tactic_end, tactic_text, ...}) =
            HolbuildAnalysisProtocol.join ["theorem", Int.toString i, name,
                                           Int.toString tactic_start, Int.toString tactic_end, tactic_text]
          val req = OS.FileSys.tmpName ()
          val resp = OS.FileSys.tmpName ()
          val request = String.concatWith "\n"
            ([HolbuildAnalysisProtocol.join ["version", HolbuildAnalysisProtocol.protocol_version],
              HolbuildAnalysisProtocol.join ["command", "proof-ir-plan"]] @
             map theorem_line (ListPair.zip (List.tabulate(length boundaries, fn i => i), boundaries)) @
             [HolbuildAnalysisProtocol.join ["end"]]) ^ "\n"
          val _ = write_temp_text req request
          val status = OS.Process.system (HolbuildHash.quote analyser ^ " --request " ^ HolbuildHash.quote req ^
                                          " --response " ^ HolbuildHash.quote resp)
          val _ = OS.FileSys.remove req handle OS.SysErr _ => ()
          val text = if OS.Process.isSuccess status then read_text resp
                     else (OS.FileSys.remove resp handle OS.SysErr _ => ();
                           raise Error "holbuild-hol-analyser failed")
          val _ = OS.FileSys.remove resp handle OS.SysErr _ => ()
          val expected = length boundaries
          val result = Array.array(expected, NONE : string option)
          fun store id expr =
            case Int.fromString id of
                SOME i => if i >= 0 andalso i < expected then Array.update(result, i, SOME expr)
                          else raise Error ("bad proof-IR response id: " ^ id)
              | NONE => raise Error ("bad proof-IR response id: " ^ id)
          fun loop rest =
            case rest of
                [] => ()
              | line :: more =>
                  (case HolbuildAnalysisProtocol.split line of
                       "begin-proof-ir" :: id :: _ :: _ :: _ :: expr :: _ => (store id expr; loop more)
                     | _ => loop more)
          val _ = loop (String.tokens (fn c => c = #"\n") text)
          fun require i =
            case Array.sub(result, i) of
                SOME expr => SOME expr
              | NONE => raise Error ("missing proof-IR plan for theorem boundary " ^ Int.toString i)
        in List.tabulate(expected, require) end

fun source_boundaries_for_node node source_text =
  SOME (detail_time_phase "build.exec.node.analyse_boundaries"
          (fn () => discover_theorem_boundaries_recovering (source_file node) source_text))
  handle Error msg =>
    (warn ("could not safely instrument theorem boundaries for " ^ logical_name node ^
           "; building without proof steps/checkpoints for this theory\n" ^ msg);
     NONE)

fun theory_checkpoints_for_node policy project plan keys toolchain_key node source_text boundaries errors =
  if not (proof_steps_enabled policy) andalso not (checkpoint_enabled policy) then []
  else
    let
      val deps_key = dependency_context_key toolchain_key plan keys node
      val proof_ir_plans =
        if null boundaries then []
        else if proof_ir_enabled policy then
          detail_time_phase "build.exec.node.proof_ir_plan"
            (fn () => analyser_proof_ir_plan_sml_for_boundaries boundaries)
        else map (fn _ => NONE) boundaries
      val _ =
        case errors of
            [] => ()
          | _ => warn ("HOL source parser recovered while instrumenting theorem boundaries for " ^
                       logical_name node ^ "; using recovered theorem boundaries\n" ^
                       String.concatWith "\n" errors)
    in
      theorem_checkpoint_specs (proof_engine policy) (tactic_timeout policy) project node deps_key source_text proof_ir_plans boundaries
    end
    handle Error msg =>
      if proof_ir_enabled policy then raise Error msg
      else
        (warn ("could not safely instrument theorem boundaries for " ^ logical_name node ^
               "; building without proof steps/checkpoints for this theory\n" ^ msg);
         [])

fun termination_diagnostics_for_node policy node source_text =
  if not (proof_steps_enabled policy) then []
  else detail_time_phase "build.exec.node.analyse_terminations"
         (fn () => discover_termination_diagnostics_strict (source_file node) source_text)
    handle Error msg =>
      (warn ("could not safely instrument termination diagnostics for " ^ logical_name node ^
             "; building without termination goal diagnostics for this theory\n" ^ msg);
       [])

fun source_spans_for_node policy node source_text =
  if proof_steps_enabled policy then
    let
      val combined =
        detail_time_phase "build.exec.node.analyse_boundaries"
          (fn () =>
              detail_time_phase "build.exec.node.analyse_terminations"
                (fn () => discover_boundaries_and_terminations (source_file node) source_text))
    in
      {source_boundaries = SOME {boundaries = #boundaries combined, errors = #errors combined},
       termination_diagnostics = #terminations combined}
    end
    handle Error _ =>
      {source_boundaries = source_boundaries_for_node node source_text,
       termination_diagnostics = termination_diagnostics_for_node policy node source_text}
  else
    {source_boundaries = source_boundaries_for_node node source_text,
     termination_diagnostics = []}

fun declaration_checkpoints_for_node policy project plan keys toolchain_key node source_text terminations =
  if not (checkpoint_enabled policy) orelse not (proof_steps_enabled policy) then []
  else
    let val deps_key = dependency_context_key toolchain_key plan keys node
    in declaration_checkpoint_specs (proof_engine policy) (tactic_timeout policy) project node deps_key source_text terminations end
    handle Error msg =>
      (warn ("could not safely create termination-definition checkpoints for " ^ logical_name node ^
             "; building without termination-definition checkpoints for this theory\n" ^ msg);
       [])

fun build_theory_node dat_hash_cache (options : build_options) tc project base_context plan keys toolchain_key node input_key =
  let
    val policy = checkpoint_policy_for_node options project node
    val metadata_checkpoints = []
    val stage = stage_dir project input_key
    val forced = force_node options project node
    val cache_allowed = #use_cache options andalso cache_enabled node
    val cache_restore_allowed = cache_allowed andalso not forced
    fun invalidate_node_dat_hash () =
      invalidate_cached_file_hash dat_hash_cache (#data_path (theory_outputs node))
    fun materialize_valid_cache () =
      materialize_theory_cache tc project plan input_key (tactic_timeout policy) node andalso
      (if theory_parent_hashes_match dat_hash_cache plan node then true
       else (remove_failed_cache_outputs project node; false))
  in
    if not forced andalso not (always_reexecute node) andalso
       up_to_date dat_hash_cache policy project plan keys input_key toolchain_key node metadata_checkpoints then
      (remove_tree_if_exists stage;
       HolbuildStatus.UpToDate)
    else if cache_restore_allowed andalso materialize_valid_cache () then
      (remove_tree stage;
       invalidate_node_dat_hash ();
       write_metadata policy project plan keys input_key toolchain_key node metadata_checkpoints;
       HolbuildStatus.Restored)
    else
      let
        val source_text = read_text (source_file node)
        val source_spans = source_spans_for_node policy node source_text
        val source_boundaries = #source_boundaries source_spans
        val theorem_checkpoints =
          case source_boundaries of
              NONE => []
            | SOME {boundaries, errors} =>
                theory_checkpoints_for_node policy project plan keys toolchain_key node source_text boundaries errors
        val termination_diagnostics = #termination_diagnostics source_spans
        val declaration_checkpoints =
          declaration_checkpoints_for_node policy project plan keys toolchain_key node source_text termination_diagnostics
      in
        let
          fun build_after_checkpoint_retries retries_left =
            ((build_theory cache_allowed policy tc project base_context plan keys toolchain_key node source_text theorem_checkpoints declaration_checkpoints termination_diagnostics;
              remove_failed_prefix_checkpoints theorem_checkpoints;
              invalidate_node_dat_hash ();
              write_metadata policy project plan keys input_key toolchain_key node metadata_checkpoints;
              HolbuildStatus.Built)
             handle RetryInvalidCheckpoint =>
               if retries_left <= 0 then raise RetryInvalidCheckpoint
               else build_after_checkpoint_retries (retries_left - 1))
        in
          build_after_checkpoint_retries (length theorem_checkpoints + length declaration_checkpoints + 1)
        end
        handle ExecutionPlanPrinted => HolbuildStatus.Inspected
      end
  end

fun build_node dat_hash_cache options tc project base_context plan keys toolchain_key node =
  let val input_key = HolbuildBuildPlan.input_key_for keys node
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript =>
          build_theory_node dat_hash_cache options tc project base_context plan keys toolchain_key node input_key
      | HolbuildSourceIndex.Sml =>
          if not (force_node options project node) andalso not (always_reexecute node) andalso
             up_to_date dat_hash_cache no_checkpoint_policy project plan keys input_key toolchain_key node [] then
            HolbuildStatus.UpToDate
          else (build_sml_like plan node ".uo";
                write_metadata no_checkpoint_policy project plan keys input_key toolchain_key node [];
                HolbuildStatus.Built)
      | HolbuildSourceIndex.Sig =>
          if not (force_node options project node) andalso not (always_reexecute node) andalso
             up_to_date dat_hash_cache no_checkpoint_policy project plan keys input_key toolchain_key node [] then
            HolbuildStatus.UpToDate
          else (build_sml_like plan node ".ui";
                write_metadata no_checkpoint_policy project plan keys input_key toolchain_key node [];
                HolbuildStatus.Built)
  end

fun node_policy options project node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => checkpoint_policy_for_node options project node
    | HolbuildSourceIndex.Sml => no_checkpoint_policy
    | HolbuildSourceIndex.Sig => no_checkpoint_policy

fun node_is_up_to_date options project plan keys toolchain_key node =
  not (force_node options project node) andalso not (always_reexecute node) andalso
  up_to_date (new_file_hash_cache ()) (node_policy options project node)
             project plan keys (HolbuildBuildPlan.input_key_for keys node)
             toolchain_key node []

fun report_up_to_date_node status project keys node =
  let
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val key = HolbuildBuildPlan.key node
    val label = HolbuildBuildPlan.logical_name node
  in
    HolbuildStatus.start_node status key label;
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript => remove_tree_if_exists (stage_dir project input_key)
      | _ => ();
    HolbuildStatus.finish_node status key label HolbuildStatus.UpToDate
  end

fun all_nodes_up_to_date options project plan keys toolchain_key =
  List.all (node_is_up_to_date options project plan keys toolchain_key)
           (HolbuildBuildPlan.selected_nodes plan)

fun report_all_up_to_date status project keys plan =
  List.app (report_up_to_date_node status project keys) (HolbuildBuildPlan.selected_nodes plan)

fun build_one dat_hash_cache status options tc project base_context plan keys toolchain_key node =
  let
    val key = HolbuildBuildPlan.key node
    val label = HolbuildBuildPlan.logical_name node
    val _ = HolbuildStatus.start_node status key label
    val outcome = build_node dat_hash_cache options tc project base_context plan keys toolchain_key node
  in
    HolbuildStatus.finish_node status key label outcome;
    outcome
  end

fun outcome_may_create_checkpoints options project node outcome =
  case outcome of
      HolbuildStatus.Built =>
        (case #kind (HolbuildBuildPlan.source_of node) of
             HolbuildSourceIndex.TheoryScript => checkpoint_enabled (checkpoint_policy_for_node options project node)
           | _ => false)
    | _ => false

fun project_checkpoint_limit_gb project =
  Option.getOpt(HolbuildProject.checkpoint_limit_gb project, default_max_checkpoints_gb)

type checkpoint_watch = (string, Time.time option) Binarymap.dict

type checkpoint_budget_state =
  {checkpoint_dir : string,
   checkpoint_limit_gb : int,
   max_bytes : Position.int,
   index : checkpoint_index ref,
   watch : checkpoint_watch ref,
   index_bases : (string, unit) Binarymap.dict ref,
   refreshed : bool ref,
   mutex : Mutex.mutex}

fun checkpoint_dir_mtime path = SOME (FS.modTime path) handle OS.SysErr _ => NONE

fun same_mtime pair =
    case pair of
        (NONE, NONE) => true
      | (SOME a, SOME b) =>
          (case Time.compare(a, b) of
               EQUAL => true
             | _ => false)
      | _ => false

fun family_base_ancestors dir base =
  let
    val start = Path.dir base
    fun loop current acc =
      if current = dir then current :: acc
      else if path_under_dir current dir then
        let val parent = Path.dir current
        in if parent = current then acc else loop parent (current :: acc) end
      else acc
  in
    loop start []
  end

fun binarymap_in_domain (dict, key) =
  case Binarymap.peek (dict, key) of
      SOME _ => true
    | NONE => false

fun watch_insert_dir path watch =
  if binarymap_in_domain (watch, path) then watch
  else Binarymap.insert (watch, path, checkpoint_dir_mtime path)

(* Watch the checkpoint root and the ancestor closure of indexed family bases.
   Creating a new family normally bumps one of these directories.  A family
   planted under a pre-existing family-less deep directory can be missed until
   the end-of-build full rebuild; real theory layouts create families at member
   granularity, and generated top-level/member dirs still bump a watched
   ancestor. *)
fun watch_from_families dir families =
  let
    val empty = Binarymap.mkDict String.compare
    val with_root = watch_insert_dir dir empty
    fun add_family ({base, ...} : checkpoint_family, watch) =
      List.foldl (fn (path, acc) => watch_insert_dir path acc) watch (family_base_ancestors dir base)
  in
    List.foldl add_family with_root families
  end

fun bases_set_of families =
  List.foldl
    (fn ({base, ...} : checkpoint_family, acc) => Binarymap.insert (acc, base, ()))
    (Binarymap.mkDict String.compare)
    families

fun changed_watch_dirs (watch : checkpoint_watch) =
  Binarymap.foldl
    (fn (path, previous, changed) =>
        if same_mtime (previous, checkpoint_dir_mtime path) then changed else path :: changed)
    []
    watch

(* Enumerate candidate family bases reachable under root without summing file
   sizes.  Stop at the first checkpoint marker subtree so this remains a shallow
   directory walk rather than a recursive byte scan. *)
fun shallow_family_bases root =
  let
    fun walk path acc =
      if not (path_exists path) then acc
      else
        case checkpoint_marker_base path of
            SOME base => base :: acc
          | NONE =>
              if FS.isDir path handle OS.SysErr _ => false then
                List.foldl (fn (child, bases) => walk child bases) acc (children path)
              else acc
  in
    unique_strings (walk root [])
  end

fun checkpoint_budget_warnings checkpoint_limit_gb
      (eviction as {before_bytes, after_bytes, max_bytes, evicted} : checkpoint_eviction) =
  (if before_bytes > max_bytes orelse evicted > 0 then
     warn ("checkpoint budget: " ^ checkpoint_eviction_text eviction ^
           " checkpoint_limit_gb=" ^ Int.toString checkpoint_limit_gb)
   else ();
   if after_bytes > max_bytes then
     warn ("checkpoint budget still exceeds limit after eviction; check permissions or oversized live families")
   else ())

fun create_checkpoint_budget_state project =
  let
    val checkpoint_dir = project_state_dir project "checkpoints"
    val checkpoint_limit_gb = project_checkpoint_limit_gb project
    val dirty_path = checkpoint_index_dirty_path checkpoint_dir
    (* If the previous build was hard-killed mid-flight the marker is still
       present and the persisted index may under-count on-disk families; rebuild
       from disk in that case so the budget is enforced against ground truth. *)
    val index =
      if path_exists dirty_path then rebuild_checkpoint_index checkpoint_dir
      else load_or_rebuild_checkpoint_index checkpoint_dir
    val _ = (ensure_parent dirty_path; write_text dirty_path "building\n") handle _ => ()
  in
    {checkpoint_dir = checkpoint_dir,
     checkpoint_limit_gb = checkpoint_limit_gb,
     max_bytes = gb_to_bytes checkpoint_limit_gb,
     index = ref index,
     watch = ref (watch_from_families checkpoint_dir (#families index)),
     index_bases = ref (bases_set_of (#families index)),
     refreshed = ref false,
     mutex = Mutex.mutex ()}
  end

fun clear_checkpoint_index_dirty (state : checkpoint_budget_state) =
  remove_file (checkpoint_index_dirty_path (#checkpoint_dir state))

fun warn_checkpoint_budget_error e =
  warn ("checkpoint budget maintenance failed: " ^ General.exnMessage e)

fun with_checkpoint_budget_lock (state : checkpoint_budget_state) f =
  (Mutex.lock (#mutex state); f () before Mutex.unlock (#mutex state))
  handle e => (Mutex.unlock (#mutex state); raise e)

fun enforce_checkpoint_index_locked (state : checkpoint_budget_state) index protected_bases =
  let
    val (evicted_index, eviction) =
      evict_from_index_excluding index (#max_bytes state) protected_bases
    val _ = checkpoint_budget_warnings (#checkpoint_limit_gb state) eviction
    val {after_bytes, max_bytes, evicted, ...} = eviction
    val final_index =
      if evicted > 0 andalso after_bytes > max_bytes then
        rebuild_checkpoint_index (#checkpoint_dir state)
      else evicted_index
    (* Persisting the index must never fail the build: eviction already happened
       and the in-memory index is returned regardless. *)
    val _ = write_checkpoint_index_atomically final_index
            handle e => warn ("could not persist checkpoint index: " ^ General.exnMessage e)
  in
    final_index
  end

fun enforce_checkpoint_budget_state_excluding state protected_bases =
  detail_time_phase "build.exec.checkpoint_budget"
    (fn () =>
        (with_checkpoint_budget_lock state
          (fn () =>
              let
                val final_index = enforce_checkpoint_index_locked state (!(#index state)) protected_bases
              in
                #index state := final_index;
                #index_bases state := bases_set_of (#families final_index);
                #watch state := watch_from_families (#checkpoint_dir state) (#families final_index)
              end))
        handle e => warn_checkpoint_budget_error e)

fun rebuild_and_enforce_checkpoint_budget_state_excluding state protected_bases =
  detail_time_phase "build.exec.checkpoint_budget"
    (fn () =>
        (with_checkpoint_budget_lock state
          (fn () =>
              let
                val dir = #checkpoint_dir state
                val index' = rebuild_checkpoint_index dir
                val final_index = enforce_checkpoint_index_locked state index' protected_bases
              in
                #index state := final_index;
                #index_bases state := bases_set_of (#families final_index);
                #watch state := watch_from_families dir (#families final_index)
              end))
        handle e => warn_checkpoint_budget_error e)

fun refresh_checkpoint_budget_after_node state project node protected_bases =
  detail_time_phase "build.exec.checkpoint_budget"
    (fn () =>
        (let
           val dir = #checkpoint_dir state
           val base = checkpoint_base project node
           val changed = changed_watch_dirs (!(#watch state))
           val known = !(#index_bases state)
           val discovered =
             List.filter
               (fn candidate =>
                   not (binarymap_in_domain (known, candidate)) orelse
                   string_member candidate protected_bases)
               (List.concat (map shallow_family_bases changed))
           val measure_bases = unique_strings (base :: discovered)
           val measurements = map (fn candidate => (candidate, collect_checkpoint_family candidate)) measure_bases
         in
           with_checkpoint_budget_lock state
             (fn () =>
                 let
                   val index' = merge_checkpoint_family_measurements (!(#index state)) measurements
                   val final_index = enforce_checkpoint_index_locked state index' protected_bases
                 in
                   #index state := final_index;
                   #index_bases state := bases_set_of (#families final_index);
                   #watch state := watch_from_families dir (#families final_index);
                   #refreshed state := true
                 end)
         end)
        handle e => warn_checkpoint_budget_error e)

fun build_serial dat_hash_cache status options tc project base_context plan keys toolchain_key budget_state =
  let
    fun error_message e =
      case e of
          Error msg => msg
        | ErrorWithDebugArtifacts (msg, _) => msg
        | _ => General.exnMessage e
    fun error_debug_artifacts e =
      case e of
          ErrorWithDebugArtifacts (_, artifacts) => artifacts
        | _ => HolbuildStatus.no_debug_artifacts
    fun one node =
      build_one dat_hash_cache status options tc project base_context plan keys toolchain_key node
      handle e =>
        let
          val msg = error_message e
          val artifacts = error_debug_artifacts e
        in
          HolbuildStatus.fail_with_debug_artifacts
            status (HolbuildBuildPlan.key node) (HolbuildBuildPlan.logical_name node)
            msg artifacts;
          raise e
        end
    fun loop [] = ()
      | loop (node :: rest) =
          case one node of
              HolbuildStatus.Inspected => ()
            | outcome =>
                (if outcome_may_create_checkpoints options project node outcome then
                   refresh_checkpoint_budget_after_node budget_state project node []
                 else ();
                 loop rest)
  in
    loop (HolbuildBuildPlan.selected_nodes plan)
  end

fun node_done done node = List.exists (fn k => k = HolbuildBuildPlan.key node) done

fun deps_done plan done node =
  List.all (node_done done) (HolbuildBuildPlan.direct_project_deps plan node)

fun find_ready plan done pending =
  let
    fun loop prefix rest =
      case rest of
          [] => NONE
        | node :: suffix =>
            if deps_done plan done node then SOME (node, rev prefix @ suffix)
            else loop (node :: prefix) suffix
  in
    loop [] pending
  end

fun build_error_message e =
  case e of
      Error msg => msg
    | ErrorWithDebugArtifacts (msg, _) => msg
    | _ => General.exnMessage e

fun build_error_debug_artifacts e =
  case e of
      ErrorWithDebugArtifacts (_, artifacts) => artifacts
    | _ => HolbuildStatus.no_debug_artifacts

fun build_parallel dat_hash_cache status options tc project base_context plan keys toolchain_key jobs budget_state =
  let
    (* Keep scheduler state explicit and reusable: precompute reverse dependency
       edges once, then release dependents by decrementing remaining_dep counts.
       Do not add a serial all-up-to-date preflight in front of this path; that
       duplicates the unchanged-prefix work before any parallel worker can run. *)
    val selected = HolbuildBuildPlan.selected_nodes plan
    val node_count = length selected
    val nodes = Vector.fromList selected
    val key_index = HolbuildBuildPlan.build_key_index selected
    val remaining_deps = Array.array (node_count, 0)
    val dependents = Array.array (node_count, [] : int list)
    val ready = ref ([] : int list)
    val mutex = Mutex.mutex ()
    val cv = ConditionVar.conditionVar ()
    val running = ref 0
    val priority_running = ref 0
    val completed = ref 0
    val active = ref jobs
    val active_nodes = Array.array (node_count, false)
    val stopped = ref false
    val failure = ref (NONE : (string * HolbuildStatus.debug_artifacts) option)
    val failed_prefix_priority = Array.array (node_count, NONE : bool option)

    fun node_id node = HolbuildBuildPlan.indexed_key_id key_index (HolbuildBuildPlan.key node)

    val protected_bases_cache = Array.array (node_count, NONE : string list option)

    fun add_unique_base (base, bases) =
      if string_member base bases then bases else base :: bases

    fun add_bases (bases, acc) = List.foldl add_unique_base acc bases

    fun protected_bases_for_id id =
      case Array.sub (protected_bases_cache, id) of
          SOME bases => bases
        | NONE =>
            let
              val node = Vector.sub (nodes, id)
              val deps = HolbuildBuildPlan.direct_project_deps plan node
              val bases =
                List.foldl
                  (fn (dep, acc) => add_bases (protected_bases_for_id (node_id dep), acc))
                  [checkpoint_base project node]
                  deps
            in
              Array.update (protected_bases_cache, id, SOME bases);
              bases
            end

    fun precompute_protected_bases id =
      if id >= node_count then ()
      else (ignore (protected_bases_for_id id); precompute_protected_bases (id + 1))

    val _ = precompute_protected_bases 0

    fun add_ready id = ready := id :: !ready

    fun register_node (id, node) =
      let val deps = HolbuildBuildPlan.direct_project_deps plan node
      in
        Array.update (remaining_deps, id, length deps);
        if null deps then add_ready id else ();
        List.app
          (fn dep =>
              let val dep_id = node_id dep
              in Array.update (dependents, dep_id, id :: Array.sub (dependents, dep_id)) end)
          deps
      end

    fun register_nodes id =
      if id >= node_count then ()
      else (register_node (id, Vector.sub (nodes, id)); register_nodes (id + 1))

    val _ = register_nodes 0

    val priority_focus = Array.array (node_count, false)
    val priority_focus_remaining = ref 0
    val priority_mode = ref false

    fun mark_priority_focus id =
      if Array.sub (priority_focus, id) then ()
      else
        let
          val node = Vector.sub (nodes, id)
          val deps = HolbuildBuildPlan.direct_project_deps plan node
          val _ = Array.update (priority_focus, id, true)
          val _ = priority_focus_remaining := !priority_focus_remaining + 1
        in
          List.app (mark_priority_focus o node_id) deps
        end

    fun mark_priority_root id =
      if node_has_failed_prefix_checkpoint project (Vector.sub (nodes, id)) then
        (priority_mode := true; mark_priority_focus id)
      else ()
      handle _ => ()

    fun mark_priority_roots id =
      if id >= node_count then ()
      else (mark_priority_root id; mark_priority_roots (id + 1))

    val _ = mark_priority_roots 0

    fun signal () = ConditionVar.broadcast cv
    fun lock () = Mutex.lock mutex
    fun unlock () = Mutex.unlock mutex

    fun failed_prefix_priority_node id =
      case Array.sub (failed_prefix_priority, id) of
          SOME value => value
        | NONE =>
            let val value = node_has_failed_prefix_checkpoint project (Vector.sub (nodes, id))
                            handle _ => false
            in Array.update (failed_prefix_priority, id, SOME value); value end

    fun pop_matching_ready matches prefix rest =
      case rest of
          [] => NONE
        | id :: suffix =>
            if matches id then SOME (id, rev prefix @ suffix)
            else pop_matching_ready matches (id :: prefix) suffix

    fun priority_focus_node id = Array.sub (priority_focus, id)

    fun pop_ready () =
      case !ready of
          [] => NONE
        | id :: rest =>
            if !priority_mode andalso !priority_focus_remaining > 0 then
              (case pop_matching_ready priority_focus_node [] (id :: rest) of
                   SOME (focus_id, remaining) =>
                     (ready := remaining; SOME (focus_id, failed_prefix_priority_node focus_id))
                 | NONE => NONE)
            else
              (priority_mode := false;
               case pop_matching_ready failed_prefix_priority_node [] (id :: rest) of
                   SOME (priority_id, remaining) => (ready := remaining; SOME (priority_id, true))
                 | NONE =>
                     if !priority_running > 0 then NONE
                     else (ready := rest; SOME (id, false)))

    fun next_work_locked () =
      case !failure of
          SOME _ => NONE
        | NONE =>
            if !stopped then NONE
            else
              case pop_ready () of
                  SOME (id, priority) =>
                    (running := !running + 1;
                     Array.update (active_nodes, id, true);
                     if priority then priority_running := !priority_running + 1 else ();
                     SOME id)
                | NONE =>
                    if !completed = node_count andalso !running = 0 then NONE
                    else (ConditionVar.wait (cv, mutex); next_work_locked ())

    fun with_lock f =
      (lock (); f () before unlock ())
      handle e => (unlock (); raise e)

    fun next_work () = with_lock next_work_locked

    fun release_dependent child_id =
      let val remaining = Array.sub (remaining_deps, child_id) - 1
      in
        Array.update (remaining_deps, child_id, remaining);
        if remaining = 0 then add_ready child_id else ()
      end

    fun stop_requested () = with_lock (fn () => !stopped)

    fun finish_priority_focus id =
      if priority_focus_node id then priority_focus_remaining := !priority_focus_remaining - 1 else ()

    fun finish_priority id =
      (finish_priority_focus id;
       if failed_prefix_priority_node id then priority_running := !priority_running - 1 else ())

    fun active_node_ids_snapshot_locked () =
      let
        fun loop i acc =
          if i >= node_count then acc
          else loop (i + 1) (if Array.sub (active_nodes, i) then i :: acc else acc)
      in
        loop 0 []
      end

    fun protected_bases_for_ids ids =
      List.foldl (fn (id, acc) => add_bases (protected_bases_for_id id, acc)) [] ids

    fun finish_success id =
      with_lock
        (fn () =>
            let
              val _ = running := !running - 1
              val _ = Array.update (active_nodes, id, false)
              val _ = finish_priority id
              val _ = completed := !completed + 1
              val _ = if !stopped then () else List.app release_dependent (Array.sub (dependents, id))
              val protected = protected_bases_for_ids (id :: active_node_ids_snapshot_locked ())
            in
              signal ();
              protected
            end)

    fun finish_inspected id =
      let
        val first_stop =
          with_lock
            (fn () =>
                let
                  val _ = running := !running - 1
                  val _ = Array.update (active_nodes, id, false)
                  val _ = finish_priority id
                  val _ = completed := !completed + 1
                  val first = not (!stopped)
                  val _ = stopped := true
                in
                  signal ();
                  first
                end)
      in
        if first_stop then HolbuildToolchain.cleanup_active_children () else ()
      end

    fun finish_cancelled_after_stop id =
      with_lock (fn () => (running := !running - 1; Array.update (active_nodes, id, false); finish_priority id; signal ()))

    fun finish_failure id msg artifacts =
      let
        val first_failure =
          with_lock
            (fn () =>
                let
                  val _ = running := !running - 1
                  val _ = Array.update (active_nodes, id, false)
                  val _ = finish_priority id
                  val first =
                    if !stopped then false
                    else
                      case !failure of
                          SOME _ => false
                        | NONE => (failure := SOME (msg, artifacts); true)
                in
                  signal ();
                  first
                end)
      in
        if first_failure then HolbuildToolchain.cleanup_active_children () else ()
      end

    fun worker_exit () =
      with_lock (fn () => (active := !active - 1; signal ()))

    fun worker () =
      let
        fun loop () =
          case next_work () of
              NONE => worker_exit ()
            | SOME id =>
                let val node = Vector.sub (nodes, id)
                in
                  ((case build_one dat_hash_cache status options tc project base_context plan keys toolchain_key node of
                        HolbuildStatus.Inspected => finish_inspected id
                      | outcome =>
                          let val protected = finish_success id
                          in
                            if outcome_may_create_checkpoints options project node outcome then
                              refresh_checkpoint_budget_after_node budget_state project node protected
                            else ()
                          end;
                    loop ())
                   handle e =>
                     if stop_requested () then
                       (finish_cancelled_after_stop id; worker_exit ())
                     else
                       let
                         val msg = build_error_message e
                         val artifacts = build_error_debug_artifacts e
                       in
                         HolbuildStatus.fail_with_debug_artifacts
                           status (HolbuildBuildPlan.key node) (HolbuildBuildPlan.logical_name node)
                           msg artifacts;
                         finish_failure id msg artifacts;
                         worker_exit ()
                       end)
                end
      in
        loop ()
      end

    fun wait_workers_locked () =
      if !active = 0 then ()
      else (ConditionVar.wait (cv, mutex); wait_workers_locked ())

    fun wait_workers_result () =
      (lock (); wait_workers_locked (); !failure before unlock ())
      handle e => (unlock (); raise e)

    fun wait_worker_threads threads =
      if List.exists Thread.isActive threads then
        (OS.Process.sleep (Time.fromReal 0.05); wait_worker_threads threads)
      else ()

    fun raise_failure result =
      case result of
          NONE => ()
        | SOME (msg, artifacts) =>
            if HolbuildStatus.debug_artifacts_empty artifacts then raise Error msg
            else raise ErrorWithDebugArtifacts (msg, artifacts)
  in
    let
      val threads = List.tabulate (jobs, fn _ => Thread.fork (worker, []))
      val result = wait_workers_result ()
      val _ = wait_worker_threads threads
    in
      raise_failure result
    end
  end

fun write_text_atomic path text =
  let
    val tmp = path ^ ".tmp"
    val out = TextIO.openOut tmp
      handle e => raise Error ("could not write " ^ tmp ^ ": " ^ General.exnMessage e)
    fun close () = TextIO.closeOut out handle _ => ()
    fun remove_tmp () = FS.remove tmp handle _ => ()
  in
    (TextIO.output(out, text);
     TextIO.closeOut out;
     FS.rename {old = tmp, new = path}
       handle e => (remove_tmp ();
                    raise Error ("could not replace " ^ path ^ ": " ^ General.exnMessage e)))
    handle e => (close (); remove_tmp (); raise e)
  end

fun dump_key_row toolchain_key plan keys node =
  let
    val key = HolbuildBuildPlan.key node
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val dependency_key =
      case #kind (HolbuildBuildPlan.source_of node) of
          HolbuildSourceIndex.TheoryScript =>
            SOME (dependency_context_key toolchain_key plan keys node)
        | _ => NONE
    val line =
      case dependency_key of
          SOME deps_key => String.concat [key, "\t", input_key, "\t", deps_key]
        | NONE => String.concat [key, "\t", input_key]
  in
    (key, line)
  end

fun compare_dump_rows ((left, _), (right, _)) = String.compare(left, right)

fun dump_keys_if_requested toolchain_key plan keys =
  case OS.Process.getEnv "HOLBUILD_DUMP_KEYS" of
      NONE => ()
    | SOME path =>
        let
          val rows =
            HolbuildBuildPlan.sort_pairs compare_dump_rows
              (map (dump_key_row toolchain_key plan keys)
                   (HolbuildBuildPlan.selected_nodes plan))
          val text = String.concat (map (fn (_, line) => line ^ "\n") rows)
        in
          write_text_atomic path text
        end

fun build (options : build_options) tc project plan toolchain_key jobs =
  let
    val budget_state = create_checkpoint_budget_state project
    val _ = enforce_checkpoint_budget_state_excluding budget_state []
    val base_context = toolchain_base_context tc
    val keys = HolbuildBuildPlan.input_keys (build_config_lines_for_node options project) toolchain_key plan
    val _ = dump_keys_if_requested toolchain_key plan keys
    val dat_hash_cache = new_file_hash_cache ()
  in
    let
      val status = HolbuildStatus.create {total = length (HolbuildBuildPlan.selected_nodes plan), jobs = jobs}
      fun run () =
        if jobs <= 1 then build_serial dat_hash_cache status options tc project base_context plan keys toolchain_key budget_state
        else build_parallel dat_hash_cache status options tc project base_context plan keys toolchain_key jobs budget_state
    in
      (run (); HolbuildStatus.finish status;
       if !(#refreshed budget_state) then
         rebuild_and_enforce_checkpoint_budget_state_excluding budget_state []
       else
         enforce_checkpoint_budget_state_excluding budget_state [];
       clear_checkpoint_index_dirty budget_state)
      handle e => (HolbuildStatus.finish status;
                   rebuild_and_enforce_checkpoint_budget_state_excluding budget_state [];
                   clear_checkpoint_index_dirty budget_state;
                   raise e)
    end
  end

fun buildheap_arg heap_kind node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => load_stem node
    | HolbuildSourceIndex.Sml => load_stem node
    | HolbuildSourceIndex.Sig =>
      (case heap_kind of
           HolbuildProject.ExecutableImage _ => #source_path (HolbuildBuildPlan.source_of node)
         | HolbuildProject.HeapImage =>
           raise Error ("heap objects cannot be signature targets: " ^
                        HolbuildBuildPlan.logical_name node))

fun buildheap_args heap_kind plan = map (buildheap_arg heap_kind) (HolbuildBuildPlan.selected_nodes plan)

fun export_heap tc (project : HolbuildProject.t) plan output heap_kind =
  let
    val stage = Path.concat(Path.concat(project_artifact_root project, ".holbuild/stage"), "heap")
    val log = Path.concat(stage, "holbuild-heap.log")
    val base_args = HolbuildToolchain.hol_subcommand_argv tc "buildheap" @
                    ["--noconfig", "--holstate", HolbuildToolchain.base_state tc, "-F"]
    val exe_args =
      case heap_kind of
          HolbuildProject.HeapImage => []
        | HolbuildProject.ExecutableImage {main} => ["--exe=" ^ main]
    val argv = base_args @ exe_args @ ["-o", output] @ buildheap_args heap_kind plan
    val _ = ensure_dir stage
    val _ = ensure_parent output
    val status = HolbuildToolchain.run_in_dir_to_file (#root project) argv log
  in
    if HolbuildToolchain.success status then
      (if echo_child_logs () then HolbuildStatus.message_stdout (read_text log handle _ => "") else ();
       remove_tree stage)
    else
      raise Error (String.concatWith "\n"
        ["hol buildheap failed while exporting heap: " ^ output,
         child_log_detail log])
  end

end
