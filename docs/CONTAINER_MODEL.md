# Container model (MVP)

## Data

`container_stats` (one row per container item), filled from the source pages by the data pipeline:

| Column | Meaning |
|---|---|
| `capacity_weight_lb` | weight limit, null if the source gives none (liquids, "20 arrows") |
| `capacity_volume_cuft` | volume limit (`1/5 cubic foot` → 0.2) |
| `weightless_contents` | contents do not count toward carried weight (Bag of Holding) |
| `extradimensional` | Bag of Holding & co.; nesting two of them is flagged |
| `max_nested_depth` | optional per-container limit (1–8); null = global limit |
| `capacity_note` | original capacity text from the source |

Seeded: 16 gear containers (Backpack 30 lb / 1 cu ft, Pouch 6 lb / 0.2 cu ft, Sack 30 lb / 1 cu ft, Chest 300 lb / 12 cu ft,
Barrel 4 cu ft solid, Quiver "20 arrows" …) and the Bag of Holding (500 lb, 64 cu ft, weightless, extradimensional; its own
weight of 15 lb is taken from its page). Other extradimensional items (Handy Haversack, Portable Hole) have no data yet.

## Decisions

| Question | MVP decision |
|---|---|
| Over capacity | **reported, not blocked**: `v_container_contents.over_capacity` (normal containers and Bag of Holding alike) |
| Bag of Holding inside another extradimensional container | **flagged** (`extradimensional_nesting`), no automatic game consequence |
| Self-containment / cycles | **blocked** (CHECK + trigger) |
| Nesting depth | **blocked above 8 levels** (or a container's own `max_nested_depth`); also checked when a container with contents is moved |
| Same inventory | a container must be in the same inventory as its contents |

## Weight

`v_inventory_weight.total_weight_lb` per inventory:

- normal container: the container **and** its contents count;
- `weightless_contents` container: only the container counts (contents at any depth below it are excluded);
- mounts and vehicles never count; vehicle cargo lives in its own inventory (`owned_assets.cargo_inventory_id`), so it is never part of a character's weight;
- catalog rows use `items.weight_lb`, free-text rows their own `weight`.

`v_container_contents` (per container): `items_inside`, `contents_weight_lb` (a weightless container nested inside counts only
itself), `capacity_*`, `over_capacity`, `extradimensional_nesting`. `v_owned_assets_detail` reports cargo weight against a
mount's carrying capacity or a vehicle's cargo capacity (`cargo_over_capacity`).

## Tests

L1 over capacity is reported · L2 Bag of Holding contents excluded, the bag counts 15 lb · L3 bag load/capacity ·
L4 container inside a weightless container · L5 extradimensional nesting flagged · L6 8 levels allowed, a 9th rejected ·
L7 moving a container with contents cannot exceed the limit · B16–B18 same inventory, no self-containment, no cycles.
