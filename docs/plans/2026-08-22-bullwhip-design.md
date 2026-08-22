# Bullwhip: the MIT Beer Game as a coworld

Four cogs, one supply chain, a demand that shifts once and is never seen
by three of them. Built on the cogame-parley technology stack exactly as
cogame-babel is (Nim game server implementing the Coworld runtime contract,
LLM-driven decisions where **a policy is just a prompt**, an always-available
scripted baseline, a pure `sim` module shared by server / tests / wasm
viewer, the parley broadcast chrome around a canvas stage). Fork of
cogame-babel 0.1.4; every convention there holds here unless this note says
otherwise.

Source idea: Coworld Ideas #09 — "the MIT Beer Game, seat by seat: retailer,
wholesaler, distributor, factory. Each seat sees only its neighbour's orders
and a two-week shipping delay; demand is hidden and shifts once. Everyone
pays holding and backlog cost; scoring is individual but selfish play
amplifies oscillation for all. A talk variant lets seats share forecasts
(truthfully or not)."

## The game

- **Seats:** exactly 4 (`num_agents` = 4). Anonymous cog aliases from the
  seed as in babel (`CogNames`); policy names spectator-only.
- **Stages:** 0 Retailer, 1 Wholesaler, 2 Distributor, 3 Factory. The
  **seat → stage assignment is a seed-drawn permutation** (`roleOf[seat]`),
  so no slot is structurally stuck with the factory. Customers sit below
  the retailer; the factory's supplier is its own production line.
- **Weeks:** `weeks` (default 36, min 4, max 60; cert fixture 8). Week `w`
  (0-based) is *observed* (every stage sees its own state), every seat
  places one **order** (a non-negative integer ≤ `MaxOrder` = 500), then the
  chain **resolves** into week `w + 1`. After the orders of week `weeks - 1`
  resolve, the episode ends. Decisions within a week are simultaneous.
