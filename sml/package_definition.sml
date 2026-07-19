structure HolbuildPackageDefinition =
struct

open HolbuildManifestUtil

(* This is the typed, path-normalized semantic model of one logical package.
   The external table is still named [project]; #110 may change that syntax when
   one repository manifest can define multiple logical packages. *)

datatype heap_kind = HeapImage | ExecutableImage of {main : string}

datatype heap =
  Heap of {name : string, output : string, objects : string list,
           kind : heap_kind}

type root_tactic_timeout = {root : string, timeout : real option}

datatype extra_input = ExtraInput of {path : string}

datatype action_policy =
  ActionPolicy of
    { logical : string,
      deps : string list,
      loads : string list,
      extra_inputs : extra_input list,
      impure : bool,
      cache : bool,
      always_reexecute : bool }

datatype generator =
  Generator of
    { name : string,
      command : string list,
      inputs : string list,
      outputs : string list,
      deps : string list }

datatype group =
  Group of
    { name : string,
      includes : string list,
      include_globs : string list,
      excludes : string list,
      exclude_globs : string list,
      allow_empty : bool }

datatype dependency_source =
    GitSource of {git : string, rev : string}
  | FromSource of {from : string, path : string, manifest : string}

datatype dependency_role = PackageDependency | HolToolchainDependency

datatype dependency =
  Dependency of
    {name : string, source : dependency_source, role : dependency_role}

(* Parsed committed semantics only. Filesystem roots, artifact locations,
   source acquisition, local overrides, and invocation configuration belong to
   resolved package/project state rather than this definition. *)
type package_metadata = {name : string, version : string option}
type source_definition =
  {members : string list, excludes : string list, exclude_globs : string list}
type entrypoint_definition =
  {roots : string list, root_groups : string list, groups : group list,
   root_tactic_timeouts : root_tactic_timeout list}
type runtime_definition =
  {run_heap : string option, run_loads : string list, heaps : heap list}
type action_dependency_policy =
  {logical : string, deps : string list, loads : string list}
type action_input_policy = {logical : string, extra_inputs : extra_input list}
type action_execution_policy =
  {logical : string, impure : bool, cache : bool, always_reexecute : bool}
type generator_definition = generator

type t =
  { metadata : package_metadata,
    sources : source_definition,
    entrypoints : entrypoint_definition,
    dependencies : dependency list,
    runtime : runtime_definition,
    actions : action_policy list,
    generators : generator_definition list }

type metadata = package_metadata
type runtime =
  {run_heap : string option, run_loads : string list, heaps : heap list,
   generators : generator list}
type compatibility = {minimum_version : string option}

