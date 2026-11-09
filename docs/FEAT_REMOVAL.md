# Feat removal

Migration `20261107000100_feat_removal.sql` (rollback `supabase/rollback/rollback_feat_removal.sql`), frontend `js/feat-ui.js`,
`js/feat-api.js`, `js/sheet.js`, `js/store.js`. Tests: `supabase/tests/feat_removal_tests.sql`,
`supabase/tests/feat_removal_concurrency_test.sh`, `supabase/tests/browser/feat_removal_ui_test.py`.

## The reported defect and its root cause

"A feat assigned to a character cannot be removed." Reproduced locally (2026-11-07):

| Feat source | Before | Root cause |
|---|---|---|
| Directly assigned (player, DM, campaign reward, approved request, import) | **Removable** (Remove → confirmation → removed). Under approval governance the "Ask your DM" dialog opened and the DM's approval removed it | – (worked) |
| Chosen in a class **Ability Score Improvement** | Card showed only **Details**: no Remove, no explanation, no way to the choice | the feat is not a `character_feats` row; it is the value `feat:<id>` of the ASI choice. The card offered nothing |
| Granted by a **background** (2024 origin feat) | Only Details | same: a `background_feat_grants` row of the chosen background |
| Chosen through a **lineage** (Variant Human, Custom Lineage) | Only Details | same: a `character_lineage_choices` value |

So the user-visible defect was the source-granted case. The audit also found real backend problems in the removal function:

1. `remove_character_feat` ran the governance gate **before** the access check: an unrelated signed-in user who held a feat
   row id got "Feats needs your DM's approval in <campaign name>", which revealed the campaign name.
2. A repeated / concurrent removal returned the raw `P0002 Feat not found` (HTTP 500), and two concurrent calls both passed
   the existence check: the second deleted nothing but wrote a **second `feat_removed` audit event**.
3. The feat's own resources (free casts) were only **deactivated**, keyed to a row that no longer exists: orphans that can
   never become active again.
4. `set_character_feat_choices` looked the grant up **before** taking the character lock: a choice change that raced a
   removal stored choice rows for a feat that no longer existed (12 orphan rows in 15 concurrent rounds).
5. **Realtime:** `character_feats` / `character_feat_choices` had no `character_revisions` trigger and the legacy subscription
   did not include them, so an open sheet (either read path) and the Combat Builder never learned that a feat was added,
   removed or re-chosen in another session unless a side table (spells, resources) changed too.
6. A refused save (governance) reloaded the sheet while an input still had focus; its `change` event then reached the closed
   sheet (`Cannot read properties of null (reading 'character')`). Guarded in `onInput` / `onChange`.

## Source-aware rules

| Source (`get_character_feats` → `source_type`) | Removable here? | What the card offers |
|---|---|---|
| `direct`, `dm_grant`, `campaign_reward`, `approved_request`, `import` (a `character_feats` row, `character_feat_id` set) | Yes, through the review dialog | **Remove…** (or **Request removal…** under approval governance; a note instead of a button when locked / DM-only) |
| `class` (ASI choice value) | No | "Granted by an Ability Score Improvement of your class. To change it, change that choice in Class features." + **Change choice…** (opens that ASI choice in Class features and moves focus into it) |
| `background` | No | "Granted by your background. To change it, choose another background or change its feat choice." + **Change background…** |
| `lineage` | No | "Granted by your lineage. To change it, change the lineage or its feat choice." + **Change lineage choice…** |

A source-granted feat cannot reach `remove_character_feat` at all: it has no `character_feats` row, and the function only
deletes rows of that table. No new override policy was invented: the existing governance model's DM path is "the DM removes
it" (the campaign DM is always allowed; a change request applied by the DM carries the player's note and the DM's reason
into the audit event).

## Governance and locks

`remove_character_feat` uses the existing action `choice.feat` (`_gov_gate`):

| Decision for the caller | Result | UI |
|---|---|---|
| allow / player managed (no campaign, relaxed, the DM) | removed now | Remove… → **Remove feat** |
| approval required (standard) | `TLAPR`; the request flow (`change_request_ops` op `remove_character_feat`, label "Remove a feat") | Request removal… → the dialog explains → **Request removal** → the campaign's "Ask your DM" dialog |
| DM only / disabled | `TLDMO` / `TLDIS` | no button; "Only your DM can remove feats in this campaign." |
| build / progression / full lock, archived | `TLLCK` | no button; "Feats are locked for this character: your DM can unlock or change them." |

The labels come from the sheet's governance state (`featRemovalPolicy()`); the server decides again on every call.

## The authoritative operation

`remove_character_feat(p_character_feat uuid, p_reason text default null)` (same signature as before), one transaction:

1. signed in, else `42501`;
2. the row exists **and** the caller can access its character, else `P0002` with hint `feat_absent` and the message "This feat
   is no longer on the character. The sheet shows the current feats." (the same answer for unknown, already removed and
   inaccessible rows: nothing about another character or campaign is revealed);
3. governance gate `choice.feat`;
4. lock order: the **character row** (`for update`), then the feat row again (`for update`): of concurrent removals exactly
   one removes, the others get `feat_absent` and write nothing;
5. delete the feat's choice rows (`grant_key = 'cf:<id>'`) and the feat row;
6. `_sync_character_feats`: removes the feat's spellcasting source and spells (a spell another source grants stays under that
   source), deactivates its resources and applies the maximum-HP policy;
7. delete the feat's own resource rows (`source_id = 'cf:<id>'`);
8. one `feat_removed` audit event in a campaign (with the reason; the change request id when applied from a request);
9. return `get_character_feats`.

Stale-state protection is the row identity: the dialog removes one specific `character_feats` row; if it changed (removed in
another session) the call answers `feat_absent` and the sheet refreshes. Idempotency: a repeated request never fails with a
raw error, never removes anything else and never writes a second audit event.

`preview_character_feat_removal(p_character_feat uuid)` (new, read-only, same authorization) returns the feat, its source, the
caller's decision (`allow` / `approval_required` / `refused`), `ok` + `message`, and `diff`: the removal executed inside the
governance simulator (`_cr_simulate`, the engine of the DM's request review) and rolled back. The diff therefore comes from the
same rules as the real removal (maximum HP, Initiative, ability scores, AC, speed, spells per source, resources, skill
proficiencies, open choices, the feat list).

## Dependent mechanics

| Mechanic | On removal of a directly assigned feat |
|---|---|
| Choices | its `character_feat_choices` rows deleted |
| Spell grants (Magic Initiate …) | its spellcasting source and spells deleted; the same spell from a class, background or another feat stays |
| Free uses / resources | deleted (were left inactive before) |
| Ability-score bonus | derived on every read from the remaining feats: gone with the row; the base score and other sources unchanged |
| Proficiencies, expertise, resistances, speed, AC, attacks, initiative | derived from the remaining rows: gone; another source's grant stays |
| Maximum HP (Tough …) | recalculated; **current HP is never raised**; current HP above the new maximum is lowered to it (existing policy of `_sync_character_feats`) |
| Inventory | a feat grants no items in the current catalog; nothing to remove |
| Build Next Steps / open choices | recomputed from the remaining grants |
| Read cache / Realtime | `tl_cache_rev` (cache counter) and the new `character_feats_revision` / `character_feat_choices_revision` triggers; open sheets reload feats, derived stats, spellbook and class resources (`scheduleFeatsChanged`), the legacy path through its own subscription, the Combat Builder its linked numbers |

A feat's **saving-throw proficiency** (Resilient) was listed as automated but not applied; **fixed 2026-11-09**
(`20261109000100`, `docs/FEAT_SYSTEM_AUDIT.md` D2): it is applied while the feat is held and removed with it (test F17b).

## The review dialog

Remove… opens "Remove feat: <name>": the feat and its source, **What changes** (the server diff: "Maximum HP: 48 → 40",
"Removed: Spells: …"), what stays, whether it is permanent, and **Remove feat** (or **Request removal** with the approval
explanation). A refused preview (lock, DM only) shows the reason and no confirm button. Keyboard: Enter on Remove… opens it,
focus starts on the confirm button, Tab is trapped, Escape cancels and focus returns to Remove…. A double click applies once.
A failed removal shows the message in the dialog (`role="alert"`) and leaves the feat and all its mechanics intact.

## Export / import

`export_character_feats` lists the current rows: a removed feat is absent. `import_character_feats` assigns what the file
contains through the governed `assign_character_feat`; an export taken after the removal never recreates it.

## Tests

| Suite | Result (2026-11-07) |
|---|---|
| `feat_removal_tests.sql` (Supabase local) | 60 / 0 |
| `feat_removal_concurrency_test.sh` (3 sessions × 15 rounds; removal vs choice change vs read) | 9 / 0 |
| `browser/feat_removal_ui_test.py` | 56 / 0 |

## Re-validation in the combined release (2026-11-07 evening)

No code change to feat removal. Re-run on the current tree: `feat_removal_tests.sql` 60 / 0, `feat_removal_concurrency_test.sh`
9 / 0, the browser suite inside the full runner (see COMBAT_BUILDER_FOLLOWUP.md section 14), and the lock-order test
(`lock_order_concurrency_test.sh`: feat assign / remove in parallel with slot spends, HP, coins, equipment and cold cache reads
on the same character: 0 deadlocks, no unexpected error). The migration is item 3 of the combined production plan.