- **Resolution** (Sterman's rules): for every stage, in this order —
  1. *Shift shipping pipeline:* `received = shipPipe[0]`;
     `shipPipe[0] = shipPipe[1]`; `shipPipe[1] = 0`.
  2. *Factory production:* `shipPipe[3][1] = order[3]` (a 2-week lead).
  3. `inventory += received`.
  4. *Incoming order* (1-week order delay): retailer ← `demand[w + 1]`
     (customer demand, hidden script); stage `i ≥ 1` ← `order[i − 1]` as
     placed this week.
  5. *Fill:* `due = backlog + incoming`; `shipped = min(inventory, due)`;
     `inventory −= shipped`; `backlog = due − shipped`.
  6. *Ship downstream:* `shipPipe[i − 1][1] = shipped` (2-week delay; the
     retailer's shipment goes to the customer).
  7. *Cost:* `costWeek = 0.5 × inventory + 1.0 × backlog`;
     `costTotal += costWeek`.
- **Initial state** (week 0, already observed): inventory 12, backlog 0,
  `shipPipe = [4, 4]`, received 4, incoming 4, shipped 4, costWeek 6.
- **Demand script** (seed-drawn, hidden from every seat; spectators see it
  week by week): `4` per week through `shiftWeek − 1` (`shiftWeek` ∈ 4..8),
  then `shiftLevel` (∈ 7..12) per week for the rest of the episode.
- **Observation** (what a seat's prompt carries): its role, the week, its
  whole history table (per week: incoming order, arrived, shipped,
  inventory, backlog, order placed, cost), the current week's numbers, the
  messages its two neighbours sent last week, and its own private notes. It
  never sees other stages' inventories, the pipelines' contents, or the
  demand script. The retailer's incoming order *is* customer demand.
- **Talk (on by default, `talk: true`):** each reply may carry `say`
  (≤ 120 chars), delivered next week to the adjacent stages only (downstream
  and upstream). Free text, non-binding. `talk: false` drops it.
- **Private notes:** every reply may carry `notes` (≤ 600 chars), stored per
  seat and fed back verbatim; recorded in the event log and shown to
  spectators.
- **Scoring:** a seat's `cost` is its stage's `costTotal` over weeks 0..W;
  `score = −cost` (higher is better; the league ranks by it). Results also
  report `roles` and `chainCost`. Individual score, shared pain: the
  bullwhip a selfish stage creates comes back as its own backlog.
- **Endings:** `reason = "complete"` after `weeks` weeks resolve;
  `"deadline"` if the episode clock stops play between weeks. Scores use the
  weeks actually played.

## Decisions: LLM with scripted fallback

Transport, credentials, JSON-only output contract, `extractJsonObject`, the
Bedrock model list, and "no credentials ⇒ every seat scripted" are ported
from babel `llm.nim`. Two changes:

- **One batch per week.** The four seats' decisions are simultaneous by
  rule, so the server fires the four model requests as one
  `curly.makeRequests` batch (parallel). Replies that fail to parse or are
  illegal are retried as a second, smaller batch with the "previous reply
  was invalid" hint; anything still failing falls back to the scripted
  baseline. 36 weeks ≈ 36 round-trips, not 144.
- **Reply shape:** `{"order": N, "say": "…", "notes": "…"}`; `order`
  accepts an integer, a numeric string, or a float (rounded); negative or
  > `MaxOrder` ⇒ invalid.

**Scripted baselines** (`PLAYER_SCRIPTED`):
- `1` / `basestock` — Sterman's anchor-and-adjust: exponential demand
  forecast `L ← 0.25·incoming + 0.75·L` (init 4); desired inventory `3·L`;
  desired supply line `3·L`; supply line = `shipPipe[0] + shipPipe[1] +
  last order`; `order = max(0, round(L + (desiredInv − inventory + backlog)/2
  + (desiredSupply − supplyLine)/2))`. Stable after a step; the
  "sensible partner".
- `mirror` — pass-through: `order = incoming`. Never amplifies on its own;
  starves under backlog.
- Neither produces `say` or `notes`.

**Episode budgeting.** `PlayBudgetFraction = 0.6` of
`COWORLD_TIMEOUT_SECONDS` (assumed `episodeTimeoutSeconds` = 1200 when the
env is silent). The deadline is checked **before every week's batch**; past
it the sim ends with `reason = "deadline"`. `turnDelayMs` (default 400, cert
0) paces between weeks, bounded by `PacingBudgetMs`.

## Sim module

`src/bullwhip/types.nim` — `BullwhipError`, `PlayerConfig`, `GameConfig`
(babel's with `weeks` replacing `rounds`, plus `talk`), `StageState`,
`EventKind`, `GameEvent`, `defaultGameConfig`, `update`.

`src/bullwhip/sim.nim` — pure rules, no IO:
- `Stages = 4`, `ShipDelay = 2`, `MaxOrder = 500`, `HoldCost = 0.5`,
  `BacklogCost = 1.0`, `InitialInventory = 12`, `BaseDemand = 4`,
  `RoleNames`, `CogNames`.
- `Sim` = config, `names`, `roleOf[seat]`, `seatOf[stage]`, `demand` (the
  whole hidden script), `week`, `stages: array[4, StageState]`, live-week
  `orders[4]` (−1 = unplaced), `says[4]`, `heard[4]` (last week's says),
  `notes`, `history: seq[WeekRecord]` (per observed week: the four stage
  states + orders placed), `weeksPlayed`, `done`, `reason`, `events`.
- Event kinds (flat `GameEvent`, JSON via `eventToJson` / `eventFromJson`):
  - `start`
  - `week` — `week`, `demand` (customer demand this week), `stages:
    [{inventory, backlog, received, incoming, shipped, costWeek, costTotal}
    ×4 by stage]` (derived; checked against the seeded re-derivation).
  - `order` — `week`, `seat`, `stage`, `order`, `say`, `scripted`, `text`
    (the seat's notes after this reply).
  - `end` — `week` = weeks played, `text` = reason.
- API: `initSim`, `sampleEpisode`, `tableNames`, `pendingSeats(sim)`,
  `applyOrder(sim, seat, order, say, notes, scripted)` (the fourth order
  resolves the week and logs the next `week` event or `end`), `endEarly`,
  `resultsJson`, `tableStateJson`, `replayMatch(config, events)`,
  `eventToJson`, `eventFromJson`.

**`tableStateJson`** (one frame; the viewer draws exactly this):
```json
{"seats":[{"name":"Sprocket","stage":2,"role":"Distributor","score":-148.5,
           "cost":148.5,"inventory":7,"backlog":0,"received":4,"incoming":9,
           "shipped":9,"shipPipe":[4,6],"order":12|null,"say":"…","heard":
           ["…","…"],"notes":"…","pending":true}, ×4 by seat],
 "stageSeat":[3,0,1,2],
 "week":5,"weeks":36,"weeksPlayed":5,
 "demand":[4,4,4,4,8,8],            // revealed through the current week
 "orders":[[4,4,4,5,9,…],×4 by stage],   // per stage, per observed week
 "phase":"orders|done","gameDone":false,"reason":""}
```

**`resultsJson`** (platform-facing, policy names):
`{"names":[4],"scores":[4 floats = −cost],"costs":[4],"roles":[4 strings],
"weeks":<played>,"maxWeeks":<cap>,"chainCost":<sum>,"reason":"complete|deadline"}`.

**Replay payload** (`bullwhip.replay.v1`): `{"protocol","names",
"policyNames","config":{"weeks","seed","talk","sampled":true},"events",
"results"}`; replay mode and the wasm viewer add `"states"`.

## Server, player, protocol

`src/bullwhip/server.nim` — babel's server with the game loop replaced:
per week, snapshot the sim, decide all pending seats in one batch outside
the lock, apply each under the lock (the fourth apply resolves), broadcast,
pace. Player websocket gets a redacted state (own seat's numbers only).
Protocol `bullwhip.player.v1`, frame shapes as babel.

`src/bullwhip_player.nim` — babel_player with a Beer Game default prompt
(track the supply line, don't double-order into backlog, share honest
forecasts).

## Viewer

`client/renderer.js` — the parley/babel chrome verbatim (topband, scorebug,
feed, scrubber, endscreen, name map, effects, both drivers, replay pacing)
with the stage replaced by the **conveyor**:
- Four stations left → right in *stage* order (Retailer … Factory) with the
  customer at the far left and the factory's production line at the far
  right. Each station: the cog sprite in its *seat* colour, role tag, name,
  cost counter, **inventory as stacked paper crates** and **backlog as red
  crates** beside it, the order slip it just wrote (a paper tag with the
  number, sliding upstream), and a speech bubble with its last `say`.
- Between stations: a conveyor belt carrying the two in-transit shipments
  as crate stacks sized by quantity, moving downstream; order slips fly
  upstream.
- Below: the **seismograph** — a strip chart of orders placed per stage
  (four seat-coloured lines) over the customer demand (ghost line), revealed
  up to the current week. The amplification is the picture.
- Feed: `WEEK n` heads; `Customer demand 8` when it changes; `Sprocket
  (Retailer) orders 12` per order, `Sprocket says: …` when talking;
  `Final — chain cost 1234`.
- Endscreen: columns `cost`, `role`; verdict = lowest-cost seat + "RAN THE
  TIGHTEST SHOP".

## Packaging

`bullwhip.nimble`, `compose.yaml` (service `bullwhip`, image
`coworld-bullwhip`), `Dockerfile` (binaries `/bin/bullwhip`,
`/bin/bullwhip-player`), `Dockerfile.replay-viewer`,
`coworld_manifest_template.json`: game name `bullwhip`, image
`{{BULLWHIP_IMAGE}}`, `source_url`
`https://github.com/Metta-AI/cogame-bullwhip/tree/main`; `config_schema`
with `tokens`/`players` 4, `num_agents` 4, `weeks` 4..60 default 36, `talk`,
the babel timing/model knobs; `results_schema` per `resultsJson`; player
runnables `bullwhip-player` (prompt), `bullwhip-basestock`
(`PLAYER_SCRIPTED=basestock`), `bullwhip-mirror` (`PLAYER_SCRIPTED=mirror`);
variant `standard`; certification (`seed: 7`, `weeks: 8`, `turnDelayMs: 0`).

## Tests

`tests/test_sim.nim`: role permutation, demand script shape, resolution
arithmetic on a hand-computed chain, order legality, scoring, `endEarly`,
replay re-derivation (`frames.len == events.len + 1`, final frame equals the
live `tableStateJson`), event JSON round-trip, seed determinism.
`tests/test_bot.nim`: four `basestock` seats play full episodes legally for
several seeds with bounded orders and chain cost below the all-`mirror`
chain's... (no: mirror is cheap on a pure step; assert basestock recovers —
backlog returns to 0 within 12 weeks of the shift); `decide` falls back to
scripted with no credentials; reply parsing.

## Out of scope (v1)

Noise on demand, variable delays, more than four stages, cross-episode
memory.
