(* step_create_push_structure: structural facts when step_create grows.
   We peel prefix ops using bind_psf_grows_extract to get same_frame_rel s sm.
   proceed_create modifies LAST context's SND.accounts via set_original,
   so we only claim accesses preservation (not storage equality) for per-position
   SND facts. For the old head (position 1 in new stack), we additionally
   claim storage equality for a ≠ callee, since set_original only modifies
   the callee address. *)
Theorem step_create_push_structure:
  step_create two s = (r, s') ∧ s.contexts ≠ [] ∧
  LENGTH s'.contexts > LENGTH s.contexts ⇒
  MAP FST (TL (TL s'.contexts)) = MAP FST (TL s.contexts) ∧
  (∀i. i < LENGTH s.contexts ⇒
       (SND (EL i (TL s'.contexts))).accesses = (SND (EL i s.contexts)).accesses) ∧
  (FST (HD (TL s'.contexts))).msgParams = (FST (HD s.contexts)).msgParams ∧
  toSet s.rollback.accesses.storageKeys ⊆ toSet s'.rollback.accesses.storageKeys ∧
  outputTo_consistent_ctx (FST (HD s'.contexts)) ∧
  toSet s.rollback.accesses.storageKeys ⊆ toSet (SND (HD s'.contexts)).accesses.storageKeys ∧
  (∀a. a ≠ (FST (HD s'.contexts)).msgParams.callee ⇒
     (lookup_account a (SND (HD (TL s'.contexts))).accounts).storage =
     (lookup_account a (SND (HD s.contexts)).accounts).storage) ∧
  (∀i. i < LENGTH s.contexts - 1 ⇒
     (SND (EL i (TL s'.contexts))).accounts =
     (SND (EL i s.contexts)).accounts) ∧
  (∀a. a ≠ (FST (HD s'.contexts)).msgParams.callee ⇒
    (lookup_account a (SND (EL (LENGTH s.contexts) s'.contexts)).accounts).storage =
    (lookup_account a (SND (LAST s.contexts)).accounts).storage)
Proof
  simp[step_create_def] >> strip_tac
  (* Peel pop_stack *)
  >> qmatch_asmsub_abbrev_tac`pop_stack n`
  >> `preserves_same_frame (pop_stack n)` by simp[]
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> `sm.contexts ≠ []` by (strip_tac >> gvs[same_frame_rel_def])
  >> `LENGTH sm.contexts = LENGTH s.contexts` by gvs[same_frame_rel_def]
  (* Peel memory_expansion_info *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ sm = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel sm s2`
  >> `same_frame_rel s s2` by metis_tac[same_frame_rel_trans]
  >> `s2.contexts ≠ [] ∧ LENGTH s2.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel consume_gas *)
  >> gvs[ignore_bind_def]
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel s2 s3`
  >> `same_frame_rel s s3` by metis_tac[same_frame_rel_trans]
  >> `s3.contexts ≠ [] ∧ LENGTH s3.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel expand_memory *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel s3 s4`
  >> `same_frame_rel s s4` by metis_tac[same_frame_rel_trans]
  >> `s4.contexts ≠ [] ∧ LENGTH s4.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel read_memory *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel s4 s5`
  >> `same_frame_rel s s5` by metis_tac[same_frame_rel_trans]
  >> `s5.contexts ≠ [] ∧ LENGTH s5.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel get_callee *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel s5 s6`
  >> `same_frame_rel s s6` by metis_tac[same_frame_rel_trans]
  >> `s6.contexts ≠ [] ∧ LENGTH s6.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel get_accounts *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel s6 s7`
  >> `same_frame_rel s s7` by metis_tac[same_frame_rel_trans]
  >> `s7.contexts ≠ [] ∧ LENGTH s7.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel assert (code length) via ignore_bind *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel s7 s8`
  >> `same_frame_rel s s8` by metis_tac[same_frame_rel_trans]
  >> `s8.contexts ≠ [] ∧ LENGTH s8.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel access_address *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel s8 s9`
  >> `same_frame_rel s s9` by metis_tac[same_frame_rel_trans]
  >> `s9.contexts ≠ [] ∧ LENGTH s9.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel get_gas_left *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel s9 s0`
  >> `same_frame_rel s s0` by metis_tac[same_frame_rel_trans]
  >> `s0.contexts ≠ [] ∧ LENGTH s0.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel consume_gas (cappedGas) *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel s0 sa`
  >> `same_frame_rel s sa` by metis_tac[same_frame_rel_trans]
  >> `sa.contexts ≠ [] ∧ LENGTH sa.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel assert_not_static *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel sa sb`
  >> `same_frame_rel s sb` by metis_tac[same_frame_rel_trans]
  >> `sb.contexts ≠ [] ∧ LENGTH sb.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel set_return_data *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel sb sc`
  >> `same_frame_rel s sc` by metis_tac[same_frame_rel_trans]
  >> `sc.contexts ≠ [] ∧ LENGTH sc.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel get_num_contexts *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel sc sd`
  >> `same_frame_rel s sd` by metis_tac[same_frame_rel_trans]
  >> `sd.contexts ≠ [] ∧ LENGTH sd.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Peel ensure_storage_in_domain *)
  >> drule_at (Pat`bind`) bind_psf_grows_extract
  >> simp[] >> qpat_x_assum`_ _ = (_,_)`kall_tac >> strip_tac >> gvs[]
  >> rename1`same_frame_rel sd se`
  >> `same_frame_rel s se` by metis_tac[same_frame_rel_trans]
  >> `se.contexts ≠ [] ∧ LENGTH se.contexts = LENGTH s.contexts`
  by (rpt strip_tac >> gvs[same_frame_rel_def])
  (* Now at the conditional *)
  >> gvs[Ntimes COND_RATOR 2]
  >> qmatch_asmsub_abbrev_tac`COND bbb _ _ = (_, _)`
  >> qpat_x_assum`COND bbb _ _ = _`mp_tac
  >> IF_CASES_TAC
  >- ((* abort_unuse: preserves_same_frame, can't grow *)
      strip_tac >>
      drule_at (Pat`_ = (_, s')`) psf_imp_length_contexts_preserved
      >> simp[])
  >> IF_CASES_TAC
  >- ((* abort_create_exists: length_preserves, can't grow *)
      strip_tac >>
      drule (REWRITE_RULE[length_preserves_def] length_preserves_abort_create_exists)
      >> simp[])
  (* Now we have proceed_create sf = (_, s') with growth, and same_frame_rel s sf *)
  >> strip_tac
  >> drule_all proceed_create_push_structure
  >> strip_tac
  (* From same_frame_rel s sf: TL sf.contexts = TL s.contexts *)
  >> `TL se.contexts = TL s.contexts` by gvs[same_frame_rel_def]
  >> gvs[]
  >> conj_asm1_tac >- (
    qpat_x_assum`same_frame_rel s se`mp_tac >>
    simp[same_frame_rel_def] >> strip_tac >>
    Cases_on`s'.contexts` >> gvs[] >>
    Cases_on`t` >> gvs[] >>
    Cases_on`se.contexts` >> gvs[] )
  (* Remaining: per-pos accesses, msgParams, rollback, outputTo, SND(HD),
     a≠callee storage *)
  >> rewrite_tac[Ntimes CONJ_ASSOC 3]
  >> reverse conj_tac >- (
    (* a ≠ callee ⇒ storage equality at position 1.
       set_last_accounts only modifies the LAST element's .accounts.
       When LENGTH se.contexts > 1, HD of TL is NOT the last, so unchanged.
       When LENGTH se.contexts = 1, HD of TL IS the last, modified by
       set_last_accounts (update_account address empty_account_state)
       which doesn't touch a ≠ address. *)
    qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac >>
    rewrite_tac[proceed_create_def] >>
    simp[ignore_bind_def, bind_def, update_accounts_def, return_def,
          get_rollback_def, get_original_def, set_original_def, fail_def] >>
    strip_tac >> gvs[] >>
    drule push_context_effect >> strip_tac >> gvs[] >>
    simp[lookup_storage_def, lookup_account_def] >>
    qmatch_goalsub_abbrev_tac`SND (EL _ (slc uc _))` >>
    qmatch_goalsub_abbrev_tac`(SND (EL _ icc)).accounts _` >>
    gvs[push_context_def,return_def,execution_state_component_equality] >>
    gvs[account_already_created_def,lookup_account_def] >>
    Cases_on`s.contexts` >- gvs[] >> simp[] >>
    Cases_on`se.contexts` >- gvs[] >> simp[Abbr`slc`] >>
    gvs[set_last_accounts_def] >>
    simp[EL_SNOC] >>
    simp[Abbr`icc`] >>
    qmatch_goalsub_abbrev_tac`EL (LENGTH t) (SNOC sn fr)` >>
    `LENGTH fr = LENGTH t` by simp[Abbr`fr`] >>
    pop_assum(SUBST1_TAC o SYM) >> simp[EL_LENGTH_SNOC,Abbr`sn`] >>
    gvs[Abbr`fr`] >>
    `SND h = SND h'` by (
      qpat_x_assum`same_frame_rel s se`mp_tac >>
      simp[same_frame_rel_def] ) >>
    simp[initial_msg_params_def] >>
    reverse(qspec_then`t`FULL_STRUCT_CASES_TAC SNOC_CASES >> gvs[]) >- (
      simp[LAST_CONS_SNOC, FRONT_CONS_SNOC] >>
      conj_tac >- ( Cases >> simp[EL_SNOC] ) >>
      simp[Abbr`uc`, update_account_def, APPLY_UPDATE_THM] >>
      gen_tac >> simp[LAST_CONS_SNOC] ) >>
    simp[Abbr`uc`, lookup_account_def, update_account_def, APPLY_UPDATE_THM] )
  >> simp[GSYM CONJ_ASSOC]
  >> reverse conj_tac >- (
    (* SND (HD s'.contexts) accesses subset *)
    reverse conj_tac
    >- metis_tac[SUBSET_TRANS, same_frame_rel_def] >>
    (* msgParams *)
    qpat_x_assum`same_frame_rel s se`mp_tac >>
    simp[same_frame_rel_def] >> strip_tac >>
    Cases_on`s.contexts` >- gvs[] >> simp[] >>
    Cases_on`s'.contexts` >- gvs[] >> simp[] >>
    Cases_on`t'` >- gvs[] >> simp[] >>
    Cases_on`se.contexts` >- gvs[] >>
    fs[]  )
  (* Per-position accesses preservation: set_original only touches .accounts *)
  >> qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac
  >> simp[proceed_create_def]
  >> simp[ignore_bind_def, bind_def, update_accounts_def, return_def,
          get_rollback_def, get_original_def, set_original_def, fail_def]
  >> strip_tac >> gvs[]
  >> drule push_context_effect >> strip_tac >> gvs[]
  (* TL s'.contexts = set_last_accounts ... sf.contexts *)
  >> rpt strip_tac
  >> `i < LENGTH se.contexts` by gvs[same_frame_rel_def]
  >> simp[set_last_accounts_def]
  >> qmatch_goalsub_abbrev_tac`SNOC new`
  >> qhdtm_x_assum`push_context` kall_tac
  >> qpat_x_assum`_ = TL s.contexts`mp_tac
  >> simp[LIST_EQ_REWRITE] >> rewrite_tac[GSYM EL]
  >> Cases_on`i=0` >- (
    Cases_on`FRONT se.contexts = []`
    >- (
      gvs[] >>
      gvs[Abbr`new`] >>
      Cases_on`se.contexts` >> gvs[] >>
      Cases_on`s.contexts` >> gvs[] >>
      qpat_x_assum`same_frame_rel s se`mp_tac >>
      simp[same_frame_rel_def] ) >>
    rewrite_tac[GSYM EL] >>
    DEP_REWRITE_TAC[EL_SNOC] >>
    simp[LENGTH_FRONT] >>
    simp[PRE_SUB1] >>
    Cases_on`se.contexts` >> gvs[] >>
    Cases_on`s.contexts` >> gvs[] >>
    Cases_on`t` >> gvs[] >>
    qpat_x_assum`same_frame_rel s se`mp_tac >>
    simp[same_frame_rel_def] )
  >> Cases_on`i = LENGTH s.contexts - 1`
  >- (
    `i = LENGTH (FRONT se.contexts)` by simp[LENGTH_FRONT] >>
    pop_assum SUBST1_TAC >>
    simp[EL_LENGTH_SNOC] >>
    simp[Abbr`new`, LENGTH_FRONT, GSYM LAST_EL] >>
    simp[LAST_EL] >> strip_tac >>
    AP_TERM_TAC >> AP_TERM_TAC >>
    first_x_assum(qspec_then`PRE i`mp_tac) >>
    simp[PRE_SUB1,ADD1] )
  >> strip_tac
  >> simp[EL_SNOC, LENGTH_FRONT, EL_FRONT, NULL_EQ]
  >> first_x_assum(qspec_then`PRE i`mp_tac)
  >> simp[ADD1, PRE_SUB1]
QED
