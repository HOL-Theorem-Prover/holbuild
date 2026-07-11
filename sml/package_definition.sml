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

type compatibility = {schema : int}

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
