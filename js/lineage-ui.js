// Lineage UI: the Bio-tab card, the guided picker and the summaries on the Stats and Spells tabs.
// Data-driven: every lineage, version, trait and choice comes from the database; nothing here knows a specific lineage.
import { $, $$, esc, toast, openModal, confirmDialog } from './utils.js?v=23';
import * as api from './lineage-api.js?v=23';
import { getCampaignGovernance } from './governance-api.js?v=23';

const CATEGORY = { standard: 'Standard', custom: 'Custom', exotic: 'Exotic', monstrous: 'Monstrous' };
const ABILITY = { str: 'Strength', dex: 'Dexterity', con: 'Constitution', int: 'Intelligence', wis: 'Wisdom', cha: 'Charisma' };
const AUTOMATION = {
  automatic: ['Applied automatically', 'auto'],
  partial: ['Partly automated', 'partial'],
  informational: ['Information only', 'info'],
};
const RECHARGE = { short_rest: 'short rest', long_rest: 'long rest', short_or_long_rest: 'short or long rest', special: 'special' };
const MOVE = { walk: 'Walk', climb: 'Climb', swim: 'Swim', fly: 'Fly', burrow: 'Burrow' };
const cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : '');
const usesText = (uses, recharge) => {
  if (!uses) return '';
  const n = uses === 'pb' ? 'proficiency bonus' : uses === 'at_will' ? 'at will' : `${uses}×`;
  return uses === 'at_will' ? 'at will' : `${n}${recharge ? ` per ${RECHARGE[recharge] || recharge}` : ''}`;
};

/** Small badges describing a version: legacy, setting, optional. */
export function versionBadges(v) {
  if (!v) return '';
  const b = [];
  if (v.status === 'legacy') b.push('<span class="lin-badge lin-legacy">Legacy</span>');
  else b.push('<span class="lin-badge lin-current">Current</span>');
  if (v.setting) b.push(`<span class="lin-badge">${esc(v.setting)}</span>`);
  if (v.is_optional) b.push('<span class="lin-badge">Optional (DM)</span>');
  return b.join(' ');
}

function automationBadge(t) {
  if (t.status === 'unresolved') return '<span class="lin-auto lin-auto-unresolved">Choice needed</span>';
  if (t.status === 'locked') return `<span class="lin-auto lin-auto-locked">From level ${t.min_level}</span>`;
  const [label, cls] = AUTOMATION[t.automation] || AUTOMATION.informational;
  return `<span class="lin-auto lin-auto-${cls}">${label}</span>`;
}

function traitHTML(t, { replaced = false, from = '' } = {}) {
  const meta = [t.min_level > 1 ? `from level ${t.min_level}` : '', usesText(t.uses, t.recharge)].filter(Boolean).join(' · ');
  return `<li class="lin-trait${replaced ? ' is-replaced' : ''}" data-trait="${esc(t.id)}">
    <div class="lin-trait-head"><strong>${esc(t.name)}${from ? ` <span class="muted small">· ${esc(from)}</span>` : ''}</strong>${replaced ? '<span class="lin-auto lin-auto-locked">Replaced</span>' : automationBadge(t)}</div>
    <p class="small">${esc(t.summary)}</p>
    ${meta ? `<p class="muted small">${esc(meta)}</p>` : ''}
    ${t.interpretation_note ? `<p class="muted small">Note: ${esc(t.interpretation_note)}</p>` : ''}
  </li>`;
}

function valueLabel(choice, value, ref) {
  switch (choice.kind) {
    case 'ability_scores': { const [a, n] = value.split(':'); return `${ABILITY[a] || a} +${n}`; }
    case 'skill': return ref?.skills.find((s) => s.id === value)?.name || value;
    case 'language': return ref?.languages.find((l) => l.id === value)?.name || value;
    case 'tool': case 'weapon': return ref?.items.find((i) => i.id === value)?.name || value;
    case 'skill_or_tool': {
      const [k, id] = value.split(':');
      return (k === 'skill' ? ref?.skills.find((s) => s.id === id)?.name : ref?.items.find((i) => i.id === id)?.name) || id;
    }
    case 'feat': {
      // feat:<version id> from the feat picker (the Feats card shows the full feat); older free text stays as written
      const m = /^feat:(.+)-(2014|2024|ua)$/.exec(value);
      if (!m) return value.replace(/^feat:/, '');
      const name = m[1].split('-').map((w) => (w.length > 2 || w === m[1] ? w[0].toUpperCase() + w.slice(1) : w)).join(' ');
      return `${name} (${m[2] === 'ua' ? 'playtest' : m[2]})`;
    }
    default: return choice.options?.find((o) => o.id === value)?.label || value;
  }
}

