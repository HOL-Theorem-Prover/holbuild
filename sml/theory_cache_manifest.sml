structure HolbuildTheoryCacheManifest =
struct

exception Error of string

fun parse_positive_finite_real_text text =
  case Real.scan Substring.getc (Substring.full text) of
      SOME (value, rest) =>
        if Substring.isEmpty rest andalso Real.isFinite value andalso value > 0.0 then SOME value
        else NONE
    | NONE => NONE

fun parse_timeout_text text =
  if text = "none" then SOME NONE
  else Option.map SOME (parse_positive_finite_real_text text)

fun timeout_satisfies (requested : real option) built =
  case requested of
      NONE => true
    | SOME requested_seconds =>
        case built of
            SOME built_seconds => built_seconds <= requested_seconds
          | NONE => false

(* Older cache/checkpoint/action metadata predates explicit proof-timeout
   fields. Those artifacts were produced under the historical CLI default. *)
val legacy_default_proof_timeout = SOME 2.5

fun extra_path_from_blob_role role =
  if String.isPrefix "extra:" role then
    SOME (HolbuildAnalysisProtocol.unescape (String.extract(role, size "extra:", NONE)))
  else NONE

fun cache_manifest_lines text = String.tokens (fn c => c = #"\n") text

fun is_hex_digit c =
  (#"0" <= c andalso c <= #"9") orelse
  (#"a" <= c andalso c <= #"f") orelse
  (#"A" <= c andalso c <= #"F")

fun all_chars pred text =
  let
    fun loop i = i >= size text orelse (pred (String.sub(text, i)) andalso loop (i + 1))
  in
    loop 0
  end

fun valid_sha1_text text = size text = 40 andalso all_chars is_hex_digit text

fun require_sha1 role hash =
  if valid_sha1_text hash then hash
  else raise Error ("cache manifest invalid " ^ role ^ " blob hash: " ^ hash)

fun known_blob_role role =
  role = "sig" orelse role = "sml" orelse role = "sml-template" orelse
  role = "dat" orelse role = "trace" orelse Option.isSome (extra_path_from_blob_role role)

fun add_manifest_blob role hash blobs =
  if not (known_blob_role role) then
    raise Error ("cache manifest unknown blob role: " ^ role)
  else if List.exists (fn (role', _) => role' = role) blobs then
    raise Error ("cache manifest duplicate blob role: " ^ role)
  else
    (role, require_sha1 role hash) :: blobs

fun blob_from_manifest role blobs =
  case List.find (fn (role', _) => role' = role) blobs of
      SOME (_, hash) => hash
    | NONE => raise Error ("cache manifest missing blob role: " ^ role)

fun sml_blob_from_manifest blobs =
  case List.find (fn (role, _) => role = "sml") blobs of
      SOME (_, hash) => hash
    | NONE => blob_from_manifest "sml-template" blobs

fun transient_stage_mldep dep = String.isSubstring "/.holbuild/stage/" dep

fun valid_mldep_name dep =
  dep <> "" andalso all_chars (fn c => not (Char.isSpace c)) dep

fun reject_transient_cache_mldeps mldeps =
  case List.find transient_stage_mldep mldeps of
      SOME dep => raise Error ("cache manifest contains transient stage mldep: " ^ dep)
    | NONE => ()

fun add_mldep dep deps =
  if not (valid_mldep_name dep) then
    raise Error ("cache manifest invalid mldep: " ^ dep)
  else if List.exists (fn existing => existing = dep) deps then deps
  else dep :: deps

fun add_parent parent parents = add_mldep parent parents

fun parse_cache_manifest_line input_key line (saw_header, saw_input, saw_kind, saw_metadata, blobs, parents, mldeps) =
  if line = "holbuild-cache-action-v4" orelse line = "holbuild-cache-action-v3" then
    if saw_header then raise Error "cache manifest duplicate header"
    else (true, saw_input, saw_kind, saw_metadata, blobs, parents, mldeps)
  else if line = "holbuild-cache-action-v2" then
    raise Error "cache manifest missing generated theory load metadata"
  else if line = "input_key=" ^ input_key then
    if saw_input then raise Error "cache manifest duplicate input key"
    else (saw_header, true, saw_kind, saw_metadata, blobs, parents, mldeps)
  else if String.isPrefix "input_key=" line then
    raise Error "cache manifest input key mismatch"
  else if line = "kind=theory" then
    if saw_kind then raise Error "cache manifest duplicate kind"
    else (saw_header, saw_input, true, saw_metadata, blobs, parents, mldeps)
  else if String.isPrefix "kind=" line then
    raise Error "cache manifest unsupported kind"
  else if line = "load-metadata-v1" then
    if saw_metadata then raise Error "cache manifest duplicate load metadata marker"
    else (saw_header, saw_input, saw_kind, true, blobs, parents, mldeps)
  else if line = "mldeps" then
    raise Error "cache manifest missing generated theory load metadata"
  else if String.isPrefix "proof-timeout=" line then
    (saw_header, saw_input, saw_kind, saw_metadata, blobs, parents, mldeps)
  else
    case String.tokens Char.isSpace line of
        ["parent", parent] => (saw_header, saw_input, saw_kind, saw_metadata, blobs, add_parent parent parents, mldeps)
      | ["mldep", dep] => (saw_header, saw_input, saw_kind, saw_metadata, blobs, parents, add_mldep dep mldeps)
      | ["blob", role, hash] => (saw_header, saw_input, saw_kind, saw_metadata, add_manifest_blob role hash blobs, parents, mldeps)
      | _ => raise Error ("cache manifest unknown line: " ^ line)

fun cache_manifest_blobs_from_lines input_key lines =
  let
    val (saw_header, saw_input, saw_kind, saw_metadata, blobs, parents, mldeps) =
      List.foldl (fn (line, state) => parse_cache_manifest_line input_key line state)
                 (false, false, false, false, [], [], []) lines
    val _ = if saw_header then () else raise Error "cache manifest missing header"
    val _ = if saw_input then () else raise Error "cache manifest missing input key"
    val _ = if saw_kind then () else raise Error "cache manifest missing kind"
    val _ = if saw_metadata then () else raise Error "cache manifest missing generated theory load metadata"
  in
    let val stable_mldeps = rev mldeps
        val stable_parents = rev parents
        val _ = reject_transient_cache_mldeps stable_mldeps
    in
      {sig_hash = blob_from_manifest "sig" blobs,
       sml_hash = sml_blob_from_manifest blobs,
       dat_hash = blob_from_manifest "dat" blobs,
       trace_hash = Option.map #2 (List.find (fn (role, _) => role = "trace") blobs),
       extra_hashes =
         List.mapPartial
           (fn (role, hash) => Option.map (fn path => (path, hash))
                                          (extra_path_from_blob_role role))
           (rev blobs),
       parents = stable_parents,
       mldeps = stable_mldeps}
    end
  end

fun explicit_cache_manifest_proof_timeouts lines =
  List.mapPartial
    (fn line =>
        if String.isPrefix "proof-timeout=" line then
          case parse_timeout_text (String.extract(line, size "proof-timeout=", NONE)) of
              SOME timeout => SOME timeout
            | NONE => raise Error "cache manifest invalid proof-timeout"
        else NONE)
    lines

fun cache_manifest_proof_timeout lines =
  case explicit_cache_manifest_proof_timeouts lines of
      [] => legacy_default_proof_timeout
    | [timeout] => timeout
    | _ => raise Error "cache manifest duplicate proof-timeout"

fun cache_manifest_proof_timeout_text input_key text =
  (cache_manifest_blobs_from_lines input_key (cache_manifest_lines text);
   cache_manifest_proof_timeout (cache_manifest_lines text))

fun cache_manifest_contract input_key text =
  let
    val lines = cache_manifest_lines text
    val _ = cache_manifest_blobs_from_lines input_key lines
    val proof_timeout = cache_manifest_proof_timeout lines
    val fields = String.fields (fn c => c = #"\n") text
    val non_timeout_fields =
      List.filter (fn line => not (String.isPrefix "proof-timeout=" line)) fields
  in
    {proof_timeout = proof_timeout,
     non_timeout_text = String.concatWith "\n" non_timeout_fields}
  end

fun timeout_at_least_as_strong candidate reference =
  timeout_satisfies reference candidate

end
