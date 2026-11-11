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
  (* The blob hash a manifest line references, if any. *)
  val blob_ref : string -> string option

  val copy_binary : string -> string -> unit
  val link_or_copy : {src : string, dst : string} -> unit
  val verify_blob : t -> string -> bool
  (* Takes ownership of a temporary file whose bytes have already been
     verified against hash. Other publishers must use publish_blob. *)
  val consume_verified_blob : t -> {hash : string, src : string} -> HolbuildCacheBackend.publish_result

  val ensure_layout : t -> unit
  (* Unlocked operations for callers holding with_action_publish_lock.
     put_action acquires that lock itself and must not be nested inside it. *)
  val write_action : t -> {key : string, text : string} -> unit
  val remove_action : t -> string -> unit
  val touch_action : t -> string -> unit
  val with_action_publish_lock : t -> string -> (unit -> 'a) -> (unit -> 'a) -> 'a
  (* Waits for a concurrent publisher before running the callback. *)
  val with_action_publish_lock_wait : t -> string -> (unit -> 'a) -> 'a

  (* Bytes written into the cache since its last GC, counting this process's
     writes not yet flushed. *)
  val growth_since_gc : t -> Position.int
  (* Appends this process's writes to each cache's growth journal. *)
  val flush_growth : unit -> unit
  (* Called by every cache GC: the cache counts as just collected. *)
  val reset_growth : t -> unit
  (* Drops this process's unflushed writes, for a throwaway cache that is
     removed before the process exits. *)
  val discard_growth : t -> unit
end
