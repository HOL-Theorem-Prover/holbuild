val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";

val tmp = valOf (OS.Process.getEnv "ATTR_TEST_TMP");
val path = OS.Path.concat(tmp, "candidate.save");
val ok_text = HolbuildBuildExec.checkpoint_ok_text "failed_prefix"
  [("proof_timeout", "2.5")];
val _ = HolbuildBuildExec.write_text path "candidate";
val _ = HolbuildBuildExec.write_text (path ^ ".ok") ok_text;
val _ = HolbuildBuildExec.write_text (path ^ ".meta")
  "proof_ir_failed_prefix_version=5\nstep_count=0\nprefix_end=0\npath=\nfocus=\nhistory_count=0\n";

fun checkpoint attrs : HolbuildTheoryCheckpoints.checkpoint =
  {kind = "theorem", name = "candidate", safe_name = "candidate",
   theorem_start = 0, theorem_stop = 0, boundary = 0,
   tactic_start = 0, tactic_end = 0, tactic_text = "",
   proof_attrs = attrs, prefix_hash = "",
   context_path = "", context_ok = "", end_of_proof_path = "",
   end_of_proof_ok = "", failed_prefix_path = path,
   failed_prefix_ok = ok_text, deps_key = "", checkpoint_key = "",
   proof_ir_plan = NONE, proof_ir_factories = NONE};

val _ =
  if Option.isSome (HolbuildBuildExec.failed_prefix_checkpoint (SOME 2.5) (checkpoint []))
  then () else raise Fail "control candidate was not accepted";
val _ =
  if Option.isSome (HolbuildBuildExec.failed_prefix_checkpoint (SOME 2.5)
       (checkpoint [("exclude_simps", ["attr_a_def"])]))
  then raise Fail "attributed failed-prefix candidate was accepted" else ();

(* Duplicate keys, valueless keys and escaped values survive both protocol
   layers in their original order. *)
val attrs = [("flip", ["a", "b"]), ("flip", []),
             ("custom", ["", "space tab\tnewline\nbackslash\\"])];
val encoded = HolbuildAnalysisProtocol.encode_proof_attrs attrs;
val [_, decoded] = HolbuildAnalysisProtocol.split
  (HolbuildAnalysisProtocol.join ["proof-attrs", encoded]);
val _ =
  if HolbuildAnalysisProtocol.decode_proof_attrs decoded = attrs then ()
  else raise Fail "proof attribute protocol lost ordering or values";
val _ = print "ATTR_POLICY_OK\n";
