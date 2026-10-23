"""API / RLS tests of the official class catalog, one section per implemented class, against the LOCAL Supabase stack.

Run by supabase/tests/run_supabase_local.sh after api_contract_test.py (same environment: API_URL, ANON_KEY,
SERVICE_ROLE_KEY of the local stack; refuses anything that is not localhost). Synthetic users (@example.test) only.
Each class section: owner reads and changes the class state through the RPCs, the campaign DM reads it, an outsider
cannot read or change it, the catalog is readable and not writable. Python 3.9+, standard library only.
"""
import json
import sys

from api_contract_test import RUN, call, check, results, rpc, svc, user


def setup():
    alice, alice_id = user("api-class-alice@example.test")
    bob, _ = user("api-class-bob@example.test")
    dm, dm_id = user("api-class-dm@example.test")
    st, camp, _ = svc("POST", "/rest/v1/campaigns", {"name": f"API Class Campaign {RUN}", "created_by": dm_id}, {"Prefer": "return=representation"})
    camp_id = camp[0]["id"]
    svc("POST", "/rest/v1/campaign_members", [{"campaign_id": camp_id, "user_id": alice_id, "role": "player"},
                                               {"campaign_id": camp_id, "user_id": dm_id, "role": "dm"}])
    return alice, alice_id, bob, dm, camp_id


def new_char(token, owner_id, camp_id, name, **scores):
    body = {"owner_id": owner_id, "name": f"{name} {RUN}", "campaign_id": camp_id}
    body.update(scores)
    st, ch, _ = svc("POST", "/rest/v1/characters", body, {"Prefer": "return=representation"})
    assert st == 201, (st, ch)
    return ch[0]["id"]


def class_row(features, class_id):
    return next((k for k in features["classes"] if k["class_id"] == class_id), None)


def catalog_section(alice, bob):
    st, rows, _ = call("GET", "/rest/v1/class_feature_versions?select=id,automation&id=like.fighter-*", token=alice)
    check("CA1 the official class feature catalog is readable by a signed-in user", st == 200 and len(rows) >= 10, st)
    st, rows, _ = call("GET", "/rest/v1/subclass_versions?select=id,implementation_status&class_id=eq.fighter")
    check("CA2 the subclass catalog is readable anonymously (10 Fighter archetypes)", st == 200 and len(rows) == 10, (st, rows))
    st, rows, _ = call("GET", "/rest/v1/class_starting_equipment?select=class_version_id&class_version_id=eq.fighter-phb", token=bob)
    check("CA3 starting equipment options are readable", st == 200 and len(rows) == 8, st)
    st, body, _ = call("POST", "/rest/v1/class_feature_versions", token=alice,
                       body={"id": f"forged-{RUN}", "feature_id": "fighter-second-wind", "name": "Forged", "summary": "x", "source_label": "x",
                             "automation": "automated"})
    check("CA4 a client cannot insert official catalog content (feature version)", st in (401, 403), (st, body))
    st, body, _ = call("PATCH", "/rest/v1/class_feature_resources?id=eq.fighter-second-wind-phb-uses", token=alice, body={"max_formula": {"fixed": 9}})
    st2, rows, _ = call("GET", "/rest/v1/class_feature_resources?select=max_formula&id=eq.fighter-second-wind-phb-uses", token=alice)
    check("CA5 a client cannot change a catalog resource formula", st in (401, 403) or (rows and rows[0]["max_formula"] == {"fixed": 1}), (st, rows))
    st, body, _ = call("POST", "/rest/v1/subclass_versions", token=alice,
                       body={"id": f"forged-sub-{RUN}", "class_id": "fighter", "name": "Forged", "source_label": "x", "source_url": "https://x"})
    check("CA6 a client cannot add a subclass to the catalog", st in (401, 403), (st, body))


