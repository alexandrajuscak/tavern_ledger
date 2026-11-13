# Crafting v1

Players turn ingredients from their inventory into items, following recipes the DM writes. The player rolls at the table and
types the total; the DM confirms or corrects it. The server never rolls dice.

Migration `20261113000100_crafting_v1.sql`, rollback `supabase/rollback/rollback_crafting_v1.sql`. Frontend `js/crafting.js`.
Earlier design notes: [POTION_AND_HERBAL_CRAFTING_DESIGN.md](POTION_AND_HERBAL_CRAFTING_DESIGN.md).

## Two off-switches (both off as shipped)

| Switch | Values | Shipped | Effect |
|---|---|---|---|
| `CRAFTING` in `js/config.js` | `'off'` / `'dm'` / `'on'` | `'off'` | `'off'`: no crafting UI anywhere, `js/crafting.js` is never loaded and no crafting RPC is called. Campaign rules does not list the Crafting rule. `'dm'`: DM Space shows **Crafting** (and Campaign rules lists the rule), so a DM can prepare recipes. `'on'`: the player's Inventory also shows **Crafting**. |
| Governance action `inventory.craft` ("Crafting") | per campaign | `disabled` in every preset | Every player RPC refuses with `TLDIS` ("Crafting is turned off in …"). `max_player = player_managed`, `can_request = false` (approval is per recipe, never a change request). |

The DM recipe RPCs check only the campaign DM role. They do **not** require the action to be enabled, so a DM can prepare
recipes while players are still off. The player panel appears only when the flag is `'on'`, the viewer owns the character, and
the character's governance decision for `inventory.craft` is `player_managed`.

### Turning it on for one campaign (later, with the user's OK)

1. Frontend: set `CRAFTING = 'dm'` (or `'on'`) in `js/config.js`, bump the asset marker, and deploy.
2. In DM Space, open **Campaign rules → Inventory → Crafting**, choose "Player managed" and save. This is one override, and the
   preset becomes "custom". Choosing a named preset again later resets it to `disabled`.
3. DM Space → **Crafting**: create the recipes and publish them.

To turn it off again, set the rule back to "Disabled" (players are refused at once) or set the flag to `'off'`.

## Model

| Table | What | Who reads it |
|---|---|---|
| `crafting_recipes` | campaign, name, player description, `dm_notes`, status `draft` / `published` / `archived`, visibility `known` / `discoverable` / `secret`, result (`output_item_id`, quantity, `output_label` for characters who do not know the item, `output_identified`), critical-success result and bonus quantity, `failure_mode` (`keep`, `lose_all`, `lose_half`) and junk result, `check_key` (skill or tool), `check_dc`, `requires_dm_approval` (default true), `time_note`, `revision` | DM only (through RPCs) |
| `crafting_recipe_ingredients` | per line: an exact item **or** an ingredient tag (`items.details.ingredient_tags`), an optional player label, quantity, consumed (false = a tool) | DM only |
| `character_known_recipes` | recipe discovery per character (`seen_at` null = "New recipe learned!") | via RPC |
| `crafting_attempts` | character, recipe (+ revision), selection `[{seq, inventory_item_id, quantity}]`, `roll_total`, `natural_roll` (nat20 / nat1, typed), `dm_roll_total`, status, outcome, `consumed` / `produced`, `dm_reply` (the player sees it), `dm_private_note` (DM only), `apply_error`, `request_id` | via RPC |

Constraints: a DC needs a check (`check_dc is null or check_key is not null`), and only a recipe without a DC may skip the DM
(`requires_dm_approval or check_dc is null`). Recipes reference items with no action, which blocks a direct item delete. All four
tables have RLS on, with no grants to `anon` / `authenticated`: there is no direct read or write.

## State machine

```
start ──(no DC and requires_dm_approval = false)──▶ applied        (consume + produce in the same transaction)
start ──▶ pending ──DM approve (outcome, corrected roll)──▶ applied | apply_failed ──DM approve again──▶ applied
                  ──DM reject──▶ rejected          (nothing changes)        apply_failed ──DM reject──▶ rejected
                  ──player cancel──▶ cancelled
```

- **Outcome.** The DM chooses `success`, `failure`, `critical_success` or `critical_failure`. Left empty, the roll decides: the
  corrected roll, or else the player's, against the DC, and success when there is no DC.
- **Consumption.** Success and critical success use up every consumed ingredient. A failure applies the recipe's
  `failure_mode`, or the DM's choice at approval. A critical failure loses everything. A failure produces the junk result if the
  recipe has one. A critical success produces the alternative result (or the normal one) plus the bonus quantity.
- **No reservation.** A pending attempt reserves nothing. At approval, `_craft_apply` locks the attempt row, then the selected
  inventory rows in id order. The character row is not locked here, because examine locks the row and then the character. It
  re-checks every row against the **current** recipe: still in the character's inventory, enough quantity, known, fitting, and
  not equipped, attuned, a quest item or a container with contents. On any problem the savepoint rolls back every partial write
  and the attempt becomes `apply_failed`. The reason is a fixed text with no item names.
