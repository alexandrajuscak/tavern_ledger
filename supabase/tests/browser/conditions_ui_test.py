"""DM conditions and tags on the main character sheet, outside combat (20261112000200, docs/HIDDEN_DM_DATA.md "Conditions and
tags on the sheet"). LOCAL ONLY, synthetic users inside isolation.

Covers: the DM adds a visible "Resistant to fire" tag (note, duration) and a HIDDEN curse from the sheet's "+ Condition"
picker; the DM sees both (the hidden one marked); the player's open sheet shows the visible tag live (no reload) and never the
hidden one: not in the DOM, not in any API response, not in any Realtime frame, and the hidden change delivers no Realtime
event at all; the player cannot remove the DM's tag; after a reload (fluent) and on ?fluent=0 the player still sees only the
visible tag; the DM reveals the curse and the player sees it live.
Usage: APP_URL=... python conditions_ui_test.py   (run_browser_local.sh sets the environment)
"""
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import ANON, APP, RUN, SHOTS, Sheet, User, call, check, report

SHOTS.mkdir(parents=True, exist_ok=True)
q = iso.psql
SECRET = f"Lich curse {RUN}"
SECRET_NOTE = f"Whispers {RUN}"


def run(t):
    dm, pl = User("cndm"), User("cnpl")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'CN Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    ch = pl.character(f"CN Hero {RUN}", [("fighter-phb", 1)])
    q(f"update public.characters set campaign_id = '{camp}' where id = '{ch}'; insert into public.character_governance (character_id, setup_complete) values ('{ch}', true);")
    t.note(character=ch)

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        P = Sheet(br, pl, tab="combat")
        pp = P.page
        seen = {"bodies": [], "frames": []}

        def on_response(r):
            if "/rest/v1/" in r.url:
                try:
                    seen["bodies"].append(r.text())
                except Exception:
                    pass
        pp.on("response", on_response)
        pp.on("websocket", lambda ws: ws.on("framereceived", lambda f: seen["frames"].append(f if isinstance(f, str) else str(f))))
        P.open(ch)
        P.wait(lambda: pp.locator("#conditions-row .condition-add").count() == 1)
        pp.wait_for_timeout(1500)   # the Realtime channel joins

        D = Sheet(br, dm, tab="combat")
        dp = D.page
        D.open(ch)
        D.wait(lambda: dp.locator("#conditions-row .condition-add").count() == 1)

        def dm_add_tag(tag_type, name, note="", duration="", hidden=False, damage=None):
            dp.locator("#conditions-row .condition-add").click()
            dp.wait_for_selector(".modal #cond-form")
            dp.select_option(".modal select[name=tag_type]", tag_type)
            if damage:
                dp.select_option(".modal select[name=damage_type_id]", damage)
            dp.fill(".modal input[name=name]", name)
            dp.fill(".modal input[name=note]", note)
            dp.fill(".modal input[name=duration_text]", duration)
            if hidden:
                dp.check(".modal input[name=hidden]")
            dp.locator(".modal [data-add-tag]").click()
            D.wait(lambda: dp.locator(".modal #cond-form").count() == 0)

        # ---- visible tag: live on the player's sheet
        dm_add_tag("resistance", "", note="Potion of Fire Resistance", duration="1 hour", damage="fire")
        D.wait(lambda: "Resistant to fire" in dp.locator("#conditions-row").inner_text())
        check("C1 the DM adds a resistance tag on the main tab (outside combat)", "Resistant to fire" in dp.locator("#conditions-row").inner_text())
        ok = P.wait(lambda: "Resistant to fire" in pp.locator("#conditions-row").inner_text(), 12000)
        check("C2 the player's open sheet shows it live (no reload), with its duration",
              ok and "1 hour" in pp.locator("#conditions-row").inner_text(), pp.locator("#conditions-row").inner_text())

        # ---- hidden tag: nothing reaches the player
        pp.wait_for_timeout(1000)
        warm = ["get_character_derived_stats", "get_character_proficiencies"]
        pl.rpc("get_character_reads", p_character=ch, p_reads=warm)   # stores the player's cache entries
        frames_before = len(seen["frames"])
        check("LK-B0 the frame capture works: the VISIBLE change arrived as postgres_changes frames",
              any("postgres_changes" in f and "character_revisions" in f for f in seen["frames"]))
        dm_add_tag("curse", SECRET, note=SECRET_NOTE, hidden=True)
        D.wait(lambda: SECRET in dp.locator("#conditions-row").inner_text())
        check("C3 the DM sees the hidden curse, marked hidden (dashed chip, secret icon)",
              dp.locator('#conditions-row .condition-chip.is-hidden[data-hidden="1"]').count() == 1
              and dp.locator('#conditions-row .condition-chip.is-hidden [data-icon="ui.dm-secret"]').count() == 1)
        dp.screenshot(path=str(SHOTS / "conditions_dm.png"))
        pp.wait_for_timeout(4000)
        new_frames = seen["frames"][frames_before:]
        stc, after = pl.rpc("get_character_reads", p_character=ch, p_reads=warm)
        check("LK-B5 the hidden change left the player's cached reads valid (no cache-hit drop)",
              stc == 200 and after["cache"]["hits"] == 2, after.get("cache") if isinstance(after, dict) else after)
        check("LK-B1 the player's DOM never shows the hidden curse", SECRET not in pp.content() and SECRET_NOTE not in pp.content())
        check("LK-B2 no Realtime frame for the hidden change (no postgres_changes event at all)",
              not [f for f in new_frames if "postgres_changes" in f], [f[:200] for f in new_frames if "postgres_changes" in f][:3])
        check("LK-B3 no API response or Realtime frame ever carried the hidden name or note",
              not [b for b in seen["bodies"] + seen["frames"] if SECRET in b or SECRET_NOTE in b])

        # ---- the same through the API with the player's own token (PostgREST table select, secrets, RPC, cached reads)
        st1, rows = call("GET", f"/rest/v1/character_conditions?character_id=eq.{ch}&select=*", token=pl.jwt, key=ANON)
        st2, secrets = call("GET", "/rest/v1/character_condition_secrets?select=*", token=pl.jwt, key=ANON)
        st3, own = pl.rpc("get_character_conditions", p_character=ch)
        reads = [pl.rpc("get_character_reads", p_character=ch, p_reads=["get_character_conditions", "characters", "get_character_derived_stats", "revisions"])
                 for _ in range(2)]
        check("LK-B4 REST select / secrets / RPC / get_character_reads (twice: miss, then hit) as the player: no hidden row",
              st1 == 200 and len(rows) == 1 and not any(r["hidden"] for r in rows) and st2 == 200 and secrets == [] and st3 == 200
              and all(s == 200 for s, _ in reads) and reads[1][1]["cache"]["hits"] >= 1
              and SECRET not in str(rows) + str(own) + str(reads), (st1, rows, st2, secrets, [r[1].get("cache") for r in reads]))

        # ---- the player cannot remove the DM's tag
        pp.locator("#conditions-row .condition-chip", has_text="Resistant to fire").click()
        pp.wait_for_selector(".modal")
        mt = pp.locator(".modal").inner_text()
        check("C4 the player sees the DM's note and duration, read-only, without Remove",
              "Potion of Fire Resistance" in mt and "Applied by your DM" in mt and pp.locator(".modal [data-remove]").count() == 0
              and pp.locator(".modal [data-save]").count() == 0, mt[:300])
        pp.screenshot(path=str(SHOTS / "conditions_player.png"))
        pp.keyboard.press("Escape")

        # ---- reload (fluent) and the legacy path
        P.open(ch)
        P.wait(lambda: "Resistant to fire" in pp.locator("#conditions-row").inner_text())
        check("C5 after a reload (fluent read) the player sees only the visible tag",
              "Resistant to fire" in pp.locator("#conditions-row").inner_text() and SECRET not in pp.content())
        pp.goto(f"{APP}?fluent=0#/c/{ch}")
        P.wait(lambda: "Resistant to fire" in pp.locator("#conditions-row").inner_text())
        check("C6 ?fluent=0: the visible tag shows, the hidden one does not",
              "Resistant to fire" in pp.locator("#conditions-row").inner_text() and SECRET not in pp.content()
              and pp.locator(".sheet-root").get_attribute("data-read-path") == "legacy")
        pp.goto(f"{APP}?fluent=default#/c/{ch}")
        P.wait(lambda: pp.locator("#conditions-row .condition-add").count() == 1)
        pp.wait_for_timeout(1500)
        home = q(f"select conditions::text from public.characters where id = '{ch}'")
        check("C7 the home card / export list (characters.conditions mirror) holds only the visible tag", "Resistant to fire" in home and SECRET not in home, home)

        # ---- reveal: the player sees it live
        dp.locator("#conditions-row .condition-chip.is-hidden").click()
        dp.wait_for_selector(".modal #cond-edit")
        dp.uncheck(".modal input[name=hidden]")
        dp.locator(".modal [data-save]").click()
        D.wait(lambda: dp.locator("#conditions-row .condition-chip.is-hidden").count() == 0)
        ok = P.wait(lambda: SECRET in pp.locator("#conditions-row").inner_text(), 12000)
        check("C8 revealed by the DM: the player's sheet shows the curse live", ok)

        errs = [e for e in P.errors + D.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not P.remote and not D.remote, (P.remote + D.remote)[:3])
        P.ctx.close(); D.ctx.close(); br.close()


if __name__ == "__main__":
    with iso.Isolated("CONDITIONS-UI") as t:
        run(t)
    report()
