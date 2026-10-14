// D&D 5e reference data and small rule helpers. Deliberately minimal:
// the app helps with bookkeeping, it does not automate class mechanics.

export const ABILITIES = [
  { key: 'str', col: 'strength', short: 'STR', name: 'Strength' },
  { key: 'dex', col: 'dexterity', short: 'DEX', name: 'Dexterity' },
  { key: 'con', col: 'constitution', short: 'CON', name: 'Constitution' },
  { key: 'int', col: 'intelligence', short: 'INT', name: 'Intelligence' },
  { key: 'wis', col: 'wisdom', short: 'WIS', name: 'Wisdom' },
  { key: 'cha', col: 'charisma', short: 'CHA', name: 'Charisma' },
];
export const ABILITY_BY_KEY = Object.fromEntries(ABILITIES.map((a) => [a.key, a]));

export const SKILLS = [
  { key: 'acrobatics', name: 'Acrobatics', ability: 'dex' },
  { key: 'animal_handling', name: 'Animal Handling', ability: 'wis' },
  { key: 'arcana', name: 'Arcana', ability: 'int' },
  { key: 'athletics', name: 'Athletics', ability: 'str' },
  { key: 'deception', name: 'Deception', ability: 'cha' },
  { key: 'history', name: 'History', ability: 'int' },
  { key: 'insight', name: 'Insight', ability: 'wis' },
  { key: 'intimidation', name: 'Intimidation', ability: 'cha' },
  { key: 'investigation', name: 'Investigation', ability: 'int' },
  { key: 'medicine', name: 'Medicine', ability: 'wis' },
  { key: 'nature', name: 'Nature', ability: 'int' },
  { key: 'perception', name: 'Perception', ability: 'wis' },
  { key: 'performance', name: 'Performance', ability: 'cha' },
  { key: 'persuasion', name: 'Persuasion', ability: 'cha' },
  { key: 'religion', name: 'Religion', ability: 'int' },
  { key: 'sleight_of_hand', name: 'Sleight of Hand', ability: 'dex' },
  { key: 'stealth', name: 'Stealth', ability: 'dex' },
  { key: 'survival', name: 'Survival', ability: 'wis' },
];
export const SKILL_BY_KEY = Object.fromEntries(SKILLS.map((s) => [s.key, s]));

export const CLASS_HIT_DIE = {
  Artificer: 'd8', Barbarian: 'd12', Bard: 'd8', Cleric: 'd8', Druid: 'd8', Fighter: 'd10',
  Monk: 'd8', Paladin: 'd10', Ranger: 'd10', Rogue: 'd8', Sorcerer: 'd6', Warlock: 'd8', Wizard: 'd6',
};
export const CLASSES = Object.keys(CLASS_HIT_DIE);
export const HIT_DICE = ['d6', 'd8', 'd10', 'd12'];

export const ALIGNMENTS = [
  'Lawful Good', 'Neutral Good', 'Chaotic Good',
  'Lawful Neutral', 'True Neutral', 'Chaotic Neutral',
  'Lawful Evil', 'Neutral Evil', 'Chaotic Evil', 'Unaligned',
];

// XP needed to reach level N is XP_TABLE[N - 1].
export const XP_TABLE = [
  0, 300, 900, 2700, 6500, 14000, 23000, 34000, 48000, 64000,
  85000, 100000, 120000, 140000, 165000, 195000, 225000, 265000, 305000, 355000,
];

export const RESOURCE_PRESETS = [
  { name: 'Ki', reset: 'short' },
  { name: 'Rage', reset: 'long' },
  { name: 'Sorcery Points', reset: 'long' },
  { name: 'Bardic Inspiration', reset: 'long' },
  { name: 'Wild Shape', reset: 'short' },
  { name: 'Channel Divinity', reset: 'short' },
  { name: 'Action Surge', reset: 'short' },
  { name: 'Second Wind', reset: 'short' },
  { name: 'Superiority Dice', reset: 'short' },
  { name: 'Lay on Hands', reset: 'long' },
  { name: 'Pact Slots', reset: 'short' },
];

