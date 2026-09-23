## Export complete Bullwhip games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED]

import std/[json, os, osproc, strutils]
import bullwhip/[sim, llm]

const OperatorPrompt = "Minimize your own inventory and backlog costs using only your stage history."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 3:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len == 3: parseInt(args[2]) else: 1
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  let variantConfig = manifest["variants"][0]["game_config"]
  var
    trainRows: seq[string]
    validationRows: seq[string]
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
    var rows: seq[string]
    while not sim.done:
      let view = sim
      for seat in view.pendingSeats():
        let teacher = view.scriptedAction(seat, skBasestock)
        let completion = %*{
          "order": teacher.order, "say": teacher.say, "notes": teacher.notes
        }
        let parsed = parseDecision(completion)
        doAssert parsed == teacher
        rows.add($(%*{
          "episode_id": "bullwhip-standard-" & $seed,
          "seed": "bullwhip-standard-" & $seed,
          "decision_id": view.week * Seats + seat,
          "prompt": [
            {"role": "system", "content": systemPrompt(view, seat)},
            {"role": "user", "content": userPrompt(view, seat, OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "bullwhip",
          "action_schema_revision": "bullwhip-order-v1"
        }))
        sim.applyOrder(seat, parsed.order, parsed.say, parsed.notes, true)
    doAssert sim.reason == "complete" and rows.len == config.weeks * Seats
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "chain_cost": outcome["chainCost"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "bullwhip",
    "variant": "standard",
    "source_revision": sourceRevision,
    "teacher": "scripted-basestock",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
