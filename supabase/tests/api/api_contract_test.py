"""API contract tests against a LOCAL Supabase stack (GoTrue Auth + PostgREST + RLS).

Run by supabase/tests/run_supabase_local.sh. Reads API_URL / ANON_KEY / SERVICE_ROLE_KEY from the environment
(the runner takes them from `supabase status -o env` of the local stack; nothing is stored in the repository).
Refuses to run against anything that is not localhost. Uses synthetic users (@example.test) and synthetic data.
Python 3.9+, standard library only.
"""
import json
import os
import sys
import threading
import uuid
import urllib.error
import urllib.request
from urllib.parse import urlparse

API = os.environ["API_URL"].rstrip("/")
ANON = os.environ["ANON_KEY"]
SERVICE = os.environ["SERVICE_ROLE_KEY"]
if urlparse(API).hostname not in ("127.0.0.1", "localhost"):
    sys.exit("refusing to run: API_URL is not a local address")

results = []
RUN = uuid.uuid4().hex[:6]   # unique names and request ids: the test can run again on the same database


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(("PASSED  " if ok else "FAILED  ") + name + ("" if ok else f"   <-- {detail}"), flush=True)


def call(method, path, token=None, body=None, headers=None, key=None):
    h = {"apikey": key or ANON, "Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path.replace(" ", "%20"), data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else None), dict(r.headers)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw), dict(e.headers)
        except ValueError:
            return e.code, raw, dict(e.headers)


def svc(method, path, body=None, headers=None):
    return call(method, path, token=SERVICE, body=body, headers=headers, key=SERVICE)


def rpc(token, fn, **args):
    return call("POST", f"/rest/v1/rpc/{fn}", token=token, body=args)


def user(email):
    pw = "local-test-password-1!"
    svc("POST", "/auth/v1/admin/users", {"email": email, "password": pw, "email_confirm": True})   # 422 if it already exists
    st, body, _ = call("POST", "/auth/v1/token?grant_type=password", body={"email": email, "password": pw})
    assert st == 200, (st, body)
    return body["access_token"], body["user"]["id"]


def main():
    # ---- fixtures (service role = local setup only) -------------------------------------------------
    alice, alice_id = user("api-alice@example.test")
    bob, bob_id = user("api-bob@example.test")
    dm, dm_id = user("api-dm@example.test")
    adm, adm_id = user("api-admin@example.test")
    svc("PATCH", f"/rest/v1/profiles?id=eq.{adm_id}", {"role": "admin"})
    st, camp, _ = svc("POST", "/rest/v1/campaigns", {"name": "API Test Campaign", "created_by": dm_id}, {"Prefer": "return=representation"})
    camp_id = camp[0]["id"]
    svc("POST", "/rest/v1/campaign_members", [{"campaign_id": camp_id, "user_id": u, "role": r}
                                               for u, r in ((alice_id, "player"), (bob_id, "player"), (dm_id, "dm"))])
    # since 20261019000100 only DMs author mechanical content: alice, the homebrew author below, DMs a campaign of her own
    st, own, _ = svc("POST", "/rest/v1/campaigns", {"name": f"API Alice Authoring {RUN}", "created_by": alice_id}, {"Prefer": "return=representation"})
    svc("POST", "/rest/v1/campaign_members", {"campaign_id": own[0]["id"], "user_id": alice_id, "role": "dm"})
    st, chars, _ = svc("POST", "/rest/v1/characters", [{"owner_id": alice_id, "name": "API Alice", "campaign_id": camp_id},
                                                         {"owner_id": bob_id, "name": "API Bob", "campaign_id": camp_id}],
                       {"Prefer": "return=representation"})
    char_a, char_b = chars[0]["id"], chars[1]["id"]
    st, invs, _ = svc("GET", f"/rest/v1/inventories?character_id=in.({char_a},{char_b})&select=id,character_id")
    inv = {i["character_id"]: i["id"] for i in invs}
    inv_a, inv_b = inv[char_a], inv[char_b]

    # ---- anon: official catalog only ----------------------------------------------------------------
    st, rows, h = call("HEAD", "/rest/v1/items?select=id", headers={"Prefer": "count=exact"})
    check("anon reads the official catalog (count 1146; PostgREST pages at max_rows = 1000)",
          st in (200, 206) and h.get("Content-Range", "").endswith("/1146"), (st, h.get("Content-Range")))
    st, rows, _ = call("GET", "/rest/v1/v_item_catalog?id=eq.longsword&select=damage_dice,weapon_properties")
    check("anon reads v_item_catalog (security_invoker view)", st == 200 and rows and rows[0]["damage_dice"] == "1d8", rows)
    st, _, _ = call("POST", "/rest/v1/items", body={"id": "anon-item", "kind_id": "gear", "name": "X"})
    check("anon cannot insert an item", st in (401, 403), st)
    st, _, _ = call("PATCH", "/rest/v1/items?id=eq.longsword", body={"name": "Hacked"})
    check("anon cannot change an item", st in (401, 403), st)
    st, _, _ = call("GET", "/rest/v1/inventory_items?select=id")
    check("anon cannot read inventories", st in (401, 403), st)
    st, _, _ = call("GET", "/rest/v1/v_inventory_detail?select=id")
    check("anon cannot read v_inventory_detail", st in (401, 403), st)
    st, _, _ = rpc(None, "use_inventory_item", p_item="00000000-0000-0000-0000-000000000000")
    check("anon cannot call inventory RPCs", st in (401, 403, 404), st)

    # ---- owner, other player, DM, admin ---------------------------------------------------------------
    st, jav, _ = rpc(alice, "add_inventory_item", p_inventory=inv_a, p_item="javelin", p_quantity=5)
    check("owner adds items through the RPC (real JWT)", st == 200 and isinstance(jav, str), (st, jav))
    st, rows, _ = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{inv_a}&select=id,quantity,item_id", token=alice)
    check("owner sees own inventory", st == 200 and any(r["id"] == jav and r["quantity"] == 5 for r in rows), rows)
    st, rows, _ = call("GET", f"/rest/v1/inventory_events?inventory_id=eq.{inv_a}&select=actor_id,action", token=alice)
    check("events carry the caller's auth.uid() from the JWT", st == 200 and any(r["actor_id"] == alice_id for r in rows), rows)
    st, rows, _ = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{inv_a}&select=id", token=bob)
    check("another player sees none of it", st == 200 and rows == [], rows)
    st, rows, _ = call("PATCH", f"/rest/v1/inventory_items?id=eq.{jav}", token=bob, body={"notes": "hacked"}, headers={"Prefer": "return=representation"})
    st2, after, _ = call("GET", f"/rest/v1/inventory_items?id=eq.{jav}&select=notes", token=alice)
    check("another player cannot modify it", (st in (401, 403) or rows == []) and after[0]["notes"] is None, (st, rows, after))
    st, body, _ = rpc(bob, "add_inventory_item", p_inventory=inv_a, p_item="dagger", p_quantity=1)
    check("another player cannot add to it (RPC)", st >= 400, (st, body))
    st, rows, _ = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{inv_a}&select=id", token=dm)
    check("the campaign DM reads the player's inventory", st == 200 and len(rows) >= 1, rows)
    st, rows, _ = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{inv_b}&select=id", token=adm)
    check("an admin reads any inventory", st == 200, (st, rows))
    st, rows, _ = call("GET", f"/rest/v1/v_inventory_detail?inventory_id=eq.{inv_a}&select=id", token=bob)
    check("security_invoker view respects RLS for another player", st == 200 and rows == [], rows)

    # ---- equip splits a stack; the legacy equipped column cannot conflict -------------------------------
    st, eq, _ = rpc(alice, "equip_item", p_item=jav, p_slot="main_hand")
    piece = eq.get("inventory_item_id") if isinstance(eq, dict) else None
    st, rows, _ = call("GET", f"/rest/v1/inventory_items?item_id=eq.javelin&inventory_id=eq.{inv_a}&select=id,quantity,equipped", token=alice)
    q = {r["id"]: (r["quantity"], r["equipped"]) for r in rows}
    check("equip_item splits Javelin x5 into x4 + x1 equipped", q.get(jav) == (4, False) and q.get(piece) == (1, True), (eq, q))
    st_p1, _, _ = call("PATCH", f"/rest/v1/inventory_items?id=eq.{piece}", token=alice, body={"equipped": False})
    st_p2, _, _ = call("PATCH", f"/rest/v1/inventory_items?id=eq.{jav}", token=alice, body={"equipped": True})
    check("direct PATCH of inventory_items is refused (RPC only)", st_p1 in (401, 403) and st_p2 in (401, 403), (st_p1, st_p2))
    st, rows, _ = call("GET", f"/rest/v1/inventory_items?item_id=eq.javelin&inventory_id=eq.{inv_a}&select=id,equipped", token=alice)
    st2, slots, _ = call("GET", f"/rest/v1/character_equipment?character_id=eq.{char_a}&select=slot_id,inventory_item_id", token=alice)
    e = {r["id"]: r["equipped"] for r in rows}
    check("the legacy equipped column still matches character_equipment",
          e.get(piece) is True and e.get(jav) is False and slots == [{"slot_id": "main_hand", "inventory_item_id": piece}], (e, slots))
    st, _, _ = call("POST", "/rest/v1/character_equipment", token=alice, body={"character_id": char_a, "slot_id": "off_hand", "inventory_item_id": jav})
    check("character_equipment is not writable through the API", st in (401, 403), st)
    st, _, _ = call("PATCH", f"/rest/v1/inventory_items?id=eq.{jav}", token=alice, body={"item_id": "greatsword"})
    check("item_id cannot be changed through the API (RPC only)", st in (401, 403), st)
    st, _, _ = call("POST", "/rest/v1/inventory_items", token=alice, body={"character_id": char_a, "name": "Empty", "quantity": 0})
    check("a new row with quantity 0 is rejected", st >= 400, st)
    st, legacy, _ = call("POST", "/rest/v1/inventory_items", token=alice,
                         body={"character_id": char_a, "name": "New item", "sort_order": 9}, headers={"Prefer": "return=representation"})
    check("a client cannot create a new legacy row (item_id null)", st in (401, 403), (st, legacy))
    st, legacy, _ = call("POST", "/rest/v1/inventory_items", token=alice,
                         body={"character_id": char_a, "item_id": "dagger", "name": "Dagger", "quantity": 1})
    check("a client cannot insert catalog rows directly either", st in (401, 403), st)
    st, _, _ = call("DELETE", f"/rest/v1/inventory_items?id=eq.{jav}", token=alice)
    check("a client cannot delete rows directly", st in (401, 403), st)

    # ---- use a potion; concurrent use never goes negative ------------------------------------------------
    st, pot, _ = rpc(alice, "add_inventory_item", p_inventory=inv_a, p_item="potion-of-healing-common", p_quantity=1)
    st, used, _ = rpc(alice, "use_inventory_item", p_item=pot)
    fx = (used or {}).get("effects", [{}])[0] if isinstance(used, dict) else {}
    check("use_inventory_item returns the healing effect and deletes the last potion",
          st == 200 and fx.get("dice_expression") == "2d4" and fx.get("flat_value") == 2 and used["deleted"], used)
    st, again, _ = rpc(alice, "use_inventory_item", p_item=pot)
    check("using it again fails", st >= 400, (st, again))
    st, stack, _ = rpc(alice, "add_inventory_item", p_inventory=inv_a, p_item="potion-of-healing-common", p_quantity=3)
    codes = []

    def use():
        s, _, _ = rpc(alice, "use_inventory_item", p_item=stack)
        codes.append(s)

    threads = [threading.Thread(target=use) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    st, left, _ = call("GET", f"/rest/v1/inventory_items?id=eq.{stack}&select=quantity", token=alice)
    check("8 concurrent uses of a stack of 3: exactly 3 succeed, nothing negative, row removed",
          codes.count(200) == 3 and len(codes) == 8 and left == [], (sorted(codes), left))

    # ---- transfer / party stash ----------------------------------------------------------------------
    st, stash, _ = call("POST", "/rest/v1/inventories", token=dm, body={"kind": "party_stash", "name": "Stash", "campaign_id": camp_id},
                        headers={"Prefer": "return=representation"})
    stash_id = stash[0]["id"] if st == 201 else None
    check("the DM creates the party stash", st == 201, (st, stash))
    st, moved, _ = rpc(alice, "transfer_inventory_item", p_item=jav, p_to_inventory=stash_id, p_quantity=1)
    check("a player deposits into the party stash (transfer RPC)", st == 200, (st, moved))
    st, back, _ = rpc(alice, "transfer_inventory_item", p_item=moved, p_to_inventory=inv_a)
    check("a player cannot withdraw from the party stash", st >= 400, (st, back))
    st, rows, _ = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{stash_id}&select=id", token=bob)
    check("other campaign members can read the party stash", st == 200 and len(rows) == 1, rows)
    st, back, _ = rpc(dm, "transfer_inventory_item", p_item=moved, p_to_inventory=inv_a)
    check("the DM can withdraw from the party stash", st == 200, (st, back))

    # ---- frontend RPCs: exact quantity, containers, linking legacy rows ---------------------------------------
    st, torch, _ = rpc(alice, "add_inventory_item", p_inventory=inv_a, p_item="torch", p_quantity=2)
    st, res, _ = rpc(alice, "set_inventory_item_quantity", p_item=torch, p_quantity=6)
    check("set_inventory_item_quantity sets an exact quantity", st == 200 and res["quantity"] == 6 and res["previous_quantity"] == 2, (st, res))
    st, res, _ = rpc(alice, "set_inventory_item_quantity", p_item=torch, p_quantity=0)
    check("set_inventory_item_quantity refuses 0", st >= 400, (st, res))
    st, res, _ = rpc(bob, "set_inventory_item_quantity", p_item=torch, p_quantity=1)
    check("another player cannot set the quantity", st >= 400, (st, res))
    st, pack, _ = rpc(alice, "add_inventory_item", p_inventory=inv_a, p_item="backpack", p_quantity=1)
    st, moved_t, _ = rpc(alice, "move_inventory_item", p_item=torch, p_container=pack)
    st2, rows, _ = call("GET", f"/rest/v1/inventory_items?id=eq.{moved_t}&select=container_item_id", token=alice)
    check("move_inventory_item puts an item into a container", st == 200 and rows[0]["container_item_id"] == pack, (st, rows))
    st, res, _ = rpc(alice, "move_inventory_item", p_item=pack, p_container=pack)
    check("move_inventory_item refuses a cycle", st >= 400, (st, res))
    # ---- legacy rows: only existing data (created here by the service role as a fixture), linked after a comparison --
    st, free, _ = svc("POST", "/rest/v1/inventory_items", {"character_id": char_a, "name": "Old rope", "quantity": 1, "weight": 7,
                                                           "description": "Frayed at one end"}, {"Prefer": "return=representation"})
    legacy_id = free[0]["id"]
    st, cands, _ = rpc(alice, "find_link_candidates", p_item=legacy_id)
    check("find_link_candidates returns suggestions with a confidence, never links", st == 200 and isinstance(cands, list), (st, cands))
    st, rows, _ = call("GET", f"/rest/v1/inventory_items?id=eq.{legacy_id}&select=item_id", token=alice)
    check("suggestions do not link anything", rows == [{"item_id": None}], rows)
    st, prev, _ = rpc(alice, "preview_link_inventory_item", p_item=legacy_id, p_catalog_item="rope-hemp-50-ft")
    fields = sorted(c["field"] for c in (prev or {}).get("changes", [])) if st == 200 else None
    check("preview_link_inventory_item compares name, description and weight", st == 200 and fields == ["description", "name", "weight"], (st, prev))
    st, res, _ = rpc(bob, "preview_link_inventory_item", p_item=legacy_id, p_catalog_item="rope-hemp-50-ft")
    check("another player cannot preview a link on someone else's row", st >= 400, (st, res))
    st, res, _ = rpc(alice, "link_inventory_item", p_item=legacy_id, p_catalog_item="rope-hemp-50-ft")
    st2, rows, _ = call("GET", f"/rest/v1/inventory_items?id=eq.{legacy_id}&select=item_id,custom_name,notes", token=alice)
    r0 = rows[0] if rows else {}
    check("link_inventory_item links after confirmation; the legacy name becomes the custom name, the description goes to notes",
          st == 200 and res.get("linked") and r0.get("item_id") == "rope-hemp-50-ft" and r0.get("custom_name") == "Old rope"
          and "Legacy description: Frayed at one end" in (r0.get("notes") or ""), (st, res, rows))
    st, res, _ = rpc(alice, "link_inventory_item", p_item=legacy_id, p_catalog_item="torch")
    check("an already linked row cannot be linked again", st >= 400, (st, res))

    RID01 = str(uuid.uuid4())
    RID02 = str(uuid.uuid4())
    RID03 = str(uuid.uuid4())
    RID04 = str(uuid.uuid4())
    RID05 = str(uuid.uuid4())
    RID06 = str(uuid.uuid4())
    # ---- homebrew items: RPC only, visibility from owner / campaign ----------------------------------------------
    st, hb, _ = call("POST", "/rest/v1/items", token=alice, body={"id": "api-homebrew-blade", "kind_id": "weapon", "name": "Homebrew Blade"})
    check("a player cannot insert into items directly", st in (401, 403), st)
    rid = RID01
    blade_def = {"name": f"API Secret Blade {RUN}", "kind_id": "weapon", "category_id": "martial-melee", "weight_lb": 3}
    blade_stats = {"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "slashing", "properties": ["finesse"]}}
    st, blade, _ = rpc(alice, "create_homebrew_item", p_request_id=rid, p_definition=blade_def, p_stats=blade_stats)
    blade_id = blade.get("id") if isinstance(blade, dict) else None
    check("create_homebrew_item creates a private homebrew weapon (labelled homebrew, id hb-<request id>)",
          st == 200 and blade_id == f"hb-{rid}" and blade["visibility"] == "private" and blade["data_source_id"] == "homebrew"
          and blade["damage_dice"] == "1d8", (st, blade))
    st, again, _ = rpc(alice, "create_homebrew_item", p_request_id=rid, p_definition=blade_def, p_stats=blade_stats)
    st2, rows, _ = call("GET", f"/rest/v1/items?name=eq.API Secret Blade {RUN}&select=id", token=alice)
    check("repeating the request (lost response) returns the same item, no duplicate", st == 200 and again["id"] == blade_id and len(rows) == 1, (st, again, rows))
    st, rows, _ = call("GET", f"/rest/v1/v_item_catalog?id=eq.{blade_id}&select=id,is_mine,can_edit", token=alice)
    check("the author sees it in the catalog (is_mine, can_edit)", rows == [{"id": blade_id, "is_mine": True, "can_edit": True}], rows)
    st, rows, _ = call("GET", f"/rest/v1/v_item_catalog?id=eq.{blade_id}&select=id", token=bob)
    check("another campaign member does not see private homebrew", rows == [], rows)
    st, rows, _ = call("GET", f"/rest/v1/v_item_catalog?id=eq.{blade_id}&select=id")
    check("anon does not see homebrew", rows == [], rows)
    st, res, _ = rpc(alice, "create_homebrew_item", p_request_id=RID02,
                     p_definition={"name": "Gift", "kind_id": "gear", "owner_id": bob_id})
    check("owner_id cannot be passed in (no homebrew in someone else's name)", st >= 400 and "cannot be set" in json.dumps(res), (st, res))
    st, res, _ = rpc(alice, "create_homebrew_item", p_request_id=RID03,
                     p_definition={"name": "Bad", "kind_id": "weapon"}, p_stats={"weapon": {"damage_dice": "lots"}})
    check("the server validates typed stats (damage dice)", st >= 400 and "Damage dice" in json.dumps(res), (st, res))
    st, blade_row, _ = rpc(alice, "add_inventory_item", p_inventory=inv_a, p_item=blade_id, p_quantity=1)
    check("the author adds private homebrew to their own character", st == 200, (st, blade_row))
    st, res, _ = rpc(dm, "add_inventory_item", p_inventory=stash_id, p_item=blade_id, p_quantity=1)
    check("the DM cannot add someone's private homebrew (it is invisible to them)", st >= 400, (st, res))
    st, res, _ = rpc(alice, "transfer_inventory_item", p_item=blade_row, p_to_inventory=stash_id)
    check("private homebrew cannot be moved into a shared inventory", st >= 400 and "private homebrew" in json.dumps(res).lower(), (st, res))
    st, res, _ = rpc(alice, "create_homebrew_item", p_request_id=str(uuid.uuid4()),
                     p_definition={"name": f"API Player Axe {RUN}", "kind_id": "weapon", "category_id": "martial-melee", "campaign_id": camp_id})
    check("a player cannot author campaign homebrew (the campaign DM does)", st >= 400 and "TLDMO" in json.dumps(res), (st, res))
    st, axe, _ = rpc(dm, "create_homebrew_item", p_request_id=RID04,
                     p_definition={"name": f"API Campaign Axe {RUN}", "kind_id": "weapon", "category_id": "martial-melee", "campaign_id": camp_id})
    axe_id = axe.get("id") if isinstance(axe, dict) else None
    st2, rows, _ = call("GET", f"/rest/v1/v_item_catalog?id=eq.{axe_id}&select=id,visibility,can_edit", token=bob)
    check("campaign homebrew is visible to other members, read-only for players",
          st == 200 and rows == [{"id": axe_id, "visibility": "campaign", "can_edit": False}], (st, axe, rows))
    st, res, _ = rpc(bob, "update_homebrew_item", p_item=axe_id, p_definition={"name": "Bob's Axe"})
    check("another player cannot edit campaign homebrew", st >= 400, (st, res))
    st, res, _ = rpc(dm, "update_homebrew_item", p_item=axe_id, p_definition={"name": f"API Campaign Axe {RUN}", "description": "DM note"})
    check("the campaign DM can edit campaign homebrew", st == 200 and res["description"] == "DM note" and res["campaign_id"] == camp_id, (st, res))
    st, res, _ = rpc(alice, "update_homebrew_item", p_item=axe_id, p_definition={"name": f"API Campaign Axe {RUN}", "campaign_id": None})
    check("a player cannot change who can see it", st >= 400, (st, res))
    st, res, _ = rpc(dm, "update_homebrew_item", p_item=axe_id, p_definition={"name": f"API Campaign Axe {RUN}", "kind_id": "gear"})
    check("the type of a homebrew item cannot change", st >= 400, (st, res))
    st, res, _ = rpc(bob, "add_inventory_item", p_inventory=inv_b, p_item=axe_id, p_quantity=1)
    check("another member adds campaign homebrew to their character", st == 200, (st, res))
    st, n, _ = rpc(dm, "homebrew_usage_count", p_item=axe_id)
    check("the author sees only an aggregate usage count", st == 200 and n == 1, (st, n))
    st, n, _ = rpc(bob, "homebrew_usage_count", p_item=axe_id)
    check("a player who cannot edit it gets no usage count", st >= 400, (st, n))
    st, res, _ = rpc(dm, "archive_homebrew_item", p_item=axe_id)
    st2, rows, _ = call("GET", f"/rest/v1/v_inventory_detail?inventory_id=eq.{inv_b}&item_id=eq.{axe_id}&select=id", token=bob)
    check("archive keeps existing inventory entries", st == 200 and len(rows) == 1, (st, res, rows))
    st, res, _ = rpc(bob, "add_inventory_item", p_inventory=inv_b, p_item=axe_id, p_quantity=1)
    check("an archived item cannot be added any more", st >= 400 and "archived" in json.dumps(res).lower(), (st, res))
    st, res, _ = rpc(dm, "update_homebrew_item", p_item=axe_id, p_definition={"name": "X"})
    check("an archived item cannot be edited until restored", st >= 400, (st, res))
    st, res, _ = rpc(dm, "restore_homebrew_item", p_item=axe_id)
    st2, res2, _ = rpc(bob, "add_inventory_item", p_inventory=inv_b, p_item=axe_id, p_quantity=1)
    check("restore makes it addable again", st == 200 and st2 == 200, (st, res, st2, res2))
    st, res, _ = rpc(alice, "archive_homebrew_item", p_item="longsword")
    check("official items cannot be archived", st >= 400, (st, res))
    st, rows, _ = call("GET", f"/rest/v1/homebrew_item_events?item_id=eq.{axe_id}&select=action&order=created_at", token=dm)
    check("homebrew changes are audited", [r["action"] for r in rows or []] == ["create", "update", "archive", "restore"], rows)

    # ---- customized instance: per-piece fields only ----------------------------------------------------------------
    st, res, _ = rpc(alice, "update_inventory_item_details", p_item=moved_t,
                     p_details={"custom_name": "Lucky torch", "notes": "From the inn", "is_quest_item": True})
    check("update_inventory_item_details changes custom name, personal notes, quest flag",
          st == 200 and res["custom_name"] == "Lucky torch" and res["is_quest_item"] is True, (st, res))
    st, res, _ = rpc(alice, "update_inventory_item_details", p_item=moved_t, p_details={"name": "Sword of Doom"})
    st2, rows, _ = call("GET", "/rest/v1/items?id=eq.torch&select=name", token=alice)
    check("catalog fields cannot be changed through the instance", st >= 400 and rows == [{"name": "Torch"}], (st, res, rows))
    st, res, _ = rpc(bob, "update_inventory_item_details", p_item=moved_t, p_details={"notes": "mine"})
    check("another player cannot edit the instance", st >= 400, (st, res))

    # ---- convert a legacy row into homebrew (one transaction, idempotent) -------------------------------------------
    st, old, _ = svc("POST", "/rest/v1/inventory_items", {"character_id": char_a, "name": f"Grandma's locket {RUN}", "quantity": 1, "weight": 0.5,
                                                          "description": "Silver, engraved"}, {"Prefer": "return=representation"})
    old_id = old[0]["id"]
    crid = RID05
    cdef = {"name": f"Grandma's locket {RUN}", "kind_id": "gear", "description": "Silver, engraved", "weight_lb": 0.5}
    st, conv, _ = rpc(alice, "convert_legacy_item_to_homebrew", p_item=old_id, p_request_id=crid, p_definition=cdef)
    st2, rows, _ = call("GET", f"/rest/v1/inventory_items?id=eq.{old_id}&select=item_id,quantity", token=alice)
    check("convert_legacy_item_to_homebrew creates the item and links the row", st == 200 and rows == [{"item_id": f"hb-{crid}", "quantity": 1}], (st, conv, rows))
    st, conv2, _ = rpc(alice, "convert_legacy_item_to_homebrew", p_item=old_id, p_request_id=crid, p_definition=cdef)
    st2, rows, _ = call("GET", f"/rest/v1/items?name=eq.Grandma's locket {RUN}&select=id", token=alice)
    check("a repeated convert request is replayed, no second item", st == 200 and conv2.get("replayed") and len(rows) == 1, (st, conv2, rows))
    st, old2, _ = svc("POST", "/rest/v1/inventory_items", {"character_id": char_a, "name": "Broken thing", "quantity": 1},
                      {"Prefer": "return=representation"})
    st, res, _ = rpc(alice, "convert_legacy_item_to_homebrew", p_item=old2[0]["id"], p_request_id=RID06,
                     p_definition={"name": "Broken thing", "kind_id": "armor"})
    st2, rows, _ = call("GET", f"/rest/v1/inventory_items?id=eq.{old2[0]['id']}&select=item_id", token=alice)
    st3, rows3, _ = call("GET", f"/rest/v1/items?id=eq.hb-{RID06}&select=id", token=alice)
    check("an invalid convert changes nothing (no item, row stays legacy)", st >= 400 and rows == [{"item_id": None}] and rows3 == [], (st, res, rows, rows3))

    # ---- equipment review for a legacy row that was equipped -------------------------------------------------------
    svc("POST", "/rest/v1/legacy_inventory_review", {"inventory_item_id": old2[0]["id"], "character_id": char_a, "legacy_name": "Broken thing",
                                                     "legacy_quantity": 1, "legacy_equipped": True, "category": "equipped_manual", "status": "manual_review"})
    st, n, _ = rpc(alice, "resolve_equipment_review", p_item=old2[0]["id"])
    st2, rows, _ = call("GET", f"/rest/v1/legacy_inventory_review?inventory_item_id=eq.{old2[0]['id']}&select=status", token=alice)
    check("resolve_equipment_review marks it as not equipped", st == 200 and n == 1 and rows == [{"status": "resolved"}], (st, n, rows))

    # ---- JSON import never creates legacy rows --------------------------------------------------------------------
    st, imp, _ = rpc(alice, "import_inventory_items", p_character=char_a,
                     p_items=[{"name": "Dagger", "quantity": 2}, {"name": f"Mysterious pebble {RUN}", "quantity": 1, "weight": 0.1}])
    st2, rows, _ = call("GET", f"/rest/v1/inventory_items?inventory_id=eq.{inv_a}&item_id=is.null&name=eq.Mysterious pebble {RUN}&select=id", token=alice)
    check("import_inventory_items: catalog match + campaign homebrew, no legacy row",
          st == 200 and imp == {"matched": 1, "homebrew_created": 1, "skipped": []} and rows == [], (st, imp, rows))
    st, imp, _ = rpc(bob, "import_inventory_items", p_character=char_a, p_items=[{"name": "Dagger"}])
    check("import into someone else's character is refused", st >= 400, (st, imp))

    derived_stats_section(alice, alice_id, bob, dm, camp_id)
    lineage_section(alice, alice_id, bob, dm, camp_id)
    spell_section(alice, alice_id, bob, dm, camp_id)
    class_section(alice, alice_id, bob, dm, camp_id)
    feature_section(alice, alice_id, bob, dm, camp_id)

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


def derived_stats_section(alice, alice_id, bob, dm, camp_id):
    """Derived stats + proficiencies over the real API (migration 20261015001400)."""
    carol, carol_id = user("api-carol@example.test")          # not a member of the campaign
    st, chars, _ = svc("POST", "/rest/v1/characters", {"owner_id": alice_id, "name": f"API Derived {RUN}", "campaign_id": camp_id,
                                                       "level": 1, "strength": 12, "dexterity": 14, "speed": 30},
                       {"Prefer": "return=representation"})
    cid = chars[0]["id"]
    st, invs, _ = svc("GET", f"/rest/v1/inventories?character_id=eq.{cid}&select=id")
    inv = invs[0]["id"]
    derived = lambda tok: rpc(tok, "get_character_derived_stats", p_character=cid)   # noqa: E731
    ac = lambda tok=alice: derived(tok)[1]["armor_class"]["value"]                      # noqa: E731
    codes = lambda: {w["code"] for w in derived(alice)[1]["warnings"]}                 # noqa: E731
    add = lambda item: rpc(alice, "add_inventory_item", p_inventory=inv, p_item=item, p_quantity=1)[1]   # noqa: E731

    st, d, _ = derived(alice)
    check("derived: the owner reads derived stats (unarmored 10 + 2 = 12)", st == 200 and d["armor_class"]["value"] == 12, (st, d))
    st, d, _ = derived(dm)
    check("derived: the campaign DM reads derived stats", st == 200 and d["armor_class"]["value"] == 12, (st, d))
    st, d, _ = derived(carol)
    st2, d2, _ = derived(bob)
    check("derived: an outsider and another player are denied", st in (401, 403) and st2 in (401, 403), (st, d, st2, d2))
    st, d, _ = derived(None)
    check("derived: anonymous callers are denied", st in (401, 403, 404), st)

    chain, shield, ring, sword, tools = add("chain-mail"), add("shield"), add("ring-of-protection"), add("longsword"), add("thieves-tools")
    rpc(alice, "equip_item", p_item=chain, p_slot="armor")
    check("derived: equipping armor updates AC (Chain Mail 16, DEX ignored)", ac() == 16, ac())
    check("derived: missing armor proficiency returns structured warnings",
          {"nonproficient_armor", "spellcasting_restricted", "stealth_disadvantage", "strength_requirement_unmet"} <= codes(), codes())
    rpc(alice, "equip_item", p_item=shield, p_slot="shield")
    check("derived: equipping a shield adds +2 (18) and reports the missing shield proficiency", ac() == 18 and "nonproficient_shield" in codes(),
          (ac(), codes()))
    st, r, _ = rpc(alice, "set_character_proficiency", p_character=cid, p_group="heavy-armor")
    st2, r2, _ = rpc(alice, "set_character_proficiency", p_character=cid, p_group="shields")
    check("derived: the owner adds explicit proficiencies; the armor warnings disappear",
          st == 200 and r["changed"] and st2 == 200 and not {"nonproficient_armor", "nonproficient_shield", "spellcasting_restricted"} & codes(),
          (st, r, codes()))
    st, r, _ = rpc(alice, "set_character_proficiency", p_character=cid, p_group="shields", p_enabled=False)
    check("derived: the owner removes a proficiency; the shield warning returns", st == 200 and r["changed"] and "nonproficient_shield" in codes(),
          (st, r, codes()))
    st, r, _ = rpc(carol, "set_character_proficiency", p_character=cid, p_group="martial-weapons")
    st2, r2, _ = rpc(bob, "set_character_proficiency", p_character=cid, p_group="martial-weapons")
    check("derived: outsiders cannot change proficiencies", st >= 400 and st2 >= 400, (st, r, st2, r2))
    rpc(alice, "unequip_item", p_item=chain)
    check("derived: unequipping the armor returns to the unarmored formula (12 + 2 shield = 14)", ac() == 14, ac())
    rpc(alice, "equip_item", p_item=ring, p_slot="ring_1")
    before = ac()
    rpc(alice, "attune_item", p_item=ring)
    after = ac()
    rpc(alice, "unattune_item", p_item=ring)
    check("derived: attunement toggles the Ring of Protection (+1 only while attuned)", (before, after, ac()) == (14, 15, 14), (before, after, ac()))
    rpc(alice, "equip_item", p_item=sword, p_slot="main_hand")
    weapon = derived(alice)[1]["equipped_weapon_attacks"][0]
    check("derived: a non-proficient martial weapon omits the proficiency bonus (+1, 1d8 + 1)",
          weapon["attack_bonus"] == 1 and not weapon["proficiency_bonus_applied"] and weapon["damage"] == "1d8 + 1", weapon)
    rpc(alice, "set_character_proficiency", p_character=cid, p_item="longsword")
    weapon = derived(alice)[1]["equipped_weapon_attacks"][0]
    check("derived: a specific weapon proficiency adds the proficiency bonus (+3)", weapon["attack_bonus"] == 3, weapon)
    tools_row = [t for t in derived(alice)[1]["tools"] if t["item_id"] == "thieves-tools"]
    rpc(alice, "set_character_proficiency", p_character=cid, p_item="thieves-tools")
    tools_after = [t for t in derived(alice)[1]["tools"] if t["item_id"] == "thieves-tools"]
    check("derived: tool proficiency is returned informationally (owned without proficiency, then proficient)",
          tools_row and not tools_row[0]["proficient"] and tools_after[0]["proficient"], (tools_row, tools_after))
    st, _, _ = call("POST", "/rest/v1/character_proficiencies", token=alice,
                    body={"character_id": cid, "proficiency_type": "weapon", "group_id": "firearms"})
    st2, _, _ = call("POST", "/rest/v1/item_effects", token=alice,
                     body={"item_id": "club", "seq": 9, "effect_type": "ac_bonus", "value": 10, "activation": "owned"})
    st3, rows, _ = call("PATCH", f"/rest/v1/armor_stats?item_id=eq.plate", token=alice, body={"base_ac": 30}, headers={"Prefer": "return=representation"})
    check("derived: direct writes to proficiencies, item effects and armor stats stay blocked",
          st in (401, 403) and st2 in (401, 403) and (st3 in (401, 403) or rows == []), (st, st2, st3, rows))
    st, r, _ = rpc(alice, "set_character_proficiency", p_character=cid, p_group="firearms", created_by=carol_id)
    st2, rows, _ = call("GET", f"/rest/v1/character_proficiencies?character_id=eq.{cid}&group_id=eq.firearms&select=created_by", token=alice)
    check("derived: the proficiency RPC accepts no forged user id (extra argument rejected, nothing written)",
          st >= 400 and rows == [], (st, r, rows))
    st, chars, _ = call("GET", f"/rest/v1/characters?id=eq.{cid}&select=ac,speed,strength,dexterity", token=alice)
    check("derived: stored character stats were never changed by equipment", chars == [{"ac": 10, "speed": 30, "strength": 12, "dexterity": 14}],
          chars)



def lineage_section(alice, alice_id, bob, dm, camp_id):
    """Lineage catalog and character lineage RPCs over the real API (migration 20261015001500)."""
    carol, _ = user("api-carol@example.test")                 # not a member of the campaign
    st, chars, _ = svc("POST", "/rest/v1/characters", {"owner_id": alice_id, "name": f"API Lineage {RUN}", "campaign_id": camp_id,
                                                       "level": 3, "strength": 10, "dexterity": 14, "constitution": 12, "speed": 30},
                       {"Prefer": "return=representation"})
    cid = chars[0]["id"]
    st, cats, _ = call("GET", "/rest/v1/lineage_categories?select=id&order=sort_order")
    check("lineage: anonymous visitors list the four categories", st == 200 and [c["id"] for c in cats] == ["standard", "custom", "exotic", "monstrous"],
          (st, cats))
    st, rows, _ = call("GET", "/rest/v1/v_lineage_catalog?select=id,version_count,child_count&search_text=ilike.*stout*", token=alice)
    check("lineage: search finds a lineage by a sub-lineage name (stout -> halfling)",
          st == 200 and [r["id"] for r in rows] == ["halfling"] and rows[0]["child_count"] >= 6, (st, rows))
    st, rows, _ = call("GET", "/rest/v1/v_lineage_catalog?select=id&category_id=eq.custom", token=alice)
    check("lineage: filter by category", st == 200 and [r["id"] for r in rows] == ["custom"], (st, rows))
    st, det, _ = rpc(alice, "get_lineage_detail", p_lineage="halfling")
    versions = {v["id"]: v for v in (det or {}).get("versions", [])}
    check("lineage: detail returns versions, sub-lineages, sources, traits and effects",
          st == 200 and versions.get("halfling-phb", {}).get("requires_child") is True
          and versions.get("halfling-stout", {}).get("parent_version_id") == "halfling-phb"
          and versions["halfling-lotusden"]["setting"] == "Wildemount" and versions["halfling-phb"]["source_label"] == "Player's Handbook"
          and any(t["automation"] == "informational" for t in versions["halfling-phb"]["traits"]), (st, det and list(versions)))

    st, r, _ = rpc(alice, "set_character_lineage", p_character=cid, p_version="halfling-phb", p_subversion="custom-tce")
    check("lineage: an invalid version / sub-lineage combination is rejected (400 with a message)",
          st == 400 and "not a sub-lineage" in str(r), (st, r))
    st, r, _ = rpc(alice, "set_character_lineage", p_character=cid, p_version="halfling-phb", p_subversion="halfling-stout")
    check("lineage: the owner assigns Halfling (Stout)", st == 200 and r["selected"] and r["subversion"]["id"] == "halfling-stout"
          and r["unresolved"] == 0, (st, r))
    st, d, _ = rpc(alice, "get_character_derived_stats", p_character=cid)
    check("lineage: derived stats apply it (DEX 16, CON 13, speed 25, Small, poison resistance)",
          st == 200 and d["abilities"]["dex"]["score"] == 16 and d["abilities"]["con"]["score"] == 13 and d["speed"]["value"] == 25
          and d["size"]["value"] == "small" and [x["damage_type"] for x in d["resistances"]] == ["poison"], (st, d and d.get("speed")))

    st, r, _ = rpc(alice, "set_character_lineage", p_character=cid, p_version="custom-tce",
                   p_choices={"custom-tce:size": ["medium"], "custom-tce:asi": ["wis:2"]})
    check("lineage: incomplete choices are saved and reported", st == 200 and r["unresolved"] == 3, (st, r and r.get("unresolved")))
    st, r, _ = rpc(alice, "set_character_lineage", p_character=cid, p_version="custom-tce",
                   p_choices={"custom-tce:size": ["medium"]}, p_require_complete=True)
    check("lineage: strict mode rejects incomplete choices", st == 400 and "Incomplete" in str(r), (st, r))
    st, r, _ = rpc(alice, "set_character_lineage", p_character=cid, p_version="custom-tce", p_choices={"custom-tce:asi": ["wis:1"]})
    check("lineage: invalid choice values are rejected", st == 400 and "pattern" in str(r), (st, r))
    full = {"custom-tce:size": ["small"], "custom-tce:asi": ["wis:2"], "custom-tce:feat": ["Observant"],
            "custom-tce:variable-trait": ["skill"], "custom-tce:variable-skill": ["insight"], "custom-tce:language": ["sylvan"]}
    st, r, _ = rpc(alice, "set_character_lineage", p_character=cid, p_version="custom-tce", p_choices=full, p_require_complete=True)
    st2, rows, _ = call("GET", f"/rest/v1/character_lineage_choices?character_id=eq.{cid}&select=choice_id", token=alice)
    check("lineage: choices are saved and readable by the owner", st == 200 and r["unresolved"] == 0 and len(rows) == 6, (st, r, rows))

    st, r, _ = rpc(dm, "get_character_lineage", p_character=cid)
    check("lineage: the campaign DM reads the lineage", st == 200 and r["lineage"]["id"] == "custom", (st, r))
    st, r, _ = rpc(bob, "set_character_lineage", p_character=cid, p_version="halfling-phb", p_subversion="halfling-stout")
    st2, r2, _ = rpc(carol, "clear_character_lineage", p_character=cid)
    st3, rows, _ = call("GET", f"/rest/v1/character_lineages?character_id=eq.{cid}&select=version_id", token=bob)
    check("lineage: another player and an outsider cannot change or see it", st >= 400 and st2 >= 400 and rows == [], (st, st2, rows))
    st, r, _ = call("POST", "/rest/v1/character_lineages", token=alice, body={"character_id": cid, "lineage_id": "halfling", "version_id": "halfling-phb"})
    st2, r2, _ = call("PATCH", "/rest/v1/lineage_traits?id=eq.halfling-phb:lucky", token=alice, body={"summary": "x"})
    check("lineage: direct table writes are refused (RPC only, catalog read-only)", st >= 400 and st2 >= 400, (st, r, st2, r2))
    st, r, _ = rpc(alice, "clear_character_lineage", p_character=cid)
    st2, d, _ = rpc(alice, "get_character_derived_stats", p_character=cid)
    st3, ch, _ = call("GET", f"/rest/v1/characters?id=eq.{cid}&select=dexterity,constitution,wisdom,speed", token=alice)
    check("lineage: removal restores the stored values; the stored scores were never changed",
          st == 200 and r["cleared"] and d["lineage"] is None and d["speed"]["value"] == 30
          and ch == [{"dexterity": 14, "constitution": 12, "wisdom": 10, "speed": 30}], (st, r, ch))



def spell_section(alice, alice_id, bob, dm, camp_id):
    """Spell catalog, class lists and the character spellbook over the real API (migration 20261015001600)."""
    carol, _ = user("api-carol@example.test")
    st, chars, _ = svc("POST", "/rest/v1/characters", {"owner_id": alice_id, "name": f"API Spells {RUN}", "campaign_id": camp_id,
                                                       "level": 3, "intelligence": 16, "wisdom": 12, "charisma": 14}, {"Prefer": "return=representation"})
    cid = chars[0]["id"]
    book = lambda tok=alice: rpc(tok, "get_character_spellbook", p_character=cid)   # noqa: E731
    st, rows, _ = call("GET", "/rest/v1/v_spell_catalog?select=id,school_id,ritual,concentration&id=in.(fireball-phb,alarm-phb,bless-phb)&order=id")
    check("spells: anonymous visitors read the official catalog (school id, ritual, concentration fields)",
          st == 200 and rows == [{"id": "alarm-phb", "school_id": "abjuration", "ritual": True, "concentration": False},
                                 {"id": "bless-phb", "school_id": "enchantment", "ritual": False, "concentration": True},
                                 {"id": "fireball-phb", "school_id": "evocation", "ritual": False, "concentration": False}], (st, rows))
    st, r, _ = call("PATCH", "/rest/v1/spell_versions?id=eq.fireball-phb", token=alice, body={"name": "Hacked"})
    st2, r2, _ = call("POST", "/rest/v1/catalog_spells", token=alice, body={"id": "hacked", "name": "Hacked"})
    check("spells: clients cannot edit or add official spells", st >= 400 and st2 >= 400, (st, r, st2, r2))
    st, rows, _ = call("GET", "/rest/v1/class_spell_list_entries?list_id=eq.artificer-spell-list&select=spell_version_id,spell_level&spell_level=eq.0", token=alice)
    check("spells: the Artificer list query works (cantrips)", st == 200 and len(rows) >= 10 and all(x["spell_level"] == 0 for x in rows),
          (st, len(rows or [])))
    st, rows, _ = call("GET", "/rest/v1/v_spell_catalog?select=id&class_lists=cs.{artificer-spell-list}&id=eq.fireball-phb", token=alice)
    st2, rows2, _ = call("GET", "/rest/v1/v_spell_catalog?select=id&class_lists=cs.{wizard-spell-list}&id=eq.fireball-phb", token=alice)
    check("spells: class-list eligibility query (Fireball: not Artificer, Wizard yes)", rows == [] and rows2 == [{"id": "fireball-phb"}], (rows, rows2))

    st, src, _ = rpc(alice, "save_character_spellcasting_source", p_character=cid,
                     p_source={"source_type": "class", "label": "Artificer (preview)", "class_version_id": "artificer-tce", "enforce_spell_list": True})
    st2, man, _ = rpc(alice, "save_character_spellcasting_source", p_character=cid,
                      p_source={"source_type": "manual", "label": "Manual", "casting_ability": "cha", "always_prepared_allowed": True})
    st3, item, _ = rpc(alice, "save_character_spellcasting_source", p_character=cid, p_source={"source_type": "item", "label": "Wand", "fixed_dc": 15})
    check("spells: the owner creates class-preview, manual and item sources", st == 200 and st2 == 200 and st3 == 200 and src["is_preview"],
          (st, src, st2, st3))
    st, r, _ = rpc(alice, "set_character_spell", p_character=cid, p_source=man["id"], p_spell_version="detect-magic-phb")
    check("spells: the owner adds a manual spell", st == 200 and r["known"], (st, r))
    st, r, _ = rpc(alice, "set_character_spell", p_character=cid, p_source=src["id"], p_spell_version="cure-wounds-phb", p_known=True, p_prepared=False)
    st2, r2, _ = rpc(alice, "set_character_spell_prepared", p_character_spell=r["id"], p_prepared=True)
    st3, r3, _ = rpc(alice, "set_character_spell_prepared", p_character_spell=r["id"], p_prepared=False)
    check("spells: the owner prepares and unprepares a spell", st2 == 200 and r2["prepared"] and st3 == 200 and not r3["prepared"],
          (st2, r2, st3, r3))
    st, r, _ = rpc(alice, "set_character_spell", p_character=cid, p_source=src["id"], p_spell_version="fireball-phb")
    check("spells: a class source that enforces its list rejects an off-list spell", st == 400 and "spell list" in str(r), (st, r))
    rpc(alice, "set_character_spell", p_character=cid, p_source=item["id"], p_spell_version="fireball-phb")
    rpc(alice, "set_character_lineage", p_character=cid, p_version="tiefling-phb", p_subversion="tiefling-asmodeus")
    rpc(alice, "set_character_spell", p_character=cid, p_source=man["id"], p_spell_version="thaumaturgy-phb")
    st, b, _ = book()
    sp = {x["id"]: x for x in b.get("spells", [])} if st == 200 else {}
    srcs = {x["label"]: x for x in b.get("sources", [])} if st == 200 else {}
    check("spells: the owner reads the spellbook; lineage spells appear automatically",
          st == 200 and "hellish-rebuke-phb" in sp and sp["hellish-rebuke-phb"]["grants"][0]["source_type"] == "lineage", (st, list(sp)))
    check("spells: a spell from two sources is one entry with both grants", sp.get("thaumaturgy-phb", {}).get("source_count") == 2,
          sp.get("thaumaturgy-phb"))
    lin = next((x for x in b.get("sources", []) if x["source_type"] == "lineage"), {})
    check("spells: source-aware Save DC and attack (Artificer INT 13/+5, manual CHA 14 + 2 lineage = 16: 13/+5, item fixed 15, lineage 13)",
          srcs["Artificer (preview)"]["stats"]["save_dc"] == 13 and srcs["Artificer (preview)"]["stats"]["attack_bonus"] == 5
          and srcs["Manual"]["stats"]["save_dc"] == 13 and srcs["Manual"]["stats"]["attack_bonus"] == 5
          and srcs["Wand"]["stats"]["save_dc"] == 15 and lin.get("stats", {}).get("save_dc") == 13,
          [(k, v["stats"]) for k, v in srcs.items()])
    check("spells: the item spell carries the fixed DC", sp["fireball-phb"]["grants"][0]["stats"]["save_dc"] == 15, sp["fireball-phb"]["grants"])
    st, r, _ = book(dm)
    check("spells: the campaign DM reads the spellbook", st == 200 and len(r["spells"]) >= 5, st)
    st, r, _ = book(carol)
    st2, rows, _ = call("GET", f"/rest/v1/character_spells?character_id=eq.{cid}&select=id", token=bob)
    check("spells: an outsider and another player are denied", st >= 400 and rows == [], (st, rows))
    st, r, _ = rpc(bob, "set_character_spell", p_character=cid, p_source=man["id"], p_spell_version="alarm-phb")
    st2, r2, _ = rpc(bob, "save_character_spellcasting_source", p_character=cid, p_source={"source_type": "manual", "label": "Forged"})
    check("spells: another player cannot add spells or forge sources on the character", st >= 400 and st2 >= 400, (st, r, st2, r2))
    st, r, _ = rpc(alice, "save_character_spellcasting_source", p_character=cid,
                   p_source={"source_type": "manual", "label": "x", "character_id": cid, "created_by": alice_id})
    check("spells: no RPC accepts a forged owner or character id in the payload", st == 400 and "cannot be set" in str(r), (st, r))
    st, r, _ = call("POST", "/rest/v1/character_spells", token=alice, body={"character_id": cid, "source_id": man["id"], "spell_version_id": "alarm-phb"})
    st2, r2, _ = call("DELETE", f"/rest/v1/character_spellcasting_sources?id=eq.{man['id']}", token=alice)
    st3, rows, _ = call("GET", f"/rest/v1/character_spellcasting_sources?id=eq.{man['id']}&select=id", token=alice)
    check("spells: direct writes to character spells and sources stay blocked", st >= 400 and rows and len(rows) == 1, (st, st2, rows))
    st, r, _ = rpc(alice, "set_character_spell", p_character=cid, p_source=man["id"], p_spell_version="no-such-spell-xx")
    check("spells: unknown or invisible spells cannot be granted (homebrew / manual scope respected)", st == 400 and "Unknown spell" in str(r), (st, r))



def class_section(alice, alice_id, bob, dm, camp_id):
    """Class levels, spell slots, Pact Magic, resources and rests over the real API (migration 20261015001700)."""
    carol, _ = user("api-carol@example.test")
    st, chars, _ = svc("POST", "/rest/v1/characters", {"owner_id": alice_id, "name": f"API Classes {RUN}", "campaign_id": camp_id,
                                                       "level": 2, "intelligence": 16, "wisdom": 12, "charisma": 16}, {"Prefer": "return=representation"})
    cid = chars[0]["id"]
    st, rows, _ = call("GET", "/rest/v1/spell_slot_progression_levels?progression_id=eq.standard-caster&class_level=eq.5&select=slot_level,slots&order=slot_level")
    check("classes: anonymous visitors read the slot progression tables (caster level 5: 4 / 3 / 2)",
          st == 200 and [(r["slot_level"], r["slots"]) for r in rows] == [(1, 4), (2, 3), (3, 2)], (st, rows))
    st, r, _ = rpc(alice, "get_character_class_summary", p_character=cid)
    check("classes: without classes the summary reports the legacy level as a fallback", st == 200 and r["fallback"] and r["total_level"] == 2, r)
    st, r, _ = rpc(alice, "set_character_class", p_character=cid, p_class_version="wizard-phb", p_level=3)
    st2, r2, _ = rpc(alice, "set_character_class", p_character=cid, p_class_version="warlock-phb", p_level=3)
    check("classes: the owner adds Wizard 3 and Warlock 3 (total 6, PB +3, Wizard primary)",
          st == 200 and st2 == 200 and r2["total_level"] == 6 and r2["proficiency_bonus"] == 3
          and next(k for k in r2["classes"] if k["class_id"] == "wizard")["is_primary"], (st, r, st2, r2))
    st, rows, _ = call("GET", f"/rest/v1/characters?id=eq.{cid}&select=level", token=alice)
    st2, r2, _ = call("PATCH", f"/rest/v1/characters?id=eq.{cid}", token=alice, body={"level": 12})
    check("classes: characters.level mirrors the classes; a conflicting edit is refused", rows == [{"level": 6}] and st2 == 400, (rows, st2, r2))
    st, slots, _ = rpc(alice, "get_character_spell_slots", p_character=cid)
    check("classes: standard slots from Wizard 3 only; Pact Magic separate (2 slots of 2nd level)",
          st == 200 and [(x["slot_level"], x["max"]) for x in slots["standard"]] == [(1, 4), (2, 2)]
          and slots["pact_magic"]["max"] == 2 and slots["pact_magic"]["slot_level"] == 2, slots)
    st, r, _ = rpc(alice, "expend_standard_spell_slot", p_character=cid, p_slot_level=2)
    st2, r2, _ = rpc(alice, "expend_pact_magic_slot", p_character=cid)
    check("classes: the owner uses a 2nd-level slot and a Pact slot; each pool changes on its own",
          st == 200 and st2 == 200 and [x["remaining"] for x in r2["standard"]] == [4, 1] and r2["pact_magic"]["remaining"] == 1, (r, r2))
    st, r, _ = rpc(alice, "expend_standard_spell_slot", p_character=cid, p_slot_level=4)
    check("classes: a slot level the character does not have is refused", st == 400 and "no level 4" in str(r), (st, r))
    # concurrency: two requests race for the last 2nd-level slot
    out = []
    t = [threading.Thread(target=lambda: out.append(rpc(alice, "expend_standard_spell_slot", p_character=cid, p_slot_level=2)[0])) for _ in range(2)]
    [x.start() for x in t]
    [x.join() for x in t]
    st, slots, _ = rpc(alice, "get_character_spell_slots", p_character=cid)
    check("classes: two parallel requests for the last slot: exactly one succeeds, never below zero",
          sorted(out) == [200, 400] and [x["remaining"] for x in slots["standard"]] == [4, 0], (out, slots["standard"]))
    rest_id = str(uuid.uuid4())
    st, r, _ = rpc(alice, "short_rest_character", p_character=cid, p_rest_id=rest_id)
    st2, r2, _ = rpc(alice, "short_rest_character", p_character=cid, p_rest_id=rest_id)
    st3, slots, _ = rpc(alice, "get_character_spell_slots", p_character=cid)
    check("classes: a short rest restores Pact slots only; repeating the same rest id is safe",
          st == 200 and not r["already_applied"] and r2["already_applied"] and slots["pact_magic"]["remaining"] == 2
          and [x["remaining"] for x in slots["standard"]] == [4, 0], (r, r2, slots))
    st, r, _ = rpc(alice, "long_rest_character", p_character=cid)
    st2, slots, _ = rpc(alice, "get_character_spell_slots", p_character=cid)
    check("classes: a long rest restores standard slots", st == 200 and [x["remaining"] for x in slots["standard"]] == [4, 2], (r, slots))
    st, summary, _ = rpc(alice, "get_character_class_summary", p_character=cid)
    wiz_src = next(k for k in summary["classes"] if k["class_id"] == "wizard")["spellcasting"]["source_id"]
    st, r, _ = rpc(alice, "set_character_spell", p_character=cid, p_source=wiz_src, p_spell_version="fireball-phb")
    st2, r2, _ = rpc(alice, "set_character_spell", p_character=cid, p_source=wiz_src, p_spell_version="misty-step-phb")
    check("classes: the class source accepts spells up to its own level (Misty Step) and refuses Fireball",
          st == 400 and "level 3 Wizard" in str(r) and st2 == 200, (st, r, st2, r2))
    st, r, _ = rpc(dm, "get_character_class_summary", p_character=cid)
    st2, r2, _ = rpc(dm, "get_character_spell_slots", p_character=cid)
    check("classes: the campaign DM reads the summary and the slots", st == 200 and st2 == 200 and r["total_level"] == 6, (st, st2))
    st, r, _ = rpc(bob, "expend_standard_spell_slot", p_character=cid, p_slot_level=1)
    st2, r2, _ = rpc(bob, "set_character_class", p_character=cid, p_class_version="bard-phb", p_level=1)
    st3, r3, _ = rpc(carol, "get_character_spell_slots", p_character=cid)
    check("classes: another player and an outsider cannot read or change classes and slots", st >= 400 and st2 >= 400 and st3 >= 400, (st, st2, st3))
    st, r, _ = call("POST", "/rest/v1/character_classes", token=alice, body={"character_id": cid, "class_id": "bard", "class_version_id": "bard-phb", "level": 1})
    st2, r2, _ = call("PATCH", f"/rest/v1/character_spell_slot_state?character_id=eq.{cid}", token=alice, body={"expended": 0})
    st3, r3, _ = rpc(alice, "_slot_change", p_character=cid, p_pool="standard", p_slot_level=1, p_delta=-5, p_reason=None)
    check("classes: direct writes and the internal slot helper are blocked (RPCs only)", st >= 400 and st3 >= 400
          and (st2 >= 400 or r2 in ([], None)), (st, st2, r2, st3))
    st, r, _ = rpc(alice, "save_character_resource", p_character=cid, p_resource={"resource_key": "x", "name": "x", "character_id": cid})
    check("classes: a resource payload with a forged character id is refused", st == 400 and "cannot be set" in str(r), (st, r))
    st, r, _ = rpc(alice, "set_spell_slot_state", p_character=cid, p_pool="standard", p_slot_level=1, p_expended=2, p_reason="")
    st2, r2, _ = rpc(alice, "set_spell_slot_state", p_character=cid, p_pool="standard", p_slot_level=1, p_expended=2, p_reason="api check")
    st3, ev, _ = call("GET", f"/rest/v1/character_resource_events?character_id=eq.{cid}&event_type=eq.manual_set&select=reason,expended_after", token=alice)
    check("classes: a manual correction needs a reason and is logged as manual_set",
          st == 400 and st2 == 200 and ev == [{"reason": "api check", "expended_after": 2}], (st, st2, ev))
    wl = next(k for k in summary["classes"] if k["class_id"] == "warlock")["id"]
    st, r, _ = rpc(alice, "remove_character_class", p_character_class=wl)
    st2, slots, _ = rpc(alice, "get_character_spell_slots", p_character=cid)
    check("classes: removing Warlock removes the Pact pool; Wizard and its spells stay; level 3",
          st == 200 and slots["pact_magic"] is None and r["total_level"] == 3, (st, r, slots.get("pact_magic")))


def feature_section(alice, alice_id, bob, dm, camp_id):
    """Class feature engine over the real API (migration 20261015001800). Needs the synthetic test fixture
    (supabase/tests/fixtures/class_feature_engine_fixture.sql); the runner loads it before this test."""
    st, chars, _ = svc("POST", "/rest/v1/characters", [
        {"owner_id": alice_id, "name": f"API Features {RUN}", "campaign_id": camp_id, "strength": 14, "dexterity": 14,
         "wisdom": 16, "charisma": 12},
        {"owner_id": alice_id, "name": f"API Feature Import {RUN}", "campaign_id": None, "strength": 14, "dexterity": 14,
         "wisdom": 16, "charisma": 12}],
        {"Prefer": "return=representation"})
    cid, cid2 = chars[0]["id"], chars[1]["id"]
    st, r, _ = rpc(alice, "set_character_class", p_character=cid, p_class_version="engine-test-fixture", p_level=2)
    row = next(k for k in r["classes"] if k["class_id"] == "engine-test")["id"]
    key = lambda res: f"f:{row}:{res}"

    def feats():
        return rpc(alice, "get_character_class_features", p_character=cid)[1]

    def feature(state, unlock):
        return next((f for k in state["classes"] for f in k["features"] if f["unlock_id"] == unlock), None)

    def choice(state, k):
        return next((c for x in state["classes"] for c in x["choices"] if c["key"] == k), None)

    st, f, _ = rpc(alice, "get_character_class_features", p_character=cid)
    check("features: the owner reads the resolved class features (level 2: Test Burst active, Extra Attack not yet)",
          st == 200 and feature(f, "et-u2-burst")["active"] and feature(f, "et-u5-extra-attack") is None
          and f["automation_coverage"]["automated"] > 0, (st, f if st != 200 else None))
    st, f2, _ = rpc(dm, "get_character_class_features", p_character=cid)
    check("features: the campaign DM reads the resolved class features", st == 200 and f2["character_id"] == cid, st)
    st, r, _ = rpc(bob, "get_character_class_features", p_character=cid)
    st2, r2, _ = call("GET", f"/rest/v1/character_feature_choices?character_id=eq.{cid}", token=bob)
    check("features: another player is denied (RPC error, no rows)", st >= 400 and r2 == [], (st, r2))

    st, r, _ = rpc(alice, "set_character_feature_choice", p_character=cid, p_character_class=row, p_unlock="et-u1-fighting-style",
                   p_choice="et-style", p_values=["archery"])
    check("features: the owner completes a feature choice", st == 200 and choice(r, "et-u1-fighting-style:et-style")["status"] == "complete", (st, r))
    st, r, _ = rpc(alice, "set_character_feature_choice", p_character=cid, p_character_class=row, p_unlock="et-u1-fighting-style",
                   p_choice="et-style", p_values=["flying"])
    check("features: an invalid option is rejected", st == 400 and "not one of the options" in str(r), (st, r))
    st, r, _ = rpc(alice, "set_character_feature_choice", p_character=cid, p_character_class=row, p_unlock="et-u1-proficiencies",
                   p_choice="et-skills", p_values=["athletics", "perception"])
    st2, d, _ = rpc(alice, "get_character_derived_stats", p_character=cid)
    check("features: a feature skill proficiency appears in the derived stats; class armor proficiency is listed",
          st == 200 and d["skills"]["athletics"].get("class_proficient")
          and any(p.get("group_id") == "martial-weapons" and p["source_type"] == "class" for p in d["proficiencies"]), (st, r))
    st, r, _ = rpc(alice, "set_character_optional_feature", p_character=cid, p_character_class=row, p_unlock="et-u1-optional-lore", p_enabled=True)
    check("features: the owner selects an optional feature", st == 200 and feature(r, "et-u1-optional-lore")["active"], (st, r))
    st, r, _ = rpc(alice, "set_character_subclass", p_character=cid, p_character_class=row, p_subclass_version="engine-test-path-fixture")
    check("features: a subclass before its level is rejected", st == 400 and "can be chosen from" in str(r), (st, r))

    st, pv, _ = rpc(alice, "preview_character_class_change", p_character=cid, p_character_class=row, p_level=5)
    st2, f, _ = rpc(alice, "get_character_class_features", p_character=cid)
    check("features: the level preview is read only (shows Extra Attack; the level stays 2)",
          st == 200 and any(x["name"] == "Extra Attack" for x in pv["features_activated"]) and f["total_level"] == 2, (st, pv))
    st, r, _ = rpc(alice, "set_character_class", p_character=cid, p_class_version="engine-test-fixture", p_level=5, p_character_class=row)
    check("features: a level increase activates features (Extra Attack, 2 attacks)",
          st == 200 and feature(feats(), "et-u5-extra-attack")["active"]
          and rpc(alice, "get_character_derived_stats", p_character=cid)[1]["attacks_per_action"]["value"] == 2, (st, r))
    st, r, _ = rpc(alice, "set_character_subclass", p_character=cid, p_character_class=row, p_subclass_version="engine-test-path-fixture")
    check("features: the owner selects the subclass at its level; a subclass feature applies (critical range 19)",
          st == 200 and rpc(alice, "get_character_derived_stats", p_character=cid)[1]["critical_range"]["value"] == 19, (st, r))
    st, r, _ = rpc(alice, "set_character_optional_feature", p_character=cid, p_character_class=row, p_unlock="et-u3-swift-reflexes", p_enabled=True)
    check("features: the owner selects a replacement feature; the replaced feature becomes inactive",
          st == 200 and feature(r, "et-u3-keen-senses")["status"] == "replaced" and feature(r, "et-u3-swift-reflexes")["active"], (st, r))
    st, b, _ = rpc(alice, "get_character_spellbook", p_character=cid)
    check("features: a feature spell (Detect Magic, always prepared) appears in the spellbook with its own source",
          st == 200 and any(sp["id"] == "detect-magic-phb" and sp["always_prepared"] for sp in b["spells"])
          and any(src["source_type"] == "class_feature" for src in b["sources"]), st)
    st, d, _ = rpc(alice, "get_character_derived_stats", p_character=cid)
    check("features: a feature attack appears in the attack summary (Spirit Strike 1d8 at level 5)",
          st == 200 and any(a["name"] == "Spirit Strike" and a["damage_dice"] == "1d8" for a in d["feature_attacks"]), st)

    # resources
    st, r, _ = rpc(alice, "expend_character_resource", p_character=cid, p_resource_key=key("et-surge-uses"))
    check("features: the owner spends a class resource", st == 200 and r["remaining"] == 0 and r["max"] == 1, (st, r))
    results_box = []

    def spend():
        results_box.append(rpc(alice, "expend_character_resource", p_character=cid, p_resource_key=key("et-burst-uses"))[0])
    threads = [threading.Thread(target=spend) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    check("features: three concurrent requests for the last use: exactly one succeeds", sorted(results_box) == [200, 400, 400], results_box)
    rpc(alice, "expend_character_resource", p_character=cid, p_resource_key=key("et-reserve-uses"))
    st, r, _ = rpc(alice, "short_rest_character", p_character=cid)
    restored = [x["name"] for x in r["breakdown"]["restored"]]
    not_restored = [x["name"] for x in r["breakdown"]["not_restored"]]
    check("features: a short rest restores short-rest resources only (Surge, Burst; not Reserve)",
          st == 200 and "Test Surge" in restored and "Test Burst" in restored and "Test Reserve" in not_restored, r.get("breakdown"))
    st, r, _ = rpc(alice, "long_rest_character", p_character=cid)
    st2, res, _ = rpc(alice, "get_character_resources", p_character=cid)
    reserve = next(x for x in res["resources"] if x["resource_id"] == "et-reserve-uses")
    check("features: a long rest restores long-rest resources", st == 200 and reserve["remaining"] == reserve["max"] == 3, reserve)
    st, r, _ = rpc(bob, "expend_character_resource", p_character=cid, p_resource_key=key("et-surge-uses"))
    check("features: an outsider cannot spend a resource", st >= 400, (st, r))

    # unsafe writes, forged ids
    st, r, _ = call("POST", "/rest/v1/character_feature_choices", token=alice,
                    body={"character_id": cid, "character_class_id": row, "unlock_id": "et-u1-strike", "choice_id": "et-style"})
    st2, r2, _ = call("PATCH", f"/rest/v1/character_resources?character_id=eq.{cid}", token=alice, body={"expended": 0})
    st3, r3, _ = call("POST", "/rest/v1/class_feature_versions", token=alice,
                      body={"id": "x", "feature_id": "et-strike", "name": "x", "summary": "x", "source_label": "x", "automation": "automated"})
    check("features: direct writes to choices, resource state and the catalog are blocked", st >= 400 and st3 >= 400
          and (st2 >= 400 or r2 in ([], None)), (st, st2, st3))
    st, r, _ = rpc(bob, "set_character_feature_choice", p_character=cid, p_character_class=row, p_unlock="et-u1-fighting-style",
                   p_choice="et-style", p_values=["defense"])
    st2, r2, _ = rpc(alice, "expend_character_resource", p_character=cid2, p_resource_key=key("et-surge-uses"))
    check("features: a forged owner (another user's call) and a forged class row of another character are refused",
          st >= 400 and st2 >= 400, (st, r, st2, r2))

    # export / import round trip
    rpc(alice, "expend_character_resource", p_character=cid, p_resource_key=key("et-focus-points"), p_amount=2)
    st, ex, _ = rpc(alice, "export_character_class_features", p_character=cid)
    st2, r2, _ = rpc(alice, "set_character_class", p_character=cid2, p_class_version="engine-test-fixture", p_level=5,
                     p_subclass_version="engine-test-path-fixture")
    row2 = next(k for k in r2["classes"] if k["class_id"] == "engine-test")["id"]
    payload = dict(ex, classRows={row: row2})
    st3, rep, _ = rpc(alice, "import_character_class_features", p_character=cid2, p_payload=payload)
    st4, f2, _ = rpc(alice, "get_character_class_features", p_character=cid2)
    focus = next(x for x in f2["resources"] if x["resource_id"] == "et-focus-points")
    check("features: export / import round trip keeps choices, optional features and resource state",
          st == 200 and st3 == 200 and choice(f2, "et-u1-fighting-style:et-style")["values"] == ["archery"]
          and feature(f2, "et-u3-keen-senses")["status"] == "replaced" and focus["remaining"] == 3 and rep["unresolved"] == [],
          (st, st3, rep))


if __name__ == "__main__":
    main()
