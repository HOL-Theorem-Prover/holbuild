structure HolbuildPackageComponent =
struct

exception Error of string

datatype validation_strategy =
    MutableWorkingTree
  | TrustedImmutable of {snapshot_id : string}

datatype symbolic_reason =
    DeclaredDependency
  | DeclaredLoad
  | SignatureCompanion
  | DeclaredExtraInput

datatype symbolic_fact =
    LogicalReference of
      {from_node : string, logical_name : string, reason : symbolic_reason}
  | InputReference of
      {from_node : string, relative_path : string, reason : symbolic_reason}

type t =
  { id : string,
    package_definition_id : string,
    inventory_id : string,
    validation : validation_strategy,
    requires_live_preparation : bool,
    inventory : HolbuildSourceIndex.package_inventory,
    symbolic_facts : symbolic_fact list }

type instance =
  { package : HolbuildProject.package,
    component : t,
    sources : HolbuildSourceIndex.source list }

fun frame text = Int.toString (size text) ^ ":" ^ text
fun framed fields = String.concat (map frame fields)
fun list_fields tag values = [tag, Int.toString (length values)] @ values
fun hash fields = HolbuildHash.string_sha256 (framed fields)

fun kind_text HolbuildSourceIndex.TheoryScript = "theory"
  | kind_text HolbuildSourceIndex.Sml = "sml"
  | kind_text HolbuildSourceIndex.Sig = "sig"

fun node_text (node : HolbuildSourceIndex.source_node) =
  framed [HolbuildSourceIndex.node_id node,
          #package_id node, #relative_path node, #logical_name node,
          kind_text (#kind node), HolbuildSourceIndex.origin_tag (#origin node),
          #policy_id node, #execution_policy_id node]

fun inventory_id inventory =
  hash (["holbuild-package-inventory-v1",
         HolbuildSourceIndex.inventory_package_id inventory] @
        list_fields "nodes"
          (map node_text (HolbuildSourceIndex.inventory_nodes inventory)))

fun validation_for package =
  let
    val provenance = HolbuildProject.package_provenance package
    val snapshot = HolbuildPackageProvenance.snapshot provenance
  in
    case snapshot of
        HolbuildPackageProvenance.WorkingTreeSnapshot => MutableWorkingTree
      | _ => TrustedImmutable
               {snapshot_id = HolbuildHash.string_sha256
                                (HolbuildPackageProvenance.snapshot_text snapshot)}
  end

fun matching_signature nodes (node : HolbuildSourceIndex.source_node) =
  #kind node = HolbuildSourceIndex.Sml andalso
  List.exists
    (fn (candidate : HolbuildSourceIndex.source_node) =>
      #kind candidate = HolbuildSourceIndex.Sig andalso
      #logical_name candidate = #logical_name node)
    nodes

fun facts_for_node nodes (node : HolbuildSourceIndex.source_node) =
  let
    val from = HolbuildSourceIndex.node_id node
    val policy = #policy node
    fun logical reason name =
      LogicalReference {from_node = from, logical_name = name, reason = reason}
    fun input (HolbuildProject.ExtraInput {path}) =
      InputReference {from_node = from, relative_path = path,
                      reason = DeclaredExtraInput}
    val companion =
      if matching_signature nodes node then
        [logical SignatureCompanion (#logical_name node)]
      else []
  in
    map (logical DeclaredDependency) (HolbuildProject.action_deps policy) @
    map (logical DeclaredLoad) (HolbuildProject.action_loads policy) @
    companion @ map input (HolbuildProject.action_extra_inputs policy)
  end

fun make {package, inventory, requires_live_preparation} =
  let
    val package_definition_id =
      HolbuildPackageDefinition.content_id
        (HolbuildProject.package_definition_of package)
    val inventory_id = inventory_id inventory
    val nodes = HolbuildSourceIndex.inventory_nodes inventory
    val symbolic_facts = List.concat (map (facts_for_node nodes) nodes)
    val validation = validation_for package
    val id =
      hash ["holbuild-package-component-v1", package_definition_id,
            inventory_id]
  in
    {id = id,
     package_definition_id = package_definition_id,
     inventory_id = inventory_id,
     validation = validation,
     requires_live_preparation = requires_live_preparation,
     inventory = inventory,
     symbolic_facts = symbolic_facts}
  end

fun id ({id, ...} : t) = id
fun inventory_id_of ({inventory_id, ...} : t) = inventory_id
fun inventory ({inventory, ...} : t) = inventory
fun symbolic_facts ({symbolic_facts, ...} : t) = symbolic_facts
fun validation ({validation, ...} : t) = validation
fun component_of ({component, ...} : instance) = component
fun package_of ({package, ...} : instance) = package
fun sources_of ({sources, ...} : instance) = sources

end
