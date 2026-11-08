"""Combat Builder through the real API (PostgREST + JWT), docs/COMBAT_PERMISSIONS.md. LOCAL ONLY, synthetic users in isolation.

The authorization matrix as the browser would hit it: anonymous, an unrelated user, a player of the campaign and its DM;
table reads (RLS), every write path (no table grants), the player-safe read model (no hidden data), and the Realtime change
log's columns (ids only).
Usage: API_URL=... ANON_KEY=... SERVICE_ROLE_KEY=... python supabase/tests/api/combat_api_test.py
"""
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "browser"))
import isolation as iso  # noqa: E402
from class_ui_common import ANON, User, call, check, report  # noqa: E402


def rpc(user, fn, **args):
    tok = user.jwt if user else ANON
    return call("POST", f"/rest/v1/rpc/{fn}", args, token=tok, key=ANON)


def denied(st, body):
    return st in (401, 403) or "42501" in str(body)


def run(t):
    dm, pl, other = User("cbapi-dm"), User("cbapi-pl"), User("cbapi-ot")
    camp = str(uuid.uuid4())
    iso.psql(f"insert into public.campaigns (id, name, created_by) values ('{camp}', 'UI Combat API {dm.id[:6]}', '{dm.id}');"
             f"insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');")
    ch = pl.character("API Hero", [("fighter-phb", 2)], hp_max=25, hp_current=25)
    call("PATCH", f"/rest/v1/characters?id=eq.{ch}", {"campaign_id": camp}, token=pl.jwt, key=ANON)

    # ---- DM builds and runs an encounter
    st, r = rpc(dm, "combat_create_encounter", p_campaign=camp, p_name="API fight", p_ruleset="2024")
    check("AP1 DM creates an encounter (200)", st == 200 and r["encounter"]["status"] == "draft", (st, str(r)[:200]))
    enc = r["encounter"]["id"]
    rpc(dm, "combat_add_characters", p_encounter=enc, p_characters=[ch])
    st, r = rpc(dm, "combat_add_monsters", p_encounter=enc, p_source_kind="srd2024", p_source_id="srd52-ogre", p_options={"hidden": True, "player_label": "Large shape"})
    ogre = r["added"][0]
    st, r = rpc(dm, "combat_add_monsters", p_encounter=enc, p_source_kind="srd2024", p_source_id="srd52-wolf", p_options={})
    wolf = r["added"][0]
    rpc(dm, "combat_roll_initiative", p_encounter=enc, p_participants=None, p_options={})
    pc = iso.psql(f"select id from public.combat_participants where encounter_id = '{enc}' and kind = 'character'")
    rpc(dm, "combat_set_initiative", p_encounter=enc, p_values=[{"id": pc, "initiative": 12}])
    st, r = rpc(dm, "combat_start", p_encounter=enc, p_accept_ties=True)
    check("AP2 DM starts combat", st == 200 and iso.psql(f"select status from public.combat_encounters where id = '{enc}'") == "active", (st, str(r)[:300]))
    st, r = rpc(dm, "combat_add_effect", p_encounter=enc, p_effect={"effect_type": "custom", "name": "Secret curse", "target": pc, "visibility": "dm"})
    st, r = rpc(dm, "combat_add_effect", p_encounter=enc, p_effect={"effect_type": "condition", "condition_key": "prone", "target": pc})
    rpc(dm, "combat_update_encounter", p_encounter=enc, p_patch={"dm_notes": "Ambush from the reeds"})
    st, r = rpc(dm, "combat_get_encounter", p_encounter=enc)
    check("AP3 DM reads the whole encounter (hidden ogre, DM notes, both effects)", st == 200 and len(r["participants"]) == 3
          and r["encounter"]["dm_notes"] == "Ambush from the reeds" and len([e for e in r["effects"] if e["active"]]) == 2)
    st, rows = call("GET", f"/rest/v1/combat_participants?encounter_id=eq.{enc}&select=id", token=dm.jwt, key=ANON)
    check("AP4 DM table read through RLS", st == 200 and len(rows) == 3)

    # ---- player
    st, r = rpc(pl, "combat_get_encounter", p_encounter=enc)
    check("AP5 player: the DM read model is refused", denied(st, r), (st, str(r)[:200]))
    for tbl in ("combat_encounters", "combat_participants", "combat_effects", "combat_events", "combat_reminders", "combat_statblocks", "combat_changes"):
        st, rows = call("GET", f"/rest/v1/{tbl}?select=*", token=pl.jwt, key=ANON)
        check(f"AP6 player sees no {tbl} rows (RLS)", st == 200 and rows == [], (st, str(rows)[:120]))
    st, r = rpc(pl, "combat_apply_hp", p_participant=wolf, p_op="damage", p_amount=3)
    check("AP7 player cannot change monster HP", denied(st, r), (st, str(r)[:200]))
    st, r = rpc(pl, "combat_next_turn", p_encounter=enc, p_expected_turn_rev=None)
    check("AP8 player cannot move the turn", denied(st, r))
    st, r = call("POST", "/rest/v1/combat_encounters", {"campaign_id": camp, "name": "x", "ruleset": "2024"}, token=pl.jwt, key=ANON)
    check("AP9 no direct insert (no table grant)", st in (401, 403) or "42501" in str(r), (st, str(r)[:200]))
    st, r = call("PATCH", f"/rest/v1/combat_participants?id=eq.{wolf}", {"hp_current": 1}, token=dm.jwt, key=ANON)
    check("AP10 even the DM cannot write tables directly (RPC only)", st in (401, 403) or "42501" in str(r) or r == [], (st, str(r)[:200]))
    st, view = rpc(pl, "get_combat_player_view", p_encounter=enc)
    txt = json.dumps(view)
    check("AP11 player-safe view: running encounter visible to the player", st == 200 and view["encounter"]["status"] == "active", (st, txt[:200]))
    check("AP12 hidden monster absent (no 'Ogre', no 'Large shape')", "Ogre" not in txt and "Large shape" not in txt)
    check("AP13 DM-only effect and DM notes absent", "Secret curse" not in txt and "Ambush" not in txt and "dm_notes" not in txt)
    check("AP14 visible effect present", "Prone" in txt)
    wolf_row = next((p for p in view["participants"] if p["kind"] == "monster"), {})
    check("AP15 monster HP only as a state word", wolf_row.get("hp", {}).get("state") in ("healthy", "bloodied", "critical", "down") and "current" not in wolf_row.get("hp", {}), wolf_row)
    check("AP16 no stat block, no notes, no reminders", "statblock" not in txt and "notes" not in txt and "reminder" not in txt)
    rpc(dm, "combat_update_participant", p_participant=ogre, p_patch={"hidden": False})
    st, view = rpc(pl, "get_combat_player_view", p_encounter=enc)
    txt = json.dumps(view)
    check("AP17 after the reveal the disguise is shown, not the true name", "Large shape" in txt and "Ogre" not in txt)
    st, r = rpc(pl, "apply_character_hp", p_character=ch, p_op="damage", p_amount=4)
    check("AP18 player's own sheet HP through the atomic RPC", st == 200 and r["after"]["hp"] == 21, (st, str(r)[:200]))

    # ---- unrelated user and anonymous
    st, r = rpc(other, "combat_get_encounter", p_encounter=enc)
    check("AP19 unrelated user denied the encounter", denied(st, r))
    st, r = rpc(other, "get_combat_player_view", p_encounter=enc)
    check("AP20 unrelated user denied the player view", denied(st, r))
    st, r = rpc(other, "apply_character_hp", p_character=ch, p_op="damage", p_amount=1)
    check("AP21 unrelated user cannot change the character's HP", denied(st, r))
    st, r = rpc(other, "combat_monster_library", p_campaign=camp)
    check("AP22 unrelated user cannot open the campaign's library", denied(st, r))
    for fn, args in (("combat_list_encounters", {}), ("combat_get_encounter", {"p_encounter": enc}), ("get_combat_player_view", {"p_encounter": enc}),
                     ("apply_character_hp", {"p_character": ch, "p_op": "damage", "p_amount": 1})):
        st, r = rpc(None, fn, **args)
        check(f"AP23 anonymous denied: {fn}", denied(st, r) or st == 404, (st, str(r)[:150]))
    st, rows = call("GET", "/rest/v1/combat_monsters?select=id&limit=1", token=ANON, key=ANON)
    check("AP24 anonymous cannot read the monster catalog", st in (401, 403) or rows == [], (st, str(rows)[:100]))
    # ---- change log columns (what Realtime could ever carry)
    cols = iso.psql("select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema = 'public' and table_name = 'combat_changes'")
    check("AP25 Realtime change log carries ids and kinds only", cols == "id,encounter_id,domain,kind,participant_id,player_visible,changed_at", cols)
    check("AP26 HP after all calls: 25 - 4 = 21 on the real character", iso.psql(f"select hp_current from public.characters where id = '{ch}'") == "21")


if __name__ == "__main__":
    with iso.Isolated("COMBAT-API") as t:
        run(t)
    report()
