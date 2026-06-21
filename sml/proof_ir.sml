structure HolbuildProofIrPlanner =
struct

open HolbuildProofIr
open HOLSourceAST

fun repeat_string s n = if n <= 0 then "" else s ^ repeat_string s (n - 1)
fun indent n = repeat_string "  " n

fun span e = expSpan e
fun span_end (_, stop) = stop

fun trim_space text =
  let
    val n = size text
    fun left i = if i >= n orelse not (Char.isSpace (String.sub(text, i))) then i else left (i + 1)
    fun right i = if i < 0 orelse not (Char.isSpace (String.sub(text, i))) then i else right (i - 1)
    val l = left 0
    val r = right (n - 1)
  in if r < l then "" else String.substring(text, l, r - l + 1) end

fun slice source (start, stop) =
  let
    val n = size source
    val a = Int.max(0, Int.min(start, n))
    val b = Int.max(a, Int.min(stop, n))
  in String.substring(source, a, b - a) end

fun source_text source sp = trim_space (slice source sp)
fun parenthesize s = "(" ^ s ^ ")"

fun ident_name (Ident {id = (_, s), ...}) = SOME s
  | ident_name _ = NONE

fun flatten_app e =
  let
    fun go (App (f, x)) acc = go f (x :: acc)
      | go x acc = x :: acc
  in
    go e []
  end

fun app_name e =
  case flatten_app e of
      f :: args => Option.map (fn s => (s, args)) (ident_name f)
    | [] => NONE

fun list_elems (List {elems = {args, ...}, ...}) = SOME args
  | list_elems _ = NONE

fun tuple_elems (Tuple {elems = {args, ...}, ...}) = SOME args
  | tuple_elems _ = NONE

fun strip_closed_parens (Parens {exp, right = SOME _, ...}) = SOME exp
  | strip_closed_parens _ = NONE

fun precedence (ExpEmpty _) = 10
  | precedence (Parens _) = 10
  | precedence (Tuple _) = 10
  | precedence (List _) = 10
  | precedence (Ident _) = 10
  | precedence (Infix {id = (_, s), ...}) =
      (case Binarymap.peek (HOLSourceParser.initialScope, s) of SOME (p, _) => p | NONE => 0)
  | precedence (App _) = 9
  | precedence _ = 0

datatype subgoal_kind = PlainSubgoal | BySubgoal

datatype tactic =
    TacThen of tactic list
  | TacThenLT of tactic * list_tactic
  | TacThen1 of tactic * tactic
  | TacThenL of tactic * tactic list
  | TacOrelse of tactic list
  | TacFirst of (int * int) * tactic list
  | TacFirstProve of (int * int) * tactic list
  | TacUnary of (int * int) * string * tactic
  | TacGenValidate of (int * int) * (int * int) * tactic
  | TacAddSgs of (int * int) * (int * int) * tactic
  | TacIf of (int * int) * tactic * tactic * tactic
  | TacTry of (int * int) * tactic
  | TacRepeat of (int * int) * tactic
  | TacReverse of (int * int) * tactic
  | TacSubgoal of subgoal_kind * (int * int)
  | TacMapEvery of (int * int) * (int * int) list
  | TacApply of (int * int) * (int * int)
  | TacMapFirst of (int * int) * tactic list
  | TacSufficesBy of (int * int) * tactic
  | TacRepairGroup of (int * int) * tactic
  | TacAtomic of int * (int * int)
and list_tactic =
    LtThenLT of list_tactic list
  | LtThen of list_tactic * tactic list
  | LtTacsToLT of tactic list
  | LtNullOk of (int * int) * list_tactic
  | LtOrelse of list_tactic list
  | LtUnary of (int * int) * string * list_tactic
  | LtGenValidate of (int * int) * (int * int) * list_tactic
  | LtTryAll of (int * int) * tactic
  | LtSelect of (int * int) * tactic
  | LtAllGoals of tactic
  | LtNthGoal of tactic * (int * int)
  | LtLastGoal of tactic
  | LtHeadGoal of tactic
  | LtSplit of (int * int) * list_tactic * list_tactic
  | LtRotate of (int * int) * (int * int)
  | LtReverse of int * int
  | LtTry of (int * int) * list_tactic
  | LtRepeat of (int * int) * list_tactic
  | LtFirstLT of tactic
  | LtSelectThen of tactic * tactic
  | LtQSelectThen of (int * int) * tactic
  | LtSelectGoal of int * int
  | LtSelectGoals of int * int
  | LtRepairGroup of (int * int) * list_tactic
  | LtAtomic of int * (int * int)

