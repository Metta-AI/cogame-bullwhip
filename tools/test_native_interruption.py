"""Actual partial HTTP signals join every native worker before private seal."""

import base64
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

root = Path(__file__).resolve().parents[1]
game, player = (str(Path(value).resolve()) for value in sys.argv[1:3])
output_root = Path(sys.argv[3]).resolve()
output_root.mkdir(mode=0o700)
for stop_signal in (signal.SIGTERM, signal.SIGINT):
    output = output_root / stop_signal.name
    output.mkdir(mode=0o700)
    ready = threading.Event()
    release = threading.Event()
    lock = threading.Lock()
    calls = {}
    prefix = b"\xffprivate-partial-native"

    class Provider(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            slot = int(self.headers["X-Coworld-Player-Slot"])
            call_id = str(uuid.uuid4())
            self.send_response(200)
            self.send_header("Content-Length", "1000")
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            self.send_header("request-id", f"provider-{slot}")
            self.end_headers()
            self.wfile.write(prefix)
            self.wfile.flush()
            with lock:
                calls[call_id] = {"slot": slot, "request": request}
                if len(calls) == 4:
                    ready.set()
            assert release.wait(8)

        def log_message(self, *_args):
            pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    owner = threading.Thread(target=provider.serve_forever)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    config = {
        "tokens": [f"t{seat}" for seat in range(4)],
        "players": [{"name": f"p{seat}"} for seat in range(4)],
        "seed": 7,
        "weeks": 36,
        "talk": True,
        "turnDelayMs": 0,
        "player_connect_timeout_seconds": 5,
        "llmTimeoutSeconds": 60,
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
        "COWORLD_GAME_VERSION": "unfrozen-native-lifecycle-fixture",
        "COWORLD_SOURCE_REVISION": os.environ["COWORLD_SOURCE_REVISION"],
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
        "COWORLD_LLM_MODEL": "fixture/requested",
        "COWORLD_LLM_TEMPERATURE": "0",
        "PLAYER_PROMPT": "private-operator-fixture",
        "PLAYER_SCRIPTED": "",
    }
    processes = []
    with provider, (output / "game.log").open("w") as log:
        owner.start()
        try:
            processes.append(subprocess.Popen([game], cwd=root, env=env, stdout=log, stderr=log))
            for _ in range(100):
                assert processes[0].poll() is None
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game did not start")
            for seat in range(4):
                player_env = {
                    **env,
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                }
                processes.append(subprocess.Popen([player], cwd=root, env=player_env, stdout=log, stderr=log))
            assert ready.wait(5)
            started = time.monotonic()
            processes[0].send_signal(stop_signal)
            for process in processes:
                assert process.wait(timeout=5) == 0
            elapsed = time.monotonic() - started
            assert elapsed < 2
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)
            release.set()
            provider.shutdown()
            owner.join(timeout=2)
            assert not owner.is_alive()
    events = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()]
    assert len(events) == 5
    assert events[-1]["status"] == "truncated"
    assert events[-1]["participant_outcomes"] is None
    assert not (output / "results.json").exists()
    assert not (output / "replay.json").exists()
    recorded = set()
    for decision in events[:-1]:
        assert decision["action_status"] == "missing"
        assert decision["executed_action"] is None
        assert decision["selected_attempt_id"] is None
        assert len(decision["attempts"]) == 1
        attempt = decision["attempts"][0]
        call_id = attempt["platform_call_id"]
        recorded.add(call_id)
        assert calls[call_id]["request"] == attempt["request"]
        assert base64.b64decode(attempt["response_body_b64"]) == prefix
        assert f"request-id: provider-{calls[call_id]['slot']}".encode() in base64.b64decode(
            attempt["response_headers_b64"]
        )
        assert attempt["response_complete"] is False
        assert attempt["response_reader_joined"] is True
        assert attempt["http_status"] == 200
        assert attempt["raw_response"] is None
        assert attempt["response"] is None
        assert attempt["accepted"] is False
    assert recorded == set(calls)
    public = (output / "game.log").read_text()
    for private in ("private-partial-native", "private-operator-fixture", *calls):
        assert private not in public
    assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
    report = {
        "signal": stop_signal.name,
        "elapsed_seconds": elapsed,
        "joined": 4,
        "scope": "fixture only; zero authority",
    }
    (output / "proof.json").write_text(json.dumps(report))
    print(json.dumps(report), flush=True)
