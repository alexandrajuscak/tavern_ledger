// Spells tab: spellcasting sources (per-source Save DC / attack), the resolved spellbook, spell details, Add Spell and the
// source editor. Data-driven: sources, grants, lists and stats come from get_character_spellbook; class levels, spell access
// and limits of class sources come from get_character_class_summary. Nothing here calculates class rules.
import { $, $$, esc, toast, openModal, confirmDialog, filtersOpenAttr } from './utils.js?v=12';
import * as api from './spell-api.js?v=12';
import { catalogOrExplain } from './catalog-load.js?v=12';
import { icon } from './icons.js?v=12';
import { spellIconHTML, spellDamage } from './spell-icons.js?v=12';

const ABILITY = { str: 'Strength', dex: 'Dexterity', con: 'Constitution', int: 'Intelligence', wis: 'Wisdom', cha: 'Charisma' };
const SOURCE_TYPE = { class: 'Class', subclass: 'Subclass', feat: 'Feat', item: 'Magic item', manual: 'Manual',
  other: 'Other feature', lineage: 'Lineage', class_feature: 'Class feature' };
const PREP = { prepared: 'Prepares spells', known: 'Knows spells', spellbook: 'Spellbook', innate: 'Innate', none: 'No preparation' };
const RITUAL = { none: 'No ritual casting', prepared: 'Rituals if prepared', known: 'Rituals if known', spellbook: 'Rituals from spellbook' };
const RECHARGE = { short_rest: 'short rest', long_rest: 'long rest', short_or_long_rest: 'short or long rest' };
const AUTOMATION = { automated: 'Automated', partially_automated: 'Dice and DC shown', informational: 'Information only', unresolved: 'Unresolved' };
const ordinal = (n) => `${n}${n === 1 ? 'st' : n === 2 ? 'nd' : n === 3 ? 'rd' : 'th'}`;
/** Class entry (get_character_class_summary) whose spellcasting source is `sourceId`. */
const classOf = (classes, sourceId) => (classes || []).find((k) => k.spellcasting?.source_id === sourceId) || null;

/** Class level, spell access and limits of a class-linked source, with over-limit warnings (nothing is removed). */
function classSourceHTML(k) {
  const sc = k.spellcasting;
  if (!sc.active) return `<p class="small sp-warn">${esc(k.class_name)} spellcasting starts at level ${esc(sc.start_level)}.</p>`;
  const lim = (label, n, max, over) => (max == null ? '' : `<span class="${over ? 'sp-warn' : ''}">${esc(label)} ${n} / ${max}</span>`);
  const parts = [lim('Cantrips', sc.counts.cantrips, sc.cantrips_known, sc.over_limit.cantrips),
    lim('Known', sc.counts.known, sc.spells_known, sc.over_limit.known),
    lim('Prepared', sc.counts.prepared, sc.prepared_limit, sc.over_limit.prepared)].filter(Boolean);
  const above = sc.spells_above_max_level || [];
  return `<p class="small" data-class-source="${esc(k.class_id)}">${esc(k.class_name)} level ${k.level} ·
      ${sc.max_spell_level ? `spells up to ${ordinal(sc.max_spell_level)} level` : 'no leveled spells yet'}${sc.pact_magic ? ' (Pact slot level)' : ''}</p>
    ${parts.length ? `<p class="small sp-limits">${parts.join(' · ')}</p>` : ''}
    ${sc.over_limit.prepared ? '<p class="small sp-warn">Over the prepared limit: unprepare spells before preparing more.</p>' : ''}
    ${above.length ? `<p class="small sp-warn">Above your ${esc(k.class_name)} spell level: ${above.map((x) => esc(x.name)).join(', ')} (review; nothing was removed).</p>` : ''}`;
}
const fmt = (n) => (n == null ? '—' : n >= 0 ? `+${n}` : `−${Math.abs(n)}`);
const ord = (n) => `${n}${n === 1 ? 'st' : n === 2 ? 'nd' : n === 3 ? 'rd' : 'th'}`;
export const levelLabel = (l) => (l === 0 ? 'Cantrip' : `${ord(l)} level`);
const cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : '');

// ---------------------------------------------------------------------------------------------------------- filters
export const emptyFilters = () => ({ q: '', level: '', school: '', list: '', ritual: false, conc: false, damage: '', status: '',
  comp: '', source: '', state: '' });

const ids = (arr, key) => (arr || []).map((x) => (typeof x === 'object' ? x[key] : x));

/** Shared filter logic for catalog rows (v_spell_catalog) and spellbook spells (_spell_summary + grants). */
export function matchSpell(s, f) {
  if (f.q && !s.name.toLowerCase().includes(f.q.trim().toLowerCase())) return false;
  if (f.level !== '' && String(s.level) !== String(f.level)) return false;
  if (f.school && s.school_id !== f.school) return false;
  if (f.list && !ids(s.class_lists, 'list_id').includes(f.list)) return false;
  if (f.ritual && !s.ritual) return false;
  if (f.conc && !s.concentration) return false;
  if (f.damage && !ids(s.damage_types, 'id').includes(f.damage)) return false;
  if (f.status === 'official' && !(s.rule_status === 'official' && s.status === 'current' && !s.setting)) return false;
  if (f.status === 'legacy' && s.status !== 'legacy') return false;
  if (f.status === 'playtest' && s.rule_status !== 'playtest') return false;
  if (f.status === 'setting' && !s.setting) return false;
  if (f.status === 'homebrew' && s.scope === 'official') return false;
  if (f.comp === 'V' && !s.verbal) return false;
  if (f.comp === 'S' && !s.somatic) return false;
  if (f.comp === 'M' && !s.material) return false;
  if (f.comp === 'costly' && !s.material_cost_gp) return false;
  if (f.comp === 'consumed' && !s.material_consumed) return false;
  if (f.source && !(s.grants || []).some((g) => g.source_type === f.source)) return false;
  if (f.state === 'known' && !s.known) return false;
  if (f.state === 'prepared' && !s.prepared) return false;
  if (f.state === 'always' && !s.always_prepared) return false;
  if (f.state === 'innate' && !s.innate) return false;
  return true;
}

