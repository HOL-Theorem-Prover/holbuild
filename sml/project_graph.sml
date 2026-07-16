structure HolbuildProjectGraph =
struct

exception Error of string

type package_id = string
type edge = HolbuildProject.project_graph_edge
type t = HolbuildProject.project_graph_data

fun package_id package = HolbuildProject.package_identity package
fun package_named packages name =
  List.find (fn package => HolbuildProject.package_name package = name) packages

fun validate_unique packages =
  let
    fun check (package, previous) =
      let
        val name = HolbuildProject.package_name package
        val id = package_id package
        val content_id = HolbuildProject.package_content_identity package
        fun conflict other =
          let val other_name = HolbuildProject.package_name other
              val other_id = package_id other
              val other_content_id = HolbuildProject.package_content_identity other
          in
            if name = other_name andalso id <> other_id then
              raise Error ("conflicting package identity for name " ^ name)
            else if content_id = other_content_id andalso name <> other_name then
              raise Error ("package content declared under different names: " ^
                           other_name ^ " and " ^ name)
            else ()
          end
      in List.app conflict previous; package :: previous end
  in ignore (List.foldl check [] packages) end

fun edges_for packages package =
  let
    val declaring_package = package_id package
    val dependencies =
      HolbuildPackageDefinition.dependencies
        (HolbuildProject.package_definition_of package)
    fun edge (HolbuildProject.Dependency {name, ...}) =
      case package_named packages name of
          NONE => raise Error ("resolved package graph is missing dependency " ^ name)
        | SOME target =>
            {declaring_package = declaring_package,
             dependency_name = name,
             dependency_package = package_id target}
  in map edge dependencies end

fun append_parse_count count =
  case OS.Process.getEnv "HOLBUILD_TEST_PACKAGE_PARSE_COUNT" of
      NONE => ()
    | SOME path =>
        let val output = TextIO.openAppend path
        in TextIO.output(output, Int.toString count ^ "\n"); TextIO.closeOut output end

fun resolve_package_closure resolution project =
  let
    val artifact_parent = #graph_artifact_root (project : HolbuildProject.t)
    fun seen_source name seen =
      Option.map #2 (List.find (fn (seen_name, _) => seen_name = name) seen)
    fun add_dependency parent_project
          (dep as HolbuildProject.Dependency {name, source, ...},
           (seen, packages)) =
      case seen_source name seen of
          SOME previous =>
            if HolbuildProject.same_dependency_source (previous, source) then
              (seen, packages)
            else raise Error ("conflicting dependency " ^ name)
        | NONE =>
            let
              val (package, dep_project) =
                HolbuildProject.dependency_package_with
                  resolution artifact_parent parent_project dep
              val state = ((name, source) :: seen, package :: packages)
            in
              add_project dep_project state
            end
    and add_project current_project state =
      List.foldl (add_dependency current_project) state
        (#dependencies (current_project : HolbuildProject.t))
    val root_package = HolbuildProject.project_package project
    val (_, packages) = add_project project ([], [root_package])
  in
    rev packages
  end

fun resolve {project, resolution} : t =
  case HolbuildProject.cached_graph_with resolution project of
      SOME graph => graph
    | NONE =>
  let
    val parse_count_before = HolbuildPackageDefinition.manifest_parse_count ()
    val packages = resolve_package_closure resolution project
    val _ = validate_unique packages
    val root_package = HolbuildProject.project_package project
    val root = package_id root_package
    val hol_packages =
      List.filter
        (fn package =>
          HolbuildPackageProvenance.is_implicit_hol
            (HolbuildProject.package_provenance package))
        packages
    val hol =
      case hol_packages of
          [package] => package_id package
        | _ => raise Error "dependency graph must contain exactly one hol dependency"
    val edges = List.concat (map (edges_for packages) packages)
    val graph = {root = root, hol = hol, packages = packages, edges = edges}
    val _ = HolbuildProject.store_graph_with resolution project graph
    val _ = append_parse_count
              (HolbuildPackageDefinition.manifest_parse_count () - parse_count_before)
  in
    graph
  end

fun packages ({packages, ...} : t) = packages
fun edges ({edges, ...} : t) = edges
fun root ({root, ...} : t) = root
fun hol ({hol, ...} : t) = hol

end
