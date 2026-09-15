structure HolbuildAnalyserProofStepPlanAdapter =
struct

open TacticParse

val shared = true

fun trim_space text =
  let
    val n = size text
    fun left i =
      if i >= n orelse not (Char.isSpace (String.sub(text, i))) then i
      else left (i + 1)
    fun right i =
      if i < 0 orelse not (Char.isSpace (String.sub(text, i))) then i
      else right (i - 1)
    val first = left 0
    val last = right (n - 1)
  in
    if last < first then ""
    else String.substring(text, first, last - first + 1)
  end

fun source_text source (start, stop) =
  trim_space (String.substring(source, start, stop - start))

fun merge_span NONE span = span
  | merge_span span NONE = span
  | merge_span (SOME (a, b)) (SOME (c, d)) =
      SOME (Int.min(a, c), Int.max(b, d))

fun spans spans = List.foldl (fn (span, result) => merge_span result span) NONE spans

fun tactic_span tactic =
  case tactic of
      Then tactics => spans (map tactic_span tactics)
    | ThenLT (first, rest) => spans (tactic_span first :: map tactic_span rest)
    | Subgoal span => SOME span
    | By (span, body) => merge_span (SOME span) (tactic_span body)
    | SufficesBy (span, body) => merge_span (SOME span) (tactic_span body)
    | First tactics => spans (map tactic_span tactics)
    | FirstProve tactics => spans (map tactic_span tactics)
    | TacticParse.Try tactic => tactic_span tactic
    | TacticParse.Repeat tactic => tactic_span tactic
    | MapEvery (span, tactics) => spans (SOME span :: map tactic_span tactics)
    | MapFirst (span, tactics) => spans (SOME span :: map tactic_span tactics)
    | Rename span => SOME span
    | Opaque (_, span) => SOME span
    | LThen (first, rest) => spans (tactic_span first :: map tactic_span rest)
    | LThenLT tactics => spans (map tactic_span tactics)
    | LThen1 tactic => tactic_span tactic
    | LTacsToLT tactic => tactic_span tactic
    | LNullOk tactic => tactic_span tactic
    | LFirst tactics => spans (map tactic_span tactics)
    | LFirstLT tactic => tactic_span tactic
    | LSelectGoal span => SOME span
    | LSelectGoals span => SOME span
    | LAllGoals tactic => tactic_span tactic
    | LNthGoal (tactic, span) => merge_span (tactic_span tactic) (SOME span)
    | LLastGoal tactic => tactic_span tactic
    | LHeadGoal tactic => tactic_span tactic
    | LSplit (span, left, right) =>
        spans [SOME span, tactic_span left, tactic_span right]
    | LReverse => NONE
    | LTry tactic => tactic_span tactic
    | LRepeat tactic => tactic_span tactic
    | LSelectThen (selector, body) =>
        merge_span (tactic_span selector) (tactic_span body)
    | LOpaque (_, span) => SOME span
    | List (span, _) => SOME span
    | Group (_, span, _) => SOME span
    | RepairEmpty (_, span, _) => SOME span
    | RepairGroup (span, _, _, _) => SOME span
    | OOpaque (_, span) => SOME span

fun required_span description tactic =
  case tactic_span tactic of
      SOME span => span
    | NONE => raise Fail ("proof-step plan has no source span for " ^ description)

fun plan_span description steps =
  case steps of
      [] => raise Fail ("proof-step plan has an empty " ^ description)
    | first :: rest =>
        List.foldl
          (fn (step, (start, stop)) =>
             let val (a, b) = step_span step
             in (Int.min(start, a), Int.max(stop, b)) end)
          (step_span first) rest
and step_span step =
  case step of
      HolbuildProofIr.StepTactic {start_pos, end_pos, ...} =>
        (start_pos, end_pos)
    | HolbuildProofIr.StepList {start_pos, end_pos, ...} =>
        (start_pos, end_pos)
    | HolbuildProofIr.StepEach {start_pos, end_pos, ...} =>
        (start_pos, end_pos)
    | HolbuildProofIr.StepSelect {start_pos, end_pos, ...} =>
        (start_pos, end_pos)
    | HolbuildProofIr.StepCases {start_pos, end_pos, ...} =>
        (start_pos, end_pos)
    | HolbuildProofIr.StepChoice {start_pos, end_pos, ...} =>
        (start_pos, end_pos)
    | HolbuildProofIr.StepRepeat {start_pos, end_pos, ...} =>
        (start_pos, end_pos)
    | HolbuildProofIr.StepTry {start_pos, end_pos, ...} =>
        (start_pos, end_pos)

fun printed source tactic =
  case TacticParse.printTacAsSML source tactic of
      SOME text => "(" ^ text ^ ")"
    | NONE => "Tactical.ALL_TAC"

fun leaf_program source ProofStepPlan.TacticLeaf tactic =
      (case tactic of
           By (quotation, Then []) =>
             "BasicProvers.byA (" ^ source_text source quotation ^
             ", Tactical.ALL_TAC)"
         | SufficesBy (quotation, Then []) =>
             "qsuff_tac " ^ source_text source quotation
         | MapEvery (function, [argument]) =>
             "(" ^ source_text source function ^ ") (" ^
             source_text source (required_span "mapped argument" argument) ^ ")"
         | _ => printed source tactic)
  | leaf_program source ProofStepPlan.ListTacticLeaf tactic =
      (case TacticParse.printTacAsSML source tactic of
           SOME text => "(" ^ text ^ ")"
         | NONE => "Tactical.ALL_LT")