def fighter_section(alice, alice_id, bob, dm, camp_id):
    ch = new_char(alice, alice_id, camp_id, "API Fighter", strength=16, dexterity=14, constitution=14)
    st, body, _ = rpc(alice, "set_character_class", p_character=ch, p_class_version="fighter-phb", p_level=3)
    check("CAF1 the owner adds Fighter 3 through the RPC", st == 200, (st, body))
    st, f, _ = rpc(alice, "get_character_class_features", p_character=ch)
    k = class_row(f, "fighter")
    check("CAF2 the read model lists the Fighter features up to level 3 and a subclass warning",
          st == 200 and k and {x["name"] for x in k["features"]} >= {"Fighting Style", "Second Wind", "Action Surge", "Martial Archetype"}
          and any(w["code"] == "subclass_not_chosen" for w in f["warnings"]), (st, f.get("warnings") if isinstance(f, dict) else f))
    st, body, _ = rpc(alice, "set_character_subclass", p_character=ch, p_character_class=k["id"], p_subclass_version="fighter-champion-phb")
    check("CAF3 the owner chooses the Champion", st == 200, (st, body))
    st, body, _ = rpc(alice, "set_character_feature_choice", p_character=ch, p_character_class=k["id"], p_unlock="fighter-phb-u1-fighting-style",
                      p_choice="fighter-fighting-style-phb-style", p_values=["defense"])
    check("CAF4 the owner chooses a fighting style", st == 200, (st, body))
    st, d, _ = rpc(alice, "get_character_derived_stats", p_character=ch)
    check("CAF5 derived: critical range 19 (Improved Critical)", st == 200 and d["critical_range"]["value"] == 19, d.get("critical_range") if isinstance(d, dict) else d)
    key = f"f:{k['id']}:fighter-action-surge-phb-uses"
    st, r, _ = rpc(alice, "expend_character_resource", p_character=ch, p_resource_key=key)
    check("CAF6 the owner spends Action Surge (0 / 1 left)", st == 200 and r["remaining"] == 0, (st, r))
    st, r, _ = rpc(alice, "expend_character_resource", p_character=ch, p_resource_key=key)
    check("CAF7 a second use is refused", st >= 400, (st, r))
    st, f, _ = rpc(dm, "get_character_class_features", p_character=ch)
    check("CAF8 the campaign DM reads the Fighter state", st == 200 and class_row(f, "fighter") is not None, st)
    st, f, _ = rpc(bob, "get_character_class_features", p_character=ch)
    check("CAF9 an outsider cannot read the Fighter state", st >= 400, (st, f))
    st, r, _ = rpc(bob, "expend_character_resource", p_character=ch, p_resource_key=f"f:{k['id']}:fighter-second-wind-phb-uses")
    check("CAF10 an outsider cannot spend Second Wind", st >= 400, (st, r))
    st, r, _ = rpc(bob, "set_character_feature_choice", p_character=ch, p_character_class=k["id"], p_unlock="fighter-phb-u1-fighting-style",
                   p_choice="fighter-fighting-style-phb-style", p_values=["archery"])
    check("CAF11 an outsider cannot change the fighting style", st >= 400, (st, r))
    st, rows, _ = call("GET", f"/rest/v1/character_feature_choices?select=id&character_id=eq.{ch}", token=bob)
    check("CAF12 raw choice rows are private (outsider sees none)", st == 200 and rows == [], (st, rows))
    st, body, _ = call("POST", "/rest/v1/character_feature_choices", token=alice,
                       body={"character_id": ch, "character_class_id": k["id"], "unlock_id": "fighter-phb-u1-fighting-style",
                             "choice_id": "fighter-fighting-style-phb-style"})
    check("CAF13 even the owner cannot write choice rows directly (RPC only)", st in (401, 403), (st, body))
    st, r, _ = rpc(alice, "short_rest_character", p_character=ch)
    st2, res, _ = rpc(alice, "get_character_resources", p_character=ch)
    surge = next((x for x in res["resources"] if x["resource_id"] == "fighter-action-surge-phb-uses"), {})
    check("CAF14 a short rest restores Action Surge", st == 200 and surge.get("remaining") == 1, (st, surge))
    st, p, _ = rpc(alice, "preview_character_class_change", p_character=ch, p_character_class=k["id"], p_level=5)
    check("CAF15 the level review previews Extra Attack at 5 without storing anything",
          st == 200 and any(x["name"] == "Extra Attack" for x in p["features_activated"]), (st, p))


