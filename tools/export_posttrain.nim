## Export complete Bullwhip games as canonical private training evidence.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES FIRST_SEED GAME_VERSION [FIRST_PROMPT_SEED]

import std/[json, options, os, osproc, strutils]
import bullwhip/[sim, llm, policy, view]
import bitworld/decision_trajectory

when isMainModule:
  let args = commandLineParams()
  if args.len notin 4 .. 5:
    quit("usage: export_posttrain OUTPUT GAMES FIRST_SEED GAME_VERSION [FIRST_PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = parseInt(args[2])
  let gameVersion = args[3]
  let mixed = args.len == 5
  let firstPromptSeed = if mixed: parseInt(args[4]) else: 0
  let wordings = if mixed: 5 else: 1
  doAssert firstPromptSeed >= 0
  doAssert gameVersion.len > 0
  doAssert execProcess("git status --porcelain").strip().len == 0, "commit source before exporting"
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
    trajectoryRows, trainingRows, validationRows: seq[string]
    runs = newJArray()
  for index in 0 ..< games * wordings:
    let seed = firstSeed + index div wordings
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    if mixed:
      runtimeConfig["promptVariant"] = %"mixed"
      runtimeConfig["promptSeed"] = %(firstPromptSeed + index mod wordings)
    config.update($runtimeConfig)
    doAssert config.selectedPromptVariant notin {pvHeldoutBriefing, pvHeldoutReference},
      "held-out wording cannot enter a teacher corpus"
    config = sampleEpisode(config)
    var sim = initSim(config)
    let episodeId = "bullwhip-standard-" & $seed &
      (if mixed: "-" & $config.selectedPromptVariant else: "")
    let trajectory = newDecisionTrajectory(episodeId, "bullwhip-" & $seed,
      "bullwhip", gameVersion, sourceRevision)
    var decisions = 0
    while not sim.done:
      let seats = sim.pendingSeats()
      let week = sim.week
      var observations: seq[JsonNode]
      for seat in seats: observations.add(decisionView(sim, seat, DefaultOperatorPrompt))
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
        attempt.prompt = %*[{"role": "system", "content": systemPrompt(observation, config)},
          {"role": "user", "content": userPrompt(observation, DefaultOperatorPrompt)}]
        attempt.response = %($completion)
        attempt.parsedAction = decisionJson(parsed)
        attempt.accepted = true
        inc decisions
        sim.applyOrder(seat, parsed.order, parsed.say, parsed.notes, true)
        trajectory.recordDecision($week & "-" & $seat, $seat, observation,
          @[attempt], some(attempt.attemptId), decisionJson(parsed), asAccepted,
          terminal = sim.done)
    doAssert sim.reason == "complete" and decisions == config.weeks * Seats
    let outcome = sim.resultsJson()
    var outcomes = newJObject()
    for seat in 0 ..< Seats: outcomes[$seat] = outcome["scores"][seat]
    trajectory.finish(esCompleted, outcome, outcomes)
    let rows = trajectory.eventsJsonl().strip()
    trajectoryRows.add(rows)
    let validation = (seed mod 5) == 0
    if validation: validationRows.add(rows)
    else: trainingRows.add(rows)
    runs.add(%*{"seed": seed, "episode": episodeId,
      "prompt_variant": $config.selectedPromptVariant, "prompt_seed": config.promptSeed,
      "split": (if validation: "validation" else: "train"), "decisions": decisions,
      "scores": outcome["scores"], "chain_cost": outcome["chainCost"]})
  writePrivate(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  writePrivate(output / "train-trajectories.jsonl", trainingRows.join("\n") & "\n")
  writePrivate(output / "validation-trajectories.jsonl", validationRows.join("\n") & "\n")
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "bullwhip",
    "variant": "standard",
    "source_revision": sourceRevision,
    "game_version": gameVersion,
    "teacher": "scripted-basestock",
    "operator_prompt": DefaultOperatorPrompt,
    "complete_episodes": games * wordings,
    "prompt_bank": PromptBankVersion, "wordings_per_family": wordings,
    "decisions": games * wordings * variantConfig["weeks"].getInt() * Seats,
    "runs": runs
  }) & "\n")
  echo "complete_episodes=", games * wordings, " decisions=", games * wordings * variantConfig["weeks"].getInt() * Seats
