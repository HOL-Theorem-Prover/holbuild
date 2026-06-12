structure HolbuildAnalyserProofIrExtract =
struct

structure S = HolbuildAnalyserTheorySpanExtract

exception Error of string

type theorem_plan = {name : string, tactic_start : int, tactic_end : int, steps : HolbuildProofIr.step list}

fun read_all path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun plans path =
  let
    val text = read_all path
    val boundaries = S.scan path text
    fun one ({name, tactic_start, tactic_end, tactic_text, ...} : S.boundary) =
      {name = name, tactic_start = tactic_start, tactic_end = tactic_end,
       steps = HolbuildProofIr.steps tactic_text}
  in
    map one boundaries
  end
  handle S.Error msg => raise Error msg
       | e => raise Error ("proof IR extraction failed for " ^ path ^ ": " ^ General.exnMessage e)

end
