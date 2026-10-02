"""Exercise Bullwhip through Metta's numeric decision protocol."""

import json
import sys
from pathlib import Path

from metta_training.decision_environment import DecisionEncoding
from metta_training.game import Terminal
from metta_training.session import GameBridge


BRIDGE = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"

for seed in ("test-1", "test-2"):
    with GameBridge([str(BRIDGE), str(MANIFEST)]) as bridge:
        observation = bridge.reset(seed, 4)
        decisions = 0
        while not isinstance(observation, Terminal):
            encoding = DecisionEncoding.model_validate_json(
                bridge.request({"kind": "encode"})
            )
            assert len(encoding.values) == 666
            assert len(encoding.actions) == 501
            action = json.loads(bridge.teacher())
            assert encoding.action_for(encoding.indices_for(action)) == action
            observation = bridge.step(
                observation.decision_id, json.dumps(action)
            ).observation
            decisions += 1
        assert decisions == 4 * 36
        assert all(score <= 0 for score in observation.scores.values())
        print(seed, decisions, observation.scores)

for seed in ("language-1", "language-2"):
    with GameBridge([str(BRIDGE), str(MANIFEST), "--language"]) as bridge:
        observation = bridge.reset(seed, 4)
        assert observation.inference_mode == "text_action"
        first_prompt = observation.messages[-1].content
        rejected = bridge.step(observation.decision_id, "invalid JSON")
        assert rejected.kind == "rejected"
        assert rejected.observation.decision_id == observation.decision_id
        retry_prompt = rejected.observation.messages[-1].content
        assert retry_prompt.startswith(first_prompt)
        assert "Your previous reply was invalid" in retry_prompt
        expected_fallback = json.loads(bridge.teacher())
        consumed = bridge.step(observation.decision_id, "{invalid again}")
        assert consumed.kind == "consumed_rejection"
        assert consumed.action == expected_fallback
        observation = consumed.observation
        decisions = 1
        while not isinstance(observation, Terminal):
            sampled = bridge.teacher()
            result = bridge.step(observation.decision_id, "```json\n" + sampled + "\n```")
            assert result.kind == "accepted"
            assert result.action == json.loads(sampled)
            observation = result.observation
            decisions += 1
        assert decisions == 4 * 36
        print(seed, decisions, "complete language decisions including consumed fallback")
