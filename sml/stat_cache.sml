structure HolbuildStatCache =
struct

type ident = {dev : string, ino : string, size : int,
              mtime_ns : LargeInt.int, ctime_ns : LargeInt.int}

type entry = ident * string

type instance =
  {path : string option,
   entries : (string, entry) Binarymap.dict ref,
   mutex : Mutex.mutex,
   enabled : bool,
   hits : int ref,
   recomputes : int ref}

val version = "holbuild-stat-cache-v1"

fun empty_entries () = Binarymap.mkDict String.compare

fun new_instance enabled path entries =
  {path = path,
   entries = ref entries,
   mutex = Mutex.mutex (),
   enabled = enabled,
   hits = ref 0,
   recomputes = ref 0}

val no_op_instance = new_instance false NONE (empty_entries ())

val global_instance : instance option ref = ref NONE

fun current_instance () =
  case !global_instance of
      SOME instance => instance
    | NONE => no_op_instance

fun set_current_instance instance = global_instance := SOME instance
fun clear_current_instance () = global_instance := NONE

fun with_lock (instance : instance) f =
  (Mutex.lock (#mutex instance); f () before Mutex.unlock (#mutex instance))
  handle e => (Mutex.unlock (#mutex instance); raise e)

fun stats (instance : instance) =
  with_lock instance
    (fn () => {hits = !(#hits instance), recomputes = !(#recomputes instance)})

fun reset_counters (instance : instance) =
  with_lock instance
    (fn () => (#hits instance := 0; #recomputes instance := 0))

fun stat_ident path =
  SOME (let val st = Posix.FileSys.stat path
        in {dev = SysWord.toString (Posix.FileSys.devToWord (Posix.FileSys.ST.dev st)),
            ino = SysWord.toString (Posix.FileSys.inoToWord (Posix.FileSys.ST.ino st)),
            size = Position.toInt (Posix.FileSys.ST.size st),
            mtime_ns = Time.toNanoseconds (Posix.FileSys.ST.mtime st),
            ctime_ns = Time.toNanoseconds (Posix.FileSys.ST.ctime st)}
        end)
  handle _ => NONE

fun same_ident ({dev = dev1, ino = ino1, size = size1,
                 mtime_ns = mtime1, ctime_ns = ctime1} : ident,
                {dev = dev2, ino = ino2, size = size2,
                 mtime_ns = mtime2, ctime_ns = ctime2} : ident) =
  dev1 = dev2 andalso ino1 = ino2 andalso size1 = size2 andalso
  mtime1 = mtime2 andalso ctime1 = ctime2

fun read_text path =
  let val input = TextIO.openIn path
      val text = TextIO.inputAll input handle e => (TextIO.closeIn input; raise e)
  in
    TextIO.closeIn input;
    text
  end

fun remove_file path = OS.FileSys.remove path handle OS.SysErr _ => ()

fun rename_replace {old, new} =
  OS.FileSys.rename {old = old, new = new}
  handle e =>
    (remove_file new;
     OS.FileSys.rename {old = old, new = new}
     handle _ => raise e)

fun tmp_path_for path =
  let
    val dir = OS.Path.dir path
    val file = OS.Path.file path
    val tmp_file = "." ^ file ^ "." ^ OS.Path.file (OS.FileSys.tmpName ()) ^ ".tmp"
  in
    OS.Path.concat (dir, tmp_file)
  end

fun write_text_atomically path text =
  let
    val tmp = tmp_path_for path
    val output = TextIO.openOut tmp
    fun close_output () = TextIO.closeOut output handle _ => ()
  in
    (TextIO.output (output, text);
     TextIO.closeOut output;
     rename_replace {old = tmp, new = path})
    handle e => (close_output (); remove_file tmp; raise e)
  end

fun drop_trailing_cr text =
  if size text > 0 andalso String.sub (text, size text - 1) = #"\r" then
    String.substring (text, 0, size text - 1)
  else text

fun parse_entry line =
  case String.fields (fn c => c = #"\t") line of
      [path_text, dev, ino, size_text, mtime_text, ctime_text, sha1] =>
        (case (String.fromString path_text,
               Int.fromString size_text,
               LargeInt.fromString mtime_text,
               LargeInt.fromString ctime_text) of
             (SOME path, SOME size, SOME mtime_ns, SOME ctime_ns) =>
               if HolbuildHash.valid_sha1 sha1 then
                 SOME (path, ({dev = dev, ino = ino, size = size,
                               mtime_ns = mtime_ns, ctime_ns = ctime_ns}, sha1))
               else NONE
           | _ => NONE)
    | _ => NONE

fun parse_entries lines =
  let
    fun loop [] entries = SOME entries
      | loop (line :: rest) entries =
          let val line' = drop_trailing_cr line
          in
            if line' = "" then loop rest entries
            else
              case parse_entry line' of
                  SOME (path, entry) =>
                    loop rest (Binarymap.insert (entries, path, entry))
                | NONE => NONE
          end
  in
    loop lines (empty_entries ())
  end

fun load {path} =
  let
    val entries =
      case (SOME (read_text path) handle _ => NONE) of
          NONE => empty_entries ()
        | SOME text =>
            (case String.fields (fn c => c = #"\n") text of
                 [] => empty_entries ()
               | first :: rest =>
                   if drop_trailing_cr first <> version then empty_entries ()
                   else
                     case parse_entries rest of
                         SOME parsed => parsed
                       | NONE => empty_entries ())
  in
    new_instance true (SOME path) entries
  end

fun entry_line (path, ({dev, ino, size, mtime_ns, ctime_ns} : ident, sha1)) =
  String.concat
    [String.toString path, "\t", dev, "\t", ino, "\t", Int.toString size, "\t",
     LargeInt.toString mtime_ns, "\t", LargeInt.toString ctime_ns, "\t", sha1, "\n"]

fun prune_missing_entries (instance : instance) =
  with_lock instance
    (fn () =>
        let
          val live =
            List.filter (fn (path, _) => Option.isSome (stat_ident path))
                        (Binarymap.listItems (!(#entries instance)))
          val entries =
            List.foldl (fn ((path, entry), dict) => Binarymap.insert (dict, path, entry))
                       (empty_entries ())
                       live
        in
          #entries instance := entries
        end)

fun flush (instance : instance) =
  if not (#enabled instance) then ()
  else
    case #path instance of
        NONE => ()
      | SOME path =>
          let
            (* Build stage artifacts are keyed by transient inputs and are
               removed after publication.  Do not retain their dead paths in
               the persistent cache forever. *)
            val _ = prune_missing_entries instance
            val items =
              with_lock instance
                (fn () => Binarymap.listItems (!(#entries instance)))
            val text = version ^ "\n" ^ String.concat (map entry_line items)
          in
            write_text_atomically path text
          end

fun file_sha1 (instance : instance) path =
  if not (#enabled instance) then HolbuildHash.file_sha1 path
  else
    case stat_ident path of
        NONE => HolbuildHash.file_sha1 path
      | SOME ident =>
          (case with_lock instance
                   (fn () => Binarymap.peek (!(#entries instance), path)) of
               SOME (cached_ident, sha1) =>
                 if same_ident (ident, cached_ident) then
                   with_lock instance
                     (fn () => (#hits instance := !(#hits instance) + 1; sha1))
                 else rehash_file_sha1 instance path ident
             | NONE => rehash_file_sha1 instance path ident)

and rehash_file_sha1 (instance : instance) path ident =
  let val sha1 = HolbuildHash.file_sha1 path
  in
    (* The identity used to index the hash must describe the bytes we just
       read.  Otherwise a same-size write on a coarse-timestamp filesystem can
       persist a hash for the wrong action input. *)
    case stat_ident path of
        SOME final_ident =>
          if same_ident (ident, final_ident) then
            with_lock instance
              (fn () =>
                  (#recomputes instance := !(#recomputes instance) + 1;
                   #entries instance :=
                     Binarymap.insert (!(#entries instance), path, (final_ident, sha1));
                   sha1))
          else file_sha1 instance path
      | NONE => file_sha1 instance path
  end

end