export const RESET_LABELS = { short: 'Short rest', long: 'Long rest', none: 'Manual' };

export const FEATURE_CATEGORIES = [
  { key: 'racial', label: 'Racial Features' },
  { key: 'class', label: 'Class Features' },
  { key: 'background', label: 'Background Features' },
  { key: 'feat', label: 'Feats' },
  { key: 'custom', label: 'Custom Abilities' },
  { key: 'magic_item', label: 'Magic Item Abilities' },
];

export const NOTE_KINDS = ['character', 'session', 'campaign', 'spells', 'attacks'];

export const mod = (score) => Math.floor(((Number(score) || 10) - 10) / 2);
export const fmt = (n) => (n >= 0 ? `+${n}` : `${n}`);
export const profBonus = (level) => Math.ceil(Math.max(1, level) / 4) + 1;
export const dieSize = (die) => parseInt(String(die).replace('d', ''), 10) || 8;
export const hitDieAverage = (die) => dieSize(die) / 2 + 1;
export const xpForNextLevel = (level) => (level >= 20 ? null : XP_TABLE[level]);
export const levelForXp = (xp) => {
  let lvl = 1;
  XP_TABLE.forEach((need, i) => { if (xp >= need) lvl = i + 1; });
  return lvl;
};

// ---- Attacks & spells ---------------------------------------------------------

export const DAMAGE_TYPES = [
  'acid', 'bludgeoning', 'cold', 'fire', 'force', 'lightning', 'necrotic',
  'piercing', 'poison', 'psychic', 'radiant', 'slashing', 'thunder',
];
export const SPELL_EFFECT_TYPES = [...DAMAGE_TYPES, 'healing'];

export const SPELL_SCHOOLS = [
  'Abjuration', 'Conjuration', 'Divination', 'Enchantment',
  'Evocation', 'Illusion', 'Necromancy', 'Transmutation',
];

export const ATTACK_ABILITIES = [
  { key: 'str', label: 'Strength' },
  { key: 'dex', label: 'Dexterity' },
  { key: 'finesse', label: 'Best of STR / DEX (finesse)' },
  { key: 'spell', label: 'Spellcasting ability' },
  { key: 'none', label: 'No modifier' },
];

export const EQUIPMENT_PROFICIENCIES = [
  { key: 'light', label: 'Light armor' },
  { key: 'medium', label: 'Medium armor' },
  { key: 'heavy', label: 'Heavy armor' },
  { key: 'shields', label: 'Shields' },
  { key: 'simple', label: 'Simple weapons' },
  { key: 'martial', label: 'Martial weapons' },
];

export const ordinal = (n) => (n === 0 ? 'Cantrip' : `${n}${['', 'st', 'nd', 'rd'][n] || 'th'} level`);

