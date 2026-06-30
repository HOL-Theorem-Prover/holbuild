(* Vendored by holbuild from https://github.com/diku-dk/sml-sha256.
   MIT licensed; see vendor/sml-sha256/LICENSE and AUTHORS. *)

(** Library for SHA256 cryptographic hashing.

    Based on Wikipedia's SHA-256 pseudocode:

    http://en.wikipedia.org/w/index.php?title=SHA-2&oldid=547734565#Pseudocode
*)

signature SHA256 = sig
  val hashStringHex : string -> string
end

(**

[hashStringHex s] returns the hexadecimal string representation of the
sha256 cryptographic hash of s.

*)
