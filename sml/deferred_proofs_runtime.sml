(* Deferred proofs, for a pipelined build's theory child.

   The child's script has each deferred proof wrapped in `defer`, which
   records the goal and accepts it with a stub.  Once the script has
   exported, `publish_outline` writes the theory's data as its children
   may load it, before any deferred proof has run; `prove_all` proves the
   recorded goals on several threads; `finalize` rewrites the data with
   what the proofs depend on.

   A stub carries two markers: the oracle "holbuild_deferred_<k>", which
   every theorem derived from it inherits, and the dependency
   (current theory, marker_base + k), which reaches only the theorems
   derived from it while it is unsaved (a saved theorem's users depend on
   its save index instead, as in a real build).  Rewriting the data
   replaces each marker by what proof k's theorem carries.  Loaded only
   into heaps with context-taking tactics.

   A proof run after the export, beside others, can record other
   dependencies than it does run in place (metis's search depends on the
   global variable counter), so the data equals a plain build's in all
   the digest covers but not always byte for byte. *)
structure HolbuildDeferred =
struct
  val marker_base = 1000000
  val oracle_prefix = "holbuild_deferred_"

  (* A `Resume` block of a deferred group (below): its label, the context,
     tactic and setup it runs with, and the deferred groups open (not
     finalised) when the script reached it. *)
  type resume = {label : string, ctxt : Context.t, make : unit -> Tactical.tactic,
                 setup : (unit -> unit) option, open_with : string list}

  (* SETUP, for a proof run by holbuild's proof runtime (proof steps on),
     tells the runtime which theorem the proof is before it runs.  GROUP
     is set for a theorem deferred with its `Resume` blocks: the labels
     they resume, how many there are, those the script has reached, the
     latest first, and the deferred groups still open (not finalised)
     when the script stated it. *)
  type item = {k : int, name : string, ctxt : Context.t, goal : Tactical.goal,
               make : unit -> Tactical.tactic, setup : (unit -> unit) option,
               group : {labels : string list, resumes : int, reached : resume list ref,
                        open_with : string list} option}

  (* Elaboration runs on one thread; prove_all drains these. *)
  val queue = ref ([] : item list)
  val marker_data = ref (NONE : HOLsexp.t option)
  val proved = ref ([] : (int * ((string * int list) list * string list)) list)

  (* A theorem of GOAL carrying proof k's markers. *)
  fun stub k goal =
    let
      val empty_tag = Thm.tag (Thm.REFL boolSyntax.T)
      val dep = Dep.DEP_UNSAVED [(Theory.current_theory (), [marker_base + k])]
    in
      Thm.add_tag (Tag.set_dep dep empty_tag, Thm.mk_oracle_thm (oracle_prefix ^ Int.toString k) goal)
    end

  fun enqueue (item as {k, name, ...} : item) =
    (* Each goal number names one theorem's proof; a second stub for it
       would share the first one's markers. *)
    if List.exists (fn {k = queued, ...} : item => queued = k) (!queue) then
      raise Fail ("deferred goal " ^ Int.toString k ^ " (" ^ name ^ ") queued twice")
    else queue := item :: !queue

  fun defer_with setup k name make : Tactical.tactic = fn goal => fn ctxt =>
    (enqueue {k = k, name = name, ctxt = ctxt, goal = goal, make = make, setup = setup, group = NONE};
     Tactic.ACCEPT_TAC (stub k goal) goal ctxt)

  fun defer k name make = defer_with NONE k name make
  fun defer_steps k name setup make = defer_with (SOME setup) k name make

  (* Deferred groups.  A theorem that suspends goals (markerLib.suspend),
     whose `Resume` blocks follow it in the script and whose `Finalise`
     follows them, is deferred with its blocks as one proof k.  At the
     theorem, its stub carries a suspended goal for each label the blocks
     resume, each the true statement B_k; each block's stub proves B_k.
     markerLib then stashes the theorem, resumes it and finalises it as it
     would the real one, so the theorem is saved at its `Finalise` and the
     theory data records the same suspensions; once a theory is exported
     those of a finalised theorem are gone (HOL's markerLib drops the
     out-of-date ones, which build_exec checks the toolchain does before
     deferring a group).  prove_all then proves the theorem, and each
     block in its own context, and assembles them as Finalise does.

     B_k is a different closed term for each k, so that two groups open at
     once, resuming the same label, never share a suspended goal (which
     markerLib would read as one citing the other), and the kernel proves
     it, so every statement made under proof k's markers is true. *)
  fun dummy_body k =
    let
      fun digits 0 acc = acc
        | digits n acc = digits (n div 2) ((n mod 2 = 1) :: acc)
      fun digit true = boolSyntax.mk_neg boolSyntax.F
        | digit false = boolSyntax.T
    in
      if k = 0 then boolSyntax.T else boolSyntax.list_mk_conj (map digit (digits k []))
    end

  fun dummy_thm k = Drule.EQT_ELIM (Conv.QCONV (Rewrite.REWRITE_CONV []) (dummy_body k))

  (* markerLib's encoding of a label whose goal has no closure
     variables. *)
  fun encoded_label label =
    let val encoded = "0 " ^ label
    in
      if boolLib.decode_suspend_label encoded = (label, 0) then encoded
      else raise Fail ("label " ^ label ^ " has no encoding as a suspended goal")
    end

  (* |- suspendlabel <label> B_k. *)
  fun dummy_label_thm k label = markerLib.add_suspension_label (encoded_label label) (dummy_thm k)

  fun open_groups () =
    List.mapPartial
      (fn {name, group, ...} : item =>
          if Option.isSome group andalso
             Option.isSome (markerLib.lookup_suspension (Theory.current_theory () ^ "." ^ name))
          then SOME name
          else NONE)
      (!queue)

  fun defer_group_with setup k name labels resumes make : Tactical.tactic = fn goal => fn ctxt =>
    let val suspended = map (fn label => Thm.concl (dummy_label_thm k label)) labels
    in
      enqueue {k = k, name = name, ctxt = ctxt, goal = goal, make = make, setup = setup,
               group = SOME {labels = labels, resumes = resumes, reached = ref [], open_with = open_groups ()}};
      Tactic.ACCEPT_TAC (stub k (suspended @ #1 goal, #2 goal)) goal ctxt
    end

  fun defer_group k name labels resumes make = defer_group_with NONE k name labels resumes make
  fun defer_group_steps k name labels resumes setup make = defer_group_with (SOME setup) k name labels resumes make

  (* The `Resume` block LABEL of the deferred group THEOREM: markerLib gives
     it the group's B_k to prove. *)
  fun defer_resume_with setup theorem label make : Tactical.tactic = fn goal => fn ctxt =>
    case List.find (fn {name, group, ...} : item => name = theorem andalso Option.isSome group) (!queue) of
        SOME {k, group = SOME {reached, ...}, ...} =>
          if null (#1 goal) andalso Term.aconv (#2 goal) (dummy_body k) then
            (reached := {label = label, ctxt = ctxt, make = make, setup = setup, open_with = open_groups ()} :: !reached;
             Tactic.ACCEPT_TAC (stub k goal) goal ctxt)
          else raise Fail ("Resume " ^ theorem ^ "[" ^ label ^ "] has another goal than its deferred group's")
      | _ => raise Fail ("Resume " ^ theorem ^ "[" ^ label ^ "] has no deferred group")

  fun defer_resume theorem label make = defer_resume_with NONE theorem label make
  fun defer_resume_steps theorem label setup make = defer_resume_with (SOME setup) theorem label make

  fun segment_data ty = Theory.LoadableThyData.segment_data {thy = Theory.current_theory (), thydataty = ty}

  (* The theory data types whose encoding holbuild knows
     (HolbuildRuntime.normalized_theory_data) and the current theory holds
     no pending load of.  A type registered with LoadableThyData.new and its
     own codec, other than the three named here, isn't checked. *)
  fun thydata_types () =
    List.filter (fn ty => (ignore (segment_data ty); true) handle Feedback.HOL_ERR _ => false)
      (List.mapPartial
         (fn (h, _) => if String.isPrefix "ThmSetData.onload." h
                       then SOME (String.extract (h, size "ThmSetData.onload.", NONE)) else NONE)
         (Listener.listeners Theory.delta_hook) @
       ["GrammarAncestry", "OpenTheoryMap", "TexTokenMap"])

  fun same_data (NONE, NONE) = true
    | same_data (SOME a, SOME b) = PolyML.pointerEq (a, b)
    | same_data _ = false

  (* The current theory's data of each of TYPES, to compare with later. *)
  fun thydata_of types = map (fn ty => (ty, segment_data ty)) types

  (* A type whose data has changed since INITIAL was taken, if any. *)
  fun changed_thydata initial =
    Option.map #1 (List.find (fn (ty, d) => not (same_data (d, segment_data ty))) initial)

  (* As the LSP replays a deferred proof: in the context its goal was
     stated in, pinned for every read the tactic makes.  The theory's data
     is checked as it stands in the pin, where a HOL whose pins take
     writes keeps (and so loses) what the proof writes; prove_all checks
     the live context too. *)
  (* TH, proved for GOAL with the theory data INITIAL before the proof.

     A theorem with fewer hypotheses than its goal's assumptions is
     accepted: the stub, an oracle theorem of GOAL, has all of them, and a
     proof that doesn't use an assumption leaves it out.  That is exact for
     a `Resume` block only because the theorem markerLib.resume proves
     goes nowhere a missing hypothesis shows: the check that its
     suspendlabel hypotheses aren't owned by a still-suspended theorem,
     build_suspendlabel_thms (which discharges the goal's assumptions, so
     stub and real theorem record the same resumption), and the value of
     the declaration, bound to `smlname` or to `_`.  A `Resume` that names
     `smlname` is therefore never deferred (deferrable_proof in
     build_exec.sml).  Don't tighten this to equal hypotheses: most
     proofs leave an assumption unused, and each would fail its attempt
     and build twice. *)
  fun checked goal initial th =
    (* A proof that suspends a subgoal (markerLib.suspend), or cites a
       still-suspended theorem, proves the goal under a hypothesis the
       stub's theorem lacks. *)
    case List.find (fn h => not (List.exists (fn a => Term.aconv a h) (#1 goal))) (Thm.hyp th) of
        SOME h => raise Fail ("the proof left a hypothesis its goal lacks: " ^ Parse.term_to_string h)
      | NONE =>
    case changed_thydata initial of
        NONE => th
      | SOME ty => raise Fail ("the proof wrote theory data of type " ^ ty)

  (* What markerLib's build_suspendlabel_thms gives for the goals NCTS of
     LABEL, proved by TH: |- suspendlabel <label> G for each.  (markerLib
     keeps it and the functions it uses to itself.) *)
  local
    open HolKernel boolLib
    val suspendimp = prim_mk_const {Thy = "marker", Name = "suspendimp"}
    val resconj = prim_mk_const {Thy = "marker", Name = "resconj"}
    fun dest_binop c t =
      let val (f, r) = dest_comb t
          val (g, l) = dest_comb f
      in if same_const g c then (l, r) else raise Fail "dest_binop" end
    val is_suspimp = can (dest_binop suspendimp)
    fun strip_suspimp t =
      case Lib.total (dest_binop suspendimp) t of
          SOME (a, rest) => let val (asms, g) = strip_suspimp rest in (a :: asms, g) end
        | NONE => ([], t)
    fun strip_foralls 0 t = ([], t)
      | strip_foralls n t =
          let val (v, body) = dest_forall t
              val (vs, rest) = strip_foralls (n - 1) body
          in (v :: vs, rest) end
    val to_suspimp = SYM markerTheory.suspendimp_def
    fun sDISCH t th = CONV_RULE (RATOR_CONV (RATOR_CONV (K to_suspimp))) (DISCH t th)
    val from_resconj = RATOR_CONV (RATOR_CONV (REWR_CONV markerTheory.resconj_def))
    fun resconjs 1 th = [th]
      | resconjs n th =
          if Lib.can (dest_binop resconj) (concl th) then
            let val (th1, th2) = CONJ_PAIR (CONV_RULE from_resconj th)
            in th1 :: resconjs (n - 1) th2 end
          else raise Fail "not a resumption conjunction"
    fun label_thm label ((nc, s_t), th) =
      let
        val (closure, body) = strip_foralls nc s_t
        val result = if is_suspimp (concl th) then th else itlist sDISCH (#1 (strip_suspimp body)) th
      in
        markerLib.add_suspension_label (Int.toString nc ^ " " ^ label) (GENL closure result)
      end
  in
    fun suspendlabel_thms label (ncts, th) =
      map (label_thm label) (ListPair.zip (ncts, resconjs (length ncts) th))
  end

  fun is_suspended t = Option.isSome (boolLib.dest_suspended t)
  fun term_in t ts = List.exists (fn u => Term.aconv t u) ts

  (* The goals each deferred group suspended, by group: those its
     theorem's proof suspended, which markerLib registers, so that a build
     in place rejects them in any other theorem or block while the group
     is open, with the groups open when the script stated it; and, per
     block, those the block suspended again, with the groups open when the
     script reached it.  In the outline a group suspends only its dummies,
     so markerLib couldn't see that; prove_all fails when a goal a group
     registered recurs, under the same label, in another group's theorem
     or block stated while the first was open. *)
  val slabs_mutex = Mutex.mutex ()
  val group_slabs =
    ref ([] : {name : string, open_with : string list, initial : Term.term list,
               nested : (string list * Term.term list) list} list)
  fun record_slabs entry =
    (Mutex.lock slabs_mutex; group_slabs := entry :: !group_slabs; Mutex.unlock slabs_mutex)
  fun check_shared_slabs () =
    let
      fun member x xs = List.exists (fn y => y = x) xs
      fun meet xs ys = List.exists (fn h => term_in h ys) xs
      (* Whether A's registered goals recur in B where A was open. *)
      fun cited (a : {name : string, open_with : string list, initial : Term.term list,
                      nested : (string list * Term.term list) list}) b =
        (member (#name a) (#open_with b) andalso meet (#initial a) (#initial b)) orelse
        List.exists (fn (open_with, slabs) => member (#name a) open_with andalso meet (#initial a) slabs) (#nested b)
      fun clash [] = ()
        | clash (a :: rest) =
            (case List.find (fn b => #name b <> #name a andalso (cited a b orelse cited b a)) rest of
                 SOME b =>
                   raise Fail ("the deferred groups " ^ #name b ^ " and " ^ #name a ^
                               " suspend the same goal under the same label")
               | NONE => clash rest)
    in
      clash (!group_slabs)
    end

  (* The theorem of group item K, NAME, its blocks proved by PROVE_BLOCK
     (in a block's context, with its setup) and assembled as markerLib's
     Finalise does.  Fails as a build in place fails: a theorem or block
     whose proof cites a theorem still suspended where it is stated, a
     resumption that reintroduces what it discharges, a goal left
     suspended; or else where the outline went another way than a build
     in place would: a block the script didn't reach.  A block whose label
     has no goal to resume doesn't run, as in place. *)
  fun prove_group prove_block ({k, name, ctxt, goal, make, setup, group, ...} : item) =
    let
      val {labels, resumes, reached, open_with} =
        case group of SOME g => g | NONE => raise Fail "not a deferred group"
      val blocks = rev (!reached)
      val _ =
        if length blocks = resumes then ()
        else raise Fail (Int.toString resumes ^ " Resume blocks of " ^ name ^ ", " ^
                         Int.toString (length blocks) ^ " reached by the script")
      (* Every statement the outline made under proof k's markers is true. *)
      val _ = List.app (fn label => ignore (dummy_label_thm k label)) labels
      (* As a build in place checks a theorem when it is stashed and a block
         when it is resumed: a goal the proof suspended (or one of the
         theorem's own, for a block) is fine, one that an open suspension
         holds in the block's context is cited from it. *)
      fun check what ctxt asl own th =
        (* Assembly may drop a block's theorem (when a later block resumes
           the same label), and with it the marker the cycle check reads. *)
        (if List.exists (fn s => s = oracle_prefix ^ Int.toString k) (#1 (Tag.dest_tag (Thm.tag th))) then
           raise Fail ("the proof of " ^ what ^ " uses the stub of its own deferred group")
         else ();
         List.app
          (fn h =>
              if term_in h asl then ()
              else if not (is_suspended h) then
                raise Fail ("the proof of " ^ what ^ " left a hypothesis its goal lacks: " ^ Parse.term_to_string h)
              else if term_in h own then
                raise Fail ("the proof of " ^ what ^ " reintroduces a goal its theorem suspended")
              else
                case Context.with_context ctxt (fn () => !boolLib.slab_owner_lookup h) () of
                    SOME (thy, n) => raise Fail ("the proof of " ^ what ^ " cites still-suspended theorem " ^ thy ^ "." ^ n)
                  | NONE => ())
          (Thm.hyp th))
      val th0 = prove_block (ctxt, goal, make, setup)
      val _ = check name ctxt (#1 goal) [] th0
      (* With no suspension a build in place saves the theorem at its
         statement, with its attributes, where the outline's stub was
         stashed until its Finalise. *)
      val _ = if List.exists is_suspended (Thm.hyp th0) then ()
              else raise Fail ("the proof of " ^ name ^ " suspends no goal")
      (* Each block's open groups, goal and theorem, the latest first. *)
      val block_ths = ref []
      (* Resumption theorems, the latest first, as markerLib keeps them.
         A block whose label has no suspended goal doesn't run, as
         markerLib's resume skips it in place: th0 and RESUMED hold every
         theorem markerLib looks the label up in, since it files each
         resumption under every label of its hypotheses.  A goal left
         without a resumption still fails the assembly. *)
      fun resume ({label, ctxt, make, setup, open_with = opened} : resume, resumed) =
        case Lib.total (markerLib.extract_suspended_goal (th0 :: resumed)) label of
            NONE => resumed
          | SOME ncts =>
              let
                val what = name ^ "[" ^ label ^ "]"
                val g = markerLib.resumption_to_goal ncts
                val th = prove_block (ctxt, g, make, setup)
              in
                check what ctxt (#1 g) (Thm.hyp th0) th;
                block_ths := (opened, g, th) :: !block_ths;
                rev (suspendlabel_thms label (ncts, th)) @ resumed
              end
      val resumed = List.foldl resume [] blocks
      val block_ths = !block_ths
      fun suspended th = List.filter is_suspended (Thm.hyp th)
      fun resumption h =
        case List.find (fn r => Term.aconv (Thm.concl r) h) resumed of
            SOME r => r
          | NONE => raise Fail ("no resumption proves " ^ Parse.term_to_string h ^ " of " ^ name)
      fun assemble th current =
        let
          val th' = List.foldl (fn (h, acc) => Drule.PROVE_HYP (resumption h) acc) th current
          val remaining = suspended th'
        in
          if null remaining then th'
          else if List.exists (fn h => term_in h remaining) current then
            raise Fail ("the resumptions of " ^ name ^ " reintroduce the goals they discharge")
          else assemble th' remaining
        end
      val th = assemble th0 (suspended th0)
      val _ = record_slabs {name = name, open_with = open_with, initial = suspended th0,
                            nested = map (fn (opened, g, th) => (opened, List.filter (fn h => not (term_in h (#1 g))) (suspended th))) block_ths}
    in
      if not (Term.aconv (Thm.concl th) (#2 goal)) then
        raise Fail ("the assembled theorem of " ^ name ^ " has another conclusion than its goal")
      else
        case List.find (fn h => not (term_in h (#1 goal))) (Thm.hyp th) of
            SOME h => raise Fail ("the assembled theorem of " ^ name ^ " has a hypothesis its goal lacks: " ^
                                  Parse.term_to_string h)
          | NONE => th
    end

  (* As the LSP replays a deferred proof, in its goal's context (see above);
     a group's theorem and blocks each in its own. *)
  fun prove_one types (item as {ctxt, goal, make, group, ...} : item) =
    let
      fun pinned ctxt f = Context.with_context ctxt f ()
      fun prove_block (ctxt, goal, make, _) =
        pinned ctxt (fn () =>
          let
            val initial = thydata_of types
            val th = Tactical.TAC_PROOF_in ctxt (goal, make ())
          in
            case changed_thydata initial of
                NONE => th
              | SOME ty => raise Fail ("the proof wrote theory data of type " ^ ty)
          end)
    in
      case group of
          NONE => pinned ctxt (fn () => let val initial = thydata_of types
                                        in checked goal initial (Tactical.TAC_PROOF_in ctxt (goal, make ())) end)
        | SOME _ => prove_group prove_block item
    end

  fun result k th =
    let val tag = Thm.tag th
    in (k, (Dep.transfer_thydepl (Tag.dep_of tag), #1 (Tag.dest_tag tag))) end

  (* With proof steps on, the proof runtime runs each step on a thread of
     its own, which a pin would not reach, and keeps its state in globals.
     So the proofs run one at a time on this thread, unpinned, each with
     the live context set back to its goal's, as when the script ran it in
     place; a step can write the context as it would there.  The first
     failure ends the phase: a step worker killed on a timeout can hold the
     context's lock, so nothing touches the context after it. *)
  fun prove_in_place types items =
    let
      val after_export = Context.snapshot ()
      fun prove_block (ctxt, goal, make, setup) =
        let
          val _ = Context.restore ctxt
          val initial = thydata_of types
          val th = (Option.app (fn f => f ()) setup; Tactical.prove_goal_in ctxt (goal, make ()))
        in
          case changed_thydata initial of
              NONE => th
            | SOME ty => raise Fail ("the proof wrote theory data of type " ^ ty)
        end
      fun prove (item as {k, name, ctxt, goal, make, setup, group} : item) =
        let
          val th = (case group of
                        NONE =>
                          let
                            val _ = Context.restore ctxt
                            val initial = thydata_of types
                          in
                            Option.app (fn f => f ()) setup;
                            checked goal initial (Tactical.prove_goal_in ctxt (goal, make ()))
                          end
                      | SOME _ => prove_group prove_block item)
                   handle e => raise Fail ("deferred proof of " ^ name ^ " failed: " ^
                                           (Feedback.exn_to_string e handle Interrupt => "interrupted"))
        in
          result k th
        end
      val results = map prove items
    in
      Context.restore after_export;
      results
    end

  fun describe_delta delta =
    case delta of
        TheoryDelta.NewTheory {newseg, ...} => "new theory " ^ newseg
      | TheoryDelta.ExportTheory thy => "exported " ^ thy
      | TheoryDelta.TheoryLoaded thy => "loaded " ^ thy
      | TheoryDelta.NewConstant {Name, ...} => "new constant " ^ Name
      | TheoryDelta.NewTypeOp {Name, ...} => "new type " ^ Name
      | TheoryDelta.DelConstant {Name, ...} => "deleted constant " ^ Name
      | TheoryDelta.DelTypeOp {Name, ...} => "deleted type " ^ Name
      | TheoryDelta.NewBinding (name, _) => "saved " ^ name
      | TheoryDelta.UpdBinding (name, _) => "updated " ^ name
      | TheoryDelta.DelBinding name => "deleted " ^ name

  (* A deferred group whose theorem the script didn't finalise would
     leave its stub in the theory's suspensions. *)
  fun check_finalised () =
    List.app (fn {name, group, ...} : item =>
                 if Option.isSome group andalso
                    Option.isSome (markerLib.lookup_suspension (Theory.current_theory () ^ "." ^ name))
                 then raise Fail ("the deferred group " ^ name ^ " was not finalised")
                 else ())
             (!queue)

  fun prove_all threads =
    let
      val _ = check_finalised ()
      val _ = group_slabs := []
      val types = thydata_types ()
      val items = ref (rev (!queue))
      val _ = queue := []
      val in_place = List.exists (fn {setup, ...} : item => Option.isSome setup) (!items)
      val mutex = Mutex.mutex ()
      val cv = ConditionVar.conditionVar ()
      val results = ref []
      val failed = ref []
      fun locked f = (Mutex.lock mutex; f () before Mutex.unlock mutex)
                     handle e => (Mutex.unlock mutex; raise e)
      fun take () =
        locked (fn () => case !items of
                             item :: rest => (items := rest; SOME item)
                           | [] => NONE)
      fun prove (item as {k, ...} : item) =
        let val r = result k (prove_one types item)
        in locked (fn () => results := r :: !results) end
      fun failure name msg = Fail ("deferred proof of " ^ name ^ " failed: " ^ msg)
      fun run item =
        prove item
        handle e =>
          let val msg = Feedback.exn_to_string e handle Interrupt => "interrupted"
          in locked (fn () => failed := (item, msg) :: !failed) end
      val count = Int.max (0, Int.min (threads, length (!items)))
      (* With several threads a proof can fail because another one raced it
         on some library's own cache (blastLib's compset, say), so each
         failed proof runs again alone before it fails the build. *)
      fun retry (item as {name, ...} : item, msg) =
        if count <= 1 then raise failure name msg
        else
          (TextIO.output (TextIO.stdErr, "deferred proof of " ^ name ^ " failed, retrying alone: " ^ msg ^ "\n");
           prove item
           handle e => raise failure name (Feedback.exn_to_string e ^ " (first run: " ^ msg ^ ")"))
      val running = ref count
      fun worker () =
        case take () of
            SOME item => (run item; worker ())
          | NONE => locked (fn () => (running := !running - 1; ConditionVar.broadcast cv))
      fun wait () = if !running = 0 then () else (ConditionVar.wait (cv, mutex); wait ())
      (* A change to the theory now would come after its export, unlike in
         a build that runs each proof in place. *)
      val change = ref NONE
      fun record delta =
        locked (fn () => if Option.isSome (!change) then () else change := SOME (describe_delta delta))
      val listener = "HolbuildDeferred.prove_all"
      val live = thydata_of types
    in
      Theory.register_hook (listener, record);
      if in_place then results := prove_in_place types (!items)
      else
        (List.app (fn _ => ignore (Thread.fork (worker, []))) (List.tabulate (count, fn i => i));
         Mutex.lock mutex; wait (); Mutex.unlock mutex;
         List.app retry (rev (!failed)));
      ignore (Listener.remove_listener Theory.delta_hook listener);
      (* In place, each proof's writes were checked before the next restore. *)
      case (!change, if in_place then NONE else changed_thydata live) of
          (SOME what, _) => raise Fail ("a deferred proof changed the theory: " ^ what)
        | (NONE, SOME ty) => raise Fail ("a deferred proof wrote theory data of type " ^ ty)
        | (NONE, NONE) => (check_shared_slabs (); proved := !results)
    end

  fun merge_strings [] ys = ys
    | merge_strings xs [] = xs
    | merge_strings (x :: xs) (y :: ys) =
        case String.compare (x, y) of
            LESS => x :: merge_strings xs (y :: ys)
          | GREATER => y :: merge_strings (x :: xs) ys
          | EQUAL => x :: merge_strings xs ys

  fun merge_deps a b = Dep.thydepl_of (Dep.merge_dep (Dep.DEP_UNSAVED a) (Dep.DEP_UNSAVED b))

  (* DEPS and ORACLES of a theorem of theory THY with each marker replaced
     by what LOOKUP gives for its proof. *)
  fun resolve thy lookup (deps, oracles) =
    let
      fun split ((t, ns), (markers, kept)) =
        if t <> thy then (markers, kept @ [(t, ns)])
        else
          let val (ms, rest) = List.partition (fn n => n >= marker_base) ns
          in (markers @ map (fn n => n - marker_base) ms,
              if null rest then kept else kept @ [(t, rest)])
          end
      val (dep_markers, deps') = List.foldl split ([], []) deps
      val (oracle_markers, oracles') = List.partition (String.isPrefix oracle_prefix) oracles
      fun marker s = valOf (Int.fromString (String.extract (s, size oracle_prefix, NONE)))
    in
      (List.foldl (fn (k, acc) => merge_deps acc (#1 (lookup k))) deps' dep_markers,
       List.foldl (fn (k, acc) => merge_strings acc (#2 (lookup k))) oracles' (map marker oracle_markers))
    end

  (* The theory data DATA of theory THY, every theorem's dependencies and
     oracles resolved through LOOKUP, as Theory.export_theory would write
     it: the string table is rebuilt in the order HOL interns its strings,
     which the theorems' dependencies take part in, and every reference to
     it renumbered.  HOL interns the strings of the types and terms and the
     theorems' names, then each theorem's theory, dependencies' theories
     and source location, then the strings of the theory data; the last
     theorem name ends the first part.  Raises Fail on theory data of an
     encoding whose string references holbuild can't find. *)
  fun rewrite_data_observing observe lookup data =
    let
      open HOLsexp
      fun fail what = raise Fail ("unexpected " ^ what ^ " in the exported theory data")
      fun items s = case strip_list s of (l, NONE) => l | _ => fail "list"
      fun int (Integer n) = n
        | int _ = fail "index"
      val (header, core, incorporate, loadable) =
        case items data of
            [Symbol "theory", h, c, i, l] => (h, c, i, l)
          | _ => fail "theory"
      val thy = case header of Cons (String name, _) => name | _ => fail "theory header"
      val (tables, exports) =
        case core of Cons (Symbol "core-data", Cons (t, e)) => (t, e) | _ => fail "core-data"
      val (strings, ids, types_terms) =
        case items tables of
            Symbol "tables" :: Cons (Symbol "string-table", s) :: Cons (Symbol "id-table", i) :: rest =>
              (items s, items i, rest)
          | _ => fail "tables"
      val (tys, tms, thms) =
        case items exports of
            [Symbol "exports", tys, tms, thms] => (tys, tms, items thms)
          | _ => fail "exports"
      val old = Vector.fromList (map (fn String s => s | _ => fail "string") strings)
      fun name_of i = Vector.sub (old, int i)
      (* (name ((theory save-index) (dependency-theory indices...)...) oracles...)
         (class private exact line location...) terms) *)
      fun decode (Cons (name, Cons (record, Cons (info, Cons (terms, Symbol "nil"))))) =
            (case items record of
                 dl :: oracles =>
                   (case items dl of
                        self :: deps =>
                          let
                            fun group g = case items g of t :: ns => (name_of t, map int ns) | [] => fail "dependency"
                          in
                            {name = name, self = group self, deps = map group deps,
                             oracles = map (fn String s => s | _ => fail "oracle") oracles,
                             info = items info, terms = terms}
                          end
                      | [] => fail "theorem dependencies")
               | [] => fail "theorem")
        | decode _ = fail "theorem"
      val theorems = map decode thms
      fun location info = case info of _ :: _ :: _ :: _ :: loc => map name_of loc | _ => []
      fun thm_strings {self, deps, info, ...} = #1 self :: map #1 deps @ location info
      fun intern (s, (n, d, acc)) =
        if isSome (Binarymap.peek (d, s)) then (n, d, acc)
        else (n + 1, Binarymap.insert (d, s, n), s :: acc)
      fun interned start l = List.foldl intern start l
      val first = List.foldl (fn ({name, ...}, m) => Int.max (m, int name + 1)) 0 theorems
      val prefix = List.tabulate (first, fn i => Vector.sub (old, i))
      val start = interned (0, Binarymap.mkDict String.compare, []) prefix
      val (_, _, added) = interned (0, #2 start, []) (List.concat (map thm_strings theorems))
      val _ = if List.tabulate (length added, fn i => Vector.sub (old, first + i)) = rev added
                 handle Subscript => false
              then () else fail "string table order"
      val theorems' =
        map (fn {name, self, deps, oracles, info, terms} =>
                let val (deps', oracles') = resolve thy lookup (deps, oracles)
                in observe oracles'; {name = name, self = self, deps = deps', oracles = oracles', info = info, terms = terms} end)
            theorems
      val (_, index, rev_table) =
        interned start (List.concat (map thm_strings theorems') @
                        List.tabulate (Vector.length old - first, fn i => Vector.sub (old, first + i)))
      fun str s = Integer (Binarymap.find (index, s))
      val renumber = str o name_of
      fun group (t, ns) = List (str t :: map Integer ns)
      fun encode {name, self, deps, oracles, info, terms} =
        List [renumber name,
              List (List (group self :: map group deps) :: map String oracles),
              List (List.take (info, Int.min (4, length info)) @ map renumber (List.drop (info, Int.min (4, length info)))),
              terms]
      fun id (Cons (a, b)) = Cons (renumber a, renumber b)
        | id _ = fail "id"
      (* ThyDataSexp's encoding: shared strings and names by index, and a
         theorem as (tag-th (theory save-index dependencies oracles) ...),
         its theories by name. *)
      fun tagged_group g = case items g of String t :: ns => (t, map int ns) | _ => fail "dependency"
      fun thydata (Cons (Symbol "tag-str", i as Integer _)) = Cons (Symbol "tag-str", renumber i)
        | thydata (Cons (Symbol "tag-knm", Cons (i as Integer _, j as Integer _))) =
            Cons (Symbol "tag-knm", Cons (renumber i, renumber j))
        | thydata (Cons (Symbol "tag-th", Cons (record, rest))) =
            (case items record of
                 [thy_name, save, deps, oracles] =>
                   let
                     val (deps', oracles') =
                       resolve thy lookup (map tagged_group (items deps),
                                           map (fn String s => s | _ => fail "oracle") (items oracles))
                     fun named_group (t, ns) = List (String t :: map Integer ns)
                     val _ = observe oracles'
                   in
                     Cons (Symbol "tag-th",
                           Cons (List [thy_name, save, List (map named_group deps'), List (map String oracles')], rest))
                   end
               | _ => fail "tag-th")
        | thydata (Cons (a, b)) = Cons (thydata a, thydata b)
        | thydata atom = atom
      (* GrammarAncestry's: theory names as bare string indices. *)
      fun indexed (i as Integer _) = renumber i
        | indexed (Cons (a, b)) = Cons (indexed a, indexed b)
        | indexed atom = atom
      fun entry (Cons (key as String k, value)) =
            Cons (key,
                  if HolbuildRuntime.sexp_coded_thydata k then thydata value
                  else if k = "GrammarAncestry" then indexed value
                  else if k = "OpenTheoryMap" orelse k = "TexTokenMap" then value
                  else raise Fail ("theory data " ^ k ^ " has an encoding holbuild doesn't know"))
        | entry _ = fail "loadable data"
      val loadable' =
        case loadable of
            Cons (tag as Symbol "loadable-thydata", l) => Cons (tag, List (map entry (items l)))
          | _ => fail "loadable data"
      val tables' =
        List (Symbol "tables" ::
              Cons (Symbol "string-table", List (map String (rev rev_table))) ::
              Cons (Symbol "id-table", List (map id ids)) :: types_terms)
    in
      List [Symbol "theory", header,
            Cons (Symbol "core-data",
                  Cons (tables', List [Symbol "exports", tys, tms, List (map encode theorems')])),
            incorporate, loadable']
    end

  fun rewrite_data lookup data = rewrite_data_observing (fn _ => ()) lookup data

  fun read_text path =
    let val input = TextIO.openIn path
    in TextIO.inputAll input before TextIO.closeIn input end

  (* As Theory.export_theory prints theory data. *)
  fun data_text data =
    let val parts = ref []
    in
      PP.prettyPrint ((fn s => parts := s :: !parts), 75) (HOLsexp.printer data);
      String.concat (rev (!parts))
    end

  (* Replaces the exported theory data of SIG_PATH by DATA, as exported
     and then normalized. *)
  fun write_data sig_path data =
    let
      val stem = OS.Path.base sig_path
      val text = data_text data
      val sml = read_text (stem ^ ".sml")
      val (before_hash, rest) = Substring.position "hash = \"" (Substring.full sml)
      val start = Substring.size before_hash + size "hash = \""
    in
      if Substring.isEmpty rest then raise Fail "exported theory source has no data hash" else ();
      HolbuildRuntime.write_text (stem ^ ".dat") text;
      HolbuildRuntime.write_text (stem ^ ".sml")
        (String.substring (sml, 0, start) ^ HolbuildRuntime.sha1_string text ^
         String.extract (sml, start + 40, NONE));
      HolbuildRuntime.normalize_theory_export sig_path
    end

  (* What the outline's children see of an unproved theorem: no
     dependencies, and the oracle every theorem loaded from disk carries. *)
  fun outline_lookup _ = ([], ["DISK_THM"])

  (* An oracle other than DISK_THM that a theorem in scope carries: one of
     the theory's own, as exported with each deferred proof as the outline
     sees it, or one of an ancestor's.  A deferred proof that uses such a
     theorem carries its oracle, which the outline can't predict; an
     ancestor's [local] theorem reaches this theory only through exported
     ones, which carry its oracles. *)
  fun oracle_in_scope data =
    let
      val found = ref NONE
      fun note thy oracles =
        case (!found, List.find (fn s => s <> "DISK_THM" andalso
                                         not (String.isPrefix "holbuild_deferred_" s)) oracles) of
            (NONE, SOME oracle) => found := SOME (oracle, thy)
          | _ => ()
      val outline = rewrite_data_observing (note (Theory.current_theory ())) outline_lookup data
      fun oracles th = #1 (Tag.dest_tag (Thm.tag th))
      fun ancestor thy = List.app (fn (_, th) => note thy (oracles th)) (DB.thms thy)
      (* Local theorems (Triviality) are not exported but a deferred proof
         may use them. *)
      fun locals () =
        List.app (fn (_, (th, _, _)) => note (Theory.current_theory ()) (oracles th))
                 (DB.matchp (fn _ => true) ["-"])
    in
      if isSome (!found) then () else locals ();
      if isSome (!found) then () else List.app ancestor (Theory.ancestry "-");
      (outline, !found)
    end

  (* Writes the theory data with every deferred proof as the outline sees
     it to the export of SIG_PATH and copies the export to OUTLINE_DIR,
     ending with the file `ready`.  With an oracle in scope it publishes
     nothing but the file `withheld`, saying which: children then wait for
     the theory's final outputs. *)
  fun publish_outline {sig_path, outline_dir} =
    let
      val stem = OS.Path.base sig_path
      fun copy ext = HolbuildRuntime.write_text (OS.Path.concat (outline_dir, OS.Path.file stem ^ ext))
                                                (read_text (stem ^ ext))
      fun publish () =
        (OS.FileSys.mkDir outline_dir handle OS.SysErr _ => ();
         List.app copy [".dat", ".sml", ".sig"];
         HolbuildRuntime.write_text (OS.Path.concat (outline_dir, "ready")) "")
    in
      if null (!queue) then (HolbuildRuntime.normalize_theory_export sig_path; publish ())
      else
        let
          (* Not HOLsexp.fromString: its time grows faster than the text
             (98 s for a 1.9 MB .dat that fromStream parses in 0.1 s). *)
          val data = let val input = TextIO.openIn (stem ^ ".dat")
                     in HOLsexp.fromStream input before TextIO.closeIn input end
          val _ = marker_data := SOME data
          val (outline, oracle) = oracle_in_scope data
        in
          case oracle of
              NONE => (write_data sig_path outline; publish ())
            | SOME (name, thy) =>
                (OS.FileSys.mkDir outline_dir handle OS.SysErr _ => ();
                 HolbuildRuntime.write_text (OS.Path.concat (outline_dir, "withheld"))
                   ("oracle " ^ name ^ " in theory " ^ thy ^ "\n"))
        end
    end

  (* Writes the theory data with each deferred proof's dependencies and
     oracles, once prove_all has proved them. *)
  fun finalize sig_path =
    case !marker_data of
        NONE => ()
      | SOME data =>
          let
            val thy = case HOLsexp.strip_list data of
                          (_ :: HOLsexp.Cons (HOLsexp.String name, _) :: _, _) => name
                        | _ => raise Fail "unexpected theory data header"
            val raw = List.foldl (fn ((k, r), d) => Binarymap.insert (d, k, r))
                                 (Binarymap.mkDict Int.compare) (!proved)
            val memo = ref (Binarymap.mkDict Int.compare)
            (* Proofs that used each other's stubs (through a registry
               outside the context, say) have no order a build in place
               could have run them in. *)
            val resolving = ref ([] : int list)
            fun lookup k =
              case Binarymap.peek (!memo, k) of
                  SOME resolved => resolved
                | NONE =>
                    if List.exists (fn j => j = k) (!resolving) then
                      raise Fail ("deferred proofs depend on each other: goals " ^
                                  String.concatWith ", " (map Int.toString (!resolving)))
                    else
                    case Binarymap.peek (raw, k) of
                        NONE => raise Fail ("no proof recorded for deferred goal " ^ Int.toString k)
                      | SOME r =>
                          let
                            val _ = resolving := k :: !resolving
                            val resolved = resolve thy lookup r
                          in
                            resolving := tl (!resolving);
                            memo := Binarymap.insert (!memo, k, resolved);
                            resolved
                          end
          in
            (* Every proof, also one whose theorem the data doesn't hold (a
               [local] one only another proof used). *)
            List.app (fn (k, _) => ignore (lookup k)) (!proved);
            write_data sig_path (rewrite_data lookup data)
          end
end
