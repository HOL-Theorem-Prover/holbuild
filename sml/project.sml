structure HolbuildProject =
struct

structure Path = OS.Path
structure FS = OS.FileSys

datatype heap_kind = datatype HolbuildPackageDefinition.heap_kind
datatype heap = datatype HolbuildPackageDefinition.heap
type root_tactic_timeout = HolbuildPackageDefinition.root_tactic_timeout
datatype extra_input = datatype HolbuildPackageDefinition.extra_input
datatype action_policy = datatype HolbuildPackageDefinition.action_policy
datatype generator = datatype HolbuildPackageDefinition.generator
datatype group = datatype HolbuildPackageDefinition.group
datatype dependency_source = datatype HolbuildPackageDefinition.dependency_source
datatype dependency_role = datatype HolbuildPackageDefinition.dependency_role
datatype dependency = datatype HolbuildPackageDefinition.dependency

datatype override = datatype HolbuildLocalConfig.override
datatype local_config = datatype HolbuildLocalConfig.t

datatype package =
  Package of
    { name : string,
      root : string,
      manifest : string,
      definition : HolbuildPackageDefinition.t,
      provenance : HolbuildPackageProvenance.t,
      members : string list,
      excludes : string list,
      exclude_globs : string list,
      roots : string list,
      root_groups : string list,
      groups : group list,
      artifact_root : string,
      action_policies : action_policy list,
      generators : generator list }

type project_graph_edge =
  {declaring_package : string, dependency_name : string,
   dependency_package : string}
type project_graph_data =
  {root : string, hol : string, packages : package list,
   edges : project_graph_edge list}

(* Transitional resolved-project record. The duplicated definition/local fields
   keep existing callers behaviorally unchanged while later #131 phases migrate
   them to package-definition and invocation-config accessors. *)
type t =
  { root : string,
    artifact_root : string,
    graph_artifact_root : string,
    manifest : string,
    definition : HolbuildPackageDefinition.t,
    name : string,
    version : string option,
    members : string list,
    excludes : string list,
    exclude_globs : string list,
    roots : string list,
    root_groups : string list,
    groups : group list,
    root_tactic_timeouts : root_tactic_timeout list,
    dependencies : dependency list,
    local_config : HolbuildLocalConfig.t,
    overrides : override list,
    local_build_excludes : string list,
    local_build_exclude_globs : string list,
    local_build_jobs : int option,
    build_tactic_timeout : real option,
    checkpoint_limit_gb : int option,
    remote_cache_url : string option,
    remote_cache_curl_config : string option,
    run_heap : string option,
    run_loads : string list,
    heaps : heap list,
    action_policies : action_policy list,
    generators : generator list,
    graph_cache :
      (HolbuildHolToolchainConfig.kernel_variant * project_graph_data) list ref }

exception Error of string

fun die msg = raise Error msg

fun warn msg = TextIO.output(TextIO.stdErr, "holbuild: warning: " ^ msg ^ "\n")

val source_dir_ref : string option ref = ref NONE

fun absolute_from_cwd path =
  Path.mkAbsolute {path = path, relativeTo = FS.getDir ()}

fun set_source_dir path = source_dir_ref := SOME (absolute_from_cwd path)

fun hol_toolchain_dependency
      (Dependency {role = HolToolchainDependency, source = GitSource _, ...}) = true
  | hol_toolchain_dependency _ = false

fun original_dir () =
  case OS.Process.getEnv "HOLBUILD_ORIG_CWD" of
      SOME d => d
    | NONE => FS.getDir ()

fun source_dir_selection () =
  case !source_dir_ref of
      SOME d => {search_root = d, artifact_root = original_dir ()}
    | NONE =>
      case OS.Process.getEnv "HOLBUILD_SOURCE_DIR" of
          SOME d => {search_root = absolute_from_cwd d, artifact_root = original_dir ()}
        | NONE => {search_root = original_dir (), artifact_root = ""}

fun source_dir () = #search_root (source_dir_selection ())

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun parent dir =
  let val p = Path.dir dir
  in if p = "" then dir else p end

