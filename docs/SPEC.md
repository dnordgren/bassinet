# bassinet — Product & Technical Spec

- **Status:** Draft 1 (root commit)
- **Author:** Doom, for Derek
- **Date:** 2026-11-09

---

## 1. What we're building

A two-parent (and later, caregiver) baby tracker. Log diaper changes, feedings,
sleep, and pumping in one tap from an iPhone home-screen app. Both parents see
each other's entries within a second when online. When offline, entries queue
locally and flush when the connection returns. Recent history lives on the
device so the app is instant and usable in a basement with no signal.

**Huckleberry is the reference, not the target.** We take the core logging loop
and the multi-caregiver sync. We are explicitly **not** building:

- SweetSpot / wake-window prediction
- Schedule creator, expert plans
- Insights, reports, charts (v2 maybe)
- AI logging, widgets, Live Activities, Apple Watch
- Any paid tier, billing, or subscription

The whole value is: *Huckleberry's free tier, but ours, and usable offline.*

### Explicit non-goals (v1)

| Not doing | Why |
| --- | --- |
| Native iOS/Android app | PWA is the requirement |
| Real-time video/audio | Out of scope |
| Growth charts, medicine reminders | v2 |
| Unit-conversion polish (ml/oz) | Store canonical, display per-profile preference |
| Push notifications | iOS PWA pushes are supported but flaky; v2 (see §11) |

---

## 2. Personas and flows

### P1 — Derek (primary, iPhone, Safari)

1. Opens the app in Safari, taps "Continue with Google". Once.
2. Adds site to Home Screen when prompted (post-login, see `docs/auth.md`).
3. Creates a child: name, birth date, optional photo.
4. Taps **Diaper → Wet** from the home screen. Entry appears instantly.
5. Loses signal in the nursery. Taps **Feed → Bottle → 120ml**. Entry appears
   instantly with a small "queued" dot. Signal returns mid-feed; the dot clears.

### P2 — Wife (secondary, iPhone, Safari)

1. Gets an invite link from Derek (SMS/whatever).
2. Opens it → Google sign-in → auto-joins Derek's household with role `caregiver`.
3. Sees the same child, same event feed, live.
4. Taps **Feed → Nursing → Left → start**. Derek's phone buzzes the feed within ~1s.

### P3 — Future: grandparent / night nurse

Same as P2, but limited to logging only — cannot invite, cannot remove events,
cannot delete the child. Role enforced server-side (see §6.3).

---

## 3. Feature scope — v1

### 3.1 Auth & household

- Google OAuth 2.0 (authorization-code + PKCE), one provider only.
- Session = encrypted, signed cookie (Rails `cookies.encrypted`), 90-day sliding.
- **Household** is the tenancy boundary. One household per account at signup;
  a user can belong to more than one household later, but the UI picks one.
- Roles: `owner` (creator) and `caregiver`.
- Invite flow: owner generates single-use token (7-day expiry, 8 chars, hashed at
  rest) → shareable link `/join/:token`.

### 3.2 Children

- Create / rename / archive. Archive rather than delete (soft).
- Fields: `name`, `birth_date`, `photo` (optional), `timezone` (default from
  device), `units` (metric/imperial preference), `archived_at`.
- Max 10 children per household, 4 members per household (sanity caps).

### 3.3 Event logging (the core)

Six event types. Every event shares a common envelope. Type-specific payload is
a free-form (but schema-validated) map.

| Type | Fields |
| --- | --- |
| `diaper` | `kind` ∈ {wet, dirty, mixed, dry}, `notes` |
| `feed` | `method` ∈ {bottle, nursing, solids, tube}, `amount_ml`, `side` ∈ {left, right, both}, `duration_s`, `foods[]`, `notes` |
| `sleep` | `started_at`, `ended_at`, `quality`, `location`, `notes` |
| `pump` | `amount_ml_left`, `amount_ml_right`, `duration_s`, `notes` |
| `growth` | `weight_g`, `height_mm`, `head_circumference_mm` |
| `note` | `body` |

