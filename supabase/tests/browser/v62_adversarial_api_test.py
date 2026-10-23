"""V6.2 adversarial API test against the LOCAL Supabase stack (real JWTs through PostgREST): authorization matrix, hidden-marker
sweep of every readable table and the player read models, approval atomicity and concurrency, custom-content version integrity
for every content type, validation, server-side numeric boundaries and idempotency.
Runs inside `isolation.Isolated` (synthetic users only, every public table verified identical afterwards).
The matrix is written to $MATRIX_OUT (default %TEMP%/v62_authorization_matrix.json) for docs/V62_AUTHORIZATION_MATRIX.md.
"""
import json
import os
import threading
import uuid
from pathlib import Path

import isolation as iso
from class_ui_common import ANON, RUN, User, call, check, report

MARK = {"note": "SECRET_NOTE_TEST_MARKER", "curse": "HIDDEN_CURSE_TEST_MARKER", "true": "TRUE_ITEM_NAME_TEST_MARKER",
        "cond": "HIDDEN_CONDITION_TEST_MARKER", "dmnote": "DM_CONTENT_NOTE_TEST_MARKER", "private": "PRIVATE_REVIEW_TEST_MARKER"}
MATRIX = []


def ok(st):
    return 200 <= st < 300


def anon(method, path, body=None):
    return call(method, path, body, token=ANON, key=ANON)


def rpc_as(u, fn, **a):
    return (anon("POST", f"/rest/v1/rpc/{fn}", a) if u is None else u.rpc(fn, **a))


def cell(actor, target, action, st, body, expect):
    """expect: 'allow' | 'deny' | 'either' (policy choice, recorded)."""
    allowed = ok(st) and not (isinstance(body, list) and len(body) == 0 and action.startswith("read"))
    MATRIX.append({"actor": actor, "target": target, "action": action, "status": st, "allowed": allowed, "expect": expect,
                   "detail": (body if isinstance(body, str) else json.dumps(body))[:160] if not allowed else ""})
    return allowed if expect == "allow" else (not allowed) if expect == "deny" else True


def main():
    with iso.Isolated("V62-API adversarial") as t:
        run(t)
    report()


