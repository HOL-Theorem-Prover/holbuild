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

datatype extra_input =
  ExtraInput of {path : string, absolute_path : string}

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

datatype dependency =
  Dependency of {name : string, source : dependency_source}

(* Parsed committed semantics only. Filesystem roots, artifact locations,
   source acquisition, local overrides, and invocation configuration belong to
   resolved package/project state rather than this definition. *)
type t =
  { name : string,
    version : string option,
    members : string list,
    excludes : string list,
    exclude_globs : string list,
    roots : string list,
    root_groups : string list,
    groups : group list,
    root_tactic_timeouts : root_tactic_timeout list,
    dependencies : dependency list,
    run_heap : string option,
    run_loads : string list,
    heaps : heap list,
    action_policies : action_policy list,
    generators : generator list }

type metadata = {name : string, version : string option}
type runtime =
  {run_heap : string option, run_loads : string list, heaps : heap list,
   generators : generator list}
type compatibility = {minimum_version : string}

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
  in Dependency {name = name, source = source} end

fun dependency_name (Dependency {name, ...}) = name

fun validate_dependency_refs deps =
  let
    fun source_for name =
      Option.map (fn Dependency {source, ...} => source)
        (List.find (fn dep => dependency_name dep = name) deps)
    fun one (Dependency {name, source = FromSource {from, ...}}) =
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

fun parse_action_policy root (logical, table) =
  let
    fun extra field path =
      let
        val context = "actions." ^ logical ^ "." ^ field
        val relative = package_relative_path context path
      in
        ExtraInput
          {path = relative, absolute_path = OS.Path.concat(root, relative)}
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

fun parse_action_policies {table, root} =
  (validate_actions table; map (parse_action_policy root) (action_entries table))

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
          NONE => die "holproject.toml must declare [holbuild] minimum_version"
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
    val minimum_version =
      case string_at holbuild ["minimum_version"] of
          NONE => die "holproject.toml must declare holbuild.minimum_version"
        | SOME "" => die "holbuild.minimum_version must not be empty"
        | SOME value => value
    val _ =
      (HolbuildVersion.require_at_least minimum_version
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

fun parse_table {table, root} : parsed =
  let
    val _ = validate_manifest table
    val compatibility = validate_compatibility table
    val {name, version} = parse_metadata table
    val {members, excludes, exclude_globs, roots, root_groups, groups,
         root_tactic_timeouts, tactic_timeout} = parse_build table
    val dependencies = parse_dependencies table
    val {run_heap, run_loads, heaps, generators} = parse_runtime table
    val action_policies = parse_action_policies {table = table, root = root}
    val definition =
      {name = name, version = version, members = members,
       excludes = excludes, exclude_globs = exclude_globs,
       roots = roots, root_groups = root_groups, groups = groups,
       root_tactic_timeouts = root_tactic_timeouts,
       dependencies = dependencies, run_heap = run_heap, run_loads = run_loads,
       heaps = heaps, action_policies = action_policies, generators = generators}
  in
    {definition = definition, compatibility = compatibility,
     tactic_timeout = tactic_timeout}
  end

fun make (definition : t) = definition
fun name (definition : t) = #name definition
fun version (definition : t) = #version definition
fun dependencies (definition : t) = #dependencies definition

end
