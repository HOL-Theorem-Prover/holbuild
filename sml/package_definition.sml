structure HolbuildPackageDefinition =
struct

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

fun make (definition : t) = definition
fun name (definition : t) = #name definition
fun version (definition : t) = #version definition
fun dependencies (definition : t) = #dependencies definition

end
