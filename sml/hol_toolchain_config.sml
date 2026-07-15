structure HolbuildHolToolchainConfig =
struct

datatype sequence = UptoHol
datatype kernel_variant = StandardKernel | TracingKernel

type t =
  {sequence : sequence,
   no_helpdocs : bool,
   kernel_variant : kernel_variant}

fun kernel_variant_name StandardKernel = "stdknl"
  | kernel_variant_name TracingKernel = "trknl"

fun kernel_variant_args StandardKernel = []
  | kernel_variant_args TracingKernel = ["--trknl"]

fun kernel_variant_tracing StandardKernel = false
  | kernel_variant_tracing TracingKernel = true

fun config kernel_variant =
  {sequence = UptoHol, no_helpdocs = true, kernel_variant = kernel_variant}

val standard = config StandardKernel
val tracing = config TracingKernel
val default = standard

fun sequence_name UptoHol = "upto-hol"

fun sequence_file UptoHol = "tools/sequences/upto-hol"

fun sequence_args sequence = ["--seq=" ^ sequence_file sequence]

fun helpdocs_args true = ["--no-helpdocs"]
  | helpdocs_args false = []

fun build_arg_list ({sequence, no_helpdocs, kernel_variant} : t) =
  helpdocs_args no_helpdocs @ sequence_args sequence @ kernel_variant_args kernel_variant

fun build_args_text config = String.concatWith " " (build_arg_list config)

(* HOL revisions from before the reduced build sequence was introduced still
   support the historical full build.  Keep kernel selection in that fallback;
   only the unavailable sequence argument is omitted. *)
fun full_build_arg_list ({no_helpdocs, kernel_variant, ...} : t) =
  helpdocs_args no_helpdocs @ kernel_variant_args kernel_variant

fun full_build_args_text config = String.concatWith " " (full_build_arg_list config)

fun key_material_fields (config : t) =
  ["build_sequence=" ^ sequence_name (#sequence config),
   "build_sequence_file=" ^ sequence_file (#sequence config),
   "no_helpdocs=" ^ Bool.toString (#no_helpdocs config),
   "kernel_variant=" ^ kernel_variant_name (#kernel_variant config),
   "build_args=" ^ build_args_text config]

fun required_sequence_file (config : t) = SOME (sequence_file (#sequence config))

end