fun tactic_end (TacThen []) = 0
  | tactic_end (TacThen xs) = tactic_end (List.last xs)
  | tactic_end (TacThenLT (_, l)) = list_tactic_end l
  | tactic_end (TacThen1 (_, t)) = tactic_end t
  | tactic_end (TacThenL (t, [])) = tactic_end t
  | tactic_end (TacThenL (_, ts)) = tactic_end (List.last ts)
  | tactic_end (TacOrelse []) = 0
  | tactic_end (TacOrelse xs) = tactic_end (List.last xs)
  | tactic_end (TacFirst (sp, _)) = span_end sp
  | tactic_end (TacFirstProve (sp, _)) = span_end sp
  | tactic_end (TacUnary (sp, _, _)) = span_end sp
  | tactic_end (TacGenValidate (sp, _, _)) = span_end sp
  | tactic_end (TacAddSgs (sp, _, _)) = span_end sp
  | tactic_end (TacIf (sp, _, _, _)) = span_end sp
  | tactic_end (TacTry (sp, _)) = span_end sp
  | tactic_end (TacRepeat (sp, _)) = span_end sp
  | tactic_end (TacReverse (sp, _)) = span_end sp
  | tactic_end (TacSubgoal (_, sp)) = span_end sp
  | tactic_end (TacApply (_, arg)) = span_end arg
  | tactic_end (TacMapEvery (f, [])) = span_end f
  | tactic_end (TacMapEvery (_, args)) = span_end (List.last args)
  | tactic_end (TacMapFirst (f, [])) = span_end f
  | tactic_end (TacMapFirst (_, ts)) = tactic_end (List.last ts)
  | tactic_end (TacSufficesBy (_, t)) = tactic_end t
  | tactic_end (TacRepairGroup (sp, _)) = span_end sp
  | tactic_end (TacAtomic (_, sp)) = span_end sp
and list_tactic_end (LtThenLT []) = 0
  | list_tactic_end (LtThenLT xs) = list_tactic_end (List.last xs)
  | list_tactic_end (LtThen (lt, [])) = list_tactic_end lt
  | list_tactic_end (LtThen (_, ts)) = tactic_end (List.last ts)
  | list_tactic_end (LtTacsToLT []) = 0
  | list_tactic_end (LtTacsToLT ts) = tactic_end (List.last ts)
  | list_tactic_end (LtNullOk (sp, _)) = span_end sp
  | list_tactic_end (LtOrelse []) = 0
  | list_tactic_end (LtOrelse xs) = list_tactic_end (List.last xs)
  | list_tactic_end (LtUnary (sp, _, _)) = span_end sp
  | list_tactic_end (LtGenValidate (sp, _, _)) = span_end sp
  | list_tactic_end (LtTryAll (sp, _)) = span_end sp
  | list_tactic_end (LtSelect (sp, _)) = span_end sp
  | list_tactic_end (LtAllGoals t) = tactic_end t
  | list_tactic_end (LtNthGoal (_, sp)) = span_end sp
  | list_tactic_end (LtLastGoal t) = tactic_end t
  | list_tactic_end (LtHeadGoal t) = tactic_end t
  | list_tactic_end (LtSplit (sp, _, _)) = span_end sp
  | list_tactic_end (LtRotate (sp, _)) = span_end sp
  | list_tactic_end (LtReverse sp) = span_end sp
  | list_tactic_end (LtTry (sp, _)) = span_end sp
  | list_tactic_end (LtRepeat (sp, _)) = span_end sp
  | list_tactic_end (LtFirstLT t) = tactic_end t
  | list_tactic_end (LtSelectThen (_, t)) = tactic_end t
  | list_tactic_end (LtQSelectThen (_, t)) = tactic_end t
  | list_tactic_end (LtSelectGoal sp) = span_end sp
  | list_tactic_end (LtSelectGoals sp) = span_end sp
  | list_tactic_end (LtRepairGroup (sp, _)) = span_end sp
  | list_tactic_end (LtAtomic (_, sp)) = span_end sp

fun atomic e = TacAtomic (precedence e, span e)
fun list_atomic e = LtAtomic (precedence e, span e)

fun parse_tactic_ast e =
  case strip_closed_parens e of
      SOME inner => parse_tactic_ast inner
    | NONE =>
        (case e of
             Parens {exp, right = NONE, ...} => TacRepairGroup (span e, parse_tactic_ast exp)
           | ExpEmpty _ => TacAtomic (10, span e)
           | Infix {left, id = (_, opn), right} => parse_tactic_infix left opn right e
           | _ => parse_tactic_app e)
and parse_tactic_app e =
  case app_name e of
      SOME ("sg", [x]) => TacSubgoal (PlainSubgoal, span x)
    | SOME ("subgoal", [x]) => TacSubgoal (PlainSubgoal, span x)
    | SOME ("ALL_TAC", []) => TacThen []
    | SOME ("all_tac", []) => TacThen []
    | SOME ("EVERY", [xs]) => parse_every e xs
    | SOME ("FIRST", [xs]) => parse_first e xs
    | SOME ("FIRST_PROVE", [xs]) => parse_first_prove e xs
    | SOME ("VALID", [t]) => TacUnary (span e, "VALID", parse_tactic_ast t)
    | SOME ("VALIDATE", [t]) => TacUnary (span e, "VALIDATE", parse_tactic_ast t)
    | SOME ("CONJ_VALIDATE", [t]) => TacUnary (span e, "CONJ_VALIDATE", parse_tactic_ast t)
    | SOME ("CHANGED_TAC", [t]) => TacUnary (span e, "CHANGED_TAC", parse_tactic_ast t)
    | SOME ("GEN_VALIDATE", [flag, t]) => TacGenValidate (span e, span flag, parse_tactic_ast t)
    | SOME ("ADD_SGS_TAC", [goals, t]) => TacAddSgs (span e, span goals, parse_tactic_ast t)
    | SOME ("IF", [g, t, f]) => TacIf (span e, parse_tactic_ast g, parse_tactic_ast t, parse_tactic_ast f)
    | SOME ("MAP_EVERY", [f, xs]) => parse_map_every e f xs
    | SOME ("map_every", [f, xs]) => parse_map_every e f xs
    | SOME ("MAP_FIRST", [f, xs]) => parse_map_first e f xs
    | SOME ("TRY", [t]) => TacTry (span e, parse_tactic_ast t)
    | SOME ("REPEAT", [t]) => TacRepeat (span e, parse_tactic_ast t)
    | SOME ("rpt", [t]) => TacRepeat (span e, parse_tactic_ast t)
    | SOME ("REVERSE", [t]) => TacReverse (span e, parse_tactic_ast t)
    | SOME ("reverse", [t]) => TacReverse (span e, parse_tactic_ast t)
    | _ => atomic e
