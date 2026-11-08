"""Production smoke test of the gameplay polish release (docs/GAMEPLAY_POLISH_AUDIT.md).

LIVE GitHub Pages site, SYNTHETIC accounts only (scripts/fluent/smoke_users.sql: smoke-fl-*@example.test, their own campaign
and two characters). Never opens or changes a real player's character. Env: SMOKE_RUN, SMOKE_PW, PROD_APP, OUT.
Player: coin calculator (gain, spend with change, Undo, Realtime to a second session), Hungry Jaws on Play (Lizardfolk set on
the synthetic character), Magic Initiate spells from the Sage background, the new icons. DM: a Tool draft without armor
fields validates, Weapon without damage and Armor without AC are explained, the draft is deleted. Stranger denied.
"""
import json
import os
import time

from playwright.sync_api import sync_playwright

import production_fluent_smoke as base
from production_fluent_smoke import Session, check, results, HERO, SOLO

OUT = os.environ.get("OUT")
summary = {}
HASH_JS = """async (path) => { const r = await fetch(path, { cache: 'no-store' }); if (!r.ok) return 'HTTP ' + r.status;
  const d = await crypto.subtle.digest('SHA-256', await r.arrayBuffer());
  return [...new Uint8Array(d)].slice(0, 8).map((x) => x.toString(16).padStart(2, '0')).join(''); }"""


def coins(page):
    return page.evaluate("() => Object.fromEntries(['cp','sp','ep','gp','pp'].map((k) => [k, document.querySelector(`.inv-coins [data-f=\"${k}\"]`)?.value]))")


def rpc(sess, fn, **args):
    """A call with the signed-in user's own session (the app's supabase client): same RLS as the UI."""
    return sess.page.evaluate("""async ([fn, args]) => { const m = await import('./js/supabase.js?v=19');
      const { data, error } = await m.supabase.rpc(fn, args); return { data, error: error && { code: error.code, message: error.message } }; }""", [fn, args])


