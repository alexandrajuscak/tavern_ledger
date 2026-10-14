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
  { key: 'feat', label: 'Feats' },
  { key: 'custom', label: 'Custom Abilities' },
  { key: 'magic_item', label: 'Magic Item Abilities' },
];

export const NOTE_KINDS = ['character', 'quest', 'campaign', 'spells', 'attacks'];

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
