structure HolbuildSourceIndex =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string
exception ErrorWithDebugArtifacts of string * HolbuildStatus.debug_artifacts

val implicit_hol_package_name = HolbuildProject.implicit_hol_package_name

fun is_implicit_hol_package package = package = implicit_hol_package_name

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
    artifact_root : string,
    artifacts : artifacts,
    policy : HolbuildProject.action_policy,
    bare : bool,
    holmake_deps : string list }

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

fun read_prefix path max_chars =
  let
    val ins = TextIO.openIn path
    val text = TextIO.inputN (ins, max_chars) before TextIO.closeIn ins
  in text end
  handle _ => ""

fun contains_substring needle haystack =
  let
    val n = size needle
    val h = size haystack
    fun at i = i + n <= h andalso String.substring(haystack, i, n) = needle
    fun loop i = i + n <= h andalso (at i orelse loop (i + 1))
  in n = 0 orelse loop 0 end

fun source_bare_marker path = contains_substring "[bare]" (read_prefix path 2048)

fun make_source package artifact_root policies kind logical_name source_path relative_path artifacts =
  {package = package,
   kind = kind,
   logical_name = logical_name,
   source_path = source_path,
   relative_path = relative_path,
   artifact_root = artifact_root,
   artifacts = artifacts,
   policy = HolbuildProject.action_policy_for policies logical_name,
   bare = source_bare_marker source_path,
   holmake_deps = []}

fun generated_theory_artifact file =
  has_suffix "Theory.sml" file orelse
  has_suffix "Theory.sig" file

fun classify package source_root artifact_root policies abs_path =
  let
    val rel = relative_path source_root abs_path
    val file = filename rel
  in
    if generated_theory_artifact file then NONE
    else if has_suffix "Script.sml" file then
      let
        val theory = drop_suffix "Script.sml" file ^ "Theory"
      in
        if is_implicit_hol_package package andalso HolbuildBootstrap.is_bare_theory theory then NONE
        else SOME (make_source package artifact_root policies TheoryScript theory abs_path rel
                            (theory_artifacts artifact_root rel theory))
      end
    else if has_suffix ".sml" file then
      let val logical = drop_suffix ".sml" file
      in
        if is_implicit_hol_package package andalso HolbuildBootstrap.is_bare_module logical then NONE
        else SOME (make_source package artifact_root policies Sml logical abs_path rel
                           (sml_artifacts artifact_root rel))
      end
    else if has_suffix ".sig" file then
      let val logical = drop_suffix ".sig" file
      in
        if is_implicit_hol_package package andalso HolbuildBootstrap.is_bare_module logical then NONE
        else SOME (make_source package artifact_root policies Sig logical abs_path rel
                           (sig_artifacts artifact_root rel))
      end
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

fun excluded excludes rel = List.exists (fn pattern => glob_match pattern rel) excludes

fun skip_dir name = String.isPrefix "." name orelse name = "_build"

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

fun scan_file package source_root artifact_root policies excludes path acc =
  if excluded excludes (relative_path source_root path) then acc
  else case classify package source_root artifact_root policies path of
      NONE => acc
    | SOME source => source :: acc

