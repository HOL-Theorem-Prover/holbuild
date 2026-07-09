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

end
