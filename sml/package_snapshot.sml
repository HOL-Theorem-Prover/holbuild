(* The files of a package's source snapshot: what a consumer needs to build
   the package without the publisher's checkout.  Computed from holbuild's own
   inventory (the committed manifest's members and excludes, the declared
   inputs of actions, sources and generators), never from a VCS, so the list
   does not depend on the publisher's machine, local configuration or on
   whether generators ran. *)
structure HolbuildPackageSnapshot =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

fun die msg = raise Error msg

fun components rel = String.fields (fn c => c = #"/") rel

(* Files that are never part of a snapshot, wherever a directory expansion
   finds them. *)
fun ignored rel =
  let val parts = components rel
  in
    List.exists (fn part => part = ".git" orelse part = ".holbuild") parts orelse
    List.last parts = ".holconfig.toml"
  end

(* ABS relative to ROOT, an error when it lies outside; "" for ROOT itself. *)
fun relative root abs =
  let
    val rel = HolbuildSourceIndex.relative_path root abs
  in
    if HolbuildSourceIndex.normalize_path root = HolbuildSourceIndex.normalize_path abs then ""
    else if Path.isAbsolute rel orelse rel = ".." orelse String.isPrefix "../" rel then
      die ("snapshot path is outside the package root: " ^ abs)
    else rel
  end

(* Every component of REL below ROOT, symlinks included, must be a real file
   or directory: the snapshot must not follow or carry a link. *)
fun reject_symlinks root rel =
  let
    fun check (part, prefix) =
      let val path = if prefix = "" then part else prefix ^ "/" ^ part
      in
        if HolbuildSourceIndex.is_link (HolbuildSourceIndex.join root path) then
          die ("symlink in package snapshot: " ^ path)
        else path
      end
  in
    ignore (List.foldl check "" (List.filter (fn part => part <> "") (components rel)))
  end

type context = {root : string, outputs : string list}

fun is_output ({outputs, ...} : context) rel = List.exists (fn output => output = rel) outputs

(* Some generator output lies at or under ABS, so ABS may legitimately be
   missing until generators run. *)
fun generated_under ({root, outputs} : context) abs =
  List.exists
    (fn output => HolbuildSourceIndex.member_contains abs (HolbuildSourceIndex.join root output))
    outputs

fun keep (context : context) rel =
  if ignored rel orelse is_output context rel then []
  else (reject_symlinks (#root context) rel; [rel])

(* A file at a known package-relative path, such as a source or a generator
   input, which may be spelled with `.` components. *)
fun file (context : context) label declared_rel =
  let
    val abs = HolbuildSourceIndex.join (#root context) declared_rel
    val rel = relative (#root context) abs
  in
    if ignored rel orelse is_output context rel then []
    else
      (reject_symlinks (#root context) rel;
       if HolbuildSourceIndex.is_readable abs then [rel]
       else if generated_under context abs then []
       else die (label ^ " not found: " ^ rel))
  end

(* The files an extra-input declaration DECL names, relative to BASE, as the
   build stages them: a file, the files under a directory, or the files a glob
   matches under BASE. *)
fun declared (context : context) base decl =
  let
    val root = #root context
    val glob = HolbuildBuildPlan.path_has_glob decl
    val abs = HolbuildSourceIndex.normalize_path
                (if Path.isAbsolute decl then decl else Path.concat(base, decl))
    (* The walk lists directories and the entries it cannot read (a dangling
       link among them) apart from the files.  A glob walks all of BASE but
       selects only some of it, so only the entries it matches are checked. *)
    fun check_entry entry =
      let val rel = relative root entry
      in
        if rel = "" orelse ignored rel orelse is_output context rel then ()
        else if glob andalso
                not (HolbuildSourceIndex.glob_match decl (HolbuildSourceIndex.relative_path base entry))
        then ()
        else reject_symlinks root rel
      end
    fun walk () =
      let val {files, dirs} = HolbuildBuildPlan.expand_extra_dep_walk base decl
      in
        List.app check_entry dirs;
        List.concat (map (fn (_, path) => keep context (relative root path)) files)
      end
  in
    if glob then walk ()
    else
      let val rel = relative root abs
      in
        if ignored rel orelse is_output context rel then []
        else
          (reject_symlinks root rel;
           if FS.access(abs, []) handle OS.SysErr _ => false then walk ()
           else if generated_under context abs then []
           else die ("extra dependency not found: " ^ rel))
      end
  end

fun shim_manifests definition =
  List.mapPartial
    (fn HolbuildPackageDefinition.Dependency
          {source = HolbuildPackageDefinition.FromSource {manifest, ...}, ...} => SOME manifest
      | _ => NONE)
    (HolbuildPackageDefinition.dependencies definition)

(* The sources the committed manifest alone discovers: its own excludes, not
   the ones of the local configuration that the package record merges in. *)
fun discovered_sources (context : context) package =
  let
    val root = #root context
    val definition = HolbuildProject.package_definition_of package
    val {members, excludes, exclude_globs} = HolbuildPackageDefinition.sources definition
    val policies = HolbuildProject.package_action_policies package
    val artifact_root = HolbuildProject.package_artifact_root package
    val name = HolbuildProject.package_name package
    fun scan (member, sources) =
      let val abs = HolbuildProject.abs_under root member
      in
        if HolbuildSourceIndex.is_dir abs orelse HolbuildSourceIndex.is_readable abs orelse
           not (generated_under context abs)
        then HolbuildSourceIndex.scan_member name "" root artifact_root policies (#outputs context)
               excludes exclude_globs (abs, sources)
        else sources
      end
    fun declared_source (source : HolbuildSourceIndex.source) =
      #origin (#node source) = HolbuildSourceIndex.DeclaredSource
  in
    List.filter declared_source (List.foldl scan [] members)
  end

(* The sorted package-relative paths of PACKAGE's snapshot: its manifest, its
   discovered sources, the files its action policies, its sources
   (`holbuild_extra_deps`) and its generators declare as inputs, and the shim
   manifests of its dependencies.  Generator outputs, `.git`, `.holbuild` and
   `.holconfig.toml` are never in it.  A symlink or a declared path outside
   the package root raises Error naming it. *)
fun files package =
  let
    val root = HolbuildProject.package_root package
    val definition = HolbuildProject.package_definition_of package
    val generators = HolbuildProject.package_generators package
    val outputs =
      map (fn output => relative root (HolbuildSourceIndex.join root output))
        (List.concat (map HolbuildProject.generator_outputs generators))
    val context = {root = root, outputs = outputs} : context
    val sources = discovered_sources context package
    fun inline_decls (source : HolbuildSourceIndex.source) =
      map (fn decl => (Path.dir (#source_path source), decl))
        (#extra_deps (HolbuildDependencies.extract_textual (#source_path source)))
    val action_decls =
      map (fn input => (root, HolbuildProject.extra_input_path input))
        (List.concat (map HolbuildProject.action_extra_inputs
                          (HolbuildProject.package_action_policies package)))
    val found =
      file context "manifest" (relative root (HolbuildProject.package_manifest package)) @
      List.concat (map (fn source => file context "source" (#relative_path source)) sources) @
      List.concat (map (fn (base, decl) => declared context base decl)
                       (action_decls @ List.concat (map inline_decls sources))) @
      List.concat
        (map (file context "generator input")
             (List.concat (map HolbuildProject.generator_inputs generators))) @
      List.concat (map (file context "shim manifest") (shim_manifests definition))
  in
    Redblackset.listItems
      (List.foldl (fn (rel, set) => Redblackset.add(set, rel)) (Redblackset.empty String.compare) found)
  end
  handle HolbuildSourceIndex.Error msg => die msg
       | HolbuildBuildPlan.Error msg => die msg
       | HolbuildDependencies.Error msg => die msg

end
