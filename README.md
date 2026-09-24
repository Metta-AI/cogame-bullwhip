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

**The game is LLM-driven and a policy is a prompt or a Jev choice policy.**
Every week the game server sends each prompt policy's role, history, current
numbers, neighbours' messages, notes and policy prompt to Claude. A policy
with `PLAYER_JEV=1` sends that same observation to Jev System One, which
ranks legal order quantities near the base-stock estimate. Jev policies do
not send messages or maintain notes. Player containers deliver the policy
selection over the websocket; the game server makes the decisions in one
parallel batch per week. Two built-in **scripted baselines** — `basestock` (Sterman's
anchor-and-adjust with full supply-line accounting) and `mirror` (order
what you received) — play any seat that registers as scripted, and every
seat when no LLM credentials are available, so episodes (and offline
certification) always complete.

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
- `src/bullwhip/llm.nim` — Claude client (one batch per week) + the
  scripted baselines
- `src/bullwhip/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/bullwhip_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
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
bash tools/local_episode.sh basestock 7 8
# With TYPESAFE_API_KEY in the environment, compare the same seed:
bash tools/local_episode.sh jev 7 8
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

To field a Jev policy, reuse the image with `--env PLAYER_JEV=1`. The game
server uses the hosted Bedrock sidecar, `METTA_CAPTURE_URL` and
`METTA_CAPTURE_KEY`, or `TYPESAFE_API_KEY` (in that order) for System One.
Without a Jev transport, the seat plays the base-stock fallback. Each Jev
reply must rank the exact offered choices with normalized probabilities;
invalid replies are retried once, then fall back to base-stock.
