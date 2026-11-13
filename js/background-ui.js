// Background card on the Build tab and its dialogs (docs/BACKGROUNDS.md): choose a background version (2024 or legacy, never
// mixed), allocate the 2024 ability increases, make the choices, review and apply the starting equipment once, replace a
// duplicated proficiency, keep personal characteristics. The server validates everything (set_character_background).
import { $, $$, esc, toast, openModal, confirmDialog } from './utils.js?v=30';
import * as api from './background-api.js?v=30';
import { loadIntoPicker } from './catalog-load.js?v=30';
import { SKILLS } from './dnd.js?v=30';

const AB = { str: 'Strength', dex: 'Dexterity', con: 'Constitution', int: 'Intelligence', wis: 'Wisdom', cha: 'Charisma' };
const ABS = { str: 'STR', dex: 'DEX', con: 'CON', int: 'INT', wis: 'WIS', cha: 'CHA' };
const coinText = (coins) => Object.entries(coins || {}).map(([k, v]) => `${v} ${k}`).join(', ');
const rulesBadge = (v) => (v.ruleset === '2024'
  ? '<span class="bg-badge bg-2024">2024 rules</span>' : '<span class="bg-badge bg-legacy">Legacy (2014)</span>');
const statusBadges = (v) => [v.status === 'playtest' ? '<span class="bg-badge bg-playtest">Playtest (UA)</span>' : '',
  v.dm_permission ? '<span class="bg-badge bg-dm">DM permission</span>' : '', v.setting ? `<span class="bg-badge">${esc(v.setting)}</span>` : '']
  .filter(Boolean).join(' ');
const sourceLine = (v) => `${esc(v.source_label)}${v.source_page ? `, p. ${esc(v.source_page)}` : ''}${
  (v.also_in_books || []).length ? ` · also in ${esc(v.also_in_books.join(', '))}` : ''}`;
const grantChip = (g) => `<span class="bg-grant" data-bg-grant="${esc(g.kind)}:${esc(g.id)}">${esc(g.name)}${
  g.origin === 'replacement' ? ' <span class="muted small">(replacement)</span>' : ''}${
  (g.also_from || []).length ? ` <span class="bg-dup" title="Also from ${esc(g.also_from.join(', '))}">also ${esc(g.also_from.join(', '))}</span>` : ''}</span>`;