def rogue_section(alice, alice_id, bob, dm, camp_id):
    ch = new_char(alice, alice_id, camp_id, "API Rogue", dexterity=16)
    st, body, _ = rpc(alice, "set_character_class", p_character=ch, p_class_version="rogue-phb", p_level=5)
    k = class_row(rpc(alice, "get_character_class_features", p_character=ch)[1], "rogue")
    check("CAR1 the owner adds Rogue 5", st == 200 and k is not None, (st, body))
    st, body, _ = rpc(alice, "set_character_feature_choice", p_character=ch, p_character_class=k["id"], p_unlock="rogue-phb-u1-proficiencies",
                      p_choice="rogue-proficiencies-phb-skills", p_values=["stealth", "perception", "acrobatics", "insight"])
    st2, body2, _ = rpc(alice, "set_character_feature_choice", p_character=ch, p_character_class=k["id"], p_unlock="rogue-phb-u1-expertise",
                        p_choice="rogue-expertise-phb-expertise", p_values=["stealth", "thieves-tools"])
    check("CAR2 the owner chooses four skills and Expertise (Stealth, thieves' tools)", st == 200 and st2 == 200, (st2, body2))
    st, d, _ = rpc(alice, "get_character_derived_stats", p_character=ch)
    sneak = next((r for r in d.get("attack_riders", []) if r["name"] == "Sneak Attack"), None)
    check("CAR3 derived: Sneak Attack 3d6 at Rogue 5; Stealth expertise", st == 200 and sneak and sneak["dice"] == "3d6"
          and d["skills"]["stealth"].get("class_expertise"), (sneak, d.get("skills", {}).get("stealth")))
    st, f, _ = rpc(dm, "get_character_class_features", p_character=ch)
    check("CAR4 the campaign DM reads the Rogue state", st == 200 and class_row(f, "rogue") is not None, st)
    st, f, _ = rpc(bob, "get_character_derived_stats", p_character=ch)
    check("CAR5 an outsider cannot read the derived Rogue values", st >= 400, st)
    st, body, _ = rpc(bob, "set_character_subclass", p_character=ch, p_character_class=k["id"], p_subclass_version="rogue-thief-phb")
    check("CAR6 an outsider cannot choose the Rogue archetype", st >= 400, (st, body))