fun find_manifest_from dir =
  let
    fun loop d =
      let val candidate = Path.concat(d, "holproject.toml")
      in
        if readable candidate then SOME candidate
        else
          let val p = parent d
          in if p = d then NONE else loop p end
      end
  in
    loop (Path.mkAbsolute {path = dir, relativeTo = FS.getDir ()})
  end

fun manifest_root manifest = Path.dir manifest

fun parse_local_config root =
  HolbuildLocalConfig.parse root
  handle HolbuildManifestUtil.Error msg => die msg

fun parse_table_at table {manifest, root, artifact_root, graph_artifact_root, local_config} =
  let
    val LocalConfig {overrides, build_excludes, build_exclude_globs, build_jobs, build_tactic_timeout, checkpoint_limit_gb, remote_cache_url, remote_cache_curl_config} = local_config
    val {definition, compatibility = _,
         tactic_timeout = manifest_timeout} =
      (HolbuildPackageDefinition.parse_table table
       handle HolbuildManifestUtil.Error msg => die msg)
    val {metadata = {name, version},
         sources = {members, excludes = manifest_excludes,
                    exclude_globs = manifest_exclude_globs},
         entrypoints = {roots, root_groups, groups, root_tactic_timeouts},
         dependencies, runtime = {run_heap, run_loads, heaps},
         actions = action_policies, generators} = definition
    val excludes = manifest_excludes @ build_excludes
    val exclude_globs = manifest_exclude_globs @ build_exclude_globs
  in
    { root = root,
      artifact_root = artifact_root,
      graph_artifact_root = graph_artifact_root,
      manifest = manifest,
      definition = definition,
      name = name,
      version = version,
      members = members,
      excludes = excludes,
      exclude_globs = exclude_globs,
      roots = roots,
      root_groups = root_groups,
      groups = groups,
      root_tactic_timeouts = root_tactic_timeouts,
      dependencies = dependencies,
      local_config = local_config,
      overrides = overrides,
      local_build_excludes = build_excludes,
      local_build_exclude_globs = build_exclude_globs,
      local_build_jobs = build_jobs,
      build_tactic_timeout = case build_tactic_timeout of NONE => manifest_timeout | some => some,
      checkpoint_limit_gb = checkpoint_limit_gb,
      remote_cache_url = remote_cache_url,
      remote_cache_curl_config = remote_cache_curl_config,
      run_heap = run_heap,
      run_loads = run_loads,
      heaps = heaps,
      action_policies = action_policies,
      generators = generators,
      graph_cache = ref [] }
  end

