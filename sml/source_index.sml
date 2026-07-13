structure HolbuildSourceIndex =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string
exception ErrorWithDebugArtifacts of string * HolbuildStatus.debug_artifacts

datatype kind = TheoryScript | Sml | Sig

type artifacts =
  { generated : string list,
    objects : string list,
    theory_data : string list }

type source =
  { package : string,
    kind : kind,
    logical_name : string,
    source_path : string,
    relative_path : string,
    artifacts : artifacts,
    policy : HolbuildProject.action_policy }

type t = source list

fun has_suffix suffix s =
  let
    val n = size s
    val m = size suffix
  in
    n >= m andalso String.substring(s, n - m, m) = suffix
  end

fun drop_suffix suffix s =
  if has_suffix suffix s then String.substring(s, 0, size s - size suffix)
  else raise Error ("expected suffix " ^ suffix ^ " in " ^ s)

fun join root rel = if rel = "" then root else Path.concat(root, rel)

fun normalize_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun relative_path root path =
  let
    val root = normalize_path root
    val path = normalize_path path
    val root' = if has_suffix "/" root then root else root ^ "/"
  in
    if String.isPrefix root' path then String.extract(path, size root', NONE)
    else path
  end

fun dirname rel = #dir (Path.splitDirFile rel)
fun filename rel = #file (Path.splitDirFile rel)

fun obj_path artifact_root rel ext =
  let val {base, ...} = Path.splitBaseExt rel
  in join artifact_root (join "obj" (base ^ ext)) end

fun theory_obj_path artifact_root rel name ext = join artifact_root (join "obj" (join (dirname rel) (name ^ ext)))
fun dat_path root rel name = theory_obj_path root rel name ".dat"

fun theory_artifacts root rel theory =
  { generated = [theory_obj_path root rel theory ".sig",
                 theory_obj_path root rel theory ".sml"],
    objects = [obj_path root rel ".uo", theory_obj_path root rel theory ".ui",
               theory_obj_path root rel theory ".uo"],
    theory_data = [dat_path root rel theory] }

fun sml_artifacts root rel =
  { generated = [], objects = [obj_path root rel ".ui", obj_path root rel ".uo"], theory_data = [] }

fun sig_artifacts root rel =
  { generated = [], objects = [obj_path root rel ".ui"], theory_data = [] }

fun make_source package policies kind logical_name source_path relative_path artifacts =
  {package = package,
   kind = kind,
   logical_name = logical_name,
   source_path = source_path,
   relative_path = relative_path,
   artifacts = artifacts,
   policy = HolbuildProject.action_policy_for policies logical_name}

fun generated_theory_artifact file =
  has_suffix "Theory.sml" file orelse
  has_suffix "Theory.sig" file

fun classify package artifact_root policies abs_path rel =
  let
    val file = filename rel
  in
    if generated_theory_artifact file then NONE
    else if has_suffix "Script.sml" file then
      let
        val theory = drop_suffix "Script.sml" file ^ "Theory"
      in
        SOME (make_source package policies TheoryScript theory abs_path rel
                            (theory_artifacts artifact_root rel theory))
      end
    else if has_suffix ".sml" file then
      let val logical = drop_suffix ".sml" file
      in SOME (make_source package policies Sml logical abs_path rel
                           (sml_artifacts artifact_root rel)) end
    else if has_suffix ".sig" file then
      let val logical = drop_suffix ".sig" file
      in SOME (make_source package policies Sig logical abs_path rel
                           (sig_artifacts artifact_root rel)) end
    else NONE
  end

fun is_dir path = FS.isDir path handle OS.SysErr _ => false
fun is_link path = FS.isLink path handle OS.SysErr _ => false
fun is_readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun glob_match pattern text =
  let
    val pn = size pattern
    val tn = size text
    fun match p t =
      if p = pn then t = tn
      else
        case String.sub(pattern, p) of
            #"*" => match (p + 1) t orelse (t < tn andalso match p (t + 1))
          | #"?" => t < tn andalso match (p + 1) (t + 1)
          | c => t < tn andalso c = String.sub(text, t) andalso match (p + 1) (t + 1)
  in
    match 0 0
  end

fun glob_excluded exclude_globs rel = List.exists (fn pattern => glob_match pattern rel) exclude_globs

