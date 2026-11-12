structure HolbuildCommandSummary =
struct

structure BP = HolbuildBuildPlan
structure PR = HolbuildPlanRecord
structure J = HolbuildStatus

val started = ref Time.zeroTime
val exit_code = ref 1
val destination = ref (NONE : string option)
val plans = ref ([] : string list)
val follows = ref ([] : string list)
val batches = ref (Binaryset.empty String.compare)
val actions = ref (Binarymap.mkDict String.compare : (string, string) Binarymap.dict)
val counts = Array.array (4, 0)
val mutex = Mutex.mutex ()

(* Polling cannot certify that no execution occurred between snapshots. *)
fun fleet_history_complete () = Binaryset.isEmpty (!batches) andalso Binarymap.numItems (!actions) = 0

fun object fields = "{" ^ String.concatWith "," fields ^ "}"
fun array values = "[" ^ String.concatWith "," values ^ "]"
fun number name n = "\"" ^ name ^ "\":" ^ LargeInt.toString n
fun timestamp name t = number name (Time.toMilliseconds t)
fun pid () = LargeInt.toString (SysWord.toLargeInt (Posix.Process.pidToWord (Posix.ProcEnv.getpid ())))

fun locked f =
  (Mutex.lock mutex; (f () before Mutex.unlock mutex)
   handle e => (Mutex.unlock mutex; raise e))

fun best_effort f =
  f () handle IO.Io _ => () | OS.SysErr _ => () | PR.Unencodable _ => ()

fun outcome result = locked (fn () =>
  let val index = case result of J.Built => SOME 0 | J.Restored => SOME 1
                  | J.RestoredRemote => SOME 2 | J.UpToDate => SOME 3 | J.Inspected => NONE
  in Option.app (fn i => Array.update (counts, i, Array.sub (counts, i) + 1)) index end)

(* These are diagnostic snapshots of the sources actually planned, not
   transitive action keys. Keep observations across changes of target. *)
fun read_sources path =
  case PR.read_optional path of
      NONE => NONE
    | SOME text =>
        let fun add ([key, hash], map) = Binarymap.insert (map, key, hash)
              | add (_, map) = map
        in SOME (List.foldl add (Binarymap.mkDict String.compare) (PR.lines_fields text)) end

fun kind node =
  case #kind (BP.source_of node) of
      HolbuildSourceIndex.TheoryScript => "theory"
    | HolbuildSourceIndex.Sml => "sml"
    | HolbuildSourceIndex.Sig => "sig"