/** The Background card body. bg = get_character_background. */
export function backgroundCardHTML(bg, { editable = true, legacyText = '' } = {}) {
  if (!bg) return '<p class="muted small">Loading…</p>';
  if (!bg.selected) {
    return `<p class="muted small" data-bg-empty>No background chosen yet.${legacyText ? ` Free text: <strong>${esc(legacyText)}</strong>.` : ''}
      Choose a 2024 background (ability increases, origin feat, two skills, a tool, equipment) or a legacy one (skills, tools,
      languages, equipment, a background feature).</p>
      ${bg.note ? `<p class="muted small">${esc(bg.note)}</p>` : ''}
      ${editable ? '<button type="button" class="btn btn-gold btn-sm" data-action="bg-choose" data-focus-key="bg-choose">Choose background…</button>' : ''}`;
  }
  const v = bg.version;
  const warn = (bg.warnings || []).map((w) => `<li data-bg-warning="${esc(w.code)}">${esc(w.message)}${
    w.code === 'duplicate_grant' && editable ? ` <button type="button" class="btn-link" data-action="bg-replace" data-focus-key="bg-replace">Replace a duplicate…</button>` : ''}</li>`).join('');
  const ab = bg.ability || {};
  const abilityHTML = bg.ruleset !== '2024' ? '<p class="muted small">Legacy background: ability increases come from the lineage.</p>'
    : ab.mode ? `<p data-bg-ability>${Object.entries(ab.allocation || {}).sort((a, b) => b[1] - a[1]).map(([k, n]) => {
        const e = ab.effective?.[k];
        return `<span class="bg-inc">+${n} ${ABS[k]}${!ab.bonuses_included && e && e.applied < n ? ` <span class="muted small">(${e.applied ? `+${e.applied}` : 'none'} applied: max 20)</span>` : ''}</span>`;
      }).join(' ')} ${ab.bonuses_included ? '<span class="bg-badge bg-compat" title="The stored scores already include these increases; they are not added again">Already in your scores</span>' : ''}</p>`
      : '<p class="bg-open" data-bg-ability-open>Ability increases not chosen yet.</p>';
  const feat = bg.feat ? `<div class="bg-feat" data-bg-feat><strong>${esc(bg.feat.name)}${bg.feat.parameter ? ` (${esc(bg.feat.parameter)})` : ''}</strong>
      <span class="bg-badge bg-${bg.feat.status === 'playtest' ? 'playtest' : 'origin'}">${bg.feat.status === 'playtest' ? 'Playtest feat' : 'Origin feat'}</span>
      <p class="small">${esc(bg.feat.summary || '')}</p>
      <p class="muted small">Reference only: the feat's rules are not applied automatically yet.${bg.feat.url ? ` <a href="${esc(bg.feat.url)}" target="_blank" rel="noopener noreferrer">Source</a>` : ''}</p></div>` : '';
  const features = (bg.features || []).map((f) => `<div class="bg-feature" data-bg-feature="${esc(f.key)}"><strong>${esc(f.name)}</strong>
      <span class="bg-badge">Informational</span><p class="small">${esc(f.summary)}</p></div>`).join('');
  const choices = (bg.choices || []).filter((c) => c.open);
  const equip = bg.equipment_applied_here
    ? `<p class="small" data-bg-equipment-applied>Starting equipment added (${esc((bg.equipment_applied || []).filter((e) => e.version_id === v.id).map((e) =>
        `${e.package_key === 'B' ? '50 GP option' : e.package_key === 'A' ? 'Package A' : 'background equipment'}, ${e.items} item${e.items === 1 ? '' : 's'}${
          Object.keys(e.coins || {}).length ? `, ${coinText(e.coins)}` : ''}`).join('; '))}).</p>`
    : editable ? '<button type="button" class="btn btn-sm" data-action="bg-equipment" data-focus-key="bg-equipment">Review starting equipment…</button>' : '';
  const tables = (bg.characteristic_tables || []);
  const ch = bg.characteristics || {};
  const charHTML = tables.length ? `<details class="bg-chars" data-open-key="bg-chars"><summary>Personal characteristics <span class="muted small">optional</span></summary>
      <form class="stack" data-bg-chars>${tables.map((t) => `<label class="field"><span>${esc(t.label)}${t.die ? ` <span class="muted small">(${esc(t.die)})</span>` : ''}</span>
        <span class="row gap"><input type="text" name="${esc(t.key)}" maxlength="300" value="${esc(ch[t.key] || '')}" ${editable ? '' : 'readonly'}
          placeholder="${t.entry_labels ? esc(t.entry_labels.slice(0, 2).join(', ') + '…') : 'Your own words, or roll and read the source'}" aria-label="${esc(t.label)}">
        ${editable && t.die ? `<button type="button" class="btn btn-sm" data-action="bg-roll" data-key="${esc(t.key)}" data-die="${esc(t.die)}" aria-label="Roll ${esc(t.die)} for ${esc(t.label)}">Roll ${esc(t.die)}</button>` : ''}</span></label>`).join('')}
        ${editable ? '<button type="submit" class="btn btn-sm">Save characteristics</button>' : ''}</form></details>` : '';
  return `<div class="bg-head">
      <h3 class="bg-name" data-bg-name>${esc(v.name)}</h3> ${rulesBadge(v)} ${statusBadges(v)}
    </div>
    <p class="muted small" data-bg-source>${sourceLine(v)} · <a href="${esc(v.source_url)}" target="_blank" rel="noopener noreferrer">source page</a></p>
    ${warn ? `<ul class="bg-warnings" aria-live="polite">${warn}</ul>` : ''}
    ${choices.length ? `<p class="bg-open" data-bg-open>Still to choose: ${choices.map((c) => esc(c.label)).join('; ')}.</p>` : ''}
    <h4 class="bg-sub">Ability score increases</h4>${abilityHTML}
    <h4 class="bg-sub">Proficiencies</h4>
    <div class="bg-grants">${(bg.grants || []).length ? bg.grants.map(grantChip).join('') : '<span class="muted small">None yet.</span>'}</div>
    ${feat ? `<h4 class="bg-sub">Feat</h4>${feat}` : ''}
    ${features ? `<h4 class="bg-sub">Background feature</h4>${features}` : ''}
    <h4 class="bg-sub">Starting equipment</h4>${equip}
    <p class="muted small">Changing or removing the background never removes equipment from the inventory.</p>
    ${charHTML}
    ${editable ? `<div class="row gap mt"><button type="button" class="btn btn-sm" data-action="bg-choose" data-focus-key="bg-change">Change or edit…</button>
      <button type="button" class="btn btn-sm btn-ghost" data-action="bg-remove" data-focus-key="bg-remove">Remove background</button></div>` : ''}`;
}