fun path_excluded excludes rel =
  List.exists (fn path => rel = path orelse String.isPrefix (path ^ "/") rel) excludes

fun excluded excludes exclude_globs rel = path_excluded excludes rel orelse glob_excluded exclude_globs rel

fun insert_unique_string (value, values) =
  case values of
      [] => [value]
    | x :: xs =>
        (case String.compare(value, x) of
             LESS => value :: values
           | EQUAL => values
           | GREATER => x :: insert_unique_string (value, xs))

fun sort_unique_strings values = List.foldl insert_unique_string [] values

fun unique_strings values =
  let
    fun add (value, (seen, acc)) =
      if List.exists (fn existing => existing = value) seen then (seen, acc)
      else (value :: seen, value :: acc)
    val (_, acc) = List.foldl add ([], []) values
  in
    rev acc
  end

fun skip_dir name = String.isPrefix "." name orelse name = "_build"

fun contains_manifest path =
  FS.access(Path.concat(path, "holproject.toml"), [FS.A_READ])
  handle OS.SysErr _ => false

fun list_dir path =
  let
    val stream = FS.openDir path
      handle OS.SysErr _ => raise Error ("could not read directory: " ^ path)
    fun loop acc =
      case FS.readDir stream of
          NONE => rev acc before FS.closeDir stream
        | SOME name => loop (name :: acc)
  in
    loop [] handle e => (FS.closeDir stream; raise e)
  end

fun list_dir_if_readable path = list_dir path handle Error _ => []

fun scan_file package source_root artifact_root policies excludes exclude_globs path acc =
  let val rel = relative_path source_root path
  in
    if excluded excludes exclude_globs rel then acc
    else case classify package artifact_root policies path rel of
      NONE => acc
    | SOME source => source :: acc
  end

