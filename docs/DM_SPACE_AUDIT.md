# DM Space audit (task start, 2026-10-19)

## Navigation today

- Routes (`js/app.js`): `#/` character list grouped by campaign, `#/c/<id>` character sheet, `#/campaigns` (admin only:
  create campaigns, manage members).
- Character sheet tabs (`js/sheet.js`): Combat, Stats, Spells, Inventory, Features, Resources, Notes, Bio.
- DM signals: a `DM` / `ADMIN` badge in the top bar; campaign headers on the list show "DM" for the user's campaigns.

## Current DM-specific UI

None besides the badge and admin campaign management. A DM reaches a player character through the list, and sees the
same sheet as the owner. There is no party view, no approvals, no content library.

## Player-facing mechanical creation (to relocate)

| Where | What | Action in this task |
|---|---|---|
| Inventory > Add item > "+ Create homebrew item" | full item definition (kind, stats, effects, container) | removed from the player UI; DM Space > Content Library > Item |
| Inventory > item > "Edit homebrew definition" | edits the shared definition | DM only; players see a read-only definition |
| Inventory > legacy item > "Convert to homebrew…" | creates a definition | DM only; players may still link a legacy item to an existing catalog item |
| Spells > "+ New spellcasting source…" | manual source | governed (`spell.change_source`); not content creation |

## Reusable UI pieces

- `openModal` (focus trap, Escape, focus restore), `toast`, `esc`, `$`/`$$` (`js/utils.js`).
- Spell card, school badges, effect tags (`js/spell-ui.js`, SPELL_VISUAL_SYSTEM.md tokens).
- Item detail / badges (`js/inventory-ui.js`), creature card (`js/creature-ui.js`), Wild Shape picker.
- `homebrew-form.js` item editor (moved into the DM item editor).

## Gaps

- No DM workspace or campaign selector.
- No way to see pending work (approvals, incomplete choices) across characters.
- No Draft / Published / Archived lifecycle for any content except item archive.
- No preview of a definition in the card the player will see.
- No assignment flow (content -> characters) with preview.
- No audit timeline.

## Decisions

- New route `#/dm` (and `#/dm/<section>`), visible in the top bar only to campaign DMs and admins; ordinary players
  never get the link, and every DM read model refuses non-DMs server side.
- Sections: Overview, Approvals, Party, Content, Assign, Hidden, Rules, Audit. A section switcher (tabs on desktop, a
  select on narrow screens).
- Last selected campaign and section are remembered in `localStorage` (convenience only).
- Distinct look: darker panel, amber DM accent, Draft / Published / Archived chips, typed content icons; the existing
  fonts, tokens and components are kept.
