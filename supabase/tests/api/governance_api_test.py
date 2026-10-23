"""API / RLS tests of campaign governance, change requests, feats, DM content and hidden DM data (20261019000100-000600)
against the LOCAL Supabase stack (GoTrue + PostgREST with real JWTs).

Run by supabase/tests/run_supabase_local.sh after wild_shape_api_test.py (same environment; refuses anything that is not
localhost through api_contract_test). Synthetic users (@example.test) only.
"""
import json
import sys
import uuid

from api_contract_test import RUN, call, check, results, rpc, svc, user


def ok(st):
    return 200 <= st < 300


def main():
    alice, alice_id = user("api-gov-alice@example.test")
    bob, _ = user("api-gov-bob@example.test")
    dm, dm_id = user("api-gov-dm@example.test")
    dm2, dm2_id = user("api-gov-dm2@example.test")
    st, camp, _ = svc("POST", "/rest/v1/campaigns", {"name": f"API Governance {RUN}", "created_by": dm_id}, {"Prefer": "return=representation"})
    camp = camp[0]["id"]
    svc("POST", "/rest/v1/campaign_members", [{"campaign_id": camp, "user_id": alice_id, "role": "player"}, {"campaign_id": camp, "user_id": dm_id, "role": "dm"},
                                               {"campaign_id": camp, "user_id": dm2_id, "role": "dm"}])
    svc("POST", "/rest/v1/campaign_governance", {"campaign_id": camp, "preset": "standard"})

    def char(name, cls, lvl, **kw):
        body = {"owner_id": alice_id, "name": f"{name} {RUN}", "campaign_id": camp, "hp_max": 20, "hp_current": 20, **kw}
        st, rows, _ = svc("POST", "/rest/v1/characters", body, {"Prefer": "return=representation"})
        cid = rows[0]["id"]
        st, b, _ = rpc(dm, "set_character_class", p_character=cid, p_class_version=cls, p_level=lvl)
        assert ok(st), b
        svc("POST", "/rest/v1/character_governance", {"character_id": cid, "setup_complete": True})
        return cid

    fighter = char("API Fighter", "fighter-phb", 3, strength=15, constitution=14)
    wizard = char("API Wizard", "wizard-phb", 1, intelligence=16)
    druid = char("API Druid", "druid-phb", 2, wisdom=16)

    # ---- governance -------------------------------------------------------------------------------------------------------
    st, g, _ = rpc(alice, "get_character_governance", p_character=fighter)
    check("GA1 the player reads the effective governance of the character",
          ok(st) and g["decisions"]["build.class_level"] == "approval_required" and g["decisions"]["runtime.hp"] == "player_managed", (st, g))
    st, body, _ = call("PATCH", f"/rest/v1/characters?id=eq.{fighter}", token=alice, body={"hp_current": 15})
    check("GA2 a player-managed write (current HP) is accepted", ok(st), (st, body))
    st, body, _ = call("PATCH", f"/rest/v1/characters?id=eq.{fighter}", token=alice, body={"strength": 20})
    check("GA3 an approval-required write is refused with TLAPR", st >= 400 and "TLAPR" in json.dumps(body), (st, body))
    st, body, _ = rpc(alice, "create_dm_content", p_type="spell", p_campaign=camp, p_fields={"name": "Nope"})
    check("GA4 a DM-only operation (content creation) is refused for the player", st >= 400 and "TLDMO" in json.dumps(body), (st, body))
    st, body, _ = rpc(alice, "set_campaign_governance", p_campaign=camp, p_settings={"preset": "relaxed"})
    check("GA5 a player cannot change the campaign rules", st >= 400, st)

    # ---- requests ----------------------------------------------------------------------------------------------------------
    st, req, _ = rpc(alice, "create_change_request", p_character=fighter, p_ops=[{"op": "assign_character_feat", "args": {"p_version": "tough-2024"}}],
                     p_title="Tough", p_idempotency_key=str(uuid.uuid4()))
    check("GA6 the player creates an allowed proposal (submitted, with a diff)", ok(st) and req["status"] == "submitted" and req["preview"]["diff"], (st, req))
    st, inbox, _ = rpc(dm, "get_campaign_change_requests", p_campaign=camp)
    check("GA7 the DM reads the approval inbox", ok(st) and any(r["id"] == req["id"] for r in inbox), st)
    st, inbox, _ = rpc(bob, "get_campaign_change_requests", p_campaign=camp)
    check("GA8 an outsider cannot read the inbox", st >= 400, st)
    st, res, _ = rpc(dm, "review_change_request", p_request=req["id"], p_decision="approve", p_private_note="watch this one")
    check("GA9 the DM approves; it is applied", ok(st) and res["status"] == "applied", (st, res))
    st, feats, _ = rpc(alice, "get_character_feats", p_character=fighter)
    check("GA10 the result appears on the character (Tough, +6 maximum HP at level 3)",
          ok(st) and any(f["feat"]["id"] == "tough-2024" for f in feats["feats"]) and feats["hit_points"]["feat_bonus"] == 6, feats.get("hit_points"))
    st, res2, _ = rpc(dm2, "review_change_request", p_request=req["id"], p_decision="approve")
    check("GA11 a second DM cannot apply it twice", st >= 400, (st, res2))
    st, rows, _ = call("GET", f"/rest/v1/change_request_private_notes?request_id=eq.{req['id']}", token=alice)
    check("GA12 the player cannot read the DM's private note", ok(st) and rows == [], rows)
    st, req2, _ = rpc(alice, "create_change_request", p_character=fighter, p_ops=[{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 4}}],
                      p_idempotency_key=str(uuid.uuid4()))
    rpc(dm, "set_character_class", p_character=fighter, p_class_version="fighter-phb", p_level=4)
    st, res, _ = rpc(dm, "review_change_request", p_request=req2["id"], p_decision="approve")
    check("GA13 a stale request is refused safely", ok(st) and res.get("refused") == "stale", (st, res))
    st, body, _ = call("POST", "/rest/v1/change_requests", token=alice, body={"campaign_id": camp, "character_id": fighter, "requested_by": dm_id,
                                                                              "category": "core_build", "action_type": "build.class_level", "title": "forged"})
    check("GA14 a forged request (other requester, direct insert) is refused", st >= 400, st)

    # ---- hidden data -------------------------------------------------------------------------------------------------------
    rpc(dm, "save_dm_note", p_character=fighter, p_title="Secret", p_body="The ring is cursed")
    rpc(dm, "apply_character_condition", p_character=fighter, p_version=None, p_name="Doomed", p_hidden=True, p_expires=None, p_note=None)
    leaks = []
    for t in ("dm_character_notes", "character_conditions", "item_secrets", "change_request_private_notes", "dm_content", "dm_content_versions"):
        st, rows, _ = call("GET", f"/rest/v1/{t}?select=*", token=alice)
        if st != 200 or rows:
            leaks.append((t, st, rows))
    st, conds, _ = rpc(alice, "get_character_conditions", p_character=fighter)
    check("GA15 the player cannot read hidden DM data (tables and read models)", not leaks and conds == [], (leaks, conds))

    # ---- custom content ------------------------------------------------------------------------------------------------------
    st, sp, _ = rpc(dm, "create_dm_content", p_type="spell", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={"name": f"API Spark {RUN}",
                    "dm_notes": "secret origin", "definition": {"level": 0, "school": "evocation", "class_lists": ["wizard-spell-list"],
                    "range": {"type": "distance", "distance": 60}, "components": {"v": True}, "attack_type": "ranged",
                    "effects": [{"category": "damage", "dice": "1d10", "damage_types": ["fire"]}]}})
    check("GA16 the DM creates a spell draft", ok(st) and sp["status"] == "draft", (st, sp))
    st, rows, _ = call("GET", f"/rest/v1/spell_versions?name=eq.API Spark {RUN}", token=alice)
    check("GA17 the draft is not in the player's catalog", ok(st) and rows == [], rows)
    st, sp, _ = rpc(dm, "publish_dm_content", p_content=sp["id"])
    ref = next(v["catalog_ref"] for v in sp["versions"] if v["status"] == "published")
    check("GA18 the DM publishes the spell", ok(st) and sp["status"] == "published", st)
    st, det, _ = rpc(alice, "get_spell_detail", p_version=ref)
    check("GA19 the player sees the published spell, without the DM notes", ok(st) and "secret origin" not in json.dumps(det), st)
    st, rows, _ = call("GET", f"/rest/v1/spell_versions?id=eq.{ref}", token=bob)
    check("GA20 an outsider does not see the campaign spell", ok(st) and rows == [], rows)
    st, body, _ = call("PATCH", f"/rest/v1/spell_versions?id=eq.{ref}", token=alice, body={"name": "Hacked"})
    st2, body2, _ = rpc(alice, "save_dm_content", p_content=sp["id"], p_fields={"name": "Hacked"})
    check("GA21 the player can edit neither the catalog row nor the definition", st >= 400 and st2 >= 400, (st, st2))
    st, res, _ = rpc(dm, "dm_assign_content", p_content=sp["id"], p_characters=[wizard], p_mode="innate", p_options={})
    st2, book, _ = rpc(alice, "get_character_spellbook", p_character=wizard)
    check("GA22 the DM assigns the spell; the player's spellbook has it (campaign scope)",
          ok(st) and res["results"][0]["ok"] and any(s["id"] == ref and s["scope"] == "campaign" for s in book["spells"]), (res, st2))
    st, it, _ = rpc(dm, "create_dm_content", p_type="item", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={"name": f"API Ring {RUN}",
                    "definition": {"item": {"kind_id": "gear", "is_magic": True, "rarity_id": "rare"}, "hidden": {"unidentified_name": "Plain ring", "curse": "It bites"}}})
    st, it, _ = rpc(dm, "publish_dm_content", p_content=it["id"])
    iref = next(v["catalog_ref"] for v in it["versions"] if v["status"] == "published")
    rpc(dm, "dm_assign_content", p_content=it["id"], p_characters=[fighter], p_mode="inventory", p_options={"identified": False})
    st, rows, _ = call("GET", f"/rest/v1/items?id=eq.{iref}", token=alice)
    st2, inv, _ = call("GET", f"/rest/v1/v_inventory_detail?character_id=eq.{fighter}&item_id=eq.{iref}&select=name,kind_id", token=alice)
    st3, know, _ = rpc(alice, "get_character_item_knowledge", p_character=fighter)
    check("GA23 an unidentified item hides its mechanics, true name and curse",
          rows == [] and inv == [{"name": "Plain ring", "kind_id": None}] and "It bites" not in json.dumps(know) and f"API Ring {RUN}" not in json.dumps(know), (rows, inv, know))
    ii = svc("GET", f"/rest/v1/inventory_items?item_id=eq.{iref}&select=id")[1][0]["id"]
    rpc(dm, "set_item_knowledge", p_inventory_item=ii, p_state="partially_identified", p_revealed=["magic"], p_magic_known=None)
    st, know, _ = rpc(alice, "get_character_item_knowledge", p_character=fighter)
    check("GA24 a reveal exposes only the selected facts", know[0]["facts"]["magic"] is True and know[0]["curse"] is None, know)
    st, ft, _ = rpc(dm, "create_dm_content", p_type="feat", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={"name": f"API Swift {RUN}", "ruleset": "2024",
                    "definition": {"category": "general", "effects": [{"type": "speed_bonus", "value": 10}]}})
    rpc(dm, "publish_dm_content", p_content=ft["id"])
    st, res, _ = rpc(dm, "dm_assign_content", p_content=ft["id"], p_characters=[wizard], p_mode="dm_grant", p_options={})
    st2, d, _ = rpc(alice, "get_character_derived_stats", p_character=wizard)
    check("GA25 a custom feat's effect resolves (speed 30 -> 40)", ok(st) and res["results"][0]["ok"] and d["speed"]["value"] == 40, (res, d.get("speed") if isinstance(d, dict) else d))
    st, cr, _ = rpc(dm, "create_dm_content", p_type="creature", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={"name": f"API Fox {RUN}",
                    "definition": {"size": "Small", "creature_type": "beast", "armor_class": 13, "hit_points": 9, "speed": {"walk": 40},
                                   "abilities": {"str": 8, "dex": 16, "con": 12, "int": 4, "wis": 12, "cha": 6}, "challenge_rating": 0.25}})
    st, cr, _ = rpc(dm, "publish_dm_content", p_content=cr["id"])
    cref = next(v["catalog_ref"] for v in cr["versions"] if v["status"] == "published")
    st, body, _ = rpc(alice, "set_seen_forms", p_character=druid, p_creatures=[cref])
    check("GA26 the player cannot self-grant a custom Wild Shape form", st >= 400, (st, body))
    rpc(dm, "dm_assign_content", p_content=cr["id"], p_characters=[druid], p_mode="seen_form", p_options={})
    st, tf, _ = rpc(alice, "get_character_transformation", p_character=druid)
    check("GA27 after the DM grant the Druid has the form", any(o["id"] == cref and o["allowed"] for o in tf["options"]), st)
    st, cp, _ = rpc(dm, "create_dm_content", p_type="companion", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={"name": f"API Hound {RUN}",
                    "definition": {"creature": {"size": "Medium", "creature_type": "beast", "armor_class": 13, "hit_points": 11, "speed": {"walk": 40},
                                                "abilities": {"str": 12, "dex": 14, "con": 12, "int": 3, "wis": 12, "cha": 6}, "challenge_rating": 0.25}}})
    rpc(dm, "publish_dm_content", p_content=cp["id"])
    st, res, _ = rpc(dm, "dm_assign_content", p_content=cp["id"], p_characters=[wizard], p_mode="companion", p_options={"name": "Ash"})
    st2, comps, _ = call("GET", f"/rest/v1/character_companions?character_id=eq.{wizard}&select=name,template_version_id", token=alice)
    check("GA28 a companion template assignment creates the companion", ok(st) and any(c["name"] == "Ash" and c["template_version_id"] for c in comps), comps)
    rpc(dm, "set_campaign_governance", p_campaign=camp, p_settings={"content": {"allow_custom": False}})
    inv_id = svc("GET", f"/rest/v1/inventories?character_id=eq.{wizard}&select=id")[1][0]["id"]
    st, body, _ = rpc(alice, "add_inventory_item", p_inventory=inv_id, p_item=iref)
    check("GA29 the campaign content policy filters the player's new picks", st >= 400, (st, body))
    rpc(dm, "set_campaign_governance", p_campaign=camp, p_settings={"content": {"allow_custom": True}})

    # ---- export / import / audit -----------------------------------------------------------------------------------------------
    st, ex, _ = rpc(alice, "export_character_feats", p_character=fighter)
    st2, imp, _ = rpc(alice, "import_character_feats", p_character=wizard, p_feats=[{"feat_version_id": "alert-2014", "feat_name": "Alert", "source_type": "direct"}])
    check("GA30 export keeps exact versions; an import cannot bypass governance (needs the DM)",
          ok(st) and any(e["feat_version_id"] == "tough-2024" for e in ex) and imp["report"][0]["status"] == "needs_dm", (ex, imp))
    st, au, _ = rpc(alice, "get_campaign_audit", p_campaign=camp)
    st2, aud, _ = rpc(dm, "get_campaign_audit", p_campaign=camp)
    check("GA31 the audit log follows visibility (no DM-only events for the player, the DM sees them)",
          ok(st) and not any(e.get("visibility") for e in au) and not any("Hidden" in e["summary"] for e in au)
          and any(e.get("visibility") == "dm" for e in aud), (len(au), len(aud)))
    st, back, _ = rpc(alice, "export_campaign_dm_backup", p_campaign=camp)
    st2, back2, _ = rpc(dm, "export_campaign_dm_backup", p_campaign=camp)
    check("GA32 the DM backup (with hidden data) is DM-only", st >= 400 and ok(st2) and "The ring is cursed" in json.dumps(back2), (st, st2))

    # cleanup: synthetic characters first (custom items in their inventories keep the campaign), then the campaigns
    svc("DELETE", f"/rest/v1/characters?id=in.({fighter},{wizard},{druid})")
    svc("DELETE", f"/rest/v1/campaigns?id=eq.{camp}")
    failed = [r[0] for r in results if not r[1]]
    print(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


main()
