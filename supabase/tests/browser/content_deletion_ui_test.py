"""DM Space usage dialog: where content is used, and deleting archived content that only has history (20261112000100,
docs/CONTENT_MANAGEMENT.md). LOCAL ONLY, synthetic users inside isolation.

Covers: a custom item in a character inventory and in the party stash: the Usage dialog says Delete blocked and lists both
places (character name with a link, stash name) with the next step, and offers no Delete; after the item is removed from both
and archived, the dialog says "Deletable, history kept", splits History (kept) from In use, does not say "archive it", and
Delete permanently with the typed name removes it while its inventory history stays with the name stamped.
Usage: APP_URL=... python content_deletion_ui_test.py   (run_browser_local.sh sets the environment)
"""
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, check, report

SHOTS.mkdir(parents=True, exist_ok=True)
q = iso.psql


def run(t):
    dm, pl = User("cddm"), User("cdpl")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'CD Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');"
      f"insert into public.inventories (kind, name, campaign_id) values ('party_stash', 'CD Hoard', '{camp}');")
    hero = f"CD Hero {RUN}"
    ch = pl.character(hero, [("fighter-phb", 1)])
    q(f"update public.characters set campaign_id = '{camp}' where id = '{ch}'; insert into public.character_governance (character_id, setup_complete) values ('{ch}', true);")
    st, c = dm.rpc("duplicate_official_as_homebrew", p_type="item", p_ref="longsword", p_campaign=camp)
    cid = c["id"]
    dm.rpc("publish_dm_content", p_content=cid, p_expected_version=None)
    ref = q(f"select v.catalog_ref from public.dm_content d join public.dm_content_versions v on v.id = d.published_version_id where d.id = '{cid}'")
    st1, a1 = dm.rpc("dm_assign_content", p_content=cid, p_characters=[ch], p_mode="inventory", p_options={})
    st2, a2 = dm.rpc("dm_assign_content", p_content=cid, p_characters=[ch], p_mode="stash", p_options={})
    check("S1 fixture: the custom item is in the hero's inventory and in the party stash",
          st1 == 200 and st2 == 200 and a1["results"][0]["ok"] and a2["results"][0]["ok"], (a1, a2))
    t.note(content=cid, character=ch)

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        D = Sheet(br, dm, tab="combat")
        dp = D.page

        def open_usage():
            dp.goto(APP + "#/dm/overview")
            D.wait(lambda: dp.locator('[data-dm-section="content"]').count() > 0)
            dp.locator('[data-dm-section="content"]').click()
            D.wait(lambda: dp.locator(f'[data-dm="usage-content"][data-id="{cid}"]').count() > 0)
            dp.locator(f'[data-dm="usage-content"][data-id="{cid}"]').click()
            D.wait(lambda: dp.locator(".modal [data-usage-class]").count() > 0)

        open_usage()
        D.wait(lambda: dp.locator(".modal [data-usage-places] li").count() >= 2)
        where = dp.locator(".modal [data-usage-places]").inner_text() if dp.locator(".modal [data-usage-places]").count() else ""
        check("U1 used item: Delete blocked, no Delete button",
              dp.locator(".modal [data-usage-class]").get_attribute("data-usage-class") == "delete_blocked"
              and dp.locator('.modal [data-u="delete"]').count() == 0, dp.locator(".modal").inner_text()[:300])
        check("U2 Where it is used: the hero's inventory (linked to the character) and the party stash, with next steps",
              hero in where and "CD Hoard" in where and "Remove it from" in where
              and dp.locator(f'.modal [data-usage-places] a[href="#/c/{ch}"]').count() == 1, where)
        dp.screenshot(path=str(SHOTS / "cd_usage_blocked.png"))
        dp.keyboard.press("Escape")

        # removed everywhere (history stays) and archived: Delete is offered now
        q(f"delete from public.inventory_items where item_id = '{ref}';")
        dm.rpc("archive_dm_content", p_content=cid, p_reason="CD test")
        open_usage()
        txt = dp.locator(".modal").inner_text()
        check("U3 archived, only history: 'Deletable, history kept', History (kept) listed, Delete offered, no archive advice",
              dp.locator(".modal [data-usage-class]").get_attribute("data-usage-class") == "delete_keeps_history"
              and dp.locator(".modal [data-usage-history]").count() == 1 and dp.locator(".modal [data-usage-current]").count() == 0
              and dp.locator('.modal [data-u="delete"]').count() == 1 and dp.locator('.modal [data-u="archive"]').count() == 0
              and "archive it" not in dp.locator(".modal [data-usage-advice]").inner_text().lower(), txt[:400])
        dp.screenshot(path=str(SHOTS / "cd_usage_history.png"))
        dp.locator('.modal [data-u="delete"]').click()
        dp.wait_for_selector(".modal [data-n]")
        check("U4 the confirmation says the history stays readable",
              "stays readable" in dp.locator('.modal[aria-label^="Delete"]').inner_text())
        dp.fill(".modal [data-n]", "Longsword (homebrew)")
        dp.locator(".modal [data-ok]").click()
        D.wait(lambda: not q(f"select id from public.dm_content where id = '{cid}'"))
        check("U5 deleted; the inventory history stays, unlinked, with the name stamped",
              not q(f"select id from public.dm_content where id = '{cid}'") and not q(f"select id from public.items where id = '{ref}'")
              and int(q(f"select count(*) from public.inventory_events where item_id is null and metadata -> 'deleted_item' ->> 'id' = '{ref}'"
                        f" and metadata -> 'deleted_item' ->> 'name' = 'Longsword (homebrew)'")) >= 4)

        errs = [e for e in D.errors if "Failed to load resource" not in e]
        check("Z1 no console errors", not errs, errs[:5])
        check("Z2 no request left this machine", not D.remote, D.remote[:3])
        D.close(); br.close()


if __name__ == "__main__":
    with iso.Isolated("CONTENT-DELETION-UI") as t:
        run(t)
    report()
