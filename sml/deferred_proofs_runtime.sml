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

  type item = {k : int, name : string, ctxt : Context.t, goal : Tactical.goal,
               make : unit -> Tactical.tactic}

  (* Elaboration runs on one thread; prove_all drains these. *)
  val queue = ref ([] : item list)
  val marker_data = ref (NONE : HOLsexp.t option)
  val proved = ref ([] : (int * ((string * int list) list * string list)) list)

  fun defer k name make : Tactical.tactic = fn goal => fn ctxt =>
    let
      val empty_tag = Thm.tag (Thm.REFL boolSyntax.T)
      val dep = Dep.DEP_UNSAVED [(Theory.current_theory (), [marker_base + k])]
      val stub = Thm.add_tag (Tag.set_dep dep empty_tag,
                              Thm.mk_oracle_thm (oracle_prefix ^ Int.toString k) goal)
    in
      queue := {k = k, name = name, ctxt = ctxt, goal = goal, make = make} :: !queue;
      Tactic.ACCEPT_TAC stub goal ctxt
    end

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
  fun prove_one types ({ctxt, goal, make, ...} : item) =
    let
      fun prove () =
        let
          val initial = thydata_of types
          val th = Tactical.TAC_PROOF_in ctxt (goal, make ())
        in
          (* A proof that suspends a subgoal (markerLib.suspend), or cites a
             still-suspended theorem, proves the goal under a hypothesis the
             stub's theorem lacks. *)
          case List.find (fn h => not (List.exists (fn a => Term.aconv a h) (#1 goal))) (Thm.hyp th) of
              SOME h => raise Fail ("the proof left a hypothesis its goal lacks: " ^ Parse.term_to_string h)
            | NONE =>
          case changed_thydata initial of
              NONE => th
            | SOME ty => raise Fail ("the proof wrote theory data of type " ^ ty)
        end
    in
      Context.with_context ctxt prove ()
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

  fun prove_all threads =
    let
      val types = thydata_types ()
      val items = ref (rev (!queue))
      val _ = queue := []
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
        let val tag = Thm.tag (prove_one types item)
        in locked (fn () => results := (k, (Dep.transfer_thydepl (Tag.dep_of tag), #1 (Tag.dest_tag tag))) :: !results) end
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
      List.app (fn _ => ignore (Thread.fork (worker, []))) (List.tabulate (count, fn i => i));
      Mutex.lock mutex; wait (); Mutex.unlock mutex;
      List.app retry (rev (!failed));
      ignore (Listener.remove_listener Theory.delta_hook listener);
      case (!change, changed_thydata live) of
          (SOME what, _) => raise Fail ("a deferred proof changed the theory: " ^ what)
        | (NONE, SOME ty) => raise Fail ("a deferred proof wrote theory data of type " ^ ty)
        | (NONE, NONE) => proved := !results
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
  fun rewrite_data lookup data =
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
                in {name = name, self = self, deps = deps', oracles = oracles', info = info, terms = terms} end)
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

  (* Writes the theory data with every deferred proof as the outline sees
     it to the export of SIG_PATH and copies the export to OUTLINE_DIR,
     ending with the file `ready`. *)
  fun publish_outline {sig_path, outline_dir} =
    let
      val stem = OS.Path.base sig_path
      fun copy ext = HolbuildRuntime.write_text (OS.Path.concat (outline_dir, OS.Path.file stem ^ ext))
                                                (read_text (stem ^ ext))
    in
      if null (!queue) then HolbuildRuntime.normalize_theory_export sig_path
      else
        let val data = HOLsexp.fromString (read_text (stem ^ ".dat"))
        in
          marker_data := data;
          write_data sig_path (rewrite_data outline_lookup (valOf data))
        end;
      OS.FileSys.mkDir outline_dir handle OS.SysErr _ => ();
      List.app copy [".dat", ".sml", ".sig"];
      HolbuildRuntime.write_text (OS.Path.concat (outline_dir, "ready")) ""
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
            fun lookup k =
              case Binarymap.peek (!memo, k) of
                  SOME resolved => resolved
                | NONE =>
                    case Binarymap.peek (raw, k) of
                        NONE => raise Fail ("no proof recorded for deferred goal " ^ Int.toString k)
                      | SOME r =>
                          let val resolved = resolve thy lookup r
                          in memo := Binarymap.insert (!memo, k, resolved); resolved end
          in
            write_data sig_path (rewrite_data lookup data)
          end
end