// ---------------------------------------------------------------------------------------------------- Bio-tab card
/** Body of the Lineage card. res = get_character_lineage result (null while loading). */
/**
 * A reliable mapping of an old free-text race to the catalog: only an exact lineage name (case, spaces and hyphens ignored).
 * Anything else ("Wood Elf", "Half-Orc (Mark of Finding)") is ambiguous and is not suggested.
 */
export function suggestLineage(race, catalog) {
  const norm = (x) => String(x || '').toLowerCase().replace(/[^a-z]+/g, ' ').trim();
  const n = norm(race);
  if (!n || !catalog?.length) return null;
  const hits = catalog.filter((l) => norm(l.name) === n);
  return hits.length === 1 ? { id: hits[0].id, name: hits[0].name, versions: hits[0].version_count } : null;
}

export function lineageCardHTML(res, character, { editable = true, ref = null, suggestion = null } = {}) {
  if (!res) return '<p class="muted small">Loading lineage…</p>';
  if (!res.selected) {
    // legacy race text: preserved, never converted silently and never a source of mechanics (docs/CHARACTER_CREATION_AUDIT.md)
    const legacy = character.race ? `<div class="lin-callout lin-legacy" data-legacy-race-unmapped>
        <p><strong>Legacy race has not been mapped to a Lineage.</strong> The old sheet says “${esc(character.race)}”. The text is kept and
          grants no traits.</p>
        ${suggestion ? `<p class="small" data-lineage-suggestion="${esc(suggestion.id)}">Suggested lineage: <strong>${esc(suggestion.name)}</strong>
            (exact name match). Review its version, traits and choices before saving.</p>`
          : '<p class="small">No exact match in the lineage catalog: choose the lineage yourself.</p>'}
        ${editable ? `<div class="row gap wrap">${suggestion ? `<button type="button" class="btn btn-gold btn-sm" data-action="lineage-choose" data-lineage-open="${esc(suggestion.id)}"
            data-focus-key="lineage-suggest">Review ${esc(suggestion.name)}…</button>` : ''}
          <button type="button" class="btn ${suggestion ? '' : 'btn-gold'} btn-sm" data-action="lineage-choose" data-focus-key="lineage-choose">Choose lineage…</button></div>` : ''}
      </div>` : '';
    return `<p class="muted">No lineage selected yet.</p>${legacy || (editable
      ? '<button type="button" class="btn btn-gold btn-sm" data-action="lineage-choose" data-focus-key="lineage-choose">Choose lineage…</button>' : '')}`;
  }
  const v = res.version;
  const s = res.subversion;
  const open = res.choices.filter((c) => c.status === 'missing');
  const later = res.choices.filter((c) => c.status === 'later');
  const chosen = res.choices.filter((c) => c.enabled && c.values.length);
  const groups = [
    ['unresolved', 'Waiting for a choice', res.traits.filter((t) => t.status === 'unresolved')],
    ['automatic', 'Applied automatically', res.traits.filter((t) => t.status !== 'unresolved' && t.automation === 'automatic')],
    ['partial', 'Partly automated', res.traits.filter((t) => t.status !== 'unresolved' && t.automation === 'partial')],
    ['informational', 'Information only', res.traits.filter((t) => t.status !== 'unresolved' && t.automation === 'informational')],
  ].filter(([, , list]) => list.length);
  return `
    <div class="lin-summary">
      <div>
        <h3 class="lin-name" data-lineage-name>${esc(res.lineage.name)}${s ? ` · ${esc(s.name)}` : ''}</h3>
        <p class="small">${esc(v.name)} — <a href="${esc(v.source_url)}" target="_blank" rel="noopener">${esc(v.source_label)}</a>
          ${s && s.source_label !== v.source_label ? ` · ${esc(s.name)}: <a href="${esc(s.source_url)}" target="_blank" rel="noopener">${esc(s.source_label)}</a>` : ''}</p>
        <p class="lin-badges">${versionBadges(v)}${s?.setting && s.setting !== v.setting ? ` <span class="lin-badge">${esc(s.setting)}</span>` : ''}
          ${v.creature_type ? `<span class="lin-badge">${esc(cap(v.creature_type))}</span>` : ''}</p>
      </div>
      ${editable ? `<div class="row gap wrap">
        <button type="button" class="btn btn-sm" data-action="lineage-choose" data-focus-key="lineage-choose">Change…</button>
        <button type="button" class="btn btn-sm btn-bad" data-action="lineage-remove" data-focus-key="lineage-remove">Remove</button></div>` : ''}
    </div>
    ${open.length ? `<div class="lin-callout" role="status" data-lineage-unresolved="${open.length}">
        <strong>${open.length} choice${open.length === 1 ? '' : 's'} still open:</strong> ${open.map((c) => esc(c.label)).join(', ')}.
        ${editable ? '<button type="button" class="btn btn-sm btn-gold" data-action="lineage-choose" data-focus-key="lineage-complete">Complete choices…</button>' : ''}
      </div>` : ''}
    ${later.length ? `<p class="muted small">Later: ${later.map((c) => `${esc(c.label)} (level ${c.min_level})`).join(', ')}.</p>` : ''}
    ${res.ability_bonuses_included ? '<p class="muted small">Ability score increases are not added: the entered scores already include them.</p>' : ''}
    ${chosen.length ? `<p class="small lin-chosen">${chosen.map((c) => `<span><span class="muted">${esc(c.label)}:</span> ${c.values.map((x) => esc(valueLabel(c, x, ref))).join(', ')}</span>`).join('')}</p>` : ''}
    ${groups.map(([key, title, list]) => `
      <h4 class="lin-group-title">${title}</h4>
      <ul class="lin-traits" data-group="${key}">${list.map((t) => traitHTML(t, { from: t.origin === 'child' ? s?.name : '' })).join('')}</ul>`).join('')}
    ${res.replaced_traits.length ? `<p class="muted small">Replaced by your choices: ${res.replaced_traits.map((t) => esc(t.name)).join(', ')}.</p>` : ''}`;
}

