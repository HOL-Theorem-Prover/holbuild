structure HolbuildProjectGraph =
struct

exception Error of string

type package_id = string
type edge =
  {declaring_package : package_id,
   dependency_name : string,
   dependency_package : package_id}
type t =
  {root : package_id,
   hol : package_id,
   packages : HolbuildProject.package list,
   edges : edge list}

fun package_id package = HolbuildProject.package_identity package
fun package_named packages name =
  List.find (fn package => HolbuildProject.package_name package = name) packages

fun validate_unique packages =
  let
    fun check (package, previous) =
      let
        val name = HolbuildProject.package_name package
        val id = package_id package
        fun conflict other =
          let val other_name = HolbuildProject.package_name other
              val other_id = package_id other
          in
            if name = other_name andalso id <> other_id then
              raise Error ("conflicting package identity for name " ^ name)
            else if id = other_id andalso name <> other_name then
              raise Error ("package identity declared under different names: " ^
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

fun resolve {project, resolution} : t =
  let
    val packages = HolbuildProject.packages_with resolution project
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
        | _ => raise Error "resolved package graph must contain exactly one typed HOL package"
    val edges = List.concat (map (edges_for packages) packages)
  in
    {root = root, hol = hol, packages = packages, edges = edges}
  end

fun packages ({packages, ...} : t) = packages
fun edges ({edges, ...} : t) = edges
fun root ({root, ...} : t) = root
fun hol ({hol, ...} : t) = hol

end
