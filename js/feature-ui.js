// Generic class feature UI: the class page (overview, next actions, at a glance, subclass, features by level, next level
// preview), choices, resources and the level / version change review. Everything shown comes from
// get_character_class_features, get_character_resources, get_character_derived_stats and preview_character_class_change;
// nothing here decides which feature is active, what a maximum is or whether a choice is valid.
// No class-specific code: controls are derived from the choice definitions, groups from the feature categories.
import { $, $$, esc, toast, openModal } from './utils.js?v=28';
import { SKILLS } from './dnd.js?v=28';
import * as api from './class-api.js?v=28';
import { getSpellCatalog } from './spell-api.js?v=28';
import { riderSlotButton } from './slot-actions.js?v=28';

const ABILITY = { str: 'Strength', dex: 'Dexterity', con: 'Constitution', int: 'Intelligence', wis: 'Wisdom', cha: 'Charisma' };
const AUTOMATION = {
  automated: ['Automatic', 'The sheet applies this for you'],
  partially_automated: ['Partly automatic', 'The sheet tracks or calculates part of it; you or your DM handle the rest'],
  informational: ['Reminder', 'Shown for reference; nothing is applied automatically'],
  unresolved: ['Not supported yet', 'Not represented by the app yet; track it by hand'],
  manual: ['Manual', 'Tracked by hand'],
};
const STATUS = {
  active: 'Active', locked: 'Not yet', available: 'Optional, not used', replaced: 'Replaced',
  subclass_inactive: 'Subclass inactive', prerequisite_unmet: 'Prerequisite not met',
};
const CHOICE_STATUS = {
  complete: 'Done', incomplete: 'Choice needed', over_selected: 'Too many chosen', optional: 'Optional', locked: 'Not yet',
  disabled: 'Depends on another choice', not_applicable: 'Not for this class', inactive_preserved: 'Kept, inactive', invalid: 'Needs review',
};
const RECHARGE = {
  short_rest: 'Back after a short or long rest', long_rest: 'Back after a long rest', short_or_long_rest: 'Back after a short or long rest',
  dawn: 'Back at dawn (restore it yourself)', manual: 'Back only when you restore it', none: 'Does not come back',
};
const REASON = {
  feature_inactive: 'its feature is not active', level: 'needs a higher level', informational: 'reminder only',
  not_wearing_armor: 'only while wearing armor', wearing_armor: 'only without armor', wearing_heavy_armor: 'not in heavy armor',
  using_shield: 'only without a shield', no_shield: 'only with a shield', primary_class_only: 'first class only',
  multiclass_only: 'only when multiclassing into this class', included_in_scores: 'already in your scores',
};
const SUBCLASS_STATE = {
  active: 'active', below_level: 'kept but inactive (below its level)', incompatible: 'kept but inactive (other class version)',
  available: 'can be chosen', not_yet: 'not yet', none: 'none',
};
const CATEGORY = {
  combat: 'Combat', defense: 'Defense', resource: 'Limited use', spellcasting: 'Spellcasting', proficiency: 'Proficiencies',
  exploration: 'Exploration', social: 'Social', utility: 'Utility', choice: 'Choice', subclass: 'Subclass', asi: 'Ability scores', transformation: 'Shape change',
};
const IMPL = {
  complete: 'Features in the app', features_partial: 'Some features in the app', partial: 'Some features in the app',
  progression_only: 'Spellcasting only', catalog_only: 'Name only: track its features by hand', level_only: 'Name only',
};
const scopeBadge = (scope) => (scope === 'test' ? '<span class="cf-badge cf-test" title="Synthetic test content, not official">Test fixture</span>' : '');
const autoBadge = (a) => `<span class="cf-badge cf-auto cf-auto-${esc(a)}" title="${esc(AUTOMATION[a]?.[1] || '')}">${esc(AUTOMATION[a]?.[0] || a)}</span>`;
const label = (v) => (v == null ? '—' : typeof v === 'string' ? v : String(v));
const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

// Open / closed state of the page's collapsible parts survives re-renders (Realtime, saves): keyed by data-ui-key.
const uiOpen = new Map();
const openAttr = (key, dflt) => ((uiOpen.has(key) ? uiOpen.get(key) : dflt) ? 'open' : '');

// ------------------------------------------------------------------------------------------------------------ resources
/** One resource row: remaining / maximum, die, recovery rule, Use / Restore. Works for class and manual resources alike. */
function resourceHTML(r, editable, { compact = false } = {}) {
  const max = r.max;
  const remaining = r.remaining;
  const known = r.max_known !== false && !r.unlimited;
  const pips = known && max <= 12
    ? `<span class="slot-pips-ro" role="img" aria-label="${esc(r.name)}: ${remaining} of ${max} left">${
      Array.from({ length: max }, (_, i) => `<span class="slot-dot ${i < remaining ? 'is-full' : ''}"></span>`).join('')}</span>` : '';
  const count = r.unlimited ? 'Unlimited' : known ? `${remaining} / ${max}` : '? / ?';
  // lineage / feat counters (20261031000100): notes = "<lineage or feat> · <what it does>"
  const [origin, ...rest] = String(r.notes || '').split(' · ');
  const detail = r.source_type === 'lineage' ? rest.join(' · ') : '';
  const source = r.kind === 'feature' ? `${r.class_name}: ${r.feature_name}`
    : r.source_type === 'lineage' ? `Lineage: ${origin || 'trait'}` : r.source_type === 'feat' && r.notes ? `Feat: ${r.notes}` : 'Manual resource';
  const locked = r.unlocked === false && r.unlock_level ? `Unlocks at level ${r.unlock_level}` : null;
  // a pool (Lay on Hands) or points are spent by an amount; uses go one at a time
  const amount = known && max > 1 && ['pool', 'points'].includes(r.resource_type) && r.active
    ? `<label class="cf-amount"><span class="sr-only">Amount of ${esc(r.name)}</span>
        <input type="number" min="1" max="${max}" value="1" inputmode="numeric" data-cf-amount data-focus-key="${compact ? 'q-' : ''}res-amount:${esc(r.key)}"></label>` : '';
  const actions = editable ? `<div class="cf-res-actions">${amount}
      <button type="button" class="btn btn-sm" data-cf-action="res-use" data-key="${esc(r.key)}" data-focus-key="${compact ? 'q-' : ''}res-use:${esc(r.key)}"
        aria-label="${amount ? 'Spend' : 'Use'} ${esc(r.name)}" ${!r.active || (known && remaining <= 0) ? 'disabled' : ''}>${amount ? 'Spend' : 'Use'}</button>
      <button type="button" class="btn btn-sm" data-cf-action="res-restore" data-key="${esc(r.key)}" data-focus-key="${compact ? 'q-' : ''}res-restore:${esc(r.key)}"
        aria-label="Restore ${amount ? '' : 'one '}${esc(r.name)}" ${!r.expended ? 'disabled' : ''}>Restore</button>
    </div>` : '';
  if (compact) {
    return `<div class="cf-quick ${r.active ? '' : 'is-inactive'}" data-cf-quick="${esc(r.key)}">
      <span class="cf-quick-name">${esc(r.name)}${r.die ? ` <span class="cf-badge">${esc(r.die)}</span>` : ''}</span>
      <span class="cf-res-count">${esc(count)}</span>
      <span class="muted small">${esc(RECHARGE[r.recharge] || '')}</span>${actions}</div>`;
  }
  return `<div class="cf-res ${r.active ? '' : 'is-inactive'}" data-cf-res="${esc(r.key)}">
    <div class="cf-res-main">
      <strong class="cf-res-name">${esc(r.name)}</strong>
      <span class="muted small">${esc(source)}</span>
      ${autoBadge(r.automation || 'manual')}
    </div>
    <div class="cf-res-state">
      ${pips}<span class="cf-res-count" data-cf-res-count>${esc(count)}</span>
      ${r.die ? `<span class="cf-badge" title="Die">${esc(r.die)}</span>` : ''}
    </div>
    <p class="muted small cf-res-rule">${esc(RECHARGE[r.recharge] || r.recharge || '')}${r.short_rest_recovery
      ? ` · ${esc(r.short_rest_recovery)} back on a short rest` : ''}${r.temporary_bonus ? ` · +${r.temporary_bonus} temporary` : ''}</p>
    ${r.activation_note ? `<p class="small">${esc(r.activation_note)}</p>` : ''}
    ${detail ? `<p class="small" data-cf-res-detail>${esc(detail)}${/temporary hp/i.test(detail) ? ' <span class="muted">(add the temporary HP by hand)</span>' : ''}</p>` : ''}
    ${!r.active ? `<p class="small sp-warn">${locked ? esc(locked) : `Inactive: ${esc(REASON[r.inactive_reason] || r.inactive_reason || 'not available now')}`}</p>` : ''}
    ${!known && !r.unlimited ? '<p class="small sp-warn">The maximum cannot be calculated yet; track it by hand.</p>' : ''}
    ${actions}
  </div>`;
}