**Timers.** `sleep`, `feed` (nursing), and `pump` are start/stop. A running
timer is a *client-side* concept plus a durable `started_at` on the server. The
server never runs a clock for the user; if the app is killed mid-timer, the
client restores from the last committed `started_at` and offers "still going?"
We store `duration_s` when the timer stops.

**Interaction model.**

- Home screen is a grid of big one-tap tiles: Diaper (wet/dirty), Feed (bottle
  amount preset), Sleep (start/stop), Pump, More.
- Every tap is optimistic: local write → UI update → background sync.
- Long-press / edit any entry to change time or details.
- Undo toast for 5 seconds after create/delete.

### 3.4 Live feed

- Household-scoped Turbo Stream / Action Cable channel: `household:<id>`.
- Broadcast a compact event summary on create, update, delete.
- Client applies stream messages through the same reducer as HTTP sync, so live
  updates and backlogged sync share one code path (see `docs/sync-protocol.md`).

### 3.5 Days & history

- Rolling feed of the day, grouped by type with a filter bar.
- Date navigator (yesterday / today) with local cache so previous days are
  viewable offline.
- "Last event" chips at the top: last feed, last diaper, last sleep, with
  relative times that tick locally.

### 3.6 Offline

- Service worker (Workbox-free, hand-rolled; see `docs/pwa-ios.md`).
- App shell precached; GET responses network-first with cache fallback.
- Writes go to an IndexedDB outbox, replay in order on reconnect.
- Recent N days (default 7, configurable) of events mirrored to IndexedDB.

### 3.7 PWA install

- `manifest.json`: `display: standalone`, `theme_color`, maskable icon,
  `start_url: /`.
- Install prompt: iOS shows nothing, so we render our own "Add to Home Screen"
  instructions banner after first successful login.
- Splash screens: generate iOS `apple-touch-startup-image` set at build time.

---

## 4. Architecture

```
┌───────────────────────── iPhone (Safari / standalone PWA) ─────────────────────────┐
│  Turbo 8 (page visits, streams)  │  Stimulus (log tiles, timers, filters)          │
│  IndexedDB: outbox + event cache │  Service Worker: shell + GET cache              │
└───────────────┬──────────────────────────────────────┬─────────────────────────────┘
                │ HTTPS (fetch, Turbo, EventSource)    │ WebSocket (Action Cable)
┌───────────────▼──────────────────────────────────────▼─────────────────────────────┐
│                            Rails 8.1 (Puma, 1 node)                                │
│  SessionsController  │  EventsController  │  SyncController  │  Cable::Connection   │
│  HouseholdChannel    │  Idempotency       │  Cursor paging   │  Presence (later)    │
└───────────────┬──────────────────────────────────────┬─────────────────────────────┘
                │ AWS SDK v3 (single-table)            │ Solid Cable (SQLite file)
┌───────────────▼──────────────────────┐   ┌───────────▼─────────────────────────────┐
│            DynamoDB                  │   │  SQLite under storage/ — Action Cable   │
│  bassinet table + GSI1/GSI2          │   │  only. No Redis, no extra container.    │
└──────────────────────────────────────┘   └─────────────────────────────────────────┘
```

### 4.1 Why DynamoDB

Derek asked for it. It's a good fit for the access pattern we actually need —
all reads are "give me events for child X in time range Y" and "give me the
household's children" — both are single-partition or single-GSI queries. There's
no join anywhere in the domain. Append-heavy writes with a monotonic sort key are
Dynamo's happy path.

The cost is: **no AR models for domain data.** Everything is hand-written
repository classes over `Aws::DynamoDB::Client`. See `docs/data-model.md`.

### 4.2 What "no ActiveRecord" actually means here

`rails new` **keeps** ActiveRecord, but only as plumbing. Domain data never
touches it.

- **No AR models, no domain migrations.** `app/models/*.rb` are plain POROs
  backed by hand-written repositories. Nothing in `app/models` inherits from
  `ApplicationRecord`.
- **ActiveRecord exists so Rails' own machinery works**: Solid Cable for Action
  Cable (SQLite files under `storage/`), Solid Queue if v2 wants background jobs,
  Solid Cache for fragment caching. All file-backed. No Redis container.
- **No Devise** — it assumes AR-backed users. Auth is hand-rolled, and it's small
  (`docs/auth.md`).

