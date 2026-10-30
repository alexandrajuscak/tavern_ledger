// Class actions on spell slots, shown next to the slot tracker: slot recovery (Arcane Recovery, Natural Recovery, Harness
// Divine Power) and slot <-> points conversion (Font of Magic). Which resources offer them, the budget, the costs and the
// limits all come from get_character_resources (resource config) and get_character_spell_slots; the server re-checks every
// request in one transaction. Also: attack riders that spend a slot (riderSlotButton / openSlotRider). No class names here.
import { $, $$, esc, toast, openModal } from './utils.js?v=14';
import * as api from './class-api.js?v=14';

const ord = (n) => `${n}${n === 1 ? 'st' : n === 2 ? 'nd' : n === 3 ? 'rd' : 'th'}`;

/** Buttons under the slot tracker for every active resource that recovers or converts slots. */
export function slotActionsHTML(res, slots, { editable = true } = {}) {
  if (!res || !slots || !editable) return '';
  const list = (res.resources || []).filter((r) => r.active && (r.config?.slot_recovery || r.config?.conversion));
  if (!list.length) return '';
  const expended = (slots.standard || []).some((s) => s.expended > 0);
  const pactExpended = slots.pact_magic?.expended || 0;
  return `<div class="slot-actions" data-slot-actions>${list.map((r) => {
    if (r.config.slot_recovery?.pool === 'pact') {
      const why = r.remaining <= 0 ? 'already used' : !pactExpended ? 'no expended Pact slot' : '';
      return `<div class="slot-action" data-slot-action="${esc(r.key)}"><span><strong>${esc(r.feature_name || r.name)}</strong>
        <span class="muted small">regain every expended Pact Magic slot · ${r.remaining} / ${r.max} use${r.max === 1 ? '' : 's'}${why ? ` · ${why}` : ''}</span></span>
        <button type="button" class="btn btn-sm" data-action="slot-recover" data-key="${esc(r.key)}" data-focus-key="slot-recover:${esc(r.key)}"
          ${why ? 'disabled' : ''}>Regain Pact slots…</button></div>`;
    }
    if (r.config.slot_recovery) {
      const why = r.remaining <= 0 ? 'already used' : !expended ? 'no expended slot' : '';
      return `<div class="slot-action" data-slot-action="${esc(r.key)}"><span><strong>${esc(r.feature_name || r.name)}</strong>
        <span class="muted small">recover up to ${r.slot_recovery_budget} slot level${r.slot_recovery_budget === 1 ? '' : 's'}
          (max ${ord(r.config.slot_recovery.max_slot_level)} level${r.config.slot_recovery.max_slots ? `, ${r.config.slot_recovery.max_slots} slot` : ''}) · ${r.remaining} / ${r.max} use${r.max === 1 ? '' : 's'}${why ? ` · ${why}` : ''}</span></span>
        <button type="button" class="btn btn-sm" data-action="slot-recover" data-key="${esc(r.key)}" data-focus-key="slot-recover:${esc(r.key)}"
          ${why ? 'disabled' : ''}>Recover slots…</button></div>`;
    }
    return `<div class="slot-action" data-slot-action="${esc(r.key)}"><span><strong>${esc(r.name)}</strong>
        <span class="muted small">${r.remaining} / ${r.max} · turn a slot into points or points into a slot</span></span>
      <button type="button" class="btn btn-sm" data-action="slot-convert" data-key="${esc(r.key)}" data-focus-key="slot-convert:${esc(r.key)}">Flexible casting…</button></div>`;
  }).join('')}</div>`;
}

