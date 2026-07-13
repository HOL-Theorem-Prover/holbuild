structure HolbuildPackageProvenance =
struct

datatype source_snapshot =
    WorkingTreeSnapshot
  | GitSnapshot of {git : string, rev : string}
  | ToolchainSnapshot of
      {git : string, rev : string,
       kernel_variant : HolbuildHolToolchainConfig.kernel_variant}

datatype definition_provenance =
    RootManifest
  | DependencyManifest of {dependency : string}
  | ShimManifest of {from : string, path : string, manifest : string}
  | ImplicitHolManifest

datatype retrieval_provenance =
    WorkingTreeRetrieval
  | DeclaredGitRetrieval of {git : string}
  | AlternateGitRetrieval of {declared_git : string, retrieval_git : string}
  | TrustedPathRetrieval of {path : string}
  | ToolchainCacheRetrieval

datatype package_origin =
    RootOrigin
  | DependencyOrigin of {dependency : string}
  | ShimOrigin of {dependency : string, from : string}
  | ImplicitHolOrigin of
      {git : string, rev : string,
       kernel_variant : HolbuildHolToolchainConfig.kernel_variant}

type materialization =
  {source_root : string, package_root : string, manifest : string}

type t =
  {snapshot : source_snapshot,
   definition : definition_provenance,
   retrieval : retrieval_provenance,
   materialization : materialization,
   origin : package_origin}

fun variant_text HolbuildHolToolchainConfig.StandardKernel = "standard"
  | variant_text HolbuildHolToolchainConfig.TracingKernel = "tracing"

fun atom text = Int.toString (size text) ^ ":" ^ text
fun fields values = String.concatWith "|" (map atom values)
fun snapshot_text WorkingTreeSnapshot = "working-tree"
  | snapshot_text (GitSnapshot {git, rev}) = fields ["git-v1", git, rev]
  | snapshot_text (ToolchainSnapshot {git, rev, kernel_variant}) =
      fields ["toolchain-v1", git, rev, variant_text kernel_variant]
fun definition_text RootManifest = "root-manifest"
  | definition_text (DependencyManifest {dependency}) =
      fields ["dependency-manifest", dependency]
  | definition_text (ShimManifest {from, path, manifest}) =
      fields ["shim-manifest", from, path, manifest]
  | definition_text ImplicitHolManifest = "implicit-hol-manifest"
fun origin_text RootOrigin = "root"
  | origin_text (DependencyOrigin {dependency}) = "dependency:" ^ dependency
  | origin_text (ShimOrigin {dependency, from}) =
      "shim:" ^ dependency ^ " from " ^ from
  | origin_text (ImplicitHolOrigin {git, rev, kernel_variant}) =
      "implicit-hol:" ^ variant_text kernel_variant ^ ":" ^ git ^ "@" ^ rev
fun retrieval_text WorkingTreeRetrieval = "working-tree"
  | retrieval_text (DeclaredGitRetrieval {git}) = "declared-git:" ^ git
  | retrieval_text (AlternateGitRetrieval {declared_git, retrieval_git}) =
      "alternate-git:" ^ retrieval_git ^ " (declared " ^ declared_git ^ ")"
  | retrieval_text (TrustedPathRetrieval {path}) = "trusted-path:" ^ path
  | retrieval_text ToolchainCacheRetrieval = "toolchain-cache"

(* Machine paths are deliberately excluded. Mutable working trees rely on live
   validation; immutable snapshots provide their own content oracle. *)
fun semantic_text definition_id
      ({snapshot, definition, origin, ...} : t) =
  fields ["package-instance-v1", definition_id, snapshot_text snapshot,
          definition_text definition, origin_text origin]
fun identity definition_id provenance =
  HolbuildHash.string_sha256 (semantic_text definition_id provenance)

fun source_root ({materialization = {source_root, ...}, ...} : t) = source_root
fun package_root ({materialization = {package_root, ...}, ...} : t) = package_root
fun manifest ({materialization = {manifest, ...}, ...} : t) = manifest
fun origin ({origin, ...} : t) = origin
fun is_implicit_hol provenance =
  case origin provenance of ImplicitHolOrigin _ => true | _ => false

end
