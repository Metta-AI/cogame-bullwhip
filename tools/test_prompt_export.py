"""Export complete real teacher games and verify wording families stay in one split."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

binary, destination = sys.argv[1:]
root = Path(destination).resolve()
root.mkdir(mode=0o700, parents=True, exist_ok=False)
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
canonical = {}
for mixed in (False, True):
    output = root / ("mixed" if mixed else "canonical")
    command = [binary, str(output), "10", "1", revision]
    if mixed:
        command.append("0")
    subprocess.run(command, check=True, timeout=90)
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["source_revision"] == revision
    assert manifest["complete_episodes"] == (50 if mixed else 10)
    expected_wordings = {"canonical", "plain", "numbered", "questions", "reordered"} if mixed else {"canonical"}
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
                assert metadata[message["role"] + "_sha256"].lower() == hashlib.sha256(
                    message["content"].encode()
                ).hexdigest()
            digest = fingerprints.setdefault(episode, hashlib.sha256())
            digest.update(json.dumps([observation, attempt["prompt"][1], event["executed_action"]], sort_keys=True).encode())
            counts[episode] = counts.setdefault(episode, 0) + 1
        else:
            assert event["event_type"] == "episode" and event["status"] == "completed"
            assert event["seed_family"] == f"bullwhip-{seed}"
            assert counts[episode] == 144
            outcome = fingerprints[episode].hexdigest(), event["participant_outcomes"]
            if mixed:
                assert outcome == canonical[seed], "Wording changed a complete teacher trajectory"
            else:
                canonical[seed] = outcome
            families.setdefault(seed, set()).add(run["prompt_variant"])
            completed.add(episode)
    assert completed == set(runs)
    assert all(wordings == expected_wordings for wordings in families.values())
    split_families = {}
    split_episodes = set()
    for split in ("train", "validation"):
        selected = set()
        for line in (output / f"{split}-trajectories.jsonl").open():
            event = json.loads(line)
            run = runs[event["episode_id"]]
            assert run["split"] == split
            if event["event_type"] == "episode":
                selected.add(event["seed_family"])
                split_episodes.add(event["episode_id"])
        split_families[split] = selected
    assert len(split_families["train"]) == 8 and len(split_families["validation"]) == 2
    assert split_families["train"].isdisjoint(split_families["validation"])
    assert split_episodes == completed
print(json.dumps({"completed_games": 60, "scenario_families": 10, "mixed_wordings_per_family": 5}))