/** Choose expended slots to recover; the running total is checked against the budget before sending. */
export function openRecoverSlots({ characterId, resource, slots, onDone }) {
  const sr = resource.config.slot_recovery;
  if (sr.pool === 'pact') return openRecoverPact({ characterId, resource, slots, onDone });
  const budget = resource.slot_recovery_budget;
  const boxes = (slots.standard || []).filter((s) => s.slot_level <= sr.max_slot_level && s.expended > 0)
    .flatMap((s) => Array.from({ length: s.expended }, (_, i) => ({ level: s.slot_level, i })));
  const m = openModal({
    title: resource.feature_name || resource.name,
    body: `<form data-recover-form>
      <p class="small">Choose expended slots to recover. Their levels may add up to <strong>${budget}</strong>
        (no slot above ${ord(sr.max_slot_level)} level${sr.max_slots ? `, at most ${sr.max_slots} slot` : ''}).
        ${sr.also_expend ? 'This also spends one use of a linked resource (shown on the Play tab).' : ''}</p>
      <fieldset class="lin-step"><legend>Expended slots</legend>
        ${boxes.length ? boxes.map((b, n) => `<label class="check-field"><input type="checkbox" name="slot" value="${b.level}" data-n="${n}">
          <span>${ord(b.level)}-level slot</span></label>`).join('') : '<p class="muted small">No expended slot can be recovered.</p>'}
      </fieldset>
      <p class="small" aria-live="polite" data-recover-total>Chosen: 0 of ${budget} levels</p>
    </form>`,
    footer: `<button type="button" class="btn" data-close>Cancel</button>
      <button type="button" class="btn btn-gold" data-recover-ok disabled>Recover</button>`,
  });
  const ok = $('[data-recover-ok]', m.el);
  const total = $('[data-recover-total]', m.el);
  const picked = () => $$('input[name=slot]:checked', m.el).map((x) => Number(x.value));
  m.el.addEventListener('change', () => {
    const p = picked();
    const sum = p.reduce((a, b) => a + b, 0);
    const over = sum > budget || (sr.max_slots && p.length > sr.max_slots);
    total.textContent = `Chosen: ${sum} of ${budget} levels${over ? ' — too many' : ''}`;
    total.classList.toggle('sp-warn', !!over);
    ok.disabled = !p.length || !!over;
  });
  ok.addEventListener('click', async () => {
    ok.disabled = true;
    try {
      const r = await api.recoverSpellSlots(characterId, resource.key, picked());
      toast(`Recovered: ${picked().map(ord).join(', ')} level slot${picked().length === 1 ? '' : 's'}.`, 'good');
      m.close();
      await onDone?.(r);
    } catch (err) { toast(err.message, 'bad'); ok.disabled = false; }
  });
  return m;
}

/** Recovery of the whole Pact Magic pool: nothing to choose, one confirmation. */
function openRecoverPact({ characterId, resource, slots, onDone }) {
  const pm = slots.pact_magic || { expended: 0, max: 0, slot_level: 1 };
  const m = openModal({
    title: resource.feature_name || resource.name,
    body: `<p class="small">Regain <strong>${pm.expended}</strong> expended Pact Magic slot${pm.expended === 1 ? '' : 's'}
      (${ord(pm.slot_level)} level). This spends ${esc(resource.name)} (${resource.remaining} / ${resource.max}).</p>
      ${resource.activation_note ? `<p class="muted small">${esc(resource.activation_note)}</p>` : ''}`,
    footer: `<button type="button" class="btn" data-close>Cancel</button>
      <button type="button" class="btn btn-gold" data-recover-ok ${pm.expended ? '' : 'disabled'}>Regain slots</button>`,
  });
  const ok = $('[data-recover-ok]', m.el);
  ok.addEventListener('click', async () => {
    ok.disabled = true;
    try {
      const r = await api.recoverSpellSlots(characterId, resource.key, []);
      toast('Pact Magic slots regained.', 'good');
      m.close();
      await onDone?.(r);
    } catch (err) { toast(err.message, 'bad'); ok.disabled = false; }
  });
  return m;
}

/** "Use…" on an attack rider that spends a spell slot (its dice depend on the slot level). */
export function riderSlotButton(r, { editable = true } = {}) {
  if (!editable || !r?.uses_slot || !r.dice_by_slot) return '';
  return `<button type="button" class="btn btn-sm" data-action="rider-slot" data-rider="${esc(r.name)}"
    data-focus-key="rider-slot:${esc(r.name)}" aria-label="Use ${esc(r.name)}: spend a spell slot">Spend a slot…</button>`;
}

/** Choose the slot to spend on a slot rider; the dice for each level come from the rider. The slot is expended by the server. */
export function openSlotRider({ characterId, rider, slots, onDone }) {
  const dice = rider.dice_by_slot || {};
  const levels = Object.keys(dice).map(Number);
  const pool = rider.slot_pool || 'standard';
  const opts = pool === 'pact'
    ? (slots.pact_magic && slots.pact_magic.max ? [{ value: 'pact', level: slots.pact_magic.slot_level, left: slots.pact_magic.remaining, label: 'Pact Magic slot' }] : [])
    : (slots.standard || []).filter((s) => levels.includes(s.slot_level))
      .map((s) => ({ value: `standard:${s.slot_level}`, level: s.slot_level, left: s.remaining, label: `${ord(s.slot_level)}-level slot` }));
  const m = openModal({
    title: rider.name,
    body: `<form data-rider-form>
      <p class="small">${esc(rider.condition || 'Spend a spell slot when the conditions are met.')}</p>
      <fieldset class="lin-step"><legend>Slot to spend</legend>
        ${opts.length ? opts.map((o) => `<label class="check-field"><input type="radio" name="rslot" value="${o.value}" data-level="${o.level}" ${o.left > 0 ? '' : 'disabled'}>
          <span>${esc(o.label)}${pool === 'pact' ? ` (${ord(o.level)})` : ''} — <strong>${esc(dice[o.level] || dice[Math.max(...levels)] || '')}</strong>
          ${esc(rider.damage_type || '')} · ${o.left} left</span></label>`).join('') : '<p class="muted small">You have no spell slot this can use.</p>'}
      </fieldset>
      <p class="muted small">The extra damage is not added to an attack automatically: roll it with the hit.</p>
    </form>`,
    footer: `<button type="button" class="btn" data-close>Cancel</button>
      <button type="button" class="btn btn-gold" data-rider-ok disabled>Spend slot</button>`,
  });
  const ok = $('[data-rider-ok]', m.el);
  m.el.addEventListener('change', () => { ok.disabled = !$('input[name=rslot]:checked', m.el); });
  ok.addEventListener('click', async () => {
    const sel = $('input[name=rslot]:checked', m.el);
    const level = Number(sel.dataset.level);
    ok.disabled = true;
    try {
      const r = sel.value === 'pact' ? await api.expendPactSlot(characterId) : await api.expendStandardSlot(characterId, level);
      toast(`${rider.name}: roll ${dice[level] || dice[Math.max(...levels)]} ${rider.damage_type || ''} (${ord(level)}-level slot spent).`, 'good');
      m.close();
      await onDone?.(r);
    } catch (err) { toast(err.message, 'bad'); ok.disabled = false; }
  });
  return m;
}

