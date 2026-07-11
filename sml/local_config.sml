structure HolbuildLocalConfig =
struct

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

val empty =
  make
    {overrides = [], build_excludes = [], build_exclude_globs = [],
     build_jobs = NONE, build_tactic_timeout = NONE, checkpoint_limit_gb = NONE,
     remote_cache_url = NONE, remote_cache_curl_config = NONE}

(* Parsing primitives remain supplied by the manifest TOML layer during the
   transition out of HolbuildProject. This function owns local-config lifetime
   and assembly without coupling this module to project/package parsing. *)
fun parse {config_path, readable, parse_file, validate, parse_overrides,
           parse_build_excludes, parse_build_jobs, parse_build_tactic_timeout,
           parse_checkpoint_limit_gb, parse_remote_cache_url,
           parse_remote_cache_curl_config} =
  if readable config_path then
    let
      val table = parse_file config_path
      val _ = validate table
      val (build_excludes, build_exclude_globs) = parse_build_excludes table
    in
      make
        {overrides = parse_overrides table,
         build_excludes = build_excludes,
         build_exclude_globs = build_exclude_globs,
         build_jobs = parse_build_jobs table,
         build_tactic_timeout = parse_build_tactic_timeout table,
         checkpoint_limit_gb = parse_checkpoint_limit_gb table,
         remote_cache_url = parse_remote_cache_url table,
         remote_cache_curl_config = parse_remote_cache_curl_config table}
    end
  else empty

fun overrides (LocalConfig {overrides, ...}) = overrides
fun build_excludes (LocalConfig {build_excludes, ...}) = build_excludes
fun build_exclude_globs (LocalConfig {build_exclude_globs, ...}) = build_exclude_globs
fun build_jobs (LocalConfig {build_jobs, ...}) = build_jobs
fun build_tactic_timeout (LocalConfig {build_tactic_timeout, ...}) = build_tactic_timeout
fun checkpoint_limit_gb (LocalConfig {checkpoint_limit_gb, ...}) = checkpoint_limit_gb
fun remote_cache_url (LocalConfig {remote_cache_url, ...}) = remote_cache_url
fun remote_cache_curl_config (LocalConfig {remote_cache_curl_config, ...}) = remote_cache_curl_config

end
