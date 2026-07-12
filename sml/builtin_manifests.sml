structure HolbuildBuiltinManifests =
struct

val holdir_manifest_name = "builtin:HOLDIR"

fun toml_string s =
  "\"" ^ String.translate (fn #"\\" => "\\\\" | #"\"" => "\\\"" | c => str c) s ^ "\""

fun manifest_text members =
  String.concatWith "\n"
    ( ["# Built-in manifest for the reserved HOL dependency.",
       "# The shared toolchain builds the configured HOL sequence into sigobj;",
       "# remaining default-build source directories are generated per toolchain.",
       "",
       "[holbuild]",
       "schema = 2",
       "minimum_version = \"0.10.0\"",
       "",
       "[project]",
       "name = \"hol\"",
       "version = \"builtin-implicit-hol\"",
       "",
       "[build]",
       "members = ["] @
      map (fn member => "  " ^ toml_string member ^ ",") members @
      ["]",
       "exclude_globs = [",
       "  \"*/selftest.sml\",",
       "  \"*/test.sml\",",
       "  \"*/tests/*\",",
       "  \"*/theory_tests/*\",",
       "  \"*/examples/*\",",
       "  \"*/Manual/*\",",
       "  \"src/emit/MLton/*\",",
       "  \"src/portableML/mlton/*\",",
       "  \"src/portableML/mosml/*\",",
       "  \"src/simp/src/mosml/*\",",
       "  \"src/tracing/no/*\",",
       "  \"src/num/reduce/conv-old/*\",",
       "]",
       ""] )

val empty_hol_manifest_text = manifest_text []

(* Toolchain caches created before minimum_version became mandatory contain a
   generated manifest with only the legacy schema marker. Upgrade that trusted
   generated text while reading it; regenerating the source inventory would
   make otherwise-cheap context commands invoke Holmake. *)
fun upgrade_cached_manifest_text text =
  let
    val lines = String.tokens (fn c => c = #"\n") text
    val has_minimum =
      List.exists (fn line => String.isPrefix "minimum_version" line) lines
    fun add [] = []
      | add (line :: rest) =
          if line = "[holbuild]" then
            line :: "minimum_version = \"0.10.0\"" :: add rest
          else line :: add rest
  in
    if has_minimum then text else String.concatWith "\n" (add lines) ^ "\n"
  end

end
