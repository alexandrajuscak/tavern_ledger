# Campaign content policy

Which rules content a campaign uses: rulesets, legacy, playtest, setting books, custom content and excluded source books.
Columns of `campaign_governance` (migration `20261019000100_campaign_governance.sql`), edited by the DM in
**DM Space → Campaign Rules** or with `set_campaign_governance(campaign, {"content": {...}})`.

| Setting | Column | Default (new campaign) | Pre-existing campaigns |
|---|---|---|---|
| Rulesets used | `content_rulesets` (`{2014,2024}`) | both | both |
| Legacy content (pre-2024 versions superseded by a 2024 one) | `content_allow_legacy` | allowed | allowed |
| Playtest / Unearthed Arcana (also third-party and unverified feat versions) | `content_allow_playtest` | **not allowed** | allowed (nothing changes for them) |
| Setting-specific content (Eberron, Ravenloft, …) | `content_allow_setting` | allowed | allowed |
| Custom campaign content | `content_allow_custom` | allowed | allowed |
| Excluded source books | `content_excluded_sources` | none | none |

## Enforcement

`_content_policy_reason(campaign, ruleset, legacy, playtest, setting, custom, source_book)` returns the first reason a piece
of content is not allowed (or null). `_gov_content_check(character, reason)` turns a reason into the error
`TLDIS` ("… is not allowed in this campaign. Ask your DM."). The check runs in the gates of:

* classes and subclasses (`_gov_gate_class`), lineages (`_gov_gate_lineage`), backgrounds (`_gov_gate_background`),
* spells (`_gov_gate_spell`), items (`_gov_gate_add_item`),
* feats (`assign_character_feat`; the feat catalog marks every version with `policy_reason` so the picker can say why).

**The DM of the campaign and admins are never blocked** by the content policy: a DM can still grant a playtest feat or a
setting item as an exception. Characters outside a campaign are not affected. A campaign without a governance row (not
configured) allows everything, exactly like before.

The policy is about **choosing** content. Content a character already has is not removed when the DM tightens the policy;
it stays on the character until the DM removes it.

## Custom content

`content_allow_custom = false` marks the campaign's custom content as not allowed in players' pickers and refuses new picks
by players (for example adding a campaign custom item); DM grants still work. Authoring custom content is always DM-only (`content.*` actions), see
[CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md).

## Tests

`governance_tests.sql` G16b (a playtest feat is refused for the player with `TLDIS` and carries a `policy_reason` in the
feat catalog; an official feat does not), `governance_api_test.py` GA29 (custom content turned off: a player can no longer
add the campaign's custom item).
