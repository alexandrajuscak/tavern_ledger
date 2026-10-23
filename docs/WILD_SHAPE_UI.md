# Wild Shape UI

The Wild Shape UI is in `js/wild-shape-ui.js`, with wiring in `js/sheet.js`, API calls in `js/creature-api.js` and styles under
`.ws-*` in `css/styles.css`.

Every number on screen comes from `get_character_transformation` (the authoritative transformed sheet) or from the
derived stats. The UI sends player decisions only: which form, which slot, an amount, an optional own roll. Rules are
in [WILD_SHAPE_RULES.md](WILD_SHAPE_RULES.md).

## Where it appears

| Place | Idle | Transformed |
|---|---|---|
| Combat tab (`#combat-transform`) | idle panel | the **full form mode** (a temporary playable sheet) |
| Features tab (`#class-transform`) | idle panel | a compact summary, with "Open the Wild Shape sheet (Combat tab)" |
| Sheet header HP card | — | a note: form HP, and that Damage / Heal apply to the form. Normal HP is shown as protected |
| Header speed tile | — | "Form: walk 40 ft · climb 30" |
| Stats tab ability notes | — | "Brown Bear form (your score 10)" for STR / DEX / CON |
| Saves and skills everywhere | — | the server's `form_total` |

## Idle panel

The idle panel shows:
- uses (`2 / 2` or Unlimited);
- the Druid level, with an explanation when the character level differs (multiclass);
- the maximum beast CR and the Circle of the Moon tag;
- swimming and flying, either ✓ or 🔒 "from Druid N";
- Elemental Wild Shape;
- the seen-forms rule and the number of usable forms;
- **Choose a form…**;
- quick buttons for favorite forms.

With no uses left, the button is disabled with "a short or long rest restores them".

## Form picker

- **Search:** by name or trait. It is always visible, including on mobile.
- **Filters and sort**, folded on screens under 600 px:
  - status: can take now / seen / favorites / all, including locked forms with their reasons;
  - max CR, size, movement, sense, damage type, multiattack;
  - sort by CR, HP, AC or recently used.
- **Groups:** favorites first, a "Recently used" line, then the beast and elemental groups.
- **Card:** CR, size, HP, AC, speeds, senses, the main attack, traits, status (icon + text), reasons, cost.
  - Actions: ☆ favorite (`aria-pressed`), Compare, Mark seen, Transform….
  - Locked forms show the reason, and their Transform button is disabled.
- **Compare (2–4 forms):** a table with differing rows highlighted and marked "(differs)" for screen readers. No
  ranking, by design. Escape closes only the comparison.

## Transformation review

Before any change, the review shows:
- the cost and remaining uses;
- the duration;
- "your normal HP stays as it is";
- a warning for an unseen form or a DM-granted exception;
- the equipment mode (merge / drop / wear) with an optional per-item choice.

Cancel changes nothing.

## Active form mode

**Header:**
- kicker (Wild Shape or Elemental Wild Shape) and name;
- CR / size / type / source / license;
- duration (started, ends by) and uses left;
- **Revert to normal form**, which confirms what returns and says that no use is spent.

**Live region** `#ws-status`: announces each result. The same text goes to a toast.

**HP block:**
- a meter, with the state in text (Healthy / Wounded / ⚠ Critical);
- form temporary HP;
- normal HP, "protected while transformed";
- amount, **Damage**, **Heal**, **Adjust…** (reason required). On mobile these controls are sticky at the bottom.

**Lethal damage:** a confirmation first, with the incoming damage, the remaining form HP, "Wild Shape will end" and the
exact carry-over (normal HP before → after).

**Combat Wild Shape (Moon):**
- slot radios with no default;
- an optional Pact slot;
- an optional own roll;
- a preview "1d8 (1–8)";
- the toast names the roll.

**Cards:**
- **Defense:** AC, alternatives, saves with their source (form / yours / gained).
- **Movement and senses**.
- **Actions:**
  - Multiattack is expandable.
  - Each attack shows the hit, reach or range, targets, damage, DC, summary and condition chips.
  - Limited abilities have Use / Roll recharge (d6) / Restore buttons.
- **Abilities:** "Form" / "Kept" labels, with the full source for screen readers.
- **Skills:** notable skills, plus "All skills".
- **Traits:** grouped as combat / movement / senses / defense / utility.
- **Spells and concentration**, with End concentration.
- **Equipment**, with a Merge / Wear toggle per item.
- **Retained features**, and the recent history.

## Behavior and accessibility

**Concurrency:**
- One request per control at a time (`tfBusy`).
- A read that overlaps a change never overwrites it (`tfEpoch`).
- Late answers for another character are ignored.
- The focus key is kept across re-renders.

**Realtime:** `character_transformations` changes re-read the state on other open pages.

**Accessibility:**
- Meaning is always in text, not color alone.
- Buttons have labels.
- Dialogs trap focus.
- Escape closes only the top modal.
- Reduced motion is respected.

**Layout:** at most two card columns on desktop, one on mobile. No horizontal overflow at 390 px; this is tested.

**Read-only viewers** (a DM in a read-only sheet) see the same sheet without controls.

## Export and import (`js/transfer.js`)

**Export** writes `wildShape`:
- seen forms with their source;
- favorites;
- settings;
- a reference copy of the active form.

**Import:**
- restores seen forms (a DM grant becomes "seen" with a note), favorites and settings;
- never restores `unrestricted`;
- skips unknown creatures;
- **never restores an active form.** The character comes back in normal form, the console warns, and uses come from the
  exported resource state. Form HP and statistics are never trusted from a file.

## Redesign of 2026-10-22

- While transformed, the **vitals HP card shows the form first**: "Wild Shape · Brown Bear" with the form HP in large
  numbers, then "Normal form 45 / 45" in smaller type, and the note "Damage and Heal apply to the form. Your normal hit
  points are protected until you revert." The card takes the nature tint.
- The header shows a **Wild Shape: <form>** chip that opens the form sheet on Play. The top-bar readout (shown after
  scrolling) shows the form HP.
- The home card of a transformed character shows the same chip.
- The panel itself (picker, review, active form sheet, Revert) is unchanged. It lives on Play (combat place) and on
  Build → Class features (class place).
