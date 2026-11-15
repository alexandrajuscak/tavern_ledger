// Weapon card icons (docs/DERIVED_CHARACTER_STATS.md "Weapon cards"). Pure: no imports, no DOM, no network, so the node /
// browser unit test (supabase/tests/js/weapon_icons.test.mjs) can load it. Only icons already in the repo (registry keys of
// js/icon-registry.js); the repo has no per-weapon art, so several weapons share the closest picture.
//
// Resolution (weaponIconKey):
//   0. the DM's uploaded icon (custom_icon) is not decided here: weapon-card.js passes it as <img src> for a known copy only;
//   1. the item's own gallery key (items.icon_key, set in the homebrew / content editor), known copy only;
//   2. WEAPON_ICON_MAP by the catalog item id (official base weapons), then by its words for the official magic weapons
//      (dagger-of-venom -> dagger, sword-of-vengeance -> sword, bloodrage-greataxe -> greataxe): base_item_id is in no payload;
//   3. the category: firearm group -> ranged -> melee by damage type;
//   4. the generic weapon icon.
// SECRECY: steps 1-3 run only for a copy the viewer knows: the derived read sends item_id = null for a masked (unidentified /
// partly identified) copy, and the masked inventory view says known === false. The derived row of a masked copy still carries
// the true weapon_group / damage_type / is_ranged, so even the category step would leak the true weapon: a masked copy gets
// only the icon of its decoy face (info.icon from the masked inventory row) or the generic icon. The name is never used.

export const GENERIC_WEAPON_ICON = 'item.weapons';

// item.weapon-* are registry aliases (scripts/local/build_icon_registry.py) so the same keys are gallery choices that pass the
// items_icon_key_check (item|potion|plant|inventory|slot prefixes) for a homebrew weapon.
const SWORD = 'item.weapon-sword';       // equipment-slots/main-hand: a sword
const KNIFE = 'item.weapon-dagger';      // equipment-slots/off-hand: a dagger
const BLADE = 'item.weapon-axe';         // damage-types/slashing: a broad cleaving blade (axes, polearm blades, whip, sickle)
const POINT = 'item.weapon-spear';       // damage-types/piercing: a spear head
const ARROWS = 'item.weapon-bow';        // items/ammunition: arrows (bows, crossbows, darts, sling, blowgun)
const GUN = 'item.firearm';              // items/firearm: a flintlock pistol
const HAMMER = GENERIC_WEAPON_ICON;      // items/weapons: a war hammer (same picture as damage-types/bludgeoning)

/** Base weapon (catalog item id) -> icon registry key. Official weapons of supabase/seed/reference_data.sql weapon_stats. */
export const WEAPON_ICON_MAP = Object.freeze({
  // swords
  longsword: SWORD, shortsword: SWORD, greatsword: SWORD, rapier: SWORD, scimitar: SWORD, 'double-bladed-scimitar': SWORD,
  // knives
  dagger: KNIFE,
  // cleaving blades
  handaxe: BLADE, battleaxe: BLADE, greataxe: BLADE, glaive: BLADE, halberd: BLADE, sickle: BLADE, whip: BLADE,
  // points
  spear: POINT, javelin: POINT, pike: POINT, lance: POINT, trident: POINT, yklwa: POINT, 'war-pick': POINT, morningstar: POINT,
  // hammers and clubs
  club: HAMMER, greatclub: HAMMER, mace: HAMMER, maul: HAMMER, warhammer: HAMMER, 'light-hammer': HAMMER, flail: HAMMER, quarterstaff: HAMMER,
  // bows, crossbows, thrown missiles
  longbow: ARROWS, shortbow: ARROWS, 'light-crossbow': ARROWS, 'hand-crossbow': ARROWS, 'heavy-crossbow': ARROWS, dart: ARROWS,
  sling: ARROWS, blowgun: ARROWS, hoopak: ARROWS,
  // firearms
  'palm-pistol': GUN, pistol: GUN, musket: GUN, pepperbox: GUN, blunderbuss: GUN, 'bad-news': GUN, 'hand-mortar': GUN,
});

/** Words of official magic weapon ids that are not a base weapon id themselves. */
const WEAPON_WORD_ICON = Object.freeze({ sword: SWORD, blade: SWORD, axe: BLADE, bow: ARROWS, hammer: HAMMER, staff: HAMMER });

/** The icon of a catalog item id: the exact base weapon, else the first base weapon / weapon word in its id, else null. */
export function weaponIdIcon(id) {
  if (!id) return null;
  if (WEAPON_ICON_MAP[id]) return WEAPON_ICON_MAP[id];
  const t = String(id).split('-');
  for (let i = 0; i < t.length; i += 1) {
    const hit = WEAPON_ICON_MAP[`${t[i]}-${t[i + 1]}`] || WEAPON_ICON_MAP[t[i]] || WEAPON_WORD_ICON[t[i]];
    if (hit) return hit;
  }
  return null;
}

/** Melee fallback by damage type (homebrew weapons have no base id in any payload the sheet has). */
export const WEAPON_DAMAGE_ICON = Object.freeze({ slashing: SWORD, piercing: POINT, bludgeoning: HAMMER });

/** Category icon of a KNOWN weapon (derived row): firearm group, then ranged, then melee by damage type, then generic. */
export function weaponCategoryIcon(w) {
  if (!w) return GENERIC_WEAPON_ICON;
  if (w.weapon_group === 'firearm') return GUN;
  if (w.is_ranged) return ARROWS;
  return WEAPON_DAMAGE_ICON[w.damage_type] || GENERIC_WEAPON_ICON;
}

/** True when the card may describe the real item: the server did not mask the copy and the masked inventory view agrees. */
export const weaponIsKnown = (w, info) => !!w && w.item_id != null && info?.known !== false;

/**
 * The registry key for a weapon card. w: an element of derived.equipped_weapon_attacks. info: the viewer's masked view of the
 * inventory row (js/inventory-ui.js weaponInfo: { known, icon, iconKey, ... }) or null.
 */
export function weaponIconKey(w, info) {
  if (!weaponIsKnown(w, info)) return info?.icon || GENERIC_WEAPON_ICON;   // the decoy face only
  return info?.iconKey || weaponIdIcon(w.item_id) || weaponCategoryIcon(w);
}