fun is_hex c = Char.isDigit c orelse (#"a" <= c andalso c <= #"f")
fun validate_git_rev rev =
  if size rev = 40 andalso List.all is_hex (String.explode rev) then ()
  else die ("git dependency rev must be a full 40-character lowercase hex commit: " ^ rev)

fun parse_metadata table : metadata =
  let
    val project =
      case table_field table ["project"] of
          NONE => die "holproject.toml must declare [project] name"
        | SOME value => value
    val name =
      case string_field project "name" of
          NONE => die "holproject.toml must declare [project] name"
        | SOME "" => die "project.name must not be empty"
        | SOME value =>
            (require_safe_materialized_dependency_name "project.name" value;
             value)
  in
    {name = name, version = string_field project "version"}
  end

fun validate_dependency_table (name, table) =
  let
    val context = "dependencies." ^ name
    val path = string_field table "path"
    val manifest = string_field table "manifest"
    val git = string_field table "git"
    val rev = string_field table "rev"
    val from = string_field table "from"
  in
    require_known_fields context ["git", "rev", "from", "path", "manifest"] table;
    case (git, rev, from, path, manifest) of
        (SOME _, SOME rev, NONE, NONE, NONE) => validate_git_rev rev
      | (SOME _, NONE, _, _, _) => die (context ^ " with git requires rev")
      | (NONE, SOME _, _, _, _) => die (context ^ " with rev requires git")
      | (SOME _, SOME _, _, _, _) => die (context ^ " git dependency may only contain git and rev")
      | (NONE, NONE, SOME from, SOME path, SOME manifest) =>
          (require_safe_materialized_dependency_name (context ^ ".from") from;
           ignore (package_relative_path (context ^ ".path") path);
           ignore (package_relative_path (context ^ ".manifest") manifest))
      | (NONE, NONE, SOME _, _, _) => die (context ^ " with from requires path and manifest")
      | (NONE, NONE, NONE, SOME _, _) => die (context ^ " path dependencies are not supported")
      | (NONE, NONE, NONE, NONE, SOME _) => die (context ^ " manifest requires from")
      | (NONE, NONE, NONE, NONE, NONE) => die (context ^ " must specify either git/rev or from/path/manifest")
  end

fun parse_dependency (name, table) =
  let
    val source =
      case (string_field table "git", string_field table "rev", string_field table "from",
            string_field table "path", string_field table "manifest") of
          (SOME git, SOME rev, NONE, NONE, NONE) => GitSource {git = git, rev = rev}
        | (NONE, NONE, SOME from, SOME path, SOME manifest) =>
            FromSource {from = from, path = path, manifest = manifest}
        | _ => die ("invalid dependency form for dependencies." ^ name)
    val role = if name = "hol" then HolToolchainDependency else PackageDependency
  in Dependency {name = name, source = source, role = role} end

fun dependency_name (Dependency {name, ...}) = name

fun validate_dependency_refs deps =
  let
    fun source_for name =
      Option.map (fn Dependency {source, ...} => source)
        (List.find (fn dep => dependency_name dep = name) deps)
    fun one (Dependency {name, source = FromSource {from, ...}, ...}) =
          (case source_for from of
               SOME (GitSource _) => ()
             | SOME _ => die ("dependencies." ^ name ^ " from dependency must refer to a direct git dependency: " ^ from)
             | NONE => die ("dependencies." ^ name ^ " from dependency is unknown: " ^ from))
      | one (Dependency {name, source = GitSource _, ...}) =
          require_safe_materialized_dependency_name ("dependencies." ^ name) name
  in List.app one deps end

fun parse_dependencies table =
  let
    val entries = named_table_entries table ["dependencies"]
    val _ = List.app validate_dependency_table entries
    val dependencies = map parse_dependency entries
    val _ = validate_dependency_refs dependencies
  in dependencies end

fun parse_image_entry section kind value =
  case value of
      TOML.TABLE table =>
        let
          val name = case string_field table "name" of SOME s => s | NONE => die ("[[" ^ section ^ "]] entry requires name")
          val output = case string_field table "output" of SOME s => s | NONE => die ("[[" ^ section ^ "]] entry requires output")
        in Heap {name = name, output = output, objects = string_array_field table "objects", kind = kind table} end
    | _ => die (section ^ " entries must be tables")

fun image_entries table section parse =
  case lookup table [section] of
      NONE => []
    | SOME (TOML.ARRAY values) => map parse values
    | SOME _ => die (section ^ " must be an array of tables")

fun parse_heaps table =
  let
    val heaps =
      image_entries table "heap" (parse_image_entry "heap" (fn _ => HeapImage)) @
      image_entries table "executable"
        (parse_image_entry "executable" (fn value =>
          ExecutableImage {main = Option.getOpt(string_field value "main", "main")}))
    fun name_of (Heap {name, ...}) = name
    fun loop _ [] = ()
      | loop names (heap :: rest) =
          let val name = name_of heap
          in if List.exists (fn old => old = name) names then
               die ("duplicate heap/executable target name: " ^ name)
             else loop (name :: names) rest
          end
  in loop [] heaps; heaps end

fun parse_generator value =
  case value of
      TOML.TABLE table =>
        let
          val name = case string_field table "name" of SOME s => s | NONE => die "[[generate]] entry requires name"
          val command = required_string_array_field ("generate." ^ name) table "command"
          val inputs = package_relative_paths ("generate." ^ name ^ ".inputs") (string_array_field table "inputs")
          val outputs = package_relative_paths ("generate." ^ name ^ ".outputs") (required_string_array_field ("generate." ^ name) table "outputs")
          val deps = string_array_field table "deps"
          val _ = if name = "" then die "generate.name must not be empty" else ()
          val _ = if null command then die ("generate." ^ name ^ ".command must not be empty") else ()
          val _ = if null outputs then die ("generate." ^ name ^ ".outputs must not be empty") else ()
        in Generator {name = name, command = command, inputs = inputs, outputs = outputs, deps = deps} end
    | _ => die "generate entries must be tables"

fun parse_generators table =
  case lookup table ["generate"] of
      NONE => []
    | SOME (TOML.ARRAY values) => map parse_generator values
    | SOME _ => die "generate must be an array of tables"

fun parse_runtime table : runtime =
  let val run = table_field table ["run"]
  in
    {run_heap = Option.mapPartial (fn value => string_field value "heap") run,
     run_loads = case run of NONE => [] | SOME value => string_array_field value "loads",
     heaps = parse_heaps table, generators = parse_generators table}
  end

fun validate_action_table (logical, table) =
  require_known_fields ("actions." ^ logical)
    ["deps", "loads", "extra_inputs", "extra_deps", "impure", "cache",
     "always_reexecute"] table

fun action_entries table = named_table_entries table ["actions"]
fun validate_actions table = List.app validate_action_table (action_entries table)

fun parse_action_policy (logical, table) =
  let
    fun extra field path =
      let
        val context = "actions." ^ logical ^ "." ^ field
        val relative = package_relative_path context path
      in
        ExtraInput {path = relative}
      end
    val extra_inputs =
      map (extra "extra_inputs") (string_array_field table "extra_inputs")
    val extra_deps =
      map (extra "extra_deps") (string_array_field table "extra_deps")
  in
    ActionPolicy
      {logical = logical,
       deps = string_array_field table "deps",
       loads = string_array_field table "loads",
       extra_inputs = extra_inputs @ extra_deps,
       impure = Option.getOpt(bool_at table ["impure"], false),
       cache = Option.getOpt(bool_at table ["cache"], true),
       always_reexecute =
         Option.getOpt(bool_at table ["always_reexecute"], false)}
  end

fun parse_action_policies table =
  (validate_actions table; map parse_action_policy (action_entries table))

fun group_name_char c =
  (#"A" <= c andalso c <= #"Z") orelse
  (#"a" <= c andalso c <= #"z") orelse
  (#"0" <= c andalso c <= #"9") orelse
  c = #"_" orelse c = #"-"

fun valid_group_name name =
  size name > 0 andalso List.all group_name_char (String.explode name)

fun require_group_name name =
  if valid_group_name name then ()
  else die ("invalid group name \"" ^ name ^ "\": use [A-Za-z0-9_-]")

fun strip_group_reference token =
  if size token > 0 andalso String.sub(token, 0) = #"@" then
    let val name = String.extract(token, 1, NONE)
    in
      if valid_group_name name then name
      else die ("invalid group reference \"" ^ token ^ "\"")
    end
  else
    (require_group_name token; token)

fun is_group_reference token =
  size token > 0 andalso String.sub(token, 0) = #"@"

fun build_tactic_timeout_from_manifest build =
  case build of
      NONE => NONE
    | SOME t => tactic_timeout_at "build.tactic_timeout" t ["tactic_timeout"]

fun root_tactic_timeouts_from_manifest build =
  case build of
      NONE => []
    | SOME t =>
        case table_field t ["root_tactic_timeouts"] of
            NONE => []
          | SOME entries =>
              map (fn (root, value) =>
                      {root = package_relative_path "build.root_tactic_timeouts" root,
                       timeout = tactic_timeout_value ("build.root_tactic_timeouts." ^ root) value})
                  entries

fun glob_match pattern text =
  let
    val pn = size pattern
    val tn = size text
    fun match p t =
      if p = pn then t = tn
      else
        case String.sub(pattern, p) of
            #"*" => match (p + 1) t orelse (t < tn andalso match p (t + 1))
          | #"?" => t < tn andalso match (p + 1) (t + 1)
          | c => t < tn andalso c = String.sub(text, t) andalso match (p + 1) (t + 1)
  in
    match 0 0
  end

fun path_matches paths globs rel =
  List.exists (fn path => rel = path orelse String.isPrefix (path ^ "/") rel) paths orelse
  List.exists (fn pattern => glob_match pattern rel) globs

fun group_matches_root root (Group {includes, include_globs, excludes, exclude_globs, ...}) =
  path_matches includes include_globs root andalso
  not (path_matches excludes exclude_globs root)

fun group_named groups name =
  List.find (fn Group {name = group_name, ...} => group_name = name) groups

fun referenced_root_group_names roots root_groups =
  root_groups @ map strip_group_reference (List.filter is_group_reference roots)

fun validate_root_tactic_timeouts roots root_groups groups timeouts =
  let
    val referenced_groups = referenced_root_group_names roots root_groups
    fun root_in_group root name =
      case group_named groups name of
          NONE => false
        | SOME group => group_matches_root root group
    fun known_root root =
      member root roots orelse
      List.exists (root_in_group root) referenced_groups
  in
    List.app
      (fn {root, ...} =>
          if is_group_reference root then
            die ("build.root_tactic_timeouts must reference a concrete root, not a group: " ^ root)
          else if known_root root then ()
          else die ("build.root_tactic_timeouts references unknown root: " ^ root))
      timeouts
  end

fun build_roots_from_manifest build_strings =
  let
    val roots = build_strings "roots" []
    fun validate root =
      if is_group_reference root then ()
      else ignore (package_relative_path "build.roots" root)
  in
    List.app validate roots;
    roots
  end

fun build_root_groups_from_manifest build_strings =
  map strip_group_reference (build_strings "root_groups" [])

fun parse_group (name, table) =
  let
    val _ = require_group_name name
    val includes = map (concrete_package_relative_path ("build.groups." ^ name ^ ".include"))
                   (string_array_field table "include")
    val include_globs = package_relative_paths ("build.groups." ^ name ^ ".include_globs")
                        (string_array_field table "include_globs")
    val excludes = map (concrete_package_relative_path ("build.groups." ^ name ^ ".exclude"))
                   (string_array_field table "exclude")
    val exclude_globs = package_relative_paths ("build.groups." ^ name ^ ".exclude_globs")
                        (string_array_field table "exclude_globs")
    val allow_empty = Option.getOpt(bool_at table ["allow_empty"], false)
    val _ =
      if null includes andalso null include_globs then
        die ("group " ^ name ^ ": needs a non-empty include or include_globs")
      else ()
  in
    Group {name = name, includes = includes, include_globs = include_globs,
           excludes = excludes, exclude_globs = exclude_globs, allow_empty = allow_empty}
  end

fun groups_at table = map parse_group (named_table_entries table ["build", "groups"])

fun validate_root_groups root_groups groups =
  let
    fun name_of (Group {name, ...}) = name
    val names = map name_of groups
  in
    List.app
      (fn name =>
          if member name names then ()
          else die ("unknown group in build.root_groups: " ^ name))
      root_groups
  end

type build_definition =
  {members : string list, excludes : string list, exclude_globs : string list,
   roots : string list, root_groups : string list, groups : group list,
   root_tactic_timeouts : root_tactic_timeout list,
   tactic_timeout : real option}

fun parse_build table : build_definition =
  let
    val build = table_field table ["build"]
    fun build_strings name default =
      case build of NONE => default
        | SOME value => Option.getOpt(string_array_field_opt value name, default)
    val members = package_relative_paths "build.members" (build_strings "members" ["."])
    val excludes = concrete_excludes "build.exclude" (build_strings "exclude" [])
    val exclude_globs =
      package_relative_paths "build.exclude_globs" (build_strings "exclude_globs" [])
    val roots = build_roots_from_manifest build_strings
    val root_groups = build_root_groups_from_manifest build_strings
    val groups = groups_at table
    val timeouts = root_tactic_timeouts_from_manifest build
    val _ = validate_root_groups root_groups groups
    val _ = validate_root_tactic_timeouts roots root_groups groups timeouts
  in
    {members = members, excludes = excludes, exclude_globs = exclude_globs,
     roots = roots, root_groups = root_groups, groups = groups,
     root_tactic_timeouts = timeouts,
     tactic_timeout = build_tactic_timeout_from_manifest build}
  end

fun validate_compatibility table =
  let
    val holbuild =
      case table_field table ["holbuild"] of
          NONE => []
        | SOME value => value
    val _ = require_known_fields "holbuild"
              ["schema", "minimum_version", "required_version"] holbuild
    val _ =
      case lookup holbuild ["required_version"] of
          NONE => ()
        | SOME _ => die "holbuild.required_version is not supported; use holbuild.minimum_version"
    val _ =
      case int_at holbuild ["schema"] of
          NONE => ()
        | SOME n =>
            if n = IntInf.fromInt 2 then ()
            else die "only legacy holproject schema 2 is supported"
    val minimum_version = string_at holbuild ["minimum_version"]
    val _ =
      case minimum_version of
          NONE => ()
        | SOME "" => die "holbuild.minimum_version must not be empty"
        | SOME value =>
            (HolbuildVersion.require_at_least value
             handle HolbuildVersion.Error msg =>
               die ("invalid holbuild.minimum_version: " ^ msg))
  in
    {minimum_version = minimum_version}
  end

fun validate_generate_entry value =
  case value of
      TOML.TABLE generate =>
        require_known_fields "generate"
          ["name", "command", "inputs", "outputs", "deps"] generate
    | _ => die "generate entries must be tables"

fun validate_groups_table table =
  let
    fun one (name, value) =
      (require_group_name name;
       case value of
           TOML.TABLE group =>
             require_known_fields ("build.groups." ^ name)
               ["include", "include_globs", "exclude", "exclude_globs",
                "allow_empty"] group
         | _ => die ("build.groups." ^ name ^ " must be a table"))
  in
    case lookup table ["build", "groups"] of
        NONE => ()
      | SOME (TOML.TABLE groups) => List.app one groups
      | SOME _ => die "build.groups must be a table"
  end

fun validate_image_entries table section fields =
  case lookup table [section] of
      NONE => ()
    | SOME (TOML.ARRAY values) =>
        List.app
          (fn TOML.TABLE image => require_known_fields section fields image
            | _ => die (section ^ " entries must be tables")) values
    | SOME _ => die (section ^ " must be an array of tables")

fun validate_manifest table =
  (require_known_fields "holproject.toml"
     ["holbuild", "project", "build", "dependencies", "run", "heap",
      "executable", "actions", "generate"] table;
   Option.app (require_known_fields "project" ["name", "version"])
     (table_field table ["project"]);
   Option.app
     (require_known_fields "build"
       ["members", "exclude", "exclude_globs", "roots", "root_groups",
        "groups", "tactic_timeout", "root_tactic_timeouts"])
     (table_field table ["build"]);
   Option.app (require_known_fields "run" ["heap", "loads"])
     (table_field table ["run"]);
   ignore (validate_compatibility table);
   List.app validate_dependency_table
     (named_table_entries table ["dependencies"]);
   validate_actions table;
   validate_groups_table table;
   (case lookup table ["generate"] of
        NONE => ()
      | SOME (TOML.ARRAY values) => List.app validate_generate_entry values
      | SOME _ => die "generate must be an array of tables");
   validate_image_entries table "heap" ["name", "output", "objects"];
   validate_image_entries table "executable"
     ["name", "output", "objects", "main"])

type parsed =
  {definition : t, compatibility : compatibility,
   tactic_timeout : real option}

val parsed_manifest_count = ref 0
fun manifest_parse_count () = !parsed_manifest_count

fun parse_table table : parsed =
  let
    val _ = parsed_manifest_count := !parsed_manifest_count + 1
    val _ = validate_manifest table
    val compatibility = validate_compatibility table
    val {name, version} = parse_metadata table
    val {members, excludes, exclude_globs, roots, root_groups, groups,
         root_tactic_timeouts, tactic_timeout} = parse_build table
    val dependencies = parse_dependencies table
    val {run_heap, run_loads, heaps, generators} = parse_runtime table
    val action_policies = parse_action_policies table
    val definition =
      {metadata = {name = name, version = version},
       sources = {members = members, excludes = excludes,
                  exclude_globs = exclude_globs},
       entrypoints = {roots = roots, root_groups = root_groups, groups = groups,
                      root_tactic_timeouts = root_tactic_timeouts},
       dependencies = dependencies,
       runtime = {run_heap = run_heap, run_loads = run_loads, heaps = heaps},
       actions = action_policies,
       generators = generators}
  in
    {definition = definition, compatibility = compatibility,
     tactic_timeout = tactic_timeout}
  end

fun bool_text value = if value then "true" else "false"
fun atom text = Int.toString (size text) ^ ":" ^ text
fun optional f NONE = "none"
  | optional f (SOME value) = "some(" ^ f value ^ ")"
fun sequence f values =
  "[" ^ String.concatWith "," (map (fn value => atom (f value)) values) ^ "]"
fun string_sequence values = sequence (fn value => value) values
fun fields values = String.concatWith "|" (map atom values)

fun insert_by key value [] = [value]
  | insert_by key value (first :: rest) =
      if String.compare(key value, key first) = LESS then value :: first :: rest
      else first :: insert_by key value rest
fun sort_by key values = List.foldl (fn (value, acc) => insert_by key value acc) [] values

fun extra_input_text (ExtraInput {path}) = path
fun group_key (Group {name, ...}) = name
fun group_text (Group {name, includes, include_globs, excludes, exclude_globs,
                       allow_empty}) =
  fields [name, string_sequence includes, string_sequence include_globs,
          string_sequence excludes, string_sequence exclude_globs,
          bool_text allow_empty]
fun dependency_key (Dependency {name, ...}) = name
fun dependency_text (Dependency {name, source, ...}) =
  fields [name,
    case source of
        GitSource {git, rev} => fields ["git", git, rev]
      | FromSource {from, path, manifest} =>
          fields ["from", from, path, manifest]]
fun heap_key (Heap {name, ...}) = name
fun heap_text (Heap {name, output, objects, kind}) =
  fields [name, output, string_sequence objects,
    case kind of HeapImage => "heap"
      | ExecutableImage {main} => fields ["executable", main]]
fun action_key (ActionPolicy {logical, ...}) = logical
fun action_dependency_policy (ActionPolicy {logical, deps, loads, ...}) =
  {logical = logical, deps = deps, loads = loads} : action_dependency_policy
fun action_input_policy (ActionPolicy {logical, extra_inputs, ...}) =
  {logical = logical, extra_inputs = extra_inputs} : action_input_policy
fun action_execution_policy
      (ActionPolicy {logical, impure, cache, always_reexecute, ...}) =
  {logical = logical, impure = impure, cache = cache,
   always_reexecute = always_reexecute} : action_execution_policy
fun action_dependency_text ({logical, deps, loads} : action_dependency_policy) =
  fields [logical, string_sequence deps, string_sequence loads]
fun action_input_text ({logical, extra_inputs} : action_input_policy) =
  fields [logical, sequence extra_input_text extra_inputs]
fun action_execution_text
      ({logical, impure, cache, always_reexecute} : action_execution_policy) =
  fields [logical, bool_text impure, bool_text cache, bool_text always_reexecute]
fun generator_text (Generator {name, command, inputs, outputs, deps}) =
  fields [name, string_sequence command, string_sequence inputs,
          string_sequence outputs, string_sequence deps]

fun metadata_text ({name, version} : package_metadata) =
  fields ["package-metadata-v1", name, optional atom version]
fun source_definition_text ({members, excludes, exclude_globs} : source_definition) =
  fields ["source-definition-v1", string_sequence members,
          string_sequence excludes, string_sequence exclude_globs]
fun entrypoint_definition_text
      ({roots, root_groups, groups, root_tactic_timeouts} : entrypoint_definition) =
  let
    fun timeout_key ({root, ...} : root_tactic_timeout) = root
    fun timeout_text ({root, timeout} : root_tactic_timeout) =
      fields [root, optional Real.toString timeout]
    val timeouts = sort_by timeout_key root_tactic_timeouts
  in
    fields ["entrypoint-definition-v1", string_sequence roots,
            string_sequence root_groups,
            sequence group_text (sort_by group_key groups),
            sequence timeout_text timeouts]
  end
fun dependency_definition_text dependencies =
  fields ["dependency-definition-v1",
          sequence dependency_text (sort_by dependency_key dependencies)]
fun runtime_definition_text ({run_heap, run_loads, heaps} : runtime_definition) =
  fields ["runtime-definition-v1", optional atom run_heap,
          string_sequence run_loads, sequence heap_text (sort_by heap_key heaps)]
fun action_dependency_policy_text actions =
  fields ["action-dependency-policy-v1",
          sequence action_dependency_text
            (map action_dependency_policy (sort_by action_key actions))]
fun action_input_policy_text actions =
  fields ["action-input-policy-v1",
          sequence action_input_text
            (map action_input_policy (sort_by action_key actions))]
fun action_execution_policy_text actions =
  fields ["action-execution-policy-v1",
          sequence action_execution_text
            (map action_execution_policy (sort_by action_key actions))]
fun generator_definition_text generators =
  fields ["generator-definition-v1", sequence generator_text generators]

fun content_text (definition : t) =
  fields ["package-content-v1",
          source_definition_text (#sources definition),
          entrypoint_definition_text (#entrypoints definition),
          dependency_definition_text (#dependencies definition),
          runtime_definition_text (#runtime definition),
          action_dependency_policy_text (#actions definition),
          action_input_policy_text (#actions definition),
          action_execution_policy_text (#actions definition),
          generator_definition_text (#generators definition)]

fun canonical_text (definition : t) =
  fields ["package-definition-v1", metadata_text (#metadata definition),
          source_definition_text (#sources definition),
          entrypoint_definition_text (#entrypoints definition),
          dependency_definition_text (#dependencies definition),
          runtime_definition_text (#runtime definition),
          action_dependency_policy_text (#actions definition),
          action_input_policy_text (#actions definition),
          action_execution_policy_text (#actions definition),
          generator_definition_text (#generators definition)]
fun canonical_id definition = HolbuildHash.string_sha256 (canonical_text definition)
fun content_id definition = HolbuildHash.string_sha256 (content_text definition)
fun metadata_id (definition : t) =
  HolbuildHash.string_sha256 (metadata_text (#metadata definition))
fun source_definition_id (definition : t) =
  HolbuildHash.string_sha256 (source_definition_text (#sources definition))
fun entrypoint_definition_id (definition : t) =
  HolbuildHash.string_sha256 (entrypoint_definition_text (#entrypoints definition))
fun dependency_definition_id (definition : t) =
  HolbuildHash.string_sha256
    (dependency_definition_text (#dependencies definition))
fun runtime_definition_id (definition : t) =
  HolbuildHash.string_sha256 (runtime_definition_text (#runtime definition))
fun generator_definition_id (definition : t) =
  HolbuildHash.string_sha256
    (generator_definition_text (#generators definition))
fun action_dependency_policy_id (definition : t) =
  HolbuildHash.string_sha256 (action_dependency_policy_text (#actions definition))
fun action_input_policy_id (definition : t) =
  HolbuildHash.string_sha256 (action_input_policy_text (#actions definition))
fun action_execution_policy_id (definition : t) =
  HolbuildHash.string_sha256 (action_execution_policy_text (#actions definition))

fun make (definition : t) = definition
fun metadata (definition : t) = #metadata definition
fun sources (definition : t) = #sources definition
fun entrypoints (definition : t) = #entrypoints definition
fun runtime (definition : t) = #runtime definition
fun actions (definition : t) = #actions definition
fun generators (definition : t) = #generators definition
fun name definition = #name (metadata definition)
fun version definition = #version (metadata definition)
fun dependencies (definition : t) = #dependencies definition

end