fun observe_plan project plan = best_effort (fn () =>
  let
    val root = HolbuildProject.artifact_root project
    val state = OS.Path.concat (root, ".holbuild/command-sources")
    val old = read_sources state
    val previous = getOpt (old, Binarymap.mkDict String.compare)
    val selected = BP.selected_nodes plan
    (* Observe the planner's hashes without preparing outputs or invoking generators. *)
    val hashes = !(#hashes (BP.analysis_state plan))
    fun observed node =
      Option.map (fn hash => (node, hash))
        (Binarymap.peek (hashes, HolbuildComponentProvider.analysis_key (BP.source_of node)))
    val current = List.mapPartial observed selected
    val known = previous
    val updated = List.foldl (fn ((node, hash), map) => Binarymap.insert (map, BP.key node, hash)) known current
    val nodes = List.foldl (fn (node, map) => Binarymap.insert (map, BP.key node, node))
                          (Binarymap.mkDict String.compare) selected
    fun cone node =
      let
        fun visit ([], seen) = seen
          | visit (key :: rest, seen) =
              if Binaryset.member (seen, key) then visit (rest, seen)
              else
                let val next = case Binarymap.peek (nodes, key) of NONE => []
                      | SOME current => map #from_node (BP.reverse_dependency_edges plan current)
                in visit (next @ rest, Binaryset.add (seen, key)) end
        val reached = visit ([BP.key node], Binaryset.empty String.compare)
      in length (List.filter (fn n => kind n = "theory" andalso Binaryset.member (reached, BP.key n)) selected) end
    fun changed (node, hash) =
      case Binarymap.peek (previous, BP.key node) of SOME old_hash => old_hash <> hash | NONE => false
    fun unseen (node, _) = not (Option.isSome (Binarymap.peek (previous, BP.key node)))
    fun source (node, hash) = object
      [J.json_string_field "package" (BP.package node),
       J.json_string_field "path" (BP.relative_path node),
       J.json_string_field "name" (BP.logical_name node),
       J.json_string_field "kind" (kind node),
       J.json_string_field "sha256" hash,
       (if unseen (node, hash) then "\"affected_theories_in_plan\":null"
        else J.json_int_field "affected_theories_in_plan" (cone node))]
    val entry = object
      [J.json_string_field "project" root,
       J.json_bool_field "cold_worktree" (not (Option.isSome old)),
       J.json_int_field "selected_sources" (length selected),
       J.json_bool_field "source_hashes_complete" (length current = length selected),
       J.json_int_field "universe_sources" (length (BP.universe_nodes plan)),
       J.json_string_field "cone_scope" "requested_plan_including_self",
       "\"changed_sources\":" ^ array (map source (List.filter changed current)),
       "\"newly_observed_sources\":" ^ array (map source (List.filter unseen current))]
    val text = String.concat (map (fn (key, hash) => PR.line "" [PR.check_text key, hash]) (Binarymap.listItems updated))
    val _ = PR.write_record state text
  in
    plans := entry :: !plans;
    if Option.isSome (!destination) then () else
      destination := SOME (OS.Path.concat (root, ".holbuild/commands/" ^
        LargeInt.toString (Time.toMicroseconds (!started)) ^ "-" ^ pid () ^ ".json"))
  end)

fun integer_field name text =
  let val needle = "\"" ^ name ^ "\""
  in
    case J.find_substring needle text of
        NONE => NONE
      | SOME i =>
          let val after = Substring.dropl Char.isSpace (Substring.extract (text, i + size needle, NONE))
          in case Substring.getc after of
              SOME (#":", rest) => LargeInt.fromString (Substring.string (Substring.dropl Char.isSpace rest))
            | _ => NONE
          end
  end

fun observe_action (batch, line) =
  let
    val field = fn name => HolbuildRemoteExec.json_string_field name line
    val key = getOpt (field "input_key", "")
    val attempt = getOpt (integer_field "attempts" line, 0)
    val began = integer_field "started" line
    val identity = batch ^ "\000" ^ key
    fun retain suffix observation action =
      let val id = identity ^ "\000" ^ suffix
      in if Option.isSome (Binarymap.peek (!actions, id)) then () else
           actions := Binarymap.insert (!actions, id, object
             [J.json_string_field "batch_id" batch,
              J.json_string_field "observation" observation,
              "\"action\":" ^ action])
      end
    val raw = Substring.string (Substring.dropr Char.isSpace (Substring.full line))
    val marker = object [J.json_string_field "input_key" key,
      J.json_string_field "state" "running", number "attempts" attempt]
    val failure_fields = List.mapPartial (fn name =>
      case field name of SOME text => if text = "" then NONE else SOME (J.json_string_field name text)
                       | NONE => NONE) ["last_failure", "failure_detail", "log_sha256"]
  in
    (* A retry snapshot may be the only observation of the preceding result.
       Retain that payload independently, without assigning it to an attempt. *)
    (case began of
         SOME ms => retain ("result\000" ^ LargeInt.toString ms) "result" raw
       | NONE =>
           if not (null failure_fields) then
             retain ("untimed-failure\000" ^ HolbuildSha256.string_hex (object failure_fields)) "untimed" raw
           else if field "state" = SOME "running" then () else
             retain ("untimed\000" ^ HolbuildSha256.string_hex raw) "untimed" raw);
    if field "state" = SOME "running" then
      retain ("attempt\000" ^ LargeInt.toString attempt) "attempt" marker
    else ()
  end

fun observe_follow (batch, start, finish) =
  (batches := Binaryset.add (!batches, batch);
   follows := object [J.json_string_field "batch_id" batch,
     timestamp "started_at_ms" start, timestamp "ended_at_ms" finish] :: !follows)

fun finish () = best_effort (fn () =>
  case !destination of
      NONE => ()
    | SOME path =>
        PR.write_record path (object
          [J.json_string_field "schema" "holbuild-command-v1",
           J.json_string_field "version" HolbuildVersion.version,
           timestamp "started_at_ms" (!started), timestamp "ended_at_ms" (Time.now ()),
           J.json_int_field "exit_code" (!exit_code),
           "\"plans\":" ^ array (rev (!plans)),
           "\"fleet_follows\":" ^ array (rev (!follows)),
           "\"fleet_batches\":" ^ array (map (fn id => "\"" ^ J.json_escape id ^ "\"") (Binaryset.listItems (!batches))),
           J.json_bool_field "fleet_history_complete" (fleet_history_complete ()),
           "\"fleet_actions\":" ^ array (map #2 (Binarymap.listItems (!actions))),
           J.json_object_field "local_outcomes"
             (ListPair.mapEq (fn (name, i) => J.json_int_field name (Array.sub (counts, i)))
               (["built", "restored_local", "restored_remote", "up_to_date"], [0, 1, 2, 3]))] ^ "\n"))

fun initialize () =
  (started := Time.now ();
   destination := (case (OS.Process.getEnv "HOLBUILD_COMMAND_RECORD", OS.Process.getEnv "HOLBUILD_COMMAND_RECORD_PID") of
       (SOME path, SOME expected) => if expected = pid () then SOME path else NONE
     | _ => NONE);
   J.command_outcome := outcome;
   HolbuildRemoteExec.command_action := observe_action;
   HolbuildRemoteExec.command_follow := observe_follow;
   HolbuildRemoteExec.command_batch := (fn batch => batches := Binaryset.add (!batches, batch));
   OS.Process.atExit finish)

end