fun leaf_label source tactic =
  case tactic of
      By (quotation, Then []) => "by-subgoal " ^ source_text source quotation
    | SufficesBy (quotation, Then []) => "qsuff_tac " ^ source_text source quotation
    | MapEvery (function, [argument]) =>
        source_text source function ^ " " ^
        source_text source (required_span "mapped argument" argument)
    | LSelectThen (selected, Then []) =>
        "SELECT_LT (" ^ leaf_label source selected ^ ")"
    | LSelectThen (selected, body) =>
        "SELECT_LT_THEN (" ^ leaf_label source selected ^ ") (" ^
        leaf_label source body ^ ")"
    | Group (_, _, inner as LSelectThen _) => leaf_label source inner
    | Group (_, span, inner) =>
        let val text = source_text source span
        in
          if size text >= 2 andalso String.sub(text, 0) = #"(" andalso
             String.sub(text, size text - 1) = #")" then
            leaf_label source inner
          else text
        end
    | RepairGroup (_, _, inner, _) => leaf_label source inner
    | _ => source_text source (required_span "leaf" tactic)

fun selector source ProofStepPlan.SelectFirst = HolbuildProofIr.SelectFirst
  | selector source (ProofStepPlan.SelectMatchingFirst span) =
      HolbuildProofIr.SelectMatchingFirst (source_text source span)
  | selector source (ProofStepPlan.SelectMatchingAll span) =
      HolbuildProofIr.SelectMatchingAll (source_text source span)

fun select_mode ProofStepPlan.SelectSolve = HolbuildProofIr.SelectSolve
  | select_mode ProofStepPlan.SelectKeep = HolbuildProofIr.SelectKeep

fun convert_plan source plan = map (convert_step source) plan
and convert_step source step =
  case step of
      ProofStepPlan.Leaf {kind, tactic} =>
        let
          val (start_pos, end_pos) = required_span "leaf" tactic
          val fields = {start_pos = start_pos, end_pos = end_pos,
                        label = leaf_label source tactic,
                        program = leaf_program source kind tactic}
        in
          case kind of
              ProofStepPlan.TacticLeaf => HolbuildProofIr.StepTactic fields
            | ProofStepPlan.ListTacticLeaf => HolbuildProofIr.StepList fields
        end
    | ProofStepPlan.Each body =>
        let val converted = convert_plan source body
            val (start_pos, end_pos) = plan_span "each body" converted
        in HolbuildProofIr.StepEach
             {start_pos = start_pos, end_pos = end_pos, body = converted}
        end
    | ProofStepPlan.Select {selector = selected, mode, body} =>
        let
          val converted = convert_plan source body
          val selected_span =
            case selected of
                ProofStepPlan.SelectFirst => NONE
              | ProofStepPlan.SelectMatchingFirst span => SOME span
              | ProofStepPlan.SelectMatchingAll span => SOME span
          val (start_pos, end_pos) =
            case (selected_span, converted) of
                (SOME span, []) => span
              | (SOME (a, b), _) =>
                  let val (c, d) = plan_span "select body" converted
                  in (Int.min(a, c), Int.max(b, d)) end
              | (NONE, _) => plan_span "select body" converted
        in
          HolbuildProofIr.StepSelect
            {start_pos = start_pos, end_pos = end_pos,
             selector = selector source selected, mode = select_mode mode,
             body = converted}
        end
    | ProofStepPlan.Cases cases =>
        let val converted = map (convert_plan source) cases
            val (start_pos, end_pos) =
              plan_span "cases"
                (List.concat converted)
        in HolbuildProofIr.StepCases
             {start_pos = start_pos, end_pos = end_pos, cases = converted}
        end
    | ProofStepPlan.Choice {source = choice_source, alternatives} =>
        let val converted = map (convert_plan source) alternatives
            val (start_pos, end_pos) =
              case choice_source of
                  SOME span => span
                | NONE => plan_span "choice" (List.concat converted)
        in HolbuildProofIr.StepChoice
             {start_pos = start_pos, end_pos = end_pos,
              label = source_text source (start_pos, end_pos),
              alternatives = converted}
        end
    | ProofStepPlan.Repeat body =>
        let val converted = convert_plan source body
            val (start_pos, end_pos) = plan_span "repeat body" converted
        in HolbuildProofIr.StepRepeat
             {start_pos = start_pos, end_pos = end_pos, body = converted}
        end
    | ProofStepPlan.Try body =>
        let val converted = convert_plan source body
            val (start_pos, end_pos) = plan_span "try body" converted
        in HolbuildProofIr.StepTry
             {start_pos = start_pos, end_pos = end_pos, body = converted}
        end

fun steps source =
  let
    val expression = HolbuildProofIrPlanner.parse_tactic_expr source
    val plan = ProofStepPlan.fromTactic (TacticParse.parseTacticBlock expression)
  in
    convert_plan source plan
  end

end
