structure HolbuildProofIr =
struct

datatype selector = SelectFirst | SelectMatchingFirst of string | SelectMatchingAll of string

datatype select_mode = SelectSolve | SelectKeep

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

fun step_signature proof_step = (step_kind proof_step, step_program proof_step)

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
    fun steps_lines i depth [] acc = (i, rev acc)
      | steps_lines i depth (step :: rest) acc =
          let val (i', acc') = step_lines i depth step acc
          in steps_lines i' depth rest acc' end
    and step_lines i depth step acc =
      case step of
          StepTactic {label, ...} => (i + 1, line i depth ("step " ^ label) :: acc)
        | StepList {label, ...} => (i + 1, line i depth ("list-step " ^ label) :: acc)
        | StepEach {body, ...} =>
            let val (j, acc1) = steps_lines (i + 1) (depth + 1) body (line i depth "each" :: acc)
            in (j + 1, line j depth "end" :: acc1) end
        | StepSelect {selector, mode, body, ...} =>
            let val (j, acc1) = steps_lines (i + 1) (depth + 1) body (line i depth ("select " ^ selector_text selector ^ " " ^ mode_text mode) :: acc)
            in (j + 1, line j depth "end" :: acc1) end
        | StepCases {cases, ...} =>
            let
              fun case_lines n j [] acc = (j, acc)
                | case_lines n j (body :: rest) acc =
                    let val (k, acc1) = steps_lines (j + 1) (depth + 2) body (line j (depth + 1) ("case " ^ Int.toString n) :: acc)
                    in case_lines (n + 1) k rest acc1 end
              val (j, acc1) = case_lines 1 (i + 1) cases (line i depth "cases" :: acc)
            in (j + 1, line j depth "end" :: acc1) end
        | StepChoice {label, alternatives, ...} =>
            let
              fun alt_lines n j [] acc = (j, acc)
                | alt_lines n j (body :: rest) acc =
                    let val (k, acc1) = steps_lines (j + 1) (depth + 2) body (line j (depth + 1) ("alternative " ^ Int.toString n) :: acc)
                    in alt_lines (n + 1) k rest acc1 end
              val (j, acc1) = alt_lines 1 (i + 1) alternatives (line i depth ("choice " ^ label) :: acc)
            in (j + 1, line j depth "end" :: acc1) end
        | StepRepeat {body, ...} =>
            let val (j, acc1) = steps_lines (i + 1) (depth + 1) body (line i depth "repeat" :: acc)
            in (j + 1, line j depth "end" :: acc1) end
        | StepTry {body, ...} =>
            let val (j, acc1) = steps_lines (i + 1) (depth + 1) body (line i depth "try" :: acc)
            in (j + 1, line j depth "end" :: acc1) end
    val (_, lines) = steps_lines 0 0 steps []
  in String.concat lines end

fun display_step_count plan = List.foldl (fn (step, n) => n + display_line_count step) 0 plan

end
