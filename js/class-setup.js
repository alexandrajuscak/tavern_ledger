// Guided class setup: Add Class (pick a class and level, see what it brings before anything is stored: multiclass
// prerequisites of every class, features, proficiencies, choices to make, spellcasting and slots) and the starting
// equipment review (one option per group, a concrete item for "any martial weapon"-style entries, added to the inventory
// once, first class only). Everything comes from preview_character_class_add / get_class_starting_equipment; no class names.
import { $, $$, esc, toast, openModal } from './utils.js?v=28';
import * as api from './class-api.js?v=28';
import { catalogOrExplain } from './catalog-load.js?v=28';

const ord = (n) => `${n}${n % 100 >= 11 && n % 100 <= 13 ? 'th' : n % 10 === 1 ? 'st' : n % 10 === 2 ? 'nd' : n % 10 === 3 ? 'rd' : 'th'}`;
const words = (id) => String(id || '').replace(/-/g, ' ');
const AUTO = { automated: 'Automatic', partially_automated: 'Partly automatic', manual: 'Manual', informational: 'Reminder' };

function slotLine(p) {
  const from = p.standard_slots?.from || {};
  const to = p.standard_slots?.to || {};
  const txt = (m) => (Object.keys(m).length ? Object.entries(m).map(([l, n]) => `${n} × ${ord(Number(l))}`).join(', ') : 'none');
  const bits = [];
  if (txt(from) !== txt(to)) bits.push(`Spell slots: ${txt(from)} → <strong>${txt(to)}</strong>`);
  const pf = p.pact_magic?.from; const pt = p.pact_magic?.to;
  if (JSON.stringify(pf) !== JSON.stringify(pt)) bits.push(`Pact Magic: ${pf ? `${pf.slots} × ${ord(pf.slot_level)}` : 'none'} → <strong>${pt ? `${pt.slots} × ${ord(pt.slot_level)}` : 'none'}</strong>`);
  const sc = p.spellcasting?.to;
  if (sc) bits.push(sc.active ? `Spellcasting (${esc(String(sc.ability || '').toUpperCase())}) up to ${sc.max_spell_level ? `${ord(sc.max_spell_level)}-level spells` : 'cantrips'}`
    : `Spellcasting starts at class level ${esc(sc.start_level)}`);
  return bits;
}

/** The preview of adding a class (server read model; nothing stored). */
function addPreviewHTML(p) {
  if (!p) return '<p class="muted small">Loading the preview…</p>';
  if (!p.possible) return `<p class="sp-warn small" role="alert">${esc(p.error || 'This class cannot be added.')}</p>`;
  const prereq = (p.prerequisites || []).map((x) => `<li class="${x.met ? 'is-met' : 'is-unmet'}" data-prereq="${esc(x.class_id)}">
      <span aria-hidden="true">${x.met ? '✓' : '✗'}</span> <strong>${esc(x.class_name)}</strong> needs ${esc(x.requirement)}
      <span class="muted">— you have ${Object.entries(x.scores || {}).map(([a, v]) => `${a.toUpperCase()} ${v}`).map(esc).join(', ')}</span>
      ${x.met ? '' : '<span class="sr-only">(not met)</span>'}</li>`).join('');
  const feats = (p.features_activated || []).map((f) => `<li>${esc(f.name)} <span class="muted small">(level ${f.level} · ${esc(AUTO[f.automation] || f.automation || '')})</span></li>`);
  const profs = (p.proficiencies?.added || []).map((x) => esc(words(x.value)));
  const choices = (p.choices_added || []).map((c) => `<li>${esc(c.feature)}: ${esc(c.label)}</li>`);
  const res = (p.resources || []).filter((r) => r.active_to).map((r) => `<li>${esc(r.name)}: ${esc(String(r.max_to ?? '—'))}${r.die_to ? ` (${esc(r.die_to)})` : ''}</li>`);
  const slots = slotLine(p);
  const warn = (p.warnings || []).filter((w) => w.code !== 'multiclass_prerequisite').map((w) => `<li>${esc(w.message)}</li>`).join('');
  return `<div class="cls-add-preview" data-add-summary>
    <p class="small"><strong>${esc(p.class_name)} ${p.level.to}</strong> · hit die ${esc(p.hit_die)} · character level ${p.total_level.from} → <strong>${p.total_level.to}</strong>
      · proficiency bonus +${p.proficiency_bonus.from ?? p.proficiency_bonus.to} → <strong>+${p.proficiency_bonus.to}</strong></p>
    ${prereq ? `<section data-add-prereq><h4>Multiclass prerequisites</h4><ul class="small cls-prereq">${prereq}</ul>
      ${p.prerequisites_met ? '' : '<p class="sp-warn small">Not every prerequisite is met. Rules as written do not allow this multiclass; add it only if your DM agrees.</p>'}</section>` : ''}
    <div class="cls-add-cols">
      <section><h4>Features you gain</h4>${feats.length ? `<ul class="small">${feats.join('')}</ul>` : '<p class="muted small">None at this level.</p>'}</section>
      <section><h4>Proficiencies</h4>${profs.length ? `<p class="small" data-add-profs>${profs.join(', ')}</p>` : '<p class="muted small">None added.</p>'}
        ${p.first_class ? '' : '<p class="muted small">A class added by multiclassing gives only its multiclass proficiencies (no saving throws).</p>'}</section>
      <section><h4>Choices to make next</h4>${choices.length ? `<ul class="small">${choices.join('')}</ul><p class="muted small">You make them on the class page after adding the class.</p>` : '<p class="muted small">None.</p>'}</section>
      <section><h4>Spellcasting and resources</h4>${slots.length ? `<p class="small">${slots.join('<br>')}</p>` : '<p class="muted small">No spellcasting change.</p>'}
        ${res.length ? `<ul class="small">${res.join('')}</ul>` : ''}</section>
    </div>
    <p class="muted small" data-add-equipment>${esc(p.starting_equipment_note || '')}</p>
    ${warn ? `<ul class="sp-warn small">${warn}</ul>` : ''}
  </div>`;
}

