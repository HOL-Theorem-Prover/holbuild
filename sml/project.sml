structure HolbuildProject =
struct

structure Path = OS.Path
structure FS = OS.FileSys

datatype heap = Heap of {name : string, output : string, objects : string list}

datatype extra_input = ExtraInput of {path : string, absolute_path : string}

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

datatype dependency =
  Dependency of
    { name : string,
      path : string option,
      manifest : string option,
      git : string option,
      rev : string option }

datatype override = Override of {name : string, path : string}

datatype local_config = LocalConfig of {overrides : override list, build_excludes : string list, build_jobs : int option, build_tactic_timeout : real option}

datatype package =
  Package of
    { name : string,
      root : string,
      manifest : string,
      members : string list,
      excludes : string list,
      roots : string list,
      artifact_root : string,
      action_policies : action_policy list,
      generators : generator list }

type t =
  { root : string,
    artifact_root : string,
    manifest : string,
    name : string option,
    version : string option,
    members : string list,
    excludes : string list,
    roots : string list,
    dependencies : dependency list,
    overrides : override list,
    local_build_excludes : string list,
    local_build_jobs : int option,
    build_tactic_timeout : real option,
    run_heap : string option,
    run_loads : string list,
    heaps : heap list,
    action_policies : action_policy list,
    generators : generator list }

exception Error of string

fun die msg = raise Error msg

val holdir_ref : string option ref = ref NONE
val source_dir_ref : string option ref = ref NONE

fun set_holdir path = holdir_ref := SOME path

fun absolute_from_cwd path =
  Path.mkAbsolute {path = path, relativeTo = FS.getDir ()}

fun set_source_dir path = source_dir_ref := SOME (absolute_from_cwd path)

fun builtin_holdir_dependency name = name = "HOLDIR"

fun builtin_holdir_manifest () = HolbuildBuiltinManifests.holdir_manifest_name

fun uses_builtin_holdir_manifest (Dependency {name, manifest = NONE, ...}) =
      builtin_holdir_dependency name
  | uses_builtin_holdir_manifest _ = false

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

fun lookup table key = TOML.lookupInTable table key

fun key_text key = String.concatWith "." key

fun table_keys table = map (fn (name, _) => name) table

fun member value values = List.exists (fn existing => existing = value) values

fun require_known_fields context allowed table =
  let val unknown = List.filter (fn name => not (member name allowed)) (table_keys table)
  in
    case unknown of
        [] => ()
      | name :: _ => die ("unknown field in " ^ context ^ ": " ^ name)
  end

fun string_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.STRING s) => SOME s
    | SOME _ => die (key_text key ^ " must be a string")

fun int_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.INTEGER n) => SOME n
    | SOME _ => die (key_text key ^ " must be an integer")

fun real_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.FLOAT r) => SOME r
    | SOME _ => die (key_text key ^ " must be a real number")

fun positive_int_field context n =
  if n >= IntInf.fromInt 1 then
    IntInf.toInt n handle Overflow => die (context ^ " is too large")
  else die (context ^ " must be a positive integer")

fun bool_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.BOOL b) => SOME b
    | SOME _ => die (key_text key ^ " must be a boolean")

fun string_array_value value =
  case value of
      TOML.ARRAY values =>
        let
          fun one v =
            case v of
                TOML.STRING s => s
              | _ => die "expected string array in holproject.toml"
        in
          SOME (map one values)
        end
    | _ => NONE

fun string_array_at table key =
  case lookup table key of
      NONE => []
    | SOME value =>
        case string_array_value value of
            SOME xs => xs
          | NONE => die (key_text key ^ " must be a string array")

fun table_field table key =
  case lookup table key of
      SOME (TOML.TABLE t) => SOME t
    | SOME _ => die (String.concatWith "." key ^ " must be a table")
    | NONE => NONE

fun string_field table name = string_at table [name]
fun string_array_field table name = string_array_at table [name]

fun env_name_char c = Char.isAlphaNum c orelse c = #"_"

