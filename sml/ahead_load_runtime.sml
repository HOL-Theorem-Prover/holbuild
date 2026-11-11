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

   The steps talk to exec-action through marker files in one directory:
   base-loaded (written here, the modules loaded and the load path),
   stand-ins, arrived-P and ready (written by exec-action), waiting-P and
   finishing (written here, for the timings) and abandoned (written here,
   its reason; the child then exits with failure). *)
structure HolbuildAheadLoad =
struct
  val dir = ref ""
  (* Every file the loader evaluated, latest first, and how many. *)
  val recorded : string list ref = ref []
  val count = ref 0
  (* Each stand-in entered: the parent, the modules loaded then, and the
     count of files recorded before its enter step. *)
  val entries : (string * string list * int) list ref = ref []

  (* Paths as the loader evaluates them, with HOL's path variables expanded. *)
  fun record file = (recorded := holpathdb.subst_pathvars file :: !recorded; count := !count + 1)
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

  fun start directory =
    (dir := directory;
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
     dir := ""; recorded := []; count := 0; entries := [];
     loader := (fn _ => ()); restore := (fn () => ()))

  fun enter parent = entries := (parent, Meta.loaded (), !count - 1) :: !entries

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

  (* The files loading ENTRIES evaluates when LOADED are loaded, by the
     loader's own rule, reading only the manifests on disk. *)
  fun walk loaded entries =
    let
      val loaded = ref loaded
      fun manifest module ext =
        let
          val cwd = HOLFileSys.getDir ()
          fun at dir = OS.Path.mkAbsolute {path = module ^ ext, relativeTo = OS.Path.mkAbsolute {path = dir, relativeTo = cwd}}
        in
          case List.find (fn file => HOLFileSys.access (file, [])) (map at ("." :: !Meta.loadPath)) of
              SOME file => manifest_lines file
            | NONE => raise Fail ("no manifest " ^ module ^ ext)
        end
      fun visit entry =
        if is_file entry then [holpathdb.subst_pathvars entry]
        else
          let
            val module = holpathdb.subst_pathvars entry
            val name = OS.Path.file module
          in
            if List.exists (fn m => m = name) (!loaded) then []
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
      (* Recorded since the enter step, without it and this wait step. *)
      val since = List.drop (rev (!recorded), position + 1)
      val since = List.take (since, length since - 1)
      val _ = write ("waiting-" ^ parent) ""
      val _ = await ("arrived-" ^ parent)
      val ui_lines = file_lines ui
      val uo_lines = file_lines uo
      val (deps, theory) =
        case rev uo_lines of
            last :: rest => (rev rest, last)
          | [] => abandon ("the manifest of " ^ parent ^ " is empty")
      val _ = if List.all is_file (theory :: ui_lines) then ()
              else abandon ("the manifest of " ^ parent ^ " ends in a module")
      val expected = walk loaded deps handle e => abandon (General.exnMessage e)
    in
      if expected = since then List.app recording_use (ui_lines @ [theory])
      else abandon ("the load of " ^ parent ^ " evaluated other files than its manifest names")
    end
end
