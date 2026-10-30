"""Export complete real teacher games and verify wording families stay in one split."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

binary, destination = sys.argv[1:]
root = Path(destination).resolve()
root.mkdir(mode=0o700, parents=True, exist_ok=False)
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
canonical = {}
physical_families = {}
for mixed in (False, True):
    output = root / ("mixed" if mixed else "canonical")
    command = [binary, str(output), "10", "1", revision]
    if mixed:
        command.append("0")
    subprocess.run(command, check=True, timeout=90)
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["source_revision"] == revision
    assert manifest["complete_episodes"] == 10
    expected_wordings = (
        {"canonical", "plain", "numbered", "questions", "reordered"}
        if mixed
        else {"canonical"}
    )
    runs = {run["episode"]: run for run in manifest["runs"]}
    families = {}
    fingerprints = {}
    counts = {}
    completed = set()
    for line in (output / "trajectories.jsonl").open():
        event = json.loads(line)
        episode = event["episode_id"]
        run = runs[episode]
        seed = run["seed"]
        scenario = run["scenario"]
        assert list(scenario) == ["weeks", "talk", "demand"]
        assert scenario["weeks"] == 36 and scenario["talk"] is True
        assert len(scenario["demand"]) == 37
        family = (
            "bullwhip-demand-v1-"
            + hashlib.sha1(
                json.dumps(scenario, separators=(",", ":")).encode()
            ).hexdigest()
        )
        assert run["scenario_family"] == family
        physical_families.setdefault(family, set()).add(seed)
        assert event["source_revision"] == revision
        if event["event_type"] == "decision":
            assert event["action_status"] == "accepted"
            observation = event["observation"]
            metadata = observation.pop("prompt_template")
            assert metadata["bank"] == "bullwhip-rules-v1"
            assert metadata["variant"] == run["prompt_variant"]
            assert metadata["selection"] == ("mixed" if mixed else "canonical")
            assert metadata["seed"] == run["prompt_seed"]
            assert len(event["attempts"]) == 1
            attempt = event["attempts"][0]
            assert attempt["origin"] == "teacher" and attempt["accepted"]
            assert attempt["parsed_action"] == event["executed_action"]
            assert event["selected_attempt_id"] == attempt["attempt_id"]
            for message in attempt["prompt"]:
                assert (
                    metadata[message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            digest = fingerprints.setdefault(episode, hashlib.sha256())
            digest.update(
                json.dumps(
                    [observation, attempt["prompt"][1], event["executed_action"]],
                    sort_keys=True,
                ).encode()
            )
            counts[episode] = counts.setdefault(episode, 0) + 1
        else:
            assert event["event_type"] == "episode" and event["status"] == "completed"
            assert event["seed_family"] == family
            assert counts[episode] == 144
            outcome = fingerprints[episode].hexdigest(), event["participant_outcomes"]
            if mixed:
                assert outcome == canonical[seed], (
                    "Wording changed a complete teacher trajectory"
                )
            else:
                canonical[seed] = outcome
            families.setdefault(seed, set()).add(run["prompt_variant"])
            completed.add(episode)
    assert completed == set(runs)
    assert set().union(*families.values()) == expected_wordings
    assert len(families) == 10
    assert all(len(wordings) == 1 for wordings in families.values())
assert len(physical_families) < 10, (
    "Distinct seeds with identical physical demand must share a split family"
)
print(
    json.dumps(
        {
            "completed_games": 20,
            "scenario_families": len(physical_families),
            "seed_aliases": 10,
        }
    )
)
