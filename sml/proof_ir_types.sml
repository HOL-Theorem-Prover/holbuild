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
  | StepPlain of {start_pos : int, end_pos : int, label : string, program : string}

fun step_start (StepTactic {start_pos, ...}) = start_pos
  | step_start (StepList {start_pos, ...}) = start_pos
  | step_start (StepChoice {start_pos, ...}) = start_pos
  | step_start (StepListChoice {start_pos, ...}) = start_pos
  | step_start (StepThen1 {start_pos, ...}) = start_pos
  | step_start (StepGentleThen1 {start_pos, ...}) = start_pos
  | step_start (StepBranch {start_pos, ...}) = start_pos
  | step_start (StepBranchList {start_pos, ...}) = start_pos
  | step_start (StepPlain {start_pos, ...}) = start_pos

fun step_end (StepTactic {end_pos, ...}) = end_pos
  | step_end (StepList {end_pos, ...}) = end_pos
  | step_end (StepChoice {end_pos, ...}) = end_pos
  | step_end (StepListChoice {end_pos, ...}) = end_pos
  | step_end (StepThen1 {end_pos, ...}) = end_pos
  | step_end (StepGentleThen1 {end_pos, ...}) = end_pos
  | step_end (StepBranch {end_pos, ...}) = end_pos
  | step_end (StepBranchList {end_pos, ...}) = end_pos
  | step_end (StepPlain {end_pos, ...}) = end_pos

fun step_label (StepTactic {label, ...}) = label
  | step_label (StepList {label, ...}) = label
  | step_label (StepChoice {label, ...}) = label
  | step_label (StepListChoice {label, ...}) = label
  | step_label (StepThen1 {label, ...}) = label
  | step_label (StepGentleThen1 {label, ...}) = label
  | step_label (StepBranch {label, ...}) = label
  | step_label (StepBranchList {label, ...}) = label
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
  | step_program (StepPlain {program, ...}) = program

fun step_kind (StepTactic _) = "tactic"
  | step_kind (StepList _) = "list_tactic"
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
  | step_kind (StepPlain _) = "plain"

fun step_signature proof_step = (step_kind proof_step, step_program proof_step)

fun display_line_count (StepChoice {alternatives, ...}) = 1 + Int.max(0, 2 * length alternatives - 1)
  | display_line_count (StepListChoice {alternatives, ...}) = 1 + Int.max(0, 2 * length alternatives - 1)
  | display_line_count (StepThen1 _) = 2
  | display_line_count (StepGentleThen1 _) = 2
  | display_line_count _ = 1

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

fun format_step (i, step) =
  case step of
      StepChoice {label, alternatives, ...} => format_choice_lines i label alternatives
    | StepListChoice {label, alternatives, ...} => format_choice_lines i label alternatives
    | StepThen1 {first_label, label, ...} =>
        "  " ^ format_index i ^ " " ^ first_label ^ "\n" ^
        "  " ^ format_index (i + 1) ^ " " ^ label ^ "\n"
    | StepGentleThen1 {first_program, label, ...} =>
        "  " ^ format_index i ^ " >> " ^ first_program ^ "\n" ^
        "  " ^ format_index (i + 1) ^ " " ^ label ^ "\n"
    | StepPlain {label, ...} => "  " ^ format_index i ^ " plain " ^ label ^ "\n"
    | _ => "  " ^ format_index i ^ " " ^ step_label step ^ "\n"

fun format_plan_lines steps =
  let
    fun loop _ [] = ""
      | loop i (step :: rest) = format_step (i, step) ^ loop (i + display_line_count step) rest
  in loop 0 steps end

fun display_step_count plan = List.foldl (fn (step, n) => n + display_line_count step) 0 plan


end
