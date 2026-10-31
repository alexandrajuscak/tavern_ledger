// Classes card (Build tab) and Slot Tracker (Spells tab). Everything shown comes from get_character_class_summary and
// get_character_spell_slots; nothing here calculates levels, slots or multiclass rules.
import { $, esc, toast, openModal, confirmDialog } from './utils.js?v=17';
import * as api from './class-api.js?v=17';
import { catalogOrExplain } from './catalog-load.js?v=17';
import { icon } from './icons.js?v=17';
import { reviewClassChange } from './feature-ui.js?v=17';
import { openAddClass, startingEquipmentButtonHTML } from './class-setup.js?v=17';

const ABILITY = { str: 'Strength', dex: 'Dexterity', con: 'Constitution', int: 'Intelligence', wis: 'Wisdom', cha: 'Charisma' };
const ord = (n) => `${n}${n % 100 >= 11 && n % 100 <= 13 ? 'th' : n % 10 === 1 ? 'st' : n % 10 === 2 ? 'nd' : n % 10 === 3 ? 'rd' : 'th'}`;
const fmt = (n) => (n == null ? '—' : n >= 0 ? `+${n}` : `−${Math.abs(n)}`);
const CONTRIB = {
  full: 'full caster', half_down: 'half caster (half the levels, rounded down)', half_up: 'Artificer (half the levels, rounded up)',
  third_down: 'one-third caster (a third of the levels, rounded down)', pact: 'Pact Magic (separate slots)', none: 'no spellcasting',
};

// ---------------------------------------------------------------------------------------------------------- Classes card
function spellcastingLine(k) {
  const sc = k.spellcasting;
  if (!sc) return `<span class="muted">${esc(CONTRIB[k.contribution.type])}</span>`;
  if (!sc.active) return `<span class="muted">Spellcasting from ${esc(k.class_name)} level ${esc(sc.start_level)}</span>`;
  const bits = [`${ABILITY[sc.ability] || '—'}`, sc.max_spell_level ? `spells up to ${ord(sc.max_spell_level)} level` : 'no leveled spells yet'];
  if (sc.cantrips_known != null) bits.push(`${sc.counts.cantrips} / ${sc.cantrips_known} cantrips`);
  if (sc.spells_known != null) bits.push(`${sc.counts.known} / ${sc.spells_known} known`);
  if (sc.prepared_limit != null) bits.push(`${sc.counts.prepared} / ${sc.prepared_limit} prepared`);
  return esc(bits.join(' · '));
}

