(* The probe sibling of holbuild park-serve: it reads lines on its stdin,
   "MARKER\tDIR\tFILE...", uses FILE... from DIR, stopping at the first that
   raises, then writes MARKER: "ok", or "error" and the exception's message.
   It keeps whatever the files left behind, a failed theorem's goals in
   HolbuildProofRuntime.failed_goals included, and never saves a heap.
   Like a session it outlives failures: HOL ends a non-interactive process
   on a theorem that fails to prove. *)
val _ = Globals.interactive := true;
fun holbuild_probe_loop () =
  case TextIO.inputLine TextIO.stdIn of
      NONE => OS.Process.exit OS.Process.success
    | SOME line =>
        case String.tokens (fn c => c = #"\t" orelse c = #"\n") line of
            marker :: dir :: files =>
              let
                val result = (OS.FileSys.chDir dir; List.app QUse.use files; "ok\n")
                             handle e => "error\n" ^ General.exnMessage e ^ "\n"
                val _ = (TextIO.flushOut TextIO.stdOut; TextIO.flushOut TextIO.stdErr)
                val tmp = marker ^ ".tmp"
                val out = TextIO.openOut tmp
              in
                TextIO.output (out, result);
                TextIO.closeOut out;
                OS.FileSys.rename {old = tmp, new = marker};
                holbuild_probe_loop ()
              end
          | _ => OS.Process.exit OS.Process.failure;
val _ = holbuild_probe_loop ();
