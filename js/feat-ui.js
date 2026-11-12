// Feats on the character sheet (docs/FEATS.md): the Feats card of the Build tab, the feat picker with structured details,
// and the choice editors of every feat grant (direct, background, lineage, Ability Score Improvement). The server resolves
// grants, prerequisites, effects, spells and resources (get_character_feats); this module only displays and edits choices.

import { $, $$, esc, toast, openModal, filtersOpenAttr, friendlyError } from './utils.js?v=23';
import { icon } from './icons.js?v=23';
import { sectionHead } from './section.js?v=23';
import { getFeatCatalog, getFeatDetail, getCharacterFeats, assignFeat, removeFeat, previewFeatRemoval, setFeatChoices, setFeatNotes, getChoiceReference, getSpellOptions } from './feat-api.js?v=23';

const ABILITY = { str: 'Strength', dex: 'Dexterity', con: 'Constitution', int: 'Intelligence', wis: 'Wisdom', cha: 'Charisma' };
const CATEGORY = { origin: 'Origin', general: 'General', fighting_style: 'Fighting Style', epic_boon: 'Epic Boon', other: 'Other' };
const STATUS = { official: 'Official', playtest: 'Playtest (UA)', third_party: 'Third-party', unverified: 'Unverified source', homebrew: 'Campaign custom' };
const AUTOMATION = { automated: ['✓', 'Automated'], partially_automated: ['◐', 'Partly automated'], informational: ['ⓘ', 'Reminder only'] };
const SOURCE_ICON = { background: 'ui/background', lineage: 'ui/lineage', class: 'ui/abilities', direct: 'ui/feat', dm_grant: 'dm/dm-grant',
  campaign_reward: 'dm/dm-grant', approved_request: 'dm/approved', import: 'ui/notes' };
// feats grouped by where they come from (docs/UX_INFORMATION_ARCHITECTURE_AUDIT.md S10)
const SOURCE_GROUP = { background: 'From your background', lineage: 'From your lineage', class: 'From your class (Ability Score Improvement)',
  direct: 'Chosen feats', approved_request: 'Chosen feats', import: 'Chosen feats', dm_grant: 'Granted by your DM', campaign_reward: 'Campaign rewards' };
// a feat that a source grants is changed at that source, never removed on its own (docs/FEAT_REMOVAL.md)
const GRANTED = {
  background: ['Granted by your background.', 'To change it, choose another background or change its feat choice.', 'Change background…', 'bg-choose'],
  lineage: ['Granted by your lineage.', 'To change it, change the lineage or its feat choice.', 'Change lineage choice…', 'lineage-choose'],
  class: ['Granted by an Ability Score Improvement of your class.', 'To change it, change that choice in Class features.', 'Change choice…', null],
};
// who may remove a directly assigned feat now (the server decides again; this only labels the action)
const REMOVAL_NOTE = { locked: 'Feats are locked for this character: your DM can unlock or change them.',
  dm_only: 'Only your DM can remove feats in this campaign.' };
const PREREQ = { satisfied: ['✓', 'Prerequisites met'], unsatisfied: ['✗', 'Prerequisites not met'], unresolved: ['?', 'Check with your DM'] };

export const featBadgesHTML = (f) => `
  <span class="feat-b feat-b-${esc(f.ruleset)}">${esc(f.ruleset === 'ua-2022' ? 'UA' : f.ruleset)}</span>
  <span class="feat-b">${esc(CATEGORY[f.category] || f.category)}</span>
  ${f.status && f.status !== 'official' ? `<span class="feat-b feat-b-${esc(f.status)}">${esc(STATUS[f.status] || f.status)}</span>` : ''}
  ${f.setting ? `<span class="feat-b feat-b-setting">${esc(f.setting)}</span>` : ''}
  ${f.automation ? `<span class="feat-b feat-auto-${esc(f.automation)}" title="${esc(AUTOMATION[f.automation]?.[1] || '')}">${AUTOMATION[f.automation]?.[0] || ''} ${esc(AUTOMATION[f.automation]?.[1] || '')}</span>` : ''}`;

const prereqHTML = (p, text) => {
  if (!p) return text ? `<p class="small muted">Prerequisite: ${esc(text)}</p>` : '';
  const [icon, label] = PREREQ[p.status] || PREREQ.unresolved;
  const failing = (p.items || []).filter((i) => i.status !== 'satisfied');
  return `<p class="small feat-pre feat-pre-${esc(p.status)}"><span aria-hidden="true">${icon}</span> ${esc(label)}${text ? `: ${esc(text)}` : ''}
    ${failing.length && p.status !== 'satisfied' ? ` <span class="muted">(${esc(failing.map((i) => i.label + (i.reason ? ` — ${i.reason}` : '')).join('; '))})</span>` : ''}</p>`;
};

// ---- the Feats card --------------------------------------------------------------------------------------------------------
export function featsCardHTML(state, { editable = true, removal = 'allow' } = {}) {
  if (!state) return `${sectionHead({ id: 'feats-card-title', icon: 'build.feat', title: 'Feats' })}<p class="muted small">Loading feats…</p>`;
  const list = state.feats || [];
  const open = state.open_choices || 0;
  return `
  ${sectionHead({ id: 'feats-card-title', icon: 'build.feat', title: 'Feats', count: list.length || '',
    desc: open ? `<span class="feat-open-badge" title="Open feat choices">${open} open choice${open === 1 ? '' : 's'}</span>` : 'Grouped by where each feat comes from.',
    action: editable ? '<button type="button" class="btn btn-sm" data-feat="add" data-focus-key="feat-add">+ Add feat</button>' : '' })}
  ${list.length ? featGroupsHTML(list, editable, removal)
    : '<p class="empty">No feats yet. Backgrounds, lineages and Ability Score Improvements can grant them too.</p>'}
  ${(state.placeholders || []).length ? `<p class="small muted">Recorded by name only (not in the feat catalog): ${esc(state.placeholders.map((p) => p.value).join(', '))}.
    Choose the exact feat again to apply its rules.</p>` : ''}
  ${(state.warnings || []).map((w) => `<p class="small warn">${esc(w.code === 'duplicate_feat' ? `${w.feat_id} is granted ${w.count} times but can be taken only once.` : w.code)}</p>`).join('')}`;
}