def caster_section(alice, alice_id, bob, dm, camp_id):
    # Wizard: spellbook acquisition and Arcane Recovery
    ch = new_char(alice, alice_id, camp_id, "API Wizard", intelligence=16)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="wizard-phb", p_level=5)
    k = class_row(rpc(alice, "get_character_class_features", p_character=ch)[1], "wizard")
    book = rpc(alice, "get_character_spellbook", p_character=ch)[1]
    src = next(x for x in book["sources"] if x.get("class_version_id") == "wizard-phb")
    st, row, _ = rpc(alice, "set_character_spell", p_character=ch, p_source=src["id"], p_spell_version="magic-missile-phb")
    st2, b2, _ = rpc(alice, "set_character_spell_acquisition", p_character_spell=row["id"], p_acquisition="copied")
    sb = next(x for x in b2["sources"] if x.get("id") == src["id"])["spellbook"] if st2 == 200 else {}
    check("CAW1 the owner records a copied spell; the spellbook summary counts it", st == 200 and st2 == 200 and sb.get("by_acquisition", {}).get("copied") == 1, (st2, sb))
    st, r, _ = rpc(bob, "set_character_spell_acquisition", p_character_spell=row["id"], p_acquisition="scroll")
    check("CAW2 an outsider cannot change the spellbook record", st >= 400, st)
    rpc(alice, "expend_standard_spell_slot", p_character=ch, p_slot_level=2)
    key = f"f:{k['id']}:wizard-arcane-recovery-phb-uses"
    st, r, _ = rpc(bob, "recover_spell_slots", p_character=ch, p_resource_key=key, p_slot_levels=[2])
    check("CAW3 an outsider cannot use Arcane Recovery", st >= 400, st)
    st, r, _ = rpc(dm, "recover_spell_slots", p_character=ch, p_resource_key=key, p_slot_levels=[2])
    check("CAW4 the campaign DM may run Arcane Recovery for the character (character access policy)", st == 200, (st, r))
    st, r, _ = rpc(alice, "recover_spell_slots", p_character=ch, p_resource_key=key, p_slot_levels=[1])
    check("CAW5 a second recovery is refused", st >= 400, (st, r))
    # Sorcerer: Flexible Casting
    ch = new_char(alice, alice_id, camp_id, "API Sorcerer", charisma=16)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="sorcerer-phb", p_level=3)
    k = class_row(rpc(alice, "get_character_class_features", p_character=ch)[1], "sorcerer")
    key = f"f:{k['id']}:sorcerer-font-of-magic-phb-points"
    st, r, _ = rpc(alice, "convert_spell_slot", p_character=ch, p_resource_key=key, p_direction="points_to_slot", p_slot_level=1)
    check("CAS1 the owner creates a 1st-level slot from 2 sorcery points (1 left, one temporary slot)",
          st == 200 and r["resource"]["remaining"] == 1 and len(r["slots"]["temporary"]) == 1, (st, r))
    tid = r["slots"]["temporary"][0]["id"] if st == 200 else None
    st, r, _ = rpc(bob, "use_temporary_spell_slot", p_character=ch, p_slot=tid)
    check("CAS2 an outsider cannot use the temporary slot", st >= 400, st)
    st, rows, _ = call("GET", f"/rest/v1/character_temporary_spell_slots?select=id&character_id=eq.{ch}", token=bob)
    check("CAS3 temporary slots are private", st == 200 and rows == [], (st, rows))
    st, r, _ = rpc(alice, "convert_spell_slot", p_character=ch, p_resource_key=key, p_direction="points_to_slot", p_slot_level=6)
    check("CAS4 a 6th-level slot cannot be created", st >= 400, (st, r))
    # Bard: Magical Secrets
    ch = new_char(alice, alice_id, camp_id, "API Bard", charisma=16)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="bard-phb", p_level=10)
    k = class_row(rpc(alice, "get_character_class_features", p_character=ch)[1], "bard")
    st, r, _ = rpc(alice, "set_character_feature_choice", p_character=ch, p_character_class=k["id"], p_unlock="bard-phb-u10-magical-secrets",
                   p_choice="bard-magical-secrets-phb-spells", p_values=["disintegrate-phb", "fireball-phb"])
    check("CAB1 Magical Secrets refuses a 6th-level spell at Bard 10", st >= 400 and "up to level 5" in str(r), (st, r))
    st, r, _ = rpc(alice, "set_character_feature_choice", p_character=ch, p_character_class=k["id"], p_unlock="bard-phb-u10-magical-secrets",
                   p_choice="bard-magical-secrets-phb-spells", p_values=["fireball-phb", "hunters-mark-phb"])
    check("CAB2 Magical Secrets accepts spells of other lists within the castable level", st == 200, (st, r))
    # Cleric: domain spells through the spellbook read model
    ch = new_char(alice, alice_id, camp_id, "API Cleric", wisdom=16)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="cleric-phb", p_level=1, p_subclass_version="cleric-life-phb")
    st, b3, _ = rpc(dm, "get_character_spellbook", p_character=ch)
    bless = next((x for x in b3.get("spells", []) if x["id"] == "bless-phb"), None) if st == 200 else None
    check("CAC1 the campaign DM sees the Life Domain spells as always prepared", bless and any(g.get("always_prepared") for g in bless["grants"]), (st, bless))
    st, r, _ = rpc(bob, "get_character_spellbook", p_character=ch)
    check("CAC2 an outsider cannot read the Cleric spellbook", st >= 400, st)


