// Character JSON import / export (format: docs/character.schema.json).
// The JSON holds source-of-truth data only: ability scores, proficiency flags,
// dice and so on. Bonuses (skills, saves, passives, initiative, to-hit) are
// always calculated by the app and never stored.

import { supabase } from './supabase.js?v=6';
import { ABILITIES, SKILLS, CLASS_HIT_DIE, ACTIVATIONS, FEATURE_CATEGORIES, skillLevel, skillValue, dieSize } from './dnd.js?v=6';

export const SCHEMA_VERSION = 1;

const EQUIP_LABELS = {
  light: 'Light armor', medium: 'Medium armor', heavy: 'Heavy armor', shields: 'Shields',
  simple: 'Simple weapons', martial: 'Martial weapons',
};

// ---- small helpers -----------------------------------------------------------

const int = (v, d = 0) => (Number.isFinite(Number(v)) && v !== '' && v !== null ? Math.trunc(Number(v)) : d);
const str = (v, d = '') => (v == null ? d : String(v));
const bool = (v) => v === true || v === 'true' || v === 1;
const list = (v) => (Array.isArray(v) ? v : v == null || v === '' ? [] : [v]);
const snake = (k) => String(k).replace(/([a-z])([A-Z])/g, '$1_$2').replace(/[\s-]+/g, '_').toLowerCase();

function activationKey(v) {
  const k = snake(v || 'passive').replace(/^1_/, '');
  if (k.startsWith('bonus')) return 'bonus_action';
  if (k.startsWith('reaction')) return 'reaction';
  if (k.startsWith('action')) return 'action';
  return 'passive';
}
const activationLabel = (k) => ACTIVATIONS.find((a) => a.key === k)?.label || 'Passive';

function resetKey(v) {
  const k = snake(v || 'long');
  if (k.startsWith('short')) return 'short';
  if (k.startsWith('none') || k.startsWith('manual')) return 'none';
  return 'long';
}

const categoryKey = (v) => {
  const k = snake(v || 'custom').replace(/_features?$/, '').replace(/^race$/, 'racial');
  return FEATURE_CATEGORIES.some((c) => c.key === k) ? k : 'custom';
};

// ---- Proficiencies: flags <-> lists ------------------------------------------

function splitProficiencies(p = {}) {
  const flags = {};
  const extra = { weapons: [], armor: [], tools: list(p.tools), languages: list(p.languages), other: list(p.other) };
  for (const [group, items] of [['armor', list(p.armor)], ['weapons', list(p.weapons)]]) {
    for (const item of items) {
      const t = String(item).toLowerCase();
      const flag =
        /light/.test(t) && /armou?r/.test(t) ? 'light'
          : /medium/.test(t) ? 'medium'
            : /heavy/.test(t) ? 'heavy'
              : /shield/.test(t) ? 'shields'
                : /simple/.test(t) ? 'simple'
                  : /martial/.test(t) ? 'martial' : null;
      if (flag) flags[flag] = true;
      else extra[group].push(String(item));
    }
  }
  const lines = [];
  if (extra.armor.length) lines.push(`Armor: ${extra.armor.join(', ')}`);
  if (extra.weapons.length) lines.push(`Weapons: ${extra.weapons.join(', ')}`);
  if (extra.tools.length) lines.push(`Tools: ${extra.tools.join(', ')}`);
  if (extra.languages.length) lines.push(`Languages: ${extra.languages.join(', ')}`);
  extra.other.forEach((o) => lines.push(String(o)));
  return { flags, text: lines.join('\n') };
}

