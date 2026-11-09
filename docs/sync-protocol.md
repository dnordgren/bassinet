# Offline sync protocol

The rule: **the server is a log, not a state machine.** Every mutation is an
idempotent append; the client's view is a projection of the log. That one
decision makes offline replay, live push, and multi-device convergence all the
same code path.

---

## 1. The outbox

Writes go to IndexedDB first, always. Online or offline, the same path.

```
DB: chuckleberry (IndexedDB v1)

outbox        { key: auto, op_id (uuidv7), method, path, body, target_id,
                created_at, attempts, next_retry_at, state }   // state: pending|inflight|failed
events        { event_id, child_id, ... }  // mirror, keyed by event_id
children      { child_id, ... }
meta          { key: 'cursor:<child_id>', value: {updated_at, event_id} }
meta          { key: 'last_sync_at', value: epoch_ms }
```

`op_id` is the event_id for creates, and a fresh UUIDv7 for updates/deletes.
It's also sent as the `Idempotency-Key` header so a retried request that the
server *did* process (but whose response was lost) returns the original result
instead of erroring.

### Write path (online or off, identical)

1. Build the full item client-side: `event_id = uuidv7()`,
   `occurred_at = now()`, `child_id`, `author_id` (from session cache).
2. `Transaction: outbox.add(op) + events.put(item)` — one IndexedDB transaction,
   so the local mirror and the queue can never disagree.
3. Emit `local:changed` → UI re-renders immediately. Tile flashes, entry appears
   in the day list with a pulsing "syncing" dot.
4. Kick the drain loop.

### Drain loop

```
while online && outbox has pending items:
  batch = next 20 pending ops, FIFO, grouped by nothing (server handles order)
  POST /sync  { ops: [...] , client_time: <now>, cursor_before: ... }
  on 200:
     for each result: mark op done, delete from outbox,
                      upsert returned item into `events` (server-authoritative copy)
     update cursor from response
  on 409 (version conflict):
     apply server item over local copy, mark op failed-with-conflict,
     surface toast: "That entry changed on another phone — kept theirs."
  on 422:
     mark op failed permanently, surface banner with the reason
  on network error / 5xx:
     attempts += 1; next_retry_at = now + min(2^attempts, 60)s
     break (do not spin)
```

Concurrency: one drain at a time, guarded by a `navigator.locks.request('outbox')`
lock so two tabs or a resumed PWA can't double-send. `inflight` state exists
purely for crash recovery — on boot, any `inflight` op reverts to `pending`, which
is safe precisely because server-side writes are idempotent.

### Head-of-line rule

Items are drained in FIFO order globally. A permanently failed item is *parked*
(removed from the active queue, shown in a "1 item didn't sync" sheet) so it
doesn't block everything else. The one exception: an op targeting an id with an
earlier *pending* op keeps relative order, so create→update→delete on the same
event can't arrive out of order.

---

## 2. Batch endpoint

### `POST /sync`

Request:

```json
{
  "client_sent_at": 1762699023123,
  "ops": [
    {
      "op_id": "018f...-uuidv7",
      "kind": "event.create",
      "child_id": "ch_01H...",
      "body": { "event_id": "...", "type": "diaper", "occurred_at": 1762699000000,
                "payload": { "kind": "wet" } }
    },
    {
      "op_id": "...",
      "kind": "event.update",
      "child_id": "ch_01H...",
      "body": { "event_id": "...", "occurred_at": 1762698100000,
                "patch": { "payload": { "kind": "mixed" } },
                "base_version": 3 }
    },
    {
      "op_id": "...",
      "kind": "event.delete",
      "child_id": "ch_01H...",
      "body": { "event_id": "...", "occurred_at": 1762698100000 }
    }
  ]
}
```

Response (always 200 if the *batch* was accepted, even if individual ops failed):

```json
{
  "results": [
    { "op_id": "...", "status": "ok", "item": { ...server-authoritative item... } },
    { "op_id": "...", "status": "ok_replay" },
    { "op_id": "...", "status": "conflict", "item": { ...current server item... } },
    { "op_id": "...", "status": "invalid", "error": "payload.amount_ml must be <= 2000" }
  ],
  "cursor": { "updated_at": 1762699024000, "event_id": "018f..." },
  "server_time": 1762699025000
}
```

Per-op status, never per-batch failure, so one bad record doesn't poison a queue.
The only 4xx that rejects the whole batch is auth/scope (401/403) or a malformed
envelope.

### Clock skew

Every response carries `server_time`. The client keeps
`skew_ms = server_time - client_received_at` (median of the last 5 samples) and
sends `occurred_at` **already corrected** at write time. The server still clamps
to `[now-72h, now+5m]` as a backstop. Two phones with wrong clocks converge; a
phone stuck in 2031 gets a visible validation error instead of a permanent
future entry.

---

## 3. Read sync

### `GET /sync?child_id=<cid>&since=<cursor>&limit=200`