The alternative — `--skip-active-record` — works, but then Action Cable needs
Redis, which is a whole container to operate for a two-parent app. Not worth it.
If ActiveRecord's presence ever confuses someone, this section is the answer.

Why Solid Cable is fine at this scale: it stores broadcasts in a SQLite table
and polls. For two clients on one box, polling cost is noise.

### 4.3 Request paths

Three ways data moves:

1. **Turbo Drive visit** — full HTML page, cached by SW, mutated by Turbo Streams.
2. **Turbo Stream over HTTP** — form/fetch submissions that render `turbo-stream`
   responses (event create from an online client could use this).
3. **JSON sync API** — what the outbox replays when reconnecting. Same handler.

Live updates ride a **separate Action Cable subscription**, not Turbo Streams
over WebSocket, because we need our own reducer semantics for out-of-order and
duplicate messages. (Turbo Streams over WS would work, but then the reducer lives
in two places.)

---

## 5. Data model (summary)

Full detail in `docs/data-model.md`. Single table `bassinet`.

```
PK                         SK                          Entity
─────────────────────────────────────────────────────────────────────
HOUSEHOLD#<hid>            META                        household
HOUSEHOLD#<hid>            MEMBER#<uid>                member
HOUSEHOLD#<hid>            INVITE#<tokenHash>          invite
CHILD#<cid>                META                        child
CHILD#<cid>                EVENT#<ts>#<eid>            event
GSI1: CHILD#<cid>          EVENT#<ts>#<eid>            (same, time-ordered)
GSI2: USER#<uid>           HOUSEHOLD#<hid>             membership lookup
```

Key decisions:

- Event `SK` is `EVENT#<epoch_ms padded>#<event_id>` — sort key ordering *is*
  chronological ordering. Cursor sync = "SK > last_seen".
- Everything is soft-deleted (`deleted_at` attribute) so outbox deletes are
  idempotent and sync stays monotonic.
- Every item carries `updated_at` (server-authoritative) for cursor-based delta
  sync. `id` is a client-generated UUIDv7 so an offline create has a stable
  identity before the server ever sees it.

---

## 6. Auth design

Full detail in `docs/auth.md`.

### 6.1 Provider

Google only. OAuth 2.0 authorization code + PKCE, `openid email profile`.
No client secret in the browser — the secret lives on the Rails box.

### 6.2 Session

- Server sets `bassinet_session` — encrypted cookie, `HttpOnly`, `Secure`,
  `SameSite=Lax`, 90 days, sliding refresh on use.
- We do *not* use Google tokens after login. We call `userinfo` once, store
  `sub`, email, name, avatar URL. No refresh tokens, no Google API access.

### 6.3 Authorization

Every controller action resolves `current_household` from the session and
`assert_member!(household, child)` before touching DynamoDB keys. Because
DynamoDB has no row-level security, the repository layer takes an explicit
`household_id` scope and *never* queries by `child_id` alone. One helper,
`scoped_child!(id)`, is the only way to get a child model.

### 6.4 The iOS standalone problem — the important bit

**Google blocks OAuth inside an installed iOS PWA** (`disallowed_useragent`), and
even if it didn't, cookies are *copied once* into the home-screen app at install
time and then isolated. Signing in in Safari does not log the installed PWA in.

Our answer is a **handoff code**:

1. Installed PWA has no session → shows "Sign in with Google (opens Safari)".
2. PWA POSTs `/auth/handoff` → server makes `{code, poll_id}`, renders a
   "waiting to be signed in" screen that polls `/auth/handoff/:poll_id`.
3. User taps through to Safari with `?handoff=<code>`.
4. Safari completes Google OAuth, server marks the handoff code claimed and sets
   the Safari session.
5. Safari shows "You're signed in — go back to the app." PWA's poll returns a
   one-time session token; PWA posts it to `/auth/session` and gets its own cookie.

Fallback path: **none in v1.** Magic link is deliberately deferred (see §12.5 of
`docs/SPEC.md`) so we don't take an email-provider dependency before the app
exists. If the handoff turns out to be fragile in real use, adding it later is
a small, self-contained change — `docs/auth.md` §3 keeps the design on file.

