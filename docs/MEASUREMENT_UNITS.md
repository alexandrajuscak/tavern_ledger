# Measurement units (US / Metric display)

Owner decision (phase 2, R-A): the DM plays with US measures as in the rules; each player may switch their own screen to Metric.

- **Where:** character sheet → Bio → **Display** → "US (feet, pounds)" / "Metric (meters, kilograms)". Default US. The choice is
  per viewer and device (`localStorage` key `tavern-ledger:units`; if storage is blocked the choice lasts for the page). It
  applies at once, on every page of the app (sheet, inventory, spells, Play, combat views, DM Space), on the fluent and the
  `?fluent=0` path.
- **Display only.** Stored data, RPC payloads, Realtime, exports and everything the DM enters stay in US units. Number fields
  (item weight, base speed, creature speeds, spell range distance) keep accepting US values; under Metric they say
  "US units".
- **Convention** (official metric D&D): 5 ft = 1.5 m (1 ft = 0.3 m: 30 ft = 9 m, 60 ft = 18 m, 120 ft = 36 m), 1 mile = 1.5 km,
  1 lb = 0.5 kg, 1 inch = 2.5 cm. Gallons and pints stay as they are. At most two decimals.
- **One conversion:** `js/units.js` `metricText(text)` converts free text: "60 feet", "30 ft.", "5-foot", "10-foot-radius",
  "1,000 feet", "150/600 ft", "(range 20/60)", "1 mile", "6 inches", "5 lb.", "3 pounds". It never touches dice ("1d10"), DCs,
  levels, CR fractions, money, "square feet" / "cubic feet" (not linear), or numbers without a unit.
  `fmtDistance(ft)`, `distanceNumber(ft)`, `fmtWeight(lb)` serve places that print a stored number.
- **How the screen follows:** with Metric on, a display layer (`startUnitsDisplay`, started in `js/app.js`) shows every visible
  text node converted and keeps its original; text the app writes later is converted as it appears; switching back restores the
  originals. Inputs, text areas, selects, editable areas, code and `[data-units-skip]` are never touched; attributes (tooltips,
  placeholders) stay US. With US nothing observes the page. Numbers printed apart from their unit (the Speed tile, Walking
  speed, the turn guide) use `distanceNumber` / `distanceUnit` and refresh on the switch.
- Tests: `supabase/tests/js/units.test.mjs` (60 text cases incl. negatives + helpers; `node supabase/tests/js/units.test.mjs`, or
  in the browser), `supabase/tests/browser/ra_release_ui_test.py` (switch, speed / weight / spell range and back).