```json
{
  "items": [ { "event_id": "...", "entity": "event", "deleted_at": null, ... } ],
  "cursor": { "updated_at": 1762699024000, "event_id": "..." },
  "has_more": false,
  "server_time": 1762699025000
}
```

Client loop: apply items → update cursor → repeat while `has_more`. Applies are
`upsert` keyed by `event_id`, with tombstoned items `deleted_at != null` causing a
local delete (not a hard delete from the mirror — keep the tombstone so a later
duplicate create can't resurrect it; prune tombstones older than 30 days).

### `GET /children` → list, cached 60s by SW, always refreshes on focus

### Freshness policy

| Trigger | Action |
| --- | --- |
| App foregrounds | full read sync (all children) |
| Online event | `ws.onopen` → read sync |
| Every 5 min while foregrounded | read sync |
| After outbox drain | read sync |

That's deliberately chatty-but-tiny. The payload is a partition scan page; it's
cheaper than being wrong.

---

## 4. Live push

Action Cable, channel `HouseholdChannel`, stream `household:<hid>`.

Server broadcasts after any successful write (and after any outbox batch):

```json
{ "kind": "sync.delta", "items": [ ...same envelope as /sync items... ],
  "origin_session": "sess_abc", "server_time": 1762699025000 }
```

Client:

- ignores messages whose `origin_session` is its own session (it already applied
  the optimistic write and the server-confirmed copy)
- otherwise runs the same `applyChanges()` reducer as read sync
- a delta never advances the local cursor — cursors only advance from HTTP
  responses, so a dropped socket can't create a hole in the client's knowledge.
  Deltas are an accelerant; `/sync` is the truth.

Reconnection: exponential backoff 1s→30s with jitter, `online`/`visibilitychange`
events force an immediate retry, and every successful reconnect triggers a full
read sync before trusting the socket.

### Why not Turbo Streams over the socket

Turbo Streams over WS would give us `append`/`replace` DOM actions, but our live
messages must survive out-of-order arrival, duplication, and gaps — that's a
reducer, not a DOM patch. Also, a Turbo Stream over the wire can't express
"this item was deleted while you were asleep" without a round trip. One reducer,
two transports (HTTP + WS), zero divergence.

Turbo Streams *are* used for server-rendered form responses (`POST /events`
returning a `turbo_stream`), which is orthogonal: that's an online-only path.

---

## 5. Conflict rules

Last-writer-wins **per field group**, resolved server-side at write time.

| Field group | Rule |
| --- | --- |
| `payload.*` | whole-map replace on update (no per-key merge); client sends full patch |
| `occurred_at` | immutable after create (moves the sort key — we don't allow it) |
| `note` | LWW |
| `started_at` / `ended_at` / `duration_s` | LWW as a unit (a timer is one fact) |
| `deleted_at` | tombstone wins over everything; deletes are final in v1 |

Optimistic concurrency: updates carry `base_version`. Server compares to the
stored `version`; mismatch → `conflict` + current item, client adopts the server
copy. This is how "my wife fixed the amount while I was editing it offline"
resolves without silent loss.

Deletion is *not* resurrect-able in v1. If you meant to un-delete, re-add it.
(Undo within 5s is client-side only — the delete op hasn't drained yet, so undo
just cancels the queued op.)

---

## 6. Local retention

- Events for the **last 7 days** per child in IndexedDB (configurable in
  settings: 3/7/14/30). Older days are fetched on demand and cached on view
  (with an LRU cap of ~2000 events total).
- Tombstones: 30 days, then pruned.
- Outbox: unbounded but expected to be tiny; a warning banner appears above 100
  pending items.
- `navigator.storage.persist()` requested on first successful write — iOS gives
  IndexedDB a generous quota when granted and can evict otherwise.

### Eviction reality on iOS

Safari can evict site data after ~7 days of non-use for non-installed sites.
Installed home-screen PWAs are exempt in practice, but there's no guarantee.
Consequence: the app must treat IndexedDB as a *cache*, never as the sole copy of
anything the user cares about. The outbox is the one place that matters — if a
queued write is evicted unsynced, it's gone. Mitigation: surface a visible
"2 items waiting to sync" banner, and drain aggressively on any connectivity.
Local backups are not in scope for v1; noted as a risk.

---

## 7. Failure UX

| Situation | UI |
| --- | --- |
| Offline | amber top bar, "Offline — logging still works" |
| Queued writes | dot on tile + count in bar |
| Reconnecting | bar shows "Syncing 3…" |
| Permanent failure | red bar, item label, "Fix" (opens editor) + "Discard" |
| Conflict adopted | toast "Entry updated from another device" |
| Auth expired | modal, "Sign in again", queue is preserved |

Nothing blocks the user from continuing to log while any of these are showing.
That's the whole point.

---

## 8. Test plan

- Unit: reducer with out-of-order, duplicated, and gapped messages.
- Integration: Playwright, offline mode → 5 writes → online → assert one write
  per op reaching DDB Local and identical local/server state.
- Idempotency: replay the same batch three times, assert item count unchanged
  and `version` incremented at most once per accepted op.
- Cron-free: no scheduled jobs to test, by design.