/** Add a class: class, level, optional subclass; live preview; prerequisites must be met or the DM's permission confirmed. */
export async function openAddClass({ characterId, summary, onSaved, host = null, saveButton = null }) {
  // inside another dialog (host) the caller shows a failure in place; as its own dialog: a notice and a clear message
  const catalog = host ? await api.getClassCatalog() : await catalogOrExplain(() => api.getClassCatalog(), 'classes');
  if (!catalog) return null;
  const taken = new Set((summary.classes || []).map((k) => k.class_id));
  const choices = catalog.classes.filter((c) => !taken.has(c.id) && c.versions.length);
  if (!choices.length) { toast('Every class is already on this character.'); return null; }
  const first = !summary.classes.length;
  const free = 20 - (first ? 0 : summary.total_level);
  const startLevel = first ? Math.min(Math.max(summary.total_level || 1, 1), 20) : 1;
  // host: render inside an existing element (the new-character dialog) with the caller's save button; otherwise a modal
  const formHTML = `<form class="form-grid" data-class-form data-add-class>
      <label class="field"><span>Class</span><select name="class" data-focus-key="add-class">${choices.map((c) =>
        `<option value="${esc(c.id)}">${esc(c.name)}</option>`).join('')}</select></label>
      <label class="field"><span>Version</span><select name="version"></select></label>
      <label class="field"><span>Level in this class</span><input name="level" type="number" min="1" max="${free}" value="${Math.min(startLevel, free)}"></label>
      <label class="field" data-subclass-field hidden><span>Subclass (optional; you can choose it later)</span><select name="subclass"></select></label>
      ${first ? '' : '<label class="check-field"><input type="checkbox" name="primary"><span>Make it the primary class</span></label>'}
      <div class="span-2" data-add-preview aria-live="polite">${addPreviewHTML(null)}</div>
      <label class="check-field span-2" data-dm-ok hidden><input type="checkbox" name="dm_ok"><span>My DM allows this multiclass anyway</span></label>
    </form>`;
  if (host) host.innerHTML = formHTML;
  const m = host ? null : openModal({
    title: first ? 'Choose your class' : 'Add a class (multiclass)',
    wide: true,
    body: formHTML,
    footer: `<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-class-save disabled>${first ? 'Choose class' : 'Add class'}</button>`,
  });
  const scope = host || m.el;
  const form = $('[data-class-form]', scope);
  const save = saveButton || $('[data-class-save]', scope);
  const cls = () => catalog.classes.find((c) => c.id === form.elements.class.value);
  let preview = null;
  let seq = 0;
  let timer = null;
  function fillVersions() {
    const c = cls();
    form.elements.version.innerHTML = c.versions.map((v) => `<option value="${esc(v.id)}">${esc(v.name)} — ${esc(v.rules_label || v.source_label)}${v.status === 'legacy' ? ' (legacy)' : ''}</option>`).join('');
  }
  function fillSubclasses() {
    const c = cls();
    const v = c.versions.find((x) => x.id === form.elements.version.value);
    const lvl = Number(form.elements.level.value) || 1;
    const subs = c.subclasses.filter((s) => s.implementation_status !== 'catalog_only' && s.status !== 'legacy');
    const show = v?.subclass_level && lvl >= v.subclass_level && subs.length;
    $('[data-subclass-field]', scope).hidden = !show;
    const keep = form.elements.subclass.value;
    form.elements.subclass.innerHTML = `<option value="">Choose later</option>${subs.map((s) => `<option value="${esc(s.id)}" ${s.id === keep ? 'selected' : ''}>${esc(s.name)}</option>`).join('')}`;
    if (!show) form.elements.subclass.value = '';
  }
  function gate() {
    const needsOk = preview?.possible && !preview.prerequisites_met;
    $('[data-dm-ok]', scope).hidden = !needsOk;
    save.disabled = !preview?.possible || (needsOk && !form.elements.dm_ok.checked);
  }
  async function refresh() {
    const n = ++seq;
    save.disabled = true;
    const lvl = Number(form.elements.level.value);
    if (!(lvl >= 1 && lvl <= free)) {
      preview = { possible: false, error: `Choose a level from 1 to ${free}.` };
    } else {
      try {
        preview = await api.previewClassAdd(characterId, form.elements.version.value, lvl, form.elements.subclass.value || null);
      } catch (err) { preview = { possible: false, error: err.message }; }
    }
    if (n !== seq) return;
    $('[data-add-preview]', scope).innerHTML = addPreviewHTML(preview);
    gate();
  }
  const later = () => { clearTimeout(timer); timer = setTimeout(refresh, 250); };
  form.addEventListener('change', (e) => {
    if (e.target.name === 'class') { fillVersions(); fillSubclasses(); later(); }
    else if (e.target.name === 'version' || e.target.name === 'level' || e.target.name === 'subclass') { fillSubclasses(); later(); }
    else if (e.target.name === 'dm_ok') gate();
  });
  form.elements.level.addEventListener('input', later);
  fillVersions();
  fillSubclasses();
  refresh();
  save.addEventListener('click', async () => {
    save.disabled = true;
    const c = cls();
    try {
      const res = await api.setCharacterClass(characterId, {
        version: form.elements.version.value, level: Number(form.elements.level.value), subclass: form.elements.subclass.value || null,
        primary: form.elements.primary?.checked || null,
      });
      toast(`${c.name} added.`, 'good');
      const equipment = preview?.first_class && (preview.starting_equipment?.groups || []).length ? preview.starting_equipment : null;
      m?.close();
      await onSaved?.(res, { equipment, className: c.name });
      if (equipment && !host) openStartingEquipment({ characterId, equipment, className: c.name, onDone: onSaved });
    } catch (err) { toast(err.message, 'bad'); gate(); }
  });
  return m || { el: host };
}