/** Filter controls; `book` adds the source / state filters of the character spellbook. */
export function filtersHTML(f, ref, { book = false, prefix = 'sf' } = {}) {
  const opt = (v, label, cur) => `<option value="${esc(v)}" ${String(cur) === String(v) ? 'selected' : ''}>${esc(label)}</option>`;
  const sel = (name, label, options) => `<label class="field sp-filter"><span>${label}</span><select data-${prefix}="${name}">${options}</select></label>`;
  return `<div class="sp-filters" role="group" aria-label="Spell filters">
    <label class="field sp-filter sp-search"><span>Search</span><input type="search" data-${prefix}="q" value="${esc(f.q)}" placeholder="Spell name" autocomplete="off"></label>
    <details class="filter-more" ${filtersOpenAttr()}><summary>Filters</summary><div class="filter-more-body">
    ${sel('level', 'Level', opt('', 'Any', f.level) + Array.from({ length: 10 }, (_, l) => opt(l, levelLabel(l), f.level)).join(''))}
    ${sel('school', 'School', opt('', 'Any', f.school) + ref.schools.map((s) => opt(s.id, s.name, f.school)).join(''))}
    ${sel('list', 'Class list', opt('', 'Any', f.list) + ref.lists.map((l) => opt(l.id, l.name, f.list)).join(''))}
    ${sel('damage', 'Damage type', opt('', 'Any', f.damage) + ref.damageTypes.map((d) => opt(d.id, d.name, f.damage)).join(''))}
    ${sel('status', 'Status', opt('', 'Any', f.status) + opt('official', 'Official, current', f.status) + opt('legacy', 'Legacy', f.status)
      + opt('playtest', 'Playtest (UA)', f.status) + opt('setting', 'Setting-specific', f.status) + opt('homebrew', 'Homebrew', f.status))}
    ${sel('comp', 'Components', opt('', 'Any', f.comp) + opt('V', 'Verbal', f.comp) + opt('S', 'Somatic', f.comp) + opt('M', 'Material', f.comp)
      + opt('costly', 'Costly material', f.comp) + opt('consumed', 'Consumed material', f.comp))}
    ${book ? sel('source', 'Source', opt('', 'Any', f.source) + Object.entries(SOURCE_TYPE).map(([k, v]) => opt(k, v, f.source)).join('')) : ''}
    ${book ? sel('state', 'State', opt('', 'Any', f.state) + opt('known', 'Known', f.state) + opt('prepared', 'Prepared', f.state)
      + opt('always', 'Always prepared', f.state) + opt('innate', 'Innate', f.state)) : ''}
    <label class="check-field"><input type="checkbox" data-${prefix}="ritual" ${f.ritual ? 'checked' : ''}><span>Ritual</span></label>
    <label class="check-field"><input type="checkbox" data-${prefix}="conc" ${f.conc ? 'checked' : ''}><span>Concentration</span></label>
    </div></details>
  </div>`;
}

export function readFilter(el, f) {
  const k = el.dataset.sf || el.dataset.cf;
  if (!k) return false;
  f[k] = el.type === 'checkbox' ? el.checked : el.value;
  return true;
}

// ---------------------------------------------------------------------------------------------------------- badges
function statusBadges(s) {
  const b = [];
  if (s.rule_status === 'playtest') b.push('<span class="sp-badge sp-playtest">Playtest (UA)</span>');
  if (s.rule_status === 'homebrew' || (s.scope && s.scope !== 'official')) b.push('<span class="sp-badge">Homebrew</span>');
  if (s.status === 'legacy') b.push('<span class="sp-badge">Legacy</span>');
  if (s.setting) b.push(`<span class="sp-badge">${esc(s.setting)}</span>`);
  if (s.source_marker) b.push(`<span class="sp-badge">${esc(cap(s.source_marker))}</span>`);
  return b.join(' ');
}

const UNIT = { action: 'action', bonus_action: 'bonus action', reaction: 'reaction', minute: 'minute', hour: 'hour' };
/** "1 reaction" instead of the full trigger text (the trigger is in the details). */
const castShort = (s) => (s.casting_time_unit && s.casting_time_unit !== 'special' && s.casting_time_amount
  ? `${s.casting_time_amount} ${UNIT[s.casting_time_unit]}${s.casting_time_amount > 1 ? 's' : ''}` : s.casting_time);
const componentText = (s) => [s.verbal && 'V', s.somatic && 'S', s.material && 'M'].filter(Boolean).join(', ')
  + (s.material_cost_gp ? ` (${s.material_cost_gp} gp${s.material_consumed ? ', consumed' : ''})` : '');

function grantBadge(g) {
  const st = g.source_type;
  return `<span class="sp-src sp-src-${esc(st)}" title="${esc(g.source_label)}">${esc(SOURCE_TYPE[st] || st)}${st === 'lineage' ? '' : `: ${esc(g.source_label)}`}</span>`;
}

/** Save DC / attack bonus line for a spell: the first unlocked grant with stats decides; every grant is in the details. */
function mainStat(s) {
  const g = s.grants.find((x) => x.stats?.save_dc != null || x.stats?.attack_bonus != null);
  if (!g) return s.grants.some((x) => x.ability_needed) ? '<span class="muted small">Choose a spellcasting ability on the Build tab</span>' : '';
  const parts = [];
  if (['save', 'multiple'].includes(s.mechanism) && g.stats.save_dc != null) parts.push(`DC ${g.stats.save_dc}${s.save_ability ? ` ${s.save_ability.toUpperCase()}` : ''}`);
  if (['attack', 'multiple'].includes(s.mechanism) && g.stats.attack_bonus != null) parts.push(`${fmt(g.stats.attack_bonus)} to hit`);
  return parts.length ? `<span class="sp-stat">${parts.join(' · ')}</span>` : '';
}

function damageSummary(s) {
  return (s.effects || []).map((e) => {
    const types = (e.damage_types || []).join(e.damage_mode === 'choice' ? ' / ' : ', ');
    const what = e.category === 'damage' ? `${e.dice || ''}${e.flat_modifier ? ` + ${e.flat_modifier}` : ''} ${types}${e.damage_mode === 'choice' ? ' (choose one)' : ''}`
      : e.category === 'healing' ? `heal ${e.dice || e.flat_modifier}${e.adds_spell_mod ? ' + ability modifier' : ''}`
        : e.category === 'temp_hp' ? `${e.dice || e.flat_modifier} temporary HP` : e.category;
    const sc = e.scaling_type === 'slot_level' ? ` (+${e.scaling_dice} per slot above ${ord(e.scaling_base)})`
      : e.scaling_type === 'character_level' ? ` (+${e.scaling_dice} at 5th, 11th, 17th level)` : '';
    return esc(what.trim() + sc);
  }).join('; ');
}