/** The selection payload that keeps everything as it is (for edits of one part). */
export function currentPayload(bg) {
  return {
    ability: bg.ability?.mode ? { mode: bg.ability.mode, allocation: bg.ability.allocation } : null,
    choices: Object.fromEntries((bg.choices || []).map((c) => [c.key, (c.selected || []).map((s) => `${s.kind}:${s.id}`)])),
    replacements: bg.replacements || [],
    options: { bonuses_included: !!bg.ability?.bonuses_included, allow_playtest: !!bg.version?.dm_permission,
      characteristics: bg.characteristics || {}, notes: bg.notes || '' },
  };
}

// ---------------------------------------------------------------------------------------------------------- picker / editor
function choiceFieldHTML(c, picked) {
  const values = new Set(picked || []);
  const opt = (o) => `${o.kind}:${o.id}`;
  if (c.count === 1) {
    return `<label class="field"><span>${esc(c.label)}</span><select name="choice:${esc(c.key)}" data-count="1">
      <option value="">— choose —</option>${c.options.map((o) => `<option value="${esc(opt(o))}" ${values.has(opt(o)) ? 'selected' : ''}>${esc(o.name)}${
        c.kind === 'tool_or_language' ? ` (${o.kind})` : ''}</option>`).join('')}</select></label>`;
  }
  const rule = c.config?.must_include_one_of ? `<span class="muted small">At least one of: ${esc(c.config.must_include_one_of.map((x) => x.replace(/-/g, ' ')).join(', '))}.</span>` : '';
  return `<fieldset class="bg-choice" data-choice="${esc(c.key)}" data-count="${c.count}"><legend>${esc(c.label)} <span class="muted small">(choose ${c.count})</span></legend>${rule}
    <div class="bg-options">${c.options.map((o) => `<label class="check-field"><input type="checkbox" name="choice:${esc(c.key)}" value="${esc(opt(o))}"
      ${values.has(opt(o)) ? 'checked' : ''}><span>${esc(o.name)}</span></label>`).join('')}</div></fieldset>`;
}

function editorHTML(v, cur) {
  const sameVersion = cur?.selected && cur.version?.id === v.id;
  const pay = sameVersion ? currentPayload(cur) : { ability: null, choices: {}, options: {} };
  const alloc = pay.ability?.allocation || {};
  const mode = pay.ability?.mode || 'plus2_plus1';
  const two = Object.keys(alloc).find((k) => alloc[k] === 2) || '';
  const one = mode === 'plus2_plus1' ? (Object.keys(alloc).find((k) => alloc[k] === 1) || '') : '';
  const abilities = v.abilities || [];
  const abSel = (name, sel) => `<select name="${name}" aria-label="${name === 'plus2' ? '+2 ability' : '+1 ability'}"><option value="">—</option>${
    abilities.map((a) => `<option value="${a}" ${sel === a ? 'selected' : ''}>${AB[a]}</option>`).join('')}</select>`;
  const ability = v.ruleset === '2024' ? `<fieldset class="bg-choice" data-bg-ability-form><legend>Ability score increases <span class="muted small">(${abilities.map((a) => ABS[a]).join(', ')})</span></legend>
      <label class="check-field"><input type="radio" name="mode" value="plus2_plus1" ${mode === 'plus2_plus1' ? 'checked' : ''}><span>+2 to one, +1 to another</span></label>
      <div class="row gap bg-ab-row"><label class="field"><span>+2</span>${abSel('plus2', two)}</label><label class="field"><span>+1</span>${abSel('plus1', one)}</label></div>
      <label class="check-field"><input type="radio" name="mode" value="plus1_x3" ${mode === 'plus1_x3' ? 'checked' : ''}><span>+1 to all three</span></label>
      <label class="check-field mt"><input type="checkbox" name="included" ${pay.options?.bonuses_included ? 'checked' : ''}>
        <span>My stored ability scores already include this background bonus</span></label>
      <p class="muted small">Scores stay as you entered them; the increases are added on top (up to 20). Tick the box for a character whose scores already contain them.</p>
    </fieldset>` : '<p class="muted small">Legacy background: no ability score increases and no origin feat (they come from the lineage and the class).</p>';
  const playtest = v.dm_permission ? `<label class="check-field bg-dm"><input type="checkbox" name="allow_playtest" ${sameVersion ? 'checked' : ''} required>
      <span>My DM allows this ${v.status === 'playtest' ? 'playtest (Unearthed Arcana) ' : ''}background</span></label>` : '';
  return `<form class="stack" data-bg-editor="${esc(v.id)}">
    <div class="bg-head"><h3 class="bg-name">${esc(v.name)}</h3> ${rulesBadge(v)} ${statusBadges(v)}</div>
    <p class="muted small">${sourceLine(v)}</p>
    ${playtest}
    <p class="small"><strong>Grants:</strong> ${(v.grants || []).map((g) => esc(g.name)).join(', ') || 'only choices'}${
      v.feat ? ` · <strong>Feat:</strong> ${esc(v.feat.name)}${v.feat.parameter ? ` (${esc(v.feat.parameter)})` : ''}` : ''}</p>
    ${ability}
    ${(v.choices || []).map((c) => choiceFieldHTML(c, pay.choices?.[c.key])).join('')}
    <p class="muted small" data-bg-editor-status role="status" aria-live="polite"></p>
  </form>`;
}

