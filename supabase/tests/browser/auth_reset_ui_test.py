"""Forgot password + email links (docs/AUTH_EMAIL_FLOWS.md), browser suite. LOCAL ONLY, synthetic users inside isolation.

AR-01..03  flag AUTH_EMAIL_FLOWS 'off' (production): the sign-in card has exactly today's controls; an unconfirmed sign-in
           gets a plain message and no Resend control.
AR-04..08  flag 'on' (js/config.js served with the flag switched for this context only): Forgot password with a neutral answer,
           Resend after an unconfirmed sign-in / a sign-up without session, with its cooldown.
AR-10..15  the reset mail of AR-05 (Mailpit, PKCE ?code= link) in the same browser: "Choose a new password", new password
           works, old one refused; the reused link gets the friendly expired text.
AR-20..27  ?token_hash=…&type=recovery link (admin generate_link, no mail): Continue first (no verify before the click), the
           #/c/<id> route survives, password changed; reused link -> friendly text without "Send a new link" (flag off).
AR-30..34  #error=…otp_expired fragment, magic link type=magiclink in a page signed in as another user (user switch), normal
           email sign-in / sign-out, no console errors.
AR-40..49  review round 2: per-address rate limit (429 over_email_send_rate_limit) answers like an unknown address (flag on);
           token_hash gone from the address before Continue; reset state ends on sign-out (next user is not asked for a new
           password); another tab's PASSWORD_RECOVERY broadcast is ignored by a tab that arrived with ?code=; ?code= without a
           verifier -> neutral notice; a non-link ?error= keeps its own text, an otp_* ?error= gets the link text.
The local stack sends at most 2 auth mails per hour (supabase/config.toml), so exactly one real mail is requested (AR-05).
Usage: APP_URL=... python auth_reset_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import re
import time
import urllib.request
from pathlib import Path

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import ANON, API, APP, PW, RUN, User, call, check, report

ROOT = Path(__file__).resolve().parents[3]
CONFIG = (ROOT / "js" / "config.js").read_text(encoding="utf-8")
MAILPIT = "http://127.0.0.1:54324"
TODAY_CONTROLS = ["btn-google", "email", "password", "signin", "signup", "btn-magic"]
EXPIRED = "expired or was already used"
NOBODY = f"nobody-{RUN}@example.test"
# the body local GoTrue sends for a second reset / confirmation mail to an EXISTING address within max_frequency (probed)
PER_ADDRESS_LIMIT = json.dumps({"code": 429, "error_code": "over_email_send_rate_limit",
                                "msg": "For security purposes, you can only request this after 41 seconds."})


def password_ok(email, pw):
    st, _ = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": pw}, token=ANON, key=ANON)
    return st == 200


def link_hash(kind, email):
    st, r = call("POST", "/auth/v1/admin/generate_link", {"type": kind, "email": email})
    assert st == 200, (st, r)
    return r.get("hashed_token") or (r.get("properties") or {}).get("hashed_token")


def mail_link(email, timeout=20):
    """The link of the newest Mailpit message to `email` (local mail catcher)."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        with urllib.request.urlopen(f"{MAILPIT}/api/v1/search?query=" + urllib.request.quote(f"to:{email}"), timeout=10) as r:
            msgs = json.loads(r.read().decode()).get("messages") or []
        if msgs:
            with urllib.request.urlopen(f"{MAILPIT}/api/v1/message/{msgs[0]['ID']}", timeout=10) as r:
                body = json.loads(r.read().decode())
            m = re.search(r'href="([^"]+/auth/v1/verify[^"]+)"', body.get("HTML") or "") or re.search(r"(http\S+/auth/v1/verify\S+)", body.get("Text") or "")
            if m:
                return m.group(1).replace("&amp;", "&")
        time.sleep(1)
    return None


