structure HolbuildVersion =
struct

exception Error of string

val version = "0.6.0"

type semver = {major : int, minor : int, patch : int}

fun all_digits s =
  size s > 0 andalso List.all Char.isDigit (String.explode s)

fun parse_component label text =
  if all_digits text then
    case Int.fromString text of
        SOME n => n
      | NONE => raise Error ("invalid semver " ^ label ^ ": " ^ text)
  else raise Error ("invalid semver " ^ label ^ ": " ^ text)

fun parse text =
  case String.fields (fn c => c = #".") text of
      [major, minor, patch] =>
        {major = parse_component "major" major,
         minor = parse_component "minor" minor,
         patch = parse_component "patch" patch}
    | _ => raise Error ("expected MAJOR.MINOR.PATCH, got " ^ HolbuildHash.quote text)

val current = parse version

fun compare ({major = a1, minor = b1, patch = c1}, {major = a2, minor = b2, patch = c2}) =
  case Int.compare(a1, a2) of
      EQUAL =>
        (case Int.compare(b1, b2) of
             EQUAL => Int.compare(c1, c2)
           | order => order)
    | order => order

fun to_string {major, minor, patch} =
  Int.toString major ^ "." ^ Int.toString minor ^ "." ^ Int.toString patch

fun require_at_least required_text =
  let val required = parse required_text
  in
    case compare(current, required) of
        LESS =>
          raise Error ("project requires holbuild >= " ^ to_string required ^
                       ", but this is holbuild " ^ version)
      | _ => ()
  end

end
