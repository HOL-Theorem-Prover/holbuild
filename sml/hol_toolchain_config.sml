structure HolbuildHolToolchainConfig =
struct

datatype sequence = UptoHol

type t = {sequence : sequence, no_helpdocs : bool}

val default = {sequence = UptoHol, no_helpdocs = true}

fun sequence_name UptoHol = "upto-hol"

fun sequence_file UptoHol = "tools/sequences/upto-hol"

fun sequence_args sequence = ["--seq=" ^ sequence_file sequence]

fun helpdocs_args true = ["--no-helpdocs"]
  | helpdocs_args false = []

fun build_arg_list ({sequence, no_helpdocs} : t) =
  helpdocs_args no_helpdocs @ sequence_args sequence

fun build_args_text config = String.concatWith " " (build_arg_list config)

fun key_material_fields (config : t) =
  ["build_sequence=" ^ sequence_name (#sequence config),
   "build_sequence_file=" ^ sequence_file (#sequence config),
   "no_helpdocs=" ^ Bool.toString (#no_helpdocs config),
   "build_args=" ^ build_args_text config]

fun required_sequence_file (config : t) = SOME (sequence_file (#sequence config))

end
