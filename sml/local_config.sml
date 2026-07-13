structure HolbuildLocalConfig =
struct

structure Path = OS.Path
open HolbuildManifestUtil

(* Local configuration is invocation/graph configuration, not committed package
   semantics. It is parsed once for each command (and each watch iteration) and
   must not be merged into dependency package definitions. *)

datatype override =
    OverridePath of {name : string, path : string}
  | OverrideGit of {name : string, git : string}

datatype t =
  LocalConfig of
    { overrides : override list,
      build_excludes : string list,
      build_exclude_globs : string list,
      build_jobs : int option,
      build_tactic_timeout : real option,
      checkpoint_limit_gb : int option,
      remote_cache_url : string option,
      remote_cache_curl_config : string option }

fun make fields = LocalConfig fields
val empty = make {overrides = [], build_excludes = [], build_exclude_globs = [],
                  build_jobs = NONE, build_tactic_timeout = NONE,
                  checkpoint_limit_gb = NONE, remote_cache_url = NONE,
                  remote_cache_curl_config = NONE}

fun override_abs root path =
  let val raw = if Path.isAbsolute path then path else Path.concat(root, path)
  in Path.mkCanonical raw handle Path.InvalidArc => raw end
fun starts_with prefix s =
  let val n = size prefix in size s >= n andalso String.substring(s, 0, n) = prefix end
fun contains c s = CharVector.exists (fn c' => c' = c) s
fun remote_git_like git = contains #":" git andalso not (starts_with "." git) andalso not (starts_with "/" git)
fun local_git_abs root git =
  if Path.isAbsolute git then override_abs root git
  else if starts_with "http://" git orelse starts_with "https://" git orelse
          starts_with "ssh://" git orelse starts_with "git://" git orelse
          starts_with "file://" git orelse remote_git_like git then git
  else override_abs root git

fun validate_override_table (name, table) =
  (require_safe_materialized_dependency_name ("overrides." ^ name) name;
   if name = "hol" then die "dependencies.hol cannot be overridden; use dependencies.hol.git with a local path and HOLBUILD_CANONICAL_HOL_GIT" else ();
   require_known_fields ("overrides." ^ name) ["path", "git"] table;
   case (string_field table "path", string_field table "git") of
       (SOME _, NONE) => () | (NONE, SOME _) => ()
     | (SOME _, SOME _) => die ("overrides." ^ name ^ " must specify only one of path or git")
     | (NONE, NONE) => die ("overrides." ^ name ^ " requires path or git"))

fun validate table =
  (require_known_fields ".holconfig.toml" ["overrides", "build", "remote_cache"] table;
   Option.app (require_known_fields ".holconfig.toml build"
     ["exclude", "exclude_globs", "jobs", "tactic_timeout", "checkpoint_limit_gb"])
     (table_field table ["build"]);
   Option.app (require_known_fields ".holconfig.toml remote_cache" ["url", "curl_config"])
     (table_field table ["remote_cache"]);
   List.app validate_override_table (named_table_entries table ["overrides"]))

fun parse_override root (name, table) =
  case (path_string_field ("overrides." ^ name) table "path",
        path_string_field ("overrides." ^ name) table "git") of
      (SOME path, NONE) => OverridePath {name = name, path = override_abs root path}
    | (NONE, SOME git) => OverrideGit {name = name, git = local_git_abs root git}
    | _ => die ("[overrides." ^ name ^ "] requires path or git")

fun build_exclusions table =
  case table_field table ["build"] of
      NONE => ([], [])
    | SOME build =>
        let
          val excludes = concrete_excludes ".holconfig.toml build.exclude"
                           (string_array_field build "exclude")
          val globs = package_relative_paths ".holconfig.toml build.exclude_globs"
                        (string_array_field build "exclude_globs")
        in (excludes, globs) end

fun positive_build_int table name =
  case table_field table ["build"] of
      NONE => NONE
    | SOME build => Option.map (positive_int_field (".holconfig.toml build." ^ name)) (int_at build [name])

fun parse root =
  let val path = Path.concat(root, ".holconfig.toml")
  in
    if not (OS.FileSys.access(path, [OS.FileSys.A_READ]) handle OS.SysErr _ => false) then empty
    else
      let
        val table = TOML.fromFile path
        val _ = validate table
        val (excludes, globs) = build_exclusions table
        val build = table_field table ["build"]
        val remote = table_field table ["remote_cache"]
      in
        make
          {overrides = map (parse_override root) (named_table_entries table ["overrides"]),
           build_excludes = excludes, build_exclude_globs = globs,
           build_jobs = positive_build_int table "jobs",
           build_tactic_timeout =
             (case build of NONE => NONE | SOME value => tactic_timeout_at ".holconfig.toml build.tactic_timeout" value ["tactic_timeout"]),
           checkpoint_limit_gb = positive_build_int table "checkpoint_limit_gb",
           remote_cache_url = (case remote of NONE => NONE | SOME value => string_at value ["url"]),
           remote_cache_curl_config = (case remote of NONE => NONE | SOME value => string_at value ["curl_config"])}
      end
  end

fun overrides (LocalConfig {overrides, ...}) = overrides
fun build_excludes (LocalConfig {build_excludes, ...}) = build_excludes
fun build_exclude_globs (LocalConfig {build_exclude_globs, ...}) = build_exclude_globs
fun build_jobs (LocalConfig {build_jobs, ...}) = build_jobs
fun build_tactic_timeout (LocalConfig {build_tactic_timeout, ...}) = build_tactic_timeout
fun checkpoint_limit_gb (LocalConfig {checkpoint_limit_gb, ...}) = checkpoint_limit_gb
fun remote_cache_url (LocalConfig {remote_cache_url, ...}) = remote_cache_url
fun remote_cache_curl_config (LocalConfig {remote_cache_curl_config, ...}) = remote_cache_curl_config

end
