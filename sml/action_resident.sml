(* What a remote-exec worker's action root holds between actions (DESIGN.md,
   "Persistent action root on workers"): each dependency theory, file and
   library manifest exec-action installed there, by its absolute path, with
   what it was installed from and the hashes the parent checks and the early
   cutoff read.  exec-action alone writes the dependency tree, under the
   worker's action.lock; theory children may only read it.

   A hydrate deletes the record file before it changes the tree and writes
   it back once it has passed, so a worker that stops part way finds none and
   starts from an empty root. *)
structure HolbuildActionResident =
struct

type theory =
  {target : string, key : string,
   (* SHA-256 of the local cache manifest the theory was installed from. *)
   source : string,
   (* What its .uo manifest was generated from. *)
   parents : string list, mldeps : string list,
   (* The .dat by the hash its children record, and the parents' it records. *)
   dat_hash : string, dat_parents : (string * string) list,
   (* SHA-256 of each of hashed_suffixes, once hashed. *)
   hashes : string list}

val hashed_suffixes = [".sig", ".sml", ".ui", ".uo"]

datatype entry =
    Theory of theory
  | File of string
  | Manifest of string
  (* Outputs one action writes at a stem besides its dependencies: its own
     and those of parents it loads ahead of, with their key.  The next
     hydrate removes them. *)
  | Scratch of string

type t =
  {file : string option, entries : (string, entry) Binarymap.dict ref,
   wanted : string Binaryset.set ref, lock : Mutex.mutex}

val header = "holbuild-action-resident-v1"

fun new file entries =
  {file = file, entries = ref entries, wanted = ref (Binaryset.empty String.compare), lock = Mutex.mutex ()}

(* Records that are never written, for a root emptied before its action. *)
fun empty () = new NONE (Binarymap.mkDict String.compare)

fun locked ({lock, ...} : t) f =
  (Mutex.lock lock; (f () before Mutex.unlock lock) handle e => (Mutex.unlock lock; raise e))

fun commas [] = "-"
  | commas items = String.concatWith "," items

fun uncommas "-" = []
  | uncommas text = String.fields (fn c => c = #",") text

fun line (path, entry) =
  String.concatWith "\t"
    (case entry of
         Theory {target, key, source, parents, mldeps, dat_hash, dat_parents, hashes} =>
           ["theory", path, target, key, source, commas parents, commas mldeps, dat_hash,
            commas (map (fn (name, hash) => name ^ "=" ^ hash) dat_parents), commas hashes]
       | File sha => ["file", path, sha]
       | Manifest sha => ["manifest", path, sha]
       | Scratch key => ["scratch", path, key]) ^ "\n"

exception Malformed

fun parse_line text =
  case String.fields (fn c => c = #"\t") text of
      ["theory", path, target, key, source, parents, mldeps, dat_hash, dat_parents, hashes] =>
        (path,
         Theory {target = target, key = key, source = source, parents = uncommas parents, mldeps = uncommas mldeps,
                 dat_hash = dat_hash,
                 dat_parents =
                   map (fn pair => case String.fields (fn c => c = #"=") pair of
                                       [name, hash] => (name, hash)
                                     | _ => raise Malformed)
                       (uncommas dat_parents),
                 hashes = uncommas hashes})
    | ["file", path, sha] => (path, File sha)
    | ["manifest", path, sha] => (path, Manifest sha)
    | ["scratch", path, key] => (path, Scratch key)
    | _ => raise Malformed

fun read_file path =
  let val input = TextIO.openIn path
  in (TextIO.inputAll input before TextIO.closeIn input) handle e => (TextIO.closeIn input; raise e) end

fun remove_file path = OS.FileSys.remove path handle OS.SysErr _ => ()

(* No records, kept at FILE once saved. *)
fun fresh file = new (SOME file) (Binarymap.mkDict String.compare)

(* The records kept at FILE; NONE when there are none or they can't be read. *)
fun read file =
  let
    val text = SOME (read_file file) handle _ => NONE
  in
    case Option.map (String.tokens (fn c => c = #"\n")) text of
        SOME (first :: lines) =>
          if first <> header then NONE
          else
            (SOME (new (SOME file)
                       (List.foldl (fn (text, dict) => let val (path, entry) = parse_line text
                                                       in Binarymap.insert (dict, path, entry) end)
                                   (Binarymap.mkDict String.compare) lines))
             handle Malformed => NONE)
      | _ => NONE
  end

(* Before the tree changes: a worker stopped from here on finds no records. *)
fun discard ({file, ...} : t) = Option.app remove_file file

fun save ({file, entries, ...} : t) =
  case file of
      NONE => ()
    | SOME path =>
        let
          val text = String.concat (header ^ "\n" :: map line (Binarymap.listItems (!entries)))
          val tmp = path ^ ".tmp"
          val output = TextIO.openOut tmp
        in
          (TextIO.output (output, text); TextIO.closeOut output; OS.FileSys.rename {old = tmp, new = path})
          handle e => (TextIO.closeOut output handle _ => (); remove_file tmp; raise e)
        end

(* A hydrate names what it wants in the root; prune drops the rest. *)
fun start (t as {wanted, ...} : t) = locked t (fn () => wanted := Binaryset.empty String.compare)

fun want (t as {wanted, ...} : t) path = locked t (fn () => wanted := Binaryset.add (!wanted, path))

fun find (t as {entries, ...} : t) path = locked t (fn () => Binarymap.peek (!entries, path))

fun put (t as {entries, wanted, ...} : t) path entry =
  locked t (fn () => (entries := Binarymap.insert (!entries, path, entry); wanted := Binaryset.add (!wanted, path)))

fun theory t path = case find t path of SOME (Theory theory) => SOME theory | _ => NONE

(* The theories recorded without their files' hashes. *)
fun unhashed (t as {entries, ...} : t) =
  locked t (fn () => List.mapPartial (fn (path, Theory {hashes = [], ...}) => SOME path | _ => NONE)
                                     (Binarymap.listItems (!entries)))

(* The keys of the recorded theories and scratch stems. *)
fun keys (t as {entries, ...} : t) =
  locked t (fn () => List.mapPartial (fn (_, Theory {key, ...}) => SOME key | (_, Scratch key) => SOME key | _ => NONE)
                                     (Binarymap.listItems (!entries)))

(* Records HASHES, of hashed_suffixes, for the theory at PATH. *)
fun hashed (t as {entries, ...} : t) path hashes =
  locked t (fn () =>
    case Binarymap.peek (!entries, path) of
        SOME (Theory {target, key, source, parents, mldeps, dat_hash, dat_parents, ...}) =>
          entries := Binarymap.insert (!entries, path,
                       Theory {target = target, key = key, source = source, parents = parents, mldeps = mldeps,
                               dat_hash = dat_hash, dat_parents = dat_parents, hashes = hashes})
      | _ => ())

(* The hash the record of a theory's file at PATH holds, the .dat by the
   hash its children record. *)
fun file_hash t path =
  let
    fun record suffix = theory t (String.substring (path, 0, size path - size suffix))
    fun nth (x :: _, 0) = SOME x
      | nth (_ :: rest, n) = nth (rest, n - 1)
      | nth ([], _) = NONE
    fun by_suffix _ [] = NONE
      | by_suffix n (suffix :: rest) =
          if String.isSuffix suffix path then Option.mapPartial (fn {hashes, ...} => nth (hashes, n)) (record suffix)
          else by_suffix (n + 1) rest
  in
    if String.isSuffix ".dat" path then Option.map #dat_hash (record ".dat")
    else by_suffix 0 hashed_suffixes
  end

(* Removes, with REMOVE, every entry the hydrate didn't want. *)
fun prune (t as {entries, wanted, ...} : t) remove =
  let
    val unwanted =
      locked t (fn () => List.filter (fn (path, _) => not (Binaryset.member (!wanted, path)))
                                     (Binarymap.listItems (!entries)))
  in
    List.app (fn (path, entry) =>
                (remove (path, entry);
                 locked t (fn () => entries := #1 (Binarymap.remove (!entries, path)))))
             unwanted
  end

end
