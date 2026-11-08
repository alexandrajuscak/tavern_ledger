# Artificer infusions (2026-11-07)

Stored class version: **Artificer (Tasha's Cauldron of Everything, `artificer-tce`)**, feature **Infuse Item**
(`artificer-infuse-item-tce`, level 2, choice "Infusions known"). Engine: migration `20261017000900_infusions_and_attunement`
(unchanged by this release). The catalog has 16 infusions (Arcane Propulsion Armor, Armor of Magical Strength, Boots of the
Winding Path, Enhanced Arcane Focus, Enhanced Defense, Enhanced Weapon, Helm of Awareness, Homunculus Servant, Mind Sharpener,
Radiant Weapon, Repeating Shot, Replicate Magic Item, Repulsion Shield, Resistant Armor, Returning Weapon, Spell-Refueling
Ring), each with its item rules, modifiers by Artificer level and attunement flag.

| Rule | Where it comes from |
|---|---|
| Infusions known / maximum infused items | class level table (`get_character_infusions.choices[0].known`, `max_items`, `active_count`) |
| Eligible items, refusal reasons | `candidates[].refusal` (wrong kind, already infused, …) |
| Level requirements, replicable magic items | catalog option data / Replicate Magic Item tables |
| Effects | managed item modifiers (+1 / +2 attack and damage, AC); shown in the character's numbers |
| Charges, reactions, teleports, spell refuel | reminders (not automated) |

## Presentation

| Place | What is shown |
|---|---|
| Build | Infused items card: known / active counts and limits, each infusion with its item, attunement state, "End infusion", "Update infusions" after a level change, "Infuse an item…" (existing) |
| Inventory | badge **"Infused: Enhanced Weapon"** on the target item (title: Artificer Infusion, attunement state); the raw modifier id badge is hidden for that item |
| Play | **Infused items** section: name, "Artificer Infusion · on Mace", attunement, the infusion's effect text; a note that numeric bonuses are already in the attack / AC values and that charges and special uses are reminders |
| Spells | nothing: no infusion grants a spell entry, so no duplicate spell source is created |

The option data carries `activation: item` (migration `20261107000400`), which keeps infusions out of the action groups.

## Reconciliation

No stored infusion, choice or item changes. Existing local and production infusions keep working and simply appear in the new
places.

## Known limitation found (not changed)

A character whose item holds an active infusion cannot be deleted directly (the managed-modifier guard refuses the cascaded
delete): end the infusion on Build first. Documented in `V6_KNOWN_LIMITATIONS.md`.
