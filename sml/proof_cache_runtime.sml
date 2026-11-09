(* The per-theorem proof cache of `holbuild build --cached-proofs`.

   Before a theorem's tactic runs, `prove` looks for a record of an earlier
   proof of the same goal, by the same tactic text, under this theory and
   name.  A record names the saved theorems the proof depended on, with
   their statements and oracles.  When each of them is still saved under its
   name with the same statement and oracles, the theorem is rebuilt from the
   record without running the tactic, with the dependency tags a replay
   would give it, so the theory's outputs are the same bytes.  Otherwise the
   tactic runs and its result is recorded.

   A theory's own constants and type operators reach a record's
   dependencies only through their defining theorems.  The listener below
   certifies each one the definition principles announce right after storing
   a defining theorem that mentions it; one made any other way (a raw kernel
   primitive, or under a definition hook installed after this runtime)
   leaves the theory uncertified, and then no proof in it is
   reused or recorded. *)
structure HolbuildProofCacheRuntime =
struct

type config = {toolchain_key : string, records_in : string, records_out : string,
               tactic_timeout : real option}

type dep = {theory : string, name : string, identity : string}
type record = {name : string, key : string, timeout : real option,
               oracles : string list, deps : dep list}

val config_ref = ref (NONE : config option)
(* Records by lookup key, newest first. *)
val records_ref = ref (Redblackmap.mkDict String.compare : (string, record list) Redblackmap.dict)

val certified_consts_ref =
  ref (Redblackmap.mkDict KernelSig.name_compare : (KernelSig.kernelname, Term.term) Redblackmap.dict)
val certified_types_ref =
  ref (Redblackmap.mkDict KernelSig.name_compare : (KernelSig.kernelname, Type.hol_type) Redblackmap.dict)
(* The defining theorem stored by the definition principle whose
   announcements may follow. *)
val pending_definition_ref = ref (NONE : Thm.thm option)
val theory_events_ref = ref 0

fun mentions_const ({Thy, Name} : KernelSig.kernelname) th =
  Lib.can (HolKernel.find_term
             (fn t => Term.is_const t andalso
                      let val {Thy = thy, Name = name, ...} = Term.dest_thy_const t
                      in thy = Thy andalso name = Name end))
          (Thm.concl th)

fun mentions_type ({Thy, Name} : KernelSig.kernelname) th =
  let
    fun in_type ty =
      not (Type.is_vartype ty) andalso
      let val {Thy = thy, Tyop, Args} = Type.dest_thy_type ty
      in (thy = Thy andalso Tyop = Name) orelse List.exists in_type Args end
  in
    Lib.can (HolKernel.find_term (in_type o Term.type_of)) (Thm.concl th)
  end

(* An announcement right after a defining theorem is certified when that
   theorem is current and mentions it; one with no definition before it
   (`new_constant`, `new_type`) introduces a name with no defining theorem. *)
fun certifies mentions knm =
  case !pending_definition_ref of
      NONE => true
    | SOME th => Theory.uptodate_thm th andalso mentions knm th

