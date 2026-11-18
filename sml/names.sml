(* The names a user can give holbuild: commands, build targets, groups,
   theories and heaps.  Error suggestions and shell completion both take
   their candidates from here. *)
structure HolbuildNames =
struct

val command_names =
  ["build", "context", "repl", "run", "execution-plan", "check", "buildhol", "heap", "executable",
   "clean", "export", "import", "gc", "cache", "action-spec", "exec-action", "run-action"]

fun target_names (sources : HolbuildSourceIndex.source list) =
  map #logical_name sources

fun theory_names (sources : HolbuildSourceIndex.source list) =
  map #logical_name
    (List.filter (fn source => #kind source = HolbuildSourceIndex.TheoryScript) sources)

(* The @NAME tokens that select a group of package's sources. *)
fun group_tokens package =
  map (fn group => "@" ^ HolbuildProject.group_name group)
    (HolbuildProject.package_groups package)

fun heap_kind_matches "heap" HolbuildProject.HeapImage = true
  | heap_kind_matches "executable" (HolbuildProject.ExecutableImage _) = true
  | heap_kind_matches _ _ = false

(* The names of the heaps the heap or executable command builds. *)
fun heap_names command heaps =
  List.mapPartial
    (fn HolbuildProject.Heap {name, kind, ...} =>
        if heap_kind_matches command kind then SOME name else NONE)
    heaps

end
