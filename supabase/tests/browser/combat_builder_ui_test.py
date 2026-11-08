"""Combat Builder, browser suite (docs/COMBAT_BUILDER_TESTING.md). LOCAL ONLY, synthetic users inside isolation.

Covers navigation and access, Combat Home, the encounter builder (party, Monster Library with SRD 5.2.1 / 5.1 and filters,
initiative table, ties, Start), the live tracker (turns, round, keyboard, HP with duplicate-click protection, preview,
conditions, advantage, concentration, legendary actions, hidden monsters, Undo, Previous turn, pause / resume, finish and
summary), Realtime between two DM windows and a player's sheet in both directions, the homebrew quick creature editor, the
sheet's atomic Damage button, reconnect banner, responsive layouts (1920 / 1366 / 1024 / 820 / 390 / 360) and accessibility
basics. Screenshots go to SCREENSHOT_DIR (outside the repository).
Usage: APP_URL=... python combat_builder_ui_test.py   (run_browser_local.sh sets the environment)
"""
import json
import re
import time
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, PW, RUN, SHOTS, Sheet, User, call, check, report

SHOTS.mkdir(parents=True, exist_ok=True)


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"cb_{name}.png"), full_page=False)


def q(sql):
    return iso.psql(sql)


class Win(Sheet):
    """A signed-in window (DM or player) without the sheet-specific waits."""

    def go(self, hash_, sel=None, timeout=20000):
        self.page.goto(f"{APP}{hash_}")
        if sel:
            self.page.wait_for_selector(sel, timeout=timeout)
        self.page.wait_for_timeout(400)


def hp_of(cid):
    return q(f"select hp_current || '/' || hp_temp from public.characters where id = '{cid}'")


def p_hp(pid):
    return q(f"select hp_current || '/' || hp_temp from public.combat_participants where id = '{pid}'")


def pid_by(enc, name, label=None):
    lab = f"= '{label}'" if label else "is null"
    return q(f"select id from public.combat_participants where encounter_id = '{enc}' and display_name = '{name}' and instance_label {lab} and removed_at is null limit 1")


WIDE_JS = """() => { const vw = document.documentElement.clientWidth; const inScroll = (e) => { for (let a = e.parentElement; a && a !== document.body; a = a.parentElement) { const o = getComputedStyle(a).overflowX; if (o === 'auto' || o === 'scroll' || o === 'hidden') return true; } return false; };
  return [...document.querySelectorAll('body *')].filter((e) => e.getBoundingClientRect().right > vw + 1 && !inScroll(e)).sort((a, b) => b.getBoundingClientRect().right - a.getBoundingClientRect().right)
  .slice(0, 6).map((e) => e.tagName + '.' + [...e.classList].join('.') + '[' + (e.dataset.cb || e.textContent.trim().slice(0, 20)) + ']:' + Math.round(e.getBoundingClientRect().right)); }"""

CHAIN_JS = """() => { const out = []; let e = document.querySelector('.cb-init-table'); while (e && e !== document.body) { const cs = getComputedStyle(e);
  out.push(e.tagName + '.' + [...e.classList].join('.') + ' w=' + e.clientWidth + ' sw=' + e.scrollWidth + ' ' + cs.display + ' ov=' + cs.overflowX); e = e.parentElement; } return out; }"""


