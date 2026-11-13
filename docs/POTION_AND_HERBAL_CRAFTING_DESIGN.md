# Potion and herbal crafting: future design

**Crafting v1 is implemented (behind flags, off by default): see [CRAFTING_V1.md](CRAFTING_V1.md).** The phases below are the
original design notes; v1 covers phases 1 to 3 except tool proficiency checks and crafting time (a note only).

This release only prepares the data: Herbs & Plants as a kind, potion metadata, and on **every** item optional
`details.ingredient_tags`, `details.recipe_refs`, `details.preparation` (and `details.ingredients` on potions). No crafting
table, time advancement, check, ingredient consumption, harvesting or production exists. No empty speculative table was added.

## Future entities

| Entity | Fields |
|---|---|
| `crafting_recipes` (versioned like DM content) | id, name, output item version, output quantity, ruleset, campaign, status / version, source, DM notes, tool requirement, proficiency requirement, minimum level, time, cost, check ability / DC |
| `crafting_recipe_ingredients` | recipe, exact item version **or** accepted category **or** accepted ingredient tag, quantity, consumed / reusable, optional substitutions |
| `crafting_attempts` | character, recipe, selected inventory entries, started / completed, outcome, consumed entries, produced entries, audit |

`details.recipe_refs` (free text today) becomes a link to recipe ids; `ingredient_tags` match `accepted tag` rows.

## Phases

1. **Recipes as DM content** (draft → publish → version), read-only "Known recipes" on the sheet; matches ingredients by
   item version, category or tag and shows what is missing. No mutation.
2. **Attempt with DM approval**: the player selects inventory entries; one atomic server function locks the inventory,
   checks quantities, consumes ingredients, adds the output, writes the audit; duplicate request ids applied once.
3. **Checks and time**: tool proficiency, ability check against the DC (server roll or typed result), crafting time as a
   downtime note; failure outcomes (ingredients lost / kept) per recipe.
4. **Harvesting** (optional): environment / region tables using the herb metadata; DM-controlled, never random by default.

Rules content needs a licensed source before any official recipe or herb is added; homebrew only until then.