(* `new_definition` passes the kernel's defining theorem to its hook, which
   stores what it makes of it and could keep the theorem itself too, where a
   proof can use it with no saved dependency.  So the hook is wrapped here,
   and every record's key covers the conclusions of the theory's defining
   theorems so far: a changed definition misses every proof below it.  A
   hook installed after this one isn't wrapped, so constants defined under
   it aren't certified. *)
val kernel_definitions_ref = ref ([] : string list)
val _ =
  let val (dest, post) = !Theory.Definition.new_definition_hook
  in
    Theory.Definition.new_definition_hook :=
      (dest, fn (V, th) =>
                (kernel_definitions_ref := HolbuildFingerprint.term (Thm.concl th) :: !kernel_definitions_ref;
                 post (V, th)))
  end
val wrapped_definition_hook = !Theory.Definition.new_definition_hook
fun definition_hook_unchanged () =
  PolyML.pointerEq (!Theory.Definition.new_definition_hook, wrapped_definition_hook)

fun generic_type ({Thy, Name} : KernelSig.kernelname) =
  case Type.op_arity {Thy = Thy, Tyop = Name} of
      SOME arity =>
        SOME (Type.mk_thy_type {Thy = Thy, Tyop = Name,
                                Args = List.tabulate (arity, fn i => Type.mk_vartype ("'a" ^ Int.toString i))})
    | NONE => NONE

fun note_theory_event event =
  (theory_events_ref := !theory_events_ref + 1;
   case event of
       TheoryDelta.NewBinding (_, (th, {class = DB.Def, ...})) => pending_definition_ref := SOME th
     | TheoryDelta.NewConstant knm =>
         if definition_hook_unchanged () andalso certifies mentions_const knm then
           certified_consts_ref := Redblackmap.insert (!certified_consts_ref, knm, Term.prim_mk_const knm)
         else ()
     | TheoryDelta.NewTypeOp knm =>
         (case (certifies mentions_type knm, generic_type knm) of
              (true, SOME ty) => certified_types_ref := Redblackmap.insert (!certified_types_ref, knm, ty)
            | _ => ())
     | _ => pending_definition_ref := NONE)

val _ = Theory.register_hook ("holbuild.proof_cache", note_theory_event)

(* Every constant and type operator of the current theory is the version
   certified for its name.  A certified one replaced since, by any means, is
   no longer up to date. *)
fun signature_certified () =
  let
    val thy = Theory.current_theory ()
    fun const_ok c =
      let val {Thy, Name, ...} = Term.dest_thy_const c
      in
        case Redblackmap.peek (!certified_consts_ref, {Thy = Thy, Name = Name}) of
            SOME certified => Term.uptodate_term certified
          | NONE => false
      end
    fun type_ok (name, _) =
      case Redblackmap.peek (!certified_types_ref, {Thy = thy, Name = name}) of
          SOME certified => Type.uptodate_type certified
        | NONE => false
  in
    List.all const_ok (Term.thy_consts thy) andalso List.all type_ok (Type.thy_types thy)
  end

fun field text = Int.toString (size text) ^ ":" ^ text

fun lookup_key toolchain_key name tactic_text proof_attrs concl =
  HolbuildSha256.string_hex
    (String.concat
       (map field
          (["holbuild-proof-record-v1", toolchain_key, Theory.current_theory (), name,
            HolbuildFingerprint.term concl, tactic_text,
            Int.toString (length (!kernel_definitions_ref))] @ !kernel_definitions_ref @
           [Int.toString (length proof_attrs)] @
           List.concat
             (map (fn (key, values) => key :: Int.toString (length values) :: values) proof_attrs))))

fun oracles_of th = Listsort.sort String.compare (#1 (Tag.dest_tag (Thm.tag th)))

fun identity th =
  HolbuildSha256.string_hex (String.concatWith "\n" (HolbuildFingerprint.thm th :: oracles_of th))

fun timeout_text NONE = "none"
  | timeout_text (SOME seconds) = Real.toString seconds

fun parse_timeout "none" = SOME NONE
  | parse_timeout text = Option.map SOME (Real.fromString text)

(* As HolbuildTheoryCacheManifest.timeout_satisfies: a proof that ran under a
   step timeout at most the requested one, or any proof when none is. *)
fun timeout_satisfies (requested : real option) recorded =
  case (requested, recorded) of
      (NONE, _) => true
    | (SOME requested_seconds, SOME recorded_seconds) => recorded_seconds <= requested_seconds
    | (SOME _, NONE) => false

(* A record is one line of tab-separated fields, each escaped with
   String.toString: R1, the theorem's name, its lookup key, the step timeout
   it ran under, the number of oracles, the oracles, then a theory, name and
   identity per dependency. *)
fun record_line ({name, key, timeout, oracles, deps} : record) =
  String.concatWith "\t"
    (map String.toString
       (["R1", name, key, timeout_text timeout, Int.toString (length oracles)] @ oracles @
        List.concat (map (fn {theory, name, identity} => [theory, name, identity]) deps))) ^ "\n"

fun parse_deps [] = SOME []
  | parse_deps (theory :: name :: identity :: rest) =
      Option.map (fn deps => {theory = theory, name = name, identity = identity} :: deps) (parse_deps rest)
  | parse_deps _ = NONE

(* NONE for a line a build cut off while writing it. *)
fun parse_record line =
  case List.map String.fromString (String.fields (fn c => c = #"\t") line) of
      SOME "R1" :: SOME name :: SOME key :: SOME timeout :: SOME count :: rest =>
        if List.exists (not o Option.isSome) rest then NONE
        else
          let val rest = List.map Option.valOf rest
          in
            case (parse_timeout timeout, Int.fromString count) of
                (SOME timeout, SOME n) =>
                  if n < 0 orelse n > length rest then NONE
                  else
                    Option.map (fn deps => {name = name, key = key, timeout = timeout,
                                            oracles = List.take (rest, n), deps = deps})
                               (parse_deps (List.drop (rest, n)))
              | _ => NONE
          end
    | _ => NONE

fun read_records path =
  let
    val text =
      let val input = TextIO.openIn path
      in TextIO.inputAll input before TextIO.closeIn input end
      handle IO.Io _ => ""
    fun add (record as {key, ...} : record, records) =
      Redblackmap.insert (records, key,
                          record :: (case Redblackmap.peek (records, key) of SOME rs => rs | NONE => []))
  in
    List.foldl add (Redblackmap.mkDict String.compare)
      (List.mapPartial parse_record (String.tokens (fn c => c = #"\n") text))
  end

fun append_record path record =
  let val output = TextIO.openAppend path
  in TextIO.output (output, record_line record); TextIO.closeOut output end

fun saved_index th =
  case Tag.dep_of (Thm.tag th) of
      Dep.DEP_SAVED ((_, n), _) => SOME n
    | Dep.DEP_UNSAVED _ => NONE

(* The theorem a dependency names, when it is saved under that name, current,
   and free of axioms. *)
fun current_dependency theory name =
  case DB.lookup {Thy = theory, Name = name} of
      SOME (th, _) =>
        (case saved_index th of
             SOME n =>
               if Theory.uptodate_thm th andalso null (Tag.axioms_of (Thm.tag th)) then SOME (th, n)
               else NONE
           | NONE => NONE)
    | NONE => NONE

(* Theorem names by save index, per theory.  A theorem saved since, or a name
   rebound, is found by reading the theory again. *)
val names_by_index_ref = ref ([] : (string * (int, string) Redblackmap.dict) list)

fun read_names_by_index theory =
  let
    val names =
      List.foldl (fn (((_, name), (th, _)), names) =>
                     case saved_index th of
                         SOME n => Redblackmap.insert (names, n, name)
                       | NONE => names)
                 (Redblackmap.mkDict Int.compare) (DB.thy theory)
  in
    names_by_index_ref := (theory, names) :: List.filter (fn (t, _) => t <> theory) (!names_by_index_ref);
    names
  end

fun name_of_index theory n =
  let
    fun current names =
      case Redblackmap.peek (names, n) of
          SOME name =>
            (case current_dependency theory name of
                 SOME (_, m) => if m = n then SOME name else NONE
               | NONE => NONE)
        | NONE => NONE
  in
    case Lib.assoc1 theory (!names_by_index_ref) of
        SOME (_, names) =>
          (case current names of
               SOME name => SOME name
             | NONE => current (read_names_by_index theory))
      | NONE => current (read_names_by_index theory)
  end

fun thydl_of deps =
  let
    val theories = Listsort.sort String.compare (Lib.mk_set (map #1 deps))
    fun indices theory =
      Listsort.sort Int.compare
        (Lib.mk_set (List.mapPartial (fn (t, n) => if t = theory then SOME n else NONE) deps))
  in
    map (fn theory => (theory, indices theory)) theories
  end

(* The theorem a replay would prove: saved dependencies DEPS, given as
   (theory, save index), and ORACLES.  disk_thm takes one dependency as the
   theorem's own; add_tag then replaces the dependency list with all of
   them. *)
fun reinstate name concl oracles deps =
  case thydl_of deps of
      [] => raise Fail "holbuild proof cache: a record without dependencies"
    | thydl as ((theory, n :: _) :: _) =>
        let
          val th0 = Thm.disk_thm (Theory.current_theory (), Thm.SavedName name)
                                 ((((theory, n), []), oracles), [concl])
        in
          Thm.add_tag (Tag.set_dep (Dep.DEP_UNSAVED thydl) (Thm.tag (Thm.REFL boolSyntax.T)), th0)
        end
    | _ => raise Fail "holbuild proof cache: an empty dependency list"

fun subset xs ys = List.all (fn x => Lib.mem x ys) xs

fun reuse requested_timeout name concl ({timeout, oracles, deps, ...} : record) =
  let
    fun resolve [] acc = SOME (rev acc)
      | resolve ({theory, name, identity = recorded} :: rest) acc =
          case current_dependency theory name of
              SOME (th, n) =>
                if identity th = recorded then resolve rest ((th, (theory, n)) :: acc) else NONE
            | NONE => NONE
  in
    if not (timeout_satisfies requested_timeout timeout) then NONE
    else
      case resolve deps [] of
          SOME resolved =>
            if subset oracles ("DISK_THM" :: List.concat (map (oracles_of o #1) resolved))
            then SOME (reinstate name concl oracles (map #2 resolved))
            else NONE
        | NONE => NONE
  end

(* The record of TH, a proof of CONCL that ran with no theory changes, when a
   reinstatement would rebuild it exactly. *)
fun record_of name key timeout concl th =
  let
    val (oracles, axioms) = Tag.dest_tag (Thm.tag th)
    val thydl = case Tag.dep_of (Thm.tag th) of Dep.DEP_UNSAVED l => l | Dep.DEP_SAVED _ => []
    val indexed = List.concat (map (fn (theory, ns) => map (fn n => (theory, n)) ns) thydl)
    fun dep (theory, n) =
      case name_of_index theory n of
          SOME dep_name =>
            (case current_dependency theory dep_name of
                 SOME (dep_th, _) => SOME {theory = theory, name = dep_name, identity = identity dep_th}
               | NONE => NONE)
        | NONE => NONE
    val deps = map dep indexed
  in
    if null (Thm.hyp th) andalso Term.identical (Thm.concl th) concl andalso
       Lib.mem "DISK_THM" oracles andalso null axioms andalso not (null indexed) andalso
       List.all Option.isSome deps
    then SOME {name = name, key = key, timeout = timeout,
               oracles = Listsort.sort String.compare oracles, deps = map Option.valOf deps}
    else NONE
  end

fun cacheable kind tactic_text (hyps, _) =
  kind <> "resume" andalso not (String.isSubstring "suspend" tactic_text) andalso null hyps

(* The prover hook: the theorem NAME proving GOAL, reused from a record or
   proved by RUN and recorded. *)
fun prove {kind, name, tactic_text, proof_attrs} (goal as (_, concl)) run =
  case !config_ref of
      NONE => run ()
    | SOME {toolchain_key, records_out, tactic_timeout, ...} =>
        if not (cacheable kind tactic_text goal andalso Theory.uptodate_term concl andalso
                signature_certified ())
        then run ()
        else
          let
            val key = lookup_key toolchain_key name tactic_text proof_attrs concl
            fun first_reuse [] = NONE
              | first_reuse (record :: rest) =
                  case reuse tactic_timeout name concl record of
                      SOME th => SOME th
                    | NONE => first_reuse rest
          in
            case first_reuse (case Redblackmap.peek (!records_ref, key) of SOME rs => rs | NONE => []) of
                SOME th =>
                  (print ("holbuild reused the cached proof of " ^ name ^ "\n"); th)
              | NONE =>
                  let
                    val events = !theory_events_ref
                    val th = run ()
                  in
                    (if !theory_events_ref = events andalso signature_certified () then
                       case record_of name key tactic_timeout concl th of
                           SOME record => append_record records_out record
                         | NONE => ()
                     else ());
                    th
                  end
          end

(* Called when the runtime loads and again on each resume from a checkpoint
   that has it loaded: the records and paths are this run's. *)
fun install (config as {records_in, ...} : config) =
  (config_ref := SOME config;
   records_ref := read_records records_in)

end
