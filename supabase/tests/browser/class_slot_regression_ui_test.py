"""Browser regression test of spell-slot Use / Restore (docs/SPELL_SLOT_BUG_AUDIT.md) against the LOCAL Supabase stack.

A Warlock 2 / Wizard 3 (standard 4 x 1st, 2 x 2nd; Pact Magic 2 x 1st) and a Wizard 1 on a throwaway user. Covers single,
final-slot and rapid clicks, the maximum, both pools, short and long rest summaries, a response that arrives after a character
switch, Realtime refreshes that must neither revert a confirmed value nor steal focus, a second open session and 390 px.
"""
import json

from playwright.sync_api import sync_playwright

from class_ui_common import Sheet, User, check, report


def counts(page):
    return page.evaluate("""() => {
      const t = document.querySelector('#slot-tracker'); if (!t) return {};
      const o = {};
      t.querySelectorAll('[data-slot-count]').forEach((e) => { o['L' + e.dataset.slotCount] = e.textContent.split(' remaining')[0].trim(); });
      const p = t.querySelector('[data-pact-count]'); if (p) o.pact = p.textContent.split(' remaining')[0].trim();
      return o;
    }""")


def main():
    u = User("slotreg")
    mc = u.character("Slot Regression", [("warlock-phb", 2), ("wizard-phb", 3)], intelligence=16, charisma=16)
    wz = u.character("Slot Regression Wizard", [("wizard-phb", 1)], intelligence=16)

    def server(cid=mc):
        _, s = u.rpc("get_character_spell_slots", p_character=cid)
        o = {f"L{x['slot_level']}": f"{x['remaining']} / {x['max']}" for x in s["standard"]}
        if s.get("pact_magic"):
            o["pact"] = f"{s['pact_magic']['remaining']} / {s['pact_magic']['max']}"
        return o

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=True)
        s = Sheet(browser, u, tab="spells")
        page = s.page
        calls = []
        page.on("request", lambda r: calls.append(r.url.split("/rpc/")[1]) if "/rpc/" in r.url and ("slot" in r.url.split("/rpc/")[1]) and "get_" not in r.url else None)
        s.open(mc)
        s.tab("spells")
        page.wait_for_selector("#slot-tracker [data-slot-pool=standard]", timeout=20000)
        page.wait_for_timeout(2500)                                   # the Realtime channel joins
        tr = page.locator("#slot-tracker")
        status = page.locator("#slot-status")
        btn = lambda action, level=None: tr.locator(f"[data-action={action}]" + (f"[data-level='{level}']" if level else ""))  # noqa: E731
        wait = lambda want: s.wait(lambda: all(counts(page).get(k) == v for k, v in want.items()))  # noqa: E731

        btn("slot-use", 1).click()
        check("SR1 Use spends one 1st-level slot (3 / 4, server agrees) and says so",
              wait({"L1": "3 / 4"}) and server()["L1"] == "3 / 4" and s.wait(lambda: "1st-level slot used. 3 of 4 left." in status.text_content()),
              (counts(page), server(), status.text_content()))
        btn("slot-restore", 1).click()
        check("SR2 Restore gives one back (4 / 4)", wait({"L1": "4 / 4"}) and server()["L1"] == "4 / 4"
              and s.wait(lambda: "restored. 4 of 4 left" in status.text_content()), (counts(page), status.text_content()))

        btn("slot-use", 2).click()
        wait({"L2": "1 / 2"})
        btn("slot-use", 2).click()
        check("SR3 the final 2nd-level slot can be spent; Use is then disabled",
              wait({"L2": "0 / 2"}) and s.wait(lambda: btn("slot-use", 2).is_disabled()), counts(page))
        btn("slot-restore", 2).click()
        wait({"L2": "1 / 2"})
        calls.clear()
        btn("slot-use", 2).dblclick()
        page.wait_for_timeout(1500)
        check("SR4 a double click on the final slot sends one request; 0 / 2, no error toast",
              calls.count("expend_standard_spell_slot") == 1 and counts(page)["L2"] == "0 / 2" and server()["L2"] == "0 / 2"
              and "No level" not in s.toasts(), (calls, counts(page), s.toasts()))

        st, body = u.rpc("restore_standard_spell_slot", p_character=mc, p_slot_level=1)
        check("SR5 Restore at the maximum is disabled and the server refuses it", btn("slot-restore", 1).is_disabled() and st == 400
              and "No expended" in str(body), (st, body))

        btn("pact-use").click()
        check("SR6 a Pact slot is spent from its own pool (1 / 2), standard slots unchanged",
              wait({"pact": "1 / 2", "L1": "4 / 4", "L2": "0 / 2"}) and server()["pact"] == "1 / 2", counts(page))
        btn("pact-restore").click()
        check("SR7 Pact Restore (2 / 2)", wait({"pact": "2 / 2"}) and s.wait(lambda: "Pact Magic slot restored. 2 of 2 left" in status.text_content()),
              status.text_content())
        btn("pact-use").click()
        wait({"pact": "1 / 2"})
        calls.clear()
        btn("pact-use").dblclick()
        page.wait_for_timeout(1500)
        check("SR8 the final Pact slot cannot be double-spent (one request, 0 / 2)",
              calls.count("expend_pact_magic_slot") == 1 and server()["pact"] == "0 / 2" and counts(page)["pact"] == "0 / 2", calls)

        btn("slot-use", 1).click()
        wait({"L1": "3 / 4"})
        btn("short-rest").click()
        page.locator(".modal [data-ok]").last.click()
        page.wait_for_selector(".modal [data-rest-summary]", timeout=15000)
        summ = page.locator(".modal [data-rest-summary]").inner_text()
        check("SR9 Short Rest restores Pact Magic only and its summary says so (Pact Magic: 2 slots; standard slots not restored)",
              "Pact Magic: 2 slots" in summ and "Standard spell slots" in page.locator(".modal [data-rest-not-restored]").inner_text()
              and wait({"pact": "2 / 2", "L1": "3 / 4", "L2": "0 / 2"}), (summ, counts(page)))
        page.locator(".modal [data-rest-ok]").click()
        btn("pact-use").click()
        wait({"pact": "1 / 2"})
        btn("long-rest").click()
        page.locator(".modal [data-ok]").last.click()
        page.wait_for_selector(".modal [data-rest-summary]", timeout=15000)
        summ = page.locator(".modal [data-rest-summary]").inner_text()
        check("SR10 Long Rest restores both pools (4 / 4, 2 / 2, 2 / 2) and lists both",
              "Spell slots: 3 slots" in summ and "Pact Magic: 1 slot" in summ and wait({"L1": "4 / 4", "L2": "2 / 2", "pact": "2 / 2"}),
              (summ, counts(page)))
        page.keyboard.press("Escape")
        page.wait_for_timeout(300)
        check("SR11 the multiclass keeps separate pools: two standard lines, one Pact panel, Pact level shown",
              tr.locator("[data-slot-pool=standard] .slot-line").count() == 2 and tr.locator("[data-slot-pool=pact]").count() == 1
              and "Slot level: 1st" in tr.locator("[data-slot-pool=pact]").inner_text())

        calls.clear()
        btn("slot-use", 1).click(click_count=3, delay=40)
        page.wait_for_timeout(1500)
        check("SR12 a rapid triple click produces exactly one mutation (3 / 4)",
              calls.count("expend_standard_spell_slot") == 1 and server()["L1"] == "3 / 4", (calls, server()))

        # SR13: the answer for the previous character arrives after switching to another one
        held = []
        page.route("**/rest/v1/rpc/expend_standard_spell_slot", lambda route: held.append(route))
        btn("slot-use", 1).click()
        s.wait(lambda: len(held) == 1, 5000)
        page.goto(f"{page.url.split('#')[0]}#/c/{wz}")
        page.wait_for_selector("#slot-tracker [data-slot-pool=standard]", timeout=20000)
        page.wait_for_timeout(800)
        held[0].continue_()
        page.wait_for_timeout(2000)
        page.unroute("**/rest/v1/rpc/expend_standard_spell_slot")
        check("SR13 a late answer for the previous character is ignored (the Wizard 1 still shows 2 / 2, no Pact panel)",
              counts(page) == {"L1": "2 / 2"} and server(wz) == {"L1": "2 / 2"}, counts(page))
        s.open(mc)
        s.tab("spells")
        page.wait_for_selector("#slot-tracker [data-slot-pool=standard]", timeout=20000)
        page.wait_for_timeout(2500)

        seq = []
        page.evaluate("""() => { window.__seq = []; let last = null; window.__iv = setInterval(() => {
            const t = document.querySelector('#slot-tracker [data-slot-count="1"]')?.textContent; if (t !== last) { window.__seq.push(t); last = t; } }, 10); }""")
        for _ in range(2):
            page.evaluate("() => document.querySelector('#slot-tracker [data-action=slot-use][data-level=\"1\"]').click()")
            page.wait_for_timeout(700)
        page.wait_for_timeout(2500)
        seq = [int(x.split(" /")[0]) for x in page.evaluate("() => { clearInterval(window.__iv); return window.__seq; }") if x]
        check("SR14 Realtime refreshes never revert a confirmed value (clicks 700 ms apart count down monotonically)",
              all(b <= a for a, b in zip(seq, seq[1:])) and seq[-1] == int(server()["L1"].split(" /")[0]), seq)

        btn("slot-restore", 1).focus()
        u.rpc("expend_pact_magic_slot", p_character=mc)               # a change from elsewhere arrives over Realtime
        check("SR15 a Realtime refresh does not steal focus (still on Restore 1st level)",
              wait({"pact": "1 / 2"}) and page.evaluate("() => document.activeElement?.dataset?.focusKey") == "slot-restore:1",
              page.evaluate("() => document.activeElement?.outerHTML?.slice(0, 120)"))
        page.keyboard.press("Enter")
        wait({"L1": "1 / 4"})
        check("SR15b Enter on a focused button works and focus stays on it", page.evaluate("() => document.activeElement?.dataset?.focusKey") == "slot-restore:1")

        types = page.evaluate("() => [...document.querySelectorAll('#slot-tracker button[data-action]')].map((b) => b.type)")
        check("SR16 every slot action button (Use, Restore, rests) is type=button (only the Manual adjust form submits)", types and all(t == "button" for t in types), types)

        b2 = Sheet(browser, u, tab="spells")
        b2.open(mc)
        b2.tab("spells")
        b2.page.wait_for_selector("#slot-tracker [data-slot-pool=standard]", timeout=20000)
        b2.page.wait_for_timeout(2500)
        btn("slot-use", 2).click()
        check("SR17 a second open session sees the change (2nd level 1 / 2)",
              wait({"L2": "1 / 2"}) and b2.wait(lambda: counts(b2.page).get("L2") == "1 / 2"), counts(b2.page))
        b2.close()

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        btn("slot-restore", 2).click()
        check("SR18 390 px: Restore works and nothing overflows", wait({"L2": "2 / 2"}) and s.overflow() <= 0, s.overflow())
        check("SR19 no browser errors and only local network traffic", not s.errors and not s.remote, (s.errors[:3], s.remote[:3]))
        s.close()
        browser.close()
    report()


if __name__ == "__main__":
    main()
