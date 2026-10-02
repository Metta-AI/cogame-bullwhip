# Metta post-training data

The native simulator exports complete private basestock teacher episodes:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/bullwhip-standard 10 1 SOURCE_GAME_VERSION
```

The exporter reads the standard Coworld manifest and freezes every seat's
private view before simultaneous weekly orders. The same private view, prompt
renderer, teacher policy, and typed action parser drive runtime and export.
The published player, exporter, and language bridge use the same default
operator strategy; custom bridge strategies require an explicit argument.
Each trajectory includes every teacher proposal, applied action, terminal
scores, immutable source commit, game version, and `bullwhip-<seed>` family.
Existing output directories are refused. Output directories use mode 0700;
private files use 0600. No split or supervised dataset rows are generated here.

In the reviewed Metta source, qualify and export complete episodes, then use
the shared application importer for the canonical seed-family split:

```sh
uv run coworld training export /tmp/bullwhip-standard/trajectories.jsonl \
  /tmp/bullwhip-qualified --transport local
uv run metta-posttrain export-hosted /tmp/bullwhip-qualified/episodes.jsonl \
  /tmp/bullwhip-dataset
```

The shared importer retains generation evidence, selects accepted teacher or
model targets, and marks the dataset unreviewed. Content review is required
before training. These local teacher examples do not establish stronger league
play, hosted platform model joins, or learner sampling evidence. Historical
corpora keep their original source and split provenance.

# Numeric reinforcement learning

Compile the persistent bridge and pass its manifest to Metta's
`recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nim c -d:release --path:src -o:/tmp/bullwhip-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/bullwhip-train-bridge
```

The certified standard game has four seats, 666 numeric observation values,
and 501 legal integer orders. Each observation contains only the acting
seat's role and stage history; it never includes the hidden demand script or
another stage's inventory. Text messages retain the hosted prompts for
Metta post-training. The base-stock policy supplies opponents and teacher
labels. A complete game returns each stage's native negative cost as score.


## Private decision corpus and language actions

The exporter writes `trajectories.jsonl`: complete engine-owned private
trajectories with exact seat observations, prompts, teacher proposals, applied
orders, scores, source commit, and game version. Output directories use mode
0700 and files use 0600. Seed families use `bullwhip-<seed>`, matching runtime.
These local scripted basestock labels do not provide hosted model or learner
sampling evidence. Review dataset content before training.

The production game writes the same private trajectory contract through
`COGAME_SAVE_TRAJECTORY_URI`. The runtime must provide `COWORLD_EPISODE_ID`,
`COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`. Publishing this source
requires those Metta runtime changes to be reviewed, deployed, and verified.
Native model capture retains every retry, actual platform response identifiers,
request and response bodies, sampling metadata when supplied, and engine-owned
acceptance. Player-asserted teacher and human origins become unknown. A player
model reply must independently parse to its submitted order; hosted eligibility
also requires independent platform archive joins.

Run the bridge with `MANIFEST --language [OPERATOR_PROMPT]` for the production
text action parser and exact private prompt renderer. Invalid replies return
the rendered retry decision. A second rejection consumes the same basestock
fallback as the hosted prompt player. Numeric order choices remain a separate
task. Public snapshots and replay events omit private notebooks.