- **Exactly once.** The attempt row is locked `FOR UPDATE`, only `pending` / `apply_failed` can be answered (`55000` otherwise),
  and an optional expected revision is checked (`40001`). Two DMs approving at once, or an approve racing a cancel: the second
  waits and is refused (`crafting_concurrency_test.sh`). A character who left the recipe's campaign is no longer listed in
  that DM's queue, and that DM can no longer answer its attempts (`55000`; the player can still cancel).
- **Idempotent starts.** `start_craft_attempt` is idempotent on `(character, request_id)`: a repeat, also a concurrent one,
  replays the first attempt. There is one pending attempt per character and recipe (a unique index; a concurrent second one gets
  `55000`). No character row lock is taken: the auto path locks inventory rows, and examine locks a row and then the character.

## Audit

Inventory changes use the existing `inventory_events` actions `remove` and `add` with
`metadata = {craft_attempt, recipe, outcome, ...}`. The CHECK constraint is unchanged. The attempt keeps `consumed` / `produced`.
`campaign_audit_events` (`item_crafted`) gets a party line for the character's owner, using the names the player sees, and a DM
line with the roll, the DC and the details. Recipe status changes and grants are audited too (`recipe_changed` DM-only,
`recipe_learned` for the player).

## Knowledge (T4 / T4b link)

- **Only fully known rows count as ingredients for a player** (`_craft_row_known`): the row has no `inventory_item_knowledge`
  row, or an `identified` one. This is the exact predicate with which `v_inventory_detail` and `use_inventory_item` mask an
  instance. It is per row, so a holder of a plain copy and a disguised copy has one usable copy.
- **The player read never says whether an unidentified row matches.** `get_character_recipes` is computed from known rows only
  and contains nothing else that depends on the inventory. It is byte-identical with a disguised matching herb and without it
  (CR9).
- **One fixed refusal.** `start_craft_attempt` checks the knowledge of every selected row before any fit or quantity check. It
  refuses with one fixed message, "You don't know what this ingredient is yet" (`22023`), whether the row would fit or not.
- **Secret items are never named to a player who does not know them.** An exact ingredient shows the DM's label (or "An unknown
  ingredient"), never its name or id. Whether a character knows an item uses the T4b overview's "effective" level
  (`_craft_item_known`): an undisguised copy, else the lowest disguised copy, else not secret, else the record. A result unknown
  to the character shows `output_label`, or else the decoy. The DC, `dm_notes`, `dm_private_note`, the critical result and the
  failure result never reach a player.
