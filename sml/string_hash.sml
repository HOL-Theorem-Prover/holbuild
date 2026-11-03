structure HolbuildStringHash =
struct

fun byte_reader text (offset, requested) =
  let
    val remaining = Int.max(0, size text - offset)
    val count = Int.min(requested, remaining)
    fun byte i = Word8.fromInt (Char.ord (String.sub(text, offset + i)))
  in
    (Word8Vector.tabulate(count, byte), offset + count)
  end

fun string_sha1 text = SHA1_ML.sha1String (byte_reader text) 0

end
