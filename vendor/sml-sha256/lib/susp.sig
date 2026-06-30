(* Vendored by holbuild from https://github.com/diku-dk/sml-sha256.
   MIT licensed; see vendor/sml-sha256/LICENSE and AUTHORS. *)

signature SUSP =
   sig
      
      type 'a susp

      val delay : (unit -> 'a) -> 'a susp
      val force : 'a susp -> 'a
         
   end