and parse_every whole xs =
  (case list_elems xs of SOME ts => TacThen (map parse_tactic_ast ts) | NONE => atomic whole)
and parse_first whole xs =
  (case list_elems xs of SOME ts => TacFirst (span whole, map parse_tactic_ast ts) | NONE => atomic whole)
and parse_first_prove whole xs =
  (case list_elems xs of SOME ts => TacFirstProve (span whole, map parse_tactic_ast ts) | NONE => atomic whole)
and parse_map_every whole f xs =
  (case list_elems xs of
      SOME args => TacThen (map (fn arg => TacApply (span f, span arg)) args)
    | NONE => atomic whole)
and parse_map_first whole f xs =
  (case list_elems xs of
      SOME [] => atomic whole
    | SOME args => TacMapFirst (span f, map (fn arg => TacApply (span f, span arg)) args)
    | NONE => atomic whole)
and parse_tactic_infix left opn right whole =
  case opn of
      ">>" => TacThen (flatten_then left @ flatten_then right)
    | "\\\\" => TacThen (flatten_then left @ flatten_then right)
    | "THEN" => TacThen (flatten_then left @ flatten_then right)
    | ">>>" => TacThenLT (parse_tactic_ast left, parse_list_tactic_ast right)
    | "THEN_LT" => TacThenLT (parse_tactic_ast left, parse_list_tactic_ast right)
    | "THENL" => parse_thenl left right whole
    | ">|" => parse_thenl left right whole
    | ">-" => TacThen1 (parse_tactic_ast left, parse_branch_rhs_ast right)
    | "THEN1" => TacThen1 (parse_tactic_ast left, parse_branch_rhs_ast right)
    | "by" => TacThen1 (TacSubgoal (BySubgoal, span left), parse_branch_rhs_ast right)
    | "suffices_by" => TacSufficesBy (span left, parse_branch_rhs_ast right)
    | "ORELSE" => TacOrelse (flatten_orelse left @ flatten_orelse right)
    | ">~" => TacThenLT (parse_tactic_ast left, LtSelectGoal (span right))
    | ">>~" => TacThenLT (parse_tactic_ast left, LtSelectGoals (span right))
    | ">>~-" => parse_select_then1 left right whole
    | _ => atomic whole
and parse_branch_rhs_ast e =
  case e of
      Parens {exp, right = SOME _, ...} => TacRepairGroup (span e, parse_tactic_ast exp)
    | _ => parse_tactic_ast e
and parse_thenl left right whole =
  case list_elems right of
      SOME branches => TacThenL (parse_tactic_ast left, map parse_branch_rhs_ast branches)
    | NONE => atomic whole
and parse_select_then1 left right whole =
  case tuple_elems right of
      SOME [pats, body] => TacThenLT (parse_tactic_ast left, LtQSelectThen (span pats, parse_tactic_ast body))
    | _ => atomic whole
and flatten_then e =
  case strip_closed_parens e of
      SOME inner => [TacRepairGroup (span e, parse_tactic_ast inner)]
    | NONE =>
        (case e of
             Infix {left, id = (_, opn), right} =>
               if opn = ">>" orelse opn = "\\\\" orelse opn = "THEN" then flatten_then left @ flatten_then right
               else [parse_tactic_ast e]
           | _ => [parse_tactic_ast e])
and flatten_orelse e =
  case strip_closed_parens e of
      SOME inner => flatten_orelse inner
    | NONE =>
        (case e of
             Infix {left, id = (_, "ORELSE"), right} => flatten_orelse left @ flatten_orelse right
           | _ => [parse_tactic_ast e])
and parse_list_tactic_ast e =
  case strip_closed_parens e of
      SOME inner => parse_list_tactic_ast inner
    | NONE =>
        (case e of
             Parens {exp, right = NONE, ...} => LtRepairGroup (span e, parse_list_tactic_ast exp)
           | Infix {left, id = (_, opn), right} => parse_list_tactic_infix left opn right e
           | _ => parse_list_tactic_app e)