function joinProficiencies(flags = {}, text = '') {
  const out = { armor: [], weapons: [], tools: [], languages: [], other: [] };
  for (const k of ['light', 'medium', 'heavy', 'shields']) if (flags[k]) out.armor.push(EQUIP_LABELS[k]);
  for (const k of ['simple', 'martial']) if (flags[k]) out.weapons.push(EQUIP_LABELS[k]);
  for (const line of String(text).split('\n').map((l) => l.trim()).filter(Boolean)) {
    const m = line.match(/^(armou?r|weapons?|tools?|languages?)\s*:\s*(.*)$/i);
    if (!m) { out.other.push(line); continue; }
    const key = m[1].toLowerCase().startsWith('arm') ? 'armor'
      : m[1].toLowerCase().startsWith('weap') ? 'weapons'
        : m[1].toLowerCase().startsWith('tool') ? 'tools' : 'languages';
    out[key].push(...m[2].split(',').map((s) => s.trim()).filter(Boolean));
  }
  return out;
}

// ---- Export --------------------------------------------------------------------

export function exportCharacter(B) {
  const c = B.character;
  const note = (kind) => B.notes.find((n) => n.kind === kind)?.content || '';
  return {
    schemaVersion: SCHEMA_VERSION,
    name: c.name,
    race: c.race,
    class: c.class_name,
    subclass: c.subclass,
    background: c.background,
    alignment: c.alignment,
    level: c.level,
    experience: c.experience,
    portrait: c.portrait_url || '',
    abilities: Object.fromEntries(ABILITIES.map((a) => [a.key, c[a.col]])),
    savingThrows: Object.fromEntries(ABILITIES.map((a) => [a.key, { proficient: !!c.save_proficiencies?.[a.key] }])),
    skills: Object.fromEntries(SKILLS.map((s) => [s.key, skillValue(skillLevel(c.skill_proficiencies?.[s.key]))])),
    combat: {
      hp: { current: c.hp_current, max: c.hp_max, temp: c.hp_temp },
      ac: c.ac,
      speed: c.speed,
      initiativeBonus: c.initiative_bonus,
      hitDice: { die: c.hit_die, current: c.hit_dice_current },
      deathSaves: { successes: c.death_successes, failures: c.death_failures },
      inspiration: !!c.inspiration,
    },
    conditions: Array.isArray(c.conditions) ? c.conditions : [],
    proficiencies: joinProficiencies(c.equipment_proficiencies, c.proficiencies),
    spellcasting: {
      ability: c.spellcasting_ability || null,
      slots: Object.fromEntries(B.slots.filter((s) => s.total > 0).map((s) => [String(s.level), { total: s.total, used: s.used }])),
    },
    resources: B.trackers.map((t) => ({ name: t.name, current: t.current, max: t.max, reset: t.reset_on })),
    attacks: B.attacks.map((a) => ({
      name: a.name, type: a.attack_kind, ability: a.ability, proficient: a.proficient, magicBonus: a.magic_bonus,
      damageDice: a.damage_dice, damageType: a.damage_type, addModifier: a.add_modifier,
      range: a.range, properties: a.properties, notes: a.notes,
    })),
    features: B.features.map((f) => ({
      name: f.name, type: activationLabel(f.activation), source: f.category, description: f.description,
    })),
    spells: B.spells.map((s) => ({
      name: s.name, level: s.level, school: s.school, castingTime: s.casting_time, range: s.range,
      duration: s.duration, components: s.components, concentration: s.concentration, ritual: s.ritual,
      attack: s.attack_type, save: s.save_ability || null, damage: s.damage, damageType: s.damage_type,
      description: s.description, prepared: s.prepared,
    })),
    inventory: B.inventory.map((i) => ({
      name: i.name, quantity: i.quantity, weight: Number(i.weight), equipped: i.equipped, description: i.description,
    })),
    currency: { cp: c.cp, sp: c.sp, ep: c.ep, gp: c.gp, pp: c.pp },
    notes: {
      character: note('character'), session: note('session'), campaign: note('campaign'),
      spells: note('spells'), combat: note('attacks'),
    },
  };
}

// ---- Import --------------------------------------------------------------------

