# Metta post-training data

The native simulator and published `basestock` policy export supervised
examples for Bullwhip's certified standard game:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/bullwhip-standard 10 1 SOURCE_GAME_VERSION
```

The exporter reads the standard configuration from the Coworld manifest, adds
the per-seat tokens supplied by the hosted platform, and plays complete seeded
games. It freezes the game state at each simultaneous weekly decision, then
records each seat's hosted system and user prompts and a `basestock` order
accepted by the game's reply parser. Parsed orders drive the simulator. Whole
games stay in one split. The manifest records source revision, scores, chain
cost, and row counts. Existing output directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/bullwhip-standard \
  --output /tmp/bullwhip-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete games yielded 1,152 training and 288 validation examples. Every
example fit the Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum
was 1,715. One CPU optimizer step with a local tiny model verifies the Metta
post-training path. These examples distill the scripted teacher; they do not
establish stronger league play.

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

The exporter also writes `trajectories.jsonl`: complete engine-owned private
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