def hybrid_section(alice, alice_id, bob, dm, camp_id):
    # Paladin: Lay on Hands by amount, auras in the derived values
    ch = new_char(alice, alice_id, camp_id, "API Paladin", strength=16, charisma=16)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="paladin-phb", p_level=6, p_subclass_version="paladin-devotion-phb")
    st, res, _ = rpc(alice, "get_character_resources", p_character=ch)
    loh = next((r for r in res.get("resources", []) if r["resource_id"] == "paladin-lay-on-hands-phb-pool"), None) if st == 200 else None
    st, r, _ = rpc(alice, "expend_character_resource", p_character=ch, p_resource_key=loh["key"], p_amount=12)
    check("CAP1 the owner spends 12 of the 30-point Lay on Hands pool", st == 200 and r.get("remaining") == 18, (st, r))
    st, r, _ = rpc(bob, "expend_character_resource", p_character=ch, p_resource_key=loh["key"], p_amount=1)
    check("CAP2 an outsider cannot spend Lay on Hands", st >= 400, st)
    st, d, _ = rpc(dm, "get_character_derived_stats", p_character=ch)
    check("CAP3 the campaign DM reads Aura of Protection (+3 on saves) and the disease immunity",
          st == 200 and d["saving_throws"]["dex"].get("class_bonus") == 3 and "disease" in d.get("condition_immunities", []), (st, d.get("saving_throws", {}).get("dex")))
    smite = next((x for x in d.get("attack_riders", []) if x["name"] == "Divine Smite"), None) if st == 200 else None
    check("CAP4 Divine Smite is a slot rider (standard pool, 2d8 at 1st)", smite and smite["uses_slot"] and smite["slot_pool"] == "standard"
          and smite["dice_by_slot"]["1"] == "2d8", smite)
    # Ranger: optional replacements are owner-only
    ch = new_char(alice, alice_id, camp_id, "API Ranger", dexterity=16, wisdom=14)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="ranger-phb", p_level=1)
    k = class_row(rpc(alice, "get_character_class_features", p_character=ch)[1], "ranger")
    st, r, _ = rpc(bob, "set_character_optional_feature", p_character=ch, p_character_class=k["id"], p_unlock="ranger-phb-u1-favored-foe", p_enabled=True)
    check("CAN1 an outsider cannot switch on Favored Foe", st >= 400, st)
    st, r, _ = rpc(alice, "set_character_optional_feature", p_character=ch, p_character_class=k["id"], p_unlock="ranger-phb-u1-favored-foe", p_enabled=True)
    st2, d, _ = rpc(alice, "get_character_derived_stats", p_character=ch)
    check("CAN2 the owner switches it on: the Favored Foe rider appears", st == 200 and any(x["name"] == "Favored Foe" for x in d.get("attack_riders", [])), (st, r))
    # Warlock: invocation prerequisites and the Pact pool
    ch = new_char(alice, alice_id, camp_id, "API Warlock", charisma=16)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="warlock-phb", p_level=2, p_subclass_version="warlock-fiend-phb")
    k = class_row(rpc(alice, "get_character_class_features", p_character=ch)[1], "warlock")
    st, r, _ = rpc(alice, "set_character_feature_choice", p_character=ch, p_character_class=k["id"], p_unlock="warlock-phb-u2-eldritch-invocations",
                   p_choice="warlock-eldritch-invocations-phb-invocations", p_values=["agonizing-blast", "devils-sight"])
    check("CAK1 Agonizing Blast is refused before Eldritch Blast is known", st >= 400 and "Eldritch Blast" in str(r), (st, r))
    st, r, _ = rpc(alice, "set_character_feature_choice", p_character=ch, p_character_class=k["id"], p_unlock="warlock-phb-u2-eldritch-invocations",
                   p_choice="warlock-eldritch-invocations-phb-invocations", p_values=["devils-sight", "beguiling-influence"])
    check("CAK2 two invocations without prerequisites are accepted", st == 200, (st, r))
    st, b, _ = rpc(dm, "get_character_spellbook", p_character=ch)
    src = next((x for x in b.get("sources", []) if x.get("class_version_id") == "warlock-phb"), None) if st == 200 else None
    check("CAK3 the campaign DM sees the Fiend expanded spells on the Warlock source", src and len(src.get("expanded_spells") or []) == 10, src and src.get("expanded_spells"))
    st, r, _ = rpc(bob, "expend_pact_magic_slot", p_character=ch)
    check("CAK4 an outsider cannot spend a Pact slot", st >= 400, st)