/** Turn JSON (this format, or the older hand-written one) into table rows. Throws on bad input. */
export function parseCharacterJson(j) {
  if (!j || typeof j !== 'object' || Array.isArray(j)) throw new Error('The file is not a character JSON object.');
  if (!str(j.name).trim()) throw new Error('The character needs a "name".');

  // Older files used "class": { "name", "level", "subclass" }.
  const cls = typeof j.class === 'object' && j.class ? j.class : { name: j.class, level: j.level, subclass: j.subclass };
  const level = Math.min(20, Math.max(1, int(cls.level ?? j.level, 1)));
  const className = str(cls.name);
  const hitDie = ['d6', 'd8', 'd10', 'd12'].includes(j.combat?.hitDice?.die || j.combat?.hitDice?.type)
    ? (j.combat.hitDice.die || j.combat.hitDice.type)
    : CLASS_HIT_DIE[className] || 'd8';
  const hp = j.combat?.hp || {};
  const hpMax = Math.max(1, int(hp.max, dieSize(hitDie)));

  const skills = {};
  for (const [k, v] of Object.entries(j.skills || {})) {
    const key = snake(k);
    if (!SKILLS.some((s) => s.key === key)) continue;
    // Only flag objects (or true/false) carry proficiency; plain numbers were derived bonuses.
    if (v && typeof v === 'object') skills[key] = skillValue(skillLevel(v));
    else if (typeof v === 'boolean') skills[key] = skillValue(v ? 1 : 0);
  }
  const saves = {};
  for (const [k, v] of Object.entries(j.savingThrows || {})) {
    if (ABILITIES.some((a) => a.key === k)) saves[k] = bool(typeof v === 'object' && v ? v.proficient : v);
  }
  const { flags, text } = splitProficiencies(j.proficiencies || { languages: j.languages });

  const character = {
    name: str(j.name).trim(),
    race: str(j.race),
    class_name: className,
    subclass: str(cls.subclass ?? j.subclass),
    background: str(j.background),
    alignment: str(j.alignment),
    level,
    experience: Math.max(0, int(j.experience)),
    portrait_url: str(j.portrait),
    hp_max: hpMax,
    hp_current: Math.max(0, int(hp.current, hpMax)),
    hp_temp: Math.max(0, int(hp.temp ?? hp.temporary)),
    ac: int(j.combat?.ac, 10),
    speed: int(j.combat?.speed, 30),
    initiative_bonus: int(j.combat?.initiativeBonus),
    hit_die: hitDie,
    hit_dice_current: Math.min(level, Math.max(0, int(j.combat?.hitDice?.current, level))),
    inspiration: bool(j.combat?.inspiration),
    save_proficiencies: saves,
    skill_proficiencies: skills,
    equipment_proficiencies: flags,
    proficiencies: text,
    spellcasting_ability: ABILITIES.some((a) => a.key === j.spellcasting?.ability) ? j.spellcasting.ability : '',
    conditions: list(j.conditions).map(String),
    ...Object.fromEntries(ABILITIES.map((a) => [a.col, Math.min(30, Math.max(1, int(j.abilities?.[a.key], 10)))])),
    ...Object.fromEntries(['cp', 'sp', 'ep', 'gp', 'pp'].map((k) => [k, Math.max(0, int(j.currency?.[k]))])),
  };

  const trackers = list(j.resources).map((r, i) => ({
    name: str(r.name, 'Resource'), max: Math.max(0, int(r.max, 1)),
    current: Math.max(0, int(r.current ?? r.max, 1)), reset_on: resetKey(r.reset), sort_order: i,
  })).map((t) => ({ ...t, current: Math.min(t.current, t.max) }));

  const attacks = list(j.attacks ?? j.weapons).map((a, i) => ({
    name: str(a.name, 'Attack'),
    attack_kind: a.type === 'ranged' ? 'ranged' : 'melee',
    ability: ['str', 'dex', 'finesse', 'spell', 'none'].includes(a.ability) ? a.ability : 'str',
    proficient: a.proficient === undefined ? true : bool(a.proficient),
    magic_bonus: int(a.magicBonus),
    damage_dice: str(a.damageDice ?? a.damage, '1d6').replace(/\s*[+-]\s*\d+\s*$/, ''),
    damage_type: snake(a.damageType || 'bludgeoning'),
    add_modifier: a.addModifier === undefined ? true : bool(a.addModifier),
    range: str(a.range, '5 ft'),
    properties: str(a.properties),
    notes: str(a.notes),
    sort_order: i,
  }));

  const features = list(j.features).map((f, i) => (typeof f === 'string'
    ? { name: f, category: 'custom', activation: 'passive', description: '', sort_order: i }
    : {
      name: str(f.name, 'Feature'), category: categoryKey(f.source ?? f.category),
      activation: activationKey(f.type ?? f.activation), description: str(f.description), sort_order: i,
    }));

  const spells = list(j.spells).map((s, i) => ({
    name: str(s.name, 'Spell'),
    level: Math.min(9, Math.max(0, int(s.level))),
    school: str(s.school),
    casting_time: str(s.castingTime, '1 action'),
    range: str(s.range),
    duration: str(s.duration),
    components: str(s.components),
    concentration: bool(s.concentration),
    ritual: bool(s.ritual),
    attack_type: ['attack', 'save'].includes(s.attack) ? s.attack : 'none',
    save_ability: ABILITIES.some((a) => a.key === s.save) ? s.save : '',
    damage: str(s.damage),
    damage_type: str(s.damageType).toLowerCase(),
    description: str(s.description),
    prepared: bool(s.prepared),
    sort_order: i,
  }));

  const inventory = list(j.inventory).map((it, i) => (typeof it === 'string'
    ? { name: it, quantity: 1, sort_order: i }
    : {
      name: str(it.name, 'Item'), quantity: Math.max(0, int(it.quantity, 1)), weight: Math.max(0, Number(it.weight) || 0),
      equipped: bool(it.equipped), description: str(it.description), sort_order: i,
    }));

  const slots = {};
  for (const [lvl, v] of Object.entries(j.spellcasting?.slots || {})) {
    const l = int(lvl);
    if (l < 1 || l > 9) continue;
    const total = Math.min(9, Math.max(0, int(typeof v === 'object' ? v.total : v)));
    slots[l] = { total, used: Math.min(total, Math.max(0, int(typeof v === 'object' ? v.used : 0))) };
  }

  const n = j.notes && typeof j.notes === 'object' ? j.notes : { character: str(j.notes) };
  const notes = {
    character: str(n.character), session: str(n.session), campaign: str(n.campaign),
    spells: str(n.spells), attacks: str(n.combat ?? n.attacks),
  };

  return { character, trackers, attacks, features, spells, inventory, slots, notes };
}

