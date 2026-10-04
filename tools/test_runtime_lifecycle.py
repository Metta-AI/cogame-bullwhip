"""Actual deadline, pacing interruption and private-first HTTP artifact gates."""

import http.server
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
OUTPUT.mkdir(mode=0o700)
for case in (
    "missing-seats",
    "paced-term",
    "paced-int",
    "invalid-budget",
    "http-artifacts",
    "private-upload503",
):
    output = OUTPUT / case
    output.mkdir(mode=0o700)
    received = []

    class Artifacts(http.server.BaseHTTPRequestHandler):
        def do_PUT(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            received.append((self.command, self.path, body))
            self.send_response(
                503 if case == "private-upload503" and self.path == "/private" else 200
            )
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *_args):
            pass

    artifacts = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Artifacts)
    artifact_owner = threading.Thread(target=artifacts.serve_forever)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    config = {
        "tokens": [f"t{seat}" for seat in range(4)],
        "players": [{"name": f"p{seat}"} for seat in range(4)],
        "seed": 7,
        "weeks": 4,
        "talk": True,
        "turnDelayMs": 30000 if case.startswith("paced-") else 0,
        "player_connect_timeout_seconds": 30 if case == "missing-seats" else 5,
        "llmTimeoutSeconds": 0 if case == "invalid-budget" else 60,
    }
    (output / "config.json").write_text(json.dumps(config))
    http_artifacts = case in {"http-artifacts", "private-upload503"}
    env = {
        **os.environ,
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": f"http://127.0.0.1:{artifacts.server_port}/results"
        if http_artifacts
        else (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": f"http://127.0.0.1:{artifacts.server_port}/replay"
        if http_artifacts
        else (output / "replay.json").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": f"http://127.0.0.1:{artifacts.server_port}/private"
        if http_artifacts
        else (output / "trajectory.jsonl").as_uri(),
        "COGAME_SAVE_TRAJECTORY_METHOD": "PUT",
        "COWORLD_EPISODE_ID": str(uuid.uuid4()),
        "COWORLD_GAME_VERSION": "runtime-lifecycle-fixture",
        "COWORLD_SOURCE_REVISION": os.environ["COWORLD_SOURCE_REVISION"],
        "COWORLD_TIMEOUT_SECONDS": "2" if case == "missing-seats" else "40",
        "COWORLD_LLM_ENDPOINT": "",
        "PLAYER_SCRIPTED": "basestock",
    }
    processes = []
    with artifacts, (output / "game.log").open("w") as log:
        artifact_owner.start()
        try:
            started = time.monotonic()
            game = subprocess.Popen(
                [str(GAME)], cwd=ROOT, env=env, stdout=log, stderr=log
            )
            processes.append(game)
            if case not in {"missing-seats", "invalid-budget"}:
                for _ in range(100):
                    assert game.poll() is None
                    with socket.socket() as probe:
                        if probe.connect_ex(("127.0.0.1", port)) == 0:
                            break
                    time.sleep(0.02)
                else:
                    raise AssertionError("game listener did not start")
                for seat in range(4):
                    processes.append(
                        subprocess.Popen(
                            [str(PLAYER)],
                            cwd=ROOT,
                            env={
                                **env,
                                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                            },
                            stdout=log,
                            stderr=log,
                        )
                    )
            if case.startswith("paced-"):
                for _ in range(100):
                    assert game.poll() is None
                    if " orders " in (output / "game.log").read_text():
                        break
                    time.sleep(0.02)
                else:
                    raise AssertionError("game never reached pacing")
                started = time.monotonic()
                game.send_signal(
                    signal.SIGTERM if case == "paced-term" else signal.SIGINT
                )
            status = game.wait(timeout=12)
            elapsed = time.monotonic() - started
            assert status == (
                1 if case in {"invalid-budget", "private-upload503"} else 0
            )
            if case == "missing-seats":
                assert elapsed < 2.5, elapsed
            if case.startswith("paced-"):
                assert elapsed < 1, elapsed
            for player in processes[1:]:
                assert player.wait(timeout=5) == 0
            if http_artifacts:
                assert [path for _, path, _ in received] == (
                    ["/private"]
                    if case == "private-upload503"
                    else ["/private", "/results", "/replay"]
                )
                raw = received[0][2].decode()
                (output / "received-private.jsonl").write_text(raw)
            else:
                raw = (output / "trajectory.jsonl").read_text()
            events = [json.loads(line) for line in raw.splitlines()]
            episode = events[-1]
            expected = (
                "failed"
                if case == "invalid-budget"
                else "truncated"
                if case.startswith("paced-") or case == "missing-seats"
                else "completed"
            )
            assert episode["status"] == expected
            if case in {"missing-seats", "invalid-budget", "paced-term", "paced-int"}:
                assert (
                    not (output / "results.json").exists()
                    and not (output / "replay.json").exists()
                )
            for decision in events[:-1]:
                for attempt in decision["attempts"]:
                    assert (
                        attempt["origin"] == "fallback"
                        and attempt["raw_response"] is None
                    )
            print(
                json.dumps(
                    {
                        "case": case,
                        "elapsed_seconds": elapsed,
                        "status": expected,
                        "artifact_paths": [path for _, path, _ in received],
                        "scope": "source fixture; zero serving authority",
                    }
                ),
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            artifacts.shutdown()
            artifact_owner.join(timeout=5)
            assert not artifact_owner.is_alive()
