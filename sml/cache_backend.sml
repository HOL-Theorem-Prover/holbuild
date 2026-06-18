structure HolbuildCacheBackend =
struct

datatype publish_result = Published | AlreadyPresent | Conflict of string | Skipped

datatype fetch_result = Hit | Miss | Corrupt of string

end

signature HOLBUILD_CACHE_BACKEND =
sig
  type t

  val get_action : t -> string -> string option
  val put_action : t -> {key : string, text : string} -> HolbuildCacheBackend.publish_result

  val has_blob : t -> string -> bool
  val fetch_blob : t -> {hash : string, dst : string} -> HolbuildCacheBackend.fetch_result
  val publish_blob : t -> {hash : string, src : string} -> HolbuildCacheBackend.publish_result
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

  val ensure_layout : t -> unit
  val write_action : t -> {key : string, text : string} -> unit
  val remove_action : t -> string -> unit
  val touch_action : t -> string -> unit
  val with_action_publish_lock : t -> string -> (unit -> 'a) -> (unit -> 'a) -> 'a
end
