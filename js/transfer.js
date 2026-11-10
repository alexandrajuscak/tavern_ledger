// Character JSON import / export (format: docs/character.schema.json).
// The JSON holds source-of-truth data only: ability scores, proficiency flags,
// dice and so on. Bonuses (skills, saves, passives, initiative, to-hit) are
// always calculated by the app and never stored.

import { supabase } from './supabase.js?v=21';
import { friendlyError } from './utils.js?v=21';
import { importInventoryItems } from './inventory-api.js?v=21';
import { setCharacterLineage } from './lineage-api.js?v=21';
import { setCharacterBackground } from './background-api.js?v=21';
import { currentPayload } from './background-ui.js?v=21';
import { setCharacterClass, getClassSummary, setSlotState, saveResource, changeResource, importClassFeatures } from './class-api.js?v=21';
import { saveSpellcastingSource, setCharacterSpell } from './spell-api.js?v=21';
import { importFeats } from './feat-api.js?v=21';
import { ABILITIES, SKILLS, CLASS_HIT_DIE, ACTIVATIONS, FEATURE_CATEGORIES, skillLevel, skillValue, dieSize } from './dnd.js?v=21';

export const SCHEMA_VERSION = 1;

const EQUIP_LABELS = {
  light: 'Light armor', medium: 'Medium armor', heavy: 'Heavy armor', shields: 'Shields',
  simple: 'Simple weapons', martial: 'Martial weapons', firearms: 'Firearms',
};

// ---- small helpers -----------------------------------------------------------

// whole numbers within the database's integer range: a hostile 1e12 becomes the largest storable value instead of failing the import (V6.2)
const int = (v, d = 0) => (Number.isFinite(Number(v)) && v !== '' && v !== null ? Math.max(-2147483648, Math.min(2147483647, Math.trunc(Number(v)))) : d);
const str = (v, d = '') => (v == null ? d : String(v));
const bool = (v) => v === true || v === 'true' || v === 1;
const list = (v) => (Array.isArray(v) ? v : v == null || v === '' ? [] : [v]);
const snake = (k) => String(k).replace(/([a-z])([A-Z])/g, '$1_$2').replace(/[\s-]+/g, '_').toLowerCase();

function activationKey(v) {
  const k = snake(v || 'passive').replace(/^1_/, '');
  if (k.startsWith('bonus')) return 'bonus_action';
  if (k.startsWith('reaction')) return 'reaction';
  if (k.startsWith('special') || k.startsWith('free') || k.startsWith('no_action')) return 'special';
  if (k.startsWith('action')) return 'action';
  return 'passive';
}
const activationLabel = (k) => (k === 'special' ? 'Special' : ACTIVATIONS.find((a) => a.key === k)?.label || 'Passive');

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


/** Normalise pendingChoices: [{id, type, description, options[]}]. */
function parsePendingChoices(v) {
  const used = new Set();
  return list(v).filter((p) => p && typeof p === 'object').map((p, i) => {
    let id = String(p.id || p.type || `choice-${i + 1}`).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || `choice-${i + 1}`;
    while (used.has(id)) id += `-${i + 1}`;
    used.add(id);
    return { id, type: str(p.type, 'Choice'), description: str(p.description), options: list(p.options).map(String) };
  });
}

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
                  : /martial/.test(t) ? 'martial'
                    : /firearm/.test(t) ? 'firearms' : null;
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
  for (const k of ['simple', 'martial', 'firearms']) if (flags[k]) out.weapons.push(EQUIP_LABELS[k]);
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

