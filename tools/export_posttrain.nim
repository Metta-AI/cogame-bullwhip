## Export complete Bullwhip games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES FIRST_SEED GAME_VERSION

import std/[json, options, os, osproc, strutils]
import bullwhip/[sim, llm, view]
import bitworld/decision_trajectory

const OperatorPrompt = "Minimize your own inventory and backlog costs using only your stage history."

when isMainModule:
  let args = commandLineParams()
  if args.len != 4:
    quit("usage: export_posttrain OUTPUT GAMES FIRST_SEED GAME_VERSION", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = parseInt(args[2])
  let gameVersion = args[3]
  doAssert gameVersion.len > 0
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  let variantConfig = manifest["variants"][0]["game_config"]
  var
    trainRows: seq[string]
    validationRows: seq[string]
    trajectoryRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    let episodeId = "bullwhip-standard-" & $seed
    let trajectory = newDecisionTrajectory(episodeId, "bullwhip-" & $seed,
      "bullwhip", gameVersion, sourceRevision)
    var rows: seq[string]
    while not sim.done:
      let seats = sim.pendingSeats()
      let week = sim.week
      var observations: seq[JsonNode]
      for seat in seats: observations.add(observationJson(sim, seat))
      for index, seat in seats:
        let observation = observations[index]
        let teacher = scriptedAction(observation, skBasestock)
        let completion = %*{
          "order": teacher.order, "say": teacher.say, "notes": teacher.notes
        }
        let proposal = parseProposal($completion, observation)
        doAssert proposal.kind == pkAccepted
        let parsed = proposal.decision
        doAssert decisionJson(parsed) == decisionJson(teacher)
        var attempt = newDecisionAttempt($week & "-" & $seat & "-teacher",
          "basestock-view", aoTeacher)
        attempt.model = some("basestock-view")
        attempt.modelIdentity = some(sourceRevision)
        attempt.prompt = %*[{"role": "system", "content": systemPrompt(observation)},
          {"role": "user", "content": userPrompt(observation, OperatorPrompt)}]
        attempt.request = %*{"teacher": "basestock-view", "observation": observation}
        attempt.rawResponse = %($completion)
        attempt.response = %($completion)
        attempt.decoder = %*{"method": "deterministic"}
        attempt.parsedAction = decisionJson(parsed)
        attempt.accepted = true
        rows.add($(%*{
          "episode_id": "bullwhip-standard-" & $seed,
          "seed": "bullwhip-" & $seed,
          "decision_id": week * Seats + seat,
          "prompt": [
            {"role": "system", "content": systemPrompt(observation)},
            {"role": "user", "content": userPrompt(observation, OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "bullwhip",
          "action_schema_revision": "bullwhip-order-v1"
        }))
        sim.applyOrder(seat, parsed.order, parsed.say, parsed.notes, true)
        trajectory.recordDecision($week & "-" & $seat, $seat, observation,
          @[attempt], some(attempt.attemptId), decisionJson(parsed), asAccepted,
          terminal = sim.done)
    doAssert sim.reason == "complete" and rows.len == config.weeks * Seats
    let outcome = sim.resultsJson()
    var outcomes = newJObject()
    for seat in 0 ..< Seats: outcomes[$seat] = outcome["scores"][seat]
    trajectory.finish(esCompleted, outcome, outcomes)
    trajectoryRows.add(trajectory.eventsJsonl().strip())
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "chain_cost": outcome["chainCost"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "bullwhip",
    "variant": "standard",
    "source_revision": sourceRevision,
    "game_version": gameVersion,
    "teacher": "scripted-basestock",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  for name in ["train.jsonl", "validation.jsonl", "trajectories.jsonl", "manifest.json"]:
    setFilePermissions(output / name, {fpUserRead, fpUserWrite})
  echo "train=", trainRows.len, " validation=", validationRows.len