def engines_section(alice, alice_id, bob, dm, camp_id):
    # Barbarian: Rage state
    ch = new_char(alice, alice_id, camp_id, "API Barbarian", strength=16, constitution=16)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="barbarian-phb", p_level=3)
    st, r, _ = rpc(bob, "start_character_state", p_character=ch, p_state="rage")
    check("CAE1 an outsider cannot start Rage", st >= 400, st)
    st, r, _ = rpc(alice, "start_character_state", p_character=ch, p_state="rage")
    check("CAE2 the owner starts Rage (a use is spent)", st == 200 and r["states"][0]["active"] and r["states"][0]["resource"]["remaining"] == 2, (st, r))
    st, d, _ = rpc(dm, "get_character_derived_stats", p_character=ch)
    check("CAE3 the campaign DM sees the Rage resistances", st == 200 and "slashing" in json.dumps(d.get("resistances")), st)
    st, rows, _ = call("GET", f"/rest/v1/character_active_states?character_id=eq.{ch}&select=state_key", token=bob)
    check("CAE4 state rows are private (outsider sees none)", st == 200 and rows == [], (st, rows))
    st, body, _ = call("POST", "/rest/v1/character_active_states", token=alice, body={"character_id": ch, "state_key": "rage",
                                                                                     "character_class_id": ch, "feature_version_id": "x"})
    check("CAE5 even the owner cannot write state rows directly", st in (401, 403), (st, body))
    # Druid: Wild Shape and companions
    ch = new_char(alice, alice_id, camp_id, "API Druid", wisdom=16)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="druid-phb", p_level=2)
    st, r, _ = rpc(alice, "start_transformation", p_character=ch, p_creature="owl")
    check("CAE6 Druid 2 cannot take a flying form (owl, CR 0): the refusal says why", st >= 400 and "flying forms need Druid level 8" in str(r), (st, r))
    st, r, _ = rpc(alice, "start_transformation", p_character=ch, p_creature="wolf")
    check("CAE7 the owner takes the wolf form", st == 200 and r["active"]["creature_id"] == "wolf", (st, r))
    st, r, _ = rpc(dm, "get_character_transformation", p_character=ch)
    check("CAE8 the campaign DM reads the current form", st == 200 and r["active"]["name"] == "Wolf", st)
    st, r, _ = rpc(bob, "change_transformation_hp", p_character=ch, p_delta=-5)
    check("CAE9 an outsider cannot damage the form", st >= 400, st)
    st, cid, _ = rpc(alice, "add_character_companion", p_character=ch, p_creature="owl", p_name="Hoot", p_source=None, p_hp_max=None)
    check("CAE10 the owner adds an owl companion", st == 200 and cid, (st, cid))
    st, rows, _ = call("GET", f"/rest/v1/character_companions?character_id=eq.{ch}&select=name", token=bob)
    check("CAE11 companions are private (outsider sees none)", st == 200 and rows == [], (st, rows))
    st, r, _ = rpc(bob, "remove_character_companion", p_companion=cid)
    check("CAE12 an outsider cannot remove the companion", st >= 400, st)
    st, rows, _ = call("GET", "/rest/v1/creatures?select=id&creature_type=eq.beast&limit=5", token=bob)
    check("CAE13 the creature catalog is readable by any signed-in user", st == 200 and len(rows) == 5, st)
    # Artificer: infusions
    ch = new_char(alice, alice_id, camp_id, "API Artificer", intelligence=16)
    rpc(alice, "set_character_class", p_character=ch, p_class_version="artificer-tce", p_level=2)
    k = class_row(rpc(alice, "get_character_class_features", p_character=ch)[1], "artificer")
    rpc(alice, "set_character_feature_choice", p_character=ch, p_character_class=k["id"], p_unlock="artificer-tce-u2-infuse-item",
        p_choice="artificer-infuse-item-tce-infusions", p_values=["enhanced-weapon", "enhanced-defense", "replicate-magic-item", "returning-weapon"])
    st, inv, _ = call("GET", f"/rest/v1/inventories?character_id=eq.{ch}&kind=eq.character&select=id", token=alice)
    st, item, _ = rpc(alice, "add_inventory_item", p_inventory=inv[0]["id"], p_item="spear", p_quantity=1)
    st, r, _ = rpc(bob, "apply_infusion", p_character=ch, p_infusion="returning-weapon", p_inventory_item=item, p_replicate_item=None)
    check("CAE14 an outsider cannot infuse the item", st >= 400, st)
    st, r, _ = rpc(alice, "apply_infusion", p_character=ch, p_infusion="returning-weapon", p_inventory_item=item, p_replicate_item=None)
    check("CAE15 the owner infuses the spear with Returning Weapon (thrown)", st == 200 and len(r["active"]) == 1, (st, r))
    st, body, _ = call("POST", "/rest/v1/inventory_item_modifiers", token=alice, body={"inventory_item_id": item, "modifier_id": "infusion-enhanced-weapon-l2"})
    check("CAE16 infusion modifiers cannot be applied directly", st >= 400, (st, body))
    st, rows, _ = call("GET", f"/rest/v1/character_infusions?character_id=eq.{ch}&select=id", token=dm)
    check("CAE17 the campaign DM reads the infusion rows", st == 200 and len(rows) == 1, (st, rows))
    # guided setup
    ch = new_char(alice, alice_id, camp_id, "API New", strength=14, dexterity=14)
    st, p, _ = rpc(alice, "preview_character_class_add", p_character=ch, p_class_version="fighter-phb", p_level=1, p_subclass_version=None)
    check("CAE18 Add Class preview: Fighter 1 as the first class (starting equipment groups, nothing stored)",
          st == 200 and p["possible"] and p["first_class"] and len(p["starting_equipment"]["groups"]) == 4, (st, p if st != 200 else p.get("error")))
    st, p, _ = rpc(bob, "preview_character_class_add", p_character=ch, p_class_version="fighter-phb", p_level=1, p_subclass_version=None)
    check("CAE19 an outsider cannot preview", st >= 400, st)


def main():
    alice, alice_id, bob, dm, camp_id = setup()
    catalog_section(alice, bob)
    fighter_section(alice, alice_id, bob, dm, camp_id)
    rogue_section(alice, alice_id, bob, dm, camp_id)
    caster_section(alice, alice_id, bob, dm, camp_id)
    hybrid_section(alice, alice_id, bob, dm, camp_id)
    engines_section(alice, alice_id, bob, dm, camp_id)
    failed = [r for r in results if not r[1]]
    print(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
