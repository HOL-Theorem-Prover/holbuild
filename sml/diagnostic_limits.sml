structure HolbuildDiagnosticLimits =
struct

fun strict_nonnegative_int text =
  if size text > 0 andalso List.all Char.isDigit (String.explode text)
  then Int.fromString text else NONE

(* Read on use: a restored checkpoint must use this invocation's settings. *)
fun from_env name =
  case OS.Process.getEnv name of
      NONE => 4096
    | SOME "unlimited" => 0
    | SOME value =>
        (case strict_nonnegative_int value of
             SOME n => n
           | NONE => raise Fail (name ^ "=" ^ value ^
               ": expected a nonnegative integer byte limit or unlimited (0 disables truncation)"))

fun failed_goals () = from_env "HOLBUILD_FAILED_GOALS_LIMIT"
fun goal_state () = from_env "HOLBUILD_GOAL_STATE_LIMIT"

fun validate () = (ignore (failed_goals ()); ignore (goal_state ()))

end
