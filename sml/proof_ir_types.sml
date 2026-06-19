structure HolbuildProofIr =
struct

datatype branch_phase = BranchStart | BranchSuffix | BranchClose

datatype step =
    StepTactic of {start_pos : int, end_pos : int, label : string, program : string}
  | StepList of {start_pos : int, end_pos : int, label : string, program : string}
  | StepChoice of {start_pos : int, end_pos : int, label : string, program : string, alternatives : string list}
  | StepListChoice of {start_pos : int, end_pos : int, label : string, program : string, alternatives : string list}
  | StepThen1 of {start_pos : int, end_pos : int, first_label : string, label : string, list_suffix : bool, first_program : string, second_program : string}
  | StepGentleThen1 of {start_pos : int, end_pos : int, label : string, list_suffix : bool, first_program : string, second_program : string}
  | StepBranch of {start_pos : int, end_pos : int, label : string, program : string, phase : branch_phase}
  | StepBranchList of {start_pos : int, end_pos : int, label : string, program : string}
  | StepEachBegin of {start_pos : int, end_pos : int}
  | StepSelectFirstSolveBegin of {start_pos : int, end_pos : int}
  | StepCasesBegin of {start_pos : int, end_pos : int}
  | StepCase of {start_pos : int, end_pos : int, index : int}
  | StepEnd of {start_pos : int, end_pos : int}
  | StepPlain of {start_pos : int, end_pos : int, label : string, program : string}

fun step_start (StepTactic {start_pos, ...}) = start_pos
  | step_start (StepList {start_pos, ...}) = start_pos
  | step_start (StepChoice {start_pos, ...}) = start_pos
  | step_start (StepListChoice {start_pos, ...}) = start_pos
  | step_start (StepThen1 {start_pos, ...}) = start_pos
  | step_start (StepGentleThen1 {start_pos, ...}) = start_pos
  | step_start (StepBranch {start_pos, ...}) = start_pos
  | step_start (StepBranchList {start_pos, ...}) = start_pos
  | step_start (StepEachBegin {start_pos, ...}) = start_pos
  | step_start (StepSelectFirstSolveBegin {start_pos, ...}) = start_pos
  | step_start (StepCasesBegin {start_pos, ...}) = start_pos
  | step_start (StepCase {start_pos, ...}) = start_pos
  | step_start (StepEnd {start_pos, ...}) = start_pos
  | step_start (StepPlain {start_pos, ...}) = start_pos

fun step_end (StepTactic {end_pos, ...}) = end_pos
  | step_end (StepList {end_pos, ...}) = end_pos
  | step_end (StepChoice {end_pos, ...}) = end_pos
  | step_end (StepListChoice {end_pos, ...}) = end_pos
  | step_end (StepThen1 {end_pos, ...}) = end_pos
  | step_end (StepGentleThen1 {end_pos, ...}) = end_pos
  | step_end (StepBranch {end_pos, ...}) = end_pos
  | step_end (StepBranchList {end_pos, ...}) = end_pos
  | step_end (StepEachBegin {end_pos, ...}) = end_pos
  | step_end (StepSelectFirstSolveBegin {end_pos, ...}) = end_pos
  | step_end (StepCasesBegin {end_pos, ...}) = end_pos
  | step_end (StepCase {end_pos, ...}) = end_pos
  | step_end (StepEnd {end_pos, ...}) = end_pos
  | step_end (StepPlain {end_pos, ...}) = end_pos

fun step_label (StepTactic {label, ...}) = label
  | step_label (StepList {label, ...}) = label
  | step_label (StepChoice {label, ...}) = label
  | step_label (StepListChoice {label, ...}) = label
  | step_label (StepThen1 {label, ...}) = label
  | step_label (StepGentleThen1 {label, ...}) = label
  | step_label (StepBranch {label, ...}) = label
  | step_label (StepBranchList {label, ...}) = label
  | step_label (StepEachBegin _) = "each"
  | step_label (StepSelectFirstSolveBegin _) = "select first solve"
  | step_label (StepCasesBegin _) = "cases"
  | step_label (StepCase {index, ...}) = "case " ^ Int.toString index
  | step_label (StepEnd _) = "end"
  | step_label (StepPlain {label, ...}) = label

