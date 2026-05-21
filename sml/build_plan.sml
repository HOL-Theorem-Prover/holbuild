structure HolbuildBuildPlan =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

type node =
  { source : HolbuildSourceIndex.source,
    deps : HolbuildDependencies.t option ref,
    source_hash : string option ref,
    external_dirs : string list,
    include_dirs : string list }

type t = node list

type keyed_node = {node : node, input_key : string}

fun source_of ({source, ...} : node) = source

fun source_hash_of ({source, source_hash, ...} : node) =
  case !source_hash of
      SOME hash => hash
    | NONE =>
        let val hash = HolbuildHash.file_sha1 (#source_path source)
        in source_hash := SOME hash; hash end

fun dependency_cache_path source =
  case #objects (#artifacts source) of
      object :: _ => object ^ ".deps"
    | [] => #source_path source ^ ".holbuild-deps"

fun deps_of (node as {source, deps, ...} : node) =
  case !deps of
      SOME value => value
    | NONE =>
      let
        val value = HolbuildDependencies.extract_cached_with_hash_and_includes
                      {cache_path = dependency_cache_path source,
                       source_path = #source_path source,
                       source_hash = source_hash_of node,
                       includes = #include_dirs node}
      in deps := SOME value; value end
fun external_dirs_of ({external_dirs, ...} : node) = external_dirs
fun include_dirs_of ({include_dirs, ...} : node) = include_dirs
fun logical_name node = #logical_name (source_of node)
fun package node = #package (source_of node)
fun relative_path node = #relative_path (source_of node)
fun key node = package node ^ "\000" ^ relative_path node ^ "\000" ^ logical_name node

fun member value values = List.exists (fn x => x = value) values

fun add_unique (value, values) = if member value values then values else value :: values

fun unique_strings values = rev (List.foldl add_unique [] values)

fun normalize_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun has_logical_name name node = logical_name node = name

fun nodes_named nodes name = List.filter (has_logical_name name) nodes

type name_index = (string * node list) Vector.vector

fun split_pairs xs =
  let
    fun loop left right rest =
      case rest of
          [] => (left, right)
        | [x] => (x :: left, right)
        | x :: y :: zs => loop (x :: left) (y :: right) zs
  in
    loop [] [] xs
  end

fun merge_pairs compare left right =
  case (left, right) of
      ([], _) => right
    | (_, []) => left
    | (l :: ls, r :: rs) =>
        if compare (l, r) <> GREATER then
          l :: merge_pairs compare ls right
        else
          r :: merge_pairs compare left rs

fun sort_pairs compare pairs =
  case pairs of
      [] => []
    | [_] => pairs
    | _ =>
      let val (left, right) = split_pairs pairs
      in merge_pairs compare (sort_pairs compare left) (sort_pairs compare right) end

fun compare_pair_key ((left, _), (right, _)) = String.compare(left, right)

fun build_name_index nodes =
  let
    val pairs = sort_pairs compare_pair_key (map (fn node => (logical_name node, node)) nodes)
    fun collect name acc rest =
      case rest of
          (name', node) :: more =>
            if name' = name then collect name (node :: acc) more
            else (name, rev acc) :: group rest
        | [] => [(name, rev acc)]
    and group rest =
      case rest of
          [] => []
        | (name, node) :: more => collect name [node] more
  in
    Vector.fromList (group pairs)
  end

fun indexed_nodes_named index name =
  let
    fun search lo hi =
      if lo > hi then []
      else
        let
          val mid = (lo + hi) div 2
          val (candidate, nodes) = Vector.sub(index, mid)
        in
          case String.compare(name, candidate) of
              LESS => search lo (mid - 1)
            | GREATER => search (mid + 1) hi
            | EQUAL => nodes
        end
  in
    search 0 (Vector.length index - 1)
  end

type key_index = (string * int) Vector.vector

fun build_key_index nodes =
  let
    fun enumerate _ [] = []
      | enumerate i (node :: rest) = (key node, i) :: enumerate (i + 1) rest
  in
    Vector.fromList (sort_pairs compare_pair_key (enumerate 0 nodes))
  end

fun indexed_key_id index node_key =
  let
    fun search lo hi =
      if lo > hi then raise Error ("internal missing node key: " ^ node_key)
      else
        let
          val mid = (lo + hi) div 2
          val (candidate, id) = Vector.sub(index, mid)
        in
          case String.compare(node_key, candidate) of
              LESS => search lo (mid - 1)
            | GREATER => search (mid + 1) hi
            | EQUAL => id
        end
  in
    search 0 (Vector.length index - 1)
  end

fun selected_nodes nodes targets =
  case targets of
      [] => nodes
    | _ =>
      let
        fun find target =
          case nodes_named nodes target of
              [] => raise Error ("unknown build target: " ^ target)
            | matches => matches
      in
        List.concat (map find targets)
      end

fun theory_name name =
  let val suffix = "Theory"
      val n = size name
      val m = size suffix
  in
    n > m andalso String.substring(name, n - m, m) = suffix
  end

fun declared_dependency_names node =
  HolbuildProject.action_deps (#policy (source_of node))

fun declared_load_names node =
  HolbuildProject.action_loads (#policy (source_of node))

fun bootstrap_provided name = HolbuildBootstrap.is_bare_logical name

fun provided_for node name = bootstrap_provided name

fun needs_standard_env_dependency node =
  let val source = source_of node
  in
    #package source <> "HOL" andalso
    not (#bare source) andalso
    #kind source <> HolbuildSourceIndex.Sig
  end

fun standard_env_dependency_names node =
  if needs_standard_env_dependency node then ["bossLib", "holTheory"] else []

fun direct_dependency_names node =
  unique_strings
    (List.filter (fn name => not (provided_for node name))
       (standard_env_dependency_names node @ declared_dependency_names node @ declared_load_names node))

fun unique_nodes nodes =
  let
    fun add (node, kept) =
      if member (key node) (map key kept) then kept else node :: kept
  in
    rev (List.foldl add [] nodes)
  end

fun describe_node node = package node ^ ":" ^ relative_path node

fun conflict_if_hol_shadow name matches =
  let
    val hol = List.filter (fn node => package node = "HOL") matches
    val non_hol = List.filter (fn node => package node <> "HOL") matches
  in
    if null hol orelse null non_hol then matches
    else raise Error ("logical name " ^ name ^ " is defined both by the implicit HOL checkout and another package: " ^
                      String.concatWith ", " (map describe_node matches))
  end

fun resolved_lookup lookup name = conflict_if_hol_shadow name (lookup name)

fun source_artifact_paths node =
  let
    val source = source_of node
    val {generated, objects, theory_data} = #artifacts source
    val dir = Path.dir (#source_path source)
    val logical = #logical_name source
    val holdep_objects =
      case #kind source of
          HolbuildSourceIndex.TheoryScript =>
            [Path.concat(dir, logical ^ ".uo"), Path.concat(dir, logical ^ ".ui")]
        | HolbuildSourceIndex.Sml =>
            [Path.concat(dir, logical ^ ".uo"), Path.concat(dir, logical ^ ".ui")]
        | HolbuildSourceIndex.Sig =>
            [Path.concat(dir, logical ^ ".ui")]
  in
    #source_path source :: generated @ objects @ theory_data @ holdep_objects
  end

fun path_matches_source dep_path candidate =
  let val dep_path = normalize_path dep_path
  in List.exists (fn path => normalize_path path = dep_path) (source_artifact_paths candidate) end

fun drop_suffix suffix s =
  if String.isSuffix suffix s then String.substring(s, 0, size s - size suffix) else s

fun drop_known_object_suffix path =
  let val base = Path.file path
  in
    if String.isSuffix ".uo" base then drop_suffix ".uo" base
    else if String.isSuffix ".ui" base then drop_suffix ".ui" base
    else if String.isSuffix ".sig" base then drop_suffix ".sig" base
    else if String.isSuffix ".sml" base then drop_suffix ".sml" base
    else base
  end

fun path_in_dir dir path =
  let
    val dir = normalize_path dir
    val path = normalize_path path
    val prefix = if String.isSuffix "/" dir then dir else dir ^ "/"
  in
    String.isPrefix prefix path
  end

fun logical_object_matches dep_path matches =
  let
    val file = Path.file dep_path
    fun is_sig node = #kind (source_of node) = HolbuildSourceIndex.Sig
    fun is_impl node = #kind (source_of node) <> HolbuildSourceIndex.Sig
    val sigs = List.filter is_sig matches
    val impls = List.filter is_impl matches
  in
    if String.isSuffix ".ui" file andalso not (null sigs) then sigs
    else if String.isSuffix ".uo" file then impls
    else matches
  end

fun source_for_resolved_file external_dirs lookup nodes dep_path =
  let
    val by_path = List.filter (path_matches_source dep_path) nodes
  in
    if not (null by_path) then logical_object_matches dep_path by_path
    else if List.exists (fn dir => path_in_dir dir dep_path) external_dirs then
      logical_object_matches dep_path (resolved_lookup lookup (drop_known_object_suffix dep_path))
    else []
  end

fun resolved_file_bootstrap_provided path =
  HolbuildBootstrap.is_bare_logical (drop_known_object_suffix path)

fun direct_holdep_file_deps_with lookup nodes node =
  let
    fun not_self candidate = key candidate <> key node
    fun matches_for dep_path =
      case source_for_resolved_file (external_dirs_of node) lookup nodes dep_path of
          [] => if resolved_file_bootstrap_provided dep_path then []
                else raise Error ("Holdep resolved dependency outside known packages: " ^
                                  dep_path ^ " referenced from " ^
                                  package node ^ ":" ^ relative_path node)
        | matches => matches
    val matches = List.concat (map matches_for (#resolved_files (deps_of node)))
  in
    unique_nodes (List.filter not_self matches)
  end

fun readable_path path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun direct_project_deps_with lookup nodes node =
  let
    fun not_self candidate = key candidate <> key node
    val named_deps = List.concat (map (resolved_lookup lookup) (direct_dependency_names node))
  in
    unique_nodes (List.filter not_self
                    (named_deps @ direct_holdep_file_deps_with lookup nodes node))
  end

fun direct_project_deps nodes node =
  direct_project_deps_with (nodes_named nodes) nodes node

fun direct_external_theories_with lookup node = []

fun direct_external_theories nodes node =
  direct_external_theories_with (nodes_named nodes) node

fun direct_external_libs_with lookup node = []

fun direct_external_libs nodes node =
  direct_external_libs_with (nodes_named nodes) node

fun direct_unresolved_loads_with lookup node = []

fun direct_unresolved_loads nodes node =
  direct_unresolved_loads_with (nodes_named nodes) node

fun direct_unresolved_declared_deps_with lookup node =
  let
    fun known name = provided_for node name orelse not (null (lookup name))
  in
    List.filter (fn name => not (known name))
      (declared_dependency_names node @ declared_load_names node)
  end

fun direct_unresolved_declared_deps nodes node =
  direct_unresolved_declared_deps_with (nodes_named nodes) node

fun reject_unresolved_loads_with lookup plan =
  let
    fun check_loads node =
      case direct_unresolved_loads_with lookup node of
          [] => ()
        | load :: _ =>
            raise Error ("unresolved load " ^ load ^ " in " ^
                         package node ^ ":" ^ relative_path node)
    fun check_declared_deps node =
      case direct_unresolved_declared_deps_with lookup node of
          [] => ()
        | dep :: _ =>
            raise Error ("unresolved action dependency " ^ dep ^ " in " ^
                         package node ^ ":" ^ relative_path node)
  in
    List.app (fn node => (check_loads node; check_declared_deps node)) plan
  end

fun reject_unresolved_loads nodes plan =
  reject_unresolved_loads_with (nodes_named nodes) plan

fun reject_source_uses plan =
  let
    fun check node =
      case #uses (deps_of node) of
          [] => ()
        | used :: _ =>
            raise Error ("unsupported use " ^ used ^ " in " ^
                         package node ^ ":" ^ relative_path node ^
                         "; declare a project module and load it instead")
  in
    List.app check plan
  end

fun cycle_message path node =
  "dependency cycle: " ^
  String.concatWith " -> " (rev (logical_name node :: map logical_name path))

fun topo_sort_with lookup nodes roots =
  let
    val key_index = build_key_index nodes
    val visited = Array.array (length nodes, false)
    val active = Array.array (length nodes, false)
    fun node_id node = indexed_key_id key_index (key node)
    fun visit active_path node order =
      let val id = node_id node
      in
        if Array.sub(visited, id) then order
        else if Array.sub(active, id) then raise Error (cycle_message active_path node)
        else
          let
            val _ = Array.update(active, id, true)
            val deps = direct_project_deps_with lookup nodes node
            val order' = List.foldl (fn (dep, acc) => visit (node :: active_path) dep acc) order deps
            val _ = Array.update(active, id, false)
            val _ = Array.update(visited, id, true)
          in
            node :: order'
          end
      end
    val order = List.foldl (fn (root, acc) => visit [] root acc) [] roots
    val plan = rev order
  in
    reject_unresolved_loads_with lookup plan;
    reject_source_uses plan;
    plan
  end

fun topo_sort nodes roots =
  topo_sort_with (nodes_named nodes) nodes roots

fun transitive_project_deps nodes node = topo_sort nodes (direct_project_deps nodes node)

fun closure_external_theories nodes node =
  unique_strings
    (List.concat (map (direct_external_theories nodes)
       (transitive_project_deps nodes node @ [node])))

fun closure_external_libs nodes node =
  unique_strings
    (List.concat (map (direct_external_libs nodes)
       (transitive_project_deps nodes node @ [node])))

fun make_node external_dirs all_non_hol_dirs source =
  {source = source,
   deps = ref NONE,
   source_hash = ref NONE,
   external_dirs = external_dirs,
   include_dirs = if #package source = "HOL" then external_dirs else all_non_hol_dirs @ external_dirs}

fun plan holdir sources targets =
  let
    val external_dirs = [normalize_path (Path.concat(holdir, "sigobj"))]
    val all_non_hol_dirs = unique_strings (map (normalize_path o Path.dir o #source_path)
                                      (List.filter (fn source => #package source <> "HOL") sources))
    val nodes = map (make_node external_dirs all_non_hol_dirs) sources
    val index = build_name_index nodes
    val lookup = indexed_nodes_named index
    val roots =
      case targets of
          [] => []
        | _ => List.concat (map (fn target =>
                   case resolved_lookup lookup target of
                       [] => raise Error ("unknown build target: " ^ target)
                     | matches => matches)
                 targets)
  in
    topo_sort_with lookup nodes roots
  end

fun kind_name source = HolbuildSourceIndex.kind_string (#kind source)

fun readable path = OS.FileSys.access(path, [OS.FileSys.A_READ]) handle OS.SysErr _ => false

fun file_hash path =
  if readable path then HolbuildHash.file_sha1 path
  else raise Error ("extra dependency not found: " ^ path)

fun is_dir path = FS.isDir path handle OS.SysErr _ => false

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

fun path_has_glob path =
  List.exists (fn c => c = #"*" orelse c = #"?") (String.explode path)

fun join root rel = if rel = "" then root else Path.concat(root, rel)

fun sort_strings xs =
  let
    fun insert x [] = [x]
      | insert x (y :: ys) =
          if String.compare(x, y) = LESS then x :: y :: ys else y :: insert x ys
  in
    List.foldl (fn (x, acc) => insert x acc) [] xs
  end

fun files_under abs rel =
  if is_dir abs then
    List.concat (map (fn name => files_under (Path.concat(abs, name)) (join rel name)) (list_dir abs))
  else if readable abs then [(rel, abs)]
  else []

fun expand_extra_dep base decl =
  if path_has_glob decl then
    let
      val root = base
      val all = files_under root ""
    in
      List.filter (fn (rel, _) => HolbuildSourceIndex.glob_match decl rel) all
    end
  else
    let val abs = normalize_path (if Path.isAbsolute decl then decl else Path.concat(base, decl))
    in
      if is_dir abs then files_under abs decl
      else if readable abs then [(decl, abs)]
      else raise Error ("extra dependency not found: " ^ abs)
    end

fun extra_dep_lines label base decls =
  let
    fun line decl =
      let val expanded = sort_strings (map (fn (rel, abs) => rel ^ "@" ^ file_hash abs) (expand_extra_dep base decl))
      in (label ^ "_decl=" ^ decl) :: map (fn s => label ^ "=" ^ s) expanded end
  in
    List.concat (map line decls)
  end

fun external_key_lookup toolchain_key =
  fn _ => fn _ => fn _ => toolchain_key

fun bool_text true = "true"
  | bool_text false = "false"

fun hash_text text = HolbuildHash.string_sha1 text

fun lookup_key keys dep =
  case List.find (fn (dep_key, _) => dep_key = key dep) keys of
      SOME (_, input_key) => input_key
    | NONE => raise Error ("missing action key for dependency: " ^ logical_name dep)

fun action_text_with lookup config_lines_for_node toolchain_key external_key nodes keys node =
  let
    val source = source_of node
    val source_hash = source_hash_of node
    val project_deps =
      map (fn dep => package dep ^ ":" ^ logical_name dep ^ "@" ^ lookup_key keys dep)
        (direct_project_deps_with lookup nodes node)
    val external_deps =
      map (fn name => "HOL:" ^ name ^ "@" ^ external_key node "theory" name)
        (direct_external_theories_with lookup node)
    val external_libs =
      map (fn name => "HOLLIB:" ^ name ^ "@" ^ external_key node "lib" name)
        (direct_external_libs_with lookup node)
    val policy = #policy source
    val declared_deps = HolbuildProject.action_deps policy
    val declared_loads = HolbuildProject.action_loads policy
    val declared_dep_lines = map (fn dep => "declared_dep=" ^ dep) declared_deps
    val declared_load_lines = map (fn dep => "declared_load=" ^ dep) declared_loads
    fun extra_input_root input =
      let
        val rel = HolbuildProject.extra_input_path input
        val abs = HolbuildProject.extra_input_absolute_path input
        val n = size abs - size rel
      in
        if n > 0 then String.substring(abs, 0, n) else Path.dir abs
      end
    val extra_inputs = HolbuildProject.action_extra_inputs policy
    val manifest_extra_dep_lines =
      List.concat (map (fn input =>
        extra_dep_lines "extra_dep" (extra_input_root input) [HolbuildProject.extra_input_path input]) extra_inputs)
    val source_extra_dep_lines =
      extra_dep_lines "source_extra_dep" (Path.dir (#source_path source)) (#extra_deps (deps_of node))
    val lines =
      ["holbuild-action-v1",
       "toolchain=" ^ toolchain_key,
       "kind=" ^ kind_name source,
       "package=" ^ #package source,
       "logical=" ^ #logical_name source,
       "source=" ^ #relative_path source,
       "source-sha1=" ^ source_hash,
       "cache=" ^ bool_text (HolbuildProject.action_cache_enabled policy),
       "always_reexecute=" ^ bool_text (HolbuildProject.action_always_reexecute policy)] @
      config_lines_for_node node @
      declared_dep_lines @
      declared_load_lines @
      manifest_extra_dep_lines @
      source_extra_dep_lines @
      map (fn dep => "dep=" ^ dep) (project_deps @ external_deps @ external_libs)
  in
    String.concatWith "\n" lines ^ "\n"
  end

fun action_text config_lines_for_node toolchain_key nodes keys node =
  let val external_key = external_key_lookup toolchain_key
  in action_text_with (nodes_named nodes) config_lines_for_node toolchain_key external_key nodes keys node end

fun add_input_key_with lookup config_lines_for_node toolchain_key external_key nodes (node, keys) =
  (key node, hash_text (action_text_with lookup config_lines_for_node toolchain_key external_key nodes keys node)) :: keys

fun add_input_key config_lines_for_node toolchain_key nodes (node, keys) =
  let val external_key = external_key_lookup toolchain_key
  in add_input_key_with (nodes_named nodes) config_lines_for_node toolchain_key external_key nodes (node, keys) end

fun compute_input_keys_with lookup config_lines_for_node toolchain_key nodes =
  let
    val external_key = external_key_lookup toolchain_key
  in
    List.foldl
      (fn (node, keys) =>
          add_input_key_with lookup config_lines_for_node toolchain_key external_key nodes (node, keys))
      [] nodes
  end

fun input_keys_with lookup config_lines_for_node toolchain_key nodes =
  HolbuildToolchain.time_phase "build.keys"
    (fn () => compute_input_keys_with lookup config_lines_for_node toolchain_key nodes)

fun input_keys config_lines_for_node toolchain_key nodes =
  input_keys_with (nodes_named nodes) config_lines_for_node toolchain_key nodes

fun input_key_for keys node = lookup_key keys node

fun print_external_deps_with lookup node =
  case direct_external_theories_with lookup node of
      [] => ()
    | deps => print ("  external theories: " ^ String.concatWith ", " deps ^ "\n")

fun print_external_deps nodes node =
  print_external_deps_with (nodes_named nodes) node

fun print_external_libs_with lookup node =
  case direct_external_libs_with lookup node of
      [] => ()
    | deps => print ("  external libs: " ^ String.concatWith ", " deps ^ "\n")

fun print_external_libs nodes node =
  print_external_libs_with (nodes_named nodes) node

fun print_project_deps_with lookup nodes node =
  case direct_project_deps_with lookup nodes node of
      [] => ()
    | deps => print ("  project deps: " ^
                     String.concatWith ", " (map logical_name deps) ^ "\n")

fun print_project_deps nodes node =
  print_project_deps_with (nodes_named nodes) nodes node

fun describe_node_with lookup nodes keys node =
  (HolbuildSourceIndex.describe_source (source_of node);
   print ("  input_key: " ^ input_key_for keys node ^ "\n");
   print_project_deps_with lookup nodes node;
   print_external_deps_with lookup node;
   print_external_libs_with lookup node)

fun describe_node nodes keys node =
  describe_node_with (nodes_named nodes) nodes keys node

fun describe config_lines_for_node toolchain_key nodes =
  let
    val lookup = indexed_nodes_named (build_name_index nodes)
    val keys = input_keys_with lookup config_lines_for_node toolchain_key nodes
  in
    List.app (describe_node_with lookup nodes keys) nodes
  end

end
