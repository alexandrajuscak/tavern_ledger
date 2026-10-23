"""Browser test of campaign governance, approvals, feats, the DM Space and custom content (docs/DM_SPACE.md,
APPROVAL_WORKFLOWS.md, FEATS.md) against the LOCAL Supabase stack.

Synthetic users only (ui-*@example.test, removed by run_browser_local.sh); the campaign fixture is created with docker exec
(admin-only table writes). Every checked interaction goes through the UI, except the setup of a few custom content items
(created with the DM's own token through the same RPCs the editors call). Refuses non-local URLs.
"""
import json
import subprocess
import sys
import uuid

from playwright.sync_api import sync_playwright

from class_ui_common import APP, User, Sheet, check, report, RUN

DB = "supabase_db_tavern_ledger"


def sql(q):
    r = subprocess.run(["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-qAt", "-v", "ON_ERROR_STOP=1"], input=q.encode(), capture_output=True)
    if r.returncode:
        raise SystemExit(r.stderr.decode())
    return r.stdout.decode().strip()


def ok(st):
    return 200 <= st < 300


# a previous run's campaign (its content goes with it)
sql("delete from public.characters where owner_id in (select id from auth.users where email like 'ui-dmspace-%@example.test');"
    "delete from public.campaigns where name = 'UI Test Campaign'")
dm, player, other = User("dmspace-dm"), User("dmspace-pl"), User("dmspace-other")
camp = str(uuid.uuid4())
sql(f"""insert into public.campaigns (id, name, created_by) values ('{camp}', 'UI Test Campaign', '{dm.id}');
insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{player.id}', 'player');
insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'standard');""")
fighter = player.character(f"Gov Fighter {RUN}", classes=[("fighter-phb", 3)], strength=15, constitution=14)
druid = player.character(f"Gov Druid {RUN}", classes=[("druid-phb", 2)], wisdom=16)
wizard = player.character(f"Gov Wizard {RUN}", classes=[("wizard-phb", 1)], intelligence=16)
sql(f"update public.characters set campaign_id = '{camp}' where id in ('{fighter}', '{druid}', '{wizard}');"
    f"insert into public.character_governance (character_id, setup_complete) values ('{fighter}', true), ('{druid}', true), ('{wizard}', true);")

# custom content prepared with the DM's token (the editors call the same RPCs; the spell editor itself is tested below)
def content(kind, fields):
    st, c = dm.rpc("create_dm_content", p_type=kind, p_campaign=camp, p_fields=fields, p_request_id=str(uuid.uuid4()))
    assert ok(st), c
    st, c = dm.rpc("publish_dm_content", p_content=c["id"])
    assert ok(st), c
    return c


ring = content("item", {"name": "Ring of the Ashen Oath", "player_text": "Warm iron.", "definition": {"item": {"kind_id": "gear", "is_magic": True, "rarity_id": "rare"},
               "hidden": {"unidentified_name": "Heavy iron ring", "curse": "Bound to the wearer forever"}}})
feat = content("feat", {"name": f"Ashwalker {RUN}", "ruleset": "2024", "definition": {"category": "general", "effects": [{"type": "speed_bonus", "value": 5, "label": "Ashwalker"}]}})
fox = content("creature", {"name": f"Cinder Fox {RUN}", "definition": {"size": "Small", "creature_type": "beast", "armor_class": 13, "hit_points": 9,
              "speed": {"walk": 40}, "abilities": {"str": 8, "dex": 16, "con": 12, "int": 4, "wis": 12, "cha": 6}, "challenge_rating": 0.25,
              "actions": [{"kind": "melee", "name": "Bite", "reach": 5, "damage": [{"dice": "1d6+3", "type": "piercing"}], "attack_bonus": 5}]}})
hound = content("companion", {"name": f"Ember Hound {RUN}", "dm_notes": "Spy of the cult", "definition": {"creature": {"size": "Medium", "creature_type": "beast",
                "armor_class": 14, "hit_points": 15, "speed": {"walk": 40}, "abilities": {"str": 14, "dex": 14, "con": 13, "int": 3, "wis": 12, "cha": 6},
                "challenge_rating": 0.5}, "rules": "Acts on your initiative."}})