class Page:
    def __init__(self, browser, flag_on=False, ctx=None):
        self.ctx = ctx or browser.new_context(viewport={"width": 1100, "height": 860})
        if not ctx:
            self.ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));")
        if flag_on and not ctx:
            src = CONFIG.replace("export const AUTH_EMAIL_FLOWS = 'off';", "export const AUTH_EMAIL_FLOWS = 'on';")
            assert src != CONFIG, "flag line not found in js/config.js"
            self.ctx.route(re.compile(r".*/js/config\.js(\?.*)?$"), lambda r: r.fulfill(status=200, content_type="text/javascript", body=src))
        self.errors, self.verifies = [], []
        self.page = self.ctx.new_page()
        self.page.on("console", lambda m: self.errors.append(m.text) if m.type == "error" else None)
        self.page.on("pageerror", lambda e: self.errors.append(f"pageerror: {e}"))
        self.page.on("request", lambda r: self.verifies.append(r.url) if "/auth/v1/verify" in r.url else None)

    def wait(self, fn, timeout=15000):
        t0 = time.time()
        while time.time() - t0 < timeout / 1000:
            try:
                if fn():
                    return True
            except Exception:
                pass
            self.page.wait_for_timeout(200)
        return False

    def controls(self):
        return self.page.evaluate("""() => [...document.querySelectorAll('#app button, #app input, #app a, #app select, #app textarea')]
            .filter((e) => !e.closest('[hidden]')).map((e) => e.id || e.name || e.value || e.textContent.trim())""")

    def text(self):
        return self.page.locator("#app").inner_text() + " " + " ".join(self.page.locator(".toast").all_inner_texts())

    def signin(self, email, pw):
        self.page.fill("input[name=email]", email)
        self.page.fill("input[name=password]", pw)
        self.page.click("button[value=signin]")

    def console_errors(self):
        # a refused verify / token request is logged by the browser as "Failed to load resource" (expected in these cases)
        return [e for e in self.errors if "Failed to load resource" not in e]


def unconfirmed(route):
    route.fulfill(status=400, content_type="application/json",
                  body=json.dumps({"code": 400, "error_code": "email_not_confirmed", "msg": "Email not confirmed"}))


