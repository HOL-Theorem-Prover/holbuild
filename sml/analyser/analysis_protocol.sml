structure HolbuildAnalysisProtocol =
struct

val protocol_version = "1"
val analyser_format_version = "holbuild-hol-analyser-v2"

fun escape s =
  let
    fun add (c, acc) =
      case c of
          #"\\" => #"\\" :: #"\\" :: acc
        | #"\n" => #"n" :: #"\\" :: acc
        | #"\t" => #"t" :: #"\\" :: acc
        | #" " => #"s" :: #"\\" :: acc
        | c => c :: acc
  in
    String.implode (rev (List.foldl add [] (String.explode s)))
  end

fun unescape s =
  let
    val n = size s
    fun loop i acc =
      if i >= n then String.implode (rev acc)
      else
        case String.sub(s, i) of
            #"\\" =>
              if i + 1 >= n then loop (i + 1) (#"\\" :: acc)
              else
                (case String.sub(s, i + 1) of
                     #"\\" => loop (i + 2) (#"\\" :: acc)
                   | #"n" => loop (i + 2) (#"\n" :: acc)
                   | #"t" => loop (i + 2) (#"\t" :: acc)
                   | #"s" => loop (i + 2) (#" " :: acc)
                   | c => loop (i + 2) (c :: #"\\" :: acc))
          | c => loop (i + 1) (c :: acc)
  in
    loop 0 []
  end

fun join fields = String.concatWith " " (map escape fields)
fun split line = map unescape (String.tokens (fn c => c = #" ") line)

(* Nested fields use the same escaping, with separators that preserve empty
   values. The tag keeps an empty attribute list a nonempty outer field. *)
fun encode_proof_attrs attrs =
  String.concatWith "\n" ("attrs" ::
    map (fn (key, values) => String.concatWith "\t" (map escape (key :: values))) attrs)

fun decode_proof_attrs text =
  case String.fields (fn c => c = #"\n") text of
      "attrs" :: rows =>
        map (fn row => case map unescape (String.fields (fn c => c = #"\t") row) of
                          key :: values => (key, values)
                        | [] => raise Fail "bad proof attribute record") rows
    | _ => raise Fail "bad proof attributes"

end
