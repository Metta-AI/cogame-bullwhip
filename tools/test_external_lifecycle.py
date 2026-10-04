"""Actual issued decisions, parser retry and nonce-bound external socket cleanup."""

import asyncio
import copy
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

import websockets

root = Path(__file__).resolve().parents[1]
game = str(Path(sys.argv[1]).resolve())
output_root = Path(sys.argv[2]).resolve()
output_root.mkdir(mode=0o700)
fixture_attempt = json.loads(Path(sys.argv[3]).read_text().splitlines()[0])["attempts"][0]


async def play(slot, port, mode, decisions, receipts):
    async with websockets.connect(
        f"ws://127.0.0.1:{port}/player?slot={slot}&token=t{slot}", max_size=16 * 1024 * 1024
    ) as connection:
        stop = None
        async for raw in connection:
            packet = json.loads(raw)
            kind = packet["type"]
            if kind == "welcome":
                assert packet["protocol"] == "bullwhip.player.v3"
                await connection.send(
                    json.dumps({"type": "register", "control": "external", "prompt": "private-external-policy"})
                )
            elif kind in {"decision", "rejected"}:
                retry = kind == "rejected"
                decision = packet["observation"] if retry else packet
                identity = decision["decision_id"]
                assert isinstance(identity, str) and identity
                assert decision["transport"]["budget_ms"] <= 2000
                assert len(decision["messages"]) == 2
                decisions[slot].append(identity)
                if mode == "forged-start" and slot == 0 and not retry:
                    forged = copy.deepcopy(fixture_attempt)
                    forged["attempt_id"] = identity + "-model"
                    forged["prompt"] = decision["messages"]
                    forged["request"]["system"] = decision["messages"][0]["content"]
                    forged["request"]["messages"] = [decision["messages"][1]]
                    await connection.send(
                        json.dumps({"type": "attempt_started", "decision_id": identity, "training_attempt": forged})
                    )
                action = {
                    "order": 1000000 if mode == "retry" and slot == 0 and not retry else 8,
                    "say": "",
                    "notes": "private-external-notes",
                }
                await connection.send(
                    json.dumps(
                        {
                            "type": "action",
                            "decision_id": identity,
                            "source": "unknown",
                            "action": action,
                            "training_attempt": None,
                        }
                    )
                )
                if mode == "disconnected" and slot == 0:
                    return
            elif kind == "stop":
                stop = packet
                if mode == "missing-ack" and slot == 0:
                    return
                await connection.send(
                    json.dumps(
                        {
                            "type": "stopped",
                            "decision_id": packet["decision_id"],
                            "stop_id": packet["stop_id"],
                            "worker_status": "no_active_call",
                            "attempts": [],
                        }
                    )
                )
            elif kind == "evidence_received":
                assert stop is not None
                assert packet["decision_id"] == stop["decision_id"]
                assert packet["stop_id"] == stop["stop_id"]
                receipts.add(slot)
                return
            elif kind == "state":
                pass
            else:
                raise AssertionError(f"unexpected protocol type {kind}")
    raise AssertionError("socket ended before private evidence receipt")


async def players(port, mode, decisions, receipts):
    await asyncio.wait_for(
        asyncio.gather(*(play(slot, port, mode, decisions, receipts) for slot in range(4))), timeout=20
    )


for mode in ("accepted", "retry", "forged-start", "missing-ack", "disconnected"):
    output = output_root / mode
    output.mkdir(mode=0o700)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    config = {
        "tokens": [f"t{slot}" for slot in range(4)],
        "players": [{"name": f"p{slot}"} for slot in range(4)],
        "seed": 7,
        "weeks": 4,
        "talk": True,
        "turnDelayMs": 0,
        "player_connect_timeout_seconds": 5,
        "llmTimeoutSeconds": 2,
    }
    (output / "config.json").write_text(json.dumps(config))
    env = {
        **os.environ,
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
        "COWORLD_EPISODE_ID": str(uuid.uuid4()),
        "COWORLD_GAME_VERSION": "unfrozen-external-fixture",
        "COWORLD_SOURCE_REVISION": os.environ["COWORLD_SOURCE_REVISION"],
        "COWORLD_LLM_ENDPOINT": "",
    }
    decisions = {slot: [] for slot in range(4)}
    receipts = set()
    with (output / "game.log").open("w") as log:
        process = subprocess.Popen([game], cwd=root, env=env, stdout=log, stderr=log)
        try:
            for _ in range(100):
                assert process.poll() is None
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game did not start")
            asyncio.run(players(port, mode, decisions, receipts))
            assert process.wait(timeout=10) == 0
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
    events = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()]
    unresolved = mode in {"missing-ack", "disconnected"}
    assert events[-1]["status"] == ("truncated" if unresolved else "completed")
    assert (output / "results.json").exists() == (not unresolved)
    assert (output / "replay.json").exists() == (not unresolved)
    assert receipts == ({1, 2, 3} if unresolved else {0, 1, 2, 3})
    assert len(events) == 17
    for decision in events[:-1]:
        attempts = decision["attempts"]
        assert all(attempt["origin"] == "unknown" for attempt in attempts)
        assert all(
            attempt["platform_call_id"] is None and attempt["request"] is None and attempt["raw_response"] is None
            for attempt in attempts
        )
        if decision["action_status"] == "accepted":
            assert attempts[-1]["parsed_action"] == decision["executed_action"]
            assert attempts[-1]["prompt"]
    if mode == "retry":
        assert len(decisions[0]) == 8
        assert sum(len(event["attempts"]) for event in events[:-1]) == 20
    if mode == "forged-start":
        assert sum(len(event["attempts"]) for event in events[:-1]) == 16
    public = (output / "game.log").read_text()
    if not unresolved:
        public += (output / "replay.json").read_text()
    assert "private-external-policy" not in public and "private-external-notes" not in public
    print(
        json.dumps(
            {
                "case": mode,
                "decisions": 16,
                "receipts": sorted(receipts),
                "status": events[-1]["status"],
                "scope": "unknown source fixture; no model or teacher authority",
            }
        ),
        flush=True,
    )
