"""Run complete native socket games against a local Messages fixture; no paid calls."""
import contextlib
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER = (str(Path(arg).resolve()) for arg in sys.argv[1:3])
for mode in ("accepted", "invalid", "sampled", "greedy-null", "greedy-tokens", "provider-error"):
    if os.environ.get("BULLWHIP_NATIVE_FIXTURE_MODE") and mode != os.environ["BULLWHIP_NATIVE_FIXTURE_MODE"]: continue
    calls = {}

    class Messages(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.path == "/v1/messages"
            request = json.loads(self.rfile.read(int(self.headers["content-length"])))
            assert request["temperature"] == (1 if mode == "sampled" else 0)
            slot = int(self.headers["X-Coworld-Player-Slot"])
            text = "invalid JSON" if mode == "invalid" and slot == 0 else json.dumps(
                {"order": 8, "say": "public forecast", "notes": "private-notebook-fixture"})
            call_id = str(uuid.uuid4())
            body = {"id": "msg_" + call_id, "model": "fixture/served",
                    "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                    "usage": {"input_tokens": 10, "output_tokens": 5}}
            if mode in {"sampled", "greedy-tokens"}:
                body["sampling_evidence"] = {
                    "policy_revision": "a" * 64, "tokenizer_revision": "b" * 64,
                    "chat_template": "fixture-template", "sampling": "full_softmax_temperature_one" if mode == "sampled" else "greedy",
                    "enable_thinking": False, "max_new_tokens": request["max_tokens"],
                    "max_sequence_length": 4096, "sampling_seed": 7, "eos_token_ids": [4],
                    "prompt_token_ids": [1, 2], "completion_token_ids": [3, 4],
                    "behavior_log_probs": [-.5, -.3] if mode == "sampled" else None,
                    "stop_reason": "eos", "response": text}
            if mode == "greedy-null": body["sampling_evidence"] = None
            failed = mode == "provider-error" and slot == 0
            if failed: body = {"error": {"message": "private-provider-error-fixture"}}
            calls[call_id] = (request, body)
            encoded = json.dumps(body).encode()
            self.send_response(500 if failed else 200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            if mode in {"sampled", "greedy-tokens"}:
                self.send_header("X-Coworld-Checkpoint-Sha256", "a" * 64)
                self.send_header("X-Coworld-Tokenizer-Sha256", "b" * 64)
                self.send_header("X-Coworld-Chat-Template-Sha256", "c" * 64)
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, *_args):
            pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Messages)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    if len(sys.argv) == 4:
        target = Path(sys.argv[3]) / mode
        target.mkdir(parents=True, mode=0o700, exist_ok=False)
        output_context = contextlib.nullcontext(target)
    else: output_context = tempfile.TemporaryDirectory()
    with output_context as directory:
        output = Path(directory)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        config = {"tokens": [f"t{s}" for s in range(4)],
                  "players": [{"name": f"p{s}"} for s in range(4)], "seed": 7,
                  "weeks": 4, "talk": True, "turnDelayMs": 0,
                  "player_connect_timeout_seconds": 5, "llmTimeoutSeconds": 5}
        (output / "config.json").write_text(json.dumps(config))
        env = {**os.environ, "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
               "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
               "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
               "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
               "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
               "COWORLD_EPISODE_ID": str(uuid.uuid4()), "COWORLD_GAME_VERSION": "native-fixture",
               "COWORLD_SOURCE_REVISION": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
               "COWORLD_LLM_MODEL": "fixture/requested", "COWORLD_LLM_TEMPERATURE": "1" if mode == "sampled" else "0",
               "PLAYER_PROMPT": "private-strategy-fixture", "PLAYER_SCRIPTED": ""}
        processes = []
        with (output / "game.log").open("w") as log:
            try:
                processes.append(subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log))
                for _ in range(100):
                    assert processes[0].poll() is None
                    with socket.socket() as probe:
                        if probe.connect_ex(("127.0.0.1", port)) == 0: break
                    time.sleep(.05)
                else: raise AssertionError("game did not start")
                for seat in range(4):
                    player_env = {**env, "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}"}
                    processes.append(subprocess.Popen([PLAYER], cwd=ROOT, env=player_env, stdout=log, stderr=log))
                for process in processes: assert process.wait(timeout=40) == 0, (output / "game.log").read_text()
                events = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()]
                assert len(events[:-1]) == 16 and events[-1]["status"] == "completed"
                assert events[-1]["outcome"]["weeks"] == 4
                recorded = set()
                fallback = 0
                for decision in events[:-1]:
                    assert decision["visibility"] == "private"
                    for attempt in decision["attempts"]:
                        assert attempt["inference_mode"] == "text_action"
                        call_id = attempt["platform_call_id"]
                        request, body = calls[call_id]
                        recorded.add(call_id)
                        assert attempt["request"] == request
                        assert json.loads(attempt["raw_response"]) == body
                        assert attempt["prompt"] == [{"role": "system", "content": request["system"]}, *request["messages"]]
                        if attempt["accepted"]:
                            assert attempt["model"] == "fixture/served"
                            assert attempt["parsed_action"] == decision["executed_action"]
                        else: assert attempt["rejection_reason"]
                        if mode in {"sampled", "greedy-tokens"}:
                            assert attempt["prompt_token_ids"] == [1, 2]
                            assert attempt["sampled_token_ids"] == [3, 4]
                            assert attempt["behavior_logprobs"] == ([-.5, -.3] if mode == "sampled" else None)
                            assert attempt["model_identity"] == "a" * 64
                    if decision["action_status"] == "fallback":
                        fallback += 1
                        assert decision["selected_attempt_id"] is None and len(decision["attempts"]) == 2
                    else:
                        assert decision["selected_attempt_id"] == decision["attempts"][-1]["attempt_id"]
                assert recorded == set(calls)
                assert fallback == (4 if mode in {"invalid", "provider-error"} else 0)
                replay = (output / "replay.json").read_text()
                public = replay + (output / "game.log").read_text()
                for secret in ["private-notebook-fixture", "private-strategy-fixture", "private-provider-error-fixture", *calls]:
                    assert secret not in public
                assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
                archive = output / "fixture_calls.json"
                archive.write_text(json.dumps({"cohort": "local native HTTP fixture; no hosted platform archive", "synthetic_model_identities": True, "calls": calls}))
                archive.chmod(0o600)
                print(mode, "16 decisions", len(recorded), "native fixture joins", flush=True)
            finally:
                for process in processes:
                    if process.poll() is None: process.terminate(); process.wait(timeout=5)
        provider.shutdown()
        provider.server_close()