def run(t):
    owner, mate, dm, outsider, dm2 = User("v62a-owner"), User("v62a-mate"), User("v62a-dm"), User("v62a-out"), User("v62a-dm2")
    camp, camp2 = str(uuid.uuid4()), str(uuid.uuid4())
    iso.psql(f"""insert into public.campaigns (id, name, created_by) values ('{camp}', 'UI Adversarial Campaign', '{dm.id}'), ('{camp2}', 'UI Adversarial Campaign B', '{dm2.id}');
      insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{owner.id}', 'player'), ('{camp}', '{mate.id}', 'player'),
        ('{camp2}', '{dm2.id}', 'dm'), ('{camp2}', '{outsider.id}', 'player');
      insert into public.campaign_governance (campaign_id, preset) values ('{camp}', 'standard'), ('{camp2}', 'standard');""")
    ch = owner.character(f"V62 Owner Fighter {RUN}", [("fighter-phb", 3)], strength=15, constitution=14, hp_max=30, hp_current=30)
    mate_ch = mate.character(f"V62 Mate Rogue {RUN}", [("rogue-phb", 3)], dexterity=16)
    out_ch = outsider.character(f"V62 Outsider Wizard {RUN}", [("wizard-phb", 3)], intelligence=16)
    iso.psql(f"""update public.characters set campaign_id = '{camp}' where id in ('{ch}', '{mate_ch}');
      update public.characters set campaign_id = '{camp2}' where id = '{out_ch}';
      insert into public.character_governance (character_id, setup_complete) values ('{ch}', true), ('{mate_ch}', true), ('{out_ch}', true);""")
    t.note(characters=[ch, mate_ch, out_ch], campaigns=[camp, camp2])

    # ---- hidden data with recognisable markers ----------------------------------------------------------------------------------
    st, item = dm.rpc("create_dm_content", p_type="item", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={
        "name": f"{MARK['true']} {RUN}", "player_text": "A plain ring.", "dm_notes": MARK["dmnote"],
        "definition": {"item": {"kind_id": "gear", "is_magic": True, "rarity_id": "rare"}, "hidden": {"unidentified_name": "Plain ring", "curse": MARK["curse"]}}})
    assert ok(st), item
    st, item = dm.rpc("publish_dm_content", p_content=item["id"], p_expected_version=None)
    assert ok(st), item
    st, r = dm.rpc("dm_assign_content", p_content=item["id"], p_characters=[ch], p_mode="inventory", p_options={"quantity": 1, "identified": False})
    assert ok(st), r
    st, note = dm.rpc("save_dm_note", p_character=ch, p_title="Plot", p_body=MARK["note"], p_note=None, p_reveal_note=None)
    assert ok(st), note
    st, cond = dm.rpc("apply_character_condition", p_character=ch, p_version=None, p_name=f"Doom {MARK['cond']}", p_hidden=True, p_expires=None, p_note=MARK["cond"])
    assert ok(st), cond

    def sweep(u, label):
        """Every public table the user can read through PostgREST + the read models the sheet uses: no marker may appear."""
        tables = iso.psql("select table_name from information_schema.tables where table_schema = 'public' and table_type in ('BASE TABLE', 'VIEW') order by 1").split()
        hits, readable = [], 0
        for tb in tables:
            st, body = call("GET", f"/rest/v1/{tb}?select=*&limit=2000", token=u.jwt, key=ANON)
            if ok(st):
                readable += 1
                txt = json.dumps(body)
                hits += [f"{tb}:{k}" for k, m in MARK.items() if m in txt]
        for fn, args in [("get_character_derived_stats", {"p_character": ch}), ("get_character_conditions", {"p_character": ch}),
                         ("get_character_change_requests", {"p_character": ch, "p_include_closed": True}), ("get_character_governance", {"p_character": ch}),
                         ("get_campaign_audit", {"p_campaign": camp, "p_character": None, "p_types": None, "p_limit": 500, "p_before": None}),
                         ("get_character_feats", {"p_character": ch}), ("get_character_spellbook", {"p_character": ch})]:
            st, body = u.rpc(fn, **args)
            hits += [f"rpc {fn}:{k}" for k, m in MARK.items() if m in json.dumps(body)]
        return hits, readable

    hits, readable = sweep(owner, "owner")
    check("SEC1 before any reveal the owner can read none of the 6 markers in any of the %d readable tables or the sheet read models" % readable, not hits and readable > 50, hits)
    hits_m, _ = sweep(mate, "mate")
    check("SEC2 another player of the campaign sees no marker either", not hits_m, hits_m)
    # reveal only the true name: the curse, the DM note and the hidden condition stay hidden
    inv_item = iso.psql(f"select ii.id from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = '{ch}' limit 1")
    st, r = dm.rpc("set_item_knowledge", p_inventory_item=inv_item, p_state="identified", p_revealed=None, p_magic_known=True)
    check("SEC3 the DM identifies the item", ok(st), r)
    hits, _ = sweep(owner, "owner after reveal")
    revealed = sorted({h.split(":")[1] for h in hits})
    check("SEC4 after identification only the true name is visible; curse, DM note, hidden condition and DM notes on content stay hidden",
          revealed == ["true"], hits)
    # the seeded demo table holds an unidentified item assigned before V6.2: read-only check as the demo player (rolled back, no write)
    player = iso.psql("select id from auth.users where email = 'local-player@example.test'")
    if player:
        claims = json.dumps({"sub": player, "role": "authenticated"})
        seen = iso.psql(f"""begin; set local role authenticated; select set_config('request.jwt.claims', '{claims}', true);
          select (select count(*) from public.campaign_audit_events e join public.inventory_items ii on ii.item_id = e.after ->> 'catalog_ref'
                    join public.inventories i on i.id = ii.inventory_id and i.character_id = e.character_id
                    join public.inventory_item_knowledge k on k.inventory_item_id = ii.id and k.state <> 'identified'
                  where e.event_type = 'item_assigned'); rollback;""")
        check("SEC7 an item event of an item the player has not identified yet is not readable by that player (existing demo rows included)", seen.strip().splitlines()[-1] == "0", seen)
    st, body = owner.rpc("export_campaign_dm_backup", p_campaign=camp)
    check("SEC5 the DM backup (with hidden data) is refused for the player", not ok(st), (st, str(body)[:120]))
    st, body = dm.rpc("export_campaign_dm_backup", p_campaign=camp)
    check("SEC6 ... and contains the hidden data for the DM", ok(st) and MARK["curse"] in json.dumps(body) and MARK["note"] in json.dumps(body), st)

    # ---- authorization matrix -------------------------------------------------------------------------------------------------------
    actors = {"anonymous": None, "owner": owner, "campaign player": mate, "campaign DM": dm, "unrelated user": outsider, "unrelated DM": dm2}
    musts = []
    for name, u in actors.items():
        tok = (lambda m, p, b=None: anon(m, p, b)) if u is None else (lambda m, p, b=None, u=u: call(m, p, b, token=u.jwt, key=ANON))
        exp_read = "allow" if name in ("owner", "campaign DM") else "either" if name == "campaign player" else "deny"
        st, body = tok("GET", f"/rest/v1/characters?id=eq.{ch}&select=id,hp_current")
        musts.append((name, "read character", cell(name, "campaign character", "read character", st, body, exp_read)))
        st, body = tok("PATCH", f"/rest/v1/characters?id=eq.{ch}", {"hp_current": 29})
        landed = iso.psql(f"select hp_current from public.characters where id = '{ch}'") == "29"
        exp = "allow" if name in ("owner", "campaign DM") else "deny"
        MATRIX.append({"actor": name, "target": "campaign character", "action": "edit runtime (HP)", "status": st, "allowed": landed, "expect": exp, "detail": ""})
        musts.append((name, "edit runtime", landed == (exp == "allow")))
        iso.psql(f"update public.characters set hp_current = 30 where id = '{ch}'")
        st, body = tok("PATCH", f"/rest/v1/characters?id=eq.{ch}", {"hp_max": 99})
        landed = iso.psql(f"select hp_max from public.characters where id = '{ch}'") == "99"
        exp = "allow" if name == "campaign DM" else "deny"   # standard preset: the player proposes, the DM changes
        MATRIX.append({"actor": name, "target": "campaign character", "action": "edit permanent (max HP)", "status": st, "allowed": landed, "expect": exp, "detail": str(body)[:120]})
        musts.append((name, "edit permanent", landed == (exp == "allow")))
        iso.psql(f"update public.characters set hp_max = 30 where id = '{ch}'")
        st, body = rpc_as(u, "create_change_request", p_character=ch, p_ops=[{"op": "assign_character_feat", "args": {"p_version": "alert-2024"}}],
                          p_title=None, p_reason=None, p_player_note=None, p_submit=True, p_idempotency_key=str(uuid.uuid4()), p_related_request=None)
        musts.append((name, "propose", cell(name, "campaign character", "propose a change", st, body,
                                                    "allow" if name == "owner" else "either" if name == "campaign DM" else "deny")))
        if ok(st) and name == "owner":
            req_alert = body["id"] if isinstance(body, dict) else None
        st, body = rpc_as(u, "get_dm_character_hidden", p_character=ch)
        hidden_ok = ok(st) and MARK["note"] in json.dumps(body)
        MATRIX.append({"actor": name, "target": "hidden DM data", "action": "read hidden", "status": st, "allowed": hidden_ok, "expect": "allow" if name == "campaign DM" else "deny", "detail": ""})
        musts.append((name, "read hidden", hidden_ok == (name == "campaign DM")))
        st, body = rpc_as(u, "create_dm_content", p_type="spell", p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields={"name": f"Matrix Spell {name} {RUN}", "definition": {"level": 1, "school": "evocation"}})
        musts.append((name, "create content", cell(name, "campaign catalog", "create / publish content", st, body, "allow" if name == "campaign DM" else "deny")))
        st, body = rpc_as(u, "dm_assign_content", p_content=item["id"], p_characters=[mate_ch], p_mode="inventory", p_options={"quantity": 1})
        musts.append((name, "assign", cell(name, "campaign catalog", "assign content", st, body, "allow" if name == "campaign DM" else "deny")))
        st, body = rpc_as(u, "set_character_lock", p_character=mate_ch, p_mode="build_locked", p_reason="matrix")
        musts.append((name, "lock", cell(name, "campaign character", "lock / unlock", st, body, "allow" if name == "campaign DM" else "deny")))
        if name == "campaign DM":
            dm.rpc("set_character_lock", p_character=mate_ch, p_mode="unlocked", p_reason=None)
        st, body = rpc_as(u, "set_item_knowledge", p_inventory_item=inv_item, p_state="identified", p_revealed=["curse"], p_magic_known=True)
        exp = "allow" if name == "campaign DM" else "deny"
        musts.append((name, "reveal", cell(name, "hidden DM data", "reveal", st, body, exp)))
        if name == "campaign DM":   # put the curse back to hidden for the rest of the test
            dm.rpc("set_item_knowledge", p_inventory_item=inv_item, p_state="identified", p_revealed=[], p_magic_known=True)
        st, body = rpc_as(u, "archive_dm_content", p_content=item["id"], p_reason="matrix")
        musts.append((name, "archive", cell(name, "campaign catalog", "archive content", st, body, "allow" if name == "campaign DM" else "deny")))
        if name == "campaign DM":
            dm.rpc("restore_dm_content", p_content=item["id"])
        st, body = rpc_as(u, "get_campaign_audit", p_campaign=camp, p_character=None, p_types=None, p_limit=50, p_before=None)
        # a player reads only the events of their own characters: the mate (no events of its own) gets an empty list, by design
        cell(name, "campaign", "read audit log (own characters' events)", st, body,
             "allow" if name in ("owner", "campaign DM") else "deny" if name == "campaign player" else "either")
        st, body = tok("GET", f"/rest/v1/characters?id=eq.{out_ch}&select=id")
        exp = "allow" if name in ("unrelated user", "unrelated DM") else "deny"
        cell(name, "unrelated character", "read character", st, body, exp)
    bad = [(a, x) for a, x, good in musts if not good]
    check("AUTH1 the authorization matrix holds for every actor (anonymous, owner, player, DM, unrelated user, unrelated DM) and action", not bad, bad)
    check("AUTH2 the anonymous key reads no character, hidden data or audit", all(not m["allowed"] for m in MATRIX if m["actor"] == "anonymous"),
          [m for m in MATRIX if m["actor"] == "anonymous" and m["allowed"]])
    out = Path(os.environ.get("MATRIX_OUT", Path(os.environ.get("TEMP", "/tmp")) / "v62_authorization_matrix.json"))
    out.write_text(json.dumps(MATRIX, indent=1), encoding="utf-8")

    # ---- approval atomicity: a composite request whose later operation fails changes nothing ------------------------------------------
    before_feats = iso.psql(f"select count(*) from public.character_feats where character_id = '{ch}'")
    before_cls = iso.psql(f"select string_agg(class_version_id || ':' || level, ',') from public.character_classes where character_id = '{ch}'")
    st, req = owner.rpc("create_change_request", p_character=ch, p_title="Two-step", p_reason=None, p_player_note=None, p_submit=True,
                        p_idempotency_key=str(uuid.uuid4()), p_related_request=None,
                        p_ops=[{"op": "assign_character_feat", "args": {"p_version": "tough-2024"}}, {"op": "set_character_class", "args": {"p_class_version": "no-such-class-version", "p_level": 4}}])
    created = ok(st)
    status = None
    if created:
        st2, res = dm.rpc("review_change_request", p_request=req["id"], p_decision="approve", p_note=None, p_expected_revision=None, p_edited_ops=None, p_private_note=None)
        status = iso.psql(f"select status from public.change_requests where id = '{req['id']}'")
    after_feats = iso.psql(f"select count(*) from public.character_feats where character_id = '{ch}'")
    after_cls = iso.psql(f"select string_agg(class_version_id || ':' || level, ',') from public.character_classes where character_id = '{ch}'")
    check("ATOM1 a composite request whose second operation fails applies nothing (no feat, class unchanged) and is not 'applied'",
          (not created) or (after_feats == before_feats and after_cls == before_cls and status != "applied"), (created, status, before_feats, after_feats, before_cls, after_cls))
    t.note(atomicity={"created": created, "status": status})
    # two DMs (same DM, two parallel connections) approving the same request: exactly one application
    st, req = owner.rpc("create_change_request", p_character=ch, p_ops=[{"op": "assign_character_feat", "args": {"p_version": "tough-2024"}}], p_title="Tough",
                        p_reason=None, p_player_note=None, p_submit=True, p_idempotency_key=str(uuid.uuid4()), p_related_request=None)
    assert ok(st), req
    results = []

    def approve():
        results.append(dm.rpc("review_change_request", p_request=req["id"], p_decision="approve", p_note=None, p_expected_revision=None, p_edited_ops=None, p_private_note=None)[0])
    ths = [threading.Thread(target=approve) for _ in range(4)]
    [x.start() for x in ths]
    [x.join() for x in ths]
    tough = iso.psql(f"select count(*) from public.character_feats f join public.feat_versions v on v.id = f.feat_version_id where f.character_id = '{ch}' and v.id = 'tough-2024'")
    events = iso.psql(f"select count(*) from public.change_request_events where request_id = '{req['id']}' and event in ('applied', 'apply')")
    check("ATOM2 four parallel approvals of one request: the feat is granted exactly once", tough == "1" and sum(1 for s in results if ok(s)) >= 1, (results, tough, events))
    # idempotency: the same key twice creates one request
    key = str(uuid.uuid4())
    a = owner.rpc("create_change_request", p_character=ch, p_ops=[{"op": "assign_character_feat", "args": {"p_version": "lucky-2024"}}], p_title="Lucky", p_reason=None,
                  p_player_note=None, p_submit=True, p_idempotency_key=key, p_related_request=None)
    b = owner.rpc("create_change_request", p_character=ch, p_ops=[{"op": "assign_character_feat", "args": {"p_version": "lucky-2024"}}], p_title="Lucky", p_reason=None,
                  p_player_note=None, p_submit=True, p_idempotency_key=key, p_related_request=None)
    n = iso.psql(f"select count(*) from public.change_requests where character_id = '{ch}' and title = 'Lucky'")
    check("IDEM1 the same idempotency key twice creates one request", n == "1", (a[0], b[0], n))

    # ---- custom-content version integrity for every type ------------------------------------------------------------------------------
    defs = {
        "spell": {"name": f"V62 Spell {RUN}", "ruleset": "2024", "definition": {"level": 1, "school": "evocation", "casting_time": {"unit": "action", "amount": 1},
                  "range": {"type": "distance", "distance": 60, "unit": "feet"}, "duration": {"type": "instantaneous"}, "components": {"v": True, "s": True},
                  "effects": [{"category": "damage", "dice": "2d6", "damage_types": ["fire"]}], "class_lists": ["wizard-spell-list"]}},
        "item": {"name": f"V62 Charm {RUN}", "definition": {"item": {"kind_id": "gear", "is_magic": True, "rarity_id": "common"}}},
        "feat": {"name": f"V62 Feat {RUN}", "ruleset": "2024", "definition": {"category": "general", "effects": [{"type": "speed_bonus", "value": 5, "label": "V62"}]}},
        "creature": {"name": f"V62 Fox {RUN}", "definition": {"size": "Small", "creature_type": "beast", "armor_class": 13, "hit_points": 9, "speed": {"walk": 40},
                     "abilities": {"str": 8, "dex": 16, "con": 12, "int": 4, "wis": 12, "cha": 6}, "challenge_rating": 0.25, "wild_shape_eligible": True,
                     "actions": [{"kind": "melee", "name": "Bite", "reach": 5, "damage": [{"dice": "1d6+3", "type": "piercing"}], "attack_bonus": 5}]}},
        "companion": {"name": f"V62 Hound {RUN}", "definition": {"creature": {"size": "Medium", "creature_type": "beast", "armor_class": 14, "hit_points": 15,
                      "speed": {"walk": 40}, "abilities": {"str": 14, "dex": 14, "con": 13, "int": 3, "wis": 12, "cha": 6}, "challenge_rating": 0.5}, "rules": "Acts on your turn."}},
        "background": {"name": f"V62 Background {RUN}", "ruleset": "2024", "definition": {"abilities": ["str", "con", "wis"], "feat": "alert-2024", "skills": ["athletics", "survival"], "tools": [], "gold": 10}},
        "lineage": {"name": f"V62 Lineage {RUN}", "definition": {"creature_type": "humanoid", "traits": [{"name": "Keen", "summary": "Sharp senses.", "effect_type": "sense", "effect_target": "darkvision", "effect_value": "60"}]}},
        "condition": {"name": f"V62 Condition {RUN}", "definition": {"category": "magical", "duration": "1 hour", "effects": [{"type": "ac_bonus", "target": "", "value": 1}]}},
    }
    modes = {"spell": "known", "item": "inventory", "feat": "dm_grant", "creature": "seen_form", "companion": "companion", "background": "direct", "lineage": "direct", "condition": "visible"}
    life = {}
    for typ, fields in defs.items():
        res = {}
        st, c = dm.rpc("create_dm_content", p_type=typ, p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields=fields)
        res["draft"] = ok(st)
        if not ok(st):
            res["error"] = str(c)[:160]
            life[typ] = res
            continue
        cid = c["id"]
        st, v = dm.rpc("validate_dm_content", p_content=cid)
        res["validate"] = st
        st, p1 = dm.rpc("publish_dm_content", p_content=cid, p_expected_version=None)
        res["publish_v1"] = ok(st)
        if not ok(st):
            res["error"] = str(p1)[:200]
            life[typ] = res
            continue
        v1 = iso.psql(f"select current_version_id from public.dm_content where id = '{cid}'") if iso.psql(
            "select count(*) from information_schema.columns where table_name='dm_content' and column_name='current_version_id'") == "1" else None
        st, a1 = dm.rpc("dm_assign_content", p_content=cid, p_characters=[ch], p_mode=modes[typ], p_options={"quantity": 1})
        res["assign_v1"] = ok(st) or str(a1)[:120]
        st, nv = dm.rpc("new_dm_content_version", p_content=cid)
        res["new_version"] = ok(st)
        f2 = json.loads(json.dumps(fields))
        f2["player_text"] = "Version two."
        st, sv = dm.rpc("save_dm_content", p_content=cid, p_fields=f2, p_expected_revision=None)
        st, p2 = dm.rpc("publish_dm_content", p_content=cid, p_expected_version=None)
        res["publish_v2"] = ok(st)
        versions = iso.psql(f"select string_agg(status, ',' order by version_no) from public.dm_content_versions where content_id = '{cid}'")
        res["versions"] = versions
        st, a2 = dm.rpc("dm_assign_content", p_content=cid, p_characters=[mate_ch], p_mode=modes[typ], p_options={"quantity": 1})
        res["assign_v2_other"] = ok(st) or str(a2)[:120]
        st, ar = dm.rpc("archive_dm_content", p_content=cid, p_reason="v62")
        res["archive"] = ok(st)
        st, a3 = dm.rpc("dm_assign_content", p_content=cid, p_characters=[mate_ch], p_mode=modes[typ], p_options={"quantity": 1})
        res["assign_after_archive_refused"] = not ok(st)
        st, rs = dm.rpc("restore_dm_content", p_content=cid)
        res["restore"] = ok(st)
        life[typ] = res
    t.note(content_lifecycle=life)
    print("LIFECYCLE", json.dumps(life))
    pub = [k for k, r in life.items() if r.get("publish_v1") and r.get("publish_v2")]
    check("CC1 every content type publishes Version 1 and Version 2 (spell, item, feat, creature, companion, background, lineage, condition)",
          len(pub) == 8, {k: r.get("error") for k, r in life.items() if k not in pub})
    check("CC2 Version 1 is superseded, not edited in place: two version rows per type", all(r.get("versions", "").count(",") >= 1 for k, r in life.items() if k in pub),
          {k: r.get("versions") for k, r in life.items()})
    check("CC3 an archived content cannot be assigned again", all(r.get("assign_after_archive_refused") for k, r in life.items() if k in pub),
          {k: r.get("assign_after_archive_refused") for k, r in life.items()})
    check("CC4 assignments made before archiving remain", iso.psql(f"select count(*) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = '{ch}'") >= "1")

    # ---- validation: invalid drafts never publish, messages are words ---------------------------------------------------------------
    bad_defs = {"no name": ("spell", {"name": "", "definition": {"level": 1, "school": "evocation"}}),
                "no school": ("spell", {"name": f"Bad {RUN}", "definition": {"level": 1}}),
                "bad damage type": ("spell", {"name": f"Bad2 {RUN}", "definition": {"level": 1, "school": "evocation", "effects": [{"category": "damage", "dice": "2d6", "damage_types": ["plasma"]}]}}),
                "negative HP": ("creature", {"name": f"Bad3 {RUN}", "definition": {"size": "Small", "creature_type": "beast", "armor_class": 13, "hit_points": -5, "challenge_rating": 0.25}}),
                "AC 0": ("creature", {"name": f"Bad4 {RUN}", "definition": {"size": "Small", "creature_type": "beast", "armor_class": 0, "hit_points": 5, "challenge_rating": 0.25}}),
                "CR 99": ("creature", {"name": f"Bad5 {RUN}", "definition": {"size": "Small", "creature_type": "beast", "armor_class": 12, "hit_points": 5, "challenge_rating": 99}}),
                "bad effect": ("feat", {"name": f"Bad6 {RUN}", "definition": {"category": "general", "effects": [{"type": "teleport_everyone", "value": 5}]}})}
    published_bad, raw_msgs = [], []
    for label, (typ, fields) in bad_defs.items():
        st, c = dm.rpc("create_dm_content", p_type=typ, p_campaign=camp, p_request_id=str(uuid.uuid4()), p_fields=fields)
        if not ok(st):
            raw_msgs += [label] if any(x in str(c) for x in ("violates", "constraint", "relation ")) else []
            continue
        st, p = dm.rpc("publish_dm_content", p_content=c["id"], p_expected_version=None)
        if ok(st):
            published_bad.append(label)
        elif any(x in str(p) for x in ("violates", "constraint", "relation ")):
            raw_msgs.append(label)
    check("VAL1 none of 7 invalid drafts (no name, no school, unknown damage type, negative HP, AC 0, CR 99, unknown effect) can be published", not published_bad, published_bad)
    check("VAL2 refusals are validation messages, not raw constraint texts", not raw_msgs, raw_msgs)

    # ---- server-side numeric boundaries: direct API writes the UI would never send --------------------------------------------------------
    probes = {"hp_current -5": {"hp_current": -5}, "hp_temp -1": {"hp_temp": -1}, "gp -10": {"gp": -10}, "gp 3e9 (int overflow)": {"gp": 3000000000},
              "strength 0": {"strength": 0}, "strength 31": {"strength": 31}, "hit_dice_current -1": {"hit_dice_current": -1}, "level 0": {"level": 0}, "level 21": {"level": 21}}
    stored = {}
    for label, patch in probes.items():
        col = list(patch)[0]
        before = iso.psql(f"select {col} from public.characters where id = '{mate_ch}'")
        st, body = call("PATCH", f"/rest/v1/characters?id=eq.{mate_ch}", patch, token=mate.jwt, key=ANON)
        after = iso.psql(f"select {col} from public.characters where id = '{mate_ch}'")
        stored[label] = {"status": st, "stored": after != before, "value": after}
        if after != before:
            iso.psql(f"update public.characters set {col} = {before if before else 'null'} where id = '{mate_ch}'")
    t.note(numeric=stored)
    print("NUMERIC", json.dumps(stored))
    accepted = [k for k, v in stored.items() if v["stored"]]
    check("NUM1 the server refuses impossible values written directly through the API (negative HP / temp HP / coins, scores 0 / 31, levels 0 / 21, overflow)",
          not accepted, accepted)
    st, body = mate.rpc("expend_standard_spell_slot", p_character=mate_ch, p_slot_level=12, p_reason=None)
    check("NUM2 an invalid slot level is refused with a message", not ok(st), (st, str(body)[:100]))


main()
