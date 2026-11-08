# Build and feat usability (2026-11-07)

What a player and a DM see on the Build and Abilities sections after the follow-up
([COMBAT_BUILDER_FOLLOWUP.md](COMBAT_BUILDER_FOLLOWUP.md)). Rules: [FEAT_REMOVAL.md](FEAT_REMOVAL.md),
[ABILITY_SCORE_SOURCE_MODEL.md](ABILITY_SCORE_SOURCE_MODEL.md).

## Feats card (Build)

| Situation | Card | Action |
|---|---|---|
| Feat you chose or your DM gave | source line ("Feat", "Campaign reward (…)", "Approved request") | Choices · Details · Notes · **Remove…** (quiet ghost button at the end of the row, not the dominant control) |
| Same, campaign needs approval | same | **Request removal…** |
| Same, character locked / feats DM-only | same | no Remove; a short note says why |
| Feat from your background | "Granted by your background." + how to change it | **Change background…** (opens the background chooser) |
| Feat from your lineage | "Granted by your lineage." + how to change it | **Change lineage choice…** (opens the lineage dialog) |
| Feat from a class Ability Score Improvement | "Granted by an Ability Score Improvement of your class." + how | **Change choice…** (opens that choice in Class features, focus inside) |

Removable and granted feats differ by text and buttons, not by colour. Every button names its feat for screen readers
("Remove feat Tough", "Change the Ability Score Improvement choice that grants Alert").

### Remove dialog

```
Remove feat: Tough                                   ✕
Tough · Feat
What changes
 • Maximum HP: 48 → 40
 • − Feats: Tough (2014, Feat)
Only what this feat gave is removed … Current HP is never raised; it is lowered only if it is above the new maximum.
This is permanent. You can add the feat again later and make its choices again.
                                   [Cancel] [Remove feat]
```

The consequences are computed by the server (the removal simulated and rolled back), so a spell or proficiency another source
grants is shown as staying. Under approval governance the text explains the request and the button reads **Request removal**;
when the campaign refuses (lock, DM only) the reason replaces the list and there is no confirm button. Success: toast "Feat
removed: Tough." and the card, derived values, spellbook and resources refresh. Already removed elsewhere: "This feat is no
longer on the character. The sheet shows the current feats." Failure: the message in the dialog, nothing removed.

Layouts checked at 1366, 820, 390 × 844 and 360 × 800: no clipping, no horizontal page scroll, the dialog's buttons stay inside
the viewport above the bottom navigation.

## Ability cards (Abilities)

```
 STRENGTH
   +3
  BASE
 [ 15 ]          ← the number you rolled / bought (editable)
 Score 17        ← from the server; "Score updating…" while an edit saves
 +1 Lineage: Ability Score Increase
 +1 Fighter: ASI
 Bonuses from sources: +2
```

No "= value" equations. A source capped at 20 says so ("+2 Lineage (+1 applied: max 20)"). In Wild Shape the physical cards show
the form's score with "From form" and "Wolf form · character base score 10"; the mental cards say "Retained from character".

## Friendly messages

| Case | Message |
|---|---|
| Source-granted feat | the card's "Granted by …" line (no Remove offered) |
| Approval needed | dialog callout + "Ask your DM" |
| Locked | "Feats are locked for this character: your DM can unlock or change them." / the lock message from the server |
| Changed in another session | "This feat is no longer on the character. The sheet shows the current feats." |
| Choice change raced a removal | "This feat is not granted to this character" |
| Server unreachable / timeout / conflict | the standard friendly texts of `friendlyError` ("Could not reach the server. Nothing was changed …") |
| Ability base edit refused (governance) | the "Ask your DM" dialog; the input returns to the stored base on reload |

No message contains SQL, constraint, function or enum names, or token text (`feat_removal_tests.sql` F31).