def run(t):
    dm, pl, other = User("cbdm"), User("cbpl"), User("cbot")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'UI Combat Campaign {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');")
    heroes = []
    for i, (nm, dex) in enumerate([("Aria", 16), ("Bram", 12), ("Cora", 14), ("Dain", 10)]):
        cid = pl.character(f"{nm} {RUN}", [("fighter-phb", 3)], dexterity=dex, hp_max=30, hp_current=30)
        call("PATCH", f"/rest/v1/characters?id=eq.{cid}", {"campaign_id": camp}, token=pl.jwt)
        heroes.append(cid)
    t.note(campaign=camp, heroes=heroes)

    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)

        # ------------------------------------------------------------------------------------------------ access
        P = Win(b, pl, width=1366, height=900)
        page = P.page
        page.wait_for_timeout(800)
        check("N1 a player sees no Combat link", not page.locator("#combat-link").is_visible())
        P.go("#/combat")
        page.wait_for_timeout(800)
        check("N2 a player's direct #/combat goes back home", "#/combat" not in page.url, page.url)
        st, body = call("POST", "/rest/v1/rpc/combat_list_encounters", {"p_campaign": camp}, token=pl.jwt)
        check("N3 the API refuses the player", st in (401, 403) or "42501" in str(body), (st, str(body)[:200]))
        D = Win(b, dm, width=1366, height=900)
        dp = D.page
        dp.wait_for_timeout(800)
        check("N4 the DM sees Combat beside DM Space", dp.locator("#combat-link").is_visible() and dp.locator("#dm-link").is_visible())
        dp.locator("#combat-link").click()
        dp.wait_for_selector(".cb .cb-title", timeout=15000)
        dp.wait_for_timeout(600)
        check("H1 Combat Home with its sections", dp.locator(".cb-section").count() >= 3 and "Prepared encounters" in dp.inner_text(".cb"))
        shot(dp, "home_empty_1366")

        # ------------------------------------------------------------------------------------------------ create
        dp.locator("[data-cb=new]").click()
        md = dp.locator(".modal")
        md.locator("[name=name]").fill(f"Ford ambush {RUN}")
        md.locator("[name=campaign]").select_option(camp)
        check("B1 campaign default ruleset explained", "Campaign default" in md.inner_text() and "2024" in md.locator("[data-cb-rs]").inner_text())
        md.locator("[data-ok]").click()
        dp.wait_for_selector(".cb-builder", timeout=15000)
        enc = dp.url.split("#/combat/e/")[1]
        t.note(encounter=enc)
        check("B2 encounter created as a draft with 2024 rules", q(f"select status || ruleset from public.combat_encounters where id = '{enc}'") == "draft2024")

        dp.locator("[data-cb=add-party]").click()
        dp.wait_for_selector(".modal .cb-pick input", timeout=10000)
        dp.locator(".modal [data-ok]").click()
        dp.wait_for_function("() => document.querySelectorAll('.cb-init-table tbody tr').length >= 4", timeout=15000)
        check("B3 four campaign characters added", q(f"select count(*) from public.combat_participants where encounter_id = '{enc}' and kind = 'character'") == "4")
        mods = q(f"select string_agg(initiative_mod::text, ',' order by display_name) from public.combat_participants where encounter_id = '{enc}' and kind = 'character'")
        check("B4 the sheet's Initiative modifiers (DEX 16 -> +3, 12 -> +1, 14 -> +2, 10 -> 0)", mods == "3,1,2,0", mods)

        # Monster Library
        dp.locator("[data-cb=add-monsters]").first.click()
        lib = dp.locator(".modal.cb-lib-modal")
        lib.wait_for(timeout=10000)
        dp.wait_for_function("() => document.querySelectorAll('.cb-lib-item').length > 20", timeout=15000)
        check("M1 the library lists SRD 5.2.1 and SRD 5.1", lib.locator(".cb-rules-2024").count() > 0 and lib.locator(".cb-rules-2014").count() > 0)
        check("M2 the CC-BY-4.0 attribution is shown", "System Reference Document 5.2.1" in lib.inner_text() and "creativecommons.org/licenses/by/4.0" in lib.inner_text())
        lib.locator("[data-q]").fill("goblin warrior")
        dp.wait_for_timeout(900)
        check("M3 search", lib.locator(".cb-lib-item").count() >= 1 and "Goblin Warrior" in lib.locator(".cb-lib-item").first.inner_text())
        lib.locator(".cb-lib-item").first.click()
        lib.locator("[data-add]").wait_for(timeout=10000)
        check("M4 preview: the stat block with its source", "Nimble Escape" in lib.inner_text() and "SRD 5.2.1" in lib.locator(".cb-sb-src").inner_text())
        shot(dp, "library_1366")
        lib.locator("[data-add] [name=qty]").fill("3")
        lib.locator("[data-add] button[type=submit]").click()
        ok = D.wait(lambda: q(f"select count(*) from public.combat_participants where encounter_id = '{enc}' and display_name = 'Goblin Warrior'") == "3", 10000)
        check("M5 add three copies (Goblin Warrior A, B, C)", ok and q(f"select string_agg(instance_label, '' order by instance_label) from public.combat_participants where encounter_id = '{enc}' and display_name = 'Goblin Warrior'") == "ABC")
        # filters
        lib.locator("[data-q]").fill("")
        lib.locator("[data-f=type]").select_option("undead")
        lib.locator("[data-f=source]").select_option("srd2024")
        dp.wait_for_timeout(900)
        txt = lib.locator("[data-count]").inner_text()
        check("M6 type + source filter (11 SRD 5.2.1 undead)", txt.startswith("11 "), txt)
        lib.locator("[data-f=type]").select_option("")
        lib.locator("[data-f=source]").select_option("")
        lib.locator("[data-f=legendary]").check()
        lib.locator("[data-f=rules]").select_option("2024")
        dp.wait_for_timeout(900)
        check("M7 legendary + rules filter (4)", lib.locator("[data-count]").inner_text().startswith("4 "), lib.locator("[data-count]").inner_text())
        lib.locator("[data-f=cr_min]").select_option("17")
        dp.wait_for_timeout(700)
        names = lib.locator(".cb-lib-item").all_inner_texts()
        check("M8 CR filter", all("CR 17" in n or "CR 21" in n or "CR 10" not in n for n in names) and any("Adult Red Dragon" in n for n in names), names[:4])
        lib.locator(".cb-lib-item", has_text="Adult Red Dragon").first.click()
        lib.locator("[data-add]").wait_for(timeout=10000)
        check("M9 legendary preview with lair uses", "Legendary Actions" in lib.inner_text() and "in lair" in lib.inner_text().lower())
        lib.locator("[data-add] [name=hidden]").check()
        lib.locator("[data-add] [name=lair]").check()
        lib.locator("[data-add] button[type=submit]").click()
        D.wait(lambda: pid_by(enc, "Adult Red Dragon") != "", 10000)
        dragon = pid_by(enc, "Adult Red Dragon")
        check("M10 hidden legendary dragon in its lair (4 uses)", q(f"select hidden::text || legendary_max from public.combat_participants where id = '{dragon}'") == "true4")
        fav = lib.locator(".cb-fav").first
        fav.click()
        dp.wait_for_timeout(600)
        check("M11 favorite", q(f"select count(*) from public.combat_monster_favorites where user_id = '{dm.id}'") == "1")
        # a 2014 creature in a 2024 encounter
        lib.locator("[data-f=cr_min]").select_option("")
        lib.locator("[data-f=legendary]").uncheck()
        lib.locator("[data-f=rules]").select_option("2014")
        lib.locator("[data-q]").fill("skeleton")
        dp.wait_for_timeout(900)
        lib.locator(".cb-lib-item").first.click()
        lib.locator("[data-add]").wait_for(timeout=10000)
        check("M12 a 2014 stat block is flagged in a 2024 encounter", "uses the 2014 rules" in lib.locator("[data-add]").inner_text())
        lib.locator("[data-add] button[type=submit]").click()
        D.wait(lambda: pid_by(enc, "Skeleton") != "", 10000)
        dp.locator(".modal [data-close]").last.click()
        dp.wait_for_timeout(800)
        check("M13 the badge stays on the row", dp.locator(".cb-badge-warn").count() >= 1)

        # ------------------------------------------------------------------------------------------------ initiative
        dp.locator("[data-cb=roll-monsters]").click()
        ok = D.wait(lambda: q(f"select count(*) from public.combat_participants where encounter_id = '{enc}' and kind = 'monster' and initiative is null") == "0", 10000)
        check("I1 Roll all monsters", ok)
        check("I2 the goblin group shares one roll", q(f"select count(distinct initiative) from public.combat_participants where encounter_id = '{enc}' and display_name = 'Goblin Warrior'") == "1")
        vals = {heroes[0]: 40, heroes[1]: 40, heroes[2]: 9, heroes[3]: 5}   # 40: no monster here can roll it (dragon max 32)
        for cid, v in vals.items():
            pid = q(f"select id from public.combat_participants where encounter_id = '{enc}' and linked_character_id = '{cid}'")
            inp = dp.locator(f"[data-cb-init='{pid}']")
            inp.fill(str(v))
            inp.press("Tab")
            D.wait(lambda: q(f"select initiative from public.combat_participants where id = '{pid}'") == str(v), 8000)
        dp.wait_for_timeout(800)
        check("I3 typed player values saved", q(f"select string_agg(initiative::text, ',' order by display_name) from public.combat_participants where encounter_id = '{enc}' and kind = 'character'") == "40,40,9,5")
        check("I4 ties highlighted in the builder", dp.locator(".cb-warn").count() >= 1)
        shot(dp, "initiative_setup_1366")
        D.ctx.set_default_timeout(10000)
        for w, h, nm in [(1920, 1080, "1920"), (1024, 768, "1024"), (390, 844, "390")]:
            dp.set_viewport_size({"width": w, "height": h})
            dp.wait_for_timeout(400)
            shot(dp, f"builder_{nm}")
            if w == 390:
                check("R1 builder: no horizontal page scroll at 390", D.overflow() <= 1, (D.overflow(), dp.evaluate(WIDE_JS), dp.evaluate(CHAIN_JS)))
        dp.set_viewport_size({"width": 1366, "height": 900})
        dp.locator("[data-cb=start]").click()
        dp.wait_for_selector(".modal [data-ties]", timeout=10000)
        check("I5 Start opens the tie review once", "Initiative 40" in dp.locator(".modal").inner_text())
        shot(dp, "tie_review")
        dp.locator(".modal [data-up]:not([disabled])").first.click()
        dp.locator(".modal [data-ok]").click()
        dp.wait_for_selector(".cb-live", timeout=15000)
        dp.wait_for_timeout(800)
        order = q(f"select string_agg(display_name, ',' order by initiative_order) from public.combat_participants where encounter_id = '{enc}' and initiative = 40")
        check("I6 the DM's tie order (Bram before Aria)", order.startswith(f"Bram {RUN}"), order)
        check("I7 Round 1, the highest Initiative acts first", dp.locator(".cb-round-num").inner_text() == "1"
              and dp.locator(".cb-row.cb-current").count() == 1)
        cur = dp.locator("[data-cb-current]").inner_text()
        top = q(f"select display_name || coalesce(' ' || instance_label, '') from public.combat_participants where encounter_id = '{enc}' order by initiative_order limit 1")
        check("I8 current turn = first in order", cur == top, (cur, top))
        check("A1 current turn not shown by colour only (arrow + label + aria-current)",
              dp.locator(".cb-row.cb-current[aria-current=step] .cb-now").count() == 1 and "▶" in dp.locator(".cb-row.cb-current .cb-turn-arrow").inner_text())
        shot(dp, "round1_1366")

        # ------------------------------------------------------------------------------------------------ turns
        gA = pid_by(enc, "Goblin Warrior", "A")
        rev0 = int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'"))
        dp.locator("[data-cb=next]").dblclick()
        dp.wait_for_timeout(1500)
        rev1 = int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'"))
        check("T1 a double click on Next moves one turn", rev1 == rev0 + 1, (rev0, rev1))
        check("T2 the live region announces the turn", "turn" in dp.locator("[data-cb-announce]").inner_text())
        dp.locator("body").click(position={"x": 5, "y": 5})
        dp.keyboard.press("n")
        D.wait(lambda: int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'")) == rev1 + 1, 6000)
        check("T3 N moves to the next turn", int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'")) == rev1 + 1)
        dp.keyboard.press("p")
        D.wait(lambda: int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'")) == rev1 + 2, 6000)
        check("T4 P goes back one turn", q(f"select current_participant_id from public.combat_encounters where id = '{enc}'")
              == q(f"select (after ->> 'current') from public.combat_events where encounter_id = '{enc}' and kind = 'turn_advanced' order by id limit 1"))

        for _ in range(12):   # move on until a player character has the turn (screenshot of a player's turn)
            if dp.locator(".cb-row.cb-current.cb-character").count():
                break
            r0 = int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'"))
            dp.locator("[data-cb=next]").click()
            D.wait(lambda: int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'")) > r0, 6000)
            dp.wait_for_timeout(300)
        check("T7 a player character's turn is highlighted the same way", dp.locator(".cb-row.cb-current.cb-character .cb-now").count() == 1)
        shot(dp, "player_turn_1366")
        for _ in range(12):   # and a monster's turn
            if dp.locator(".cb-row.cb-current.cb-monster").count():
                break
            r0 = int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'"))
            dp.locator("[data-cb=next]").click()
            D.wait(lambda: int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'")) > r0, 6000)
            dp.wait_for_timeout(300)
        check("T8 a monster's turn is highlighted the same way", dp.locator(".cb-row.cb-current.cb-monster .cb-now").count() == 1)
        shot(dp, "monster_turn_1366")

        # ------------------------------------------------------------------------------------------------ HP
        dp.locator(f".cb-row[data-pid='{gA}'] .cb-row-main").click()
        dp.wait_for_timeout(400)
        amt = dp.locator(f"[data-cb-amount='{gA}']")
        amt.fill("4")
        dp.wait_for_timeout(200)
        check("H1 damage preview before applying", "10 → 6" in dp.locator("[data-cb-preview]").inner_text(), dp.locator("[data-cb-preview]").inner_text())
        dp.locator("[data-cb=hp][data-op=damage]").dblclick()
        dp.wait_for_timeout(1500)
        check("H2 duplicate-click protection: 10 -> 6 once", p_hp(gA) == "6/0", p_hp(gA))
        check("H3 the row shows the new HP", "6/10" in dp.locator(f".cb-row[data-pid='{gA}']").inner_text())
        amt = dp.locator(f"[data-cb-amount='{gA}']")
        amt.fill("20")
        amt.press("Enter")
        D.wait(lambda: p_hp(gA) == "0/0", 6000)
        check("H4 Enter applies damage; at 0 a monster is Defeated", q(f"select defeated from public.combat_participants where id = '{gA}'") == "t"
              and "Defeated" in dp.locator(f".cb-row[data-pid='{gA}']").inner_text())
        dp.locator("[data-cb=undo]").click()
        D.wait(lambda: p_hp(gA) == "6/0", 6000)
        check("U1 Undo restores the last damage", p_hp(gA) == "6/0" and q(f"select defeated from public.combat_participants where id = '{gA}'") == "f")
        # quick popover on a player row
        hero0 = q(f"select id from public.combat_participants where encounter_id = '{enc}' and linked_character_id = '{heroes[0]}'")
        dp.locator(f".cb-row[data-pid='{hero0}'] [data-op=damage]").click()
        pop = dp.locator(".cb-pop input")
        pop.fill("7")
        pop.press("Enter")
        D.wait(lambda: hp_of(heroes[0]) == "23/0", 6000)
        check("H5 quick damage on a player changes the real character (30 -> 23)", hp_of(heroes[0]) == "23/0", hp_of(heroes[0]))
        check("H6 focus returns to the quick button", dp.evaluate("() => document.activeElement?.dataset?.focusKey || ''").startswith("qd:"))

        # player's sheet <-> tracker
        P.open(heroes[0])
        P.tab("play") if page.locator('.tab[data-tab="play"]').count() else None
        page.wait_for_timeout(600)
        check("S1 the sheet shows the tracker's damage", page.locator("#hp-card .hp-current").input_value() == "23")
        dp.locator(f".cb-row[data-pid='{hero0}'] [data-op=damage]").click()
        dp.locator(".cb-pop input").fill("3")
        dp.locator(".cb-pop input").press("Enter")
        ok = P.wait(lambda: page.locator("#hp-card .hp-current").input_value() == "20", 8000)
        check("S2 Realtime: DM damage reaches the open sheet without a reload", ok, page.locator("#hp-card .hp-current").input_value())
        page.locator("#hp-amount").fill("5")
        page.locator("[data-action=hp-damage]").click()
        ok = D.wait(lambda: "15/30" in dp.locator(f".cb-row[data-pid='{hero0}']").inner_text(), 8000)
        check("S3 the sheet's Damage (atomic RPC) reaches the tracker", ok and hp_of(heroes[0]) == "15/0", (hp_of(heroes[0]), dp.locator(f".cb-row[data-pid='{hero0}']").inner_text()[:80]))
        check("S4 the sheet keeps its message", "Took 5 damage" in P.toasts())

        # ------------------------------------------------------------------------------------------------ effects
        dp.locator(f".cb-row[data-pid='{hero0}'] .cb-row-main").click()
        dp.locator("[data-cb=effect][data-tab=condition]").click()
        em = dp.locator(".modal")
        em.locator(".cb-cond input[value=poisoned]").check()
        em.locator("[name=duration]").select_option("rounds")
        em.locator("[name=rounds]").fill("2")
        em.locator("[data-ok]").click()
        dp.wait_for_timeout(1200)
        check("C1 a condition chip with its duration", dp.locator(f".cb-row[data-pid='{hero0}'] .cb-chip-condition", has_text="Poisoned").count() == 1)
        dp.locator("[data-cb=adv][data-mode=advantage]").click()
        am = dp.locator(".modal")
        am.locator("[name=scope]").select_option("next_attack")
        am.locator("[data-ok]").click()
        dp.wait_for_timeout(900)
        dp.locator("[data-cb=adv][data-mode=disadvantage]").click()
        dp.locator(".modal [name=scope]").select_option("next_attack")
        dp.locator(".modal [data-ok]").click()
        dp.wait_for_timeout(900)
        check("C2 Advantage + Disadvantage on the same scope show as normal", "(both: normal)" in dp.locator(f".cb-row[data-pid='{hero0}']").inner_text())
        # concentration
        dp.locator("[data-cb=effect][data-tab=concentration]").click()
        dp.locator(".modal [name=conc_name]").fill("Bless")
        dp.locator(".modal [data-ok]").click()
        dp.wait_for_timeout(900)
        amt = dp.locator(f"[data-cb-amount='{hero0}']")
        amt.fill("6")
        dp.locator("[data-cb=hp][data-op=damage]").click()
        dp.wait_for_selector(".cb-conc-check", timeout=8000)
        check("C3 damage while concentrating: CON save DC 10 reminder", "DC 10" in dp.locator(".cb-conc-check").inner_text())
        shot(dp, "concentration_1366")
        dp.locator(".cb-conc-check [data-result=failure]").click()
        dp.wait_for_timeout(1000)
        check("C4 Failure ends the concentration", q(f"select count(*) from public.combat_effects where encounter_id = '{enc}' and effect_type = 'concentration' and active") == "0")

        # second DM window
        D2 = Win(b, dm, width=1366, height=900)
        D2.go(f"#/combat/e/{enc}", ".cb-live")
        before = D2.page.locator("[data-cb-current]").inner_text()
        dp.locator("[data-cb=next]").click()
        ok = D2.wait(lambda: D2.page.locator("[data-cb-current]").inner_text() != before, 8000)
        check("RT1 a second DM window follows the turn via Realtime", ok)
        trs = int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'"))
        D2.page.locator("[data-cb=next]").click()
        dp.wait_for_timeout(200)
        dp.evaluate("() => document.querySelector('[data-cb=next]').click()")
        dp.wait_for_timeout(2500)
        tre = int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'"))
        check("RT2 two windows clicking Next together: no double move beyond what each saw", tre in (trs + 1, trs + 2) and not [e for e in D2.errors if "pageerror" in e])
        D2.close()

        # reveal the dragon, legendary
        dp.locator(f".cb-row[data-pid='{dragon}'] .cb-row-main").click()
        dp.wait_for_timeout(400)
        dp.locator("[data-cb=load-statblock]").click()
        dp.wait_for_selector(".cb-detail .cb-sb", timeout=8000)
        dp.locator(".cb-leg [data-delta='-1']").first.click()
        D.wait(lambda: q(f"select legendary_left from public.combat_participants where id = '{dragon}'") == "3", 6000)
        check("L1 spend a Legendary Action use (4 -> 3)", q(f"select legendary_left from public.combat_participants where id = '{dragon}'") == "3")
        shot(dp, "legendary_hidden_1366")
        dp.locator("[data-cb=toggle-hidden]").click()
        D.wait(lambda: q(f"select hidden from public.combat_participants where id = '{dragon}'") == "f", 6000)
        check("L2 reveal a hidden monster", q(f"select hidden from public.combat_participants where id = '{dragon}'") == "f")

        # pause / resume
        dp.locator("[data-cb=pause]").click()
        dp.wait_for_selector(".cb-paused", timeout=8000)
        check("T5 Pause: Next disabled", dp.locator("[data-cb=next]").is_disabled())
        dp.locator("[data-cb=resume]").click()
        dp.wait_for_selector(".cb-live:not(.cb-paused)", timeout=8000)
        check("T6 Resume", q(f"select status from public.combat_encounters where id = '{enc}'") == "active")

        # responsive live views
        for w, h, nm in [(1920, 1080, "1920"), (1024, 768, "1024"), (820, 1180, "820"), (390, 844, "390"), (360, 800, "360")]:
            dp.set_viewport_size({"width": w, "height": h})
            dp.wait_for_timeout(500)
            shot(dp, f"live_{nm}")
            check(f"R{nm} live: no horizontal page scroll", D.overflow() <= 1, (D.overflow(), dp.evaluate(WIDE_JS)))
            if w <= 820:
                dp.locator(f".cb-row[data-pid='{gA}'] .cb-row-main").click()
                dp.wait_for_timeout(500)
                check(f"R{nm}b detail opens as a drawer", dp.locator(".cb-detail.cb-drawer-open").count() == 1)
                shot(dp, f"drawer_{nm}")
                dp.locator("[data-cb=close-drawer]").click()
                dp.wait_for_timeout(300)
        dp.set_viewport_size({"width": 1366, "height": 900})
        for w in (1366, 390):
            dp.set_viewport_size({"width": w, "height": 900})
            dp.wait_for_timeout(300)
            unnamed = dp.evaluate("""() => [...document.querySelectorAll('.cb button, .cb input, .cb select')].filter((e) => e.offsetParent !== null)
              .filter((e) => !(e.getAttribute('aria-label') || (e.labels && e.labels.length && e.labels[0].textContent.trim()) || (e.tagName === 'BUTTON' && e.textContent.trim()) || e.title))
              .map((e) => e.outerHTML.slice(0, 80))""")
            check(f"A3 every visible control has an accessible name ({w})", not unnamed, unnamed[:3])
        dp.set_viewport_size({"width": 1366, "height": 900})
        nb = dp.locator(".cb-dock [data-cb=next]").bounding_box()
        check("A2 the Next button is a large touch target", nb and nb["height"] >= 44, nb)

        # reconnect banner
        D.ctx.set_offline(True)
        dp.evaluate("() => window.dispatchEvent(new Event('offline'))")
        dp.wait_for_timeout(500)
        check("O1 offline: a read-only banner, controls marked disabled", dp.locator("[data-cb-banner]").is_visible() and dp.locator(".cb.cb-offline").count() == 1)
        shot(dp, "offline_1366")
        before = int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'"))
        dp.evaluate("() => document.querySelector('[data-cb=next]').click()")
        dp.wait_for_timeout(800)
        check("O2 nothing is sent offline", int(q(f"select turn_rev from public.combat_encounters where id = '{enc}'")) == before)
        D.ctx.set_offline(False)
        dp.evaluate("() => window.dispatchEvent(new Event('online'))")
        dp.wait_for_timeout(1500)
        check("O3 back online", dp.locator("[data-cb-banner]").is_hidden())

        # homebrew quick creature
        dp.locator("[data-cb=add-monsters]").first.click()
        dp.locator(".modal [data-new-creature]").click()
        ed = dp.locator(".modal.cb-ed-modal")
        ed.wait_for(timeout=8000)
        ed.locator("[data-p=name]").fill(f"Reed Lurker {RUN}")
        ed.locator("[data-p='d.hit_points']").fill("26")
        ed.locator("[data-p='d.armor_class']").fill("13")
        ed.locator("[data-p='d.actions.0.name']").fill("Claw")
        ed.locator("[data-publish]").click()
        dp.wait_for_timeout(2000)
        check("HB1 publishing without to-hit and damage shows friendly errors", "to-hit" in ed.inner_text() and "damage formula" in ed.inner_text(), ed.locator("[data-errors]").inner_text()[:200])
        shot(dp, "homebrew_editor_1366")
        ed.locator("[data-p='d.actions.0.attack_bonus']").fill("5")
        ed.locator("[data-p='d.actions.0.damage.0.dice']").fill("1d8+3")
        ed.locator("[data-publish]").click()
        ok = D.wait(lambda: q(f"select count(*) from public.creatures where name = 'Reed Lurker {RUN}' and campaign_id = '{camp}'") == "1", 10000)
        check("HB2 a quick creature is published to the campaign", ok)
        lib = dp.locator(".modal.cb-lib-modal")
        lib.locator("[data-f=rules]").select_option("")
        lib.locator("[data-q]").fill("Reed Lurker")
        dp.wait_for_timeout(1000)
        check("HB3 it appears in the library as homebrew", "Homebrew" in lib.locator(".cb-lib-list").inner_text())
        lib.locator(".cb-lib-item").first.click()
        lib.locator("[data-add]").wait_for(timeout=8000)
        lib.locator("[data-add] [name=init]").fill("12")
        lib.locator("[data-add] button[type=submit]").click()
        D.wait(lambda: pid_by(enc, f"Reed Lurker {RUN}") != "", 8000)
        check("HB4 a late homebrew combatant joins at its Initiative", q(f"select initiative from public.combat_participants where id = '{pid_by(enc, f'Reed Lurker {RUN}')}'") == "12")
        dp.locator(".modal [data-close]").last.click()
        dp.wait_for_timeout(600)

        # history, help
        dp.locator("[data-cb=history]").click()
        dp.wait_for_selector(".modal .cb-hist li", timeout=8000)
        check("HI1 history lists the events", dp.locator(".modal .cb-hist li").count() > 10)
        dp.keyboard.press("Escape")
        dp.locator("[data-cb=help]").click()
        check("K1 shortcuts listed", "Next turn" in dp.locator(".modal").inner_text())
        dp.keyboard.press("Escape")
        dp.wait_for_timeout(300)

        # finish
        dp.locator("[data-cb=finish]").click()
        dp.locator(".modal [data-n]").fill("The goblins fled.")
        dp.locator(".modal [data-ok]").click()
        dp.wait_for_selector(".modal [data-d], .cb-summary .cb-sum-stats", timeout=15000)
        review = dp.locator(".modal [data-d]")
        check("F0 lasting effects on characters are reviewed before finishing", review.count() >= 1)
        if review.count():
            first = review.first
            carried = first.get_attribute("data-d")
            if first.locator("option[value=carry]").count():
                first.select_option("carry")
            dp.locator(".modal [data-ok]").last.click()
        dp.wait_for_selector(".cb-summary .cb-sum-stats", timeout=15000)
        check("F1 finish -> summary", q(f"select status from public.combat_encounters where id = '{enc}'") == "completed")
        check("F2 player HP kept as it was", hp_of(heroes[0]) == "9/0" or int(hp_of(heroes[0]).split('/')[0]) < 30, hp_of(heroes[0]))
        dp.wait_for_timeout(800)
        shot(dp, "summary_1366")
        check("F3 summary shows participants and history", dp.locator(".cb-summary table tbody tr").count() >= 8 and dp.locator(".cb-summary .cb-hist li").count() > 5)
        dp.locator("[data-cb=duplicate]").first.click()
        dp.wait_for_selector(".cb-builder", timeout=15000)
        check("F4 run again: a fresh prepared copy", "draft" == q(f"select status from public.combat_encounters where source_encounter_id = '{enc}'"))
        dp.goto(f"{APP}#/combat")
        dp.wait_for_selector(".cb-card", timeout=10000)
        shot(dp, "home_1366")
        check("H7 Combat Home lists prepared and finished encounters", dp.locator(".cb-card-completed").count() >= 1 and dp.locator(".cb-card-draft").count() >= 1)

        # error and loading states
        dp.goto(f"{APP}#/combat/e/{uuid.uuid4()}")
        dp.wait_for_selector(".cb-error", timeout=10000)
        check("E1 an unknown encounter shows a friendly error with Retry", "Retry" in dp.locator(".cb-error").inner_text()
              and "not the DM" in dp.locator(".cb-error").inner_text())
        shot(dp, "error_1366")
        cdp = dp.context.new_cdp_session(dp)
        cdp.send("Network.enable")
        cdp.send("Network.emulateNetworkConditions", {"offline": False, "latency": 1500, "downloadThroughput": -1, "uploadThroughput": -1})
        dp.goto(f"{APP}#/combat")
        dp.wait_for_selector(".cb .spinner", timeout=10000)
        check("E2 loading state: a spinner with an accessible label while the list loads", dp.locator(".cb .spinner[aria-label]").count() >= 1)
        shot(dp, "loading_1366")
        cdp.send("Network.emulateNetworkConditions", {"offline": False, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1})
        dp.wait_for_selector(".cb-card", timeout=20000)
        dp.evaluate("() => console.clear && 0")
        D.errors[:] = [e for e in D.errors if "Encounter not found" not in e and "42501" not in e]
        errs = [e for e in D.errors + P.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not D.remote and not P.remote, (D.remote + P.remote)[:3])
        D.close(); P.close(); b.close()


if __name__ == "__main__":
    with iso.Isolated("COMBAT-BUILDER-UI") as t:
        run(t)
    report()