This is the single most likely thing to break in real use. It gets its own
integration test target and a manual device checklist.

---

## 7. Offline & sync

Full detail in `docs/sync-protocol.md`. The shape:

- **Read:** SW serves the shell + last-synced pages from Cache Storage; event
  lists come from IndexedDB.
- **Write:** every mutation gets a client UUIDv7 → pushed to an outbox in
  IndexedDB → optimistic UI → HTTP `POST /sync` in batches.
- **Sync:** `GET /sync?child_id=…&since=<updated_at>&limit=200` → server returns
  changes ordered by `updated_at`, plus a `next_since` cursor. Client applies,
  upserts IndexedDB, repeats until `has_more=false`.
- **Conflicts:** last-writer-wins per field group, server clock wins ties, all
  mutations are idempotent by `event_id` (+ `Idempotency-Key` header). Deletes
  are tombstones, never hard deletes, so replay can't resurrect anything.
- **Live:** Action Cable `household:<id>` pushes the same change envelope as
  `/sync`, so both paths converge on one reducer.

**Queue drain policy:** FIFO with per-item retry, exponential backoff
(1s→2s→4s… cap 60s), 3 attempts before parking an item as "failed" with a
visible banner. Failed items never block later items unless they're for the same
id (then head-of-line preserved).

---

## 8. UI / UX

Mobile-first, one column, thumb-reachable. Turbo 8 + Stimulus, no React, no
build step beyond importmaps.

### 8.1 Screens

| Route | Screen |
| --- | --- |
| `/` | Today: last-event chips, action grid, today's feed |
| `/c/:child_id/day/:date` | Day view with filters |
| `/c/:child_id/new` | Add child |
| `/c/:child_id/settings` | Child settings, members, invite |
| `/household/members` | Manage caregivers |
| `/settings` | Units, offline window, sign out, about |
| `/join/:token` | Accept invite |
| `/auth/*` | Sign in, handoff |

### 8.2 Design language

- Generous tap targets (min 56×56pt), one accent color, big time-since labels.
- Dark mode via `prefers-color-scheme`; no theme switcher in v1.
- Motion: 150ms, opt out under `prefers-reduced-motion`.
- Palette: warm cream background, deep berry accent (`#7A2A45`), soft shadows.
  Deliberately *not* Huckleberry's green.

### 8.3 Empty / error states

- No child yet → single "Add your first child" card.
- Offline → thin amber bar "Offline — logging still works", persisted in layout.
- Queued writes → a dot on the tile plus a count in the offline bar.
- Sync failure → red bar with "Retry" and the failing item's label.

---

## 9. Infra & deploy

- **Host:** Derek's small home box, Docker. Reachable via **Cloudflare Tunnel**
  (see §9.1) — no port forwarding, no dynamic DNS, TLS at the edge.
- **App server:** Puma under Kamal 2, single `web` role. No job host: no queue.
- **DynamoDB:** real AWS, on-demand capacity, one table, PITR on, deletion
  protection on. Region `us-east-1`.
- **SQLite:** four files under `storage/` — primary, cache, queue, cable. Written
  by Rails, not by us. Persisted in the Docker volume. No Redis, no extra service.
- **Backups:** DynamoDB PITR + weekly export to S3. The box itself holds only
  code and secrets, so it's disposable — losing it costs a redeploy, not data.
- **Secrets:** Kamal secrets file locally; Google client secret and AWS keys
  live there. Never in git.

Dev needs Ruby 3.4 (via `mise`), plus a JRE or Docker for DynamoDB Local. No Redis.

`rails new` flags: `--skip-active-storage --skip-action-mailbox --skip-action-text`.
**Do not** pass `--skip-active-record` — ActiveRecord stays for the Solid gems.

### 9.1 Home hosting consequences

Running at home changes the risk profile, so it changes the design:

| Concern | Answer |
| --- | --- |
| Dynamic residential IP | Cloudflare Tunnel — outbound-only connection, no inbound ports |
| Router exposure | None. The box never listens publicly. |
| Box goes down / reboots | The PWA keeps logging offline and drains on reconnect. This is why offline is phase 5 and not phase 9. |
| ISP outage | Same answer. Both phones queue locally. |
| Disk dies | Data is in DynamoDB. Rebuild the box, redeploy, done. |
| Power blip | UPS if Derek has one; otherwise Docker restart policies + a healthcheck. |