/** The Classes card body. `summary` from get_character_class_summary; `catalog` from getClassCatalog (may be null). */
export function classCardHTML(summary, catalog, { editable = true, startEq = null } = {}) {
  if (!summary) return '<p class="muted small">Loading…</p>';
  const rows = summary.classes || [];
  const versionsOf = (classId) => catalog?.classes.find((c) => c.id === classId)?.versions || [];
  const head = rows.length
    ? `<p class="cls-total" data-class-total><strong>Level ${summary.total_level}</strong> · Proficiency bonus ${fmt(summary.proficiency_bonus)}
        ${summary.slot_mode === 'multiclass' ? ` · Caster level ${summary.effective_caster_level} (multiclass)` : ''}</p>`
    : `<p class="lin-callout small" data-class-fallback>No class chosen yet. The level (${summary.total_level}) is the manual level from before;
        once you add a class, levels, proficiency bonus and spell slots come from your classes.</p>`;
  const list = rows.map((k) => `
    <article class="cls-row" data-class-row="${esc(k.id)}">
      <div class="cls-row-head">
        <h3 class="cls-row-title">${esc(k.class_name)}${k.subclass_name ? ` <span class="muted small">(${esc(k.subclass_name)})</span>` : ''}</h3>
        ${k.is_primary ? '<span class="sp-badge" title="Primary class">Primary</span>' : ''}
        ${k.status === 'legacy' ? '<span class="sp-badge">Legacy version</span>' : ''}
        <span class="muted small">${esc(k.version_name)} · ${esc(k.rules_label || k.source_label)} ·
          <a href="${esc(k.source_url)}" target="_blank" rel="noopener">source</a> · hit die ${esc(k.hit_die)}</span>
      </div>
      <div class="cls-row-body">
        ${editable ? `<label class="field cls-level"><span>Level</span>
          <select data-class-level="${esc(k.id)}" data-focus-key="class-level:${esc(k.id)}" aria-label="${esc(k.class_name)} level">
            ${Array.from({ length: 20 }, (_, i) => i + 1).map((l) => `<option value="${l}" ${l === k.level ? 'selected' : ''}
              ${l - k.level + summary.total_level > 20 ? 'disabled' : ''}>${l}</option>`).join('')}</select></label>`
          : `<span class="cls-level-ro">Level ${k.level}</span>`}
        <p class="small cls-contrib">${esc(CONTRIB[k.contribution.type])}${k.contribution.type !== 'none' && k.contribution.type !== 'pact'
          ? ` → adds ${k.contribution.rounded}${k.contribution.active ? '' : ' (not yet)'}` : ''}</p>
        <p class="small">${spellcastingLine(k)}</p>
      </div>
      ${editable ? `<div class="cls-row-actions">
        ${k.is_primary ? '' : `<button type="button" class="btn btn-sm" data-action="class-primary" data-row="${esc(k.id)}">Make primary</button>`}
        <button type="button" class="btn btn-sm" data-action="class-edit" data-row="${esc(k.id)}" data-focus-key="class-edit:${esc(k.id)}">
          ${versionsOf(k.class_id).length > 1 ? 'Version / subclass' : 'Details'}</button>
        ${k.is_primary && startEq?.class_version_id === k.class_version_id ? startingEquipmentButtonHTML(startEq, { editable }) : ''}
        <button type="button" class="btn btn-sm btn-bad" data-action="class-remove" data-row="${esc(k.id)}">Remove</button>
      </div>` : ''}
    </article>`).join('');
  const warnings = (summary.warnings || []).map((w) => `<li>${esc(w.message)}</li>`).join('');
  return `${head}
    <div class="cls-list">${list}</div>
    ${warnings ? `<ul class="cls-warnings sp-warn small" data-class-warnings>${warnings}</ul>` : ''}
    ${editable ? `<button type="button" class="btn btn-sm btn-gold" data-action="class-add" data-focus-key="class-add" ${summary.total_level >= 20 && rows.length ? 'disabled' : ''}>${rows.length ? '+ Add class (multiclass)' : '+ Choose class'}</button>` : ''}
    <details class="cls-limits small"><summary>What this foundation does and does not do</summary>
      <ul>${(summary.limitations || []).map((l) => `<li>${esc(l)}</li>`).join('')}
        ${rows.flatMap((k) => k.limitations || []).map((l) => `<li>${esc(l)}</li>`).join('')}</ul></details>`;
}