fun parse_at args =
  parse_table_at (TOML.fromFile (#manifest args)) args
  handle Error msg => die (#manifest args ^ ": " ^ msg)

fun parse_builtin_holdir_at args =
  let
    val cached_manifest = HolbuildHolSharedCache.hol_source_manifest_for_holdir (#root args)
    val text =
      if readable cached_manifest then
        let val input = TextIO.openIn cached_manifest
        in TextIO.inputAll input before TextIO.closeIn input end
      else HolbuildBuiltinManifests.empty_hol_manifest_text
  in
    parse_table_at (TOML.fromString text) args
    handle Error msg => die (cached_manifest ^ ": " ^ msg)
  end

fun parse manifest =
  let
    val root = manifest_root manifest
    val local_config = parse_local_config root
  in
    parse_at {manifest = manifest, root = root, artifact_root = root, graph_artifact_root = root, local_config = local_config}
  end

fun discover () =
  let val {search_root, artifact_root} = source_dir_selection ()
  in
    case find_manifest_from search_root of
        SOME manifest =>
          let
            val root = manifest_root manifest
            val artifact_root' = if artifact_root = "" then root else artifact_root
            val local_config = parse_local_config root
          in
            parse_at {manifest = manifest, root = root, artifact_root = artifact_root', graph_artifact_root = artifact_root', local_config = local_config}
          end
      | NONE => die "no holproject.toml found in --source-dir/current directory or parents"
  end

fun abs_under root path =
  if Path.isAbsolute path then path else Path.concat(root, path)

fun abs_member ({root, ...} : t) member = abs_under root member
fun abs_run_heap ({root, run_heap, ...} : t) = Option.map (abs_under root) run_heap

fun override_path overrides name =
  let
    fun matches (OverridePath {name = name', ...}) = name = name'
      | matches (OverrideGit {name = name', ...}) = name = name'
  in
    case List.find matches overrides of
        SOME (OverridePath {path, ...}) => SOME path
      | NONE => NONE
      | SOME (OverrideGit _) => NONE
  end

fun override_git overrides name =
  let
    fun matches (OverridePath {name = name', ...}) = name = name'
      | matches (OverrideGit {name = name', ...}) = name = name'
  in
    case List.find matches overrides of
        SOME (OverrideGit {git, ...}) => SOME git
      | NONE => NONE
      | SOME (OverridePath _) => NONE
  end

fun dependency_name (Dependency {name, ...}) = name

fun package_name (Package {name, ...}) = name
fun package_root (Package {root, ...}) = root
fun package_manifest (Package {manifest, ...}) = manifest
fun package_definition_of (Package {definition, ...}) = definition
fun package_provenance (Package {provenance, ...}) = provenance
fun package_content_identity package =
  HolbuildPackageProvenance.content_identity
    (HolbuildPackageDefinition.content_id (package_definition_of package))
    (package_provenance package)
fun package_identity package =
  let val definition = package_definition_of package
  in
    HolbuildPackageProvenance.identity
      {name = package_name package,
       metadata_id = HolbuildPackageDefinition.metadata_id definition,
       content_id = package_content_identity package}
  end
fun package_source_root package =
  HolbuildPackageProvenance.source_root (package_provenance package)
fun package_members (Package {members, ...}) = members
fun package_excludes (Package {excludes, ...}) = excludes
fun package_exclude_globs (Package {exclude_globs, ...}) = exclude_globs
fun package_roots (Package {roots, ...}) = roots
fun package_root_groups (Package {root_groups, ...}) = root_groups
fun package_groups (Package {groups, ...}) = groups
fun package_artifact_root (Package {artifact_root, ...}) = artifact_root
fun root_tactic_timeouts ({root_tactic_timeouts, ...} : t) = root_tactic_timeouts
fun root_tactic_timeout_for ({root_tactic_timeouts, ...} : t) root =
  Option.map #timeout (List.find (fn entry => #root entry = root) root_tactic_timeouts)
fun package_generators (Package {generators, ...}) = generators
fun artifact_root ({artifact_root, ...} : t) = artifact_root
fun package_definition ({definition, ...} : t) = definition
fun local_config ({local_config, ...} : t) = local_config
fun hol_dependency ({dependencies, ...} : t) =
  List.find
    (fn Dependency {role = HolToolchainDependency, ...} => true | _ => false)
    dependencies

type resolution = {kernel_variant : HolbuildHolToolchainConfig.kernel_variant}
fun cached_graph_with ({kernel_variant} : resolution) (project : t) =
  Option.map #2
    (List.find (fn (variant, _) => variant = kernel_variant)
      (!(#graph_cache project)))
fun store_graph_with ({kernel_variant} : resolution) (project : t) graph =
  #graph_cache project :=
    (kernel_variant, graph) ::
    List.filter (fn (variant, _) => variant <> kernel_variant)
      (!(#graph_cache project))
val standard_resolution = {kernel_variant = HolbuildHolToolchainConfig.StandardKernel}

fun hol_holdir ({kernel_variant} : resolution) {git, rev} =
  HolbuildHolSharedCache.holdir_for_with_kernel
    {git = git, rev = rev, kernel_variant = kernel_variant}

fun project_hol_dir_with resolution project =
  case hol_dependency project of
      SOME (Dependency {source = GitSource request, ...}) =>
        SOME (hol_holdir resolution request)
    | _ => NONE

fun project_hol_dir project = project_hol_dir_with standard_resolution project
fun build_roots ({roots, ...} : t) = roots
fun build_root_groups ({root_groups, ...} : t) = root_groups
fun build_groups ({groups, ...} : t) = groups
fun checkpoint_limit_gb ({checkpoint_limit_gb, ...} : t) = checkpoint_limit_gb
fun remote_cache_url ({remote_cache_url, ...} : t) = remote_cache_url
fun remote_cache_curl_config ({remote_cache_curl_config, ...} : t) = remote_cache_curl_config
fun package_action_policies (Package {action_policies, ...}) = action_policies

fun generator_name (Generator {name, ...}) = name
fun generator_command (Generator {command, ...}) = command
fun generator_inputs (Generator {inputs, ...}) = inputs
fun generator_outputs (Generator {outputs, ...}) = outputs
fun generator_deps (Generator {deps, ...}) = deps

fun group_name (Group {name, ...}) = name
fun group_includes (Group {includes, ...}) = includes
fun group_include_globs (Group {include_globs, ...}) = include_globs
fun group_excludes (Group {excludes, ...}) = excludes
fun group_exclude_globs (Group {exclude_globs, ...}) = exclude_globs
fun group_allow_empty (Group {allow_empty, ...}) = allow_empty

fun action_policy_logical (ActionPolicy {logical, ...}) = logical
fun action_deps (ActionPolicy {deps, ...}) = deps
fun action_loads (ActionPolicy {loads, ...}) = loads
fun action_extra_inputs (ActionPolicy {extra_inputs, ...}) = extra_inputs
fun action_cache_enabled (ActionPolicy {impure, cache, always_reexecute, ...}) =
  cache andalso not impure andalso not always_reexecute
fun action_always_reexecute (ActionPolicy {impure, always_reexecute, ...}) =
  impure orelse always_reexecute
fun extra_input_path (ExtraInput {path}) = path

fun default_action_policy logical =
  ActionPolicy {logical = logical, deps = [], loads = [], extra_inputs = [], impure = false,
                cache = true, always_reexecute = false}

fun action_policy_for policies logical =
  case List.find (fn policy => action_policy_logical policy = logical) policies of
      SOME policy => policy
    | NONE => default_action_policy logical

fun dependency_path_context name = "dependencies." ^ name ^ ".path"
fun dependency_manifest_context name = "dependencies." ^ name ^ ".manifest"

fun dependency_local_path_with resolution (project as {graph_artifact_root, ...} : t) (Dependency {name, source, role}) =
  case override_path (#overrides project) name of
      SOME path => SOME path
    | NONE =>
        case source of
            GitSource {git, rev} =>
              if role = HolToolchainDependency then
                SOME (hol_holdir resolution {git = git, rev = rev})
              else SOME (Path.concat(Path.concat(Path.concat(graph_artifact_root, ".holbuild"), "src"), name))
          | FromSource {from, path, ...} =>
              (case hol_dependency project of
                   SOME (Dependency {role = HolToolchainDependency,
                                     source = GitSource {git, rev}, ...}) =>
                     if from = "hol" then SOME (Path.concat(hol_holdir resolution {git = git, rev = rev}, path))
                     else SOME (Path.concat(Path.concat(Path.concat(Path.concat(graph_artifact_root, ".holbuild"), "src"), from), path))
                 | _ => SOME (Path.concat(Path.concat(Path.concat(Path.concat(graph_artifact_root, ".holbuild"), "src"), from), path)))

fun dependency_local_path project dep = dependency_local_path_with standard_resolution project dep

fun dependency_manifest (project as {manifest = project_manifest, graph_artifact_root, ...} : t) dep =
  case dep of
      dep as Dependency {name, source = GitSource _, ...} =>
        if hol_toolchain_dependency dep then SOME (HolbuildBuiltinManifests.holdir_manifest_name)
        else
          (case override_path (#overrides project) name of
               SOME path => SOME (Path.concat(path, "holproject.toml"))
             | NONE => SOME (Path.concat(Path.concat(Path.concat(Path.concat(graph_artifact_root, ".holbuild"), "src"), name),
                                         "holproject.toml")))
    | Dependency {source = FromSource {manifest, ...}, ...} =>
        SOME (abs_under (manifest_root project_manifest) manifest)

fun heap_kind_to_string HeapImage = "heap"
  | heap_kind_to_string (ExecutableImage {main}) = "executable main=" ^ main

fun heap_to_string (Heap {name, output, objects, kind}) =
  name ^ " (" ^ heap_kind_to_string kind ^ ") -> " ^ output ^ " [" ^ String.concatWith ", " objects ^ "]"

fun dependency_to_string project (dep as Dependency {name, source, ...}) =
  let
    fun field label value =
      case value of NONE => [] | SOME s => [label ^ "=" ^ s]
    val override = override_path (#overrides project) name
    val override_git_value = override_git (#overrides project) name
    val local_path = dependency_local_path project dep
    val resolved_manifest = dependency_manifest project dep
    val source_fields =
      case source of
          GitSource {git, rev} => ["git=" ^ git, "rev=" ^ rev]
        | FromSource {from, path, manifest} => ["from=" ^ from, "path=" ^ path, "manifest=" ^ manifest]
    val fields =
      source_fields @ field "override" override @ field "override-git" override_git_value @ field "local" local_path @
      field "resolved-manifest" resolved_manifest
  in
    name ^ " [" ^ String.concatWith ", " fields ^ "]"
  end

fun override_to_string (OverridePath {name, path}) = name ^ " path -> " ^ path
  | override_to_string (OverrideGit {name, git}) = name ^ " git -> " ^ git

fun project_package ({root, artifact_root, graph_artifact_root, manifest, definition, name, members, excludes, exclude_globs, roots, root_groups, groups, action_policies, generators, ...} : t) =
  let
    val provenance =
      {snapshot = HolbuildPackageProvenance.WorkingTreeSnapshot,
       definition = HolbuildPackageProvenance.RootManifest,
       retrieval = HolbuildPackageProvenance.WorkingTreeRetrieval,
       materialization = {source_root = root, package_root = root,
                          manifest = manifest},
       origin = HolbuildPackageProvenance.RootOrigin}
  in
  Package {name = name, root = root, manifest = manifest,
           definition = definition, provenance = provenance,
           members = members, excludes = excludes, exclude_globs = exclude_globs,
           roots = roots, root_groups = root_groups, groups = groups,
           artifact_root = if artifact_root = graph_artifact_root then Path.concat(artifact_root, ".holbuild") else artifact_root,
           action_policies = action_policies,
           generators = generators}
  end

fun root_package_name project = package_name (project_package project)

fun dependency_project_with resolution (project : t) (dep as Dependency {name, source, ...}) =
  let
    val _ =
      case source of
          FromSource {from, ...} =>
            if Option.isSome (override_path (#overrides project) name) orelse
               Option.isSome (override_git (#overrides project) name) then
              die ("overrides." ^ name ^
                   " cannot override a from/path/manifest package; override its source dependency " ^
                   from ^ " instead")
            else ()
        | _ => ()
    val _ =
      case source of
          GitSource {git, rev} =>
            if hol_toolchain_dependency dep orelse Option.isSome (override_path (#overrides project) name) then ()
            else
              let val effective_git = Option.getOpt(override_git (#overrides project) name, git)
              in ignore (HolbuildGitCache.materialize {name = name, git = effective_git, rev = rev,
                                                       artifact_root = #graph_artifact_root project}) end
        | _ => ()
    val dep_root =
      case dependency_local_path_with resolution project dep of
          SOME path => path
        | NONE => die ("dependency " ^ name ^ " has no local path; add path or .holconfig.toml override")
    val dep_manifest =
      case dependency_manifest project dep of
          SOME manifest => manifest
        | NONE => die ("dependency " ^ name ^ " has no manifest")
    val parse_dep =
      if hol_toolchain_dependency dep then parse_builtin_holdir_at
      else
        (if readable dep_manifest then ()
         else die ("dependency " ^ name ^ " manifest not found: " ^ dep_manifest);
         parse_at)
    val dep_artifact_root =
      Path.concat(Path.concat(Path.concat(#graph_artifact_root project, ".holbuild"), "packages"), name)
    val dep_project = parse_dep {manifest = dep_manifest, root = dep_root, artifact_root = dep_artifact_root,
                                 graph_artifact_root = #graph_artifact_root project,
                                 local_config =
                                   HolbuildLocalConfig.for_dependency
                                     (#local_config project)}
    val declared_name = #name dep_project
    val _ =
      if declared_name = name then ()
      else die ("dependency " ^ name ^ " manifest declares project.name = " ^ declared_name)
  in
    dep_project
  end

fun dependency_project project dep = dependency_project_with standard_resolution project dep

fun resolved_hol_dependency_with (resolution as {kernel_variant} : resolution) project =
  case cached_graph_with resolution project of
      SOME {packages, hol, ...} =>
        (case List.find (fn package => package_identity package = hol) packages of
             SOME package =>
               (case HolbuildPackageProvenance.origin
                       (package_provenance package) of
                    HolbuildPackageProvenance.ImplicitHolOrigin {git, rev, ...} =>
                      SOME (Dependency
                        {name = "hol", source = GitSource {git = git, rev = rev},
                         role = HolToolchainDependency})
                  | _ => die "typed HOL graph ID has non-HOL origin")
           | NONE => die "typed HOL graph ID is not a package")
    | NONE =>
  let
    fun seen name names = List.exists (fn n => n = name) names
    fun search_project names p =
      case hol_dependency p of
          SOME dep => SOME dep
        | NONE => search_deps names p (#dependencies p)
    and search_deps names parent deps =
      case deps of
          [] => NONE
        | (dep as Dependency {name, ...}) :: rest =>
            if seen name names then search_deps names parent rest
            else
              (case search_project (name :: names) (dependency_project_with resolution parent dep) of
                   SOME hol => SOME hol
                 | NONE => search_deps (name :: names) parent rest)
  in
    search_project [] project
  end

fun resolved_hol_dependency project = resolved_hol_dependency_with standard_resolution project

fun dependency_package_with resolution artifact_parent project
      (dep as Dependency {name, source, ...}) =
  let
    val dep_project = dependency_project_with resolution project dep
    val dep_root =
      case dependency_local_path_with resolution project dep of
          SOME value => value
        | NONE => die ("dependency " ^ name ^ " has no local path")
    val dep_manifest =
      case dependency_manifest project dep of
          SOME value => value
        | NONE => die ("dependency " ^ name ^ " has no manifest")
    val artifact_root =
      Path.concat(Path.concat(Path.concat(artifact_parent, ".holbuild"), "packages"), name)
    fun declared_dependency dep_name =
      List.find (fn Dependency {name, ...} => name = dep_name)
        (#dependencies project)
    fun git_retrieval dep_name git =
      case override_path (#overrides project) dep_name of
          SOME path => HolbuildPackageProvenance.TrustedPathRetrieval {path = path}
        | NONE =>
            (case override_git (#overrides project) dep_name of
                 SOME retrieval_git =>
                   HolbuildPackageProvenance.AlternateGitRetrieval
                     {declared_git = git, retrieval_git = retrieval_git}
               | NONE => HolbuildPackageProvenance.DeclaredGitRetrieval {git = git})
    val provenance =
      case source of
          GitSource {git, rev} =>
            if hol_toolchain_dependency dep then
              {snapshot = HolbuildPackageProvenance.ToolchainSnapshot
                            {git = git, rev = rev,
                             kernel_variant = #kernel_variant resolution},
               definition = HolbuildPackageProvenance.ImplicitHolManifest,
               retrieval = HolbuildPackageProvenance.ToolchainCacheRetrieval,
               materialization = {source_root = dep_root, package_root = dep_root,
                                  manifest = dep_manifest},
               origin = HolbuildPackageProvenance.ImplicitHolOrigin
                          {git = git, rev = rev,
                           kernel_variant = #kernel_variant resolution}}
            else
              {snapshot = HolbuildPackageProvenance.GitSnapshot {git = git, rev = rev},
               definition = HolbuildPackageProvenance.DependencyManifest
                              {dependency = name},
               retrieval = git_retrieval name git,
               materialization = {source_root = dep_root, package_root = dep_root,
                                  manifest = dep_manifest},
               origin = HolbuildPackageProvenance.DependencyOrigin
                          {dependency = name}}
        | FromSource {from, path, manifest} =>
            let
              val (git, rev, role, source_root, retrieval) =
                case declared_dependency from of
                    SOME (from_dep as Dependency
                            {source = GitSource {git, rev}, role, ...}) =>
                      (git, rev, role,
                       (case dependency_local_path_with resolution project from_dep of
                            SOME value => value
                          | NONE => die ("dependency " ^ from ^ " has no local path")),
                       (case role of
                            HolToolchainDependency =>
                              HolbuildPackageProvenance.ToolchainCacheRetrieval
                          | PackageDependency => git_retrieval from git))
                  | _ => die ("validated from dependency disappeared: " ^ from)
            in
              {snapshot =
                 (case role of
                      HolToolchainDependency =>
                        HolbuildPackageProvenance.ToolchainSnapshot
                          {git = git, rev = rev,
                           kernel_variant = #kernel_variant resolution}
                    | PackageDependency =>
                        HolbuildPackageProvenance.GitSnapshot {git = git, rev = rev}),
               definition = HolbuildPackageProvenance.ShimManifest
                              {from = from, path = path, manifest = manifest},
               retrieval = retrieval,
               materialization = {source_root = source_root, package_root = dep_root,
                                  manifest = dep_manifest},
               origin = HolbuildPackageProvenance.ShimOrigin
                          {dependency = name, from = from}}
            end
  in
    (Package {name = name, root = dep_root, manifest = dep_manifest,
              definition = #definition dep_project, provenance = provenance,
              members = #members dep_project, excludes = #excludes dep_project,
              exclude_globs = #exclude_globs dep_project,
              roots = #roots dep_project, root_groups = #root_groups dep_project,
              groups = #groups dep_project, artifact_root = artifact_root,
              action_policies = #action_policies dep_project,
              generators = #generators dep_project},
     dep_project)
  end

fun dependency_package artifact_parent project dep =
  dependency_package_with standard_resolution artifact_parent project dep

fun same_dependency_source (GitSource a, GitSource b) = #git a = #git b andalso #rev a = #rev b
  | same_dependency_source (FromSource a, FromSource b) =
      #from a = #from b andalso #path a = #path b andalso #manifest a = #manifest b
  | same_dependency_source _ = false

fun packages project =
  case cached_graph_with standard_resolution project of
      SOME {packages, ...} => packages
    | NONE => die "project package graph has not been resolved"

fun describe (project : t) =
  let
    val {root, artifact_root, manifest, name, version, members, excludes, exclude_globs, roots, root_groups, groups, root_tactic_timeouts, dependencies,
         overrides, local_build_excludes, local_build_exclude_globs, local_build_jobs, build_tactic_timeout, run_heap, run_loads, heaps, action_policies, generators, ...} = project
    fun opt label value =
      case value of NONE => () | SOME s => print (label ^ s ^ "\n")
    fun describe_package (package as Package {name, root, manifest, artifact_root,
                                              provenance, ...}) =
      (print ("package: " ^ name ^ " [root=" ^ root ^ ", manifest=" ^ manifest ^
              ", artifact-root=" ^ artifact_root ^ "]\n");
       print ("package-identity: " ^ name ^ " " ^ package_identity package ^ "\n");
       print ("package-origin: " ^ name ^ " " ^
              HolbuildPackageProvenance.origin_text
                (HolbuildPackageProvenance.origin provenance) ^ "\n");
       print ("package-snapshot: " ^ name ^ " " ^
              HolbuildPackageProvenance.snapshot_text (#snapshot provenance) ^ "\n");
       print ("package-definition-provenance: " ^ name ^ " " ^
              HolbuildPackageProvenance.definition_text (#definition provenance) ^ "\n");
       print ("package-retrieval: " ^ name ^ " " ^
              HolbuildPackageProvenance.retrieval_text (#retrieval provenance) ^ "\n");
       print ("package-source-root: " ^ name ^ " " ^
              HolbuildPackageProvenance.source_root provenance ^ "\n");
       print ("package-root: " ^ name ^ " " ^ root ^ "\n"))
    fun describe_group group =
      print ("group: " ^ group_name group ^
             " include=" ^ String.concatWith ", " (group_includes group) ^
             " include_globs=" ^ String.concatWith ", " (group_include_globs group) ^
             " exclude=" ^ String.concatWith ", " (group_excludes group) ^
             " exclude_globs=" ^ String.concatWith ", " (group_exclude_globs group) ^
             " allow_empty=" ^ (if group_allow_empty group then "true" else "false") ^ "\n")
  in
    print ("manifest: " ^ manifest ^ "\n");
    print ("root: " ^ root ^ "\n");
    print ("artifact-root: " ^ artifact_root ^ "\n");
    print ("name: " ^ name ^ "\n");
    opt "version: " version;
    print ("package-definition-id: " ^
           HolbuildPackageDefinition.canonical_id (#definition project) ^ "\n");
    print ("metadata-id: " ^
           HolbuildPackageDefinition.metadata_id (#definition project) ^ "\n");
    print ("source-definition-id: " ^
           HolbuildPackageDefinition.source_definition_id (#definition project) ^ "\n");
    print ("entrypoint-definition-id: " ^
           HolbuildPackageDefinition.entrypoint_definition_id (#definition project) ^ "\n");
    print ("dependency-definition-id: " ^
           HolbuildPackageDefinition.dependency_definition_id (#definition project) ^ "\n");
    print ("runtime-definition-id: " ^
           HolbuildPackageDefinition.runtime_definition_id (#definition project) ^ "\n");
    print ("generator-definition-id: " ^
           HolbuildPackageDefinition.generator_definition_id (#definition project) ^ "\n");
    print ("action-dependency-policy-id: " ^
           HolbuildPackageDefinition.action_dependency_policy_id (#definition project) ^ "\n");
    print ("action-input-policy-id: " ^
           HolbuildPackageDefinition.action_input_policy_id (#definition project) ^ "\n");
    print ("action-execution-policy-id: " ^
           HolbuildPackageDefinition.action_execution_policy_id (#definition project) ^ "\n");
    print ("members: " ^ String.concatWith ", " members ^ "\n");
    print ("exclude: " ^ String.concatWith ", " excludes ^ "\n");
    print ("exclude_globs: " ^ String.concatWith ", " exclude_globs ^ "\n");
    print ("roots: " ^ String.concatWith ", " roots ^ "\n");
    print ("root_groups: " ^ String.concatWith ", " root_groups ^ "\n");
    List.app describe_group groups;
    List.app (fn {root, timeout} =>
                print ("root tactic_timeout: " ^ root ^ " = " ^
                       (case timeout of NONE => "none" | SOME t => Real.toString t) ^ "\n"))
             root_tactic_timeouts;
    List.app describe_package (packages project);
    List.app (fn dep => print ("dependency: " ^ dependency_to_string project dep ^ "\n")) dependencies;
    List.app (fn override => print ("override: " ^ override_to_string override ^ "\n")) overrides;
    Option.app (fn jobs => print ("local build.jobs: " ^ Int.toString jobs ^ "\n")) local_build_jobs;
    Option.app (fn t => print ("build.tactic_timeout: " ^ Real.toString t ^ "\n")) build_tactic_timeout;
    opt "run.heap: " run_heap;
    print ("run.loads: " ^ String.concatWith ", " run_loads ^ "\n");
    List.app (fn heap => print ("heap: " ^ heap_to_string heap ^ "\n")) heaps;
    List.app (fn generator => print ("generate: " ^ generator_name generator ^ "\n")) generators;
    List.app (fn policy => print ("action: " ^ action_policy_logical policy ^ "\n")) action_policies
  end

end