/** Font of Magic: create a slot from points, or turn a slot into points. */
export function openFlexibleCasting({ characterId, resource, slots, onDone }) {
  const cv = resource.config.conversion;
  const levels = Object.keys(cv.create_costs).map(Number).filter((l) => l <= cv.max_created_level).sort((a, b) => a - b);
  const stdLeft = (slots.standard || []).filter((s) => s.remaining > 0);
  const pact = slots.pact_magic && slots.pact_magic.remaining > 0 ? slots.pact_magic : null;
  const room = resource.expended || 0;
  const m = openModal({
    title: `Flexible casting (${resource.name}: ${resource.remaining} / ${resource.max})`,
    wide: true,
    body: `<div class="form-grid" data-flex>
      <fieldset class="lin-step"><legend>Create a spell slot</legend>
        ${levels.map((l) => `<label class="check-field"><input type="radio" name="create" value="${l}" ${resource.remaining < cv.create_costs[l] ? 'disabled' : ''}>
          <span>${ord(l)}-level slot — ${cv.create_costs[l]} points${resource.remaining < cv.create_costs[l] ? ' (not enough points)' : ''}</span></label>`).join('')}
        <p class="muted small">A created slot vanishes after a long rest.</p>
        <button type="button" class="btn btn-sm btn-gold" data-flex-create disabled>Create slot</button>
      </fieldset>
      <fieldset class="lin-step"><legend>Turn a slot into points</legend>
        ${stdLeft.map((s) => `<label class="check-field"><input type="radio" name="convert" value="standard:${s.slot_level}" ${room ? '' : 'disabled'}>
          <span>${ord(s.slot_level)}-level slot → ${Math.min(s.slot_level, room)} point${Math.min(s.slot_level, room) === 1 ? '' : 's'}</span></label>`).join('')}
        ${pact ? `<label class="check-field"><input type="radio" name="convert" value="pact:${pact.slot_level}" ${room ? '' : 'disabled'}>
          <span>Pact Magic slot (${ord(pact.slot_level)}) → ${Math.min(pact.slot_level, room)} points</span></label>` : ''}
        ${!stdLeft.length && !pact ? '<p class="muted small">No spell slot left.</p>' : ''}
        ${room ? '' : '<p class="muted small">Your points are full.</p>'}
        <button type="button" class="btn btn-sm" data-flex-convert disabled>Convert slot</button>
      </fieldset></div>`,
    footer: '<button type="button" class="btn" data-close>Close</button>',
  });
  const cBtn = $('[data-flex-create]', m.el);
  const vBtn = $('[data-flex-convert]', m.el);
  m.el.addEventListener('change', () => {
    cBtn.disabled = !$('input[name=create]:checked', m.el);
    vBtn.disabled = !$('input[name=convert]:checked', m.el);
  });
  const run = async (btn, fn, msg) => {
    btn.disabled = true;
    try { const r = await fn(); toast(msg, 'good'); m.close(); await onDone?.(r); } catch (err) { toast(err.message, 'bad'); btn.disabled = false; }
  };
  cBtn.addEventListener('click', () => {
    const l = Number($('input[name=create]:checked', m.el).value);
    run(cBtn, () => api.convertSpellSlot(characterId, resource.key, 'points_to_slot', l), `Created a ${ord(l)}-level slot.`);
  });
  vBtn.addEventListener('click', () => {
    const [pool, l] = $('input[name=convert]:checked', m.el).value.split(':');
    run(vBtn, () => api.convertSpellSlot(characterId, resource.key, 'slot_to_points', Number(l), pool), `Turned a ${ord(Number(l))}-level slot into points.`);
  });
  return m;
}
