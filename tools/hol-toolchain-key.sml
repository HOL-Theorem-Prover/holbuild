(* Compute the schema-2 HOL toolchain cache key.
 * Keep this in lockstep with sml/hol_shared_cache.sml until the key computation
 * can move behind a holbuild subcommand.
 *)

val format_version = "holbuild-hol-toolchain-v1"
val default_canonical_git = "https://github.com/HOL-Theorem-Prover/HOL.git"
val build_args = ""

fun quote s =
  "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun die msg = (TextIO.output(TextIO.stdErr, msg ^ "\n"); OS.Process.exit OS.Process.failure)

fun command_output command =
  let
    val tmp = OS.FileSys.tmpName ()
    val status = OS.Process.system (command ^ " > " ^ quote tmp ^ " 2>&1")
    val input = TextIO.openIn tmp
    val text = TextIO.inputAll input before TextIO.closeIn input
    val _ = OS.FileSys.remove tmp handle OS.SysErr _ => ()
  in
    if OS.Process.isSuccess status then text
    else die ("command failed: " ^ command ^ "\n" ^ text)
  end
  handle e => die ("command failed: " ^ command ^ ": " ^ General.exnMessage e)

fun trim text =
  let
    fun ws c = Char.isSpace c
    val n = size text
    fun left i = if i < n andalso ws (String.sub(text, i)) then left (i + 1) else i
    fun right i = if i >= 0 andalso ws (String.sub(text, i)) then right (i - 1) else i
    val l = left 0
    val r = right (n - 1)
  in if r < l then "" else String.substring(text, l, r - l + 1) end

fun canonical_git () = Option.getOpt(OS.Process.getEnv "HOLBUILD_CANONICAL_HOL_GIT", default_canonical_git)
fun poly_command () = Option.getOpt(OS.Process.getEnv "HOLBUILD_POLY", "poly")
fun poly_version () = trim (command_output (quote (poly_command ()) ^ " -v"))

fun key_material rev =
  String.concatWith "\n"
    [format_version, "git=" ^ canonical_git (), "rev=" ^ rev, "poly=" ^ poly_command (),
     "poly_version=" ^ poly_version (), "build_args=" ^ build_args]

fun sha1 text =
  let
    val input = OS.FileSys.tmpName ()
    val output = OS.FileSys.tmpName ()
    val out = TextIO.openOut input
    val _ = TextIO.output(out, text)
    val _ = TextIO.closeOut out
    val status = OS.Process.system ("sha1sum " ^ quote input ^ " > " ^ quote output)
    val inS = TextIO.openIn output
    val result = TextIO.inputAll inS before TextIO.closeIn inS
    val _ = OS.FileSys.remove input handle OS.SysErr _ => ()
    val _ = OS.FileSys.remove output handle OS.SysErr _ => ()
  in
    if OS.Process.isSuccess status then
      case String.tokens Char.isSpace result of
          hash :: _ => hash
        | [] => die "sha1sum produced no output"
    else die "sha1sum failed"
  end
  handle e => die ("sha1sum failed: " ^ General.exnMessage e)

fun key rev = sha1 (key_material rev)

fun main () =
  case OS.Process.getEnv "HOLBUILD_TOOLCHAIN_KEY_REV" of
      SOME rev => (print (key rev); print "\n")
    | NONE => die "usage: hol-toolchain-key.sml HOL_REV"

val _ = main ()