function featGroupsHTML(list, editable, removal) {
  const groups = new Map();
  for (const g of list) {
    const k = SOURCE_GROUP[g.source_type] || 'Other feats';
    groups.set(k, [...(groups.get(k) || []), g]);
  }
  return [...groups].map(([k, gs]) => `<h3 class="feat-group-title tl-sub-title">${esc(k)} <span class="count">${gs.length}</span></h3>
    <div class="feat-list">${gs.map((g) => featEntryHTML(g, editable, removal)).join('')}</div>`).join('');
}

/** Where a source-granted feat is changed: the class choice key of an ASI grant ('asi:<row>:<unlock>:<choice>'). */
const asiChoiceKey = (g) => { const p = String(g.grant_key || '').split(':'); return p[0] === 'asi' && p.length >= 4 ? `${p[2]}:${p[3]}` : ''; };

function grantedHTML(g, f, editable) {
  const x = GRANTED[g.source_type];
  if (!x || g.character_feat_id) return '';
  const [why, how, btn, action] = x;
  const key = asiChoiceKey(g);
  const what = btn.replace('…', '');
  const button = !editable ? '' : action
    ? `<button type="button" class="btn btn-xs" data-action="${action}" data-focus-key="feat-src:${esc(g.grant_key)}" aria-label="${esc(`${what} (this changes ${f.name})`)}">${esc(btn)}</button>`
    : key ? `<button type="button" class="btn btn-xs" data-feat="source" data-choice="${esc(key)}" data-focus-key="feat-src:${esc(g.grant_key)}" aria-label="${esc(`Change the Ability Score Improvement choice that grants ${f.name}`)}">${esc(btn)}</button>` : '';
  return `<p class="small feat-granted" data-feat-granted="${esc(g.source_type)}"><span class="feat-granted-why">${esc(why)}</span> ${esc(how)} ${button}</p>`;
}

function removalHTML(g, f, removal) {
  if (!g.character_feat_id) return '';
  if (REMOVAL_NOTE[removal]) return `<span class="small muted feat-rm-note" data-feat-rm-note>${esc(REMOVAL_NOTE[removal])}</span>`;
  const request = removal === 'request';
  return `<button type="button" class="btn btn-xs btn-ghost feat-rm" data-feat="remove" data-cf="${esc(g.character_feat_id)}" data-name="${esc(f.name)}"
    data-focus-key="feat-rm:${esc(g.character_feat_id)}" aria-label="${esc(`${request ? 'Request removal of' : 'Remove'} feat ${f.name}`)}">${request ? 'Request removal…' : 'Remove…'}</button>`;
}

function featEntryHTML(g, editable, removal = 'allow') {
  const f = g.feat || {};
  const auto = (g.effects || []).filter((e) => e.active && e.automation !== 'informational' && e.effect_type !== 'informational');
  const info = (g.effects || []).filter((e) => e.effect_type === 'informational');
  const pending = (g.effects || []).filter((e) => !e.active && e.inactive_reason === 'choice_incomplete');
  return `<article class="feat-card ${g.active ? '' : 'is-inactive'}" data-feat-grant="${esc(g.grant_key)}">
    <header class="feat-card-head">
      <h4>${esc(f.name)}</h4>
      <div class="feat-badges">${featBadgesHTML(f)}${f.scope === 'campaign' ? '<span class="feat-b feat-b-homebrew">Campaign custom</span>' : ''}</div>
    </header>
    <p class="small feat-source">${icon(SOURCE_ICON[g.source_type] || 'ui/feat', { size: 18 })}${esc(g.source_label)}${g.parameter ? ` · ${esc(g.parameter)}` : ''}
      ${g.active ? '' : `<span class="feat-b feat-b-off">Inactive: ${esc(g.inactive_reason === 'lineage_changed' ? 'lineage changed' : g.inactive_reason === 'feature_inactive' ? 'its class feature is not active' : g.inactive_reason || 'inactive')}</span>`}</p>
    ${f.summary ? `<p class="feat-summary">${esc(f.summary)}</p>` : ''}
    ${grantedHTML(g, f, editable)}
    ${g.prerequisite?.status && g.prerequisite.status !== 'satisfied' ? prereqHTML(g.prerequisite, f.prerequisite_text) : ''}
    ${g.prerequisite_override ? `<p class="small muted">Prerequisite waived by the DM: ${esc(g.prerequisite_override.reason)}</p>` : ''}
    ${g.open_choices ? `<p class="feat-open" data-feat-state="${esc(g.state || 'incomplete')}"><strong>Next step:</strong> ${esc(nextStepText(g))}${pending.length || (g.spells || []).length === 0 && hasSpellChoice(g) ? ' Its spells and effects wait for these choices.' : ''}
      ${editable ? `<button type="button" class="btn btn-xs btn-gold" data-feat="choices" data-grant="${esc(g.grant_key)}" data-focus-key="feat-ch:${esc(g.grant_key)}">Choose…</button>` : ''}</p>` : ''}
    <details class="feat-more"><summary>What it does</summary>
      ${auto.length ? `<ul class="feat-effects">${auto.map((e) => `<li><span aria-hidden="true">✓</span> ${esc(effectText(e))}</li>`).join('')}</ul>` : ''}
      ${info.length ? `<ul class="feat-effects feat-info">${info.map((e) => `<li><span aria-hidden="true">ⓘ</span> ${esc(e.label || 'See the source')}</li>`).join('')}</ul>` : ''}
      ${(g.spells || []).length ? `<p class="small"><strong>Spells:</strong> ${esc(g.spells.map((s) => s.name).join(', '))} (in your spellbook under this feat)</p>` : ''}
      ${(g.resources || []).length ? `<p class="small"><strong>Uses:</strong> ${esc(g.resources.map((r) => `${r.name} ${Math.max((r.max ?? 0) - r.expended, 0)}/${r.max ?? '?'}`).join(', '))} (Play tab)</p>` : ''}
      ${(g.choices || []).filter((c) => c.values?.length).map((c) => `<p class="small"><strong>${esc(c.label)}:</strong> ${esc((c.value_labels || c.values).join(', '))}</p>`).join('')}
      ${f.source_url ? `<p class="small"><a href="${esc(f.source_url)}" target="_blank" rel="noopener">Source: ${esc(f.source_label || 'page')}</a></p>` : `<p class="small muted">${esc(f.source_label || '')}</p>`}
    </details>
    ${editable ? `<div class="feat-actions">
      ${(g.choices || []).length ? `<button type="button" class="btn btn-xs" data-feat="choices" data-grant="${esc(g.grant_key)}">Choices</button>` : ''}
      <button type="button" class="btn btn-xs" data-feat="details" data-version="${esc(f.id)}">Details</button>
      ${g.character_feat_id ? `<button type="button" class="btn btn-xs" data-feat="notes" data-cf="${esc(g.character_feat_id)}">Notes</button>
        ${removalHTML(g, f, removal)}` : ''}
    </div>` : ''}
    ${g.notes ? `<p class="small feat-notes">${esc(g.notes)}</p>` : ''}
  </article>`;
}

