"""Real four-request parallel HTTP ownership, shared deadline and signal gates."""

import base64
import http.server
import json
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

binary = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
root.mkdir(mode=0o700)
for mode in ("complete", "mixed", "deadline", "term", "int"):
    barrier = threading.Barrier(4)
    prefix_ready = threading.Event()
    release = threading.Event()
    lock = threading.Lock()
    seats = []
    prefixes = []
    payload = b'{"ok":true}' if mode in {"complete", "mixed"} else b"\xffowned"

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seat = int(self.headers["X-Coworld-Player-Slot"])
            assert request == {"seat": seat}
            with lock:
                seats.append(seat)
            barrier.wait(timeout=5)
            complete = mode == "complete" or (mode == "mixed" and seat < 3)
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload) if complete else 64))
            self.send_header("X-Fixture-Seat", str(seat))
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            with lock:
                prefixes.append(seat)
                if len(prefixes) == 4:
                    prefix_ready.set()
            if not complete:
                release.wait(6)

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    owner = threading.Thread(target=server.serve_forever)
    output = root / (mode + ".json")
    with server, (root / (mode + ".log")).open("w") as log:
        owner.start()
        process = subprocess.Popen(
            [
                str(binary),
                str(output),
                f"http://127.0.0.1:{server.server_port}/v1/messages",
                "300" if mode in {"deadline", "mixed"} else "5000",
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        try:
            if mode in {"term", "int"}:
                assert prefix_ready.wait(2)
                started = time.monotonic()
                process.send_signal(signal.SIGTERM if mode == "term" else signal.SIGINT)
            assert process.wait(timeout=8) == 0
            if mode in {"term", "int"}:
                assert time.monotonic() - started < 2
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
            release.set()
            server.shutdown()
            owner.join(timeout=2)
            assert not owner.is_alive()
    report = json.loads(output.read_text())
    assert sorted(seats) == list(range(4))
    assert len(report["responses"]) == 4
    for seat, response in enumerate(report["responses"]):
        assert response["status"] == 200
        assert response["reader_joined"] is True
        assert base64.b64decode(response["body_b64"]) == payload
        assert f"X-Fixture-Seat: {seat}".encode() in base64.b64decode(response["headers_b64"])
        complete = mode == "complete" or (mode == "mixed" and seat < 3)
        assert response["complete"] == complete
        if mode == "mixed":
            assert response["kind"] == ("nhComplete" if complete else "nhDeadline")
            assert (response["received_elapsed_ms"] < 300) == complete
            if complete:
                assert response["received_elapsed_ms"] < report["elapsed_ms"] - 100
            continue
        assert (
            response["kind"]
            == {"complete": "nhComplete", "deadline": "nhDeadline", "term": "nhInterrupted", "int": "nhInterrupted"}[
                mode
            ]
        )
    assert report["interrupted"] == (mode in {"term", "int"})
    if mode in {"deadline", "mixed"}:
        assert report["elapsed_ms"] < 700
    print(
        json.dumps(
            {
                "case": mode,
                "requests": 4,
                "elapsed_ms": report["elapsed_ms"],
                "joined": True,
                "scope": "native transport fixture only; zero receipt authority",
            }
        )
    )
