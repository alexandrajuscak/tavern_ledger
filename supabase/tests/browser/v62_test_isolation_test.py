"""The test-isolation harness itself (docs/V62_TEST_ISOLATION.md): synthetic setup, cleanup, protected digests, interruption
detection. Synthetic users only (ui-*@example.test). Refuses non-local URLs (class_ui_common)."""
import json
import uuid

import isolation as iso
from class_ui_common import RUN, User, call, check, report


def make_world(tag):
    """A synthetic player + DM, a campaign, a character with inventory, homebrew item and published DM content."""
    pl, dm = User(f"{tag}-pl"), User(f"{tag}-dm")
    ch = pl.character(f"Iso Fighter {RUN}", [("fighter-phb", 2)])
    camp = str(uuid.uuid4())
    iso.psql(f"""insert into public.campaigns (id, name, created_by) values ('{camp}', 'UI Adversarial Campaign', '{dm.id}');
      insert into public.campaign_members (campaign_id, user_id, role) values ('{camp}', '{dm.id}', 'dm'), ('{camp}', '{pl.id}', 'player');
      update public.characters set campaign_id = '{camp}' where id = '{ch}';""")
    _, inv = call("GET", f"/rest/v1/inventories?character_id=eq.{ch}&kind=eq.character&select=id", token=pl.jwt)
    st, _ = pl.rpc("add_inventory_item", p_inventory=inv[0]["id"], p_item="dagger", p_quantity=3, p_custom_name=None, p_notes=None, p_state={})
    assert st == 200, st
    st, c = dm.rpc("create_dm_content", p_type="item", p_campaign=camp, p_request_id=str(uuid.uuid4()),
                   p_fields={"name": f"Iso Charm {RUN}", "player_text": "x", "definition": {"item": {"kind_id": "gear", "is_magic": True, "rarity_id": "common"}}})
    assert 200 <= st < 300, c
    return pl, dm, ch, camp


def main():
    start = iso.table_digests()
    check("I0 no synthetic residue before the suite", not iso.residue(), iso.residue())

    # 1. a normal isolated test: everything synthetic is removed, every public table is identical afterwards
    with iso.Isolated("ISO-1 normal") as t:
        pl, dm, ch, camp = make_world("iso1")
        t.note(character=ch, campaign=camp)
        st, _ = call("PATCH", f"/rest/v1/characters?id=eq.{ch}", {"hp_current": 3}, token=pl.jwt)
        check("I1 the synthetic world exists during the test (user, campaign, character, items, DM content)",
              {"users", "campaigns", "characters", "dm_content"} <= set(iso.residue()) and st in (200, 204), iso.residue())
    check("I2 after the test: no residue and all 152 public tables byte-identical to the start", not iso.residue() and iso.table_digests() == start)
    last = json.loads(iso.JOURNAL.read_text(encoding="utf-8").strip().splitlines()[-1])
    check("I3 the journal records the test, what was removed and the reconciliation", last["test"] == "ISO-1 normal" and last["removed"].get("characters") == 1
          and last["residue_after"] == {} and last["protected_tables_changed"] == [], last)

    # 2. cleanup interrupted: the harness must notice and report it, not continue silently
    real_cleanup = iso.cleanup
    iso.cleanup = lambda: iso.psql(f"delete from public.characters where owner_id in {iso.SYN_USERS};") and {}   # only part of the work
    caught = None
    try:
        with iso.Isolated("ISO-2 interrupted cleanup"):
            make_world("iso2")
    except iso.IsolationError as e:
        caught = str(e)
    finally:
        iso.cleanup = real_cleanup
    check("I4 an interrupted cleanup is detected and reported (leftover users / campaign / content named)",
          caught is not None and "residue" in caught and "users" in caught, caught)
    last = json.loads(iso.JOURNAL.read_text(encoding="utf-8").strip().splitlines()[-1])
    check("I5 the journal records the failed reconciliation honestly", last["test"] == "ISO-2 interrupted cleanup" and last["residue_after"], last)

    # 3. a later run refuses to start on residue unless it may clean first; resuming the cleanup restores the start state
    refused = None
    try:
        with iso.Isolated("ISO-3 refuses residue", clean_first=False):
            pass
    except iso.IsolationError as e:
        refused = str(e)
    check("I6 a test refuses to start on residue when it may not clean it", refused is not None and "residue" in refused, refused)
    removed = iso.cleanup()
    check("I7 resuming the cleanup removes the leftovers", removed and not iso.residue(), (removed, iso.residue()))
    check("I8 ... and every public table is identical to the start again", iso.table_digests() == start)
    report()


main()
