(* A theory child that loads ahead of late parents (exec-action
   --ahead-parent).  Its preload loads through HOL's own loader with a `use`
   that records every file it evaluates.  exec-action puts a stand-in
   manifest in each late parent's place: an enter step, the parent's
   predicted manifest and a wait step.  The wait step blocks until
   exec-action has put the parent's real files in place, then walks the
   parent's real manifests from the modules loaded at entry, as the loader
   would, and continues only if that walk evaluates exactly the files
   recorded since entry.  It then evaluates the parent's signature and
   theory files, which a plain load evaluates before and after the walk.

   The preload ends in a barrier: it waits for exec-action's ready, which
   comes only once every late parent has arrived and the script is written,
   then puts the loader back as a plain load has it, before the plain
   preload saves its heap.

   A stand-in may stand in for a parent whose own late parents have stand-ins
   too: the inner one completes inside the outer one's preload, and the outer
   wait walks the inner parent's real manifests as its completion evaluated
   them.  The enter and wait steps themselves are not recorded.

   The steps talk to exec-action through marker files in one directory:
   base-loaded (written here, the modules loaded and the load path),
   stand-ins, arrived-P and ready (written by exec-action), waiting-P and
   finishing (written here, for the timings), shared (written here, the
   parent whose wait step shared the heap) and abandoned (written here,
   its reason; the child then exits with failure).

   The plain preload saves the heap the theory's checkpoints are children
   of, after the last parent has arrived.  So the first wait step that has to
   wait shares the heap's common data while the child is idle, with most of
   its ancestors loaded, and saves it as the ahead heap; the plain preload
   then saves only what was loaded since, as the ahead heap's child, without
   sharing again.  Later waits don't save again: on a chain of late parents
   they last only as long as one parent's own hand-off.  The save's full GC
   hands back the duplicates the share freed.  The ahead heap is never a
   start point: it was saved inside a load, and the deps heap's overwrite of
   mutable data restores the state the load ended in. *)