with sync_playwright() as pw:
    browser = pw.chromium.launch(channel="msedge", headless=True)
    D = Sheet(browser, dm)
    P = Sheet(browser, player)
    O = Sheet(browser, other)
    d, p = D.page, P.page

    # ---- DM Space navigation ------------------------------------------------------------------------------------------
    check("DS1 the DM Space link is shown to a DM", d.locator("#dm-link").is_visible())
    check("DS2 ... and hidden from a player", not p.locator("#dm-link").is_visible() and not O.page.locator("#dm-link").is_visible())
    O.page.goto(APP + "#/dm")
    O.page.wait_for_timeout(1200)
    check("DS3 a player opening #/dm is sent back to the character list", "#/dm" not in O.page.url)
    d.goto(APP + "#/dm/overview")
    D.wait(lambda: d.locator("[data-dm-campaign]").count() > 0)
    d.select_option("[data-dm-campaign]", camp)
    D.wait(lambda: "UI Test Campaign" in d.locator(".dm-title h1").inner_text())
    check("DS4 the campaign selector switches the campaign", "UI Test Campaign" in d.locator(".dm-title h1").inner_text())
    check("DS5 the overview loads (stats + party warnings)", D.wait(lambda: d.locator(".dm-stat").count() >= 6 and d.locator(".dm-card").count() >= 4))
    for sec, sel in [("party", ".dm-pc"), ("approvals", ".dm-filters"), ("content", ".dm-content-list"), ("rules", ".dm-presets"), ("audit", ".dm-filters")]:
        d.locator(f'[data-dm-section="{sec}"]').click()
        check(f"DS6 the {sec} section loads", D.wait(lambda: d.locator(f"[data-dm-panel] {sel}").count() > 0))

    # ---- custom spell editor -------------------------------------------------------------------------------------------
    d.locator('[data-dm-section="content"]').click()
    D.wait(lambda: d.locator('[data-dm="new-content"][data-type="spell"]').count() > 0)
    d.locator('[data-dm="new-content"][data-type="spell"]').click()
    d.wait_for_selector(".modal [data-ce-form]")
    spell_name = f"Ember Lance {RUN}"
    d.fill(".modal [name=name]", spell_name)
    d.select_option('.modal [name="definition.level"]', "1")
    d.select_option('.modal [name="definition.school"]', "evocation")
    d.locator('.modal [name="definition.class_lists"][value="wizard-spell-list"]').check()
    d.select_option('.modal [name="definition.range.type"]', "distance")
    d.fill('.modal [name="definition.range.distance"]', "60")
    d.locator('.modal [name="definition.components.v"]').check()
    d.fill('.modal [name="player_text"]', "A lance of embers.")
    d.fill('.modal [name="dm_notes"]', "Taught by a fire giant")
    d.locator('.modal [data-ce-act="save"]').click()
    check("DS7 the DM saves a spell draft", D.wait(lambda: "Draft" in d.locator(".modal .ce-status").inner_text()))
    st, lib = dm.rpc("get_dm_content_library", p_campaign=camp)
    sp = next(x for x in lib if x["name"] == spell_name)
    st, seen = player.rpc("get_dm_content", p_content=sp["id"])
    check("DS8 the player cannot see the draft", st >= 400, seen)
    d.locator('.modal [data-ce-act="preview"]').click()
    check("DS9 the preview shows the player card (name, campaign custom badge, no DM notes)",
          D.wait(lambda: spell_name in d.locator(".modal [data-ce-preview]").inner_text()) and "fire giant" not in d.locator(".modal [data-ce-preview]").inner_text())
    d.once("dialog", lambda x: x.accept())
    d.locator('.modal [data-ce-act="publish"]').click()
    d.locator(".modal [data-ok]").last.click()
    check("DS10 publishing marks it Published", D.wait(lambda: "Published" in d.locator(".modal .ce-status").first.inner_text()))
    d.keyboard.press("Escape")
    st, lib = dm.rpc("get_dm_content_library", p_campaign=camp)
    sp = next(x for x in lib if x["name"] == spell_name)
    st, det = player.rpc("get_spell_detail", p_version=sp["catalog_ref"])
    check("DS11 the published spell is visible to the player, without DM notes", ok(st) and det["name"] == spell_name and "fire giant" not in json.dumps(det), det)

    # ---- assign spell + item (unidentified) through the Assign section ---------------------------------------------------
    def assign(content_id, char_id, mode=None, unidentified=False):
        d.locator('[data-dm-section="assign"]').click()
        D.wait(lambda: d.locator("[data-as-content]").count() > 0)
        d.select_option("[data-as-content]", content_id)
        d.locator(f'[data-as-char][value="{char_id}"]').check()
        if mode:
            d.select_option("[data-as-m]", mode)
        if unidentified:
            d.locator("[data-as-unid]").check()
        d.locator("[data-as-go]").click()
        return D.wait(lambda: "done" in d.locator("[data-as-result]").inner_text())
    check("DS12 the DM assigns the custom spell to the wizard", assign(sp["id"], wizard, "innate"))
    P.open(wizard)
    P.tab("spells")
    check("DS13 the spell appears on the wizard's spellbook with its campaign scope",
          P.wait(lambda: spell_name in p.locator('[data-panel="spells"]').inner_text()))
    check("DS14 the DM assigns the ring unidentified", assign(ring["id"], fighter, "inventory", unidentified=True))
    P.open(fighter)
    P.tab("inventory")
    P.wait(lambda: "Heavy iron ring" in p.locator('[data-panel="inventory"]').inner_text())
    html = p.content()
    check("DS15 the player sees only the disguise; the true name and the curse are not in the DOM",
          "Heavy iron ring" in html and "Ashen Oath" not in html and "Bound to the wearer" not in html)
    d.locator('[data-dm-section="hidden"]').click()
    D.wait(lambda: d.locator("[data-h-char]").count() > 0)
    d.select_option("[data-h-char]", fighter)
    D.wait(lambda: d.locator("[data-k-state]").count() > 0)
    d.select_option("[data-k-state]", "identified")
    d.locator('[data-h="knowledge"]').click()
    D.page.wait_for_timeout(1500)
    P.open(fighter)
    P.tab("inventory")
    check("DS16 after identification the player sees the true name (the curse stays hidden)",
          P.wait(lambda: "Ashen Oath" in p.locator('[data-panel="inventory"]').inner_text()) and "Bound to the wearer" not in p.content())

    # ---- player proposes a feat; DM returns, player resubmits, DM approves ---------------------------------------------------
    P.tab("features")
    p.locator('[data-feat="add"]').click()
    p.wait_for_selector(".modal [data-q]")
    p.fill(".modal [data-q]", "Tough")
    P.wait(lambda: p.locator('.modal [data-pick="tough-2024"]').count() > 0)
    check("DS17 the feat picker searches and shows eligible feats with badges",
          "2024" in p.locator('.modal [data-pick="tough-2024"]').inner_text())
    p.select_option(".modal [data-ruleset]", "2014")
    check("DS18 the ruleset filter hides other versions", P.wait(lambda: p.locator('.modal [data-pick="tough-2024"]').count() == 0 and p.locator('.modal [data-pick="tough-2014"]').count() == 1))
    p.select_option(".modal [data-ruleset]", "")
    p.fill(".modal [data-q]", "Great Weapon Master")
    P.wait(lambda: p.locator('.modal [data-pick="great-weapon-master-2024"]').count() == 0)
    check("DS19 'Eligible only' hides feats whose prerequisites are not met (GWM 2024 needs level 4)",
          p.locator('.modal [data-pick="great-weapon-master-2024"]').count() == 0)
    p.locator(".modal [data-eligible]").uncheck()
    P.wait(lambda: p.locator('.modal [data-pick="great-weapon-master-2024"]').count() == 1)
    p.locator('.modal [data-pick="great-weapon-master-2024"]').click()
    check("DS20 an unmet prerequisite is explained", P.wait(lambda: "Level 4+" in p.locator(".modal [data-detail]").inner_text()))
    p.fill(".modal [data-q]", "Tough")
    p.locator(".modal [data-eligible]").check()
    P.wait(lambda: p.locator('.modal [data-pick="tough-2024"]').count() > 0)
    p.locator('.modal [data-pick="tough-2024"]').click()
    p.wait_for_selector('.modal [data-take="tough-2024"]')
    p.locator('.modal [data-take="tough-2024"]').click()
    check("DS21 a feat in a standard campaign opens the 'Ask your DM' dialog", P.wait(lambda: p.locator(".modal [data-send]").count() > 0))
    p.fill(".modal [data-note]", "Toughened by the siege")
    p.locator(".modal [data-send]").click()
    check("DS22 the request is sent and shown as waiting", P.wait(lambda: "waiting for the DM" in p.locator("#gov-bar").inner_text()))
    d.locator('[data-dm-section="approvals"]').click()
    D.wait(lambda: d.locator(".dm-req-card").count() > 0)
    check("DS23 the pending request appears in the DM inbox", "Tough" in d.locator("[data-dm-panel]").inner_text() or "Feat" in d.locator("[data-dm-panel]").inner_text())
    d.locator('.dm-req-card [data-dm="review"]').first.click()
    d.wait_for_selector(".modal .diff-list, .modal .gov-error", timeout=15000)
    body = d.locator(".modal").inner_text()
    check("DS24 the review shows a structured diff (maximum HP before -> after) and the player note", "Maximum HP" in body and "Toughened" in body, body[:400])
    d.fill(".modal [data-rv-note]", "Tell me how the siege changed you")
    d.locator('.modal [data-rv="return"]').click()
    check("DS25 the player sees the return note", P.wait(lambda: "returned" in p.locator("#gov-bar").inner_text().lower(), timeout=20000))
    p.locator('[data-gov="list"]').click()
    p.wait_for_selector(".modal .req-item")
    check("DS26 ... with the DM's message in the request list", "siege changed you" in p.locator(".modal").inner_text())
    p.locator(".modal [data-open]").first.click()
    p.wait_for_selector(".modal [data-send]")
    p.fill(".modal [data-note]", "I held the gate for three days")
    p.locator(".modal [data-send]").click()
    P.wait(lambda: "waiting for the DM" in p.locator("#gov-bar").inner_text())
    d.goto(APP + "#/dm/approvals")
    D.wait(lambda: d.locator('.dm-req-card [data-dm="review"]').count() > 0)
    d.locator('.dm-req-card [data-dm="review"]').first.click()
    d.wait_for_selector('.modal [data-rv="approve"]')
    d.locator('.modal [data-rv="approve"]').click()
    feats = {}
    def approved():
        nonlocal_feats = player.rpc("get_character_feats", p_character=fighter)[1]
        feats.update(nonlocal_feats)
        return any(f["feat"]["id"] == "tough-2024" for f in nonlocal_feats["feats"])
    D.wait(approved, timeout=20000)
    check("DS27 approved: the feat is on the character and its HP maximum grew", any(f["feat"]["id"] == "tough-2024" for f in feats["feats"])
          and feats["hit_points"]["feat_bonus"] == 6, feats.get("hit_points"))
    P.open(fighter)
    P.tab("features")
    check("DS28 the player's Feats card shows it with its source", P.wait(lambda: "tough" in p.locator("#feats-card").inner_text().lower()
          and "approved request" in p.locator("#feats-card").inner_text().lower()))
    hp_note = p.locator("#hp-card [data-derived-hp]")
    check("DS28b the HP card counts the feat: maximum = base + 6 from Tough",
          P.wait(lambda: hp_note.is_visible() and "+ 6 from Tough" in hp_note.inner_text()), hp_note.inner_text() if hp_note.count() else "")
    full = int(hp_note.inner_text().split("Maximum ")[1].split(":")[0]) if hp_note.count() and "Maximum " in hp_note.inner_text() else -1
    p.fill("#hp-amount", "999")
    p.locator('[data-action="hp-heal"]').click()
    check("DS28c healing fills up to the feat-aware maximum (not the base)",
          P.wait(lambda: p.locator("#hp-card .hp-current").input_value() == str(full)), (full, p.locator("#hp-card .hp-current").input_value()))

    # ---- stale request ----------------------------------------------------------------------------------------------------------
    st, req = player.rpc("create_change_request", p_character=fighter, p_ops=[{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 4}}],
                         p_idempotency_key=str(uuid.uuid4()))
    dm.rpc("set_character_class", p_character=fighter, p_class_version="fighter-phb", p_level=4)
    d.goto(APP + f"#/dm/approvals/{req['id']}")
    check("DS29 a stale request warns the DM and blocks approval until refreshed",
          D.wait(lambda: "changed after this request" in d.locator(".modal").inner_text()) and d.locator('.modal [data-rv="approve"]').is_disabled())
    d.keyboard.press("Escape")

    # ---- custom feat, Wild Shape form, companion ----------------------------------------------------------------------------------
    st, res = dm.rpc("dm_assign_content", p_content=feat["id"], p_characters=[druid], p_mode="campaign_reward", p_options={})
    P.open(druid)
    P.tab("features")
    check("DS30 a custom campaign feat appears with the campaign badge", P.wait(lambda: f"ashwalker {RUN}" in p.locator("#feats-card").inner_text().lower()
          and "Campaign custom" in p.locator("#feats-card").inner_text(), timeout=20000), (res, p.locator("#feats-card").inner_text()[:300]))
    st, ws = player.rpc("get_character_transformation", p_character=druid)
    fox_ref = fox["versions"][0]["catalog_ref"]
    check("DS31 the custom beast is not a Wild Shape option before the DM grant", fox_ref not in json.dumps(ws))
    st, err = player.rpc("set_seen_forms", p_character=druid, p_creatures=[fox_ref])
    check("DS32 the player cannot self-grant it (refused: needs the DM's approval in a standard campaign)", st >= 400 and fox_ref not in json.dumps(player.rpc("get_character_transformation", p_character=druid)[1]), err)
    check("DS33 the DM grants it from Assign", assign(fox["id"], druid, "seen_form"))
    st, ws = player.rpc("get_character_transformation", p_character=druid)
    check("DS34 the Druid now has it as an option", fox_ref in json.dumps(ws))
    check("DS35 the DM assigns a companion from a template", assign(hound["id"], wizard, "companion"))
    companions = sql(f"select count(*) from public.character_companions where character_id = '{wizard}' and template_version_id is not null")
    check("DS36 ... and the companion instance exists", companions == "1", companions)

    # ---- lock ------------------------------------------------------------------------------------------------------------------
    d.goto(APP + "#/dm/party")
    D.wait(lambda: d.locator(".dm-pc").count() >= 3)
    card = d.locator(".dm-pc", has_text=f"Gov Fighter {RUN}")
    card.locator("summary").click()
    card.locator('[data-dm="lock"]').click()
    d.locator('.modal [name=lock][value="progression_locked"]').check()
    d.fill(".modal [data-reason]", "Between sessions")
    d.locator(".modal [data-ok]").click()
    D.page.wait_for_timeout(1000)
    P.open(fighter)
    check("DS37 the player sees a friendly lock message with the reason", P.wait(lambda: "paused progression" in p.locator("#gov-bar").inner_text()
          and "Between sessions" in p.locator("#gov-bar").inner_text()))

    # ---- player restrictions -------------------------------------------------------------------------------------------------
    P.tab("inventory")
    p.locator("#inventory-app button", has_text="Add").first.click()
    p.wait_for_timeout(800)
    check("DS38 the player has no 'create homebrew item' button", p.locator(".modal [data-create]").count() == 0 and "Ask your DM" in p.locator(".modal").inner_text())
    p.keyboard.press("Escape")
    P.tab("bio")
    ta = p.locator('#notes-section textarea').first
    ta.fill(f"Personal note {RUN}")
    ta.blur()
    check("DS39 free-text notes stay editable for the player (even while progression is locked)",
          P.wait(lambda: sql(f"select count(*) from public.notes where character_id = '{fighter}' and content like 'Personal note%'") == "1", timeout=10000),
          sql(f"select kind || ':' || left(content, 30) from public.notes where character_id = '{fighter}' and content <> ''"))

    # ---- keyboard, mobile, hygiene ---------------------------------------------------------------------------------------------
    d.goto(APP + "#/dm/overview")
    D.wait(lambda: d.locator('[data-dm="create"]').count() > 0)
    d.locator('.dm-head [data-dm="create"]').focus()
    d.keyboard.press("Enter")
    d.wait_for_selector(".modal .dm-create-tile")
    for _ in range(14):
        d.keyboard.press("Tab")
    inside = d.evaluate("() => !!document.activeElement.closest('.modal')")
    d.keyboard.press("Escape")
    d.wait_for_timeout(400)
    back = d.evaluate("() => document.activeElement?.dataset?.dm === 'create'")
    check("DS40 keyboard: the create dialog traps focus and returns it on Escape", inside and back)
    unnamed = d.evaluate("""() => [...document.querySelectorAll('.dm-space button, .dm-space select, .dm-space input')].filter((e) =>
      !(e.getAttribute('aria-label') || e.textContent.trim() || e.labels?.length || e.title || e.placeholder)).length""")
    check("DS41 no unnamed controls in the DM Space", unnamed == 0, unnamed)
    M = Sheet(browser, dm, width=390, height=844)
    for sec in ["overview", "approvals", "party", "content", "rules"]:
        M.page.goto(APP + f"#/dm/{sec}")
        M.page.wait_for_timeout(1500)
    check("DS42 no horizontal overflow at 390 px", M.overflow() <= 0, M.overflow())
    # the player's feat in the standard campaign is refused on purpose (DS21: "needs approval" is an HTTP 400 of PostgREST)
    errs = D.errors + M.errors + [e for e in P.errors if "status of 400" not in e]
    check("DS43 no console errors (apart from the one intended governance refusal)",
          not errs and sum("status of 400" in e for e in P.errors) <= 1, (errs or P.errors)[:5])
    check("DS44 no hosted requests", not (D.remote + P.remote + M.remote), (D.remote + P.remote)[:3])
    browser.close()
sql("delete from public.change_requests where campaign_id = (select id from public.campaigns where name = 'UI Test Campaign')")
report()
