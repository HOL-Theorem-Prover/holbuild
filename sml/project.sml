structure HolbuildProject =
struct

structure Path = OS.Path
structure FS = OS.FileSys

datatype heap_kind = HeapImage | ExecutableImage of {main : string}

datatype heap = Heap of {name : string, output : string, objects : string list, kind : heap_kind}

type root_tactic_timeout = {root : string, timeout : real option}

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

datatype dependency = Dependency of {name : string, source : dependency_source}

datatype override =
    OverridePath of {name : string, path : string}
  | OverrideGit of {name : string, git : string}

datatype local_config = LocalConfig of {overrides : override list, build_excludes : string list, build_exclude_globs : string list, build_jobs : int option, build_tactic_timeout : real option, checkpoint_limit_gb : int option, remote_cache_url : string option, remote_cache_curl_config : string option}

datatype package =
  Package of
    { name : string,
      root : string,
      manifest : string,
      members : string list,
      excludes : string list,
      exclude_globs : string list,
      roots : string list,
      root_groups : string list,
      groups : group list,
      artifact_root : string,
      action_policies : action_policy list,
      generators : generator list }

type t =
  { root : string,
    artifact_root : string,
    graph_artifact_root : string,
    manifest : string,
    schema : int,
    name : string option,
    version : string option,
    members : string list,
    excludes : string list,
    exclude_globs : string list,
    roots : string list,
    root_groups : string list,
    groups : group list,
    root_tactic_timeouts : root_tactic_timeout list,
    dependencies : dependency list,
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
    generators : generator list }

exception Error of string

fun die msg = raise Error msg

fun warn msg = TextIO.output(TextIO.stdErr, "holbuild: warning: " ^ msg ^ "\n")

val source_dir_ref : string option ref = ref NONE

fun absolute_from_cwd path =
  Path.mkAbsolute {path = path, relativeTo = FS.getDir ()}

fun set_source_dir path = source_dir_ref := SOME (absolute_from_cwd path)

fun schema2_hol_dependency (Dependency {name = "hol", source = GitSource _}) = true
  | schema2_hol_dependency _ = false

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

fun real_value context value =
  case value of
      TOML.FLOAT r => r
    | TOML.INTEGER n =>
        (case Real.fromString (IntInf.toString n) of
             SOME r => r
           | NONE => die (context ^ " is too large"))
    | _ => die (context ^ " must be a non-negative number")

fun tactic_timeout_value context value =
  let val seconds = real_value context value
  in
    if seconds < 0.0 then die (context ^ " must be a non-negative number")
    else if seconds <= 0.0 then NONE
    else SOME seconds
  end

fun tactic_timeout_at context table key =
  case lookup table key of
      NONE => NONE
    | SOME value => tactic_timeout_value context value

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

