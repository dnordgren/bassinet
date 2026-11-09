# Auth: Google sign-in + iOS handoff

The requirement is "log in via Google account on Safari on iPhone." The naive
implementation fails, and it fails *only on the installed app*, which is the
worst place to discover it. This doc is the workaround, written down before code
exists so it doesn't get "simplified" away later.

---

## 1. Why the naive thing breaks

Two independent iOS problems compound:

**Problem 1 — Google blocks the standalone user agent.**
An installed home-screen web app on iOS has a user agent without the `Safari/`
token, and navigations that leave the app's scope open in an in-app Safari view.
Google's OAuth authorize endpoint returns **403 `disallowed_useragent`** for that
class of client. This is Google policy against embedded webviews, not something
page JS can patch. Changing `navigator.userAgent` from JavaScript does not help
(and is against Google's terms).

**Problem 2 — cookies don't flow into the installed app.**
Home-screen web apps get their own storage container. Since iOS 17.2 the
container is seeded *once*, at install time, from Safari's cookies. After that
they're isolated. So: signing in in Safari does not sign in an already-installed
PWA, and signing in inside the PWA doesn't work because of Problem 1.

**Therefore:** you cannot complete Google OAuth inside the installed app. The
only way in is a *handoff* — start in the app, finish in Safari, get a credential
back into the app.

---

## 2. The handoff flow

```
 INSTALLED PWA                     SAFARI                        RAILS
 ─────────────                     ──────                        ─────
 tap "Sign in with Google"
 POST /auth/handoff ───────────────────────────────────────────▶ create handoff
                                  code=A7K2QX, poll_id=p_9f3...
 ◀──────────────────────────────────────────────────────────────  {code, poll_id}
 open "https://app/?handoff=A7K2QX" in Safari ──▶
                                  GET /?handoff=...
                                  "Finish signing in" ──▶ Google OAuth
                                                          (real Safari UA ✓)
                                                          ◀──── callback
                                                          code verified
                                                          handoff A7K2QX → claimed
                                                          session cookie set
                                  "Signed in! Go back to
                                   the app." 
 poll GET /auth/handoff/p_9f3... ◀──────────────────────────────  {status: claimed,
 (every 2s, 90s budget)                                            session_token: ...}
 POST /auth/session {session_token} ───────────────────────────▶ mints the PWA's
                                                                own session cookie
 redirect /  (signed in)
```

### Handoff code rules

- 6 chars, Crockford base32 alphabet (no I/L/O/U), ~30 bits — enough because it
  is *not* a bearer credential on its own.
- TTL 10 minutes, single use.
- Bound to the `poll_id` (also single-use, 128-bit). The code alone gets you
  nothing; `poll_id` alone gets you nothing. Only the pair completes.
- Stored hashed (SHA-256) in DynamoDB under
  `PK=HANDOFF#<code_hash>`, with `poll_id_hash`, `status ∈ created|claimed|consumed`,
  `user_id` once claimed, `expires_at`.
- Pollution resistance: the `POST /auth/session` step requires the
  `session_token` returned by the poll *and* the poll's own cookie — so a
  shoulder-surfed poll URL is useless in another browser. (Poll responses also
  bind to a `handoff_poll` cookie set when the poll starts.)

### Safari-side UX

`GET /?handoff=A7K2QX` on Safari:

- If already signed in → immediately mark claimed, show a big
  "Signed in — return to the app" screen with a `bassinet://` attempt (no-op
  on iOS) and a plain "Done" button. Look for the app, don't insist.
- If not signed in → a one-button page: "Continue with Google". No other UI.
  After OAuth, land on the same "return to the app" screen.
- Deliberately ugly-free but deliberately minimal. It's a hallway, not a room.

### PWA-side UX

While polling, the app shows: *"Finish signing in Safari, then come back here."*
With a "Didn't work? Use email link instead" escape hatch and a cancel. If the
poll times out (90s) the code is discarded and the user lands back on the sign-in
screen with an explanation.

### Also: the "install after login" path

If the user has *not* installed the app yet, the normal flow is simply: sign in
in Safari, **then** Add to Home Screen. The install-time cookie seed then carries
the session into the app and the handoff is never used. So the sign-in screen
detects standalone mode:

```js
const standalone =
  window.navigator.standalone === true ||
  window.matchMedia("(display-mode: standalone)").matches;
```

- `standalone === false` (Safari tab) → normal OAuth redirect, then we show the
  install banner.
- `standalone === true` → handoff flow.

**Recommendation surfaced in-app:** "Sign in first, then add to Home Screen."
That is the path that just works, and it's what we tell users in the banner.

---

## 3. Magic-link fallback — **deferred, not built in v1**

Decision (2026-11-09): ship Google-only. No email provider dependency until the
app exists and we know whether the handoff is actually fragile. This section is
kept as the design so that adding it later doesn't require re-thinking it.

When we do build it: it works regardless of platform, which is exactly why it's
the right escape hatch.

1. `POST /auth/magic` with email → look up or create user → single-use token
   (32 bytes, URL-safe), hash stored, 15-min TTL.
2. Delivery needs a mail provider (Resend / Postmark, one HTTP call, free at this
   volume, requires a verified domain). That dependency is the only reason this
   isn't in v1.
3. `GET /auth/magic/:token` → verify hash, unexpired, unconsumed → set session →
   redirect `/`. Works in Safari *and* standalone — it's a plain navigation, so
   Google's user-agent check never enters the picture.

Estimated cost when we pick it up: ~40 lines plus one API key and a DNS record.

---

## 4. Sessions

- Cookie: `bassinet_session`, Rails `cookies.encrypted` + `signed` (both), `HttpOnly`,
  `Secure`, `SameSite=Lax`, `max_age 90 days`, sliding (re-issued when older than
  30 days on an authenticated request).
- Contents: `{ uid:, hid: (active household), sess: (session uuid), iat: }`.
  Nothing sensitive, nothing Google.
- `sess` is used as the `origin_session` discriminator for Action Cable echo
  suppression and as a rate-limit key. Revocable per-device via a
  `USER#<uid> / SESSION#<sess>` item (logout-everywhere = delete all).
- 401 from `/sync` → client shows re-auth modal, **keeps the outbox**.
- Session fixation: OAuth completion always rotates `sess`.

### CSRF

Rails defaults for HTML. For `/sync` (JSON, called by fetch) we require the
`X-CSRF-Token` meta value; Action Cable's connection is authenticated by the
same cookie and channel subscriptions are checked against household membership
on `subscribed`.

---

## 5. Google Cloud setup (console clicks)

Steps for Derek, once:

1. `console.cloud.google.com` → new project `bassinet`.
2. APIs & Services → OAuth consent screen → **External**, publishing status
   *Testing*. Add yourself and your wife as test users (max 100; testing consent
   screens expire refresh tokens after 7 days — irrelevant, we don't use them).
3. Credentials → Create OAuth client ID → **Web application**.
   - Authorized redirect URIs:
     - `https://<prod-domain>/auth/google/callback`
     - `http://localhost:3000/auth/google/callback`
4. Copy client ID + secret into Kamal secrets / `.env`.
5. Scopes: `openid`, `email`, `profile` only. No verification review needed for
   those, even in testing.

**Note on "Testing" status:** the consent screen stays in testing mode
indefinitely as long as the app is only for family use. That's fine; the only
cost is a "unverified app" warning screen on first sign-in per account. If that
warning bothers anyone, publish it (still no review needed for openid/email/profile,
just a privacy policy URL and domain verification).

---

## 6. User records

```
PK = USER#<google_sub>
SK = PROFILE
entity      = "user"
sub         = "1098..."
email       = "derek@..."
email_verified = true
name        = "Derek Nordgren"
avatar_url  = "https://lh3..."
created_at, updated_at
```

Keyed by Google `sub`, not email. Email changes are a display-field update, not a
new identity. (This matters if magic link ever lands — it would authenticate
into an existing Google-created account rather than forking a second one.) Store
`email` as a lookup item too:

```
PK = EMAIL#<lowercased email>
SK = USER
entity = "email_index"
user_sub = "..."
```

First login creates: user, email index, household, member(owner). One
`TransactWriteItems`.

---

## 7. Tests

| Test | Asserts |
| --- | --- |
| `auth/google_callback_spec` | token exchange stubbed; user+household created on first login; same sub reuses account |
| `auth/handoff_spec` | code+poll pair required; single use; expiry; wrong cookie rejected; session minted matches uid |
| `auth/magic_link_spec` | *(deferred)* hash verified, single use, expiry, email→user mapping |
| `auth/scoping_spec` | every controller action rejects a child from a foreign household |
| manual device checklist | real iPhone: standalone install → handoff → logging works. Documented in `docs/pwa-ios.md` §4. |

The handoff has a clock in it, so its spec uses `travel_to` rather than sleeping.
