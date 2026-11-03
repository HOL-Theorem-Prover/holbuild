(* Nearest-name suggestions for a name that did not resolve, ranked from
   the candidate names the caller already has. *)
structure HolbuildSuggest =
struct

val max_suggestions = 3

(* Optimal string alignment distance, ignoring case: insertions, deletions,
   substitutions and swaps of adjacent characters each cost one. *)
fun distance (a, b) =
  let
    val a = String.map Char.toLower a
    val b = String.map Char.toLower b
    val n = size a
    val m = size b
    val d = Array2.array (n + 1, m + 1, 0)
    fun at (i, j) = Array2.sub (d, i, j)
    fun cell i j =
      if i = 0 then j
      else if j = 0 then i
      else
        let
          val ai = String.sub (a, i - 1)
          val bj = String.sub (b, j - 1)
          val best = Int.min (Int.min (at (i - 1, j) + 1, at (i, j - 1) + 1),
                              at (i - 1, j - 1) + (if ai = bj then 0 else 1))
        in
          if i > 1 andalso j > 1 andalso ai = String.sub (b, j - 2)
             andalso String.sub (a, i - 2) = bj
          then Int.min (best, at (i - 2, j - 2) + 1)
          else best
        end
  in
    Array2.modifyi Array2.RowMajor (fn (i, j, _) => cell i j)
      {base = d, row = 0, col = 0, nrows = NONE, ncols = NONE};
    at (n, m)
  end

(* One edit per four characters of the name, and at least one. *)
fun cutoff name = Int.max (1, size name div 4)

fun closer ((d1, c1), (d2, c2)) =
  d1 < d2 orelse (d1 = d2 andalso String.< (c1, c2))

fun insert x [] = [x]
  | insert x (y :: ys) =
      if #2 x = #2 y then y :: ys
      else if closer (x, y) then x :: y :: ys
      else y :: insert x ys

(* The candidates within the cutoff of name, nearest first, ties in string
   order; at most max_suggestions, never name itself. *)
fun nearest name candidates =
  let
    val limit = cutoff name
    fun add (candidate, acc) =
      if candidate = name orelse abs (size candidate - size name) > limit then acc
      else
        let val d = distance (name, candidate)
        in if d <= limit then insert (d, candidate) acc else acc end
    val ranked = List.foldl add [] candidates
  in
    map #2 (List.take (ranked, Int.min (max_suggestions, length ranked)))
  end

(* A line to append to an error about name: "" when nothing is near. *)
fun did_you_mean name candidates =
  case nearest name candidates of
      [] => ""
    | names => "\ndid you mean " ^ String.concatWith ", " names ^ "?"

end