// SRD 5.1 weapon table. kind: melee/ranged; cat: simple/martial.
const W = (name, cat, kind, dice, type, props = '', range = '') => ({ name, cat, kind, dice, type, props, range });
export const WEAPONS = [
  W('Club', 'simple', 'melee', '1d4', 'bludgeoning', 'Light'),
  W('Dagger', 'simple', 'melee', '1d4', 'piercing', 'Finesse, light, thrown', '5 ft or 20/60 ft'),
  W('Greatclub', 'simple', 'melee', '1d8', 'bludgeoning', 'Two-handed'),
  W('Handaxe', 'simple', 'melee', '1d6', 'slashing', 'Light, thrown', '5 ft or 20/60 ft'),
  W('Javelin', 'simple', 'melee', '1d6', 'piercing', 'Thrown', '5 ft or 30/120 ft'),
  W('Light hammer', 'simple', 'melee', '1d4', 'bludgeoning', 'Light, thrown', '5 ft or 20/60 ft'),
  W('Mace', 'simple', 'melee', '1d6', 'bludgeoning'),
  W('Quarterstaff', 'simple', 'melee', '1d6', 'bludgeoning', 'Versatile (1d8)'),
  W('Sickle', 'simple', 'melee', '1d4', 'slashing', 'Light'),
  W('Spear', 'simple', 'melee', '1d6', 'piercing', 'Thrown, versatile (1d8)', '5 ft or 20/60 ft'),
  W('Light crossbow', 'simple', 'ranged', '1d8', 'piercing', 'Ammunition, loading, two-handed', '80/320 ft'),
  W('Dart', 'simple', 'ranged', '1d4', 'piercing', 'Finesse, thrown', '20/60 ft'),
  W('Shortbow', 'simple', 'ranged', '1d6', 'piercing', 'Ammunition, two-handed', '80/320 ft'),
  W('Sling', 'simple', 'ranged', '1d4', 'bludgeoning', 'Ammunition', '30/120 ft'),
  W('Battleaxe', 'martial', 'melee', '1d8', 'slashing', 'Versatile (1d10)'),
  W('Flail', 'martial', 'melee', '1d8', 'bludgeoning'),
  W('Glaive', 'martial', 'melee', '1d10', 'slashing', 'Heavy, reach, two-handed', '10 ft'),
  W('Greataxe', 'martial', 'melee', '1d12', 'slashing', 'Heavy, two-handed'),
  W('Greatsword', 'martial', 'melee', '2d6', 'slashing', 'Heavy, two-handed'),
  W('Halberd', 'martial', 'melee', '1d10', 'slashing', 'Heavy, reach, two-handed', '10 ft'),
  W('Lance', 'martial', 'melee', '1d12', 'piercing', 'Reach, special', '10 ft'),
  W('Longsword', 'martial', 'melee', '1d8', 'slashing', 'Versatile (1d10)'),
  W('Maul', 'martial', 'melee', '2d6', 'bludgeoning', 'Heavy, two-handed'),
  W('Morningstar', 'martial', 'melee', '1d8', 'piercing'),
  W('Pike', 'martial', 'melee', '1d10', 'piercing', 'Heavy, reach, two-handed', '10 ft'),
  W('Rapier', 'martial', 'melee', '1d8', 'piercing', 'Finesse'),
  W('Scimitar', 'martial', 'melee', '1d6', 'slashing', 'Finesse, light'),
  W('Shortsword', 'martial', 'melee', '1d6', 'piercing', 'Finesse, light'),
  W('Trident', 'martial', 'melee', '1d6', 'piercing', 'Thrown, versatile (1d8)', '5 ft or 20/60 ft'),
  W('War pick', 'martial', 'melee', '1d8', 'piercing'),
  W('Warhammer', 'martial', 'melee', '1d8', 'bludgeoning', 'Versatile (1d10)'),
  W('Whip', 'martial', 'melee', '1d4', 'slashing', 'Finesse, reach', '10 ft'),
  W('Blowgun', 'martial', 'ranged', '1', 'piercing', 'Ammunition, loading', '25/100 ft'),
  W('Hand crossbow', 'martial', 'ranged', '1d6', 'piercing', 'Ammunition, light, loading', '30/120 ft'),
  W('Heavy crossbow', 'martial', 'ranged', '1d10', 'piercing', 'Ammunition, heavy, loading, two-handed', '100/400 ft'),
  W('Longbow', 'martial', 'ranged', '1d8', 'piercing', 'Ammunition, heavy, two-handed', '150/600 ft'),
];

/** Turn a preset weapon into attack-row defaults. */
export function weaponToAttack(w, equipmentProfs = {}) {
  const finesse = /finesse/i.test(w.props);
  return {
    name: w.name,
    attack_kind: w.kind,
    ability: finesse ? 'finesse' : w.kind === 'ranged' ? 'dex' : 'str',
    proficient: !!equipmentProfs[w.cat],
    damage_dice: w.dice,
    damage_type: w.type,
    range: w.range || '5 ft',
    properties: w.props,
  };
}