/** Add a class or change version / subclass of an existing class row. */
export async function openClassEditor({ characterId, summary, row = null, onSaved }) {
  if (!row) return openAddClass({ characterId, summary, onSaved });
  const catalog = await catalogOrExplain(() => api.getClassCatalog(), 'classes');
  if (!catalog) return null;
  const taken = new Set((summary.classes || []).map((k) => k.class_id));
  const current = row ? summary.classes.find((k) => k.id === row) : null;
  const free = 20 - summary.total_level + (current?.level || 0);
  const choices = current ? catalog.classes.filter((c) => c.id === current.class_id) : catalog.classes.filter((c) => !taken.has(c.id));
  if (!choices.length) { toast('Every class is already on this character.'); return null; }
  const firstLevel = !summary.classes.length ? Math.min(summary.total_level, 20) : 1;
  const m = openModal({
    title: current ? `${current.class_name}: version and subclass` : 'Add a class',
    body: `<form class="form-grid" data-class-form>
      <label class="field"><span>Class</span><select name="class" ${current ? 'disabled' : ''}>${choices.map((c) =>
        `<option value="${esc(c.id)}">${esc(c.name)}</option>`).join('')}</select></label>
      <label class="field"><span>Version</span><select name="version"></select></label>
      <label class="field"><span>Level</span><input name="level" type="number" min="1" max="${free}" value="${current?.level || Math.min(firstLevel, free)}" ${current ? 'readonly' : ''}></label>
      <label class="field" data-subclass-field hidden><span>Subclass</span><select name="subclass"></select></label>
      ${!current && summary.classes.length ? '<label class="check-field"><input type="checkbox" name="primary"><span>Primary class</span></label>' : ''}
      <p class="muted small span-2" data-class-note></p>
      <p class="muted small span-2">Features, choices and resources of the class are on the class page (Build tab).</p>
    </form>`,
    footer: `<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-class-save>${current ? 'Save' : 'Add class'}</button>`,
  });
  const form = $('[data-class-form]', m.el);
  const cls = () => catalog.classes.find((c) => c.id === form.elements.class.value);
  function fill() {
    const c = cls();
    form.elements.version.innerHTML = c.versions.map((v) => `<option value="${esc(v.id)}" ${v.id === (current?.class_version_id) ? 'selected' : ''}>
      ${esc(v.name)} — ${esc(v.rules_label || v.source_label)}${v.status === 'legacy' ? ' (legacy)' : ''}</option>`).join('');
    const subField = $('[data-subclass-field]', m.el);
    subField.hidden = !c.subclasses.length;
    form.elements.subclass.innerHTML = `<option value="">None</option>${c.subclasses
      .filter((s) => s.implementation_status !== 'catalog_only' || s.id === current?.subclass_version_id).map((s) => `<option value="${esc(s.id)}"
      ${s.id === current?.subclass_version_id ? 'selected' : ''}>${esc(s.name)}${s.spellcasting_start_level ? ` (spellcasting from level ${s.spellcasting_start_level})` : ''}</option>`).join('')}`;
    const v = c.versions.find((x) => x.id === form.elements.version.value);
    const pre = v?.multiclass_prerequisite;
    const req = pre ? (pre.all || pre.any || []).map((x) => `${x.ability.toUpperCase()} ${x.min}`).join(pre.any ? ' or ' : ' and ') : '';
    $('[data-class-note]', m.el).textContent = [
      v ? `${CONTRIB[v.multiclass_contribution]}${v.spellcasting_start_level ? `, spellcasting from level ${v.spellcasting_start_level}` : ''}, hit die ${v.hit_die}.` : '',
      summary.classes.length && req ? `Multiclassing usually needs ${req} (shown as a warning, not enforced).` : '',
      current && v && v.id !== current.class_version_id ? 'Changing the version keeps your spells; spells not on the new list are flagged, not removed.' : '',
    ].filter(Boolean).join(' ');
  }
  form.addEventListener('change', (e) => { if (e.target.name === 'class' || e.target.name === 'version') fill(); });
  fill();
  $('[data-class-save]', m.el).addEventListener('click', async () => {
    const version = form.elements.version.value;
    const level = Number(form.elements.level.value);
    if (current && version !== current.class_version_id && !(await reviewClassChange({
      characterId, row: current.id, className: current.class_name, version }))) return;
    try {
      const res = await api.setCharacterClass(characterId, {
        version, level, subclass: form.elements.subclass.value || null,
        primary: form.elements.primary?.checked || null, row: current?.id || null,
      });
      toast(current ? 'Class updated.' : `${cls().name} added.`, 'good');
      m.close();
      await onSaved?.(res);
    } catch (err) { toast(err.message, 'bad'); }
  });
  return m;
}

/** Level change: the review (features, choices, resources, slots, spells, warnings) is shown and must be confirmed. */
export async function changeClassLevel({ characterId, summary, row, level, onSaved }) {
  const k = summary.classes.find((x) => x.id === row);
  if (!k || k.level === level) return;
  if (!(await reviewClassChange({ characterId, row: k.id, className: k.class_name, level }))) return false;
  const res = await api.setCharacterClass(characterId, { version: k.class_version_id, level, subclass: k.subclass_version_id, row: k.id });
  await onSaved?.(res);
  return true;
}

export async function removeClass({ summary, row, onSaved }) {
  const k = summary.classes.find((x) => x.id === row);
  if (!k) return;
  const spells = k.spellcasting ? k.spellcasting.counts.cantrips + k.spellcasting.counts.known + (k.spellcasting.counts.always_prepared || 0) : 0;
  const msg = `Remove ${k.class_name} (level ${k.level})? ${k.spellcasting ? `Its spell slots and its spellcasting source${spells ? ' with its spells' : ''} go with it. ` : ''}`
    + 'Manual, item, feat and lineage spells stay.';
  if (!(await confirmDialog(msg, { title: 'Remove class?', okLabel: 'Remove class', danger: true }))) return;
  try {
    const res = await api.removeCharacterClass(row, true);
    toast(`${k.class_name} removed.`, 'good');
    await onSaved?.(res);
  } catch (err) { toast(err.message, 'bad'); }
}

