structure HolbuildBuildExec =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string
exception ErrorWithDebugArtifacts of string * HolbuildStatus.debug_artifacts
exception ExecutionPlanPrinted
exception RetryInvalidCheckpoint

fun normalize_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun warn msg = HolbuildStatus.message_stderr ("holbuild: warning: " ^ msg ^ "\n")

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
  HolbuildTempPath.near path ".tmp"

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun rename_replace {old, new} =
  FS.rename {old = old, new = new}
  handle OS.SysErr _ =>
    (FS.remove new handle OS.SysErr _ => ();
     FS.rename {old = old, new = new})

val remove_tree = HolbuildRemoveTree.remove

fun remove_trees paths = List.app remove_tree paths

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

fun link_or_copy {src, dst} =
  HolbuildCache.link_or_copy {src = src, dst = dst}
  handle HolbuildCache.Error msg => raise Error msg

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
fun source_deps plan node = HolbuildBuildPlan.dependencies plan node
fun source_extra_output_declarations plan node = #extra_outputs (source_deps plan node)
fun source_extra_output_path node declaration =
  normalize_path (Path.concat(Path.dir (source_file node), declaration))
fun source_extra_output_paths plan node =
  map (source_extra_output_path node) (source_extra_output_declarations plan node)
fun staged_extra_output_path stage declaration = normalize_path (Path.concat(stage, declaration))
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

(* What a theory's preload loads, in order. *)
datatype theory_load =
    LoadTheory of string   (* a HOL theory, by name *)
  | LoadLibrary of string  (* a HOL library, by name *)
  | LoadObject of string   (* a project theory or library: its object stem in the action root *)

(* A theory action: everything building one theory needs, without the build
   plan.  Paths in the action root, the directory that holds `.holbuild/`,
   are relative to it and made absolute only when the action runs: the
   preload's objects and `outputs`.  `inputs` are staged under
   the stage root, which mirrors the package layout; each `path` is relative
   to it, and `from` says where the file's bytes are read.  `script_dir` is
   the script's directory in the stage ("" when the script lies outside its
   package root), `extra_outputs` are declared relative to it, and
   `source_file` is where the script is read from and what diagnostics name.
   `inputs_key` hashes the extra inputs, for the checkpoint keys. *)
type theory_action =
  {input_key : string,
   deps_key : string,
   inputs_key : string option,
   package : string,
   logical : string,
   relative_path : string,
   source_file : string,
   source_name : string,
   script_dir : string,
   inputs : {path : string, from : string} list,
   loads : theory_load list,
   outputs : {sig_path : string, sml_path : string, data_path : string},
   extra_outputs : string list}

fun in_root root path = if Path.isAbsolute path then path else Path.concat(root, path)

fun root_relative root path =
  let
    val prefix = if has_suffix "/" root then root else root ^ "/"
    val rel = if String.isPrefix prefix path then String.extract(path, size prefix, NONE) else ""
  in
    if rel <> "" andalso in_root root rel = path then rel
    else raise Error ("internal error: " ^ path ^ " is not under the action root " ^ root)
  end

fun theory_load_line _ (LoadTheory name) = load_theory_line name
  | theory_load_line _ (LoadLibrary name) = load_project_line name
  | theory_load_line root (LoadObject stem) = load_project_line (in_root root stem)

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

(* An action `deps` entry orders builds but must not itself be loaded into the
   HOL session: loading it causes HOL to export the dependency as a theory
   parent.  Only source-discovered loads/mentions and explicit action `loads`
   belong in the preload heap. *)
