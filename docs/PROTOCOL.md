# Bullwhip player protocol

All messages are JSON text frames over authenticated `COWORLD_PLAYER_WS_URL`.
The welcome frame declares `bullwhip.player.v3`. Register once after welcome;
registration and new socket admission freeze before gameplay starts.

The reference player sends `{type: "prompt", prompt: string, scripted: string|false}`.
The game owns its native model calls or named private-view baseline.
An external player sends `{type: "register", control: "external", prompt: string}`.

External `decision` frames contain an opaque `decision_id`, private
`observation`, exact `messages`, and separate `transport.budget_ms` and
`transport.cleanup_budget_ms`. One original `llmTimeoutSeconds` budget covers
all four seats and their repairs. Retry frames are `rejected` with the exact
new decision in `observation`; they consume remaining time.

Before HTTP, send `{type: "attempt_started", decision_id, training_attempt}`.
The strict Bitworld attempt wire must identify `decision_id + "-model"`, use
origin `model`, preserve the exact issued prompt and request, and contain no
observed response facts. Later progress cannot rewrite request intent,
received byte prefixes, completed bodies, identities, or finished facts.

Return `{type: "action", decision_id, source, action, training_attempt}`.
`source` is `llm`, `unknown`, or `fallback`; action contains `order`, `say`,
and `notes`. `llm` requires the prestarted complete successful response,
joined reader, actual raw HTTP evidence, and response text/model equality
with the received body. Its normal parser result must equal the submitted
action. Unknown proposals remain excluded from model and teacher labels.
A rejected order gets one repair; another rejection consumes base-stock.

At shutdown, `stop` carries `stop_id`, the latest `decision_id` or null,
and the remaining `cleanup_budget_ms`. Every registered external owner,
including a disconnected seat, must join its native worker before sending
`{type: "stopped", stop_id, decision_id, worker_status, attempts}`.
Worker status is `joined` or `no_active_call`. Preserve genuine partial and
late evidence for its issued decision. Only the exact latest ID, nonce,
receipt window, and joined-reader facts earn acknowledgement credit.
Wait for matching `evidence_received` before closing the client.

The engine stages authoritative decisions until cleanup. Missing acknowledgements
or interruption produce private `truncated` traces and no public results/replay.
Unexpected runtime failures produce private `failed` traces after owned joins.
Private trajectory upload precedes public artifacts within one five-second
cleanup deadline. Provider bytes, strategy prompts, notes, and native call IDs
never appear in public replay or logs. Frame budget is 16 MiB.