fun path_components path = String.tokens (fn c => c = #"/" orelse c = #"\\") path

fun package_relative_path field path =
  let
    val has_parent_component =
      List.exists (fn component => component = "..") (path_components path)
  in
    if Path.isAbsolute path orelse has_parent_component then
      die (field ^ " must be package-root-relative: " ^ path)
    else path
  end

fun package_relative_paths field paths = map (package_relative_path field) paths

fun has_suffix suffix s =
  let val n = size s val m = size suffix
  in n >= m andalso String.substring(s, n - m, m) = suffix end

fun concrete_package_relative_path field path =
  let
    val components = path_components path
    val path = package_relative_path field path
  in
    if path = "" then die (field ^ " must not be empty")
    else if has_suffix "/" path orelse has_suffix "\\" path then
      die (field ^ " must not have a trailing slash: " ^ path)
    else if List.exists (fn component => component = ".") components then
      die (field ^ " must not contain . components: " ^ path)
    else path
  end

fun glob_like path =
  CharVector.exists (fn c => c = #"*" orelse c = #"?") path

fun split_deprecated_excludes context paths =
  let
    fun one (path, (excludes, globs)) =
      if glob_like path then
        let val path = package_relative_path context path
        in
          warn (context ^ " glob pattern \"" ^ path ^ "\" is deprecated; use " ^ context ^ "_globs instead");
          (excludes, path :: globs)
        end
      else (concrete_package_relative_path context path :: excludes, globs)
    val (excludes, globs) = List.foldl one ([], []) paths
  in
    (rev excludes, rev globs)
  end

fun safe_materialized_dependency_name name =
  size name > 0 andalso name <> "." andalso name <> ".." andalso
  List.all (fn c => Char.isAlphaNum c orelse c = #"_" orelse c = #"." orelse c = #"-")
           (String.explode name)

fun require_safe_materialized_dependency_name context name =
  if safe_materialized_dependency_name name then ()
  else die (context ^ " must be a safe dependency name: " ^ name)

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

fun is_hex c = Char.isDigit c orelse (#"a" <= c andalso c <= #"f")

fun validate_git_rev rev =
  if size rev = 40 andalso List.all is_hex (String.explode rev) then ()
  else die ("git dependency rev must be a full 40-character lowercase hex commit: " ^ rev)

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

fun parse_image_entry section kind value =
  case value of
      TOML.TABLE table =>
        let
          val name =
            case string_field table "name" of
                SOME s => s
              | NONE => die ("[[" ^ section ^ "]] entry requires name")
          val output =
            case string_field table "output" of
                SOME s => s
              | NONE => die ("[[" ^ section ^ "]] entry requires output")
          val objects = string_array_field table "objects"
        in
          Heap {name = name, output = output, objects = objects, kind = kind table}
        end
    | _ => die (section ^ " entries must be tables")

fun parse_heap value = parse_image_entry "heap" (fn _ => HeapImage) value

fun parse_executable value =
  parse_image_entry "executable"
    (fn table => ExecutableImage {main = Option.getOpt (string_field table "main", "main")})
    value

fun heap_entries_at table =
  case lookup table ["heap"] of
      NONE => []
    | SOME (TOML.ARRAY values) => map parse_heap values
    | SOME _ => die "heap must be an array of tables"

fun executable_entries_at table =
  case lookup table ["executable"] of
      NONE => []
    | SOME (TOML.ARRAY values) => map parse_executable values
    | SOME _ => die "executable must be an array of tables"

fun reject_duplicate_heap_names heaps =
  let
    fun name_of (Heap {name, ...}) = name
    fun seen name values = List.exists (fn value => value = name) values
    fun loop names rest =
      case rest of
          [] => ()
        | heap :: more =>
          let val name = name_of heap
          in
            if seen name names then die ("duplicate heap/executable target name: " ^ name)
            else loop (name :: names) more
          end
  in
    loop [] heaps
  end

fun heaps_at table =
  let val heaps = heap_entries_at table @ executable_entries_at table
  in reject_duplicate_heap_names heaps; heaps end

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
        (case (version_field_at holbuild "minimum_version", version_field_at holbuild "required_version") of
             (NONE, NONE) => NONE
           | (SOME version, NONE) => SOME version
           | (NONE, SOME version) => SOME version
           | (SOME _, SOME _) => raise Fail "unreachable version field state")

fun validate_required_version holbuild =
  case configured_required_version holbuild of
      NONE => ()
    | SOME (name, required) =>
        (HolbuildVersion.require_at_least required
         handle HolbuildVersion.Error msg => die ("invalid holbuild." ^ name ^ ": " ^ msg))

fun validate_schema table =
  case table_field table ["holbuild"] of
      NONE => ()
    | SOME holbuild =>
        (require_known_fields "holbuild" ["schema", "minimum_version", "required_version"] holbuild;
         ignore (schema_version table);
         validate_required_version holbuild)

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

fun validate_action_table (logical, table) =
  require_known_fields ("actions." ^ logical)
    ["deps", "loads", "extra_inputs", "extra_deps", "impure", "cache", "always_reexecute"] table

fun validate_generate_entry value =
  case value of
      TOML.TABLE generate => require_known_fields "generate" ["name", "command", "inputs", "outputs", "deps"] generate
    | _ => die "generate entries must be tables"

fun validate_groups_table table =
  let
    fun validate_one (name, value) =
      (require_group_name name;
       case value of
           TOML.TABLE group =>
             require_known_fields ("build.groups." ^ name)
               ["include", "include_globs", "exclude", "exclude_globs", "allow_empty"] group
         | _ => die ("build.groups." ^ name ^ " must be a table"))
  in
    case lookup table ["build", "groups"] of
        NONE => ()
      | SOME (TOML.TABLE groups) => List.app validate_one groups
      | SOME _ => die "build.groups must be a table"
  end

fun validate_manifest_table table =
  let
    val _ = require_known_fields "holproject.toml"
              ["holbuild", "project", "build", "dependencies", "run", "heap", "executable", "actions", "generate"] table
    val _ = Option.app (require_known_fields "project" ["name", "version"])
              (table_field table ["project"])
    val _ = Option.app (require_known_fields "build" ["members", "exclude", "exclude_globs", "roots", "root_groups", "groups", "tactic_timeout", "root_tactic_timeouts"])
              (table_field table ["build"])
    val _ = Option.app (require_known_fields "run" ["heap", "loads"])
              (table_field table ["run"])
    val _ = ignore (schema_version table)
    val _ = List.app validate_dependency_table (named_table_entries table ["dependencies"])
    val _ = List.app validate_action_table (named_table_entries table ["actions"])
    val _ = validate_groups_table table
    val _ =
      case lookup table ["generate"] of
          NONE => ()
        | SOME (TOML.ARRAY values) => List.app validate_generate_entry values
        | SOME _ => die "generate must be an array of tables"
    fun validate_image_entry section fields value =
      case value of
          TOML.TABLE image => require_known_fields section fields image
        | _ => die (section ^ " entries must be tables")
    val _ =
      case lookup table ["heap"] of
          NONE => ()
        | SOME (TOML.ARRAY values) => List.app (validate_image_entry "heap" ["name", "output", "objects"]) values
        | SOME _ => die "heap must be an array of tables"
    val _ =
      case lookup table ["executable"] of
          NONE => ()
        | SOME (TOML.ARRAY values) => List.app (validate_image_entry "executable" ["name", "output", "objects", "main"]) values
        | SOME _ => die "executable must be an array of tables"
  in
    validate_schema table
  end

fun validate_override_table (name, table) =
  (require_safe_materialized_dependency_name ("overrides." ^ name) name;
   if name = "hol" then die "dependencies.hol cannot be overridden; use dependencies.hol.git with a local path and HOLBUILD_CANONICAL_HOL_GIT"
   else ();
   require_known_fields ("overrides." ^ name) ["path", "git"] table;
   case (string_field table "path", string_field table "git") of
       (SOME _, NONE) => ()
     | (NONE, SOME _) => ()
     | (SOME _, SOME _) => die ("overrides." ^ name ^ " must specify only one of path or git")
     | (NONE, NONE) => die ("overrides." ^ name ^ " requires path or git"))

fun validate_local_build_table table =
  require_known_fields ".holconfig.toml build" ["exclude", "exclude_globs", "jobs", "tactic_timeout", "checkpoint_limit_gb"] table

fun validate_local_remote_cache_table table =
  require_known_fields ".holconfig.toml remote_cache" ["url", "curl_config"] table

fun validate_local_config_table table =
  (require_known_fields ".holconfig.toml" ["overrides", "build", "remote_cache"] table;
   Option.app validate_local_build_table (table_field table ["build"]);
   Option.app validate_local_remote_cache_table (table_field table ["remote_cache"]);
   List.app validate_override_table (named_table_entries table ["overrides"]))

fun parse_dependency (name, table) =
  let
    val source =
      case (string_field table "git", string_field table "rev", string_field table "from",
            string_field table "path", string_field table "manifest") of
          (SOME git, SOME rev, NONE, NONE, NONE) => GitSource {git = git, rev = rev}
        | (NONE, NONE, SOME from, SOME path, SOME manifest) =>
            FromSource {from = from, path = path, manifest = manifest}
        | _ => die ("invalid dependency form for dependencies." ^ name)
  in
    Dependency {name = name, source = source}
  end

fun dependencies_at table = map parse_dependency (named_table_entries table ["dependencies"])

fun dependency_name (Dependency {name, ...}) = name

fun validate_schema2_dependency_refs deps =
  let
    fun source_for name =
      Option.map (fn Dependency {source, ...} => source)
        (List.find (fn dep => dependency_name dep = name) deps)
    fun validate_one (Dependency {name, source = FromSource {from, ...}}) =
          (case source_for from of
               SOME (GitSource _) => ()
             | SOME _ => die ("dependencies." ^ name ^ " from dependency must refer to a direct git dependency: " ^ from)
             | NONE => die ("dependencies." ^ name ^ " from dependency is unknown: " ^ from))
      | validate_one (Dependency {name, source = GitSource _, ...}) =
          require_safe_materialized_dependency_name ("dependencies." ^ name) name
  in
    List.app validate_one deps
  end

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

fun override_abs root path =
  let val raw = if Path.isAbsolute path then path else Path.concat(root, path)
  in Path.mkCanonical raw handle Path.InvalidArc => raw end

fun starts_with prefix s =
  let val n = size prefix
  in size s >= n andalso String.substring(s, 0, n) = prefix end

fun contains c s = CharVector.exists (fn c' => c' = c) s

fun remote_git_like git =
  contains #":" git andalso not (starts_with "." git) andalso not (starts_with "/" git)

fun local_git_abs root git =
  if Path.isAbsolute git then override_abs root git
  else if starts_with "http://" git orelse starts_with "https://" git orelse
          starts_with "ssh://" git orelse starts_with "git://" git orelse
          starts_with "file://" git orelse remote_git_like git then git
  else override_abs root git

fun parse_override root (name, table) =
  case (path_string_field ("overrides." ^ name) table "path",
        path_string_field ("overrides." ^ name) table "git") of
      (SOME path, NONE) => OverridePath {name = name, path = override_abs root path}
    | (NONE, SOME git) => OverrideGit {name = name, git = local_git_abs root git}
    | _ => die ("[overrides." ^ name ^ "] requires path or git")

fun overrides_at root table = map (parse_override root) (named_table_entries table ["overrides"])

fun local_build_excludes table =
  case table_field table ["build"] of
      NONE => ([], [])
    | SOME build =>
        let
          val (excludes, deprecated_globs) =
            split_deprecated_excludes ".holconfig.toml build.exclude" (string_array_field build "exclude")
          val globs = package_relative_paths ".holconfig.toml build.exclude_globs" (string_array_field build "exclude_globs")
        in
          (excludes, deprecated_globs @ globs)
        end

fun local_build_jobs table =
  case table_field table ["build"] of
      NONE => NONE
    | SOME build => Option.map (positive_int_field ".holconfig.toml build.jobs") (int_at build ["jobs"])

fun local_build_tactic_timeout table =
  case table_field table ["build"] of
      NONE => NONE
    | SOME build => tactic_timeout_at ".holconfig.toml build.tactic_timeout" build ["tactic_timeout"]

fun build_tactic_timeout_from_manifest build =
  case build of
      NONE => NONE
    | SOME t => tactic_timeout_at "build.tactic_timeout" t ["tactic_timeout"]

fun local_checkpoint_limit_gb table =
  case table_field table ["build"] of
      NONE => NONE
    | SOME build => Option.map (positive_int_field ".holconfig.toml build.checkpoint_limit_gb") (int_at build ["checkpoint_limit_gb"])

fun local_remote_cache_url table =
  case table_field table ["remote_cache"] of
      NONE => NONE
    | SOME remote_cache => string_at remote_cache ["url"]

fun local_remote_cache_curl_config table =
  case table_field table ["remote_cache"] of
      NONE => NONE
    | SOME remote_cache => string_at remote_cache ["curl_config"]

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

fun validate_root_tactic_timeouts roots timeouts =
  List.app
    (fn {root, ...} =>
        if member root roots then ()
        else die ("build.root_tactic_timeouts references unknown root: " ^ root))
    timeouts

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

fun parse_local_config root =
  let val config = Path.concat(root, ".holconfig.toml")
  in
    if readable config then
      let
        val table = TOML.fromFile config
        val _ = validate_local_config_table table
        val (build_excludes, build_exclude_globs) = local_build_excludes table
      in
        LocalConfig {overrides = overrides_at root table,
                     build_excludes = build_excludes,
                     build_exclude_globs = build_exclude_globs,
                     build_jobs = local_build_jobs table,
                     build_tactic_timeout = local_build_tactic_timeout table,
                     checkpoint_limit_gb = local_checkpoint_limit_gb table,
                     remote_cache_url = local_remote_cache_url table,
                     remote_cache_curl_config = local_remote_cache_curl_config table}
      end
    else LocalConfig {overrides = [], build_excludes = [], build_exclude_globs = [], build_jobs = NONE, build_tactic_timeout = NONE, checkpoint_limit_gb = NONE, remote_cache_url = NONE, remote_cache_curl_config = NONE}
  end

fun parse_table_at table {manifest, root, artifact_root, graph_artifact_root, local_config} =
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
    val LocalConfig {overrides, build_excludes, build_exclude_globs, build_jobs, build_tactic_timeout, checkpoint_limit_gb, remote_cache_url, remote_cache_curl_config} = local_config
    val members = package_relative_paths "build.members" (build_strings "members" ["."])
    val (manifest_excludes, deprecated_exclude_globs) =
      split_deprecated_excludes "build.exclude" (build_strings "exclude" [])
    val excludes = manifest_excludes @ build_excludes
    val exclude_globs = deprecated_exclude_globs @ package_relative_paths "build.exclude_globs" (build_strings "exclude_globs" []) @ build_exclude_globs
    val roots = build_roots_from_manifest build_strings
    val root_groups = build_root_groups_from_manifest build_strings
    val groups = groups_at table
    val root_tactic_timeouts = root_tactic_timeouts_from_manifest build
    val _ = validate_root_tactic_timeouts roots root_tactic_timeouts
    val _ = validate_root_groups root_groups groups
    val manifest_timeout = build_tactic_timeout_from_manifest build
    val schema = schema_version table
    val dependencies = dependencies_at table
    val _ = validate_schema2_dependency_refs dependencies
  in
    { root = root,
      artifact_root = artifact_root,
      graph_artifact_root = graph_artifact_root,
      manifest = manifest,
      schema = schema,
      name = Option.mapPartial (fn t =>
               Option.map (fn name =>
                 (require_safe_materialized_dependency_name "project.name" name; name))
                 (string_field t "name")) project,
      version = Option.mapPartial (fn t => string_field t "version") project,
      members = members,
      excludes = excludes,
      exclude_globs = exclude_globs,
      roots = roots,
      root_groups = root_groups,
      groups = groups,
      root_tactic_timeouts = root_tactic_timeouts,
      dependencies = dependencies,
      overrides = overrides,
      local_build_excludes = build_excludes,
      local_build_exclude_globs = build_exclude_globs,
      local_build_jobs = build_jobs,
      build_tactic_timeout = case build_tactic_timeout of NONE => manifest_timeout | some => some,
      checkpoint_limit_gb = checkpoint_limit_gb,
      remote_cache_url = remote_cache_url,
      remote_cache_curl_config = remote_cache_curl_config,
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
fun schema ({schema, ...} : t) = schema
fun hol_dependency ({dependencies, ...} : t) =
  List.find (fn Dependency {name, ...} => name = "hol") dependencies

fun project_hol_dir project =
  case hol_dependency project of
      SOME (Dependency {source = GitSource {git, rev}, ...}) =>
        SOME (HolbuildHolSharedCache.holdir_for {git = git, rev = rev})
    | _ => NONE
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

fun dependency_local_path (project as {graph_artifact_root, ...} : t) (Dependency {name, source}) =
  case override_path (#overrides project) name of
      SOME path => SOME path
    | NONE =>
        case source of
            GitSource {git, rev} =>
              if name = "hol" then SOME (HolbuildHolSharedCache.holdir_for {git = git, rev = rev})
              else SOME (Path.concat(Path.concat(Path.concat(graph_artifact_root, ".holbuild"), "src"), name))
          | FromSource {from, path, ...} =>
              (case hol_dependency project of
                   SOME (Dependency {name = "hol", source = GitSource {git, rev}}) =>
                     if from = "hol" then SOME (Path.concat(HolbuildHolSharedCache.holdir_for {git = git, rev = rev}, path))
                     else SOME (Path.concat(Path.concat(Path.concat(Path.concat(graph_artifact_root, ".holbuild"), "src"), from), path))
                 | _ => SOME (Path.concat(Path.concat(Path.concat(Path.concat(graph_artifact_root, ".holbuild"), "src"), from), path)))

fun dependency_manifest (project as {manifest = project_manifest, graph_artifact_root, ...} : t) dep =
  case dep of
      dep as Dependency {name, source = GitSource _, ...} =>
        if schema2_hol_dependency dep then SOME (HolbuildBuiltinManifests.holdir_manifest_name)
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

fun dependency_to_string project (dep as Dependency {name, source}) =
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

fun project_package ({root, artifact_root, graph_artifact_root, manifest, name, members, excludes, exclude_globs, roots, root_groups, groups, action_policies, generators, ...} : t) =
  Package {name = Option.getOpt(name, "root"), root = root, manifest = manifest,
           members = members, excludes = excludes, exclude_globs = exclude_globs,
           roots = roots, root_groups = root_groups, groups = groups,
           artifact_root = if artifact_root = graph_artifact_root then Path.concat(artifact_root, ".holbuild") else artifact_root,
           action_policies = action_policies,
           generators = generators}

fun dependency_project (project : t) (dep as Dependency {name, source}) =
  let
    val _ =
      case source of
          GitSource {git, rev} =>
            if schema2_hol_dependency dep orelse Option.isSome (override_path (#overrides project) name) then ()
            else
              let val effective_git = Option.getOpt(override_git (#overrides project) name, git)
              in ignore (HolbuildGitCache.materialize {name = name, git = effective_git, rev = rev,
                                                       artifact_root = #graph_artifact_root project}) end
        | _ => ()
    val dep_root =
      case dependency_local_path project dep of
          SOME path => path
        | NONE => die ("dependency " ^ name ^ " has no local path; add path or .holconfig.toml override")
    val dep_manifest =
      case dependency_manifest project dep of
          SOME manifest => manifest
        | NONE => die ("dependency " ^ name ^ " has no manifest")
    val parse_dep =
      if schema2_hol_dependency dep then parse_builtin_holdir_at
      else
        (if readable dep_manifest then ()
         else die ("dependency " ^ name ^ " manifest not found: " ^ dep_manifest);
         parse_at)
    val dep_artifact_root =
      Path.concat(Path.concat(Path.concat(#graph_artifact_root project, ".holbuild"), "packages"), name)
    val dep_project = parse_dep {manifest = dep_manifest, root = dep_root, artifact_root = dep_artifact_root,
                                 graph_artifact_root = #graph_artifact_root project,
                                 local_config = LocalConfig {overrides = #overrides project,
                                                             build_excludes = #local_build_excludes project,
                                                             build_exclude_globs = #local_build_exclude_globs project,
                                                             build_jobs = #local_build_jobs project,
                                                             build_tactic_timeout = #build_tactic_timeout project,
                                                             checkpoint_limit_gb = #checkpoint_limit_gb project,
                                                             remote_cache_url = #remote_cache_url project,
                                                             remote_cache_curl_config = #remote_cache_curl_config project}}
    val declared_name = #name dep_project
    val _ =
      case declared_name of
          NONE => ()
        | SOME actual =>
            if actual = name orelse schema2_hol_dependency dep then ()
            else die ("dependency " ^ name ^ " manifest declares project.name = " ^ actual)
  in
    dep_project
  end

fun resolved_hol_dependency project =
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
              (case search_project (name :: names) (dependency_project parent dep) of
                   SOME hol => SOME hol
                 | NONE => search_deps (name :: names) parent rest)
  in
    search_project [] project
  end

fun dependency_package artifact_parent project (dep as Dependency {name, ...}) =
  let
    val dep_project = dependency_project project dep
    val dep_root = valOf (dependency_local_path project dep)
    val dep_manifest = valOf (dependency_manifest project dep)
    val artifact_root =
      Path.concat(Path.concat(Path.concat(artifact_parent, ".holbuild"), "packages"), name)
  in
    (Package {name = name, root = dep_root, manifest = dep_manifest,
              members = #members dep_project, excludes = #excludes dep_project,
              exclude_globs = #exclude_globs dep_project,
              roots = #roots dep_project, root_groups = #root_groups dep_project,
              groups = #groups dep_project, artifact_root = artifact_root,
              action_policies = #action_policies dep_project,
              generators = #generators dep_project},
     dep_project)
  end

fun same_dependency_source (GitSource a, GitSource b) = #git a = #git b andalso #rev a = #rev b
  | same_dependency_source (FromSource a, FromSource b) =
      #from a = #from b andalso #path a = #path b andalso #manifest a = #manifest b
  | same_dependency_source _ = false

fun packages (project : t) =
  let
    val artifact_parent = #graph_artifact_root project
    fun seen_source name seen =
      Option.map #2 (List.find (fn (n, _) => n = name) seen)
    fun add_dependency parent_project (dep as Dependency {name, source}, (seen, packages)) =
      case seen_source name seen of
          SOME previous =>
            if same_dependency_source (previous, source) then (seen, packages)
            else die ("conflicting dependency " ^ name)
        | NONE =>
            let
              val (package, dep_project) = dependency_package artifact_parent parent_project dep
              val (seen', packages') = add_project dep_project ((name, source) :: seen, package :: packages)
            in
              (seen', packages')
            end
    and add_project current_project state =
      List.foldl (add_dependency current_project) state (#dependencies current_project)
    val root_package = project_package project
    val (_, packages) = add_project project ([], [root_package])
    val result = rev packages
    val hol_count = length (List.filter (fn package => package_name package = "hol") result)
    val _ =
      if hol_count <> 1 then
        die "dependency graph must contain exactly one hol dependency"
      else ()
  in
    result
  end

fun describe (project : t) =
  let
    val {root, artifact_root, manifest, name, version, members, excludes, exclude_globs, roots, root_groups, groups, root_tactic_timeouts, dependencies,
         overrides, local_build_excludes, local_build_exclude_globs, local_build_jobs, build_tactic_timeout, run_heap, run_loads, heaps, action_policies, generators, ...} = project
    fun opt label value =
      case value of NONE => () | SOME s => print (label ^ s ^ "\n")
    fun describe_package (Package {name, root, manifest, artifact_root, ...}) =
      print ("package: " ^ name ^ " [root=" ^ root ^ ", manifest=" ^ manifest ^
             ", artifact-root=" ^ artifact_root ^ "]\n")
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
    opt "name: " name;
    opt "version: " version;
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
