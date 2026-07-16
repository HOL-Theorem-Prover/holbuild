structure HolbuildProofIr =
struct

datatype selector = SelectFirst | SelectMatchingFirst of string | SelectMatchingAll of string

datatype select_mode = SelectSolve | SelectKeep

datatype proof_path_component =
    PathStep of int
  | PathEach of int
  | PathSelect
  | PathCase of int
  | PathAlternative of int
  | PathTry
  | PathRepeat of int

type proof_path = proof_path_component list

datatype dynamic_event =
    ChoiceEvent of proof_path * int
  | TryEvent of proof_path * bool
  | RepeatIterEvent of proof_path * int
  | RepeatStopEvent of proof_path * int

datatype step =
    StepTactic of {start_pos : int, end_pos : int, label : string, program : string}
  | StepList of {start_pos : int, end_pos : int, label : string, program : string}
  | StepEach of {start_pos : int, end_pos : int, body : step list}
  | StepSelect of {start_pos : int, end_pos : int, selector : selector, mode : select_mode, body : step list}
  | StepCases of {start_pos : int, end_pos : int, cases : step list list}
  | StepChoice of {start_pos : int, end_pos : int, label : string, alternatives : step list list}
  | StepRepeat of {start_pos : int, end_pos : int, body : step list}
  | StepTry of {start_pos : int, end_pos : int, body : step list}

fun step_start (StepTactic {start_pos, ...}) = start_pos
  | step_start (StepList {start_pos, ...}) = start_pos
  | step_start (StepEach {start_pos, ...}) = start_pos
  | step_start (StepSelect {start_pos, ...}) = start_pos
  | step_start (StepCases {start_pos, ...}) = start_pos
  | step_start (StepChoice {start_pos, ...}) = start_pos
  | step_start (StepRepeat {start_pos, ...}) = start_pos
  | step_start (StepTry {start_pos, ...}) = start_pos

fun step_end (StepTactic {end_pos, ...}) = end_pos
  | step_end (StepList {end_pos, ...}) = end_pos
  | step_end (StepEach {end_pos, ...}) = end_pos
  | step_end (StepSelect {end_pos, ...}) = end_pos
  | step_end (StepCases {end_pos, ...}) = end_pos
  | step_end (StepChoice {end_pos, ...}) = end_pos
  | step_end (StepRepeat {end_pos, ...}) = end_pos
  | step_end (StepTry {end_pos, ...}) = end_pos

fun selector_text SelectFirst = "first"
  | selector_text (SelectMatchingFirst pats) = "matching-first " ^ pats
  | selector_text (SelectMatchingAll pats) = "matching-all " ^ pats

fun mode_text SelectSolve = "solve"
  | mode_text SelectKeep = "keep"

fun step_label (StepTactic {label, ...}) = label
  | step_label (StepList {label, ...}) = label
  | step_label (StepEach _) = "each"
  | step_label (StepSelect {selector, mode, ...}) = "select " ^ selector_text selector ^ " " ^ mode_text mode
  | step_label (StepCases _) = "cases"
  | step_label (StepChoice {label, ...}) = label
  | step_label (StepRepeat _) = "repeat"
  | step_label (StepTry _) = "try"

fun step_program (StepTactic {program, ...}) = program
  | step_program (StepList {program, ...}) = program
  | step_program _ = ""

fun step_kind (StepTactic _) = "step"
  | step_kind (StepList _) = "list-step"
  | step_kind (StepEach _) = "each"
  | step_kind (StepSelect _) = "select"
  | step_kind (StepCases _) = "cases"
  | step_kind (StepChoice _) = "choice"
  | step_kind (StepRepeat _) = "repeat"
  | step_kind (StepTry _) = "try"

fun display_line_count step =
  let
    fun body_count xs = List.foldl (fn (s, n) => n + display_line_count s) 0 xs
  in
    case step of
        StepEach {body, ...} => 2 + body_count body
      | StepSelect {body, ...} => 2 + body_count body
      | StepCases {cases, ...} => 2 + length cases + List.foldl (fn (body, n) => n + body_count body) 0 cases
      | StepChoice {alternatives, ...} => 2 + length alternatives + List.foldl (fn (body, n) => n + body_count body) 0 alternatives
      | StepRepeat {body, ...} => 2 + body_count body
      | StepTry {body, ...} => 2 + body_count body
      | _ => 1
  end

