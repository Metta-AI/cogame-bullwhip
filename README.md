# Bullwhip

The **MIT Beer Game** for the Softmax Coworld platform, on the
[cogame-parley](https://github.com/Metta-AI/cogame-parley) technology
stack (forked from [cogame-babel](https://github.com/Metta-AI/cogame-babel)).
Four cogs run the four stages of a supply chain — **Retailer, Wholesaler,
Distributor, Factory** (roles dealt from the seed) — for 36 weeks. Every
week a stage receives an order from downstream, ships what it can from
inventory (the shortfall becomes **backlog**, owed until shipped), and
places **one order** upstream. Orders take a week to be seen, shipments two
weeks to arrive, and the factory's orders are production requests with a
two-week lead. Holding costs $0.5 a unit a week, backlog $1.0; **a seat's
score is minus its total cost**. Customer demand is hidden from every seat
and steps up once. Greedy ordering into a backlog creates the bullwhip: a
single demand step amplified stage by stage into an oscillation that comes
back as everyone's excess inventory. In the talk variant (default on) each
seat may send one short, non-binding message a week to its two neighbours —
honest forecasts or otherwise.

The reference player registers one frozen prompt or a scripted baseline.
The game owns native model calls and simultaneous weekly decisions. The
`basestock` policy uses Sterman's anchor-and-adjust with full supply-line
accounting; `mirror` orders what it received. Custom external players use
[bullwhip.player.v3](docs/PROTOCOL.md), with the same private observation,
prompt renderer, normal order parser, and engine rules.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy
display names never reach the agents' prompts, so nobody can meta-game
"that seat is the champion". The spectator and replay viewers map the
aliases back to policy names; results are reported under policy names.

Scoring: `cost` = the stage's total holding + backlog cost over the weeks
played; `score = -cost`. Results also report `roles` and `chainCost`. The
episode ends `complete` after `weeks` weeks (default 36, 4..60) or
`deadline` when the episode clock stops play between weeks.

## Layout

- `src/bullwhip.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/bullwhip/sim.nim` — pure rules: roles and demand from the seed, the
  weekly resolution, orders, messages, tallies, endings, replay derivation;
  shared by server, tests, and the wasm viewer
- `src/bullwhip/llm.nim` — native model adapter and game fallback
- `src/bullwhip/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/bullwhip_player.nim` — the bounded native WebSocket prompt registrar
- `src/bullwhip/policy.nim` — shared private-view base-stock decisions
- `client/` — shared canvas renderer + global/player/replay pages (the
  parley broadcast chrome around the conveyor and the seismograph)
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `data/` — cog sprites and art, borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)
- `docs/plans/` — the design note this game was built from

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the
# paths are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim            # rules tests
nim r -d:release --path:src tests/test_bot.nim # scripted-baseline tests
nim c -d:release -o:bin/bullwhip src/bullwhip.nim
nim c -d:release -o:bin/bullwhip-player src/bullwhip_player.nim
nim c --hints:off -d:emscripten replay-viewer/bullwhip_replay.nim  # wasm viewer
# A full local episode (game + four players, results and replay in tmp/):
bash tools/local_episode.sh 7 8
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
```

## Fielding a policy

```bash
uv run coworld upload-policy <bullwhip image> --name my-bullwhip \
  --run /bin/bullwhip-player \
  --secret-env PLAYER_PROMPT="Your Beer Game strategy here."
```

Hosted model calls use the platform-provided `COWORLD_LLM_ENDPOINT` sidecar.
`COWORLD_LLM_MODEL` selects the canonical model; `COWORLD_LLM_TEMPERATURE`
is finite and in [0, 1]. Native calls consume one configured weekly deadline.
Without an endpoint, the engine uses its explicit base-stock fallback.

For scripted baselines, pass `--secret-env PLAYER_SCRIPTED=basestock` or
`--secret-env PLAYER_SCRIPTED=mirror` to the same policy upload command.

The game uses base-stock if an external player misses its action deadline.
It rejects invalid actions.
