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
scores, immutable source commit, game version, and a physical-demand family.
The family is `bullwhip-demand-v1-<sha1>` over compact UTF-8 JSON with
ordered fields `weeks`, `talk`, and `demand` (including terminal-week demand).
It excludes seed, seat aliases, role permutation, prompt wording, and prompt seed.
Equivalent demand schedules therefore remain in one split across different seeds.
The private export manifest retains the exact family input for independent hashing.
The native server and exporter call the same simulator-owned family function.
Historical seed-based trajectories remain historical evidence and must not be
admitted as physically disjoint train/validation data.
Existing output directories are refused. Output directories use mode 0700;
private files use 0600. No split or supervised dataset rows are generated here.

Use the shared Coworld reader to validate complete episodes, then import them from a
[posttraining-research](https://github.com/Metta-AI/posttraining-research) environment:

```python
from pathlib import Path

from coworld.decision_trajectory import export_complete_episodes, read_trajectory_jsonl
from metta_training.posttrain.hosted import export_hosted
from metta_training.posttrain.hosted_receipts import HostedImportAuthority

source = Path("/tmp/bullwhip-qualified/episodes.jsonl")
export_complete_episodes(
    read_trajectory_jsonl(Path("/tmp/bullwhip-standard/trajectories.jsonl")), source
)
# Independent review supplies this authority, bound to the exact qualified source bytes.
authority = HostedImportAuthority.model_validate_json(
    Path("/private/bullwhip-review.json").read_text()
)
export_hosted(
    source,
    Path("/tmp/bullwhip-dataset"),
    target_policy="basestock-view",
    authority=authority,
)
```

The teacher attempt policy is `basestock-view`; the source manifest's teacher label
is `scripted-basestock`. The review must match the actual attempt policy, source
revision, game version, and selected seats. Qualification alone does not authorize labels.
The importer retains generation evidence and owns the scenario-family split. Inspect
its `prompt_wordings` counts before using a mixed corpus; raw wording coverage is insufficient.
For prompt seed zero, seeds 1–10 retain only `plain` and `questions` in training under
the default 20% hash split. Seeds 1–20 retain all five training wordings, with 1,584
training and 1,296 validation targets across all four seats. Other ranges and target
filters need their own coverage check.

```sh
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/bullwhip-mixed 20 1 SOURCE_GAME_VERSION 0
```

Use that collection's `trajectories.jsonl` in the qualification step above.
Provider-backed model targets additionally require authenticated platform receipts.
These local teacher examples do not establish stronger league play or learner sampling evidence.
Historical corpora keep their original source and split provenance.

# Numeric reinforcement learning

The JSONL bridge also accepts explicit teacher queries such as
`{"kind":"teacher","policy":"mirror"}`. Policies are `basestock`, `mirror`
(order the seat-visible incoming demand), and `zero` (order zero). Explicit
replies include `response`, `policy`, and `decision_id`; queries without a policy
retain their original response shape and basestock behavior. Invalid selectors
return an error without advancing the decision or consuming an action retry.
Only the seat's private observation is used. These are scripted references for
teacher-diversity studies; their relative native performance must be measured.

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

Episode IDs include requested selection, resolved wording, and prompt seed for
both manifest-configured and mixed collections. Scenario families remain unchanged;
the shared importer still owns splitting and training-wording coverage checks.
