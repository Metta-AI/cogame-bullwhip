"""Complete real Bullwhip socket games across wording and talk modes; no model calls."""

import asyncio
import hashlib
import json
import os
from pathlib import Path
import socket
import sys

import websockets


async def play(binary, folder, configuration, revision):
    folder.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = configuration | {"tokens": [str(seat) for seat in range(4)]}
    (folder / "config.json").write_text(json.dumps(config))
    environment = dict(os.environ)
    environment.pop("COWORLD_LLM_ENDPOINT", None)
    environment.update(
        COGAME_HOST="127.0.0.1", COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(folder / "config.json").as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=folder.name, COWORLD_GAME_VERSION="prompt-fuzzing-system",
        COWORLD_SOURCE_REVISION=revision,
    )
    observations = {}
    systems = {}
    identities = {}
    roles = set()
    with (folder / "game.log").open("w") as log:
        process = await asyncio.create_subprocess_exec(binary, env=environment, stdout=log, stderr=log)
        players = []
        try:
            async with asyncio.timeout(20):
                while "serving on" not in (folder / "game.log").read_text():
                    assert process.returncode is None, (folder / "game.log").read_text()
                    await asyncio.sleep(0.02)

            async def player(seat):
                async with websockets.connect(f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}") as connection:
                    stop = None
                    async for raw in connection:
                        frame = json.loads(raw)
                        kind = frame["type"]
                        if kind == "welcome":
                            assert frame["protocol"] == "bullwhip.player.v3"
                            await connection.send(json.dumps({
                                "type": "register", "control": "external", "prompt": f"PRIVATE-OPERATOR-{seat}",
                            }))
                        elif kind == "decision":
                            observation = frame["observation"]
                            messages = frame["messages"]
                            identity = observation.pop("prompt_template")
                            assert identity["bank"] == "bullwhip-rules-v1"
                            assert identity["selection"] == config["promptVariant"]
                            assert identity["seed"] == config["promptSeed"]
                            assert [message["role"] for message in messages] == ["system", "user"]
                            for message in messages:
                                assert identity[message["role"] + "_sha256"].lower() == hashlib.sha256(
                                    message["content"].encode()
                                ).hexdigest()
                            assert systems.setdefault(seat, messages[0]["content"]) == messages[0]["content"]
                            roles.add(observation["stage"])
                            user = messages[1]["content"]
                            for other in range(4):
                                if other != seat:
                                    assert f"PRIVATE-NOTES-{other}" not in user
                                    assert f"PRIVATE-OPERATOR-{other}" not in user
                            key = observation["week"], seat
                            identities[key] = identity
                            action = {"order": 8, "say": "forecast" if config["talk"] else "", "notes": f"PRIVATE-NOTES-{seat}"}
                            observations[key] = observation, user, action
                            await connection.send(json.dumps({
                                "type": "action", "decision_id": frame["decision_id"],
                                "source": "unknown", "action": action, "training_attempt": None,
                            }))
                        elif kind == "stop":
                            stop = frame
                            await connection.send(json.dumps({
                                "type": "stopped", "stop_id": frame["stop_id"], "decision_id": frame["decision_id"],
                                "worker_status": "no_active_call", "attempts": [],
                            }))
                        elif kind == "evidence_received":
                            assert stop is not None and frame["stop_id"] == stop["stop_id"]
                            assert frame["decision_id"] == stop["decision_id"]
                            return
                        else:
                            assert kind == "state", frame
                    raise AssertionError("socket closed before evidence acknowledgement")

            players = [asyncio.create_task(player(seat)) for seat in range(4)]
            async with asyncio.timeout(120):
                await asyncio.gather(*players)
                assert await process.wait() == 0, (folder / "game.log").read_text()
        finally:
            for task in players:
                task.cancel()
            await asyncio.gather(*players, return_exceptions=True)
            if process.returncode is None:
                process.terminate()
                await process.wait()
    events = [json.loads(line) for line in (folder / "trajectory.jsonl").read_text().splitlines()]
    assert events[-1]["status"] == "completed"
    assert roles == set(range(4))
    assert len(events) == len(observations) + 1 == config["weeks"] * 4 + 1
    for event in events[:-1]:
        key = event["observation"]["week"], int(event["seat"])
        assert event["observation"]["prompt_template"] == identities[key]
        assert all(attempt["origin"] == "unknown" for attempt in event["attempts"])
    result = json.loads((folder / "results.json").read_text())
    assert result["reason"] == "complete"
    assert len({identity["variant"] for identity in identities.values()}) == 1
    public = (folder / "replay.json").read_text() + json.dumps(result)
    assert "prompt_template" not in public
    assert "PRIVATE-NOTES-" not in public and "PRIVATE-OPERATOR-" not in public
    return observations, result, systems, next(iter(identities.values()))["variant"]


async def main():
    binary, destination, revision = sys.argv[1:]
    root = Path(destination).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = json.loads((Path(__file__).resolve().parents[1] / "coworld_manifest_template.json").read_text())
    templates = ["canonical", "plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference"]
    reports = []
    for talk in (True, False):
        for seed in (17, 946001):
            canonical = None
            direct = []
            for selection, prompt_seed in [*((name, 0) for name in templates), *(("mixed", i) for i in range(5))]:
                name = f'{talk}-{seed}-{selection}-{prompt_seed}'
                run = await play(binary, root / name, manifest["variants"][0]["game_config"] | {
                    "seed": seed, "talk": talk, "turnDelayMs": 0,
                    "promptVariant": selection, "promptSeed": prompt_seed,
                }, revision)
                if selection == "canonical":
                    canonical = run
                else:
                    assert run[:2] == canonical[:2], "Wording changed state, private visibility, or results"
                if selection == "mixed":
                    assert run[2:] == direct[prompt_seed][2:]
                else:
                    assert run[3] == selection
                    direct.append(run)
                reports.append({"game": name, "decisions": len(run[0]), "selected": run[3]})
            for seat in range(4):
                assert len({run[2][seat] for run in direct}) == 7
    (root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
    print(json.dumps({"completed_games": len(reports), "templates": 7, "output": str(root)}))


asyncio.run(main())