const hasSpellChoice = (g) => (g.choices || []).some((c) => c.kind === 'spell' || c.kind === 'spell_list');
/** Build "Next step" for a grant that is not applied yet (state from get_character_feats: incomplete | invalidated). */
export function nextStepText(g) {
  const open = (g.choices || []).filter((c) => c.status === 'incomplete' || c.status === 'invalid');
  const bad = open.filter((c) => c.status === 'invalid');
  if (bad.length) return `Choose again: ${bad.map((c) => c.label).join(', ')} ${bad.length === 1 ? 'is' : 'are'} no longer valid.`;
  return `Choose ${open.map((c) => c.label).join(', ') || 'the remaining options'}.`;
}

function effectText(e) {
  const v = e.value != null ? Number(e.value) : null;
  switch (e.effect_type) {
    case 'ability_bonus': return `+${v} ${ABILITY[e.target] || e.target}`;
    case 'hp_per_level': return `+${v} hit points per level`;
    case 'hp_flat': return `+${v} hit point maximum`;
    case 'initiative_bonus': return e.value_text === 'pb' ? 'Proficiency Bonus to Initiative' : `+${v} Initiative`;
    case 'speed_bonus': return `+${v} ft speed`;
    case 'ac_bonus': return `+${v} AC${e.label ? ` (${e.label})` : ''}`;
    case 'attack_bonus': return `+${v} to attack rolls${e.label ? ` (${e.label})` : ''}`;
    case 'damage_bonus': return `+${v} damage${e.label ? ` (${e.label})` : ''}`;
    case 'proficiency': return `Proficiency: ${String(e.value_text || '').replace(/[-_]/g, ' ')}${e.target ? ` (${e.target})` : ''}`;
    case 'expertise': return `Expertise: ${String(e.value_text || '').replace(/_/g, ' ')}`;
    case 'resistance': return `Resistance: ${e.value_text || e.target}`;
    case 'sense': return `${e.target} ${v} ft`;
    case 'attack': return e.label || 'Attack';
    default: return e.label || e.effect_type;
  }
}

