# Character locks and initial setup

A DM can freeze parts of a character between sessions or after a campaign ends. Table `character_governance`
(`lock_mode`, `lock_reason`, `locked_by`, `locked_at`, `setup_complete`), migration `20261019000100_campaign_governance.sql`.
Locks only apply to characters in a campaign; the decision logic is in [DM_GOVERNANCE.md](DM_GOVERNANCE.md).

## Modes

Every governed action has a **lock class** (`governance_actions.lock_class`). `_gov_lock_blocks(mode, class)` decides:

| Mode | Blocks (lock classes) | Typical use |
|---|---|---|
| `unlocked` | nothing | normal play |
| `progression_locked` | `progression` (class, level, subclass, lineage, background, feats, ASI, class feature choices) | between sessions: no level-ups, play continues |
| `build_locked` | `progression`, `build` (abilities, max HP, manual values, proficiencies, spells learned, companions, seen forms), `inventory_acquire` (adding, transferring, deleting items) | a finished build; HP, resources, equipping and rests still work |
| `fully_locked` | everything the player could change, including runtime (HP, resources, rests, Wild Shape) and identity | the DM takes the character over |
| `archived` | everything, for everyone except the lock itself; the character is read-only | the campaign ended |

The lock is checked on the server for the player (`TLLCK`, with the reason in the message). The DM is not blocked by a lock
in direct actions, but **an approved request is applied under the lock that is in force at that moment**: a request
approved while the character is locked fails safely (`apply_failed`) until the DM unlocks it or rejects the request.
`disabled` actions stay `disabled` (`TLDIS`) whatever the lock.

`set_character_lock(character, mode, reason)` (DM of the character's campaign, or admin; an archived character can be
restored by the DM) locks the character row first
(`for update`), so a lock and a concurrent approval are serialized; it is audited in `campaign_audit_events`.

## Initial setup

A character that joins a campaign may need a whole build (class, background, lineage, spells, equipment). Until the DM
marks the setup complete (`set_character_setup_complete(character, true)`), every `approval_required` action of the
`build` and `progression` lock classes is **player-managed** for that character. Runtime and inventory rules apply from the
start. Characters that were already in a campaign before the migration were marked `setup_complete`.

## In the UI

The sheet shows a banner under the header (`#gov-bar`, `js/request-ui.js`): the lock with its reason ("Your DM paused
progression" plus the DM's reason), or the initial-setup note ("build your character freely; once your DM marks the setup
complete, permanent changes go through requests"). Refused writes show a
friendly toast and, when the action can be requested, the **Ask your DM** dialog. In the DM Space the Party section has a
lock control per character and the setup toggle.

## Tests

`governance_tests.sql` (G16–G17 setup, G20–G26 locks, A24–A25 lock during apply), `governance_concurrency_test.sh` (lock vs.
approval), `dm_space_ui_test.py` (DS37, DS39).