- **Produced items arrive like a DM assignment** (`_craft_produce`, `_dm_add_item` semantics without its governance gate):
  - `output_identified = true` (default): the crafter made it, so they know it. Plain rows are added. For a secret item the
    character knew only partly, `_identify_apply('{all}')` runs first, so their other copies follow.
  - `false`: the row is INSERTED already disguised (decoy name and description, plus a knowledge row and the character's
    record), so the Realtime INSERT never carries the true name. The result items become `secret` when the DM publishes the
    recipe (a DM action, never a player's first craft). This is refused at save time for official items, because it would flip
    `items.secret` on a shared row.
- The DM sees everything, including selected rows that are no longer known (they are marked "unidentified").

## RPCs

| RPC | Who | Notes |
|---|---|---|
| `get_character_recipes(character)` | owner (TLDIS while off), DM | Visible recipes: published, the character's campaign, `known` or learned. For each: what the character has and is missing, candidate stacks, check label, whether the DM confirms. Plus the last 20 attempts and the number of `discoverable` recipes still to find. |
| `start_craft_attempt(character, recipe, selected, roll_total, request_id, natural, note)` | owner | See above. A roll is required when the recipe has a check. |
| `cancel_craft_attempt(attempt)` | owner | Only while pending. Owner check only, without the campaign rule: a player can always take back their own pending attempt. |
| `mark_recipes_seen(character)` | owner | Clears "new". |
| `dm_save_recipe(campaign, recipe, expected_revision)` | DM | Insert or update (draft / published). Ingredients are replaced as a set. Items must be official or of this campaign and not archived. An archived recipe must be restored first. |
| `dm_set_recipe_status(recipe, status)` | DM | `draft` / `published` / `archived`. Archived keeps attempts, and pending ones can still be answered. |
| `dm_grant_recipe(recipe, characters, grant)` | DM | Discovery: grant or take back. |
| `dm_resolve_craft_attempt(attempt, approve/reject, outcome, dm_roll, reply, private_note, failure_consumes, expected_revision)` | DM | Approving an `apply_failed` attempt is the retry. |
| `get_campaign_recipes(campaign)` / `get_campaign_craft_attempts(campaign, 'open'/'closed'/status)` / `get_campaign_pending_craft_count(campaign)` / `get_campaign_craft_items(campaign, query)` | DM | Editor, queue, history, badge, item picker. |

Internal helpers (`_craft_*`) are not executable by `authenticated`.

## Cache, Realtime, live refresh

- `crafting_recipes` / `crafting_recipe_ingredients` use `tl_cache.skip()`. No read in the `get_character_reads` cacheable list
  touches them, so a DM's recipe edit never invalidates any cache.
- `crafting_attempts` / `character_known_recipes` use `tl_cache.bump('character')` (the coverage rule).
- None of the four tables is in the Realtime publication. Every attempt change, answer and grant writes one `character_revisions`
  row with the source `inventory_items` (`_identify_touch`). Every frontend already handles that source: the open Inventory
  re-reads, and the Crafting panel re-reads with it. A new source table would break older open sheets.
- The DM's queue badge refreshes when DM Space re-reads (navigation, or its realtime events on requests and characters), not
  on each new attempt.

## Which items recipes may use (trusted items)

A recipe may name only official items, DM Content, or campaign items authored by a DM of the campaign (`_craft_item_trusted`; the
editor's picker lists only those). An item authored by a player, such as a legacy row or the JSON import's homebrew, is refused (`22023`). A
tag ingredient matches only trusted items too, so a player cannot forge an ingredient by tagging their own item.

## Deleting items used by recipes

`_item_dependencies` has a blocking key `crafting_recipes`, which counts every recipe of any status that names the item: the
result, the critical or failure result, or an ingredient. `preview_item_deletion` lists the recipes by name ("used in crafting
recipe “X”"). `_dm_content_dependencies` adds the key in its item branch. `get_dm_content_usage_detail` lists a
`crafting_recipe` place. Delete therefore answers `TLUSE` instead of a raw foreign-key error. Recipe names are DM data: they are
named only to the DM of the recipe's campaign or an admin. Anybody else, for example the player who authored the item, gets the
fixed reason "used by your DM's crafting" and a count of at most 1. The delete stays blocked.

These four functions were replaced with the same signatures; the rollback restores their exact previous bodies.

## Tests

- `supabase/tests/classes/crafting_tests.sql` (29 checks, CR1–CR25). It covers the governance off-switch (the DM still
  manages recipes), auto craft with its events, the DC / approval constraint, pending → approve with an edited roll, reject,
  failure rules and the junk result, critical success, `apply_failed`, idempotency, the revision guard, the knowledge rule
  (byte-identical read, one fixed refusal), the secret result label, a disguised result, discovery, refusals, hidden data
  (tables and RPC output), the deletion report, and cache / Realtime / grants.
- `supabase/tests/crafting_concurrency_test.sh`: two DMs approve at once; approve versus cancel.
- `supabase/tests/browser/crafting_ui_test.py` (18 checks):
  - with the shipped `'off'`: no UI and no request;
  - with `'on'` (config served through a route, as in `auth_reset_ui_test.py`): the DM turns the rule on, creates and
    publishes a recipe, the player crafts with a typed roll, the DM approves with an edited roll, and the inventory changes
    live;
  - the REQUIRED leak check: the player's REST / RPC bodies, websocket frames, DOM and storage never hold the DC, the DM notes
    or the secret ingredient's true name.

## Locks

`_craft_produce` takes the character's rows of the result and its knowledge record `NOWAIT`. If the player is examining that item
at that moment, the approval becomes `apply_failed` (all partial writes rolled back) and the DM tries again. It never deadlocks
with examine (row, then character, then record, then rows). The migration sets `lock_timeout = 5s` for the CLI connection (reset at
the end); the rollback sets it for its `psql -1` transaction.

## Known limits (v1)

- Read cost: `get_character_recipes` checks every inventory row against every ingredient line through per-row functions. That is
  about 0.4 s locally for 30 recipes × 5 tag lines × 300 rows, and the read runs again on every inventory change while the panel
  is open. A set-based prefilter is planned before crafting is turned on for players; the knowledge rule must stay exactly the
  same.

- One stack per ingredient line in the player dialog. The server accepts several, but the dialog offers only stacks large
  enough on their own. `have` may count a stack that also fits another line.
- Recipes cannot be deleted, only archived (they reference items).
- A recipe edited after an attempt is checked against its current ingredients at approval. An attempt that no longer fits
  becomes `apply_failed`, and the DM can reject it.
- Choosing a named preset in Campaign rules resets the Crafting override to `disabled`, like every other override.
- An old cached `?v=27` DM page lists the Crafting rule in Campaign rules (generic renderer). A DM could turn it on there; players
  still have no UI, and every RPC stays governed.
- The raw `inventory_events.item_id` of a disguised result is readable by its holder. This is the documented T4 residual, and
  herbs and DM content have opaque ids.
- Ideas not in v1 (experimenting with unknown herbs, quality tiers, journal, harvesting, downtime, shared workshop) are parked
  for a later decision.