// ---- choice editors --------------------------------------------------------------------------------------------------------
async function choiceFormHTML(choices, values, ctx = {}) {
  const ref = await getChoiceReference().catch(() => ({ skills: [], tools: [], languages: [], damageTypes: [], weapons: [] }));
  const parts = [];
  for (const c of choices) {
    const vals = values[c.key] || c.values || [];
    if (c.fixed || c.status === 'fixed') {
      parts.push(`<fieldset class="feat-choice"><legend>${esc(c.label)}</legend><p class="small">${esc((c.value_labels || vals).join(', '))} <span class="muted">(set by the source)</span></p></fieldset>`);
      continue;
    }
    const max = c.max ?? c.max_picks ?? 1;
    const min = c.min ?? c.min_picks ?? 1;
    const name = `fc-${c.key}`;
    const cfg = c.config || {};
    const boxes = (opts) => `<div class="feat-opts" data-max="${max}">${opts.map(([v, l]) =>
      `<label class="check-field"><input type="${max === 1 ? 'radio' : 'checkbox'}" name="${esc(name)}" value="${esc(v)}" ${vals.includes(v) ? 'checked' : ''}><span>${esc(l)}</span></label>`).join('')}</div>`;
    let ctl = '';
    switch (c.kind) {
      case 'ability_increase': case 'ability': case 'spellcasting_ability':
        ctl = boxes((cfg.from || Object.keys(ABILITY)).map((k) => [k, ABILITY[k] + (c.kind === 'ability_increase' ? ` +${cfg.amount || 1}` : '')])); break;
      case 'asi_points': {
        const pairs = vals.map((v) => v.split(':'));
        const two = pairs.length === 2;
        const sel = (n, cur) => `<select name="${esc(name)}-${n}" aria-label="Ability">${Object.entries(ABILITY).map(([k, l]) => `<option value="${k}" ${cur === k ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
        ctl = `<label class="cf-opt"><input type="radio" name="${esc(name)}-mode" value="one" ${two ? '' : 'checked'}><span>+2 to ${sel(1, pairs[0]?.[0])}</span></label>
          <label class="cf-opt"><input type="radio" name="${esc(name)}-mode" value="two" ${two ? 'checked' : ''}><span>+1 to ${sel(2, pairs[0]?.[0])} and +1 to ${sel(3, pairs[1]?.[0] || 'dex')}</span></label>`;
        break;
      }
      case 'skill': case 'expertise':
        ctl = boxes(ref.skills.filter((s) => !cfg.from || cfg.from.includes(s.id)).map((s) => [s.id, s.name])); break;
      case 'tool':
        ctl = boxes(ref.tools.filter((t) => !cfg.category || t.category_id === cfg.category).map((t) => [t.id, t.name])); break;
      case 'skill_or_tool':
        ctl = `<p class="small muted">Skills</p>${boxes(ref.skills.map((s) => [`skill:${s.id}`, s.name]))}<p class="small muted">Tools</p>${boxes(ref.tools.map((t) => [`tool:${t.id}`, t.name]))}`; break;
      case 'language': ctl = boxes(ref.languages.map((l) => [l.id, l.name])); break;
      case 'damage_type': ctl = boxes(ref.damageTypes.filter((d) => !cfg.from || cfg.from.includes(d.id)).map((d) => [d.id, d.name])); break;
      case 'weapon': ctl = boxes(ref.weapons.map((w) => [w.id, w.name])); break;
      case 'spell_list': case 'option': ctl = boxes((c.options || c.config?.options || []).map((o) => [o.option_id || o.id, o.label])); break;
      case 'spell': {
        const listKey = cfg.list_from;
        ctl = `<div class="feat-spells" data-spell-choice="${esc(c.key)}" data-level="${cfg.level ?? ''}" data-list-from="${esc(listKey || '')}"
                 data-schools="${esc((cfg.schools || []).join(','))}" data-selected="${esc(vals.join(','))}" data-max="${max}">
                 <p class="muted small">${listKey ? 'Choose the spell list first.' : 'Loading spells…'}</p></div>`;
        break;
      }
      default:
        ctl = `<input name="${esc(name)}" value="${esc(vals[0] || '')}" maxlength="200" aria-label="${esc(c.label)}">`;
    }
    parts.push(`<fieldset class="feat-choice" data-choice="${esc(c.key)}" data-kind="${esc(c.kind)}" data-max="${max}" data-min="${min}">
      <legend>${esc(c.label)} <span class="muted small">${min === max ? `choose ${max}` : `choose ${min}–${max}`}</span></legend>${ctl}</fieldset>`);
  }
  return parts.join('') || '<p class="muted small">This feat has no choices.</p>';
}

/** Fill the spell choice boxes (they depend on the chosen list) and enforce "choose N" on checkbox groups. */
function wireChoiceForm(form, fixedList = {}) {
  const spellBoxes = async () => {
    for (const box of $$('[data-spell-choice]', form)) {
      const listKey = box.dataset.listFrom;
      const listId = listKey ? ($(`[name="fc-${listKey}"]:checked`, form)?.value || fixedList[listKey] || null) : null;
      if (listKey && !listId) { box.innerHTML = '<p class="muted small">Choose the spell list first.</p>'; continue; }
      const sig = `${listId}|${box.dataset.level}|${box.dataset.schools}`;
      if (box.dataset.sig === sig) continue;
      box.dataset.sig = sig;
      box.innerHTML = '<p class="muted small">Loading spells…</p>';
      try {
        const spells = await getSpellOptions({ level: box.dataset.level === '' ? null : Number(box.dataset.level), listId,
          schools: box.dataset.schools ? box.dataset.schools.split(',') : null });
        const sel = (box.dataset.selected || '').split(',').filter(Boolean);
        const max = Number(box.dataset.max) || 1;
        box.innerHTML = spells.length ? `<div class="feat-opts feat-opts-scroll" data-max="${max}">${spells.map((s) => `<label class="check-field">
          <input type="${max === 1 ? 'radio' : 'checkbox'}" name="fc-${esc(box.dataset.spellChoice)}" value="${esc(s.id)}" ${sel.includes(s.id) ? 'checked' : ''}>
          <span>${esc(s.name)}${s.rule_status !== 'official' ? ` <span class="muted small">(${esc(s.rule_status)})</span>` : ''}</span></label>`).join('')}</div>`
          : '<p class="muted small">No matching spells in the catalog.</p>';
      } catch (err) { box.innerHTML = `<p class="warn small">${esc(err.message)}</p>`; }
    }
    limitPicks(form);
  };
  form.addEventListener('change', (e) => {
    if (e.target.closest('[data-kind="spell_list"]')) spellBoxes();
    limitPicks(form);
  });
  spellBoxes();
}

function limitPicks(form) {
  $$('.feat-opts', form).forEach((grp) => {
    const max = Number(grp.dataset.max) || 1;
    const boxes = $$('input[type="checkbox"]', grp);
    const n = boxes.filter((b) => b.checked).length;
    boxes.forEach((b) => { b.disabled = !b.checked && n >= max; });
  });
}

function collectChoices(form) {
  const out = {};
  $$('[data-choice]', form).forEach((fs) => {
    const key = fs.dataset.choice;
    const name = `fc-${key}`;
    if (fs.dataset.kind === 'asi_points') {
      const two = $(`[name="${name}-mode"]:checked`, fs)?.value === 'two';
      out[key] = two ? [`${$(`[name="${name}-2"]`, fs).value}:1`, `${$(`[name="${name}-3"]`, fs).value}:1`] : [`${$(`[name="${name}-1"]`, fs).value}:2`];
      return;
    }
    const checked = $$(`[name="${CSS.escape(name)}"]`, fs).filter((i) => (i.type === 'checkbox' || i.type === 'radio') ? i.checked : i.value.trim());
    if (checked.length || $$(`[name="${CSS.escape(name)}"]`, fs).length) out[key] = checked.map((i) => i.value.trim());
  });
  return out;
}

// ---- picker ------------------------------------------------------------------------------------------------------------------
/**
 * The feat picker. mode 'assign' (default): pick, fill the choices, take the feat (assign_character_feat; in a campaign that
 * needs approval the sheet offers a request). mode 'pick': return the chosen version (ASI / lineage feat choices).
 */
export async function openFeatPicker({ characterId, mode = 'assign', title = 'Choose a feat', category = null, focus = null, onPick, onChanged } = {}) {
  const m = openModal({
    title, wide: true,
    body: `<div class="feat-picker">
      <div class="feat-filters">
        <input type="search" data-q placeholder="Search feats" aria-label="Search feats">
        <details class="filter-more" ${filtersOpenAttr()}><summary>Filters</summary><div class="filter-more-body">
        <select data-ruleset aria-label="Rules version"><option value="">Any rules</option><option value="2024">2024</option><option value="2014">2014</option></select>
        <select data-category aria-label="Category"><option value="">All categories</option>${Object.entries(CATEGORY).map(([k, l]) => `<option value="${k}" ${category === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
        <select data-status aria-label="Source"><option value="">All sources</option><option value="official">Official</option><option value="legacy">Legacy (2014)</option>
          <option value="setting">Setting-specific</option><option value="playtest">Playtest / other</option><option value="homebrew">Campaign custom</option></select>
        <label class="check-field"><input type="checkbox" data-eligible ${characterId ? 'checked' : 'disabled'}><span>Eligible only</span></label>
        <label class="check-field"><input type="checkbox" data-asi><span>Ability increase</span></label>
        <label class="check-field"><input type="checkbox" data-spells><span>Spells</span></label>
        <label class="check-field"><input type="checkbox" data-prof><span>Proficiencies</span></label>
        <label class="check-field"><input type="checkbox" data-repeat><span>Repeatable</span></label>
        <select data-tag aria-label="Theme"><option value="">Any theme</option><option value="combat">Combat</option><option value="exploration">Exploration</option>
          <option value="social">Social</option><option value="spellcasting">Spellcasting</option></select>
        </div></details>
      </div>
      <p class="muted small" data-count role="status" aria-live="polite">Loading the feat catalog…</p>
      <div class="feat-picker-body"><ul class="feat-results" data-results></ul><div class="feat-detail" data-detail>
        <p class="muted">Select a feat to see what it does.</p></div></div>
    </div>`,
    footer: '<button type="button" class="btn" data-close>Close</button>',
  });
  let all = [];
  try { all = await getFeatCatalog(characterId); } catch (err) { $('[data-count]', m.el).textContent = err.message; return; }
  const f = () => ({
    q: $('[data-q]', m.el).value.trim().toLowerCase(), ruleset: $('[data-ruleset]', m.el).value, category: $('[data-category]', m.el).value,
    status: $('[data-status]', m.el).value, eligible: $('[data-eligible]', m.el).checked, asi: $('[data-asi]', m.el).checked,
    spells: $('[data-spells]', m.el).checked, prof: $('[data-prof]', m.el).checked, repeat: $('[data-repeat]', m.el).checked, tag: $('[data-tag]', m.el).value,
  });
  const usable = (x) => !x.policy_reason && !(x.taken > 0 && x.repeatable === 'once');
  function list() {
    const v = f();
    const shown = all.filter((x) => (!v.q || x.name.toLowerCase().includes(v.q) || (x.summary || '').toLowerCase().includes(v.q))
      && (!v.ruleset || x.ruleset === v.ruleset) && (!v.category || x.category === v.category)
      && (!v.status || (v.status === 'legacy' ? x.legacy : v.status === 'setting' ? !!x.setting : v.status === 'playtest' ? ['playtest', 'third_party', 'unverified'].includes(x.status) : x.status === v.status))
      && (!v.eligible || (usable(x) && x.prerequisite?.status !== 'unsatisfied'))
      && (!v.asi || x.grants.ability) && (!v.spells || x.grants.spells) && (!v.prof || x.grants.proficiency)
      && (!v.repeat || x.repeatable !== 'once') && (!v.tag || (x.tags || []).includes(v.tag)))
      .sort((a, b) => (usable(b) - usable(a)) || ((a.prerequisite?.status === 'unsatisfied') - (b.prerequisite?.status === 'unsatisfied'))
        || (a.scope === 'campaign' ? -1 : 0) - (b.scope === 'campaign' ? -1 : 0) || a.name.localeCompare(b.name) || b.ruleset.localeCompare(a.ruleset));
    $('[data-count]', m.el).textContent = `${shown.length} of ${all.length} feats`;
    $('[data-results]', m.el).innerHTML = shown.slice(0, 200).map((x) => `<li>
      <button type="button" class="feat-row ${usable(x) && x.prerequisite?.status !== 'unsatisfied' ? '' : 'is-locked'}" data-pick="${esc(x.id)}">
        <span class="feat-row-name">${esc(x.name)}</span>
        <span class="feat-badges">${featBadgesHTML(x)}${x.scope === 'campaign' ? '<span class="feat-b feat-b-homebrew">Campaign custom</span>' : ''}</span>
        <span class="small">${esc(x.summary || '')}</span>
        ${x.prerequisite_text ? `<span class="small muted">Prerequisite: ${esc(x.prerequisite_text)}${x.prerequisite ? ` · ${esc(PREREQ[x.prerequisite.status]?.[1] || '')}` : ''}</span>` : ''}
        ${x.policy_reason ? `<span class="small warn">${esc(x.policy_reason)}</span>` : ''}
        ${x.taken ? `<span class="small muted">You have it${x.taken > 1 ? ` ×${x.taken}` : ''}${x.repeatable === 'once' ? '' : ' (repeatable)'}</span>` : ''}
      </button></li>`).join('') + (shown.length > 200 ? '<li class="muted small">Refine the search to see more.</li>' : '');
  }
  async function detail(id) {
    const box = $('[data-detail]', m.el);
    box.innerHTML = '<p class="muted">Loading…</p>';
    let d;
    try { d = await getFeatDetail(id); } catch (err) { box.innerHTML = `<p class="warn">${esc(err.message)}</p>`; return; }
    const row = all.find((x) => x.id === id);
    const choices = (d.choices || []).map((c) => ({ ...c, min: c.min_picks, max: c.max_picks, options: c.options }));
    box.innerHTML = `<h3>${esc(d.name)}</h3><div class="feat-badges">${featBadgesHTML(d)}</div>
      <p>${esc(d.summary || '')}</p>
      ${prereqHTML(row?.prerequisite, d.prerequisite_text)}
      ${d.repeatable !== 'once' ? `<p class="small">Repeatable${d.repeatable === 'repeatable_distinct' ? ' (each time with a different choice)' : ''}.</p>` : ''}
      ${(d.ability_increase || []).length ? `<p class="small"><strong>Ability increase:</strong> ${esc(d.ability_increase.map((a) => a.points ? `${a.points} points` : `+${a.amount || 1} ${(a.from || []).map((k) => k.toUpperCase()).join(' / ')} (max ${a.max || 20})`).join('; '))}</p>` : ''}
      ${(d.effects || []).length ? `<ul class="feat-effects">${d.effects.map((e) => `<li>${e.effect_type === 'informational' ? 'ⓘ' : '✓'} ${esc(e.label || effectText(e))}</li>`).join('')}</ul>` : ''}
      ${(d.spell_grants || []).length ? `<p class="small"><strong>Spells:</strong> ${esc(d.spell_grants.map((s) => s.spell_name || s.label).join(', '))}</p>` : ''}
      ${(d.resources || []).length ? `<p class="small"><strong>Uses:</strong> ${esc(d.resources.map((r) => r.name).join(', '))}</p>` : ''}
      <p class="small muted">${esc(d.implementation_note || '')} ${d.source_url ? `<a href="${esc(d.source_url)}" target="_blank" rel="noopener">${esc(d.source_label || 'Source')}</a>` : esc(d.source_label || '')}</p>
      ${(d.other_versions || []).length ? `<p class="small muted">Other versions: ${d.other_versions.map((o) => `<button type="button" class="btn btn-xs btn-ghost" data-pick="${esc(o.id)}">${esc(o.ruleset)}</button>`).join(' ')}</p>` : ''}
      ${mode === 'assign' && choices.length ? `<form class="feat-choice-form" data-choice-form>${await choiceFormHTML(choices, {})}</form>` : ''}
      <div class="feat-detail-actions">${row?.policy_reason ? `<p class="warn small">${esc(row.policy_reason)}</p>` : ''}
        ${mode === 'view' ? '' : `<button type="button" class="btn btn-gold" data-take="${esc(id)}" ${row?.policy_reason ? 'disabled' : ''}>${mode === 'pick' ? 'Choose this feat' : 'Take this feat'}</button>`}</div>`;
    const form = $('[data-choice-form]', box);
    if (form) wireChoiceForm(form);
  }
  m.el.addEventListener('input', (e) => { if (e.target.closest('.feat-filters')) list(); });
  // selects and checkboxes; the search box already filters on 'input' (its 'change' on blur would re-render the results
  // under the pointer and swallow the click that caused the blur)
  m.el.addEventListener('change', (e) => { if (e.target.closest('.feat-filters') && e.target.type !== 'search') list(); });
  m.el.addEventListener('click', async (e) => {
    const pick = e.target.closest('[data-pick]');
    if (pick) { detail(pick.dataset.pick); return; }
    const take = e.target.closest('[data-take]');
    if (!take) return;
    const id = take.dataset.take;
    if (mode === 'pick') { m.close(); onPick?.(all.find((x) => x.id === id) || { id }); return; }
    const form = $('[data-choice-form]', m.el);
    take.disabled = true;
    try {
      await assignFeat(characterId, id, form ? collectChoices(form) : {});
      toast('Feat added.', 'good');
      m.close();
      onChanged?.();
    } catch (err) {
      take.disabled = false;
      if (err.code !== 'TLAPR') toast(err.message, 'bad'); else m.close();
    }
  });
  list();
  if (focus) { $('[data-eligible]', m.el).checked = false; list(); detail(focus); } else $('[data-q]', m.el).focus();
}

/** The options of 'spell_list' / 'option' choices: from the grant (get_character_feats, 20261109000100) or, for an older
 *  server or a cached read without them, from the feat version's detail (the same rows). Without options such a choice had no
 *  buttons, its dependent spell pickers never loaded and only the other choices were saved (docs/FEAT_SYSTEM_AUDIT.md). */
async function choicesWithOptions(grant) {
  const choices = (grant.choices || []).map((c) => ({ ...c }));
  const missing = choices.filter((c) => (c.kind === 'spell_list' || c.kind === 'option') && !(c.options || []).length && !c.fixed);
  if (!missing.length) return choices;
  const detail = await getFeatDetail(grant.feat?.id || grant.feat_version_id).catch(() => null);
  const byKey = new Map((detail?.choices || detail?.feat?.choices || []).map((c) => [c.key, c.options || []]));
  for (const c of missing) c.options = byKey.get(c.key) || [];
  return choices;
}

/** Edit the choices of one grant (any source). */
export async function openFeatChoices({ characterId, grant, onChanged }) {
  const choices = await choicesWithOptions(grant);
  const m = openModal({ title: `${grant.feat?.name || 'Feat'}: choices`, wide: true,
    body: `<form class="feat-choice-form" data-choice-form>${await choiceFormHTML(choices, {})}</form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-save>Save choices</button>' });
  const fixed = Object.fromEntries((grant.choices || []).filter((c) => c.status === 'fixed').map((c) => [c.key, c.values?.[0]]));
  wireChoiceForm($('[data-choice-form]', m.el), fixed);
  $('[data-save]', m.el).addEventListener('click', async (e) => {
    e.target.disabled = true;
    try {
      const res = await setFeatChoices(characterId, grant.grant_key, collectChoices($('[data-choice-form]', m.el)));
      const after = res?.feats?.find((x) => x.grant_key === grant.grant_key);
      // say what was actually stored: "saved" only when every required choice is complete and the mechanics are applied
      if (after && after.open_choices) toast(`Saved, but not complete yet. ${nextStepText(after)}`, 'warn', 7000);
      else toast(after?.spells?.length ? 'Choices saved. The spells are in your spellbook.' : 'Choices saved.', 'good');
      m.close();
      onChanged?.();
    } catch (err) { e.target.disabled = false; if (err.code !== 'TLAPR') toast(err.message, 'bad'); else m.close(); }
  });
}

/** Delegated handlers of the Feats card. state() returns the last get_character_feats result. */
export function attachFeatHandlers(root, { getCharacterId, getState, onChanged }) {
  root.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-feat]');
    if (!b || !root.contains(b)) return;
    const characterId = getCharacterId();
    const st = getState();
    switch (b.dataset.feat) {
      case 'add': openFeatPicker({ characterId, onChanged }); break;
      case 'choices': {
        const grant = st?.feats?.find((g) => g.grant_key === b.dataset.grant);
        if (grant) openFeatChoices({ characterId, grant, onChanged });
        break;
      }
      case 'details': openFeatPicker({ characterId, mode: 'view', title: 'Feat details', focus: b.dataset.version }); break;
      case 'notes': {
        const g = st?.feats?.find((x) => x.character_feat_id === b.dataset.cf);
        const m = openModal({ title: 'Notes', body: `<textarea data-n rows="4" maxlength="1000" aria-label="Notes">${esc(g?.notes || '')}</textarea>`,
          footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-s>Save</button>' });
        $('[data-s]', m.el).addEventListener('click', async () => {
          try { await setFeatNotes(b.dataset.cf, $('[data-n]', m.el).value); m.close(); onChanged?.(); } catch (err) { toast(err.message, 'bad'); }
        });
        break;
      }
      case 'remove': openRemoveFeat({ characterFeatId: b.dataset.cf, name: b.dataset.name, onChanged }); break;
      case 'source': revealChoice(b.dataset.choice); break;
      default:
    }
  });
  pickCharacter = getCharacterId;
  if (!pickListening) {
    pickListening = true;
    document.addEventListener('click', onPickFeat);   // also inside modals (the lineage picker)
  }
}

// ---- removal (docs/FEAT_REMOVAL.md) ------------------------------------------------------------------------------------
const ABBR = { STR: 'Strength', DEX: 'Dexterity', CON: 'Constitution', INT: 'Intelligence', WIS: 'Wisdom', CHA: 'Charisma' };
const shown = (x) => (x == null ? 'none' : typeof x === 'object' ? JSON.stringify(x) : String(x));

/** The server's simulated diff as a consequence list: "Maximum HP: 48 → 40", "Removed: Spells: Shield (…)". */
export function removalDiffHTML(diff) {
  const items = [];
  for (const d of diff || []) {
    const label = ABBR[d.label] ? `${ABBR[d.label]} score` : d.label;
    if (d.kind === 'changed') {
      items.push(`<li>${esc(label)}: ${esc(shown(d.before))} <span aria-hidden="true">→</span><span class="sr-only">changes to</span> ${esc(shown(d.after))}</li>`);
    } else {
      (d.removed || []).forEach((x) => items.push(`<li><span class="feat-rm-minus" aria-hidden="true">−</span><span class="sr-only">Removed:</span> ${esc(label)}: ${esc(shown(x))}</li>`));
      (d.added || []).forEach((x) => items.push(`<li><span aria-hidden="true">+</span><span class="sr-only">Added:</span> ${esc(label)}: ${esc(shown(x))}</li>`));
    }
  }
  return items.length ? `<ul class="feat-rm-list" data-rf-diff>${items.join('')}</ul>` : '<p class="small muted" data-rf-diff>No other value of the sheet changes.</p>';
}

const ABSENT = (err) => err?.code === 'P0002' || err?.raw?.hint === 'feat_absent';

/** Review dialog: source, exact consequences (server simulation), governance, then Remove feat / Request removal. */
async function openRemoveFeat({ characterFeatId, name, onChanged }) {
  const m = openModal({ title: `Remove feat: ${name}`,
    body: `<div data-rf-body><p class="muted" role="status">Checking what removing ${esc(name)} changes…</p></div><p class="small" data-rf-status role="status" aria-live="polite"></p>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-bad" data-rf-ok disabled>Remove feat</button>' });
  const ok = $('[data-rf-ok]', m.el);
  const status = $('[data-rf-status]', m.el);
  let pv = null;
  try { pv = await previewFeatRemoval(characterFeatId); } catch (err) {
    if (ABSENT(err)) { m.close(); toast(err.message, 'info'); onChanged?.(); return; }
    // an older server without the preview: the plain statement of what is removed
    $('[data-rf-body]', m.el).innerHTML = `<p>Remove <strong>${esc(name)}</strong>? Only what this feat gave is removed; the same spell or proficiency from another source stays.</p>`;
  }
  const request = pv?.decision === 'approval_required';
  if (pv) {
    $('[data-rf-body]', m.el).innerHTML = `
      <p><strong>${esc(pv.feat_name || name)}</strong> <span class="muted">· ${esc(pv.source_label || 'Feat')}</span></p>
      ${pv.ok ? `<h3 class="feat-rm-h">What changes</h3>${removalDiffHTML(pv.diff)}
        <p class="small muted">Only what this feat gave is removed: its choices, spells, uses and bonuses. The same spell, proficiency or bonus from another source stays. Current HP is never raised; it is lowered only if it is above the new maximum.</p>
        ${request ? `<p class="callout" data-rf-request>Feat changes need your DM's approval in this campaign: this sends a removal request. Nothing changes until your DM approves it.</p>`
          : '<p class="small" data-rf-permanent>This is permanent. You can add the feat again later and make its choices again.</p>'}`
        : `<p class="gov-error" role="alert" data-rf-refused>${esc(friendlyError({ message: pv.message || '' }, 'This feat cannot be removed now.'))}</p>`}`;
    if (!pv.ok) ok.hidden = true;
    ok.textContent = request ? 'Request removal' : 'Remove feat';
  }
  if (m.el.dataset.closing || !m.el.isConnected) return;   // cancelled while the preview loaded
  ok.disabled = false;
  if (!ok.hidden) ok.focus();
  let busy = false;
  ok.addEventListener('click', async () => {
    if (busy) return;                  // one request per dialog: a double click applies once
    busy = true;
    ok.disabled = true;
    if (request) m.close();            // the campaign's "Ask your DM" dialog opens for the refused call (request-ui)
    else status.textContent = 'Removing…';
    try {
      await removeFeat(characterFeatId);
      m.close();
      toast(`Feat removed: ${pv?.feat_name || name}.`, 'good');
      onChanged?.();
    } catch (err) {
      if (err.code === 'TLAPR') return;
      if (ABSENT(err)) { m.close(); toast(err.message, 'info'); onChanged?.(); return; }
      if (request) { toast(err.message, 'bad'); return; }
      status.setAttribute('role', 'alert');
      status.textContent = `${err.message} Nothing was removed.`;
      busy = false;
      ok.disabled = false;
    }
  });
}

/** "Change choice…" of an ASI-granted feat: open that choice in Class features and move focus into it. */
function revealChoice(key) {
  const wrap = key && document.querySelector(`[data-cf-choice-wrap="${CSS.escape(key)}"]`);
  if (!wrap) { toast('Open Class features to change this choice.', 'info'); return; }
  for (let a = wrap.parentElement; a; a = a.parentElement) if (a.tagName === 'DETAILS') a.open = true;
  const change = $('details.cf-change', wrap);
  if (change) change.open = true;
  wrap.scrollIntoView({ block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  ($('input[name="asi-mode"]:checked', wrap) || $('summary, input, select, button', wrap))?.focus({ preventScroll: true });
}

// "Choose a feat…" buttons of ASI and lineage choices write the picked version into their form field
let pickCharacter = () => null;
let pickListening = false;
function onPickFeat(e) {
  {
    const b = e.target.closest('[data-pick-feat]');
    if (!b) return;
    e.preventDefault();
    openFeatPicker({ characterId: pickCharacter(), mode: 'pick', title: 'Choose a feat', onPick: (x) => {
      const form = b.closest('form') || b.parentElement;
      const input = $(`[name="${CSS.escape(b.dataset.pickFeat)}"]`, form);
      if (input) { input.value = b.dataset.prefix ? `${b.dataset.prefix}${x.id}` : x.id; input.dispatchEvent(new Event('input', { bubbles: true })); input.dispatchEvent(new Event('change', { bubbles: true })); }   // the lineage dialog reads choices on 'change'
      const lbl = $('[data-feat-label]', b.parentElement);
      if (lbl) lbl.textContent = `${x.name} (${x.ruleset})`;
      const radio = $('input[type="radio"][value="feat"]', b.closest('.cf-asi') || form);
      if (radio) { radio.checked = true; radio.dispatchEvent(new Event('change', { bubbles: true })); }
    } });
  }
}

export const loadCharacterFeats = getCharacterFeats;