fun project_preload_deps plan node =
  let
    val source = HolbuildBuildPlan.source_of node
    val deps = source_deps plan node
    val load_names =
      unique_strings
        (#loads deps @ #holdep_mentions deps @
         HolbuildProject.action_loads (#policy source))
    fun signature_companion dep =
      #kind source = HolbuildSourceIndex.Sml andalso
      #kind (HolbuildBuildPlan.source_of dep) = HolbuildSourceIndex.Sig andalso
      HolbuildBuildPlan.package dep = HolbuildBuildPlan.package node andalso
      HolbuildBuildPlan.logical_name dep = HolbuildBuildPlan.logical_name node
    fun needed dep = List.exists (fn name => name = HolbuildBuildPlan.logical_name dep) load_names orelse
                     signature_companion dep
  in
    List.filter needed (HolbuildBuildPlan.direct_project_deps plan node)
  end

fun preload_loads root plan node =
  map LoadTheory (HolbuildBuildPlan.direct_external_theories plan node) @
  map LoadLibrary (HolbuildBuildPlan.direct_external_libs plan node) @
  map (fn dep => LoadObject (root_relative root (load_stem dep)))
      (List.filter loadable_project_dep (project_preload_deps plan node))

fun write_preload load_lines deps_loaded deps_ok path =
  let
    val lines = runtime_line () ::
                (load_lines @
                 [checkpoint_save_runtime_line (),
                  save_heap_line {label = "deps_loaded", share_common_data = true,
                                  output = deps_loaded, ok_text = deps_ok}])
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

fun write_plain_preload load_lines path =
  write_text path (String.concatWith "\n" (runtime_line () :: load_lines) ^ "\n")

(* HOL's theory exporter enables generated HTML documentation by default.  A
   holbuild child runs in a disposable stage and these files are not build
   artifacts, so generating them only adds pretty-printing and I/O to the
   critical export path.  Keep this policy in its own first-loaded file: unlike
   the regular preload, it must also run when a child resumes from any saved
   checkpoint.  The trace was renamed in HOL, so tolerate either spelling. *)
val child_policy_traces = ["TheoryPP.include_docs", "TheoryPP.include_html_docs"]

fun write_child_policy tc path =
  let
    val directory = HolbuildCache.theory_modules_dir
                      (Path.mkAbsolute {path = HolbuildCacheConfig.cache_root (),
                                        relativeTo = FS.getDir ()})
    val configure =
      "val _ = Meta.configureTheoryModuleCache {directory = " ^
      HolbuildToolchain.sml_string directory ^ ", base_state = " ^
      HolbuildToolchain.sml_string (HolbuildToolchain.base_state tc) ^ "};"
    (* Older HOL installations keep their source loader.  Compile the call
       only after checking the optional capability in the live namespace. *)
    val module_cache =
      "val _ = case #lookupStruct PolyML.globalNameSpace \"Meta\" of " ^
      "NONE => () | SOME meta => " ^
      "if Option.isSome (#lookupVal (PolyML.NameSpace.Structures.contents meta) " ^
      "\"configureTheoryModuleCache\") then " ^
      "CompilerSpecific.quietbind " ^ HolbuildToolchain.sml_string configure ^
      "else ();"
  in
    write_text path
      (String.concat
         (map (fn trace => "val _ = (Feedback.set_trace " ^ HolbuildToolchain.sml_string trace ^
                           " 0 handle _ => ());\n")
              child_policy_traces) ^ module_cache ^ "\n")
  end

(* Checkpoints are saved with the child policy in effect.  A `run --from`
   session loads these lines so it exports theories as a plain run does. *)
val child_policy_reset_lines =
  map (fn trace => "val _ = (Feedback.reset_trace " ^ HolbuildToolchain.sml_string trace ^
                   " handle _ => ());")
      child_policy_traces

fun generated_metadata_report_lines {parents_report, mldeps_report} =
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

fun hfs_unmapped_path path =
  let
    val {dir, file} = Path.splitDirFile path
    val {dir = parent, file = leaf} = Path.splitDirFile dir
  in
    if leaf = "objs" andalso Path.file parent = ".hol" then
      Path.concat(Path.dir parent, file)
    else path
  end

(* Export now seals a theory in current HOL versions, so the source child
   captures metadata and exports, but never loads the generated theory module. *)
(* The exporter is the child's last file, so the child's peak resident set
   size is known there: it records /proc/self/status's VmHWM line beside
   itself, where it can, for a remote worker's result record. *)
val peak_rss_report_name = "holbuild-peak-rss.txt"

fun peak_rss_report_line path =
  String.concat
    ["val _ = let fun find s = case TextIO.inputLine s of NONE => \"\" ",
     "| SOME l => if String.isPrefix \"VmHWM:\" l then l else find s; ",
     "val s = TextIO.openIn \"/proc/self/status\"; val l = find s before TextIO.closeIn s; ",
     "val out = TextIO.openOut ", HolbuildToolchain.sml_string path, " ",
     "in TextIO.output (out, l); TextIO.closeOut out end handle _ => ();"]

fun write_theory_exporter {sig_path, path, parents_report, mldeps_report} =
  let
    val produce = "Meta.produceTheoryModule " ^
      HolbuildToolchain.sml_string
        (hfs_unmapped_path (drop_suffix ".sig" sig_path ^ ".sml")) ^ ";"
    val module_producer =
      "val _ = case #lookupStruct PolyML.globalNameSpace \"Meta\" of " ^
      "NONE => () | SOME meta => " ^
      "if Option.isSome (#lookupVal (PolyML.NameSpace.Structures.contents meta) " ^
      "\"produceTheoryModule\") then CompilerSpecific.quietbind " ^
      HolbuildToolchain.sml_string produce ^ " else ();"
    val lines =
      generated_metadata_report_lines {parents_report = parents_report,
                                       mldeps_report = mldeps_report} @
      [export_theory_if_needed_line sig_path,
       "val _ = HolbuildRuntime.normalize_theory_export " ^ HolbuildToolchain.sml_string sig_path ^ ";",
       module_producer,
       peak_rss_report_line (Path.concat(Path.dir path, peak_rss_report_name))]
  in
    write_text path (String.concatWith "\n" lines ^ "\n")
  end

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

datatype extra_output_owner = ExtraOutputOwner of
  {package : string, source : string, logical : string}

fun extra_output_owner node =
  ExtraOutputOwner
    {package = package node,
     source = HolbuildBuildPlan.relative_path node,
     logical = logical_name node}

fun same_extra_output_owner
      (ExtraOutputOwner {package = left_package, source = left_source, ...},
       ExtraOutputOwner {package = right_package, source = right_source, ...}) =
  left_package = right_package andalso left_source = right_source

fun extra_output_owner_text (ExtraOutputOwner {package, source, logical}) =
  package ^ ":" ^ logical ^ " (" ^ source ^ ")"

fun extra_output_registry_path_exists path =
  FS.access(path, []) handle OS.SysErr _ => false

fun extra_output_registry_root project =
  Path.concat(project_artifact_root project, ".holbuild/extra-outputs")

fun extra_output_claim_path project output =
  Path.concat(Path.concat(extra_output_registry_root project, "owners"),
              HolbuildHash.string_sha256 output ^ ".owner")

fun extra_output_action_path project node =
  let
    val ExtraOutputOwner {package, source, ...} = extra_output_owner node
    val identity = package ^ "\000" ^ source
  in
    Path.concat(Path.concat(extra_output_registry_root project, "actions"),
                HolbuildHash.string_sha256 identity ^ ".outputs")
  end

fun extra_output_owner_fields (ExtraOutputOwner {package, source, logical}) =
  [package, source, logical]

fun extra_output_claim_text owner output =
  String.concatWith "\n"
    ["holbuild-extra-output-owner-v1",
     HolbuildAnalysisProtocol.join ("owner" :: extra_output_owner_fields owner),
     HolbuildAnalysisProtocol.join ["path", output]] ^ "\n"

fun parse_extra_output_claim path text =
  case String.tokens (fn c => c = #"\n") text of
      [version, owner_line, path_line] =>
        (case (version, HolbuildAnalysisProtocol.split owner_line,
                HolbuildAnalysisProtocol.split path_line) of
             ("holbuild-extra-output-owner-v1", ["owner", package, source, logical],
              ["path", output]) =>
               (ExtraOutputOwner {package = package, source = source, logical = logical}, output)
           | _ => raise Error ("invalid extra-output ownership record: " ^ path))
    | _ => raise Error ("invalid extra-output ownership record: " ^ path)

fun read_extra_output_claim project output =
  let val path = extra_output_claim_path project output
  in
    if extra_output_registry_path_exists path then
      let val (owner, recorded_output) = parse_extra_output_claim path (read_text path)
      in
        if recorded_output = output then SOME owner
        else raise Error ("extra-output ownership record path mismatch: " ^ path)
      end
    else NONE
  end

fun extra_output_action_text owner outputs =
  String.concatWith "\n"
    (["holbuild-extra-output-action-v1",
      HolbuildAnalysisProtocol.join ("owner" :: extra_output_owner_fields owner)] @
     map (fn output => HolbuildAnalysisProtocol.join ["path", output]) outputs) ^ "\n"

fun parse_extra_output_action path expected_owner text =
  case String.tokens (fn c => c = #"\n") text of
      version :: owner_line :: output_lines =>
        (case (version, HolbuildAnalysisProtocol.split owner_line) of
             ("holbuild-extra-output-action-v1", ["owner", package, source, logical]) =>
               let
                 val owner = ExtraOutputOwner {package = package, source = source, logical = logical}
                 fun output line =
                   case HolbuildAnalysisProtocol.split line of
                       ["path", value] => value
                     | _ => raise Error ("invalid extra-output action record: " ^ path)
               in
                 if same_extra_output_owner (owner, expected_owner) then map output output_lines
                 else raise Error ("extra-output action record owner mismatch: " ^ path)
               end
           | _ => raise Error ("invalid extra-output action record: " ^ path))
    | _ => raise Error ("invalid extra-output action record: " ^ path)

fun recorded_extra_outputs project node =
  let val path = extra_output_action_path project node
  in
    if extra_output_registry_path_exists path then
      parse_extra_output_action path (extra_output_owner node) (read_text path)
    else []
  end

fun member_string value values = List.exists (fn existing => existing = value) values

fun claim_extra_outputs project node outputs =
  let
    val owner = extra_output_owner node
    val recorded = recorded_extra_outputs project node
    val created = ref ([] : string list)
    fun claim output =
      let val path = extra_output_claim_path project output
      in
        case read_extra_output_claim project output of
            NONE =>
              if extra_output_registry_path_exists output andalso
                 not (member_string output recorded) then
                raise Error ("extra output already exists without an ownership record: " ^ output)
              else (write_text path (extra_output_claim_text owner output);
                    created := path :: !created)
          | SOME existing =>
              if same_extra_output_owner (owner, existing) then ()
              else raise Error ("extra output is already owned: " ^ output ^ " by " ^
                                extra_output_owner_text existing)
      end
  in
    (List.app claim outputs)
    handle e => (List.app remove_file (!created); raise e)
  end

fun release_extra_output project owner strict output =
  let val claim_path = extra_output_claim_path project output
  in
    case read_extra_output_claim project output of
        SOME existing =>
          if same_extra_output_owner (owner, existing) then
            (remove_file output; remove_file claim_path)
          else if strict then
            raise Error ("refusing to remove extra output owned by " ^
                         extra_output_owner_text existing ^ ": " ^ output)
          else ()
      | NONE =>
          if strict andalso extra_output_registry_path_exists output then
            raise Error ("extra output has no ownership record; refusing to remove: " ^ output)
          else ()
  end

fun record_materialized_extra_outputs project node outputs =
  let
    val owner = extra_output_owner node
    val previous = recorded_extra_outputs project node
    val obsolete = List.filter (fn output => not (member_string output outputs)) previous
    val _ = List.app (release_extra_output project owner true) obsolete
    val action_path = extra_output_action_path project node
  in
    if null outputs then remove_file action_path
    else write_text action_path (extra_output_action_text owner outputs)
  end

fun clean_registered_extra_outputs project plan node =
  let
    val owner = extra_output_owner node
    val recorded = recorded_extra_outputs project node
    val current = source_extra_output_paths plan node
    val unrecorded = List.filter (fn output => not (member_string output recorded)) current
    val _ = List.app (release_extra_output project owner true) recorded
    val _ = List.app (release_extra_output project owner false) unrecorded
  in
    remove_file (extra_output_action_path project node)
  end

fun stage_root_at root input_key = Path.concat(Path.concat(root, ".holbuild/stage"), input_key)

fun stage_dir (project : HolbuildProject.t) input_key = stage_root_at (project_artifact_root project) input_key

(* A theory's latest child logs, under its action root. *)
fun current_log_dir root package logical =
  Path.concat(Path.concat(Path.concat(Path.concat(root, ".holbuild/logs"), "current"), package), logical)

fun current_build_log dir = Path.concat(dir, "build.log")
fun current_checkpoint_failure_log dir = Path.concat(dir, "instrumented-failure.log")
fun current_proof_trace_log dir = Path.concat(dir, "proof-trace.log")

fun staged_theory_file stage logical ext = Path.concat(Path.concat(stage, ".hol/objs"), logical ^ ext)
fun staged_dat_reference stage logical = Path.concat(stage, logical ^ ".dat")

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

(* The script's path in recorded theorem locations, in holpathdb form so that
   a cached theory carries no path of the checkout that built it: HOL's own
   sources under `$(HOLDIR)`, as HOL records them, and other packages under
   their package name. *)
fun located_source_name holdir node =
  case holpath_reference (canonical_path (source_file node)) (canonical_path holdir) "HOLDIR" of
      SOME name => name
    | NONE => "$(" ^ package node ^ ")/" ^ HolbuildBuildPlan.relative_path node

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

fun stage_dat_references stage logical =
  let val path = staged_dat_reference stage logical
  in unique_strings (path :: holpath_stage_references path) end

fun stage_dat_replacements stage logical final_dat =
  map (fn path_ref => (path_ref, final_dat)) (stage_dat_references stage logical)

(* A theory's checkpoints live under one base path in a checkpoint root, by
   default the one in its action root; the functions below take that base. *)
fun default_checkpoint_root root = Path.concat(root, ".holbuild/checkpoints")

fun checkpoint_base_in checkpoint_root package relative_path =
  Path.concat(Path.concat(checkpoint_root, package), relative_path)

fun checkpoint_base_at root package relative_path =
  checkpoint_base_in (default_checkpoint_root root) package relative_path

fun checkpoint_base (project : HolbuildProject.t) node =
  checkpoint_base_at (project_artifact_root project) (HolbuildBuildPlan.package node)
    (HolbuildBuildPlan.relative_path node)

fun deps_checkpoint_root base = base ^ ".deps"

fun deps_loaded_path base deps_key =
  Path.concat(Path.concat(deps_checkpoint_root base, deps_key), "deps_loaded.save")

fun theorem_checkpoint_root base = base ^ ".theorems"

fun theorem_checkpoints_for_deps_root base deps_key =
  Path.concat(theorem_checkpoint_root base, deps_key)

fun theorem_checkpoint_dir base deps_key proof_engine prefix_hash =
  Path.concat(Path.concat(theorem_checkpoints_for_deps_root base deps_key, proof_engine), prefix_hash)

fun declaration_checkpoint_root base = base ^ ".decls"

fun declaration_checkpoints_for_deps_root base deps_key =
  Path.concat(declaration_checkpoint_root base, deps_key)

fun declaration_checkpoint_dir base deps_key proof_engine prefix_hash =
  Path.concat(Path.concat(declaration_checkpoints_for_deps_root base deps_key, proof_engine), prefix_hash)

fun remove_legacy_checkpoint_family base =
  let
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

fun remove_theorem_checkpoints_for_deps base deps_key =
  remove_tree (theorem_checkpoints_for_deps_root base deps_key)

fun remove_declaration_checkpoints_for_deps base deps_key =
  remove_tree (declaration_checkpoints_for_deps_root base deps_key)

(* Delete these before deleting or replacing the deps parent.  A deps heap path
   is stable for a deps_key, so surviving descendants must never outlive
   deletion of that parent path. *)
fun remove_deps_checkpoint_descendants base deps_key =
  (remove_theorem_checkpoints_for_deps base deps_key;
   remove_declaration_checkpoints_for_deps base deps_key)

fun remove_deps_checkpoint_family base deps_key deps_loaded =
  (remove_deps_checkpoint_descendants base deps_key;
   remove_checkpoint deps_loaded)

fun remove_checkpoint_family base =
  (remove_legacy_checkpoint_family base;
   remove_trees [base ^ ".theorems", base ^ ".decls", base ^ ".deps"])

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

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
  contains_failed_prefix_ok (theorem_checkpoint_root (checkpoint_base project node))

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
  has_suffix ".meta" path orelse has_suffix ".prefix" path orelse
  has_suffix ".steps" path

fun remove_empty_dir path = FS.rmDir path handle OS.SysErr _ => ()

fun remove_empty_dirs dir =
  if not (path_exists dir) orelse not (FS.isDir dir handle OS.SysErr _ => false) then ()
  else
    (List.app remove_empty_dirs (children dir);
     remove_empty_dir dir)

fun checkpoint_save_artifact_base path =
  if has_suffix ".save.ok.tmp" path then SOME (drop_suffix ".ok.tmp" path)
  else if has_suffix ".save.ok.bak" path then SOME (drop_suffix ".ok.bak" path)
  else if has_suffix ".save.ok" path then SOME (drop_suffix ".ok" path)
  else if has_suffix ".save.tmp" path then SOME (drop_suffix ".tmp" path)
  else if has_suffix ".save.bak" path then SOME (drop_suffix ".bak" path)
  else if has_suffix ".meta" path then SOME (drop_suffix ".meta" path)
  else if has_suffix ".prefix" path then SOME (drop_suffix ".prefix" path)
  else if has_suffix ".steps" path then SOME (drop_suffix ".steps" path)
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
    (* Older holbuild versions saved a .final_context.save beside each theory
       checkpoint; it still belongs to that family, so cleaning removes it. *)
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
    else if has_suffix ".final_context.save.steps" name then
      SOME (Path.concat(Path.dir path, drop_suffix ".final_context.save.steps" name))
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
  (remove_trees [base ^ ".theorems", base ^ ".decls", base ^ ".deps"];
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
    [base,
     base ^ ".ok",
     base ^ ".tmp",
     base ^ ".ok.tmp",
     base ^ ".bak",
     base ^ ".ok.bak",
     base ^ ".meta",
     base ^ ".prefix",
     base ^ ".steps",
     base ^ ".theorems",
     base ^ ".decls",
     base ^ ".deps",
     final_context,
     final_context ^ ".ok",
     final_context ^ ".tmp",
     final_context ^ ".ok.tmp",
     final_context ^ ".bak",
     final_context ^ ".ok.bak",
     final_context ^ ".meta",
     final_context ^ ".prefix",
     final_context ^ ".steps"]
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

(* Version two invalidates indexes written by builds predating the dirty-marker
   persistence fixes.  Such an index can look syntactically valid while naming
   families that were already evicted and omitting all of the current families. *)
val checkpoint_index_header = "holbuild-checkpoint-index-v2"

fun checkpoint_index_path dir = Path.concat(dir, ".index-v2")

fun checkpoint_index_tmp_path dir = Path.concat(dir, ".index-v2.tmp")

fun legacy_checkpoint_index_path dir = Path.concat(dir, ".index-v1")

fun legacy_checkpoint_index_tmp_path dir = Path.concat(dir, ".index-v1.tmp")

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

(* Discover checkpoint family topology without measuring artifact sizes.  Marker
   directories can contain thousands of heap segments, so stop as soon as one
   checkpoint artifact proves that the family is non-empty.  Ordinary save
   files and sidecars outside marker directories must also be included: older
   holbuild versions can leave either layout behind. *)
fun checkpoint_tree_has_artifact path =
  if not (path_exists path) then false
  else if FS.isDir path handle OS.SysErr _ => false then
    List.exists checkpoint_tree_has_artifact (children path)
  else checkpoint_clean_artifact path

fun checkpoint_family_bases_on_disk root =
  let
    fun add_base base bases = Binaryset.add (bases, base)
    fun walk path bases =
      if not (path_exists path) then bases
      else
        case checkpoint_marker_base path of
            SOME base =>
              if checkpoint_tree_has_artifact path then add_base base bases else bases
          | NONE =>
              if FS.isDir path handle OS.SysErr _ => false then
                List.foldl (fn (child, acc) => walk child acc) bases (children path)
              else
                (case checkpoint_save_artifact_base path of
                     SOME base => add_base base bases
                   | NONE => bases)
  in
    Binaryset.listItems (walk root (Binaryset.empty String.compare))
  end

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
     rename_replace {old = tmp, new = path};
     remove_file (legacy_checkpoint_index_tmp_path dir);
     remove_file (legacy_checkpoint_index_path dir))
    handle e => (close_output (); remove_file tmp; raise e)
  end

fun rebuild_checkpoint_index dir =
  checkpoint_index_with_families dir (collect_checkpoint_families dir)

fun checkpoint_index_roots_exist ({families, ...} : checkpoint_index) =
  List.all (fn ({base, ...} : checkpoint_family) => checkpoint_family_root_exists base)
           families

fun checkpoint_index_covers_disk
      ({dir, families, ...} : checkpoint_index) =
  let
    val indexed =
      List.foldl
        (fn ({base, ...} : checkpoint_family, bases) => Binaryset.add (bases, base))
        (Binaryset.empty String.compare)
        families
  in
    List.all (fn base => Binaryset.member (indexed, base))
             (checkpoint_family_bases_on_disk dir)
  end

fun load_or_rebuild_checkpoint_index dir =
  case read_checkpoint_index dir of
      SOME index => if checkpoint_index_roots_exist index andalso
                       checkpoint_index_covers_disk index then index
                    else rebuild_checkpoint_index dir
    | NONE => rebuild_checkpoint_index dir

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

(* Oldest first. *)
fun sort_by_mtime_ascending (mtime_of : 'a -> Time.time) families =
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
        | (x :: xs, y :: ys) =>
            if Time.<=(mtime_of x, mtime_of y) then x :: merge xs right
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

fun sort_families_by_mtime_ascending families =
  sort_by_mtime_ascending (fn ({mtime, ...} : checkpoint_family) => mtime) families

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
              val _ = remove_checkpoint_family_base base
            in
              if checkpoint_family_root_exists base then
                (warn ("could not completely evict checkpoint family: " ^ base);
                 evict rest freed removed removed_bases)
              else
                let
                  val freed' = freed + bytes
                  val removed' = removed + 1
                  val removed_bases' = base :: removed_bases
                in
                  if before_bytes - freed' <= max_bytes then
                    (freed', removed', removed_bases')
                  else evict rest freed' removed' removed_bases'
                end
            end
    val over_budget = not (max_bytes <= 0 orelse before_bytes <= max_bytes)
    val (freed, evicted, removed_bases) =
      if over_budget then evict sorted 0 0 [] else (0 : Position.int, 0, [])
    val families' =
      List.filter (fn ({base, ...} : checkpoint_family) => not (string_member base removed_bases)) families
    val after_bytes = before_bytes - freed
    val index' = {dir = dir, families = families', total_bytes = after_bytes}
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

fun file_hash path = HolbuildStatCache.file_sha256 (HolbuildStatCache.current_instance ()) path

(* HOL records each parent theory as the SHA-1 of the parent's .dat file
   (Theory.sml's export), so checking those records needs HOL's hash, not
   holbuild's own. *)
fun hol_dat_hash path =
  if HolbuildHash.large_file path then
    case HolbuildHash.external_hash "sha1sum" (HolbuildHash.valid_hex 40) path of
        SOME hash => hash
      | NONE => SHA1_ML.sha1_file {filename = path}
  else SHA1_ML.sha1_file {filename = path}

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
        (case (SOME (hol_dat_hash path) handle _ => NONE) of
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

fun sort_strings xs =
  let
    fun insert x [] = [x]
      | insert x (y :: ys) =
          if String.compare(x, y) = LESS then x :: y :: ys else y :: insert x ys
  in
    List.foldl (fn (x, acc) => insert x acc) [] xs
  end

fun expand_extra_dep base decl =
  HolbuildBuildPlan.expand_extra_dep base decl
  handle HolbuildBuildPlan.Error msg => raise Error msg

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
val cache_trace = HolbuildStatus.cache_trace

fun hol_run_file_arg stage file =
  if canonical_path (Path.dir file) = canonical_path stage then Path.file file else file

(* The exit status of the latest HOL child, NONE while one is starting.
   exec-action tells a failure of the HOL run itself from an error around
   it, and an OOM kill from another failure, by this. *)
val last_child_status : OS.Process.status option ref = ref NONE

(* HOL's `use` remembers a source parse error in the heap and, with
   failOnError set as `hol run` sets it, exits with failure after the next
   top-level declaration.  A checkpoint saved after such an error (holbuild
   before 0.13.7 saved them) carries it, so a run from it exits on its first
   declaration before printing anything.
   A failure exit with an empty log is reported with this marker; a death by
   signal (the shell's 128 + n) is not. *)
val hol_silent_exit_marker = "HOL exited without output"

fun silent_exit_detail status log =
  case Posix.Process.fromStatus status of
      Posix.Process.W_EXITSTATUS w =>
        if w <= 0w128 andalso file_size log = 0 then
          [hol_silent_exit_marker ^ " (exit status " ^ Word8.fmt StringCvt.DEC w ^ ")"]
        else []
    | _ => []

fun run_hol_files_to_log tc stage workdir context files log_name current_log error_message =
  let
    val log = Path.concat(stage, log_name)
    val file_args = map (hol_run_file_arg workdir) files
    val _ = ensure_parent log
    val _ = create_current_log_link log current_log
    val _ = last_child_status := NONE
    val status =
      HolbuildToolchain.run_in_dir_to_file workdir
        (HolbuildToolchain.theory_run_argv tc @ ["--noconfig"] @ hol_context_args context @ file_args)
        log
      handle HolbuildToolchain.Error msg => raise Error msg
    val _ = last_child_status := SOME status
    val detail_log = finalize_current_log log current_log
  in
    if HolbuildToolchain.success status then
      if echo_child_logs () then HolbuildStatus.message_stdout (read_text log handle _ => "") else ()
    else
      raise Error (String.concatWith "\n"
        ([error_message] @ silent_exit_detail status log @ [child_log_detail detail_log]))
  end

fun toolchain_base_context tc = HolState (HolbuildToolchain.base_state tc)

val cache_sml_token = "__HOLBUILD_THEORY_DAT_LOAD__"

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

(* The marker is the line after the first, where run_hol_files_to_log puts
   it; the child's own output comes later, after "--- child log tail ---". *)
fun hol_silent_exit_line text =
  case String.fields (fn c => c = #"\n") text of
      _ :: second :: _ =>
        if String.isPrefix hol_silent_exit_marker second then SOME second else NONE
    | _ => NONE

fun hol_silent_exit_failure text = Option.isSome (hol_silent_exit_line text)

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

fun remove_source_checkpoints_for_deps base deps_key =
  (remove_theorem_checkpoints_for_deps base deps_key;
   remove_declaration_checkpoints_for_deps base deps_key)

fun remove_loaded_checkpoint_descendants base deps_key deps_loaded theorem_checkpoints declaration_checkpoints loaded_path =
  if loaded_path = deps_loaded then
    remove_deps_checkpoint_family base deps_key deps_loaded
  else
    case List.find (theorem_failed_prefix_path loaded_path) theorem_checkpoints of
        SOME checkpoint => remove_checkpoint (#failed_prefix_path checkpoint)
      | NONE =>
          case List.find (theorem_context_or_end_path loaded_path) theorem_checkpoints of
              SOME _ => remove_source_checkpoints_for_deps base deps_key
            | NONE =>
                case List.find (declaration_context_path_matches loaded_path) declaration_checkpoints of
                    SOME _ => remove_source_checkpoints_for_deps base deps_key
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

fun checkpoint_failure_output log_dir stage =
  retained_or_ephemeral_output
    (HolbuildStatus.retain_debug_artifacts ())
    (stage_build_output stage)
    (current_checkpoint_failure_log log_dir)

fun proof_trace_output log_dir stage =
  retained_or_ephemeral_output
    (HolbuildStatus.retain_debug_artifacts ())
    (stage_build_output stage)
    (current_proof_trace_log log_dir)

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

val parse_timeout_text = HolbuildTheoryCacheManifest.parse_timeout_text
val timeout_satisfies = HolbuildTheoryCacheManifest.timeout_satisfies

fun cache_timeout_satisfies allow_discrepancy requested built =
  allow_discrepancy orelse timeout_satisfies requested built

fun timeout_min (NONE, timeout) = timeout
  | timeout_min (timeout, NONE) = timeout
  | timeout_min (SOME a, SOME b) = SOME (Real.min(a, b))

fun timeout_equal (NONE, NONE) = true
  | timeout_equal (SOME a, SOME b) = Real.== (a, b)
  | timeout_equal _ = false

val legacy_default_proof_timeout = HolbuildTheoryCacheManifest.legacy_default_proof_timeout

datatype proof_timeout_field =
    ProofTimeoutAbsent
  | ProofTimeoutPresent of real option
  | ProofTimeoutInvalid

fun parse_present_proof_timeout_field prefix line =
  if String.isPrefix prefix line then
    case parse_timeout_text (String.extract(line, size prefix, NONE)) of
        SOME timeout => ProofTimeoutPresent timeout
      | NONE => ProofTimeoutInvalid
  else ProofTimeoutInvalid

fun parse_proof_timeout_field lines field_name =
  let
    val prefix = field_name ^ "="
    val matching_lines = List.filter (String.isPrefix field_name) lines
  in
    case matching_lines of
        [] => ProofTimeoutAbsent
      | [line] => parse_present_proof_timeout_field prefix line
      | _ => ProofTimeoutInvalid
  end

fun proof_timeout_field_satisfies allow_discrepancy requested field =
  case field of
      ProofTimeoutAbsent =>
        cache_timeout_satisfies allow_discrepancy requested legacy_default_proof_timeout
    | ProofTimeoutPresent built =>
        cache_timeout_satisfies allow_discrepancy requested built
    | ProofTimeoutInvalid => false

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

fun extra_blob_role path = "extra:" ^ HolbuildAnalysisProtocol.escape path

fun cache_manifest_text {input_key, sig_hash, sml_hash, dat_hash, trace_hash, extra_hashes,
                         parents, mldeps, proof_timeout} =
  String.concatWith "\n"
    (["holbuild-cache-action-v4",
      "input_key=" ^ input_key,
      "kind=theory",
      "proof-timeout=" ^ timeout_text proof_timeout,
      "load-metadata-v1"] @
     map (fn parent => "parent " ^ parent) parents @
     map (fn dep => "mldep " ^ dep) mldeps @
     ["blob sig " ^ sig_hash,
      "blob sml " ^ sml_hash,
      "blob dat " ^ dat_hash] @
     (case trace_hash of NONE => [] | SOME hash => ["blob trace " ^ hash]) @
     map (fn (path, hash) => "blob " ^ extra_blob_role path ^ " " ^ hash) extra_hashes) ^ "\n"

val cache_manifest_lines = HolbuildTheoryCacheManifest.cache_manifest_lines
val valid_sha1_text = HolbuildTheoryCacheManifest.valid_sha1_text
val transient_stage_mldep = HolbuildTheoryCacheManifest.transient_stage_mldep
val valid_mldep_name = HolbuildTheoryCacheManifest.valid_mldep_name

fun cache_manifest_blobs_from_lines key lines =
  HolbuildTheoryCacheManifest.cache_manifest_blobs_from_lines key lines
  handle HolbuildTheoryCacheManifest.Error msg => raise Error msg

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
    val _ = HolbuildCache.with_action_publish_lock_wait root input_key drop
  in
    !dropped
  end

fun transient_cache_manifest_error root input_key manifest manifest_text dep =
  let
    val dropped = drop_cache_manifest_if_unchanged root input_key manifest_text
    val action = if dropped then "; deleted cache manifest" else "; cache manifest not deleted because manifest changed"
  in
    raise Error ("cache manifest contains transient stage mldep: " ^ dep ^ action)
  end

fun cache_manifest_blobs root input_key =
  case HolbuildCache.get_action root input_key of
      SOME manifest_text => cache_manifest_blobs_from_lines input_key (cache_manifest_lines manifest_text)
    | NONE => raise Error ("cache manifest missing: " ^ input_key)

fun cache_manifest_proof_timeout lines =
  HolbuildTheoryCacheManifest.cache_manifest_proof_timeout lines
  handle HolbuildTheoryCacheManifest.Error msg => raise Error msg

fun cache_manifest_proof_timeout_text key text =
  HolbuildTheoryCacheManifest.cache_manifest_proof_timeout_text key text
  handle HolbuildTheoryCacheManifest.Error msg => raise Error msg

fun cache_manifest_contract key text =
  HolbuildTheoryCacheManifest.cache_manifest_contract key text
  handle HolbuildTheoryCacheManifest.Error msg => raise Error msg

val timeout_at_least_as_strong = HolbuildTheoryCacheManifest.timeout_at_least_as_strong

fun cache_manifest_outputs_equal input_key left right =
  let
    val left_blobs = cache_manifest_blobs_from_lines input_key (cache_manifest_lines left)
    val right_blobs = cache_manifest_blobs_from_lines input_key (cache_manifest_lines right)
  in
    #sig_hash left_blobs = #sig_hash right_blobs andalso
    #sml_hash left_blobs = #sml_hash right_blobs andalso
    #dat_hash left_blobs = #dat_hash right_blobs andalso
    #trace_hash left_blobs = #trace_hash right_blobs andalso
    #extra_hashes left_blobs = #extra_hashes right_blobs
  end

fun cache_entry_usable root input_key text =
  let
    val lines = cache_manifest_lines text
    val _ = cache_manifest_proof_timeout lines
    val {sig_hash, sml_hash, dat_hash, trace_hash, extra_hashes, ...} =
      cache_manifest_blobs_from_lines input_key lines
  in
    HolbuildCache.verify_blob root sig_hash andalso
    HolbuildCache.verify_blob root sml_hash andalso
    HolbuildCache.verify_blob root dat_hash andalso
    (case trace_hash of NONE => true | SOME hash => HolbuildCache.verify_blob root hash) andalso
    List.all (fn (_, hash) => HolbuildCache.verify_blob root hash) extra_hashes
  end
  handle _ => false

fun cache_manifest_output_summary {sig_hash, sml_hash, dat_hash, trace_hash, extra_hashes,
                                   parents, mldeps} =
  String.concat
    ["sig=", sig_hash,
     " sml=", sml_hash,
     " dat=", dat_hash,
     " trace=", Option.getOpt(trace_hash, "none"),
     " extras=", Int.toString (length extra_hashes),
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

(* The filesystem cache backend verifies the source blob and its materialized
   destination before reporting Hit.  Do not repeat those full-file hashes here:
   cache restoration can otherwise hash each blob four times. *)
fun copy_blob _ root hash dst =
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

(* The HTTP cache has no compare-and-swap operation.  Re-read after each
   authorized replacement and retry a weaker observation, but retain the
   restore-time compatibility check as the correctness boundary. *)
val remote_theory_publish_attempts = 3

fun put_remote_theory_action remote _ (request as {key, text}) =
  let
    val incoming = cache_manifest_contract key text
    fun conflict detail = HolbuildCacheBackend.Conflict ("remote theory action " ^ key ^ ": " ^ detail)
    fun compatible_contract resident_text =
      let val resident = cache_manifest_contract key resident_text
      in
        if #non_timeout_text resident = #non_timeout_text incoming then resident
        else raise Error "resident manifest differs outside proof-timeout"
      end
    fun attempt attempts =
      let
        fun retry detail =
          if attempts > 1 then attempt (attempts - 1) else conflict detail
        fun verify result =
          case HolbuildRemoteCache.get_action remote key of
              NONE => retry "action missing after publication"
            | SOME observed_text =>
                let val observed = compatible_contract observed_text
                in
                  if timeout_at_least_as_strong (#proof_timeout observed) (#proof_timeout incoming) then result
                  else retry "weaker proof-timeout observed after publication"
                end
        fun publish_missing () =
          case HolbuildRemoteCache.put_action remote HolbuildCacheBackend.PutIfAbsentOrSame request of
              result as HolbuildCacheBackend.Published => verify result
            | result as HolbuildCacheBackend.AlreadyPresent => verify result
            | HolbuildCacheBackend.Conflict detail => retry detail
            | HolbuildCacheBackend.Skipped => HolbuildCacheBackend.Skipped
        fun replace_weaker () =
          case HolbuildRemoteCache.replace_action_unconditionally remote request of
              result as HolbuildCacheBackend.Published => verify result
            | HolbuildCacheBackend.Conflict detail => retry detail
            | result as HolbuildCacheBackend.AlreadyPresent => verify result
            | HolbuildCacheBackend.Skipped => HolbuildCacheBackend.Skipped
      in
        case HolbuildRemoteCache.get_action remote key of
            NONE => publish_missing ()
          | SOME resident_text =>
              let val resident = compatible_contract resident_text
              in
                if timeout_at_least_as_strong (#proof_timeout resident) (#proof_timeout incoming) then
                  HolbuildCacheBackend.AlreadyPresent
                else if timeout_at_least_as_strong (#proof_timeout incoming) (#proof_timeout resident) then
                  replace_weaker ()
                else
                  conflict "proof-timeout contracts are incomparable"
              end
      end
  in
    attempt remote_theory_publish_attempts
  end
  handle e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun remote_cache_destination remote : HolbuildCacheTransfer.destination =
  {put_action = put_remote_theory_action remote,
   publish_blob = HolbuildRemoteCache.publish_blob remote}

fun remote_cache_source_with_action remote key manifest : HolbuildCacheTransfer.source =
  {get_action = fn requested => if requested = key then SOME manifest else HolbuildRemoteCache.get_action remote requested,
   fetch_blob = HolbuildRemoteCache.fetch_blob remote}

(* The keys whose entries this process copied from the remote cache, so that
   restoring one counts as a remote hit. *)
val remote_copied_keys = ref (Redblackset.empty String.compare)
val remote_copied_mutex = Mutex.mutex ()

fun note_remote_copy key =
  (Mutex.lock remote_copied_mutex;
   remote_copied_keys := Redblackset.add (!remote_copied_keys, key);
   Mutex.unlock remote_copied_mutex)

fun copied_from_remote key =
  (Mutex.lock remote_copied_mutex;
   Redblackset.member (!remote_copied_keys, key)
   before Mutex.unlock remote_copied_mutex)

(* Copies the remote entry for key into the local cache.  Returns false on a
   remote miss and raises if the entry is unusable. *)
fun copy_remote_cache_entry root url key =
  let
    val remote = HolbuildRemoteCache.remote url
    val local_cache = HolbuildFSCacheBackend.filesystem root
  in
    case HolbuildRemoteCache.get_action remote key of
        NONE => false
      | SOME manifest =>
          (HolbuildFSCacheBackend.ensure_layout local_cache;
           (* Before the copy, which a build worker may restore as soon as
              its manifest lands. *)
           note_remote_copy key;
           HolbuildCacheTransfer.copy_entry
             {source = remote_cache_source_with_action remote key manifest,
              destination = fs_cache_destination local_cache,
              tmp_dir = HolbuildFSCacheBackend.tmp_dir local_cache}
             key;
           true)
  end

fun hydrate_remote_cache_key root key =
  case HolbuildRemoteCacheConfig.url () of
      NONE => false
    | SOME url =>
        (if copy_remote_cache_entry root url key then
           (cache_trace ("remote cache hydrated: " ^ key); true)
         else
           (cache_trace ("remote cache miss: " ^ key); false))
        handle e =>
          (* A full disk is not a miss: the entry would be unusable for any
             key, and a rebuild needs the space too. *)
          if String.isSubstring "No space left on device" (General.exnMessage e) then raise e
          else
            (warn ("remote cache entry unusable for " ^ key ^ ": " ^ General.exnMessage e);
             false)

fun prefetch_remote_cache_key root url key =
  if Option.isSome (HolbuildCache.get_action root key) then ()
  else if copy_remote_cache_entry root url key then
    cache_trace ("remote cache prefetched: " ^ key)
  else ()

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

fun cache_warning_subject logical source_file =
  String.concat [logical, " (", source_file, ")"]

(* The caller holds the action publication lock, including for a new entry. *)
fun publish_cache_manifest root cache_key subject staged_sig published_sml staged_dat staged_trace
                           staged_extras cache_parents cache_mldeps proof_timeout =
  let
    val manifest_path = HolbuildCache.action_manifest root cache_key
    val sig_hash = cache_blob root staged_sig
    val sml_hash = cache_blob root published_sml
    val dat_hash = cache_blob root staged_dat
    val trace_hash = Option.map (cache_blob root) staged_trace
    val extra_hashes = map (fn (path, staged) => (path, cache_blob root staged)) staged_extras
    fun manifest_with timeout =
      cache_manifest_text {input_key = cache_key, sig_hash = sig_hash,
                           sml_hash = sml_hash,
                           dat_hash = dat_hash,
                           trace_hash = trace_hash,
                           extra_hashes = extra_hashes,
                           parents = cache_parents,
                           mldeps = cache_mldeps,
                           proof_timeout = timeout}
    val manifest = manifest_with proof_timeout
    val existing = HolbuildCache.get_action root cache_key
    fun write_manifest text = HolbuildCache.write_action root {key = cache_key, text = text}
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
      | NONE => write_manifest manifest
  end

fun publish_theory_cache subject input_key proof_timeout staged_sig published_sml staged_dat
                         staged_trace staged_extras {parents, mldeps} =
  let
    val root = cache_root ()
    val _ = HolbuildCache.ensure_layout root
    val cache_mldeps = List.filter (not o transient_stage_mldep) mldeps
    fun publish () =
      publish_cache_manifest root input_key subject staged_sig published_sml staged_dat staged_trace
                             staged_extras parents cache_mldeps proof_timeout
    fun skip_locked_publish () = ()
  in
    (HolbuildCache.with_action_publish_lock root input_key publish skip_locked_publish;
     publish_remote_cache_key_if_usable root input_key)
    handle e => warn ("could not publish cache entry: " ^ General.exnMessage e)
  end

(* A generated theory's parents and ML dependencies are names; a load stem
   resolver maps the project's to their object stems, and the rest stay names
   for HOL to find. *)
fun plan_load_stem plan name = Option.map load_stem (HolbuildBuildPlan.node_named plan name)

fun mldep_load_stem resolve dep = getOpt (resolve dep, dep)

fun mldep_load_stems resolve mldeps = unique_strings (map (mldep_load_stem resolve) mldeps)

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

fun parent_theory_load_stem resolve parent =
  let val theory_name = parent ^ "Theory"
  in getOpt (resolve theory_name, theory_name) end

fun parent_load_stems resolve parents = unique_strings (map (parent_theory_load_stem resolve) parents)

fun generated_theory_loads resolve {parents, mldeps} =
  parent_load_stems resolve parents @
  mldep_load_stems resolve (stable_generated_mldeps mldeps)

fun write_local_theory_manifests plan node generated_metadata =
  let
    val {sig_path, sml_path, script_uo, theory_ui, theory_uo, ...} = theory_outputs node
    val deps = HolbuildBuildPlan.direct_project_deps plan node
    val theory_loads = generated_theory_loads (plan_load_stem plan) generated_metadata
    val script_loads = direct_external_loads plan node @ project_load_stems deps
  in
    write_object_manifest theory_ui [sig_path];
    write_object_manifest theory_uo (theory_loads @ [sml_path]);
    write_object_manifest script_uo (script_loads @ [source_file node])
  end

fun remove_failed_cache_outputs project node =
  let
    val {sig_path, sml_path, data_path, script_uo, theory_ui, theory_uo} = theory_outputs node
    val trace_path = drop_suffix ".dat" data_path ^ ".tr.gz"
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
       sml_path, hfs_remapped_path sml_path,
       trace_path, hfs_remapped_path trace_path]
  in
    List.app remove_file (manifest_paths @ payload_paths);
    remove_checkpoint_family (checkpoint_base project node)
  end

datatype theory_cache_restore = CacheMiss | CacheRestored of real option

val cache_key_role = "source/dependency key"

(* A cache entry's manifest, checked for a restore: no transient stage mldep,
   the declared extra outputs (any, given NONE), a trace when one is required, and a timeout
   contract at least as strict as the one requested.  Raises
   `Error "cache entry not found"` on a miss. *)
fun checked_cache_entry allow_timeout_discrepancy {root, input_key, subject, expected_extra_outputs,
                                                  requested_timeout, require_trace} =
  let
    val manifest = HolbuildCache.action_manifest root input_key
    val manifest_text =
      case ensure_local_cache_entry root input_key of
          SOME text => text
        | NONE => (cache_trace ("cache miss: " ^ subject ^ " " ^ cache_key_role ^ "=" ^ input_key ^ " (no manifest)");
                   raise Error "cache entry not found")
    val _ =
      case transient_stage_mldep_in_manifest manifest_text of
          SOME dep => transient_cache_manifest_error root input_key manifest manifest_text dep
        | NONE => ()
    val manifest_lines = cache_manifest_lines manifest_text
    val blobs as {extra_hashes, trace_hash, ...} = cache_manifest_blobs_from_lines input_key manifest_lines
    val _ =
      case expected_extra_outputs of
          NONE => ()
        | SOME expected =>
            if map #1 extra_hashes = expected then ()
            else raise Error "cache manifest extra outputs do not match the action declaration"
    val _ =
      if require_trace andalso not (Option.isSome trace_hash) then
        raise Error "cache manifest missing blob role: trace"
      else ()
    val proof_timeout = cache_manifest_proof_timeout manifest_lines
    val _ =
      if cache_timeout_satisfies allow_timeout_discrepancy requested_timeout proof_timeout then ()
      else raise Error ("cache entry built with insufficient tactic-timeout contract: built " ^
                        timeout_text proof_timeout ^ ", requested " ^ timeout_text requested_timeout)
  in
    {blobs = blobs, proof_timeout = proof_timeout}
  end

(* Installs a checked cache entry's outputs at the given paths, its extra
   outputs where `extra_destination` puts each declaration, and its load
   manifests with `write_manifests`. *)
fun install_cache_entry verify_cache root input_key subject
                        {blobs = {sig_hash, sml_hash, dat_hash, trace_hash, extra_hashes, parents, mldeps},
                         proof_timeout}
                        {outputs = {sig_path, sml_path, data_path}, extra_destination, write_manifests} =
  let
    val trace_path = drop_suffix ".dat" data_path ^ ".tr.gz"
  in
    copy_blob verify_cache root dat_hash data_path;
    link_or_copy {src = data_path, dst = hfs_remapped_path data_path};
    copy_blob verify_cache root sig_hash sig_path;
    link_or_copy {src = sig_path, dst = hfs_remapped_path sig_path};
    copy_blob verify_cache root sml_hash sml_path;
    write_text sml_path (replace_all cache_sml_token data_path (read_text sml_path));
    link_or_copy {src = sml_path, dst = hfs_remapped_path sml_path};
    (case trace_hash of
         NONE => ()
       | SOME hash =>
           (copy_blob verify_cache root hash trace_path;
            link_or_copy {src = trace_path, dst = hfs_remapped_path trace_path}));
    List.app
      (fn (declaration, hash) =>
          let val destination = extra_destination declaration
          in ensure_parent destination; copy_blob verify_cache root hash destination end)
      extra_hashes;
    write_manifests {parents = parents, mldeps = mldeps};
    HolbuildCache.touch_action root input_key;
    cache_trace ("cache hit: " ^ subject ^ " " ^ cache_key_role ^ "=" ^ input_key);
    proof_timeout
  end

fun materialize_theory_cache verify_cache allow_timeout_discrepancy project plan input_key requested_timeout require_trace node =
  let
    val root = cache_root ()
    val subject = logical_name node
    val entry =
      checked_cache_entry allow_timeout_discrepancy
        {root = root, input_key = input_key, subject = subject,
         expected_extra_outputs = SOME (source_extra_output_declarations plan node),
         requested_timeout = requested_timeout, require_trace = require_trace}
    val {sig_path, sml_path, data_path, ...} = theory_outputs node
    val extra_output_paths = source_extra_output_paths plan node
    val _ = claim_extra_outputs project node extra_output_paths
    fun write_manifests metadata =
      (record_materialized_extra_outputs project node extra_output_paths;
       write_local_theory_manifests plan node metadata)
  in
    CacheRestored
      (install_cache_entry verify_cache root input_key subject entry
         {outputs = {sig_path = sig_path, sml_path = sml_path, data_path = data_path},
          extra_destination = source_extra_output_path node,
          write_manifests = write_manifests})
  end
  handle Error "cache entry not found" => CacheMiss
       | e => (remove_failed_cache_outputs project node;
               cache_trace ("cache miss: " ^ logical_name node ^ " " ^
                            cache_key_role ^ "=" ^ input_key ^
                            " (" ^ General.exnMessage e ^ ")");
               warn ("cache entry unusable for " ^ logical_name node ^ ": " ^ General.exnMessage e);
               CacheMiss)

fun metadata_path (project : HolbuildProject.t) node =
  let
    val source = HolbuildBuildPlan.source_of node
    val base = Path.concat(Path.concat(project_artifact_root project, ".holbuild/dep"), #package source)
  in
    Path.concat(base, #relative_path source ^ ".key")
  end

fun clean_theory_node project plan node =
  (clean_registered_extra_outputs project plan node;
   remove_failed_cache_outputs project node;
   remove_file (metadata_path project node);
   remove_file (HolbuildBuildPlan.dependency_cache_path (HolbuildBuildPlan.source_of node)))

fun theorem_context_path base deps_key proof_engine prefix_hash safe_name =
  Path.concat(theorem_checkpoint_dir base deps_key proof_engine prefix_hash,
              safe_name ^ "_context.save")

fun theorem_end_of_proof_path base deps_key proof_engine prefix_hash safe_name =
  Path.concat(theorem_checkpoint_dir base deps_key proof_engine prefix_hash,
              safe_name ^ "_end_of_proof.save")

fun failed_prefix_checkpoint_dir base deps_key proof_engine =
  Path.concat(theorem_checkpoint_root base, Path.concat(Path.concat(deps_key, proof_engine), ".failed"))

fun theorem_failed_prefix_path base deps_key proof_engine safe_name =
  Path.concat(failed_prefix_checkpoint_dir base deps_key proof_engine,
              safe_name ^ "_failed_prefix.save")

fun declaration_context_path base deps_key proof_engine prefix_hash safe_name =
  Path.concat(declaration_checkpoint_dir base deps_key proof_engine prefix_hash,
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

(* Context checkpoints hold the theorems saved so far, with their recorded
   locations; this names how those were recorded, so that states saved before
   staged scripts carried location pragmas are not resumed. *)
val theorem_location_schema = "source_pragmas_v1"

(* Context checkpoints also hold the theorem numbering HOL assigned so far.
   States saved while termination goals were derived by a second Hol_defn
   carry advanced numbering, so they are not resumed. *)
val termination_goal_schema = "in_tactic_v1"

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
        "prefix_key=" ^ prefix_hash,
        "theorem_locations=" ^ theorem_location_schema,
        "termination_goals=" ^ termination_goal_schema] ^ "\n")

fun declaration_checkpoint_key {name, safe_name, boundary, deps_key, proof_engine, prefix_hash} =
  HolbuildToolchain.hash_text
    (String.concatWith "\n"
       ["holbuild-declaration-checkpoint-key-v1",
        "name=" ^ name,
        "safe_name=" ^ safe_name,
        "boundary=" ^ Int.toString boundary,
        "deps_key=" ^ deps_key,
        "proof_engine=" ^ proof_engine,
        "prefix_key=" ^ prefix_hash,
        "theorem_locations=" ^ theorem_location_schema,
        "termination_goals=" ^ termination_goal_schema] ^ "\n")

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

(* Checkpoints save state from running the script up to a boundary.  Besides
   the source prefix, that run may have read the node's extra inputs, so
   their contents are part of the prefix identity.  Without extra inputs the
   key is the plain source prefix hash. *)
fun script_prefix_key NONE source_prefix_hash = source_prefix_hash
  | script_prefix_key (SOME inputs_key) source_prefix_hash =
      HolbuildToolchain.hash_text
        ("holbuild-script-prefix-v1\nsource_prefix=" ^ source_prefix_hash ^
         "\nextra_inputs=" ^ inputs_key ^ "\n")

fun failed_prefix_diagnostic_key proof_engine = proof_engine ^ ":finish_goal_state_v2"
(* Failed-prefix heaps retain the proof runtime and its compiled tactic refs. *)
fun failed_prefix_resume_schema_key proof_engine = proof_engine ^ ":dependency_prefix_history_v2"

fun failed_prefix_ok proof_engine proof_timeout deps_key safe_name pre_hash header_hash =
  checkpoint_ok_text "failed_prefix"
    [("deps_key", deps_key),
     ("proof_engine", proof_engine),
     proof_timeout_field proof_timeout,
     ("safe_name", safe_name),
     ("pre_theorem_key", pre_hash),
     ("header_key", header_hash),
     ("failure_diagnostic_key", failed_prefix_diagnostic_key proof_engine),
     ("resume_schema_key", failed_prefix_resume_schema_key proof_engine),
     ("theorem_locations", theorem_location_schema),
     ("termination_goals", termination_goal_schema)]

fun theorem_checkpoint_specs proof_engine proof_timeout base deps_key inputs_key source proof_ir_plans (boundaries : HolbuildTheoryCheckpoints.boundary list) =
  let
    fun pair (boundary, proof_ir_plan) =
      let
        val {kind, name, safe_name, theorem_start, theorem_stop, boundary = boundary_pos, tactic_start,
             tactic_end, tactic_text, has_proof_attrs, prefix_hash = source_prefix_hash} = boundary
        val prefix_hash = script_prefix_key inputs_key source_prefix_hash
        val checkpoint_key = theorem_checkpoint_key {kind = kind, name = name, safe_name = safe_name,
                                                     boundary = boundary_pos, deps_key = deps_key,
                                                     proof_engine = proof_engine,
                                                     prefix_hash = prefix_hash}
        val header_hash = theorem_header_hash source theorem_start tactic_start
        val pre_hash = script_prefix_key inputs_key (pre_theorem_hash source theorem_start)
      in
        {kind = kind, name = name, safe_name = safe_name, theorem_start = theorem_start,
         theorem_stop = theorem_stop, boundary = boundary_pos,
         tactic_start = tactic_start, tactic_end = tactic_end,
         tactic_text = tactic_text, has_proof_attrs = has_proof_attrs,
         prefix_hash = prefix_hash,
         context_path = theorem_context_path base deps_key proof_engine prefix_hash safe_name,
         context_ok = theorem_checkpoint_ok "theorem_context" deps_key proof_engine proof_timeout prefix_hash checkpoint_key,
         end_of_proof_path = theorem_end_of_proof_path base deps_key proof_engine prefix_hash safe_name,
         end_of_proof_ok = theorem_checkpoint_ok "end_of_proof" deps_key proof_engine proof_timeout prefix_hash checkpoint_key,
         failed_prefix_path = theorem_failed_prefix_path base deps_key proof_engine safe_name,
         failed_prefix_ok = failed_prefix_ok proof_engine proof_timeout deps_key safe_name pre_hash header_hash,
         deps_key = deps_key,
         checkpoint_key = checkpoint_key,
         proof_ir_plan = proof_ir_plan}
      end
  in
    if length proof_ir_plans = length boundaries then ListPair.map pair (boundaries, proof_ir_plans)
    else raise Error "internal error: proof-IR plan count does not match theorem boundary count"
  end

fun declaration_checkpoint_specs proof_engine proof_timeout base deps_key inputs_key source terminations =
  map (fn ({name, safe_name, definition_start, boundary, ...} : HolbuildTheoryCheckpoints.termination) =>
          let
            val prefix_hash =
              script_prefix_key inputs_key (HolbuildTheoryCheckpoints.prefix_hash source boundary)
            val checkpoint_key = declaration_checkpoint_key {name = name, safe_name = safe_name,
                                                             boundary = boundary, deps_key = deps_key,
                                                             proof_engine = proof_engine,
                                                             prefix_hash = prefix_hash}
          in
            {name = name, safe_name = safe_name,
             definition_start = definition_start, boundary = boundary,
             prefix_hash = prefix_hash,
             context_path = declaration_context_path base deps_key proof_engine prefix_hash safe_name,
             context_ok = checkpoint_context_ok "definition_context" deps_key proof_engine proof_timeout prefix_hash checkpoint_key,
             deps_key = deps_key,
             checkpoint_key = checkpoint_key}
          end)
      terminations

(* The dependency context keyed on the dependencies' input keys.  Remote
   action specs and key dumps use this one: it is known before anything is
   built. *)
fun dependency_input_context_key toolchain_key plan keys node =
  let
    val project_deps = HolbuildBuildPlan.transitive_project_deps plan node
    val project_lines = map (fn dep => "project " ^ HolbuildBuildPlan.key dep ^ " " ^
                                       HolbuildBuildPlan.input_key_for keys dep)
                            project_deps
    (* The plan may be reused with a different input-key map.  Include the
       relevant map entries in the memo discriminator, not just the toolchain. *)
    val context_id = String.concatWith "\n" (toolchain_key :: project_lines)
  in
    case HolbuildBuildPlan.cached_dependency_context_key plan node context_id of
        SOME key => key
      | NONE =>
          let
            val external_theories = HolbuildBuildPlan.direct_external_theories plan node
            val external_libs = HolbuildBuildPlan.direct_external_libs plan node
            val theory_lines = map (fn dep => "external_theory " ^ dep) external_theories
            val lib_lines = map (fn dep => "external_lib " ^ dep) external_libs
            val key =
              HolbuildToolchain.hash_text
                (String.concatWith "\n"
                   (* Local heaps must contain the export-normalizing runtime.
                      Artifact action keys remain compatible. *)
                   (["holbuild-dependency-context-v2",
                     "toolchain_key=" ^ toolchain_key] @ project_lines @ theory_lines @ lib_lines) ^ "\n")
          in
            HolbuildBuildPlan.remember_dependency_context_key plan node context_id key;
            key
          end
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

fun checkpoint_timeout_satisfies requested_timeout path =
  case current_metadata (path ^ ".ok") of
      NONE => timeout_satisfies requested_timeout legacy_default_proof_timeout
    | SOME text =>
        proof_timeout_field_satisfies false requested_timeout
          (parse_proof_timeout_field (metadata_lines text) "proof_timeout")

fun theorem_context_checkpoint_exists requested_timeout base checkpoint =
  let val deps_loaded = deps_loaded_path base (#deps_key checkpoint)
  in
    deps_checkpoint_exists deps_loaded (#deps_key checkpoint) andalso
    checkpoint_ok_matches (#context_path checkpoint)
      [("kind", "theorem_context"),
       ("deps_key", #deps_key checkpoint),
       ("prefix_key", #prefix_hash checkpoint),
       ("checkpoint_key", #checkpoint_key checkpoint)] andalso
    checkpoint_timeout_satisfies requested_timeout (#context_path checkpoint)
  end

fun declaration_context_checkpoint_exists requested_timeout base checkpoint =
  let val deps_loaded = deps_loaded_path base (#deps_key checkpoint)
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

fun theorem_replay_candidates requested_timeout base checkpoints =
  List.mapPartial
    (fn checkpoint =>
        if theorem_context_checkpoint_exists requested_timeout base checkpoint then
          SOME {boundary = #boundary checkpoint, path = #context_path checkpoint,
                safe_name = #safe_name checkpoint, kind = "theorem-context",
                failure_checkpoints = theorem_replay_failure_checkpoints checkpoint}
        else NONE)
    checkpoints

fun declaration_replay_candidates requested_timeout base checkpoints =
  List.mapPartial
    (fn checkpoint =>
        if declaration_context_checkpoint_exists requested_timeout base checkpoint then
          SOME {boundary = #boundary checkpoint, path = #context_path checkpoint,
                safe_name = #safe_name checkpoint, kind = "definition-context",
                failure_checkpoints = [#context_path checkpoint]}
        else NONE)
    checkpoints

fun replay_candidates requested_timeout base theorem_checkpoints declaration_checkpoints =
  theorem_replay_candidates requested_timeout base theorem_checkpoints @
  declaration_replay_candidates requested_timeout base declaration_checkpoints

fun later_candidate (a, b) = if #boundary a >= #boundary b then a else b

fun best_replay_candidate requested_timeout base theorem_checkpoints declaration_checkpoints =
  case replay_candidates requested_timeout base theorem_checkpoints declaration_checkpoints of
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
          case (value "proof_ir_failed_prefix_version", value "step_count", value "prefix_end",
                value "path", value "focus", value "prefix_signature", value "history_count") of
              (SOME version, SOME step_count_text, SOME _, SOME _, SOME _, prefix_signature, SOME _) =>
                if version = "5" then
                  Option.mapPartial
                    (fn step_count =>
                       if step_count = 0 orelse Option.isSome prefix_signature then
                         SOME {step_count = step_count, metadata_text = text}
                       else NONE)
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

type build_options = {use_cache : bool, verify_cache : bool, force : force_level, force_targets : string list, skip_checkpoints : bool, proof_steps : bool, new_ir : bool, node_tactic_timeouts : (string * real option) list, execution_plan : string option, trace_steps : bool, repl_on_failure : bool, emit_output_hashes : bool, allow_cache_timeout_discrepancy : bool, trknl : bool, restore_only : bool}

datatype checkpoint_policy =
  CheckpointPolicy of {checkpoint : bool, proof_steps : bool, new_ir : bool, tactic_timeout : real option, execution_plan : string option, trace_steps : bool, repl_on_failure : bool, trknl : bool}

val no_checkpoint_policy =
  CheckpointPolicy {checkpoint = false, proof_steps = false, new_ir = false, tactic_timeout = NONE, execution_plan = NONE, trace_steps = false, repl_on_failure = false, trknl = false}

fun checkpoint_enabled (CheckpointPolicy {checkpoint, ...}) = checkpoint
fun proof_steps_enabled (CheckpointPolicy {proof_steps, ...}) = proof_steps
fun proof_ir_enabled (CheckpointPolicy {new_ir, ...}) = new_ir
fun tactic_timeout (CheckpointPolicy {tactic_timeout, ...}) = tactic_timeout
fun execution_plan (CheckpointPolicy {execution_plan, ...}) = execution_plan
fun trace_steps (CheckpointPolicy {trace_steps, ...}) = trace_steps
fun repl_on_failure (CheckpointPolicy {repl_on_failure, ...}) = repl_on_failure
fun trknl_enabled (CheckpointPolicy {trknl, ...}) = trknl

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

(* The files a node hands its dependents, by role, plus a line for what they
   don't show.  A theory hands over its generated files, its load manifests
   (which carry its ML dependencies), its kernel trace if it has one, and its
   extra outputs.  An ML library's load manifest only names its source, so a
   library's own inputs stand in for its content.  What a dependency loads in
   turn is in the dependent's closure too, with its own digest. *)
fun output_digest_parts toolchain_key plan node =
  let
    (* HOL's loader reads the remapped copies, which are separate files. *)
    fun with_remapped files =
      files @ map (fn (role, path) => ("remapped " ^ role, hfs_remapped_path path)) files
    val extras =
      ListPair.zip (map (fn declaration => "extra " ^ declaration)
                        (source_extra_output_declarations plan node),
                    source_extra_output_paths plan node)
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript =>
          let
            val {sig_path, sml_path, data_path, theory_ui, theory_uo, ...} = theory_outputs node
            val trace_path = drop_suffix ".dat" data_path ^ ".tr.gz"
          in
            ([], with_remapped
                   ([("dat", data_path), ("sig", sig_path), ("sml", sml_path),
                     ("ui", theory_ui), ("uo", theory_uo)] @
                    (if file_exists trace_path then [("trace", trace_path)] else [])) @
                 extras)
          end
      | _ =>
          (["self " ^ HolbuildBuildPlan.self_input_key plan
                        (fn _ => policy_config_lines no_checkpoint_policy) toolchain_key node],
           with_remapped (map (fn path => ("object", path)) (#objects (source_artifacts node))) @
           extras)
  end

(* Computes and remembers the output digests of NODES, hashing all their files
   in one batch.  A node with a missing output gets none. *)
fun remember_output_digests toolchain_key plan nodes =
  let
    val parts =
      List.mapPartial
        (fn node =>
            let val (lines, files) = output_digest_parts toolchain_key plan node
            in
              if List.all (fn (_, path) => file_exists path) files
              then SOME (node, lines, files)
              else NONE
            end
            handle _ => NONE)
        nodes
    val hashes = HolbuildHash.files_sha256 (List.concat (map (fn (_, _, files) => map #2 files) parts))
    fun digest [] _ = ()
      | digest ((node, lines, files) :: rest) hashes =
          let
            val n = length files
            val file_lines =
              ListPair.map (fn ((role, _), hash) => role ^ " " ^ hash) (files, List.take(hashes, n))
          in
            HolbuildBuildPlan.remember_output_digest plan node
              (HolbuildToolchain.hash_text
                 (String.concatWith "\n" ("holbuild-output-digest-v1" :: lines @ file_lines) ^ "\n"));
            digest rest (List.drop(hashes, n))
          end
  in
    digest parts hashes
  end
  handle _ => ()

(* A hash of everything NODE loads from its project dependencies: the output
   digest of each node in its closure.  NONE when an output is missing.
   Digests are memoized for the build; build_one forgets a node's digest when
   it finishes, since only then are its outputs final. *)
fun deps_output_key toolchain_key plan node =
  let
    val deps = HolbuildBuildPlan.transitive_project_deps plan node
    fun cached dep = HolbuildBuildPlan.cached_output_digest plan dep
    val _ =
      case List.filter (fn dep => not (Option.isSome (cached dep))) deps of
          [] => ()
        | missing => remember_output_digests toolchain_key plan missing
    fun line dep =
      case cached dep of
          SOME digest => SOME (HolbuildBuildPlan.key dep ^ " " ^ digest)
        | NONE => NONE
    val lines = map line deps
  in
    if List.all Option.isSome lines then
      SOME (HolbuildToolchain.hash_text
              (String.concatWith "\n" ("holbuild-deps-output-v1" :: map valOf lines) ^ "\n"))
    else NONE
  end

(* The key of a theory's loaded dependencies (deps_loaded.save and the
   checkpoints above it).  Keyed on what the dependencies produced, so an edit
   that leaves their outputs unchanged keeps the dependents' checkpoints; on
   their input keys when an output is missing. *)
fun dependency_context_key toolchain_key plan keys node =
  case deps_output_key toolchain_key plan node of
      NONE => dependency_input_context_key toolchain_key plan keys node
    | SOME outputs_key =>
        let
          val context_id = "outputs " ^ toolchain_key ^ " " ^ outputs_key
        in
          case HolbuildBuildPlan.cached_dependency_context_key plan node context_id of
              SOME key => key
            | NONE =>
                let
                  val theory_lines =
                    map (fn dep => "external_theory " ^ dep)
                        (HolbuildBuildPlan.direct_external_theories plan node)
                  val lib_lines =
                    map (fn dep => "external_lib " ^ dep)
                        (HolbuildBuildPlan.direct_external_libs plan node)
                  val key =
                    HolbuildToolchain.hash_text
                      (String.concatWith "\n"
                         (["holbuild-dependency-context-v3",
                           "toolchain_key=" ^ toolchain_key,
                           "deps_output_key=" ^ outputs_key] @ theory_lines @ lib_lines) ^ "\n")
                in
                  HolbuildBuildPlan.remember_dependency_context_key plan node context_id key;
                  key
                end
        end

fun plain_source_from_checkpoint source_name source_text start_offset =
  String.concat
    [if start_offset <= 0 then ""
     else HolbuildTheoryCheckpoints.generated_code_pragma source_text ^
          "val _ = HolbuildRuntime.restore_prover();\n",
     HolbuildTheoryCheckpoints.file_pragma source_name,
     HolbuildTheoryCheckpoints.source_line_pragma source_text start_offset,
     String.extract(source_text, Int.max(0, start_offset), NONE)]

fun instrumented_source policy timeout_marker plan_only_marker source_name source_text start_offset checkpoints declaration_checkpoints terminations =
  if proof_steps_enabled policy then
    HolbuildTheoryCheckpoints.instrument
      {source = source_text, source_name = source_name, start_offset = start_offset, checkpoints = checkpoints,
       declaration_checkpoints = if checkpoint_enabled policy then declaration_checkpoints else [],
       terminations = terminations,
       save_checkpoints = checkpoint_enabled policy,
       tactic_timeout = tactic_timeout policy,
       timeout_marker = timeout_marker,
       plan_theorem = execution_plan policy,
       trace_all = trace_steps policy,
       plan_only_marker = plan_only_marker,
       new_ir = proof_ir_enabled policy}
  else plain_source_from_checkpoint source_name source_text start_offset

fun replay_candidate policy base theorem_checkpoints declaration_checkpoints =
  best_replay_candidate (tactic_timeout policy) base theorem_checkpoints declaration_checkpoints

fun source_location_text source_path source_text offset =
  let
    val bounded = Int.min(size source_text, Int.max(0, offset))
    val line = HolbuildTheoryDiagnostics.line_number_at source_text bounded
    val col = HolbuildTheoryDiagnostics.column_number_at source_text bounded
  in
    String.concat [source_path, ":", Int.toString line, ":", Int.toString col]
  end

fun checkpoint_resume_message logical lines =
  HolbuildStatus.message_stdout
    (String.concat ("resuming " ^ logical ^ "\n" :: map (fn line => "  " ^ line ^ "\n") lines))

fun deps_loaded_resume_message logical =
  checkpoint_resume_message logical ["from: deps-loaded checkpoint"]

fun source_context_resume_message logical source_file source_text kind safe_name boundary =
  checkpoint_resume_message logical
    ["from: " ^ kind ^ " checkpoint after " ^ safe_name,
     "continuing at: " ^ source_location_text source_file source_text boundary]

fun failed_prefix_resume_message logical checkpoint step_count =
  checkpoint_resume_message logical
    ["from: failed-prefix checkpoint in " ^ #safe_name checkpoint,
     "restoring proof-ir prefix with " ^ Int.toString step_count ^ " successful leaf steps"]

fun failed_prefix_resume_source policy timeout_marker plan_only_marker source_name source checkpoints declaration_checkpoints terminations checkpoint metadata_text =
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
    val finish_failed_prefix_call =
      String.concat
        ["HolbuildProofRuntime.finish_failed_prefix ",
         HolbuildToolchain.sml_string (#name checkpoint), " ",
         HolbuildToolchain.sml_string metadata_text, " ",
         HolbuildToolchain.sml_string (#tactic_text checkpoint),
         " " ^ HolbuildToolchain.sml_string (#failed_prefix_path checkpoint) ^
         " " ^ HolbuildToolchain.sml_string (#failed_prefix_ok checkpoint)]
    (* "Theorem name[attrs]", "Triviality name": the source up to the colon
       that ends the theorem's header, outside comments and its attribute
       list. *)
    fun header_end i depth =
      if i >= #tactic_start checkpoint then
        raise Error ("no header colon in theorem " ^ #name checkpoint)
      else if HolbuildTheoryCheckpoints.starts_with source i "(*" then
        header_end (HolbuildTheoryCheckpoints.skip_comment source i) depth
      else
        case String.sub(source, i) of
            #"[" => header_end (i + 1) (depth + 1)
          | #"]" => header_end (i + 1) (depth - 1)
          | #":" => if depth = 0 then i else header_end (i + 1) depth
          | _ => header_end (i + 1) depth
    (* A theorem binds the resumed proof through HOL's own `Theorem name[attrs]
       = thm` form, which keeps its attributes ([simp], [local], ...) without
       parsing the statement again after the proof prefix has run. *)
    fun theorem_replay () =
      String.concat
        [HolbuildTheoryCheckpoints.source_line_pragma source (#theorem_start checkpoint),
         source_slice (#theorem_start checkpoint) (header_end (#theorem_start checkpoint) 0),
         " =\n  (", finish_failed_prefix_call, ");\n"]
    fun resume_replay () =
      String.concat
        [HolbuildTheoryCheckpoints.source_line_pragma source (#theorem_start checkpoint),
         source_slice (#theorem_start checkpoint) (#tactic_start checkpoint),
         "(ACCEPT_TAC (", finish_failed_prefix_call, "))",
         source_slice (#tactic_end checkpoint) (#boundary checkpoint),
         "\n"]
    val plan_line =
      case #proof_ir_plan checkpoint of
          SOME expr => "val _ = HolbuildProofRuntime.set_theorem_plan (SOME (" ^ expr ^ "));\n"
        | NONE => "val _ = HolbuildProofRuntime.set_theorem_plan NONE;\n"
    val replay_block =
      plan_line ^ (if #kind checkpoint = "resume" then resume_replay () else theorem_replay ())
    val suffix =
      HolbuildTheoryCheckpoints.instrument
        {source = source,
         source_name = source_name,
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
    String.concat
      [HolbuildTheoryCheckpoints.generated_code_pragma source, prelude,
       HolbuildTheoryCheckpoints.file_pragma source_name, replay_block, suffix]
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

(* The theory action that builds `node` in action root `root`. *)
fun theory_action root plan keys toolchain_key holdir deps_key node : theory_action =
  let
    val package_root = #package_root (HolbuildBuildPlan.source_of node)
    val script_dir = Path.dir (source_file node)
    val script_rel_dir =
      Path.mkRelative {path = normalize_path script_dir, relativeTo = normalize_path package_root}
    (* The stage mirrors the package layout, and the script runs from its own
       directory in it, so inputs it reaches through ../ stay in the stage. *)
    val stage_script_dir = if String.isPrefix ".." script_rel_dir then "" else script_rel_dir
    fun staged base (rel, abs) =
      {path = if Path.isAbsolute rel then rel
              else normalize_path (if base = "" then rel else Path.concat(base, rel)),
       from = abs}
    val source_inputs =
      List.concat
        (map (fn decl => map (staged stage_script_dir) (expand_extra_dep script_dir decl))
             (#extra_deps (source_deps plan node)))
    val manifest_inputs =
      List.concat
        (map (fn input =>
                 map (staged "") (expand_extra_dep package_root (HolbuildProject.extra_input_path input)))
             (HolbuildProject.action_extra_inputs (source_policy node)))
    val {sig_path, sml_path, data_path, ...} = theory_outputs node
  in
    {input_key = HolbuildBuildPlan.input_key_for keys node,
     deps_key = deps_key,
     inputs_key = HolbuildBuildPlan.extra_inputs_key plan node,
     package = package node,
     logical = logical_name node,
     relative_path = HolbuildBuildPlan.relative_path node,
     source_file = source_file node,
     source_name = located_source_name holdir node,
     script_dir = stage_script_dir,
     inputs = source_inputs @ manifest_inputs,
     loads = preload_loads root plan node,
     outputs = {sig_path = root_relative root sig_path,
                sml_path = root_relative root sml_path,
                data_path = root_relative root data_path},
     extra_outputs = source_extra_output_declarations plan node}
  end

fun action_stage root (action : theory_action) =
  let val stage_root = stage_root_at root (#input_key action)
  in
    if #script_dir action = "" then stage_root
    else normalize_path (Path.concat(stage_root, #script_dir action))
  end

fun action_checkpoint_base checkpoint_root (action : theory_action) =
  checkpoint_base_in checkpoint_root (#package action) (#relative_path action)

fun action_outputs root ({outputs = {sig_path, sml_path, data_path}, ...} : theory_action) =
  {sig_path = in_root root sig_path, sml_path = in_root root sml_path,
   data_path = in_root root data_path}

fun write_theory_script policy root checkpoint_root base_context (action : theory_action) source_text checkpoints declaration_checkpoints terminations staged_script preload timeout_marker plan_only_marker =
  let
    val source_name = #source_name action
    val logical = #logical action
    val load_lines = map (theory_load_line root) (#loads action)
  in
  if not (checkpoint_enabled policy) then
    (write_plain_preload load_lines preload;
     write_text staged_script (instrumented_source policy (SOME timeout_marker) plan_only_marker source_name source_text 0 checkpoints [] terminations);
     {context = base_context, files = [preload, staged_script], failure_checkpoints = [], failed_prefix_context = NONE})
  else
    let
      val base = action_checkpoint_base checkpoint_root action
      val deps_key = #deps_key action
      val deps_loaded = deps_loaded_path base deps_key
      val deps_ok = deps_checkpoint_ok_text deps_key
      fun ensure_source_checkpoint_parents () =
        (List.app (fn {context_path, end_of_proof_path, failed_prefix_path, ...} =>
                     (ensure_parent context_path; ensure_parent end_of_proof_path; ensure_parent failed_prefix_path))
                  checkpoints;
         List.app (fn {context_path, ...} => ensure_parent context_path) declaration_checkpoints)
      fun run_from_deps_checkpoint () =
        (ensure_source_checkpoint_parents ();
         write_text staged_script (instrumented_source policy (SOME timeout_marker) plan_only_marker source_name source_text 0 checkpoints declaration_checkpoints terminations);
         deps_loaded_resume_message logical;
         {context = HolState deps_loaded, files = [staged_script], failure_checkpoints = [deps_loaded], failed_prefix_context = NONE})
      fun run_from_fresh_preload () =
        (remove_deps_checkpoint_descendants base deps_key;
         ensure_source_checkpoint_parents ();
         write_preload load_lines deps_loaded deps_ok preload;
         write_text staged_script (instrumented_source policy (SOME timeout_marker) plan_only_marker source_name source_text 0 checkpoints declaration_checkpoints terminations);
         {context = base_context, files = [preload, staged_script], failure_checkpoints = [], failed_prefix_context = NONE})
      fun run_from_failed_prefix {checkpoint, step_count, metadata_text} =
        let
          val path = #failed_prefix_path checkpoint
          val _ = ensure_source_checkpoint_parents ()
          val _ = write_text staged_script (failed_prefix_resume_source policy timeout_marker plan_only_marker source_name source_text checkpoints declaration_checkpoints terminations checkpoint metadata_text)
          val _ = failed_prefix_resume_message logical checkpoint step_count
        in
          {context = HolState path, files = [staged_script], failure_checkpoints = [path, deps_loaded], failed_prefix_context = SOME (path, step_count)}
        end
      fun run_from_replay {boundary, path, safe_name, kind, failure_checkpoints} =
        let
          val _ = ensure_source_checkpoint_parents ()
          val _ = write_text staged_script (instrumented_source policy (SOME timeout_marker) plan_only_marker source_name source_text boundary checkpoints declaration_checkpoints terminations)
          val _ = source_context_resume_message logical (#source_file action) source_text kind safe_name boundary
        in
          {context = HolState path, files = [staged_script], failure_checkpoints = failure_checkpoints @ [deps_loaded], failed_prefix_context = NONE}
        end
      fun failed_prefix_at_least_as_late failed NONE = true
        | failed_prefix_at_least_as_late failed (SOME replay) =
            #boundary (#checkpoint failed) >= #boundary replay
      (* Saved ML state does not include files written by the script.  Replay
         the whole script to recreate declared outputs in the fresh stage. *)
      val script_replay_allowed = null (#extra_outputs action)
      val failed_prefix =
        if script_replay_allowed andalso proof_steps_enabled policy andalso not (trace_steps policy) then
          best_failed_prefix_checkpoint (tactic_timeout policy) checkpoints
        else NONE
      val replay =
        if not script_replay_allowed orelse trace_steps policy then NONE
        else replay_candidate policy base checkpoints declaration_checkpoints
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
  end

(* Runs a theory action in action root `root`: stages its inputs, runs HOL,
   installs the theory's outputs under `root` and, when `cache_allowed`,
   publishes them to the cache.  Returns the generated theory's load metadata,
   and leaves the stage, which holds the declared extra outputs, to the
   caller. *)
fun run_theory_action cache_allowed policy tc root checkpoint_root base_context (action : theory_action) source_text theorem_checkpoints declaration_checkpoints termination_diagnostics =
  let
    val input_key = #input_key action
    val logical = #logical action
    val source_file = #source_file action
    val stage_root = stage_root_at root input_key
    val stage = action_stage root action
    val staged_script = Path.concat(stage, Path.file source_file)
    val child_policy = Path.concat(stage, "holbuild-child-policy.sml")
    val preload = Path.concat(stage, "holbuild-preload.sml")
    val theory_exporter = Path.concat(stage, "holbuild-export-theory.sml")
    val parents_report = Path.concat(stage, "holbuild-theory-parents.txt")
    val mldeps_report = Path.concat(stage, "holbuild-theory-mldeps.txt")
    val timeout_marker = Path.concat(stage, "holbuild-tactic-timeout.txt")
    val plan_only_marker = Path.concat(stage, "holbuild-proof-ir-plan.txt")
    val log_dir = current_log_dir root (#package action) logical
    val checkpoint_base = action_checkpoint_base checkpoint_root action
    val deps_key = #deps_key action
    val deps_loaded = deps_loaded_path checkpoint_base deps_key
    val {sig_path, sml_path, data_path} = action_outputs root action
    val staged_sig = staged_theory_file stage logical ".sig"
    val staged_sml = staged_theory_file stage logical ".sml"
    val staged_dat = staged_theory_file stage logical ".dat"
    val staged_trace = staged_theory_file stage logical ".tr.gz"
    val trace_path = drop_suffix ".dat" data_path ^ ".tr.gz"
    val staged_extra_outputs =
      map (fn declaration => (declaration, staged_extra_output_path stage declaration))
          (#extra_outputs action)
    fun stage_input {path, from} =
      let val dst = normalize_path (in_root stage_root path)
      in ensure_parent dst; copy_binary from dst end
    val _ = remove_tree stage_root
    val _ = ensure_dir stage
    (* Extra inputs go in first, so holbuild's own files (the instrumented
       script above all) overwrite any input staged at the same path. *)
    val _ = List.app stage_input (#inputs action)
    val _ = write_child_policy tc child_policy
    val _ =
      write_theory_exporter
        {sig_path = staged_sig, path = theory_exporter,
         parents_report = SOME parents_report,
         mldeps_report = SOME mldeps_report}
    val _ = if checkpoint_enabled policy then ensure_parent deps_loaded else ()
    val _ =
      if checkpoint_enabled policy then
        List.app (fn {context_path, end_of_proof_path, failed_prefix_path, ...} =>
                    (ensure_parent context_path; ensure_parent end_of_proof_path; ensure_parent failed_prefix_path))
                 theorem_checkpoints
      else ()
    val _ = remove_file timeout_marker
    val _ = remove_file plan_only_marker
    val _ = List.app (ensure_parent o #2) staged_extra_outputs
    val run_spec = write_theory_script policy root checkpoint_root base_context action source_text
                                    theorem_checkpoints declaration_checkpoints termination_diagnostics staged_script preload timeout_marker
                                    (if execution_plan_only policy then SOME plan_only_marker else NONE)
    fun tactic_timeout_error () =
      let
        val words = String.tokens Char.isSpace (read_text timeout_marker)
        val failure_output = checkpoint_failure_output log_dir stage
        val failure_output_path = captured_output_path_option failure_output
        val source_context =
          Option.mapPartial
            (HolbuildTheoryDiagnostics.summarize_failed_fragment_source
               source_file source_text theorem_checkpoints termination_diagnostics)
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
                              logical ^ ": " ^ String.concatWith " " (rev rev_label_words)))
                failure_output
          | [] =>
              error_with_captured_output
                (with_detail ("tactic timed out while building " ^ logical))
                failure_output
      end
    fun discard_loaded_checkpoint_after_load_failure () =
      remove_loaded_checkpoint_descendants checkpoint_base deps_key deps_loaded theorem_checkpoints declaration_checkpoints
        (hol_context_path (#context run_spec))
    fun discard_failed_prefix_after_resume_failure msg =
      case #failed_prefix_context run_spec of
          NONE => false
        | SOME (path, _) =>
            let
              val failure_output = checkpoint_failure_output log_dir stage
              val output_text =
                case captured_output_path_option failure_output of
                    NONE => ""
                  | SOME output_path => read_text output_path handle _ => ""
              val failure_text = msg ^ "\n" ^ output_text
            in
              (* A silent exit means a checkpoint saved after a source parse
                 error, which holbuild before 0.13.7 wrote. *)
              if hol_silent_exit_failure msg orelse
                 List.exists (fn marker => String.isSubstring marker failure_text)
                   ["failed-prefix checkpoint cannot rewind",
                    "failed-prefix checkpoint history does not match metadata",
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
        val failure_output = checkpoint_failure_output log_dir stage
        val failure_output_path = captured_output_path_option failure_output
        val goal_state =
          Option.mapPartial
            (HolbuildTheoryDiagnostics.summarize_goal_state_with_log_reference
               (captured_output_has_retained_log failure_output))
            failure_output_path
        val plan_position = Option.mapPartial HolbuildTheoryDiagnostics.plan_position_summary failure_output_path
        val trace_context = if trace_steps policy then Option.mapPartial HolbuildTheoryDiagnostics.summarize_trace_steps failure_output_path else NONE
        val static_error = Option.mapPartial (fn path => HolbuildTheoryDiagnostics.static_error_summary source_file source_text (String.fields (fn c => c = #"\n") (read_text path))) failure_output_path
        val source_context = Option.mapPartial
          (HolbuildTheoryDiagnostics.summarize_failed_fragment_source
             source_file source_text theorem_checkpoints termination_diagnostics)
          failure_output_path
        val termination_context =
          Option.mapPartial
            (HolbuildTheoryDiagnostics.summarize_termination_goal_source
               source_file source_text termination_diagnostics)
            failure_output_path
        val child_failure =
          if Option.isSome static_error then NONE
          else Option.mapPartial HolbuildTheoryDiagnostics.child_failure_summary failure_output_path
        val fallback =
          if Option.isSome child_failure then ""
          else
            case String.fields (fn c => c = #"\n") msg of
                [] => "hol run failed while building theory script\n"
              | first :: _ =>
                  first ^ "\n" ^
                  (case hol_silent_exit_line msg of SOME line => line ^ "\n" | NONE => "")
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
    val build_log = Path.concat(stage, "holbuild-build.log")
    val _ =
      (validate_hol_context (#context run_spec);
       detail_time_phase "build.exec.node.child_run"
         (fn () =>
             run_hol_files_to_log tc stage stage
               (#context run_spec)
               (child_policy :: (#files run_spec @ [theory_exporter]))
               "holbuild-build.log"
               (SOME (current_build_log log_dir))
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
            val failure_output = checkpoint_failure_output log_dir stage
            val failure_output_path = captured_output_path_option failure_output
            val static_error =
              Option.mapPartial
                (fn path => HolbuildTheoryDiagnostics.static_error_summary
                              source_file source_text
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
                val _ = cleanup_json_stage stage_root
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
          (case proof_trace_output log_dir stage of
               NONE => ()
             | SOME output => HolbuildStatus.message_stdout ("proof step trace log: " ^ captured_output_path output ^ "\n"))
      else ()
    val _ =
      List.app
        (fn (declaration, staged) =>
            if not (file_exists staged) then
              raise Error ("theory " ^ logical ^
                           " did not produce declared extra output: " ^ declaration)
            else if OS.FileSys.isDir staged then
              raise Error ("declared extra output is not a file: " ^ declaration)
            else ())
        staged_extra_outputs
    val generated_metadata =
      read_generated_load_metadata {parents_report = parents_report,
                                    mldeps_report = mldeps_report}
    val _ =
      if trknl_enabled policy then
        if file_exists staged_trace then
          (copy_binary staged_trace trace_path;
           copy_binary staged_trace (hfs_remapped_path trace_path))
        else raise Error ("tracing kernel did not produce expected proof trace: " ^ staged_trace)
      else ()
    val _ = copy_binary staged_dat data_path
    val _ = link_or_copy {src = data_path, dst = hfs_remapped_path data_path}
    val _ = copy_binary staged_sig sig_path
    val _ = link_or_copy {src = sig_path, dst = hfs_remapped_path sig_path}
    val dat_replacements = stage_dat_replacements stage logical data_path
    val _ = copy_rewriting_path {src = staged_sml, dst = sml_path,
                                 replacements = dat_replacements}
    val _ = link_or_copy {src = sml_path, dst = hfs_remapped_path sml_path}
    val _ =
      if cache_allowed then
        detail_time_phase "build.exec.publish_cache"
          (fn () => publish_theory_cache (cache_warning_subject logical source_file)
                                      input_key (tactic_timeout policy)
                                      staged_sig sml_path staged_dat
                                      (if trknl_enabled policy then SOME staged_trace else NONE)
                                      staged_extra_outputs generated_metadata)
      else ()
    val _ = remove_file (current_checkpoint_failure_log log_dir)
  in
    generated_metadata
  end

fun same_package_logical a b =
  HolbuildBuildPlan.package a = HolbuildBuildPlan.package b andalso
  HolbuildBuildPlan.logical_name a = HolbuildBuildPlan.logical_name b

fun has_signature_companion plan node =
  List.exists
    (fn candidate => same_package_logical candidate node andalso
                     #kind (HolbuildBuildPlan.source_of candidate) = HolbuildSourceIndex.Sig)
    (HolbuildBuildPlan.lookup plan (HolbuildBuildPlan.logical_name node))

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

fun trace_paths checkpoint_policy data_paths =
  if trknl_enabled checkpoint_policy then
    map (fn path => drop_suffix ".dat" path ^ ".tr.gz") data_paths
  else []

fun output_paths checkpoint_policy _ node =
  let
    val artifacts = source_artifacts node
    val generated_paths = #generated artifacts
    val object_paths = #objects artifacts
    val data_paths = #theory_data artifacts
    val trace_paths = trace_paths checkpoint_policy data_paths
  in
    generated_paths @ map hfs_remapped_path generated_paths @
    object_paths @ map hfs_remapped_path object_paths @
    data_paths @ map hfs_remapped_path data_paths @
    trace_paths @ map hfs_remapped_path trace_paths
  end

fun output_hash_line path hash = "output-sha256=" ^ path ^ " " ^ hash

fun output_hash_lines_for_paths paths =
  (* Remapped artifacts are normally copied from their canonical counterparts,
     but they remain separate files and can be changed independently.  Hash
     each emitted path rather than treating the copy relationship as an
     integrity assertion. *)
  map (fn path => output_hash_line path (file_hash path))
      (paths @ map hfs_remapped_path paths)

fun output_hash_lines checkpoint_policy plan node =
  let
    val artifacts = source_artifacts node
    val data_paths = #theory_data artifacts
  in
    output_hash_lines_for_paths (#generated artifacts) @
    output_hash_lines_for_paths (#objects artifacts) @
    output_hash_lines_for_paths data_paths @
    output_hash_lines_for_paths (trace_paths checkpoint_policy data_paths) @
    map (fn path => output_hash_line path (file_hash path))
        (source_extra_output_paths plan node)
  end

fun theory_name_from_logical logical =
  if has_suffix "Theory" logical then drop_suffix "Theory" logical else logical

(* The whole closure, since a theory parent can be reached through an ML
   library.  Callers keep only the deps the child's .dat records as parents,
   which drops ordering-only deps. *)
fun project_theory_deps plan node =
  List.filter
    (fn dep => #kind (HolbuildBuildPlan.source_of dep) = HolbuildSourceIndex.TheoryScript)
    (HolbuildBuildPlan.transitive_project_deps plan node)

fun insert_first_string_dict (dict, key, value) =
  case Binarymap.peek (dict, key) of
      SOME _ => dict
    | NONE => Binarymap.insert (dict, key, value)

fun parse_dat_parent_hashes dat_text =
  let
    val n = size dat_text
    val empty = Binarymap.mkDict String.compare
    fun whitespace c = c = #" " orelse c = #"\n" orelse c = #"\t" orelse c = #"\r"
    fun skip_ws i = if i < n andalso whitespace (String.sub(dat_text, i)) then skip_ws (i + 1) else i
    fun scan_quote i =
      if i >= n then NONE
      else if String.sub(dat_text, i) = #"\"" then SOME i
      else scan_quote (i + 1)
    fun parse_pair start dict =
      let
        val key_start = start + 2
      in
        case scan_quote key_start of
            NONE => (dict, n)
          | SOME key_end =>
              let
                val dot = skip_ws (key_end + 1)
                val quote = skip_ws (dot + 1)
                val next = key_end + 1
              in
                if dot < n andalso String.sub(dat_text, dot) = #"." andalso
                   quote < n andalso String.sub(dat_text, quote) = #"\"" andalso
                   quote + 41 <= n then
                  let
                    val hash = String.substring(dat_text, quote + 1, 40)
                    val valid_hash = valid_sha1_text hash
                    val dict' =
                      if valid_hash then
                        insert_first_string_dict
                          (dict,
                           String.substring(dat_text, key_start, key_end - key_start),
                           hash)
                      else dict
                  in
                    (dict', if valid_hash then quote + 41 else quote + 1)
                  end
                else
                  (dict, next)
              end
      end
    fun loop i dict =
      if i + 1 >= n then dict
      else if String.sub(dat_text, i) = #"(" andalso String.sub(dat_text, i + 1) = #"\"" then
        let val (dict', next) = parse_pair i dict
        in loop next dict' end
      else
        loop (i + 1) dict
  in
    loop 0 empty
  end

fun parent_hash_metadata_lines plan node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        let
          val parent_hashes = parse_dat_parent_hashes (read_text (#data_path (theory_outputs node)))
          fun parent_line dep =
            let val parent_name = theory_name_from_logical (logical_name dep)
            in
              case Binarymap.peek (parent_hashes, parent_name) of
                  NONE => NONE
                | SOME hash => SOME ("parent_dat=" ^ parent_name ^ " " ^ hash)
            end
        in
          "parent_hashes=v1" :: List.mapPartial parent_line (project_theory_deps plan node)
        end
    | _ => []

fun checkpoint_lines _ _ _ = []

fun dependency_context_lines plan keys toolchain_key node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        ["dependency_context_key=" ^ dependency_context_key toolchain_key plan keys node]
    | _ => []

fun node_self_input_key checkpoint_policy plan toolchain_key node =
  HolbuildBuildPlan.self_input_key plan (fn _ => policy_config_lines checkpoint_policy)
    toolchain_key node

(* What early cutoff compares on a later key miss: the theory's own inputs and
   what its dependencies produced when it was built. *)
fun early_cutoff_lines checkpoint_policy plan toolchain_key node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        ("self_input_key=" ^ node_self_input_key checkpoint_policy plan toolchain_key node) ::
        (case deps_output_key toolchain_key plan node of
             SOME key => ["deps_output_key=" ^ key]
           | NONE => [])
    | _ => []

fun action_policy_lines plan node =
  let
    val policy = source_policy node
    val declared_dep_lines =
      map (fn dep => "declared_dep=" ^ dep) (HolbuildProject.action_deps policy)
    val declared_load_lines =
      map (fn dep => "declared_load=" ^ dep) (HolbuildProject.action_loads policy)
    val extra_inputs = HolbuildProject.action_extra_inputs policy
    val extra_lines =
      List.concat (map (fn input =>
        extra_dep_lines "extra_dep"
          (#package_root (HolbuildBuildPlan.source_of node))
          [HolbuildProject.extra_input_path input]) extra_inputs)
    val source_extra_lines =
      extra_dep_lines "source_extra_dep" (Path.dir (source_file node)) (#extra_deps (source_deps plan node))
    val source_extra_output_lines =
      map (fn output => "source_extra_output=" ^ output)
          (source_extra_output_declarations plan node)
  in
    ["cache=" ^ bool_text (HolbuildProject.action_cache_enabled policy),
     "always_reexecute=" ^ bool_text (HolbuildProject.action_always_reexecute policy)] @
    declared_dep_lines @
    declared_load_lines @
    extra_lines @
    source_extra_lines @
    source_extra_output_lines
  end

fun theorem_boundary_line ({safe_name, prefix_hash, context_path, end_of_proof_path, ...} : HolbuildTheoryCheckpoints.checkpoint) =
  "theorem_boundary " ^ safe_name ^ " " ^ prefix_hash ^ " " ^
  context_path ^ " " ^ end_of_proof_path

fun theorem_boundary_lines theorem_checkpoints =
  map theorem_boundary_line theorem_checkpoints

fun proof_timeout_lines proof_timeout node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => ["proof_timeout=" ^ timeout_text proof_timeout]
    | _ => []

fun metadata_core_lines checkpoint_policy proof_timeout project plan keys input_key toolchain_key node theorem_checkpoints =
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
    early_cutoff_lines checkpoint_policy plan toolchain_key node @
    parent_hash_metadata_lines plan node @
    proof_timeout_lines proof_timeout node @
    action_policy_lines plan node @
    checkpoint_lines checkpoint_policy project node @
    theorem_boundary_lines theorem_checkpoints
  end

fun lines_text lines = String.concatWith "\n" lines ^ "\n"

fun metadata_core_text checkpoint_policy proof_timeout project plan keys input_key toolchain_key node theorem_checkpoints =
  lines_text (metadata_core_lines checkpoint_policy proof_timeout project plan keys input_key toolchain_key node theorem_checkpoints)

fun metadata_text emit_output_hashes checkpoint_policy proof_timeout project plan keys input_key toolchain_key node theorem_checkpoints =
  lines_text
    (metadata_core_lines checkpoint_policy proof_timeout project plan keys input_key toolchain_key node theorem_checkpoints @
     (if emit_output_hashes then output_hash_lines checkpoint_policy plan node else []))

fun semantic_metadata_text text =
  lines_text (List.filter (fn line => not (String.isPrefix "output-sha256=" line))
                          (metadata_lines text))

fun metadata_input_key_matches input_key text =
  case metadata_value "input_key" (metadata_lines text) of
      SOME old_key => old_key = input_key
    | NONE => false

fun metadata_proof_timeout text =
  case parse_proof_timeout_field (metadata_lines text) "proof_timeout" of
      ProofTimeoutAbsent => legacy_default_proof_timeout
    | ProofTimeoutPresent timeout => timeout
    | ProofTimeoutInvalid => raise Error "metadata invalid proof_timeout"

fun metadata_timeout_satisfies allow_discrepancy policy node text =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript =>
        proof_timeout_field_satisfies allow_discrepancy (tactic_timeout policy)
          (parse_proof_timeout_field (metadata_lines text) "proof_timeout")
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

fun write_metadata emit_output_hashes checkpoint_policy proof_timeout project plan keys input_key toolchain_key node theorem_checkpoints =
  write_text (metadata_path project node)
             (metadata_text emit_output_hashes checkpoint_policy proof_timeout project plan keys input_key toolchain_key node theorem_checkpoints)

fun metadata_has_parent_hashes lines =
  metadata_value "parent_hashes" lines = SOME "v1"

fun theory_parent_metadata_needs_refresh node text =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => not (metadata_has_parent_hashes (metadata_lines text))
    | _ => false

fun parse_parent_dat_metadata_line line =
  let val prefix = "parent_dat="
  in
    if String.isPrefix prefix line then
      case String.tokens (fn c => c = #" ") (String.extract(line, size prefix, NONE)) of
          [parent_name, hash] =>
            if valid_sha1_text hash then SOME (parent_name, hash) else NONE
        | _ => NONE
    else NONE
  end

fun metadata_parent_hashes lines =
  List.foldl
    (fn (line, dict) =>
        case parse_parent_dat_metadata_line line of
            NONE => dict
          | SOME (parent_name, hash) => insert_first_string_dict (dict, parent_name, hash))
    (Binarymap.mkDict String.compare)
    lines

fun theory_parent_hash_recorded parent_hashes dep =
  Binarymap.peek (parent_hashes, theory_name_from_logical (logical_name dep)) <> NONE

(* Action dependencies also express build ordering.  A theory dependency is a
   parent only when the exported .dat records it, so do not make an ordering-only
   edge invalidate an otherwise valid artifact. *)
fun project_theory_parent_deps parent_hashes theory_deps =
  List.filter (theory_parent_hash_recorded parent_hashes) theory_deps

fun same_theory_parent_deps left right =
  let
    fun contains node nodes =
      List.exists (fn candidate => logical_name candidate = logical_name node)
                  nodes
  in
    List.all (fn node => contains node right) left andalso
    List.all (fn node => contains node left) right
  end

fun theory_parent_hash_matches dat_hash_cache parent_hashes dep =
  let
    val parent_name = theory_name_from_logical (logical_name dep)
  in
    (* Every selected exported theory parent must be represented by a valid hash.
       Treating a missing entry as a match lets truncated metadata or a
       malformed child .dat suppress a necessary rebuild. *)
    case cached_file_hash dat_hash_cache (#data_path (theory_outputs dep)) of
        NONE => false
      | SOME parent_hash =>
          (case Binarymap.peek (parent_hashes, parent_name) of
               NONE => false
             | SOME recorded_hash => recorded_hash = parent_hash)
  end

fun dat_parent_hashes_match dat_hash_cache plan node dat_path =
  let
    val parent_hashes = parse_dat_parent_hashes (read_text dat_path)
  in List.all (theory_parent_hash_matches dat_hash_cache parent_hashes)
              (project_theory_parent_deps parent_hashes (project_theory_deps plan node))
  end

fun child_dat_parent_hashes_match dat_hash_cache plan node =
  dat_parent_hashes_match dat_hash_cache plan node (#data_path (theory_outputs node))

fun metadata_parent_hashes_match dat_hash_cache plan node text =
  let
    val lines = metadata_lines text
    val child_parent_hashes = parse_dat_parent_hashes (read_text (#data_path (theory_outputs node)))
    val theory_deps = project_theory_deps plan node
    val child_parent_deps = project_theory_parent_deps child_parent_hashes theory_deps
  in
    if metadata_has_parent_hashes lines then
      let
        val recorded_parent_hashes = metadata_parent_hashes lines
        val recorded_parent_deps = project_theory_parent_deps recorded_parent_hashes theory_deps
      in
        (* Metadata is a cache for this check, not an authority on the current
           child artifact.  The two parent tables must name the same project
           theories: otherwise either metadata or the child .dat was truncated.
           Filtering through each table still admits ordering-only action deps,
           which appear in neither table. *)
        same_theory_parent_deps child_parent_deps recorded_parent_deps andalso
        List.all (theory_parent_hash_matches dat_hash_cache recorded_parent_hashes)
                 child_parent_deps andalso
        List.all (theory_parent_hash_matches dat_hash_cache child_parent_hashes)
                 child_parent_deps
      end
    else
      List.all (theory_parent_hash_matches dat_hash_cache child_parent_hashes)
               child_parent_deps
  end

fun theory_parent_hashes_match dat_hash_cache plan node metadata_text =
  detail_time_phase "build.exec.node.parent_hash_check"
    (fn () =>
        (case #kind (HolbuildBuildPlan.source_of node) of
             HolbuildSourceIndex.TheoryScript =>
               (case metadata_text of
                    SOME text => metadata_parent_hashes_match dat_hash_cache plan node text
                  | NONE => child_dat_parent_hashes_match dat_hash_cache plan node)
           | _ => true)
        handle _ => false)

fun up_to_date dat_hash_cache emit_output_hashes allow_timeout_discrepancy checkpoint_policy project plan keys input_key toolchain_key node theorem_checkpoints =
  detail_time_phase "build.exec.node.up_to_date"
    (fn () =>
        List.all (output_exists_for_node node) (output_paths checkpoint_policy plan node) andalso
        List.all file_exists (source_extra_output_paths plan node) andalso
        case current_metadata (metadata_path project node) of
             SOME text =>
               let
                 val metadata_ok =
                   metadata_input_key_matches input_key text andalso
                   metadata_timeout_satisfies allow_timeout_discrepancy checkpoint_policy node text
                 val parents_ok =
                   metadata_ok andalso theory_parent_hashes_match dat_hash_cache plan node (SOME text)
                 val _ =
                   if parents_ok andalso
                       (theory_parent_metadata_needs_refresh node text orelse
                        emit_output_hashes orelse
                        List.exists (String.isPrefix "output-sha256=") (metadata_lines text)) then
                     write_metadata emit_output_hashes checkpoint_policy
                       (if allow_timeout_discrepancy then metadata_proof_timeout text
                        else tactic_timeout checkpoint_policy)
                       project plan keys input_key toolchain_key node theorem_checkpoints
                   else ()
               in
                 metadata_ok andalso parents_ok
               end
           | NONE => false)

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

fun checkpoint_policy_for_node ({skip_checkpoints, proof_steps, new_ir, node_tactic_timeouts, execution_plan, trace_steps, repl_on_failure, trknl, ...} : build_options) project node =
  if root_package_node project node then
    CheckpointPolicy {checkpoint = not skip_checkpoints,
                      proof_steps = proof_steps,
                      new_ir = new_ir,
                      tactic_timeout = effective_tactic_timeout proof_steps
                                        (assoc_timeout (HolbuildBuildPlan.key node) node_tactic_timeouts),
                      execution_plan = if proof_steps then execution_plan else NONE,
                      trace_steps = proof_steps andalso trace_steps,
                      repl_on_failure = repl_on_failure,
                      trknl = trknl}
  else
    CheckpointPolicy {checkpoint = false,
                      proof_steps = false,
                      new_ir = false,
                      tactic_timeout = NONE,
                      execution_plan = NONE,
                      trace_steps = false,
                      repl_on_failure = false,
                      trknl = trknl}

fun proof_engine (CheckpointPolicy {proof_steps = false, ...}) = "plain_v1"
  | proof_engine (CheckpointPolicy {new_ir = true, ...}) = "proof_ir_v3"
  | proof_engine _ = "proof_steps_failed_fragment_span_v6"

fun build_config_lines_for_node options project node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => policy_config_lines (checkpoint_policy_for_node options project node)
    | HolbuildSourceIndex.Sml => policy_config_lines no_checkpoint_policy
    | HolbuildSourceIndex.Sig => policy_config_lines no_checkpoint_policy

(* The saved HOL state `run --from` starts from, or why there is none.
   deps_loaded has THEORY's ancestors loaded; LOAD is THEORY's generated module
   when its built outputs are for its current source, so the session loads it
   on top. *)
datatype run_from_state =
  DepsLoadedState of {path : string, load : string option}
| NoRunFromState of string

(* Checkpoints are current only for the keys a build of NODE would use now.
   Run holds no project lock, so this only reads checkpoint files; a build, gc
   or eviction that removes the chosen checkpoint before HOL loads it makes
   the run fail rather than start from a wrong state. *)
fun run_from_state tc project plan keys node =
  let
    val name = logical_name node
    val toolchain_key = HolbuildToolchain.toolchain_key tc
    fun built_for_current_source dep =
      case current_metadata (metadata_path project dep) of
          SOME text => metadata_input_key_matches (HolbuildBuildPlan.input_key_for keys dep) text
        | NONE => false
    (* Run builds nothing, so the dependencies' outputs on disk can be older
       than their sources: key on them only when every one is built for its
       current source. *)
    val deps_key =
      if List.all built_for_current_source (HolbuildBuildPlan.transitive_project_deps plan node)
      then dependency_context_key toolchain_key plan keys node
      else dependency_input_context_key toolchain_key plan keys node
    val base = checkpoint_base project node
    fun deps_loaded_current dir =
      HolbuildCheckpointStore.ok_current (Path.concat(dir, "deps_loaded.save"))
        [("kind", "deps_loaded"), ("deps_key", Path.file dir)]
    val deps_dir = Path.concat(deps_checkpoint_root base, deps_key)
    fun theory_built () =
      case current_metadata (metadata_path project node) of
          SOME text => metadata_input_key_matches (HolbuildBuildPlan.input_key_for keys node) text
        | NONE => false
    fun deps_changed () =
      List.exists (fn dir => dir <> deps_dir andalso deps_loaded_current dir)
        (children (deps_checkpoint_root base))
  in
    if not (root_package_node project node) then
      NoRunFromState (name ^ " is in dependency package " ^ package node ^
                      "; holbuild keeps checkpoints only for root-package theories")
    else if deps_loaded_current deps_dir then
      DepsLoadedState {path = deps_loaded_path base deps_key,
                       load = if theory_built () then SOME (load_stem node) else NONE}
    else if deps_changed () then
      NoRunFromState ("the dependencies or HOL toolchain of " ^ name ^
                      " changed since its checkpoints were saved")
    else
      NoRunFromState (name ^ " has no current checkpoint (not built yet, restored from the cache " ^
                      "without a local build, " ^
                      "built with --skip-checkpoints, or removed by gc)")
  end

fun write_temp_text path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

type proof_ir_input = {name : string, tactic_start : int, tactic_end : int, tactic_text : string}

fun analyser_proof_ir_plan_sml (inputs : proof_ir_input list) =
  case HolbuildDependencies.current_analyser_path () of
      NONE => raise Error "internal error: HOL analyser is not configured"
    | SOME analyser =>
        let
          fun proof_line (i, {name, tactic_start, tactic_end, tactic_text} : proof_ir_input) =
            HolbuildAnalysisProtocol.join ["theorem", Int.toString i, name,
                                           Int.toString tactic_start, Int.toString tactic_end, tactic_text]
          val req = OS.FileSys.tmpName ()
          val resp = OS.FileSys.tmpName ()
          val request = String.concatWith "\n"
            ([HolbuildAnalysisProtocol.join ["version", HolbuildAnalysisProtocol.protocol_version],
              HolbuildAnalysisProtocol.join ["command", "proof-ir-plan"]] @
             map proof_line (ListPair.zip (List.tabulate(length inputs, fn i => i), inputs)) @
             [HolbuildAnalysisProtocol.join ["end"]]) ^ "\n"
          val _ = write_temp_text req request
          val status = OS.Process.system (HolbuildHash.quote analyser ^ " " ^
                                          String.concatWith " " (HolbuildDependencies.analyser_min_heap_args ()) ^
                                          " --request " ^ HolbuildHash.quote req ^
                                          " --response " ^ HolbuildHash.quote resp)
          val _ = OS.FileSys.remove req handle OS.SysErr _ => ()
          val text = if OS.Process.isSuccess status then read_text resp
                     else (OS.FileSys.remove resp handle OS.SysErr _ => ();
                           raise Error "holbuild-hol-analyser failed")
          val _ = OS.FileSys.remove resp handle OS.SysErr _ => ()
          val expected = length inputs
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

fun reject_unenforced_tactic_timeout policy (action : theory_action) detail =
  case tactic_timeout policy of
      NONE => ()
    | SOME seconds =>
        raise Error ("cannot enforce requested tactic timeout of " ^
                     timeout_text (SOME seconds) ^ "s while building " ^
                     #logical action ^ " because theorem instrumentation is unavailable\n" ^
                     detail)

fun source_boundaries_for_action policy (action : theory_action) source_text =
  SOME (detail_time_phase "build.exec.node.analyse_boundaries"
          (fn () => discover_theorem_boundaries_recovering (#source_file action) source_text))
  handle Error msg =>
    (reject_unenforced_tactic_timeout policy action msg;
     warn ("could not safely instrument theorem boundaries for " ^ #logical action ^
           "; building without proof steps/checkpoints for this theory\n" ^ msg);
     NONE)

fun fallback_theory_checkpoints (action : theory_action) msg =
  (warn ("could not safely instrument theorem boundaries for " ^ #logical action ^
         "; building without proof steps/checkpoints for this theory\n" ^ msg);
   [])

fun theory_checkpoints_for_action policy checkpoint_root (action : theory_action) source_text boundaries errors =
  if not (proof_steps_enabled policy) andalso not (checkpoint_enabled policy) then []
  else
    let
      val proof_ir_plans =
        if null boundaries then []
        else if proof_ir_enabled policy then
          detail_time_phase "build.exec.node.proof_ir_plan"
            (fn () => analyser_proof_ir_plan_sml
              (map (fn {name, tactic_start, tactic_end, tactic_text, ...} =>
                       {name = name, tactic_start = tactic_start,
                        tactic_end = tactic_end, tactic_text = tactic_text})
                   boundaries))
        else map (fn _ => NONE) boundaries
      val _ =
        case errors of
            [] => ()
          | _ => warn ("HOL source parser recovered while instrumenting theorem boundaries for " ^
                       #logical action ^ "; using recovered theorem boundaries\n" ^
                       String.concatWith "\n" errors)
    in
      theorem_checkpoint_specs (proof_engine policy) (tactic_timeout policy)
        (action_checkpoint_base checkpoint_root action) (#deps_key action)
        (#inputs_key action) source_text proof_ir_plans boundaries
    end
    handle Error msg =>
      (reject_unenforced_tactic_timeout policy action msg;
       if proof_ir_enabled policy then raise Error msg
       else fallback_theory_checkpoints action msg)

fun termination_proof_plans_for_action policy (action : theory_action) terminations =
  if null terminations orelse not (proof_ir_enabled policy) then terminations
  else
    let
      val plans = detail_time_phase "build.exec.node.proof_ir_plan_terminations"
        (fn () => analyser_proof_ir_plan_sml
          (map (fn ({name, tactic_start, tactic_end, tactic_text, ...} : HolbuildTheoryCheckpoints.termination) =>
                   {name = name, tactic_start = tactic_start,
                    tactic_end = tactic_end, tactic_text = tactic_text})
               terminations))
      fun attach (termination, plan) =
        let
          val {name, safe_name, definition_start, definition_stop, boundary,
               quote_start, quote_end, quote_text, tactic_start, tactic_end,
               tactic_text, ...} = termination
        in
          {name = name, safe_name = safe_name,
           definition_start = definition_start, definition_stop = definition_stop,
           boundary = boundary, quote_start = quote_start, quote_end = quote_end,
           quote_text = quote_text, tactic_start = tactic_start,
           tactic_end = tactic_end, tactic_text = tactic_text,
           proof_ir_plan = plan}
        end
    in
      if length plans = length terminations then ListPair.map attach (terminations, plans)
      else raise Error "internal error: proof-IR plan count does not match termination count"
    end
    handle Error msg =>
      (reject_unenforced_tactic_timeout policy action msg;
       raise Error ("could not create termination proof plans for " ^ #logical action ^ "\n" ^ msg))

fun termination_diagnostics_for_action policy (action : theory_action) source_text =
  if not (proof_steps_enabled policy) then []
  else detail_time_phase "build.exec.node.analyse_terminations"
         (fn () => discover_termination_diagnostics_strict (#source_file action) source_text)
    handle Error msg =>
      (warn ("could not safely instrument termination diagnostics for " ^ #logical action ^
             "; building without termination goal diagnostics for this theory\n" ^ msg);
       [])

fun source_spans_for_action policy (action : theory_action) source_text =
  if proof_steps_enabled policy then
    let
      val combined =
        detail_time_phase "build.exec.node.analyse_boundaries"
          (fn () =>
              detail_time_phase "build.exec.node.analyse_terminations"
                (fn () => discover_boundaries_and_terminations (#source_file action) source_text))
    in
      {source_boundaries = SOME {boundaries = #boundaries combined, errors = #errors combined},
       termination_diagnostics = #terminations combined}
    end
    handle Error _ =>
      {source_boundaries = source_boundaries_for_action policy action source_text,
       termination_diagnostics = termination_diagnostics_for_action policy action source_text}
  else
    {source_boundaries = source_boundaries_for_action policy action source_text,
     termination_diagnostics = []}

fun declaration_checkpoints_for_action policy checkpoint_root (action : theory_action) source_text terminations =
  if not (checkpoint_enabled policy) orelse not (proof_steps_enabled policy) then []
  else
    declaration_checkpoint_specs (proof_engine policy) (tactic_timeout policy)
      (action_checkpoint_base checkpoint_root action) (#deps_key action)
      (#inputs_key action) source_text terminations
    handle Error msg =>
      (warn ("could not safely create termination-definition checkpoints for " ^ #logical action ^
             "; building without termination-definition checkpoints for this theory\n" ^ msg);
       [])

(* The theory's proof-step and checkpoint plan, from its script. *)
fun action_checkpoints policy checkpoint_root (action : theory_action) source_text =
  let
    val source_spans = source_spans_for_action policy action source_text
    val theorem_checkpoints =
      case #source_boundaries source_spans of
          NONE => []
        | SOME {boundaries, errors} =>
            theory_checkpoints_for_action policy checkpoint_root action source_text boundaries errors
    val termination_diagnostics =
      termination_proof_plans_for_action policy action (#termination_diagnostics source_spans)
    val declaration_checkpoints =
      declaration_checkpoints_for_action policy checkpoint_root action source_text termination_diagnostics
  in
    {theorem_checkpoints = theorem_checkpoints,
     declaration_checkpoints = declaration_checkpoints,
     termination_diagnostics = termination_diagnostics}
  end

(* Runs a theory action in action root `root` with the plan above, keeping
   its checkpoints in checkpoint root `checkpoint_root`, again after
   discarding a checkpoint HOL could not resume from.  Returns the generated
   theory's load metadata, and leaves the stage to the caller, as
   `run_theory_action`, and the failed-prefix checkpoints a successful run
   made obsolete too: checkpoints saved after resuming from one are its
   children. *)
fun run_theory_action_checkpoints cache_allowed policy tc root checkpoint_root base_context (action : theory_action) source_text
      {theorem_checkpoints, declaration_checkpoints, termination_diagnostics} =
  let
    fun run retries_left =
      run_theory_action cache_allowed policy tc root checkpoint_root base_context action source_text
                        theorem_checkpoints declaration_checkpoints termination_diagnostics
      handle RetryInvalidCheckpoint =>
        if retries_left <= 0 then raise RetryInvalidCheckpoint
        else run (retries_left - 1)
  in
    run (length theorem_checkpoints + length declaration_checkpoints + 1)
  end

fun build_theory_action cache_allowed policy tc root checkpoint_root base_context (action : theory_action) =
  let
    val source_text = read_text (#source_file action)
    val checkpoints = action_checkpoints policy checkpoint_root action source_text
    val generated_metadata =
      run_theory_action_checkpoints cache_allowed policy tc root checkpoint_root base_context action source_text
        checkpoints
  in
    remove_failed_prefix_checkpoints (#theorem_checkpoints checkpoints);
    generated_metadata
  end

(* Builds a theory from its source in the project: runs its theory action with
   the project's artifact root as action root, then puts the extra outputs in
   the source tree and writes the theory's local load manifests. *)
fun build_theory cache_allowed policy tc project base_context plan keys toolchain_key node =
  let
    val root = project_artifact_root project
    val action = theory_action root plan keys toolchain_key (#holdir tc)
                   (dependency_context_key toolchain_key plan keys node) node
    val generated_metadata =
      build_theory_action cache_allowed policy tc root (default_checkpoint_root root) base_context action
    val stage = action_stage root action
    val extra_output_paths = source_extra_output_paths plan node
  in
    claim_extra_outputs project node extra_output_paths;
    List.app
      (fn declaration =>
          let val destination = source_extra_output_path node declaration
          in ensure_parent destination;
             copy_binary (staged_extra_output_path stage declaration) destination
          end)
      (#extra_outputs action);
    record_materialized_extra_outputs project node extra_output_paths;
    write_local_theory_manifests plan node generated_metadata;
    remove_tree (stage_root_at root (#input_key action))
  end

(* After early cutoff, the theory's cache entry under its old input key also
   describes its outputs for the new one, so the entry is copied to the new
   key, where commands that read the cache by current key (export) find it,
   and published to the remote cache as a build would.  Only a usable entry
   is copied, and only where the new key has none. *)
fun alias_cache_entry old_key new_key =
  let
    val root = cache_root ()
    fun alias () =
      case (HolbuildCache.get_action root new_key, HolbuildCache.get_action root old_key) of
          (NONE, SOME old_text) =>
            if cache_entry_usable root old_key old_text then
              (HolbuildCache.write_action root
                 {key = new_key,
                  text = replace_all ("\ninput_key=" ^ old_key ^ "\n") ("\ninput_key=" ^ new_key ^ "\n")
                                     old_text};
               true)
            else false
        | _ => false
  in
    if HolbuildCache.with_action_publish_lock root new_key alias (fn () => false)
    then publish_remote_cache_key_if_usable root new_key
    else ()
  end
  handle e => warn ("could not alias cache entry: " ^ General.exnMessage e)

fun build_theory_node dat_hash_cache (options : build_options) tc project base_context plan keys toolchain_key node input_key =
  let
    val policy = checkpoint_policy_for_node options project node
    val metadata_checkpoints = []
    val stage = stage_dir project input_key
    val forced = force_node options project node
    val cache_allowed = #use_cache options andalso cache_enabled node
    val cache_restore_allowed = cache_allowed andalso not forced
    val allow_timeout_discrepancy = #allow_cache_timeout_discrepancy options
    val _ = claim_extra_outputs project node (source_extra_output_paths plan node)
    fun invalidate_node_dat_hash () =
      invalidate_cached_file_hash dat_hash_cache (#data_path (theory_outputs node))
    fun materialize_valid_cache () =
      let
        val root = cache_root ()
        val existing = ensure_local_cache_entry root input_key
        fun discard_entry () =
          case existing of
              SOME text => ignore (drop_cache_manifest_if_unchanged root input_key text)
            | NONE => ()
        fun reject_parents () =
          (cache_trace ("cache miss: " ^ logical_name node ^ " " ^ cache_key_role ^ "=" ^
                        input_key ^ " (parent outputs differ)");
           discard_entry ();
           remove_failed_cache_outputs project node; CacheMiss)
        fun cached_parents_match text =
          let
            val {dat_hash, ...} = cache_manifest_blobs_from_lines input_key (cache_manifest_lines text)
          in
            dat_parent_hashes_match dat_hash_cache plan node (HolbuildCache.blob_path root dat_hash)
          end
          handle _ => false
      in
        case existing of
            NONE => (cache_trace ("cache miss: " ^ logical_name node ^ " " ^ cache_key_role ^ "=" ^
                                  input_key ^ " (no manifest)"); CacheMiss)
          | SOME text =>
              case materialize_theory_cache (#verify_cache options) allow_timeout_discrepancy
                     project plan input_key (tactic_timeout policy) (trknl_enabled policy) node of
                  (* A policy miss can also hide stale parent outputs. Preserve
                     compatible weaker-policy entries if rechecking fails. *)
                  CacheMiss => if cached_parents_match text then CacheMiss else reject_parents ()
                | restored as CacheRestored _ =>
                    if theory_parent_hashes_match dat_hash_cache plan node NONE then restored
                    else reject_parents ()
      end
    fun restore_from_cache built_timeout =
      (remove_tree stage;
       invalidate_node_dat_hash ();
       write_metadata (#emit_output_hashes options) policy
         (if allow_timeout_discrepancy then built_timeout else tactic_timeout policy)
         project plan keys input_key toolchain_key node metadata_checkpoints;
       if copied_from_remote input_key then HolbuildStatus.RestoredRemote else HolbuildStatus.Restored)
    fun build_from_source () =
      if #restore_only options then
        (HolbuildHolSharedCache.local_build_needed := true;
         raise Error (logical_name node ^ " is not in the remote cache, and --remote-only builds nothing locally"))
      else
      (build_theory cache_allowed policy tc project base_context plan keys toolchain_key node;
       invalidate_node_dat_hash ();
       write_metadata (#emit_output_hashes options) policy (tactic_timeout policy) project plan keys input_key toolchain_key node metadata_checkpoints;
       HolbuildStatus.Built)
      handle ExecutionPlanPrinted => (remove_tree stage; HolbuildStatus.Inspected)
    (* The metadata goes before the outputs are replaced, so outputs of an
       interrupted restore or build are never taken for those of the last one
       (by the up-to-date check or early cutoff).  Printing the execution plan
       replaces nothing. *)
    fun restore_or_build () =
      (if execution_plan_only policy then () else remove_file (metadata_path project node);
       if not cache_restore_allowed then build_from_source ()
       else
         case materialize_valid_cache () of
             CacheRestored built_timeout => restore_from_cache built_timeout
           | CacheMiss => build_from_source ())
    (* Early cutoff: on an input-key miss, the outputs on disk are still the
       ones a build would produce when the theory's own inputs and everything
       its dependencies produced are as they were at its last build.  Returns
       that build's metadata. *)
    fun early_cutoff_metadata () =
      if List.all (output_exists_for_node node) (output_paths policy plan node) andalso
         List.all file_exists (source_extra_output_paths plan node) then
        case current_metadata (metadata_path project node) of
            NONE => NONE
          | SOME text =>
              let val lines = metadata_lines text
              in
                if metadata_value "self_input_key" lines =
                     SOME (node_self_input_key policy plan toolchain_key node) andalso
                   (case deps_output_key toolchain_key plan node of
                        SOME key => metadata_value "deps_output_key" lines = SOME key
                      | NONE => false) andalso
                   metadata_timeout_satisfies allow_timeout_discrepancy policy node text andalso
                   theory_parent_hashes_match dat_hash_cache plan node (SOME text)
                then SOME text
                else NONE
              end
      else NONE
    fun reuse_outputs text =
      (remove_tree stage;
       if cache_allowed then
         case metadata_value "input_key" (metadata_lines text) of
             SOME old_key => alias_cache_entry old_key input_key
           | NONE => ()
       else ();
       write_metadata (#emit_output_hashes options) policy
         (if allow_timeout_discrepancy then metadata_proof_timeout text else tactic_timeout policy)
         project plan keys input_key toolchain_key node metadata_checkpoints;
       cache_trace ("early cutoff: " ^ logical_name node ^ " (dependency outputs unchanged)");
       HolbuildStatus.UpToDate)
  in
    if forced orelse always_reexecute node then restore_or_build ()
    else if up_to_date dat_hash_cache (#emit_output_hashes options) allow_timeout_discrepancy
              policy project plan keys input_key toolchain_key node metadata_checkpoints then
      (remove_tree stage;
       HolbuildStatus.UpToDate)
    else
      case early_cutoff_metadata () of
          SOME text => reuse_outputs text
        | NONE => restore_or_build ()
  end

fun build_node dat_hash_cache options tc project base_context plan keys toolchain_key node =
  let val input_key = HolbuildBuildPlan.input_key_for keys node
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript =>
          build_theory_node dat_hash_cache options tc project base_context plan keys toolchain_key node input_key
      | HolbuildSourceIndex.Sml =>
          if not (force_node options project node) andalso not (always_reexecute node) andalso
             up_to_date dat_hash_cache (#emit_output_hashes options) (#allow_cache_timeout_discrepancy options)
               no_checkpoint_policy project plan keys input_key toolchain_key node [] then
            HolbuildStatus.UpToDate
          else (build_sml_like plan node ".uo";
                write_metadata (#emit_output_hashes options) no_checkpoint_policy (tactic_timeout no_checkpoint_policy) project plan keys input_key toolchain_key node [];
                HolbuildStatus.Built)
      | HolbuildSourceIndex.Sig =>
          if not (force_node options project node) andalso not (always_reexecute node) andalso
             up_to_date dat_hash_cache (#emit_output_hashes options) (#allow_cache_timeout_discrepancy options)
               no_checkpoint_policy project plan keys input_key toolchain_key node [] then
            HolbuildStatus.UpToDate
          else (build_sml_like plan node ".ui";
                write_metadata (#emit_output_hashes options) no_checkpoint_policy (tactic_timeout no_checkpoint_policy) project plan keys input_key toolchain_key node [];
                HolbuildStatus.Built)
  end

fun node_policy options project node =
  case #kind (HolbuildBuildPlan.source_of node) of
      HolbuildSourceIndex.TheoryScript => checkpoint_policy_for_node options project node
    | HolbuildSourceIndex.Sml => no_checkpoint_policy
    | HolbuildSourceIndex.Sig => no_checkpoint_policy

fun node_is_up_to_date options project plan keys toolchain_key node =
  not (force_node options project node) andalso not (always_reexecute node) andalso
  up_to_date (new_file_hash_cache ()) (#emit_output_hashes options) (#allow_cache_timeout_discrepancy options)
             (node_policy options project node) project plan keys (HolbuildBuildPlan.input_key_for keys node)
             toolchain_key node []

fun report_up_to_date_node status project keys node =
  let
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val key = HolbuildBuildPlan.key node
    val label = HolbuildBuildPlan.logical_name node
  in
    HolbuildStatus.start_node status key label;
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript => remove_tree (stage_dir project input_key)
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
    (* Its outputs are final now; a digest taken earlier may be stale. *)
    HolbuildBuildPlan.forget_output_digest plan node;
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
   watch_paths : string list ref,
   index_bases : (string, unit) Binarymap.dict ref,
   index_finalized : bool ref,
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

fun watch_with_paths paths dir families =
  List.foldl (fn (path, watch) => watch_insert_dir path watch)
             (watch_from_families dir families)
             paths

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

(* Mid-build discovery and startup index validation use the same artifact-aware,
   size-free topology walk. *)
fun shallow_family_bases root = checkpoint_family_bases_on_disk root

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
    (* If the dirty marker cannot be installed, discard the trusted index.  A
       crash during this build must make the next process rescan rather than
       accept state that this process could not mark as in-flight. *)
    val _ =
      (ensure_parent dirty_path; write_text dirty_path "building\n")
      handle e =>
        (warn ("could not mark checkpoint index dirty: " ^ General.exnMessage e);
         remove_file (checkpoint_index_path checkpoint_dir))
  in
    {checkpoint_dir = checkpoint_dir,
     checkpoint_limit_gb = checkpoint_limit_gb,
     max_bytes = gb_to_bytes checkpoint_limit_gb,
     index = ref index,
     watch_paths = ref [checkpoint_dir],
     watch = ref (watch_with_paths [checkpoint_dir] checkpoint_dir (#families index)),
     index_bases = ref (bases_set_of (#families index)),
     index_finalized = ref false,
     refreshed = ref false,
     mutex = Mutex.mutex ()}
  end

fun clear_checkpoint_index_dirty (state : checkpoint_budget_state) =
  if !(#index_finalized state) then
    remove_file (checkpoint_index_dirty_path (#checkpoint_dir state))
  else ()

fun warn_checkpoint_budget_error e =
  warn ("checkpoint budget maintenance failed: " ^ General.exnMessage e)

fun with_checkpoint_budget_lock (state : checkpoint_budget_state) f =
  (Mutex.lock (#mutex state); f () before Mutex.unlock (#mutex state))
  handle e => (Mutex.unlock (#mutex state); raise e)

(* Generated source trees commonly already exist before their checkpoint
   families are created.  Watching only ancestors of existing families then
   misses their mtime changes, postponing eviction until the final recovery
   scan.  Register every scheduled checkpoint base up front so such families
   are discovered after the node that creates them, without a byte scan. *)
fun register_checkpoint_budget_bases state bases =
  with_checkpoint_budget_lock state
    (fn () =>
        let
          val dir = #checkpoint_dir state
          val paths = unique_strings
                        (!(#watch_paths state) @
                         List.concat (map (family_base_ancestors dir) bases))
        in
          #watch_paths state := paths;
          #watch state := watch_with_paths paths dir (#families (!(#index state)))
        end)

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
  in
    final_index
  end

fun install_checkpoint_index_locked (state : checkpoint_budget_state) final_index =
  (#index state := final_index;
   #index_bases state := bases_set_of (#families final_index);
   #watch state := watch_with_paths (!(#watch_paths state))
                                     (#checkpoint_dir state) (#families final_index))

fun enforce_checkpoint_budget_state_excluding state protected_bases =
  detail_time_phase "build.exec.checkpoint_budget"
    (fn () =>
        (with_checkpoint_budget_lock state
          (fn () =>
              let
                val final_index = enforce_checkpoint_index_locked state (!(#index state)) protected_bases
              in
                install_checkpoint_index_locked state final_index
              end))
        handle e => warn_checkpoint_budget_error e)

(* Mid-build passes update only the in-memory index.  The dirty marker already
   guarantees a recovery scan after a crash, so rewriting the full index after
   every completed theory provides no safety and is expensive on large graphs.
   Only this final pass may authorize removal of the dirty marker. *)
fun finalize_checkpoint_budget_state_excluding state rebuild protected_bases =
  detail_time_phase "build.exec.checkpoint_budget"
    (fn () =>
        (with_checkpoint_budget_lock state
          (fn () =>
              let
                val _ = #index_finalized state := false
                val index' =
                  if rebuild then rebuild_checkpoint_index (#checkpoint_dir state)
                  else !(#index state)
                val final_index = enforce_checkpoint_index_locked state index' protected_bases
                val _ = install_checkpoint_index_locked state final_index
                val _ = write_checkpoint_index_atomically final_index
              in
                #index_finalized state := true
              end))
        handle e => warn ("could not finalize checkpoint index: " ^ General.exnMessage e))

fun mark_checkpoint_budget_refresh_needed state =
  with_checkpoint_budget_lock state (fn () => #refreshed state := true)

(* Tests can hold a refresh at its entry to make scheduler/maintenance ordering
   observable without relying on the speed of a filesystem scan. *)
fun checkpoint_budget_test_gate () =
  case OS.Process.getEnv "HOLBUILD_TEST_CHECKPOINT_BUDGET_GATE" of
      NONE => ()
    | SOME base =>
        let
          val active = base ^ ".active"
          val release = base ^ ".release"
          fun wait 0 = warn "checkpoint budget test gate timed out"
            | wait remaining =
                if path_exists release then ()
                else
                  (OS.Process.sleep (Time.fromReal 0.01);
                   wait (remaining - 1))
          val _ = write_text active "active\n"
          val _ = wait 3000
        in
          remove_file active
        end

fun refresh_checkpoint_budget_after_node state project node protected_bases =
  detail_time_phase "build.exec.checkpoint_budget"
    (fn () =>
        (let
           (* Mark this before any filesystem operation.  If discovery fails,
              finalization must rebuild rather than persist the old in-memory
              index and clear the dirty marker. *)
           val _ = mark_checkpoint_budget_refresh_needed state
           val _ = checkpoint_budget_test_gate ()
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
                   install_checkpoint_index_locked state final_index
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
              HolbuildStatus.Inspected => mark_checkpoint_budget_refresh_needed budget_state
            | outcome =>
                (if outcome_may_create_checkpoints options project node outcome then
                   refresh_checkpoint_budget_after_node budget_state project node []
                 else ();
                 loop rest)
  in
    loop (HolbuildBuildPlan.selected_nodes plan)
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
    val priority_ready_count = ref 0
    val mutex = Mutex.mutex ()
    val cv = ConditionVar.conditionVar ()
    val running = ref 0
    val priority_running = ref 0
    val completed = ref 0
    val active = ref jobs
    val active_nodes = Array.array (node_count, false)
    fun int_compare (left : int, right : int) =
      if left < right then LESS else if left > right then GREATER else EQUAL
    val active_ids : int Binaryset.set ref = ref (Binaryset.empty int_compare)
    (* A checkpoint refresh may unlink whole Poly/ML saved-state families.  Keep
       dispatch closed from the protected-family snapshot through eviction, and
       hand consecutive refreshes directly to the next completing worker so
       there is no dispatch window between them. *)
    val checkpoint_maintenance_owner = ref (NONE : int option)
    val checkpoint_maintenance_queue = ref ([] : int list)
    val stopped = ref false
    val failure = ref (NONE : (string * HolbuildStatus.debug_artifacts) option)
    val failed_prefix_priority = Array.array (node_count, NONE : bool option)

    fun node_id node = HolbuildBuildPlan.indexed_key_id key_index (HolbuildBuildPlan.key node)

    fun node_may_create_checkpoints node =
      case #kind (HolbuildBuildPlan.source_of node) of
          HolbuildSourceIndex.TheoryScript => checkpoint_enabled (checkpoint_policy_for_node options project node)
        | _ => false

    val checkpoints_possible = List.exists node_may_create_checkpoints selected

    val empty_protected_bases : string Binaryset.set = Binaryset.empty String.compare

    fun mark_active_node id =
      (Array.update (active_nodes, id, true);
       active_ids := Binaryset.add (!active_ids, id))

    fun clear_active_node id =
      (Array.update (active_nodes, id, false);
       active_ids := (Binaryset.delete (!active_ids, id) handle Binaryset.NotFound => !active_ids))

    fun failed_prefix_priority_node id =
      case Array.sub (failed_prefix_priority, id) of
          SOME value => value
        | NONE =>
            let val value =
                  (node_has_failed_prefix_checkpoint project (Vector.sub (nodes, id))
                   handle _ => false)
            in Array.update (failed_prefix_priority, id, SOME value); value end

    fun add_ready id =
      (if failed_prefix_priority_node id then
         priority_ready_count := !priority_ready_count + 1
       else ();
       ready := id :: !ready)

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
      let val has = node_has_failed_prefix_checkpoint project (Vector.sub (nodes, id))
                    handle _ => false
      in
        Array.update (failed_prefix_priority, id, SOME has);
        if has then (priority_mode := true; mark_priority_focus id) else ()
      end

    fun mark_priority_roots id =
      if id >= node_count then ()
      else (mark_priority_root id; mark_priority_roots (id + 1))

    (* Replay retained failures before unrelated ready work.  This scheduling
       policy is independent of whether a post-failure REPL was requested. *)
    val _ = mark_priority_roots 0

    fun signal () = ConditionVar.broadcast cv
    fun lock () = Mutex.lock mutex
    fun unlock () = Mutex.unlock mutex

    fun pop_matching_ready matches prefix rest =
      case rest of
          [] => NONE
        | id :: suffix =>
            if matches id then SOME (id, rev prefix @ suffix)
            else pop_matching_ready matches (id :: prefix) suffix

    fun priority_focus_node id = Array.sub (priority_focus, id)

    fun note_ready_pop priority =
      if priority then priority_ready_count := !priority_ready_count - 1 else ()

    fun pop_ready () =
      case !ready of
          [] => NONE
        | id :: rest =>
            if !priority_mode andalso !priority_focus_remaining > 0 then
              (case pop_matching_ready priority_focus_node [] (id :: rest) of
                   SOME (focus_id, remaining) =>
                     let val priority = failed_prefix_priority_node focus_id
                     in
                       ready := remaining;
                       note_ready_pop priority;
                       SOME (focus_id, priority)
                     end
                 | NONE => NONE)
            else
              (priority_mode := false;
               if !priority_ready_count > 0 then
                 case pop_matching_ready failed_prefix_priority_node [] (id :: rest) of
                     SOME (priority_id, remaining) =>
                       (ready := remaining; note_ready_pop true; SOME (priority_id, true))
                   | NONE =>
                       if !priority_running > 0 then NONE
                       else (ready := rest; SOME (id, false))
               else if !priority_running > 0 then NONE
               else (ready := rest; SOME (id, false)))

    fun next_work_locked () =
      case !failure of
          SOME _ => NONE
        | NONE =>
            if !stopped then NONE
            else if Option.isSome (!checkpoint_maintenance_owner) then
              (ConditionVar.wait (cv, mutex); next_work_locked ())
            else
              case pop_ready () of
                  SOME (id, priority) =>
                    (running := !running + 1;
                     mark_active_node id;
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
      Binaryset.listItems (!active_ids)

    fun protected_bases_for_ids ids =
      Binaryset.listItems
        (List.foldl
           (* A child resumes only from a heap in its own checkpoint family.
              Project dependencies are loaded from ordinary .uo/.dat artifacts,
              so protecting their checkpoint families pins completed, unused
              state and can defeat the configured budget on a wide/deep graph. *)
           (fn (id, acc) =>
               Binaryset.add
                 (acc, checkpoint_base project (Vector.sub (nodes, id))))
           empty_protected_bases
           ids)

    fun finish_success_transition_locked id =
      (running := !running - 1;
       clear_active_node id;
       finish_priority id;
       completed := !completed + 1;
       if !stopped then () else List.app release_dependent (Array.sub (dependents, id)))

    fun wait_for_no_checkpoint_maintenance_locked () =
      case !checkpoint_maintenance_owner of
          NONE => ()
        | SOME _ =>
            (ConditionVar.wait (cv, mutex);
             wait_for_no_checkpoint_maintenance_locked ())

    fun finish_success id =
      with_lock
        (fn () =>
            (wait_for_no_checkpoint_maintenance_locked ();
             finish_success_transition_locked id;
             signal ()))

    fun enqueue_checkpoint_maintenance_locked id =
      case !checkpoint_maintenance_owner of
          NONE => checkpoint_maintenance_owner := SOME id
        | SOME _ =>
            checkpoint_maintenance_queue := !checkpoint_maintenance_queue @ [id]

    fun wait_for_checkpoint_maintenance_turn_locked id =
      case !checkpoint_maintenance_owner of
          SOME owner =>
            if owner = id then ()
            else
              (ConditionVar.wait (cv, mutex);
               wait_for_checkpoint_maintenance_turn_locked id)
        | NONE => raise Error "checkpoint maintenance owner disappeared"

    fun begin_checkpoint_maintenance id =
      with_lock
        (fn () =>
            let
              val _ = enqueue_checkpoint_maintenance_locked id
              val _ = wait_for_checkpoint_maintenance_turn_locked id
            in
              (* The completing node is still active here.  So are workers that
                 completed during an earlier pass and are waiting their turn. *)
              protected_bases_for_ids (active_node_ids_snapshot_locked ())
            end)

    fun advance_checkpoint_maintenance_locked id =
      case !checkpoint_maintenance_owner of
          SOME owner =>
            if owner <> id then raise Error "checkpoint maintenance owner mismatch"
            else
              (case !checkpoint_maintenance_queue of
                   [] => checkpoint_maintenance_owner := NONE
                 | next :: rest =>
                     (checkpoint_maintenance_owner := SOME next;
                      checkpoint_maintenance_queue := rest))
        | NONE => raise Error "checkpoint maintenance finished without an owner"

    fun finish_checkpoint_maintenance id =
      with_lock
        (fn () =>
            (finish_success_transition_locked id;
             advance_checkpoint_maintenance_locked id;
             signal ()))

    fun finish_inspected id =
      let
        val _ = mark_checkpoint_budget_refresh_needed budget_state
        val first_stop =
          with_lock
            (fn () =>
                let
                  val _ = running := !running - 1
                  val _ = clear_active_node id
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
      with_lock (fn () => (running := !running - 1; clear_active_node id; finish_priority id; signal ()))

    fun finish_failure id msg artifacts =
      let
        val first_failure =
          with_lock
            (fn () =>
                let
                  val _ = running := !running - 1
                  val _ = clear_active_node id
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
                          let
                            val collect_protected =
                              checkpoints_possible andalso
                              outcome_may_create_checkpoints options project node outcome
                          in
                            if collect_protected then
                              let
                                val protected = begin_checkpoint_maintenance id
                                val _ = refresh_checkpoint_budget_after_node budget_state project node protected
                              in
                                finish_checkpoint_maintenance id
                              end
                            else finish_success id
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
                         (HolbuildStatus.fail_with_debug_artifacts
                           status (HolbuildBuildPlan.key node) (HolbuildBuildPlan.logical_name node)
                           msg artifacts
                          handle IO.Io _ => ());
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

fun dump_key_label key =
  String.translate (fn #"\000" => "\\0" | c => str c) key

fun dump_key_row toolchain_key plan keys node =
  let
    val key = HolbuildBuildPlan.key node
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val dependency_key =
      case #kind (HolbuildBuildPlan.source_of node) of
          HolbuildSourceIndex.TheoryScript =>
            SOME (dependency_input_context_key toolchain_key plan keys node)
        | _ => NONE
    val line =
      case dependency_key of
          SOME deps_key => String.concat [dump_key_label key, "\t", input_key, "\t", deps_key]
        | NONE => String.concat [dump_key_label key, "\t", input_key]
  in
    (key, line)
  end

fun compare_dump_rows ((left, _), (right, _)) = String.compare(left, right)

(* Key dumps are normally a faithful view of the build's cache keys.  Tests may
   supply a fixed toolchain identity: real toolchain keys hash platform-built
   HOL binaries, so using them in a checked-in golden fixture would make that
   fixture host-specific.  The fixed identity stands for both the theory
   toolchain key and the exact toolchain key.  This affects only the
   diagnostic dump; execution and cache lookup continue to use the real keys. *)
fun dump_toolchain_key () =
  case OS.Process.getEnv "HOLBUILD_DUMP_KEYS_TOOLCHAIN_KEY" of
      SOME key => if key = "" then NONE else SOME key
    | NONE => NONE

fun dump_keys_if_requested config_lines_for_node toolchain_key plan keys =
  case OS.Process.getEnv "HOLBUILD_DUMP_KEYS" of
      NONE => ()
    | SOME path =>
        let
          val (dump_toolchain, dump_keys) =
            case dump_toolchain_key () of
                NONE => (toolchain_key, keys)
              | SOME key => (key, HolbuildBuildPlan.input_keys config_lines_for_node key plan)
          val rows =
            HolbuildBuildPlan.sort_pairs compare_dump_rows
              (map (dump_key_row dump_toolchain plan dump_keys)
                   (HolbuildBuildPlan.selected_nodes plan))
          val text = String.concat (map (fn (_, line) => line ^ "\n") rows)
        in
          write_text_atomic path text
        end

(* A node whose metadata already records its input key is most likely up to
   date, so fetching its entry would only download what the build won't use. *)
fun prefetch_key (options : build_options) project keys node =
  let val input_key = HolbuildBuildPlan.input_key_for keys node
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.TheoryScript =>
          if cache_enabled node andalso not (force_node options project node) andalso
             not (case current_metadata (metadata_path project node) of
                      SOME text => metadata_input_key_matches input_key text
                    | NONE => false) then
            SOME input_key
          else NONE
      | _ => NONE
  end

(* Runs `work` on each item added, on up to `limit` background threads, in
   the order added; an item added while fewer than `limit` run starts at
   once.  Returns {add, stop}: stop drops the items not yet started and
   waits for those in flight.  Failures are silent: for a prefetch, the
   demand restore of the same key retries and reports. *)
fun start_background_pool limit work =
  let
    val front = ref [] and back = ref []
    val active = ref 0
    val stopped = ref false
    val mutex = Mutex.mutex ()
    fun with_lock f =
      (Mutex.lock mutex; f () before Mutex.unlock mutex)
      handle e => (Mutex.unlock mutex; raise e)
    fun pop () =
      case !front of
          item :: rest => (front := rest; SOME item)
        | [] =>
            case rev (!back) of
                [] => NONE
              | item :: rest => (front := rest; back := []; SOME item)
    (* A thread ends only once nothing is queued, under the lock add takes,
       so no added item is left behind. *)
    fun worker item =
      ((work item handle _ => ());
       case with_lock (fn () => case pop () of
                                    NONE => (active := !active - 1; NONE)
                                  | next => next) of
           SOME next => worker next
         | NONE => ())
    fun add item =
      if with_lock (fn () =>
           if !stopped then false
           else if !active < limit then (active := !active + 1; true)
           else (back := item :: !back; false))
      then ignore (Thread.fork (fn () => worker item, []))
           handle e => (with_lock (fn () => active := !active - 1); raise e)
      else ()
    fun wait () =
      if with_lock (fn () => !active) > 0 then (OS.Process.sleep (Time.fromReal 0.05); wait ())
      else ()
    fun stop () = (with_lock (fn () => (stopped := true; front := []; back := [])); wait ())
  in
    {add = add, stop = stop}
  end

fun prefetch_limit jobs =
  Option.getOpt (!HolbuildRemoteCacheConfig.prefetch_concurrency, Int.max (50, 2 * jobs))

(* Starts --prefetch-concurrency (default max(50, 2 * jobs)) background
   threads that hydrate the plan's remote theory cache entries into the local
   cache, in build order, while the build runs; returns a function that drops
   the nodes not yet started and waits for the copies in flight.  The build
   workers keep their own demand restore, so they never wait behind a
   prefetch. *)
fun start_remote_cache_prefetch (options : build_options) project plan keys jobs =
  case HolbuildRemoteCacheConfig.url () of
      SOME url =>
        if not (#use_cache options) then (fn () => ())
        else
          let
            val root = cache_root ()
            val nodes = HolbuildBuildPlan.selected_nodes plan
            fun prefetch node =
              case prefetch_key options project keys node of
                  SOME key => prefetch_remote_cache_key root url key
                | NONE => ()
            val limit = prefetch_limit jobs
            val _ = cache_trace ("remote cache prefetch threads: " ^ Int.toString (Int.min (limit, length nodes)))
            val {add, stop} = start_background_pool limit prefetch
          in
            List.app add nodes;
            stop
          end
    | NONE => (fn () => ())

(* For build --remote-exec while it follows its batch: starts copying into
   the local cache the remote entries of the plan's theories outside the
   batch, given its keys (SOME batch_keys), which the remote cache already
   holds, as start_remote_cache_prefetch does.  Returns {add, stop}: add
   copies the entry of one more key, as the batch finishes its action; stop
   drops the copies not yet started, which the build's own prefetch makes,
   and waits for those in flight. *)
fun start_remote_exec_prefetch (options : build_options) tc project plan toolchain_key jobs batch_keys =
  case HolbuildRemoteCacheConfig.url () of
      SOME url =>
        if not (#use_cache options) then {add = fn _ => (), stop = fn () => ()}
        else
          let
            val root = cache_root ()
            val pool as {add, ...} = start_background_pool (prefetch_limit jobs) (prefetch_remote_cache_key root url)
            fun seed batch_keys =
              let
                val keys = HolbuildBuildPlan.input_keys (build_config_lines_for_node options project)
                             (HolbuildToolchain.action_toolchain_key tc (fn _ => toolchain_key)) plan
                val in_batch = Redblackset.addList (Redblackset.empty String.compare, batch_keys)
              in
                List.app (fn node =>
                             case prefetch_key options project keys node of
                                 SOME key => if Redblackset.member (in_batch, key) then () else add key
                               | NONE => ())
                         (HolbuildBuildPlan.selected_nodes plan)
              end
          in
            Option.app seed batch_keys;
            pool
          end
    | NONE => {add = fn _ => (), stop = fn () => ()}

(* Linux PSI: total microseconds runnable tasks, machine-wide, waited for a CPU.
   NONE where /proc/pressure/cpu doesn't exist (e.g. macOS). *)
fun cpu_pressure_total_us () =
  let
    val input = TextIO.openIn "/proc/pressure/cpu"
    val line = Option.getOpt (TextIO.inputLine input, "") before TextIO.closeIn input
  in
    Option.mapPartial (fn field => LargeInt.fromString (String.extract (field, size "total=", NONE)))
      (List.find (String.isPrefix "total=") (String.tokens Char.isSpace line))
  end
  handle IO.Io _ => NONE

fun trace_cpu_pressure_delta start =
  case (start, cpu_pressure_total_us ()) of
      (SOME before_us, SOME after_us) =>
        cache_trace ("system cpu pressure some delta: " ^ LargeInt.toString (after_us - before_us) ^ "us")
    | _ => ()

fun build (options : build_options) tc project plan toolchain_key jobs =
  let
    val cpu_pressure_start =
      if HolbuildStatus.cache_trace_enabled () then cpu_pressure_total_us () else NONE
    val budget_state = create_checkpoint_budget_state project
    val _ = register_checkpoint_budget_bases budget_state
              (map (checkpoint_base project) (HolbuildBuildPlan.selected_nodes plan))
    val _ = enforce_checkpoint_budget_state_excluding budget_state []
    val base_context = toolchain_base_context tc
    val keys = HolbuildBuildPlan.input_keys (build_config_lines_for_node options project)
                 (HolbuildToolchain.action_toolchain_key tc (fn _ => toolchain_key)) plan
    val _ = dump_keys_if_requested (build_config_lines_for_node options project) toolchain_key plan keys
    val dat_hash_cache = new_file_hash_cache ()
    val _ = HolbuildBuildPlan.forget_output_digests plan
  in
    let
      val status = HolbuildStatus.create {total = length (HolbuildBuildPlan.selected_nodes plan), jobs = jobs}
      fun run () =
        let
          val stop_prefetch = start_remote_cache_prefetch options project plan keys jobs
          fun build_nodes () =
            if jobs <= 1 then build_serial dat_hash_cache status options tc project base_context plan keys toolchain_key budget_state
            else build_parallel dat_hash_cache status options tc project base_context plan keys toolchain_key jobs budget_state
        in
          (build_nodes (); stop_prefetch ())
          handle e => (stop_prefetch (); raise e)
        end
    in
      (run (); HolbuildStatus.finish status;
       trace_cpu_pressure_delta cpu_pressure_start;
       finalize_checkpoint_budget_state_excluding
         budget_state (!(#refreshed budget_state)) [];
       clear_checkpoint_index_dirty budget_state)
      handle e => (HolbuildStatus.finish status;
                   trace_cpu_pressure_delta cpu_pressure_start;
                   finalize_checkpoint_budget_state_excluding budget_state true [];
                   clear_checkpoint_index_dirty budget_state;
                   raise e)
    end
  end

(* ActionSpecs: a theory action serialized for a remote worker, and the batch
   of uncached actions a coordinator schedules.  Everything a spec names is
   relative to an action root or the theory's stage root, never to this
   machine.  The README describes the formats. *)

val action_spec_header = "holbuild-action-spec-v1"
val action_batch_header = "holbuild-action-batch-v1"

(* The holbuild sources a theory child loads, directly or through the HOL
   analyser that instruments its script.  They end up in saved heaps, so a
   worker runs only specs exported by holbuild with the same sources. *)
val runtime_source_files =
  ["sml/checkpoint_save_runtime.sml", "sml/holbuild_runtime.sml",
   "sml/proof_runtime.sml", "sml/tactic_compat_runtime.sml"] @
  map (fn file => normalize_path (Path.concat("sml/analyser", file)))
      HolbuildHolSharedCache.analyser_source_files

fun runtime_identity () =
  let
    fun line rel =
      rel ^ " " ^ HolbuildHash.file_sha256 (Path.concat(HolbuildRuntimePaths.source_root, rel))
  in
    HolbuildToolchain.hash_text
      (String.concatWith "\n"
         ("holbuild-runtime-v1" :: map line (sort_strings (unique_strings runtime_source_files))) ^ "\n")
  end

fun spec_token context text =
  if text <> "" andalso not (CharVector.exists (fn c => Char.isSpace c orelse Char.isCntrl c) text)
  then text
  else raise Error ("action-spec: " ^ context ^ " can't run remotely: " ^
                    HolbuildHash.quote text ^ " is empty or contains whitespace")

fun is_theory_node node = #kind (HolbuildBuildPlan.source_of node) = HolbuildSourceIndex.TheoryScript

fun escapes_root rel = Path.isAbsolute rel orelse rel = ".." orelse String.isPrefix "../" rel

(* A HOL theory or library the preload names by a path on this machine
   rather than by name; a worker has no such file. *)
fun hol_load_by_path (LoadTheory name) = CharVector.exists (fn c => c = #"/") name
  | hol_load_by_path (LoadLibrary name) = CharVector.exists (fn c => c = #"/") name
  | hol_load_by_path (LoadObject _) = false

(* Why a theory can't run remotely, if it can't. *)
fun excluded_reason (options : build_options) project (action : theory_action) node =
  if always_reexecute node then SOME "it sets always_reexecute"
  else if not (cache_enabled node) then SOME "it sets cache = false"
  else if force_node options project node then SOME "it is forced"
  else if escapes_root (HolbuildBuildPlan.relative_path node) then
    SOME "its script lies outside its package root"
  else
    case List.find (fn {path, ...} => escapes_root path) (#inputs action) of
        SOME {path, ...} => SOME ("its extra input " ^ path ^ " lies outside its package root")
      | NONE =>
          case List.find hol_load_by_path (#loads action) of
              SOME (LoadTheory name) => SOME ("it loads " ^ name ^ " by path")
            | SOME (LoadLibrary name) => SOME ("it loads " ^ name ^ " by path")
            | _ => NONE

(* Whether the remote cache holds an entry this build would restore: usable,
   and with a timeout contract at least as strict as the one requested,
   whose blobs the cache still holds. *)
fun remote_entry_satisfies remote (options : build_options) project plan node input_key =
  case HolbuildRemoteCache.get_action remote input_key of
      NONE => false
    | SOME text =>
        (let
           val lines = cache_manifest_lines text
           val {extra_hashes, ...} = cache_manifest_blobs_from_lines input_key lines
           val requested = tactic_timeout (checkpoint_policy_for_node options project node)
         in
           not (Option.isSome (transient_stage_mldep_in_manifest text)) andalso
           map #1 extra_hashes = source_extra_output_declarations plan node andalso
           cache_timeout_satisfies (#allow_cache_timeout_discrepancy options) requested
             (cache_manifest_proof_timeout lines) andalso
           List.all (HolbuildRemoteCache.blob_present remote) (HolbuildCacheTransfer.unique_blobs text)
         end
         handle _ => false)

(* Where a worker places a library's source, relative to its action root. *)
fun library_source_path node =
  normalize_path (String.concatWith "/"
    [".holbuild/action-src", package node, HolbuildBuildPlan.relative_path node])

fun library_manifest root plan node =
  let
    val context = package node ^ ":" ^ logical_name node
    fun name text =
      if CharVector.exists (fn c => c = #"/") text then
        raise Error ("action-spec: " ^ context ^ " can't run remotely: it loads " ^ text ^ " by path")
      else spec_token context text
    fun rooted path = spec_token context (root_relative root path)
    val deps = HolbuildBuildPlan.direct_project_deps plan node
    val loads =
      map name (direct_external_loads plan node) @
      map rooted (project_load_stems deps) @
      [spec_token context (library_source_path node)]
    fun line suffix loads =
      String.concatWith " "
        (["lib", context, rooted (drop_suffix suffix (one_with_suffix suffix (#objects (source_artifacts node)))),
          suffix] @ loads)
  in
    case #kind (HolbuildBuildPlan.source_of node) of
        HolbuildSourceIndex.Sig => [line ".ui" loads]
      | HolbuildSourceIndex.Sml =>
          line ".uo" loads ::
          (if has_signature_companion plan node then [] else [line ".ui" []])
      | HolbuildSourceIndex.TheoryScript => []
  end

fun file_line role path from =
  String.concatWith " "
    ["file", role, path, HolbuildHash.file_sha256 from, Position.toString (FS.fileSize from)]

fun theory_load_spec_line token (LoadTheory name) = "load theory " ^ token name
  | theory_load_spec_line token (LoadLibrary name) = "load library " ^ token name
  | theory_load_spec_line token (LoadObject stem) = "load object " ^ token stem

fun bool_option name value = "option " ^ name ^ "=" ^ bool_text value

(* The spec text and the files a worker fetches by content hash for it. *)
fun action_spec_text {root, plan, keys, action_toolchain_key, runtime, toolchain_line} policy
                     (action : theory_action) node action_text =
  let
    val context = #package action ^ ":" ^ #logical action
    val token = spec_token context
    val deps = HolbuildBuildPlan.transitive_project_deps plan node
    val theory_deps = List.filter is_theory_node deps
    val libraries = List.filter (not o is_theory_node) deps
    val source = #source_file action
    val {sig_path, sml_path, data_path} = #outputs action
    val input_lines =
      map (fn {path, from} => file_line "input" (token path) from) (#inputs action)
    (* A library's key comes from its planned source hash, which the action
       text doesn't carry, so the file shipped must be the one planned. *)
    fun library_line lib =
      let val line = file_line "library" (token (library_source_path lib)) (source_file lib)
      in
        if List.nth (String.tokens Char.isSpace line, 3) = HolbuildBuildPlan.source_hash plan lib then line
        else raise Error ("library changed since the build was planned: " ^ source_file lib)
      end
    val library_lines = map library_line libraries
    val dep_lines =
      map (fn dep => String.concatWith " "
             ["dep theory", token (package dep ^ ":" ^ logical_name dep),
              token (root_relative root (load_stem dep)), HolbuildBuildPlan.input_key_for keys dep])
          theory_deps
    val lines =
      [action_spec_header,
       "holbuild-version=" ^ HolbuildVersion.version,
       "holbuild-runtime=" ^ runtime,
       toolchain_line,
       "input-key=" ^ #input_key action,
       "action-text-sha256=" ^ HolbuildToolchain.hash_text action_text,
       "deps-key=" ^ dependency_input_context_key action_toolchain_key plan keys node,
       "target " ^ token context,
       String.concatWith " "
         ["source", token (#package action), token (#relative_path action),
          HolbuildHash.file_sha256 source, Position.toString (FS.fileSize source)]] @
      input_lines @
      library_lines @
      dep_lines @
      List.concat (map (library_manifest root plan) libraries) @
      map (theory_load_spec_line token) (#loads action) @
      ["output sig " ^ token sig_path,
       "output sml " ^ token sml_path,
       "output dat " ^ token data_path] @
      map (fn decl => "output extra " ^ token decl) (#extra_outputs action) @
      [bool_option "proof-steps" (proof_steps_enabled policy),
       "option tactic-timeout=" ^ timeout_text (tactic_timeout policy),
       bool_option "new-ir" (proof_ir_enabled policy),
       "action-text"]
  in
    {text = String.concatWith "\n" lines ^ "\n" ^ action_text,
     files = source :: map #from (#inputs action) @ map source_file libraries}
  end

(* A theory waits for the nearest uncached theories it depends on, looking
   through libraries and cached theories, which a worker restores but
   doesn't build. *)
fun uncached_parents plan uncached node =
  let
    fun walk (dep, (seen, parents)) =
      let val key = HolbuildBuildPlan.key dep
      in
        if List.exists (fn k => k = key) seen then (seen, parents)
        else if is_theory_node dep andalso uncached dep then (key :: seen, dep :: parents)
        else List.foldl walk (key :: seen, parents) (HolbuildBuildPlan.direct_project_deps plan dep)
      end
    val (_, parents) = List.foldl walk ([], []) (HolbuildBuildPlan.direct_project_deps plan node)
  in
    rev parents
  end

fun publish_spec_blob remote path =
  case HolbuildRemoteCache.publish_blob remote {hash = HolbuildHash.file_sha256 path, src = path} of
      HolbuildCacheBackend.Published => ()
    | HolbuildCacheBackend.AlreadyPresent => ()
    | HolbuildCacheBackend.Conflict message => raise Error ("could not upload " ^ path ^ ": " ^ message)
    | HolbuildCacheBackend.Skipped => raise Error ("could not upload " ^ path ^ ": skipped")

(* The input keys of the plan's theories whose input key is missing or that
   depend on that theory. *)
fun theory_keys_depending_on (options : build_options) tc project plan toolchain_key missing =
  let
    val keys = HolbuildBuildPlan.input_keys (build_config_lines_for_node options project)
                 (HolbuildToolchain.action_toolchain_key tc (fn _ => toolchain_key)) plan
    val key_of = HolbuildBuildPlan.input_key_for keys
    fun depends node =
      key_of node = missing orelse
      List.exists (fn dep => key_of dep = missing) (HolbuildBuildPlan.transitive_project_deps plan node)
  in
    map key_of (List.filter (fn node => is_theory_node node andalso depends node) (HolbuildBuildPlan.selected_nodes plan))
  end

(* Drops the local cache's entries for keys, so that a build restores them
   from the remote cache. *)
fun drop_local_cache_entries keys =
  let val root = cache_root ()
  in
    List.app (fn key => HolbuildCache.with_action_publish_lock_wait root key
                          (fn () => HolbuildCache.remove_action root key))
             keys
  end

(* Writes the ActionSpec of every theory in the plan the remote cache can't
   satisfy, or whose input key is in forced, uploads them and their sources
   with upload, and returns the batch. *)
fun export_action_specs (options : build_options) tc project plan toolchain_key upload forced =
  let
    val remote =
      case HolbuildRemoteCacheConfig.url () of
          SOME url => HolbuildRemoteCache.remote url
        | NONE => raise Error "action-spec needs a remote cache: pass --remote-cache URL"
    val _ =
      if #trknl options then
        raise Error "action-spec: tracing-kernel actions key on the exact HOL executable and stay local"
      else if not (#use_cache options) then
        raise Error "action-spec: a remote action's result is its cache entry, so --no-cache can't apply"
      else ()
    val root = project_artifact_root project
    val config_lines = build_config_lines_for_node options project
    val action_toolchain_key = HolbuildToolchain.action_toolchain_key tc (fn _ => toolchain_key)
    val keys = HolbuildBuildPlan.input_keys config_lines action_toolchain_key plan
    val theories = List.filter is_theory_node (HolbuildBuildPlan.selected_nodes plan)
    val actions =
      map (fn node => (node, theory_action root plan keys toolchain_key (#holdir tc)
                               (dependency_input_context_key toolchain_key plan keys node) node))
          theories
    val _ =
      List.app
        (fn (node, action) =>
            case excluded_reason options project action node of
                SOME reason =>
                  raise Error ("action-spec: " ^ package node ^ ":" ^ logical_name node ^
                               " can't run remotely: " ^ reason)
              | NONE => ())
        actions
    val uncached_actions =
      List.filter
        (fn (node, action) =>
            List.exists (fn key => key = #input_key action) forced orelse
            not (remote_entry_satisfies remote options project plan node (#input_key action)))
        actions
    val uncached_keys = map (HolbuildBuildPlan.key o #1) uncached_actions
    fun uncached node = List.exists (fn k => k = HolbuildBuildPlan.key node) uncached_keys
    val toolchain_line =
      case HolbuildProject.resolved_hol_dependency_with {kernel_variant = #kernel_variant tc} project of
          SOME (HolbuildProject.Dependency {source = HolbuildProject.GitSource {git, rev}, ...}) =>
            "toolchain git=" ^ spec_token "the HOL dependency" git ^ " rev=" ^ spec_token "the HOL dependency" rev ^
            " kernel=" ^ HolbuildToolchain.kernel_variant_name (#kernel_variant tc)
        | _ => raise Error "action-spec: the project has no git dependencies.hol"
    val spec_dir = Path.concat(root, ".holbuild/action-specs")
    val context = {root = root, plan = plan, keys = keys, action_toolchain_key = action_toolchain_key,
                   runtime = runtime_identity (), toolchain_line = toolchain_line}
    fun export (node, action) =
      let
        val action_text =
          HolbuildBuildPlan.action_text_with plan config_lines action_toolchain_key keys node
        val _ =
          if HolbuildToolchain.hash_text action_text = #input_key action then ()
          else raise Error ("internal error: action text of " ^ logical_name node ^ " does not hash to its input key")
        val {text, files} =
          action_spec_text context (checkpoint_policy_for_node options project node)
            action node action_text
        val spec_sha256 = HolbuildHash.string_sha256 text
        val path = Path.concat(spec_dir, spec_sha256)
        val _ = (ensure_dir spec_dir; write_text path text)
      in
        {files = files @ [path], lines = String.concatWith " "
          ["action", #input_key action, HolbuildRemoteCache.remote_action_key (#input_key action),
           spec_sha256, package node ^ ":" ^ logical_name node] ::
        map (fn parent => "edge " ^ #input_key action ^ " " ^ HolbuildBuildPlan.input_key_for keys parent)
            (uncached_parents plan uncached node)}
      end
    val exported = map export uncached_actions
    val action_lines = List.concat (map #lines exported)
    (* Specs share their library sources, so each file goes up once. *)
    val _ =
      if upload then List.app (publish_spec_blob remote) (unique_strings (List.concat (map #files exported)))
      else ()
  in
    String.concatWith "\n" (action_batch_header :: action_lines) ^ "\n"
  end

(* holbuild exec-action: a remote worker builds one ActionSpec in a fixed
   action root under the cache root, with only the remote cache as input, and
   reports the outcome as a result record.  See README, "Running one theory
   action as a remote worker". *)

val action_result_header = "holbuild-action-result-v1"

datatype action_failure =
    ProofFailure
  | TacticTimeoutFailure
  | MemoryFailure
  | InputMissing of string  (* "theory <input_key>" or "blob <sha256>" *)
  | PublishFailure
  | ToolchainFailure
  | DiskFailure
  | SpecRejected
  | InternalFailure

exception ActionFailed of action_failure * string

fun failure_name ProofFailure = "proof"
  | failure_name TacticTimeoutFailure = "tactic-timeout"
  | failure_name MemoryFailure = "memory"
  | failure_name (InputMissing _) = "input-missing"
  | failure_name PublishFailure = "publish"
  | failure_name ToolchainFailure = "toolchain"
  | failure_name DiskFailure = "disk"
  | failure_name SpecRejected = "spec-rejected"
  | failure_name InternalFailure = "internal"

(* 1 is final, 2 retries on more memory, 3 retries or resubmits, 4 rejects. *)
fun failure_exit_code ProofFailure = 1
  | failure_exit_code TacticTimeoutFailure = 1
  | failure_exit_code MemoryFailure = 2
  | failure_exit_code SpecRejected = 4
  | failure_exit_code _ = 3

fun reject_spec msg = raise ActionFailed (SpecRejected, msg)

type spec_file = {path : string, sha256 : string, size : string}

type action_spec =
  {version : string, runtime : string,
   toolchain : {git : string, rev : string, kernel : string},
   input_key : string, action_text_sha256 : string, deps_key : string,
   package : string, logical : string,
   source : spec_file,
   inputs : spec_file list, libraries : spec_file list,
   deps : {target : string, stem : string, key : string} list,
   libs : {target : string, stem : string, suffix : string, loads : string list} list,
   loads : theory_load list,
   outputs : {sig_path : string, sml_path : string, data_path : string},
   extra_outputs : string list,
   proof_steps : bool, tactic_timeout : real option, new_ir : bool,
   action_text : string}

fun split_spec_text text =
  let val marker = "\naction-text\n"
      val (head, rest) = Substring.position marker (Substring.full text)
  in
    if Substring.size rest = 0 then reject_spec "spec has no action-text section"
    else (Substring.string head, Substring.string (Substring.triml (size marker) rest))
  end

fun target_name text =
  case String.fields (fn c => c = #":") text of
      [package, logical] =>
        if package <> "" andalso logical <> "" then (package, logical)
        else reject_spec ("malformed target " ^ text)
    | _ => reject_spec ("malformed target " ^ text)

fun spec_bool name text =
  case text of "true" => true | "false" => false
     | _ => reject_spec ("option " ^ name ^ " is not a boolean: " ^ text)

fun parse_action_spec text : action_spec =
  let
    val (head, action_text) = split_spec_text text
    val lines = List.filter (fn line => line <> "") (String.fields (fn c => c = #"\n") head)
    val _ =
      case lines of
          first :: _ => if first = action_spec_header then ()
                        else reject_spec ("not an ActionSpec: " ^ HolbuildHash.quote first)
        | [] => reject_spec "empty spec"
    val values = ref ([] : (string * string) list)
    val toolchain = ref NONE
    val target = ref NONE
    val source = ref NONE
    val inputs = ref []
    val libraries = ref []
    val deps = ref []
    val libs = ref []
    val loads = ref []
    val outputs = ref ([] : (string * string) list)
    val extra_outputs = ref []
    fun push r x = r := x :: !r
    fun key_value text =
      case Substring.position "=" (Substring.full text) of
          (key, value) =>
            if Substring.size value = 0 then reject_spec ("malformed spec line: " ^ text)
            else (Substring.string key, Substring.string (Substring.triml 1 value))
    fun line text =
      case String.tokens (fn c => c = #" ") text of
          ["toolchain", git, rev, kernel] =>
            (case (key_value git, key_value rev, key_value kernel) of
                 (("git", g), ("rev", r), ("kernel", k)) => toolchain := SOME {git = g, rev = r, kernel = k}
               | _ => reject_spec ("malformed toolchain line: " ^ text))
        | ["target", t] => target := SOME t
        | ["source", package, path, sha256, size] =>
            source := SOME (package, {path = path, sha256 = sha256, size = size})
        | ["file", "input", path, sha256, size] => push inputs {path = path, sha256 = sha256, size = size}
        | ["file", "library", path, sha256, size] => push libraries {path = path, sha256 = sha256, size = size}
        | ["dep", "theory", t, stem, key] => push deps {target = t, stem = stem, key = key}
        | "lib" :: t :: stem :: suffix :: lib_loads =>
            push libs {target = t, stem = stem, suffix = suffix, loads = lib_loads}
        | ["load", "theory", name] => push loads (LoadTheory name)
        | ["load", "library", name] => push loads (LoadLibrary name)
        | ["load", "object", stem] => push loads (LoadObject stem)
        | ["output", "extra", decl] => push extra_outputs decl
        | ["output", role, path] => push outputs (role, path)
        | ["option", option] => push values (key_value ("option " ^ option))
        | [single] => push values (key_value single)
        | _ => reject_spec ("unknown spec line: " ^ text)
    val _ = List.app line (tl lines)
    fun value key =
      case List.find (fn (k, _) => k = key) (!values) of
          SOME (_, v) => v
        | NONE => reject_spec ("spec has no " ^ key)
    fun output role =
      case List.find (fn (r, _) => r = role) (!outputs) of
          SOME (_, path) => path
        | NONE => reject_spec ("spec has no output " ^ role)
    val (package, logical) =
      target_name (case !target of SOME t => t | NONE => reject_spec "spec has no target")
    val (source_package, source_file) =
      case !source of SOME s => s | NONE => reject_spec "spec has no source"
    val _ = if source_package = package then ()
            else reject_spec "the source's package is not the target's"
    val tactic_timeout =
      case parse_timeout_text (value "option tactic-timeout") of
          SOME timeout => timeout
        | NONE => reject_spec "malformed option tactic-timeout"
  in
    {version = value "holbuild-version", runtime = value "holbuild-runtime",
     toolchain = (case !toolchain of SOME t => t | NONE => reject_spec "spec has no toolchain"),
     input_key = value "input-key", action_text_sha256 = value "action-text-sha256",
     deps_key = value "deps-key", package = package, logical = logical,
     source = source_file, inputs = rev (!inputs), libraries = rev (!libraries),
     deps = rev (!deps), libs = rev (!libs), loads = rev (!loads),
     outputs = {sig_path = output "sig", sml_path = output "sml", data_path = output "dat"},
     extra_outputs = rev (!extra_outputs),
     proof_steps = spec_bool "proof-steps" (value "option proof-steps"),
     tactic_timeout = tactic_timeout,
     new_ir = spec_bool "new-ir" (value "option new-ir"),
     action_text = action_text}
  end

fun action_text_values (spec : action_spec) prefix =
  List.mapPartial
    (fn line => if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE)) else NONE)
    (String.fields (fn c => c = #"\n") (#action_text spec))

fun action_text_value spec key =
  case action_text_values spec (key ^ "=") of
      [value] => value
    | _ => reject_spec ("the action text has no single " ^ key ^ " line")

(* Step 1: the spec is for this holbuild, intact, and of an action a worker
   may run. *)
fun escapes path = Path.isAbsolute path orelse path = ".." orelse String.isPrefix "../" path orelse
                   String.isSubstring "/../" path

fun sha256_text text =
  size text = 64 andalso CharVector.all (fn c => Char.isDigit c orelse (c >= #"a" andalso c <= #"f")) text

fun verify_action_spec (spec : action_spec) =
  let
    val text_hash = HolbuildToolchain.hash_text (#action_text spec)
    fun check ok msg = if ok then () else reject_spec msg
    (* The extra inputs are the files the action text names with their
       hashes: a manifest input by its path in the package, a script's by its
       path from the script's directory. *)
    val script_dir = Path.dir (#path (#source spec))
    fun named prefix base =
      map (fn value =>
             case rev (String.fields (fn c => c = #"@") value) of
                 hash :: (rel as _ :: _) =>
                   let val rel = String.concatWith "@" (rev rel)
                   in (normalize_path (if base = "" then rel else Path.concat(base, rel)), hash) end
               | _ => reject_spec ("malformed action text line " ^ prefix ^ value))
          (action_text_values spec prefix)
    val text_inputs = named "extra_dep=" "" @ named "source_extra_dep=" script_dir
    val spec_inputs = map (fn {path, sha256, ...} => (normalize_path path, sha256)) (#inputs spec)
    fun contains xs x = List.exists (fn y => y = x) xs
    fun same_files (xs, ys) = List.all (contains ys) xs andalso List.all (contains xs) ys
    (* A direct project dependency is a theory with this key or a library;
       a HOL dependency has no key. *)
    fun direct_dep_ok dep_line =
      case String.fields (fn c => c = #"@") dep_line of
          [target, key] =>
            (case List.find (fn {target = t, ...} => t = target) (#deps spec) of
                 SOME {key = spec_key, ...} => spec_key = key
               | NONE => List.exists (fn {target = t, ...} => t = target) (#libs spec))
        | _ => true
  in
    check (#version spec = HolbuildVersion.version)
      ("spec is for holbuild " ^ #version spec ^ ", this is " ^ HolbuildVersion.version);
    check (#runtime spec = runtime_identity ()) "spec is for different holbuild runtime sources";
    check (#kernel (#toolchain spec) = "stdknl") "spec is for a tracing kernel";
    check (sha256_text (#deps_key spec)) "deps-key is not a SHA-256";
    check (List.all (sha256_text o #key) (#deps spec)) "a dependency's key is not a SHA-256";
    check (text_hash = #input_key spec) "the action text does not hash to input-key";
    check (#action_text_sha256 spec = text_hash) "action-text-sha256 does not match the action text";
    check (action_text_value spec "package" = #package spec) "the action text names another package";
    check (action_text_value spec "logical" = #logical spec) "the action text names another theory";
    check (action_text_value spec "source" = #path (#source spec)) "the action text names another source";
    check (action_text_value spec "source-sha256" = #sha256 (#source spec))
      "the source's SHA-256 does not match the action text";
    check (action_text_value spec "cache" = "true") "the action sets cache = false";
    check (action_text_value spec "always_reexecute" = "false") "the action sets always_reexecute";
    check (List.all direct_dep_ok (action_text_values spec "dep="))
      "a dependency's key does not match the action text";
    check (same_files (text_inputs, spec_inputs)) "the extra inputs do not match the action text";
    check (same_files (action_text_values spec "source_extra_output=", #extra_outputs spec))
      "the extra outputs do not match the action text";
    check (List.all (fn {suffix, ...} => suffix = ".ui" orelse suffix = ".uo") (#libs spec))
      "a library manifest is neither .ui nor .uo";
    List.app (fn path => check (not (escapes path)) ("path " ^ path ^ " leaves the action root"))
      (#package spec :: #logical spec :: map (#1 o target_name o #target) (#deps spec) @
       map (#1 o target_name o #target) (#libs spec) @
       #path (#source spec) :: map #path (#inputs spec @ #libraries spec) @
       map #stem (#deps spec) @ map #stem (#libs spec) @
       List.filter (CharVector.exists (fn c => c = #"/")) (List.concat (map #loads (#libs spec))) @
       [#sig_path (#outputs spec), #sml_path (#outputs spec), #data_path (#outputs spec)])
  end

(* The extra-inputs key the build plan records for checkpoint keys, from the
   extra-input lines of the action text, which name the same bytes. *)
fun spec_inputs_key (spec : action_spec) =
  let
    val lines =
      List.filter
        (fn line => List.exists (fn prefix => String.isPrefix prefix line)
                      ["extra_dep_decl=", "extra_dep=", "source_extra_dep_decl=", "source_extra_dep="])
        (String.fields (fn c => c = #"\n") (#action_text spec))
  in
    case lines of
        [] => NONE
      | _ => SOME (HolbuildToolchain.hash_text
                     (String.concatWith "\n" ("holbuild-extra-inputs-v1" :: lines) ^ "\n"))
  end

fun action_source_path package path =
  normalize_path (String.concatWith "/" [".holbuild/action-src", package, path])

fun spec_load_stems (spec : action_spec) =
  let
    fun add ((name, stem), acc) =
      if List.exists (fn (n, _) => n = name) acc then acc else acc @ [(name, stem)]
  in
    List.foldl add []
      (map (fn {target, stem, ...} => (#2 (target_name target), stem)) (#deps spec) @
       map (fn {target, stem, ...} => (#2 (target_name target), stem)) (#libs spec))
  end

fun spec_theory_action root (spec : action_spec) : theory_action =
  let
    val package = #package spec
    val path = #path (#source spec)
    val script_dir = case Path.dir path of "" => "" | dir => normalize_path dir
  in
    {input_key = #input_key spec,
     deps_key = #deps_key spec,
     inputs_key = spec_inputs_key spec,
     package = package,
     logical = #logical spec,
     relative_path = path,
     source_file = in_root root (action_source_path package path),
     source_name = "$(" ^ package ^ ")/" ^ path,
     script_dir = script_dir,
     inputs = map (fn {path, ...} => {path = path, from = in_root root (action_source_path package path)}) (#inputs spec),
     loads = #loads spec,
     outputs = #outputs spec,
     extra_outputs = #extra_outputs spec}
  end

fun spec_policy (spec : action_spec) =
  CheckpointPolicy {checkpoint = true,
                    proof_steps = #proof_steps spec,
                    new_ir = #new_ir spec,
                    tactic_timeout = effective_tactic_timeout (#proof_steps spec) (#tactic_timeout spec),
                    execution_plan = NONE,
                    trace_steps = false,
                    repl_on_failure = false,
                    trknl = false}

val no_space = HolbuildCacheTransfer.no_space
(* A failed child's log is no evidence of a full disk either way: it is on
   that filesystem, and a handled checkpoint write failure warns into it. *)
val out_of_space = HolbuildCacheTransfer.out_of_space

(* A full disk is a disk failure, whichever step hit it.  A failed download
   need not say so (curl reports only a failed write, or leaves a short
   file), so the cache root is probed too. *)
fun action_failed failure msg =
  ActionFailed (if String.isSubstring no_space msg orelse out_of_space (cache_root ()) then DiskFailure
                else failure, msg)

fun fetch_spec_blob remote {hash, dst} =
  (ensure_parent dst;
   case HolbuildRemoteCache.fetch_unlisted_blob remote {hash = hash, dst = dst} of
       HolbuildCacheBackend.Hit => ()
     | HolbuildCacheBackend.Miss => raise ActionFailed (InputMissing ("blob " ^ hash), "blob " ^ hash ^ " is not in the cache")
     | HolbuildCacheBackend.Corrupt msg => raise action_failed InternalFailure ("cannot fetch blob " ^ hash ^ ": " ^ msg))

(* Restores a theory the action depends on, or the action's own entry, into
   the action root, writing its load manifests with the spec's stems. *)
fun restore_spec_theory root (spec : action_spec) {key, subject, stem, extra_outputs, requested_timeout} =
  let
    val cache = cache_root ()
    val entry =
      checked_cache_entry false
        {root = cache, input_key = key, subject = subject,
         expected_extra_outputs = extra_outputs,
         requested_timeout = requested_timeout, require_trace = false}
    val stems = spec_load_stems spec
    fun resolve name = Option.map (fn (_, s) => in_root root s) (List.find (fn (n, _) => n = name) stems)
    val stem_path = in_root root stem
    val sig_path = stem_path ^ ".sig"
    val sml_path = stem_path ^ ".sml"
    fun write_manifests metadata =
      (write_object_manifest (stem_path ^ ".ui") [sig_path];
       write_object_manifest (stem_path ^ ".uo") (generated_theory_loads resolve metadata @ [sml_path]))
  in
    ignore
      (install_cache_entry false cache key subject entry
         {outputs = {sig_path = sig_path, sml_path = sml_path, data_path = stem_path ^ ".dat"},
          (* Apart from the sources, so a restored output never replaces an
             input the action fetched by its hash; the build reads none. *)
          extra_destination = fn decl =>
            if escapes decl then raise Error ("cache entry " ^ key ^ " has an extra output outside the action root: " ^ decl)
            else in_root root (normalize_path (String.concatWith "/" [".holbuild/action-extra", key, decl])),
          write_manifests = write_manifests})
  end

(* Each restored theory's .dat records the hashes of its parents' .dat
   files; every parent the spec places must match. *)
fun spec_parent_hashes_match root (spec : action_spec) data_path =
  let
    val recorded = parse_dat_parent_hashes (read_text data_path)
  in
    List.all
      (fn {target, stem, ...} =>
          case Binarymap.peek (recorded, theory_name_from_logical (#2 (target_name target))) of
              NONE => true
            | SOME hash => (hol_dat_hash (in_root root (stem ^ ".dat")) = hash handle _ => false))
      (#deps spec)
  end

(* Step 3: sources and library manifests from the spec, dependency theories
   from the cache. *)
fun hydrate_action_root remote root (spec : action_spec) =
  let
    val package = #package spec
    fun fetch_file {path, sha256, ...} =
      fetch_spec_blob remote {hash = sha256, dst = in_root root (action_source_path package path)}
    fun fetch_library {path, sha256, ...} =
      fetch_spec_blob remote {hash = sha256, dst = in_root root path}
    fun lib_load load = if CharVector.exists (fn c => c = #"/") load then in_root root load else load
    fun write_lib {stem, suffix, loads, ...} =
      (ensure_parent (in_root root stem);
       write_object_manifest (in_root root (stem ^ suffix)) (map lib_load loads))
    fun restore_dep {target, stem, key} =
      (ensure_parent (in_root root stem);
       restore_spec_theory root spec
         {key = key, subject = target, stem = stem, extra_outputs = NONE, requested_timeout = NONE})
      handle e => raise action_failed (InputMissing ("theory " ^ key))
                          ("dependency " ^ target ^ " (" ^ key ^ ") is not restorable from the cache: " ^
                           General.exnMessage e)
  in
    fetch_file (#source spec);
    List.app fetch_file (#inputs spec);
    List.app fetch_library (#libraries spec);
    List.app write_lib (#libs spec);
    List.app restore_dep (#deps spec);
    List.app
      (fn {target, stem, key} =>
          if spec_parent_hashes_match root spec (in_root root (stem ^ ".dat")) then ()
          else
            (* The worker's local copy may be one the remote has since
               replaced, so the next attempt restores the remote's. *)
            (Option.app (ignore o drop_cache_manifest_if_unchanged (cache_root ()) key)
               (HolbuildCache.get_action (cache_root ()) key);
             raise ActionFailed (InputMissing ("theory " ^ key),
                                 "dependency " ^ target ^ " does not match its parents in the cache")))
      (#deps spec)
  end

(* Step 4: the action's own entry restores with full validation. *)
fun action_already_done root (spec : action_spec) =
  let
    val {sig_path, sml_path, data_path} = #outputs spec
    val stem = drop_suffix ".dat" data_path
  in
    (restore_spec_theory root spec
       {key = #input_key spec, subject = #package spec ^ ":" ^ #logical spec, stem = stem,
        extra_outputs = SOME (#extra_outputs spec), requested_timeout = #tactic_timeout spec};
     spec_parent_hashes_match root spec (in_root root data_path))
    handle _ => false
  end

(* Whether the remote's entry for the action, given by its manifest, records
   parents other than the remote's own, as restored in the action root: no
   build that restores them can use it.  Each parent it records must have
   been restored from an entry with the remote's outputs, since one from the
   worker's local cache may be out of date. *)
fun resident_misfits_parents remote root (spec : action_spec) resident =
  let
    val {dat_hash, ...} = cache_manifest_blobs_from_lines (#input_key spec) (cache_manifest_lines resident)
    val path = in_root root ".holbuild/resident.dat"
    fun as_remote key =
      case (HolbuildCache.get_action (cache_root ()) key, HolbuildRemoteCache.get_action remote key) of
          (SOME mine, SOME theirs) => cache_manifest_outputs_equal key mine theirs
        | _ => false
  in
    ensure_parent path;
    case HolbuildRemoteCache.fetch_blob remote {hash = dat_hash, dst = path} of
        HolbuildCacheBackend.Hit =>
          let val recorded = parse_dat_parent_hashes (read_text path)
          in
            not (spec_parent_hashes_match root spec path) andalso
            List.all
              (fn {target, key, ...} =>
                  not (Option.isSome (Binarymap.peek (recorded, theory_name_from_logical (#2 (target_name target))))) orelse
                  as_remote key)
              (#deps spec)
          end
      | _ => false
  end
  handle _ => false

(* Uploads every blob of the local entry for the action, raising if one fails
   (the build's own publish only warns), then puts the action.  A different
   entry already there is replaced when it records parents other than the
   restored ones, and otherwise left for check_remote_publication to judge. *)
fun publish_action_entry remote root (spec : action_spec) =
  let
    val key = #input_key spec
    val local_cache = HolbuildFSCacheBackend.filesystem (cache_root ())
    val source = fs_cache_source local_cache
    val destination = remote_cache_destination remote
    val tmp_dir = HolbuildFSCacheBackend.tmp_dir local_cache
    val manifest =
      case #get_action source key of
          SOME text => text
        | NONE => raise ActionFailed (PublishFailure, "the build published no local cache entry")
  in
    ensure_dir tmp_dir;
    (List.app (fn hash => ignore (HolbuildCacheTransfer.copy_blob source destination tmp_dir hash (0, 0)))
       (HolbuildCacheTransfer.unique_blobs manifest)
     handle e => raise action_failed PublishFailure ("could not publish the entry: " ^ General.exnMessage e));
    case HolbuildRemoteCache.get_action remote key of
        SOME resident =>
          if not (cache_manifest_outputs_equal key resident manifest handle _ => false) andalso
             resident_misfits_parents remote root spec resident
          then
            (warn ("replacing remote cache entry " ^ key ^ ": its recorded parents differ from the cache's");
             ignore (HolbuildRemoteCache.replace_action_unconditionally remote {key = key, text = manifest}))
          else ()
      | NONE => ();
    ignore (#put_action destination HolbuildCacheBackend.PutIfAbsentOrSame {key = key, text = manifest})
  end

(* Step 6: publish the entry, then check that the remote holds an entry for
   the action with this build's outputs and a timeout contract at least as
   strict as the spec's. *)
fun check_remote_publication remote root (spec : action_spec) =
  let
    val key = #input_key spec
    val _ = publish_action_entry remote root spec
    val local_manifest = HolbuildCache.get_action (cache_root ()) key
    val remote_manifest = HolbuildRemoteCache.get_action remote key
    fun fail msg = raise ActionFailed (PublishFailure, msg)
  in
    case (local_manifest, remote_manifest) of
        (NONE, _) => fail "the build published no local cache entry"
      | (_, NONE) => fail "the remote cache holds no entry for the action after publishing"
      | (SOME mine, SOME theirs) =>
          if not (cache_manifest_outputs_equal key mine theirs) then
            fail "the remote cache holds different outputs for the action"
          else if not (timeout_satisfies (#tactic_timeout spec)
                         (cache_manifest_proof_timeout (cache_manifest_lines theirs))) then
            fail "the remote cache's entry has a weaker timeout contract than requested"
          else ()
  end

(* The OOM killer's count for this process's cgroup (v2), if readable. *)
fun cgroup_oom_kills () =
  let
    val cgroup_line =
      List.find (String.isPrefix "0::") (String.fields (fn c => c = #"\n") (read_text "/proc/self/cgroup"))
    val path =
      case cgroup_line of
          SOME line => "/sys/fs/cgroup" ^ String.extract(line, 3, NONE) ^ "/memory.events"
        | NONE => raise Fail "no cgroup v2"
    fun count line =
      case String.tokens Char.isSpace line of
          ["oom_kill", n] => Int.fromString n
        | _ => NONE
  in
    List.mapPartial count (String.fields (fn c => c = #"\n") (read_text path))
  end
  handle _ => []

fun peak_rss_mb stage =
  case String.tokens Char.isSpace (read_text (Path.concat(stage, peak_rss_report_name))) of
      ["VmHWM:", kb, "kB"] => Option.map (fn n => n div 1024) (Int.fromString kb)
    | _ => NONE
  handle _ => NONE

(* The child's own report of a full disk; a checkpoint write that failed
   only warned, and the run went on. *)
fun child_reports_no_space log_text =
  List.exists
    (fn line => String.isSubstring no_space line andalso
                not (String.isPrefix "holbuild: warning: dropping checkpoint" line))
    (String.fields (fn c => c = #"\n") log_text)

(* The shell running the child reports its death by signal n as 128 + n. *)
fun death_signal status =
  case Posix.Process.fromStatus status of
      Posix.Process.W_SIGNALED s => SOME s
    | Posix.Process.W_EXITSTATUS w =>
        if w > 0w128 then SOME (Posix.Signal.fromWord (SysWord.fromInt (Word8.toInt w - 128))) else NONE
    | _ => NONE

fun classify_run_failure stage log_text oom_before msg =
  let
    val (child_failed, signal) =
      case !last_child_status of
          SOME status => (not (OS.Process.isSuccess status), death_signal status)
        | NONE => (false, NONE)
    val oom_killed =
      signal = SOME Posix.Signal.kill andalso
      (case (oom_before, cgroup_oom_kills ()) of
           ([earlier], [later]) => later > earlier
         | _ => false)
  in
    if oom_killed orelse String.isSubstring "Run out of store" (msg ^ "\n" ^ log_text) then MemoryFailure
    else if (if child_failed then child_reports_no_space log_text orelse out_of_space stage
             else String.isSubstring no_space msg) then DiskFailure
    else if not child_failed then InternalFailure
    else if String.isPrefix "tactic timed out" msg then TacticTimeoutFailure
    else if Option.isSome signal then InternalFailure
    else ProofFailure
  end

(* The worker cache cap: one LRU over everything a worker keeps between
   actions (its checkpoint tree, the toolchains with their analysers, and the
   local cache), swept before each action.  It extends the checkpoint budget
   sweep's family eviction to the whole cache root: a family goes whole, and a
   toolchain another process is using is pinned. *)
(* A family's eviction returns the bytes it freed, or NONE if it was kept. *)
type cache_family = {mtime : Time.time, evict : unit -> Position.int option}

fun tree_bytes path =
  if (FS.isLink path handle OS.SysErr _ => false) then 0
  else if (FS.isDir path handle OS.SysErr _ => false) then
    List.foldl (fn (child, total) => total + tree_bytes child) (0 : Position.int) (children path)
  else file_size path

fun modified_time path = FS.modTime path handle OS.SysErr _ => Time.zeroTime

fun checkpoint_cache_families checkpoint_root =
  List.map
    (fn ({base, mtime, bytes} : checkpoint_family) =>
        {mtime = mtime,
         evict = fn () => (remove_checkpoint_family_base base;
                           if checkpoint_family_root_exists base then NONE else SOME bytes)})
    (collect_checkpoint_families checkpoint_root)

fun toolchain_cache_families () =
  let
    (* Any cutoff after now makes every entry stale, so gc_entry removes it
       unless a process holds its usage lease. *)
    val cutoff = Time.+(Time.now (), Time.fromSeconds 86400)
    fun family k =
      {mtime = Option.getOpt (HolbuildHolSharedCache.last_use_time k, Time.zeroTime),
       evict = fn () =>
         let val bytes = tree_bytes (HolbuildHolSharedCache.entry_dir_for_key k)
         in
           if HolbuildHolSharedCache.gc_entry cutoff k = HolbuildHolSharedCache.GcRemoved then SOME bytes
           else NONE
         end
         handle e => (warn ("could not evict HOL toolchain " ^ k ^ ": " ^ General.exnMessage e); NONE)}
  in
    List.map family (HolbuildHolSharedCache.toolchain_keys ())
  end

(* Local cache entries, and a family of the blobs no entry names.  Evicting an
   entry removes the blobs no remaining entry names, whatever order the
   entries go in. *)
fun local_cache_families cache =
  let
    val blobs_dir = HolbuildCache.blobs_dir cache
    val entries =
      List.map (fn dir => (dir, HolbuildCache.action_live_blobs dir))
               (HolbuildCache.children (HolbuildCache.actions_dir cache))
    fun count_blob (blob, users) =
      Redblackmap.insert (users, blob, 1 + Option.getOpt (Redblackmap.peek (users, blob), 0))
    val users = ref (List.foldl (fn ((_, blobs), users) => Redblackset.foldl count_blob users blobs)
                                (Redblackmap.mkDict String.compare) entries)
    fun remove_paths paths =
      List.foldl
        (fn (path, freed) =>
            let val bytes = tree_bytes path
            in HolbuildCache.remove_tree path; if path_exists path then freed else freed + bytes end)
        (0 : Position.int) paths
    fun release blob =
      case Redblackmap.peek (!users, blob) of
          SOME 1 => (users := #1 (Redblackmap.remove (!users, blob)); [Path.concat(blobs_dir, blob)])
        | SOME n => (users := Redblackmap.insert (!users, blob, n - 1); [])
        | NONE => []
    fun entry_family (dir, blobs) =
      {mtime = modified_time (HolbuildCache.manifest_path dir),
       evict = fn () =>
         let val freed = remove_paths [dir]
         in
           if path_exists dir then NONE
           else SOME (freed + remove_paths (List.concat (map release (Redblackset.listItems blobs))))
         end}
    val orphans =
      List.filter (fn path => not (Option.isSome (Redblackmap.peek (!users, Path.file path))))
                  (HolbuildCache.children blobs_dir)
  in
    {mtime = Time.zeroTime, evict = fn () => SOME (remove_paths orphans)} ::
    List.map entry_family entries
  end

(* The shared heap and checkpoint store: one family per heap directory,
   used when an action restores from it or adds to it. *)
fun share_store cache = Path.concat(cache, "checkpoint-store")

(* An action holds a shared lease on each store family it uses until it
   exits, so no other container's cap sweep evicts the family meanwhile.
   fcntl locks are dropped when the process closes any descriptor for the
   file, so a family is leased at most once per process, as toolchains are. *)
fun store_lease_path dir = dir ^ ".lease"

val store_leases = ref ([] : (string * HolbuildFileLock.t) list)

fun holds_store_lease path = List.exists (fn (held, _) => held = path) (!store_leases)

fun lease_store_family store heap =
  let val path = store_lease_path (Path.concat(store, heap))
  in
    if holds_store_lease path then ()
    else store_leases := (path, HolbuildFileLock.acquire_shared_path_wait {path = path}) :: !store_leases
  end

fun store_cache_families cache =
  List.map
    (fn dir =>
        {mtime = modified_time dir,
         evict = fn () =>
           let val lease = store_lease_path dir
           in
             if holds_store_lease lease then NONE
             else
               case HolbuildFileLock.try_acquire_path {path = lease, obsolete_kind = NONE}
                    handle HolbuildFileLock.Error _ => NONE of
                   NONE => NONE
                 | SOME lock =>
                     let val bytes = tree_bytes dir
                     in
                       (HolbuildCache.remove_tree dir handle e => (HolbuildFileLock.release lock; raise e));
                       HolbuildFileLock.release lock;
                       if path_exists dir then NONE else SOME bytes
                     end
           end})
    (List.filter (fn path => FS.isDir path handle OS.SysErr _ => false)
                 (HolbuildCache.children (share_store cache)))

(* Factory modules have no on-disk module parents.  Once loaded their code
   is resident, so concurrent eviction only makes a later load use source. *)
fun module_cache_families cache =
  List.map
    (fn path =>
       {mtime = modified_time path,
        evict = fn () =>
          let val bytes = tree_bytes path
          in
            HolbuildCache.remove_tree path;
            if path_exists path then NONE else SOME bytes
          end})
    (HolbuildCache.children (HolbuildCache.theory_modules_dir cache))

(* A toolchain retired but not yet removed when its remover stopped. *)
fun toolchain_trash_family () =
  {mtime = Time.zeroTime,
   evict = fn () =>
     SOME (List.foldl
             (fn (path, freed) =>
                 let val bytes = tree_bytes path
                 in
                   HolbuildHolSharedCache.remove_unlocked_tree path;
                   if path_exists path then freed else freed + bytes
                 end)
             (0 : Position.int) (HolbuildHolSharedCache.toolchain_trash ()))}

fun worker_cache_bytes {cache, checkpoint_root} =
  total_checkpoint_bytes (collect_checkpoint_families checkpoint_root) +
  tree_bytes (share_store cache) +
  tree_bytes (HolbuildCache.theory_modules_dir cache) +
  List.foldl (fn (path, total) => total + tree_bytes path)
             (0 : Position.int) (HolbuildHolSharedCache.toolchain_trash ()) +
  List.foldl (fn (k, total) => total + tree_bytes (HolbuildHolSharedCache.entry_dir_for_key k))
             (0 : Position.int) (HolbuildHolSharedCache.toolchain_keys ()) +
  tree_bytes (HolbuildCache.actions_dir cache) + tree_bytes (HolbuildCache.blobs_dir cache)

(* Evict least recently used families until the cache leaves reserve_bytes of
   room under limit_bytes. *)
fun enforce_worker_cache_cap {cache, checkpoint_root, limit_bytes, reserve_bytes} =
  let
    val families =
      sort_by_mtime_ascending (fn ({mtime, ...} : cache_family) => mtime)
        (toolchain_trash_family () :: checkpoint_cache_families checkpoint_root @
         store_cache_families cache @ module_cache_families cache @
         toolchain_cache_families () @ local_cache_families cache)
    val target = limit_bytes - reserve_bytes
    fun sweep total remaining =
      if total <= target then total
      else
        case remaining of
            [] => total
          | ({evict, ...} : cache_family) :: rest =>
              let
                val freed =
                  evict () handle e => (warn ("worker cache eviction failed: " ^ General.exnMessage e); NONE)
              in
                sweep (total - Option.getOpt (freed, 0)) rest
              end
    val after = sweep (worker_cache_bytes {cache = cache, checkpoint_root = checkpoint_root}) families
  in
    if after <= target then ()
    else warn ("worker cache holds " ^ gb_decimal_text after ^ " GB of entries in use, over the " ^
               gb_decimal_text target ^ " GB left under the cap after its reserve")
  end
  handle e => warn ("worker cache sweep failed: " ^ General.exnMessage e)

fun with_action_root_lock cache f =
  let
    val _ = ensure_dir cache
    val lock = HolbuildFileLock.acquire_exclusive_path_wait {path = Path.concat(cache, "action.lock")}
  in
    (f () before HolbuildFileLock.release lock)
    handle e => (HolbuildFileLock.release lock; raise e)
  end

fun result_text (spec_sha256, input_key) {status, failure, wall_ms, peak, log} =
  String.concatWith "\n"
    ([action_result_header,
      "spec=" ^ spec_sha256,
      "input-key=" ^ input_key,
      "status=" ^ status] @
     (case failure of
          NONE => []
        | SOME (kind, _) =>
            ("failure=" ^ failure_name kind) ::
            (case kind of InputMissing missing => ["missing=" ^ missing] | _ => [])) @
     (case peak of SOME mb => ["peak-rss-mb=" ^ Int.toString mb] | NONE => []) @
     ["wall-ms=" ^ LargeInt.toString wall_ms] @
     (case log of SOME (sha, bytes) => ["log=" ^ sha ^ " " ^ bytes] | NONE => [])) ^ "\n"

fun exception_failure e =
  let val msg = General.exnMessage e
  in
    if String.isSubstring "No space left on device" msg then (DiskFailure, msg)
    else (InternalFailure, msg)
  end

(* Shared heaps and checkpoints (exec-action --share-heaps).

   A run's checkpoints are Poly/ML child states that name their parents by
   absolute path: each context checkpoint is a child of the one before it,
   back to the deps-loaded heap, whose parent is the toolchain's hol.state.
   A published checkpoint's manifest lists that chain by SHA-256: the heap,
   the spine between the heap and the checkpoint, and each checkpoint's
   records (.ok, with .meta and .prefix for a failed prefix), so a worker
   with the same cache root restores exactly those bytes at the same paths.

   The host store, CACHE/checkpoint-store/<heap>/<sha256>, keeps the files of
   each published heap and the checkpoints built on it, one directory per
   heap, and never writes one in place.  The action's checkpoint tree is its
   own: emptied before and after the action and filled from the store, its
   Poly/ML states by hard links where both are on one mount and by symbolic
   links otherwise, its records by copies.  A save over a linked file can't
   write through the link because checkpoint saving unlinks the old file
   first (HolbuildCheckpointSaveRuntime.begin_replacement).  A store file
   stays readable through the action's own link: a hard link outlives an
   eviction, and a symbolic one points into a family the action leases until
   it exits, which no cap sweep evicts. *)

fun store_path store heap sha = Path.concat(Path.concat(store, heap), sha)

(* A name no process, in this container or another, also picks. *)
fun store_temp path =
  HolbuildTempPath.near path ("." ^ LargeInt.toString (Time.toNanoseconds (Time.now ())) ^ ".tmp")

fun link_or_copy_file src dst =
  (ensure_parent dst;
   remove_file dst;
   Posix.FileSys.link {old = src, new = dst}
   handle OS.SysErr _ => copy_binary src dst)

fun touch_dir dir = Posix.FileSys.utime (dir, NONE) handle OS.SysErr _ => ()

(* Only Poly/ML states are linked: the run writes a failed prefix's .meta and
   .prefix in place. *)
fun share_file save src dst = if save then link_or_copy_file src dst else copy_binary src dst

fun store_add store heap {sha, src, save} =
  let
    val _ = lease_store_family store heap
    val dst = store_path store heap sha
  in
    if file_exists dst then ()
    else
      let val tmp = store_temp dst
      in
        (ensure_parent tmp; share_file save src tmp; FS.rename {old = tmp, new = dst})
        handle e => (remove_file tmp; raise e)
      end
  end

(* A blob a shared entry names that the remote cache no longer holds. *)
exception MissingSharedBlob of string

val noted_store_mount = ref false

(* A Poly/ML state from the store, hard-linked; across file systems, where a
   store on its own mount puts it, symbolically linked, which is safe while
   this process leases the state's family. *)
fun place_state stored dst =
  (remove_file dst;
   Posix.FileSys.link {old = stored, new = dst}
   handle OS.SysErr (_, err) =>
     if err <> SOME Posix.Error.xdev then copy_binary stored dst
     else
       (if !noted_store_mount then ()
        else (noted_store_mount := true;
              HolbuildStatus.message_stderr
                "holbuild: the checkpoint store is on another file system; linking its states symbolically\n");
        Posix.FileSys.symlink {old = Path.mkAbsolute {path = stored, relativeTo = FS.getDir ()}, new = dst}))

(* Puts blob `sha` of heap `heap`'s family at `dst`, from the store, which
   fetches it from the remote cache if it lacks it. *)
fun place_shared_blob remote store heap {sha, dst, save} =
  let
    val stored = store_path store heap sha
    fun fetch () =
      let val tmp = store_temp stored
      in
        ensure_parent tmp;
        case HolbuildRemoteCache.fetch_unlisted_blob remote {hash = sha, dst = tmp} of
            HolbuildCacheBackend.Hit => FS.rename {old = tmp, new = stored}
          | HolbuildCacheBackend.Miss => (remove_file tmp; raise MissingSharedBlob sha)
          | HolbuildCacheBackend.Corrupt msg =>
              (remove_file tmp; raise Error ("could not fetch shared checkpoint blob " ^ sha ^ ": " ^ msg))
      end
    fun place () = if save then place_state stored dst else copy_binary stored dst
    (* Another worker's cap sweep may evict the family between the check
       and the link. *)
    fun from_store () = file_exists stored andalso ((place (); true) handle Error _ => false)
  in
    lease_store_family store heap;
    ensure_parent dst;
    if from_store () then () else (fetch (); place ())
  end

fun shared_heap_key tc root (action : theory_action) =
  HolbuildHash.string_sha256
    (String.concatWith "\n"
       ["holbuild-shared-heap-v1",
        "deps-key=" ^ #deps_key action,
        "preload=" ^ HolbuildHash.string_sha256
                       (String.concatWith "\n" (map (theory_load_line root) (#loads action)) ^ "\n"),
        "toolchain-exact=" ^ HolbuildToolchain.toolchain_key tc,
        "holdir=" ^ FS.fullPath (#holdir tc),
        "action-root=" ^ FS.fullPath root,
        "platform=" ^ String.concatWith " "
                        (map HolbuildHolSharedCache.platform_value
                             ["uname -s", "uname -m", "getconf GNU_LIBC_VERSION"]),
        "runtime=" ^ runtime_identity ()] ^ "\n")

fun shared_checkpoint_key heap_key kind checkpoint_key =
  HolbuildHash.string_sha256
    (String.concat ["holbuild-shared-checkpoint-v1\nheap=", heap_key, "\nkind=", kind,
                    "\ncheckpoint-key=", checkpoint_key, "\n"])

(* A checkpoint a build can resume from, under its key in the shared cache. *)
type shared_candidate =
  {kind : string, key : string, boundary : int, path : string, sidecars : string list,
   accepts : unit -> bool}

(* The records a checkpoint's state may have beside it. *)
val shared_sidecar_suffixes = [".ok", ".meta", ".prefix"]

(* Later boundaries first and, at one boundary, a failed prefix before the
   context, the order in which a local build prefers them. *)
fun shared_candidates policy base {theorem_checkpoints, declaration_checkpoints, termination_diagnostics = _} =
  let
    val timeout = tactic_timeout policy
    fun theorem (cp : HolbuildTheoryCheckpoints.checkpoint) : shared_candidate =
      {kind = "theorem_context", key = #checkpoint_key cp, boundary = #boundary cp,
       path = #context_path cp, sidecars = [".ok"],
       accepts = fn () => theorem_context_checkpoint_exists timeout base cp}
    fun declaration (cp : HolbuildTheoryCheckpoints.declaration_checkpoint) : shared_candidate =
      {kind = "definition_context", key = #checkpoint_key cp, boundary = #boundary cp,
       path = #context_path cp, sidecars = [".ok"],
       accepts = fn () => declaration_context_checkpoint_exists timeout base cp}
    (* A failed prefix's local identity is its .ok fields; the recorded
       timeout is checked on restore, as for contexts. *)
    fun failed (cp : HolbuildTheoryCheckpoints.checkpoint) : shared_candidate =
      {kind = "failed_prefix",
       key = HolbuildHash.string_sha256
               (String.concatWith "\n"
                  (List.filter (fn line => not (String.isPrefix "proof_timeout=" line))
                               (String.fields (fn c => c = #"\n") (#failed_prefix_ok cp)))),
       boundary = #boundary cp, path = #failed_prefix_path cp,
       sidecars = [".ok", ".meta", ".prefix"],
       accepts = fn () => Option.isSome (failed_prefix_checkpoint timeout cp)}
    fun before_ (a : shared_candidate) (b : shared_candidate) =
      #boundary a > #boundary b orelse
      (#boundary a = #boundary b andalso #kind a = "failed_prefix")
    fun insert c [] = [c]
      | insert c (d :: ds) = if before_ c d then c :: d :: ds else d :: insert c ds
  in
    List.foldl (fn (c, sorted) => insert c sorted) []
      ((if proof_steps_enabled policy then map failed theorem_checkpoints else []) @
       map theorem theorem_checkpoints @ map declaration declaration_checkpoints)
  end

(* Manifest lines are `blob=<sha256> <role> [<argument>]`, which the remote
   cache lists as the entry's blobs. *)
fun shared_manifest header kind entries =
  String.concat
    (header ^ "\n" ::
     (case kind of SOME k => "kind=" ^ k ^ "\n" | NONE => "") ::
     map (fn (role, sha, arg) =>
             "blob=" ^ sha ^ " " ^ role ^ (if arg = "" then "" else " " ^ arg) ^ "\n")
         entries)

fun shared_manifest_entries text =
  List.mapPartial
    (fn line =>
        if not (String.isPrefix "blob=" line) then NONE
        else
          case String.fields (fn c => c = #" ") (String.extract(line, 5, NONE)) of
              sha :: role :: arg =>
                if sha256_text sha then SOME (role, sha, String.concatWith " " arg)
                else raise Error ("malformed shared checkpoint manifest line: " ^ line)
            | _ => raise Error ("malformed shared checkpoint manifest line: " ^ line))
    (String.tokens (fn c => c = #"\n") text)

type shared_context =
  {store : string, checkpoint_root : string, heap_key : string, base_state : string,
   deps_key : string, deps_loaded : string, requested_timeout : real option,
   candidates : shared_candidate list}

fun shared_context cache checkpoint_root tc root policy (action : theory_action) checkpoints : shared_context =
  let val base = action_checkpoint_base checkpoint_root action
  in
    {store = share_store cache, checkpoint_root = checkpoint_root,
     heap_key = shared_heap_key tc root action,
     base_state = FS.fullPath (HolbuildToolchain.base_state tc),
     deps_key = #deps_key action,
     deps_loaded = deps_loaded_path base (#deps_key action),
     requested_timeout = tactic_timeout policy,
     candidates = shared_candidates policy base checkpoints}
  end

fun saved_parent path = PolyML.SaveState.showParent path handle _ => NONE

fun shared_heap_parent_ok ({deps_loaded, base_state, ...} : shared_context) =
  case saved_parent deps_loaded of
      SOME parent => (FS.fullPath parent = base_state handle OS.SysErr _ => false)
    | NONE => false

fun tree_relative root path =
  if String.isPrefix (root ^ "/") path then SOME (String.extract(path, size root + 1, NONE)) else NONE

fun tree_path root rel =
  if rel = "" orelse escapes rel then raise Error ("shared checkpoint path leaves the checkpoint tree: " ^ rel)
  else Path.concat(root, rel)

(* The files restored, with their SHA-256s, and the heap they are on; and
   the entries found naming blobs the cache no longer holds, with those
   blobs, which the publish replaces. *)
type shared_restore =
  {heap : string option, files : (string * string) list, stale : string list, missing : string list}

val nothing_restored : shared_restore = {heap = NONE, files = [], stale = [], missing = []}

(* Before the run: the latest checkpoint the cache holds for this source,
   else the heap, placed in the action's checkpoint tree, which is empty. *)
fun restore_shared_checkpoints remote (ctx as {store, checkpoint_root, heap_key, deps_key, deps_loaded,
                                              requested_timeout, candidates, ...} : shared_context) =
  let
    val stale = ref ([] : string list)
    val missing = ref ([] : string list)
    fun missing_blob key sha =
      (warn ("the cache lost blob " ^ sha ^ " of shared entry " ^ key);
       stale := key :: !stale; missing := sha :: !missing)
    val no_files = {heap = NONE, files = []}
    fun wipe () = remove_tree checkpoint_root
    fun place heap (sha, dst) = place_shared_blob remote store heap {sha = sha, dst = dst, save = true}
    fun place_sidecar heap (sha, dst) = place_shared_blob remote store heap {sha = sha, dst = dst, save = false}
    fun place_heap heap =
      (place heap (heap, deps_loaded);
       write_text (checkpoint_ok_path deps_loaded) (deps_checkpoint_ok_text deps_key);
       touch_dir (Path.concat(store, heap)))
    fun single role entries =
      case List.filter (fn (r, _, _) => r = role) entries of
          [(_, sha, arg)] => (sha, arg)
        | _ => raise Error ("shared checkpoint manifest needs one " ^ role)
    (* Each file's recorded parent is the next one down the chain. *)
    fun chain_ok paths =
      case paths of
          [] => true
        | [last] => saved_parent last = SOME deps_loaded
        | p :: (rest as q :: _) => saved_parent p = SOME q andalso chain_ok rest
    fun try_candidate (c : shared_candidate) =
      let val key = shared_checkpoint_key heap_key (#kind c) (#key c)
      in
        case HolbuildRemoteCache.get_action remote key of
            NONE => NONE
          | SOME text =>
              (let
                 val entries = shared_manifest_entries text
                 val (heap, _) = single "heap" entries
                 val (leaf, leaf_rel) = single "leaf" entries
                 val _ = if tree_path checkpoint_root leaf_rel = #path c then ()
                         else raise Error "shared checkpoint manifest names another checkpoint"
                 val spine =
                   List.mapPartial (fn ("spine", sha, rel) => SOME (sha, tree_path checkpoint_root rel) | _ => NONE)
                                   entries
                 (* The spine's own records, so that a retry after HOL rejects
                    the leaf resumes from the checkpoint under it. *)
                 val spine_sidecars =
                   List.mapPartial
                     (fn ("spine-sidecar", sha, rel) =>
                           let val path = tree_path checkpoint_root rel
                           in
                             if List.exists (fn (_, p) => List.exists (fn suffix => path = p ^ suffix)
                                                                      shared_sidecar_suffixes)
                                            spine
                             then SOME (sha, path)
                             else raise Error ("unexpected shared checkpoint sidecar " ^ rel)
                           end
                       | _ => NONE)
                     entries
                 val sidecars =
                   List.mapPartial
                     (fn ("sidecar", sha, suffix) =>
                           if List.exists (fn s => s = suffix) (#sidecars c) then SOME (sha, #path c ^ suffix)
                           else raise Error ("unexpected shared checkpoint sidecar " ^ suffix)
                       | _ => NONE)
                     entries
                 val restored = (heap, deps_loaded) :: spine @ spine_sidecars @ ((leaf, #path c) :: sidecars)
               in
                 (* The small .ok first: a checkpoint with a laxer timeout than
                    requested is skipped before its chain is fetched. *)
                 List.app (place_sidecar heap) sidecars;
                 if not (checkpoint_timeout_satisfies requested_timeout (#path c)) then (wipe (); NONE)
                 else
                   (place_heap heap;
                    List.app (place heap) spine;
                    List.app (place_sidecar heap) spine_sidecars;
                    place heap (leaf, #path c);
                    if shared_heap_parent_ok ctx andalso chain_ok (#path c :: rev (map #2 spine)) andalso
                       #accepts c () then
                      (HolbuildStatus.message_stdout
                         ("restored shared " ^ #kind c ^ " checkpoint " ^ leaf_rel ^ "\n");
                       SOME {heap = SOME heap, files = map (fn (sha, path) => (path, sha)) restored})
                    else (warn ("shared checkpoint failed validation: " ^ leaf_rel); wipe (); NONE))
               end
               handle MissingSharedBlob sha => (missing_blob key sha; wipe (); NONE)
                    | e => (warn ("could not restore shared checkpoint: " ^ General.exnMessage e);
                            wipe (); NONE))
      end
    fun try_heap () =
      case HolbuildRemoteCache.get_action remote heap_key of
          NONE => no_files
        | SOME text =>
            (let val (heap, _) = single "heap" (shared_manifest_entries text)
             in
               place_heap heap;
               if shared_heap_parent_ok ctx andalso deps_checkpoint_exists deps_loaded deps_key then
                 (HolbuildStatus.message_stdout "restored shared deps-loaded heap\n";
                  {heap = SOME heap, files = [(deps_loaded, heap)]})
               else (warn "shared deps-loaded heap failed validation"; wipe (); no_files)
             end
             handle MissingSharedBlob sha => (missing_blob heap_key sha; wipe (); no_files)
                  | e => (warn ("could not restore the shared heap: " ^ General.exnMessage e);
                          wipe (); no_files))
    val {heap, files} =
      case first_some try_candidate candidates of
          SOME restored => restored
        | NONE => try_heap ()
  in
    {heap = heap, files = files, stale = !stale, missing = !missing}
  end
  handle e => (warn ("shared checkpoint restore failed: " ^ General.exnMessage e);
               remove_tree (#checkpoint_root ctx); nothing_restored)

(* After the run, successful or not: the heap if this run saved it, then,
   if the heap under them is the published one, the new checkpoints. *)
fun publish_shared_checkpoints remote (ctx as {store, checkpoint_root, heap_key, deps_key, deps_loaded,
                                              candidates, ...} : shared_context)
                               ({heap = restored_heap, files = restored, stale, missing} : shared_restore) =
  let
    fun member x xs = List.exists (fn y => y = x) xs
    (* An entry naming a blob the cache lost is replaced, as if absent. *)
    fun present key = not (member key stale) andalso Option.isSome (HolbuildRemoteCache.get_action remote key)
    (* has_blob knows only the blobs of the entries this process read. *)
    fun upload_sha path sha =
        if HolbuildRemoteCache.has_blob remote sha andalso not (member sha missing) then sha
        else
          case HolbuildRemoteCache.publish_blob remote {hash = sha, src = path} of
              HolbuildCacheBackend.Published => sha
            | HolbuildCacheBackend.AlreadyPresent => sha
            | _ => raise Error ("could not upload " ^ path)
    fun upload path = upload_sha path (HolbuildHash.file_sha256 path)
    (* A heap this run saved is published only where no other worker's is:
       checkpoints on a heap that lost are chained to bytes no other worker
       has, so they stay local. *)
    fun publish_heap sha =
      if present heap_key orelse
         not (shared_heap_parent_ok ctx) then NONE
      else
        let
          val manifest = shared_manifest "holbuild-shared-heap-v1" NONE [("heap", sha, "")]
          val _ = upload_sha deps_loaded sha
          val _ = HolbuildRemoteCache.publish_action remote {key = heap_key, text = manifest}
        in
          if HolbuildRemoteCache.get_action remote heap_key = SOME manifest then
            (store_add store sha {sha = sha, src = deps_loaded, save = true}; SOME sha)
          else NONE
        end
    val heap =
      if not (deps_checkpoint_exists deps_loaded deps_key) then NONE
      else
        let val current = HolbuildHash.file_sha256 deps_loaded
        in
          (* A restored heap Poly failed to load was replaced by this run's. *)
          if restored_heap = SOME current then restored_heap else publish_heap current
        end
    fun was_restored path =
      List.exists (fn (p, sha) => p = path andalso (HolbuildHash.file_sha256 path = sha handle _ => false))
                  restored
    val parents = ref (Redblackmap.mkDict String.compare)
    fun parent p =
      case Redblackmap.peek (!parents, p) of
          SOME q => q
        | NONE => let val q = saved_parent p in parents := Redblackmap.insert (!parents, p, q); q end
    (* The checkpoint's ancestors in the tree, nearest first, down to the
       heap. *)
    fun ancestors path =
      let
        fun loop p acc =
          case parent p of
              NONE => NONE
            | SOME q =>
                if q = deps_loaded then SOME (rev acc)
                else if Option.isSome (tree_relative checkpoint_root q) andalso length acc < 100000 then
                  loop q (q :: acc)
                else NONE
      in
        loop path []
      end
    fun publish_candidate heap (c : shared_candidate) =
      let val key = shared_checkpoint_key heap_key (#kind c) (#key c)
      in
        if not (checkpoint_exists (#path c)) orelse was_restored (#path c) orelse not (#accepts c ()) orelse
           present key then ()
        else
          case ancestors (#path c) of
              NONE => warn ("shared checkpoint chain is not on the heap: " ^ #path c)
            | SOME nearest_first =>
                let
                  val rel = valOf o tree_relative checkpoint_root
                  val spine = rev nearest_first
                  val sidecars = List.filter (fn suffix => file_exists (#path c ^ suffix)) (#sidecars c)
                  fun sidecars_of role p =
                    List.mapPartial
                      (fn suffix => if file_exists (p ^ suffix) then SOME (role, p ^ suffix, rel (p ^ suffix))
                                    else NONE)
                      shared_sidecar_suffixes
                  val files =
                    map (fn p => ("spine", p, rel p)) spine @
                    List.concat (map (sidecars_of "spine-sidecar") spine) @
                    [("leaf", #path c, rel (#path c))] @
                    map (fn suffix => ("sidecar", #path c ^ suffix, suffix)) sidecars
                  val entries = map (fn (role, path, arg) => (role, upload path, arg)) files
                  val _ = HolbuildRemoteCache.publish_action remote
                            {key = key,
                             text = shared_manifest "holbuild-shared-checkpoint-v1" (SOME (#kind c))
                                      (("heap", heap, "") :: entries)}
                in
                  ListPair.app (fn ((role, path, _), (_, sha, _)) =>
                                   store_add store heap
                                     {sha = sha, src = path, save = role = "spine" orelse role = "leaf"})
                               (files, entries)
                end
      end
      handle e => warn ("could not publish shared checkpoint " ^ #path c ^ ": " ^ General.exnMessage e)
  in
    case heap of
        NONE => ()
      | SOME heap => List.app (publish_candidate heap) candidates
  end
  handle e => warn ("shared checkpoint publish failed: " ^ General.exnMessage e)

(* Runs one ActionSpec, writes its result record and returns the exit code.
   `toolchain` ensures the spec's HOL toolchain and returns it. *)
fun exec_action {spec_sha256, result_file, cache_cap, share_heaps, toolchain} =
  let
    val start = Time.now ()
    val remote =
      case HolbuildRemoteCacheConfig.url () of
          SOME url => HolbuildRemoteCache.remote url
        | NONE => raise Error "exec-action needs a remote cache: pass --remote-cache URL"
    val cache = cache_root ()
    val root = Path.concat(cache, "action")
    val checkpoint_root = Path.concat(cache, "checkpoints")
    val input_key = ref ""
    val target = ref ("", "")
    val peak = ref NONE
    (* Without shared heaps the checkpoint tree outlives the action root, so
       a rerun after an edit resumes from the checkpoints before it; the
       worker cache cap bounds it.  With them it is the action's own, filled
       from the store. *)
    fun empty_root () = (remove_tree root; if share_heaps then remove_tree checkpoint_root else ())
    fun build_log () = current_build_log (current_log_dir root (#1 (!target)) (#2 (!target)))
    fun upload_log () =
      let val path = build_log ()
      in
        if not (file_exists path) then NONE
        else
          let val sha = HolbuildHash.file_sha256 path
          in
            case HolbuildRemoteCache.publish_blob remote {hash = sha, src = path} of
                HolbuildCacheBackend.Published => SOME (sha, Position.toString (FS.fileSize path))
              | HolbuildCacheBackend.AlreadyPresent => SOME (sha, Position.toString (FS.fileSize path))
              | _ => (warn "could not upload the action log"; NONE)
          end
      end
      handle e => (warn ("could not upload the action log: " ^ General.exnMessage e); NONE)
    fun run () =
      let
        val _ = (HolbuildRemoveTree.remove_strict root; ensure_dir root)
        val _ = if share_heaps then HolbuildRemoveTree.remove_strict checkpoint_root else ()
        val spec_path = Path.concat(root, ".holbuild/action-spec")
        (* Only a spec the cache doesn't have is rejected; a failed fetch is
           retryable. *)
        val _ =
          (ensure_parent spec_path;
           case HolbuildRemoteCache.fetch_unlisted_blob remote {hash = spec_sha256, dst = spec_path} of
               HolbuildCacheBackend.Hit => ()
             | HolbuildCacheBackend.Miss => reject_spec ("the cache has no spec " ^ spec_sha256)
             | HolbuildCacheBackend.Corrupt msg => raise action_failed InternalFailure ("cannot fetch the spec: " ^ msg))
        val spec = parse_action_spec (read_text spec_path)
        val _ = input_key := #input_key spec
        val _ = verify_action_spec spec
        (* Names the build log, so only once the names are known safe. *)
        val _ = target := (#package spec, #logical spec)
        val tc =
          toolchain (#toolchain spec)
          handle e => raise action_failed ToolchainFailure (General.exnMessage e)
        val _ =
          if HolbuildToolchain.action_toolchain_key tc HolbuildToolchain.toolchain_key =
             action_text_value spec "toolchain" then ()
          else raise ActionFailed (ToolchainFailure, "the toolchain's identity does not match the action text")
        val _ = hydrate_action_root remote root spec
      in
        if action_already_done root spec then
          (* The entry may have come from the worker's local cache, so make
             sure the remote, where the result counts, holds it too. *)
          (check_remote_publication remote root spec;
           "cached")
        else
          let
            val action = spec_theory_action root spec
            (* A local entry that didn't restore must not stand in for this
               build's when the publication is checked, and, as in a local
               build, its theory's checkpoints may hold parents other than
               the ones now restored. *)
            val _ =
              case HolbuildCache.get_action cache (#input_key spec) of
                  SOME _ =>
                    (HolbuildCache.remove_action cache (#input_key spec);
                     remove_checkpoint_family (action_checkpoint_base checkpoint_root action))
                | NONE => ()
            val stage = action_stage root action
            val policy = spec_policy spec
            val oom_before = cgroup_oom_kills ()
            val _ = last_child_status := NONE
            val _ =
              let
                val source_text = read_text (#source_file action)
                val checkpoints = action_checkpoints policy checkpoint_root action source_text
                val shared =
                  if not share_heaps then NONE
                  else
                    SOME (shared_context cache checkpoint_root tc root policy action checkpoints)
                    handle e => (warn ("not sharing heaps: " ^ General.exnMessage e); NONE)
                val restored =
                  case shared of
                      SOME ctx => restore_shared_checkpoints remote ctx
                    | NONE => nothing_restored
                fun publish_shared () =
                  case shared of
                      SOME ctx => publish_shared_checkpoints remote ctx restored
                    | NONE => ()
              in
                (ignore (run_theory_action_checkpoints true policy tc root checkpoint_root
                           (toolchain_base_context tc) action source_text checkpoints)
                 handle e => (publish_shared (); raise e));
                (* After the publish: the checkpoints saved after resuming
                   from a failed prefix are its children. *)
                publish_shared ();
                remove_failed_prefix_checkpoints (#theorem_checkpoints checkpoints)
              end
              handle Error msg =>
                let val log_text = read_text (build_log ()) handle _ => ""
                in
                  raise ActionFailed
                    (classify_run_failure stage log_text oom_before msg, msg)
                end
            val _ = peak := peak_rss_mb stage
            val _ = check_remote_publication remote root spec
          in
            "built"
          end
      end
    fun attempt () =
      (run (), NONE)
      handle ActionFailed failure => ("failed", SOME failure)
           | e => ("failed", SOME (exception_failure e))
    val (status, failure, log) =
      with_action_root_lock cache
        (fn () =>
            let
              val _ =
                let val {limit_bytes, reserve_bytes} = cache_cap
                in
                  enforce_worker_cache_cap
                    {cache = cache, checkpoint_root = checkpoint_root,
                     limit_bytes = limit_bytes, reserve_bytes = reserve_bytes}
                end
              val (status, failure) = attempt ()
              val log = upload_log ()
              (* A final failure's log is its only diagnostic and nothing
                 retries the action to recover it. *)
              val failure =
                case (failure, log) of
                    (SOME (kind, msg), NONE) =>
                      if (kind = ProofFailure orelse kind = TacticTimeoutFailure) andalso
                         file_exists (build_log ()) then
                        SOME (PublishFailure, "could not upload the build log of a " ^
                                              failure_name kind ^ " failure: " ^ msg)
                      else failure
                  | _ => failure
            in
              empty_root ();
              (status, failure, log)
            end)
    val wall_ms = Time.toMilliseconds (Time.-(Time.now (), start))
    val text =
      result_text (spec_sha256, !input_key)
        {status = status, failure = failure, wall_ms = wall_ms,
         peak = if status = "built" then !peak else NONE, log = log}
  in
    (case failure of
         SOME (_, msg) => HolbuildStatus.message_stderr ("holbuild: exec-action failed: " ^ msg ^ "\n")
       | NONE => ());
    (case result_file of
         SOME path => write_text path text
       | NONE => print text);
    case failure of
        NONE => 0
      | SOME (kind, _) => failure_exit_code kind
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

fun buildheap_external_args plan =
  unique_strings
    (List.concat
      (map (direct_external_loads plan)
           (HolbuildBuildPlan.selected_nodes plan)))

fun buildheap_args heap_kind plan =
  buildheap_external_args plan @
  map (buildheap_arg heap_kind) (HolbuildBuildPlan.selected_nodes plan)

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
                 handle HolbuildToolchain.Error msg => raise Error msg
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