/** The Resources card body: every class and manual resource. */
export function resourceListHTML(res, { editable = true } = {}) {
  if (!res) return '<p class="muted small">Loading…</p>';
  // a lineage counter of a lineage the character no longer has stays stored (its count is kept) but is not shown
  const list = (res.resources || []).filter((r) => !(r.source_type === 'lineage' && r.active === false && r.unlocked !== false));
  if (!list.length) return '<p class="empty">No class resources. Class features that grant uses (and manual resources) appear here.</p>';
  return `<div class="cf-res-list">${list.map((r) => resourceHTML(r, editable)).join('')}</div>`;
}

// ------------------------------------------------------------------------------------------------------------ choices
const valuesOf = (c) => c.values || [];
const opts = (c) => c.options || [];

function prereqNote(p) {
  if (!p || p.status === 'met') return '';
  const items = (p.items || []).filter((i) => i.status !== 'met').map((i) => i.label).join(', ');
  return `<span class="cf-prereq cf-prereq-${esc(p.status)}">${p.status === 'manual' ? 'Confirm with your DM: ' : 'Needs '}${esc(items)}</span>`;
}

const isPlaytest = (i) => i.data?.status === 'playtest';

function listControl(c, items, multi) {
  const name = `cf-${c.key}`;
  const chosen = new Set(valuesOf(c));
  const one = (i) => `<label class="cf-opt">
      <input type="${multi ? 'checkbox' : 'radio'}" name="${esc(name)}" value="${esc(i.id)}" ${chosen.has(i.id) ? 'checked' : ''}>
      <span><strong>${esc(i.label)}</strong>${i.summary ? ` <span class="muted small">${esc(i.summary)}</span>` : ''}
        ${prereqNote(i.prerequisite)}</span></label>`;
  const main = items.filter((i) => !isPlaytest(i));
  const play = items.filter(isPlaytest);
  const groups = [...new Set(main.map((i) => i.group || ''))];
  const body = groups.map((g) => {
    const inGroup = main.filter((i) => (i.group || '') === g).map(one).join('');
    return g ? `<fieldset class="cf-group"><legend>${esc(g)}</legend>${inGroup}</fieldset>` : inGroup;
  }).join('');
  // playtest (Unearthed Arcana) options stay folded away unless one of them is already chosen
  const pk = `play:${c.key}`;
  const playHTML = play.length ? `<details class="cf-playtest" data-ui-key="${esc(pk)}" ${openAttr(pk, play.some((i) => chosen.has(i.id)))}>
      <summary>Playtest options (Unearthed Arcana, ${play.length}) — only with your DM's permission</summary>${play.map(one).join('')}</details>` : '';
  return body + playHTML;
}

