(* SHA-256 (FIPS 180-4) over strings.  Planning hashes thousands of short
   canonical texts per invocation, so this reads message words straight out of
   the string and keeps all per-block state in two preallocated arrays. *)
structure HolbuildSha256 =
struct

structure W = Word32

val k : W.word Vector.vector = Vector.fromList
  [0wx428a2f98, 0wx71374491, 0wxb5c0fbcf, 0wxe9b5dba5, 0wx3956c25b, 0wx59f111f1, 0wx923f82a4, 0wxab1c5ed5,
   0wxd807aa98, 0wx12835b01, 0wx243185be, 0wx550c7dc3, 0wx72be5d74, 0wx80deb1fe, 0wx9bdc06a7, 0wxc19bf174,
   0wxe49b69c1, 0wxefbe4786, 0wx0fc19dc6, 0wx240ca1cc, 0wx2de92c6f, 0wx4a7484aa, 0wx5cb0a9dc, 0wx76f988da,
   0wx983e5152, 0wxa831c66d, 0wxb00327c8, 0wxbf597fc7, 0wxc6e00bf3, 0wxd5a79147, 0wx06ca6351, 0wx14292967,
   0wx27b70a85, 0wx2e1b2138, 0wx4d2c6dfc, 0wx53380d13, 0wx650a7354, 0wx766a0abb, 0wx81c2c92e, 0wx92722c85,
   0wxa2bfe8a1, 0wxa81a664b, 0wxc24b8b70, 0wxc76c51a3, 0wxd192e819, 0wxd6990624, 0wxf40e3585, 0wx106aa070,
   0wx19a4c116, 0wx1e376c08, 0wx2748774c, 0wx34b0bcb5, 0wx391c0cb3, 0wx4ed8aa4a, 0wx5b9cca4f, 0wx682e6ff3,
   0wx748f82ee, 0wx78a5636f, 0wx84c87814, 0wx8cc70208, 0wx90befffa, 0wxa4506ceb, 0wxbef9a3f7, 0wxc67178f2]

val initial : W.word list =
  [0wx6a09e667, 0wxbb67ae85, 0wx3c6ef372, 0wxa54ff53a,
   0wx510e527f, 0wx9b05688c, 0wx1f83d9ab, 0wx5be0cd19]

fun rotr (x, n) = W.orb (W.>> (x, n), W.<< (x, 0w32 - n))

(* Compress the 16 message words already in w[0..15] into hash. *)
fun compress (hash : W.word Array.array, w : W.word Array.array) =
  let
    fun extend i =
      if i < 64 then
        let
          val w15 = Array.sub (w, i - 15)
          val w2 = Array.sub (w, i - 2)
          val s0 = W.xorb (W.xorb (rotr (w15, 0w7), rotr (w15, 0w18)), W.>> (w15, 0w3))
          val s1 = W.xorb (W.xorb (rotr (w2, 0w17), rotr (w2, 0w19)), W.>> (w2, 0w10))
        in
          Array.update (w, i, Array.sub (w, i - 16) + s0 + Array.sub (w, i - 7) + s1);
          extend (i + 1)
        end
      else ()
    fun round i (a, b, c, d, e, f, g, h) =
      if i < 64 then
        let
          val s1 = W.xorb (W.xorb (rotr (e, 0w6), rotr (e, 0w11)), rotr (e, 0w25))
          val ch = W.xorb (W.andb (e, f), W.andb (W.notb e, g))
          val t1 = h + s1 + ch + Vector.sub (k, i) + Array.sub (w, i)
          val s0 = W.xorb (W.xorb (rotr (a, 0w2), rotr (a, 0w13)), rotr (a, 0w22))
          val maj = W.xorb (W.andb (a, W.xorb (b, c)), W.andb (b, c))
        in
          round (i + 1) (t1 + s0 + maj, a, b, c, d + t1, e, f, g)
        end
      else
        List.app
          (fn (j, x) => Array.update (hash, j, Array.sub (hash, j) + x))
          [(0, a), (1, b), (2, c), (3, d), (4, e), (5, f), (6, g), (7, h)]
    fun h j = Array.sub (hash, j)
  in
    extend 16;
    round 0 (h 0, h 1, h 2, h 3, h 4, h 5, h 6, h 7)
  end

fun hex_digest hash =
  let
    fun word_hex x =
      StringCvt.padLeft #"0" 8 (String.map Char.toLower (W.toString x))
  in
    String.concat (Array.foldr (fn (x, acc) => word_hex x :: acc) [] hash)
  end

fun string_hex text =
  let
    val len = size text
    val hash = Array.fromList initial
    val w = Array.array (64, 0w0 : W.word)
    (* The padded message is text, 0x80, zeros, then the 64-bit bit length,
       rounded up to whole 64-byte blocks. *)
    val padded = ((len + 8) div 64 + 1) * 64
    val bit_len = LargeWord.<< (LargeWord.fromInt len, 0w3)
    fun length_byte j =
      W.fromLarge (LargeWord.andb (LargeWord.>> (bit_len, Word.fromInt (8 * (7 - j))), 0wxff))
    fun byte i =
      if i < len then W.fromInt (Char.ord (String.sub (text, i)))
      else if i = len then 0wx80
      else if i < padded - 8 then 0w0
      else length_byte (i - (padded - 8))
    fun word i =
      W.orb (W.orb (W.<< (byte i, 0w24), W.<< (byte (i + 1), 0w16)),
             W.orb (W.<< (byte (i + 2), 0w8), byte (i + 3)))
    fun load_block base j =
      if j < 16 then
        (Array.update (w, j, word (base + 4 * j)); load_block base (j + 1))
      else ()
    fun blocks base =
      if base < padded then
        (load_block base 0; compress (hash, w); blocks (base + 64))
      else ()
  in
    blocks 0;
    hex_digest hash
  end

end
