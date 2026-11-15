// Unit tests of the weapon card icon resolution (js/weapon-icons.js, docs/DERIVED_CHARACTER_STATS.md "Weapon cards").
// Pure functions, no network, no DOM.
// Run with node:            node supabase/tests/js/weapon_icons.test.mjs
// Run in a browser (the T7 smoke does): import('/supabase/tests/js/weapon_icons.test.mjs').then((m) => m.run())
import { weaponIconKey, weaponIdIcon, weaponIsKnown, weaponCategoryIcon, WEAPON_ICON_MAP, GENERIC_WEAPON_ICON } from '../../../js/weapon-icons.js';

// the weapon keys of js/item-icon-gallery.js (that module imports utils/icons, so the list is repeated here)
const KNOWN_GALLERY = ['item.weapons', 'item.weapon-sword', 'item.weapon-dagger', 'item.weapon-axe', 'item.weapon-spear', 'item.weapon-bow', 'item.firearm'];
const DB_KEY = /^(item|potion|plant|inventory|slot)\.[a-z0-9]+(-[a-z0-9]+)*$/;   // items_icon_key_check

const longbow = { inventory_item_id: 'i1', item_id: 'longbow', weapon_group: 'martial', is_ranged: true, damage_type: 'piercing' };
const known = { known: true, icon: 'inventory.weapon', iconKey: null };

// [label, actual, expected]
export const cases = () => [
  ['known longsword -> sword', weaponIconKey({ item_id: 'longsword', damage_type: 'slashing' }, known), 'item.weapon-sword'],
  ['known dagger -> dagger', weaponIconKey({ item_id: 'dagger', damage_type: 'piercing' }, known), 'item.weapon-dagger'],
  ['known longbow -> arrows', weaponIconKey(longbow, known), 'item.weapon-bow'],
  ['known musket -> firearm', weaponIconKey({ item_id: 'musket', weapon_group: 'firearm', is_ranged: true }, known), 'item.firearm'],
  ['homebrew weapon with the dagger gallery key shows the dagger', weaponIconKey({ item_id: 'hb-x', damage_type: 'slashing' }, { ...known, iconKey: 'item.weapon-dagger' }), 'item.weapon-dagger'],
  ['decoy ignores the dagger gallery key', weaponIconKey({ item_id: null, damage_type: 'slashing' }, { known: false, icon: 'item.gear', iconKey: 'item.weapon-dagger' }), 'item.gear'],
  ['every map icon is a gallery choice (DB-valid key)', Object.values(WEAPON_ICON_MAP).every((k) => KNOWN_GALLERY.includes(k)), true],
  ['author gallery key beats the map', weaponIconKey(longbow, { ...known, iconKey: 'item.wand' }), 'item.wand'],
  ['homebrew (no map entry) firearm group', weaponIconKey({ item_id: 'x-1', weapon_group: 'firearm', is_ranged: true }, known), 'item.firearm'],
  ['homebrew ranged', weaponIconKey({ item_id: 'x-2', is_ranged: true, damage_type: 'piercing' }, known), 'item.weapon-bow'],
  ['homebrew melee slashing', weaponIconKey({ item_id: 'x-3', damage_type: 'slashing' }, known), 'item.weapon-sword'],
  ['homebrew melee piercing', weaponIconKey({ item_id: 'x-4', damage_type: 'piercing' }, known), 'item.weapon-spear'],
  ['homebrew melee fire -> generic', weaponIconKey({ item_id: 'x-5', damage_type: 'fire' }, known), GENERIC_WEAPON_ICON],
  ['official magic dagger by its id words', weaponIdIcon('dagger-of-venom'), 'item.weapon-dagger'],
  ['official magic sword by a weapon word', weaponIdIcon('sword-of-vengeance'), 'item.weapon-sword'],
  ['two-word base inside an id', weaponIdIcon('hand-crossbow-plus-one'), 'item.weapon-bow'],
  ['magic greataxe', weaponIconKey({ item_id: 'bloodrage-greataxe', damage_type: 'slashing' }, known), 'item.weapon-axe'],
  ['homebrew uuid id does not match words', weaponIdIcon('hb-8c5ab05e-1aa2-4828-a6e2-c12b8628db2b'), null],
  ['decoy: id words never used for a masked copy', weaponIconKey({ item_id: null, damage_type: 'piercing' }, { known: false, icon: 'item.gear' }), 'item.gear'],
  ['known, inventory not loaded (info null) still maps', weaponIconKey({ item_id: 'longsword' }, null), 'item.weapon-sword'],
  // SECRECY: a masked copy. The derived row keeps the true stats (longbow) but item_id is null; the masked view says known:false.
  ['decoy: masked longbow shows the decoy face icon', weaponIconKey({ ...longbow, item_id: null }, { known: false, icon: 'item.gear', iconKey: null }), 'item.gear'],
  ['decoy: never the true weapon icon', weaponIconKey({ ...longbow, item_id: null }, { known: false, icon: 'item.gear' }) !== 'item.weapon-bow', true],
  ['decoy: a stale gallery key is ignored', weaponIconKey({ ...longbow, item_id: null }, { known: false, icon: 'inventory.weapon', iconKey: 'item.wand' }), 'inventory.weapon'],
  ['decoy: known:false wins even if item_id leaked', weaponIconKey(longbow, { known: false, icon: 'item.gear' }), 'item.gear'],
  ['decoy, inventory not loaded (known:null, item_id null) -> generic', weaponIconKey({ ...longbow, item_id: null }, { known: null, name: 'Old stick' }), GENERIC_WEAPON_ICON],
  ['decoy, no info at all -> generic', weaponIconKey({ ...longbow, item_id: null }, null), GENERIC_WEAPON_ICON],
  ['weaponIsKnown masked', weaponIsKnown({ item_id: null }, { known: true }), false],
  ['category of nothing', weaponCategoryIcon(null), GENERIC_WEAPON_ICON],
  ['every map value passes items_icon_key_check', Object.values(WEAPON_ICON_MAP).every((k) => DB_KEY.test(k)), true],
];

export function run() {
  const fails = cases().filter(([, a, e]) => a !== e).map(([l, a, e]) => `${l}: got ${a}, expected ${e}`);
  return { total: cases().length, fails };
}

if (typeof process !== 'undefined' && process.argv?.[1]?.endsWith('weapon_icons.test.mjs')) {
  const r = run();
  r.fails.forEach((f) => console.error('FAIL', f));
  console.log(`${r.total - r.fails.length}/${r.total} passed`);
  if (r.fails.length) process.exit(1);
}