def wait(fn, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if fn():
                return True
        except Exception:
            pass
        time.sleep(0.25)
    return False


def run():
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        pl = Session(b, "player")
        page = pl.page
        info = page.evaluate("() => window.__tavernLedgerReadPath")
        check("PP-01 player signed in on the progressive path (site default)", info.get("path") == "fluent" and info.get("configured") == "on", info)
        v = page.evaluate("() => [...new Set([...document.querySelectorAll('script[src],link[href]')].map((e) => (e.src || e.href).match(/[?]v=(\\d+)/)?.[1]).filter(Boolean))]")
        check("PP-02 one asset version (?v=19)", v == ["19"], v)
        hero, solo = pl.char_id(HERO), pl.char_id(SOLO)

        # icons
        h = {a: page.evaluate(HASH_JS, f"assets/icons/{a}.webp") for a in ["items/weapons", "items/tools", "items/lute", "classes/fighter", "spell-schools/illusion", "classes/rogue"]}
        check("PP-03 Weapons is not the site logo; Tools is the lute; Illusion is not the Rogue emblem",
              h["items/weapons"] != h["classes/fighter"] and h["items/tools"] == h["items/lute"] and h["spell-schools/illusion"] != h["classes/rogue"]
              and not any(x.startswith("HTTP") for x in h.values()), h)

        # coin calculator on the synthetic character outside the campaign (the player manages it)
        r = rpc(pl, "adjust_character_coins", p_character=solo, p_mode="set", p_amount={"gp": 1},
                p_expected=page.evaluate(f"""async () => {{ const m = await import('./js/supabase.js?v=19');
                  const {{ data }} = await m.supabase.from('characters').select('cp,sp,ep,gp,pp').eq('id', '{solo}').single(); return data; }}"""))
        check("PP-04 a wallet of 1 gp is set (synthetic character)", not r["error"], r["error"])
        pl.open(solo); pl.tab("inventory")
        wait(lambda: page.locator('[data-action="coin-calc"]').count() == 1)
        p2 = Session(b, "player"); p2.open(solo); p2.tab("inventory")
        page.locator('[data-action="coin-calc"]').click()
        dlg = page.locator(".modal").last
        dlg.locator("[data-coin-calc]").wait_for(timeout=15000)
        dlg.locator('[data-coin="sp"]').fill("3"); dlg.locator('[data-coin="cp"]').fill("4")
        check("PP-05 spend preview: 1 gp - 3 sp 4 cp -> 6 sp, 6 cp", dlg.locator("[data-coin-after]").inner_text().startswith("6 sp, 6 cp"), dlg.locator("[data-coin-preview]").inner_text())
        i = pl.mark(); t0 = time.time()
        dlg.locator("[data-coin-apply]").click()
        ok = wait(lambda: coins(page)["sp"] == "6")
        summary["coin_apply_ms"] = round((time.time() - t0) * 1000)
        check("PP-06 applied: the sheet shows 6 sp 6 cp", ok and coins(page) == {"cp": "6", "sp": "6", "ep": "0", "gp": "0", "pp": "0"}, coins(page))
        reqs = [r["name"] for r in pl.since(i)]
        summary["coin_requests"] = reqs
        check("PP-07 no full-sheet reload after the coin change", "get_character_shell" not in reqs and "get_character_view" not in reqs, reqs)
        check("PP-08 Realtime: the second session shows the new coins", wait(lambda: coins(p2.page)["sp"] == "6", 15), coins(p2.page))
        dlg.locator("[data-coin-undo]").click()
        check("PP-09 Undo restores 1 gp", wait(lambda: coins(page)["gp"] == "1"), coins(page))
        dlg.locator('input[name="coin-mode"][value="gain"]').check()
        dlg.locator('[data-coin="gp"]').fill("2")
        dlg.locator("[data-coin-apply]").click()
        wait(lambda: coins(page)["gp"] == "3")
        dlg.locator("[data-coin-undo]").click()
        check("PP-10 a tiny gain applied and reversed (back to 1 gp)", wait(lambda: coins(page)["gp"] == "1"), coins(page))
        page.keyboard.press("Escape"); p2.ctx.close()

        # Magic Initiate from the Sage background (synthetic character outside the campaign)
        r = rpc(pl, "set_character_background", p_character=solo, p_version="sage-2024", p_ability={"mode": "2024", "allocation": {"int": 2, "con": 1}})
        if r["error"]:
            r = rpc(pl, "set_character_background", p_character=solo, p_version="sage-2024")
        check("PP-11 the player chooses the Sage background", not r["error"], r["error"])
        sp = page.evaluate("""async () => { const m = await import('./js/supabase.js?v=19');
          const q = (lvl) => m.supabase.from('class_spell_list_entries').select('spell_version_id, spell_versions!inner(level, name)').eq('list_id', 'wizard-spell-list').eq('spell_versions.level', lvl).order('spell_version_id').limit(2);
          const [a, b] = await Promise.all([q(0), q(1)]); return { c: (a.data || []).map((x) => [x.spell_version_id, x.spell_versions.name]), s: (b.data || []).slice(0, 1).map((x) => [x.spell_version_id, x.spell_versions.name]) }; }""")
        r = rpc(pl, "set_character_feat_choices", p_character=solo, p_grant_key="bg:sage-2024",
                p_choices={"ability": ["int"], "cantrips": [x[0] for x in sp["c"]], "spell1": [x[0] for x in sp["s"]]})
        check("PP-12 the Magic Initiate choices save (background grant)", not r["error"] and len(sp["c"]) == 2 and len(sp["s"]) == 1, r["error"] or sp)
        pl.open(solo); pl.tab("spells")
        names = [x[1] for x in sp["c"] + sp["s"]]
        ok = wait(lambda: all(n in page.locator("#spellbook-list").inner_text() for n in names), 20)
        check("PP-13 the Spells tab lists both cantrips and the level-1 spell", ok and len(names) == 3, (names, page.locator("#spellbook-list").inner_text()[:200]))
        check("PP-14 their source is Magic Initiate", "Magic Initiate" in pl.text())
        illus = page.evaluate("() => [...document.querySelectorAll('#spellbook-list img')].map((i) => i.getAttribute('src')).filter((s) => s.includes('spell-schools/illusion')).length")
        summary["illusion_icons_on_spells"] = illus

        # DM: Lizardfolk on the campaign character (Hungry Jaws), the item editor
        dm = Session(b, "dm")
        r = rpc(dm, "set_character_lineage", p_character=hero, p_version="lizardfolk-mpmm")
        check("PP-15 the DM sets Lizardfolk (MPMM) on the synthetic campaign character", not r["error"], r["error"])
        pl.open(hero); pl.tab("combat")
        ok = wait(lambda: page.locator('.cf-quick:has-text("Hungry Jaws")').count() > 0, 20)
        q = page.locator('.cf-quick:has-text("Hungry Jaws")').first
        check("PP-16 Play shows Hungry Jaws in Ready to use (2 / 2)", ok and "2 / 2" in q.inner_text(), q.inner_text() if ok else pl.text()[:300])
        i = pl.mark()
        q.locator('[data-cf-action="res-use"]').click()
        ok = wait(lambda: "1 / 2" in page.locator('.cf-quick:has-text("Hungry Jaws")').first.inner_text())
        reqs = [r["name"] for r in pl.since(i)]
        check("PP-17 Use decrements once, without a full-sheet reload", ok and "get_character_shell" not in reqs, reqs)
        page.locator('.cf-quick:has-text("Hungry Jaws")').first.locator('[data-cf-action="res-restore"]').click()
        check("PP-18 Restore puts it back (2 / 2)", wait(lambda: "2 / 2" in page.locator('.cf-quick:has-text("Hungry Jaws")').first.inner_text()))

        d = dm.page
        d.goto(base.APP + "#/dm/content")
        wait(lambda: d.locator("[data-dm-campaign]").count() > 0, 20)
        camp = d.evaluate("(n) => [...document.querySelectorAll('[data-dm-campaign] option')].find((o) => o.textContent.includes(n))?.value", f"Smoke FL {base.RUN}")
        if camp:
            d.select_option("[data-dm-campaign]", camp)
        wait(lambda: d.locator('[data-dm="new-content"][data-type="item"]').count() > 0, 20)
        d.locator('[data-dm="new-content"][data-type="item"]').click()
        d.wait_for_selector(".modal [data-ce-form]", timeout=20000)
        md = d.locator(".modal").last
        md.locator('[name="definition.item.kind_id"]').select_option("tool")
        md.locator("[name=name]").fill(f"Smoke Tinker Kit {base.RUN}")
        check("PP-19 Tool: no Armor / Weapon section", not md.locator('[data-ce-for="armor"]').is_visible() and not md.locator('[data-ce-for="weapon"]').is_visible())
        md.locator('[data-ce-act="validate"]').click()
        ok = wait(lambda: md.locator(".ce-status").count() > 0 and "Ready" in md.locator(".ce-status").inner_text(), 20)
        check("PP-20 a Tool draft without armor fields saves and validates", ok, md.locator(".modal-body").inner_text()[:300])
        md.locator('[name="definition.item.kind_id"]').select_option("weapon")
        md.locator('[data-ce-act="validate"]').click()
        ok = wait(lambda: "damage dice" in md.locator(".modal-body").inner_text(), 20)
        check("PP-21 Weapon without damage: explained (no raw error)", ok and "constraint" not in md.inner_text().lower(), md.locator(".gov-error").inner_text() if md.locator(".gov-error").count() else "")
        md.locator('[name="definition.item.kind_id"]').select_option("armor")
        md.locator('[name="definition.item.category_id"]').fill("light-armor")
        md.locator('[data-ce-act="validate"]').click()
        ok = wait(lambda: "base AC" in md.locator(".modal-body").inner_text(), 20)
        check("PP-22 Armor without a base AC: explained", ok, md.locator(".gov-error").inner_text() if md.locator(".gov-error").count() else "")
        d.once("dialog", lambda x: x.accept())
        if md.locator('[data-ce-act="delete"]').count():
            md.locator('[data-ce-act="delete"]').click()
            if d.locator(".modal [data-ok]").count():
                d.locator(".modal [data-ok]").last.click()
        d.wait_for_timeout(1500)
        summary["dm_draft_deleted"] = d.locator(".modal [data-ce-form]").count() == 0

        # stranger: denied
        st = Session(b, "stranger")
        r = rpc(st, "adjust_character_coins", p_character=solo, p_mode="gain", p_amount={"gp": 100})
        check("PP-23 an unrelated player cannot change the coins (42501)", r["error"] and r["error"]["code"] == "42501", r)
        r = rpc(st, "get_character_resources", p_character=hero)
        check("PP-24 an unrelated player cannot read the counters", bool(r["error"]), r)
        secret = [s for s in base.SECRETS if s in pl.text()]
        check("PP-25 no hidden data on the player's page", not secret, secret)
        page.locator("#btn-signout").click(); page.wait_for_selector("input[name=email]", timeout=15000)
        keys = page.evaluate("() => Object.keys(localStorage).filter((k) => /^tavern-ledger:(list|bundle:|cardstats:)/.test(k))")
        check("PP-26 sign-out leaves no user data", not keys, keys)
        errs = [e for e in pl.errors + dm.errors if "Failed to load resource" not in e]
        check("PP-27 no console errors", not errs, errs[:3])
        b.close()
    summary["passed"], summary["failed"] = sum(results), len(results) - sum(results)
    print(json.dumps(summary, indent=1))
    if OUT:
        with open(OUT, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=1)


if __name__ == "__main__":
    run()
