structure HolbuildDependencies =
struct

structure Path = OS.Path

exception Error of string

datatype token = Word of string | StringLit of string | Symbol of char

type t =
  { loads : string list,
    uses : string list,
    extra_deps : string list,
    extra_outputs : string list,
    holdep_mentions : string list }

val cache_version = "holbuild-dependencies-cache-v4"
val extractor_version = "holbuild-hol-analyser-deps-v3"
(* identity names what the analyser's answers depend on; see
   HolbuildHolSharedCache.analyser_identity_for_holdir. *)
val analyser : {path : string, identity : string} option ref = ref NONE

fun set_analyser a = analyser := SOME a
fun clear_analyser () = analyser := NONE
fun current_analyser_path () = Option.map #path (!analyser)

fun configure_analyser_for_holdir holdir =
  if holdir = "" then clear_analyser ()
  else set_analyser (HolbuildHolSharedCache.analyser_for_holdir holdir)

(* Without a HOL toolchain the textual extractor answers instead. *)
fun analyser_identity () =
  case !analyser of
      SOME {identity, ...} => identity
    | NONE => "textual"

(* Workaround for a released Poly/ML, to drop once the toolchain's Poly/ML has
   the heap-sizing and segmentation rework of Poly/ML master (49ae4e76 and
   neighbours, in no release yet; #280 tracks the removal): without a floor the
   analyser cannot allocate a source of a few MB from Poly's 8 MB initial heap
   - the parallel collector reports "Completed with insufficient space", the
   runtime prints "Run out of store - interrupting threads", waits 5 s and the
   process exits non-zero, failing the build that spawned it (issue #278).
   128 MB covers sources several times the largest one measured (a 2.3 MB
   generated source needed more than the 8 MB default and was comfortable at
   50 MB), and Poly maps the heap lazily, so a small source costs nothing; the
   measured peak RSS of that batch is 89 MB at a 64 MB floor and 123 MB here.
   The options go on the command line of every analyser process: Poly's runtime
   consumes its own options wherever they appear and leaves the rest. *)
val analyser_min_heap_mb = 128

fun analyser_min_heap_args () = ["--minheap", Int.toString analyser_min_heap_mb]

fun has_suffix suffix s =
  let
    val n = size s
    val m = size suffix
  in
    n >= m andalso String.substring(s, n - m, m) = suffix
  end

fun is_word_start c = Char.isAlpha c orelse c = #"_"
fun is_word_char c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"

fun add_unique item items =
  if List.exists (fn x => x = item) items then items else item :: items

fun insert_sorted item items =
  case items of
      [] => [item]
    | x :: xs =>
        case String.compare(item, x) of
            LESS => item :: items
          | EQUAL => items
          | GREATER => x :: insert_sorted item xs

fun sort_unique items = List.foldl (fn (item, acc) => insert_sorted item acc) [] items

fun normalize_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun absolute_path path = Path.isAbsolute path handle Path.InvalidArc => false

fun normalize_dep_path source_path dep =
  normalize_path
    (if absolute_path dep then dep else Path.concat(Path.dir source_path, dep))

fun read_all path =
  let
    val input = TextIO.openIn path
      handle e => raise Error ("could not read " ^ path ^ ": " ^ General.exnMessage e)
  in
    TextIO.inputAll input before TextIO.closeIn input
    handle e => (TextIO.closeIn input; raise e)
  end

fun scan_string text start =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun loop i acc =
      if i >= n then (String.implode (rev acc), i)
      else
        case sub i of
            #"\"" => (String.implode (rev acc), i + 1)
          | #"\\" =>
              if i + 1 < n then loop (i + 2) (sub (i + 1) :: acc)
              else loop (i + 1) acc
          | c => loop (i + 1) (c :: acc)
  in
    loop start []
  end

fun skip_comment text start =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun closes i = i + 1 < n andalso sub i = #"*" andalso sub (i + 1) = #")"
    fun loop depth i =
      if i >= n then i
      else if opens i then loop (depth + 1) (i + 2)
      else if closes i then
        if depth = 1 then i + 2 else loop (depth - 1) (i + 2)
      else loop depth (i + 1)
  in
    loop 1 start
  end

fun scan_word text start =
  let
    val n = size text
    fun loop i =
      if i < n andalso is_word_char (String.sub(text, i)) then loop (i + 1)
      else i
    val stop = loop start
  in
    (String.substring(text, start, stop - start), stop)
  end

fun tokenize text =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens_comment i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun loop i acc =
      if i >= n then rev acc
      else if Char.isSpace (sub i) then loop (i + 1) acc
      else if opens_comment i then loop (skip_comment text (i + 2)) acc
      else if sub i = #"\"" then
        let val (s, next) = scan_string text (i + 1)
        in loop next (StringLit s :: acc) end
      else if is_word_start (sub i) then
        let val (word, next) = scan_word text i
        in loop next (Word word :: acc) end
      else loop (i + 1) (Symbol (sub i) :: acc)
  in
    loop 0 []
  end

fun theory_name s = has_suffix "Theory" s andalso size s > size "Theory"

fun extract_string_args keyword tokens =
  let
    fun loop rest acc =
      case rest of
          Word word :: StringLit value :: xs =>
            if word = keyword then loop xs (add_unique value acc)
            else loop (StringLit value :: xs) acc
        | _ :: xs => loop xs acc
        | [] => acc
  in
    loop tokens []
  end

fun extract_string_list_args keyword tokens =
  let
    fun list rest acc =
      case rest of
          Symbol #"]" :: xs => (rev acc, xs)
        | StringLit value :: xs => list xs (add_unique value acc)
        | Symbol #"," :: xs => list xs acc
        | _ => raise Error ("expected literal string list after " ^ keyword)
    fun loop rest acc =
      case rest of
          Word word :: Symbol #"[" :: xs =>
            if word = keyword then
              let val (values, rest') = list xs []
              in loop rest' (values @ acc) end
            else loop (Symbol #"[" :: xs) acc
        | Word _ :: _ :: _ =>
            (case rest of _ :: xs => loop xs acc | [] => acc)
        | _ :: xs => loop xs acc
        | [] => acc
  in
    loop tokens []
  end

fun extract_textual path =
  let
    val tokens = tokenize (read_all path)
    val loads = extract_string_args "load" tokens
    val uses = extract_string_args "use" tokens
    val extra_deps = extract_string_list_args "holbuild_extra_deps" tokens
    val extra_outputs = extract_string_list_args "holbuild_extra_outputs" tokens
  in
    {loads = sort_unique loads, uses = sort_unique uses,
     extra_deps = sort_unique extra_deps,
     extra_outputs = sort_unique extra_outputs,
     holdep_mentions = []}
  end

fun empty_deps () =
  {loads = [], uses = [], extra_deps = [], extra_outputs = [], holdep_mentions = []} : t

fun add_response_field source_path_for_error field value
      ({loads, uses, extra_deps, extra_outputs, holdep_mentions} : t) =
  case field of
      "load" => {loads = value :: loads, uses = uses, extra_deps = extra_deps,
                  extra_outputs = extra_outputs, holdep_mentions = holdep_mentions}
    | "use" => {loads = loads, uses = value :: uses, extra_deps = extra_deps,
                 extra_outputs = extra_outputs, holdep_mentions = holdep_mentions}
    | "extra-dep" => {loads = loads, uses = uses, extra_deps = value :: extra_deps,
                       extra_outputs = extra_outputs, holdep_mentions = holdep_mentions}
    | "extra-output" => {loads = loads, uses = uses, extra_deps = extra_deps,
                          extra_outputs = value :: extra_outputs, holdep_mentions = holdep_mentions}
    | "mention" => {loads = loads, uses = uses, extra_deps = extra_deps,
                     extra_outputs = extra_outputs, holdep_mentions = value :: holdep_mentions}
    | _ => raise Error ("bad analyser response field for " ^ source_path_for_error () ^ ": " ^ field)

fun finish_deps ({loads, uses, extra_deps, extra_outputs, holdep_mentions} : t) =
  {loads = sort_unique loads, uses = sort_unique uses,
   extra_deps = sort_unique extra_deps,
   extra_outputs = sort_unique extra_outputs,
   holdep_mentions = sort_unique holdep_mentions}

fun assoc id pairs =
  case pairs of
      [] => NONE
    | (k, v) :: rest => if k = id then SOME v else assoc id rest

fun parse_analyser_response response id_paths =
  let
    val lines = String.tokens (fn c => c = #"\n") response
    fun add_source ((id, path), dict) =
      case Binarymap.peek(dict, id) of
          NONE => Binarymap.insert(dict, id, path)
        | SOME _ => raise Error ("duplicate analyser request id: " ^ id)
    val source_paths =
      List.foldl add_source (Binarymap.mkDict String.compare) id_paths
    fun source_for id =
      Option.getOpt(Binarymap.peek(source_paths, id), "file " ^ id)
    fun expected id = Option.isSome (Binarymap.peek(source_paths, id))
    fun missing_response completed =
      case List.find (fn (id, _) => not (Option.isSome (Binarymap.peek(completed, id)))) id_paths of
          SOME (id, _) => raise Error ("analyser response missing file: " ^ source_for id)
        | NONE => ()
    fun loop rest current completed acc =
      case rest of
          [] => raise Error "analyser response missing end"
        | line :: more =>
            (case HolbuildAnalysisProtocol.split line of
                 ["begin-file", id] =>
                   (case current of
                        NONE =>
                          if not (expected id) then
                            raise Error ("analyser response has unknown file id: " ^ id)
                          else if Option.isSome (Binarymap.peek(completed, id)) then
                            raise Error ("analyser response has duplicate file id: " ^ id)
                          else loop more (SOME (id, empty_deps ())) completed acc
                      | SOME (open_id, _) =>
                          raise Error ("analyser response missing end-file for " ^ source_for open_id))
               | ["end-file", id] =>
                   (case current of
                        SOME (current_id, deps) =>
                          if id = current_id then
                            loop more NONE (Binarymap.insert(completed, id, ()))
                              ((id, finish_deps deps) :: acc)
                          else raise Error ("analyser response end-file mismatch: " ^ source_for current_id)
                      | NONE => raise Error ("analyser response end-file without begin-file: " ^ id))
               | ["end"] =>
                   (case current of
                        NONE =>
                          if null more then (missing_response completed; rev acc)
                          else raise Error "analyser response has trailing records after end"
                      | SOME (id, _) =>
                          raise Error ("analyser response missing end-file for " ^ source_for id))
               | [field, value] =>
                   (case current of
                        SOME (id, deps) =>
                          loop more (SOME (id, add_response_field (fn () => source_for id) field value deps)) completed acc
                      | NONE => raise Error ("analyser response field outside file: " ^ field))
               | _ => raise Error ("bad analyser response line: " ^ line))
    fun require_version line =
      case HolbuildAnalysisProtocol.split line of
          ["version", v] =>
            if v = HolbuildAnalysisProtocol.protocol_version then ()
            else raise Error ("unsupported analyser protocol version: " ^ v)
        | _ => raise Error "analyser response missing version header"
    fun require_ok line =
      case HolbuildAnalysisProtocol.split line of
          ["ok"] => ()
        | _ => raise Error "analyser response missing ok header"
  in
    case lines of
        version :: ok :: records =>
          (require_version version;
           require_ok ok;
           loop records NONE (Binarymap.mkDict String.compare) [])
      | [] => raise Error "analyser response missing version header"
      | version :: _ => (require_version version;
                         raise Error "analyser response missing ok header")
  end

fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

(* Runs the analyser on REQUEST, returning its stdout and, if it succeeded,
   its response; ERRORS is where its stderr goes.  Under exec-action it was
   built from the action's toolchain, so it runs confined: it reads that
   analyser, the action tree and checkpoints, writes only a fresh work
   directory, and its response counts once the sandbox has validated it. *)
(* Runs ANALYSER on REQUEST.  Under exec-action it runs confined, in a
   fresh work directory that alone is writable, and the response (and the
   stderr, when CAPTURE_STDERR) is read only after the sandbox has checked
   that work directory. *)
fun run_analyser {analyser, request, capture_stderr} =
  let
    fun command dir =
      String.concatWith " "
        (map HolbuildHash.quote
           (analyser :: analyser_min_heap_args () @
            ["--request", OS.Path.concat(dir, "request"), "--response", OS.Path.concat(dir, "response")])) ^
      (if capture_stderr then " 2> " ^ HolbuildHash.quote (OS.Path.concat(dir, "stderr")) else "")
    fun result dir {status, output} =
      {output = output,
       stderr = if capture_stderr then read_all (OS.Path.concat(dir, "stderr")) handle _ => "" else "",
       response = if OS.Process.isSuccess status then SOME (read_all (OS.Path.concat(dir, "response")))
                  else NONE}
  in
    case !HolbuildActionSandbox.private_roots of
        SOME (root, checkpoints) =>
          HolbuildActionSandbox.shell
            {writable = [], readable = [OS.Path.dir (OS.Path.dir analyser), root, checkpoints], toolchain = false}
            (fn work => (write_file (OS.Path.concat(work, "request")) request; command work))
            HolbuildProcessGroup.run_shell_output
            (fn (work, outcome) => result work outcome)
      | NONE =>
          let
            (* Not OS.FileSys.tmpName: it swaps the process umask, which races
               when several analysers start at once. *)
            val dir = HolbuildTempPath.temporary "analyser"
            fun remove () = HolbuildRemoveTree.remove_untrusted dir handle _ => ()
            fun go () =
              (OS.FileSys.mkDir dir;
               write_file (OS.Path.concat(dir, "request")) request;
               result dir (HolbuildProcessGroup.run_shell_output (command dir)))
          in
            (go () before remove ()) handle e => (remove (); raise e)
          end
  end

(* The response to REQUEST, or NONE if the analyser failed; its stdout is
   printed. *)
fun analyser_response analyser request =
  let val {output, response, ...} = run_analyser {analyser = analyser, request = request, capture_stderr = false}
  in print output; response end

datatype 'a outcome = Done of 'a | Failed of exn

fun outcome_value outcome =
  case outcome of
      Done value => value
    | Failed e => raise e

(* Runs one analyser process over files and returns its stdout with its
   parsed response, or the error the response or exit status gives. *)
fun analyse_files analyser files =
  let
    fun file_line (id, path) = HolbuildAnalysisProtocol.join ["file", id, path, "deps"]
    val request = String.concatWith "\n"
      ([HolbuildAnalysisProtocol.join ["version", HolbuildAnalysisProtocol.protocol_version],
        HolbuildAnalysisProtocol.join ["command", "analyse"]] @
       map file_line files @
       [HolbuildAnalysisProtocol.join ["end"]]) ^ "\n"
    val {output, response, ...} = run_analyser {analyser = analyser, request = request, capture_stderr = false}
    val outcome =
      (case response of
           SOME text => Done (parse_analyser_response text files)
         | NONE => raise Error "holbuild-hol-analyser failed")
      handle e => Failed e
  in
    (output, outcome)
  end

fun run_analyser_batch analyser files =
  let val (output, outcome) = analyse_files analyser files
  in print output; outcome_value outcome end

(* Starting an analyser costs about as much as analysing two or three
   files, so each extra process gets at least this many. *)
val min_files_per_analyser = 8
val analyser_jobs = ref 1
fun set_analyser_jobs n = analyser_jobs := Int.max (1, n)

(* Analyses a frontier batch with up to !analyser_jobs processes at once,
   the files dealt round-robin. The processes' stdout is printed and their
   failures raised in process order, and the results come back in request
   order, so the outcome is the one a single process gives. *)
fun run_analyser_parallel analyser files =
  let
    val n = Int.min (!analyser_jobs, length files div min_files_per_analyser)
  in
    if n <= 1 then run_analyser_batch analyser files
    else
      let
        val chunks = Array.array (n, [])
        val _ = List.foldl (fn (file, i) =>
                  (Array.update (chunks, i mod n, file :: Array.sub (chunks, i mod n)); i + 1))
                  0 files
        val results = Array.array (n, NONE)
        val mutex = Mutex.mutex ()
        val cv = ConditionVar.conditionVar ()
        val pending = ref n
        fun worker i () =
          let
            val result = analyse_files analyser (rev (Array.sub (chunks, i)))
                         handle e => ("", Failed e)
          in
            Mutex.lock mutex;
            Array.update (results, i, SOME result);
            pending := !pending - 1;
            ConditionVar.broadcast cv;
            Mutex.unlock mutex
          end
        val _ = List.tabulate (n, fn i => Thread.fork (worker i, []))
        fun wait () =
          if !pending = 0 then () else (ConditionVar.wait (cv, mutex); wait ())
        val _ = (Mutex.lock mutex; wait (); Mutex.unlock mutex)
        val outcomes = Array.foldr (fn (result, acc) => valOf result :: acc) [] results
        val _ = List.app (print o #1) outcomes
        val by_id =
          List.foldl (fn ((id, deps), dict) => Binarymap.insert (dict, id, deps))
            (Binarymap.mkDict String.compare)
            (List.concat (map (outcome_value o #2) outcomes))
      in
        map (fn (id, _) => (id, Binarymap.find (by_id, id))) files
      end
  end

fun extract_with_analyser analyser source_path =
  case assoc "1" (run_analyser_batch analyser [("1", source_path)]) of
      SOME deps => deps
    | NONE => raise Error ("holbuild-hol-analyser returned no result for " ^ source_path)

fun extract_uncached path =
  case current_analyser_path () of
      SOME analyser => extract_with_analyser analyser path
    | NONE => extract_textual path

fun line_value prefix line =
  if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE))
  else NONE

fun values prefix lines = List.mapPartial (line_value prefix) lines

fun read_cache cache_path source_hash =
  let
    val text = read_all cache_path
    val lines = String.tokens (fn c => c = #"\n") text
  in
    case lines of
        version :: extractor :: analyser_line :: hash_line :: rest =>
          if version = cache_version andalso
             extractor = "extractor=" ^ extractor_version andalso
             analyser_line = "analyser=" ^ analyser_identity () andalso
             hash_line = "source_sha256=" ^ source_hash then
            SOME {loads = values "load=" rest,
                  uses = values "use=" rest,
                  extra_deps = values "extra_dep=" rest,
                  extra_outputs = values "extra_output=" rest,
                  holdep_mentions = values "mention=" rest}
          else NONE
      | _ => NONE
  end
  handle _ => NONE

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if OS.FileSys.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); OS.FileSys.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

fun cache_text source_hash ({loads, uses, extra_deps, extra_outputs, holdep_mentions} : t) =
  String.concatWith "\n"
    ([cache_version,
      "extractor=" ^ extractor_version,
      "analyser=" ^ analyser_identity (),
      "source_sha256=" ^ source_hash] @
     map (fn value => "load=" ^ value) loads @
     map (fn value => "use=" ^ value) uses @
     map (fn value => "extra_dep=" ^ value) extra_deps @
     map (fn value => "extra_output=" ^ value) extra_outputs @
     map (fn value => "mention=" ^ value) holdep_mentions) ^ "\n"

fun write_cache cache_path source_hash deps =
  (ensure_parent cache_path;
   HolbuildStatCache.write_text_atomically cache_path (cache_text source_hash deps))

(* Besides the project's own copy, each analysis is kept in the shared cache
   under a name derived from everything it depends on, so another checkout
   of the same sources on this machine finds it instead of analysing again.
   An entry's modification time is its last use, which `holbuild gc` goes by. *)
fun shared_cache_path source_hash =
  Path.concat(Path.concat(HolbuildCacheConfig.cache_root (), "analysis"),
              HolbuildHash.string_sha256
                (String.concatWith "\n"
                   [cache_version, extractor_version, analyser_identity (), source_hash]))

(* The project's copy, else the shared one, which is then copied into the
   project. A shared entry that cannot be read is a miss. *)
fun read_cached cache_path source_hash =
  case read_cache cache_path source_hash of
      SOME deps => SOME deps
    | NONE =>
        let val shared = shared_cache_path source_hash
        in
          case read_cache shared source_hash of
              SOME deps =>
                (OS.FileSys.setTime (shared, NONE) handle OS.SysErr _ => ();
                 write_cache cache_path source_hash deps handle _ => ();
                 SOME deps)
            | NONE => NONE
        end
        handle _ => NONE

fun write_cached cache_path source_hash deps =
  (write_cache cache_path source_hash deps handle _ => ();
   write_cache (shared_cache_path source_hash) source_hash deps handle _ => ())

fun extract_cached_with_hash {cache_path, source_path, source_hash} =
  case read_cached cache_path source_hash of
      SOME deps => deps
    | NONE =>
        let val deps = extract_uncached source_path
        in write_cached cache_path source_hash deps; deps end

(* Returns, for each request, the dependency facts read from its cache or
   produced by the batch analyser run, or NONE if neither produced them. *)
fun prefetch_cached_with_hash requests =
  let
    fun enumerate i xs =
      case xs of
          [] => []
        | x :: rest => (Int.toString i, x) :: enumerate (i + 1) rest
    fun cached_or_missing ((id, req as {cache_path, source_path, source_hash}), (cached, missing)) =
      case read_cached cache_path source_hash of
          SOME deps => ((id, deps) :: cached, missing)
        | NONE => (cached, (id, req) :: missing)
    val (cached, missing) = List.foldl cached_or_missing ([], []) (enumerate 1 requests)
    val analysed =
      case (current_analyser_path (), missing) of
          (_, []) => []
        | (NONE, _) => []
        | (SOME analyser, _) =>
            let
              val files = map (fn (id, {source_path, ...}) => (id, source_path)) (rev missing)
              val results = run_analyser_parallel analyser files
              val missing_by_id =
                List.foldl
                  (fn ((id, req), dict) => Binarymap.insert(dict, id, req))
                  (Binarymap.mkDict String.compare)
                  missing
              fun store (id, deps) =
                case Binarymap.peek(missing_by_id, id) of
                    SOME {cache_path, source_hash, ...} => write_cached cache_path source_hash deps
                  | NONE => ()
            in
              List.app store results;
              List.filter (fn (id, _) => Option.isSome (Binarymap.peek(missing_by_id, id))) results
            end
    val by_id =
      List.foldl (fn ((id, deps), dict) => Binarymap.insert(dict, id, deps))
        (Binarymap.mkDict String.compare) (cached @ analysed)
  in
    map (fn (id, _) => Binarymap.peek(by_id, id)) (enumerate 1 requests)
  end

fun extract_cached {cache_path, source_path} =
  extract_cached_with_hash {cache_path = cache_path,
                            source_path = source_path,
                            source_hash = HolbuildHash.file_sha256 source_path}

fun extract path = extract_uncached path

fun describe ({loads, uses, extra_deps, extra_outputs, holdep_mentions} : t) =
  let
    fun line label values =
      case values of
          [] => ()
        | _ => print ("  " ^ label ^ ": " ^ String.concatWith ", " values ^ "\n")
  in
    line "loads" loads;
    line "uses" uses;
    line "extra deps" extra_deps;
    line "extra outputs" extra_outputs;
    line "Holdep mentions" holdep_mentions
  end

end
