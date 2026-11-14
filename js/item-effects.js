// Item effects (docs/ITEM_EFFECTS.md, 20261114000500): the shared words for effect kinds, activations and granted spells, used by
// the DM Space item editor, the inventory "Use" result and the sheet's "where a bonus comes from" lines. Display only: the database
// validates and applies every effect.

export const ABILITY_NAMES = { str: 'Strength', dex: 'Dexterity', con: 'Constitution', int: 'Intelligence', wis: 'Wisdom', cha: 'Charisma' };
export const SKILL_NAMES = {
  acrobatics: 'Acrobatics', animal_handling: 'Animal Handling', arcana: 'Arcana', athletics: 'Athletics', deception: 'Deception',
  history: 'History', insight: 'Insight', intimidation: 'Intimidation', investigation: 'Investigation', medicine: 'Medicine',
  nature: 'Nature', perception: 'Perception', performance: 'Performance', persuasion: 'Persuasion', religion: 'Religion',
  sleight_of_hand: 'Sleight of Hand', stealth: 'Stealth', survival: 'Survival',
};

// [value, label] lists for the editor (the order is the order of the select)
export const EFFECT_KINDS = [
  ['ability_bonus', 'Ability score +'], ['ability_override', 'Ability score set to'], ['skill_bonus', 'Skill +'],
  ['save_bonus', 'Saving throw + (no target: all saves)'], ['ac_bonus', 'Armor Class +'], ['initiative_bonus', 'Initiative +'],
  ['speed_bonus', 'Speed + (ft)'], ['speed_penalty', 'Speed − (ft)'], ['resistance', 'Resistance (damage type)'],
  ['skill_advantage', 'Advantage on a skill'], ['skill_disadvantage', 'Disadvantage on a skill'],
  ['attack_bonus', 'Attack rolls + (weapons: this weapon)'], ['damage_bonus', 'Damage + (weapons: this weapon)'],
];
export const ACTIVATIONS = [
  ['equipped', 'While equipped'], ['attuned', 'While attuned'], ['equipped_and_attuned', 'While equipped and attuned'],
  ['owned', 'While carried'], ['permanent', 'Permanent, when used (consumable)'],
];
export const CASTING = [['per_rest', 'Uses per rest (own counter)'], ['at_will', 'At will'], ['spell_slots', 'Uses the character’s spell slots']];
export const RECHARGE = [['long_rest', 'Long rest'], ['short_rest', 'Short rest']];
// weapon blocks (R-D2)
export const ACTION_COSTS = [['action', 'Action'], ['bonus_action', 'Bonus action'], ['reaction', 'Reaction']];
export const ACTION_ROLLS = [['none', 'No roll'], ['attack', 'Attack roll (the weapon’s to hit)'], ['save', 'Saving throw']];
export const DC_ABILITIES = [['', 'DC: 8 + proficiency + the weapon’s ability'], ['str', '8 + prof. + Strength'], ['dex', '8 + prof. + Dexterity'],
  ['con', '8 + prof. + Constitution'], ['int', '8 + prof. + Intelligence'], ['wis', '8 + prof. + Wisdom'], ['cha', '8 + prof. + Charisma']];
export const CONDITION_APPLIES = [['hit', 'On a hit'], ['action', 'By a weapon action']];
/** SRD conditions for the editor's list (the server maps a name of the conditions catalog to its key; other text is custom). */
export const CONDITION_NAMES = ['Blinded', 'Charmed', 'Deafened', 'Exhaustion', 'Frightened', 'Grappled', 'Incapacitated', 'Invisible',
  'Paralyzed', 'Petrified', 'Poisoned', 'Prone', 'Restrained', 'Stunned', 'Unconscious', 'Bleeding'];

/** Targets of an effect for one select: abilities, then skills (the server checks that the target fits the kind). */
export function effectTargetOptions(damageTypes = []) {
  return [['', '— (AC, initiative, speed, all saves)'],
    ...Object.entries(ABILITY_NAMES).map(([k, v]) => [k, v]),
    ...Object.entries(SKILL_NAMES).map(([k, v]) => [k, `${v} (skill)`]),
    ...damageTypes.map((d) => [d.id, `${d.name} (damage type)`])];
}

const signed = (n) => (Number(n) >= 0 ? `+${Number(n)}` : `−${Math.abs(Number(n))}`);
const targetName = (t) => ABILITY_NAMES[t] || SKILL_NAMES[t] || t || '';

/** One effect as a short phrase: "+1 Wisdom", "Strength set to 19", "+1 to all saving throws", "+10 ft speed". */
export function effectText(e) {
  const v = e.value;
  switch (e.effect_type || e.type) {
    case 'ability_bonus': return `${signed(v)} ${targetName(e.target)}${e.max_score || e.max ? ` (up to ${e.max_score || e.max})` : ''}`;
    case 'ability_override': return `${targetName(e.target)} set to ${v}`;
    case 'skill_bonus': return `${signed(v)} ${targetName(e.target)}`;
    case 'save_bonus': return e.target ? `${signed(v)} ${targetName(e.target)} saving throws` : `${signed(v)} to all saving throws`;
    case 'ac_bonus': return `${signed(v)} Armor Class`;
    case 'initiative_bonus': return `${signed(v)} Initiative`;
    case 'speed_bonus': return `${signed(v)} ft speed`;
    case 'speed_penalty': return `−${Math.abs(Number(v))} ft speed`;
    case 'resistance': return `Resistance to ${e.target} damage`;
    case 'skill_advantage': return `Advantage on ${targetName(e.target)}`;
    case 'skill_disadvantage': return `Disadvantage on ${targetName(e.target)}`;
    case 'attack_bonus': return `${signed(v)} to attack rolls`;
    case 'damage_bonus': return `${signed(v)} damage`;
    default: return String(e.effect_type || e.type || 'Effect');
  }
}

/** How a granted spell is cast: "1× per long rest", "at will", "with your spell slots". */
export function castingText(g) {
  if ((g.casting || g.uses) === 'at_will' || g.uses === 'at_will') return 'at will';
  if (g.casting === 'spell_slots' || (g.uses == null && g.uses_spell_slot)) return 'with your spell slots';
  const per = g.recharge === 'short_rest' ? 'short rest' : 'long rest';
  return `${g.uses || 1}× per ${per}`;
}