function readEditor(form, v) {
  const fd = new FormData(form);
  const choices = {};
  for (const c of v.choices || []) {
    const vals = fd.getAll(`choice:${c.key}`).filter(Boolean);
    if (vals.length) choices[c.key] = vals;
  }
  let ability = null;
  if (v.ruleset === '2024') {
    const mode = fd.get('mode');
    if (mode === 'plus1_x3') ability = { mode, allocation: Object.fromEntries((v.abilities || []).map((a) => [a, 1])) };
    else if (fd.get('plus2') && fd.get('plus1')) ability = { mode, allocation: { [fd.get('plus2')]: 2, [fd.get('plus1')]: 1 } };
  }
  return { ability, choices, included: fd.get('included') === 'on', allowPlaytest: fd.get('allow_playtest') === 'on' };
}

/** Choose or edit the background: list (search, ruleset filter, playtest only on request) then the editor. */
export async function openBackgroundPicker({ characterId, current, onSaved }) {
  // the dialog opens at once; the catalog loads into the list and ends in results or a message with Retry (js/catalog-load.js)
  let versions = null;
  const m = openModal({
    title: current?.selected ? 'Background' : 'Choose a background',
    wide: true,
    body: `<div class="bg-picker">
      <div class="bg-filters row gap">
        <label class="field"><span>Search</span><input type="search" name="q" placeholder="e.g. sage" autocomplete="off" aria-label="Search backgrounds"></label>
        <label class="field"><span>Rules</span><select name="rules" aria-label="Rules version"><option value="all">2024 and legacy</option>
          <option value="2024">2024 rules</option><option value="2014">Legacy (2014)</option></select></label>
        <label class="check-field"><input type="checkbox" name="playtest"><span>Show playtest (DM permission)</span></label>
      </div>
      <ul class="bg-list" data-bg-list role="listbox" aria-label="Backgrounds"></ul>
      <div data-bg-edit></div></div>`,
    footer: `<button type="button" class="btn" data-close>Cancel</button>
      <button type="button" class="btn btn-gold" data-bg-save disabled>Save background</button>`,
  });
  const list = $('[data-bg-list]', m.el);
  const edit = $('[data-bg-edit]', m.el);
  const save = $('[data-bg-save]', m.el);
  let picked = null;     // the complete version shown in the editor
  let pickedId = null;   // the highlighted list entry (its detail may still be loading)
  const render = () => {
    if (!versions) return;   // still loading, or the load failed (the list shows the state)
    const q = $('[name=q]', m.el).value.trim().toLowerCase();
    const rules = $('[name=rules]', m.el).value;
    const pt = $('[name=playtest]', m.el).checked;
    const rows = versions.filter((v) => (rules === 'all' || v.ruleset === rules) && (v.enabled_by_default || pt || v.id === pickedId)
      && (!q || v.name.toLowerCase().includes(q)));
    // rebuilt only when it changes: a blur "change" right before a click must not replace the button under the pointer
    const html = rows.map((v) => `<li><button type="button" class="bg-pick${pickedId === v.id ? ' is-picked' : ''}" data-bg-pick="${esc(v.id)}"
        aria-pressed="${pickedId === v.id}"><strong>${esc(v.name)}</strong> ${rulesBadge(v)} ${statusBadges(v)}
        <span class="muted small">${esc(v.source_label)} · ${(v.skills || []).map((n) => esc(n)).join(', ') || 'skills by choice'}</span></button></li>`).join('')
      || '<li class="muted small">No background matches.</li>';
    if (list.__html !== html) { list.innerHTML = html; list.__html = html; }
  };
  const showEditor = () => {
    edit.innerHTML = picked ? editorHTML(picked, current) : '';
    save.disabled = !picked;
  };
  /** The complete version of the selected entry: detail request (fluent) or the catalog entry; Retry on failure. */
  const select = async (id, { focus = true } = {}) => {
    pickedId = id;
    picked = null;
    render();
    edit.innerHTML = '<p class="muted small" data-bg-detail-state="loading" role="status"><span class="spinner spinner-inline" aria-hidden="true"></span> Loading the background…</p>';
    save.disabled = true;
    let d;
    try { d = await api.getBackgroundDetail(id); } catch (err) {
      if (pickedId !== id || !m.el.isConnected) return;
      edit.innerHTML = `<p class="bg-eq-warn" data-bg-detail-state="error" role="alert">${esc(err.message)}
        <button type="button" class="btn btn-sm" data-bg-detail-retry>Retry</button></p>`;
      $('[data-bg-detail-retry]', m.el).addEventListener('click', () => select(id), { once: true });
      return;
    }
    if (pickedId !== id || !m.el.isConnected) return;   // another background was selected meanwhile
    picked = d;
    showEditor();
    if (focus) $('[data-bg-editor] select, [data-bg-editor] input', m.el)?.focus();
  };
  m.el.addEventListener('input', (e) => { if (e.target.closest('.bg-filters')) render(); });
  // not for the search box: it filters on 'input', and its 'change' on blur would re-render under the pointer (lost click)
  m.el.addEventListener('change', (e) => { if (e.target.closest('.bg-filters') && e.target.type !== 'search') render(); });
  m.el.addEventListener('click', (e) => {
    const b = e.target.closest('[data-bg-pick]');
    if (!b || !versions) return;
    select(b.dataset.bgPick);
  });
  save.addEventListener('click', async () => {
    const form = $('[data-bg-editor]', m.el);
    if (!form || !picked) return;
    const r = readEditor(form, picked);
    const status = $('[data-bg-editor-status]', m.el);
    if (picked.dm_permission && !r.allowPlaytest) { status.textContent = 'Confirm that your DM allows this background.'; return; }
    save.disabled = true;
    const keep = current?.selected && current.version.id === picked.id ? currentPayload(current) : null;
    try {
      const res = await api.setCharacterBackground(characterId, picked.id, {
        ability: r.ability, choices: r.choices, replacements: keep?.replacements || [],
        options: { bonuses_included: r.included, allow_playtest: r.allowPlaytest, characteristics: keep?.options.characteristics || {},
          notes: keep?.options.notes || '' } });
      m.close();
      toast(`${picked.name} saved.`, 'good');
      await onSaved?.(res, { changed: !current?.selected || current.version.id !== picked.id });
    } catch (err) {
      status.textContent = err.message;
      save.disabled = false;
    }
  });
  showEditor();
  // initial focus on the search box, unless the user already moved the focus to a control of the dialog (fast keyboard use)
  setTimeout(() => {
    const a = document.activeElement;
    if (!a || !m.el.contains(a) || !a.matches('input, select, button:not([data-close]), textarea')) $('[name=q]', m.el)?.focus();
  }, 60);
  // search and filters typed while loading are kept: the first render uses them
  loadIntoPicker(list, () => api.getBackgroundList(), {
    label: 'backgrounds',
    isOpen: () => m.el.isConnected && !m.el.dataset.closing,
    onReady: (catalog) => {
      versions = catalog.versions || [];
      list.__html = null;
      if (current?.selected && versions.some((v) => v.id === current.version.id)) select(current.version.id, { focus: false });
      else { render(); showEditor(); }
    },
  });
  return m;
}