// ---------------------------------------------------------------------------------------------------------- sources
function statRows(st, { compact = false } = {}) {
  if (!st || (st.save_dc == null && st.attack_bonus == null)) return '<p class="muted small">No spellcasting ability set for this source.</p>';
  const rows = [];
  if (st.fixed_dc == null && st.ability) rows.push([`${ABILITY[st.ability]} modifier`, fmt(st.ability_modifier)]);
  if (st.fixed_dc == null && st.ability) rows.push(['Proficiency bonus', fmt(st.proficiency_bonus)]);
  (st.dc_breakdown || []).filter((p) => p.part === 'bonus').forEach((p) => rows.push(['Save DC bonus', fmt(p.value)]));
  if (st.fixed_dc != null) rows.push(['Fixed Save DC', String(st.fixed_dc)]);
  rows.push(['Spell Save DC', st.save_dc == null ? '—' : String(st.save_dc)]);
  if (st.fixed_attack_bonus != null) rows.push(['Fixed attack bonus', fmt(st.fixed_attack_bonus)]);
  rows.push(['Spell Attack Bonus', fmt(st.attack_bonus)]);
  return `<table class="sp-stats${compact ? ' compact' : ''}"><tbody>${rows.map(([k, v], i) => `<tr class="${i >= rows.length - 2 ? 'sp-total' : ''}">
    <th scope="row">${esc(k)}</th><td>${esc(v)}</td></tr>`).join('')}</tbody></table>`;
}

const ACQ = { starting: 'starting spells', level_up: 'from level-ups', copied: 'copied', scroll: 'from scrolls', feature: 'from features',
  other: 'other', unrecorded: 'not recorded' };

/** Spellbook line of a spellbook source (Wizard): spells in the book, free spells for the class level, how they got there. */
function spellbookSummary(sb) {
  if (!sb) return '';
  const acq = Object.entries(sb.by_acquisition || {}).map(([k, n]) => `${n} ${ACQ[k] || k}`).join(', ');
  return `<p class="small" data-spellbook-summary><strong>Spellbook:</strong> ${sb.spells} spell${sb.spells === 1 ? '' : 's'}${
    sb.free_expected != null ? ` (${sb.free_expected} free by your level)` : ''} · ${sb.prepared} prepared${acq ? ` · ${esc(acq)}` : ''}</p>`;
}

/** The Spellcasting summary: one compact card per source (stored sources and the lineage) with its own DC and attack bonus;
 *  the calculation is behind "How it is calculated". */
export function sourcesHTML(book, { editable = true, classes = [] } = {}) {
  if (!book) return '<p class="muted small">Loading…</p>';
  if (!book.sources.length) {
    return `<p class="muted small">No spellcasting source yet. Lineage spells appear here automatically; add a source for class,
      feat, item or manual spells.</p>`;
  }
  return `<div class="sp-sources">${book.sources.map((s) => { const k = classOf(classes, s.id); const st = s.stats || {}; return `
    <section class="sp-source" data-source-key="${esc(s.key)}">
      <div class="sp-source-head">
        <h3 class="sp-source-title">${esc(s.label)}</h3>
        <span class="sp-src sp-src-${esc(s.source_type)}">${esc(k ? 'Class' : SOURCE_TYPE[s.source_type] || s.source_type)}</span>
        ${s.is_preview ? '<span class="sp-badge" title="Not linked to a class on the Build tab: levels and limits are not checked">Preview</span>' : ''}
      </div>
      <div class="sp-source-stats" data-source-stats>
        <span><span class="stat-label">Save DC</span> <strong class="sp-big">${st.save_dc ?? '—'}</strong></span>
        <span><span class="stat-label">Attack</span> <strong class="sp-big">${st.attack_bonus == null ? '—' : fmt(st.attack_bonus)}</strong></span>
        <span class="muted small">${st.ability ? esc(ABILITY[st.ability]) : st.fixed_dc != null ? 'fixed values' : 'no ability'}</span>
      </div>
      ${k ? classSourceHTML(k) : ''}
      ${spellbookSummary(s.spellbook)}
      <p class="muted small">${[PREP[s.preparation_mode], s.ritual_mode && s.ritual_mode !== 'none' ? RITUAL[s.ritual_mode] : '',
        s.counts && !s.spellbook ? `${s.counts.total} spell${s.counts.total === 1 ? '' : 's'}${s.counts.prepared ? `, ${s.counts.prepared} prepared` : ''}${s.counts.always_prepared ? `, ${s.counts.always_prepared} always prepared` : ''}` : '']
        .filter(Boolean).map(esc).join(' · ')}</p>
      <details class="sp-calc"><summary>How it is calculated</summary>${statRows(s.stats)}</details>
      ${editable && s.id ? `<button type="button" class="btn btn-sm" data-action="spell-source-edit" data-source="${esc(s.id)}" data-focus-key="spell-source:${esc(s.id)}">Edit source</button>` : ''}
    </section>`; }).join('')}</div>`;
}

// ---------------------------------------------------------------------------------------------------------- spell visuals
// docs/SPELL_VISUAL_SYSTEM.md: the school owns the card (edge, tint, school badge); damage types are chips (swatch + name);
// meaning is always in text. Colors come from CSS tokens chosen by data attributes, never from inline styles.
const SCHOOL_IDS = ['abjuration', 'conjuration', 'divination', 'enchantment', 'evocation', 'illusion', 'necromancy', 'transmutation'];
const DAMAGE_IDS = ['acid', 'bludgeoning', 'cold', 'fire', 'force', 'lightning', 'necrotic', 'piercing', 'poison', 'psychic', 'radiant',
  'slashing', 'thunder'];
const schoolId = (s) => {
  const id = String(s.school_id || s.school || '').toLowerCase();
  return SCHOOL_IDS.includes(id) ? id : 'none';
};

/** Damage in words for compact rows: " · Fire", " · Bludgeoning + Cold", " · Choose one: Acid, Cold". */
export function damageText(s) {
  const r = spellDamage(s);
  if (!r.types.length) return '';
  const names = r.types.map(cap);
  // "+" only when the data says the types are dealt together; separate effects (ambiguous) are listed with commas
  return esc(r.relation === 'choose' ? ` · Choose one: ${names.join(', ')}` : ` · ${names.join(r.relation === 'multiple' ? ' + ' : ', ')}`);
}

/** School badge: colored marker + school name (the name carries the meaning). */
export function schoolBadgeHTML(s) {
  return `<span class="sp-badge sp-school" data-school="${schoolId(s)}"><span class="sp-swatch" aria-hidden="true"></span>${esc(s.school || 'School not resolved')}</span>`;
}

const dmgChip = (t) => `<span class="dmg-chip" data-dmg="${DAMAGE_IDS.includes(t) ? t : 'none'}"><span class="sp-swatch" aria-hidden="true"></span>${esc(cap(t))}</span>`;
const dmgGroup = (types, choice) => `<span class="dmg-group ${choice ? 'dmg-choice' : 'dmg-both'}" role="group"
    aria-label="${esc(choice ? `Choose one damage type: ${types.map(cap).join(', ')}` : `Deals ${types.map(cap).join(' and ')} damage`)}">${
  choice ? '<span class="dmg-group-label">Choose one</span>' : ''}${types.map(dmgChip).join(`<span class="dmg-sep" aria-hidden="true">${choice ? 'or' : '+'}</span>`)}</span>`;

