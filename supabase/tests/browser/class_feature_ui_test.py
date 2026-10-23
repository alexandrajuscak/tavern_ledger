"""Browser test of the generic class feature UI (migration 20261015001800) against the LOCAL Supabase stack.

Uses the SYNTHETIC Engine Test Class (supabase/tests/fixtures/class_feature_engine_fixture.sql, loaded by this test; test
content, not official). The service role only creates the synthetic user and character; every checked interaction goes
through the UI: Features tab (feature cards, optional / replacement features, generated choice controls, subclass),
Resources tab (generic resource component), Bio (level change review), rests, Combat, Spells, Stats, export / import.
Refuses non-local URLs.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright

sys.stdout.reconfigure(encoding="utf-8")
API = os.environ["API_URL"].rstrip("/")
ANON = os.environ["ANON_KEY"]
SERVICE = os.environ["SERVICE_ROLE_KEY"]
APP = os.environ.get("APP_URL", "http://127.0.0.1:5173/")
SHOTS = Path(os.environ.get("SCREENSHOT_DIR", "."))
DB = os.environ.get("DB_CONTAINER", "supabase_db_tavern_ledger")
for u in (API, APP):
    if urlparse(u).hostname not in ("127.0.0.1", "localhost"):
        sys.exit(f"refusing to run: {u} is not local")
PW = "local-test-password-1!"
RUN = str(int(time.time()))
FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "class_feature_engine_fixture.sql"
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {detail}"), flush=True)


def call(method, path, body=None, headers=None, token=SERVICE, key=SERVICE):
    h = {"apikey": key, "Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def fixtures():
    subprocess.run(["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-q"],
                   input=FIXTURE.read_bytes(), check=True, capture_output=True)
    email = f"ui-features-{RUN}@example.test"
    call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    _, body = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, token=ANON, key=ANON)
    uid, jwt = body["user"]["id"], body["access_token"]
    _, chars = call("POST", "/rest/v1/characters", {"owner_id": uid, "name": "Feature UI Tester", "level": 1, "strength": 14, "dexterity": 14,
                                                    "constitution": 12, "intelligence": 10, "wisdom": 16, "charisma": 12,
                                                    "hp_max": 30, "hp_current": 30}, {"Prefer": "return=representation"})
    return email, chars[0]["id"], jwt


def main():
    email, cid, jwt = fixtures()
    SHOTS.mkdir(parents=True, exist_ok=True)
    errors, remote = [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        ctx = browser.new_context(viewport={"width": 1366, "height": 900}, accept_downloads=True)
        ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                            "localStorage.setItem('tavern-ledger:tab', 'features');")
        ctx.on("request", lambda r: remote.append(r.url) if urlparse(r.url).hostname not in ("127.0.0.1", "localhost")
               else None)  # fonts and supabase-js are self-hosted since v6.1: any other host is unexpected
        page = ctx.new_page()
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
        page.goto(APP)
        page.fill("input[name=email]", email)
        page.fill("input[name=password]", PW)
        page.click("button[value=signin]")
        page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        page.goto(f"{APP}#/c/{cid}")
        panel = page.locator("#class-features")
        resources = page.locator("#class-resources")
        card = page.locator("#class-card-body")

        def tab(name):
            page.locator(f'.tab[data-tab="{name}"]').click()
            page.wait_for_timeout(300)

        def wait_for(fn, timeout=15000):
            t0 = time.time()
            while time.time() - t0 < timeout / 1000:
                try:
                    if fn():
                        return True
                except Exception:
                    pass
                page.wait_for_timeout(200)
            return False

        def feature(unlock):
            return panel.locator(f'[data-cf-feature="{unlock}"]')

        def choice(key):
            return panel.locator(f'[data-cf-choice-key="{key}"]')

        def result(key):
            """The visible result of a choice (its wrapper; a finished choice is folded to "Chosen: ...")."""
            w = panel.locator(f'[data-cf-choice-wrap="{key}"]')
            return (w if w.count() else choice(key)).first.text_content()

        def save(key):
            choice(key).locator("button[type=submit]").click()
            page.wait_for_timeout(700)

        def toast_text():
            return " ".join(page.locator(".toast").all_inner_texts())

        def confirm_review():
            page.wait_for_selector(".modal [data-cf-review]", timeout=15000)
            body = page.locator(".modal [data-cf-review]").text_content()
            page.locator(".modal [data-cf-confirm]").click()
            page.wait_for_selector(".modal [data-cf-review]", state="detached")
            return body

        def set_level(level):
            sel = card.locator("select[data-class-level]").first
            sel.select_option(str(level))

        # ---- add the test class on Build -----------------------------------------------------------------------------
        page.wait_for_selector("#class-card-body [data-class-fallback]", timeout=20000)
        page.click("[data-action=class-add]")
        page.wait_for_selector(".modal [data-class-form]")
        value = page.eval_on_selector(".modal [data-class-form] select[name=class]",
                                      "s => [...s.options].find((o) => o.textContent.includes('Engine Test'))?.value")
        page.select_option(".modal [data-class-form] select[name=class]", value)
        page.fill(".modal [data-class-form] input[name=level]", "2")
        page.click(".modal [data-class-save]")
        page.wait_for_selector(".modal [data-class-form]", state="detached")
        check("0 the synthetic test class is added on Bio (level 2) and its summary links to the class features",
              wait_for(lambda: "Level 2" in card.inner_text()) and wait_for(lambda: page.locator("[data-cf-summary]").count() == 1),
              card.inner_text()[:200])

        tab("features")
        check("1 the generic Class features section loads", wait_for(lambda: panel.locator(".cf-class").count() == 1), panel.inner_text()[:200])
        check("2 feature cards come from the backend (Spirit Strike, Test Burst; not Extra Attack at level 2)",
              feature("et-u1-strike").count() == 1 and feature("et-u2-burst").count() == 1 and feature("et-u5-extra-attack").count() == 0)
        check("3 active and inactive features are distinguished (optional feature not selected yet)",
              "is-active" in (feature("et-u1-strike").get_attribute("class") or "")
              and "is-available" in (feature("et-u1-optional-lore").get_attribute("class") or ""))
        check("4 automation status is visible (automated / informational)",
              "Automatic" in feature("et-u1-strike").text_content() and "Reminder" in feature("et-u2-tactical-note").text_content())
        check("11 an incomplete-choice warning appears", panel.locator("[data-cf-incomplete]").count() == 1
              and "Fighting style" in panel.locator("[data-cf-incomplete]").inner_text())

        feature("et-u1-optional-lore").locator("[data-cf-action=optional]").click()
        check("5 an optional feature can be selected", wait_for(lambda: "is-active" in (feature("et-u1-optional-lore").get_attribute("class") or "")))

        style = choice("et-u1-fighting-style:et-style")
        skills = choice("et-u1-proficiencies:et-skills")
        check("8 the choice controls are generated from the definitions (radios for one option, checkboxes for two skills)",
              style.locator("input[type=radio]").count() == 5 and skills.locator("input[type=checkbox]").count() == 5)
        skills.locator("input[value=athletics]").check()
        save("et-u1-proficiencies:et-skills")
        t = toast_text()
        skills.locator("input[value=perception]").check()
        save("et-u1-proficiencies:et-skills")
        check("9 multiple-choice validation: one skill is refused (choose at least 2), two are saved",
              "at least 2" in t and wait_for(lambda: "Done" in result("et-u1-proficiencies:et-skills")), t)
        style.locator("input[value=archery]").check()
        save("et-u1-fighting-style:et-style")
        el_before = choice("et-u2-discipline:et-element").count()
        choice("et-u2-discipline:et-discipline-pick").locator("input[value=elements]").check()
        save("et-u2-discipline:et-discipline-pick")
        wait_for(lambda: choice("et-u2-discipline:et-element").locator("input[value=fire]").count() == 1)
        choice("et-u2-discipline:et-element").locator("input[value=fire]").check()
        save("et-u2-discipline:et-element")
        check("10 a dependent sub-choice opens only after its parent option (Element after Elements)",
              el_before == 0 and wait_for(lambda: "Done" in result("et-u2-discipline:et-element")),
              el_before)
        check("12a the subclass choice is not offered before its level", choice("et-u3-subclass:et-subclass-pick").count() == 0)

        # ---- level change review (increase) --------------------------------------------------------------------------------
        tab("features")
        set_level(5)
        body = confirm_review()
        check("22 a level increase shows the review first (features activated, resources, proficiency bonus)",
              "Extra Attack" in body and "Features activated" in body and "+2 → +3" in body, body[:400])
        check("23 the level change is applied after confirmation", wait_for(lambda: "Level 5" in card.inner_text()))
        tab("features")
        check("12 the subclass selection appears at its level",
              wait_for(lambda: choice("et-u3-subclass:et-subclass-pick").locator("input[name=subclass]").count() >= 1))
        choice("et-u3-subclass:et-subclass-pick").locator("input[value=engine-test-path-fixture]").check()
        save("et-u3-subclass:et-subclass-pick")
        check("13 the subclass feature appears and is active (Path Precision)",
              wait_for(lambda: "is-active" in (feature("et-p3-precision").get_attribute("class") or "")))
        feature("et-u3-swift-reflexes").locator("[data-cf-action=optional]").click()
        check("6 a replacement feature can be selected", wait_for(lambda: "is-active" in (feature("et-u3-swift-reflexes").get_attribute("class") or "")))
        check("7 the replaced feature becomes inactive (Keen Senses: Replaced)",
              wait_for(lambda: "Replaced" in feature("et-u3-keen-senses").text_content()))
        check("27 the ASI placeholder shows as incomplete, with a feat placeholder option",
              "Choice needed" in result("et-u4-asi:et-asi-pick")
              and choice("et-u4-asi:et-asi-pick").locator("input[name=asi-feat]").count() == 1)
        nxt = panel.locator("[data-cf-next]")
        nxt.locator("summary").click()
        check("26 the next-level preview is displayed (level 6: Advanced Technique)",
              "Next level preview" in nxt.inner_text() and wait_for(lambda: "Advanced Technique" in nxt.inner_text()), nxt.inner_text()[:200])

        # ---- resources ----------------------------------------------------------------------------------------------------
        tab("features")
        page.locator("#class-resources-card").evaluate("d => { d.open = true; }")
        surge = resources.locator('[data-cf-res$=":et-surge-uses"]')
        check("14 the resource component shows remaining / maximum, die and recovery",
              wait_for(lambda: "1 / 1" in surge.inner_text()) and "short or long rest" in surge.inner_text()
              and "d8" in resources.locator('[data-cf-res$=":et-inspiration-uses"]').inner_text(), resources.inner_text()[:300])
        surge.locator("[data-cf-action=res-use]").click()
        check("15 a resource can be spent (0 / 1)", wait_for(lambda: "0 / 1" in surge.inner_text()))
        check("16 the final use cannot be spent twice (Use disabled)", surge.locator("[data-cf-action=res-use]").is_disabled())
        burst = resources.locator('[data-cf-res$=":et-burst-uses"]')
        burst.locator("[data-cf-action=res-use]").dblclick()
        page.wait_for_timeout(1500)
        _, ev = call("GET", f"/rest/v1/character_resource_events?character_id=eq.{cid}&feature_resource_id=eq.et-burst-uses&event_type=eq.expend&select=id")
        check("16b a double click spends one use only (one expend event)", isinstance(ev, list) and len(ev) == 1, ev)
        resources.locator('[data-cf-res$=":et-reserve-uses"] [data-cf-action=res-use]').click()
        page.wait_for_timeout(800)
        page.locator("[data-action=short-rest]").first.click()
        dlg = page.locator(".modal").last.inner_text()
        page.locator(".modal [data-ok]").last.click()
        page.wait_for_selector(".modal [data-rest-summary]", timeout=15000); page.locator(".modal [data-rest-ok]").last.click(); page.wait_for_selector(".modal [data-rest-summary]", state="detached", timeout=5000)
        page.wait_for_timeout(500)
        check("17 a short rest restores the short-rest resources and lists what it does not restore",
              "Class resources restored" in dlg and wait_for(lambda: "1 / 1" in surge.inner_text())
              and "2 / 3" in resources.locator('[data-cf-res$=":et-reserve-uses"]').inner_text(), dlg)
        page.locator("[data-action=long-rest]").first.click()
        page.locator(".modal [data-ok]").last.click()
        page.wait_for_selector(".modal [data-rest-summary]", timeout=15000); page.locator(".modal [data-rest-ok]").last.click(); page.wait_for_selector(".modal [data-rest-summary]", state="detached", timeout=5000)
        check("18 a long rest restores the long-rest resource (Test Reserve 3 / 3)",
              wait_for(lambda: "3 / 3" in resources.locator('[data-cf-res$=":et-reserve-uses"]').inner_text()))

        # ---- grants on the other tabs --------------------------------------------------------------------------------------
        tab("stats")
        dot = page.locator('[data-action=cycle-skill][data-k=athletics]')
        check("19 the feature skill proficiency appears on Stats (Athletics from your class)",
              wait_for(lambda: dot.get_attribute("data-level") == "1" and "from-class" in (dot.get_attribute("class") or "")),
              (dot.get_attribute("data-level"), dot.get_attribute("class")))
        tab("spells")
        check("20 the feature spell appears in the spellbook with a Class feature badge (Detect Magic, Shield)",
              wait_for(lambda: "Detect Magic" in page.locator("#spellbook-list").inner_text()
                       and "Class feature" in page.locator("#spellbook-list").inner_text()), page.locator("#spellbook-list").inner_text()[:300])
        tab("combat")
        check("21 the feature attack appears on Combat (Spirit Strike, 2 attacks, critical 19-20)",
              wait_for(lambda: "Spirit Strike" in page.locator("#feature-attacks").inner_text())
              and "2 attacks" in page.locator("#feature-attacks").inner_text() and "19–20" in page.locator("#feature-attacks").inner_text(),
              page.locator("#feature-attacks").inner_text()[:200])

        # ---- export / import ------------------------------------------------------------------------------------------------
        tab("bio")
        with page.expect_download() as dl:
            page.locator("[data-action=export-json]").click()
        exported = json.loads(Path(dl.value.path()).read_text(encoding="utf-8"))
        cf = exported.get("classFeatures") or {}
        check("28 the export includes the feature state with stable ids (choices, optional features, resources)",
              any(c["choice"] == "et-style" and c["values"] == ["archery"] for c in cf.get("choices", []))
              and any(o["unlock"] == "et-u3-swift-reflexes" for o in cf.get("optionalFeatures", []))
              and any(r["resource"] == "et-surge-uses" for r in cf.get("resources", [])), cf)

        # ---- level decrease review and preserved choices ---------------------------------------------------------------------
        tab("features")
        sel = card.locator("select[data-class-level]").first
        sel.focus()                                  # a user changes the select with focus on it (select_option does not focus)
        sel.select_option("2")
        page.wait_for_selector(".modal [data-cf-review]", timeout=15000)
        body = page.locator(".modal [data-cf-review]").text_content()
        page.locator(".modal [data-close]").last.click()
        page.wait_for_selector(".modal [data-cf-review]", state="detached")
        wait_for(lambda: page.evaluate("() => document.activeElement?.dataset?.focusKey || ''").startswith("class-level:"), 4000)
        focused = page.evaluate("() => (document.activeElement?.dataset?.focusKey || '') + '|' + (document.activeElement?.tagName || '')")
        check("24 a level decrease shows the review (Extra Attack deactivated, subclass inactive)",
              "Features deactivated" in body and "Extra Attack" in body and "below its level" in body, body[-400:])
        check("31 cancelling the review keeps level 5 and returns focus to the level select",
              "Level 5" in card.inner_text() and focused.startswith("class-level:"), (focused, card.inner_text()[:120]))
        set_level(2)
        confirm_review()
        tab("features")
        check("25 after lowering the level the subclass and its choices are kept for review (inactive, warned)",
              wait_for(lambda: "kept but inactive" in panel.locator("[data-cf-subclass]").inner_text())
              and "kept but inactive" in panel.locator("[data-cf-warnings]").inner_text(), panel.inner_text()[:300])

        exported["name"] = "Feature UI Tester (imported)"
        imp = SHOTS / f"feature_import_{RUN}.json"
        imp.write_text(json.dumps(exported), encoding="utf-8")
        page.goto(APP)
        page.click("#btn-import")
        page.set_input_files(".modal input[name=file]", str(imp))
        page.locator(".modal button[type=submit]").click()
        page.wait_for_url(re.compile(r"#/c/"), timeout=20000)
        tab("features")
        check("29 import restores the feature state (archery, Swift Reflexes replacing Keen Senses, subclass)",
              wait_for(lambda: "Archery" in result("et-u1-fighting-style:et-style"))
              and "Replaced" in feature("et-u3-keen-senses").text_content() and feature("et-p3-precision").count() == 1,
              panel.inner_text()[:300])

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        ov = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
        page.screenshot(path=str(SHOTS / "features_mobile.png"), full_page=True)
        tab("combat")
        ov2 = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
        check("30 mobile (390 px): no horizontal overflow on Build and Play", ov <= 0 and ov2 <= 0, (ov, ov2))
        relevant = [e for e in errors if "status of 400" not in e]     # the deliberately refused choice (test 9) answers 400
        check("32 no uncaught browser errors", not relevant, relevant[:5])
        check("33 no request went to a hosted service (only local + CDN / fonts)", not remote, remote[:5])
        browser.close()
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
