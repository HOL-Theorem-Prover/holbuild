structure HolbuildComponentProvider =
struct

exception Error of string

datatype provider = LiveProvider

type project_components =
  { provider : provider,
    graph : HolbuildProjectGraph.t,
    instances : HolbuildPackageComponent.instance list,
    sources : HolbuildSourceIndex.t,
    resolution_context_id : string }

fun frame text = Int.toString (size text) ^ ":" ^ text
fun framed fields = String.concat (map frame fields)
fun list_fields tag values = [tag, Int.toString (length values)] @ values
fun insert_string value values =
  case values of
      [] => [value]
    | existing :: rest =>
        if String.compare(value, existing) = LESS then value :: values
        else existing :: insert_string value rest
fun sort_strings values =
  List.foldl (fn (value, sorted) => insert_string value sorted) [] values
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

fun resolution_context_text graph instances =
  let
    val bindings =
      sort_strings
        (map (fn instance =>
          framed
            [HolbuildProject.package_identity
               (HolbuildPackageComponent.package_of instance),
             HolbuildPackageComponent.id
               (HolbuildPackageComponent.component_of instance)]) instances)
    val edges = sort_strings (map edge_text (HolbuildProjectGraph.edges graph))
  in
    framed
      (["holbuild-resolution-context-v2", HolbuildProjectGraph.root graph,
        HolbuildProjectGraph.hol graph] @
       list_fields "bindings" bindings @ list_fields "edges" edges)
  end

fun context_id graph instances =
  HolbuildHash.string_sha256 (resolution_context_text graph instances)

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
    {provider = LiveProvider,
     graph = graph,
     instances = instances,
     sources = sources,
     resolution_context_id = resolution_context_id}
  end

type node_analysis =
  {node_id : string,
   source_hash : string,
   symbolic_dependencies : HolbuildDependencies.t}

type analysis_state =
  {provider : provider,
   hashes : (string * string) list ref,
   analyses : (string * node_analysis) list ref}

fun new_analysis_state provider : analysis_state =
  {provider = provider, hashes = ref [], analyses = ref []}

fun lookup key entries =
  Option.map #2 (List.find (fn (candidate, _) => candidate = key) entries)

fun analysis_key (source : HolbuildSourceIndex.source) =
  #package source ^ "\000" ^ HolbuildSourceIndex.source_id source

fun source_hash ({hashes, ...} : analysis_state) source =
  let val key = analysis_key source
  in
    case lookup key (!hashes) of
        SOME value => value
      | NONE =>
          let
            val value = HolbuildToolchain.time_phase "source.hash"
                          (fn () => HolbuildHash.file_sha1 (#source_path source))
          in hashes := (key, value) :: !hashes; value end
  end

(* Live providers analyse only an explicitly requested frontier node. Future
   immutable and incremental providers implement this same request without
   changing component consumers. The immutable result keeps extracted symbolic
   facts separate from project-wide resolved edges. *)
fun analyse state {source, cache_path} : node_analysis =
  case #provider (state : analysis_state) of LiveProvider =>
  let
    val id = HolbuildSourceIndex.source_id source
    val key = analysis_key source
  in
    case lookup key (!(#analyses (state : analysis_state))) of
        SOME analysis => analysis
      | NONE =>
          let
            val source_hash = source_hash state source
            val symbolic_dependencies =
              HolbuildToolchain.time_phase "dependency.extract"
                (fn () => HolbuildDependencies.extract_cached_with_hash
                  {cache_path = cache_path,
                   source_path = #source_path (source : HolbuildSourceIndex.source),
                   source_hash = source_hash})
            val analysis =
              {node_id = id, source_hash = source_hash,
               symbolic_dependencies = symbolic_dependencies}
          in
            #analyses state := (key, analysis) :: !(#analyses state);
            analysis
          end
  end

fun analysis_dependencies ({symbolic_dependencies, ...} : node_analysis) =
  symbolic_dependencies

fun provider ({provider, ...} : project_components) = provider
fun component_symbolic_facts ({instances, ...} : project_components) source =
  let
    val package_name = #package (source : HolbuildSourceIndex.source)
    val node_id = HolbuildSourceIndex.source_id source
    fun matching_instance instance =
      HolbuildProject.package_name (HolbuildPackageComponent.package_of instance) =
      package_name
    fun matching_fact fact =
      case fact of
          HolbuildPackageComponent.LogicalReference {from_node, ...} =>
            from_node = node_id
        | HolbuildPackageComponent.InputReference {from_node, ...} =>
            from_node = node_id
  in
    case List.find matching_instance instances of
        NONE => raise Error ("component instance is missing for package " ^ package_name)
      | SOME instance =>
          List.filter matching_fact
            (HolbuildPackageComponent.symbolic_facts
              (HolbuildPackageComponent.component_of instance))
  end
fun sources ({sources, ...} : project_components) = sources
fun instances ({instances, ...} : project_components) = instances
fun graph ({graph, ...} : project_components) = graph
fun resolution_context_id ({resolution_context_id, ...} : project_components) =
  resolution_context_id
fun canonical_resolution_context ({graph, instances, ...} : project_components) =
  resolution_context_text graph instances

end