/**
 * What the spell does, as chips: one chip per damage type; "choose one" types grouped with "or" under a Choose label; types
 * dealt together grouped with "+"; Healing and Temp HP chips. A spell without these gets no damage color at all.
 */
export function effectTagsHTML(s) {
  const out = [];
  const seen = new Set();
  // types dealt together are stored as one effect row per type (damage_mode simultaneous): one "+" group for all of them
  const together = [...new Set((s.effects || []).filter((e) => e.category === 'damage' && e.damage_mode === 'simultaneous')
    .flatMap((e) => e.damage_types || []))];
  if (together.length) {
    out.push(together.length === 1 ? dmgChip(together[0]) : dmgGroup(together, false));
    seen.add('simultaneous');
  }
  for (const e of s.effects || []) {
    const types = e.damage_types || [];
    if (e.category === 'damage' && e.damage_mode === 'simultaneous') continue;
    if (e.category === 'damage' && types.length) {
      const key = `${e.damage_mode}:${types.join(',')}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(types.length === 1 ? dmgChip(types[0]) : dmgGroup(types, e.damage_mode === 'choice'));
    } else if (e.category === 'healing' && !seen.has('healing')) {
      seen.add('healing');
      out.push('<span class="dmg-chip" data-effect="healing"><span class="sp-swatch" aria-hidden="true"></span>Healing</span>');
    } else if (e.category === 'temp_hp' && !seen.has('temp_hp')) {
      seen.add('temp_hp');
      out.push('<span class="dmg-chip" data-effect="temp-hp"><span class="sp-swatch" aria-hidden="true"></span>Temp HP</span>');
    }
  }
  // damage types known without effect rows: still shown as they are, never invented
  if (!out.length && (s.damage_types || []).length) {
    const types = s.damage_types.map((d) => (typeof d === 'object' ? d.id : d));
    const choice = s.damage_types.some((d) => d && d.relation === 'choice');
    out.push(types.length === 1 ? dmgChip(types[0]) : dmgGroup(types, choice));
  }
  return out.join('');
}

/** Can I cast it? The first thing on the card. */
function readiness(s) {
  if (!s.unlocked) return { key: 'locked', text: `From level ${Math.min(...s.grants.map((g) => g.min_level || 1))}` };
  if (s.always_prepared) return { key: 'always', text: 'Always prepared' };
  if (s.prepared) return { key: 'prepared', text: 'Prepared' };
  if (s.level === 0) return { key: 'ready', text: 'Ready' };
  // a prepared caster's spell (or a spellbook spell) that is not prepared cannot be cast yet, even though it is "known"
  const needsPrep = s.grants.some((g) => g.unlocked && ['prepared', 'spellbook'].includes(g.preparation_mode))
    && !s.grants.some((g) => g.unlocked && !['prepared', 'spellbook'].includes(g.preparation_mode));
  if (needsPrep) return { key: 'unprepared', text: 'Not prepared' };
  if (s.innate) return { key: 'ready', text: 'Innate' };
  if (s.known) return { key: 'ready', text: 'Known' };
  return { key: 'unprepared', text: 'Not prepared' };
}

// ---------------------------------------------------------------------------------------------------------- spellbook
function spellCardHTML(s, { editable }) {
  const stored = s.grants.filter((g) => g.character_spell_id);
  const preparable = (g) => ['prepared', 'spellbook'].includes(g.preparation_mode);
  const prepToggle = editable && stored.length === 1 && preparable(stored[0]) && !stored[0].always_prepared && s.level > 0
    ? `<label class="check-field sp-prep"><input type="checkbox" data-action="spell-prepare" data-cs="${esc(stored[0].character_spell_id)}"
         ${stored[0].prepared ? 'checked' : ''} aria-label="Prepared: ${esc(s.name)}"><span>Prepared</span></label>` : '';
  const free = s.grants.find((g) => g.unlocked && g.uses_spell_slot === false && s.level > 0);
  const r = readiness(s);
  const extra = [s.known && r.text !== 'Known' ? 'Known' : '', s.innate && r.text !== 'Innate' ? 'Innate' : '']
    .filter(Boolean).map((t) => `<span class="sp-state">${t}</span>`).join(' ');
  const slot = s.level === 0 ? ''
    : free ? '<span class="sp-badge sp-slot" title="Can be cast without a spell slot (see the details)">No slot</span>'
      : `<span class="sp-badge sp-slot" title="Uses a spell slot of this level or higher">Slot ${esc(ord(s.level))}+</span>`;
  return `<article class="sp-card${s.unlocked ? '' : ' is-locked'}" data-spell="${esc(s.id)}" data-school="${schoolId(s)}" data-ready="${r.key}">
    <div class="sp-card-top">
      ${spellIconHTML(s)}
      <h5 class="sp-card-title"><button type="button" class="btn-link sp-name" data-action="spell-detail" data-spell="${esc(s.id)}" data-focus-key="spell:${esc(s.id)}"
        aria-label="${esc(s.name)}: show details">${esc(s.name)}</button></h5>
      <span class="sp-level">${esc(levelLabel(s.level))}</span>
    </div>
    <div class="sp-tags"><span class="sp-ready" data-ready="${r.key}">${esc(r.text)}</span>${schoolBadgeHTML(s)}${effectTagsHTML(s)}${
      s.concentration ? `<span class="sp-badge sp-conc" title="Concentration: one such spell at a time">${icon('actions/concentration', { size: 14 })}Concentration</span>` : ''}${
      s.ritual ? `<span class="sp-badge sp-ritual" title="Can be cast as a ritual (10 minutes longer, no slot)">${icon('ui/ritual', { size: 14 })}Ritual</span>` : ''}${slot}${statusBadges(s)}</div>
    <p class="sp-meta small">${[castShort(s), s.range, s.duration].filter(Boolean).map(esc).join(' · ')}</p>
    <div class="sp-card-foot">${mainStat(s)} ${prepToggle}</div>
    <p class="sp-sources-line">${s.grants.map(grantBadge).join(' ')} ${extra}</p>
  </article>`;
}

// open / closed state of the spell groups survives re-renders; only the player's own clicks are remembered
const sectionOpen = new Map();
const openIf = (key, dflt) => ((sectionOpen.has(key) ? sectionOpen.get(key) : dflt) ? 'open' : '');
/** Remember the player's open / close of the spell groups (attach once to the mounted sheet). */
export function rememberSpellSections(root) {
  root.addEventListener('click', (e) => {
    const d = e.target.closest('summary')?.parentElement;
    if (d?.tagName === 'DETAILS' && d.dataset.spSection) setTimeout(() => sectionOpen.set(d.dataset.spSection, d.open), 0);
  }, true);
}

/** Ready to cast now: prepared, always prepared, innate, cantrips and spells of sources that cast what they know. */
const isReady = (s) => s.unlocked && (s.always_prepared || s.prepared || s.innate || s.level === 0
  || s.grants.some((g) => g.unlocked && g.known && !['prepared', 'spellbook'].includes(g.preparation_mode)));

function byLevel(list, editable) {
  const levels = [...new Set(list.map((s) => s.level))].sort((a, b) => a - b);
  return levels.map((l) => `<section class="sp-group"><h4 class="sp-group-title">${l === 0 ? 'Cantrips' : `${ord(l)} level`}
      <span class="muted small">${list.filter((s) => s.level === l).length}</span></h4>
    <div class="sp-grid">${list.filter((s) => s.level === l).map((s) => spellCardHTML(s, { editable })).join('')}</div></section>`).join('');
}

/** "Your spells": ready to cast first (by level), then spells in a spellbook or on a list that are not prepared, then spells
 *  that unlock later. Filters apply to every group. */
export function spellbookListHTML(book, f, { editable = true } = {}) {
  if (!book) return '<p class="muted small">Loading…</p>';
  const list = book.spells.filter((s) => matchSpell(s, f));
  const extra = [];
  if (book.unresolved_grants.length) {
    extra.push(`<p class="muted small">Granted but not in the spell catalog: ${book.unresolved_grants.map((u) => esc(u.name)).join(', ')}.</p>`);
  }
  if (!book.spells.length) {
    const sb = book.sources.find((x) => x.spellbook);
    return `<p class="empty">No spells yet. ${sb ? `Your spellbook should hold ${sb.spellbook.free_expected} spells at your level: use <strong>+ Add spell</strong>.`
      : 'Use <strong>+ Add spell</strong>, or choose a lineage with innate spells.'}</p>${extra.join('')}`;
  }
  if (!list.length) return `<p class="empty">No spell matches the filters.</p>${extra.join('')}`;
  const ready = list.filter(isReady);
  const later = list.filter((s) => !s.unlocked);
  const idle = list.filter((s) => s.unlocked && !isReady(s));
  return `<section class="sp-section" data-sp-section="ready"><h3 class="sp-section-title">Ready to cast <span class="muted small">${ready.length}</span></h3>
      ${ready.length ? byLevel(ready, editable) : '<p class="muted small">Nothing prepared yet: tick "Prepared" on a spell below.</p>'}</section>
    ${idle.length ? `<details class="sp-section" data-sp-section="idle" ${openIf('idle', true)}><summary class="sp-section-title">Not prepared
      <span class="muted small">${idle.length} in your spellbook or on your list</span></summary>${byLevel(idle, editable)}</details>` : ''}
    ${later.length ? `<details class="sp-section" data-sp-section="later" ${openIf('later', false)}><summary class="sp-section-title">Not available yet
      <span class="muted small">${later.length} unlock at a higher level</span></summary>${byLevel(later, editable)}</details>` : ''}
    ${extra.join('')}`;
}

// ---------------------------------------------------------------------------------------------------------- details
function grantRow(g, s, editable) {
  const st = g.stats || {};
  const uses = g.uses ? `${g.uses === 'at_will' ? 'at will' : `${g.uses}× per ${RECHARGE[g.recharge] || g.recharge || 'rest'}`}` : '';
  return `<tr>
    <th scope="row">${esc(SOURCE_TYPE[g.source_type] || g.source_type)}<br><span class="muted small">${esc(g.source_label)}</span></th>
    <td>${[g.always_prepared ? 'Always prepared' : g.prepared ? 'Prepared' : '', g.known ? 'Known' : '', g.innate ? 'Innate' : '',
      g.unlocked ? '' : `from level ${g.min_level}`].filter(Boolean).join(', ') || '—'}
      ${uses ? `<br><span class="muted small">${esc(uses)}${g.cast_level ? ` · as level ${esc(g.cast_level)}` : ''}${g.uses_spell_slot ? '' : ' · no slot needed'}</span>` : ''}
      ${g.on_source_list === false ? '<br><span class="sp-warn small">Not on this source’s spell list</span>' : ''}</td>
    <td>${g.casting_ability ? esc(ABILITY[g.casting_ability]) : g.ability_needed ? 'choose on Build tab' : st.fixed_dc != null ? 'fixed' : '—'}</td>
    <td>${st.save_dc ?? '—'}</td><td>${fmt(st.attack_bonus)}</td>
    <td>${editable && g.character_spell_id ? `
      ${['prepared', 'spellbook'].includes(g.preparation_mode) && !g.always_prepared && s.level > 0 ? `<button type="button" class="btn btn-sm" data-grant-prepare="${esc(g.character_spell_id)}" data-on="${g.prepared ? '0' : '1'}">${g.prepared ? 'Unprepare' : 'Prepare'}</button>` : ''}
      <button type="button" class="btn btn-sm btn-bad" data-grant-remove="${esc(g.character_spell_id)}">Remove</button>` : ''}</td>
  </tr>`;
}

const ACQ_CHOICES = { starting: 'Starting spellbook (level 1)', level_up: 'Free spell from a level-up', copied: 'Copied (found or bought)',
  scroll: 'Copied from a scroll', feature: 'Granted by a feature', other: 'Other' };

export async function openSpellDetail(spell, { editable = false, onChanged } = {}) {
  const d = spell.grants ? spell : await api.getSpellDetail(spell.id);
  const book = (d.grants || []).find((g) => g.preparation_mode === 'spellbook' && g.character_spell_id);
  const row = (k, v) => (v ? `<div class="kv"><span>${esc(k)}</span><strong>${v}</strong></div>` : '');
  const m = openModal({
    title: d.name,
    wide: true,
    body: `
      <p class="sp-detail-badges">${spellIconHTML(d, { size: 28, cls: 'sp-detail-icon' })}${schoolBadgeHTML(d)} <span class="sp-badge">${esc(levelLabel(d.level))}</span> ${effectTagsHTML(d)}
        ${d.concentration ? '<span class="sp-badge sp-conc">Concentration</span>' : ''} ${d.ritual ? '<span class="sp-badge sp-ritual">Ritual</span>' : ''} ${statusBadges(d)}</p>
      <div class="kv-list" data-spell-facts>
        ${row('School', esc(d.school))}
        ${row('Casting time', esc(d.casting_time) + (d.reaction_trigger ? ` <span class="muted small">(${esc(d.reaction_trigger)})</span>` : ''))}
        ${row('Range', esc(d.range) + (d.area_shape ? ` <span class="muted small">(${esc(d.area_size)}-ft ${esc(d.area_shape)})</span>` : ''))}
        ${row('Duration', esc(d.duration))}
        ${row('Concentration', d.concentration ? 'Yes' : 'No')}
        ${row('Ritual', d.ritual ? 'Yes' : 'No')}
        ${row('Components', esc(componentText(d)))}
        ${d.material_text ? row('Material', esc(d.material_text)) : ''}
        ${row('Resolution', esc({ attack: 'Spell attack', save: `Saving throw${d.save_ability ? ` (${d.save_ability.toUpperCase()})` : ''}`, automatic: 'Automatic',
          multiple: 'Attack and saving throw', none: 'No roll', check: 'Ability check', unresolved: 'Unresolved' }[d.mechanism] || d.mechanism))}
        ${row('Effects', damageSummary(d) || '<span class="muted">not structured</span>')}
        ${row('Automation', esc(AUTOMATION[d.automation] || d.automation))}
        ${row('Class lists', (d.class_lists || []).map((c) => esc(c.class || c.list_id) + (c.optional ? ' (optional)' : '')).join(', ') || '—')}
        ${row('Source', `<a href="${esc(d.source_url)}" target="_blank" rel="noopener">${esc(d.source_label)}</a>`)}
      </div>
      <p class="muted small">The full rules text is on the linked source page${d.has_higher_levels ? ', including how the spell scales at higher levels' : ''}.
        Casting, slot use and effects are not applied automatically.</p>
      ${d.grants ? `<h4 class="lin-group-title">Why you have this spell</h4>
        <div class="sp-table-wrap"><table class="sp-grants"><thead><tr><th scope="col">Source</th><th scope="col">State</th><th scope="col">Ability</th>
          <th scope="col">Save DC</th><th scope="col">Attack</th><th scope="col"><span class="sr-only">Actions</span></th></tr></thead>
          <tbody>${d.grants.map((g) => grantRow(g, d, editable)).join('')}</tbody></table></div>` : ''}
      ${book ? `<div data-acq-box><h4 class="lin-group-title">In your spellbook</h4><p class="muted small">Loading…</p></div>` : ''}`,
    footer: '<button type="button" class="btn btn-gold" data-close>Close</button>',
  });
  // spellbook spells: how the spell entered the book (starting, level up, copied, scroll ...), shown and editable
  if (book) {
    const box = $('[data-acq-box]', m.el);
    api.getSpellAcquisition(book.character_spell_id).then((a) => {
      box.innerHTML = `<h4 class="lin-group-title">In your spellbook</h4>
        <div class="form-grid"><label class="field"><span>How it entered the spellbook</span><select data-acq ${editable ? '' : 'disabled'}>
          <option value="">Not recorded</option>${Object.entries(ACQ_CHOICES).map(([k, v]) => `<option value="${k}" ${a?.acquisition === k ? 'selected' : ''}>${esc(v)}</option>`).join('')}</select></label>
        <label class="field"><span>Notes</span><input data-acq-notes maxlength="300" value="${esc(a?.acquisition_notes || '')}" ${editable ? '' : 'disabled'}></label></div>
        ${editable ? '<button type="button" class="btn btn-sm" data-acq-save>Save</button>' : ''}`;
    }).catch(() => { box.innerHTML = ''; });
    box.addEventListener('click', async (e) => {
      if (!e.target.closest('[data-acq-save]')) return;
      try {
        await api.setSpellAcquisition(book.character_spell_id, $('[data-acq]', box).value, null, $('[data-acq-notes]', box).value || null);
        toast('Spellbook record saved.', 'good');
        await onChanged?.();
      } catch (err) { toast(err.message, 'bad'); }
    });
  }
  m.el.addEventListener('click', async (e) => {
    const prep = e.target.closest('[data-grant-prepare]');
    const rem = e.target.closest('[data-grant-remove]');
    if (!prep && !rem) return;
    try {
      if (prep) await api.setSpellPrepared(prep.dataset.grantPrepare, prep.dataset.on === '1');
      else {
        if (!(await confirmDialog(`Remove ${d.name} from this source? Other sources of the spell stay.`, { title: 'Remove spell?', okLabel: 'Remove', danger: true }))) return;
        await api.removeCharacterSpell(rem.dataset.grantRemove);
      }
      toast(prep ? 'Updated.' : 'Spell removed from that source.', 'good');
      m.close();
      await onChanged?.();
    } catch (err) { toast(err.message, 'bad'); }
  });
  return m;
}

// ---------------------------------------------------------------------------------------------------------- add spell
export async function openAddSpell({ characterId, book, classes = [], onSaved, onNewSource }) {
  const loaded = await catalogOrExplain(() => Promise.all([api.getSpellCatalog(), api.getSpellReference()]), 'spells');
  if (!loaded) return null;
  const [catalog, ref] = loaded;
  const f = emptyFilters();
  f.status = 'official';
  let limit = 60;
  let picked = null;
  const m = openModal({
    title: 'Add a spell',
    wide: true,
    body: `<div data-add-root></div>`,
    footer: `<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-add-save hidden>Add spell</button>`,
  });
  const root = $('[data-add-root]', m.el);
  const saveBtn = $('[data-add-save]', m.el);
  const stored = book.sources.filter((s) => s.id);

  function renderBrowse() {
    saveBtn.hidden = true;
    const list = catalog.filter((s) => matchSpell(s, f));
    root.innerHTML = `${filtersHTML(f, ref, { prefix: 'cf' })}
      <p class="muted small" aria-live="polite" data-add-count>${list.length} spell${list.length === 1 ? '' : 's'}</p>
      <ul class="sp-pick-list">${list.slice(0, limit).map((s) => `<li><button type="button" class="sp-pick" data-pick="${esc(s.id)}">
        ${spellIconHTML(s, { size: 22, cls: 'sp-pick-icon' })}<strong>${esc(s.name)}</strong> <span class="muted small">${esc(levelLabel(s.level))} ${esc(s.school)}${damageText(s)} · ${esc(s.source_label)}</span>
        ${s.ritual ? '<span class="sp-badge sp-ritual" title="Ritual">Ritual</span>' : ''}${s.concentration ? '<span class="sp-badge sp-conc" title="Concentration">Conc.</span>' : ''} ${statusBadges(s)}
      </button></li>`).join('')}</ul>
      ${list.length > limit ? '<button type="button" class="btn btn-sm" data-more>Show more</button>' : ''}`;
  }

  function renderConfigure() {
    const versions = catalog.filter((s) => s.spell_id === picked.spell_id);
    const src = stored.find((s) => s.id === root.dataset.source) || stored[0];
    if (src) root.dataset.source = src.id;
    const onList = src?.spell_list_id ? picked.class_lists.includes(src.spell_list_id) : null;
    const k = src ? classOf(classes, src.id) : null;
    const sc = k?.spellcasting;
    // the class level decides (not the slots): a multiclass character may have higher slots than one class can use
    const tooHigh = sc && (!sc.active || (picked.level > 0 && (sc.max_spell_level == null || picked.level > sc.max_spell_level))
      || (picked.level === 0 && sc.cantrips_known == null));
    const why = !sc ? '' : !sc.active ? `${k.class_name} spellcasting starts at level ${sc.start_level}.`
      : picked.level === 0 ? `${k.class_name} does not learn cantrips.`
        : `A level ${k.level} ${k.class_name} can choose spells up to ${sc.max_spell_level ? `${ordinal(sc.max_spell_level)} level` : 'no level yet'}.`;
    saveBtn.hidden = !src;
    saveBtn.disabled = !!tooHigh;
    root.innerHTML = `<button type="button" class="btn-link" data-back>← All spells</button>
      <h3>${esc(picked.name)} <span class="muted small">${esc(levelLabel(picked.level))} ${esc(picked.school)}</span></h3>
      <label class="field"><span>Version</span><select data-version>${versions.map((v) => `<option value="${esc(v.id)}" ${v.id === picked.id ? 'selected' : ''}>
        ${esc(v.source_label)} — ${esc(v.rule_status === 'playtest' ? 'playtest' : v.status)}${v.setting ? `, ${esc(v.setting)}` : ''}</option>`).join('')}</select></label>
      ${stored.length ? `<label class="field"><span>Spellcasting source</span><select data-source-select>${stored.map((s) => `<option value="${esc(s.id)}" ${s.id === src.id ? 'selected' : ''}>
        ${esc(s.label)} (${esc(SOURCE_TYPE[s.source_type])})</option>`).join('')}</select></label>`
        : '<p class="lin-callout small">This character has no spellcasting source yet.</p>'}
      <button type="button" class="btn btn-sm" data-new-source>+ New spellcasting source…</button>
      ${onList === false ? `<p class="sp-warn small" data-list-warning>${esc(picked.name)} is not on this source’s spell list${src.enforce_spell_list ? ' (the source enforces its list, so it will be rejected)' : ''}.</p>`
        : onList ? '<p class="small lin-ok">On this source’s spell list.</p>' : ''}
      ${src?.is_preview ? '<p class="muted small">Class Foundation Preview: this source is not linked to a class, so levels and limits are not checked.</p>' : ''}
      ${tooHigh ? `<p class="sp-warn small" data-level-warning>${esc(picked.name)} is ${esc(levelLabel(picked.level).toLowerCase())}. ${esc(why)}</p>`
        : sc ? `<p class="small lin-ok" data-level-ok>${esc(why)}</p>` : ''}
      <fieldset class="lin-step"><legend>State</legend>
        <label class="check-field"><input type="checkbox" data-known checked><span>Known</span></label>
        <label class="check-field"><input type="checkbox" data-prepared><span>Prepared</span></label>
        <label class="check-field"><input type="checkbox" data-always ${src?.always_prepared_allowed ? '' : 'disabled'}><span>Always prepared${src?.always_prepared_allowed ? '' : ' (not allowed by this source)'}</span></label>
      </fieldset>
      ${src?.allowed_abilities?.length ? `<label class="field"><span>Casting ability</span><select data-ability><option value="">Source default (${esc(ABILITY[src.casting_ability] || '—')})</option>
        ${src.allowed_abilities.map((a) => `<option value="${a}">${esc(ABILITY[a])}</option>`).join('')}</select></label>` : ''}
      ${src?.preparation_mode === 'spellbook' ? `<label class="field"><span>How it entered the spellbook</span><select data-acquisition>
        ${Object.entries(ACQ_CHOICES).map(([k, v]) => `<option value="${k}" ${k === 'level_up' ? 'selected' : ''}>${esc(v)}</option>`).join('')}</select></label>
        <p class="muted small">Two spells per Wizard level are free; copied spells cost 2 hours and 50 gp per spell level (recorded, not enforced).</p>` : ''}
      <label class="field"><span>Notes</span><input type="text" data-notes maxlength="500"></label>`;
  }

  root.addEventListener('input', (e) => {
    if (e.target.dataset.cf === 'q') {
      readFilter(e.target, f);
      limit = 60;
      const pos = e.target.selectionStart;
      renderBrowse();
      const inp = $('[data-cf="q"]', root);
      inp.focus();
      inp.setSelectionRange(pos, pos);
    }
  });
  root.addEventListener('change', (e) => {
    if (e.target.dataset.cf) { readFilter(e.target, f); limit = 60; renderBrowse(); $(`[data-cf="${e.target.dataset.cf}"]`, root)?.focus(); return; }
    if (e.target.matches('[data-version]')) { picked = catalog.find((s) => s.id === e.target.value); renderConfigure(); $('[data-version]', root).focus(); }
    if (e.target.matches('[data-source-select]')) { root.dataset.source = e.target.value; renderConfigure(); $('[data-source-select]', root).focus(); }
  });
  root.addEventListener('click', async (e) => {
    const pick = e.target.closest('[data-pick]');
    if (pick) { picked = catalog.find((s) => s.id === pick.dataset.pick); renderConfigure(); $('[data-back]', root)?.focus(); return; }
    if (e.target.closest('[data-more]')) { limit += 60; renderBrowse(); return; }
    if (e.target.closest('[data-back]')) { picked = null; renderBrowse(); return; }
    if (e.target.closest('[data-new-source]')) {
      onNewSource?.(async (newBook) => { stored.splice(0, stored.length, ...newBook.sources.filter((s) => s.id)); root.dataset.source = stored.at(-1)?.id; renderConfigure(); });
    }
  });
  saveBtn.addEventListener('click', async () => {
    saveBtn.disabled = true;
    try {
      const row = await api.setCharacterSpell(characterId, {
        source: root.dataset.source, spell: picked.id, known: $('[data-known]', root).checked, prepared: $('[data-prepared]', root).checked,
        alwaysPrepared: $('[data-always]', root).checked, castingAbility: $('[data-ability]', root)?.value || null,
        notes: $('[data-notes]', root).value || null,
      });
      const acq = $('[data-acquisition]', root)?.value;
      if (acq && row?.id) await api.setSpellAcquisition(row.id, acq);
      toast(`${picked.name} added.`, 'good');
      m.close();
      await onSaved?.();
    } catch (err) { toast(err.message, 'bad'); } finally { saveBtn.disabled = false; }
  });
  renderBrowse();
  return m;
}

// ---------------------------------------------------------------------------------------------------------- source editor
export async function openSourceEditor({ characterId, source = null, classInfo = null, onSaved }) {
  const ref = await api.getSpellReference();
  const s = source || { source_type: 'manual', label: 'Manual Spellcasting Source', casting_ability: null, allowed_abilities: [],
    preparation_mode: 'known', ritual_mode: 'none', uses_spell_slots: true, always_prepared_allowed: true };
  const opt = (v, l, cur) => `<option value="${esc(v)}" ${String(cur ?? '') === String(v) ? 'selected' : ''}>${esc(l)}</option>`;
  const st = s.stats || {};
  const m = openModal({
    title: source ? `Edit ${source.label}` : 'New spellcasting source',
    wide: true,
    body: `<form class="form-grid" data-source-form>
      <label class="field"><span>Type</span><select name="source_type">${Object.entries(SOURCE_TYPE).filter(([k]) => k !== 'lineage')
        .map(([k, v]) => opt(k, v, s.source_type)).join('')}</select></label>
      <label class="field"><span>Name</span><input name="label" required maxlength="80" value="${esc(s.label)}"></label>
      <label class="field"><span>Class version</span><select name="class_version_id">${opt('', '—', s.class_version_id)}
        ${ref.classVersions.map((c) => opt(c.id, `${c.name} (${c.source_label})`, s.class_version_id)).join('')}</select></label>
      <label class="field"><span>Spell list</span><select name="spell_list_id">${opt('', 'Class default / none', s.spell_list_id)}
        ${ref.lists.map((l) => opt(l.id, l.name, s.spell_list_id)).join('')}</select></label>
      <label class="field"><span>Casting ability</span><select name="casting_ability">${opt('', 'Class default / none', s.casting_ability)}
        ${Object.entries(ABILITY).map(([k, v]) => opt(k, v, s.casting_ability)).join('')}</select></label>
      <label class="field"><span>Class level (preview, for slot tests)</span><input name="class_level" type="number" min="1" max="20" value="${esc(s.class_level ?? '')}"></label>
      <label class="field"><span>Fixed Save DC (items)</span><input name="fixed_dc" type="number" min="1" max="40" value="${esc(st.fixed_dc ?? '')}"></label>
      <label class="field"><span>Fixed attack bonus (items)</span><input name="fixed_attack_bonus" type="number" min="-5" max="20" value="${esc(st.fixed_attack_bonus ?? '')}"></label>
      <label class="field"><span>Permanent Save DC bonus</span><input name="dc_bonus" type="number" min="-5" max="10" value="${esc(s.dc_bonus ?? 0)}"></label>
      <label class="field"><span>Permanent attack bonus</span><input name="attack_bonus" type="number" min="-5" max="10" value="${esc(s.attack_bonus ?? 0)}"></label>
      <label class="field"><span>Preparation</span><select name="preparation_mode">${Object.entries(PREP).map(([k, v]) => opt(k, v, s.preparation_mode)).join('')}</select></label>
      <label class="field"><span>Ritual casting</span><select name="ritual_mode">${Object.entries(RITUAL).map(([k, v]) => opt(k, v, s.ritual_mode)).join('')}</select></label>
      <fieldset class="span-2 lin-step"><legend>Spells of this source may use instead</legend>
        ${Object.entries(ABILITY).map(([k, v]) => `<label class="check-field"><input type="checkbox" name="allowed_abilities" value="${k}" ${(s.allowed_abilities || []).includes(k) ? 'checked' : ''}><span>${v}</span></label>`).join('')}
      </fieldset>
      <label class="check-field"><input type="checkbox" name="uses_spell_slots" ${s.uses_spell_slots !== false ? 'checked' : ''}><span>Uses spell slots</span></label>
      <label class="check-field"><input type="checkbox" name="enforce_spell_list" ${s.enforce_spell_list ? 'checked' : ''}><span>Only spells from its spell list</span></label>
      <label class="check-field"><input type="checkbox" name="always_prepared_allowed" ${s.always_prepared_allowed ? 'checked' : ''}><span>May mark spells always prepared</span></label>
      <label class="field span-2"><span>Notes</span><input name="notes" maxlength="500" value="${esc(s.notes || '')}"></label>
      ${classInfo ? `<p class="lin-callout small span-2" data-class-linked>This source belongs to your ${esc(classInfo.class_name)} class (level ${classInfo.level}).
        Its class version, spell list, preparation and level follow the class; change or remove the class on the Build tab.</p>`
        : `<p class="muted small span-2" data-preview-note>A class source that is not linked to a class on the Build tab is a <strong>class preview</strong>: levels, spells known, preparation limits and slots are not checked. Add the class on the Build tab to link it.</p>`}
    </form>`,
    footer: `${source && !classInfo ? '<button type="button" class="btn btn-bad" data-delete-source>Delete source</button>' : ''}
      <button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-save-source>Save source</button>`,
  });
  const form = $('[data-source-form]', m.el);
  if (classInfo) {   // class-owned fields are set by the class; keep them read-only here
    ['source_type', 'class_version_id', 'spell_list_id', 'preparation_mode', 'ritual_mode'].forEach((n) => { form.elements[n].disabled = true; });
    form.elements.class_level.closest('label').hidden = true;
  }
  $('[data-save-source]', m.el).addEventListener('click', async () => {
    const fd = new FormData(form);
    const num = (k) => (fd.get(k) === '' || fd.get(k) == null ? null : Number(fd.get(k)));
    const payload = {
      ...(source?.id ? { id: source.id } : {}),
      source_type: classInfo ? 'class' : fd.get('source_type'), label: fd.get('label'),
      class_version_id: classInfo ? classInfo.class_version_id : fd.get('class_version_id') || null,
      spell_list_id: classInfo ? null : fd.get('spell_list_id') || null, casting_ability: fd.get('casting_ability') || null,
      allowed_abilities: fd.getAll('allowed_abilities'), fixed_dc: num('fixed_dc'), fixed_attack_bonus: num('fixed_attack_bonus'),
      dc_bonus: num('dc_bonus') ?? 0, attack_bonus: num('attack_bonus') ?? 0,
      ...(classInfo ? {} : { preparation_mode: fd.get('preparation_mode'), ritual_mode: fd.get('ritual_mode'), class_level: num('class_level') }),
      uses_spell_slots: fd.get('uses_spell_slots') === 'on',
      enforce_spell_list: fd.get('enforce_spell_list') === 'on', always_prepared_allowed: fd.get('always_prepared_allowed') === 'on',
      notes: fd.get('notes') || null,
    };
    try {
      await api.saveSpellcastingSource(characterId, payload);
      toast('Spellcasting source saved.', 'good');
      m.close();
      await onSaved?.();
    } catch (err) { toast(err.message, 'bad'); }
  });
  $('[data-delete-source]', m.el)?.addEventListener('click', async () => {
    if (!(await confirmDialog(`Delete ${source.label} and the spells it grants? Spells from other sources stay.`, { title: 'Delete source?', okLabel: 'Delete', danger: true }))) return;
    try { await api.deleteSpellcastingSource(source.id); toast('Source deleted.', 'good'); m.close(); await onSaved?.(); } catch (err) { toast(err.message, 'bad'); }
  });
  return m;
}
