(* The plan record: what one planning run found, kept so the next run can
   check cheaply which files moved and redo only the work below them.

   A record lives in .holbuild/plan/<fingerprint>, where the fingerprint
   hashes every planning input that is not a scanned file.  It keeps the stat
   and hash of each selected source and extra-input file, the stat and
   classified entries of each directory discovery listed outside HOL and
   pinned git checkouts, every discovered source, and per selected node
   everything execute reads from the plan.

   A file counts as unchanged only when its size, mtime, ctime, inode and
   device all match, as in git's index.  A file or directory modified within
   a second of the run that recorded it is marked racy and checked again in
   full on the next run. *)
structure HolbuildPlanRecord =
struct

structure BP = HolbuildBuildPlan
structure SI = HolbuildSourceIndex
structure SC = HolbuildStatCache

exception Error of string

val format = "holbuild-plan-record-v2"
val kept_records = 4

datatype mode = Off | On | Check

fun mode () =
  case OS.Process.getEnv "HOLBUILD_PLAN_RECORD" of
      NONE => On
    | SOME "" => On
    | SOME "on" => On
    | SOME "off" => Off
    | SOME "check" => Check
    | SOME other => raise Error ("HOLBUILD_PLAN_RECORD must be on, off or check, not " ^ other)

(* Records live with the project's other build state, wherever holbuild
   runs from. *)
fun record_dir project =
  OS.Path.concat (OS.Path.concat (HolbuildProject.artifact_root project, ".holbuild"), "plan")

(* ---- Encoding ----
   One entry per line; fields are separated by \001, list items by \002 and
   the parts of an item by \003.  A record is not written when any text it
   would hold contains one of these characters or a newline. *)

val sep_field = #"\001"
val sep_item = #"\002"
val sep_part = #"\003"

