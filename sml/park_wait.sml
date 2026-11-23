(* A parked child of holbuild park-serve: loaded and ready, it waits for
   one line on its stdin, "DIR\tFILE...\n", then runs FILE... from DIR as
   `hol run` would have run them. *)
val _ =
  case TextIO.inputLine TextIO.stdIn of
      NONE => OS.Process.exit OS.Process.failure
    | SOME line =>
        case String.tokens (fn c => c = #"\t" orelse c = #"\n") line of
            dir :: files => (OS.FileSys.chDir dir; List.app QUse.use files)
          | [] => OS.Process.exit OS.Process.failure;
