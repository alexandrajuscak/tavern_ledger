# V6.2 authorization matrix

Measured, not assumed. `v62_adversarial_api_test.py` (AUTH1, AUTH2) calls the real local PostgREST / RPC endpoints as six
actors. It records every cell to `$MATRIX_OUT` as JSON (72 cells) and fails if a "must" cell differs. The campaign uses the
**standard** governance preset.

Actors:
- **anonymous**: the anon key with no session.
- **owner**: the player who owns the character.
- **campaign player**: another player in the same campaign.
- **campaign DM**: the campaign's DM.
- **unrelated user**: a player in another campaign.
- **unrelated DM**: the DM of another campaign.

| Target | Action | anonymous | owner | campaign player | campaign DM | unrelated user | unrelated DM |
|---|---|---|---|---|---|---|---|
| campaign character | read character | refused | allowed | refused ¹ | allowed | refused | refused |
| campaign character | edit runtime (current HP) | refused | allowed | refused | allowed | refused | refused |
| campaign character | edit permanent (max HP) | refused | refused ² | refused | allowed | refused | refused |
| campaign character | propose a change (change request) | refused | allowed | refused | allowed ³ | refused | refused |
| campaign character | lock / unlock | refused | refused | refused | allowed | refused | refused |
| hidden DM data | read (DM notes, curse, hidden condition) | refused | refused | refused | allowed | refused | refused |
| hidden DM data | reveal (identify, reveal a property) | refused | refused | refused | allowed | refused | refused |
| campaign catalog | create / publish custom content | refused | refused | refused | allowed | refused | refused |
| campaign catalog | assign content to a character | refused | refused | refused | allowed | refused | refused |
| campaign catalog | archive content | refused | refused | refused | allowed | refused | refused |
| campaign | read audit log | refused (401) | own characters' events | own characters' events ⁴ | all events | refused ("Campaign not found") | refused ("Campaign not found") |
| unrelated character | read character | refused | refused | refused | refused | allowed (owner / their DM) | allowed (owner / their DM) |

1. A policy choice: players of a campaign do not read each other's sheets through the API. A "party view" is not part of the
   product.
2. Under the **standard** preset the player proposes permanent changes and the DM approves them. Under **relaxed** the owner
   edits directly. Each preset is covered by `governance_tests.sql` (60 checks).
3. A DM may also open a change request. This is accepted: the request goes through the same review and audit path.
4. The RPC answers 200 with only the events of the caller's own characters. That player has none, so the list is empty.
   Party-visible events of other characters are not shown. Item events of an item the player has not identified yet are
   not shown either (ADV-BLOCKER-001).

## Hidden-data sweep (SEC1–SEC7)

The DM creates and assigns an unidentified item with a curse, a DM note on the content, a hidden DM note on the character
and a hidden condition, each with a unique marker string. The owner and a second campaign player then read **every**
PostgREST table and view they can see (159 readable), plus the sheet read models (derived stats, conditions, change
requests, governance, campaign audit, feats, spellbook). No marker may appear.

- Before V6.2 the item's true name leaked through `campaign_audit_events` and `get_campaign_audit`.
- After the fix, nothing leaks before a reveal.
- After identification only the true name is visible. The curse, the DM notes and the hidden condition stay hidden.
- The DM backup export is refused to the player and contains the hidden data for the DM.
- SEC7 checks the existing demo data read-only, inside a rolled-back transaction, as the demo player: no event of a
  still-unidentified item is readable.

## How to read the raw matrix

```bash
MATRIX_OUT=/somewhere/matrix.json python supabase/tests/browser/v62_adversarial_api_test.py
```

Each entry holds `actor`, `target`, `action`, `status`, `allowed`, `expect` ("allow" / "deny" / "either" = documented policy
choice) and `detail` (the refusal message).
