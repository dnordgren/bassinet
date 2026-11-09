# Google OAuth — console setup steps

For Derek, once, in `console.cloud.google.com`. Takes about 10 minutes. You'll
end up with two strings to hand me: a **client ID** and a **client secret**.

The app is `bassinet.nordg.ren`. Everything below is scoped to that.

---

## 0. Before you start

You need to be signed into the Google account that will **own** the project. It
doesn't have to be the same account you sign into the app with — the owner just
administers the project. Using your personal account is fine.

---

## 1. Create the project

1. Go to <https://console.cloud.google.com/projectcreate>
2. **Project name:** `bassinet`
3. **Project ID:** accept the generated one (something like `bassinet-482113`) or
   type `bassinet-prod` if available. The ID is permanent; the name is not.
4. **Location:** *No organization* (unless you have a Workspace org you want it
   under — either is fine).
5. **Create**, then make sure the project picker at the top of the page shows
   `bassinet`.

---

## 2. Configure the OAuth consent screen

This is the screen users see when they tap "Continue with Google".

1. Left nav → **APIs & Services** → **OAuth consent screen**
2. **Audience / User type:** **External**. (Internal would require a Workspace
   org and would restrict sign-in to that org's users.)
3. **App information:**
   - **App name:** `bassinet`
   - **User support email:** your email
   - **App logo:** skip it (uploading a logo triggers a verification review that
     you do not want)
4. **App domain:**
   - **Application home page:** `https://bassinet.nordg.ren`
   - **Application privacy policy link:** `https://bassinet.nordg.ren/privacy`
   - **Application terms of service link:** `https://bassinet.nordg.ren/terms`
   - Both pages must exist and be publicly reachable *before* you submit, or
     Google rejects the submission. We'll ship static versions of both in phase 1.
     (If you'd rather not publish them yet, leave these blank for now — testing
     mode doesn't require them.)
5. **Authorized domains:** add `nordg.ren`
6. **Developer contact information:** your email
7. **Save and continue**

### Scopes

1. **Add or remove scopes**
2. Manually add these three, checking the boxes:

   | Scope | Why |
   | --- | --- |
   | `openid` | identifies the account |
   | `.../auth/userinfo.email` | we show your email, and it's the account key |
   | `.../auth/userinfo.profile` | name + avatar for the member list |

3. **Update** → **Save and continue**

These three are **non-sensitive** scopes. That's the whole point: they need no
Google review, no security assessment, no CASA audit. Anything beyond them
(Calendar, Drive, Gmail) would trigger a multi-week verification process. Don't
add anything else.

### Test users

1. **Audience** tab → **Test users** → **Add users**
2. Add:
   - your Google address
   - your wife's Google address
3. **Save**

While the app is in **Testing** status, only these accounts can sign in. There's
a hard cap of 100 test users, which is irrelevant here.

> **Known wrinkle:** apps in Testing status show an "unverified app" interstitial
> on first sign-in ("Google hasn't verified this app" → *Advanced* → *Go to
> bassinet*). It's one extra tap, once per account. That's the price of not
> publishing. If it annoys you, see §6 — publishing is free and doesn't require
> review for these scopes, it just requires the privacy policy and terms pages.

---

## 3. Create the OAuth client

1. Left nav → **APIs & Services** → **Credentials**
2. **+ Create credentials** → **OAuth client ID**
3. **Application type:** **Web application** ← important. Not "iOS", not
   "Desktop". We're a server-side web app doing the code exchange; the "iOS"
   client type is for native apps using the iOS SDK, which we're not.
4. **Name:** `bassinet web`
5. **Authorized JavaScript origins** — leave **empty**. We don't use
   `google.accounts.id`, so no origin allowlist is needed.
6. **Authorized redirect URIs** — add exactly these two:

   ```
   https://bassinet.nordg.ren/auth/google/callback
   http://localhost:3000/auth/google/callback
   ```

   Rules Google enforces that will bite you:
   - Must be an exact match — scheme, host, port, path. No trailing slash, no
     wildcards, no query string.
   - `http://` only allowed for `localhost` / `127.0.0.1`.
   - Adding a redirect URI is instant; **removing** one and re-adding the same
     value can take a few minutes to propagate.

7. **Create**
8. A dialog shows the **Client ID** and **Client secret**. Copy both now — the
   secret is viewable later, but it's easier to just take it.

---

## 4. Hand me the credentials

Put them in a file, never in chat:

```bash
cat > ~/.config/bassinet/oauth.env <<'EOF'
GOOGLE_CLIENT_ID=...apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-...
EOF
chmod 600 ~/.config/bassinet/oauth.env
```

Then tell me it's there. I'll wire it into Rails credentials / the Kamal secrets
file at deploy time. The secret never goes in git, never into a doc, never into
a log line.

The client ID is not secret — it appears in every OAuth redirect URL — but it
lives in the same file for convenience.

---

## 5. Verify before we build

Two checks you can do in 30 seconds each, so we don't discover a typo mid-deploy:

**a) Does the client exist and have the right redirect?**

```bash
# Nothing secret here; this just confirms the URI is registered.
# (Run after I've created the app; this command needs gcloud auth.)
gcloud alpha iap oauth-clients list --project=bassinet 2>/dev/null || true
```

Skip it if `gcloud` isn't set up — the redirect URI is the one thing that fails
loudly at first sign-in anyway.

**b) Do you have the right project selected?** The project picker in the console
header should read `bassinet` before you close the tab. Mistakes here are the
most common cause of "I created the client but the app says invalid_client".

---

## 6. Optional: publish (removes the "unverified app" warning)

Only worth doing if the interstitial bothers you. Requirements:

1. `https://bassinet.nordg.ren/privacy` and `/terms` live and reachable.
2. **OAuth consent screen** → **Publish app**.
3. For `openid`/`email`/`profile` only, no review is triggered — the app goes
   live within minutes and the warning screen goes away for everyone.

The tradeoff: once published, *anyone* with a Google account can complete the
sign-in flow. They'd land in a fresh empty household of their own, since
household membership requires an invite, so it's not an exposure — just noise.
For a family app, staying in Testing is the safer default.

---

## 7. What I need from you, in order

- [ ] Project created, project picker shows `bassinet`
- [ ] Consent screen configured, scopes = `openid`, `email`, `profile`
- [ ] Test users added (you + wife)
- [ ] Web application OAuth client created
- [ ] Redirect URIs: `https://bassinet.nordg.ren/auth/google/callback` and
      `http://localhost:3000/auth/google/callback`
- [ ] Client ID + secret written to `~/.config/bassinet/oauth.env` (mode 600)
- [ ] You've told me the file exists

Then I can finish phase 1 and we can do a real sign-in test on a real phone.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Error 400: redirect_uri_mismatch` | The URI in the code doesn't exactly match the console. Diff them character by character — trailing slashes and `http` vs `https` are the usual culprits. |
| `Error 403: access_denied` | Your Google account isn't in the Test users list. |
| `Error 403: disallowed_useragent` | This is the iOS standalone problem, not a config problem. See `docs/auth.md` §1. |
| `invalid_client` | Wrong project selected in the console, or you copied a client ID from a different client. |
| Consent screen won't save | Missing required field (usually support email or app name). |
| "This app is blocked" | Test-user list again, or the account is a Workspace account whose admin blocks third-party apps. |
