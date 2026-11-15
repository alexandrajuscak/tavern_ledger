// Unit tests of the weapon card icon resolution (js/weapon-icons.js, docs/DERIVED_CHARACTER_STATS.md "Weapon cards").
// Pure functions, no network, no DOM.
// Run with node:            node supabase/tests/js/weapon_icons.test.mjs
// Run in a browser (the T7 smoke does): import('/supabase/tests/js/weapon_icons.test.mjs').then((m) => m.run())
import { weaponIconKey, weaponIsKnown, weaponCategoryIcon, WEAPON_ICON_MAP, GENERIC_WEAPON_ICON } from '../../../js/weapon-icons.js';

const longbow = { inventory_item_id: 'i1', item_id: 'longbow', weapon_group: 'martial', is_ranged: true, damage_type: 'piercing' };
const known = { known: true, icon: 'inventory.weapon', iconKey: null };

// [label, actual, expected]
export const cases = () => [
  ['known longsword -> sword', weaponIconKey({ item_id: 'longsword', damage_type: 'slashing' }, known), 'slot.main-hand'],
  ['known dagger -> dagger', weaponIconKey({ item_id: 'dagger', damage_type: 'piercing' }, known), 'slot.off-hand'],
  ['known longbow -> arrows', weaponIconKey(longbow, known), 'item.ammunition'],
  ['known musket -> firearm', weaponIconKey({ item_id: 'musket', weapon_group: 'firearm', is_ranged: true }, known), 'item.firearm'],
  ['author gallery key beats the map', weaponIconKey(longbow, { ...known, iconKey: 'item.wand' }), 'item.wand'],
  ['homebrew (no map entry) firearm group', weaponIconKey({ item_id: 'x-1', weapon_group: 'firearm', is_ranged: true }, known), 'item.firearm'],
  ['homebrew ranged', weaponIconKey({ item_id: 'x-2', is_ranged: true, damage_type: 'piercing' }, known), 'item.ammunition'],
  ['homebrew melee slashing', weaponIconKey({ item_id: 'x-3', damage_type: 'slashing' }, known), 'slot.main-hand'],
  ['homebrew melee piercing', weaponIconKey({ item_id: 'x-4', damage_type: 'piercing' }, known), 'spell.damage.piercing'],
  ['homebrew melee fire -> generic', weaponIconKey({ item_id: 'x-5', damage_type: 'fire' }, known), GENERIC_WEAPON_ICON],
  ['known, inventory not loaded (info null) still maps', weaponIconKey({ item_id: 'longsword' }, null), 'slot.main-hand'],
  // SECRECY: a masked copy. The derived row keeps the true stats (longbow) but item_id is null; the masked view says known:false.
  ['decoy: masked longbow shows the decoy face icon', weaponIconKey({ ...longbow, item_id: null }, { known: false, icon: 'item.gear', iconKey: null }), 'item.gear'],
  ['decoy: never the true weapon icon', weaponIconKey({ ...longbow, item_id: null }, { known: false, icon: 'item.gear' }) !== 'item.ammunition', true],
  ['decoy: a stale gallery key is ignored', weaponIconKey({ ...longbow, item_id: null }, { known: false, icon: 'inventory.weapon', iconKey: 'item.wand' }), 'inventory.weapon'],
  ['decoy: known:false wins even if item_id leaked', weaponIconKey(longbow, { known: false, icon: 'item.gear' }), 'item.gear'],
  ['decoy, inventory not loaded (known:null, item_id null) -> generic', weaponIconKey({ ...longbow, item_id: null }, { known: null, name: 'Old stick' }), GENERIC_WEAPON_ICON],
  ['decoy, no info at all -> generic', weaponIconKey({ ...longbow, item_id: null }, null), GENERIC_WEAPON_ICON],
  ['weaponIsKnown masked', weaponIsKnown({ item_id: null }, { known: true }), false],
  ['category of nothing', weaponCategoryIcon(null), GENERIC_WEAPON_ICON],
  ['every map value is one of the 7 repo icons', Object.values(WEAPON_ICON_MAP).every((k) => ['slot.main-hand', 'slot.off-hand', 'spell.damage.slashing',
    'spell.damage.piercing', 'item.ammunition', 'item.firearm', 'item.weapons'].includes(k)), true],
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
