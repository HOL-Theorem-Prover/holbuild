(* Whole buffers written to a file stream at most 64 KiB per write(2).
   Poly/ML passes any output larger than its 4 KiB stream buffer to a single
   write, and Linux sizes the page-cache folio of a buffered write by its
   length: a write of 1 MiB or more asks for a 1-2 MiB folio, which a host
   with fragmented memory can only supply by waking kswapd to reclaim page
   cache. 64 KiB folios stay available. *)
structure HolbuildBoundedOutput =
struct

val max_write = 65536

fun text (out, s) =
  let
    val total = String.size s
    fun loop start =
      if start >= total then ()
      else
        let val n = Int.min (max_write, total - start)
        in TextIO.outputSubstr (out, Substring.substring (s, start, n)); loop (start + n) end
  in
    loop 0
  end

(* As print, which flushes stdout after each write. *)
fun print s = (text (TextIO.stdOut, s); TextIO.flushOut TextIO.stdOut)

fun binary (out, bytes) =
  let
    val total = Word8Vector.length bytes
    fun loop start =
      if start >= total then ()
      else
        let val n = Int.min (max_write, total - start)
        in
          BinIO.output (out, Word8VectorSlice.vector (Word8VectorSlice.slice (bytes, start, SOME n)));
          loop (start + n)
        end
  in
    loop 0
  end

end
