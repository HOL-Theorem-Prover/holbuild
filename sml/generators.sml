structure HolbuildGenerators =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string
exception ErrorWithDebugArtifacts of string * HolbuildStatus.debug_artifacts

fun die msg = raise Error msg
fun die_with_debug_artifacts msg artifacts =
  if HolbuildStatus.debug_artifacts_empty artifacts then die msg
  else raise ErrorWithDebugArtifacts (msg, artifacts)

fun member x xs = List.exists (fn y => x = y) xs

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if FS.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun read_text path =
  let
    val input = TextIO.openIn path
    fun loop acc =
      case TextIO.inputLine input of
          NONE => String.concat (rev acc) before TextIO.closeIn input
        | SOME line => loop (line :: acc)
  in
    loop [] handle e => (TextIO.closeIn input; raise e)
  end

fun read_lines path = String.tokens (fn c => c = #"\n") (read_text path)

fun write_text path text =
  let val _ = ensure_parent path
      val output = TextIO.openOut path
  in
    TextIO.output(output, text);
    TextIO.closeOut output
  end
  handle e => die ("could not write " ^ path ^ ": " ^ General.exnMessage e)

fun file_hash label path =
  if readable path then HolbuildHash.file_sha1 path
  else die (label ^ " not found: " ^ path)

fun output_hash path = file_hash "generator output" path

fun hash_text text = HolbuildHash.string_sha1 text

fun abs_under root rel = HolbuildProject.abs_under root rel

fun generator_state_dir package =
  Path.concat(HolbuildProject.package_artifact_root package, "generate")

fun generator_stem package generator =
  let
    val key = hash_text (HolbuildProject.package_name package ^ ":" ^ HolbuildProject.generator_name generator)
  in
    Path.concat(generator_state_dir package, key)
  end

fun metadata_path package generator = generator_stem package generator ^ ".key"
fun log_path package generator = generator_stem package generator ^ ".log"

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun retain_debug_artifacts () =
  HolbuildStatus.json_mode () andalso HolbuildStatus.retain_debug_artifacts ()

fun command_output_path package generator =
  if HolbuildStatus.json_mode () andalso not (retain_debug_artifacts ()) then FS.tmpName ()
  else log_path package generator

fun generator_output_detail output =
  if HolbuildStatus.json_mode () then
    let val text = read_text output handle _ => ""
    in
      if text = "" then ""
      else "\n--- generator output ---\n" ^ text ^ "--- end generator output ---\n"
    end
  else
    "; log: " ^ output

fun cleanup_command_output output =
  if HolbuildStatus.json_mode () andalso not (retain_debug_artifacts ()) then remove_file output else ()

fun command_debug_artifacts output =
  if retain_debug_artifacts () andalso readable output then {log = SOME output}
  else HolbuildStatus.no_debug_artifacts

fun dependency_result deps name =
  case List.find (fn (dep_name, _) => dep_name = name) deps of
      SOME (_, result) => result
    | NONE => die ("internal missing generator dependency result: " ^ name)

fun input_line root generator rel =
  let val path = abs_under root rel
  in "input=" ^ rel ^ "@" ^ file_hash ("generator " ^ HolbuildProject.generator_name generator ^ " input") path end

fun command_arg_line arg = "command_arg_sha1=" ^ hash_text arg

fun dependency_line dep_results dep =
  "dep=" ^ dep ^ "@" ^ dependency_result dep_results dep

fun input_key package dep_results generator =
  let
    val root = HolbuildProject.package_root package
    val lines =
      ["holbuild-generate-v1",
       "package=" ^ HolbuildProject.package_name package,
       "name=" ^ HolbuildProject.generator_name generator] @
      map command_arg_line (HolbuildProject.generator_command generator) @
      map (input_line root generator) (HolbuildProject.generator_inputs generator) @
      map (dependency_line dep_results) (HolbuildProject.generator_deps generator)
  in
    hash_text (String.concatWith "\n" lines ^ "\n")
  end

fun output_line root rel =
  let val path = abs_under root rel
  in "output=" ^ rel ^ "@" ^ output_hash path end

fun metadata_text package generator key =
  let
    val root = HolbuildProject.package_root package
    val output_lines = map (output_line root) (HolbuildProject.generator_outputs generator)
  in
    String.concatWith "\n" (["holbuild-generate-result-v1", "input_key=" ^ key] @ output_lines) ^ "\n"
  end

fun line_present line lines = List.exists (fn existing => existing = line) lines

fun output_metadata_matches package rel lines =
  let val expected = output_line (HolbuildProject.package_root package) rel
  in line_present expected lines end
  handle Error _ => false

fun metadata_up_to_date package generator key =
  let val path = metadata_path package generator
  in
    if not (readable path) then false
    else
      let val lines = read_lines path
      in
        line_present "holbuild-generate-result-v1" lines andalso
        line_present ("input_key=" ^ key) lines andalso
        List.all (fn rel => output_metadata_matches package rel lines)
                 (HolbuildProject.generator_outputs generator)
      end
  end
  handle _ => false

fun ensure_output_parents package generator =
  let val root = HolbuildProject.package_root package
  in List.app (fn rel => ensure_parent (abs_under root rel)) (HolbuildProject.generator_outputs generator) end

fun run_command package generator =
  let
    val output = command_output_path package generator
    val _ = ensure_parent output
    val _ = ensure_output_parents package generator
    val status = HolbuildToolchain.run_in_dir_to_file
                   (HolbuildProject.package_root package)
                   (HolbuildProject.generator_command generator)
                   output
  in
    if HolbuildToolchain.success status then
      cleanup_command_output output
    else
      let
        val detail = generator_output_detail output
        val artifacts = command_debug_artifacts output
        val _ = cleanup_command_output output
      in
        die_with_debug_artifacts
          ("generator " ^ HolbuildProject.generator_name generator ^ " failed" ^ detail)
          artifacts
      end
  end

fun verify_outputs package generator =
  let
    val root = HolbuildProject.package_root package
    fun verify rel =
      let val path = abs_under root rel
      in if readable path then ()
         else die ("generator " ^ HolbuildProject.generator_name generator ^ " did not produce declared output: " ^ rel)
      end
  in
    List.app verify (HolbuildProject.generator_outputs generator)
  end

fun run_one package dep_results generator =
  let
    val key = input_key package dep_results generator
    val _ =
      if metadata_up_to_date package generator key then ()
      else (run_command package generator;
            verify_outputs package generator;
            write_text (metadata_path package generator) (metadata_text package generator key))
    val result = hash_text (read_text (metadata_path package generator))
  in
    (HolbuildProject.generator_name generator, result)
  end

fun duplicate_name names =
  case names of
      [] => NONE
    | name :: rest => if member name rest then SOME name else duplicate_name rest

fun duplicate_output generators =
  let
    fun add_output owner (output, (seen, duplicate)) =
      case duplicate of
          SOME _ => (seen, duplicate)
        | NONE =>
            (case Binarymap.peek(seen, output) of
                 SOME first => (seen, SOME (output, first, owner))
               | NONE => (Binarymap.insert(seen, output, owner), NONE))
    fun add_generator (generator, state) =
      let val owner = HolbuildProject.generator_name generator
      in List.foldl (add_output owner) state (HolbuildProject.generator_outputs generator) end
    val (_, duplicate) =
      List.foldl add_generator (Binarymap.mkDict String.compare, NONE) generators
        : (string, string) Binarymap.dict * (string * string * string) option
  in
    duplicate
  end

fun generator_named generators name =
  List.find (fn generator => HolbuildProject.generator_name generator = name) generators

fun validate_generators generators =
  let
    val names = map HolbuildProject.generator_name generators
    val _ =
      case duplicate_name names of
          NONE => ()
        | SOME name => die ("duplicate generator name: " ^ name)
    val _ =
      case duplicate_output generators of
          NONE => ()
        | SOME (output, first, second) =>
            die ("generator output " ^ output ^ " is produced by both " ^ first ^ " and " ^ second)
    fun validate_dep generator dep =
      case generator_named generators dep of
          SOME _ => ()
        | NONE => die ("generator " ^ HolbuildProject.generator_name generator ^ " depends on unknown generator " ^ dep)
    val _ = List.app (fn generator => List.app (validate_dep generator) (HolbuildProject.generator_deps generator)) generators
  in
    ()
  end

fun topo_sort generators =
  let
    val _ = validate_generators generators
    fun unique_deps deps =
      let
        fun add (dep, (seen, kept)) =
          if Binaryset.member(seen, dep) then (seen, kept)
          else (Binaryset.add(seen, dep), dep :: kept)
        val (_, kept) = List.foldl add (Binaryset.empty String.compare, []) deps
      in
        rev kept
      end
    fun add_generator (generator, (by_name, indegrees, dependents)) =
      let
        val name = HolbuildProject.generator_name generator
        val deps = unique_deps (HolbuildProject.generator_deps generator)
        fun add_dependent (dep, dict) =
          let val existing = Option.getOpt(Binarymap.peek(dict, dep), [])
          in Binarymap.insert(dict, dep, name :: existing) end
      in
        (Binarymap.insert(by_name, name, generator),
         Binarymap.insert(indegrees, name, length deps),
         List.foldl add_dependent dependents deps)
      end
    val (by_name, initial_indegrees, dependents) =
      List.foldl add_generator
        (Binarymap.mkDict String.compare, Binarymap.mkDict String.compare, Binarymap.mkDict String.compare)
        generators
        : (string, HolbuildProject.generator) Binarymap.dict *
          (string, int) Binarymap.dict *
          (string, string list) Binarymap.dict
    val manifest_positions =
      #2 (List.foldl
            (fn (generator, (position, positions)) =>
                (position + 1,
                 Binarymap.insert(positions, HolbuildProject.generator_name generator, position)))
            (0, Binarymap.mkDict String.compare)
            generators)
    fun before_in_manifest left right =
      Binarymap.find(manifest_positions, left) < Binarymap.find(manifest_positions, right)
    fun indegree dict name = Option.getOpt(Binarymap.peek(dict, name), 0)
    fun ready_names () =
      List.foldr
        (fn (generator, acc) =>
            let val name = HolbuildProject.generator_name generator
            in if indegree initial_indegrees name = 0 then name :: acc else acc end)
        [] generators
    fun pop_queue queue =
      case queue of
          (item :: front, back) => SOME (item, (front, back))
        | ([], []) => NONE
        | ([], back) => pop_queue (rev back, [])
    fun queue_items (front, back) = front @ rev back
    fun insert_ready item queue =
      let
        fun insert [] = [item]
          | insert (other :: rest) =
              if before_in_manifest item other then item :: other :: rest
              else other :: insert rest
      in
        (* FIFO insertion orders newly unblocked independent generators by
           predecessor completion; retain the manifest's stable ordering. *)
        (insert (queue_items queue), [])
      end
    fun process_dependent (dependent, (indegrees, queue)) =
      let
        val count = indegree indegrees dependent - 1
        val indegrees' = Binarymap.insert(indegrees, dependent, count)
      in
        if count = 0 then (indegrees', insert_ready dependent queue)
        else (indegrees', queue)
      end
    fun generator_for name =
      Binarymap.find(by_name, name)
      handle Binarymap.NotFound => die ("internal missing generator: " ^ name)
    fun loop done ordered count indegrees queue =
      case pop_queue queue of
          NONE =>
            if count = length generators then rev ordered
            else die "generator dependency cycle"
        | SOME (name, queue') =>
            if Binaryset.member(done, name) then
              loop done ordered count indegrees queue'
            else
              let
                val generator = generator_for name
                val done' = Binaryset.add(done, name)
                val newly_unblocked = rev (Option.getOpt(Binarymap.peek(dependents, name), []))
                val (indegrees', queue'') =
                  List.foldl process_dependent (indegrees, queue') newly_unblocked
              in
                loop done' (generator :: ordered) (count + 1) indegrees' queue''
              end
  in
    loop (Binaryset.empty String.compare) [] 0 initial_indegrees (ready_names (), [])
  end

fun run_package package =
  let val generators = HolbuildProject.package_generators package
  in
    if null generators then ()
    else
      let
        val ordered = topo_sort generators
        fun run (generator, dep_results) = run_one package dep_results generator :: dep_results
      in
        ignore (List.foldl run [] ordered)
      end
  end

end