The honest expectation: this will be unreachable sometimes, and that is fine,
because the app was designed to not care.

---

## 10. Security & privacy

- Households are hard-isolated at the repository layer (§6.3).
- Invite tokens: 8 chars from a 32-char alphabet ≈ 40 bits, single use, 7-day
  expiry, stored hashed, rate-limited on redemption (5 attempts / 15 min / IP).
- All writes require session; all reads scoped by household.
- Event payloads validated against a per-type JSON schema before persistence.
- CSRF: Rails default `protect_from_forgery`; sync API uses a
  `X-CSRF-Token` from the meta tag.
- Rate limits: 300 requests/min/session on sync, 30/min on invite creation.
- Logs scrub `email` to `sub` hash. No event bodies in logs.
- Baby data is sensitive by default: no analytics, no third-party scripts, no
  CDN fonts. Self-hosted only. (`web_push` in v2 would be the one exception.)

---

## 11. Roadmap

### Phase 0 — spec (this commit)

### Phase 1 — skeleton (1 session)
- `rails new` with skips, Kamal init, DynamoDB local via docker-compose
- Table creation script (`bin/ddb-create`) with GSI1/GSI2
- Repository base class + `Child`/`Event` repos with tests against DDB Local
- Google OAuth + iOS handoff code (no magic link — see §12.5)

### Phase 2 — core logging (1–2 sessions)
- Home screen action grid, event create/edit/delete via Turbo Frames
- Day view, last-event chips, undo toast
- Server-side validation + idempotency

### Phase 3 — household (1 session)
- Invites, roles, members screen, `saved`-only access checks
- Event authorship on the feed

### Phase 4 — live (1 session)
- Action Cable channel, broadcast hooks, reconnection backoff
- Presence (who's online) if cheap

### Phase 5 — offline (1–2 sessions)
- Service worker + app shell, Cache Storage strategy
- IndexedDB outbox + cache, sync endpoint, reducer
- Conflict/error UI

### Phase 6 — PWA polish
- Manifest, icons, splash, install banner, safe-area insets
- Lighthouse pass, iOS device checklist

### Phase 7 (maybe)
- Growth charts, medicine logging, reminders, web push

Each phase ends with a demo-able build. No phase merges itself; PR per phase.

---

## 12. Decisions (formerly open questions)

1. **Google Cloud project** — Derek has one; console-click steps are written out
   in `docs/setup-google-oauth.md`.
2. **AWS account** — existing account. Region `us-east-1` unless it argues.
3. **Domain** — `bassinet.nordg.ren`.
4. **Host** — self-hosted on a small home box. Consequence: home uplink is the
   availability ceiling, so the offline-first design isn't a nicety, it's the
   product. Also: no static IP needed — see §9.1 on Cloudflare Tunnel.
5. **Magic link** — **skipped for v1.** No email provider dependency. Google only.
   The design stays documented in `docs/auth.md` §3 as the escape hatch if iOS
   changes something; adding it later is ~40 lines plus one API key.
6. **Timezone** — store UTC epoch ms, render in the child's timezone. Confirmed.

### 9.1 Self-hosting at home (added)

Since the box is at home behind a residential connection:

- Public entry via **Cloudflare Tunnel** (no port forwarding, no dynamic DNS, TLS
  terminated at the edge, `cloudflared` runs next to Puma). Free tier is fine.
- Consequence: the app is reachable even when the house IP changes, and we don't
  expose ports on the home router — good for a box holding baby data.
- Backups matter more than usual: a home disk dying is a realistic failure, not
  a hypothetical. DynamoDB PITR covers the data; the box itself only holds
  code and secrets, so it's disposable.
- Uptime expectation: it will be down sometimes. The PWA keeps logging anyway.

---

## 13. Names considered

`bassinet` (chosen — Derek's pick). Runners-up: `hootenanny`, `chuckleberry`,
`babygoats`, `diaperindex`, `the-other-berry`.