fun env_value context name =
  if name = "" then die (context ^ " contains empty environment variable reference")
  else
    case OS.Process.getEnv name of
        SOME value => value
      | NONE => die (context ^ " references unset environment variable " ^ name)

fun expand_env context text =
  let
    val n = size text
    fun emit start stop acc =
      if stop <= start then acc else String.substring(text, start, stop - start) :: acc
    fun braced start acc =
      let
        fun find j =
          if j >= n then die (context ^ " contains unterminated ${...} reference")
          else if String.sub(text, j) = #"}" then j
          else find (j + 1)
        val close = find start
        val name = String.substring(text, start, close - start)
      in loop (close + 1) (env_value context name :: acc) end
    and unbraced start acc =
      let
        fun take j = if j < n andalso env_name_char (String.sub(text, j)) then take (j + 1) else j
        val stop = take start
      in
        if stop = start then loop start ("$" :: acc)
        else loop stop (env_value context (String.substring(text, start, stop - start)) :: acc)
      end
    and loop i acc =
      if i >= n then String.concat (rev acc)
      else
        case String.sub(text, i) of
            #"$" =>
              if i + 1 < n andalso String.sub(text, i + 1) = #"{" then braced (i + 2) acc
              else unbraced (i + 1) acc
          | _ =>
              let
                fun plain j = if j < n andalso String.sub(text, j) <> #"$" then plain (j + 1) else j
                val j = plain i
              in loop j (emit i j acc) end
  in loop 0 [] end

fun path_string_field context table name =
  Option.map (expand_env (context ^ "." ^ name)) (string_field table name)

fun string_array_field_opt table name =
  case lookup table [name] of
      NONE => NONE
    | SOME value =>
        case string_array_value value of
            SOME xs => SOME xs
          | NONE => die (name ^ " must be a string array")

fun required_string_array_field context table name =
  case lookup table [name] of
      NONE => die (context ^ " requires " ^ name)
    | SOME value =>
        case string_array_value value of
            SOME xs => xs
          | NONE => die (context ^ "." ^ name ^ " must be a string array")

