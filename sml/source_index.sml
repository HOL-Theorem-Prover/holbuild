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

fun has_source_path path sources =
  let val path = normalize_path path
  in List.exists (fn source : source => normalize_path (#source_path source) = path) sources end

fun scan_file package source_root artifact_root policies excludes path acc =
  if excluded excludes (relative_path source_root path) then acc
  else case classify package source_root artifact_root policies path of
      NONE => acc
    | SOME source => if has_source_path path acc then acc else source :: acc

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

fun compatible_same_name (a : source) (b : source) =
  #package a = #package b andalso
  (case (#kind a, #kind b) of
       (Sml, Sig) => true
     | (Sig, Sml) => true
     | _ => false)

fun by_logical sources =
  let
    fun conflicts source other =
      #logical_name source = #logical_name other andalso
      not (compatible_same_name source other)
    fun insert (source, seen) =
      case List.find (conflicts source) seen of
          NONE => source :: seen
        | SOME other =>
            raise Error ("duplicate logical name " ^ #logical_name source ^ ": " ^
                         #package other ^ ":" ^ #relative_path other ^ " and " ^
                         #package source ^ ":" ^ #relative_path source)
  in
    ignore (List.foldl insert [] sources);
    sources
  end

fun insert_sorted source sources =
  case sources of
      [] => [source]
    | x :: xs =>
        if compare_source(source, x) = LESS then source :: sources
        else x :: insert_sorted source xs

fun sort_sources sources = List.foldl (fn (source, acc) => insert_sorted source acc) [] sources

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

fun scan_member name source_root artifact_root policies excludes (member, acc) =
  if is_dir member then scan_dir name source_root artifact_root policies excludes member acc
  else if is_readable member then scan_file name source_root artifact_root policies excludes member acc
  else raise Error ("member does not exist: " ^ member)

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
    val sources =
      List.foldl
        (scan_member name source_root artifact_root policies excludes)
        acc
        members
    val _ = validate_action_policies name policies sources
  in
    sources
  end

fun discover (project : HolbuildProject.t) =
  by_logical
    (sort_sources
       (List.foldl
          (fn (package, acc) => discover_package package acc)
          []
          (HolbuildProject.packages project)))

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

fun roots_for_package sources package =
  map
    (fn root =>
       case List.filter (fn source => source_matches_root package source root) sources of
           [] => raise Error ("unknown build root: " ^ HolbuildProject.package_name package ^ ":" ^ root)
         | [source] => #logical_name source
         | _ => raise Error ("ambiguous build root: " ^ HolbuildProject.package_name package ^ ":" ^ root))
    (HolbuildProject.package_roots package)

fun default_targets sources project =
  List.concat
    (map (roots_for_package sources)
         (List.filter (fn package => not (null (HolbuildProject.package_roots package)))
                      (HolbuildProject.packages project)))

end
