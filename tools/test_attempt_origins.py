"""Exercise player-controlled provenance and reply/action bindings on real sockets."""
import asyncio
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
import websockets

ROOT = Path(__file__).resolve().parents[1]
GAME = str(Path(sys.argv[1]).resolve())

async def player(port, seat, origin):
    async with websockets.connect(f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}") as socket:
        await socket.send(json.dumps({"type": "register", "control": "external"}))
        async for raw in socket:
            packet = json.loads(raw)
            if packet["type"] == "final": break
            if packet["type"] != "observation": continue
            evidence = {"attempt_id": f"{seat}-{packet['week']}", "policy": "untrusted-player",
                        "origin": "model" if origin == "model-mismatch" else origin,
                        "platform_call_id": None, "rejection_reason": None,
                        "response": '{"order":40}', "latency_ms": None,
                        "input_tokens": None, "output_tokens": None,
                        "prompt": [{"role": "user", "content": json.dumps(packet["observation"])}],
                        "request": {"observation": packet["observation"]},
                        "raw_response": '{"order":40}', "model": "asserted-policy",
                        "model_identity": "a" * 40, "tokenizer_identity": None,
                        "chat_template_sha256": None, "decoder": {"method": "deterministic"},
                        "prompt_token_ids": None, "sampled_token_ids": None,
                        "behavior_logprobs": None, "stop_reason": None}
            await socket.send(json.dumps({"type": "action", "week": packet["week"],
                "action": {"order": 70 if origin == "model-mismatch" else 40},
                "training_attempt": evidence}))

for origin in ("teacher", "human", "model-mismatch"):
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        config = {"tokens": [f"t{s}" for s in range(4)],
                  "players": [{"name": f"p{s}"} for s in range(4)], "seed": 7,
                  "weeks": 4, "turnDelayMs": 0, "player_connect_timeout_seconds": 5,
                  "llmTimeoutSeconds": 1}
        (output / "config.json").write_text(json.dumps(config))
        env = {**os.environ, "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
               "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
               "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
               "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
               "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
               "COWORLD_EPISODE_ID": str(uuid.uuid4()), "COWORLD_GAME_VERSION": "attack-fixture",
               "COWORLD_SOURCE_REVISION": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
        for key in ("COWORLD_LLM_ENDPOINT", "AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI"):
            env[key] = ""
        with (output / "game.log").open("w") as log:
            game = subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    assert game.poll() is None
                    with socket.socket() as probe:
                        if probe.connect_ex(("127.0.0.1", port)) == 0: break
                    time.sleep(.05)
                else: raise AssertionError("game did not start")
                async def play():
                    await asyncio.gather(*(player(port, seat, origin) for seat in range(4)))
                asyncio.run(asyncio.wait_for(play(), timeout=30))
                assert game.wait(timeout=5) == 0, (output / "game.log").read_text()
                events = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()]
                assert len(events[:-1]) == 16 and events[-1]["status"] == "completed"
                for decision in events[:-1]:
                    attempt, = decision["attempts"]
                    if origin == "model-mismatch":
                        assert attempt["origin"] == "model" and not attempt["accepted"]
                        assert attempt["parsed_action"] == {"order": 40, "say": "", "notes": ""}
                        assert decision["selected_attempt_id"] is None and decision["action_status"] == "fallback"
                    else:
                        assert attempt["origin"] == "unknown" and attempt["accepted"]
                        assert attempt["parsed_action"] == decision["executed_action"]
                print(origin, "16 external decisions; no asserted teacher or mismatched model targets", flush=True)
            finally:
                if game.poll() is None: game.terminate(); game.wait(timeout=5)
