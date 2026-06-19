structure HolbuildProofIr =
struct

type span = {start_pos : int, end_pos : int}

datatype step =
    StepTactic of {start_pos : int, end_pos : int, label : string, program : string}
  | StepList of {start_pos : int, end_pos : int, label : string, program : string}
  | StepChoice of {start_pos : int, end_pos : int, label : string, program : string, alternatives : string list}
  | StepListChoice of {start_pos : int, end_pos : int, label : string, program : string, alternatives : string list}
  | StepEach of {start_pos : int, end_pos : int, body : step list}
  | StepSelectFirstSolve of {start_pos : int, end_pos : int, body : step list}
  | StepCases of {start_pos : int, end_pos : int, cases : step list list}
  | StepPlain of {start_pos : int, end_pos : int, label : string, program : string}

fun step_start (StepTactic {start_pos, ...}) = start_pos
  | step_start (StepList {start_pos, ...}) = start_pos
  | step_start (StepChoice {start_pos, ...}) = start_pos
  | step_start (StepListChoice {start_pos, ...}) = start_pos
  | step_start (StepEach {start_pos, ...}) = start_pos
  | step_start (StepSelectFirstSolve {start_pos, ...}) = start_pos
  | step_start (StepCases {start_pos, ...}) = start_pos
  | step_start (StepPlain {start_pos, ...}) = start_pos

fun step_end (StepTactic {end_pos, ...}) = end_pos
  | step_end (StepList {end_pos, ...}) = end_pos
  | step_end (StepChoice {end_pos, ...}) = end_pos
  | step_end (StepListChoice {end_pos, ...}) = end_pos
  | step_end (StepEach {end_pos, ...}) = end_pos
  | step_end (StepSelectFirstSolve {end_pos, ...}) = end_pos
  | step_end (StepCases {end_pos, ...}) = end_pos
  | step_end (StepPlain {end_pos, ...}) = end_pos

fun step_label (StepTactic {label, ...}) = label
  | step_label (StepList {label, ...}) = label
  | step_label (StepChoice {label, ...}) = label
  | step_label (StepListChoice {label, ...}) = label
  | step_label (StepEach _) = "each"
  | step_label (StepSelectFirstSolve _) = "select first solve"
  | step_label (StepCases _) = "cases"
  | step_label (StepPlain {label, ...}) = label

fun step_program (StepTactic {program, ...}) = program
  | step_program (StepList {program, ...}) = program
  | step_program (StepChoice {program, ...}) = program
  | step_program (StepListChoice {program, ...}) = program
  | step_program (StepEach _) = "<each>"
  | step_program (StepSelectFirstSolve _) = "<select first solve>"
  | step_program (StepCases _) = "<cases>"
  | step_program (StepPlain {program, ...}) = program

fun step_kind (StepTactic _) = "step"
  | step_kind (StepList _) = "list-step"
  | step_kind (StepChoice _) = "choice"
  | step_kind (StepListChoice _) = "list-choice"
  | step_kind (StepEach _) = "each"
  | step_kind (StepSelectFirstSolve _) = "select"
  | step_kind (StepCases _) = "cases"
  | step_kind (StepPlain _) = "plain"

fun step_signature proof_step = (step_kind proof_step, step_program proof_step)

fun flat_steps plan =
  let
    fun go (step, acc) =
      case step of
          StepEach {body, ...} => step :: List.foldr go acc body
        | StepSelectFirstSolve {body, ...} => step :: List.foldr go acc body
        | StepCases {cases, ...} => step :: List.foldr (fn (body, a) => List.foldr go a body) acc cases
        | _ => step :: acc
  in List.foldr go [] plan end

fun display_line_count step =
  case step of
      StepEach {body, ...} => 2 + display_step_count body
    | StepSelectFirstSolve {body, ...} => 2 + display_step_count body
    | StepCases {cases, ...} => 2 + length cases + List.foldl (fn (body, n) => n + display_step_count body) 0 cases
    | _ => 1
and display_step_count plan = List.foldl (fn (step, n) => n + display_line_count step) 0 plan

fun format_index i = if i < 10 then "0" ^ Int.toString i else Int.toString i
fun spaces n = String.implode (List.tabulate (Int.max(0, n), fn _ => #" "))
fun format_line i depth text = "  " ^ format_index i ^ " " ^ spaces (2 * depth) ^ text ^ "\n"

fun format_plan_lines steps =
  let
    fun fmt depth i [] = ("", i)
      | fmt depth i (step :: rest) =
          let
            val (line, i') = fmt_step depth i step
            val (more, i'') = fmt depth i' rest
          in (line ^ more, i'') end
    and fmt_step depth i step =
      case step of
          StepChoice {label, ...} => (format_line i depth ("choice " ^ label), i + 1)
        | StepListChoice {label, ...} => (format_line i depth ("list-choice " ^ label), i + 1)
        | StepTactic {label, ...} => (format_line i depth ("step " ^ label), i + 1)
        | StepList {label, ...} => (format_line i depth ("list-step " ^ label), i + 1)
        | StepPlain {label, ...} => (format_line i depth ("plain " ^ label), i + 1)
        | StepEach {body, ...} =>
            let val (body_s, j) = fmt (depth + 1) (i + 1) body
            in (format_line i depth "each" ^ body_s ^ format_line j depth "end", j + 1) end
        | StepSelectFirstSolve {body, ...} =>
            let val (body_s, j) = fmt (depth + 1) (i + 1) body
            in (format_line i depth "select first solve" ^ body_s ^ format_line j depth "end", j + 1) end
        | StepCases {cases, ...} =>
            let
              fun fmt_cases _ j [] = ("", j)
                | fmt_cases n j (body :: rest) =
                    let val (body_s, k) = fmt (depth + 2) (j + 1) body
                        val (rest_s, l) = fmt_cases (n + 1) k rest
                    in (format_line j (depth + 1) ("case " ^ Int.toString n) ^ body_s ^ rest_s, l) end
              val (cases_s, j) = fmt_cases 1 (i + 1) cases
            in (format_line i depth "cases" ^ cases_s ^ format_line j depth "end", j + 1) end
    val (s, _) = fmt 0 0 steps
  in s end

end