and parse_list_tactic_app e =
  case app_name e of
      SOME ("TACS_TO_LT", [xs]) =>
        (case list_elems xs of SOME ts => LtTacsToLT (map parse_tactic_ast ts) | NONE => list_atomic e)
    | SOME ("EVERY_LT", [xs]) => parse_every_lt e xs
    | SOME ("VALID_LT", [lt]) => LtUnary (span e, "VALID_LT", parse_list_tactic_ast lt)
    | SOME ("VALIDATE_LT", [lt]) => LtUnary (span e, "VALIDATE_LT", parse_list_tactic_ast lt)
    | SOME ("GEN_VALIDATE_LT", [flag, lt]) => LtGenValidate (span e, span flag, parse_list_tactic_ast lt)
    | SOME ("TRYALL", [t]) => LtTryAll (span e, parse_tactic_ast t)
    | SOME ("SELECT_LT", [t]) => LtSelect (span e, parse_tactic_ast t)
    | SOME ("SELECT_LT_THEN", [selector, body]) => LtSelectThen (parse_tactic_ast selector, parse_tactic_ast body)
    | SOME ("ALLGOALS", [t]) => LtAllGoals (parse_tactic_ast t)
    | SOME ("NTH_GOAL", [t, n]) => LtNthGoal (parse_tactic_ast t, span n)
    | SOME ("LASTGOAL", [t]) => LtLastGoal (parse_tactic_ast t)
    | SOME ("HEADGOAL", [t]) => LtHeadGoal (parse_tactic_ast t)
    | SOME ("SPLIT_LT", [n, branches]) => parse_split_lt e n branches
    | SOME ("NULL_OK_LT", [lt]) => LtNullOk (span e, parse_list_tactic_ast lt)
    | SOME ("ROTATE_LT", [n]) => LtRotate (span e, span n)
    | SOME ("REVERSE_LT", []) => LtReverse (span e)
    | SOME ("TRY_LT", [lt]) => LtTry (span e, parse_list_tactic_ast lt)
    | SOME ("REPEAT_LT", [lt]) => LtRepeat (span e, parse_list_tactic_ast lt)
    | SOME ("FIRST_LT", [t]) => LtFirstLT (parse_tactic_ast t)
    | _ => list_atomic e
and parse_every_lt whole xs =
  (case list_elems xs of SOME lts => LtThenLT (map parse_list_tactic_ast lts) | NONE => list_atomic whole)
and parse_split_lt whole n branches =
  case tuple_elems branches of
      SOME [left, right] => LtSplit (span n, parse_list_tactic_ast left, parse_list_tactic_ast right)
    | _ => list_atomic whole
and parse_list_tactic_infix left opn right whole =
  case opn of
      ">>>" => LtThenLT (flatten_thenlt left @ flatten_thenlt right)
    | "THEN_LT" => LtThenLT (flatten_thenlt left @ flatten_thenlt right)
    | ">>" => LtThen (parse_list_tactic_ast left, flatten_then right)
    | "\\\\" => LtThen (parse_list_tactic_ast left, flatten_then right)
    | "THEN" => LtThen (parse_list_tactic_ast left, flatten_then right)
    | "ORELSE_LT" => LtOrelse (flatten_orelse_lt left @ flatten_orelse_lt right)
    | _ => list_atomic whole
and flatten_thenlt e =
  case strip_closed_parens e of
      SOME inner => flatten_thenlt inner
    | NONE =>
        (case e of
             Infix {left, id = (_, opn), right} =>
               if opn = ">>>" orelse opn = "THEN_LT" then flatten_thenlt left @ flatten_thenlt right
               else [parse_list_tactic_ast e]
           | _ => [parse_list_tactic_ast e])
and flatten_orelse_lt e =
  case strip_closed_parens e of
      SOME inner => flatten_orelse_lt inner
    | NONE =>
        (case e of
             Infix {left, id = (_, "ORELSE_LT"), right} => flatten_orelse_lt left @ flatten_orelse_lt right
           | _ => [parse_list_tactic_ast e])

fun parse_tactic_expr source =
  let
    val fed = ref false
    fun read _ = if !fed then "" else (fed := true; source)
    fun ignore_parse_error _ _ _ = ()
    val result = HOLSourceParser.parseSML "<holbuild proof ir tactic>" read ignore_parse_error HOLSourceParser.initialScope
  in
    case #parseDec result () of
        SOME (DecExp e) => e
      | NONE => ExpEmpty 0
      | _ => raise Fail "expected tactic expression"
  end

fun parse_tactic source = parse_tactic_ast (parse_tactic_expr source)

fun join_program combinator [] identity = identity
  | join_program _ [x] _ = x
  | join_program combinator (x :: xs) identity =
      List.foldl (fn (rhs, lhs) => combinator ^ "(" ^ lhs ^ ", " ^ rhs ^ ")") x xs