fun step_program (StepTactic {program, ...}) = program
  | step_program (StepList {program, ...}) = program
  | step_program (StepChoice {program, ...}) = program
  | step_program (StepListChoice {program, ...}) = program
  | step_program (StepThen1 {list_suffix, first_program, second_program, ...}) =
      let val tactic = "Tactical.THEN1(" ^ first_program ^ ", " ^ second_program ^ ")"
      in if list_suffix then "Tactical.ALLGOALS (" ^ tactic ^ ")" else tactic end
  | step_program (StepGentleThen1 {list_suffix, first_program, second_program, ...}) =
      let val tactic = "HolbuildProofRuntime.gentle_then1 (" ^ first_program ^ ") (" ^ second_program ^ ")"
      in if list_suffix then "Tactical.ALLGOALS (" ^ tactic ^ ")" else tactic end
  | step_program (StepBranch {program, ...}) = program
  | step_program (StepBranchList {program, ...}) = program
  | step_program (StepEachBegin _) = "<each>"
  | step_program (StepSelectFirstSolveBegin _) = "<select first solve>"
  | step_program (StepCasesBegin _) = "<cases>"
  | step_program (StepCase {index, ...}) = "<case " ^ Int.toString index ^ ">"
  | step_program (StepEnd _) = "<end>"
  | step_program (StepPlain {program, ...}) = program

fun step_kind (StepTactic _) = "step"
  | step_kind (StepList _) = "list-step"
  | step_kind (StepChoice _) = "choice"
  | step_kind (StepListChoice _) = "list_choice"
  | step_kind (StepThen1 {list_suffix = true, ...}) = "list_then1"
  | step_kind (StepThen1 _) = "then1"
  | step_kind (StepGentleThen1 {list_suffix = true, ...}) = "list_gentle_then1"
  | step_kind (StepGentleThen1 _) = "gentle_then1"
  | step_kind (StepBranch {phase = BranchStart, ...}) = "branch_start"
  | step_kind (StepBranch {phase = BranchSuffix, ...}) = "branch_suffix"
  | step_kind (StepBranch {phase = BranchClose, ...}) = "branch_close"
  | step_kind (StepBranchList _) = "branch_list_suffix"
  | step_kind (StepEachBegin _) = "each"
  | step_kind (StepSelectFirstSolveBegin _) = "select"
  | step_kind (StepCasesBegin _) = "cases"
  | step_kind (StepCase _) = "case"
  | step_kind (StepEnd _) = "end"
  | step_kind (StepPlain _) = "plain"

fun step_signature proof_step = (step_kind proof_step, step_program proof_step)

fun display_line_count _ = 1

fun format_index i = if i < 10 then "0" ^ Int.toString i else Int.toString i

fun format_choice_lines i label alternatives =
  let
    fun alt_lines (_, []) = ""
      | alt_lines (j, [alt]) = "  " ^ format_index j ^ "   " ^ alt ^ "\n"
      | alt_lines (j, alt :: rest) =
          "  " ^ format_index j ^ "   " ^ alt ^ "\n" ^
          "  " ^ format_index (j + 1) ^ "   |\n" ^
          alt_lines (j + 2, rest)
  in
    "  " ^ format_index i ^ " " ^ label ^ "\n" ^ alt_lines (i + 1, alternatives)
  end

fun spaces n = String.implode (List.tabulate (Int.max(0, n), fn _ => #" "))

fun format_line i depth text =
  "  " ^ format_index i ^ " " ^ spaces (2 * depth) ^ text ^ "\n"

fun format_step i depth step =
  case step of
      StepChoice {label, alternatives, ...} => format_choice_lines i label alternatives
    | StepListChoice {label, alternatives, ...} => format_choice_lines i label alternatives
    | StepThen1 {first_label, ...} => format_line i depth first_label
    | StepGentleThen1 {first_program, ...} => format_line i depth (">> " ^ first_program)
    | StepTactic {label, ...} => format_line i depth ("step " ^ label)
    | StepList {label, ...} => format_line i depth ("list-step " ^ label)
    | StepEachBegin _ => format_line i depth "each"
    | StepSelectFirstSolveBegin _ => format_line i depth "select first solve"
    | StepCasesBegin _ => format_line i depth "cases"
    | StepCase {index, ...} => format_line i depth ("case " ^ Int.toString index)
    | StepEnd _ => format_line i depth "end"
    | StepPlain {label, ...} => format_line i depth ("plain " ^ label)
    | _ => format_line i depth (step_label step)

fun format_plan_lines steps =
  let
    fun depth stack = length stack
    fun pop_case ("case" :: rest) = rest
      | pop_case stack = stack
    fun line_stack stack step =
      case step of
          StepCase _ => pop_case stack
        | StepEnd _ =>
            (case pop_case stack of [] => [] | _ :: rest => rest)
        | _ => stack
    fun next_stack stack step =
      case step of
          StepEachBegin _ => "each" :: stack
        | StepSelectFirstSolveBegin _ => "select" :: stack
        | StepCasesBegin _ => "cases" :: stack
        | StepCase _ => "case" :: pop_case stack
        | StepEnd _ => line_stack stack step
        | _ => stack
    fun loop _ _ [] = ""
      | loop i stack (step :: rest) =
          let val line_s = line_stack stack step
          in format_step i (depth line_s) step ^ loop (i + 1) (next_stack stack step) rest end
  in loop 0 [] steps end

fun display_step_count plan = length plan


end
