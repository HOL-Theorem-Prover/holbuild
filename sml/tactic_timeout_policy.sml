structure HolbuildTacticTimeoutPolicy =
struct

datatype proof_scope = ProofRoot | ProofAll

fun timeout_min (NONE, timeout) = timeout
  | timeout_min (timeout, NONE) = timeout
  | timeout_min (SOME a, SOME b) = SOME (Real.min(a, b))

(* Each node's tactic timeout, by node key: one lookup per node per pass, so
   a map rather than a list, which made plan-wide passes quadratic. *)
type timeouts = (string, real option) Binarymap.dict

val no_timeouts : timeouts = Binarymap.mkDict String.compare

fun timeout_of (timeouts : timeouts) node_key = Option.join (Binarymap.peek (timeouts, node_key))

fun add_key_timeout combine ((node_key, timeout), acc : timeouts) =
  case Binarymap.peek (acc, node_key) of
      NONE => Binarymap.insert (acc, node_key, timeout)
    | SOME old_timeout => Binarymap.insert (acc, node_key, combine (old_timeout, timeout))

fun add_node_timeout node timeout acc =
  add_key_timeout timeout_min ((HolbuildBuildPlan.key node, timeout), acc)

fun root_package_name project = HolbuildProject.package_name (HolbuildProject.project_package project)

fun root_package_node project node = HolbuildBuildPlan.package node = root_package_name project

fun includes_node ProofRoot project node = root_package_node project node
  | includes_node ProofAll _ _ = true

fun add_root_node_timeout project timeout (node, acc) =
  if root_package_node project node then add_node_timeout node timeout acc else acc

fun plan_timeouts scope project plan timeout =
  List.foldl
    (fn (node, acc) => if includes_node scope project node then add_node_timeout node timeout acc else acc)
    no_timeouts (HolbuildBuildPlan.selected_nodes plan)

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
    val root_groups = HolbuildProject.package_root_groups package
  in
    if null roots andalso null root_groups then implicit_entries package index
    else HolbuildSourceIndex.declared_root_entries index package
  end

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

(* The timeouts the roots with their own tactic timeout set on the root-package
   nodes of their closures.  Every other root would set the default timeout,
   which plan_timeouts already sets on each such node. *)
fun entry_timeouts project index entry_plan =
  List.foldl
    (fn ((root, logical), acc) =>
        case HolbuildProject.root_tactic_timeout_for project root of
            SOME timeout => add_entry_timeout project entry_plan (logical, timeout) acc
          | NONE => acc)
    no_timeouts
    (declared_entries project index)

fun selected_node_for_source project plan source =
  let
    val package = root_package_name project
    val path = #relative_path (source : HolbuildSourceIndex.source)
  in
    List.find
      (fn node =>
          HolbuildBuildPlan.package node = package andalso
          #relative_path (HolbuildBuildPlan.source_of node) = path)
      (HolbuildBuildPlan.selected_nodes plan)
  end

fun theory_timeouts project index plan =
  let
    val package = root_package_name project
    (* Entries name a theory by package-relative script path or by logical
       name (`src/SlowScript.sml` or `SlowTheory`). *)
    fun source_for name =
      case List.filter
             (fn (source : HolbuildSourceIndex.source) =>
                 #package source = package andalso
                 (#relative_path source = name orelse #logical_name source = name))
             index of
          [] => raise HolbuildProject.Error
                  ("build.theory_tactic_timeouts references unknown source: " ^ name)
        | matches =>
            if List.exists (fn source => #kind source <> HolbuildSourceIndex.TheoryScript) matches then
              raise HolbuildProject.Error
                ("build.theory_tactic_timeouts references a non-theory source: " ^ name)
            else
              case matches of
                  [source] => source
                | _ => raise HolbuildProject.Error
                         ("build.theory_tactic_timeouts references an ambiguous source: " ^ name)
    fun one ({source = name, timeout}, (seen, acc)) =
      let
        val source = source_for name
        val path = #relative_path source
        val _ =
          if List.exists (fn seen_path => seen_path = path) seen then
            raise HolbuildProject.Error
              ("build.theory_tactic_timeouts references " ^ #logical_name source ^ " more than once")
          else ()
        val acc =
          case selected_node_for_source project plan source of
              NONE => acc
            | SOME node => (HolbuildBuildPlan.key node, timeout) :: acc
      in
        (path :: seen, acc)
      end
  in
    #2 (List.foldl one ([], []) (HolbuildProject.theory_tactic_timeouts project))
  end

fun replace_timeouts base overrides = List.foldl (add_key_timeout #2) base overrides

fun combine_timeouts left (right : timeouts) =
  Binarymap.foldl (fn (node_key, timeout, acc) => add_key_timeout timeout_min ((node_key, timeout), acc)) left right

fun explicit_entries project index =
  List.filter
    (fn (root, _) => Option.isSome (HolbuildProject.root_tactic_timeout_for project root))
    (declared_entries project index)

end
