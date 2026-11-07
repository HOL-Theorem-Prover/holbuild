structure HolbuildRuntime =
struct
  val load = Meta.load
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
  fun normalized_theory_data data =
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
      (* ThyDataSexp's encoding: shared strings and names by index; a theorem
         as (tag-th (theory save-index dependencies oracles) terms theory anonymous-index). *)
      fun thydata (Cons(Symbol "tag-str", i as Integer _)) = Cons(Symbol "tag-str", str i)
        | thydata (Cons(Symbol "tag-knm", Cons(i as Integer _, j as Integer _))) =
            Cons(Symbol "tag-knm", Cons(str i, str j))
        | thydata (Cons(Symbol "tag-th",
                        Cons(Cons(thy, Cons(Integer _, Cons(_, Cons(oracles, Symbol "nil")))),
                             Cons(terms, Cons(saved, Cons(Integer _, Symbol "nil")))))) =
            Cons(Symbol "tag-th", List [thy, oracles, terms, saved])
        | thydata (Cons(a, b)) = Cons(thydata a, thydata b)
        | thydata atom = atom
      (* GrammarAncestry writes its theory names as bare string indices. *)
      fun entry (Cons(key as String "GrammarAncestry", ancestry)) =
            Cons(key, List (map str (items "grammar ancestry" ancestry)))
        | entry (Cons(key, data)) = Cons(key, thydata data)
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

  (* The digest of the theory data at DAT_PATH that dependents compare and
     that children record for the parent: SHA-1 of the normalized view, or
     of the file when the data has an unexpected shape. *)
  fun theory_data_digest dat_path =
    let
      fun as_written e =
        (TextIO.output (TextIO.stdErr,
                        "holbuild: warning: hashing " ^ dat_path ^ " as written: " ^
                        General.exnMessage e ^ "\n");
         SHA1.sha1_file {filename = dat_path})
      (* Not HOLsexp.fromFile: HOLFileSys would remap the path again. *)
      fun read_data () =
        let val input = TextIO.openIn dat_path
        in HOLsexp.fromStream input before TextIO.closeIn input end
    in
      sha1_string (serialize_sexp (normalized_theory_data (read_data ())))
      handle e as Fail _ => as_written e
           | e as Subscript => as_written e
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
