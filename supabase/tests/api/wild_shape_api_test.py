"""API / RLS tests of the Wild Shape engine (20261017001300) against the LOCAL Supabase stack.

Run by supabase/tests/run_supabase_local.sh after class_catalog_api_test.py (same environment; refuses anything that is
not localhost through api_contract_test). Synthetic users (@example.test) only. The owner plays through the RPCs, the
campaign DM reads and grants exceptions, an outsider can neither read nor change anything, and no client can write the
Wild Shape tables directly or make the server trust client-supplied hit points, scores or eligibility.
"""
import sys

from api_contract_test import RUN, call, check, results, rpc, svc, user


def main():
    alice, alice_id = user("api-ws-alice@example.test")
    bob, _ = user("api-ws-bob@example.test")
    dm, dm_id = user("api-ws-dm@example.test")
    st, camp, _ = svc("POST", "/rest/v1/campaigns", {"name": f"API Wild Shape {RUN}", "created_by": dm_id}, {"Prefer": "return=representation"})
    camp_id = camp[0]["id"]
    svc("POST", "/rest/v1/campaign_members", [{"campaign_id": camp_id, "user_id": alice_id, "role": "player"},
                                               {"campaign_id": camp_id, "user_id": dm_id, "role": "dm"}])
    st, ch, _ = svc("POST", "/rest/v1/characters", {"owner_id": alice_id, "name": f"API Moon Druid {RUN}", "campaign_id": camp_id, "wisdom": 16,
                                                    "constitution": 14, "hp_max": 40, "hp_current": 40}, {"Prefer": "return=representation"})
    ch = ch[0]["id"]
    st, body, _ = rpc(alice, "set_character_class", p_character=ch, p_class_version="druid-phb", p_level=6, p_subclass_version="druid-moon-phb")
    assert st == 200, (st, body)

    # catalog
    st, rows, _ = call("GET", "/rest/v1/creatures?select=id,hit_points,mechanics_status&id=eq.brown-bear", token=bob)
    check("WA1 the creature catalog is readable (Brown Bear, 34 HP, complete mechanics)",
          st == 200 and rows == [{"id": "brown-bear", "hit_points": 34, "mechanics_status": "complete"}], (st, rows))
    st, body, _ = call("PATCH", "/rest/v1/creatures?id=eq.brown-bear", token=alice, body={"hit_points": 999})
    st2, rows, _ = call("GET", "/rest/v1/creatures?select=hit_points&id=eq.brown-bear", token=alice)
    check("WA2 a client cannot change a creature's statistics", rows[0]["hit_points"] == 34, (st, rows))

    # read model and access
    st, tf, _ = rpc(alice, "get_character_transformation", p_character=ch)
    check("WA3 the owner reads the Wild Shape state: Druid 6, Moon, 2 uses, options with status and reasons",
          st == 200 and tf["druid_level"] == 6 and tf["moon"] and tf["resources"][0]["remaining"] == 2
          and any(o["id"] == "giant-eagle" and not o["allowed"] and o["reasons"] for o in tf["options"]), st)
    st, tf, _ = rpc(dm, "get_character_transformation", p_character=ch)
    check("WA4 the campaign DM reads the Wild Shape state", st == 200 and tf["druid_level"] == 6, st)
    st, tf, _ = rpc(bob, "get_character_transformation", p_character=ch)
    check("WA5 an outsider cannot read the Wild Shape state", st >= 400, st)

    # transformation: server-authoritative eligibility and stats
    st, r, _ = rpc(bob, "start_transformation", p_character=ch, p_creature="brown-bear", p_options={})
    check("WA6 an outsider cannot transform the character", st >= 400, st)
    st, r, _ = rpc(alice, "start_transformation", p_character=ch, p_creature="giant-eagle", p_options={})
    check("WA7 a form the rules do not allow (flying at Druid 6) is refused", st >= 400, (st, r))
    st, r, _ = rpc(alice, "start_transformation", p_character=ch, p_creature="no-such-beast", p_options={})
    check("WA8 an unknown creature is refused", st >= 400, st)
    st, r, _ = rpc(alice, "start_transformation", p_character=ch, p_creature="brown-bear",
                   p_options={"hp_max": 999, "hp_current": 999, "abilities": {"str": 30}, "max_cr": 20, "allowed": True, "equipment": {"mode": "merge"}})
    check("WA9 the owner transforms; client-supplied HP, scores and eligibility are ignored (34 / 34, STR 19)",
          st == 200 and r["active"]["hp_max"] == 34 and r["active"]["hp_current"] == 34 and r["active"]["sheet"]["abilities"]["str"]["score"] == 19,
          (st, r.get("active", {}).get("hp_max") if isinstance(r, dict) else r))
    check("WA10 one Wild Shape use was spent by the server", r["resources"][0]["remaining"] == 1, r["resources"])
    st, d, _ = rpc(alice, "get_character_derived_stats", p_character=ch)
    check("WA11 the derived stats use the form (STR 19, AC 11, walk 40 ft) and keep the character's WIS save +6",
          st == 200 and d["abilities"]["str"]["score"] == 19 and d["armor_class"]["value"] == 11 and d["speed"]["value"] == 40
          and d["saving_throws"]["wis"]["form_total"] == 6, st)
    st, d, _ = rpc(dm, "get_character_derived_stats", p_character=ch)
    check("WA12 the DM sees the same transformed statistics", st == 200 and d["abilities"]["str"]["score"] == 19, st)

    # direct writes
    st, body, _ = call("PATCH", f"/rest/v1/character_transformations?character_id=eq.{ch}", token=alice, body={"hp_current": 999, "hp_max": 999})
    st2, rows, _ = call("GET", f"/rest/v1/character_transformations?character_id=eq.{ch}&select=hp_current,hp_max", token=alice)
    check("WA13 the owner cannot write form hit points directly", rows == [{"hp_current": 34, "hp_max": 34}], (st, rows))
    st, body, _ = call("POST", "/rest/v1/character_seen_forms", token=alice, body={"character_id": ch, "creature_id": "giant-eagle", "source": "dm_grant"})
    st2, body2, _ = call("POST", "/rest/v1/character_wild_shape_settings", token=alice, body={"character_id": ch, "seen_mode": "unrestricted"})
    st3, body3, _ = call("POST", "/rest/v1/character_transformation_events", token=alice, body={"character_id": ch, "event_type": "started"})
    check("WA14 no direct insert into seen forms (a forged DM grant), settings or the history", min(st, st2, st3) >= 400, (st, st2, st3))
    st, body, _ = call("DELETE", f"/rest/v1/character_transformations?character_id=eq.{ch}", token=alice)
    st2, rows, _ = call("GET", f"/rest/v1/character_transformations?character_id=eq.{ch}&select=creature_id", token=alice)
    check("WA15 the form cannot be deleted directly (no free revert outside the engine)", len(rows) == 1, (st, rows))
    st, rows, _ = call("GET", f"/rest/v1/character_transformations?character_id=eq.{ch}&select=creature_id", token=bob)
    check("WA16 an outsider cannot read the form row", st == 200 and rows == [], (st, rows))

    # HP engine
    st, r, _ = rpc(alice, "damage_active_transformation", p_character=ch, p_amount=-5, p_note=None)
    check("WA17 negative damage is refused", st >= 400, st)
    st, r, _ = rpc(bob, "damage_active_transformation", p_character=ch, p_amount=5, p_note=None)
    check("WA18 an outsider cannot damage the form", st >= 400, st)
    st, r, _ = rpc(alice, "set_transformation_hp", p_character=ch, p_hp=99, p_temp=0, p_reason="test")
    check("WA19 setting form HP above the form maximum is refused", st >= 400, st)
    st, r, _ = rpc(alice, "damage_active_transformation", p_character=ch, p_amount=10, p_note=None)
    st, r, _ = rpc(alice, "combat_wild_shape_heal", p_character=ch, p_slot_level=1, p_pool="standard", p_roll=9)
    st2, rows, _ = call("GET", f"/rest/v1/character_spell_slot_state?character_id=eq.{ch}&pool=eq.standard&select=expended", token=alice)
    check("WA20 an impossible player roll (9 on 1d8) is refused and spends no slot", st >= 400 and sum(x["expended"] for x in rows) == 0, (st, rows))
    st, r, _ = rpc(alice, "damage_active_transformation", p_character=ch, p_amount=30, p_note=None)
    st2, c, _ = call("GET", f"/rest/v1/characters?id=eq.{ch}&select=hp_current", token=alice)
    check("WA21 lethal damage ends the form and carries the excess over once (24 - 30: 6, normal 40 -> 34)",
          st == 200 and r["active"] is None and r["result"]["carryover"] == 6 and c[0]["hp_current"] == 34, (st, r.get("result") if isinstance(r, dict) else r, c))

    # settings, seen forms and DM grants
    st, r, _ = rpc(alice, "set_wild_shape_settings", p_character=ch, p_seen_mode="unrestricted", p_default_equipment=None, p_confirm_lethal=None)
    check("WA22 the player cannot switch the seen rule off (unrestricted is the DM's)", st >= 400, st)
    st, r, _ = rpc(alice, "set_seen_forms", p_character=ch, p_creatures=["giant-eagle"], p_seen=True, p_source="dm_grant", p_note=None)
    check("WA23 the player cannot grant a form exception", st >= 400, st)
    st, r, _ = rpc(dm, "set_seen_forms", p_character=ch, p_creatures=["giant-eagle"], p_seen=True, p_source="dm_grant", p_note="story reward")
    eagle = next((o for o in r["options"] if o["id"] == "giant-eagle"), {}) if st == 200 else {}
    check("WA24 the campaign DM grants the Giant Eagle: allowed as a DM-granted exception", st == 200 and eagle.get("allowed") and eagle.get("status") == "dm_granted", (st, eagle))
    st, r, _ = rpc(alice, "set_seen_forms", p_character=ch, p_creatures=["giant-eagle"], p_seen=False, p_source="seen", p_note=None)
    check("WA25 the player cannot remove the DM grant", st >= 400, st)
    st, r, _ = rpc(alice, "start_transformation", p_character=ch, p_creature="giant-eagle", p_options={})
    check("WA26 the player can now take the granted form", st == 200 and r["active"]["creature_id"] == "giant-eagle", (st, r if st != 200 else ""))
    st, r, _ = rpc(bob, "end_transformation", p_character=ch, p_reason="manual")
    check("WA27 an outsider cannot end the form", st >= 400, st)
    st, r, _ = rpc(alice, "end_transformation", p_character=ch, p_reason="manual")
    check("WA28 the owner reverts; the history shows the start, the carry-over and the revert",
          st == 200 and r["active"] is None and {"transformed", "excess_damage", "reverted_manual"} <= {e["type"] for e in r["events"]}, (st, r.get("events") if isinstance(r, dict) else r))
    st, rows, _ = call("GET", f"/rest/v1/character_transformation_events?character_id=eq.{ch}&select=id", token=bob)
    check("WA29 an outsider cannot read the Wild Shape history", st == 200 and rows == [], (st, rows))
    st, r, _ = rpc(bob, "set_form_favorite", p_character=ch, p_creature="wolf", p_favorite=True)
    check("WA30 an outsider cannot change favorites", st >= 400, st)
    st, r, _ = rpc(dm, "set_wild_shape_settings", p_character=ch, p_seen_mode="unrestricted", p_default_equipment=None, p_confirm_lethal=None)
    check("WA31 the DM can set the seen rule to unrestricted", st == 200 and r["settings"]["seen_mode"] == "unrestricted", (st, r if st != 200 else ""))

    failed = [x for x in results if not x[1]]
    print(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
