"""Quest log (20261114000400, docs/QUEST_LOG.md). LOCAL ONLY, synthetic users.

The DM creates, in DM Space -> Quests, a party quest (two objectives, DM notes), an individual quest for character A and a
private quest for A. Player A sees all three; player B sees the party quest and A's individual quest but not A's private one;
neither session ever receives the DM notes or (for B) the private quest (REST bodies, websocket frames, DOM, storage). The DM
ticks an objective and A sees it ticked when the tab is shown again. ?fluent=0 loads the tab through the same RPC. A phone
width bottom bar fits seven sections.
Usage: APP_URL=... python quest_log_ui_test.py   (run_browser_local.sh sets the environment)
"""
import uuid

from playwright.sync_api import sync_playwright

import isolation as iso
from class_ui_common import APP, RUN, SHOTS, Sheet, User, check, report

q = iso.psql
NOTE = f"DMNOTE-{RUN}"
PARTY, INDIV, PRIV = f"Lost Mine {RUN}", f"Debt of A {RUN}", f"A's secret {RUN}"
OBJ1, OBJ2 = f"Reach Phandalin {RUN}", f"Find the map {RUN}"


def dm_new_quest(D, title, vis, target=None, objectives=(), notes=""):
    dp = D.page
    dp.locator('[data-qa="new"]').click()
    D.wait(lambda: dp.locator(".modal [data-quest-form]").count() == 1)
    m = dp.locator(".modal").last
    m.locator('input[name="title"]').fill(title)
    m.locator('textarea[name="description"]').fill(f"About {title}")
    m.locator('select[name="visibility"]').select_option(vis)
    if target:
        m.locator('select[name="target"]').select_option(target)
    for o in objectives:
        m.locator("[data-obj-add]").click()
        m.locator("[data-obj-text]").last.fill(o)
    if notes:
        m.locator('textarea[name="dm_notes"]').fill(notes)
    m.locator("[data-quest-save]").click()
    return D.wait(lambda: dp.locator(".quest-dm-row", has_text=title).count() == 1, 15000)


def quest_titles(P):
    return P.page.locator("#quests-app .quest-card .quest-title").all_inner_texts()


def capture(page):
    seen = {"bodies": [], "frames": []}

    def on_response(r):
        if "/rest/v1/" in r.url:
            try:
                seen["bodies"].append(r.text())
            except Exception:
                pass
    page.on("response", on_response)
    page.on("websocket", lambda ws: ws.on("framereceived", lambda f: seen["frames"].append(f if isinstance(f, str) else str(f))))
    return seen


def everything(page, seen):
    return seen["bodies"] + seen["frames"] + [page.content()] + page.evaluate(
        "() => { const o = []; for (const s of [localStorage, sessionStorage]) for (let i = 0; i < s.length; i++) o.push(s.key(i) + '=' + s.getItem(s.key(i))); return o; }")


def quest_rpcs(page):
    return len([1 for r in page.evaluate("() => performance.getEntriesByType('resource').map((e) => e.name)") if "rpc/get_character_quests" in r])


