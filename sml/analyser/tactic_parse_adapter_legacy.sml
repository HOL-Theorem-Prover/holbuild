(* Uniform view of the constructors whose annotations changed in HOL. *)
structure HolbuildTacticParseAdapter =
struct
  datatype 'a view =
      ByNode of 'a * 'a TacticParse.tac_expr
    | SufficesByNode of 'a * 'a TacticParse.tac_expr
    | Then1Node of 'a TacticParse.tac_expr
    | Other of 'a TacticParse.tac_expr

  fun view (TacticParse.By (quotation, body)) = ByNode (quotation, body)
    | view (TacticParse.SufficesBy (quotation, body)) = SufficesByNode (quotation, body)
    | view (TacticParse.LThen1 body) = Then1Node body
    | view tactic = Other tactic
end
