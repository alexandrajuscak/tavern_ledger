# V6.2 import / export safety

Character files (`.json`, Bio → "Download character file") and their import (home → "Import file"). Verified by
`v62_import_session_soak_test.py` (IMP0–IMP7).

## What an import trusts

Nothing in the file is trusted.

- `parseCharacterJson` builds a new row from known fields only. Unknown keys are ignored, including `id`, `owner_id`,
  `campaign_id`, `created_at`, `__proto__` and `constructor`.
- The **owner** is the signed-in user, or the owner chosen in the dialog by an admin or DM. The **campaign** is the one
  chosen in the dialog, never the one in the file.
- Numbers are clamped: level 1–20, ability scores 1–30, HP max ≥ 1, current HP 0..max, temp HP ≥ 0, coins ≥ 0, hit dice
  0..level, spell levels 0–9, slots 0–9.
- **(new)** The portrait accepts `http(s):` and `data:image/` only. `javascript:`, `file:` and relative URLs are dropped. An
  external image URL is still allowed: it is the same choice as the "Image URL" field on Bio, and the browser loads it.
- Catalog references (lineage, background, classes, spells, feats, creatures) go through the same server functions as the
  app. Their rules, campaign permissions and validation apply. An unknown or forbidden version is never guessed: it is kept
  as legacy text or as a pending choice, with a warning.
- The database is the last line: RLS (the importer must be allowed to create the character), CHECK constraints (including
  the new `hp_current >= 0` and non-negative coins), and the RPC validation.

## Atomicity

| Phase | Behaviour |
|---|---|
| Core rows: character, trackers, attacks, features, spells, slots, notes, inventory | **All-or-nothing (new).** If any of them fails, the new character is deleted again (its child rows cascade). The toast says "Import failed: … Nothing was imported." If even the delete fails, the toast says a partial character may remain. |
| Enrichment: lineage, background, classes, spellcasting sources, catalog spells, resources, slot usage, class features, feats, Wild Shape, companions | Best effort, one by one. Anything that cannot be restored is reported (warnings, pending choices, unresolved spells kept as free text) and never silently dropped. The character is usable either way. |

A single server transaction for the whole import would need an import RPC covering about 15 domains. That is a new engine
and out of scope for V6.2 (see V6_KNOWN_LIMITATIONS.md).

## Checks (browser, local)

| Id | Scenario | Expected |
|---|---|---|
| IMP0 | export a character with classes and inventory | a file with name, classes and inventory |
| IMP1 | broken JSON, an array, no name, an empty file | refused in the preview with a message; Import stays disabled |
| IMP2 | double-click on Import | exactly one character |
| IMP3 | forged `id`, `owner_id` (the DM's), `campaign_id` | new id, owned by the importer, no campaign |
| IMP4 | level 99, STR 999, DEX -5, CON "abc", gp -500, pp 1e12, HP max -4 / current 9999 / temp -3, `javascript:` portrait | clamped; the portrait is dropped |
| IMP5 | `__proto__` / `constructor.prototype` keys | no prototype pollution |
| IMP6 | export → import round trip | same level, scores, HP, classes and inventory |
| IMP7 | the attacks insert fails half-way (network abort) | no character left behind; "Nothing was imported" |

## Export

The player's export contains only what the player can read through RLS: the sheet, the inventory with the player-visible
item names, and so on. Hidden DM data (curses, DM notes, hidden conditions, the true name of an unidentified item) is in the
**DM backup** only. That backup is refused to players (SEC5 / SEC6 in the authorization matrix).
