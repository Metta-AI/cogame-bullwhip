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