def run(t):
    a = User("auth-a")
    b = User("auth-b")
    cid = a.character(f"Auth Hero {RUN}")
    t.note(characters=[cid])
    pw2, pw3 = "second-pass-" + RUN, "third-pass-" + RUN
    errors = []
    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)

        # --- flag off (production value)
        s = Page(br)
        s.page.goto(APP)
        s.page.wait_for_selector("input[name=email]", timeout=20000)
        check("AR-01 flag off: the sign-in card has exactly today's controls", s.controls() == TODAY_CONTROLS, s.controls())
        check("AR-02 flag off: no Forgot password / Resend in the page", s.page.locator("#btn-forgot, #btn-resend").count() == 0
              and "Forgot" not in s.page.locator("#app").inner_text(), s.page.locator("#app").inner_text())
        s.page.route("**/auth/v1/token?grant_type=password", unconfirmed)
        s.signin(a.email, PW)
        ok = s.wait(lambda: "Confirm your email first" in s.text())
        check("AR-03 flag off: an unconfirmed sign-in gets a plain message, no Resend control", ok and s.page.locator("#btn-resend").count() == 0, s.text())
        s.page.unroute("**/auth/v1/token?grant_type=password")
        errors += s.console_errors()
        s.ctx.close()

        # --- flag on
        s = Page(br, flag_on=True)
        s.page.goto(APP)
        s.page.wait_for_selector("input[name=email]", timeout=20000)
        check("AR-04 flag on: today's controls plus Forgot password (Resend stays hidden until needed)",
              s.controls() == TODAY_CONTROLS + ["btn-forgot"], s.controls())
        s.page.route("**/auth/v1/token?grant_type=password", unconfirmed)
        s.page.route("**/auth/v1/resend*", lambda r: r.fulfill(status=200, content_type="application/json", body="{}"))
        s.signin(a.email, PW)
        ok = s.wait(lambda: s.page.locator("#auth-confirm").is_visible() and "Confirm your email first" in s.page.locator("#auth-confirm").inner_text())
        check("AR-06 flag on: unconfirmed sign-in shows the message and a Resend button", ok, s.text())
        s.page.click("#btn-resend")
        ok = s.wait(lambda: "new link is on its way" in s.text() and s.page.locator("#btn-resend").is_disabled() and "s)" in s.page.locator("#btn-resend").inner_text())
        check("AR-07 Resend: neutral confirmation, then a cooldown", ok, (s.text(), s.page.locator("#btn-resend").inner_text()))
        s.page.unroute("**/auth/v1/token?grant_type=password")
        s.page.route("**/auth/v1/signup*", lambda r: r.fulfill(status=200, content_type="application/json", body=json.dumps(
            {"id": "00000000-0000-4000-8000-000000000001", "aud": "authenticated", "role": "", "email": "new@example.test", "identities": []})))
        s.page.goto(APP)
        s.page.wait_for_selector("input[name=email]", timeout=20000)
        s.page.fill("input[name=email]", "new@example.test")
        s.page.fill("input[name=password]", "whatever-123")
        s.page.click("button[value=signup]")
        ok = s.wait(lambda: s.page.locator("#auth-confirm").is_visible() and "Check your inbox" in s.page.locator("#auth-confirm").inner_text())
        check("AR-08 flag on: sign-up without a session -> 'check your inbox' (same words for an existing address) + Resend", ok, s.text())
        s.page.unroute("**/auth/v1/signup*")
        s.page.unroute("**/auth/v1/resend*")
        # the one real mail of this run
        s.page.goto(APP)
        s.page.wait_for_selector("input[name=email]", timeout=20000)
        s.page.fill("input[name=email]", a.email)
        s.page.click("#btn-forgot")
        s.page.wait_for_selector("#forgot-form", timeout=10000)
        s.page.click("#btn-send-reset")
        ok = s.wait(lambda: s.page.locator("#forgot-sent").is_visible() or "Too many emails" in s.text())
        sent = s.page.locator("#forgot-sent").is_visible()
        check("AR-05 Forgot password: the neutral answer (or the friendly rate-limit text on a rerun within the hour)",
              ok and (not sent or "If an account exists" in s.page.locator("#forgot-sent").inner_text()), s.text())

        # --- the PKCE (?code=) reset link from the mail, same browser
        link = mail_link(a.email) if sent else None
        if link:
            s.page.goto(link)
            ok = s.wait(lambda: s.page.locator("#newpw-form").count() == 1, 20000)
            check("AR-10 PKCE reset link in the same browser opens 'Choose a new password' (not the character list)", ok,
                  (s.page.url, s.page.locator("#app").inner_text()[:300]))
            check("AR-11 the address has no ?code= left", "code=" not in s.page.url, s.page.url)
            s.page.fill("#newpw-form input[name=password]", pw2)
            s.page.fill("#newpw-form input[name=confirm]", pw2 + "x")
            s.page.click("#btn-save-password")
            check("AR-12 different repeat -> refused in the page", s.wait(lambda: "do not match" in s.text(), 5000), s.text())
            s.page.fill("#newpw-form input[name=confirm]", pw2)
            s.page.click("#btn-save-password")
            ok = s.wait(lambda: "Password updated" in s.text() and s.page.locator(".char-card").count() >= 1, 15000)
            check("AR-13 new password saved, then the character list", ok, s.text()[:300])
            check("AR-14 the new password works, the old one is refused", password_ok(a.email, pw2) and not password_ok(a.email, PW))
            s.page.click("#btn-signout")
            s.page.wait_for_selector("input[name=email]", timeout=15000)
            s.page.goto(link)
            ok = s.wait(lambda: EXPIRED in s.text(), 15000)
            check("AR-15 the reused mail link -> friendly expired text; no error parameters left in the address", ok
                  and not re.search(r"[?#&]error", s.page.url), (s.page.url, s.text()[:300]))
            cur = pw2
        else:
            check("AR-10 (skipped: no reset mail this run, the local mail limit is 2 per hour)", True)
            cur = PW
        # (after the PKCE link: every reset request in this browser replaces its PKCE verifier, which would break that link)
        # --- no user enumeration: a refused repeat for an existing address reads exactly like an unknown address
        def forgot_answer(addr, limited):
            if limited:
                s.page.route("**/auth/v1/recover*", lambda r: r.fulfill(status=429, content_type="application/json", body=PER_ADDRESS_LIMIT))
            s.page.goto(APP)
            s.page.wait_for_selector("input[name=email]", timeout=20000)
            s.page.fill("input[name=email]", addr)
            s.page.click("#btn-forgot")
            s.page.wait_for_selector("#forgot-form", timeout=10000)
            s.page.click("#btn-send-reset")
            s.wait(lambda: s.page.locator("#forgot-sent").is_visible() or s.page.locator(".toast").count() > 0, 10000)
            out = (s.page.locator("#forgot-sent").inner_text() if s.page.locator("#forgot-sent").is_visible() else "", s.text())
            if limited:
                s.page.unroute("**/auth/v1/recover*")
            return out
        unknown = forgot_answer(NOBODY, False)          # real request: GoTrue answers 200 for an unknown address
        limited = forgot_answer(a.email, True)          # GoTrue's 429 for an existing address within 60 s
        check("AR-40 Forgot password: an existing address within 60 s (429 over_email_send_rate_limit) gets exactly the answer of "
              "an unknown address", unknown[0] and unknown[0] == limited[0] and "Too many" not in limited[1], (unknown, limited))

        def resend_answer(addr, limited):
            s.page.route("**/auth/v1/token?grant_type=password", unconfirmed)
            if limited:
                s.page.route("**/auth/v1/resend*", lambda r: r.fulfill(status=429, content_type="application/json", body=PER_ADDRESS_LIMIT))
            s.page.goto(APP)
            s.page.wait_for_selector("input[name=email]", timeout=20000)
            s.signin(addr, PW)
            s.wait(lambda: s.page.locator("#auth-confirm").is_visible())
            s.page.evaluate("() => document.querySelectorAll('.toast').forEach((t) => t.remove())")
            s.page.click("#btn-resend")
            s.wait(lambda: s.page.locator(".toast").count() > 0, 10000)
            out = " ".join(s.page.locator(".toast").all_inner_texts())
            s.page.unroute("**/auth/v1/token?grant_type=password")
            if limited:
                s.page.unroute("**/auth/v1/resend*")
            return out
        unknown = resend_answer(NOBODY, False)          # real request: 200 for an unknown address
        limited = resend_answer(a.email, True)
        check("AR-41 Resend: an existing address within 60 s gets exactly the answer of an unknown address",
              "on its way" in unknown and unknown == limited, (unknown, limited))

        errors += s.console_errors()
        s.ctx.close()

        # --- token_hash recovery link (cross-device template), flag off, hash route kept
        h = link_hash("recovery", a.email)
        s = Page(br)
        s.page.goto(f"{APP}?fluent=0&token_hash={h}&type=recovery#/c/{cid}")   # also the legacy read path
        s.page.wait_for_selector("#btn-link-continue", timeout=20000)
        s.page.wait_for_timeout(800)
        check("AR-20 token_hash link: a Continue card, and nothing is verified before the click", not s.verifies, s.verifies)
        check("AR-42 token_hash / type are out of the address already before Continue (?fluent=0 and #/c/<id> kept)",
              "token_hash" not in s.page.url and "type=" not in s.page.url and s.page.url.endswith(f"?fluent=0#/c/{cid}"), s.page.url)
        s.page.click("#btn-link-continue")
        ok = s.wait(lambda: s.page.locator("#newpw-form").count() == 1, 15000)
        check("AR-21 Continue -> 'Choose a new password'", ok, s.page.locator("#app").inner_text()[:300])
        check("AR-22 token_hash / type removed, ?fluent=0 and #/c/<id> kept", "token_hash" not in s.page.url and "type=" not in s.page.url
              and "?fluent=0#" in s.page.url
              and s.page.url.endswith(f"#/c/{cid}"), s.page.url)
        s.page.fill("#newpw-form input[name=password]", "12345")
        s.page.fill("#newpw-form input[name=confirm]", "12345")
        s.page.click("#btn-save-password")
        check("AR-23 the sign-up minimum (6) applies", s.wait(lambda: "at least 6 characters" in s.text(), 5000), s.text())
        s.page.fill("#newpw-form input[name=password]", pw3)
        s.page.fill("#newpw-form input[name=confirm]", pw3)
        s.page.click("#btn-save-password")
        ok = s.wait(lambda: s.page.locator(".tab").count() > 0, 20000)
        check("AR-24 after saving, the character of the #/c/<id> route opens", ok, (s.page.url, s.page.locator("#app").inner_text()[:200]))
        check("AR-25 the new password works, the previous one is refused", password_ok(a.email, pw3) and not password_ok(a.email, cur))
        s.page.click("#btn-signout")
        s.page.wait_for_selector("input[name=email]", timeout=15000)
        s.page.goto(f"{APP}?token_hash={h}&type=recovery")
        s.page.click("#btn-link-continue")
        ok = s.wait(lambda: EXPIRED in s.page.locator("#app").inner_text(), 10000)
        check("AR-26 reused token_hash link -> friendly expired text, no 'Send a new link' (flag off)", ok
              and s.page.locator("#btn-link-new").count() == 0 and "request a new one" not in s.text(), s.text()[:300])
        s.page.click("#btn-link-back")
        ok = s.wait(lambda: s.page.locator("input[name=email]").count() == 1 and "token_hash" not in s.page.url)
        check("AR-27 Back -> the sign-in card, link parameters gone", ok, s.page.url)

        # --- an error the auth server put into the fragment (a fresh page load, as after the auth server's redirect)
        s.page.goto(f"{APP}#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")
        s.page.reload()
        ok = s.wait(lambda: s.page.locator("#auth-notice").count() == 1 and EXPIRED in s.page.locator("#auth-notice").inner_text())
        check("AR-30 #error=…otp_expired -> notice on the sign-in card, the fragment is cleared", ok and "#error" not in s.page.url, s.page.url)
        # a failed Google return (GoTrue puts the error into the query and the fragment); "invalid" in it is not an email link
        oauth = "error=invalid_request&error_code=bad_oauth_state&error_description=OAuth+callback+with+invalid+state"
        s.page.goto(f"{APP}?{oauth}#{oauth}")
        ok = s.wait(lambda: "OAuth callback with invalid state" in s.text())
        check("AR-43 a non-link ?error= (Google failure) keeps its own text, no 'expired' text, address cleared", ok
              and EXPIRED not in s.text() and "error" not in s.page.url, (s.page.url, s.text()[:300]))
        s.page.goto(f"{APP}?error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")
        ok = s.wait(lambda: EXPIRED in s.text())
        check("AR-44 ?error_code=otp_expired (query) -> the friendly link text", ok and "error" not in s.page.url, (s.page.url, s.text()[:300]))
        s.page.goto(f"{APP}?code=00000000-0000-4000-8000-00000000c0de")
        ok = s.wait(lambda: s.page.locator("#auth-notice").count() == 1 and "different browser" in s.page.locator("#auth-notice").inner_text())
        check("AR-45 ?code= without a PKCE verifier in this browser -> neutral notice, code removed", ok and "code=" not in s.page.url,
              (s.page.url, s.text()[:300]))

        # --- normal email sign-in / sign-out, then a magic link of user B in a page signed in as A (user switch)
        s.page.goto(APP)
        s.signin(a.email, pw3)
        ok = s.wait(lambda: s.page.locator(".char-card").count() == 1, 20000)
        check("AR-31 email sign-in still works (A sees A's character)", ok, s.text()[:200])
        mh = link_hash("magiclink", b.email)
        s.page.goto(f"{APP}?token_hash={mh}&type=magiclink")
        s.page.wait_for_selector("#btn-link-continue", timeout=20000)
        title = s.page.locator("#app h1").inner_text()
        s.page.click("#btn-link-continue")
        ok = s.wait(lambda: "Signed in" in s.text(), 15000) and title == "Sign in" and "Email confirmed" not in s.text()
        s.page.wait_for_timeout(1500)
        uid = s.page.evaluate("async () => (await (await import('./js/supabase.js?v=32')).supabase.auth.getSession()).data.session?.user?.id")
        check("AR-32 magic link (type=magiclink, the template's type) reads as signing in; in a page signed in as A: now B, and none of A's characters is shown", ok and uid == b.id
              and s.page.locator(".char-card").count() == 0 and f"Auth Hero {RUN}" not in s.page.locator("#app").inner_text(), (uid, s.text()[:200]))
        s.page.click("#btn-signout")
        ok = s.wait(lambda: s.page.locator("input[name=email]").count() == 1)
        check("AR-33 sign-out still works", ok)

        # --- a reset link of B, then sign-out, then A signs in in the same tab: A is NOT asked for a new password
        hb = link_hash("recovery", b.email)
        s.page.goto(f"{APP}?token_hash={hb}&type=recovery")
        s.page.click("#btn-link-continue")
        ok = s.wait(lambda: s.page.locator("#newpw-form").count() == 1, 15000)
        s.page.click("#btn-signout")
        s.page.wait_for_selector("input[name=email]", timeout=15000)
        s.signin(a.email, pw3)
        ok = ok and s.wait(lambda: s.page.locator(".char-card").count() == 1, 20000)
        s.page.wait_for_timeout(800)
        check("AR-46 reset link of B -> sign-out -> A signs in: A's character list, no 'Choose a new password'",
              ok and s.page.locator("#newpw-form").count() == 0, s.text()[:300])
        errors += s.console_errors()
        s.ctx.close()

        # --- two tabs of one browser: tab 1 arrived with ?code= (and a verifier, like a Google return), tab 2 opens a reset link
        s = Page(br)
        s.page.goto(APP)
        s.page.wait_for_selector("input[name=email]", timeout=20000)
        sk = s.page.evaluate("async () => (await import('./js/supabase.js?v=32')).supabase.auth.storageKey")
        s.page.evaluate("(k) => localStorage.setItem(k + '-code-verifier', JSON.stringify('x'.repeat(56)))", sk)
        s.page.goto(f"{APP}?code=00000000-0000-4000-8000-00000000c0de")
        ok = s.wait(lambda: s.page.locator("#auth-notice").count() == 1 and "could not finish here" in s.page.locator("#auth-notice").inner_text())
        check("AR-47 ?code= with a verifier whose exchange fails -> the 'could not finish' notice (not the other-browser one)", ok,
              s.text()[:300])
        s.signin(a.email, pw3)
        ok = s.wait(lambda: s.page.locator(".char-card").count() == 1, 20000)
        t2 = Page(br, ctx=s.ctx)
        ha = link_hash("recovery", a.email)
        t2.page.goto(f"{APP}?token_hash={ha}&type=recovery")
        t2.page.click("#btn-link-continue")
        ok2 = t2.wait(lambda: t2.page.locator("#newpw-form").count() == 1, 15000)
        s.page.wait_for_timeout(2500)
        check("AR-48 tab 2: the reset link opens 'Choose a new password'", ok2, t2.page.locator("#app").inner_text()[:200])
        check("AR-49 tab 1 (arrived with ?code= long ago) ignores tab 2's PASSWORD_RECOVERY broadcast", ok
              and s.page.locator("#newpw-form").count() == 0 and s.page.locator(".char-card").count() == 1, s.text()[:300])
        t2.page.click("#btn-newpw-later")
        errors += s.console_errors() + t2.console_errors()
        s.ctx.close()
        check("AR-34 no console errors", not errors, errors[:5])
        br.close()


if __name__ == "__main__":
    with iso.Isolated("AUTH-RESET-UI") as t:
        run(t)
    report()