// ---------------------------------------------------------------------------------------------------------- Slot Tracker
function pips(remaining, max, label) {
  return `<span class="slot-pips-ro" role="img" aria-label="${esc(label)}: ${remaining} of ${max} remaining">${
    Array.from({ length: max }, (_, i) => `<span class="slot-dot ${i < remaining ? 'is-full' : ''}"></span>`).join('')}</span>`;
}

/** "1st-level slot used. 3 of 4 left." after a confirmed slot change (pool standard | pact | temporary). */
export function slotChangeMessage(slots, pool, key, verb) {
  if (pool === 'pact') {
    const p = slots?.pact_magic;
    return p ? `Pact Magic slot ${verb}. ${p.remaining} of ${p.max} left (${ord(p.slot_level)} level).` : `Pact Magic slot ${verb}.`;
  }
  if (pool === 'temporary') {
    const t = (slots?.temporary || []).find((x) => x.id === key);
    return t ? `Temporary ${ord(t.slot_level)}-level slot ${verb}. ${t.remaining} of ${t.quantity} left.` : `Temporary slot ${verb}.`;
  }
  const s = (slots?.standard || []).find((x) => String(x.slot_level) === String(key));
  return s ? `${ord(s.slot_level)}-level slot ${verb}. ${s.remaining} of ${s.max} left.` : `Spell slot ${verb}.`;
}

/** The Spell slots card body: standard slots and Pact Magic in separate panels, temporary slots, rests, manual adjust.
 * pending: keys ("standard:1", "pact", "temporary:<id>") with a request in flight; their buttons are marked busy (not
 * natively disabled, so keyboard focus stays) and further clicks are ignored by the sheet. */
