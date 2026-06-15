structure HolbuildRuntime =
struct
  val load = Meta.load
  val use = use
  val print = print
  val export_theory = export_theory
  val restore_prover = Tactical.restore_prover
  val save_thm = Theory.save_thm

  fun save_hierarchy_depth () = List.length (PolyML.SaveState.showHierarchy())

  fun readable path = OS.FileSys.access(path, [OS.FileSys.A_READ])

  fun write_text path text =
    let
      val out = TextIO.openOut path
      val _ = TextIO.output(out, text)
      val _ = TextIO.closeOut out
    in
      ()
    end

  fun write_lines path lines =
    write_text path (String.concatWith "\n" lines ^ "\n")

  fun write_hol_file path text =
    let
      val out = HOLFileSys.openOut path
      val _ = HOLFileSys.output(out, text)
      val _ = HOLFileSys.closeOut out
    in
      ()
    end

  fun write_manifest path lines =
    write_hol_file path (String.concatWith "\n" lines ^ "\n")

  fun write_parent_report path = write_lines path (Theory.parents "-")

  fun write_mldeps_report path = write_lines path (Theory.current_ML_deps())

  fun export_theory_if_needed sig_path =
    if readable sig_path then () else export_theory ()
end
