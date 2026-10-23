# DM Space

The DM's campaign workspace, separate from the character sheets: route `#/dm/<section>[/<id>]` (`js/dm-space.js`, data in
`js/dm-api.js`, editors in `js/content-editors.js`, styles appended to `css/styles.css`). The header shows a **DM Space**
link only to users who are a DM of at least one campaign (or admins); a player opening `#/dm` is sent back to the
character list. **Every read and write is checked again by the database** – the UI never grants a right.

Read models: `get_my_dm_campaigns()` (campaigns the user DMs, with preset and pending count),
`get_dm_overview(campaign)` (counts, pending requests, recent content and activity, character ids),
`get_dm_party(campaign, characters)` (one row per character; called in parallel batches of 5 because one row costs about
0.2 s and a PostgREST request is capped at 8 s), migration `20261019000600_dm_read_models.sql`.

## Sections

| Section | What the DM does there |
|---|---|
| **Overview** | Urgent work first: pending approvals, failed applies, warnings from the party (0 HP and death saves, low HP, open choices, characters still in initial setup), active Wild Shape forms, recent content and activity. A campaign selector switches between the DM's campaigns (remembered per browser). |
| **Approvals** | The request inbox with filters (Pending, Failed, Returned, Approved, Rejected, Cancelled, All; character; kind). Opening a request shows the player's reason and note, the structured before → after diff, the operations, warnings, a stale warning (approve disabled until refreshed), and the actions approve / edit and approve / return / reject, with a public note and a private DM note. Deep link `#/dm/approvals/<request id>`. |
| **Party** | A card per character: HP bar, AC, conditions (hidden ones marked 👁), lock and setup state, Wild Shape form, companions, open choices. Per character: lock / unlock (with reason), mark setup complete, add a condition (visible or hidden), add a secret note, open the sheet. |
| **Content** | The custom content library: filter by type and status, search, usage counts, "New …" for every type. The editor validates, previews the player card, publishes, creates new versions, archives, restores, duplicates, deletes unused drafts and jumps to Assign ([CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md)). |
| **Assign** | A wizard: published content → characters → mode (spell: known / spellbook / always prepared / innate; item: inventory or party stash, identified or not; feat: DM grant or reward; creature: Wild Shape grant or companion; companion; background; lineage; condition: visible or hidden) → per-character results. |
| **Hidden** | Per character: secret notes (reveal, delete), conditions with DM notes and timers (reveal, remove), item knowledge (identify, partially identify, reveal facts) ([HIDDEN_DM_DATA.md](HIDDEN_DM_DATA.md)), and the DM-only campaign backup download. |
| **Campaign rules** | Preset (Relaxed / Standard / Strict / Custom) with a plain-language description, the decision of every action grouped by category (only decisions the action allows are offered), unmet prerequisites, approval notes, edit and approve, and the content policy ([DM_GOVERNANCE.md](DM_GOVERNANCE.md), [CAMPAIGN_CONTENT_POLICY.md](CAMPAIGN_CONTENT_POLICY.md)). Saving uses the revision (two DMs cannot overwrite each other silently). |
| **Audit log** | Campaign events (requests, approvals, level and feat changes, spells learned, items assigned, content, hidden effects, locks, rule changes, overrides, reveals) filtered by character and event type; DM-only events are visible to DMs only. |

Realtime: the space subscribes to `change_requests` and `characters` of the campaign and refreshes Overview, Approvals and
Party (debounced, never while a dialog is open), and the Approvals counter.

## Player side

The sheet mounts `js/request-ui.js` (`#gov-bar` under the header): lock and initial-setup banners, the **pending changes
tray** (draft request with its operations, send / discard), the **Ask your DM** dialog that opens automatically when a
change is refused with `TLAPR` (from any RPC or autosave, via the `tavern:governance` event of `js/supabase.js`), the list
of the character's requests with status chips and DM notes, and live updates. `TLDMO` / `TLDIS` / `TLLCK` show a friendly
toast with the campaign's name.

## Accessibility and layout

Sections are a labelled navigation of tabs (`aria-selected`; on phones a section select replaces the tab row); the panel is
an `aria-live` region; dialogs trap focus and return it on close (Escape closes); every
control has a name (checked by `dm_space_ui_test.py` DS41); no horizontal overflow at 390 px (DS42); at ≤ 480 px the
header link shows only its icon. The visual identity of the sheet is unchanged; the DM Space reuses its cards, chips and
buttons.

## Tests

`supabase/tests/browser/dm_space_ui_test.py` (50 checks with a DM and a player in two browser contexts: link visibility,
campaign selector, overview, spell editor end to end, unidentified item, feat picker and request, return / resubmit /
approve, HP with the feat, stale request, custom feat / Wild Shape form / companion, lock, no homebrew button for players,
keyboard, accessible names, 390 px layout, console and network locality).
