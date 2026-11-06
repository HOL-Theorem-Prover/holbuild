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

  (* Graph.fringe follows load order. Canonicalize only the parent header,
     preserving the potentially large theory payload byte for byte. *)
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
    in
      if text = normalized then ()
      else
        let
          val old_hash = "\"" ^ SHA1.sha1_file {filename = dat_path} ^ "\""
          val sml = read_text sml_path
          val (before_hash, hash_and_rest) = Substring.position old_hash (Substring.full sml)
          val _ = if Substring.isEmpty hash_and_rest then
                    raise Fail "exported theory source does not contain its data hash"
                  else ()
          val _ = write_text dat_path normalized
          val new_hash = "\"" ^ SHA1.sha1_file {filename = dat_path} ^ "\""
        in
          write_text sml_path (Substring.string before_hash ^ new_hash ^
                              Substring.string (Substring.triml (size old_hash) hash_and_rest))
        end
    end

  fun export_theory_if_needed sig_path =
    if readable sig_path then () else export_theory ()
end