// ---- Feature activation & combat grouping -------------------------------------

export const ACTIVATIONS = [
  { key: 'action', label: 'Action', plural: 'Actions' },
  { key: 'bonus_action', label: 'Bonus Action', plural: 'Bonus Actions' },
  { key: 'reaction', label: 'Reaction', plural: 'Reactions' },
  { key: 'passive', label: 'Passive', plural: 'Passive Features' },
];
export const ACTIVATION_BY_KEY = Object.fromEntries(ACTIVATIONS.map((a) => [a.key, a]));

export const CASTING_TIMES = ['1 action', '1 bonus action', '1 reaction', '1 minute', '10 minutes', '1 hour', '8 hours'];

/** Which combat group a spell belongs to, from its free-text casting time. */
export function castingGroup(castingTime) {
  const t = String(castingTime || '').toLowerCase();
  if (/bonus/.test(t)) return 'bonus_action';
  if (/reaction/.test(t)) return 'reaction';
  if (/action/.test(t) || t.trim() === '') return 'action';
  return 'other'; // 1 minute, 10 minutes, rituals…
}

// ---- Conditions ----------------------------------------------------------------
// Short reminders for new players (summarised from the 5e SRD), plus two common
// table states that are not official conditions.

export const CONDITIONS = [
  { name: 'Blessed', text: 'Add 1d4 to attack rolls and saving throws (Bless spell).' },
  { name: 'Blinded', text: "You can't see. Attacks against you have advantage; your attacks have disadvantage." },
  { name: 'Charmed', text: "You can't attack the charmer, and they have advantage on social checks against you." },
  { name: 'Concentrating', text: 'When you take damage, make a CON save (DC 10 or half the damage, whichever is higher) or the spell ends. Casting another concentration spell also ends it.' },
  { name: 'Deafened', text: "You can't hear and automatically fail checks that require hearing." },
  { name: 'Frightened', text: "Disadvantage on checks and attacks while you can see the source of fear; you can't move closer to it." },
  { name: 'Grappled', text: 'Your speed is 0. Ends if the grappler is incapacitated or you are moved out of reach.' },
  { name: 'Incapacitated', text: "You can't take actions or reactions." },
  { name: 'Invisible', text: "You can't be seen without magic. Your attacks have advantage; attacks against you have disadvantage." },
  { name: 'Paralyzed', text: "Incapacitated, can't move or speak. You fail STR and DEX saves. Attacks against you have advantage; hits from within 5 ft are critical." },
  { name: 'Poisoned', text: 'Disadvantage on attack rolls and ability checks.' },
  { name: 'Prone', text: 'You can only crawl (standing up costs half your speed). Your attacks have disadvantage. Melee attacks against you have advantage; ranged attacks have disadvantage.' },
  { name: 'Restrained', text: 'Your speed is 0. Your attacks and DEX saves have disadvantage; attacks against you have advantage.' },
  { name: 'Stunned', text: "Incapacitated, can't move, can barely speak. You fail STR and DEX saves; attacks against you have advantage." },
  { name: 'Unconscious', text: 'Incapacitated, prone, drop what you hold. Fail STR and DEX saves. Attacks have advantage; hits from within 5 ft are critical.' },
  { name: 'Exhaustion', text: 'Level 1: disadvantage on ability checks. Gets worse at higher levels; a long rest removes one level.' },
];
export const CONDITION_BY_NAME = Object.fromEntries(CONDITIONS.map((c) => [c.name.toLowerCase(), c]));

// ---- Skills: {proficient, expertise} objects -----------------------------------

/** 0 = none, 1 = proficient, 2 = expertise. Accepts the old 0/1/2 numbers too. */
export function skillLevel(v) {
  if (typeof v === 'number') return v;
  if (v && typeof v === 'object') return v.expertise ? 2 : v.proficient ? 1 : 0;
  return 0;
}
export const skillValue = (level) => ({ proficient: level >= 1, expertise: level >= 2 });
