(* The re-submit record: what a remote check of one named theory needs to
   send that theory's action again after an edit of its script alone,
   without planning.  The last check whose batch held only that theory
   writes it in .holbuild/resubmit/<fingerprint>, the plan record's
   fingerprint: the stats and hashes of the files and directories the plan
   record watched, the script's dependency facts, and the parts of the
   action and its spec that the script's text doesn't decide.

   The fast path checks those stats as the plan record does (size, mtime,
   ctime, inode and device all equal; a racy entry checked in full), hashes
   the script, runs the dependency analyser on it, and rebuilds the action
   and its spec from the parts with the full path's own serializers.  It
   declines, for the full path, on anything else: a changed toolchain,
   action toolchain key, runtime identity or command line, a changed file
   or directory, changed dependency facts, a batch that came back for
   missing inputs, or an edit that landed while the check ran.

   For now it runs in shadow mode: the full path still plans, submits and
   decides every check, and the fast path's action is computed beside it
   and compared with the full path's, as are the outcomes, in the command
   summary's resubmit_shadow field.  With one batch for both, the fast
   path's outcome is the batch's answer for its action, so the outcomes
   differ only where the full path's tail changes the answer or the script
   changed under the check. *)
structure HolbuildResubmit =
struct

structure PR = HolbuildPlanRecord
structure BE = HolbuildBuildExec
structure BP = HolbuildBuildPlan
structure SI = HolbuildSourceIndex
structure J = HolbuildStatus

val format = "holbuild-resubmit-record-v1"

fun record_dir project =
  OS.Path.concat (OS.Path.concat (HolbuildProject.artifact_root project, ".holbuild"), "resubmit")

type record =
  {fingerprint : string,
   identity : string list,
   toolchain : {hol : PR.stamp, state : PR.stamp, racy : bool},
   members : (string * string) list,
   dirs : PR.dir list,
   files : PR.file list,
   input_dirs : PR.stamped_dir list,
   script : {path : string, cache_path : string, deps : HolbuildDependencies.t},
   action : {head : string list, tail : string list},
   spec : BE.spec_parts,
   scratch : string list,
   blobs : (string * string) list}

