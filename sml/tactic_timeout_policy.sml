structure HolbuildTacticTimeoutPolicy =
struct

fun timeout_min (NONE, timeout) = timeout
  | timeout_min (timeout, NONE) = timeout
  | timeout_min (SOME a, SOME b) = SOME (Real.min(a, b))

fun add_node_timeout node timeout acc =
  let
    val node_key = HolbuildBuildPlan.key node
    fun insert entries =
      case entries of
          [] => [(node_key, timeout)]
        | (key, old_timeout) :: rest =>
            if key = node_key then (key, timeout_min (old_timeout, timeout)) :: rest
            else (key, old_timeout) :: insert rest
  in
    insert acc
  end

fun root_package_name project = HolbuildProject.package_name (HolbuildProject.project_package project)

fun root_package_node project node = HolbuildBuildPlan.package node = root_package_name project

fun add_root_node_timeout project timeout (node, acc) =
  if root_package_node project node then add_node_timeout node timeout acc else acc

fun plan_timeouts project plan timeout =
  List.foldl (add_root_node_timeout project timeout) [] (HolbuildBuildPlan.selected_nodes plan)

fun source_entry source = (#relative_path source, #logical_name source)

fun implicit_entries package index =
  List.map source_entry
    (List.filter
       (fn source => #package source = HolbuildProject.package_name package andalso
                     #kind source = HolbuildSourceIndex.TheoryScript)
       index)

fun declared_entries project index =
  let
    val package = HolbuildProject.project_package project
    val roots = HolbuildProject.package_roots package
  in
    if null roots then implicit_entries package index
    else ListPair.zip (roots, HolbuildSourceIndex.roots_for_package index package)
  end

fun entry_timeout project default_timeout root =
  case HolbuildProject.root_tactic_timeout_for project root of
      SOME timeout => timeout
    | NONE => default_timeout

fun node_named plan logical =
  case List.filter (fn node => HolbuildBuildPlan.logical_name node = logical) (HolbuildBuildPlan.selected_nodes plan) of
      [] => NONE
    | node :: _ => SOME node

fun closure_nodes plan root =
  HolbuildBuildPlan.transitive_project_deps plan root @ [root]

fun add_entry_timeout project plan (logical, timeout) acc =
  case node_named plan logical of
      NONE => acc
    | SOME root => List.foldl (add_root_node_timeout project timeout) acc (closure_nodes plan root)

fun entry_timeouts project index entry_plan default_timeout =
  List.foldl
    (fn ((root, logical), acc) => add_entry_timeout project entry_plan (logical, entry_timeout project default_timeout root) acc)
    []
    (declared_entries project index)

end