structure HolbuildAheadLoad =
struct
  val dir = ref ""
  (* Every file the loader evaluated, latest first, and how many. *)
  val recorded : string list ref = ref []
  val count = ref 0
  (* Each stand-in entered: the parent, the modules loaded then, and the
     count of files recorded before its enter step. *)
  val entries : (string * string list * int) list ref = ref []
  (* The parents whose wait steps let the load go on. *)
  val completed : string list ref = ref []
  (* Where a wait step that has to wait still shares and saves the heap;
     "" once one has, or when the child saves no checkpoints. *)
  val ahead_heap = ref ""

  (* Paths as the loader evaluates them, with HOL's path variables expanded;
     the steps' own files, in the marker directory, are left out. *)
  fun record file =
    let val expanded = holpathdb.subst_pathvars file
    in
      if !dir <> "" andalso String.isPrefix (!dir ^ "/") expanded then ()
      else (recorded := expanded :: !recorded; count := !count + 1)
    end
  fun recording_use file = (record file; Meta.qquse file)
  (* How the preload loads a module.  On a HOL with theory modules the
     preload makes it Meta.load, recording through Meta.moduleSourceLoader,
     so modules load from the module store as in a plain load. *)
  val loader = ref (Meta.loadPlan recording_use)
  fun load module = !loader module
  (* Puts back what the preload changed of HOL's loader. *)
  val restore = ref (fn () => ())

  fun path name = OS.Path.concat (!dir, name)
  fun exists name = OS.FileSys.access (path name, []) handle OS.SysErr _ => false
  fun await name = if exists name then () else (OS.Process.sleep (Time.fromMilliseconds 50); await name)
  (* Renamed into place, so exec-action never reads a partial marker. *)
  fun write name text =
    (HolbuildRuntime.write_text (path name ^ ".tmp") text;
     OS.FileSys.rename {old = path name ^ ".tmp", new = path name})

  fun abandon reason =
    (write "abandoned" reason;
     TextIO.output (TextIO.stdErr, "holbuild: loading ahead abandoned: " ^ reason ^ "\n");
     OS.Process.exit OS.Process.failure)

  fun start directory ahead_heap_path =
    (dir := directory;
     ahead_heap := ahead_heap_path;
     write "base-loaded"
       (String.concat (map (fn m => "loaded " ^ m ^ "\n") (Meta.loaded ()) @
                       map (fn d => "path " ^ d ^ "\n") (!Meta.loadPath)));
     await "stand-ins")

  (* The plain preload saves its heap after this, so nothing of the load
     ahead is left in it. *)
  fun finish () =
    (write "finishing" "";
     await "ready";
     !restore ();
     dir := ""; recorded := []; count := 0; entries := []; completed := []; ahead_heap := "";
     loader := (fn _ => ()); restore := (fn () => ()))

  (* The plain preload's save sees the ahead heap in the hierarchy and saves
     its child.  It is removed first: the path may be a link to a state other
     actions use.  A failed save leaves the hierarchy as it was, so the plain
     preload saves the whole heap. *)
  fun save_ahead_heap path =
    let
      fun dropped e =
        ((OS.FileSys.remove path handle OS.SysErr _ => ());
         TextIO.output (TextIO.stdErr, "holbuild: warning: could not save the ahead heap " ^ path ^ ": " ^
                                       General.exnMessage e ^ "\n"))
    in
      (* saveChild runs a full GC first, which hands back what the share
         freed. *)
      PolyML.shareCommonData PolyML.rootFunction;
      ((OS.FileSys.remove path handle OS.SysErr _ => ());
       PolyML.SaveState.saveChild (path, List.length (PolyML.SaveState.showHierarchy ())))
      handle e as IO.Io _ => dropped e
           | e as OS.SysErr _ => dropped e
    end

  fun enter parent = entries := (parent, Meta.loaded (), !count) :: !entries

  fun split text = String.tokens (fn c => c = #"\n") text
  (* A module's manifest, where HOL's file system keeps it. *)
  fun manifest_lines file =
    let val input = HOLFileSys.openIn file
    in split (HOLFileSys.inputAll input before HOLFileSys.closeIn input) end
  (* A file exec-action wrote, at its own path. *)
  fun file_lines file =
    let val input = TextIO.openIn file
    in split (TextIO.inputAll input before TextIO.closeIn input) end

  fun is_file entry = case OS.Path.ext entry of SOME "sml" => true | SOME "sig" => true | _ => false

  (* A real .uo manifest: the entries before the theory file, and it. *)
  fun split_theory parent uo_lines =
    case rev uo_lines of
        last :: rest => (rev rest, last)
      | [] => abandon ("the manifest of " ^ parent ^ " is empty")

  (* The files loading ENTRIES evaluates when LOADED are loaded, by the
     loader's own rule, reading only the manifests on disk.  A completed
     parent is still a stand-in on disk: its real manifests are the ones its
     wait step read, evaluated as that step did, its loads before its
     signature. *)
  fun walk loaded entries =
    let
      val loaded = ref loaded
      fun manifest module ext =
        let
          val cwd = HOLFileSys.getDir ()
          fun at dir = OS.Path.mkAbsolute {path = module ^ ext, relativeTo = OS.Path.mkAbsolute {path = dir, relativeTo = cwd}}
          (* Each path is built only when tried: the load path has hundreds
             of directories and a wait step looks up thousands of manifests. *)
          fun first [] = raise Fail ("no manifest " ^ module ^ ext)
            | first (dir :: dirs) =
                let val file = at dir
                in if HOLFileSys.access (file, []) then manifest_lines file else first dirs end
        in
          first ("." :: !Meta.loadPath)
        end
      fun visit entry =
        if is_file entry then [holpathdb.subst_pathvars entry]
        else
          let
            val module = holpathdb.subst_pathvars entry
            val name = OS.Path.file module
          in
            if List.exists (fn m => m = name) (!loaded) then []
            else if List.exists (fn m => m = name) (!completed) then
              let
                val _ = loaded := name :: !loaded
                val (deps, theory) = split_theory name (file_lines (path (name ^ ".uo")))
              in
                List.concat (map visit (deps @ file_lines (path (name ^ ".ui")) @ [theory]))
              end
            else
              (loaded := name :: !loaded;
               List.concat (map visit (manifest module ".ui" @ manifest module ".uo")))
          end
    in
      List.concat (map visit entries)
    end

  (* The wait step of PARENT's stand-in; UI and UO are its real manifests. *)
  fun wait {parent, ui, uo} =
    let
      val (loaded, position) =
        case List.find (fn (p, _, _) => p = parent) (!entries) of
            SOME (_, loaded, position) => (loaded, position)
          | NONE => abandon ("the stand-in of " ^ parent ^ " was not entered")
      val since = List.drop (rev (!recorded), position)
      (* Before waiting-P, so the timings count the save as loading. *)
      val _ =
        if !ahead_heap <> "" andalso not (exists ("arrived-" ^ parent)) then
          (save_ahead_heap (!ahead_heap); ahead_heap := ""; write "shared" parent)
        else ()
      val _ = write ("waiting-" ^ parent) ""
      val _ = await ("arrived-" ^ parent)
      val ui_lines = file_lines ui
      val uo_lines = file_lines uo
      val (deps, theory) = split_theory parent uo_lines
      val _ = if List.all is_file (theory :: ui_lines) then ()
              else abandon ("the manifest of " ^ parent ^ " ends in a module")
      val expected = walk loaded deps handle e => abandon (General.exnMessage e)
    in
      if expected = since then (List.app recording_use (ui_lines @ [theory]); completed := parent :: !completed)
      else abandon ("the load of " ^ parent ^ " evaluated other files than its manifest names")
    end
end
