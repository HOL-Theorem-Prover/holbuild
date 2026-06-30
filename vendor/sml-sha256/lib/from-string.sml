(* Vendored by holbuild from https://github.com/diku-dk/sml-sha256.
   MIT licensed; see vendor/sml-sha256/LICENSE and AUTHORS. *)

structure FromString :> FROM_STRING =
   struct

      type cs = Substring.substring

      fun scanSubstringAll scan str =
         (case scan Substring.getc str of
             SOME (x, tail) =>
                if Substring.isEmpty tail then
                   SOME x
                else
                   NONE
           | NONE => NONE)

      fun scanStringAll scan str = scanSubstringAll scan (Substring.full str)

      val toInt = scanStringAll (Int.scan StringCvt.DEC)
      val toWord8 = scanStringAll (Word8.scan StringCvt.DEC)
      val toWord8Hex = scanStringAll (Word8.scan StringCvt.HEX)

   end
