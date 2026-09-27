#!/usr/bin/env bash
set -euo pipefail

seed=${1:?usage: local_episode.sh seed weeks}
weeks=${2:?weeks required}
port=${PORT:-18082}

mkdir -p bin tmp
episode_dir=$(mktemp -d tmp/episode.XXXXXX)
episode_dir="$PWD/$episode_dir"
python3 - "$seed" "$weeks" "$episode_dir/config.json" <<'PY'
import json
import sys
from pathlib import Path
seed, weeks, path = sys.argv[1:]
Path(path).write_text(json.dumps({
    'tokens': ['t0', 't1', 't2', 't3'],
    'players': [{'name': f'P{i}'} for i in range(4)],
    'seed': int(seed), 'weeks': int(weeks), 'turnDelayMs': 0,
    'player_connect_timeout_seconds': 10,
}))
PY
nim c --hints:off -o:bin/bullwhip src/bullwhip.nim
nim c --hints:off -o:bin/bullwhip-player src/bullwhip_player.nim
bin/bullwhip --host:127.0.0.1 --port:"$port" \
  --config-path:"$episode_dir/config.json" \
  --results-uri:"file://$episode_dir/results.json" \
  --save-replay-uri:"file://$episode_dir/episode.replay" \
  > "$episode_dir/game.log" 2>&1 &
game=$!
trap 'kill "$game" 2>/dev/null || true' EXIT
sleep 0.5
for slot in 0 1 2 3; do
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
    PLAYER_SCRIPTED=basestock bin/bullwhip-player \
    > "$episode_dir/player$slot.log" 2>&1 &
done
wait "$game"
python3 - "$episode_dir" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
results = json.loads((path / 'results.json').read_text())
replay = json.loads((path / 'episode.replay').read_text())
print(json.dumps({
    'artifacts': str(path), 'weeks': results['weeks'],
    'seat0_cost': results['costs'][0], 'chain_cost': results['chainCost'],
    'seat0_scripted_orders': sum(event['scripted'] for event in replay['events']
        if event['kind'] == 'order' and event['seat'] == 0),
}))
PY