def run():
    dm, pa, pb = User("qldm"), User("qlpa"), User("qlpb")
    camp = str(uuid.uuid4())
    q(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'Quest Table {RUN}', '{dm.id}');"
      f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pa.id}', 'player'), ('{camp}', '{pb.id}', 'player');"
      f"insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'relaxed');")
    a = pa.character(f"Quester A {RUN}", [("fighter-phb", 1)])
    b = pb.character(f"Quester B {RUN}", [("fighter-phb", 1)])
    q(f"update public.characters set campaign_id = '{camp}' where id in ('{a}', '{b}');"
      f"insert into public.character_governance (character_id, setup_complete) values ('{a}', true), ('{b}', true);")

    with sync_playwright() as p:
        br = p.chromium.launch(channel="msedge", headless=True)
        # ---- 1. the DM creates three quests in DM Space -> Quests -----------------------------------------------------------------
        D = Sheet(br, dm, tab="combat")
        dp = D.page
        dp.goto(APP + "#/dm/quests")
        D.wait(lambda: dp.locator('[data-qa="new"]').count() == 1, 20000)
        ok1 = dm_new_quest(D, PARTY, "party", objectives=(OBJ1, OBJ2), notes=NOTE)
        ok2 = dm_new_quest(D, INDIV, "individual", target=a, notes=NOTE + "-i")
        ok3 = dm_new_quest(D, PRIV, "private", target=a, notes=NOTE + "-p")
        stored = q(f"select string_agg(visibility || ':' || coalesce(target_character_id::text, '-'), ',' order by sort_order) from public.quests where campaign_id = '{camp}'").strip()
        check("QU1 DM Space: the DM creates a party, an individual and a private quest (stored with the right visibility and target)",
              ok1 and ok2 and ok3 and stored == f"party:-,individual:{a},private:{a}" and NOTE in dp.locator("[data-quest-dm]").inner_text(),
              (ok1, ok2, ok3, stored))

        # ---- 2. player A sees all three, never the DM notes ----------------------------------------------------------------------
        A = Sheet(br, pa, tab="combat")
        ap = A.page
        seen_a = capture(ap)
        A.open(a)
        ap.wait_for_timeout(1500)
        lazy0 = quest_rpcs(ap)
        A.tab("quests")
        A.wait(lambda: len(quest_titles(A)) == 3, 15000)
        ta = quest_titles(A)
        leak_a = [t[:100] for t in everything(ap, seen_a) if NOTE in t]
        check("QU2 player A sees the party quest, A's individual quest and A's private quest", sorted(ta) == sorted([PARTY, INDIV, PRIV]), ta)
        check("QU3 REQUIRED A's session never receives the DM notes (REST, websocket, DOM, storage)", not leak_a, leak_a)

        # ---- 3. player B: party + A's individual, not A's private --------------------------------------------------------------
        B = Sheet(br, pb, tab="quests")
        bp = B.page
        seen_b = capture(bp)
        B.open(b)
        B.wait(lambda: len(quest_titles(B)) == 2, 15000)
        tb = quest_titles(B)
        leak_b = [t[:100] for t in everything(bp, seen_b) if NOTE in t or PRIV in t]
        check("QU4 player B sees the party quest and A's individual quest (as A's), not A's private quest",
              sorted(tb) == sorted([PARTY, INDIV]) and "Quester A" in bp.locator("#quests-app").inner_text(), (tb, bp.locator("#quests-app").inner_text()[:300]))
        check("QU5 REQUIRED B's session never receives A's private quest or any DM note (REST, websocket, DOM, storage)", not leak_b, leak_b)
        check("QU6 the tab is ONE request (get_character_quests), lazily: an open on another tab makes none, opening the tab one",
              lazy0 == 0 and quest_rpcs(ap) == 1 and quest_rpcs(bp) == 1, (lazy0, quest_rpcs(ap), quest_rpcs(bp)))

        # ---- 4. the DM ticks an objective; A sees it on the next show of the tab ----------------------------------------------------
        dp.locator(".quest-dm-row", has_text=PARTY).locator("label", has_text=OBJ2).locator("input[data-qo]").check()
        D.wait(lambda: q(f"select done from public.quest_objectives where body = '{OBJ2}'").strip() == "t", 10000)
        A.tab("combat")
        A.tab("quests")
        card = ap.locator("#quests-app .quest-card", has_text=PARTY)
        A.wait(lambda: card.locator("summary").inner_text().find("1/2") >= 0, 10000)
        card.locator("summary").click()
        done = A.wait(lambda: card.locator("li.is-done", has_text=OBJ2).count() == 1 and card.locator("li.is-done", has_text=OBJ1).count() == 0, 5000)
        check("QU7 the objective the DM ticked shows as done for the player (1/2, ticked row)", done, card.inner_text()[:300])

        # ---- 5. ?fluent=0 legacy path, phone width ----------------------------------------------------------------------------------
        bp.goto(f"{APP}?fluent=0#/c/{b}")
        B.wait(lambda: bp.locator(".tab").count() > 0, 20000)
        legacy = B.wait(lambda: len(quest_titles(B)) == 2, 15000)
        check("QU8 ?fluent=0: the Quests tab loads through the same RPC (B: 2 quests)",
              legacy and bp.evaluate("() => document.querySelector('[data-read-path]')?.dataset.readPath") == "legacy", quest_titles(B))
        bp.goto(f"{APP}?fluent=default")
        bp.wait_for_selector(".char-card, .empty-state, a.brand", timeout=20000)
        M = Sheet(br, pa, width=360, height=740, tab="quests")
        M.open(a)
        M.wait(lambda: len(quest_titles(M)) == 3, 15000)
        bar = M.page.evaluate("""() => { const t = document.querySelector('.tabs'); const r = t.getBoundingClientRect();
          return { n: t.querySelectorAll('.tab').length, w: r.width, sw: t.scrollWidth, page: document.documentElement.scrollWidth,
                   fixed: getComputedStyle(t).position }; }""")
        M.page.locator("#quests-app .quest-card summary").first.click()
        M.page.screenshot(path=str(SHOTS / "quest_log_mobile.png"), full_page=True)
        check("QU9 phone (360 px): seven sections in the bottom bar, no horizontal overflow", bar["n"] == 7 and bar["fixed"] == "fixed"
              and bar["sw"] <= bar["w"] + 1 and bar["page"] <= 361, bar)
        check("QU10 no console errors (DM, A, B, phone)", not D.errors and not A.errors and not B.errors and not M.errors,
              (D.errors[:3], A.errors[:3], B.errors[:3], M.errors[:3]))
        br.close()
    report()


if __name__ == "__main__":
    run()
