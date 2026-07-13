structure HolbuildPackagePrepare =
struct

exception Error of string
exception ErrorWithDebugArtifacts of string * HolbuildStatus.debug_artifacts

type t =
  {graph : HolbuildProjectGraph.t,
   prepared_packages : string list,
   generator_packages : string list,
   expected_outputs : (string * string) list,
   requires_live_preparation : bool}

fun prepare_package (package, (prepared, generator_packages, outputs)) =
  let
    val id = HolbuildProject.package_identity package
    val generators = HolbuildProject.package_generators package
    val _ =
      HolbuildGenerators.run_package package
      handle HolbuildGenerators.Error msg => raise Error msg
           | HolbuildGenerators.ErrorWithDebugArtifacts (msg, artifacts) =>
               raise ErrorWithDebugArtifacts (msg, artifacts)
    val package_outputs =
      List.concat
        (map (fn generator =>
          map (fn output => (id, output))
            (HolbuildProject.generator_outputs generator)) generators)
  in
    (id :: prepared,
     if null generators then generator_packages else id :: generator_packages,
     rev package_outputs @ outputs)
  end

fun prepare graph : t =
  let
    val (prepared, generator_packages, outputs) =
      List.foldl prepare_package ([], [], [])
        (HolbuildProjectGraph.packages graph)
  in
    {graph = graph,
     prepared_packages = rev prepared,
     generator_packages = rev generator_packages,
     expected_outputs = rev outputs,
     requires_live_preparation = not (null generator_packages)}
  end

fun graph ({graph, ...} : t) = graph
fun prepared_packages ({prepared_packages, ...} : t) = prepared_packages
fun generator_packages ({generator_packages, ...} : t) = generator_packages
fun expected_outputs ({expected_outputs, ...} : t) = expected_outputs
fun requires_live_preparation ({requires_live_preparation, ...} : t) =
  requires_live_preparation

end
