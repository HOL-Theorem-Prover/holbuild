structure HolbuildCacheBackend =
struct

type action_key = string
type blob_hash = string
type manifest_text = string
type local_path = string

datatype publish_result = Published | AlreadyPresent | Conflict of string | Skipped

datatype action_publish_policy = PutIfAbsent | PutIfAbsentOrSame

datatype fetch_result = Hit | Miss | Corrupt of string

end

signature HOLBUILD_CACHE_BACKEND =
sig
  type t

  val get_action : t -> HolbuildCacheBackend.action_key -> HolbuildCacheBackend.manifest_text option
  val put_action : t -> HolbuildCacheBackend.action_publish_policy ->
                    {key : HolbuildCacheBackend.action_key,
                     text : HolbuildCacheBackend.manifest_text} -> HolbuildCacheBackend.publish_result

  val has_blob : t -> HolbuildCacheBackend.blob_hash -> bool

  (* Blob transfer crosses the backend/local-filesystem boundary.  dst and src
     are local filesystem paths, not backend object names. *)
  val fetch_blob : t -> {hash : HolbuildCacheBackend.blob_hash,
                         dst : HolbuildCacheBackend.local_path} -> HolbuildCacheBackend.fetch_result
  val publish_blob : t -> {hash : HolbuildCacheBackend.blob_hash,
                           src : HolbuildCacheBackend.local_path} -> HolbuildCacheBackend.publish_result
end

signature HOLBUILD_FS_CACHE_BACKEND =
sig
  include HOLBUILD_CACHE_BACKEND

  exception Error of string

  val filesystem : string -> t
  val default : unit -> t
  val root : t -> string

  val actions_dir : t -> string
  val blobs_dir : t -> string
  val tmp_dir : t -> string
  val locks_dir : t -> string
  val action_dir : t -> string -> string
  val action_manifest : t -> string -> string
  val blob_path : t -> string -> string

  val copy_binary : string -> string -> unit
  val link_or_copy : {src : string, dst : string} -> unit
  val verify_blob : t -> string -> bool

  val ensure_layout : t -> unit
  val write_action : t -> {key : string, text : string} -> unit
  val remove_action : t -> string -> unit
  val touch_action : t -> string -> unit
  val with_action_publish_lock : t -> string -> (unit -> 'a) -> (unit -> 'a) -> 'a
end
