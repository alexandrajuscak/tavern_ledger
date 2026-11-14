"""Combat Builder performance probe (docs/COMBAT_BUILDER_TESTING.md "Performance"). LOCAL ONLY, synthetic data in isolation.

LARGE encounter: 6 player characters, 12 goblins in groups, a hidden reinforcement, a legendary dragon, several effects.
Measures, per profile (local / 4x CPU + 50 ms / 4x CPU + 150 ms / 4x CPU + 300 ms latency): Combat Home, encounter open,
Next Turn, HP change feedback, condition, stat block, monster search; RPC requests per open and Realtime channels; then one
DM and six open player sheets (HP propagation). Prints a JSON summary; checks only generous ceilings (not a benchmark gate).
"""
import json
import time
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, Sheet, User, call, check, report

PROFILES = [("local", 1, 0), ("cpu4_lat50", 4, 50), ("cpu4_lat150", 4, 150), ("cpu4_lat300", 4, 300)]


def ms(t0):
    return round((time.time() - t0) * 1000)


def throttle(page, cpu, latency):
    cdp = page.context.new_cdp_session(page)
    cdp.send("Emulation.setCPUThrottlingRate", {"rate": cpu})
    cdp.send("Network.enable")
    cdp.send("Network.emulateNetworkConditions", {"offline": False, "latency": latency, "downloadThroughput": -1, "uploadThroughput": -1})
    return cdp


