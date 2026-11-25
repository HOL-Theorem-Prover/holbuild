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

  (* Source-load timing, a diagnostic: a process whose environment has
     HOLBUILD_TIMING_SOURCE_LOADS=1 times each source file the loader
     evaluates, and each holbuild runtime file it uses.  A row per label
     keeps the count, the total time (inclusive) and the self time: the
     total less the timed loads the file made while it ran and any heap
     sharing around a theory (share_around_theory), which is loader
     overhead.  At exit the process prints the self time and count of each
     kind as hol-phases (srclib, srcrt, srcthy, in ms; srclibn, srcrtn,
     srcthyn) and a `holbuild source-load` line per row, with
     HOLBUILD_SOURCE_LOAD_CONTEXT as ctx: every runtime file, the
     max_library_rows libraries of most self time and the rest as one
     `other` row, and all theories as one row; or, having timed nothing,
     one `none` row.  A heap saved while timing keeps the table; a process
     restoring it is another process (process_identity) and starts afresh. *)
  val max_library_rows = 64
  fun no_source_loads () : (string * string, int * LargeInt.int * LargeInt.int) Binarymap.dict =
    Binarymap.mkDict (fn ((k1, n1), (k2, n2)) =>
                        case String.compare (k1, k2) of EQUAL => String.compare (n1, n2) | order => order)
  (* The process: its pid, and its start time, which tells a process that
     restores a heap from the one that saved it even if the pid is reused. *)
  fun process_identity () =
    let
      val pid = LargeInt.toString (SysWord.toLargeInt (Posix.Process.pidToWord (Posix.ProcEnv.getpid ())))
      val start =
        let
          val input = TextIO.openIn "/proc/self/stat"
          val stat = TextIO.inputAll input before TextIO.closeIn input
          (* The fields after the command name, which ends at the last ')'. *)
          val fields = String.tokens Char.isSpace
                         (Substring.string (Substring.taker (fn c => c <> #")") (Substring.full stat)))
        in
          List.nth (fields, 19)
        end
        handle _ => ""
    in
      pid ^ ":" ^ start
    end
  type source_load_state =
    {process : string option ref,
     loads : (string * string, int * LargeInt.int * LargeInt.int) Binarymap.dict ref,
     (* The nested time of each timed load still running, innermost first. *)
     stack : LargeInt.int ref list ref,
     (* The directory of a load ahead's step files (ahead_load_runtime.sml),
        which wait for late parents rather than load a library: not timed. *)
     untimed_dir : string ref}
  (* A process that compiles this file again (a load ahead's two preloads
     each do) keeps the table of the structure this one replaces, which is
     still the one bound while this one compiles: one table, one report. *)
  val source_load_state : source_load_state =
    case lookup_value ["HolbuildRuntime"] "source_load_state" of
        SOME state => RunCall.unsafeCast state
      | NONE => {process = ref NONE, loads = ref (no_source_loads ()), stack = ref [], untimed_dir = ref ""}
  val untimed_dir = #untimed_dir source_load_state

  fun label_text text = String.map (fn c => if Char.isGraph c andalso c <> #"=" then c else #"_") text

  fun report_source_loads () =
    if !(#process source_load_state) <> SOME (process_identity ()) then ()
    else
      let
        val rows = Binarymap.listItems (!(#loads source_load_state))
        val _ = #loads source_load_state := no_source_loads ()
        fun of_kind kind = List.filter (fn ((k, _), _) => k = kind) rows
        val libraries =
          Listsort.sort (fn ((_, (_, _, a)), (_, (_, _, b))) => LargeInt.compare (b, a)) (of_kind "library")
        fun fold_rows kind name rows =
          ((kind, name),
           List.foldl (fn ((_, (n, total, self)), (n', total', self')) => (n + n', total + total', self + self'))
                      (0, 0, 0) rows)
        val shown =
          of_kind "runtime" @
          (if length libraries <= max_library_rows then libraries
           else List.take (libraries, max_library_rows) @
                [fold_rows "library" "other" (List.drop (libraries, max_library_rows))]) @
          (case of_kind "theory" of [] => [] | theories => [fold_rows "theory" "*" theories])
        fun phases (name, kind) =
          let val (_, (n, _, self)) = fold_rows kind "" (of_kind kind)
          in name ^ "=" ^ LargeInt.toString (self div 1000) ^ " " ^ name ^ "n=" ^ Int.toString n end
        val context = label_text (getOpt (OS.Process.getEnv "HOLBUILD_SOURCE_LOAD_CONTEXT", "other"))
        fun row ((kind, name), (n, total, self)) =
          String.concatWith " "
            ["holbuild source-load", "ctx=" ^ context, "kind=" ^ kind, "name=" ^ name, "n=" ^ Int.toString n,
             "total_us=" ^ LargeInt.toString total, "self_us=" ^ LargeInt.toString self] ^ "\n"
      in
        TextIO.output (TextIO.stdErr,
          String.concat
            (("holbuild hol-phases " ^
              String.concatWith " " (map phases [("srclib", "library"), ("srcrt", "runtime"), ("srcthy", "theory")]) ^
              "\n") :: map row (if null shown then [(("none", "-"), (0, 0, 0))] else shown)));
        TextIO.flushOut TextIO.stdErr
      end

  (* Whether this process times source loads, starting its table and its
     report when it first asks. *)
  fun timing_source_loads () =
    OS.Process.getEnv "HOLBUILD_TIMING_SOURCE_LOADS" = SOME "1" andalso
    (if !(#process source_load_state) = SOME (process_identity ()) then ()
     else
       (#process source_load_state := SOME (process_identity ());
        #loads source_load_state := no_source_loads ();
        #stack source_load_state := [];
        OS.Process.atExit report_source_loads);
     true)
  (* A process compiling this file starts here; one resuming from a heap
     that holds it starts when the proof runtime installs. *)
  val _ = timing_source_loads ()

  (* F's time, counted as part of the timed load running (if any) but not
     its self time. *)
  fun outside_self_time f =
    case !(#stack source_load_state) of
        [] => f ()
      | nested :: _ =>
          let
            val start = Time.now ()
            fun finish () = nested := !nested + Time.toMicroseconds (Time.- (Time.now (), start))
          in
            (f () before finish ()) handle e => (finish (); PolyML.Exception.reraise e)
          end

  fun time_source_load label f =
    if not (timing_source_loads ()) then f ()
    else
      let
        val stack = #stack source_load_state
        val nested = ref (0 : LargeInt.int)
        val _ = stack := nested :: !stack
        val start = Time.now ()
        fun finish () =
          let
            val total = Time.toMicroseconds (Time.- (Time.now (), start))
            val self = total - !nested
            val _ = stack := (case !stack of _ :: outer => outer | [] => [])
            val _ = case !stack of outer :: _ => outer := !outer + total | [] => ()
            val loads = #loads source_load_state
            val (n, total', self') = getOpt (Binarymap.peek (!loads, label), (0, 0, 0))
          in
            loads := Binarymap.insert (!loads, label, (n + 1, total' + total, self' + self))
          end
      in
        (f () before finish ()) handle e => (finish (); PolyML.Exception.reraise e)
      end

  (* A file the loader evaluates: a theory's (its initialization, from its
     module or its source), a HOL library's by its path under HOLDIR, or a
     project library's by its file name alone, the action root's path being
     local to the machine. *)
  fun time_source_file path f =
    let
      val expanded = holpathdb.subst_pathvars path handle _ => path
      val file = OS.Path.file expanded
      val holdir = Systeml.HOLDIR ^ "/"
      val label =
        if String.isSuffix "Theory.sml" file orelse String.isSuffix "Theory.sig" file then ("theory", "*")
        else if String.isPrefix holdir expanded then
          ("library", "hol:" ^ label_text (String.extract (expanded, size holdir, NONE)))
        else ("library", "project:" ^ label_text file)
    in
      if !untimed_dir <> "" andalso String.isPrefix (!untimed_dir ^ "/") expanded then f ()
      else time_source_load label f
    end

  (* USE, sharing the heap around a theory as the comment above says. *)
  fun share_around_theory use path =
    case theory_dat_size path of
        NONE => use path
      | SOME size =>
          (if !unshared_dat_bytes > 0 andalso
              (size >= large_single_dat orelse !unshared_dat_bytes + size >= large_cumulative_dat)
           then outside_self_time share_heap else ();
           use path;
           unshared_dat_bytes := !unshared_dat_bytes + size;
           (* Anything loaded before was shared above, so only a large
              theory can bring the count to a share here. *)
           if size >= large_single_dat then outside_self_time share_heap else ())

  (* share_around_theory, timed. *)
  fun use_with_large_theory_sharing use path =
    time_source_file path (fn () => share_around_theory use path)

  (* How a preload loads a module: sharing through
     use_with_large_theory_sharing, on whichever loader this HOL has.  A HOL
     with theory modules evaluates a theory's source only when its module is
     missing, through Meta.moduleSourceLoader; one without has Meta.loadPlan.
     Names Meta may lack are compiled only once Meta is known to have them,
     at the first load: a file is bound only once all of it has run, so
     this structure can't be named while it loads.  The source loader is
     wrapped for one load at a time, as the child policy may replace it.
     It times each file it is given, so a theory loaded from its module
     counts too. *)
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
         "(fn use => fn file => HolbuildRuntime.time_source_file file " ^
         "(fn () => source (HolbuildRuntime.share_around_theory use) file)); " ^
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
  (* holbuild uses its runtime files through this. *)
  val plain_use = use
  fun use path = time_source_load ("runtime", label_text (OS.Path.file path)) (fn () => plain_use path)
  val print = TextIO.print
  val export_theory = Theory.export_theory
  val restore_prover = Tactical.restore_prover

  fun save_hierarchy_depth () = List.length (PolyML.SaveState.showHierarchy())

  fun readable path = OS.FileSys.access(path, [OS.FileSys.A_READ])

  fun write_text path text =
    let
      val out = TextIO.openOut path
      val _ = HolbuildBoundedOutput.text (out, text)
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
      (* A child reads every theorem of this theory with DISK_THM among its
         oracles (HOL's Tag.read_disk_tag), so it can't tell whether the
         export lists it.  An outline lists it for each theorem whose proof
         it defers, while the proof itself may use no theorem from disk; so
         a proved theorem's oracles get it merged in, in Tag.merge_oracle's
         order.  Axioms and definitions, never deferred, keep their list
         as written, which keeps most theories' digests as they were. *)
      fun with_disk_thm oracles =
        let
          fun merge [] = [String "DISK_THM"]
            | merge (l as String s :: rest) =
                (case String.compare (s, "DISK_THM") of
                     LESS => String s :: merge rest
                   | EQUAL => l
                   | GREATER => String "DISK_THM" :: l)
            | merge _ = fail "oracle"
        in
          List (merge (items "oracles" oracles))
        end
      val proved = Integer 2
      (* (name-index (((theory save-index) dependencies...) oracles...) (class private location...) terms...) *)
      fun thm (Cons(i, Cons(Cons(_, oracles), Cons(info, Cons(terms, Symbol "nil"))))) =
            (case items "theorem info" info of
                 class :: private :: _ =>
                   List [str i, if class = proved then with_disk_thm oracles else oracles, class, private, terms]
               | _ => fail "theorem info")
        | thm _ = fail "theorem"
      val theorems = items "theorems" thms
      (* The save indices of this theory's axioms and definitions. *)
      val unproved =
        List.mapPartial
          (fn Cons(_, Cons(Cons(dependencies, _), Cons(info, _))) =>
                (case (items "theorem info" info, items "dependencies" dependencies) of
                     (class :: _, self :: _) =>
                       if class = proved then NONE
                       else (case items "dependency" self of [_, save] => SOME save | _ => fail "dependency")
                   | _ => fail "theorem")
            | _ => fail "theorem")
          theorems
      (* ThyDataSexp's encoding: shared strings and names by index, an integer
         as itself, and a theorem as
         (tag-th (theory save-index dependencies oracles) terms theory anonymous-index). *)
      fun thydata (Cons(Symbol "tag-str", i as Integer _)) = Cons(Symbol "tag-str", str i)
        | thydata (Cons(Symbol "tag-knm", Cons(i as Integer _, j as Integer _))) =
            Cons(Symbol "tag-knm", Cons(str i, str j))
        | thydata (Cons(Symbol "tag-th",
                        Cons(Cons(thy, Cons(save as Integer _, Cons(_, Cons(oracles, Symbol "nil")))),
                             Cons(terms, Cons(saved, Cons(Integer _, Symbol "nil")))))) =
            Cons(Symbol "tag-th",
                 List [thy,
                       if thy = name andalso not (List.exists (fn i => i = save) unproved)
                       then with_disk_thm oracles else oracles,
                       terms, saved])
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
            List (map thm theorems), incorporate, loadable']
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

(* From HOL a58912a73f a HOL_ERR's message is a HOLmessage.message, which
   Poly/ML's value printer shows as `?`, and HOL registers a printer for it
   only in interactive sessions.  A failed proof is reported through
   General.exnMessage (HOL's uncaught-exception line), so give the type a
   printer here, quoting its text as the field printed while it was a
   string.  A HOL without the type compiles nothing. *)
val _ =
  if Option.isSome (HolbuildRuntime.lookup_value ["HOLmessage"] "toString") then
    let
      val stream =
        TextIO.openString
          "val () = PolyML.addPrettyPrinter (fn _ => fn _ => fn (m : HOLmessage.message) => \
          \PolyML.PrettyString (\"\\\"\" ^ String.toString (HOLmessage.toString m) ^ \"\\\"\"));"
    in
      PolyML.compiler (fn () => TextIO.input1 stream, []) ()
    end
  else ();