// --------------------------------------------------------------------------------------------- Stats / Spells tabs
/** What the lineage adds to the character, from get_character_derived_stats. */
export function lineageStatsHTML(d) {
  if (!d) return '<p class="muted small">Loading…</p>';
  // without a lineage the card still lists what the classes give (speed, senses, resistances, immunities)
  const note = d.lineage ? '' : '<p class="muted small" data-no-lineage>No lineage selected. Choose one on the Build tab.</p>';
  const rows = [];
  const add = (label, value, key) => { if (value) rows.push(`<div class="kv" data-lineage-stat="${key}"><span>${label}</span><strong>${value}</strong></div>`); };
  add('Size', d.size ? esc(cap(d.size.value)) : '', 'size');
  add('Creature type', d.creature_type ? esc(cap(d.creature_type)) : '', 'type');
  const mv = d.speed?.movement || {};
  add('Speed', Object.entries(mv).map(([k, m]) => `${MOVE[k] || k} ${m.value} ft${m.active ? '' : ' (not in this armor)'}`).map(esc).join(', '), 'speed');
  add('Senses', Object.entries(d.senses || {}).map(([k, s]) => `${cap(k)} ${s.value} ft`).map(esc).join(', '), 'senses');
  add('Languages', (d.languages || []).map((l) => esc(l.name)).join(', '), 'languages');
  add('Resistances', (d.resistances || []).map((r) => esc(cap(r.damage_type))).join(', '), 'resistances');
  add('Immunities', [...new Set([...(d.immunities || []), ...(d.condition_immunities || [])])]
    .map((x) => esc(cap(typeof x === 'string' ? x : x.condition))).join(', '), 'immunities');
  if (d.initiative?.bonus) add('Initiative', `+${d.initiative.bonus}`, 'initiative');
  if (d.hit_points?.lineage_bonus) add('Hit point maximum', `+${d.hit_points.lineage_bonus} (not added to your HP automatically)`, 'hp');
  if (d.carrying_capacity?.size_steps) add('Carrying capacity', 'counts as one size larger', 'carry');
  const adv = (d.advantages || []).map((a) => `<li><span class="lin-auto lin-auto-partial">${a.kind === 'save_advantage' ? 'Save' : 'Check'}</span>
      Advantage: ${esc(a.scope)} <span class="muted small">(${esc(a.source_name)})</span></li>`).join('');
  if (!d.lineage && !rows.length && !adv) return note;
  return `${note}<div class="kv-list">${rows.join('') || '<p class="muted small">Nothing numeric to apply.</p>'}</div>
    ${adv ? `<h4 class="lin-group-title">Advantages (roll them yourself)</h4><ul class="lin-adv">${adv}</ul>` : ''}`;
}

export function lineageSpellsHTML(d, { spells: withSpells = true } = {}) {
  const spells = withSpells ? d?.lineage_spells || [] : [];
  const actions = d?.lineage_actions || [];
  if (!spells.length && !actions.length) return '';
  return `
    ${spells.length ? `<ul class="lin-spells">${spells.map((s) => `<li class="${s.unlocked ? '' : 'is-locked'}" data-lineage-spell="${esc(s.slug)}">
        <strong>${esc(s.name)}</strong>
        <span class="muted small">${s.uses === 'at_will' ? 'at will' : esc(usesText(s.uses, s.recharge))}${s.cast_level ? ` · as level ${esc(s.cast_level)}` : ''}
        ${s.ability ? ` · ${esc(ABILITY[s.ability])}, DC ${s.save_dc}, +${s.attack_bonus} to hit` : s.ability_needed ? ' · choose a spellcasting ability' : ''}
        ${s.unlocked ? '' : ` · from level ${s.min_level}`}</span></li>`).join('')}</ul>` : ''}
    ${actions.length ? `<ul class="lin-spells">${actions.map((a) => `<li class="${a.unlocked ? '' : 'is-locked'}">
        <strong>${esc(a.name)}</strong>
        <span class="muted small">${esc(usesText(String(a.uses ?? ''), a.recharge))}${a.dice ? ` · ${esc(a.dice)}${a.damage_type ? ` ${esc(a.damage_type)}` : ''}` : ''}
        ${a.save_dc ? ` · DC ${a.save_dc}${a.save_ability ? ` ${esc(a.save_ability.toUpperCase())}` : ''}` : ''}${a.unlocked ? '' : ` · from level ${a.min_level}`}</span></li>`).join('')}</ul>` : ''}
    <p class="muted small">Shown for reference: casting and uses are tracked by you.</p>`;
}