/** Create a new character from JSON. Returns the new character id. */
export async function importCharacter(json, ownerId, campaignId) {
  const p = parseCharacterJson(json);
  const row = { ...p.character };
  if (ownerId) row.owner_id = ownerId;
  if (campaignId) row.campaign_id = campaignId;

  const { data: c, error } = await supabase.from('characters').insert(row).select('id').single();
  if (error) throw error;
  const withChar = (rows) => rows.map((r) => ({ ...r, character_id: c.id }));

  const ops = [];
  if (p.trackers.length) ops.push(supabase.from('feature_trackers').insert(withChar(p.trackers)));
  if (p.attacks.length) ops.push(supabase.from('attacks').insert(withChar(p.attacks)));
  if (p.features.length) ops.push(supabase.from('features').insert(withChar(p.features)));
  if (p.spells.length) ops.push(supabase.from('spells').insert(withChar(p.spells)));
  if (p.inventory.length) ops.push(supabase.from('inventory_items').insert(withChar(p.inventory)));
  for (const [level, s] of Object.entries(p.slots)) {
    ops.push(supabase.from('spell_slots').update(s).eq('character_id', c.id).eq('level', Number(level)));
  }
  for (const [kind, content] of Object.entries(p.notes)) {
    if (content) ops.push(supabase.from('notes').update({ content }).eq('character_id', c.id).eq('kind', kind));
  }
  const results = await Promise.all(ops);
  const failed = results.find((r) => r.error);
  if (failed) throw failed.error;
  return c.id;
}

export function downloadJson(obj, filename) {
  const blob = new Blob([JSON.stringify(obj, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