function asiControl(c) {
  const v = valuesOf(c);
  const feat = v.length === 1 && v[0].startsWith('feat:') ? v[0].slice(5) : '';
  const incs = v.filter((x) => !x.startsWith('feat:')).map((x) => x.split(':'));
  const mode = feat ? 'feat' : incs.length === 2 ? 'two' : 'one';
  const sel = (n, cur, lbl) => `<select name="asi-${n}" aria-label="${esc(lbl)}">${Object.entries(ABILITY).map(([k, l]) =>
    `<option value="${k}" ${cur === k ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
  return `<div class="cf-asi">
    <label class="cf-opt"><input type="radio" name="asi-mode" value="one" ${mode === 'one' ? 'checked' : ''}><span>+2 to one ability ${sel(1, incs[0]?.[0], 'Ability for +2')}</span></label>
    <label class="cf-opt"><input type="radio" name="asi-mode" value="two" ${mode === 'two' ? 'checked' : ''}><span>+1 to two abilities
      ${sel(2, incs[0]?.[0], 'First ability for +1')} ${sel(3, incs[1]?.[0] || 'dex', 'Second ability for +1')}</span></label>
    <label class="cf-opt"><input type="radio" name="asi-mode" value="feat" ${mode === 'feat' ? 'checked' : ''}><span>A feat
      <input type="hidden" name="asi-feat" value="${esc(feat)}">
      <span class="small" data-feat-label>${feat ? esc(c.feat_label || feat) : 'none chosen'}</span>
      <button type="button" class="btn btn-xs" data-pick-feat="asi-feat" data-focus-key="asi-feat:${esc(c.key)}">Choose a feat…</button></span></label>
    <p class="muted small">The feat's own choices (skills, spells…) are made in the Feats card after saving. Scores cannot go above 20.</p>
    <label class="check-field"><input type="checkbox" name="asi-included" ${c.manual_status === 'applied_manually' ? 'checked' : ''}>
      <span>Already included in my ability scores (do not add it again)</span></label>
  </div>`;
}

function spellControl(c) {
  const n = Math.max(1, c.max);
  const v = valuesOf(c);
  const lbl = c.value_labels || [];
  return Array.from({ length: n }, (_, i) => `<select name="spell" data-cf-spell-list="${esc(c.config?.spell_list || '')}"
      data-cf-spell-level="${esc(c.config?.spell_level ?? '')}" data-cf-spell-max="${esc(c.castable_level ?? (Number.isInteger(c.config?.max_spell_level) ? c.config.max_spell_level : ''))}"
      data-cf-spell-any="${c.config?.spell_list || c.config?.spell_lists ? '' : '1'}"
      data-value="${esc(v[i] || '')}" aria-label="${esc(c.label)}${n > 1 ? ` (${i + 1} of ${n})` : ''}">
      <option value="${esc(v[i] || '')}">${esc(lbl[i]?.label || (v[i] ? v[i] : 'Loading spells…'))}</option></select>`).join('');
}

function controlHTML(c, cls) {
  const multi = c.max > 1;
  switch (c.kind) {
    case 'option': return listControl(c, opts(c), multi);
    case 'skill': case 'expertise': {
      const from = c.config?.from || SKILLS.map((s) => s.key);
      const items = from.map((k) => ({ id: k, label: SKILLS.find((s) => s.key === k)?.name || k }));
      if (c.kind === 'expertise') items.push(...(c.tool_options || []).map((t) => ({ id: t.id, label: t.label, group: 'Tools' })));
      return listControl(c, items, multi);
    }
    case 'ability': {
      const from = c.config?.from || Object.keys(ABILITY);
      return listControl(c, from.map((k) => ({ id: k, label: ABILITY[k] })), multi);
    }
    case 'subclass': return subclassPicker(c, cls);
    case 'spell': return spellControl(c);
    case 'asi': return asiControl(c);
    case 'number':
      return (c.config?.keys || []).map((k) => {
        const cur = valuesOf(c).find((x) => x.startsWith(`${k}:`))?.split(':')[1] || '';
        return `<label class="field-inline"><span>${esc(k)}</span><input type="number" min="0" max="99" name="num-${esc(k)}" value="${esc(cur)}"></label>`;
      }).join('');
    default:     // free text, language, tool, weapon, item, proficiency group without a list: ids or text, one per line
      if (c.config?.from) return listControl(c, c.config.from.map((k) => ({ id: k, label: k })), multi);
      return `<textarea name="text" rows="${Math.min(c.max, 4)}" maxlength="400" aria-label="${esc(c.label)}"
        placeholder="One per line">${esc(valuesOf(c).map((v) => (v.startsWith('text:') ? v.slice(5) : v)).join('\n'))}</textarea>`;
  }
}

/** Subclass options: official first, then setting-specific; each with its source and how much the app implements. */
function subclassPicker(c, cls) {
  const options = (cls.subclass?.options || []).filter((s) => s.compatible);
  const cur = valuesOf(c)[0] || '';
  const row = (s) => `<label class="cf-opt cf-sub-opt">
      <input type="radio" name="subclass" value="${esc(s.id)}" ${cur === s.id ? 'checked' : ''}>
      <span><strong>${esc(s.name)}</strong> <span class="muted small">${esc(s.source_label || '')}${s.setting ? ` · ${esc(s.setting)}` : ''}</span>
        <span class="cf-badge cf-impl-${esc(s.implementation_status)}">${esc(IMPL[s.implementation_status] || s.implementation_status)}</span>
        ${s.content_scope === 'test' ? scopeBadge('test') : ''}
        ${s.requires_dm_permission ? `<span class="cf-prereq">${esc(s.dm_permission_note || 'Check with your DM')}</span>` : ''}
        ${s.feature_notes ? `<span class="muted small cf-sub-note">${esc(s.feature_notes)}</span>` : ''}</span></label>`;
  const main = options.filter((s) => s.source_status !== 'setting');
  const setting = options.filter((s) => s.source_status === 'setting');
  const done = (s) => (s.implementation_status === 'complete' ? 0 : 1);
  main.sort((a, b) => done(a) - done(b) || a.name.localeCompare(b.name));
  const sk = `subset:${cls.id}`;
  return `${main.map(row).join('')}${setting.length ? `<details class="cf-playtest" data-ui-key="${esc(sk)}" ${openAttr(sk, setting.some((s) => s.id === cur))}>
      <summary>Setting-specific subclasses (${setting.length})</summary>${setting.map(row).join('')}</details>` : ''}`;
}

const choiceKey = (c) => `choice:${c.key}`;

function chosenText(c) {
  return (c.value_labels || []).map((v) => `${esc(v.label)}${prereqNote(v.prerequisite)}`).join(', ');
}

function choiceHTML(c, cls, editable) {
  const values = chosenText(c);
  const needs = ['incomplete', 'over_selected', 'invalid'].includes(c.status);
  const head = `<div class="cf-choice-head"><span class="cf-choice-label">${esc(c.label)}</span>
      <span class="cf-badge cf-cs-${esc(c.status)}">${esc(CHOICE_STATUS[c.status] || c.status)}</span>
      <span class="muted small">${c.min === c.max ? `choose ${c.max}` : `choose ${c.min}–${c.max}`}</span></div>`;
  if (!c.open || !editable) {
    const why = c.status === 'locked' ? `Opens at ${esc(cls.class_name)} level ${c.level}.`
      : c.status === 'disabled' ? 'Depends on an earlier choice.'
        : c.status === 'not_applicable' ? (c.applies_to === 'multiclass' ? 'Only when this is not your first class.' : 'Only for your first class.')
          : c.status === 'inactive_preserved' ? 'Kept for review; it applies again when its feature is active.' : '';
    return `<div class="cf-choice is-${esc(c.status)}" data-cf-choice-key="${esc(c.key)}">${head}
      ${values ? `<p class="small">Chosen: ${values}</p>` : ''}${why ? `<p class="muted small">${why}</p>` : ''}</div>`;
  }
  const confirm = valuesOf(c).length && (c.value_labels || []).some((v) => v.prerequisite?.status === 'manual')
    ? `<label class="check-field"><input type="checkbox" name="confirmed" ${c.manual_status === 'confirmed' ? 'checked' : ''}>
        <span>My DM allows this</span></label>` : '';
  const form = `<form class="cf-choice-form" data-cf-choice="${esc(cls.id)}|${esc(c.unlock_id)}|${esc(c.choice_id)}"
      data-kind="${esc(c.kind)}" data-max="${c.max}" data-cf-choice-key="${esc(c.key)}">
    ${prereqNote(c.prerequisite)}
    <div class="cf-control">${controlHTML(c, cls)}</div>
    ${confirm}
    <div class="cf-choice-actions">
      <button type="submit" class="btn btn-sm btn-gold" data-focus-key="cf-save:${esc(c.key)}">Save choice</button>
      ${valuesOf(c).length && c.kind !== 'subclass' ? `<button type="button" class="btn btn-sm" data-cf-action="choice-clear" data-focus-key="cf-clear:${esc(c.key)}">Clear</button>` : ''}
    </div>
  </form>`;
  // a finished choice shows its result; the controls open on "Change"
  return `<div class="cf-choice is-${esc(c.status)}" data-cf-choice-wrap="${esc(c.key)}">${head}
    ${needs ? `${values ? `<p class="small">Chosen: ${values}</p>` : ''}${form}`
    : `<details class="cf-change" data-ui-key="${esc(choiceKey(c))}" ${openAttr(choiceKey(c), false)}>
        <summary>${values ? `Chosen: ${values}` : 'Nothing chosen'} <span class="link-btn">Change</span></summary>${form}</details>`}</div>`;
}

// ------------------------------------------------------------------------------------------------------------ features
function scalingHTML(f) {
  return (f.scaling || []).map((s) => `<span class="cf-scale">${esc(s.label)}: <strong>${esc(label(s.value))}</strong>${
    s.next_level ? ` <span class="muted">(${esc(label(s.next_value))} at level ${s.next_level})</span>` : ''}</span>`).join('');
}

function effectLine(e) {
  const what = e.effect_type === 'spell' ? `Spell: ${e.spell_name || e.spell_version_id || 'chosen spell'}`
    : e.effect_type === 'attack' ? `Attack: ${e.data?.name || ''}`
      : e.effect_type === 'informational' ? (e.value_text || 'Reminder')
        : [e.effect_type.replace(/_/g, ' '), e.target, e.value_text, e.value].filter((x) => x != null && x !== '').join(' ');
  return `<li class="${e.active ? '' : 'muted'}">${esc(what)}${e.active || e.effect_type === 'informational' ? ''
    : ` — ${esc(REASON[e.inactive_reason] || e.inactive_reason || 'inactive')}`}</li>`;
}

function featureHTML(f, cls, state, editable) {
  // a dependent sub-choice whose parent option is not chosen (and holds nothing) is not shown at all
  const choices = (cls.choices || []).filter((c) => c.unlock_id === f.unlock_id && !(c.status === 'disabled' && !valuesOf(c).length));
  const res = (state.resources || []).filter((r) => r.unlock_id === f.unlock_id && r.character_class_id === cls.id);
  const toggle = f.is_optional && editable && (f.status === 'available' || f.opted_in)
    ? `<button type="button" class="btn btn-sm" data-cf-action="optional" data-row="${esc(cls.id)}" data-unlock="${esc(f.unlock_id)}"
        data-enable="${f.opted_in ? '0' : '1'}" data-focus-key="cf-opt:${esc(f.unlock_id)}">${f.opted_in ? 'Stop using this optional feature'
        : f.replaces ? `Use instead of ${esc(f.replaces.name)}` : 'Use this optional feature'}</button>` : '';
  const dk = `details:${f.unlock_id}`;
  return `<article class="cf-card is-${esc(f.status)}" data-cf-feature="${esc(f.unlock_id)}">
    <div class="cf-head">
      <h4>${esc(f.name)}</h4>
      ${f.origin === 'subclass' ? '<span class="cf-badge">Subclass</span>' : ''}
      ${f.is_optional ? `<span class="cf-badge" title="${esc(f.source_label)}">Optional</span>` : ''}
      ${f.category ? `<span class="cf-cat">${esc(CATEGORY[f.category] || f.category)}</span>` : ''}
      ${autoBadge(f.automation)}
      ${f.status !== 'active' ? `<span class="cf-badge cf-st cf-st-${esc(f.status)}" data-cf-status>${esc(STATUS[f.status] || f.status)}</span>`
    : '<span class="cf-badge cf-st cf-st-active sr-only" data-cf-status>Active</span>'}
    </div>
    <p class="small">${esc(f.summary)}</p>
    ${f.scaling?.length ? `<p class="small cf-scaling">${scalingHTML(f)}</p>` : ''}
    ${f.replaces ? `<p class="muted small">${f.replaces.mode === 'replace' ? 'Replaces' : 'Changes'} ${esc(f.replaces.name)}.</p>` : ''}
    ${f.replaced_by ? `<p class="muted small">Replaced by ${esc(f.replaced_by.name)}.</p>` : ''}
    ${f.status === 'prerequisite_unmet' ? `<p class="small sp-warn">${prereqNote(f.prerequisite)}</p>` : ''}
    ${res.length ? `<div class="cf-quick-list">${res.map((r) => resourceHTML(r, editable, { compact: true })).join('')}</div>` : ''}
    ${toggle}
    ${choices.map((c) => choiceHTML(c, cls, editable)).join('')}
    <details class="cf-details" data-ui-key="${esc(dk)}" ${openAttr(dk, false)}><summary>Details and source</summary>
      ${f.effects?.length ? `<ul class="small">${f.effects.map(effectLine).join('')}</ul>` : '<p class="muted small">No structured effects.</p>'}
      ${f.automation_notes ? `<p class="muted small">${esc(f.automation_notes)}</p>` : ''}
      <p class="muted small">Level ${f.level} · ${esc(f.source_label)}${f.source_url ? ` · <a href="${esc(f.source_url)}" target="_blank" rel="noopener">source</a>` : ''}
        ${f.version_status === 'legacy' ? ' · legacy version' : ''}</p>
    </details>
  </article>`;
}

function nextLevelHTML(cls) {
  const n = cls.next_level;
  if (!n?.possible) return '';
  const items = [
    ...n.features.map((f) => `<li>${esc(f.name)} ${autoBadge(f.automation)}${f.is_optional ? ' (optional)' : ''}${f.asi
      ? ' — ability score improvement or feat' : ''}${f.choices.length && !f.asi ? ` — choose: ${esc(f.choices.join(', '))}` : ''}</li>`),
    ...n.scaling.map((s) => `<li>${esc(s.feature)}: ${esc(s.label)} ${esc(label(s.from))} → ${esc(label(s.to))}</li>`),
    n.subclass_unlock ? `<li>Choose your ${esc(cls.subclass_label || 'subclass')}</li>` : '',
  ].filter(Boolean);
  const k = `next:${cls.id}`;
  return `<details class="cf-next" data-cf-next="${esc(cls.id)}" data-ui-key="${esc(k)}" ${openAttr(k, false)}>
    <summary>Next level preview (${esc(cls.class_name)} ${n.level})</summary>
    <p class="small">Proficiency bonus at the new total level: +${n.proficiency_bonus}</p>
    ${items.length ? `<ul class="small">${items.join('')}</ul>` : '<p class="muted small">No new class features at this level.</p>'}
    <p class="muted small">Read only. Change the level on the Build tab to see the full review (slots, spells, resources) before it is applied.</p></details>`;
}

/** The subclass block of a class: the chosen subclass with its source and implementation, or the picker. */
function subclassBlockHTML(cls, editable) {
  const sub = cls.subclass || {};
  const subChoice = (cls.choices || []).find((c) => c.kind === 'subclass');
  const label2 = cls.subclass_label || 'Subclass';
  const sel = sub.selected ? (sub.options || []).find((o) => o.id === sub.selected.id) : null;
  if (!sub.selected && sub.status === 'not_yet') {
    return `<p class="muted small cf-sub">${esc(label2)}: chosen at ${esc(cls.class_name)} level ${sub.selection_level}.</p>`;
  }
  const info = sel ? `<p class="small"><strong>${esc(sel.name)}</strong> <span class="muted">${esc(sel.source_label || '')}${sel.setting ? ` · ${esc(sel.setting)}` : ''}</span>
      <span class="cf-badge cf-impl-${esc(sel.implementation_status)}">${esc(IMPL[sel.implementation_status] || sel.implementation_status)}</span>
      ${sub.active ? '' : `<span class="cf-badge cf-cs-incomplete">${esc(SUBCLASS_STATE[sub.status] || sub.status)}</span>`}</p>
      ${sel.implementation_status === 'catalog_only' ? `<p class="muted small">This subclass is in the catalog by name; its features are not in the app yet.
        Add them under "Your own notes" below and track their uses on the Play tab.</p>` : ''}` : '';
  return `<div class="cf-sub ${sub.selected ? '' : 'is-needed'}" data-cf-subclass="${esc(cls.id)}">
    <h4>${esc(label2)}</h4>${info}
    ${subChoice ? choiceHTML(subChoice, cls, editable) : ''}</div>`;
}

/** Features grouped by the level that unlocked them: the current and the previous level and every level with an open choice
 *  start expanded, older levels start collapsed (their state is remembered). */
function levelsHTML(cls, state, editable) {
  const feats = (cls.features || []).filter((f) => !(f.choices?.length === 1 && (cls.choices || []).find((c) => c.key === f.choices[0])?.kind === 'subclass'));
  const byLevel = new Map();
  for (const f of feats) byLevel.set(f.level, [...(byLevel.get(f.level) || []), f]);
  const levels = [...byLevel.keys()].sort((a, b) => b - a);
  const open = new Set((cls.choices || []).filter((c) => c.open && ['incomplete', 'over_selected', 'invalid'].includes(c.status)).map((c) => c.unlock_id));
  return levels.map((lv) => {
    const list = byLevel.get(lv).sort((a, b) => (a.origin === b.origin ? 0 : a.origin === 'class' ? -1 : 1));
    const k = `lvl:${cls.id}:${lv}`;
    const needs = list.filter((f) => open.has(f.unlock_id)).length;
    const dflt = lv >= cls.level - 1 || needs > 0;
    return `<details class="cf-level" data-ui-key="${esc(k)}" data-cf-level="${lv}" ${openAttr(k, dflt)}>
      <summary><span class="cf-level-n">Level ${lv}</span> <span class="cf-level-names">${list.map((f) => esc(f.name)).join(' · ')}</span>
        ${needs ? `<span class="cf-badge cf-cs-incomplete">${plural(needs, 'choice')} needed</span>` : ''}</summary>
      <div class="cf-list">${list.map((f) => featureHTML(f, cls, state, editable)).join('')}</div></details>`;
  }).join('');
}

/** "2d8–5d8" for a rider whose dice depend on the slot spent. */
export function riderDiceRange(r) {
  const d = Object.entries(r?.dice_by_slot || {}).sort((a, b) => Number(a[0]) - Number(b[0])).map(([, v]) => v);
  return d.length ? (d[0] === d[d.length - 1] ? d[0] : `${d[0]}–${d[d.length - 1]}`) : '';
}

/** States a feature switches on (Rage): Start spends a use, End stops it; a rest ends it too. `states` from getStates. */
export function statesHTML(states, { editable = true } = {}) {
  const list = states?.states || [];
  if (!list.length) return '';
  return `<div class="cf-states" data-cf-states>${list.map((s) => {
    const r = s.resource;
    const left = r ? (r.unlimited ? 'unlimited' : `${r.remaining} / ${r.max} left`) : '';
    const empty = r && !r.unlimited && r.remaining <= 0;
    return `<div class="cf-state ${s.active ? 'is-active' : ''}" data-cf-state="${esc(s.key)}">
      <div><strong>${esc(s.name)}</strong> <span class="cf-badge ${s.active ? 'cf-auto-automated' : ''}" data-cf-state-status>${s.active ? 'Active' : 'Not active'}</span>
        <span class="muted small">${esc([s.duration, left].filter(Boolean).join(' · '))}</span>
        ${s.summary ? `<p class="small muted">${esc(s.summary)}</p>` : ''}</div>
      ${editable ? (s.active
        ? `<button type="button" class="btn btn-sm" data-cf-action="state-end" data-key="${esc(s.key)}" data-focus-key="state:${esc(s.key)}">End ${esc(s.name)}</button>`
        : `<button type="button" class="btn btn-sm btn-gold" data-cf-action="state-start" data-key="${esc(s.key)}" data-focus-key="state:${esc(s.key)}"
            ${empty ? 'disabled' : ''} title="${empty ? 'No uses left' : ''}">Start ${esc(s.name)}</button>`) : ''}
    </div>`;
  }).join('')}</div>`;
}

/** "At a glance": what a player needs during play (attacks, critical range, damage riders, quick resources). */
/** Ready to use (Play): states such as Rage, feature DCs and quick resource buttons. attackFacts: also attacks per action,
 *  critical range and damage riders (off on Play, where the Attacks section shows them). */
export function glanceHTML(state, derived, editable, states, { attackFacts = true } = {}) {
  if (!derived || !state) return statesHTML(states, { editable });
  const apa = derived.attacks_per_action?.value || 1;
  const crit = derived.critical_range?.value || 20;
  const riders = derived.attack_riders || [];
  const half = derived.check_half_proficiency;
  // a resource spent by starting a state (Rage) is shown on the state card, not as a separate Use button
  const stateKeys = new Set((states?.states || []).map((s) => s.resource_key).filter(Boolean));
  // lineage counters too (Hungry Jaws) and a feat's own counters (a feat's free spell casts stay on the Spells tab)
  const res = (state.resources || []).filter((r) => (r.kind === 'feature' || r.source_type === 'lineage' || (r.source_type === 'feat' && !r.spell_version_id))
    && r.active && !stateKeys.has(r.key));
  const facts = [
    !attackFacts ? '' : apa > 1 ? `<li><strong>${apa} attacks</strong> when you take the Attack action</li>` : '',
    attackFacts && crit < 20 ? `<li>Critical hit on <strong>${crit}–20</strong></li>` : '',
    ...(derived.feature_dcs || []).map((x) => `<li data-feature-dc="${esc(x.name)}"><strong>${esc(x.name)} ${x.dc}</strong>
      <span class="muted small">(8 + proficiency bonus + ${esc(String(x.ability).toUpperCase())} · ${esc(x.source_name)})</span></li>`),
    ...(attackFacts ? riders : []).map((r) => `<li data-glance-rider="${esc(r.name)}"><strong>${esc(r.name)} ${esc(r.dice || riderDiceRange(r))}</strong>${r.once_per_turn ? ' once per turn' : ''}
      <span class="muted small">${esc(r.condition || '')}</span> ${riderSlotButton(r, { editable })}</li>`),
    half ? `<li>+${half.value} to ${esc(half.abilities.map((a) => a.toUpperCase()).join(' / '))} checks you are not proficient in
      <span class="muted small">(${esc(half.source_name)})</span></li>` : '',
  ].filter(Boolean);
  const st = statesHTML(states, { editable });
  if (!facts.length && !res.length && !st) return '';
  return `<section class="cf-glance" data-cf-glance aria-label="Ready to use">${st}
    ${facts.length ? `<ul class="small cf-facts">${facts.join('')}</ul>` : ''}
    ${res.length ? `<div class="cf-quick-list">${res.map((r) => resourceHTML(r, editable, { compact: true })).join('')}</div>` : ''}
  </section>`;
}

/** "Next actions": everything that needs the player's attention, each with a button that opens the right place. */
function actionsHTML(state) {
  const inc = state.incomplete_choices || [];
  const items = [];
  for (const cls of state.classes || []) {
    const sub = cls.subclass || {};
    if (!sub.selected && sub.status === 'available' && (sub.options || []).some((o) => o.compatible)) {
      const c = (cls.choices || []).find((x) => x.kind === 'subclass');
      items.push(`<li><span><strong>${esc(cls.class_name)} ${cls.level}:</strong> choose your ${esc(cls.subclass_label || 'subclass')}</span>
        ${c ? `<button type="button" class="btn btn-sm btn-gold" data-cf-goto="${esc(c.key)}">Choose</button>` : ''}</li>`);
    }
  }
  for (const x of inc) {
    if (x.kind === 'subclass') continue;
    const cls = (state.classes || []).find((k) => k.id === x.character_class_id);
    const c = cls?.choices?.find((y) => y.key === x.key);
    const need = c ? (c.min === c.max ? `choose ${c.max}` : `choose ${c.min}–${c.max}`) : '';
    items.push(`<li><span><strong>${esc(x.class_name)} · ${esc(x.feature_name)}:</strong> ${esc(x.label)}${need ? ` <span class="muted small">(${need})</span>` : ''}
      ${x.status === 'invalid' ? ' <span class="sp-warn small">needs review</span>' : ''}</span>
      <button type="button" class="btn btn-sm btn-gold" data-cf-goto="${esc(x.key)}">${x.kind === 'asi' ? 'Allocate' : 'Choose'}</button></li>`);
  }
  const warn = (state.warnings || []).filter((w) => !['subclass_not_chosen'].includes(w.code));
  return `<section class="cf-actions" data-cf-actions>
    <h3 class="cf-actions-title">Next actions</h3>
    ${items.length ? `<ul class="cf-action-list" data-cf-incomplete>${items.join('')}</ul>` : '<p class="small cf-all-done">All class choices are made.</p>'}
    ${warn.length ? `<ul class="cls-warnings sp-warn small" data-cf-warnings>${warn.map((w) => `<li>${esc(w.message)}</li>`).join('')}</ul>` : ''}
  </section>`;
}

/** The class page (Build tab): overview, next actions, at a glance, then one section per class. */
export function featuresPanelHTML(state, { editable = true, derived = null, states = null } = {}) {
  if (!state) return '<p class="muted small">Loading…</p>';
  if (!state.classes?.length) return '<p class="empty">No classes yet. Add a class on the Build tab; its features appear here.</p>';
  const cov = state.automation_coverage || {};
  const primary = state.classes.find((k) => k.is_primary);
  const overview = `<p class="cf-overview" data-cf-overview>${state.classes.map((k) => `<span class="cf-chip"><strong>${esc(k.class_name)} ${k.level}</strong>${
    k.subclass?.selected ? ` · ${esc(k.subclass.selected.name)}` : ''}</span>`).join('')}
    <span class="muted small">Character level ${state.total_level} · proficiency bonus +${state.proficiency_bonus}${
    state.classes.length > 1 && primary ? ` · first class: ${esc(primary.class_name)}` : ''}</span></p>`;
  return `${overview}${actionsHTML(state)}
    ${state.classes.map((cls) => {
    const empty = !(cls.features || []).length;
    const v = cls.version || {};
    return `<section class="cf-class" data-cf-class="${esc(cls.id)}">
      <h3 class="section-title">${esc(cls.class_name)} ${cls.level} ${scopeBadge(cls.content_scope)}
        <span class="hint">${esc(v.rules_label || cls.version_name || '')}${v.hit_die ? ` · hit die ${esc(v.hit_die)}` : ''}</span></h3>
      ${v.feature_status && v.feature_status !== 'complete' && cls.content_scope !== 'test'
    ? '<p class="muted small">This class is not fully in the app yet: some of its features are missing; track them under "Your own notes".</p>' : ''}
      ${subclassBlockHTML(cls, editable)}
      ${empty ? '<p class="muted small">No features for this class in the catalog yet (class levels, slots and spells still work).</p>' : ''}
      ${levelsHTML(cls, state, editable)}
      ${(cls.review_items || []).length ? `<details class="cf-review" open><summary>Kept for review (${cls.review_items.length})</summary>
        <ul class="small">${cls.review_items.map((r) => `<li>${esc(r.kind.replace('_', ' '))}: ${esc(r.name)}${r.detail ? ` — ${esc(r.detail)}` : ''}</li>`).join('')}</ul>
        <p class="muted small">These belong to another class version or subclass. They are not applied and were not deleted.</p></details>` : ''}
      ${nextLevelHTML(cls)}
    </section>`;
  }).join('')}
    <p class="muted small cf-coverage">Active features: ${cov.automated || 0} automatic, ${cov.partially_automated || 0} partly automatic,
      ${cov.informational || 0} reminders${cov.unresolved ? `, ${cov.unresolved} not supported yet` : ''}.</p>`;
}

/** Short summary for the Classes card (Bio): incomplete choices and the subclass state. */
export function featureSummaryHTML(state) {
  if (!state?.classes?.length) return '';
  const inc = state.incomplete_choices || [];
  const subs = (state.classes || []).filter((k) => !k.subclass?.selected && k.subclass?.status === 'available').length;
  const n = inc.filter((x) => x.kind !== 'subclass').length + subs;
  return `<p class="small" data-cf-summary>${n ? `<strong>${plural(n, 'class choice')} to make</strong> — `
    : 'All class choices made. '}<button type="button" class="link-btn" data-action="tab" data-tab="features">Open class features</button></p>`;
}

/** Fill the spell choice selects after rendering (one cached request per spell list). */
export async function hydrateSpellChoices(container) {
  for (const sel of $$('select[data-cf-spell-list]', container)) {
    if (sel.dataset.hydrated) continue;
    sel.dataset.hydrated = '1';
    const list = sel.dataset.cfSpellList;
    if (!list && !sel.dataset.cfSpellAny) continue;
    try {
      const level = sel.dataset.cfSpellLevel === '' ? null : Number(sel.dataset.cfSpellLevel);
      const max = sel.dataset.cfSpellMax === '' ? 9 : Number(sel.dataset.cfSpellMax);
      // no list: any class list (Magical Secrets); official current spells of the whole catalog, up to the castable level
      const spells = (list ? await api.getSpellListOptions(list, level)
        : (await getSpellCatalog()).filter((s) => s.status === 'current' && s.rule_status !== 'playtest' && s.scope === 'official'
          && (s.class_lists || []).length && (level == null || s.level === level)).map((s) => ({ id: s.id, level: s.level, name: s.name })))
        .filter((s) => s.level <= max);
      sel.innerHTML = `<option value="">— choose a spell —</option>${spells.map((s) =>
        `<option value="${esc(s.id)}" ${s.id === sel.dataset.value ? 'selected' : ''}>${esc(s.name)}${s.level ? ` (level ${s.level})` : ' (cantrip)'}</option>`).join('')}`;
    } catch (err) { sel.dataset.hydrated = ''; console.warn('[features] spell list', err?.message || err); }
  }
}

// ------------------------------------------------------------------------------------------------------------ writes
function readValues(form) {
  const kind = form.dataset.kind;
  const fd = new FormData(form);
  if (kind === 'asi') {
    const mode = fd.get('asi-mode');
    if (mode === 'feat') return { values: fd.get('asi-feat')?.trim() ? [`feat:${fd.get('asi-feat').trim()}`] : [] };
    const values = mode === 'two' ? [`${fd.get('asi-2')}:1`, `${fd.get('asi-3')}:1`] : [`${fd.get('asi-1')}:2`];
    return { values, manual: fd.get('asi-included') ? 'applied_manually' : null };
  }
  if (kind === 'spell') return { values: fd.getAll('spell').filter(Boolean) };
  if (kind === 'subclass') return { subclass: fd.get('subclass') || null };
  if (kind === 'number') {
    return { values: [...form.querySelectorAll('input[name^="num-"]')].filter((i) => i.value !== '' && Number(i.value) > 0)
      .map((i) => `${i.name.slice(4)}:${Number(i.value)}`) };
  }
  if (form.querySelector('textarea[name="text"]')) {
    return { values: fd.get('text').split('\n').map((x) => x.trim()).filter(Boolean) };
  }
  return { values: fd.getAll(`cf-${form.dataset.cfChoiceKey}`), manual: fd.get('confirmed') ? 'confirmed' : null };
}

// Unsaved edits of a choice survive re-renders (Realtime, derived refresh): drafts keyed by choice key, cleared on save.
const drafts = new Map();
function serializeForm(form) {
  return [...form.querySelectorAll('input, select, textarea')].map((el, i) => [i, el.name, el.type, el.type === 'checkbox' || el.type === 'radio' ? el.checked : el.value]);
}
/** Re-apply unsaved choice edits after the panel was re-rendered (call after every render of the class page). */
export function restoreDrafts(container) {
  for (const form of $$('form[data-cf-choice]', container)) {
    const d = drafts.get(form.dataset.cfChoiceKey);
    if (!d) continue;
    const els = [...form.querySelectorAll('input, select, textarea')];
    if (els.length !== d.length) { drafts.delete(form.dataset.cfChoiceKey); continue; }   // the definition changed: drop the draft
    d.forEach(([i, name, type, v]) => {
      const el = els[i];
      if (!el || el.name !== name) return;
      if (type === 'checkbox' || type === 'radio') el.checked = v;
      else if (el.tagName === 'SELECT' && el.dataset.cfSpellList !== undefined && !el.dataset.hydrated) el.dataset.value = v;
      else el.value = v;
    });
    const wrap = form.closest('details.cf-change');
    if (wrap) wrap.open = true;
  }
}

/** Open the collapsible parts around a choice, scroll to it and focus its first control. */
function gotoChoice(root, key) {
  const target = $(`[data-cf-choice-key="${CSS.escape(key)}"]`, root);
  if (!target) return;
  for (let el = target.parentElement; el && el !== root; el = el.parentElement) {
    if (el.tagName === 'DETAILS') { el.open = true; if (el.dataset.uiKey) uiOpen.set(el.dataset.uiKey, true); }
  }
  target.scrollIntoView({ block: 'center', behavior: 'smooth' });
  setTimeout(() => $('input:not([type=hidden]), select, textarea, button', target)?.focus({ preventScroll: true }), 250);
}

const busy = new Set();
/** Event delegation for the feature panel and the resource list (attached once per mounted sheet). */
export function attachFeatureHandlers(root, { getCharacterId, onChanged, onResources }) {
  // only the player's own open / close is remembered (a details element rendered open also fires "toggle");
  // a click on the summary also covers Enter / Space from the keyboard
  root.addEventListener('click', (e) => {
    const sum = e.target.closest('summary');
    const d = sum?.parentElement;
    if (d?.tagName === 'DETAILS' && d.dataset.uiKey && root.contains(d)) setTimeout(() => uiOpen.set(d.dataset.uiKey, d.open), 0);
  }, true);
  const draft = (e) => {
    const form = e.target.closest?.('form[data-cf-choice]');
    if (form && root.contains(form)) drafts.set(form.dataset.cfChoiceKey, serializeForm(form));
  };
  root.addEventListener('change', draft);
  root.addEventListener('input', draft);
  root.addEventListener('submit', async (e) => {
    const form = e.target.closest('form[data-cf-choice]');
    if (!form) return;
    e.preventDefault();
    const [row, unlock, choice] = form.dataset.cfChoice.split('|');
    const btn = form.querySelector('[type="submit"]');
    if (btn.disabled) return;
    btn.disabled = true;
    try {
      const v = readValues(form);
      const res = v.subclass !== undefined
        ? await api.setSubclass(getCharacterId(), row, v.subclass)
        : await api.setFeatureChoice(getCharacterId(), row, unlock, choice, v.values, v.manual || null);
      const wrap = form.closest('details.cf-change');
      if (wrap?.dataset.uiKey) uiOpen.set(wrap.dataset.uiKey, false);    // a saved change folds back to its result
      drafts.delete(form.dataset.cfChoiceKey);
      toast('Choice saved.', 'good');
      await onChanged?.(res);
    } catch (err) { toast(err.message, 'bad'); } finally { btn.disabled = false; }
  });
  root.addEventListener('click', async (e) => {
    const go = e.target.closest('[data-cf-goto]');
    if (go && root.contains(go)) { gotoChoice(root, go.dataset.cfGoto); return; }
    const el = e.target.closest('[data-cf-action]');
    if (!el || !root.contains(el) || el.disabled) return;
    const id = getCharacterId();
    const kind = el.dataset.cfAction;
    const k = `${kind}:${el.dataset.key || el.dataset.unlock || ''}`;
    if (busy.has(k)) return;                      // a second click while the request runs is ignored (no double use)
    busy.add(k);
    el.disabled = true;
    try {
      if (kind === 'res-use' || kind === 'res-restore') {
        const amt = el.closest('.cf-res-actions')?.querySelector('[data-cf-amount]');
        const n = amt ? Math.max(1, Math.floor(Number(amt.value) || 1)) : 1;
        const r = kind === 'res-use' ? await api.expendResource(id, el.dataset.key, n) : await api.restoreResource(id, el.dataset.key, n);
        toast(`${r.name}: ${r.remaining == null ? 'used' : `${r.remaining} / ${r.max} left`}`, 'good');
        await onResources?.();
      } else if (kind === 'state-start' || kind === 'state-end') {
        const r = kind === 'state-start' ? await api.startState(id, el.dataset.key) : await api.endState(id, el.dataset.key);
        const s = (r.states || []).find((x) => x.key === el.dataset.key);
        toast(`${s?.name || el.dataset.key} ${kind === 'state-start' ? 'started' : 'ended'}.`, 'good');
        await onChanged?.(r);
      } else if (kind === 'optional') {
        const res = await api.setOptionalFeature(id, el.dataset.row, el.dataset.unlock, el.dataset.enable === '1');
        await onChanged?.(res);
      } else if (kind === 'choice-clear') {
        const form = el.closest('form[data-cf-choice]');
        const [row, unlock, choice] = form.dataset.cfChoice.split('|');
        const res = await api.setFeatureChoice(id, row, unlock, choice, []);
        drafts.delete(form.dataset.cfChoiceKey);
        toast('Choice cleared.', 'good');
        await onChanged?.(res);
      }
    } catch (err) { toast(err.message, 'bad'); el.disabled = false; } finally { busy.delete(k); }
  });
}

// ------------------------------------------------------------------------------------------------------------ change review
const listOr = (items, empty) => (items.length ? `<ul class="small">${items.join('')}</ul>` : `<p class="muted small">${empty}</p>`);
const slotText = (m) => (Object.keys(m || {}).length ? Object.entries(m).map(([l, n]) => `${l}: ${n}`).join(' · ') : 'none');

function reviewBody(p) {
  const res = (p.resources || []).map((r) => `<li>${esc(r.name)}: ${r.active_from ? esc(label(r.max_from)) : 'inactive'} → ${
    r.active_to ? esc(label(r.max_to)) : 'inactive'}${r.die_from !== r.die_to && (r.die_from || r.die_to) ? ` (die ${esc(label(r.die_from))} → ${esc(label(r.die_to))})` : ''}</li>`);
  const slotsChanged = slotText(p.standard_slots?.from) !== slotText(p.standard_slots?.to);
  const pact = p.pact_magic || {};
  const sc = p.spellcasting || {};
  return `<div class="cf-review-body" data-cf-review>
    <p><strong>Level</strong> ${p.level.from} → ${p.level.to} · total ${p.total_level.from} → ${p.total_level.to} ·
      proficiency bonus +${p.proficiency_bonus.from} → +${p.proficiency_bonus.to}</p>
    ${p.class_version.from !== p.class_version.to ? `<p><strong>Version</strong> ${esc(p.class_version.from_name)} → ${esc(p.class_version.to_name)}</p>` : ''}
    <h4>Features activated</h4>${listOr((p.features_activated || []).map((f) => `<li>${esc(f.name)} (level ${f.level}) ${autoBadge(f.automation)}</li>`), 'None')}
    <h4>Features deactivated</h4>${listOr((p.features_deactivated || []).map((f) => `<li>${esc(f.name)} (level ${f.level})</li>`), 'None')}
    <h4>New choices</h4>${listOr((p.choices_added || []).map((c) => `<li>${esc(c.feature)}: ${esc(c.label)}</li>`), 'None')}
    <h4>Choices made inactive (kept)</h4>${listOr((p.choices_inactive || []).map((c) => `<li>${esc(c.feature)}: ${esc(c.label)}</li>`), 'None')}
    <h4>Resources</h4>${listOr(res, 'No change')}
    <h4>Spell slots</h4><p class="small">${slotsChanged ? `${esc(slotText(p.standard_slots.from))} → ${esc(slotText(p.standard_slots.to))}` : 'No change'}${
      JSON.stringify(pact.from) !== JSON.stringify(pact.to) ? ` · Pact Magic ${pact.from ? `${pact.from.slots} × ${pact.from.slot_level}` : 'none'} → ${pact.to ? `${pact.to.slots} × ${pact.to.slot_level}` : 'none'}` : ''}</p>
    ${sc.from || sc.to ? `<p class="small">Spell access: up to level ${esc(label(sc.from?.max_spell_level))} → ${esc(label(sc.to?.max_spell_level))}${
      sc.from?.prepared_limit != null || sc.to?.prepared_limit != null ? ` · prepared ${esc(label(sc.from?.prepared_limit))} → ${esc(label(sc.to?.prepared_limit))}` : ''}</p>` : ''}
    ${p.subclass?.from !== p.subclass?.to ? `<p class="small" data-cf-review-subclass><strong>Subclass</strong> ${esc(p.subclass.name || '')}: ${
      esc(SUBCLASS_STATE[p.subclass.from] || p.subclass.from)} → ${esc(SUBCLASS_STATE[p.subclass.to] || p.subclass.to)}</p>` : ''}
    ${(p.proficiencies?.added || []).length || (p.proficiencies?.removed || []).length ? `<p class="small">Proficiencies: ${
      [...p.proficiencies.added.map((x) => `+ ${x.value}`), ...p.proficiencies.removed.map((x) => `− ${x.value}`)].map(esc).join(', ')}</p>` : ''}
    ${(p.warnings || []).length ? `<ul class="sp-warn small">${p.warnings.map((w) => `<li>${esc(w.message)}</li>`).join('')}</ul>` : ''}
    <p class="muted small">Nothing is deleted: choices, spells and resource state are kept and flagged when they no longer apply.</p>
  </div>`;
}

/** Review a level and / or version change before it is applied. Resolves true when the user confirms. */
export async function reviewClassChange({ characterId, row, className, level = null, version = null }) {
  let p;
  try { p = await api.previewClassChange(characterId, row, { level, version }); } catch (err) { toast(err.message, 'bad'); return false; }
  if (!p.possible) { toast(p.error || 'This change is not possible.', 'bad'); return false; }
  return new Promise((resolve) => {
    let answered = false;
    const m = openModal({
      title: version ? `Change ${className} version?` : `${className}: level ${p.level.from} → ${p.level.to}?`,
      body: reviewBody(p), wide: true,
      footer: `<button type="button" class="btn" data-close>Cancel</button>
        <button type="button" class="btn btn-gold" data-cf-confirm>${version ? 'Change version' : 'Apply level change'}</button>`,
      onClose: () => { if (!answered) resolve(false); },
    });
    $('[data-cf-confirm]', m.el).addEventListener('click', () => { answered = true; m.close(); resolve(true); });
  });
}

/** What a rest will do with class resources (shown before the rest is taken). */
export function restResourceLines(kind, res) {
  const list = (res?.resources || []).filter((r) => r.active && r.expended > 0);
  const back = list.filter((r) => r.recharge === 'short_or_long_rest' || (kind === 'short' ? r.recharge === 'short_rest' || r.short_rest_recovery
    : ['short_rest', 'long_rest'].includes(r.recharge)));
  const stay = list.filter((r) => !back.includes(r));
  return [back.length ? `Class resources restored: ${back.map((r) => r.name).join(', ')}` : '',
    stay.length ? `Not restored: ${stay.map((r) => r.name).join(', ')}` : ''].filter(Boolean);
}

/** One-line rest result from the server breakdown. */
const restAmount = (x) => (x.amount ? `${x.amount} ${x.unit === 'slots' ? (x.amount === 1 ? 'slot' : 'slots') : (x.amount === 1 ? 'use' : 'uses')}` : '');

/**
 * The summary after a rest: what came back, what did not and why, states that ended. `extra` adds app-side lines
 * (hit points, hit dice on a long rest). Built from the server's breakdown, never guessed.
 */
export function restSummaryHTML(res, { extra = [] } = {}) {
  const b = res?.breakdown || { restored: [], not_restored: [] };
  const why = { long_rest: 'only on a long rest', short_rest: 'on a short rest', dawn: 'at dawn', manual: 'restored by hand', none: 'does not recharge',
    inactive: 'feature not active' };
  const li = (x) => `<li><strong>${esc(x.name)}</strong>${restAmount(x) ? `: ${esc(restAmount(x))}` : ''}${x.partial ? ' (partly)' : ''}${
    x.levels ? ` <span class="muted small">(${x.levels.map((l) => `${l.restored} × level ${l.slot_level}`).join(', ')})</span>` : ''}</li>`;
  const restored = [...b.restored.map(li), ...extra.map((t) => `<li>${esc(t)}</li>`)];
  const notRestored = b.not_restored.map((x) => `<li><strong>${esc(x.name)}</strong>${x.amount ? `: ${esc(restAmount({ ...x, unit: x.name.includes('slot') ? 'slots' : '' }))} still used` : ''}${
    why[x.reason] ? ` <span class="muted small">(${esc(why[x.reason])})</span>` : ''}</li>`);
  const ended = (res?.states_ended || []).map((k) => `<li>${esc(k.charAt(0).toUpperCase() + k.slice(1).replace(/-/g, ' '))}</li>`);
  return `<div class="rest-summary" data-rest-summary>
    <h3 class="small-head">Restored</h3>${restored.length ? `<ul data-rest-restored>${restored.join('')}</ul>` : '<p class="muted" data-rest-restored>Nothing needed restoring.</p>'}
    ${notRestored.length ? `<h3 class="small-head">Not restored</h3><ul data-rest-not-restored>${notRestored.join('')}</ul>` : ''}
    ${ended.length ? `<h3 class="small-head">Ended</h3><ul data-rest-ended>${ended.join('')}</ul>` : ''}
  </div>`;
}

export function restResultText(res) {
  const b = res?.breakdown;
  if (!b) return '';
  const r = b.restored.map((x) => (x.amount ? `${x.name}: ${restAmount(x)}${x.partial ? ' (partly)' : ''}` : x.name));
  const n = b.not_restored.map((x) => x.name);
  const ended = (res.states_ended || []).map((k) => k.charAt(0).toUpperCase() + k.slice(1).replace(/-/g, ' '));
  return `${r.length ? `Restored: ${r.join(', ')}.` : 'Nothing to restore.'}${n.length ? ` Not restored: ${n.join(', ')}.` : ''}${
    ended.length ? ` Ended: ${ended.join(', ')}.` : ''}`;
}
