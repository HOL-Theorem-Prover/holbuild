(* HOL 9b7e182fe adds combinator-token spans.  Deliberately ignore those
   annotations here: existing step extents and labels measure operands. *)
structure HolbuildTacticParseAdapter =
struct
  datatype 'a view =
      ByNode of 'a * 'a TacticParse.tac_expr
    | SufficesByNode of 'a * 'a TacticParse.tac_expr
    | Then1Node of 'a TacticParse.tac_expr
    | Other of 'a TacticParse.tac_expr

  fun view (TacticParse.By (quotation, _, body)) = ByNode (quotation, body)
    | view (TacticParse.SufficesBy (quotation, _, body)) = SufficesByNode (quotation, body)
    | view (TacticParse.LThen1 (_, body)) = Then1Node body
    | view tactic = Other tactic
end