fun tactic_program source tactic =
  case tactic of
      TacThen [] => "Tactical.ALL_TAC"
    | TacThen xs => join_program "Tactical.THEN" (map (tactic_program source) xs) "Tactical.ALL_TAC"
    | TacThenLT (t, lt) => "Tactical.THEN_LT(" ^ tactic_program source t ^ ", " ^ list_tactic_program source lt ^ ")"
    | TacThen1 (a, b) => "Tactical.THEN1(" ^ tactic_program source a ^ ", " ^ tactic_program source b ^ ")"
    | TacThenL (a, bs) => "Tactical.THENL(" ^ tactic_program source a ^ ", [" ^ String.concatWith ", " (map (tactic_program source) bs) ^ "])"
    | TacOrelse xs => join_program "Tactical.ORELSE" (map (tactic_program source) xs) "Tactical.NO_TAC"
    | TacFirst (_, xs) => "Tactical.FIRST [" ^ String.concatWith ", " (map (tactic_program source) xs) ^ "]"
    | TacFirstProve (_, xs) => "Tactical.FIRST_PROVE [" ^ String.concatWith ", " (map (tactic_program source) xs) ^ "]"
    | TacUnary (_, name, t) => "Tactical." ^ name ^ "(" ^ tactic_program source t ^ ")"
    | TacGenValidate (_, flag, t) => "Tactical.GEN_VALIDATE " ^ source_text source flag ^ " (" ^ tactic_program source t ^ ")"
    | TacAddSgs (_, goals, t) => "Tactical.ADD_SGS_TAC " ^ source_text source goals ^ " (" ^ tactic_program source t ^ ")"
    | TacIf (_, g, t, f) => "Tactical.IF (" ^ tactic_program source g ^ ") (" ^ tactic_program source t ^ ") (" ^ tactic_program source f ^ ")"
    | TacTry (_, t) => "Tactical.TRY(" ^ tactic_program source t ^ ")"
    | TacRepeat (_, t) => "Tactical.REPEAT(" ^ tactic_program source t ^ ")"
    | TacReverse (_, t) => "Tactical.REVERSE(" ^ tactic_program source t ^ ")"
    | TacSubgoal (PlainSubgoal, sp) => "sg " ^ source_text source sp
    | TacSubgoal (BySubgoal, sp) => "BasicProvers.byA (" ^ source_text source sp ^ ", Tactical.ALL_TAC)"
    | TacApply (f, arg) => parenthesize (source_text source f) ^ " " ^ parenthesize (source_text source arg)
    | TacMapEvery _ => parenthesize (source_text source (tactic_span tactic))
    | TacMapFirst (_, ts) => "Tactical.FIRST [" ^ String.concatWith ", " (map (tactic_program source) ts) ^ "]"
    | TacSufficesBy (q, rhs) =>
        "Tactical.THEN1(qsuff_tac " ^ source_text source q ^ ", " ^ tactic_program source rhs ^ ")"
    | TacRepairGroup (_, t) => tactic_program source t
    | TacAtomic (_, sp) => parenthesize (source_text source sp)
and list_tactic_program source lt =
  case lt of
      LtThenLT [] => "Tactical.ALL_LT"
    | LtThenLT xs => join_program "Tactical.THEN_LT" (map (list_tactic_program source) xs) "Tactical.ALL_LT"
    | LtThen (lt, []) => list_tactic_program source lt
    | LtThen (lt, ts) => join_program "Tactical.THEN" (list_tactic_program source lt :: map (tactic_program source) ts) "Tactical.ALL_LT"
    | LtTacsToLT ts => "Tactical.TACS_TO_LT [" ^ String.concatWith ", " (map (tactic_program source) ts) ^ "]"
    | LtNullOk (_, lt) => "Tactical.NULL_OK_LT(" ^ list_tactic_program source lt ^ ")"
    | LtOrelse xs => join_program "Tactical.ORELSE_LT" (map (list_tactic_program source) xs) "Tactical.NO_LT"
    | LtUnary (_, name, lt) => "Tactical." ^ name ^ "(" ^ list_tactic_program source lt ^ ")"
    | LtGenValidate (_, flag, lt) => "Tactical.GEN_VALIDATE_LT " ^ source_text source flag ^ " (" ^ list_tactic_program source lt ^ ")"
    | LtTryAll (_, t) => "Tactical.TRYALL(" ^ tactic_program source t ^ ")"
    | LtSelect (_, t) => "Tactical.SELECT_LT(" ^ tactic_program source t ^ ")"
    | LtAllGoals t => "Tactical.ALLGOALS(" ^ tactic_program source t ^ ")"
    | LtNthGoal (t, n) => "Tactical.NTH_GOAL (" ^ tactic_program source t ^ ") (" ^ source_text source n ^ ")"
    | LtLastGoal t => "Tactical.LASTGOAL(" ^ tactic_program source t ^ ")"
    | LtHeadGoal t => "Tactical.HEADGOAL(" ^ tactic_program source t ^ ")"
    | LtSplit (n, a, b) => "Tactical.SPLIT_LT (" ^ source_text source n ^ ") (" ^ list_tactic_program source a ^ ", " ^ list_tactic_program source b ^ ")"
    | LtRotate (_, n) => "Tactical.ROTATE_LT (" ^ source_text source n ^ ")"
    | LtReverse _ => "Tactical.REVERSE_LT"
    | LtTry (_, lt) => "Tactical.TRY_LT(" ^ list_tactic_program source lt ^ ")"
    | LtRepeat (_, lt) => "Tactical.REPEAT_LT(" ^ list_tactic_program source lt ^ ")"
    | LtFirstLT t => "Tactical.FIRST_LT(" ^ tactic_program source t ^ ")"
    | LtSelectThen (selector, body) => "Tactical.SELECT_LT_THEN (" ^ tactic_program source selector ^ ") (" ^ tactic_program source body ^ ")"
    | LtQSelectThen (pats, body) => "Q.SELECT_GOALS_LT_THEN1 " ^ source_text source pats ^ " (" ^ tactic_program source body ^ ")"
    | LtSelectGoal sp => "Q.SELECT_GOAL_LT " ^ source_text source sp
    | LtSelectGoals sp => "Q.SELECT_GOALS_LT " ^ source_text source sp
    | LtRepairGroup (_, lt) => list_tactic_program source lt
    | LtAtomic (_, sp) => parenthesize (source_text source sp)
