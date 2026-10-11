(* Inspect the installed signature, as the tactic ABI loader does.  Ignore
   whitespace, but reject unknown constructor shapes rather than guessing. *)
structure HolbuildTacticParseCapabilities =
struct
  fun has_token_spans text =
    let
      val compact = String.implode
        (List.filter (fn c => not (Char.isSpace c)) (String.explode text))
    in
      if String.isSubstring "|Byof'a*'a*'atac_expr" compact then true
      else if String.isSubstring "|Byof'a*'atac_expr" compact then false
      else raise Fail "unsupported TacticParse.By signature"
    end
end
