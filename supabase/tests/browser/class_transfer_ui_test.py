"""Browser test of JSON export / import with official class data: a multiclass Ranger / Druid (Tasha's replacements, choices,
subclass, spells) with a companion; export from the Bio tab, import as a new character, and the imported character has the
same classes, choices, optional features, derived riders and the companion. Local-only network, no console errors.
"""
import json
import re
from pathlib import Path

from playwright.sync_api import sync_playwright

from class_ui_common import APP, RUN, SHOTS, Sheet, User, call, check, report


def main():
    u = User("transfer")
    ch = u.character("Transfer UI Tester", [("ranger-phb", 3, "ranger-hunter-phb"), ("druid-phb", 2)], dexterity=16, wisdom=14)
    _, rows = call("GET", f"/rest/v1/character_classes?character_id=eq.{ch}&class_id=eq.ranger&select=id", token=u.jwt)
    row = rows[0]["id"]
    for unlock in ("ranger-phb-u1-favored-foe", "ranger-phb-u1-deft-explorer"):
        st, r = u.rpc("set_character_optional_feature", p_character=ch, p_character_class=row, p_unlock=unlock, p_enabled=True)
        assert st == 200, (st, r)
    for unlock, choice, vals in [("ranger-phb-u1-proficiencies", "ranger-proficiencies-phb-skills", ["stealth", "survival", "perception"]),
                                 ("ranger-phb-u1-deft-explorer", "ranger-deft-explorer-tce-canny-skill", ["survival"]),
                                 ("ranger-phb-u1-deft-explorer", "ranger-deft-explorer-tce-canny-languages", ["elvish", "sylvan"]),
                                 ("ranger-phb-u2-fighting-style", "ranger-fighting-style-phb-style", ["archery"]),
                                 ("ranger-hunter-phb-u3-hunters-prey", "ranger-hunter-hunters-prey-phb-prey", ["colossus-slayer"])]:
        st, r = u.rpc("set_character_feature_choice", p_character=ch, p_character_class=row, p_unlock=unlock, p_choice=choice, p_values=vals,
                      p_manual_status=None)
        assert st == 200, (unlock, st, r)
    st, cid = u.rpc("add_character_companion", p_character=ch, p_creature="wolf", p_name="Ash", p_source="Animal friend", p_hp_max=None)
    assert st == 200, (st, cid)
    u.rpc("update_character_companion", p_companion=cid, p_patch={"hp_current": 7, "notes": "Good boy"})
    st, r = u.rpc("assign_character_feat", p_character=ch, p_version="tough-2024", p_choices={}, p_source_type="direct",
                  p_source_note=None, p_override_reason=None, p_notes="Exported feat")
    assert st == 200, (st, r)
    SHOTS.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="bio")
        page = s.page
        s.open(ch)
        s.tab("bio")
        with page.expect_download() as dl:
            page.locator("[data-action=export-json]").click()
        exported = json.loads(Path(dl.value.path()).read_text(encoding="utf-8"))
        cf = exported.get("classFeatures") or {}
        check("TR1 the export has both class rows, the Tasha's replacements and the choices with stable ids",
              {k["classVersion"] for k in exported.get("classes", [])} == {"ranger-phb", "druid-phb"}
              and {o["unlock"] for o in cf.get("optionalFeatures", [])} == {"ranger-phb-u1-favored-foe", "ranger-phb-u1-deft-explorer"}
              and any(c["choice"] == "ranger-hunter-hunters-prey-phb-prey" and c["values"] == ["colossus-slayer"] for c in cf.get("choices", [])),
              (exported.get("classes"), cf.get("optionalFeatures")))
        check("TR2 the export has the companion (catalog wolf, 7 / 11 HP, notes)",
              exported.get("companions") == [{"creature": "wolf", "name": "Ash", "source": "Animal friend", "hpMax": 11, "hpCurrent": 7,
                                              "notes": "Good boy", "active": True}], exported.get("companions"))
        check("TR2b the export has the Tough (2024) feat with its version id and notes, no DM-only data",
              [(f["version"], f["sourceType"], f["notes"]) for f in exported.get("feats", [])] == [("tough-2024", "direct", "Exported feat")]
              and "dm_note" not in json.dumps(exported), exported.get("feats"))
        exported["name"] = f"Transfer UI Tester (imported {RUN})"
        imp = SHOTS / f"class_transfer_{RUN}.json"
        imp.write_text(json.dumps(exported), encoding="utf-8")
        page.goto(APP)
        page.click("#btn-import")
        page.set_input_files(".modal input[name=file]", str(imp))
        page.locator(".modal button[type=submit]").click()
        page.wait_for_url(re.compile(r"#/c/"), timeout=20000)
        new_id = page.url.split("#/c/")[1].split("/")[0]
        page.wait_for_timeout(1500)
        s.tab("combat")
        glance = page.locator("#feature-attacks")
        check("TR3 the imported character has Favored Foe 1d4 and Colossus Slayer 1d8 with its attacks (Play)",
              s.wait(lambda: "Favored Foe 1d4" in glance.text_content() and "Colossus Slayer 1d8" in glance.text_content()),
              glance.text_content()[:300] if glance.count() else "")
        def open_choices(cid):
            st, f = u.rpc("get_character_class_features", p_character=cid)
            return sorted((k["class_id"], c["key"]) for k in f["classes"] for c in k["choices"]
                          if c.get("open") and c.get("status") in ("incomplete", "invalid"))
        check("TR4 the import keeps exactly the open choices of the original (here only the Druid circle)",
              open_choices(new_id) == open_choices(ch) and len(open_choices(ch)) == 1, (open_choices(ch), open_choices(new_id)))
        comp = page.locator("#companions-body [data-companion]")
        check("TR5 the companion Ash came along (7 / 11 HP, notes)",
              s.wait(lambda: comp.count() == 1 and "Ash" in comp.inner_text() and "7 / 11" in comp.inner_text() and "Good boy" in comp.inner_text()),
              comp.inner_text() if comp.count() else "")
        _, rows = call("GET", f"/rest/v1/character_classes?character_id=eq.{new_id}&select=class_version_id,level,subclass_version_id", token=u.jwt)
        check("TR6 class rows: Ranger 3 (Hunter) and Druid 2", sorted((r["class_version_id"], r["level"], r["subclass_version_id"]) for r in rows)
              == [("druid-phb", 2, None), ("ranger-phb", 3, "ranger-hunter-phb")], rows)
        st, nf = u.rpc("get_character_feats", p_character=new_id)
        check("TR6b the imported character has Tough (2024) again, with its notes",
              [(f["feat"]["id"], f.get("notes")) for f in nf["feats"]] == [("tough-2024", "Exported feat")], nf.get("feats"))
        check("TR7 no console errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        s.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
