(* A parked child of holbuild park-serve: loaded and ready, it waits on its
   stdin for lines.  "prerun\tMARKER\tDIR\tFILE...\n" runs FILE... from DIR
   and writes "ok" or "failed" to MARKER, then waits again; a failure still
   ends the child as `hol run` would.  "DIR\tFILE...\n" runs FILE... from
   DIR as `hol run` would have run them, and ends the wait. *)
fun holbuild_park_marker marker text =
  let val out = TextIO.openOut (marker ^ ".tmp")
  in TextIO.output (out, text); TextIO.closeOut out; OS.FileSys.rename {old = marker ^ ".tmp", new = marker} end;
fun holbuild_park_wait () =
  case TextIO.inputLine TextIO.stdIn of
      NONE => OS.Process.exit OS.Process.failure
    | SOME line =>
        case String.tokens (fn c => c = #"\t" orelse c = #"\n") line of
            "prerun" :: marker :: dir :: files =>
              ((OS.FileSys.chDir dir; List.app QUse.use files)
               handle e => (holbuild_park_marker marker "failed"; raise e);
               holbuild_park_marker marker "ok";
               holbuild_park_wait ())
          | dir :: files => (OS.FileSys.chDir dir; List.app QUse.use files)
          | [] => OS.Process.exit OS.Process.failure;
val _ = holbuild_park_wait ();
