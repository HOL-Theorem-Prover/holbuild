open HolKernel Parse boolLib bossLib;

val _ = new_theory "PureRepro";

Datatype:
  args = <| x_arg : num |>
End

Datatype:
  locals = <| x : num; y : num |>
End

Datatype:
  machine = <| args : args; locals : locals |>
End

Datatype:
  value = NoneV | BoolV bool | ArrayV num | IntV num | FlagV num | ExtraA num | ExtraB num | ExtraC num | ExtraD num
End

Datatype:
  outcome = MRet num machine | MExc num machine
End

Definition evaluate_binop_def:
  evaluate_binop (a:num) (b:num) (c:num) (d:num) (e:num) = (INL (IntV (d + e)) : value + num)
End

Definition state_view_def:
  state_view m = m.locals
End

Definition body_def:
  body m =
  (case evaluate_binop 0 0 0 m.args.x_arg 10 of
     INL NoneV => MExc 0 (m with locals updated_by (λlocals. locals with x := m.args.x_arg))
   | INL (BoolV v44) => MExc 0 (m with locals updated_by (λlocals. locals with x := m.args.x_arg))
   | INL (ArrayV v45) => MExc 0 (m with locals updated_by (λlocals. locals with x := m.args.x_arg))
   | INL (IntV bop_body_1_rhs) =>
       (case evaluate_binop 0 0 0 bop_body_1_rhs 100 of
          INL NoneV => MExc 0 (m with locals updated_by ((λlocals. locals with x := bop_body_1_rhs) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (BoolV T) =>
            (case evaluate_binop 0 0 0 100 20 of
               INL NoneV => MExc 0 (m with locals updated_by ((λlocals. locals with x := 100) ∘ (λlocals. locals with x := bop_body_1_rhs) ∘ (λlocals. locals with x := m.args.x_arg)))
             | INL (BoolV T) => MRet 100 (m with locals updated_by ((λlocals. locals with x := 100) ∘ (λlocals. locals with x := bop_body_1_rhs) ∘ (λlocals. locals with x := m.args.x_arg)))
             | INL (BoolV F) =>
                 (case evaluate_binop 0 0 0 100 20 of
                    INL NoneV => MExc 0 (m with locals updated_by ((λlocals. locals with x := 100) ∘ (λlocals. locals with x := bop_body_1_rhs) ∘ (λlocals. locals with x := m.args.x_arg)))
                  | INL (BoolV v10) => MExc 0 (m with locals updated_by ((λlocals. locals with x := 100) ∘ (λlocals. locals with x := bop_body_1_rhs) ∘ (λlocals. locals with x := m.args.x_arg)))
                  | INL (ArrayV v11) => MExc 0 (m with locals updated_by ((λlocals. locals with x := 100) ∘ (λlocals. locals with x := bop_body_1_rhs) ∘ (λlocals. locals with x := m.args.x_arg)))
                  | INL (IntV bop_body_4_rhs) => MRet bop_body_4_rhs (m with locals updated_by ((λlocals. locals with y := bop_body_4_rhs) ∘ (λlocals. locals with x := 100) ∘ (λlocals. locals with x := bop_body_1_rhs) ∘ (λlocals. locals with x := m.args.x_arg)))
                  | INL (FlagV v13) => MExc 0 (m with locals updated_by ((λlocals. locals with x := 100) ∘ (λlocals. locals with x := bop_body_1_rhs) ∘ (λlocals. locals with x := m.args.x_arg)))
                  | INL (ExtraA q) => MExc 0 (m with locals updated_by ((λlocals. locals with x := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraB q) => MExc 0 (m with locals updated_by ((λlocals. locals with y := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraC q) => MRet q (m with locals updated_by ((λlocals. locals with x := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraD q) => MExc 0 (m with locals updated_by ((λlocals. locals with y := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INR e => MExc 0 m)
             | INL (ArrayV v11) => MExc 0 m
             | INL (IntV bop_body_4_rhs) => MRet bop_body_4_rhs m
             | INL (BoolV v99) => MExc 0 (m with locals updated_by ((λlocals. locals with x := 101) ∘ (λlocals. locals with x := m.args.x_arg)))
   | INL (BoolV v98) => MExc 0 (m with locals updated_by ((λlocals. locals with y := 102) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (FlagV v13) => MExc 0 m
             | INL (ExtraA q) => MExc 0 (m with locals updated_by ((λlocals. locals with x := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraB q) => MExc 0 (m with locals updated_by ((λlocals. locals with y := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraC q) => MRet q (m with locals updated_by ((λlocals. locals with x := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraD q) => MExc 0 (m with locals updated_by ((λlocals. locals with y := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INR e => MExc 0 m)
        | INL (BoolV F) => MExc 0 m
        | INL (ArrayV v11) => MExc 0 m
        | INL (IntV bop_body_4_rhs) => MRet bop_body_4_rhs m
        | INL (FlagV v13) => MExc 0 m
        | INL (ExtraA q) => MExc 0 (m with locals updated_by ((λlocals. locals with x := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraB q) => MExc 0 (m with locals updated_by ((λlocals. locals with y := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraC q) => MRet q (m with locals updated_by ((λlocals. locals with x := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraD q) => MExc 0 (m with locals updated_by ((λlocals. locals with y := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INR e => MExc 0 m)
   | INL (FlagV v13) => MExc 0 m
   | INL (ExtraA q) => MExc 0 (m with locals updated_by ((λlocals. locals with x := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraB q) => MExc 0 (m with locals updated_by ((λlocals. locals with y := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraC q) => MRet q (m with locals updated_by ((λlocals. locals with x := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INL (ExtraD q) => MExc 0 (m with locals updated_by ((λlocals. locals with y := q) ∘ (λlocals. locals with x := m.args.x_arg)))
        | INR e => MExc 0 m)
End

Theorem neutral_checkpoint_xxxxxxxxxxxxx:
  T
Proof
  simp[]
QED

Theorem neutral_failure_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx:
  (∀m r m'. body m = MRet r m' ⇒ state_view m' = state_view m) /\
  (∀m r m'. body m = MRet r m' ⇒ state_view m' = state_view m) /\
  (∀m r m'. body m = MRet r m' ⇒ state_view m' = state_view m) /\
  (∀m r m'. body m = MRet r m' ⇒ state_view m' = state_view m) /\
  (∀m r m'. body m = MRet r m' ⇒ state_view m' = state_view m) /\
  (∀m r m'. body m = MRet r m' ⇒ state_view m' = state_view m) /\
  (∀m r m'. body m = MRet r m' ⇒ state_view m' = state_view m) /\
  (∀m r m'. body m = MRet r m' ⇒ state_view m' = state_view m)
Proof
  rw[body_def, state_view_def] >>
  rpt (BasicProvers.TOP_CASE_TAC >> gvs[state_view_def])
QED

val _ = export_theory();