fun scan_dir package source_root artifact_root policies excludes exclude_globs path acc =
  let
    fun scan_name (name, acc) =
      let val path' = join path name
      in
        if is_link path' then acc
        else if is_dir path' then
          if skip_dir name orelse not (is_readable path') orelse contains_manifest path' orelse
             excluded excludes exclude_globs (relative_path source_root path') then acc
          else scan_dir package source_root artifact_root policies excludes exclude_globs path' acc
        else if String.isPrefix "." name then acc
        else if is_readable path' then scan_file package source_root artifact_root policies excludes exclude_globs path' acc
        else acc
      end
  in
    List.foldl scan_name acc (list_dir_if_readable path)
  end

fun compare_source (a : source, b : source) =
  case String.compare(#package a, #package b) of
      EQUAL => String.compare(#relative_path a, #relative_path b)
    | order => order

fun split xs =
  let
    fun loop left right rest =
      case rest of
          [] => (left, right)
        | [x] => (x :: left, right)
        | x :: y :: zs => loop (x :: left) (y :: right) zs
  in
    loop [] [] xs
  end

fun merge compare left right =
  case (left, right) of
      ([], _) => right
    | (_, []) => left
    | (l :: ls, r :: rs) =>
        if compare (l, r) <> GREATER then
          l :: merge compare ls right
        else
          r :: merge compare left rs

fun msort compare xs =
  case xs of
      [] => []
    | [_] => xs
    | _ =>
      let val (left, right) = split xs
      in merge compare (msort compare left) (msort compare right) end

fun compatible_same_name (a : source) (b : source) =
  #package a = #package b andalso
  (case (#kind a, #kind b) of
       (Sml, Sig) => true
     | (Sig, Sml) => true
     | _ => false)

fun by_logical (sources : source list) =
  let
    fun conflicts source other = not (compatible_same_name source other)
    fun insert (source, seen) =
      case Binarymap.peek (seen, #logical_name source) of
          NONE => Binarymap.insert (seen, #logical_name source, [source])
        | SOME same_name =>
          case List.find (conflicts source) same_name of
              NONE => Binarymap.insert (seen, #logical_name source, source :: same_name)
            | SOME other =>
                raise Error ("duplicate logical name " ^ #logical_name source ^ ": " ^
                             #package other ^ ":" ^ #relative_path other ^ " and " ^
                             #package source ^ ":" ^ #relative_path source)
  in
    ignore (List.foldl insert (Binarymap.mkDict String.compare) sources);
    sources
  end

fun dedup_sources sources =
  let
    fun insert (source : source, (seen, acc)) =
      let val path = normalize_path (#source_path source)
      in
        if Redblackset.member (seen, path) then (seen, acc)
        else (Redblackset.add (seen, path), source :: acc)
      end
  in
    #2 (List.foldr insert (Redblackset.empty String.compare, []) sources)
  end

fun sort_sources sources = msort compare_source sources

fun validate_action_policies package_name policies sources =
  let
    fun has_logical logical =
      List.exists
        (fn source => #package source = package_name andalso #logical_name source = logical)
        sources
    fun validate policy =
      let val logical = HolbuildProject.action_policy_logical policy
      in
        if has_logical logical then ()
        else raise Error ("action policy references unknown target " ^
                          package_name ^ ":" ^ logical)
      end
  in
    List.app validate policies
  end

fun scan_member name source_root artifact_root policies excludes exclude_globs (member, acc) =
  if is_dir member then scan_dir name source_root artifact_root policies excludes exclude_globs member acc
  else if is_readable member then scan_file name source_root artifact_root policies excludes exclude_globs member acc
  else raise Error ("member does not exist: " ^ member)

fun discover_package package acc =
  let
    val name = HolbuildProject.package_name package
    val source_root = HolbuildProject.package_root package
    val artifact_root = HolbuildProject.package_artifact_root package
    val policies = HolbuildProject.package_action_policies package
    val excludes = HolbuildProject.package_excludes package
    val exclude_globs = HolbuildProject.package_exclude_globs package
    val _ = HolbuildGenerators.run_package package
            handle HolbuildGenerators.Error msg => raise Error msg
                 | HolbuildGenerators.ErrorWithDebugArtifacts (msg, artifacts) =>
                     raise ErrorWithDebugArtifacts (msg, artifacts)
    val members =
      map (fn member => HolbuildProject.abs_under source_root member)
        (HolbuildProject.package_members package)
    val sources =
      List.foldl
        (scan_member name source_root artifact_root policies excludes exclude_globs)
        acc
        members
    val _ = validate_action_policies name policies sources
  in
    sources
  end

fun discover_with resolution (project : HolbuildProject.t) =
  by_logical
    (sort_sources
       (dedup_sources
          (List.foldl
             (fn (package, acc) => discover_package package acc)
             []
             (HolbuildProject.packages_with resolution project))))

fun discover project = discover_with HolbuildProject.standard_resolution project

fun kind_string kind =
  case kind of
      TheoryScript => "theory"
    | Sml => "sml"
    | Sig => "sig"

fun print_list label values =
  case values of
      [] => ()
    | _ => print ("  " ^ label ^ ": " ^ String.concatWith ", " values ^ "\n")

fun describe_source ({package, kind, logical_name, relative_path,
                      artifacts = {generated, objects, theory_data}, ...} : source) =
  (print (logical_name ^ " (" ^ kind_string kind ^ ", package " ^ package ^ ")\n");
   print ("  source: " ^ package ^ ":" ^ relative_path ^ "\n");
   print_list "generated" generated;
   print_list "objects" objects;
   print_list "theory_data" theory_data)

fun describe sources = List.app describe_source sources

fun select_targets sources targets =
  case targets of
      [] => sources
    | _ =>
      let
        fun source_named target (source : source) = #logical_name source = target
        fun find target =
          case List.filter (source_named target) sources of
              [] => raise Error ("unknown build target: " ^ target)
            | matches => matches
      in
        List.concat (map find targets)
      end

fun root_candidate_paths source_root root =
  let
    val exact = HolbuildProject.abs_under source_root root
    val sml = exact ^ ".sml"
  in
    [relative_path source_root exact, relative_path source_root sml]
  end

fun source_matches_root package (source : source) root =
  #package source = HolbuildProject.package_name package andalso
  List.exists (fn rel => rel = #relative_path source)
    (root_candidate_paths (HolbuildProject.package_root package) root)

fun group_members sources package group =
  let
    val package_name = HolbuildProject.package_name package
    val group_name = HolbuildProject.group_name group
    val includes = HolbuildProject.group_includes group
    val include_globs = HolbuildProject.group_include_globs group
    val excludes = HolbuildProject.group_excludes group
    val exclude_globs = HolbuildProject.group_exclude_globs group
    fun matches paths globs rel = excluded paths globs rel
    fun source_member (source : source) =
      let val rel = #relative_path source
      in
        #package source = package_name andalso
        matches includes include_globs rel andalso
        not (matches excludes exclude_globs rel)
      end
    val members =
      sort_unique_strings
        (map (fn source : source => #logical_name source)
             (List.filter source_member sources))
  in
    case members of
        [] =>
          if HolbuildProject.group_allow_empty group then []
          else raise Error ("group " ^ package_name ^ ":" ^ group_name ^ " matched no sources")
      | _ => members
  end

fun lookup_group package name =
  case List.find (fn group => HolbuildProject.group_name group = name)
                 (HolbuildProject.package_groups package) of
      SOME group => group
    | NONE => raise Error ("unknown group: " ^ HolbuildProject.package_name package ^ ":" ^ name)

fun resolve_group_ref sources package name = group_members sources package (lookup_group package name)

fun group_member_sources sources package name =
  let
    val package_name = HolbuildProject.package_name package
    val members = resolve_group_ref sources package name
    fun source_for_logical logical =
      case List.filter
             (fn source => #package source = package_name andalso
                           #logical_name source = logical)
             sources of
          [] => raise Error ("group member disappeared: " ^ package_name ^ ":" ^ logical)
        | source :: _ => source
  in
    map source_for_logical members
  end

fun group_token_name token =
  let val name = String.extract(token, 1, NONE)
  in
    if HolbuildProject.valid_group_name name then name
    else raise Error ("invalid group reference \"" ^ token ^ "\"")
  end

fun is_group_token token = size token > 0 andalso String.sub(token, 0) = #"@"

fun expand_group_tokens sources package tokens =
  unique_strings
    (List.concat
       (map (fn token =>
               if is_group_token token then resolve_group_ref sources package (group_token_name token)
               else [token])
            tokens))

fun root_for_package sources package root =
  if is_group_token root then resolve_group_ref sources package (group_token_name root)
  else
    case List.filter (fn source => source_matches_root package source root) sources of
        [] => raise Error ("unknown build root: " ^ HolbuildProject.package_name package ^ ":" ^ root)
      | [source] => [#logical_name source]
      | _ => raise Error ("ambiguous build root: " ^ HolbuildProject.package_name package ^ ":" ^ root)

fun source_entry source = (#relative_path source, #logical_name source)

fun root_entries_for_package_root sources package root =
  if is_group_token root then
    map source_entry (group_member_sources sources package (group_token_name root))
  else
    case List.filter (fn source => source_matches_root package source root) sources of
        [] => raise Error ("unknown build root: " ^ HolbuildProject.package_name package ^ ":" ^ root)
      | [source] => [(root, #logical_name source)]
      | _ => raise Error ("ambiguous build root: " ^ HolbuildProject.package_name package ^ ":" ^ root)

fun roots_for_package sources package =
  List.concat (map (root_for_package sources package) (HolbuildProject.package_roots package))

fun root_groups_for_package sources package =
  List.concat (map (resolve_group_ref sources package) (HolbuildProject.package_root_groups package))

fun root_group_entries_for_package sources package =
  List.concat (map (fn group => map source_entry (group_member_sources sources package group))
                   (HolbuildProject.package_root_groups package))

fun declared_root_entries sources package =
  List.concat (map (root_entries_for_package_root sources package)
                   (HolbuildProject.package_roots package)) @
  root_group_entries_for_package sources package

fun default_package_targets sources package =
  roots_for_package sources package @ root_groups_for_package sources package

fun package_has_default_targets package =
  not (null (HolbuildProject.package_roots package)) orelse
  not (null (HolbuildProject.package_root_groups package))

fun default_targets_with resolution sources project =
  unique_strings
    (List.concat
       (map (default_package_targets sources)
            (List.filter package_has_default_targets
              (HolbuildProject.packages_with resolution project))))

fun default_targets sources project =
  default_targets_with HolbuildProject.standard_resolution sources project

fun root_package_targets sources project =
  let val root_name = HolbuildProject.root_package_name project
  in
    map (fn (source : source) => #logical_name source)
      (List.filter (fn (source : source) => #package source = root_name) sources)
  end

end
