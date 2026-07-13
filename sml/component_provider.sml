structure HolbuildComponentProvider =
struct

exception Error of string

datatype provider = LiveProvider

type project_components =
  { graph : HolbuildProjectGraph.t,
    instances : HolbuildPackageComponent.instance list,
    sources : HolbuildSourceIndex.t,
    resolution_context_id : string }

fun frame text = Int.toString (size text) ^ ":" ^ text
fun framed fields = String.concat (map frame fields)
fun hash fields = HolbuildHash.string_sha256 (framed fields)

fun inventory_named inventories name =
  List.find
    (fn inventory => HolbuildSourceIndex.inventory_package_name inventory = name)
    inventories

fun sources_for sources package =
  let val name = HolbuildProject.package_name package
  in List.filter (fn (source : HolbuildSourceIndex.source) => #package source = name) sources end

fun live_instance inventories sources package =
  let
    val name = HolbuildProject.package_name package
    val inventory =
      case inventory_named inventories name of
          SOME inventory => inventory
        | NONE => raise Error ("source discovery did not produce an inventory for package " ^ name)
    val requires_live_preparation =
      not (null (HolbuildProject.package_generators package))
    val component =
      HolbuildPackageComponent.make
        {package = package, inventory = inventory,
         requires_live_preparation = requires_live_preparation}
  in
    {package = package, component = component,
     sources = sources_for sources package}
  end

fun edge_text ({declaring_package, dependency_name, dependency_package} :
                HolbuildProjectGraph.edge) =
  framed [declaring_package, dependency_name, dependency_package]

fun context_id graph instances =
  hash
    (["holbuild-resolution-context-v1", HolbuildProjectGraph.root graph,
      HolbuildProjectGraph.hol graph] @
     map (fn instance =>
       HolbuildProject.package_identity
         (HolbuildPackageComponent.package_of instance) ^ ":" ^
       HolbuildPackageComponent.id
         (HolbuildPackageComponent.component_of instance)) instances @
     map edge_text (HolbuildProjectGraph.edges graph))

fun write_test_components instances resolution_context_id =
  case OS.Process.getEnv "HOLBUILD_TEST_PACKAGE_COMPONENTS" of
      NONE => ()
    | SOME path =>
        let
          val output = TextIO.openOut path
          fun write_instance instance =
            TextIO.output
              (output,
               HolbuildProject.package_name
                 (HolbuildPackageComponent.package_of instance) ^ " " ^
               HolbuildPackageComponent.id
                 (HolbuildPackageComponent.component_of instance) ^ "\n")
          val _ = List.app write_instance instances
          val _ = TextIO.output(output, "context " ^ resolution_context_id ^ "\n")
        in TextIO.closeOut output end

fun load LiveProvider {preparation, discovery} : project_components =
  let
    val graph = HolbuildPackagePrepare.graph preparation
    val inventories = HolbuildSourceIndex.inventories_of discovery
    val sources = HolbuildSourceIndex.sources_of discovery
    val instances =
      map (live_instance inventories sources) (HolbuildProjectGraph.packages graph)
    val resolution_context_id = context_id graph instances
    val _ = write_test_components instances resolution_context_id
  in
    {graph = graph,
     instances = instances,
     sources = sources,
     resolution_context_id = resolution_context_id}
  end

type node_analysis =
  {node_id : string,
   source_hash : string,
   symbolic_dependencies : HolbuildDependencies.t}

(* Live providers analyse only an explicitly requested frontier node. Future
   immutable and incremental providers implement this same request without
   changing component consumers. The immutable result keeps extracted symbolic
   facts separate from project-wide resolved edges. *)
fun analyse LiveProvider {source, cache_path, source_hash} : node_analysis =
  let
    val symbolic_dependencies =
      HolbuildDependencies.extract_cached_with_hash
        {cache_path = cache_path,
         source_path = #source_path (source : HolbuildSourceIndex.source),
         source_hash = source_hash}
  in
    {node_id = HolbuildSourceIndex.source_id source,
     source_hash = source_hash,
     symbolic_dependencies = symbolic_dependencies}
  end

fun analysis_dependencies ({symbolic_dependencies, ...} : node_analysis) =
  symbolic_dependencies

fun sources ({sources, ...} : project_components) = sources
fun instances ({instances, ...} : project_components) = instances
fun graph ({graph, ...} : project_components) = graph
fun resolution_context_id ({resolution_context_id, ...} : project_components) =
  resolution_context_id

end
