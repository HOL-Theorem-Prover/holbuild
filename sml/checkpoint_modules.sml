(* Checks that the theory modules a module-dependent checkpoint was saved
   against are still on disk with the same ids.  Poly/ML's
   saveChildWithModules records, in each saved state, the (id, path) of every
   module it refers to instead of copying; a state's parents record the
   modules they added.  Loading the state loads those modules, and fails if
   one is missing or has another id.

   The files are read directly rather than with PolyML.SaveState: the driver
   may run on another Poly/ML than the child that wrote them, and
   getModuleInfo rejects modules written by another executable.  Layouts are
   those of Poly/ML's 64-bit SavedStateHeader (version 3, and version 4 with a
   module table), ModuleTableEntry and ModuleHeader. *)
structure HolbuildCheckpointModules =
struct

datatype problem = Missing of string | Changed of string

(* Reads LEN bytes at OFFSET; fewer at the end of the file. *)
fun read_at fd offset len =
  (ignore (Posix.IO.lseek (fd, Position.fromInt offset, Posix.IO.SEEK_SET));
   Posix.IO.readVec (fd, len))

fun with_file path f =
  let val fd = Posix.FileSys.openf (path, Posix.FileSys.O_RDONLY, Posix.FileSys.O.flags [])
  in (f fd before Posix.IO.close fd) handle e => (Posix.IO.close fd; raise e) end

fun le_int (v : Word8Vector.vector) offset bytes =
  let
    fun loop i acc =
      if i < 0 then acc
      else loop (i - 1) (acc * 256 + Word8.toInt (Word8Vector.sub (v, offset + i)))
  in
    loop (bytes - 1) 0
  end

fun bytes_text v = Byte.bytesToString v

val state_v3_length = 88
val state_v4_length = 104
val module_table_entry_length = 12
val module_id_offset = 36

(* The parent path and module table of a saved state; NONE if it isn't a
   saved state this layout describes. *)
fun read_state path =
  with_file path (fn fd =>
    let val header = read_at fd 0 state_v4_length
    in
      if Word8Vector.length header < state_v3_length orelse
         bytes_text (Word8VectorSlice.vector (Word8VectorSlice.slice (header, 0, SOME 8))) <> "POLYSAVE"
      then NONE
      else
        let
          val version = le_int header 8 4
          val length = le_int header 12 4
          val v4 = version = 4 andalso length = state_v4_length andalso
                   Word8Vector.length header = state_v4_length
          val parent =
            let
              val string_table = le_int header 40 8
              val string_size = le_int header 48 8
              val entry = le_int header 56 4
            in
              if entry = 0 orelse entry >= string_size then NONE
              else
                let
                  val text = bytes_text (read_at fd (string_table + entry) (string_size - entry))
                in
                  SOME (hd (String.fields (fn c => c = #"\000") text))
                end
            end
          fun table offset count =
            if count = 0 then []
            else
              let
                val entry = read_at fd offset module_table_entry_length
                val id = Word8VectorSlice.vector (Word8VectorSlice.slice (entry, 0, SOME 8))
                val path_length = le_int entry 8 4
                val module_path = bytes_text (read_at fd (offset + module_table_entry_length) path_length)
              in
                (id, module_path) :: table (offset + module_table_entry_length + path_length) (count - 1)
              end
        in
          if version = 3 andalso length = state_v3_length then SOME (parent, [])
          else if v4 then SOME (parent, table (le_int header 88 8) (le_int header 96 4))
          else NONE
        end
    end)

(* The parent recorded in a saved state, as PolyML.SaveState.showParent
   gives it. *)
fun parent path =
  case (read_state path handle OS.SysErr _ => NONE) of
      SOME (p, _) => p
    | NONE => NONE

fun module_id path =
  with_file path (fn fd =>
    let val header = read_at fd 0 (module_id_offset + 8)
    in
      if Word8Vector.length header < module_id_offset + 8 then NONE
      else SOME (Word8VectorSlice.vector (Word8VectorSlice.slice (header, module_id_offset, SOME 8)))
    end)

(* The first module recorded by the state at PATH or one of its parents
   that is missing or has another id, if any. *)
fun check path =
  let
    fun check_module (id, module_path) =
      case (SOME (module_id module_path) handle OS.SysErr _ => NONE) of
          NONE => SOME (Missing module_path)
        | SOME (SOME found) => if found = id then NONE else SOME (Changed module_path)
        | SOME NONE => SOME (Changed module_path)
    fun walk state =
      case (read_state state handle OS.SysErr _ => NONE) of
          NONE => NONE
        | SOME (next, modules) =>
            case List.foldl (fn (m, NONE) => check_module m | (_, found) => found) NONE modules of
                SOME found => SOME found
              | NONE => (case next of SOME p => walk p | NONE => NONE)
  in
    walk path
  end

(* Module-dependent checkpoints skipped in this process because a module
   they need was missing or changed. *)
val skipped = ref 0

fun describe (Missing path) = path ^ " missing"
  | describe (Changed path) = path ^ " has another id"

(* True if the checkpoint at PATH can be restored; otherwise warns, counts
   the skip and returns false.  The caller discards the checkpoint. *)
fun ok path =
  case check path of
      NONE => true
    | SOME found =>
        (skipped := !skipped + 1;
         TextIO.output (TextIO.stdErr,
           "holbuild: warning: module-dependent checkpoint skipped: " ^ describe found ^
           " (checkpoint " ^ path ^ ", skips=" ^ Int.toString (!skipped) ^ ")\n");
         false)

end