(* What, besides the plan record's inputs, decides the action and its spec:
   holbuild itself, the execution options (the command line, and source-load
   timing, which the plan record's fingerprint leaves out), the runtime the
   worker loads and the toolchain the action keys on. *)
fun identity {runtime, action_toolchain_key} =
  ["version=" ^ HolbuildVersion.version,
   "argv=" ^ String.concatWith "\003" (CommandLine.arguments ()),
   "source-load-timing=" ^ Bool.toString (BE.timing_source_loads ()),
   "runtime=" ^ runtime,
   "action-toolchain=" ^ action_toolchain_key]

(* ---- Encoding, as the plan record's ---- *)

fun encode ({fingerprint, identity, toolchain = {hol, state, racy}, members, dirs, files, input_dirs,
             script = {path, cache_path, deps}, action = {head, tail},
             spec = {runtime, toolchain_line, deps_key, target, body, options, timing, files = spec_files},
             scratch, blobs} : record) =
  String.concat
    ([format ^ "\n",
      PR.line "F" [fingerprint],
      PR.line "I" [PR.items identity],
      PR.line "T" [PR.stamp_text hol, PR.stamp_text state, PR.bool_text racy],
      PR.line "S" ([PR.check_text path, PR.check_text cache_path] @ PR.deps_fields deps),
      PR.line "a" [PR.items head, PR.items tail],
      PR.line "p" [PR.check_text runtime, PR.check_text toolchain_line, PR.check_text deps_key,
                   PR.items target, PR.items body, PR.items options, PR.items timing, PR.items spec_files],
      PR.line "x" [PR.items scratch]] @
     map (fn (path, kind) => PR.line "M" [PR.check_text path, kind]) members @
     map (fn {path, stamp, racy, entries} =>
            PR.line "D" [PR.check_text path, PR.stamp_text stamp, PR.bool_text racy, PR.items entries]) dirs @
     map (fn {path, stamp, racy, hash} =>
            PR.line "f" [PR.check_text path, PR.stamp_text stamp, PR.bool_text racy, hash]) files @
     map (fn {path, stamp, racy} =>
            PR.line "d" [PR.check_text path, PR.stamp_text stamp, PR.bool_text racy]) input_dirs @
     map (fn (path, hash) => PR.line "b" [PR.check_text path, hash]) blobs @
     [PR.line "E" [""]])

fun decode text : record =
  let
    val fingerprint = ref NONE val identity = ref NONE val toolchain = ref NONE val script = ref NONE
    val action = ref NONE val spec = ref NONE val scratch = ref NONE val complete = ref false
    val members = ref [] val dirs = ref [] val files = ref [] val input_dirs = ref [] val blobs = ref []
    val split = PR.split_items
    fun deps [loads, uses, extra_deps, extra_outputs, holdep_mentions] =
          {loads = split loads, uses = split uses, extra_deps = split extra_deps,
           extra_outputs = split extra_outputs, holdep_mentions = split holdep_mentions}
      | deps _ = PR.bad "dependency facts"
    fun entry [""] = ()
      | entry [] = ()
      | entry (first :: rest) =
          if !complete then PR.bad "text after the end marker"
          else
            case (String.sub (first, 0), String.extract (first, 1, NONE) :: rest) of
                (#"F", [value]) => fingerprint := SOME value
              | (#"I", [values]) => identity := SOME (split values)
              | (#"T", [hol, state, racy]) =>
                  toolchain := SOME {hol = PR.parse_stamp hol, state = PR.parse_stamp state, racy = PR.parse_bool racy}
              | (#"S", path :: cache_path :: facts) =>
                  script := SOME {path = path, cache_path = cache_path, deps = deps facts}
              | (#"a", [head, tail]) => action := SOME {head = split head, tail = split tail}
              | (#"p", [runtime, toolchain_line, deps_key, target, body, options, timing, spec_files]) =>
                  spec := SOME {runtime = runtime, toolchain_line = toolchain_line, deps_key = deps_key,
                                target = split target, body = split body, options = split options,
                                timing = split timing, files = split spec_files}
              | (#"x", [values]) => scratch := SOME (split values)
              | (#"M", [path, kind]) => members := (path, kind) :: !members
              | (#"D", [path, st, racy, entries]) =>
                  dirs := {path = path, stamp = PR.parse_stamp st, racy = PR.parse_bool racy,
                           entries = split entries} :: !dirs
              | (#"f", [path, st, racy, hash]) =>
                  files := {path = path, stamp = PR.parse_stamp st, racy = PR.parse_bool racy, hash = hash} :: !files
              | (#"d", [path, st, racy]) =>
                  input_dirs := {path = path, stamp = PR.parse_stamp st, racy = PR.parse_bool racy} :: !input_dirs
              | (#"b", [path, hash]) => blobs := (path, hash) :: !blobs
              | (#"E", [""]) => complete := true
              | (tag, _) => PR.bad ("line " ^ str tag)
    val _ = case PR.lines_fields text of
                [first] :: rest => if first = format then List.app entry rest else PR.bad ("format " ^ first)
              | _ => PR.bad "format"
    fun get (SOME value) = value
      | get NONE = PR.bad "a line is missing"
  in
    if not (!complete) then PR.bad "the record ends early"
    else
      {fingerprint = get (!fingerprint), identity = get (!identity), toolchain = get (!toolchain),
       members = rev (!members), dirs = rev (!dirs), files = rev (!files), input_dirs = rev (!input_dirs),
       script = get (!script), action = get (!action), spec = get (!spec), scratch = get (!scratch),
       blobs = rev (!blobs)}
  end

(* ---- Writing ---- *)

(* The record of a check whose batch held only the action EXPORTED, of the
   plan whose plan record is PLAN_RECORD. *)
fun write project (plan_record : PR.t) {runtime, action_toolchain_key}
          ({node, blobs, action_parts, spec_parts, ...} : BE.exported_spec) =
  let
    val source = BP.source_of node
    val path = #source_path source
    val sources = Vector.fromList (#sources plan_record)
    val deps =
      case List.find (fn (entry : PR.node_entry) =>
                        #source_path (Vector.sub (sources, #source entry)) = path) (#selected plan_record) of
          SOME entry => #deps entry
        | NONE => raise PR.Unrecordable ("no plan record entry for " ^ path)
    val {hol, state, racy, ...} = #toolchain plan_record
    val scratch = !BE.scratch_input_files
    (* The source and the scratch inputs are hashed afresh. *)
    val kept = List.filter (fn (file, _) => file <> path andalso not (List.exists (fn s => s = file) scratch)) blobs
    val record =
      {fingerprint = #fingerprint plan_record,
       identity = identity {runtime = runtime, action_toolchain_key = action_toolchain_key},
       toolchain = {hol = hol, state = state, racy = racy},
       members = #members plan_record, dirs = #dirs plan_record, files = #files plan_record,
       input_dirs = #input_dirs plan_record,
       script = {path = path, cache_path = BP.dependency_cache_path source, deps = deps},
       action = action_parts, spec = spec_parts, scratch = scratch, blobs = kept}
  in
    PR.write_record (OS.Path.concat (record_dir project, #fingerprint plan_record)) (encode record)
  end

(* ---- The fast path ---- *)

type ready =
  {input_key : string, spec_sha256 : string, text : string, blobs : (string * string) list,
   script : string, hash : string}

datatype attempt = Ready of ready | Declined of string

exception Decline of string
fun decline reason = raise Decline reason

fun same_stamp (a, b) = HolbuildStatCache.same_ident (a, b)

(* The action the record says a check of FINGERPRINT would send now, or why
   it can't say. *)
fun attempt {project, graph, tc : HolbuildToolchain.t, fingerprint} =
  let
    val text =
      case PR.read_optional (OS.Path.concat (record_dir project, fingerprint)) of
          SOME text => text
        | NONE => decline "no re-submit record"
    val record = decode text handle PR.Error msg => decline msg
    val _ = if #fingerprint record = fingerprint then () else decline "the record names other inputs"
    val {hol, state, racy} = #toolchain record
    val _ =
      case (PR.stamp (HolbuildToolchain.hol tc), PR.stamp (HolbuildToolchain.base_state tc)) of
          (SOME h, SOME s) =>
            if not racy andalso same_stamp (h, hol) andalso same_stamp (s, state) then ()
            else decline "the toolchain changed"
        | _ => decline "the toolchain is missing"
    val action_toolchain_key =
      HolbuildToolchain.action_toolchain_key tc (fn _ => decline "a tracing kernel keys on the exact toolchain")
    val runtime = BE.runtime_identity ()
    val _ =
      ListPair.appEq
        (fn (now, recorded) =>
           if now = recorded then ()
           else if String.isPrefix "action-toolchain=" now then decline "the action toolchain key changed"
           else if String.isPrefix "runtime=" now then decline "the runtime identity changed"
           else if String.isPrefix "argv=" now orelse String.isPrefix "source-load-timing=" now
           then decline "the execution options changed"
           else decline "holbuild changed")
        (identity {runtime = runtime, action_toolchain_key = action_toolchain_key}, #identity record)
      handle ListPair.UnequalLengths => decline "malformed re-submit record: identity"
    val _ = if PR.member_kinds graph = #members record then ()
            else decline "a package member appeared or vanished"
    val _ =
      List.app
        (fn {path, stamp = recorded, racy, entries} =>
           case PR.stamp path of
               NONE => decline ("directory vanished: " ^ path)
             | SOME st =>
                 if not racy andalso same_stamp (st, recorded) then ()
                 else if (SI.observed_entries path handle SI.Error _ => decline ("cannot list " ^ path)) = entries
                 then ()
                 else decline ("files added, removed or renamed in " ^ path))
        (#dirs record)
    val _ =
      List.app
        (fn {path, stamp = recorded, racy} =>
           case PR.stamp path of
               SOME st => if not racy andalso same_stamp (st, recorded) then ()
                          else decline ("extra-input directory changed: " ^ path)
             | NONE => decline ("extra-input directory vanished: " ^ path))
        (#input_dirs record)
    val {path = script, cache_path, deps} = #script record
    val recorded_hash = ref NONE
    val _ =
      List.app
        (fn {path, stamp = recorded, racy, hash} =>
           if path = script then recorded_hash := SOME hash
           else
             case PR.stamp path of
                 NONE => decline ("file vanished: " ^ path)
               | SOME st =>
                   if not racy andalso same_stamp (st, recorded) then ()
                   else if (HolbuildHash.file_sha256 path handle _ => decline ("cannot read " ^ path)) = hash then ()
                   else decline ("file changed: " ^ path))
        (#files record)
    val size = case PR.stamp script of SOME {size, ...} => size | NONE => decline ("cannot stat " ^ script)
    val hash = HolbuildHash.file_sha256 script handle _ => decline ("cannot read " ^ script)
    val _ =
      if SOME hash = !recorded_hash then ()
      else
        (HolbuildDependencies.configure_analyser_for_holdir (#holdir tc);
         case HolbuildDependencies.prefetch_cached_with_hash
                [{cache_path = cache_path, source_path = script, source_hash = hash}] of
             [SOME now] => if now = deps then () else decline "the script's dependency facts changed"
           | _ => decline ("cannot analyse " ^ script))
    val action_text = BP.action_text_of (#action record) hash
    val input_key = HolbuildToolchain.hash_text action_text
    val scratch = map (fn path => (path, HolbuildHash.file_sha256 path handle _ => decline ("cannot read " ^ path)))
                    (#scratch record)
    val text =
      BE.action_spec_assemble (#spec record)
        {input_key = input_key, action_text = action_text, source_hash = hash,
         source_size = Position.fromInt size, scratch_hashes = map #2 scratch}
  in
    Ready {input_key = input_key, spec_sha256 = HolbuildHash.string_sha256 text, text = text,
           blobs = (script, hash) :: #blobs record @ scratch,
           script = script, hash = hash}
  end
  handle Decline reason => Declined reason

(* ---- The shadow ---- *)

datatype shadow = Off | Shadow of {attempt : attempt, ms : LargeInt.int}

val shadow = ref Off
(* The first decline after the fast path was ready: the full path would
   have taken over then. *)
val late_decline = ref (NONE : string option)
(* Each compared field, whether it matched, and what differed. *)
val compared = ref ([] : (string * bool) list)
val detail = ref ([] : string list)
val exported_once = ref false
val followed_once = ref false
(* The batch's answer for the fast path's action: "done" or "failed". *)
val fast_state = ref (NONE : string option)
val json_events = ref ""

fun ready () =
  case !shadow of
      Shadow {attempt = Ready ready, ...} => if Option.isSome (!late_decline) then NONE else SOME ready
    | _ => NONE

fun note_decline reason =
  case (!shadow, !late_decline) of
      (Shadow {attempt = Ready _, ...}, NONE) => late_decline := SOME reason
    | _ => ()

fun compare field matched what =
  (compared := (field, matched) :: !compared;
   if matched then () else detail := (field ^ ": " ^ what) :: !detail)

(* Runs the fast path, timed, for a check that may take it, before the full
   path plans. *)
fun start inputs =
  let
    val began = Time.now ()
    val attempt = attempt (inputs ())
                  handle Thread.Interrupt => raise Thread.Interrupt
                       | e => Declined ("internal error: " ^ General.exnMessage e)
    val ms = Time.toMilliseconds (Time.- (Time.now (), began))
  in
    HolbuildToolchain.append_timing
      (HolbuildToolchain.phase_line_milliseconds
         {name = "resubmit.shadow.fast", status = case attempt of Ready _ => "ok" | Declined _ => "declined",
          ms = ms, fields = []});
    shadow := Shadow {attempt = attempt, ms = ms}
  end

fun stop () = shadow := Off

fun active () = case !shadow of Off => false | Shadow _ => true

(* Compares the full path's first export with the fast path's action, and
   says whether its batch held only ROOT, of which a record can be written.
   Any other batch differs from the fast path's. *)
fun compare_export root (exported : BE.exported_spec list) =
  if not (active ()) orelse !exported_once then false
  else
    let
      val _ = exported_once := true
      fun differ what = case ready () of SOME _ => compare "action_bytes" false what | NONE => ()
    in
      case exported of
          [spec as {node, ...}] =>
            if BP.key node <> BP.key root then
              (differ ("the full path sent " ^ BP.logical_name node ^ "'s action"); false)
            else
              ((case ready () of
                    SOME {input_key, spec_sha256, text, blobs, ...} =>
                      let
                        fun sorted pairs = BP.sort_pairs (fn ((a, _), (b, _)) => String.compare (a, b)) pairs
                        val what =
                          List.mapPartial (fn (differs, field) => if differs then SOME field else NONE)
                            [(input_key <> #input_key spec, "input key"),
                             (spec_sha256 <> #spec_sha256 spec orelse text <> #text spec, "spec"),
                             (sorted blobs <> sorted (#blobs spec), "blobs")]
                      in
                        compare "action_bytes" (null what) (String.concatWith ", " what ^ " differ")
                      end
                  | NONE => ());
               true)
        | _ => (differ ("the full path sent " ^ Int.toString (length exported) ^ " actions"); false)
    end

(* The batch's state for an action; the fast path's own is kept. *)
fun observe_action (key, state) =
  case ready () of
      SOME {input_key, ...} => if key = input_key andalso (state = "done" orelse state = "failed")
                               then fast_state := SOME state else ()
    | NONE => ()

(* After the first batch is followed, whether the script is still the one
   the fast path read: one that changed has it report on bytes no longer
   there. *)
fun check_followed () =
  if !followed_once then ()
  else
    (followed_once := true;
     case ready () of
         SOME {script, hash, ...} =>
           (HolbuildHolSharedCache.wait_test_gate "HOLBUILD_TEST_RESUBMIT_FOLLOWED_GATE";
            if (HolbuildHash.file_sha256 script handle _ => "") = hash then ()
            else (List.app (fn field => compare field false "the script changed under the check")
                    ["verdict", "diagnostics", "exit_status", "json_events"];
                  note_decline "an edit landed while the check ran"))
       | NONE => ())

fun observe_json line = if active () then json_events := HolbuildHash.string_sha256 (!json_events ^ line) else ()

(* The outcomes, compared at exit: the fast path's is the batch's answer
   for its action; the full path's is what the command reported.  A test
   names in HOLBUILD_TEST_RESUBMIT_SHADOW_PERTURB the fields whose fast
   value it spoils, to see each mismatch counted. *)
fun compare_outcomes () =
  case ready () of
      NONE => ()
    | SOME _ =>
        if not (!exported_once) then compare "action_bytes" false "the full path exported no action"
        else if not (List.exists (fn (field, matched) => field = "action_bytes" andalso matched) (!compared)) then ()
        else
          let
            val perturbed =
              String.tokens (fn c => c = #",") (getOpt (OS.Process.getEnv "HOLBUILD_TEST_RESUBMIT_SHADOW_PERTURB", ""))
            fun fast field value = if List.exists (fn f => f = field) perturbed then value ^ "~" else value
            val exit = !HolbuildCommandSummary.exit_code
            val full_verdict = case exit of 0 => "pass" | 1 => "fail" | _ => "none"
            val fast_verdict = case !fast_state of SOME "done" => "pass" | SOME "failed" => "fail" | _ => "none"
            val fast_exit = case fast_verdict of "pass" => "0" | "fail" => "1" | _ => "none"
            val diagnostics =
              HolbuildHash.string_sha256 (String.concatWith "\n" (map #3 (!HolbuildCommandSummary.failures)))
            fun field name full fast_value =
              let val fast_value = fast name fast_value
              in compare name (full = fast_value) ("full " ^ full ^ ", fast " ^ fast_value) end
          in
            field "verdict" full_verdict fast_verdict;
            field "diagnostics" diagnostics diagnostics;
            field "exit_status" (Int.toString exit) fast_exit;
            field "json_events" (!json_events) (!json_events)
          end

fun summary_fields () =
  case !shadow of
      Off => []
    | Shadow {attempt, ms} =>
        let
          val _ = compare_outcomes ()
          val fields = rev (!compared)
          val matches = length (List.filter #2 fields)
          val reason =
            case (attempt, !late_decline) of
                (Declined reason, _) => SOME reason
              | (_, SOME reason) => SOME reason
              | _ => NONE
        in
          [J.json_object_field "resubmit_shadow"
             ([J.json_string_field "state" (if Option.isSome reason then "declined" else "compared")] @
              J.json_optional_string_field "reason" reason @
              [J.json_int_field "fast_ms" (LargeInt.toInt ms),
               J.json_int_field "matches" matches,
               J.json_int_field "mismatches" (length fields - matches),
               J.json_object_field "fields"
                 (map (fn (name, matched) => J.json_string_field name (if matched then "match" else "mismatch")) fields)] @
              (case !detail of [] => [] | details => [J.json_string_field "detail" (String.concatWith "; " (rev details))]))]
        end

val _ = HolbuildCommandSummary.extra_fields := summary_fields
val _ = J.json_event := observe_json

end