fun encodable text =
  not (CharVector.exists (fn c => c = #"\n" orelse c = sep_field orelse c = sep_item orelse c = sep_part) text)

exception Unencodable of string

fun check_text text = if encodable text then text else raise Unencodable text

fun line tag fields = tag ^ String.concatWith (str sep_field) fields ^ "\n"
(* An item may itself be a list of parts. *)
fun items values =
  String.concatWith (str sep_item)
    (map (fn text => if CharVector.exists (fn c => c = #"\n" orelse c = sep_field orelse c = sep_item) text
                     then raise Unencodable text else text) values)
fun parts values = String.concatWith (str sep_part) (map check_text values)

(* String.fields on one separator, without a predicate call per character:
   records run to megabytes. *)
fun fields_on sep text =
  let
    fun loop i stop acc =
      if i < 0 then String.substring(text, 0, stop) :: acc
      else if String.sub(text, i) = sep then loop (i - 1) i (String.substring(text, i + 1, stop - i - 1) :: acc)
      else loop (i - 1) stop acc
  in
    loop (size text - 1) (size text) []
  end

fun split sep text = if text = "" then [] else fields_on sep text

(* The fields of each line, in one pass over the record. *)
fun lines_fields text =
  let
    fun piece i stop = String.substring(text, i + 1, stop - i - 1)
    fun loop i stop fields lines =
      if i < 0 then (String.substring(text, 0, stop) :: fields) :: lines
      else
        case String.sub(text, i) of
            #"\n" => loop (i - 1) i [] ((piece i stop :: fields) :: lines)
          | #"\001" => loop (i - 1) i (piece i stop :: fields) lines
          | _ => loop (i - 1) stop fields lines
  in
    loop (size text - 1) (size text) [] []
  end
fun split_items text = split sep_item text
fun split_parts text = fields_on sep_part text

fun bad what = raise Error ("malformed plan record: " ^ what)

fun int_text n = Int.toString n
fun parse_int text =
  if text = "" orelse size text > 9 then bad ("expected a number, found " ^ text)
  else
    CharVector.foldl
      (fn (c, n) => if Char.isDigit c then 10 * n + (ord c - ord #"0")
                    else bad ("expected a number, found " ^ text))
      0 text
fun large_text n = LargeInt.toString n
fun parse_large text =
  case LargeInt.fromString text of
      SOME n => n
    | NONE => bad ("expected a number, found " ^ text)

fun bool_text true = "1"
  | bool_text false = "0"
fun parse_bool "1" = true
  | parse_bool "0" = false
  | parse_bool text = bad ("expected 0 or 1, found " ^ text)

type stamp = SC.ident

fun stamp_text ({dev, ino, size, mtime_ns, ctime_ns} : stamp) =
  parts [dev, ino, int_text size, large_text mtime_ns, large_text ctime_ns]

fun parse_stamp text : stamp =
  case split_parts text of
      [dev, ino, size, mtime, ctime] =>
        {dev = dev, ino = ino, size = parse_int size,
         mtime_ns = parse_large mtime, ctime_ns = parse_large ctime}
    | _ => bad "stamp"

fun stamp path = SC.stat_ident path

(* Racy: modified so close to the run that recorded it that a later change
   in the same timestamp tick would leave the stat unchanged. *)
fun racy_at start_ns ({mtime_ns, ctime_ns, ...} : stamp) =
  let val window = start_ns - 1000000000
  in mtime_ns >= window orelse ctime_ns >= window end

fun kind_char SI.TheoryScript = "t"
  | kind_char SI.Sml = "m"
  | kind_char SI.Sig = "s"
fun parse_kind "t" = SI.TheoryScript
  | parse_kind "m" = SI.Sml
  | parse_kind "s" = SI.Sig
  | parse_kind text = bad ("source kind " ^ text)

fun reason_text reason = BP.dependency_reason_text reason
val reasons =
  [BP.ExtractedLoad, BP.ExtractedHoldepMention, BP.DeclaredActionDependency,
   BP.DeclaredActionLoad, BP.DeclaredExtraInput, BP.SignatureCompanionReason]
fun parse_reason text =
  case List.find (fn reason => reason_text reason = text) reasons of
      SOME reason => reason
    | NONE => bad ("dependency reason " ^ text)

fun external_kind_text BP.ExternalTheory = "theory"
  | external_kind_text BP.ExternalLibrary = "library"
  | external_kind_text BP.ExternalInput = "input"
fun parse_external_kind "theory" = BP.ExternalTheory
  | parse_external_kind "library" = BP.ExternalLibrary
  | parse_external_kind "input" = BP.ExternalInput
  | parse_external_kind text = bad ("external dependency kind " ^ text)

(* ---- Contents ---- *)

type file = {path : string, stamp : stamp, racy : bool, hash : string}
type dir = {path : string, stamp : stamp, racy : bool, entries : string list}
type stamped_dir = {path : string, stamp : stamp, racy : bool}

(* A discovered source, by position of its package in the record. *)
type source_entry =
  {package : int, kind : SI.kind, logical_name : string, relative_path : string,
   source_path : string}

type node_entry =
  {source : int, hash : string, deps : HolbuildDependencies.t,
   symbolic : (string * BP.dependency_reason) list,
   resolved : (int * string * BP.dependency_reason) list,
   external : (string * BP.external_dependency_kind * BP.dependency_reason) list,
   config_lines : string list, input_key : string, extra_inputs_key : string option}

type expansion = {base : string, decl : string, files : (string * string) list, dirs : string list}

type t =
  {fingerprint : string,
   toolchain : {hol : stamp, state : stamp, racy : bool, key : string},
   action_toolchain_key : string,
   packages : (string * string) list,
   members : (string * string) list,
   dirs : dir list,
   files : file list,
   input_dirs : stamped_dir list,
   expansions : expansion list,
   sources : source_entry list,
   roots : int list,
   selected : node_entry list,
   targets : string list,
   ids : {resolution_context_id : string, selected_graph_id : string,
          selected_plan_id : string, resolved_plan_id : string}}

fun deps_fields ({loads, uses, extra_deps, extra_outputs, holdep_mentions} : HolbuildDependencies.t) =
  map items [loads, uses, extra_deps, extra_outputs, holdep_mentions]

(* Edges are stored against the node's symbolic dependencies, which start
   with its extracted loads and mentions: only the declared ones are kept,
   external edges as one kind letter (or "-") per symbolic dependency, and
   resolved edges by symbolic position and target. *)
exception Irregular
(* A path the record would have to watch but cannot stat, such as a dangling
   link in an extra-input directory. *)
exception Unrecordable of string

fun extracted_symbolic ({loads, holdep_mentions, ...} : HolbuildDependencies.t) =
  map (fn name => (name, BP.ExtractedLoad)) loads @
  map (fn name => (name, BP.ExtractedHoldepMention)) holdep_mentions

fun external_kind_char BP.ExternalTheory = #"t"
  | external_kind_char BP.ExternalLibrary = #"l"
  | external_kind_char BP.ExternalInput = #"i"

fun compact_edges deps symbolic resolved external =
  let
    val extracted = extracted_symbolic deps
    val declared =
      if List.take (symbolic, length extracted) = extracted then List.drop (symbolic, length extracted)
      else raise Irregular
    fun external_codes ([], []) = []
      | external_codes ([], _ :: _) = raise Irregular
      | external_codes (dep :: deps, edges) =
          case edges of
              (name, kind, reason) :: rest =>
                if (name, reason) = dep then external_kind_char kind :: external_codes (deps, rest)
                else #"-" :: external_codes (deps, edges)
            | [] => #"-" :: external_codes (deps, [])
    fun positions _ _ [] = []
      | positions _ [] (_ :: _) = raise Irregular
      | positions i (deps as dep :: rest_deps) (edges as (target, name, reason) :: rest) =
          if (name, reason) = dep then (i, target) :: positions i deps rest
          else positions (i + 1) rest_deps edges
  in
    {declared = declared,
     external = String.implode (external_codes (symbolic, external)),
     resolved = positions 0 symbolic resolved}
  end
  handle Subscript => raise Irregular

fun expand_edges deps declared external_codes resolved =
  let
    val symbolic = extracted_symbolic deps @ declared
    val symbolic_vector = Vector.fromList symbolic
    val _ = if size external_codes = Vector.length symbolic_vector then () else bad "external edges"
    fun external_at (i, c) =
      let val (name, reason) = Vector.sub(symbolic_vector, i)
      in
        case c of
            #"-" => NONE
          | #"t" => SOME (name, BP.ExternalTheory, reason)
          | #"l" => SOME (name, BP.ExternalLibrary, reason)
          | #"i" => SOME (name, BP.ExternalInput, reason)
          | _ => bad "external edge kind"
      end
  in
    {symbolic = symbolic,
     external = List.mapPartial external_at (List.tabulate (size external_codes, fn i => (i, String.sub(external_codes, i)))),
     resolved = map (fn (position, target) =>
                       let val (name, reason) = Vector.sub(symbolic_vector, position) handle Subscript => bad "resolved edge"
                       in (target, name, reason) end)
                    resolved}
  end

fun default_source_path root rel = root ^ "/" ^ rel

fun encode ({fingerprint, toolchain, action_toolchain_key, packages, members, dirs, files, input_dirs,
             expansions, sources, roots, selected, targets, ids} : t) =
  let
    val roots_of = Vector.fromList (map (fn (_, root) => root) packages)
    fun source ({package, kind, logical_name, relative_path, source_path} : source_entry) =
      line "S" [int_text package, kind_char kind, logical_name, relative_path,
                if source_path = default_source_path (Vector.sub(roots_of, package)) relative_path
                then "" else check_text source_path]
    fun node ({source, hash, deps, symbolic, resolved, external, config_lines, input_key, extra_inputs_key} : node_entry) =
      let val {declared, external, resolved} = compact_edges deps symbolic resolved external
      in
        line "N"
          ([int_text source, hash, input_key, getOpt (extra_inputs_key, ""), items config_lines] @
           deps_fields deps @
           [items (map (fn (name, reason) => parts [name, reason_text reason]) declared),
            external,
            items (map (fn (position, target) => parts [int_text position, int_text target]) resolved)])
      end
  in
    String.concat
      ([format ^ "\n",
        line "F" [fingerprint],
        line "T" [stamp_text (#hol toolchain), stamp_text (#state toolchain), bool_text (#racy toolchain), #key toolchain],
        line "A" [action_toolchain_key],
        line "I" (map (fn (name, value) => check_text name ^ "=" ^ check_text value)
                   [("resolution_context_id", #resolution_context_id ids),
                    ("selected_graph_id", #selected_graph_id ids),
                    ("selected_plan_id", #selected_plan_id ids),
                    ("resolved_plan_id", #resolved_plan_id ids)]),
        line "G" [items targets],
        line "R" [items (map int_text roots)]] @
       map (fn (name, root) => line "P" [check_text name, check_text root]) packages @
       map (fn (path, kind) => line "M" [check_text path, kind]) members @
       map (fn ({path, stamp, racy, entries} : dir) =>
              line "D" [check_text path, stamp_text stamp, bool_text racy, items entries]) dirs @
       map (fn ({path, stamp, racy, hash} : file) =>
              line "f" [check_text path, stamp_text stamp, bool_text racy, hash]) files @
       map (fn ({path, stamp, racy} : stamped_dir) =>
              line "d" [check_text path, stamp_text stamp, bool_text racy]) input_dirs @
       map (fn ({base, decl, files, dirs} : expansion) =>
              line "X" [check_text base, check_text decl,
                        items (map (fn (rel, abs) => parts [rel, abs]) files), items dirs]) expansions @
       map source sources @
       map node selected @
       ["E\n"])
  end

fun read_text path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input
     handle e => (TextIO.closeIn input; raise e)
  end

fun decode text : t =
  let
    val lines = lines_fields text
    val _ = case lines of
                [first] :: _ => if first = format then () else bad ("format " ^ first)
              | _ => bad ("format of " ^ String.substring(text, 0, Int.min(size text, 40)))
    val fingerprint = ref "" val toolchain = ref NONE val action_key = ref ""
    val ids = ref [] val targets = ref [] val roots = ref []
    val packages = ref [] val members = ref [] val dirs = ref [] val files = ref []
    val input_dirs = ref [] val expansions = ref [] val sources = ref [] val selected = ref []
    val complete = ref false
    val package_roots = ref (Vector.fromList [])
    fun source_line [package, kind, logical, rel, path] =
          let val package = parse_int package
              val _ = if Vector.length (!package_roots) = length (!packages) then ()
                      else package_roots := Vector.fromList (rev (map #2 (!packages)))
              val root = Vector.sub(!package_roots, package) handle Subscript => bad "package index"
          in
            {package = package, kind = parse_kind kind, logical_name = logical, relative_path = rel,
             source_path = if path = "" then default_source_path root rel else path}
          end
      | source_line _ = bad "source"
    fun deps_of [loads, uses, extra_deps, extra_outputs, holdep_mentions] =
          {loads = split_items loads, uses = split_items uses, extra_deps = split_items extra_deps,
           extra_outputs = split_items extra_outputs, holdep_mentions = split_items holdep_mentions}
      | deps_of _ = bad "dependency facts"
    fun node_line (source :: hash :: input_key :: extra_key :: config :: rest) =
          (case rest of
               [loads, uses, extra_deps, extra_outputs, mentions, declared, external, resolved] =>
                 let
                   val deps = deps_of [loads, uses, extra_deps, extra_outputs, mentions]
                   val edges =
                     expand_edges deps
                       (map (fn item => case split_parts item of
                                            [name, reason] => (name, parse_reason reason)
                                          | _ => bad "declared dependency") (split_items declared))
                       external
                       (map (fn item => case split_parts item of
                                            [position, target] => (parse_int position, parse_int target)
                                          | _ => bad "resolved edge") (split_items resolved))
                 in
                   {source = parse_int source, hash = hash, input_key = input_key,
                    extra_inputs_key = if extra_key = "" then NONE else SOME extra_key,
                    config_lines = split_items config, deps = deps,
                    symbolic = #symbolic edges, resolved = #resolved edges, external = #external edges}
                 end
             | _ => bad "node")
      | node_line _ = bad "node"
    fun id_field text =
      case String.fields (fn c => c = #"=") text of
          [name, value] => (name, value)
        | _ => bad "plan identity"
    fun entry [""] = ()
      | entry [] = bad "empty entry"
      | entry (first :: rest) =
      if !complete then bad "text after the end marker"
      else
        let val fields = String.extract(first, 1, NONE) :: rest
        in
          case (String.sub(first, 0), fields) of
              (#"F", [value]) => fingerprint := value
            | (#"T", [hol, state, racy, key]) =>
                toolchain := SOME {hol = parse_stamp hol, state = parse_stamp state,
                                   racy = parse_bool racy, key = key}
            | (#"A", [value]) => action_key := value
            | (#"I", values) => ids := map id_field values
            | (#"G", [values]) => targets := split_items values
            | (#"R", [values]) => roots := map parse_int (split_items values)
            | (#"P", [name, root]) => packages := (name, root) :: !packages
            | (#"M", [path, kind]) => members := (path, kind) :: !members
            | (#"D", [path, st, racy, entries]) =>
                dirs := {path = path, stamp = parse_stamp st, racy = parse_bool racy,
                         entries = split_items entries} :: !dirs
            | (#"f", [path, st, racy, hash]) =>
                files := {path = path, stamp = parse_stamp st, racy = parse_bool racy, hash = hash} :: !files
            | (#"d", [path, st, racy]) =>
                input_dirs := {path = path, stamp = parse_stamp st, racy = parse_bool racy} :: !input_dirs
            | (#"X", [base, decl, xfiles, xdirs]) =>
                expansions := {base = base, decl = decl,
                               files = map (fn item => case split_parts item of
                                                           [rel, abs] => (rel, abs)
                                                         | _ => bad "expanded input") (split_items xfiles),
                               dirs = split_items xdirs} :: !expansions
            | (#"S", fields) => sources := source_line fields :: !sources
            | (#"N", fields) => selected := node_line fields :: !selected
            | (#"E", [""]) => complete := true
            | (tag, _) => bad ("entry " ^ str tag)
        end
    val _ = List.app entry (tl lines)
    val _ = if !complete then () else bad "truncated"
    fun id name = case List.find (fn (n, _) => n = name) (!ids) of
                      SOME (_, value) => value
                    | NONE => bad ("missing " ^ name)
  in
    {fingerprint = !fingerprint,
     toolchain = (case !toolchain of SOME value => value | NONE => bad "missing toolchain"),
     action_toolchain_key = !action_key,
     packages = rev (!packages), members = rev (!members), dirs = rev (!dirs), files = rev (!files),
     input_dirs = rev (!input_dirs), expansions = rev (!expansions), sources = rev (!sources),
     roots = !roots, selected = rev (!selected), targets = !targets,
     ids = {resolution_context_id = id "resolution_context_id", selected_graph_id = id "selected_graph_id",
            selected_plan_id = id "selected_plan_id", resolved_plan_id = id "resolved_plan_id"}}
  end
  handle Subscript => bad "short entry"

(* ---- Fingerprint ---- *)

fun read_optional path = SOME (read_text path) handle IO.Io _ => NONE

(* HOL and the packages inside it, which the toolchain's stamp covers. *)
fun is_hol_package package =
  case HolbuildPackageProvenance.snapshot (HolbuildProject.package_provenance package) of
      HolbuildPackageProvenance.ToolchainSnapshot _ => true
    | _ => false

(* A git dependency holbuild checked out at its pinned revision: the record
   keeps the files planning read there, but not what its directories hold. *)
fun is_pinned_git_package package =
  let val provenance = HolbuildProject.package_provenance package
  in
    case (HolbuildPackageProvenance.snapshot provenance, HolbuildPackageProvenance.retrieval provenance) of
        (HolbuildPackageProvenance.GitSnapshot _, HolbuildPackageProvenance.DeclaredGitRetrieval _) => true
      | (HolbuildPackageProvenance.GitSnapshot _, HolbuildPackageProvenance.AlternateGitRetrieval _) => true
      | _ => false
  end

fun recorded_env_var entry =
  String.isPrefix "HOLBUILD_" entry andalso
  not (String.isPrefix "HOLBUILD_TIMING_" entry) andalso
  not (String.isPrefix "HOLBUILD_PLAN_RECORD=" entry)

(* An argument naming a file names it through any links it follows, which
   no recorded stat covers. *)
fun argument_text arg =
  let val real = OS.FileSys.realPath arg handle OS.SysErr _ => arg
  in if real = arg then arg else arg ^ "\001" ^ real end

(* Every planning input that is not a scanned file.  Packages are named by
   their resolved roots and identities, after $VAR expansion, and by their
   manifests' text. *)
fun fingerprint {project : HolbuildProject.t, graph, holdir, kernel_variant} =
  let
    fun package_text package =
      [HolbuildProject.package_name package, HolbuildProject.package_root package,
       HolbuildProject.package_artifact_root package, HolbuildProject.package_manifest package,
       HolbuildProject.package_identity package,
       HolbuildPackageDefinition.canonical_id (HolbuildProject.package_definition_of package),
       String.concatWith "\002" (HolbuildProject.package_members package),
       String.concatWith "\002" (HolbuildProject.package_excludes package),
       String.concatWith "\002" (HolbuildProject.package_exclude_globs package),
       getOpt (read_optional (HolbuildProject.package_manifest package), "\001")]
  in
    HolbuildHash.string_sha256
      (BP.canonical_fields
        ([format, HolbuildVersion.version, OS.FileSys.getDir (), holdir,
          HolbuildHolToolchainConfig.kernel_variant_name kernel_variant,
          getOpt (read_optional (OS.Path.concat (#root project, ".holconfig.toml")), "\001")] @
         BP.canonical_list "argv" (map argument_text (CommandLine.arguments ())) @
         BP.canonical_list "env" (BP.sort_strings (List.filter recorded_env_var (Posix.ProcEnv.environ ()))) @
         List.concat (map (fn package => BP.canonical_list "package" (package_text package))
                          (HolbuildProjectGraph.packages graph))))
  end

(* ---- Members ---- *)

(* Whether each member of each package is a directory, a file or missing,
   taken before discovery reads them. *)
fun member_kinds graph =
  let
    fun kind path =
      if (OS.FileSys.isDir path handle OS.SysErr _ => false) then "d"
      else if (OS.FileSys.access(path, [OS.FileSys.A_READ]) handle OS.SysErr _ => false) then "f"
      else "n"
    fun members package =
      map (fn member => let val path = HolbuildProject.abs_under (HolbuildProject.package_root package) member
                        in (path, kind path) end)
        (HolbuildProject.package_members package)
  in
    List.concat (map members (List.filter (not o is_hol_package) (HolbuildProjectGraph.packages graph)))
  end

(* ---- Writing ---- *)

fun under root path = path = root orelse String.isPrefix (root ^ "/") path

(* What the plan record keeps beyond the plan itself. *)
type context =
  {fingerprint : string,
   start_ns : LargeInt.int,
   toolchain : {hol : string, state : string, key : string},
   action_toolchain_key : string,
   graph : HolbuildProjectGraph.t,
   members : (string * string) list,
   dirs : (string * stamp option * string list) list,
   stamps : (string, stamp) Binarymap.dict,
   index : SI.source list,
   targets : string list}

fun write_record path text =
  (HolbuildDependencies.ensure_dir (OS.Path.dir path);
   SC.write_text_atomically path text)

fun prune_records dir =
  let
    fun records () =
      let val stream = OS.FileSys.openDir dir
          fun loop acc =
            case OS.FileSys.readDir stream of
                NONE => acc
              | SOME name =>
                  if String.isSuffix ".tmp" name orelse String.isPrefix "." name then loop acc
                  else loop (OS.Path.concat(dir, name) :: acc)
      in loop [] before OS.FileSys.closeDir stream end
    val dated = List.mapPartial (fn path => SOME (OS.FileSys.modTime path, path) handle OS.SysErr _ => NONE) (records ())
    val newest_first = HolbuildBuildPlan.sort_pairs (fn ((a, _), (b, _)) => Time.compare(b, a)) dated
    fun drop (n, entries) = if n <= 0 then entries else case entries of [] => [] | _ :: rest => drop (n - 1, rest)
  in
    List.app (fn (_, path) => OS.FileSys.remove path handle OS.SysErr _ => ()) (drop (kept_records, newest_first))
  end
  handle OS.SysErr _ => ()

datatype write_outcome = Written | NotWritten of string

(* The record of PLAN and its KEYS. *)
fun build ({fingerprint, start_ns, toolchain, action_toolchain_key, graph, members, dirs,
            stamps, index, targets} : context) plan keys : t =
  let
    val packages = HolbuildProjectGraph.packages graph
    val hol_roots = map HolbuildProject.package_root (List.filter is_hol_package packages)
    fun in_hol path = List.exists (fn root => under root path) hol_roots
    val pinned_roots = map HolbuildProject.package_root (List.filter is_pinned_git_package packages)
    fun in_pinned path = List.exists (fn root => under root path) pinned_roots
    val package_names = map HolbuildProject.package_name packages
    val package_ids =
      List.foldl (fn ((i, name), map) => Binarymap.insert(map, name, i)) (Binarymap.mkDict String.compare)
        (ListPair.zip (List.tabulate (length package_names, fn i => i), package_names))
    fun package_index name =
      case Binarymap.peek(package_ids, name) of
          SOME i => i
        | NONE => raise Error ("source of unknown package " ^ name)
    val positions =
      #2 (List.foldl (fn (source : SI.source, (i, map)) =>
                        (i + 1, Binarymap.insert(map, #package source ^ "\000" ^ #relative_path source ^ "\000" ^ #logical_name source, i)))
                     (0, Binarymap.mkDict String.compare) index)
    fun position_of_key key =
      case Binarymap.peek(positions, key) of
          SOME i => i
        | NONE => raise Error ("planned node missing from the discovered sources: " ^ String.toString key)
    fun position node = position_of_key (BP.key node)
    fun stamp_of path =
      case Binarymap.peek(stamps, path) of
          SOME st => st
        | NONE => (case stamp path of
                       SOME st => st
                     | NONE => raise Unrecordable ("cannot stat " ^ path))
    val racy = racy_at start_ns
    val selected = BP.selected_nodes plan
    fun source_entry (source : SI.source) =
      {package = package_index (#package source), kind = #kind source, logical_name = #logical_name source,
       relative_path = #relative_path source, source_path = #source_path source}
    fun node_entry node =
      let
        val known =
          case BP.known_input_key plan node of
              SOME known => known
            | NONE => raise Error ("no input key for " ^ BP.logical_name node)
        val _ = if #input_key known = BP.input_key_for keys node then ()
                else raise Error ("stale input key for " ^ BP.logical_name node)
      in
        {source = position node, hash = BP.source_hash plan node, deps = BP.dependencies plan node,
         symbolic = map (fn BP.SymbolicDependency {name, reason, ...} => (name, reason))
                      (BP.symbolic_dependencies plan node),
         resolved = map (fn {to_node, symbolic_name, reason, ...} => (position_of_key to_node, symbolic_name, reason))
                      (BP.resolved_dependency_edges plan node),
         external = map (fn {name, kind, reason, ...} => (name, kind, reason)) (BP.external_dependencies plan node),
         config_lines = #config_lines known, input_key = #input_key known,
         extra_inputs_key = #extra_inputs_key known}
      end
    val source_files =
      List.mapPartial
        (fn node =>
           let val path = #source_path (BP.source_of node)
           in if in_hol path then NONE else SOME (path, BP.source_hash plan node) end)
        selected
    val expansions = BP.input_expansions plan
    val input_files = BP.input_hashes plan
    val file_hashes =
      List.foldl (fn ((path, hash), map) => Binarymap.insert(map, path, hash))
        (Binarymap.mkDict String.compare) (source_files @ input_files)
    val file_entries =
      map (fn (path, hash) => let val st = stamp_of path
                              in {path = path, stamp = st, racy = racy st, hash = hash} end)
        (Binarymap.listItems file_hashes)
    val input_dir_entries =
      map (fn path => let val st = stamp_of path in {path = path, stamp = st, racy = racy st} end)
        (SI.sort_unique_strings (List.concat (map (fn (_, _, {dirs, ...}) => dirs) expansions)))
    val dir_entries =
      List.mapPartial
        (fn (path, SOME st, entries) =>
              if in_hol path orelse in_pinned path then NONE
              else SOME {path = path, stamp = st, racy = racy st, entries = entries}
          | (path, NONE, _) => raise Unrecordable ("cannot stat " ^ path))
        dirs
    val hol_stamp = stamp_of (#hol toolchain)
    val state_stamp = stamp_of (#state toolchain)
  in
    {fingerprint = fingerprint,
     toolchain = {hol = hol_stamp, state = state_stamp,
                  racy = racy hol_stamp orelse racy state_stamp, key = #key toolchain},
     action_toolchain_key = action_toolchain_key,
     packages = map (fn package => (HolbuildProject.package_name package, HolbuildProject.package_root package)) packages,
     members = members,
     dirs = dir_entries,
     files = file_entries,
     input_dirs = input_dir_entries,
     expansions = map (fn (base, decl, {files, dirs}) => {base = base, decl = decl, files = files, dirs = dirs}) expansions,
     sources = map source_entry index,
     roots = map position (BP.root_nodes plan),
     selected = map node_entry selected,
     targets = targets,
     ids = {resolution_context_id = BP.resolution_context_id plan,
            selected_graph_id = BP.selected_graph_id plan,
            selected_plan_id = BP.selected_plan_id plan,
            resolved_plan_id = BP.resolved_plan_id plan}}
  end

(* Writes the record of PLAN and its KEYS into DIR, or says why not. *)
fun write dir context plan keys =
  let val record = build context plan keys
  in
    write_record (OS.Path.concat (dir, #fingerprint record)) (encode record);
    prune_records dir;
    Written
  end
  handle Unencodable text => NotWritten ("a path or name holds a control character: " ^ String.toString text)
       | IO.Io {name, cause, ...} => NotWritten ("cannot write " ^ name ^ ": " ^ General.exnMessage cause)
       | OS.SysErr (msg, _) => NotWritten ("cannot write the record: " ^ msg)
       | Irregular => NotWritten "dependency edges out of their usual order"
       | Unrecordable reason => NotWritten reason

(* ---- Reading ---- *)

datatype check =
    Restored of {index : SI.source list, targets : string list, plan : BP.t,
                 toolchain_key : string, changed : bool, record : t,
                 stamps : (string, stamp) Binarymap.dict, rehashed : int}
  | Fallback of string

fun same_stamp (a, b) = SC.same_ident (a, b)

exception Fall of string
fun fall reason = raise Fall reason

fun load dir fingerprint =
  case read_optional (OS.Path.concat (dir, fingerprint)) of
      NONE => fall "no plan record for these inputs"
    | SOME text =>
        (decode text handle Error msg => fall msg)

fun configure_analyser ({holdir, ...} : HolbuildToolchain.t) =
  if holdir = "" then HolbuildDependencies.clear_analyser_path ()
  else HolbuildDependencies.set_analyser_path (HolbuildHolSharedCache.analyser_path_for_holdir holdir)

(* Check RECORD against the files it names and rebuild the plan from it, or
   say why planning must start over. *)
fun restore {dir, graph, tc : HolbuildToolchain.t, fingerprint, start_ns} =
  let
    val record = load dir fingerprint
    val _ = if #fingerprint record = fingerprint then () else fall "plan record names other inputs"
    val packages = HolbuildProjectGraph.packages graph
    val _ = if List.exists (not o null o HolbuildProject.package_generators) packages
            then fall "the project has generators" else ()
    val _ = if map (fn package => (HolbuildProject.package_name package, HolbuildProject.package_root package)) packages =
               #packages record then ()
            else fall "packages changed"
    val changed = ref false
    val stamps = ref (Binarymap.mkDict String.compare)
    fun note_stamp path st = stamps := Binarymap.insert(!stamps, path, st)
    (* Toolchain *)
    val {hol, state, racy, key} = #toolchain record
    val hol_path = HolbuildToolchain.hol tc
    val state_path = HolbuildToolchain.base_state tc
    val toolchain_key =
      case (stamp hol_path, stamp state_path) of
          (SOME h, SOME s) =>
            (note_stamp hol_path h; note_stamp state_path s;
             if not racy andalso same_stamp (h, hol) andalso same_stamp (s, state) then key
             else (changed := true; HolbuildToolchain.toolchain_key tc))
        | _ => fall "the toolchain is missing"
    (* Members and directories *)
    val _ = if member_kinds graph = #members record then () else fall "a package member appeared or vanished"
    (* The directories whose stat held, whose entries' readability is
       checked once the files' stamps are known. *)
    fun check_dir ({path, stamp = recorded, racy, entries} : dir, held) =
      case stamp path of
          NONE => fall ("directory vanished: " ^ path)
        | SOME st =>
            (note_stamp path st;
             if not racy andalso same_stamp (st, recorded) then (path, entries) :: held
             else
               (changed := true;
                if (SI.classified_entries path handle SI.Error _ => fall ("cannot list " ^ path)) = entries then held
                else fall ("sources added, removed or renamed in " ^ path)))
    val held_dirs = List.foldl check_dir [] (#dirs record)
    (* Files: the recorded hash while the stat holds, else a fresh one. *)
    val rehashed = ref 0
    val hashes =
      List.foldl
        (fn ({path, stamp = recorded, racy, hash} : file, map) =>
           case stamp path of
               NONE => fall ("file vanished: " ^ path)
             | SOME st =>
                 (note_stamp path st;
                  if not racy andalso same_stamp (st, recorded) then Binarymap.insert(map, path, hash)
                  else
                    (changed := true;
                     rehashed := !rehashed + 1;
                     Binarymap.insert(map, path, HolbuildHash.file_sha256 path
                                                   handle _ => fall ("cannot read " ^ path)))))
        (Binarymap.mkDict String.compare) (#files record)
    fun hash_of path = Binarymap.peek(hashes, path)
    (* A change of mode moves only the entry's own stat, which the record
       keeps for selected sources alone. *)
    val _ =
      List.app
        (fn (path, entries) =>
           List.app
             (fn entry =>
                 let val entry_path = SI.join path (SI.entry_name entry)
                 in
                   if SI.unreadable_entry entry then
                     (if SI.is_readable entry_path then fall ("an unreadable entry became readable in " ^ path) else ())
                   else if String.isPrefix "f" entry andalso not (Option.isSome (hash_of entry_path)) andalso
                           not (SI.is_readable entry_path)
                   then fall ("a source became unreadable in " ^ path)
                   else ()
                 end)
             entries)
        held_dirs
    (* Extra-input directories that moved are expanded again. *)
    val moved_input_dirs =
      List.foldl
        (fn ({path, stamp = recorded, racy} : stamped_dir, set) =>
           case stamp path of
               SOME st => (note_stamp path st;
                           if not racy andalso same_stamp (st, recorded) then set
                           else (changed := true; Binarymap.insert(set, path, ())))
             | NONE => (changed := true; Binarymap.insert(set, path, ())))
        (Binarymap.mkDict String.compare) (#input_dirs record)
    fun dir_moved path = Option.isSome (Binarymap.peek(moved_input_dirs, path))
    (* Sources *)
    val package_vector = Vector.fromList packages
    val package_ids = Vector.map SI.source_graph_package_id package_vector
    val sources =
      map (fn ({package, kind, logical_name, relative_path, source_path} : source_entry) =>
             SI.restore_source (Vector.sub(package_vector, package)) (Vector.sub(package_ids, package))
               {kind = kind, logical_name = logical_name, source_path = source_path, relative_path = relative_path})
        (#sources record)
      handle Subscript => fall "malformed plan record: package index"
    val source_vector = Vector.fromList sources
    fun source_at i = Vector.sub(source_vector, i) handle Subscript => fall "malformed plan record: source index"
    (* Sources whose content moved are analysed again through the .deps cache;
       other facts would change the graph. *)
    val selected = #selected record
    val current_hash =
      map (fn (entry : node_entry) =>
             let val path = #source_path (source_at (#source entry))
             in getOpt (hash_of path, #hash entry) end)
        selected
    val moved =
      List.filter (fn (entry : node_entry, hash) => hash <> #hash entry) (ListPair.zip (selected, current_hash))
    val requests =
      map (fn (entry : node_entry, hash) =>
             let val source = source_at (#source entry)
             in {cache_path = BP.dependency_cache_path source, source_path = #source_path source, source_hash = hash} end)
        moved
    val _ = configure_analyser tc
    val facts = HolbuildDependencies.prefetch_cached_with_hash requests
    val _ =
      ListPair.app
        (fn ((entry : node_entry, _), SOME deps) =>
              if deps = #deps entry then ()
              else fall ("dependencies of " ^ #logical_name (source_at (#source entry)) ^ " changed")
          | ((entry, _), NONE) => fall ("cannot analyse " ^ #source_path (source_at (#source entry))))
        (moved, facts)
    val analysis =
      HolbuildComponentProvider.restored_analysis_state (HolbuildPackagePrepare.prepare graph)
        (ListPair.map (fn (entry : node_entry, hash) => (source_at (#source entry), hash, #deps entry))
                      (selected, current_hash))
    val ids = #ids record
    val plan =
      BP.restore {holdir = #holdir tc, sources = sources, roots = #roots record,
                  selected = map #source selected, analysis = analysis,
                  edges = map (fn ({symbolic, resolved, external, ...} : node_entry) =>
                                 {symbolic = symbolic, resolved = resolved, external = external}) selected,
                  resolution_context_id = #resolution_context_id ids, selected_graph_id = #selected_graph_id ids,
                  selected_plan_id = #selected_plan_id ids, resolved_plan_id = #resolved_plan_id ids}
      handle Subscript => fall "malformed plan record: node index"
    (* Extra inputs: an expansion whose directories moved is redone; file
       hashes come from the check above. *)
    val _ =
      List.app
        (fn ({base, decl, files, dirs} : expansion) =>
           if List.exists dir_moved dirs then ()
           else BP.remember_input_expansion plan base decl {files = files, dirs = dirs})
        (#expansions record)
    val _ = Binarymap.app (fn (path, hash) => BP.remember_input_hash plan path hash) hashes
    (* Input keys: a node keeps its recorded key while its source hash, its
       inputs and its dependencies' keys are unchanged. *)
    (* A node's project dependencies are its resolved targets, first
       appearance first, as BP.direct_project_deps lists them. *)
    val recorded_key_at = Array.array(Vector.length source_vector, "")
    val _ = List.app (fn (entry : node_entry) => Array.update(recorded_key_at, #source entry, #input_key entry)) selected
    fun recorded_dep_keys (entry : node_entry) =
      let
        fun add ((target, _, _), (seen, keys)) =
          if Option.isSome (Binarymap.peek(seen, target)) then (seen, keys)
          else (Binarymap.insert(seen, target, ()), Array.sub(recorded_key_at, target) :: keys)
      in
        rev (#2 (List.foldl add (Binarymap.mkDict Int.compare, []) (#resolved entry)))
      end
      handle Subscript => fall "malformed plan record: node index"
    val recorded_hashes =
      List.foldl (fn ({path, hash, ...} : file, map) => Binarymap.insert(map, path, hash))
        (Binarymap.mkDict String.compare) (#files record)
    val recorded_expansions =
      List.foldl (fn (expansion as {base, decl, ...} : expansion, map) =>
                    Binarymap.insert(map, base ^ "\000" ^ decl, expansion))
        (Binarymap.mkDict String.compare) (#expansions record)
    fun file_unchanged (_, abs) =
      case (hash_of abs, Binarymap.peek(recorded_hashes, abs)) of
          (SOME now, SOME recorded) => now = recorded
        | _ => false
    fun inputs_unchanged node =
      List.all
        (fn (_, base, decl) =>
           case Binarymap.peek(recorded_expansions, base ^ "\000" ^ decl) of
               NONE => false
             | SOME {files, dirs, ...} => not (List.exists dir_moved dirs) andalso List.all file_unchanged files)
        (BP.extra_input_decls plan node)
    val _ =
      ListPair.app
        (fn (node, (entry : node_entry, hash)) =>
           if hash <> #hash entry orelse not (inputs_unchanged node) then ()
           else
             BP.remember_input_key plan node
               {toolchain_key = #action_toolchain_key record, config_lines = #config_lines entry,
                dep_keys = recorded_dep_keys entry,
                input_key = #input_key entry, extra_inputs_key = #extra_inputs_key entry})
        (BP.selected_nodes plan, ListPair.zip (selected, current_hash))
  in
    Restored {index = sources, targets = #targets record, plan = plan, toolchain_key = toolchain_key,
              changed = !changed, record = record, stamps = !stamps, rehashed = !rehashed}
  end
  handle Fall reason => Fallback reason


(* How many of the plan's keys differ from those the record kept. *)
fun changed_keys (record : t) plan keys =
  ListPair.foldl
    (fn (node, entry : node_entry, n) => if BP.input_key_for keys node = #input_key entry then n else n + 1)
    0 (BP.selected_nodes plan, #selected record)

(* ---- Check mode ---- *)

(* A source as the plan reads it; restored sources keep no node identities
   or canonical artifacts (SI.restore_source). *)
fun source_text (source : SI.source) =
  let
    val node = #node source
    fun artifacts ({generated, objects, theory_data} : SI.artifacts) =
      String.concatWith "," (generated @ ["|"] @ objects @ ["|"] @ theory_data)
  in
    String.concatWith " "
      [#package source, #package_root source, SI.kind_string (#kind source), #logical_name source,
       #source_path source, #relative_path source, artifacts (#artifacts source),
       #package_id node, #relative_path node, #logical_name node, SI.kind_string (#kind node),
       SI.origin_tag (#origin node), SI.policy_render (#policy node), SI.execution_policy_render (#policy node),
       SI.policy_render (#policy source)]
  end

fun deps_text ({loads, uses, extra_deps, extra_outputs, holdep_mentions} : HolbuildDependencies.t) =
  String.concatWith " | " (map (String.concatWith ",") [loads, uses, extra_deps, extra_outputs, holdep_mentions])

(* Everything a planned build reads, one fact per line, in order. *)
fun plan_lines ({index, targets, plan, ...} : {index : SI.source list, targets : string list,
                                               entry_plan : BP.t option, plan : BP.t,
                                               toolchain_key : string, components : 'a option}, keys) =
  let
    fun node_lines node =
      let
        val name = BP.package node ^ ":" ^ BP.relative_path node
        fun tagged tag values = map (fn value => name ^ " " ^ tag ^ " " ^ value) values
        fun reason r = BP.dependency_reason_text r
      in
        tagged "source" [source_text (BP.source_of node)] @
        tagged "hash" [BP.source_hash plan node] @
        tagged "facts" [deps_text (BP.dependencies plan node)] @
        tagged "symbolic" (map (fn BP.SymbolicDependency {from_node, name, reason = r} =>
                                  String.toString from_node ^ " " ^ name ^ " " ^ reason r)
                             (BP.symbolic_dependencies plan node)) @
        tagged "resolved" (map (fn {from_node, to_node, symbolic_name, reason = r} =>
                                  String.toString from_node ^ " " ^ String.toString to_node ^ " " ^
                                  symbolic_name ^ " " ^ reason r)
                             (BP.resolved_dependency_edges plan node)) @
        tagged "external" (map (fn {from_node, name, kind, reason = r} =>
                                  String.toString from_node ^ " " ^ name ^ " " ^ external_kind_text kind ^ " " ^ reason r)
                             (BP.external_dependencies plan node)) @
        tagged "unresolved" (map (fn {from_node, name, reason = r} =>
                                    String.toString from_node ^ " " ^ name ^ " " ^ reason r)
                               (BP.unresolved_dependencies plan node)) @
        (* Only the set of incoming edges matters: full planning lists them
           in bootstrap order, which the record does not keep. *)
        tagged "reverse" (BP.sort_strings
                            (map (fn {from_node, to_node, symbolic_name, reason = r} =>
                                    String.toString from_node ^ " " ^ String.toString to_node ^ " " ^
                                    symbolic_name ^ " " ^ reason r)
                                 (BP.reverse_dependency_edges plan node))) @
        tagged "external_theories" [String.concatWith "," (BP.direct_external_theories plan node)] @
        tagged "external_libs" [String.concatWith "," (BP.direct_external_libs plan node)] @
        tagged "extra_inputs_key" [getOpt (BP.extra_inputs_key plan node, "none")] @
        tagged "input_key" [BP.input_key_for keys node]
      end
  in
    ["targets " ^ String.concatWith "," targets] @
    map (fn source => "discovered " ^ source_text source) index @
    map (fn node => "universe " ^ String.toString (BP.key node)) (BP.universe_nodes plan) @
    map (fn node => "root " ^ String.toString (BP.key node)) (BP.root_nodes plan) @
    map (fn node => "selected " ^ String.toString (BP.key node)) (BP.selected_nodes plan) @
    ["resolution_context_id " ^ BP.resolution_context_id plan,
     "selected_graph_id " ^ BP.selected_graph_id plan,
     "selected_plan_id " ^ BP.selected_plan_id plan,
     "resolved_plan_id " ^ BP.resolved_plan_id plan] @
    List.concat (map node_lines (BP.selected_nodes plan))
  end

(* Fails on the first fact the plan from the record and full planning
   disagree on. *)
fun compare ((from_record, record_keys), (from_full, full_keys)) =
  let
    fun first_difference (a :: rest_a, b :: rest_b) =
          if a = b then first_difference (rest_a, rest_b) else SOME (a, b)
      | first_difference ([], []) = NONE
      | first_difference (a :: _, []) = SOME (a, "(nothing)")
      | first_difference ([], b :: _) = SOME ("(nothing)", b)
  in
    case first_difference (plan_lines (from_record, record_keys), plan_lines (from_full, full_keys)) of
        NONE => ()
      | SOME (recorded, planned) =>
          raise Error ("plan record check failed: the plan from the record has\n  " ^ recorded ^
                       "\nwhere full planning has\n  " ^ planned)
  end

end
