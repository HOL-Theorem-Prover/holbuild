structure HolbuildOffline =
struct

exception Error of string

val offline = ref false

(* Read at startup, not when exporting the holbuild executable. *)
fun initialize () = offline := OS.Process.getEnv "HOLBUILD_OFFLINE" = SOME "1"
fun enable () = offline := true
fun enabled () = !offline

fun require_online operation =
  if enabled () then
    raise Error ("offline: cannot " ^ operation ^
                 "; run once without --offline (and unset HOLBUILD_OFFLINE) to prepare it")
  else ()

(* Even a local inspection can fetch missing objects in a partial clone.
   GIT_ALLOW_PROTOCOL's empty allowlist denies every transport, including
   helpers and protocols explicitly enabled by repository configuration. *)
fun git_command () = if enabled () then "GIT_ALLOW_PROTOCOL= git" else "git"

fun git_run args =
  if enabled () then
    HolbuildSpawn.run {program = "env", args = ["GIT_ALLOW_PROTOCOL=", "git"] @ args,
                       stderr = HolbuildSpawn.Discard}
  else HolbuildSpawn.run {program = "git", args = args, stderr = HolbuildSpawn.Discard}

end
