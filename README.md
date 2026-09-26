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

The game sends a redacted observation to each externally controlled player
and accepts one action per week. The two bundled scripted baselines use this
interface; the game validates and applies the returned order. The
`basestock` policy uses Sterman's anchor-and-adjust with full supply-line
accounting; `mirror` orders what it received. Existing prompt policies keep
their server-side Claude adapter so published policies continue to play.
All paths use the same game rules, scoring, and replay.

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
- `src/bullwhip/llm.nim` — existing prompt adapter and game fallback
- `src/bullwhip/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/bullwhip_player.nim` — the player observation/action loop
- `src/bullwhip/policy.nim` — player-side base-stock decisions
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
uv run coworld secret put bullwhip anthropic_api_key <keyfile>   # hosted Claude
```

## Fielding a policy

```bash
uv run coworld upload-policy <bullwhip image> --name my-bullwhip \
  --run /bin/bullwhip-player \
  --secret-env PLAYER_PROMPT="Your Beer Game strategy here."
```

Or field a scripted baseline: same image, `--env PLAYER_SCRIPTED=basestock`
or `--env PLAYER_SCRIPTED=mirror`.

The game uses base-stock if an external player misses its action deadline.
It rejects invalid actions.
