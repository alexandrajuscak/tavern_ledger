# Email account flows: password reset, email confirmation, magic link

Frontend only (no migration). Code: `js/auth-links.js`, boot in `js/app.js` `init()`, capture listener in `js/supabase.js`.
Test: `supabase/tests/browser/auth_reset_ui_test.py` (in `run_browser_local.sh`).

## Feature flag `AUTH_EMAIL_FLOWS` (`js/config.js`)

| value | sign-in card |
|---|---|
| `'off'` (production until custom SMTP exists) | exactly the earlier card: Google, email + password, Sign in, Create account, magic link |
| `'on'` | adds **Forgot password?** (reset mail) and, after an unconfirmed sign-in or a sign-up without a session, **Resend confirmation email** (60 s cooldown) |

Both added controls send mail. The Supabase built-in mailer delivers only to project team addresses (2 mails per hour), so the
flag is switched on only after custom SMTP is configured in the dashboard. Rollback = `'off'` (+ asset marker bump).

## Always active (flag independent)

These only react to a link the user already arrived with, so a mail sent from the dashboard works with the flag off:

- **PKCE return with a recovery code** (`?code=` from `{{ .ConfirmationURL }}`): `js/supabase.js` registers a record-only
  `onAuthStateChange` listener right after `createClient`, before supabase-js finishes initializing, because supabase-js
  announces `PASSWORD_RECOVERY` once, from a timer, during start-up. The main listener in `init()` keeps its place and its
  `setTimeout` defer (auth-lock deadlock). The event is honoured only in a tab that arrived with `?code=` and a PKCE verifier
  of this browser, and only until the end of boot; later events (another tab's BroadcastChannel broadcast) are ignored.
  The recovery state belongs to the user whose link was opened: sign-out or any other signed-in user clears it.
- **`?token_hash=…&type=recovery|signup|email|magiclink`** (cross-device template): a Continue card first, then
  `verifyOtp({ token_hash, type })`. Nothing is verified before the click, so a mail scanner that prefetches the link does not
  use it up. `token_hash` and `type` are read into memory and removed from the address at once (`js/supabase.js`); `?fluent`,
  `?env` and the `#/…` route stay, and a reload shows the normal app / sign-in card. If the link signs in a different account
  than the stored session, the per-user caches are cleared first (as on sign-out). Wording: `recovery` -> reset, `magiclink`
  -> sign in, `signup` / `email` -> confirm your email.
- **Choose a new password** view after a recovery: two fields, the sign-up minimum (6, `PASSWORD_MIN`), `updateUser({ password })`;
  `same_password`, `weak_password` and an ended session get plain texts. Afterwards the `#/…` route of the URL opens.
- **Expired / used links**: the auth server redirects with `#error=access_denied&error_code=otp_expired…` (fragment) and, for
  PKCE, also `?error_code=…&error_description=` (query); both are cleared from the address. Only an `error_code` starting with
  `otp_` or `flow_state_` gets the "expired or already used" text; any other error (a failed or cancelled Google sign-in)
  shows its own description as before.
- **`?code=` opened in another browser**: there is no PKCE verifier here, so supabase-js ignores the code silently. The app
  checks for a verifier when the page loads; with none and no session it shows a neutral notice ("opened in a different
  browser … or expired; if you were confirming your email, that is done: sign in or request a new link"). A Google return
  always has its verifier (same browser), and a cancelled Google sign-in returns `?error=`, not `?code=`. A `?code=` whose
  exchange fails although a verifier exists gets its own explanation. `code` is removed from the address in both cases.
- **No user enumeration (flag on)**: GoTrue answers a repeated reset / confirmation mail to an existing address within 60 s
  (and the hourly mail limit) with 429 `over_email_send_rate_limit`, but 200 for an unknown address. Forgot password and
  Resend treat that code as the neutral success ("if an account exists…"). `over_request_rate_limit` (per IP, the same for
  every address) keeps the "Too many emails" text.
- **`email_not_confirmed` on sign-in**: a plain message (flag off) or message + Resend (flag on).

Nothing in the client blocks a signed-in session because `email_confirmed_at` is missing: whether new accounts must confirm
their email is the dashboard setting "Confirm email"; the code works with it on or off.

## Email templates (dashboard)

Cross-device links point at the app with the token hash. The app parses exactly:
`<app URL>?token_hash=<hash>&type=<recovery|signup|email|magiclink>` (any `#/…` after it is kept). Templates: Reset password
`type=recovery`, Confirm sign up `type=email`, Magic link `type=magiclink` (checked on the local stack: a magic-link token hash
verifies with `magiclink` and `email`, not with `signup`; a sign-up hash with `email`, not with `magiclink`). With
`{{ .SiteURL }}?token_hash={{ .TokenHash }}&type=recovery`, the Site URL must end with `/`
(`https://<user>.github.io/<repo>/`), otherwise the link points at `/<repo>?token_hash=…` and relies on a GitHub Pages redirect.