def run(t):
    dm, pl = User("cbperf-dm"), User("cbperf-pl")
    camp = str(uuid.uuid4())
    iso.psql(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'UI Combat Perf {RUN}', '{dm.id}');"
             f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');")
    heroes = []
    for i in range(6):
        cid = pl.character(f"Perf Hero {i} {RUN}", [("fighter-phb", 5)], dexterity=10 + i, hp_max=200, hp_current=200)
        call("PATCH", f"/rest/v1/characters?id=eq.{cid}", {"campaign_id": camp}, token=pl.jwt)
        heroes.append(cid)
    _, r = dm.rpc("combat_create_encounter", p_campaign=camp, p_name="Perf battle", p_ruleset="2024")
    enc = r["encounter"]["id"]
    dm.rpc("combat_add_characters", p_encounter=enc, p_characters=heroes)
    for q in (4, 4, 4):
        dm.rpc("combat_add_monsters", p_encounter=enc, p_source_kind="srd2024", p_source_id="srd52-goblin-warrior", p_options={"quantity": q, "group": "shared"})
    dm.rpc("combat_add_monsters", p_encounter=enc, p_source_kind="srd2024", p_source_id="srd52-adult-red-dragon", p_options={"in_lair": True})
    dm.rpc("combat_add_monsters", p_encounter=enc, p_source_kind="srd2024", p_source_id="srd52-ogre", p_options={"hidden": True, "joins_round": 3})
    dm.rpc("combat_roll_initiative", p_encounter=enc, p_participants=None, p_options={"reroll": True})
    ids = iso.psql(f"select string_agg(id::text, ',') from public.combat_participants where encounter_id = '{enc}' and kind = 'character'").split(",")
    dm.rpc("combat_set_initiative", p_encounter=enc, p_values=[{"id": x, "initiative": 5 + i} for i, x in enumerate(ids)])
    _, st = dm.rpc("combat_start", p_encounter=enc, p_accept_ties=True)
    for i, x in enumerate(ids[:3]):
        dm.rpc("combat_add_effect", p_encounter=enc, p_effect={"effect_type": "condition", "condition_key": ["poisoned", "prone", "frightened"][i], "target": x,
                                                               "duration_type": "rounds", "duration_rounds": 10})
    check("P0 large fixture running (6 PCs, 14 monsters)", iso.psql(f"select status || count(p.*) from public.combat_encounters e join public.combat_participants p on p.encounter_id = e.id where e.id = '{enc}' group by status") == "active20")
    out = {}
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        for name, cpu, lat in PROFILES:
            s = Sheet(b, dm, width=1366, height=900)
            page = s.page
            page.wait_for_timeout(500)
            rpcs = []
            page.on("request", lambda r: rpcs.append(r.url) if "/rest/v1/rpc/" in r.url else None)
            throttle(page, cpu, lat)
            m = {}
            t0 = time.time(); page.goto(f"{APP}#/combat"); page.wait_for_selector(".cb-card", timeout=60000); m["home_ms"] = ms(t0)
            rpcs.clear()
            t0 = time.time(); page.goto(f"{APP}#/combat/e/{enc}"); page.wait_for_selector(".cb-live .cb-row", timeout=60000); m["open_shell_ms"] = ms(t0)
            page.wait_for_function("() => document.querySelectorAll('.cb-row').length >= 20", timeout=60000); m["open_list_ms"] = ms(t0)
            page.wait_for_timeout(2500)
            m["rpc_on_open"] = len(rpcs)
            m["rpc_names_on_open"] = sorted({u.split("/rpc/")[1].split("?")[0] for u in rpcs})
            m["channels"] = page.evaluate("async () => { const m = await import('./js/supabase.js?v=36'); return m.supabase.getChannels().map((c) => c.topic); }")
            before = page.locator("[data-cb-current]").inner_text()
            t0 = time.time(); page.locator("[data-cb=next]").click()
            page.wait_for_function("(b) => document.querySelector('[data-cb-current]')?.textContent !== b", arg=before, timeout=60000); m["next_turn_ms"] = ms(t0)
            gob = iso.psql(f"select id from public.combat_participants where encounter_id = '{enc}' and display_name = 'Goblin Warrior' and instance_label = 'B'")
            page.locator(f".cb-row[data-pid='{gob}'] [data-op=damage]").click()
            page.locator(".cb-pop input").fill("1")
            t0 = time.time(); page.locator(".cb-pop input").press("Enter")
            page.wait_for_function("(id) => /\\b(9|8|7|6|5|4|3|2|1|0)\\/10\\b/.test(document.querySelector(`.cb-row[data-pid='${id}']`)?.textContent || '')", arg=gob, timeout=60000)
            m["hp_feedback_ms"] = ms(t0)
            page.locator(f".cb-row[data-pid='{gob}'] .cb-row-main").click()
            page.wait_for_timeout(300)
            page.locator("[data-cb=effect][data-tab=condition]").click()
            page.locator(".modal .cb-cond input[value=restrained]").check()
            t0 = time.time(); page.locator(".modal [data-ok]").click()
            page.wait_for_selector(f".cb-row[data-pid='{gob}'] .cb-chip-condition", timeout=60000); m["condition_ms"] = ms(t0)
            t0 = time.time(); page.locator("[data-cb=load-statblock]").click(); page.wait_for_selector(".cb-detail .cb-sb", timeout=60000); m["statblock_ms"] = ms(t0)
            page.locator("[data-cb=add-monsters]").first.click()
            t0 = time.time(); page.wait_for_selector(".modal .cb-lib-item", timeout=60000); m["library_open_ms"] = ms(t0)
            t0 = time.time(); page.locator(".modal [data-q]").fill("dragon")
            page.wait_for_function("() => [...document.querySelectorAll('.cb-lib-item')].length && [...document.querySelectorAll('.cb-lib-item')].every((x) => /dragon/i.test(x.textContent))", timeout=60000)
            m["search_ms"] = ms(t0)
            m["errors"] = [e for e in s.errors if "Failed to load resource" not in e][:3]
            out[name] = m
            s.close()
            print(name, json.dumps(m))

        # one DM and six players with their sheets open: HP propagation
        players = []
        for cid in heroes:
            ps = Sheet(b, pl, width=900, height=800)
            ps.open(cid)
            players.append((cid, ps))
        d = Sheet(b, dm, width=1366, height=900)
        d.page.goto(f"{APP}#/combat/e/{enc}")
        d.page.wait_for_selector(".cb-live .cb-row", timeout=30000)
        d.page.wait_for_timeout(1500)
        lat = []
        for cid, ps in players:
            pid = iso.psql(f"select id from public.combat_participants where encounter_id = '{enc}' and linked_character_id = '{cid}'")
            want = str(int(iso.psql(f"select hp_current from public.characters where id = '{cid}'")) - 2)
            d.page.locator(f".cb-row[data-pid='{pid}'] [data-op=damage]").click()
            d.page.locator(".cb-pop input").fill("2")
            t0 = time.time(); d.page.locator(".cb-pop input").press("Enter")
            ok = ps.wait(lambda: ps.page.locator("#hp-card .hp-current").input_value() == want, 15000)
            lat.append(ms(t0) if ok else None)
        out["dm_plus_6_players_sheet_update_ms"] = lat
        out["dm_plus_6_channels_per_dm_window"] = len(d.page.evaluate("async () => { const m = await import('./js/supabase.js?v=36'); return m.supabase.getChannels(); }"))
        print("dm+6", json.dumps(lat))
        for _, ps in players:
            ps.close()
        d.close()
        b.close()
    t.note(perf=out)
    loc, slow = out["local"], out["cpu4_lat300"]
    check("PF1 encounter list visible locally under 1.5 s", loc["open_list_ms"] < 1500, loc["open_list_ms"])
    check("PF2 Next Turn locally under 500 ms", loc["next_turn_ms"] < 500, loc["next_turn_ms"])
    check("PF3 HP feedback locally under 500 ms", loc["hp_feedback_ms"] < 500, loc["hp_feedback_ms"])
    check("PF4 one Realtime channel for the encounter", len([c for c in loc["channels"] if "combat-" in c]) == 1, loc["channels"])
    # one encounter read + one cached summary read per linked character (after first paint, three at a time)
    check("PF5 no request storm on open (1 + one per player character)", loc["rpc_on_open"] <= 1 + len(heroes)
          and set(loc["rpc_names_on_open"]) <= {"combat_get_encounter", "get_character_reads"}, (loc["rpc_on_open"], loc["rpc_names_on_open"]))
    check("PF6 300 ms latency + 4x CPU: list usable under 4 s, Next under 1.5 s", slow["open_list_ms"] < 4000 and slow["next_turn_ms"] < 1500, slow)
    check("PF7 six player sheets all receive the DM's HP change", all(x is not None for x in out["dm_plus_6_players_sheet_update_ms"]), out["dm_plus_6_players_sheet_update_ms"])
    check("PF8 no console errors", not any(out[k]["errors"] for k, _, _ in [(n, 0, 0) for n, _, _ in PROFILES]), [out[n]["errors"] for n, _, _ in PROFILES])
    print("SUMMARY " + json.dumps(out))


if __name__ == "__main__":
    with iso.Isolated("COMBAT-PERF") as t:
        run(t)
    report()
