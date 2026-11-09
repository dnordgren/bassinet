# iOS PWA constraints

Everything here is a thing that will bite us. Written down so future-us doesn't
call it a bug.

---

## 1. What we get, what we don't

| Capability | iOS Safari | Notes |
| --- | --- | --- |
| Service worker | ✅ 11.3+ | Works, but no background sync API |
| IndexedDB | ✅ | Subject to eviction (§3) |
| `navigator.storage.persist()` | ⚠️ | Promptless grant/deny; not surfaced |
| WebSocket / EventSource | ✅ | Fine while foregrounded / briefly after |
| Push notifications | ⚠️ 16.4+ | Only for **installed** apps, requires user gesture, flaky in the wild |
| Background sync (`SyncManager`) | ❌ | Never. Not even 18.x |
| Periodic background sync | ❌ | ditto |
| `beforeinstallprompt` | ❌ | We render our own instructions |
| Web Share Target | ✅ 17+ | Not needed v1 |
| Badging API | ✅ 16.4+ | Not needed v1 |
| Bluetooth / Contact Picker / etc | ❌/partial | Irrelevant |

**Consequence:** there is no "sync in the background while the phone is in my
pocket." Syncing happens when the app is open. The outbox drains on foreground,
on `online`, and on socket reconnect. That's it. Design the UX so this is
invisible (it is, for a tracker).

---

## 2. Safe areas and viewport

- `viewport-fit=cover` + `env(safe-area-inset-*)` padding on the top bar and
  bottom action bar. Without it, the home indicator eats our last row of tiles.
- No `position: fixed` footers without accounting for the keyboard; iOS resizes
  the visual viewport, not the layout viewport. Use `visualViewport` events for
  the note field.
- `-webkit-tap-highlight-color: transparent` and explicit `:active` states,
  otherwise every tap flashes gray.

## 3. Storage eviction

- Non-installed sites: Safari may evict site data after ~7 days of no
  interaction. Installed home-screen apps are exempt *in practice*, not by
  contract.
- `navigator.storage.persist()` is the best we can do. Call it on first write.
- Therefore: **IndexedDB is a cache, never the only copy** of anything durable —
  except the outbox, which is inherently at risk. Mitigation is UX (visible
  pending count) rather than technology.

## 4. Manual device checklist

Run on a real iPhone before any release. Simulator UAs lie about standalone.

- [ ] Fresh install: sign in in **Safari**, install from share sheet, opens
      signed in (cookie seed path).
- [ ] Fresh install: install **first**, sign in from standalone → handoff flow
      completes, session lands in the app.
- [ ] Handoff: quit Safari mid-flow, come back, poll still resolves.
- [ ] Airplane mode: log 5 events, kill the app, reopen, still offline, events
      present, queue intact.
- [ ] Airplane off: queue drains, dots clear, second phone shows the events.
- [ ] Two phones online: create event on A, appears on B in <2s.
- [ ] Rotate to landscape: layout doesn't explode.
- [ ] Dynamic Type at max: labels don't clip tiles.
- [ ] Dark mode: contrast holds.
- [ ] Screen lock 30 min with the app backgrounded, unlock, resume → socket
      reconnects and read sync fires.
- [ ] Delete an event on A while B is offline with a queued edit to it → B gets
      a conflict toast, adopts server state, doesn't resurrect.

## 5. Manifest

```json
{
  "name": "chuckleberry",
  "short_name": "chuckleberry",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "background_color": "#FDF8F3",
  "theme_color": "#7A2A45",
  "icons": [
    { "src": "/icons/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icons/icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "/icons/icon-maskable-512.png", "sizes": "512x512",
      "type": "image/png", "purpose": "maskable" }
  ]
}
```

Plus iOS-specific head tags: `apple-mobile-web-app-capable`,
`apple-mobile-web-app-status-bar-style: default`,
`apple-mobile-web-app-title: chuckleberry`, and the
`apple-touch-startup-image` set (one per device size, generated at build time
from a template — `bin/gen-splash`).

## 6. Service worker strategy

Hand-rolled, ~150 lines, no Workbox (we don't want a Node build step):

| Request | Strategy |
| --- | --- |
| `/` and app shell assets (`/assets/*`, icons) | precache on install, cache-first |
| Turbo Drive page visits (HTML) | network-first, 3s timeout → cache → offline shell |
| `/sync`, `/children`, `/events*` (JSON + turbo-stream) | network-only (the app has its own IndexedDB layer; caching these would double-truth) |
| Everything else same-origin GET | stale-while-revalidate |

`skipWaiting` + `clients.claim` on install so a deploy takes effect on next
launch. Cache version = build SHA; old caches deleted on activate.

**Never cache** `/auth/*`, `/sync` POSTs, or anything with `Set-Cookie`.