// ------------------------------------------------------------------------------------------------------- picker
/**
 * Guided lineage picker: browse (category + search) -> version -> sub-lineage -> choices -> save.
 * onSaved(result) is called with the get_character_lineage result (or {selected:false} after removal).
 */
export async function openLineagePicker({ characterId, current, level, onSaved, open = null, campaignId = null, host = null,
  saveButton = null, onStep = null }) {
  const st = {
    step: 'browse', cat: 'all', q: '', catalog: [], detail: null, ref: null, policy: null,
    sel: { version: null, sub: null, choices: {}, included: false },
  };
  // host: render inside an existing element (the new-character dialog) with the caller's save button; otherwise a modal
  const m = host ? null : openModal({
    title: 'Choose a lineage',
    wide: true,
    body: '<div data-lin-root><p class="muted">Loading lineages…</p></div>',
    footer: `<button type="button" class="btn" data-close>Cancel</button>
      <button type="button" class="btn btn-gold" data-lin-save hidden>Save lineage</button>`,
  });
  if (host) host.innerHTML = '<div data-lin-root><p class="muted">Loading lineages…</p></div>';
  const rootEl = $('[data-lin-root]', host || m.el);
  const saveBtn = saveButton || $('[data-lin-save]', m.el);

  // campaign content policy (the server enforces it; this only explains and disables for players)
  const isDm = () => !!st.policy?.can_edit;
  function policyReason(v) {
    const c = st.policy?.content;
    if (!c || !v) return null;
    if (v.status === 'legacy' && c.allow_legacy === false) return 'Legacy content is not allowed in this campaign';
    if (v.setting && c.allow_setting === false) return 'Setting-specific content is not allowed in this campaign';
    if (String(v.id).startsWith('cc-') && c.allow_custom === false) return 'Custom campaign content is turned off in this campaign';
    return null;
  }
  const usable = (v) => !policyReason(v) || isDm();

  async function openLineage(id, keepSelection = false) {
    rootEl.innerHTML = '<p class="muted">Loading…</p>';
    st.detail = await api.getLineageDetail(id);
    st.step = 'configure';
    if (!keepSelection) {
      const bases = st.detail.versions.filter((v) => v.kind === 'base');
      const pick = bases.find((v) => v.status === 'current' && usable(v)) || bases.find(usable) || bases[0];
      st.sel = { version: pick && usable(pick) ? pick.id : null, sub: null, choices: {}, included: st.sel.included };
    }
    render();
    $('[data-lin-back]', rootEl)?.focus();
  }

  // ---- derived view of the current selection (mirrors the server rules for the preview; the server decides) ----
  const versionById = (id) => st.detail?.versions.find((v) => v.id === id);
  const children = (id) => st.detail.versions.filter((v) => v.parent_version_id === id);
  function activeChoices() {
    const base = versionById(st.sel.version);
    const sub = versionById(st.sel.sub);
    if (!base) return [];
    const all = [...base.choices, ...(sub?.choices || [])];
    const replaced = replacedTraits();
    return all.filter((c) => (!c.trait_id || !replaced.has(c.trait_id))
      && (!c.parent_choice_id || (st.sel.choices[c.parent_choice_id] || []).includes(c.parent_option_id)));
  }
  function replacedTraits() {
    const base = versionById(st.sel.version);
    const sub = versionById(st.sel.sub);
    const out = new Set();
    if (sub?.replaces_all_parent_traits) base?.traits.forEach((t) => out.add(t.id));
    sub?.traits.forEach((t) => t.replaces.forEach((r) => out.add(r)));
    [...(base?.choices || []), ...(sub?.choices || [])].forEach((c) => c.options.forEach((o) => {
      if ((st.sel.choices[c.id] || []).includes(o.id)) o.replaces.forEach((r) => out.add(r));
    }));
    return out;
  }
  function complete(c) {
    const vals = st.sel.choices[c.id] || [];
    if (c.kind === 'ability_scores') {
      const got = vals.map((v) => Number(v.split(':')[1])).sort().join(',');
      return c.config.patterns.some((p) => [...p].sort().join(',') === got);
    }
    return vals.length === c.pick_count;
  }
  const missing = () => activeChoices().filter((c) => c.required && c.min_level <= level && !complete(c));

  // ---- rendering ----
  function render() {
    saveBtn.hidden = st.step !== 'configure';
    if (st.step === 'browse') renderBrowse(); else renderConfigure();
    onStep?.(st.step, st);
  }

  function renderBrowse() {
    const q = st.q.trim().toLowerCase();
    const rows = st.catalog.filter((l) => (st.cat === 'all' || l.category_id === st.cat) && (!q || l.search_text.toLowerCase().includes(q)));
    const count = (cat) => st.catalog.filter((l) => cat === 'all' || l.category_id === cat).length;
    rootEl.innerHTML = `
      <div class="lin-cats" role="group" aria-label="Lineage categories">
        ${['all', 'standard', 'exotic', 'monstrous', 'custom'].map((cat) => `
          <button type="button" class="inv-chip" data-lin-cat="${cat}" aria-pressed="${st.cat === cat}" aria-selected="${st.cat === cat}">
            ${cat === 'all' ? 'All' : CATEGORY[cat]} <span class="count">${count(cat)}</span></button>`).join('')}
      </div>
      <label class="field mt"><span>Search lineages and sub-lineages</span>
        <input type="search" name="lin-q" value="${esc(st.q)}" placeholder="e.g. halfling, stout, custom" autocomplete="off"></label>
      <ul class="lin-list" aria-live="polite">
        ${rows.length ? rows.map((l) => `<li><button type="button" class="lin-row" data-lin-open="${esc(l.id)}">
            <span class="lin-row-name">${esc(l.name)}${String(l.id).startsWith('cc-') ? ' <span class="lin-badge lin-custom">Campaign custom</span>' : ''}</span>
            <span class="muted small">${CATEGORY[l.category_id] || ''} · ${l.version_count} version${l.version_count === 1 ? '' : 's'}${l.child_count ? ` · ${l.child_count} sub-lineage${l.child_count === 1 ? '' : 's'}` : ''}</span>
            <span class="muted small lin-row-src">${(l.sources || []).map(esc).join(' · ')}</span></button></li>`).join('')
          : '<li class="muted small">No lineage matches the search.</li>'}
      </ul>`;
  }

  function renderConfigure() {
    const d = st.detail;
    const bases = d.versions.filter((v) => v.kind === 'base');
    const base = versionById(st.sel.version);
    const kids = base ? children(base.id) : [];
    const sub = versionById(st.sel.sub);
    const replaced = replacedTraits();
    const choices = activeChoices();
    const miss = missing();
    rootEl.innerHTML = `
      <button type="button" class="btn-link" data-lin-back>← All lineages</button>
      <h3 class="lin-title">${esc(d.name)} <span class="muted small">${CATEGORY[d.category_id] || ''}</span></h3>
      ${d.summary ? `<p class="small">${esc(d.summary)}</p>` : ''}
      <fieldset class="lin-step"><legend>1. Published version</legend>
        <div class="lin-cards">${bases.map((v) => `
          <label class="lin-card ${v.id === st.sel.version ? 'is-selected' : ''} ${policyReason(v) ? 'is-restricted' : ''}">
            <input type="radio" name="lin-version" value="${esc(v.id)}" ${v.id === st.sel.version ? 'checked' : ''} ${usable(v) ? '' : 'disabled'}>
            <span class="lin-card-body"><strong>${esc(v.name)}</strong>
              <span class="small">${esc(v.source_label)}</span>
              <span>${versionBadges(v)}${String(v.id).startsWith('cc-') ? ' <span class="lin-badge lin-custom">Campaign custom</span>' : ''}</span>
              ${policyReason(v) ? `<span class="small warn" data-lin-policy>${esc(policyReason(v))}${isDm() ? ' (you are the DM: allowed for you)' : ''}</span>` : ''}
              ${v.summary ? `<span class="muted small">${esc(v.summary)}</span>` : ''}
              ${v.superseded_by_version_id ? `<span class="muted small">Replaced by ${esc(versionById(v.superseded_by_version_id)?.source_label || 'a newer version')}.</span>` : ''}
            </span></label>`).join('')}</div>
      </fieldset>
      ${kids.length ? `<fieldset class="lin-step"><legend>2. Sub-lineage${base.requires_child ? ' (required)' : ' (optional)'}</legend>
        <div class="lin-cards">
          ${base.requires_child ? '' : `<label class="lin-card ${!st.sel.sub ? 'is-selected' : ''}"><input type="radio" name="lin-sub" value="" ${!st.sel.sub ? 'checked' : ''}>
            <span class="lin-card-body"><strong>None</strong><span class="muted small">Only the base traits.</span></span></label>`}
          ${kids.map((v) => `<label class="lin-card ${v.id === st.sel.sub ? 'is-selected' : ''}">
            <input type="radio" name="lin-sub" value="${esc(v.id)}" ${v.id === st.sel.sub ? 'checked' : ''}>
            <span class="lin-card-body"><strong>${esc(v.name)}</strong><span class="small">${esc(v.source_label)}</span>
              <span>${versionBadges(v)}${v.kind === 'variant' ? ' <span class="lin-badge">Variant</span>' : ''}</span>
              ${v.summary ? `<span class="muted small">${esc(v.summary)}</span>` : ''}</span></label>`).join('')}
        </div></fieldset>` : ''}
      <fieldset class="lin-step"><legend>${kids.length ? '3' : '2'}. Choices</legend>
        ${choices.length ? choices.map((c) => choiceHTML(c)).join('') : '<p class="muted small">This version has no choices.</p>'}
        <label class="check-field mt"><input type="checkbox" name="lin-included" ${st.sel.included ? 'checked' : ''}>
          <span>My entered ability scores already include this lineage’s increases (don’t add them again)</span></label>
      </fieldset>
      <div class="lin-missing" data-lin-missing aria-live="polite">${missingHTML(miss)}</div>
      <details class="lin-preview" open><summary>Traits you get</summary>
        <ul class="lin-traits">
          ${(base?.traits || []).map((t) => traitHTML({ ...t, status: t.min_level > level ? 'locked' : 'active' }, { replaced: replaced.has(t.id) })).join('')}
          ${(sub?.traits || []).map((t) => traitHTML({ ...t, status: t.min_level > level ? 'locked' : 'active' }, { from: sub.name })).join('')}
        </ul>
        ${base?.interpretation_note ? `<p class="muted small">Note: ${esc(base.interpretation_note)}</p>` : ''}
        ${sub?.interpretation_note ? `<p class="muted small">Note: ${esc(sub.interpretation_note)}</p>` : ''}
      </details>`;
  }

  function missingHTML(miss) {
    return miss.length
      ? `<p class="lin-callout small"><strong>Still to choose:</strong> ${miss.map((c) => esc(c.label)).join(', ')}. You can save now and finish later.</p>`
      : '<p class="small lin-ok">All required choices are made.</p>';
  }

  function choiceHTML(c) {
    const vals = st.sel.choices[c.id] || [];
    const name = `lin-choice:${c.id}`;
    const status = complete(c) ? '<span class="lin-auto lin-auto-auto">Done</span>'
      : c.min_level > level ? `<span class="lin-auto lin-auto-locked">From level ${c.min_level}</span>`
        : c.required ? '<span class="lin-auto lin-auto-unresolved">Required</span>' : '<span class="lin-auto lin-auto-info">Optional</span>';
    const pickNote = c.kind === 'ability_scores'
      ? `Allowed: ${c.config.patterns.map((p) => p.map((n) => `+${n}`).join(' / ')).join(', or ')}${c.config.exclude ? ` (not ${c.config.exclude.map((a) => ABILITY[a]).join(', ')})` : ''}`
      : c.pick_count > 1 ? `Choose ${c.pick_count}` : '';
    let input = '';
    const ref = st.ref;
    const selectMany = (opts, n) => Array.from({ length: n }, (_, i) => `
      <select name="${esc(name)}" data-pick="${i}" aria-label="${esc(c.label)} ${n > 1 ? i + 1 : ''}">
        <option value="">— choose —</option>
        ${opts.map((o) => `<option value="${esc(o.id)}" ${vals[i] === o.id ? 'selected' : ''}>${esc(o.label)}</option>`).join('')}
      </select>`).join('');
    switch (c.kind) {
      case 'ability_scores': {
        const amounts = [...new Set(c.config.patterns.flat())].sort();
        input = `<div class="lin-asi">${Object.entries(ABILITY).map(([k, label]) => {
          const cur = vals.find((v) => v.startsWith(`${k}:`))?.split(':')[1] || '';
          const off = (c.config.exclude || []).includes(k);
          return `<label class="field"><span>${label}</span><select name="${esc(name)}" data-ability="${k}" ${off ? 'disabled' : ''}>
            <option value="">+0</option>${amounts.map((n) => `<option value="${n}" ${String(n) === cur ? 'selected' : ''}>+${n}</option>`).join('')}</select></label>`;
        }).join('')}</div>`;
        break;
      }
      case 'size': case 'option': case 'spellcasting_ability':
        input = `<div class="lin-options">${c.options.map((o) => `<label class="lin-option">
          <input type="${c.pick_count > 1 ? 'checkbox' : 'radio'}" name="${esc(name)}" value="${esc(o.id)}" ${vals.includes(o.id) ? 'checked' : ''}>
          <span><strong>${esc(o.label)}</strong>${o.summary ? ` <span class="muted small">${esc(o.summary)}</span>` : ''}</span></label>`).join('')}</div>`;
        break;
      case 'skill': {
        const list = ref.skills.filter((s) => !c.config.from || c.config.from.includes(s.id));
        input = c.pick_count > 1 || list.length <= 8
          ? `<div class="lin-options lin-options-grid">${list.map((s) => `<label class="lin-option">
              <input type="checkbox" name="${esc(name)}" value="${esc(s.id)}" ${vals.includes(s.id) ? 'checked' : ''}><span>${esc(s.name)}</span></label>`).join('')}</div>`
          : selectMany(list.map((s) => ({ id: s.id, label: s.name })), c.pick_count);
        break;
      }
      case 'language':
        input = selectMany(ref.languages.filter((l) => !(c.config.exclude || []).includes(l.id) && (!c.config.from || c.config.from.includes(l.id)))
          .map((l) => ({ id: l.id, label: l.name })), c.pick_count);
        break;
      case 'tool': case 'weapon':
        input = selectMany(ref.items.filter((i) => i.kind === c.kind && (!c.config.from || c.config.from.includes(i.id))
          && (!c.config.category || i.category === c.config.category) && (!c.config.weapon_group || i.weaponGroup === c.config.weapon_group))
          .map((i) => ({ id: i.id, label: i.name })), c.pick_count);
        break;
      case 'skill_or_tool':
        input = selectMany([...ref.skills.map((s) => ({ id: `skill:${s.id}`, label: `Skill: ${s.name}` })),
          ...ref.items.filter((i) => i.kind === 'tool').map((i) => ({ id: `tool:${i.id}`, label: `Tool: ${i.name}` }))], c.pick_count);
        break;
      case 'feat':   // a catalog feat (feat:<version>); older free-text names stay as they are
        input = Array.from({ length: c.pick_count }, (_, i) => `<span class="lin-feat-pick">
          <input type="hidden" name="${esc(name)}" data-pick="${i}" value="${esc(vals[i] || '')}">
          <span class="small" data-feat-label>${vals[i] ? esc(valueLabel(c, String(vals[i]))) : 'none chosen'}</span>
          <button type="button" class="btn btn-xs" data-pick-feat="${esc(name)}" data-prefix="feat:">Choose a feat…</button></span>`).join('');
        break;
      default:   // spell: free text until the lineage spell choices use the spell catalog
        input = Array.from({ length: c.pick_count }, (_, i) => `<input type="text" name="${esc(name)}" data-pick="${i}" maxlength="100"
          value="${esc(vals[i] || '')}" placeholder="${esc(c.config.hint || (c.kind === 'feat' ? 'Feat name' : 'Spell name'))}" aria-label="${esc(c.label)}">`).join('');
    }
    return `<div class="lin-choice" data-choice="${esc(c.id)}" data-kind="${esc(c.kind)}">
      <div class="lin-choice-head"><strong>${esc(c.label)}</strong>${status}</div>
      ${pickNote ? `<p class="muted small">${esc(pickNote)}</p>` : ''}
      ${c.changeable ? '<p class="muted small">The rules let you change this later (e.g. after a long rest).</p>' : ''}
      ${c.kind === 'spell' ? '<p class="muted small">Not automated yet: it is recorded and shown on the sheet.</p>' : ''}
      ${c.kind === 'feat' ? '<p class="muted small">The feat is applied from the feat catalog; make its own choices in the Feats card.</p>' : ''}
      ${input}</div>`;
  }

  /** Read one choice block back into st.sel.choices. */
  function readChoice(block) {
    const id = block.dataset.choice;
    const kind = block.dataset.kind;
    let vals;
    if (kind === 'ability_scores') {
      vals = $$('select[data-ability]', block).filter((s) => s.value).map((s) => `${s.dataset.ability}:${s.value}`);
    } else if (['size', 'option', 'spellcasting_ability'].includes(kind) || $('input[type=checkbox]', block)) {
      vals = $$('input:checked', block).map((i) => i.value);
    } else {
      vals = $$('select, input[type=text], input[type=hidden]', block).map((s) => s.value.trim()).filter(Boolean);   // hidden: a feat from the feat picker
    }
    if (vals.length) st.sel.choices[id] = vals; else delete st.sel.choices[id];
  }

  // ---- events ----
  rootEl.addEventListener('click', async (e) => {
    const cat = e.target.closest('[data-lin-cat]');
    if (cat) { st.cat = cat.dataset.linCat; renderBrowse(); $(`[data-lin-cat="${st.cat}"]`, rootEl)?.focus(); return; }
    const open = e.target.closest('[data-lin-open]');
    if (open) {
      try { await openLineage(open.dataset.linOpen); } catch (err) { toast(err.message, 'bad'); st.step = 'browse'; render(); }
      return;
    }
    if (e.target.closest('[data-lin-back]')) { st.step = 'browse'; render(); $('input[name=lin-q]', rootEl)?.focus(); }
  });
  rootEl.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter' || e.target.name !== 'lin-q') return;
    e.preventDefault();
    $('[data-lin-open]', rootEl)?.click();
  });
  rootEl.addEventListener('input', (e) => {
    if (e.target.name === 'lin-q') {
      st.q = e.target.value;
      const pos = e.target.selectionStart;
      renderBrowse();
      const input = $('input[name=lin-q]', rootEl);
      input.focus();
      input.setSelectionRange(pos, pos);
    }
  });
  rootEl.addEventListener('change', (e) => {
    const t = e.target;
    if (t.name === 'lin-version') { st.sel.version = t.value; st.sel.sub = null; st.sel.choices = {}; renderConfigure(); $('input[name=lin-version]:checked', rootEl)?.focus(); return; }
    if (t.name === 'lin-sub') { st.sel.sub = t.value || null; renderConfigure(); $('input[name=lin-sub]:checked', rootEl)?.focus(); return; }
    if (t.name === 'lin-included') { st.sel.included = t.checked; return; }
    const block = t.closest('[data-choice]');
    if (!block) return;
    const choice = activeChoices().find((c) => c.id === block.dataset.choice);
    // keep the number of picks within the limit for checkbox lists
    if (t.type === 'checkbox' && choice && $$('input:checked', block).length > choice.pick_count) {
      t.checked = false;
      toast(`Choose at most ${choice.pick_count}.`, 'bad');
    }
    readChoice(block);
    // an option can enable a sub-choice or replace traits: re-render; otherwise only refresh the status lines
    if (['option', 'size', 'spellcasting_ability'].includes(block.dataset.kind)) {
      const key = t.name;
      const val = t.value;
      renderConfigure();
      $$(`[name="${CSS.escape(key)}"]`, rootEl).find((x) => x.value === val)?.focus();
    } else {
      const fresh = activeChoices().find((c) => c.id === block.dataset.choice);
      if (fresh) $('.lin-choice-head', block).outerHTML = $('.lin-choice-head', document.createRange().createContextualFragment(choiceHTML(fresh)));
      $('[data-lin-missing]', rootEl).innerHTML = missingHTML(missing());
    }
  });

  saveBtn.addEventListener('click', async () => {
    if (!st.sel.version) return;
    const enabled = new Set(activeChoices().map((c) => c.id));
    const choices = Object.fromEntries(Object.entries(st.sel.choices).filter(([id, v]) => enabled.has(id) && v.length));
    const miss = missing();
    if (miss.length && !(await confirmDialog(`${miss.length} required choice${miss.length === 1 ? ' is' : 's are'} still open (${miss.map((c) => c.label).join(', ')}). Save now and finish later?`,
      { title: 'Save with open choices?', okLabel: 'Save anyway' }))) return;
    saveBtn.disabled = true;
    try {
      const res = await api.setCharacterLineage(characterId, { version: st.sel.version, subversion: st.sel.sub, choices,
        abilityBonusesIncluded: st.sel.included });
      toast(res.unresolved ? `Lineage saved. ${res.unresolved} choice${res.unresolved === 1 ? '' : 's'} still open.` : 'Lineage saved.', 'good');
      m?.close();
      await onSaved?.(res);
    } catch (err) {
      toast(err.message, 'bad');
    } finally { saveBtn.disabled = false; }
  });

  // initial load (after every helper above is defined); an existing lineage opens on its own version
  try {
    [st.catalog, st.ref, st.policy] = await Promise.all([api.getLineageCatalog(), api.getLineageReference(),
      campaignId ? getCampaignGovernance(campaignId).catch(() => null) : null]);
    if (current?.selected && !open) {
      st.sel = { version: current.version.id, sub: current.subversion?.id || null, included: !!current.ability_bonuses_included,
        choices: Object.fromEntries(current.choices.filter((c) => c.values.length).map((c) => [c.id, [...c.values]])) };
      await openLineage(current.lineage.id, true);
    } else if (open && st.catalog.some((l) => l.id === open)) {
      await openLineage(open);
    } else {
      render();
    }
  } catch (err) {
    rootEl.innerHTML = `<p class="muted">${esc(err.message)}</p>`;
    saveBtn.hidden = true;
  }
  return m || { el: host };
}

/** Remove the lineage after confirmation. */
export async function removeLineage(characterId, onSaved) {
  if (!(await confirmDialog('Remove the lineage and its choices? Ability scores, inventory and everything else stay as they are.',
    { title: 'Remove lineage?', okLabel: 'Remove', danger: true }))) return false;
  try {
    await api.clearCharacterLineage(characterId);
    toast('Lineage removed.', 'good');
    await onSaved?.({ selected: false });
    return true;
  } catch (err) {
    toast(err.message, 'bad');
    return false;
  }
}
