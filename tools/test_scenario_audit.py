"""Private scenario audit must not alter a complete learner-visible game."""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "coworld_manifest_template.json"
GAME = json.loads(MANIFEST.read_text())["game"]["name"]
PLAYERS = 5 if GAME == "eleusis" else 4
OPTIONS = ["--language"] if GAME == "bullwhip" else ["standard", "text" if GAME == "eleusis" else "--language"]


def start(enabled):
    environment = dict(os.environ)
    environment.pop("METTA_SCENARIO_AUDIT", None)
    if enabled:
        environment["METTA_SCENARIO_AUDIT"] = "1"
    return subprocess.Popen(
        [sys.argv[1], str(MANIFEST), *OPTIONS],
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )


def request(process, value):
    process.stdin.write(json.dumps(value) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, "bridge exited unexpectedly"
    return json.loads(line)


normal, audit = start(False), start(True)
try:
    assert request(normal, {"kind": "audit_scenario"})["kind"] == "error"
    assert request(audit, {"kind": "audit_scenario"})["kind"] == "error"
    reset = {"kind": "reset", "seed": "scenario-audit-system", "players": PLAYERS}
    visible = request(normal, reset)
    assert request(audit, reset) == visible
    initial = request(audit, {"kind": "audit_scenario"})
    assert initial["protocol"] == "coworld.native-scenario-audit.v1"
    assert initial["game"] == GAME and initial["seed"] == reset["seed"]
    assert initial["family"]
    if GAME == "bullwhip":
        assert len(initial["family"]["demand"]) == 37
        assert initial["family"]["demand"][0] == 4
    elif GAME == "hanabi":
        assert len(initial["family"]["initial_cards"]) == 50
    else:
        assert 0 <= initial["family"]["rule_id"] < 68
    steps = 0
    while visible["kind"] == "decision":
        assert request(normal, {"kind": "audit_scenario"})["kind"] == "error"
        assert request(audit, {"kind": "audit_scenario"}) == initial
        teacher = request(normal, {"kind": "teacher"})
        assert request(audit, {"kind": "teacher"}) == teacher
        action = {"kind": "step", "decision_id": visible["decision_id"], "response": teacher["response"]}
        result = request(normal, action)
        assert request(audit, action) == result
        assert result["kind"] == "accepted"
        visible = result["observation"]
        steps += 1
    assert request(audit, {"kind": "audit_scenario"}) == initial
    assert set(visible["scores"]) == {str(seat) for seat in range(PLAYERS)}
    families = []
    for seed in ["80f84ae0e84c9a05", "872981009609e632"]:
        request(audit, {"kind": "reset", "seed": seed, "players": PLAYERS})
        evidence = request(audit, {"kind": "audit_scenario"})
        assert evidence["engine_seed"] == 861174924
        families.append(evidence["family"])
    assert families[0] == families[1]
    print(GAME, steps, "decisions unchanged; audit stable; seed aliases grouped")
finally:
    for process in [normal, audit]:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()
