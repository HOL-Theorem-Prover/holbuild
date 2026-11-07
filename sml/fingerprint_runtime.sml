(* Statement fingerprints: the SHA-256 of a canonical encoding of a sequent.
   Constants and type operators are named with their theories, free variables
   with their names and types, and bound variables by de Bruijn index, so
   alpha-equivalent statements agree and no pretty-printing or theory-table
   detail leaks in.  `holbuild check --fingerprint` prints these for theorems
   loaded from disk; a script calls the same functions in-session. *)
structure HolbuildFingerprint =
struct

local
  fun str s = Int.toString (size s) ^ ":" ^ s

  (* The encoders build the text in reverse, as a list of pieces. *)
  fun push pieces acc = List.revAppend (pieces, acc)

  fun encode_type ty acc =
    if Type.is_vartype ty then push ["v", str (Type.dest_vartype ty)] acc
    else
      let val {Thy, Tyop, Args} = Type.dest_thy_type ty
      in
        List.foldl (fn (arg, acc) => encode_type arg acc)
                   (push ["t", str Thy, str Tyop, Int.toString (length Args), ":"] acc)
                   Args
      end

  (* bound: the enclosing binders as (name, type), innermost first.  The
     standard kernel's dest_abs renames a binder whose name occurs free in its
     body; the experimental kernel's keeps it, and there a variable of the
     binder's name and type in the body is bound by it. *)
  fun index_of (name, ty) bound =
    let
      fun find _ [] = NONE
        | find i ((b, bty) :: rest) =
            if b = name andalso Type.compare (bty, ty) = EQUAL then SOME i
            else find (i + 1) rest
    in find 0 bound end

  fun encode_term bound tm acc =
    case Term.dest_term tm of
        Term.CONST {Thy, Name, Ty} => encode_type Ty (push ["c", str Thy, str Name] acc)
      | Term.VAR (name, ty) =>
          (case index_of (name, ty) bound of
               SOME i => push ["b", Int.toString i, ":"] acc
             | NONE => encode_type ty (push ["f", str name] acc))
      | Term.COMB (f, x) => encode_term bound x (encode_term bound f ("a" :: acc))
      | Term.LAMB (v, body) =>
          let val (name, ty) = Term.dest_var v
          in encode_term ((name, ty) :: bound) body (encode_type ty ("l" :: acc)) end

  fun encoded tm = String.concat (rev (encode_term [] tm []))

  fun sequent (hyps, concl) =
    HolbuildSha256.string_hex
      (String.concat
         ("holbuild-fingerprint-v1\n" :: Int.toString (length hyps) :: ":" ::
          Listsort.sort String.compare (map encoded hyps) @ [encoded concl]))
in
  (* A theorem's fingerprint, as 64 lowercase hex digits: the hash of its
     statement, hypotheses included. *)
  fun thm th = sequent (Thm.hyp th, Thm.concl th)

  (* The fingerprint of |- tm, which equals that of any theorem proving tm
     with no hypotheses. *)
  fun term tm = sequent ([], tm)
end

end
