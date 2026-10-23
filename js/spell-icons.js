// The one spell-icon rule (docs/SPELL_VISUAL_SYSTEM.md, docs/SPELL_ICON_COVERAGE.md). Every spell view uses resolveSpellIcon():
// spellbook cards, the catalog picker, the details dialog and the DM custom spell preview.
//
//   spell school -> that school's icon (spell.school.<school>); school missing or unknown -> the generic spell icon
//
// Damage, healing and other effects never choose the primary icon: damage types are shown as colored chips next to it.
// spellDamage() reads the structured damage (effect rows: spell_effects.damage_mode single / simultaneous / choice; or, where
// a view has no effect rows (the catalog), the spell's damage-type links: relation always / choice) for those chips and texts.
import { esc } from './utils.js?v=10';
import { icon, resolveIcon } from './icons.js?v=10';

const SCHOOLS = ['abjuration', 'conjuration', 'divination', 'enchantment', 'evocation', 'illusion', 'necromancy', 'transmutation'];
const cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : '');
const typeId = (d) => String((d && typeof d === 'object' ? d.id || d.damage_type_id : d) || '').toLowerCase();
const uniq = (a) => [...new Set(a.filter(Boolean))];

/** Damage types and their relationship, from effect rows (preferred) or the damage-type links. */
export function spellDamage(s) {
  const rows = (s?.effects || []).filter((e) => e.category === 'damage' && (e.damage_types || []).length);
  if (rows.length) {
    const types = uniq(rows.flatMap((e) => e.damage_types.map(typeId)));
    const modes = uniq(rows.map((e) => e.damage_mode || 'single'));
    if (types.length === 1) return { types, relation: 'single', source: 'effects' };
    if (modes.length === 1 && modes[0] === 'simultaneous') return { types, relation: 'multiple', source: 'effects' };
    if (modes.length === 1 && modes[0] === 'choice' && rows.length === 1) return { types, relation: 'choose', source: 'effects' };
    return { types, relation: 'ambiguous', source: 'effects' };   // separate rows with different types, or a mix of modes
  }
  const links = (s?.damage_types || []).map((d) => ({ id: typeId(d), choice: !!(d && typeof d === 'object' && d.relation === 'choice') }))
    .filter((d) => d.id);
  if (links.length) {
    const types = uniq(links.map((d) => d.id));
    const choice = s.damage_choice === true || links.some((d) => d.choice);
    const always = s.damage_choice === true ? [] : links.filter((d) => !d.choice);
    if (types.length === 1) return { types, relation: 'single', source: 'links' };
    if (choice && !always.length) return { types, relation: 'choose', source: 'links' };
    return { types, relation: 'ambiguous', source: 'links' };     // "always" links do not say whether they are dealt together
  }
  return { types: [], relation: 'none', source: 'none' };
}

const schoolKey = (s) => {
  const id = String(s?.school_id || s?.school || '').toLowerCase();
  return SCHOOLS.includes(id) ? id : null;
};

/**
 * Primary icon of a spell, from its school only. Returns { key, requested, school, label, coverage: 'direct'|'fallback' }.
 * key is what is drawn: the school icon, or the generic spell icon when the school is unresolved or its asset is not registered.
 */
export function resolveSpellIcon(s) {
  const school = schoolKey(s);
  const key = school ? `spell.school.${school}` : 'spell.school.generic';
  const r = resolveIcon(key);
  return {
    key: r.key, requested: key, school,
    label: school ? `${cap(school)} school` : 'Spell (school not resolved)',
    coverage: school && r.key === key ? 'direct' : 'fallback',
  };
}

/** The primary icon as an <img> with an accessible label (the school is also in the school badge as text). */
export function spellIconHTML(s, { size = 34, cls = 'sp-icon' } = {}) {
  const r = resolveSpellIcon(s);
  return icon(r.key, { size, cls, label: r.label }).replace('<img ', `<img data-spell-icon="${esc(r.school || 'generic')}" `);
}
