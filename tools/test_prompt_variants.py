"""Complete real language-bridge games; compare wording without inference substitutes."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


binary = Path(sys.argv[1]).resolve()
manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
templates = [
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
]
completed = 0
for talk in (True, False):
    config = json.loads(manifest.read_text())
    config["variants"][0]["game_config"]["talk"] = talk
    directory = tempfile.TemporaryDirectory(prefix="bullwhip-bridge-")
    variant_manifest = Path(directory.name) / "manifest.json"
    variant_manifest.write_text(json.dumps(config))
    process = subprocess.Popen(
        [str(binary), str(variant_manifest), "--language"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )

    def request(value):
        process.stdin.write(json.dumps(value) + "\n")
        process.stdin.flush()
        line = process.stdout.readline()
        assert line, process.poll()
        return json.loads(line)

    try:
        for seed in ("prompt-17",):
            canonical = None
            direct_systems = []
            for selection, prompt_seed in [
                *((name, 0) for name in templates),
                ("mixed", 4),
            ]:
                selected = templates[prompt_seed] if selection == "mixed" else selection
                observation = request(
                    {
                        "kind": "reset",
                        "seed": seed,
                        "players": 4,
                        "promptVariant": selection,
                        "promptSeed": prompt_seed,
                        "split": "validation",
                    }
                )
                transcript = []
                systems = {}
                while observation["kind"] == "decision":
                    view = observation["semantic_view"]
                    metadata = view.pop("prompt_template")
                    assert metadata["bank"] == "bullwhip-rules-v1"
                    assert (
                        metadata["selection"],
                        metadata["seed"],
                        metadata["variant"],
                    ) == (
                        selection,
                        prompt_seed,
                        selected,
                    )
                    system, user = observation["messages"]
                    assert [system["role"], user["role"]] == ["system", "user"]
                    for message in (system, user):
                        assert (
                            metadata[message["role"] + "_sha256"].lower()
                            == hashlib.sha256(message["content"].encode()).hexdigest()
                        )
                    seat = observation["seat"]
                    assert (
                        systems.setdefault(seat, system["content"]) == system["content"]
                    )
                    if not transcript:
                        rejected = request(
                            {
                                "kind": "step",
                                "decision_id": observation["decision_id"],
                                "response": '{"order": 4}\n{"order": 5}'
                                if talk
                                else "not JSON",
                            }
                        )
                        assert rejected["kind"] == "rejected"
                        repaired = rejected["observation"]
                        assert repaired["decision_id"] == observation["decision_id"]
                        repair_metadata = repaired["semantic_view"].pop(
                            "prompt_template"
                        )
                        assert repaired["semantic_view"] == view
                        assert (
                            repaired["messages"][0] == system
                            and repaired["messages"][1] != user
                        )
                        assert repair_metadata["variant"] == selected
                        for message in repaired["messages"]:
                            assert (
                                repair_metadata[message["role"] + "_sha256"].lower()
                                == hashlib.sha256(
                                    message["content"].encode()
                                ).hexdigest()
                            )
                    action = json.loads(request({"kind": "teacher"})["response"])
                    transcript.append((view, user, action))
                    result = request(
                        {
                            "kind": "step",
                            "decision_id": observation["decision_id"],
                            "response": json.dumps(action),
                        }
                    )
                    assert result["kind"] == "accepted" and result["action"] == action
                    observation = result["observation"]
                    assert len(transcript) <= 36 * 4
                assert observation["kind"] == "terminal" and transcript
                assert len(transcript) == 36 * 4
                assert all(value <= 0 for value in observation["scores"].values())
                outcome = transcript, observation
                if selection == "canonical":
                    canonical = outcome
                else:
                    assert outcome == canonical, (
                        "Wording changed private views, actions, or outcomes"
                    )
                if selection == "mixed":
                    assert systems == direct_systems[prompt_seed]
                else:
                    direct_systems.append(systems)
                completed += 1
            for seat in range(4):
                assert len({system[seat] for system in direct_systems}) == 7
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0

    for configuration in (
        {"promptVariant": "heldout-briefing"},
        {"promptVariant": "heldout-reference"},
        {"promptVariant": "mixed"},
        {"promptVariant": "plain", "promptSeed": -1},
        {"promptVariant": "mixed", "promptSeed": True},
    ):
        result = subprocess.run(
            [str(binary), str(variant_manifest), "--language"],
            input=json.dumps(
                {"kind": "reset", "seed": "rejected", "players": 4} | configuration
            )
            + "\n",
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert result.returncode != 0 and not result.stdout
    directory.cleanup()
print(
    json.dumps({"completed_games": completed, "training_templates": 5, "talk_modes": 2})
)
