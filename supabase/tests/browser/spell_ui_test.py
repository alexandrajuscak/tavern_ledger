"""Browser test of the spell catalog and character spellbook against the LOCAL Supabase stack.

Run like the other browser tests (API_URL / ANON_KEY / SERVICE_ROLE_KEY from `supabase status`, app served locally,
Microsoft Edge through playwright). The service role only creates the synthetic user and character; sources and spells
are created with the user's own JWT (same RPCs as the app), and every checked interaction goes through the UI.
Also covers the combined JSON export / import of lineage + spellcasting data. Refuses non-local URLs.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect

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
LAST = {}


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
    email = f"ui-spells-{RUN}@example.test"
    call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    _, body = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, token=ANON, key=ANON)
    uid, jwt = body["user"]["id"], body["access_token"]
    _, chars = call("POST", "/rest/v1/characters", {"owner_id": uid, "name": "Spell Tester", "level": 5, "intelligence": 16, "wisdom": 14,
                                                    "charisma": 14}, {"Prefer": "return=representation"})
    cid = chars[0]["id"]
    rpc = lambda fn, **a: call("POST", f"/rest/v1/rpc/{fn}", a, token=jwt, key=ANON)[1]   # noqa: E731
    rpc("set_character_lineage", p_character=cid, p_version="tiefling-phb", p_subversion="tiefling-asmodeus")
    art = rpc("save_character_spellcasting_source", p_character=cid,
              p_source={"source_type": "class", "label": "Artificer (preview)", "class_version_id": "artificer-tce", "enforce_spell_list": True})["id"]
    man = rpc("save_character_spellcasting_source", p_character=cid,
              p_source={"source_type": "manual", "label": "Manual Spellcasting Source", "casting_ability": "wis", "always_prepared_allowed": True})["id"]
    wand = rpc("save_character_spellcasting_source", p_character=cid, p_source={"source_type": "item", "label": "Wand of Testing", "fixed_dc": 15})["id"]
    for src, sp, known, prep, always in ((art, "alarm-phb", True, False, False), (art, "cure-wounds-phb", True, True, False),
                                         (man, "bless-phb", True, False, True), (man, "thaumaturgy-phb", True, False, False),
                                         (wand, "fireball-phb", True, False, False)):
        rpc("set_character_spell", p_character=cid, p_source=src, p_spell_version=sp, p_known=known, p_prepared=prep, p_always_prepared=always)
    call("POST", "/rest/v1/spells", {"character_id": cid, "name": "Free Text Hex", "level": 1})
    return email, cid


def main():
    email, cid = fixtures()
    SHOTS.mkdir(parents=True, exist_ok=True)
    errors, remote = [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        ctx = browser.new_context(viewport={"width": 1366, "height": 900}, accept_downloads=True)
        ctx.add_init_script(f"localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({{url: {json.dumps(API)}, key: {json.dumps(ANON)}}}));"
                            "localStorage.setItem('tavern-ledger:tab', 'spells');")
        ctx.on("request", lambda r: remote.append(r.url) if urlparse(r.url).hostname not in ("127.0.0.1", "localhost")
               else None)  # fonts and supabase-js are self-hosted since v6.1: any other host is unexpected
        page = ctx.new_page()
        LAST.update(page=page, errors=errors)
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
        page.goto(APP)
        page.fill("input[name=email]", email)
        page.fill("input[name=password]", PW)
        page.click("button[value=signin]")
        page.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        page.goto(f"{APP}#/c/{cid}")
        modal = page.locator(".modal")
        book = page.locator("#spellbook-list")

        def select_text(sel, text):
            value = page.eval_on_selector(sel, "(s, t) => [...s.options].find((o) => o.textContent.includes(t))?.value", text)
            page.select_option(sel, value)

        def card(name):
            return book.locator(".sp-card", has=page.locator(".sp-name", has_text=re.compile(f"^{re.escape(name)}$")))

        page.wait_for_selector("#spellbook-list .sp-card", timeout=20000)
        check("1 the Spells tab loads the resolved spellbook", book.locator(".sp-card").count() >= 7, book.locator(".sp-card").count())
        # the calculation is folded ("How it is calculated"): read the text content of the source cards
        sources = page.locator("#spellcasting-sources").text_content()
        art_block = page.locator('#spellcasting-sources .sp-source', has_text="Artificer (preview)").text_content()
        check("22 Spell Save DC breakdown per source (Artificer: INT +3, PB +3, DC 14)",
              re.search(r"Intelligence modifier\s*\+3", art_block) and re.search(r"Proficiency bonus\s*\+3", art_block)
              and re.search(r"Spell Save DC\s*14", art_block), art_block)
        check("23 Spell Attack Bonus breakdown per source (Artificer +6; item fixed DC 15; lineage CHA 16 -> DC 14)",
              re.search(r"Spell Attack Bonus\s*\+6", art_block) and re.search(r"Fixed Save DC\s*15", sources)
              and "tiefling (lineage)" in sources.lower(), sources)
        check("18 lineage spells appear automatically (Hellish Rebuke, Darkness locked until 5th? level 5: unlocked)",
              card("Hellish Rebuke").count() == 1 and card("Darkness").count() == 1)
        check("19 the source badge names the lineage", "Lineage" in card("Hellish Rebuke").locator(".sp-src").first.inner_text())
        check("20 a spell from two sources is shown once (Thaumaturgy)", card("Thaumaturgy").count() == 1)
        check("25 an always-prepared spell is distinguished (Bless)", "Always prepared" in card("Bless").inner_text())

        # details + focus restoration
        card("Alarm").locator(".sp-name").click()
        page.wait_for_selector(".modal [data-spell-facts]")
        facts = modal.locator("[data-spell-facts]").inner_text()
        check("11-17 details show school, casting time, range, duration, components, ritual and concentration",
              all(x in facts for x in ("Abjuration", "1 minute", "30 feet", "8 hours", "V, S, M", "Ritual\tYes", "Concentration\tNo"))
              or all(re.search(x, facts, re.I) for x in ("Abjuration", "1 minute", "30 feet", "8 hours", r"V, S, M", r"Ritual\s+Yes", r"Concentration\s+No")), facts)
        page.keyboard.press("Escape")
        page.wait_for_timeout(400)
        check("29 closing the detail returns focus to the spell button",
              page.evaluate("document.activeElement?.dataset?.focusKey") == "spell:alarm-phb", page.evaluate("document.activeElement?.dataset?.focusKey"))
        card("Thaumaturgy").locator(".sp-name").click()
        page.wait_for_selector(".modal .sp-grants")
        grants = modal.locator(".sp-grants tbody tr").all_inner_texts()
        check("21 the source breakdown shows both grants with their own DC (lineage CHA 14, manual WIS 13)",
              len(grants) == 2 and any("Lineage" in g and "14" in g for g in grants) and any("Manual" in g and "13" in g for g in grants), grants)
        page.keyboard.press("Escape")

        # prepared toggle
        card("Alarm").locator("[data-action=spell-prepare]").check()
        expect(card("Alarm")).to_contain_text("Prepared", timeout=10000)
        page.wait_for_timeout(600)
        check("24 the prepared state can be changed", card("Alarm").locator("[data-action=spell-prepare]").is_checked())

        # spellbook filters
        page.locator(".sp-filter-box > summary").click()
        page.select_option('[data-sf="source"]', "lineage")
        names = book.locator(".sp-name").all_inner_texts()
        check("26b the source filter shows only lineage spells", names and all(n in ("Thaumaturgy", "Hellish Rebuke", "Darkness") for n in names), names)
        page.select_option('[data-sf="source"]', "")

        # catalog browser (Add spell)
        page.click("[data-action=spell-add]")
        page.wait_for_selector(".modal .sp-pick", timeout=20000)
        picks = lambda: modal.locator(".sp-pick").all_inner_texts()   # noqa: E731
        modal.locator('[data-cf="q"]').fill("fireball")
        check("2 catalog search works", any(t.startswith("Fireball") for t in picks()), picks()[:5])
        modal.locator('[data-cf="q"]').fill("")
        modal.locator('[data-cf="level"]').select_option("3")
        check("3 the level filter works", all("3rd level" in t for t in picks()[:20]), picks()[:3])
        modal.locator('[data-cf="level"]').select_option("")
        modal.locator('[data-cf="school"]').select_option("necromancy")
        check("4 the school filter works", picks() and all("Necromancy" in t for t in picks()[:20]), picks()[:3])
        modal.locator('[data-cf="school"]').select_option("")
        modal.locator('[data-cf="list"]').select_option("artificer-spell-list")
        count = int(re.match(r"(\d+)", modal.locator("[data-add-count]").inner_text()).group(1))
        check("5/10 the class-list filter shows the Artificer list (Cure Wounds yes, Fireball no)",
              count >= 50 and any(t.startswith("Cure Wounds") for t in picks()) and not any(t.startswith("Fireball") for t in picks()), count)
        modal.locator('[data-cf="list"]').select_option("")
        modal.locator('[data-cf="ritual"]').check()
        check("6 the ritual filter works", picks() and all("R" in t.split("·")[-1] or " R" in t for t in picks()[:15])
              and modal.locator(".sp-pick").first.locator(".sp-ritual").count() == 1, picks()[:3])
        modal.locator('[data-cf="ritual"]').uncheck()
        modal.locator('[data-cf="conc"]').check()
        check("7 the concentration filter works", modal.locator(".sp-pick").count() > 0
              and modal.locator(".sp-pick").count() == modal.locator(".sp-pick .sp-conc").count())
        modal.locator('[data-cf="conc"]').uncheck()
        modal.locator('[data-cf="damage"]').select_option("fire")
        check("8 the damage-type filter works", any(t.startswith("Fireball") for t in picks()) and not any(t.startswith("Alarm") for t in picks()))
        modal.locator('[data-cf="damage"]').select_option("")
        modal.locator('[data-cf="status"]').select_option("playtest")
        check("9 the source-status filter works (playtest only)", picks() and all("Playtest" in t for t in picks()[:20]), picks()[:3])
        modal.locator('[data-cf="status"]').select_option("official")

        # add a manual spell; reject an off-list spell for the enforced class source
        modal.locator('[data-cf="q"]').fill("light")
        modal.locator(".sp-pick", has=page.locator("strong", has_text=re.compile(r"^Light$"))).first.click()
        select_text(".modal [data-source-select]", "Manual Spellcasting Source")
        modal.locator("[data-add-save]").click()
        expect(card("Light")).to_have_count(1, timeout=10000)
        check("26 a manual spell can be added", "Manual" in card("Light").inner_text())
        page.click("[data-action=spell-add]")
        page.wait_for_selector(".modal .sp-pick", timeout=20000)
        modal.locator('[data-cf="q"]').fill("fireball")
        modal.locator(".sp-pick", has=page.locator("strong", has_text=re.compile(r"^Fireball$"))).first.click()
        select_text(".modal [data-source-select]", "Artificer")
        warn = modal.locator("[data-list-warning]").inner_text()
        always_disabled = modal.locator("[data-always]").is_disabled()
        before = len(errors)
        modal.locator("[data-add-save]").click()
        expect(page.locator(".toast", has_text="not on the spell list").last).to_be_visible(timeout=10000)
        errors[before:] = [e for e in errors[before:] if "status of 400" not in e]
        check("27 invalid operations are prevented or rejected (off-list spell refused, always-prepared not offered)",
              "not on this source" in warn and always_disabled, warn)
        modal.locator("[data-close]").first.click()

        # export / import (lineage + spellcasting)
        tab = page.locator('.tab[data-tab="bio"]')
        tab.click()
        with page.expect_download() as dl:
            page.locator("[data-action=export-json]").click()
        path = dl.value.path()
        exported = json.loads(Path(path).read_text(encoding="utf-8"))
        cs = exported.get("catalogSpells", [])
        check("32 the export contains the spell selections with stable ids and their sources",
              {g["spell"] for g in cs} >= {"alarm-phb", "cure-wounds-phb", "bless-phb", "thaumaturgy-phb", "fireball-phb", "light-phb"}
              and len(exported["spellcasting"].get("sources", [])) == 3 and exported.get("lineage", {}).get("subversion") == "tiefling-asmodeus",
              (len(cs), exported["spellcasting"].get("sources")))
        exported["name"] = "Spell Tester (imported)"
        imp = SHOTS / f"spell_import_{RUN}.json"
        imp.write_text(json.dumps(exported), encoding="utf-8")
        page.goto(APP)
        page.click("#btn-import")
        page.set_input_files(".modal input[name=file]", str(imp))
        page.locator(".modal button[type=submit]").click()
        page.wait_for_url(re.compile(r"#/c/"), timeout=20000)
        page.locator('.tab[data-tab="spells"]').click()
        page.wait_for_selector("#spellbook-list .sp-card", timeout=20000)
        page.wait_for_timeout(800)
        check("33 import restores the lineage, the three sources and every spell with its sources",
              card("Hellish Rebuke").count() == 1 and card("Fireball").count() == 1 and card("Bless").count() == 1
              and "Always prepared" in card("Bless").inner_text() and page.locator("#spellcasting-sources .sp-source").count() == 4,
              page.locator("#spellcasting-sources").inner_text()[:300])
        check("34 free-text spells stay available after import", "free text hex" in page.locator("#spells-list").inner_text().lower(), page.locator("#spells-list").inner_text()[:200])

        # mobile
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        ov = page.evaluate("() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
        page.click("[data-action=spell-add]")
        page.wait_for_selector(".modal .sp-pick", timeout=20000)
        mov = page.evaluate("() => { const m = document.querySelector('.modal'); return m.scrollWidth - m.clientWidth; }")
        page.screenshot(path=str(SHOTS / "spells_mobile.png"))
        check("28 the mobile layout has no horizontal overflow (page and Add spell dialog)", ov <= 1 and mov <= 1, (ov, mov))
        modal.locator("[data-close]").first.click()
        check("30 no uncaught console errors", not errors, errors)
        check("31 no request went to a hosted service", not remote, remote)
        browser.close()
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