export function slotTrackerHTML(slots, { editable = true, pending = new Set() } = {}) {
  if (!slots) return '<p class="muted small">Loading…</p>';
  const std = slots.standard || [];
  const pact = slots.pact_magic;
  const btn = (action, label, attrs, disabled, busyKey, alt) => {
    if (!editable) return '';
    const busy = pending.has(busyKey);
    return `<button type="button" class="btn btn-sm${busy ? ' is-pending' : ''}" data-action="${action}" data-slot-key="${esc(busyKey)}" ${attrs}
      ${alt ? `data-focus-alt="${esc(alt)}"` : ''} ${disabled ? 'disabled' : ''} ${busy ? 'aria-disabled="true" aria-busy="true"' : ''}>${label}</button>`;
  };
  const mode = slots.slot_mode === 'multiclass'
    ? `Multiclass caster level ${slots.effective_caster_level}: ${slots.breakdown.filter((b) => b.rounded_contribution > 0)
      .map((b) => `${b.class_id[0].toUpperCase() + b.class_id.slice(1)} ${b.class_level} → ${b.rounded_contribution}`).join(' + ')}`
    : slots.slot_mode === 'single_class' ? 'From your class table' : '';
  const stdHTML = std.length ? `<section class="slot-panel" data-slot-pool="standard">
      <h3 class="slot-panel-title">Standard slots <span class="muted small">${esc(mode)}</span></h3>
      ${std.map((s) => `<div class="slot-line" data-slot-level="${s.slot_level}">
        <span class="slot-line-level">${ord(s.slot_level)} level</span>
        ${pips(s.remaining, s.max, `${ord(s.slot_level)}-level slots`)}
        <span class="slot-line-count" data-slot-count="${s.slot_level}">${s.remaining} / ${s.max} remaining</span>
        <span class="slot-line-actions">${btn('slot-use', 'Use', `data-level="${s.slot_level}" data-focus-key="slot-use:${s.slot_level}" aria-label="Use a ${ord(s.slot_level)}-level slot"`, s.remaining <= 0, `standard:${s.slot_level}`, `slot-restore:${s.slot_level}`)}
          ${btn('slot-restore', 'Restore', `data-level="${s.slot_level}" data-focus-key="slot-restore:${s.slot_level}" aria-label="Restore a ${ord(s.slot_level)}-level slot"`, s.expended <= 0, `standard:${s.slot_level}`, `slot-use:${s.slot_level}`)}</span>
      </div>`).join('')}
      <p class="muted small">Standard slots come back on a long rest. A spell can use a slot of its level or higher.</p>
    </section>` : '';
  const pactHTML = pact ? `<section class="slot-panel slot-pact" data-slot-pool="pact">
      <h3 class="slot-panel-title">Pact Magic <span class="muted small">Warlock ${pact.warlock_level}</span></h3>
      <div class="slot-line">
        <span class="slot-line-level">Slot level: ${ord(pact.slot_level)}</span>
        ${pips(pact.remaining, pact.max, 'Pact Magic slots')}
        <span class="slot-line-count" data-pact-count>${pact.remaining} / ${pact.max} remaining</span>
        <span class="slot-line-actions">${btn('pact-use', 'Use', 'data-focus-key="pact-use" aria-label="Use a Pact Magic slot"', pact.remaining <= 0, 'pact', 'pact-restore')}
          ${btn('pact-restore', 'Restore', 'data-focus-key="pact-restore" aria-label="Restore a Pact Magic slot"', pact.expended <= 0, 'pact', 'pact-use')}</span>
      </div>
      <p class="muted small">All Pact slots are ${ord(pact.slot_level)} level and come back on a short or long rest. They are separate from standard slots.</p>
    </section>` : '';
  const temp = (slots.temporary || []).length ? `<section class="slot-panel" data-slot-pool="temporary"><h3 class="slot-panel-title">Temporary slots</h3>${slots.temporary.map((t) =>
    `<div class="slot-line" data-temp-slot="${esc(t.id)}"><span class="slot-line-level">${ord(t.slot_level)} level</span>
      ${pips(t.remaining, t.quantity, `Temporary ${ord(t.slot_level)}-level slot`)}
      <span class="slot-line-count">${t.remaining} / ${t.quantity} · ${esc(t.source_label)}, until ${t.expires_on === 'long_rest' ? 'a long rest' : t.expires_on === 'short_rest' ? 'a rest' : 'removed'}</span>
      <span class="slot-line-actions">${btn('temp-use', 'Use', `data-id="${esc(t.id)}" data-focus-key="temp-use:${esc(t.id)}"`, t.remaining <= 0, `temporary:${t.id}`, `temp-restore:${t.id}`)}
        ${btn('temp-restore', 'Restore', `data-id="${esc(t.id)}" data-focus-key="temp-restore:${esc(t.id)}"`, t.expended <= 0, `temporary:${t.id}`, `temp-use:${t.id}`)}</span></div>`).join('')}</section>` : '';
  const none = !std.length && !pact
    ? `<p class="muted small" data-no-class-slots>No spell slots from classes. ${slots.legacy_manual_active ? 'The manual slot tracker below still works for characters without classes.' : ''}</p>` : '';
  const adjust = editable && (std.length || pact) ? `<details class="slot-adjust" data-open-key="slot-adjust"><summary>Manual adjust</summary>
      <form class="form-grid" data-slot-adjust>
        <label class="field"><span>Slots</span><select name="pool">${std.map((s) => `<option value="standard:${s.slot_level}">${ord(s.slot_level)} level (max ${s.max})</option>`).join('')}
          ${pact ? `<option value="pact:0">Pact Magic (max ${pact.max})</option>` : ''}</select></label>
        <label class="field"><span>Used</span><input name="expended" type="number" min="0" max="9" value="0"></label>
        <label class="field span-2"><span>Reason (kept in the history)</span><input name="reason" maxlength="300" required placeholder="e.g. forgot to mark a slot"></label>
        <button type="submit" class="btn btn-sm">Set</button>
      </form></details>` : '';
  return `${stdHTML}${pactHTML}${temp}${none}
    ${editable ? `<div class="slot-rests">
      <button type="button" class="btn btn-sm" data-action="short-rest" data-focus-key="slot-short-rest">${icon('actions/short-rest', { size: 18 })}Short rest</button>
      <button type="button" class="btn btn-sm" data-action="long-rest" data-focus-key="slot-long-rest">${icon('actions/long-rest', { size: 18 })}Long rest</button></div>` : ''}
    ${adjust}`;
}

/** What a rest restores in this version (shown before the rest is taken). */
export function restDescription(kind, slots) {
  const pact = slots?.pact_magic;
  if (kind === 'short') {
    return ['Short rest restores:', pact ? '• Pact Magic slots' : '', '• resources and trackers that recharge on a short rest',
      'Standard spell slots are not restored. Spend hit dice by editing them on the Abilities tab.'].filter(Boolean).join('\n');
  }
  return ['Long rest restores:', '• HP, temporary HP and death saves; half your hit dice', '• all spell slots (standard and Pact Magic)',
    '• resources and trackers that recharge on a short or long rest', 'Temporary spell slots end. Conditions and prepared spells are not changed.'].join('\n');
}
