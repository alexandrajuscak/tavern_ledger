# Combat Builder permissions

**Authority.** The campaign's membership and DM role decide every action, through `_combat_can_run(campaign)`
(`is_admin() or is_campaign_dm(campaign)`). The feature flag (`COMBAT_BUILDER` in `js/config.js`) only hides the link
and the route. It never grants anything.

**How it is enforced:**

- **Tables.** RLS `SELECT` only, for the campaign DM (`_combat_can_see(encounter)` for child tables). There are no
  INSERT, UPDATE or DELETE grants for `authenticated` or `anon`.
- **Functions.**
  - Every `combat_*` RPC is SECURITY DEFINER with `search_path = public, pg_temp`. It checks the caller first
    (`_combat_auth`, `_combat_participant_auth`) and raises `42501` "Encounter not found, or you are not the DM of its
    campaign", the same answer for an unrelated user and a wrong id.
  - `EXECUTE` is granted to `authenticated` only and revoked from `public` and `anon`.
  - Internal helpers (`_combat_*`) are not executable by clients, except the two RLS helpers.
- **Hidden data.** It lives in rows a player's RLS never returns. Players get exactly one combat read model,
  `get_combat_player_view`, which builds its answer from visible data only. Realtime evaluates the same select policies
  per subscriber, so a player receives no combat change rows at all.
- **Linked HP.** `apply_character_hp` allows the owner, the campaign DM or an admin (`can_access_character`). It then
  applies the campaign's `runtime.hp` governance rule (`_gov_gate`), because a SECURITY DEFINER write skips the
  `characters_governance` trigger.

## Authorization matrix

| Action | Campaign DM | Admin | Player of the campaign | Unrelated user | Anonymous |
|---|---|---|---|---|---|
| See the Combat link / open `#/combat` | yes | yes | no (route goes home) | no | no (sign-in) |
| List, create, edit, duplicate, archive, delete a draft | yes | yes | 42501 | 42501 | no EXECUTE |
| Add / remove / reveal / hide / rename combatants | yes | yes | 42501 | 42501 | no EXECUTE |
| Initiative (enter, roll, sort, reorder), start, next / previous / choose turn, pause, resume, finish | yes | yes | 42501 | 42501 | no EXECUTE |
| Monster HP, effects, concentration, Reaction, Legendary, reminders, Undo | yes | yes | 42501 | 42501 | no EXECUTE |
| Linked character HP through the combat RPC | yes | yes | 42501 | 42501 | no EXECUTE |
| Own character HP through `apply_character_hp` (sheet) | yes (campaign characters) | yes | own characters, governance rules apply | 42501 | no EXECUTE |
| Read combat tables (REST / Realtime) | all rows of the campaign | all | **no rows** | no rows | no grant |
| Full encounter read (`combat_get_encounter`, history, stat blocks, summary) | yes | yes | 42501 | 42501 | no EXECUTE |
| Player-safe read (`get_combat_player_view`) | yes | yes | yes, running encounters only | 42501 | no EXECUTE |
| Monster Library (SRD + this campaign's published homebrew) | yes | yes | 42501 | 42501 | no EXECUTE |
| Catalog tables (`combat_monsters`, `combat_conditions`, `creature_legendary_actions`) | read | read | read (public SRD data) | read | no grant |
| Favorites | own | own | own | own | no |
| Homebrew creature authoring (DM content lifecycle) | yes (`content.create_creature`) | yes | no | no | no |

### What the player-safe read returns and never returns

**Returns:**
- the encounter id, name, status, round, ruleset;
- the current combatant, only if visible;
- visible combatants in order with their Initiative;
- player characters' HP;
- monsters as the disguise name (`player_label`) or the true name once revealed;
- monster HP as a state word (Healthy / Bloodied / Critical / Down) by default, nothing (`none`) or exact numbers
  (`exact`) as the DM chooses (`settings.player_enemy_hp`);
- visible effects with their remaining rounds.

**Never returns:**
- hidden or not-yet-joined combatants, or a hidden current turn;
- the true name behind a disguise;
- exact monster HP (unless the DM chose `exact`);
- DM-only effects, DM notes, participant notes;
- reminders, stat blocks, history;
- prepared (draft) and finished encounters (`not_running`).

## Tests

- **`supabase/tests/combat_builder_tests.sql`:**
  - P1–P9: roles, grants, helper privileges, no write grants;
  - E7–E8: another campaign's DM;
  - H17–H20: sheet RPC as player / unrelated;
  - V1–V10: player-safe view;
  - B16: homebrew of another campaign;
  - X4–X5: what Realtime carries.
- **`supabase/tests/api/combat_api_test.py`** (PostgREST + JWT):
  - AP5–AP10: player reads and writes refused, no direct table writes even for the DM;
  - AP11–AP17: the player-safe view;
  - AP19–AP24: unrelated user and anonymous;
  - AP25: change-log columns.
- **`supabase/tests/browser/combat_builder_ui_test.py`:** N1–N4, the link and the route.