fun scan_dir package source_root artifact_root policies excludes path acc =
  let
    fun scan_name (name, acc) =
      let val path' = join path name
      in
        if is_link path' then acc
        else if is_dir path' then
          if skip_dir name orelse not (is_readable path') orelse
             excluded excludes (relative_path source_root path' ^ "/") then acc
          else scan_dir package source_root artifact_root policies excludes path' acc
        else if String.isPrefix "." name then acc
        else if is_readable path' then scan_file package source_root artifact_root policies excludes path' acc
        else acc
      end
  in
    List.foldl scan_name acc (list_dir_if_readable path)
  end

fun compare_source (a : source, b : source) =
  case String.compare(#package a, #package b) of
      EQUAL => String.compare(#relative_path a, #relative_path b)
    | order => order

fun compare_logical (a : source, b : source) =
  case String.compare(#logical_name a, #logical_name b) of
      EQUAL => compare_source(a, b)
    | order => order

fun compare_source_path (a : source, b : source) =
  case String.compare(normalize_path (#source_path a), normalize_path (#source_path b)) of
      EQUAL => compare_source(a, b)
    | order => order

fun compatible_same_name sources =
  case sources of
      [a, b] =>
        #package a = #package b andalso
        ((#kind a = Sml andalso #kind b = Sig) orelse
         (#kind a = Sig andalso #kind b = Sml))
    | _ => false

fun duplicate_logical_error logical sources =
  raise Error ("duplicate logical name " ^ logical ^ ": " ^
               String.concatWith " and "
                 (map (fn source => #package source ^ ":" ^ #relative_path source) sources))

fun validate_logical_uniqueness sources =
  let
    fun finish_group logical group =
      case group of
          [] => ()
        | [_] => ()
        | _ => if compatible_same_name group then () else duplicate_logical_error logical (rev group)
    fun loop current group rest =
      case rest of
          [] => finish_group current group
        | source :: sources' =>
            if #logical_name source = current then loop current (source :: group) sources'
            else (finish_group current group; loop (#logical_name source) [source] sources')
  in
    case sources of
        [] => ()
      | source :: rest => loop (#logical_name source) [source] rest
  end

fun split_sources sources =
  let
    fun loop left right rest =
      case rest of
          [] => (left, right)
        | [x] => (x :: left, right)
        | x :: y :: xs => loop (x :: left) (y :: right) xs
  in
    loop [] [] sources
  end

fun merge_sources compare left right =
  case (left, right) of
      ([], _) => right
    | (_, []) => left
    | (x :: xs, y :: ys) =>
        if compare(x, y) = GREATER then y :: merge_sources compare left ys
        else x :: merge_sources compare xs right

fun sort_by compare sources =
  case sources of
      [] => []
    | [_] => sources
    | _ =>
        let val (left, right) = split_sources sources
        in merge_sources compare (sort_by compare left) (sort_by compare right) end

fun sort_sources sources = sort_by compare_source sources

fun with_holmake_deps deps (source : source) =
  {package = #package source,
   kind = #kind source,
   logical_name = #logical_name source,
   source_path = #source_path source,
   relative_path = #relative_path source,
   artifact_root = #artifact_root source,
   artifacts = #artifacts source,
   policy = #policy source,
   bare = #bare source,
   holmake_deps = deps}

fun validate_unique_source_paths sources =
  let
    fun source_id source = normalize_path (#source_path source)
    fun duplicate_error path group =
      raise Error ("source path appears in multiple package members: " ^ path ^ " as " ^
                   String.concatWith " and "
                     (map (fn source => #package source ^ ":" ^ #relative_path source) (rev group)))
    fun finish path group =
      case group of
          [] => ()
        | [_] => ()
        | _ => duplicate_error path group
    fun loop current group rest =
      case rest of
          [] => finish current group
        | source :: sources' =>
            let val path = source_id source
            in
              if path = current then loop current (source :: group) sources'
              else (finish current group; loop path [source] sources')
            end
  in
    case sources of
        [] => ()
      | source :: rest => loop (source_id source) [source] rest
  end

fun by_logical sources =
  let val logical_sorted = sort_by compare_logical sources
  in validate_logical_uniqueness logical_sorted; sources end

fun by_source_path sources =
  let val path_sorted = sort_by compare_source_path sources
  in validate_unique_source_paths path_sorted; sources end

fun validate_action_policies package_name policies sources =
  if is_implicit_hol_package package_name then () else
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

fun scan_member name source_root artifact_root policies excludes (member, acc) =
  if is_dir member then scan_dir name source_root artifact_root policies excludes member acc
  else if is_readable member then scan_file name source_root artifact_root policies excludes member acc
  else if is_implicit_hol_package name then acc
  else raise Error ("member does not exist: " ^ member)

fun strip_object_suffix file =
  if has_suffix ".uo" file then SOME (drop_suffix ".uo" file)
  else if has_suffix ".ui" file then SOME (drop_suffix ".ui" file)
  else NONE

fun source_target_name (source : source) =
  case #kind source of
      Sig => #logical_name source ^ ".ui"
    | _ => #logical_name source ^ ".uo"

fun source_dir (source : source) = Path.dir (#source_path source)

fun same_dir a b = normalize_path a = normalize_path b

fun source_logical_in_package package_name sources logical =
  List.exists (fn source => #package source = package_name andalso #logical_name source = logical) sources

fun dep_logical dep = strip_object_suffix (filename dep)

fun holmake_rule_info holmakefile =
  let
    val dir = Path.dir holmakefile
    val old = FS.getDir ()
    fun restore () = FS.chDir old handle OS.SysErr _ => ()
    fun die msg = raise Error msg
    fun parse () =
      ReadHMF.diagread {warn = fn _ => (), info = fn _ => (), die = die}
                       holmakefile (Holmake_types.base_environment ())
  in
    (FS.chDir dir;
     parse () before restore ())
    handle e =>
      (restore ();
       raise Error ("could not read HOL Holmakefile dependency metadata from " ^
                    holmakefile ^ ": " ^ General.exnMessage e))
  end

fun holmake_deps_for_source sources source =
  let
    val hmf = Path.concat(source_dir source, "Holmakefile")
  in
    if not (is_implicit_hol_package (#package source)) orelse not (is_readable hmf) then []
    else
      let val (env, ruledb, _) = holmake_rule_info hmf
      in
        case Holmake_types.get_rule_info ruledb env (source_target_name source) of
            NONE => []
          | SOME {dependencies, ...} =>
              sort_by String.compare
                (List.mapPartial
                   (fn dep =>
                       case dep_logical dep of
                           NONE => NONE
                         | SOME logical =>
                             if logical = #logical_name source then NONE
                             else if source_logical_in_package (#package source) sources logical then SOME logical
                             else NONE)
                   dependencies)
      end
  end

fun add_holmake_deps sources =
  map (fn source => with_holmake_deps (holmake_deps_for_source sources source) source) sources

fun discover_package package acc =
  let
    val name = HolbuildProject.package_name package
    val source_root = HolbuildProject.package_root package
    val artifact_root = HolbuildProject.package_artifact_root package
    val policies = HolbuildProject.package_action_policies package
    val excludes = HolbuildProject.package_excludes package
    val _ = HolbuildGenerators.run_package package
            handle HolbuildGenerators.Error msg => raise Error msg
                 | HolbuildGenerators.ErrorWithDebugArtifacts (msg, artifacts) =>
                     raise ErrorWithDebugArtifacts (msg, artifacts)
    val members =
      map (fn member => HolbuildProject.abs_under source_root member)
        (HolbuildProject.package_members package)
    val package_sources =
      List.foldl
        (scan_member name source_root artifact_root policies excludes)
        []
        members
    val _ = validate_action_policies name policies package_sources
  in
    package_sources @ acc
  end

fun discover (project : HolbuildProject.t) =
  let
    val sources =
      sort_sources
        (List.foldl
           (fn (package, acc) => discover_package package acc)
           []
           (HolbuildProject.packages project))
    val _ = by_source_path sources
    val _ = by_logical sources
  in
    add_holmake_deps sources
  end

fun kind_string kind =
  case kind of
      TheoryScript => "theory"
    | Sml => "sml"
    | Sig => "sig"

fun print_list label values =
  case values of
      [] => ()
    | _ => print ("  " ^ label ^ ": " ^ String.concatWith ", " values ^ "\n")

fun describe_source ({package, kind, logical_name, relative_path, bare, holmake_deps,
                      artifacts = {generated, objects, theory_data}, ...} : source) =
  (print (logical_name ^ " (" ^ kind_string kind ^ ", package " ^ package ^ ")\n");
   print ("  source: " ^ package ^ ":" ^ relative_path ^ "\n");
   if bare then print "  bare: true\n" else ();
   print_list "generated" generated;
   print_list "objects" objects;
   print_list "theory_data" theory_data;
   print_list "holmake deps" holmake_deps)

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

fun roots_for_package sources package =
  map
    (fn root =>
       case List.filter (fn source => source_matches_root package source root) sources of
           [] => raise Error ("unknown build root: " ^ HolbuildProject.package_name package ^ ":" ^ root)
         | [source] => #logical_name source
         | _ => raise Error ("ambiguous build root: " ^ HolbuildProject.package_name package ^ ":" ^ root))
    (HolbuildProject.package_roots package)

fun default_targets sources project =
  let
    val rooted =
      List.concat
        (map (roots_for_package sources)
             (List.filter (fn package => not (null (HolbuildProject.package_roots package)))
                          (HolbuildProject.packages project)))
  in
    if not (null rooted) then rooted
    else
      map #logical_name
        (List.filter (fn source => not (is_implicit_hol_package (#package source))) sources)
  end

end