fun package_relative_path field path =
  let
    val has_parent_component =
      List.exists (fn component => component = "..")
        (String.tokens (fn c => c = #"/" orelse c = #"\\") path)
  in
    if Path.isAbsolute path orelse has_parent_component then
      die (field ^ " must be package-root-relative: " ^ path)
    else path
  end

fun package_relative_paths field paths = map (package_relative_path field) paths

fun named_table_entries table key =
  case table_field table key of
      NONE => []
    | SOME entries =>
        let
          fun one (name, value) =
            case value of
                TOML.TABLE t => (name, t)
              | _ => die (String.concatWith "." (key @ [name]) ^ " must be a table")
        in
          map one entries
        end

fun parse_heap value =
  case value of
      TOML.TABLE table =>
        let
          val name =
            case string_field table "name" of
                SOME s => s
              | NONE => die "[[heap]] entry requires name"
          val output =
            case string_field table "output" of
                SOME s => s
              | NONE => die "[[heap]] entry requires output"
          val objects = string_array_field table "objects"
        in
          Heap {name = name, output = output, objects = objects}
        end
    | _ => die "heap entries must be tables"

fun heaps_at table =
  case lookup table ["heap"] of
      NONE => []
    | SOME (TOML.ARRAY values) => map parse_heap values
    | SOME _ => die "heap must be an array of tables"

fun parse_generator value =
  case value of
      TOML.TABLE table =>
        let
          val name =
            case string_field table "name" of
                SOME s => s
              | NONE => die "[[generate]] entry requires name"
          val command = required_string_array_field ("generate." ^ name) table "command"
          val inputs = package_relative_paths ("generate." ^ name ^ ".inputs") (string_array_field table "inputs")
          val outputs = package_relative_paths ("generate." ^ name ^ ".outputs") (required_string_array_field ("generate." ^ name) table "outputs")
          val deps = string_array_field table "deps"
          val _ = if name = "" then die "generate.name must not be empty" else ()
          val _ = if null command then die ("generate." ^ name ^ ".command must not be empty") else ()
          val _ = if null outputs then die ("generate." ^ name ^ ".outputs must not be empty") else ()
        in
          Generator {name = name, command = command, inputs = inputs, outputs = outputs, deps = deps}
        end
    | _ => die "generate entries must be tables"

fun generators_at table =
  case lookup table ["generate"] of
      NONE => []
    | SOME (TOML.ARRAY values) => map parse_generator values
    | SOME _ => die "generate must be an array of tables"

fun validate_schema table =
  case table_field table ["holbuild"] of
      NONE => ()
    | SOME holbuild =>
        (require_known_fields "holbuild" ["schema"] holbuild;
         case int_at holbuild ["schema"] of
             NONE => ()
           | SOME n =>
               if n = IntInf.fromInt 1 then ()
               else die ("unsupported holproject schema: " ^ IntInf.toString n))

fun validate_dependency_table (name, table) =
  require_known_fields ("dependencies." ^ name) ["path", "manifest", "git", "rev"] table

fun validate_action_table (logical, table) =
  require_known_fields ("actions." ^ logical)
    ["deps", "loads", "extra_inputs", "extra_deps", "impure", "cache", "always_reexecute"] table

fun validate_generate_entry value =
  case value of
      TOML.TABLE generate => require_known_fields "generate" ["name", "command", "inputs", "outputs", "deps"] generate
    | _ => die "generate entries must be tables"

fun validate_manifest_table table =
  let
    val _ = require_known_fields "holproject.toml"
              ["holbuild", "project", "build", "dependencies", "run", "heap", "actions", "generate"] table
    val _ = Option.app (require_known_fields "project" ["name", "version"])
              (table_field table ["project"])
    val _ = Option.app (require_known_fields "build" ["members", "exclude", "roots", "tactic_timeout"])
              (table_field table ["build"])
    val _ = Option.app (require_known_fields "run" ["heap", "loads"])
              (table_field table ["run"])
    val _ = List.app validate_dependency_table (named_table_entries table ["dependencies"])
    val _ = List.app validate_action_table (named_table_entries table ["actions"])
    val _ =
      case lookup table ["generate"] of
          NONE => ()
        | SOME (TOML.ARRAY values) => List.app validate_generate_entry values
        | SOME _ => die "generate must be an array of tables"
    fun validate_heap_entry value =
      case value of
          TOML.TABLE heap => require_known_fields "heap" ["name", "output", "objects"] heap
        | _ => die "heap entries must be tables"
    val _ =
      case lookup table ["heap"] of
          NONE => ()
        | SOME (TOML.ARRAY values) => List.app validate_heap_entry values
        | SOME _ => die "heap must be an array of tables"
  in
    validate_schema table
  end

fun validate_override_table (name, table) =
  require_known_fields ("overrides." ^ name) ["path"] table

fun validate_local_build_table table =
  require_known_fields ".holconfig.toml build" ["exclude", "jobs", "tactic_timeout"] table

fun validate_local_config_table table =
  (require_known_fields ".holconfig.toml" ["overrides", "build"] table;
   Option.app validate_local_build_table (table_field table ["build"]);
   List.app validate_override_table (named_table_entries table ["overrides"]))

fun parse_dependency (name, table) =
  Dependency
    { name = name,
      path = string_field table "path",
      manifest = string_field table "manifest",
      git = string_field table "git",
      rev = string_field table "rev" }

fun dependencies_at table = map parse_dependency (named_table_entries table ["dependencies"])

fun parse_action_policy root (logical, table) =
  let
    fun extra field path =
      if Path.isAbsolute path then
        die ("actions." ^ logical ^ "." ^ field ^ " must be package-root-relative: " ^ path)
      else ExtraInput {path = path, absolute_path = Path.concat(root, path)}
    val extra_inputs = map (extra "extra_inputs") (string_array_field table "extra_inputs")
    val extra_deps = map (extra "extra_deps") (string_array_field table "extra_deps")
  in
    ActionPolicy
      { logical = logical,
        deps = string_array_field table "deps",
        loads = string_array_field table "loads",
        extra_inputs = extra_inputs @ extra_deps,
        impure = Option.getOpt(bool_at table ["impure"], false),
        cache = Option.getOpt(bool_at table ["cache"], true),
        always_reexecute = Option.getOpt(bool_at table ["always_reexecute"], false) }
  end

fun action_policies_at root table =
  map (parse_action_policy root) (named_table_entries table ["actions"])

fun parse_override (name, table) =
  case path_string_field ("overrides." ^ name) table "path" of
      SOME path => Override {name = name, path = path}
    | NONE => die ("[overrides." ^ name ^ "] requires path")

fun overrides_at table = map parse_override (named_table_entries table ["overrides"])

fun local_build_excludes table =
  case table_field table ["build"] of
      NONE => []
    | SOME build => package_relative_paths ".holconfig.toml build.exclude" (string_array_field build "exclude")

fun local_build_jobs table =
  case table_field table ["build"] of
      NONE => NONE
    | SOME build => Option.map (positive_int_field ".holconfig.toml build.jobs") (int_at build ["jobs"])

fun local_build_tactic_timeout table =
  case table_field table ["build"] of
      NONE => NONE
    | SOME build => real_at build ["tactic_timeout"]

fun build_tactic_timeout_from_manifest build =
  case build of
      NONE => NONE
    | SOME t => real_at t ["tactic_timeout"]

fun parse_local_config root =
  let val config = Path.concat(root, ".holconfig.toml")
  in
    if readable config then
      let val table = TOML.fromFile config
      in
        validate_local_config_table table;
        LocalConfig {overrides = overrides_at table,
                     build_excludes = local_build_excludes table,
                     build_jobs = local_build_jobs table,
                     build_tactic_timeout = local_build_tactic_timeout table}
      end
    else LocalConfig {overrides = [], build_excludes = [], build_jobs = NONE, build_tactic_timeout = NONE}
  end

fun parse_table_at table {manifest, root, artifact_root, local_config} =
  let
    val _ = validate_manifest_table table
    val project = table_field table ["project"]
    val build = table_field table ["build"]
    val run = table_field table ["run"]
    fun from opt f default = case opt of NONE => default | SOME t => f t
    fun build_strings name default =
      case build of
          NONE => default
        | SOME t => Option.getOpt(string_array_field_opt t name, default)
    val LocalConfig {overrides, build_excludes, build_jobs, build_tactic_timeout} = local_config
    val members = package_relative_paths "build.members" (build_strings "members" ["."])
    val excludes = package_relative_paths "build.exclude" (build_strings "exclude" []) @ build_excludes
    val roots = package_relative_paths "build.roots" (build_strings "roots" [])
    val manifest_timeout = build_tactic_timeout_from_manifest build
  in
    { root = root,
      artifact_root = artifact_root,
      manifest = manifest,
      name = Option.mapPartial (fn t => string_field t "name") project,
      version = Option.mapPartial (fn t => string_field t "version") project,
      members = members,
      excludes = excludes,
      roots = roots,
      dependencies = dependencies_at table,
      overrides = overrides,
      local_build_excludes = build_excludes,
      local_build_jobs = build_jobs,
      build_tactic_timeout = case build_tactic_timeout of NONE => manifest_timeout | some => some,
      run_heap = Option.mapPartial (fn t => string_field t "heap") run,
      run_loads = from run (fn t => string_array_field t "loads") [],
      heaps = heaps_at table,
      action_policies = action_policies_at root table,
      generators = generators_at table }
  end

fun parse_at args = parse_table_at (TOML.fromFile (#manifest args)) args

fun parse_builtin_holdir_at args =
  parse_table_at (TOML.fromString HolbuildBuiltinManifests.holdir_manifest_text) args

fun parse manifest =
  let
    val root = manifest_root manifest
    val local_config = parse_local_config root
  in
    parse_at {manifest = manifest, root = root, artifact_root = root, local_config = local_config}
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
            parse_at {manifest = manifest, root = root, artifact_root = artifact_root', local_config = local_config}
          end
      | NONE => die "no holproject.toml found in --source-dir/current directory or parents"
  end

fun abs_under root path =
  if Path.isAbsolute path then path else Path.concat(root, path)

fun abs_member ({root, ...} : t) member = abs_under root member
fun abs_run_heap ({root, run_heap, ...} : t) = Option.map (abs_under root) run_heap

fun override_path overrides name =
  let
    fun matches (Override {name = name', ...}) = name = name'
  in
    case List.find matches overrides of
        SOME (Override {path, ...}) => SOME path
      | NONE => NONE
  end

fun dependency_name (Dependency {name, ...}) = name

fun package_name (Package {name, ...}) = name
fun package_root (Package {root, ...}) = root
fun package_members (Package {members, ...}) = members
fun package_excludes (Package {excludes, ...}) = excludes
fun package_roots (Package {roots, ...}) = roots
fun package_artifact_root (Package {artifact_root, ...}) = artifact_root
fun package_generators (Package {generators, ...}) = generators
fun artifact_root ({artifact_root, ...} : t) = artifact_root
fun build_roots ({roots, ...} : t) = roots
fun package_action_policies (Package {action_policies, ...}) = action_policies

fun generator_name (Generator {name, ...}) = name
fun generator_command (Generator {command, ...}) = command
fun generator_inputs (Generator {inputs, ...}) = inputs
fun generator_outputs (Generator {outputs, ...}) = outputs
fun generator_deps (Generator {deps, ...}) = deps

fun action_policy_logical (ActionPolicy {logical, ...}) = logical
fun action_deps (ActionPolicy {deps, ...}) = deps
fun action_loads (ActionPolicy {loads, ...}) = loads
fun action_extra_inputs (ActionPolicy {extra_inputs, ...}) = extra_inputs
fun action_cache_enabled (ActionPolicy {impure, cache, always_reexecute, ...}) =
  cache andalso not impure andalso not always_reexecute
fun action_always_reexecute (ActionPolicy {impure, always_reexecute, ...}) =
  impure orelse always_reexecute
fun extra_input_path (ExtraInput {path, ...}) = path
fun extra_input_absolute_path (ExtraInput {absolute_path, ...}) = absolute_path

fun default_action_policy logical =
  ActionPolicy {logical = logical, deps = [], loads = [], extra_inputs = [], impure = false,
                cache = true, always_reexecute = false}

fun action_policy_for policies logical =
  case List.find (fn policy => action_policy_logical policy = logical) policies of
      SOME policy => policy
    | NONE => default_action_policy logical

fun dependency_path_context name = "dependencies." ^ name ^ ".path"
fun dependency_manifest_context name = "dependencies." ^ name ^ ".manifest"

fun dependency_local_path ({root, overrides, ...} : t) (Dependency {name, path, ...}) =
  Option.map (abs_under root)
    (case override_path overrides name of
         SOME override => SOME override
       | NONE =>
           case path of
               SOME p => SOME (expand_env (dependency_path_context name) p)
             | NONE => if builtin_holdir_dependency name then !holdir_ref else NONE)

fun dependency_manifest (project as {manifest = project_manifest, ...} : t) dep =
  case dep of
      Dependency {name, manifest = SOME manifest, ...} =>
        SOME (abs_under (manifest_root project_manifest)
                (expand_env (dependency_manifest_context name) manifest))
    | Dependency {name, manifest = NONE, ...} =>
        if builtin_holdir_dependency name then SOME (builtin_holdir_manifest ())
        else
          Option.map (fn path => Path.concat(path, "holproject.toml"))
            (dependency_local_path project dep)

fun heap_to_string (Heap {name, output, objects}) =
  name ^ " -> " ^ output ^ " [" ^ String.concatWith ", " objects ^ "]"

fun dependency_to_string project (dep as Dependency {name, path, manifest, git, rev}) =
  let
    fun field label value =
      case value of NONE => [] | SOME s => [label ^ "=" ^ s]
    val override = override_path (#overrides project) name
    val local_path = dependency_local_path project dep
    val resolved_manifest = dependency_manifest project dep
    val fields =
      field "path" path @ field "override" override @ field "local" local_path @
      field "manifest" manifest @ field "resolved-manifest" resolved_manifest @
      field "git" git @ field "rev" rev
  in
    name ^ " [" ^ String.concatWith ", " fields ^ "]"
  end

fun override_to_string (Override {name, path}) = name ^ " -> " ^ path

fun project_package ({root, artifact_root, manifest, name, members, excludes, roots, action_policies, generators, ...} : t) =
  Package {name = Option.getOpt(name, "root"), root = root, manifest = manifest,
           members = members, excludes = excludes, roots = roots,
           artifact_root = Path.concat(artifact_root, ".holbuild"),
           action_policies = action_policies,
           generators = generators}

fun dependency_project (project : t) (dep as Dependency {name, ...}) =
  let
    val dep_root =
      case dependency_local_path project dep of
          SOME path => path
        | NONE => die ("dependency " ^ name ^ " has no local path; add path or .holconfig.toml override")
    val dep_manifest =
      case dependency_manifest project dep of
          SOME manifest => manifest
        | NONE => die ("dependency " ^ name ^ " has no manifest")
    val parse_dep =
      if uses_builtin_holdir_manifest dep then parse_builtin_holdir_at
      else
        (if readable dep_manifest then ()
         else die ("dependency " ^ name ^ " manifest not found: " ^ dep_manifest);
         parse_at)
    val dep_project = parse_dep {manifest = dep_manifest, root = dep_root, artifact_root = dep_root,
                                 local_config = LocalConfig {overrides = #overrides project,
                                                             build_excludes = #local_build_excludes project,
                                                             build_jobs = #local_build_jobs project,
                                                             build_tactic_timeout = #build_tactic_timeout project}}
    val declared_name = #name dep_project
    val _ =
      case declared_name of
          NONE => ()
        | SOME actual =>
            if actual = name then ()
            else die ("dependency " ^ name ^ " manifest declares project.name = " ^ actual)
  in
    dep_project
  end

fun dependency_package artifact_parent project (dep as Dependency {name, ...}) =
  let
    val dep_project = dependency_project project dep
    val dep_root = valOf (dependency_local_path project dep)
    val dep_manifest = valOf (dependency_manifest project dep)
    val artifact_root = Path.concat(Path.concat(artifact_parent, ".holbuild/deps"), name)
  in
    (Package {name = name, root = dep_root, manifest = dep_manifest,
              members = #members dep_project, excludes = #excludes dep_project,
              roots = #roots dep_project, artifact_root = artifact_root,
              action_policies = #action_policies dep_project,
              generators = #generators dep_project},
     dep_project)
  end

fun packages (project : t) =
  let
    val artifact_parent = artifact_root project
    fun seen name names = List.exists (fn n => n = name) names
    fun add_dependency parent_project (dep, (names, packages)) =
      let val name = dependency_name dep
      in
        if seen name names then (names, packages)
        else
          let
            val (package, dep_project) = dependency_package artifact_parent parent_project dep
            val (names', packages') = add_project dep_project (name :: names, package :: packages)
          in
            (names', packages')
          end
      end
    and add_project current_project state =
      List.foldl (add_dependency current_project) state (#dependencies current_project)
    val root_package = project_package project
    val (_, packages) = add_project project ([package_name root_package], [root_package])
  in
    rev packages
  end

fun describe (project : t) =
  let
    val {root, artifact_root, manifest, name, version, members, excludes, roots, dependencies,
         overrides, local_build_excludes, local_build_jobs, build_tactic_timeout, run_heap, run_loads, heaps, action_policies, generators} = project
    fun opt label value =
      case value of NONE => () | SOME s => print (label ^ s ^ "\n")
  in
    print ("manifest: " ^ manifest ^ "\n");
    print ("root: " ^ root ^ "\n");
    print ("artifact-root: " ^ artifact_root ^ "\n");
    opt "name: " name;
    opt "version: " version;
    print ("members: " ^ String.concatWith ", " members ^ "\n");
    print ("exclude: " ^ String.concatWith ", " excludes ^ "\n");
    print ("roots: " ^ String.concatWith ", " roots ^ "\n");
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