// ---------------------------------------------------------------------------------------------------------- equipment
export async function openBackgroundEquipment({ characterId, bg, onApplied }) {
  const pkgs = bg.equipment || [];
  if (!pkgs.length) { toast('This background lists no equipment.'); return; }
  const m = openModal({
    title: `Background equipment: ${bg.version.name}`,
    wide: true,
    body: `<div class="stack">
      ${pkgs.length > 1 ? `<fieldset class="bg-choice"><legend>Option</legend>${pkgs.map((p, i) => `<label class="check-field"><input type="radio" name="pkg" value="${esc(p.key)}" ${i === 0 ? 'checked' : ''}>
        <span>${esc(p.label)}${Object.keys(p.coins || {}).length ? ` · ${esc(coinText(p.coins))}` : ''}</span></label>`).join('')}</fieldset>` : ''}
      <div data-bg-eq-review aria-live="polite"><p class="muted small">Loading…</p></div>
      <p class="muted small">Items are added to the inventory once. Changing or removing the background later never removes them.</p></div>`,
    footer: `<button type="button" class="btn" data-close>Not now</button><button type="button" class="btn btn-gold" data-bg-eq-apply disabled>Add to inventory</button>`,
  });
  const review = $('[data-bg-eq-review]', m.el);
  const apply = $('[data-bg-eq-apply]', m.el);
  let pv = null;
  const load = async () => {
    const pkg = $('[name=pkg]:checked', m.el)?.value || pkgs[0].key;
    apply.disabled = true;
    try {
      pv = await api.previewBackgroundEquipment(characterId, pkg);
      const rows = pv.entries.map((e) => {
        const status = e.status === 'resolved' ? `<span class="bg-eq-ok">Added</span>${e.owned ? ` <span class="muted small">(you already have ${e.owned})</span>` : ''}`
          : e.status === 'pick' ? `<select data-bg-eq-pick="${e.seq}" aria-label="Choose: ${esc(e.label)}"><option value="">— choose —</option>${
              (e.pick_options || []).map((o) => `<option value="${esc(o.id)}">${esc(o.name)}</option>`).join('')}</select>`
          : e.status === 'needs_choice' ? '<span class="bg-eq-warn">Make the background choice first</span>'
          : `<span class="bg-eq-note">Not in the catalog: noted only</span>${e.note ? ` <span class="muted small">(${esc(e.note)})</span>` : ''}`;
        return `<tr data-bg-eq-row="${e.seq}" data-status="${esc(e.status)}"><td>${esc(e.name)}</td><td>${e.quantity}</td><td>${status}</td></tr>`;
      }).join('');
      review.innerHTML = `${pv.already_applied ? '<p class="bg-eq-warn">This background\'s equipment was already added.</p>' : ''}
        ${pv.entries.length ? `<table class="bg-eq"><thead><tr><th>Item</th><th>Qty</th><th>Result</th></tr></thead><tbody>${rows}</tbody></table>` : ''}
        ${Object.keys(pv.coins || {}).length ? `<p data-bg-eq-coins><strong>Coins:</strong> ${esc(coinText(pv.coins))} (added to your purse)</p>` : ''}`;
      apply.disabled = pv.already_applied || pv.entries.some((e) => e.status === 'needs_choice');
    } catch (err) { review.innerHTML = `<p class="bg-eq-warn">${esc(err.message)}</p>`; }
  };
  m.el.addEventListener('change', (e) => { if (e.target.name === 'pkg') load(); });
  apply.addEventListener('click', async () => {
    const picks = {};
    for (const s of $$('[data-bg-eq-pick]', m.el)) {
      if (!s.value) { s.focus(); toast('Choose the item first.', 'bad'); return; }
      picks[s.dataset.bgEqPick] = s.value;
    }
    apply.disabled = true;
    try {
      const r = await api.applyBackgroundEquipment(characterId, pv.package, picks);
      m.close();
      toast(`Added ${r.added} item${r.added === 1 ? '' : 's'}${Object.keys(r.coins || {}).length ? ` and ${coinText(r.coins)}` : ''}${
        r.noted?.length ? `; noted ${r.noted.length} not in the catalog` : ''}.`, 'good', 6000);
      await onApplied?.(r);
    } catch (err) { toast(err.message, 'bad'); apply.disabled = false; }
  });
  load();
  return m;
}