export function exportCharacter(B, { lineage = null, spellbook = null, classSummary = null, slotState = null, classFeatureState = null,
  companions = null, background = null, wildShape = null, feats = null } = {}) {
  const c = B.character;
  const classes = classSummary?.classes || [];
  const classOfSource = (id) => classes.find((k) => k.spellcasting?.source_id === id);
  const lin = lineage?.selected ? lineage : null;
  const note = (kind) => B.notes.find((n) => n.kind === kind)?.content || '';
  return {
    schemaVersion: SCHEMA_VERSION,
    name: c.name,
    // "race" is only the old free-text value (legacy compatibility), never a copy of the lineage (docs/CHARACTER_CREATION_AUDIT.md)
    ...(c.race ? { race: c.race } : {}),
    // the structured selection (re-applied on import): exact version, sub-lineage, choices; name and label for people
    ...(lin ? { lineage: {
      lineageId: lin.lineage.id, version: lin.version.id, subversion: lin.subversion?.id || null,
      name: [lin.lineage.name, lin.subversion?.name].filter(Boolean).join(' · '), versionLabel: `${lin.version.name} (${lin.version.source_label})`,
      abilityBonusesIncluded: !!lin.ability_bonuses_included,
      choices: Object.fromEntries(lin.choices.filter((ch) => ch.enabled && ch.values.length).map((ch) => [ch.id, ch.values])),
    } } : {}),
    class: c.class_name,
    subclass: c.subclass,
    // class rows (class version + level): the total level, proficiency bonus and spell slots follow from them on import
    ...(classes.length ? { classes: classes.map((k) => ({
      key: k.id, classVersion: k.class_version_id, level: k.level, subclassVersion: k.subclass_version_id || null,
      primary: !!k.is_primary, notes: k.notes || null,
    })) } : {}),
    // class feature state (export_character_class_features): stable catalog ids + character decisions, never the catalog.
    // classKey = the "key" of the class row above.
    ...(classFeatureState && (classFeatureState.choices?.length || classFeatureState.optionalFeatures?.length
      || classFeatureState.resources?.length) ? { classFeatures: {
      format: classFeatureState.format, version: classFeatureState.version, choices: classFeatureState.choices || [],
      optionalFeatures: classFeatureState.optionalFeatures || [], resources: classFeatureState.resources || [],
    } } : {}),
    // companions (familiars, steeds ...): catalog creature id or a custom name / hit points
    ...(companions?.length ? { companions: companions.map((x) => ({
      creature: x.creature_id || null, name: x.name, source: x.source || null, hpMax: x.hp_max, hpCurrent: x.hp_current,
      notes: x.notes || null, active: x.active !== false,
    })) } : {}),
    background: c.background,
    // Wild Shape: seen forms, favorites and settings are restored on import; an active form is exported for reference only
    // and imported as inactive (form HP and uses are never trusted from a file). docs/WILD_SHAPE_RULES.md
    ...(wildShape && (wildShape.options || []).some((o) => o.seen || o.favorite) || wildShape?.active ? { wildShape: {
      seen: (wildShape.options || []).filter((o) => o.seen).map((o) => ({ creature: o.id, source: o.seen })),
      favorites: (wildShape.options || []).filter((o) => o.favorite).map((o) => o.id),
      settings: { seenMode: wildShape.settings?.seen_mode, defaultEquipment: wildShape.settings?.default_equipment,
        confirmLethal: wildShape.settings?.confirm_lethal },
      active: wildShape.active ? { creature: wildShape.active.creature_id, formHp: wildShape.active.hp_current, formHpMax: wildShape.active.hp_max,
        formTempHp: wildShape.active.hp_temp || 0, elemental: !!wildShape.active.elemental, equipment: wildShape.active.equipment?.mode || null,
        startedAt: wildShape.active.started_at, policy: 'reference only: imported as inactive' } : null,
    } } : {}),
    // feats (export_character_feats): catalog version ids + the character's choices, never the catalog or DM-only data.
    // Direct feats are re-assigned on import; background / lineage / ASI feats only get their choices back (docs/FEATS.md)
    ...(feats?.length ? { feats: feats.map((f) => ({
      version: f.feat_version_id, name: f.feat_name, ruleset: f.ruleset, sourceType: f.source_type, sourceLabel: f.source_label || null,
      grantKey: f.grant_key || null, choices: f.choices || {}, notes: f.notes || null, custom: !!f.custom,
    })) } : {}),
    // the structured background (2024 or legacy version id + the character's decisions; re-applied on import)
    ...(background?.selected ? { backgroundVersion: (() => {
      const pay = currentPayload(background);
      return { version: background.version.id, ability: pay.ability, bonusesIncluded: pay.options.bonuses_included, choices: pay.choices,
        replacements: pay.replacements, characteristics: pay.options.characteristics, notes: pay.options.notes || null,
        dmApproved: !!background.version.dm_permission };
    })() } : {}),
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
    pendingChoices: Array.isArray(c.pending_choices) ? c.pending_choices : [],
    proficiencies: joinProficiencies(c.equipment_proficiencies, c.proficiencies),
    spellcasting: {
      ability: c.spellcasting_ability || null,
      slots: Object.fromEntries(B.slots.filter((s) => s.total > 0).map((s) => [String(s.level), { total: s.total, used: s.used }])),
      // stored spellcasting sources (lineage grants are derived from the lineage and not exported twice)
      ...(spellbook ? { sources: spellbook.sources.filter((s) => s.id).map((s) => ({
        key: s.id, type: s.source_type, label: s.label, classVersion: s.class_version_id || null, spellList: s.spell_list_id || null,
        ...(classOfSource(s.id) ? { classKey: classOfSource(s.id).id } : {}),
        castingAbility: s.casting_ability || null, allowedAbilities: s.allowed_abilities || [], fixedDc: s.stats?.fixed_dc ?? null,
        fixedAttackBonus: s.stats?.fixed_attack_bonus ?? null, dcBonus: s.dc_bonus || 0, attackBonus: s.attack_bonus || 0,
        preparationMode: s.preparation_mode, ritualMode: s.ritual_mode, usesSpellSlots: s.uses_spell_slots !== false,
        classLevel: s.class_level ?? null, enforceSpellList: !!s.enforce_spell_list, alwaysPreparedAllowed: !!s.always_prepared_allowed,
        notes: s.notes || null,
      })) } : {}),
    },
    // catalog spells: stable spell version ids + per-source state (the catalog itself is not exported)
    ...(spellbook ? { catalogSpells: spellbook.spells.flatMap((sp) => sp.grants.filter((g) => g.character_spell_id).map((g) => ({
      spell: sp.id, name: sp.name, level: sp.level, source: g.source_key, known: !!g.known, prepared: !!g.prepared,
      alwaysPrepared: !!g.always_prepared, castingAbility: g.casting_ability_override || null, notes: g.notes || null,
    }))) } : {}),
    // runtime slot usage (maximums are derived from the classes and never exported)
    ...(slotState && (slotState.standard?.length || slotState.pact_magic) ? { slotState: {
      standard: Object.fromEntries((slotState.standard || []).filter((s) => s.expended > 0).map((s) => [String(s.slot_level), s.expended])),
      pact: slotState.pact_magic?.expended || 0,
    } } : {}),
    ...(classSummary?.resources?.length ? { characterResources: classSummary.resources.map((r) => ({
      key: r.resource_key, name: r.name, sourceType: r.source_type, sourceId: r.source_id || null,
      classKey: r.character_class_id || null, maxFormula: r.max_formula, die: r.die || null, recharge: r.recharge,
      unlockLevel: r.unlock_level ?? null, spellVersion: r.spell_version_id || null, castLevel: r.cast_level ?? null,
      active: r.active !== false, notes: r.notes || null, expended: r.expended || 0,
    })) } : {}),
    resources: B.trackers.map((t) => ({
      name: t.name, current: t.current, max: t.max, reset: t.reset_on, ...(t.formula ? { formula: t.formula } : {}),
    })),
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
      description: s.description, prepared: s.prepared, ...(s.source ? { source: s.source } : {}),
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
    portrait_url: /^(https?:\/\/|data:image\/)/i.test(str(j.portrait).trim()) ? str(j.portrait).trim() : '',   // no javascript:, file: or relative URLs
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
    pending_choices: parsePendingChoices(j.pendingChoices),
    ...Object.fromEntries(ABILITIES.map((a) => [a.col, Math.min(30, Math.max(1, int(j.abilities?.[a.key], 10)))])),
    ...Object.fromEntries(['cp', 'sp', 'ep', 'gp', 'pp'].map((k) => [k, Math.max(0, int(j.currency?.[k]))])),
  };

  const trackers = list(j.resources).map((r, i) => ({
    name: str(r.name, 'Resource'), max: Math.max(0, int(r.max, 1)),
    current: Math.max(0, int(r.current ?? r.max, 1)), reset_on: resetKey(r.reset), formula: str(r.formula), sort_order: i,
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
    source: str(s.source),
    sort_order: i,
  }));

  // Inventory entries go through import_inventory_items: an exact catalog match or a homebrew item, never a legacy row.
  // The old "equipped" flag is not imported (equipment slots are chosen in the Inventory tab).
  const inventory = list(j.inventory).map((it) => (typeof it === 'string'
    ? { name: it, quantity: 1 }
    : {
      name: str(it.name, 'Item'), quantity: Math.max(1, int(it.quantity, 1)), weight: Math.max(0, Number(it.weight) || 0),
      description: str(it.description),
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

  const lineage = j.lineage && typeof j.lineage === 'object' && typeof j.lineage.version === 'string'
    ? { version: j.lineage.version, subversion: typeof j.lineage.subversion === 'string' ? j.lineage.subversion : null,
        lineageId: typeof j.lineage.lineageId === 'string' ? j.lineage.lineageId : null,
        name: typeof j.lineage.name === 'string' ? j.lineage.name : null,
        choices: j.lineage.choices && typeof j.lineage.choices === 'object' ? j.lineage.choices : {},
        abilityBonusesIncluded: !!j.lineage.abilityBonusesIncluded }
    : null;
  const spellSources = (Array.isArray(j.spellcasting?.sources) ? j.spellcasting.sources : [])
    .filter((s) => s && typeof s.key === 'string' && typeof s.label === 'string');
  const catalogSpells = (Array.isArray(j.catalogSpells) ? j.catalogSpells : [])
    .filter((s) => s && typeof s.spell === 'string' && typeof s.source === 'string');
  const classes = (Array.isArray(j.classes) ? j.classes : [])
    .filter((k) => k && typeof k.classVersion === 'string' && Number.isInteger(k.level) && k.level >= 1 && k.level <= 20);
  const slotState = j.slotState && typeof j.slotState === 'object' ? j.slotState : null;
  const characterResources = (Array.isArray(j.characterResources) ? j.characterResources : [])
    .filter((r) => r && typeof r.key === 'string' && typeof r.name === 'string');
  const classFeatures = j.classFeatures && typeof j.classFeatures === 'object' ? {
    choices: Array.isArray(j.classFeatures.choices) ? j.classFeatures.choices : [],
    optionalFeatures: Array.isArray(j.classFeatures.optionalFeatures) ? j.classFeatures.optionalFeatures : [],
    resources: Array.isArray(j.classFeatures.resources) ? j.classFeatures.resources : [],
  } : null;
  const companions = (Array.isArray(j.companions) ? j.companions : [])
    .filter((x) => x && typeof x.name === 'string' && x.name.trim())
    .map((x) => ({ creature: typeof x.creature === 'string' ? x.creature : null, name: x.name.trim().slice(0, 80),
      source: typeof x.source === 'string' ? x.source.slice(0, 120) : null, hpMax: Number.isInteger(x.hpMax) ? x.hpMax : null,
      hpCurrent: Number.isInteger(x.hpCurrent) ? x.hpCurrent : null, notes: typeof x.notes === 'string' ? x.notes.slice(0, 2000) : null,
      active: x.active !== false }));
  const bv = j.backgroundVersion;
  const backgroundVersion = bv && typeof bv === 'object' && typeof bv.version === 'string' ? {
    version: bv.version, ability: bv.ability && typeof bv.ability === 'object' ? bv.ability : null, bonusesIncluded: !!bv.bonusesIncluded,
    choices: bv.choices && typeof bv.choices === 'object' ? bv.choices : {}, replacements: Array.isArray(bv.replacements) ? bv.replacements : [],
    characteristics: bv.characteristics && typeof bv.characteristics === 'object' ? bv.characteristics : {},
    notes: typeof bv.notes === 'string' ? bv.notes.slice(0, 2000) : '', dmApproved: !!bv.dmApproved } : null;
  // old export (before 2026-10-22): "race" was a copy of the lineage label, not a legacy race; it stays the readable name
  if (lineage && j.lineage.name === undefined) { lineage.name = character.race || null; character.race = ''; }
  return { character, trackers, attacks, features, spells, inventory, slots, notes, lineage, spellSources, catalogSpells, classes,
    slotState, characterResources, classFeatures, companions, backgroundVersion,
    feats: (Array.isArray(j.feats) ? j.feats : []).filter((f) => f && typeof f.version === 'string').slice(0, 100).map((f) => ({
      feat_version_id: f.version, feat_name: typeof f.name === 'string' ? f.name.slice(0, 200) : null,
      source_type: ['background', 'lineage', 'class'].includes(f.sourceType) ? f.sourceType : 'direct',
      source_label: typeof f.sourceLabel === 'string' ? f.sourceLabel.slice(0, 200) : null,
      grant_key: typeof f.grantKey === 'string' ? f.grantKey.slice(0, 200) : null,
      choices: f.choices && typeof f.choices === 'object' && !Array.isArray(f.choices) ? f.choices : {},
      notes: typeof f.notes === 'string' ? f.notes.slice(0, 2000) : null })),
    wildShape: j.wildShape && typeof j.wildShape === 'object' ? {
      seen: (Array.isArray(j.wildShape.seen) ? j.wildShape.seen : []).filter((x) => x && typeof x.creature === 'string').slice(0, 300),
      favorites: (Array.isArray(j.wildShape.favorites) ? j.wildShape.favorites : []).filter((x) => typeof x === 'string').slice(0, 300),
      settings: j.wildShape.settings && typeof j.wildShape.settings === 'object' ? j.wildShape.settings : null,
      active: j.wildShape.active && typeof j.wildShape.active === 'object' ? j.wildShape.active : null } : null };
}

let lastReport = null;
/** What the last import could not restore exactly (class feature choices, resources). */
export const getLastImportReport = () => lastReport;

/** Create a new character from JSON. Returns the new character id; details of the class feature import: getLastImportReport(). */
export async function importCharacter(json, ownerId, campaignId) {
  lastReport = null;
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
  for (const [level, s] of Object.entries(p.slots)) {
    ops.push(supabase.from('spell_slots').update(s).eq('character_id', c.id).eq('level', Number(level)));
  }
  for (const [kind, content] of Object.entries(p.notes)) {
    if (content) ops.push(supabase.from('notes').update({ content }).eq('character_id', c.id).eq('kind', kind));
  }
  // the core rows (sheet, attacks, features, spells, slots, notes, inventory) are all-or-nothing: when one of them fails, the
  // half-imported character is removed again, so a failed import never leaves a partial character behind (V6.2)
  try {
    const results = await Promise.all(ops);
    const failed = results.find((r) => r.error);
    if (failed) throw failed.error;
    if (p.inventory.length) await importInventoryItems(c.id, p.inventory);
  } catch (err) {
    const { error: undo } = await supabase.from('characters').delete().eq('id', c.id);
    if (undo) console.error('[import] the partial character could not be removed:', undo.message);
    throw Object.assign(new Error(`Import failed: ${friendlyError(err, 'the file could not be saved')}. ${undo
      ? 'A partial character may remain; delete it from the home screen.' : 'Nothing was imported.'}`), { raw: err });
  }
  const warnings = [];
  if (p.lineage) {
    // 1. the exact lineage version. Nothing else is tried automatically: another version, a guessed mapping or the plain
    // text would change the mechanics. An unknown version (a newer catalog, a custom lineage of another campaign) or a
    // refused one (campaign rules) is kept as unresolved legacy text, with a warning, for the player or DM to review.
    try {
      await setCharacterLineage(c.id, { version: p.lineage.version, subversion: p.lineage.subversion, choices: p.lineage.choices,
        abilityBonusesIncluded: p.lineage.abilityBonusesIncluded });
    } catch (err) {
      console.warn('[import] lineage not applied:', err?.message || err);
      const text = p.character.race || p.lineage.name || p.lineage.version;
      if (!p.character.race && text) await supabase.from('characters').update({ race: text }).eq('id', c.id);
      warnings.push({ code: 'lineage_unresolved', message: `Lineage "${text}" could not be applied (${err?.message || 'unknown version'}); kept as legacy race text: choose the lineage on Build` });
    }
  } else if (p.character.race) {
    warnings.push({ code: 'legacy_race', message: `Race "${p.character.race}" is old free text: it is kept but not mapped to a lineage; choose the lineage on Build` });
  }
  if (p.backgroundVersion) {
    // best effort: an unknown version (a file from a newer catalog) keeps the plain background text
    const b = p.backgroundVersion;
    try {
      await setCharacterBackground(c.id, b.version, { ability: b.ability, choices: b.choices, replacements: b.replacements,
        options: { bonuses_included: b.bonusesIncluded, allow_playtest: b.dmApproved, characteristics: b.characteristics, notes: b.notes } });
    } catch (err) {
      console.warn('[import] background not applied:', err?.message || err);
    }
  }
  // classes next: each spellcasting class creates its own linked source; an unknown class version keeps the legacy class text
  const classRows = {};
  const classSources = {};
  const classAccess = {};   // linked source id -> what its class can take now (checked before asking the server)
  for (const k of p.classes) {
    try {
      await setCharacterClass(c.id, { version: k.classVersion, level: k.level, subclass: k.subclassVersion || null,
        primary: k.primary ? true : null, notes: k.notes || null });
    } catch (err) {
      console.warn('[import] class not added:', k.classVersion, err?.message || err);
    }
  }
  if (p.classes.length) {
    try {
      const summary = await getClassSummary(c.id);
      for (const k of p.classes) {
        const row = summary.classes.find((x) => x.class_version_id === k.classVersion);
        if (row && k.key) { classRows[k.key] = row.id; if (row.spellcasting?.source_id) classSources[k.key] = row.spellcasting.source_id; }
        if (row?.spellcasting?.source_id) classAccess[row.spellcasting.source_id] = { cls: row.class_name, level: row.level, sc: row.spellcasting };
      }
    } catch (err) { console.warn('[import] class summary not read:', err?.message || err); }
  }
  // spellcasting sources (new ids; a class source reuses the source its class created), then the catalog spells per source
  const sourceIds = {};
  for (const s of p.spellSources) {
    if (s.classKey && classSources[s.classKey]) { sourceIds[s.key] = classSources[s.classKey]; continue; }
    try {
      const saved = await saveSpellcastingSource(c.id, {
        source_type: s.type, label: s.label, class_version_id: s.classVersion || null, spell_list_id: s.spellList || null,
        casting_ability: s.castingAbility || null, allowed_abilities: Array.isArray(s.allowedAbilities) ? s.allowedAbilities : [],
        fixed_dc: s.fixedDc ?? null, fixed_attack_bonus: s.fixedAttackBonus ?? null, dc_bonus: s.dcBonus || 0, attack_bonus: s.attackBonus || 0,
        preparation_mode: s.preparationMode || null, ritual_mode: s.ritualMode || null, uses_spell_slots: s.usesSpellSlots !== false,
        class_level: s.classLevel ?? null, enforce_spell_list: false, always_prepared_allowed: !!s.alwaysPreparedAllowed, notes: s.notes || null,
      });
      sourceIds[s.key] = saved.id;
    } catch (err) {
      console.warn('[import] spellcasting source not created:', s.label, err?.message || err);
    }
  }
  const unresolved = [];
  for (const g of p.catalogSpells) {
    const sid = sourceIds[g.source];
    try {
      if (!sid) throw new Error('its source was not imported');
      const acc = classAccess[sid];
      const lvl = int(g.level, 0);
      if (acc && (!acc.sc.active || (lvl > 0 && !(acc.sc.max_spell_level >= lvl)) || (lvl === 0 && acc.sc.cantrips_known == null))) {
        throw new Error(`a level ${acc.level} ${acc.cls} cannot take a level ${lvl} spell`);
      }
      const grant = { source: sid, spell: g.spell, known: !!g.known, prepared: !!g.prepared,
        alwaysPrepared: !!g.alwaysPrepared, castingAbility: g.castingAbility || null, notes: g.notes || null };
      try {
        await setCharacterSpell(c.id, grant);
      } catch (err) {
        // over a class's prepared limit: keep the spell, unprepared (the player decides what to prepare)
        if (!grant.prepared || !/can prepare/.test(err?.message || '')) throw err;
        await setCharacterSpell(c.id, { ...grant, prepared: false, known: true });
      }
    } catch (err) {
      unresolved.push({ character_id: c.id, name: str(g.name || g.spell).slice(0, 200) || 'Unknown spell', level: Math.min(9, Math.max(0, int(g.level, 0))),
        description: `Imported catalog spell "${g.spell}" could not be restored (${err?.message || err}).`, source: 'Import' });
    }
  }
  // unresolved catalog spells are kept as free-text spells instead of being dropped
  if (unresolved.length) {
    const { error: e2 } = await supabase.from('spells').insert(unresolved);
    if (e2) console.warn('[import] unresolved spells not kept:', e2.message);
  }
  // generic resources and slot usage (best effort; maximums come from the classes)
  // a lineage counter (Hungry Jaws, ...) already exists: the restored lineage created it; only its used count is carried over
  const { data: existing } = await supabase.from('character_resources').select('id, resource_key').eq('character_id', c.id).eq('source_type', 'lineage');
  const lineageIds = Object.fromEntries((existing || []).map((x) => [x.resource_key, x.id]));
  for (const r of p.characterResources) {
    if (r.sourceType === 'lineage') {
      try { if (lineageIds[r.key] && r.expended > 0) await changeResource(lineageIds[r.key], r.expended, 'Imported from JSON'); }
      catch (err) { console.warn('[import] lineage counter use not restored:', r.name, err?.message || err); }
      continue;
    }
    try {
      const saved = await saveResource(c.id, {
        resource_key: r.key, name: r.name, source_type: r.sourceType || 'manual', source_id: r.sourceId || null,
        character_class_id: (r.classKey && classRows[r.classKey]) || null, max_formula: r.maxFormula || { fixed: 1 }, die: r.die || null,
        recharge: r.recharge || 'long_rest', unlock_level: r.unlockLevel ?? null, spell_version_id: r.spellVersion || null,
        cast_level: r.castLevel ?? null, active: r.active !== false, notes: r.notes || null,
      });
      if (r.expended > 0) await changeResource(saved.id, r.expended, 'Imported from JSON');
    } catch (err) { console.warn('[import] resource not restored:', r.name, err?.message || err); }
  }
  if (p.slotState && p.classes.length) {
    for (const [lvl, n] of Object.entries(p.slotState.standard || {})) {
      try { if (int(n, 0) > 0) await setSlotState(c.id, 'standard', Number(lvl), int(n, 0), 'Imported from JSON'); }
      catch (err) { console.warn('[import] slot usage not restored:', lvl, err?.message || err); }
    }
    if (int(p.slotState.pact, 0) > 0) {
      try { await setSlotState(c.id, 'pact', null, int(p.slotState.pact, 0), 'Imported from JSON'); }
      catch (err) { console.warn('[import] Pact slot usage not restored:', err?.message || err); }
    }
  }
  // class feature choices, optional features and resource state: resolved on the server (stable ids, clamping, report)
  if (p.classFeatures && p.classes.length) {
    try {
      lastReport = await importClassFeatures(c.id, { ...p.classFeatures, classRows });
      // entries that could not be resolved are kept visibly as pending choices (never dropped silently)
      const pending = (lastReport.unresolved || []).map((u, i) => ({
        id: `imported-class-feature-${i + 1}`, type: 'Imported class feature (review)',
        description: `${u.kind}: ${u.entry?.unlock || u.entry?.resource || ''}${u.entry?.choice ? ` / ${u.entry.choice}` : ''} — ${u.reason}`,
        options: (u.entry?.values || []).map(String),
      }));
      if (pending.length) {
        await supabase.from('characters').update({ pending_choices: [...(p.character.pending_choices || []), ...pending] }).eq('id', c.id);
      }
    } catch (err) {
      console.warn('[import] class features not restored:', err?.message || err);
      lastReport = { error: err?.message || String(err), unresolved: [], warnings: [] };
    }
  }
  // feats after classes, background and lineage, so the grants of an ASI, background or lineage exist; unknown or custom
  // versions that are not visible stay in the report (an import never creates a feat)
  if (p.feats.length) {
    try {
      const r = await importFeats(c.id, p.feats);
      lastReport = { ...(lastReport || { unresolved: [], warnings: [] }), feats: r.report || [] };
    } catch (err) { console.warn('[import] feats not restored:', err?.message || err); }
  }
  // Wild Shape: seen forms (a DM grant becomes "seen" with a note: only a DM can grant), favorites, settings (never
  // "unrestricted", which is the DM's); an active form is not restored (warning only)
  if (p.wildShape) {
    const w = p.wildShape;
    const unknown = [];
    for (const x of w.seen) {
      const r = await supabase.rpc('set_seen_forms', { p_character: c.id, p_creatures: [x.creature], p_seen: true, p_source: 'seen',
        p_note: x.source === 'dm_grant' ? 'imported DM grant: ask your DM to grant it again' : 'imported' });
      if (r.error) unknown.push(x.creature);
    }
    for (const id of w.favorites) {
      const r = await supabase.rpc('set_form_favorite', { p_character: c.id, p_creature: id, p_favorite: true });
      if (r.error) unknown.push(id);
    }
    if (w.settings) {
      await supabase.rpc('set_wild_shape_settings', { p_character: c.id,
        p_seen_mode: ['enforce', 'warn'].includes(w.settings.seenMode) ? w.settings.seenMode : null,
        p_default_equipment: ['merge', 'drop', 'wear'].includes(w.settings.defaultEquipment) ? w.settings.defaultEquipment : null,
        p_confirm_lethal: typeof w.settings.confirmLethal === 'boolean' ? w.settings.confirmLethal : null });
    }
    if (unknown.length) console.warn('[import] Wild Shape: unknown creatures kept out:', unknown.join(', '));
    if (w.active) console.warn(`[import] Wild Shape: the file was exported in the form "${w.active.creature}"; it is imported in normal form (take the form again in the app).`);
  }
  // companions: through the companion RPCs (a catalog creature that no longer exists becomes a custom companion)
  for (const x of p.companions || []) {
    try {
      let id;
      const custom = { p_character: c.id, p_creature: null, p_name: x.name, p_source: x.source, p_hp_max: x.hpMax || 1 };
      const first = await supabase.rpc('add_character_companion', x.creature ? { ...custom, p_creature: x.creature, p_hp_max: x.hpMax } : custom);
      if (first.error && x.creature) {
        const again = await supabase.rpc('add_character_companion', custom);
        if (again.error) throw again.error;
        id = again.data;
      } else if (first.error) throw first.error; else id = first.data;
      await supabase.rpc('update_character_companion', { p_companion: id, p_patch: { hp_current: x.hpCurrent ?? x.hpMax, notes: x.notes, active: x.active } });
    } catch (err) { console.warn('[import] companion not restored:', x.name, err?.message || err); }
  }
  if (warnings.length) lastReport = { unresolved: [], ...(lastReport || {}), warnings: [...(lastReport?.warnings || []), ...warnings] };
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
