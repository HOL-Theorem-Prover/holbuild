structure HolbuildRuntime =
struct
  (* Poly/ML's GC no longer shares common data by itself, and loading a
     theory keeps its decoded .dat live.  Where each theory's .dat repeats
     most of its parent's, as CakeML's translator theories do (each tens of
     MiB), a chain of them fills the heap with duplicates before the script
     starts.  So loading a theory whose .dat is large, or after the theories
     loaded since the last share add up to a lot, shares the heap's common
     data: before the theory, if anything is unshared, and after it.  A load
     of the usual size never shares. *)
  val large_single_dat : Position.int = 67108864
  val large_cumulative_dat : Position.int = 134217728
  (* Bytes of theory .dat files loaded since the last share. *)
  val unshared_dat_bytes : Position.int ref = ref 0

  fun share_heap () =
    (PolyML.shareCommonData PolyML.rootFunction; unshared_dat_bytes := 0)

  (* A value by its structure path and name, looked up at run time so that
     this compiles whether the runtime and HOL have it or not. *)
  fun lookup_value path name =
    let
      fun contents s = PolyML.NameSpace.Structures.contents s
      fun sub (ns : PolyML.NameSpace.nameSpace) s = Option.map contents (#lookupStruct ns s)
      val ns = List.foldl (fn (s, ns) => Option.mapPartial (fn ns => sub ns s) ns)
                          (SOME PolyML.globalNameSpace) path
    in
      Option.mapPartial (PolyML.CodeTree.evalue o PolyML.NameSpace.Values.code)
        (Option.mapPartial (fn ns => #lookupVal ns name) ns)
    end

  (* PolyML.SaveState.saveChildWithModules, where this Poly/ML has it.  A
     state it saves refers to the modules the process loaded from files,
     by id and path, instead of copying them, and loading the state loads
     them.  Modules the process wrote itself are copied. *)
  val save_child_with_modules : (string * int -> unit) option =
    Option.map RunCall.unsafeCast (lookup_value ["PolyML", "SaveState"] "saveChildWithModules")

  (* Whether the process loaded a module from a file: HOL's theory module
     cache counts those loads (hits), not the modules it writes.  Without
     that count, whether the runtime has loaded any module at all. *)
  fun loaded_module_files () =
    case lookup_value ["TheoryModules"] "statistics" of
        SOME statistics =>
          #hits ((RunCall.unsafeCast statistics : unit -> {hits : int, misses : int, writes : int}) ()) > 0
      | NONE =>
          case lookup_value ["PolyML", "SaveState"] "showLoadedModules" of
              SOME loaded => not (null ((RunCall.unsafeCast loaded : unit -> Word8Vector.vector list) ()))
            | NONE => false

  (* Whether the deps heap's save (HolbuildCheckpointSaveRuntime.
     save_deps_checkpoint) shares common data first, unless
     HOLBUILD_SHARE_COMMON_DATA says otherwise: not when it saves the
     heap with modules, which it does only where holbuild reads such a
     state (MODULES). *)
  fun deps_save_shares modules =
    not (modules andalso Option.isSome save_child_with_modules andalso loaded_module_files ())

  (* The size of the .dat beside a theory's .sml, where HOL's file system
     keeps it, or NONE for any other file. *)
  fun theory_dat_size path =
    let val expanded = holpathdb.subst_pathvars path handle _ => path
    in
      if String.isSuffix "Theory.sml" expanded then
        SOME (HFS_NameMunge.toFSfn false OS.FileSys.fileSize (OS.Path.base expanded ^ ".dat")
              handle _ => 0)
      else NONE
    end

  (* USE, sharing the heap around a theory as the comment above says. *)
  fun use_with_large_theory_sharing use path =
    case theory_dat_size path of
        NONE => use path
      | SOME size =>
          (if !unshared_dat_bytes > 0 andalso
              (size >= large_single_dat orelse !unshared_dat_bytes + size >= large_cumulative_dat)
           then share_heap () else ();
           use path;
           unshared_dat_bytes := !unshared_dat_bytes + size;
           (* Anything loaded before was shared above, so only a large
              theory can bring the count to a share here. *)
           if size >= large_single_dat then share_heap () else ())

  (* How a preload loads a module: sharing through
     use_with_large_theory_sharing, on whichever loader this HOL has.  A HOL
     with theory modules evaluates a theory's source only when its module is
     missing, through Meta.moduleSourceLoader; one without has Meta.loadPlan.
     Names Meta may lack are compiled only once Meta is known to have them,
     at the first load: a file is bound only once all of it has run, so
     this structure can't be named while it loads.  The source loader is
     wrapped for one load at a time, as the child policy may replace it. *)
  val loader : (string -> unit) option ref = ref NONE
  fun meta_has names =
    case #lookupStruct PolyML.globalNameSpace "Meta" of
        NONE => false
      | SOME meta =>
          List.all (Option.isSome o #lookupVal (PolyML.NameSpace.Structures.contents meta)) names
  fun choose_loader () =
    if meta_has ["moduleSourceLoader"] then
      CompilerSpecific.quietbind
        ("val _ = HolbuildRuntime.loader := SOME (fn module => " ^
         "let val source = !Meta.moduleSourceLoader " ^
         "in Meta.moduleSourceLoader := " ^
         "(fn use => source (HolbuildRuntime.use_with_large_theory_sharing use)); " ^
         "(Meta.load module handle e => (Meta.moduleSourceLoader := source; PolyML.Exception.reraise e)); " ^
         "Meta.moduleSourceLoader := source end);")
    else if meta_has ["loadPlan", "qquse"] then
      CompilerSpecific.quietbind
        "val _ = HolbuildRuntime.loader := SOME (Meta.loadPlan (HolbuildRuntime.use_with_large_theory_sharing Meta.qquse));"
    else loader := SOME Meta.load
  fun load module =
    case !loader of
        SOME load => load module
      | NONE => (choose_loader (); valOf (!loader) module)
  val use = use
  val print = TextIO.print
  val export_theory = Theory.export_theory
  val restore_prover = Tactical.restore_prover

  fun save_hierarchy_depth () = List.length (PolyML.SaveState.showHierarchy())

  fun readable path = OS.FileSys.access(path, [OS.FileSys.A_READ])

  fun write_text path text =
    let
      val out = TextIO.openOut path
      val _ = TextIO.output(out, text)
      val _ = TextIO.closeOut out
    in
      ()
    end

  fun write_lines path lines =
    write_text path (String.concatWith "\n" lines ^ "\n")

  fun write_hol_file path text =
    let
      val out = HOLFileSys.openOut path
      val _ = HOLFileSys.output(out, text)
      val _ = HOLFileSys.closeOut out
    in
      ()
    end

  fun write_manifest path lines =
    write_hol_file path (String.concatWith "\n" lines ^ "\n")

  fun write_parent_report path =
    write_lines path (Listsort.sort String.compare (Theory.parents "-"))

  fun write_mldeps_report path = write_lines path (Theory.current_ML_deps())

  fun string_byte_reader text (offset, requested) =
    let val count = Int.max(0, Int.min(requested, size text - offset))
    in (Byte.stringToBytes (String.substring(text, offset, count)), offset + count) end

  fun sha1_string text = SHA1.sha1String (string_byte_reader text) 0

  (* The view of a theory's exported data that its digest covers: the data
     without the parts a proof edit changes (each theorem's dependency
     record and source location, the parents' hashes), so that children
     built on it stay reusable after a proof-only edit of the theory
     (DESIGN.md, "Early cutoff").  The string table is dropped, with every
     reference to it resolved, since those parts shift its indices; the
     type and term tables index only each other and the id table.  Raises
     Fail on data of another shape. *)
  local
    open HOLsexp
    fun fail what = raise Fail ("unexpected " ^ what ^ " in the exported theory data")
    fun items what s = case strip_list s of (l, NONE) => l | _ => fail what
    fun tagged tag s =
      case s of
          Cons(Symbol t, rest) => if t = tag then rest else fail tag
        | _ => fail tag
  in
  fun normalized_theory_data {sexp_coded : string -> bool} data =
    let
      val (header, core, incorporate, loadable) =
        case items "theory" data of
            [Symbol "theory", header, core, incorporate, loadable] =>
              (header, core, incorporate, loadable)
          | _ => fail "theory"
      val (name, parents) =
        case header of
            Cons(name, parents) =>
              (name, map (fn Cons(parent, _) => parent | _ => fail "parent") (items "parents" parents))
          | _ => fail "header"
      val (tables, exports) =
        case tagged "core-data" core of Cons(tables, exports) => (tables, exports) | _ => fail "core-data"
      val (strings, ids, types, terms) =
        case items "tables" (tagged "tables" tables) of
            [strings, ids, types, terms] => (strings, ids, types, terms)
          | _ => fail "tables"
      val string_table =
        Vector.fromList (map (fn String s => s | _ => fail "string")
                             (items "string-table" (tagged "string-table" strings)))
      fun str (Integer i) = String (Vector.sub(string_table, i))
        | str _ = fail "string index"
      val ids' = List (map (fn Cons(i, j) => Cons(str i, str j) | _ => fail "id")
                           (items "id-table" (tagged "id-table" ids)))
      val (tys, tms, thms) =
        case items "exports" (tagged "exports" exports) of [tys, tms, thms] => (tys, tms, thms) | _ => fail "exports"
      (* (name-index ((dependencies...) oracles...) (class private location...) terms...) *)
      fun thm (Cons(i, Cons(Cons(_, oracles), Cons(info, Cons(terms, Symbol "nil"))))) =
            (case items "theorem info" info of
                 class :: private :: _ => List [str i, oracles, class, private, terms]
               | _ => fail "theorem info")
        | thm _ = fail "theorem"
      (* ThyDataSexp's encoding: shared strings and names by index, an integer
         as itself, and a theorem as
         (tag-th (theory save-index dependencies oracles) terms theory anonymous-index). *)
      fun thydata (Cons(Symbol "tag-str", i as Integer _)) = Cons(Symbol "tag-str", str i)
        | thydata (Cons(Symbol "tag-knm", Cons(i as Integer _, j as Integer _))) =
            Cons(Symbol "tag-knm", Cons(str i, str j))
        | thydata (Cons(Symbol "tag-th",
                        Cons(Cons(thy, Cons(Integer _, Cons(_, Cons(oracles, Symbol "nil")))),
                             Cons(terms, Cons(saved, Cons(Integer _, Symbol "nil")))))) =
            Cons(Symbol "tag-th", List [thy, oracles, terms, saved])
        | thydata (Cons(a, b)) = Cons(thydata a, thydata b)
        | thydata atom = atom
      (* GrammarAncestry's: theory names as bare string indices. *)
      fun indexed (i as Integer _) = str i
        | indexed (Cons(a, b)) = Cons(indexed a, indexed b)
        | indexed atom = atom
      (* A codec of its own writes what it likes, so a bare integer may name
         a string whose index the proofs decide: only data of a known
         encoding is normalized, and the rest keeps the theory hashed as
         written. *)
      fun entry (Cons(key as String k, data)) =
            Cons(key,
                 if sexp_coded k then thydata data
                 else if k = "GrammarAncestry" then indexed data
                 else if k = "OpenTheoryMap" orelse k = "TexTokenMap" then data
                 else raise Fail ("theory data " ^ k ^ " has an encoding holbuild doesn't know"))
        | entry _ = fail "loadable data"
      val loadable' = List (map entry (items "loadable-thydata" (tagged "loadable-thydata" loadable)))
    in
      List [name, List parents, ids', types, terms, tys, tms,
            List (map thm (items "theorems" thms)), incorporate, loadable']
    end

  (* An unambiguous flat text of DATA: atoms are length-prefixed. *)
  fun serialize_sexp data =
    let
      fun atom prefix text = prefix ^ Int.toString (size text) ^ ":" ^ text
      fun go (Symbol s, acc) = atom "s" s :: acc
        | go (String s, acc) = atom "\"" s :: acc
        | go (Integer i, acc) = ("i" ^ Int.toString i ^ ";") :: acc
        | go (Cons(a, b), acc) = ")" :: go (b, go (a, "(" :: acc))
    in
      String.concat (List.rev (go (data, [])))
    end
  end

  (* Whether theory data of type KEY is in ThyDataSexp's encoding:
     ThyDataSexp.new registers each key's load hook under this name. *)
  fun sexp_coded_thydata key =
    List.exists (fn (h, _) => h = "ThmSetData.onload." ^ key) (Listener.listeners Theory.delta_hook)

  (* The digest of the theory data at DAT_PATH that dependents compare and
     that children record for the parent: SHA-1 of the normalized view, or
     of the file when the data has an unexpected shape. *)
  fun theory_data_digest dat_path =
    let
      fun as_written why =
        (TextIO.output (TextIO.stdErr,
                        "holbuild: warning: hashing " ^ dat_path ^ " as written: " ^ why ^ "\n");
         SHA1.sha1_file {filename = dat_path})
      (* Not HOLsexp.fromFile: HOLFileSys would remap the path again. *)
      fun read_data () =
        let val input = TextIO.openIn dat_path
        in HOLsexp.fromStream input before TextIO.closeIn input end
    in
      sha1_string (serialize_sexp (normalized_theory_data {sexp_coded = sexp_coded_thydata} (read_data ())))
      handle Fail why => as_written why
           | Subscript => as_written "a string index is out of range"
    end

  (* Graph.fringe follows load order.  Canonicalize only the parent header,
     preserving the potentially large theory payload byte for byte, and
     make the hash literal in Theory.sml the data's digest. *)
  fun normalize_theory_export sig_path =
    let
      val stem = OS.Path.base sig_path
      val dat_path = stem ^ ".dat"
      val sml_path = stem ^ ".sml"
      fun read_text path =
        let val input = TextIO.openIn path
        in TextIO.inputAll input before TextIO.closeIn input end
      val text = read_text dat_path
      val prefix = "(theory"
      fun skip_space i =
        if i < size text andalso Char.isSpace (String.sub(text, i)) then skip_space (i + 1) else i
      fun header_end i depth quoted escaped =
        if i >= size text then raise Fail "unterminated exported theory parent header"
        else
          let val c = String.sub(text, i)
          in
            if quoted then
              header_end (i + 1) depth (escaped orelse c <> #"\"") (not escaped andalso c = #"\\")
            else if c = #"\"" then header_end (i + 1) depth true false
            else if c = #"(" then header_end (i + 1) (depth + 1) false false
            else if c = #")" then
              if depth = 1 then i + 1 else header_end (i + 1) (depth - 1) false false
            else header_end (i + 1) depth false false
          end
      val start = skip_space (size prefix)
      val _ = if String.isPrefix prefix text andalso start < size text andalso
                 String.sub(text, start) = #"(" then ()
              else raise Fail "unexpected exported theory data format"
      val stop = header_end start 0 false false
      val header =
        case HOLsexp.fromString (String.substring(text, start, stop - start)) of
            SOME result => result
          | NONE => raise Fail "cannot parse exported theory parent header"
      val decode_parent = HOLsexp.pair_decode (HOLsexp.string_decode, HOLsexp.string_decode)
      val (name, parents) =
        case HOLsexp.pair_decode (HOLsexp.string_decode, HOLsexp.list_decode decode_parent) header of
            SOME result => result
          | NONE => raise Fail "invalid exported theory parent header"
      val sorted = Listsort.sort (fn ((a, _), (b, _)) => String.compare (a, b)) parents
      val encode_parent = HOLsexp.pair_encode (HOLsexp.String, HOLsexp.String)
      val canonical_header =
        HOLsexp.pair_encode (HOLsexp.String, HOLsexp.list_encode encode_parent) (name, sorted)
      val printed = HOLPP.pp_to_string 74 HOLsexp.printer canonical_header
      val normalized = prefix ^ "\n " ^
        String.translate (fn #"\n" => "\n " | c => str c) printed ^
        String.extract(text, stop, NONE)
      val old_hash = "\"" ^ sha1_string text ^ "\""
      val sml = read_text sml_path
      val (before_hash, hash_and_rest) = Substring.position old_hash (Substring.full sml)
      val _ = if Substring.isEmpty hash_and_rest then
                raise Fail "exported theory source does not contain its data hash"
              else ()
      val _ = if text = normalized then () else write_text dat_path normalized
      val new_hash = "\"" ^ theory_data_digest dat_path ^ "\""
    in
      write_text sml_path (Substring.string before_hash ^ new_hash ^
                          Substring.string (Substring.triml (size old_hash) hash_and_rest))
    end

  fun export_theory_if_needed sig_path =
    if readable sig_path then () else export_theory ()
end