// ------------------------------------------------------------------------------------------------------ starting equipment
function entryHTML(x, g, opt, i) {
  if (x.unresolved) return `<li class="muted">${esc(x.unresolved)} <span class="small">(not added automatically)</span></li>`;
  if (x.item_id) return `<li>${x.quantity > 1 ? `${x.quantity} × ` : ''}${esc(x.name || words(x.item_id))}</li>`;
  const q = x.quantity || 1;
  const selects = Array.from({ length: q }, (_, k) => `<select data-pick="${g}:${opt}:${i}" data-pick-n="${k}" aria-label="${esc(x.label || 'Item')}${q > 1 ? ` ${k + 1}` : ''}">
      <option value="">Choose…</option>${(x.candidates || []).map((c) => `<option value="${esc(c.id)}">${esc(c.name)}</option>`).join('')}</select>`).join(' ');
  return `<li>${esc(x.label || 'Item of your choice')}: ${selects}</li>`;
}

/** Review the starting equipment: pick one option per group and the concrete items; add them to the inventory. */
export function openStartingEquipment({ characterId, equipment, className, onDone }) {
  const groups = equipment.groups || [];
  const m = openModal({
    title: `Starting equipment${className ? ` (${className})` : ''}`,
    wide: true,
    body: `<form data-start-eq>
      <p class="small">Choose one option in each group. The items are added to your inventory once; you can still change the inventory afterwards.</p>
      ${groups.map((g) => `<fieldset class="lin-step" data-eq-group="${g.group}"><legend>${g.options.length > 1 ? `Choice ${g.group}` : 'You also get'}</legend>
        ${g.options.map((o) => `<div class="eq-option">
          ${g.options.length > 1 ? `<label class="check-field"><input type="radio" name="g${g.group}" value="${esc(o.key)}"><span>(${esc(o.key)}) ${esc(o.label)}</span></label>`
            : `<p class="small"><strong>${esc(o.label)}</strong></p>`}
          <ul class="small eq-items">${o.items.map((x, i) => entryHTML(x, g.group, o.key, i)).join('')}</ul></div>`).join('')}
      </fieldset>`).join('')}
      ${equipment.starting_gold ? `<p class="muted small">Alternative: starting wealth ${esc(equipment.starting_gold)} instead of this equipment (record gold yourself).</p>` : ''}
      <p class="small" aria-live="polite" data-eq-status></p>
    </form>`,
    footer: `<button type="button" class="btn" data-close>Later</button><button type="button" class="btn btn-gold" data-eq-ok disabled>Add to inventory</button>`,
  });
  const ok = $('[data-eq-ok]', m.el);
  const status = $('[data-eq-status]', m.el);
  const collect = () => {
    const options = {};
    const picks = {};
    let missing = 0;
    for (const g of groups) {
      const key = g.options.length > 1 ? $(`input[name=g${g.group}]:checked`, m.el)?.value : g.options[0].key;
      if (!key) { missing += 1; continue; }
      options[g.group] = key;
      const opt = g.options.find((o) => o.key === key);
      opt.items.forEach((x, i) => {
        if (x.item_id || x.unresolved) return;
        const vals = $$(`select[data-pick="${g.group}:${key}:${i}"]`, m.el).map((s) => s.value);
        if (vals.some((v) => !v)) missing += 1;
        picks[`${g.group}:${key}:${i}`] = vals.length === 1 ? vals[0] : vals;
      });
    }
    return { options, picks, missing };
  };
  m.el.addEventListener('change', () => {
    // only the chosen option's item pickers are enabled
    for (const g of groups) {
      if (g.options.length < 2) continue;
      const key = $(`input[name=g${g.group}]:checked`, m.el)?.value;
      $$(`[data-eq-group="${g.group}"] select[data-pick]`, m.el).forEach((s) => { s.disabled = !s.dataset.pick.startsWith(`${g.group}:${key}:`); });
    }
    const { missing } = collect();
    status.textContent = missing ? `${missing} choice${missing === 1 ? '' : 's'} left` : 'Ready to add';
    ok.disabled = missing > 0;
  });
  $$('select[data-pick]', m.el).forEach((s) => {
    const g = groups.find((x) => String(x.group) === s.dataset.pick.split(':')[0]);
    if (g && g.options.length > 1) s.disabled = true;
  });
  m.el.dispatchEvent(new Event('change'));
  ok.addEventListener('click', async () => {
    ok.disabled = true;
    const { options, picks } = collect();
    try {
      const r = await api.applyStartingEquipment(characterId, equipment.class_version_id, { options, picks });
      const n = r.added.reduce((a, x) => a + (x.quantity || 1), 0);
      toast(`Added ${n} item${n === 1 ? '' : 's'} to the inventory${r.skipped.length ? ` (${r.skipped.length} left for you to add)` : ''}.`, 'good');
      m.close();
      await onDone?.(r);
    } catch (err) { toast(err.message, 'bad'); ok.disabled = false; }
  });
  return m;
}

/** Card button for the primary class while its starting equipment was not added yet. */
export function startingEquipmentButtonHTML(state, { editable = true } = {}) {
  if (!editable || !state || !state.class_version_id) return '';
  if (state.error) {
    return `<span class="muted" data-start-eq-error>Starting equipment could not be loaded.</span>
      <button type="button" class="btn btn-sm" data-action="class-start-eq-retry" data-focus-key="class-start-eq-retry">Retry</button>`;
  }
  if (state.applied || !state.has_options) return '';
  return `<button type="button" class="btn btn-sm" data-action="class-start-eq" data-version="${esc(state.class_version_id)}" data-focus-key="class-start-eq">Starting equipment…</button>`;
}
