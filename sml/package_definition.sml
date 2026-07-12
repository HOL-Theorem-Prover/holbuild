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
  { name : string option,
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

type metadata = {name : string option, version : string option}
type runtime =
  {run_heap : string option, run_loads : string list, heaps : heap list,
   generators : generator list}
type compatibility = {schema : int}

fun is_hex c = Char.isDigit c orelse (#"a" <= c andalso c <= #"f")
fun validate_git_rev rev =
  if size rev = 40 andalso List.all is_hex (String.explode rev) then ()
  else die ("git dependency rev must be a full 40-character lowercase hex commit: " ^ rev)

fun parse_metadata table : metadata =
  case table_field table ["project"] of
      NONE => {name = NONE, version = NONE}
    | SOME project =>
        let
          val name =
            Option.map
              (fn value =>
                (require_safe_materialized_dependency_name "project.name" value; value))
              (string_field project "name")
        in {name = name, version = string_field project "version"} end

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
      if OS.Path.isAbsolute path then
        die ("actions." ^ logical ^ "." ^ field ^
             " must be package-root-relative: " ^ path)
      else ExtraInput {path = path, absolute_path = OS.Path.concat(root, path)}
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

fun schema_version table =
  case table_field table ["holbuild"] of
      NONE => die "holproject.toml must declare [holbuild] schema = 2"
    | SOME holbuild =>
        case int_at holbuild ["schema"] of
            NONE => die "holproject.toml must declare [holbuild] schema = 2"
          | SOME n =>
              if n = IntInf.fromInt 2 then 2
              else die "only holproject schema 2 is supported"

fun version_field_at holbuild name =
  case string_at holbuild [name] of
      NONE => NONE
    | SOME "" => NONE
    | SOME text => SOME (name, text)

fun configured_required_version holbuild =
  case (lookup holbuild ["minimum_version"], lookup holbuild ["required_version"]) of
      (SOME _, SOME _) => die "holbuild.minimum_version and holbuild.required_version may not both be set"
    | _ =>
        (case (version_field_at holbuild "minimum_version",
               version_field_at holbuild "required_version") of
             (NONE, NONE) => NONE
           | (SOME version, NONE) => SOME version
           | (NONE, SOME version) => SOME version
           | (SOME _, SOME _) => raise Fail "unreachable version field state")

fun validate_required_version holbuild =
  case configured_required_version holbuild of
      NONE => ()
    | SOME (name, required) =>
        (HolbuildVersion.require_at_least required
         handle HolbuildVersion.Error msg =>
           die ("invalid holbuild." ^ name ^ ": " ^ msg))

fun validate_compatibility table =
  let
    val holbuild =
      case table_field table ["holbuild"] of
          NONE => die "holproject.toml must declare [holbuild] schema = 2"
        | SOME value => value
    val _ = require_known_fields "holbuild"
              ["schema", "minimum_version", "required_version"] holbuild
    val schema = schema_version table
    val _ = validate_required_version holbuild
  in
    {schema = schema}
  end

fun make (definition : t) = definition
fun name (definition : t) = #name definition
fun version (definition : t) = #version definition
fun dependencies (definition : t) = #dependencies definition

end
