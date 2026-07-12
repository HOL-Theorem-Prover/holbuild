structure HolbuildManifestUtil =
struct

exception Error of string
fun die msg = raise Error msg
fun warn msg = TextIO.output(TextIO.stdErr, "holbuild: warning: " ^ msg ^ "\n")

structure Path = OS.Path

fun lookup table key = TOML.lookupInTable table key
fun key_text key = String.concatWith "." key
fun table_keys table = map (fn (name, _) => name) table
fun member value values = List.exists (fn existing => existing = value) values

fun require_known_fields context allowed table =
  case List.filter (fn name => not (member name allowed)) (table_keys table) of
      [] => ()
    | name :: _ => die ("unknown field in " ^ context ^ ": " ^ name)

fun string_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.STRING s) => SOME s
    | SOME _ => die (key_text key ^ " must be a string")

fun int_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.INTEGER n) => SOME n
    | SOME _ => die (key_text key ^ " must be an integer")

fun bool_at table key =
  case lookup table key of
      NONE => NONE
    | SOME (TOML.BOOL b) => SOME b
    | SOME _ => die (key_text key ^ " must be a boolean")

fun real_value context value =
  case value of
      TOML.FLOAT r => r
    | TOML.INTEGER n =>
        (case Real.fromString (IntInf.toString n) of
             SOME r => r
           | NONE => die (context ^ " is too large"))
    | _ => die (context ^ " must be a non-negative number")

fun tactic_timeout_value context value =
  let val seconds = real_value context value
  in
    if seconds < 0.0 then die (context ^ " must be a non-negative number")
    else if seconds <= 0.0 then NONE
    else SOME seconds
  end

fun tactic_timeout_at context table key =
  case lookup table key of
      NONE => NONE
    | SOME value => tactic_timeout_value context value

fun positive_int_field context n =
  if n >= IntInf.fromInt 1 then
    IntInf.toInt n handle Overflow => die (context ^ " is too large")
  else die (context ^ " must be a positive integer")

fun string_array_value value =
  case value of
      TOML.ARRAY values =>
        let
          fun one (TOML.STRING s) = s
            | one _ = die "expected string array in holproject.toml"
        in SOME (map one values) end
    | _ => NONE

fun string_array_at table key =
  case lookup table key of
      NONE => []
    | SOME value =>
        (case string_array_value value of
             SOME xs => xs
           | NONE => die (key_text key ^ " must be a string array"))

fun table_field table key =
  case lookup table key of
      SOME (TOML.TABLE t) => SOME t
    | SOME _ => die (key_text key ^ " must be a table")
    | NONE => NONE

fun string_field table name = string_at table [name]
fun string_array_field table name = string_array_at table [name]

fun required_string_array_field context table name =
  case lookup table [name] of
      NONE => die (context ^ " requires " ^ name)
    | SOME value =>
        (case string_array_value value of
             SOME xs => xs
           | NONE => die (context ^ "." ^ name ^ " must be a string array"))

fun env_name_char c = Char.isAlphaNum c orelse c = #"_"
fun env_value context name =
  if name = "" then die (context ^ " contains empty environment variable reference")
  else case OS.Process.getEnv name of
           SOME value => value
         | NONE => die (context ^ " references unset environment variable " ^ name)

fun expand_env context text =
  let
    val n = size text
    fun braced start acc =
      let
        fun find j =
          if j >= n then die (context ^ " contains unterminated ${...} reference")
          else if String.sub(text, j) = #"}" then j else find (j + 1)
        val close = find start
        val name = String.substring(text, start, close - start)
      in loop (close + 1) (env_value context name :: acc) end
    and unbraced start acc =
      let
        fun take j = if j < n andalso env_name_char (String.sub(text, j)) then take (j + 1) else j
        val stop = take start
      in
        if stop = start then loop start ("$" :: acc)
        else loop stop (env_value context (String.substring(text, start, stop - start)) :: acc)
      end
    and loop i acc =
      if i >= n then String.concat (rev acc)
      else if String.sub(text, i) = #"$" then
        if i + 1 < n andalso String.sub(text, i + 1) = #"{" then braced (i + 2) acc
        else unbraced (i + 1) acc
      else
        let
          fun plain j = if j < n andalso String.sub(text, j) <> #"$" then plain (j + 1) else j
          val j = plain i
        in loop j (String.substring(text, i, j - i) :: acc) end
  in loop 0 [] end

fun path_string_field context table name =
  Option.map (expand_env (context ^ "." ^ name)) (string_field table name)

fun path_components path = String.tokens (fn c => c = #"/" orelse c = #"\\") path
fun package_relative_path field path =
  if Path.isAbsolute path orelse List.exists (fn component => component = "..") (path_components path)
  then die (field ^ " must be package-root-relative: " ^ path)
  else path
fun package_relative_paths field paths = map (package_relative_path field) paths

fun has_suffix suffix s =
  let val n = size s val m = size suffix
  in n >= m andalso String.substring(s, n - m, m) = suffix end

fun concrete_package_relative_path field path =
  let val components = path_components path val path = package_relative_path field path
  in
    if path = "" then die (field ^ " must not be empty")
    else if has_suffix "/" path orelse has_suffix "\\" path then
      die (field ^ " must not have a trailing slash: " ^ path)
    else if List.exists (fn component => component = ".") components then
      die (field ^ " must not contain . components: " ^ path)
    else path
  end

fun glob_like path = CharVector.exists (fn c => c = #"*" orelse c = #"?") path
fun split_deprecated_excludes context paths =
  let
    fun one (path, (excludes, globs)) =
      if glob_like path then
        let val path = package_relative_path context path
        in warn (context ^ " glob pattern \"" ^ path ^ "\" is deprecated; use " ^ context ^ "_globs instead");
           (excludes, path :: globs)
        end
      else (concrete_package_relative_path context path :: excludes, globs)
    val (excludes, globs) = List.foldl one ([], []) paths
  in (rev excludes, rev globs) end

fun safe_materialized_dependency_name name =
  size name > 0 andalso name <> "." andalso name <> ".." andalso
  List.all (fn c => Char.isAlphaNum c orelse c = #"_" orelse c = #"." orelse c = #"-")
           (String.explode name)
fun require_safe_materialized_dependency_name context name =
  if safe_materialized_dependency_name name then ()
  else die (context ^ " must be a safe dependency name: " ^ name)

fun named_table_entries table key =
  case lookup table key of
      NONE => []
    | SOME (TOML.TABLE entries) =>
        map (fn (name, TOML.TABLE value) => (name, value)
              | (name, _) => die (key_text (key @ [name]) ^ " must be a table")) entries
    | SOME _ => die (key_text key ^ " must be a table")

end
