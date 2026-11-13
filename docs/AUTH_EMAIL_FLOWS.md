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
  `setTimeout` defer (auth-lock deadlock). The event is honoured only in a tab that arrived with `?code=` or `?token_hash=`
  (other tabs receive it through the BroadcastChannel and ignore it).
- **`?token_hash=…&type=recovery|signup|email|magiclink`** (cross-device template): a Continue card first, then
  `verifyOtp({ token_hash, type })`. Nothing is verified before the click, so a mail scanner that prefetches the link does not
  use it up. `token_hash` and `type` are removed afterwards; `?fluent`, `?env` and the `#/…` route stay. If the link signs in a
  different account than the stored session, the per-user caches are cleared first (as on sign-out).
- **Choose a new password** view after a recovery: two fields, the sign-up minimum (6, `PASSWORD_MIN`), `updateUser({ password })`;
  `same_password`, `weak_password` and an ended session get plain texts. Afterwards the `#/…` route of the URL opens.
- **Expired / used links**: the auth server redirects with `#error=access_denied&error_code=otp_expired…` (fragment) or
  `?error_description=` (query); both are cleared from the address and shown as a plain message. A `?code=` that cannot be
  exchanged here (opened in another browser) gets an explanation (an email confirmation is already done server-side).
- **`email_not_confirmed` on sign-in**: a plain message (flag off) or message + Resend (flag on).

Nothing in the client blocks a signed-in session because `email_confirmed_at` is missing: whether new accounts must confirm
their email is the dashboard setting "Confirm email"; the code works with it on or off.

## Email templates (dashboard)

Cross-device links point at the app with the token hash. The app parses exactly:
`<app URL>?token_hash=<hash>&type=<recovery|signup|email|magiclink>` (any `#/…` after it is kept). With
`{{ .SiteURL }}?token_hash={{ .TokenHash }}&type=recovery`, the Site URL must end with `/`
(`https://<user>.github.io/<repo>/`), otherwise the link points at `/<repo>?token_hash=…` and relies on a GitHub Pages redirect.