// ---------------------------------------------------------------------------------------------------------- duplicates
export async function openReplaceDuplicate({ characterId, bg, onSaved }) {
  const dup = (bg.warnings || []).find((w) => w.code === 'duplicate_grant');
  if (!dup) return;
  const items = dup.items || [];
  // tools: every tool any background offers (artisan's tools, instruments, gaming sets, kits)
  const cat = await api.getBackgroundList().catch(() => ({ tools: [] }));
  const tools = new Map((cat.tools || []).map((t) => [t.id, t.name]));
  const have = new Set((bg.grants || []).map((g) => `${g.kind}:${g.id}`));
  const opts = (kind) => (kind === 'skill' ? SKILLS.map((x) => [x.key, x.name]) : [...tools.entries()].sort((a, b) => a[1].localeCompare(b[1])))
    .filter(([id]) => !have.has(`${kind}:${id}`)).map(([id, name]) => `<option value="${esc(id)}">${esc(name)}</option>`).join('');
  const m = openModal({
    title: 'Replace a duplicate proficiency',
    body: `<p class="small">${esc(dup.rule)}</p>${dup.dm_approval ? '<p class="bg-eq-warn small">2024 rules: ask your DM before replacing.</p>' : ''}
      <form class="stack" data-bg-replace>
        <label class="field"><span>Duplicate</span><select name="original">${items.map((x) => `<option value="${esc(x.kind)}:${esc(x.id)}">${esc(x.name)} (also ${esc((x.also_from || []).join(', '))})</option>`).join('')}</select></label>
        <label class="field"><span>Replace with (same kind)</span><select name="replacement" required>${opts(items[0]?.kind || 'skill')}</select></label>
      </form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Replace</button>',
  });
  const form = $('[data-bg-replace]', m.el);
  form.elements.original.addEventListener('change', () => { form.elements.replacement.innerHTML = opts(form.elements.original.value.split(':')[0]); });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const f = form;
    const [kind, original] = f.elements.original.value.split(':');
    const replacement = f.elements.replacement.value.trim();
    if (!replacement) { f.elements.replacement.focus(); return; }
    const pay = currentPayload(bg);
    try {
      const res = await api.setCharacterBackground(characterId, bg.version.id, { ...pay,
        replacements: [...pay.replacements.filter((r) => !(r.kind === kind && r.original === original)), { kind, original, replacement }] });
      m.close();
      toast('Proficiency replaced.', 'good');
      await onSaved?.(res);
    } catch (err) { toast(err.message, 'bad'); }
  });
}

/** Save the characteristics form (keeps every other part of the selection). */
export async function saveCharacteristics({ characterId, bg, form, onSaved }) {
  const pay = currentPayload(bg);
  const chars = {};
  for (const el of form.elements) if (el.name && el.tagName === 'INPUT' && el.value.trim()) chars[el.name] = el.value.trim().slice(0, 300);
  const res = await api.setCharacterBackground(characterId, bg.version.id, { ...pay, options: { ...pay.options, characteristics: chars } });
  toast('Characteristics saved.', 'good');
  await onSaved?.(res);
}

/** Roll a table die; with short entry titles the result is filled in, otherwise the number is shown to look up. */
export function rollCharacteristic(form, bg, key, die) {
  const t = (bg.characteristic_tables || []).find((x) => x.key === key);
  const n = 1 + Math.floor(Math.random() * Number(die.slice(1)));
  const input = form.elements[key];
  const label = t?.entry_labels?.[n - 1];
  if (label) input.value = label;
  toast(`${t?.label || key}: rolled ${n} on ${die}${label ? ` → ${label}` : ' (look it up in the source)'}.`);
  input.focus();
}

export async function removeBackground({ characterId, bg, onSaved }) {
  if (!(await confirmDialog(`Remove ${bg.version.name}? Its ability increases, proficiencies and choices go with it. `
    + 'Equipment already added stays in the inventory.', { title: 'Remove background?', okLabel: 'Remove background', danger: true }))) return;
  try {
    const res = await api.clearCharacterBackground(characterId);
    toast('Background removed.', 'good');
    await onSaved?.(res);
  } catch (err) { toast(err.message, 'bad'); }
}