and tactic_span tactic =
  case tactic of
      TacThen [] => (0, 0)
    | TacThen xs => (#1 (tactic_span (hd xs)), #2 (tactic_span (List.last xs)))
    | TacThenLT (t, lt) => (#1 (tactic_span t), #2 (list_tactic_span lt))
    | TacThen1 (a, b) => (#1 (tactic_span a), #2 (tactic_span b))
    | TacThenL (a, []) => tactic_span a
    | TacThenL (a, bs) => (#1 (tactic_span a), #2 (tactic_span (List.last bs)))
    | TacOrelse [] => (0, 0)
    | TacOrelse xs => (#1 (tactic_span (hd xs)), #2 (tactic_span (List.last xs)))
    | TacFirst (sp, _) => sp
    | TacFirstProve (sp, _) => sp
    | TacUnary (sp, _, _) => sp
    | TacGenValidate (sp, _, _) => sp
    | TacAddSgs (sp, _, _) => sp
    | TacIf (sp, _, _, _) => sp
    | TacTry (sp, _) => sp
    | TacRepeat (sp, _) => sp
    | TacReverse (sp, _) => sp
    | TacSubgoal (_, sp) => sp
    | TacApply (f, arg) => (#1 f, #2 arg)
    | TacMapEvery (f, []) => f
    | TacMapEvery (f, xs) => (#1 f, #2 (List.last xs))
    | TacMapFirst (f, []) => f
    | TacMapFirst (f, xs) => (#1 f, #2 (tactic_span (List.last xs)))
    | TacSufficesBy (q, t) => (#1 q, #2 (tactic_span t))
    | TacRepairGroup (sp, _) => sp
    | TacAtomic (_, sp) => sp
and list_tactic_span lt =
  case lt of
      LtThenLT [] => (0, 0)
    | LtThenLT xs => (#1 (list_tactic_span (hd xs)), #2 (list_tactic_span (List.last xs)))
    | LtThen (lt, []) => list_tactic_span lt
    | LtThen (lt, ts) => (#1 (list_tactic_span lt), #2 (tactic_span (List.last ts)))
    | LtTacsToLT [] => (0, 0)
    | LtTacsToLT ts => (#1 (tactic_span (hd ts)), #2 (tactic_span (List.last ts)))
    | LtNullOk (sp, _) => sp
    | LtOrelse [] => (0, 0)
    | LtOrelse xs => (#1 (list_tactic_span (hd xs)), #2 (list_tactic_span (List.last xs)))
    | LtUnary (sp, _, _) => sp
    | LtGenValidate (sp, _, _) => sp
    | LtTryAll (sp, _) => sp
    | LtSelect (sp, _) => sp
    | LtAllGoals t => tactic_span t
    | LtNthGoal (t, n) => (#1 (tactic_span t), #2 n)
    | LtLastGoal t => tactic_span t
    | LtHeadGoal t => tactic_span t
    | LtSplit (n, _, _) => n
    | LtRotate (sp, _) => sp
    | LtReverse sp => sp
    | LtTry (sp, _) => sp
    | LtRepeat (sp, _) => sp
    | LtFirstLT t => tactic_span t
    | LtSelectThen (a, b) => (#1 (tactic_span a), #2 (tactic_span b))
    | LtQSelectThen (pats, b) => (#1 pats, #2 (tactic_span b))
    | LtSelectGoal sp => sp
    | LtSelectGoals sp => sp
    | LtRepairGroup (sp, _) => sp
    | LtAtomic (_, sp) => sp

fun tactic_label source (TacThen []) = "ALL_TAC"
  | tactic_label source (TacApply (f, arg)) = source_text source f ^ " " ^ source_text source arg
  | tactic_label source (TacMapFirst (f, ts)) =
      let
        fun arg_text (TacApply (_, arg)) = source_text source arg
          | arg_text t = tactic_label source t
      in "MAP_FIRST " ^ source_text source f ^ " [" ^ String.concatWith ", " (map arg_text ts) ^ "]" end
  | tactic_label source (TacSubgoal (PlainSubgoal, sp)) = "sg " ^ source_text source sp
  | tactic_label source (TacSubgoal (BySubgoal, sp)) = "by-subgoal " ^ source_text source sp
  | tactic_label source (TacRepairGroup (_, inner)) = tactic_label source inner
  | tactic_label source tactic = source_text source (tactic_span tactic)

fun tactic_step source tactic =
  let val sp = tactic_span tactic
  in
    StepTactic {start_pos = #1 sp, end_pos = #2 sp,
                label = tactic_label source tactic,
                program = tactic_program source tactic}
  end

fun list_step sp label program =
  StepList {start_pos = #1 sp, end_pos = #2 sp, label = label, program = program}

fun each_step sp body = StepEach {start_pos = #1 sp, end_pos = #2 sp, body = body}

fun select_first_solve_step sp body =
  StepSelect {start_pos = #1 sp, end_pos = #2 sp, selector = SelectFirst, mode = SelectSolve, body = body}

fun cases_step sp cases = StepCases {start_pos = #1 sp, end_pos = #2 sp, cases = cases}

fun choice_step sp label alternatives = StepChoice {start_pos = #1 sp, end_pos = #2 sp, label = label, alternatives = alternatives}

fun repeat_step (sp : int * int) body = StepRepeat {start_pos = #1 sp, end_pos = #2 sp, body = body}
fun try_step sp body = StepTry {start_pos = #1 sp, end_pos = #2 sp, body = body}

fun suffices_tactic_program source q = "qsuff_tac " ^ source_text source q
fun by_tactic_program source q = "sg " ^ source_text source q

fun branch_steps source rhs =
  select_first_solve_step (tactic_span rhs) (plan_tactic source rhs)

and needs_each_suffix tactic =
  case tactic of
      TacThen xs => List.exists needs_each_suffix xs
    | TacThen1 _ => true
    | TacThenL _ => true
    | TacSufficesBy _ => true
    | TacTry _ => true
    | TacOrelse _ => true
    | TacFirst _ => true
    | TacFirstProve _ => true
    | TacMapFirst _ => true
    | TacRepairGroup (_, inner) => needs_each_suffix inner
    | _ => false

and suffix_steps source tactic =
  case tactic of
      TacThen1 (lhs, rhs) => [each_step (tactic_span tactic) (plan_tactic source lhs @ [branch_steps source rhs])]
    | TacSufficesBy (q, rhs) =>
        [each_step (tactic_span tactic)
           [StepTactic {start_pos = #1 q, end_pos = #2 q, label = suffices_tactic_program source q, program = suffices_tactic_program source q},
            branch_steps source rhs]]
    | TacTry _ => [each_step (tactic_span tactic) (plan_tactic source tactic)]
    | TacOrelse _ => [each_step (tactic_span tactic) (plan_tactic source tactic)]
    | TacFirst _ => [each_step (tactic_span tactic) (plan_tactic source tactic)]
    | TacFirstProve _ => [each_step (tactic_span tactic) (plan_tactic source tactic)]
    | TacMapFirst _ => [each_step (tactic_span tactic) (plan_tactic source tactic)]
    | TacRepairGroup (_, inner) =>
        if needs_each_suffix inner then [each_step (tactic_span tactic) (plan_tactic source inner)]
        else plan_tactic source inner
    | _ => plan_tactic source tactic

and plan_tactic source tactic =
  case tactic of
      TacThen [] => [tactic_step source tactic]
    | TacThen (first :: rest) => plan_tactic source first @ List.concat (map (suffix_steps source) rest)
    | TacThen1 (lhs, rhs) =>
        plan_tactic source lhs @ [branch_steps source rhs]
    | TacThenL (lhs, branches) =>
        plan_tactic source lhs @ [cases_step (tactic_span tactic) (map (plan_tactic source) branches)]
    | TacThenLT (lhs, lt) => plan_tactic source lhs @ plan_list_tactic source ">>>" lt
    | TacReverse _ => [tactic_step source tactic]
    | TacOrelse xs => [choice_step (tactic_span tactic) (tactic_label source tactic) (map (fn t => plan_tactic source t) xs)]
    | TacTry (_, t) => [try_step (tactic_span tactic) (plan_tactic source t)]
    | TacRepeat _ => [tactic_step source tactic]
    | TacFirst (_, xs) => [choice_step (tactic_span tactic) (tactic_label source tactic) (map (fn t => plan_tactic source t) xs)]
    | TacFirstProve (_, xs) => [choice_step (tactic_span tactic) (tactic_label source tactic) (map (fn t => plan_tactic source t) xs)]
    | TacMapFirst (_, xs) => [choice_step (tactic_span tactic) (tactic_label source tactic) (map (fn t => plan_tactic source t) xs)]
    | TacSufficesBy (q, rhs) =>
        [StepTactic {start_pos = #1 q, end_pos = #2 q, label = suffices_tactic_program source q, program = suffices_tactic_program source q},
         branch_steps source rhs]
    | TacRepairGroup (_, inner) => plan_tactic source inner
    | _ => [tactic_step source tactic]
and plan_list_tactic source prefix lt =
  case lt of
      LtThenLT [] => [list_step (list_tactic_span lt) "ALL_LT" (list_tactic_program source lt)]
    | LtThenLT xs => List.concat (map (plan_list_tactic source prefix) xs)
    | LtTacsToLT ts =>
        [list_step (list_tactic_span lt)
           ("TACS_TO_LT [" ^ String.concatWith ", " (map (tactic_label source) ts) ^ "]")
           (list_tactic_program source lt)]
    | LtAllGoals t =>
        [list_step (list_tactic_span lt)
           ("ALLGOALS (" ^ tactic_label source t ^ ")")
           (list_tactic_program source lt)]
    | LtNthGoal (t, n) =>
        [list_step (list_tactic_span lt)
           ("NTH_GOAL (" ^ tactic_label source t ^ ") " ^ source_text source n)
           (list_tactic_program source lt)]
    | LtLastGoal t =>
        [list_step (list_tactic_span lt)
           ("LASTGOAL (" ^ tactic_label source t ^ ")")
           (list_tactic_program source lt)]
    | LtHeadGoal t =>
        [list_step (list_tactic_span lt)
           ("HEADGOAL (" ^ tactic_label source t ^ ")")
           (list_tactic_program source lt)]
    | LtSplit (n, a, b) =>
        [list_step (list_tactic_span lt)
           ("SPLIT_LT " ^ source_text source n ^ " (" ^ list_tactic_label source a ^ ", " ^ list_tactic_label source b ^ ")")
           (list_tactic_program source lt)]
    | LtFirstLT t =>
        [list_step (list_tactic_span lt)
           ("FIRST_LT " ^ tactic_label source t)
           (list_tactic_program source lt)]
    | LtUnary _ =>
        [list_step (list_tactic_span lt) (list_tactic_label source lt) (list_tactic_program source lt)]
    | LtGenValidate _ =>
        [list_step (list_tactic_span lt) (list_tactic_label source lt) (list_tactic_program source lt)]
    | LtTryAll _ =>
        [list_step (list_tactic_span lt) (list_tactic_label source lt) (list_tactic_program source lt)]
    | LtSelect _ =>
        [list_step (list_tactic_span lt) (list_tactic_label source lt) (list_tactic_program source lt)]
    | LtNullOk _ =>
        [list_step (list_tactic_span lt) (list_tactic_label source lt) (list_tactic_program source lt)]
    | LtRotate _ =>
        [list_step (list_tactic_span lt) (list_tactic_label source lt) (list_tactic_program source lt)]
    | LtReverse _ =>
        [list_step (list_tactic_span lt) "REVERSE_LT" (list_tactic_program source lt)]
    | LtTry _ =>
        [list_step (list_tactic_span lt) (list_tactic_label source lt) (list_tactic_program source lt)]
    | LtRepeat _ =>
        [list_step (list_tactic_span lt) (list_tactic_label source lt) (list_tactic_program source lt)]
    | LtOrelse _ =>
        [list_step (list_tactic_span lt) (list_tactic_label source lt) (list_tactic_program source lt)]
    | LtSelectGoal sp =>
        [StepSelect {start_pos = #1 sp, end_pos = #2 sp,
                     selector = SelectMatchingFirst (source_text source sp),
                     mode = SelectKeep, body = []}]
    | LtSelectGoals sp =>
        [StepSelect {start_pos = #1 sp, end_pos = #2 sp,
                     selector = SelectMatchingAll (source_text source sp),
                     mode = SelectKeep, body = []}]
    | LtQSelectThen (pats, body) =>
        [StepSelect {start_pos = #1 pats, end_pos = #2 (tactic_span body),
                     selector = SelectMatchingAll (source_text source pats),
                     mode = SelectSolve, body = plan_tactic source body}]
    | LtSelectThen (selector, body) =>
        [list_step (list_tactic_span lt)
           ("SELECT_LT_THEN (" ^ tactic_label source selector ^ ") (" ^ tactic_label source body ^ ")")
           (list_tactic_program source lt)]
    | _ => [list_step (list_tactic_span lt) (source_text source (list_tactic_span lt)) (list_tactic_program source lt)]
and list_tactic_label source lt =
  case lt of
      LtTacsToLT ts => "TACS_TO_LT [" ^ String.concatWith ", " (map (tactic_label source) ts) ^ "]"
    | LtAllGoals t => "ALLGOALS (" ^ tactic_label source t ^ ")"
    | LtNthGoal (t, n) => "NTH_GOAL (" ^ tactic_label source t ^ ") " ^ source_text source n
    | LtLastGoal t => "LASTGOAL (" ^ tactic_label source t ^ ")"
    | LtHeadGoal t => "HEADGOAL (" ^ tactic_label source t ^ ")"
    | LtSplit (n, a, b) => "SPLIT_LT " ^ source_text source n ^ " (" ^ list_tactic_label source a ^ ", " ^ list_tactic_label source b ^ ")"
    | LtUnary (_, name, inner) => name ^ " (" ^ list_tactic_label source inner ^ ")"
    | LtGenValidate (_, flag, inner) => "GEN_VALIDATE_LT " ^ source_text source flag ^ " (" ^ list_tactic_label source inner ^ ")"
    | LtTryAll (_, t) => "TRYALL (" ^ tactic_label source t ^ ")"
    | LtSelect (_, t) => "SELECT_LT (" ^ tactic_label source t ^ ")"
    | LtNullOk (_, inner) => "NULL_OK_LT (" ^ list_tactic_label source inner ^ ")"
    | LtRotate (_, n) => "ROTATE_LT " ^ source_text source n
    | LtReverse _ => "REVERSE_LT"
    | LtTry _ => source_text source (list_tactic_span lt)
    | LtRepeat _ => source_text source (list_tactic_span lt)
    | LtFirstLT t => "FIRST_LT " ^ tactic_label source t
    | LtOrelse xs => String.concatWith " ORELSE_LT " (map (list_tactic_label source) xs)
    | LtRepairGroup (_, inner) => list_tactic_label source inner
    | _ => source_text source (list_tactic_span lt)

fun span_text source (start, stop) = String.substring(source, start, stop - start)

fun plain_steps source =
  [StepTactic {start_pos = 0, end_pos = size source,
               label = trim_space source, program = source}]

fun steps source =
  (plan_tactic source (parse_tactic_ast (parse_tactic_expr source))
   handle _ => plain_steps source)


end
