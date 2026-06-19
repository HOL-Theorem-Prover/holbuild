structure HolbuildProofIr =
struct

type span = {start_pos : int, end_pos : int}

datatype selector = SelectFirst | SelectMatchingFirst of string | SelectMatchingAll of string
datatype select_mode = SelectSolve | SelectKeep

datatype step =
    StepTactic of {start_pos : int, end_pos : int, label : string, program : string}
  | StepList of {start_pos : int, end_pos : int, label : string, program : string}
  | StepEach of {start_pos : int, end_pos : int, body : step list}
  | StepSelect of {start_pos : int, end_pos : int, selector : selector, mode : select_mode, body : step list}
  | StepCases of {start_pos : int, end_pos : int, cases : step list list}
  | StepChoice of {start_pos : int, end_pos : int, alternatives : step list list}
  | StepRepeat of {start_pos : int, end_pos : int, body : step list}
  | StepTry of {start_pos : int, end_pos : int, body : step list}

fun selector_text SelectFirst = "first"
  | selector_text (SelectMatchingFirst pats) = "matching-first " ^ pats
  | selector_text (SelectMatchingAll pats) = "matching-all " ^ pats

fun mode_text SelectSolve = "solve"
  | mode_text SelectKeep = "keep"

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

fun step_label (StepTactic {label, ...}) = label
  | step_label (StepList {label, ...}) = label
  | step_label (StepEach _) = "each"
  | step_label (StepSelect {selector, mode, ...}) = "select " ^ selector_text selector ^ " " ^ mode_text mode
  | step_label (StepCases _) = "cases"
  | step_label (StepChoice _) = "choice"
  | step_label (StepRepeat _) = "repeat"
  | step_label (StepTry _) = "try"

fun step_program (StepTactic {program, ...}) = program
  | step_program (StepList {program, ...}) = program
  | step_program (StepEach _) = "<each>"
  | step_program (StepSelect _) = "<select>"
  | step_program (StepCases _) = "<cases>"
  | step_program (StepChoice _) = "<choice>"
  | step_program (StepRepeat _) = "<repeat>"
  | step_program (StepTry _) = "<try>"

fun step_kind (StepTactic _) = "step"
  | step_kind (StepList _) = "list-step"
  | step_kind (StepEach _) = "each"
  | step_kind (StepSelect _) = "select"
  | step_kind (StepCases _) = "cases"
  | step_kind (StepChoice _) = "choice"
  | step_kind (StepRepeat _) = "repeat"
  | step_kind (StepTry _) = "try"

fun step_signature proof_step = (step_kind proof_step, step_program proof_step)

fun flat_steps plan =
  let
    fun append_body body acc = List.foldr go acc body
    and go (step, acc) =
      case step of
          StepEach {body, ...} => step :: append_body body acc
        | StepSelect {body, ...} => step :: append_body body acc
        | StepCases {cases, ...} => step :: List.foldr (fn (body, a) => append_body body a) acc cases
        | StepChoice {alternatives, ...} => step :: List.foldr (fn (body, a) => append_body body a) acc alternatives
        | StepRepeat {body, ...} => step :: append_body body acc
        | StepTry {body, ...} => step :: append_body body acc
        | _ => step :: acc
  in List.foldr go [] plan end

fun display_line_count step =
  case step of
      StepEach {body, ...} => 2 + display_step_count body
    | StepSelect {body, ...} => 2 + display_step_count body
    | StepCases {cases, ...} => 2 + length cases + List.foldl (fn (body, n) => n + display_step_count body) 0 cases
    | StepChoice {alternatives, ...} => 2 + length alternatives + List.foldl (fn (body, n) => n + display_step_count body) 0 alternatives
    | StepRepeat {body, ...} => 2 + display_step_count body
    | StepTry {body, ...} => 2 + display_step_count body
    | _ => 1
and display_step_count plan = List.foldl (fn (step, n) => n + display_line_count step) 0 plan

fun format_index i = if i < 10 then "0" ^ Int.toString i else Int.toString i
fun spaces n = String.implode (List.tabulate (Int.max(0, n), fn _ => #" "))
fun format_line i depth text = "  " ^ format_index i ^ " " ^ spaces (2 * depth) ^ text ^ "\n"

fun format_plan_lines steps =
  let
    fun fmt depth i [] = ("", i)
      | fmt depth i (step :: rest) =
          let val (line, i') = fmt_step depth i step
              val (more, i'') = fmt depth i' rest
          in (line ^ more, i'') end
    and fmt_step depth i step =
      case step of
          StepTactic {label, ...} => (format_line i depth ("step " ^ label), i + 1)
        | StepList {label, ...} => (format_line i depth ("list-step " ^ label), i + 1)
        | StepEach {body, ...} => block depth i "each" body
        | StepSelect {selector, mode, body, ...} => block depth i ("select " ^ selector_text selector ^ " " ^ mode_text mode) body
        | StepRepeat {body, ...} => block depth i "repeat" body
        | StepTry {body, ...} => block depth i "try" body
        | StepCases {cases, ...} => indexed_block depth i "cases" "case" cases
        | StepChoice {alternatives, ...} => indexed_block depth i "choice" "alternative" alternatives
    and block depth i name body =
      let val (body_s, j) = fmt (depth + 1) (i + 1) body
      in (format_line i depth name ^ body_s ^ format_line j depth "end", j + 1) end
    and indexed_block depth i name child_name bodies =
      let
        fun fmt_bodies _ j [] = ("", j)
          | fmt_bodies n j (body :: rest) =
              let val (body_s, k) = fmt (depth + 2) (j + 1) body
                  val (rest_s, l) = fmt_bodies (n + 1) k rest
              in (format_line j (depth + 1) (child_name ^ " " ^ Int.toString n) ^ body_s ^ rest_s, l) end
        val (body_s, j) = fmt_bodies 1 (i + 1) bodies
      in (format_line i depth name ^ body_s ^ format_line j depth "end", j + 1) end
    val (s, _) = fmt 0 0 steps
  in s end

end