fun format_index i = if i < 10 then "0" ^ Int.toString i else Int.toString i

fun indent n = String.concat (List.tabulate (n, fn _ => "  "))

fun format_plan_lines steps =
  let
    fun line i depth text = "  " ^ format_index i ^ " " ^ indent depth ^ text ^ "\n"
    fun steps_lines i depth [] = (i, [])
      | steps_lines i depth (step :: rest) =
          let
            val (i', lines1) = step_lines i depth step
            val (i'', lines2) = steps_lines i' depth rest
          in (i'', lines1 @ lines2) end
    and step_lines i depth step =
      case step of
          StepTactic {label, ...} => (i + 1, [line i depth ("step " ^ label)])
        | StepList {label, ...} => (i + 1, [line i depth ("list-step " ^ label)])
        | StepEach {body, ...} =>
            let val (j, body_lines) = steps_lines (i + 1) (depth + 1) body
            in (j + 1, line i depth "each" :: body_lines @ [line j depth "end"]) end
        | StepSelect {selector, mode, body, ...} =>
            let val (j, body_lines) = steps_lines (i + 1) (depth + 1) body
            in (j + 1, line i depth ("select " ^ selector_text selector ^ " " ^ mode_text mode) :: body_lines @ [line j depth "end"]) end
        | StepCases {cases, ...} =>
            let
              fun case_lines n j [] = (j, [])
                | case_lines n j (body :: rest) =
                    let
                      val (k, body_lines) = steps_lines (j + 1) (depth + 2) body
                      val (m, rest_lines) = case_lines (n + 1) k rest
                    in (m, line j (depth + 1) ("case " ^ Int.toString n) :: body_lines @ rest_lines) end
              val (j, body_lines) = case_lines 1 (i + 1) cases
            in (j + 1, line i depth "cases" :: body_lines @ [line j depth "end"]) end
        | StepChoice {label, alternatives, ...} =>
            let
              fun alt_lines n j [] = (j, [])
                | alt_lines n j (body :: rest) =
                    let
                      val (k, body_lines) = steps_lines (j + 1) (depth + 2) body
                      val (m, rest_lines) = alt_lines (n + 1) k rest
                    in (m, line j (depth + 1) ("alternative " ^ Int.toString n) :: body_lines @ rest_lines) end
              val (j, body_lines) = alt_lines 1 (i + 1) alternatives
            in (j + 1, line i depth ("choice " ^ label) :: body_lines @ [line j depth "end"]) end
        | StepRepeat {body, ...} =>
            let val (j, body_lines) = steps_lines (i + 1) (depth + 1) body
            in (j + 1, line i depth "repeat" :: body_lines @ [line j depth "end"]) end
        | StepTry {body, ...} =>
            let val (j, body_lines) = steps_lines (i + 1) (depth + 1) body
            in (j + 1, line i depth "try" :: body_lines @ [line j depth "end"]) end
    val (_, lines) = steps_lines 0 0 steps
  in String.concat lines end

fun display_line_count_list steps = List.foldl (fn (step, n) => n + display_line_count step) 0 steps

fun display_step_count plan = display_line_count_list plan

(* Canonical proof-state dependency encodings deliberately omit source spans and
   display labels.  Opaque executable programs and selector patterns remain
   exact: Proof-IR does not have a semantics-preserving normalizer for arbitrary
   SML expressions.  Fields are length-prefixed so the encoding is unambiguous. *)
fun canonical_field text = Int.toString (size text) ^ ":" ^ text

fun canonical_node tag fields =
  canonical_field tag ^ canonical_field (Int.toString (length fields)) ^
  String.concat (map canonical_field fields)

fun canonical_selector SelectFirst = canonical_node "first" []
  | canonical_selector (SelectMatchingFirst pats) = canonical_node "matching-first" [pats]
  | canonical_selector (SelectMatchingAll pats) = canonical_node "matching-all" [pats]

fun canonical_mode SelectSolve = "solve"
  | canonical_mode SelectKeep = "keep"

fun canonical_full_plan steps =
  canonical_node "plan" (map canonical_full_step steps)
and canonical_full_step step =
  case step of
      StepTactic {program, ...} => canonical_node "tactic" [program]
    | StepList {program, ...} => canonical_node "list-tactic" [program]
    | StepEach {body, ...} => canonical_node "each" [canonical_full_plan body]
    | StepSelect {selector, mode, body, ...} =>
        canonical_node "select"
          [canonical_selector selector, canonical_mode mode, canonical_full_plan body]
    | StepCases {cases, ...} =>
        canonical_node "cases"
          [Int.toString (length cases), canonical_node "case-bodies" (map canonical_full_plan cases)]
    | StepChoice {alternatives, ...} =>
        canonical_node "choice"
          [Int.toString (length alternatives),
           canonical_node "alternative-bodies" (map canonical_full_plan alternatives)]
    | StepRepeat {body, ...} => canonical_node "repeat" [canonical_full_plan body]
    | StepTry {body, ...} => canonical_node "try" [canonical_full_plan body]

fun canonical_dependency_prefix plan target =
  let
    fun split_nth n xs =
      if n < 0 then NONE
      else
        let
          fun loop 0 prefix (x :: rest) = SOME (rev prefix, x, rest)
            | loop k prefix (x :: rest) = loop (k - 1) (x :: prefix) rest
            | loop _ _ [] = NONE
        in loop n [] xs end
    fun plan_prefix steps path =
      case path of
          PathStep i :: rest =>
            (case split_nth i steps of
                 SOME (before, step, _) =>
                   Option.map
                     (fn current => canonical_node "plan-prefix"
                                      [canonical_full_plan before, current])
                     (step_prefix step rest)
               | NONE => NONE)
        | _ => NONE
    and step_prefix step path =
      case (step, path) of
          (StepTactic {program, ...}, []) => SOME (canonical_node "tactic" [program])
        | (StepList {program, ...}, []) => SOME (canonical_node "list-tactic" [program])
        | (StepSelect {selector, mode, body, ...}, PathSelect :: rest) =>
            Option.map
              (fn child => canonical_node "select-prefix"
                             [canonical_selector selector, canonical_mode mode, child])
              (plan_prefix body rest)
        | (StepEach {body, ...}, PathEach iteration :: rest) =>
            if iteration < 0 then NONE
            else
              Option.map
                (fn child => canonical_node "each-prefix"
                               [Int.toString iteration,
                                if iteration = 0 then "" else canonical_full_plan body,
                                child])
                (plan_prefix body rest)
        | (StepCases {cases, ...}, PathCase n :: rest) =>
            if n <= 0 then NONE
            else
              (case split_nth (n - 1) cases of
                   SOME (before, body, _) =>
                     Option.map
                       (fn child => canonical_node "cases-prefix"
                                      [Int.toString (length cases),
                                       canonical_node "completed-cases" (map canonical_full_plan before),
                                       child])
                       (plan_prefix body rest)
                 | NONE => NONE)
        | (StepChoice {alternatives, ...}, PathAlternative n :: rest) =>
            if n <= 0 then NONE
            else
              (case split_nth (n - 1) alternatives of
                   SOME (before, body, _) =>
                     Option.map
                       (fn child => canonical_node "choice-prefix"
                                      [Int.toString (length alternatives),
                                       canonical_node "attempted-alternatives" (map canonical_full_plan before),
                                       child])
                       (plan_prefix body rest)
                 | NONE => NONE)
        | (StepTry {body, ...}, PathTry :: rest) =>
            Option.map (fn child => canonical_node "try-prefix" [child])
              (plan_prefix body rest)
        | (StepRepeat {body, ...}, PathRepeat iteration :: rest) =>
            if iteration < 0 then NONE
            else
              Option.map
                (fn child => canonical_node "repeat-prefix"
                               [Int.toString iteration,
                                if iteration = 0 then "" else canonical_full_plan body,
                                child])
                (plan_prefix body rest)
        | _ => NONE
  in
    plan_prefix plan target
  end

end
