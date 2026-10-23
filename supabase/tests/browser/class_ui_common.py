"""Shared helpers of the per-class browser tests (class_*_ui_test.py) against the LOCAL Supabase stack.

The service role only creates the synthetic user (ui-*@example.test, removed by run_browser_local.sh); characters and
classes are created with the user's own token (the same RPCs the app calls). Every checked interaction goes through the
UI. Refuses non-local URLs.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

sys.stdout.reconfigure(encoding="utf-8")
API = os.environ["API_URL"].rstrip("/")
ANON = os.environ["ANON_KEY"]
SERVICE = os.environ["SERVICE_ROLE_KEY"]
APP = os.environ.get("APP_URL", "http://127.0.0.1:5173/")
SHOTS = Path(os.environ.get("SCREENSHOT_DIR", "."))
for u in (API, APP):
    if urlparse(u).hostname not in ("127.0.0.1", "localhost"):
        sys.exit(f"refusing to run: {u} is not local")
PW = "local-test-password-1!"
RUN = str(int(time.time()))
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {str(detail)[:400]}"), flush=True)


def call(method, path, body=None, token=SERVICE, key=SERVICE):
    h = {"apikey": key, "Authorization": f"Bearer {token}", "Content-Type": "application/json", "Prefer": "return=representation"}
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class User:
    def __init__(self, tag):
        self.email = f"ui-{tag}-{RUN}@example.test"
        call("POST", "/auth/v1/admin/users", {"email": self.email, "password": PW, "email_confirm": True})
        _, body = call("POST", "/auth/v1/token?grant_type=password", {"email": self.email, "password": PW}, token=ANON, key=ANON)
        self.id, self.jwt = body["user"]["id"], body["access_token"]

    def rpc(self, fn, **args):
        return call("POST", f"/rest/v1/rpc/{fn}", args, token=self.jwt, key=ANON)

    def character(self, name, classes=(), **scores):
        body = {"owner_id": self.id, "name": name, "level": 1, "hp_max": 40, "hp_current": 40, "strength": 10, "dexterity": 10,
                "constitution": 12, "intelligence": 10, "wisdom": 10, "charisma": 10}
        body.update(scores)
        st, rows = call("POST", "/rest/v1/characters", body, token=self.jwt, key=ANON)
        assert st == 201, (st, rows)
        cid = rows[0]["id"]
        for spec in classes:                       # (version, level[, subclass])
            st, r = self.rpc("set_character_class", p_character=cid, p_class_version=spec[0], p_level=spec[1],
                             p_subclass_version=spec[2] if len(spec) > 2 else None)
            assert st == 200, (st, r)
        return cid


class Sheet:
    """One signed-in browser page on a character sheet, with the helpers the class tests need."""

    def __init__(self, browser, user, width=1366, height=900, tab="features"):
        self.ctx = browser.new_context(viewport={"width": width, "height": height}, accept_downloads=True)
        self.ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                                 f"localStorage.setItem('tavern-ledger:tab', {json.dumps(tab)});")
        self.errors, self.remote = [], []
        self.ctx.on("request", lambda r: self.remote.append(r.url) if urlparse(r.url).hostname not in ("127.0.0.1", "localhost")
                    else None)  # fonts and supabase-js are self-hosted since v6.1: any other host is unexpected
        self.page = self.ctx.new_page()
        self.page.on("console", lambda m: self.errors.append(m.text) if m.type == "error" else None)
        self.page.on("pageerror", lambda e: self.errors.append(f"pageerror: {e}"))
        p = self.page
        p.goto(APP)
        p.fill("input[name=email]", user.email)
        p.fill("input[name=password]", PW)
        p.click("button[value=signin]")
        p.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        self.panel = p.locator("#class-features")

    def open(self, cid):
        self.page.goto(f"{APP}#/c/{cid}")
        self.wait(lambda: self.page.locator(".tab").count() > 0)
        self.page.wait_for_timeout(800)

    def tab(self, name):
        self.page.locator(f'.tab[data-tab="{name}"]').click()
        self.page.wait_for_timeout(400)

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

    def choice(self, key):
        return self.panel.locator(f'[data-cf-choice-key="{key}"]').first

    def goto_choice(self, key):
        self.panel.locator(f'[data-cf-goto="{key}"]').first.click()
        self.page.wait_for_timeout(500)

    def open_change(self, key):
        """Open the folded "Chosen: … Change" part of a finished choice."""
        wrap = self.panel.locator(f'[data-cf-choice-wrap="{key}"] details.cf-change')
        if wrap.count() and not wrap.first.evaluate("d => d.open"):
            wrap.first.locator(":scope > summary").click()
            self.page.wait_for_timeout(200)

    def save(self, key):
        self.choice(key).locator("button[type=submit]").click()
        self.page.wait_for_timeout(900)

    def toasts(self):
        return " ".join(self.page.locator(".toast").all_inner_texts())

    def set_level(self, row_id, level):
        self.tab("features")
        self.page.select_option(f"[data-class-level='{row_id}']", str(level))
        self.page.wait_for_selector(".modal [data-cf-review]", timeout=15000)
        body = self.page.locator(".modal [data-cf-review]").text_content()
        self.page.locator(".modal [data-cf-confirm]").click()
        self.page.wait_for_selector(".modal [data-cf-review]", state="detached")
        self.page.wait_for_timeout(1200)
        return body

    def overflow(self):
        return self.page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")

    def close(self):
        self.ctx.close()


def report():
    failed = [n for n, ok in results if not ok]
    print(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)
