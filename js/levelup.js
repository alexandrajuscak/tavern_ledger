// Level Up Wizard: a guided editor, not a rules engine. It proposes sensible
// defaults (average HP, next level) and lets the player/DM change anything.

import { supabase } from './supabase.js?v=7';
import {
  ABILITY_BY_KEY, FEATURE_CATEGORIES, ACTIVATIONS, HIT_DICE, RESOURCE_PRESETS, RESET_LABELS,
  mod, fmt, hitDieAverage, dieSize, profBonus,
} from './dnd.js?v=7';
import { $, $$, esc, toast, openModal } from './utils.js?v=7';

const STEPS = ['Level & HP', 'Subclass & Features', 'Resources', 'Spell Slots', 'Review'];

export function openLevelUp(bundle, { onApplied }) {
  const c = bundle.character;
  if (c.level >= 20) {
    toast('This character is already level 20.');
    return;
  }

  const conMod = mod(c[ABILITY_BY_KEY.con.col]);
  const st = {
    step: 0,
    level: c.level + 1,
    hitDie: c.hit_die,
    hpMethod: 'average', // average | roll | manual
    hpRoll: '',
    hpManual: '',
    subclass: c.subclass || '',
    features: [], // { category, name, description }
    trackerMax: Object.fromEntries(bundle.trackers.map((t) => [t.id, t.max])),
    newTrackers: [], // { name, max, reset }
    slotTotals: Object.fromEntries(bundle.slots.map((s) => [s.level, s.total])),
  };

  function hpGain() {
    let base;
    if (st.hpMethod === 'average') base = hitDieAverage(st.hitDie) + conMod;
    else if (st.hpMethod === 'roll') base = (parseInt(st.hpRoll, 10) || 0) + conMod;
    else return Math.max(0, parseInt(st.hpManual, 10) || 0);
    return Math.max(1, base);
  }

  // ---- Step renderers -------------------------------------------------------

  function stepLevel() {
    const pbOld = profBonus(c.level);
    const pbNew = profBonus(st.level);
    return `
      <div class="wiz-grid">
        <label class="field"><span>New level</span>
          <input type="number" id="lu-level" min="${c.level}" max="20" value="${st.level}">
        </label>
        <label class="field"><span>Hit die</span>
          <select id="lu-die">${HIT_DICE.map((d) => `<option ${d === st.hitDie ? 'selected' : ''}>${d}</option>`).join('')}</select>
        </label>
      </div>
      ${pbNew !== pbOld ? `<p class="callout">Proficiency bonus increases to <strong>${fmt(pbNew)}</strong>.</p>` : ''}
      <h4>Hit point increase</h4>
      <div class="radio-cards">
        <label class="radio-card"><input type="radio" name="lu-hp" value="average" ${st.hpMethod === 'average' ? 'checked' : ''}>
          <span><strong>Take average</strong><small>${hitDieAverage(st.hitDie)} ${fmt(conMod)} CON</small></span></label>
        <label class="radio-card"><input type="radio" name="lu-hp" value="roll" ${st.hpMethod === 'roll' ? 'checked' : ''}>
          <span><strong>Rolled</strong><small>1${st.hitDie} ${fmt(conMod)} CON</small></span></label>
        <label class="radio-card"><input type="radio" name="lu-hp" value="manual" ${st.hpMethod === 'manual' ? 'checked' : ''}>
          <span><strong>Custom</strong><small>DM's call</small></span></label>
      </div>
      <div class="wiz-grid">
        <label class="field" ${st.hpMethod === 'roll' ? '' : 'hidden'}><span>Die result (1–${dieSize(st.hitDie)})</span>
          <input type="number" id="lu-roll" min="1" max="${dieSize(st.hitDie)}" value="${esc(st.hpRoll)}"></label>
        <label class="field" ${st.hpMethod === 'manual' ? '' : 'hidden'}><span>Total HP gained</span>
          <input type="number" id="lu-manual" min="0" value="${esc(st.hpManual)}"></label>
      </div>
      <p class="hp-preview">Max HP: <strong>${c.hp_max}</strong> → <strong class="gold">${c.hp_max + hpGain()}</strong> <span class="muted">(+${hpGain()})</span></p>`;
  }

  function stepFeatures() {
    const rows = st.features.map((f, i) => `
      <div class="wiz-feature card" data-i="${i}">
        <div class="feature-head">
          <input type="text" data-ff="name" value="${esc(f.name)}" placeholder="Feature name">
          <select data-ff="activation" aria-label="Type">${ACTIVATIONS.map((a) => `<option value="${a.key}" ${f.activation === a.key ? 'selected' : ''}>${a.label}</option>`).join('')}</select>
          <select data-ff="category" aria-label="Source">${FEATURE_CATEGORIES.map((c) => `<option value="${c.key}" ${f.category === c.key ? 'selected' : ''}>${c.label}</option>`).join('')}</select>
          <button type="button" class="icon-btn danger" data-remove-feature="${i}" aria-label="Remove">✕</button>
        </div>
        <textarea data-ff="description" rows="2" placeholder="Description">${esc(f.description)}</textarea>
      </div>`).join('');
    return `
      <label class="field"><span>Subclass</span>
        <input type="text" id="lu-subclass" value="${esc(st.subclass)}" placeholder="e.g. Path of the Berserker">
      </label>
      <div class="section-head mt"><h4>New features</h4>
        <button type="button" class="btn btn-sm" id="lu-add-feature">+ Add feature</button></div>
      <div id="lu-features">${rows || '<p class="empty">No new features this level? That is fine too.</p>'}</div>`;
  }

  function stepResources() {
    const existing = bundle.trackers.map((t) => `
      <div class="kv">
        <span>${esc(t.name)} <small class="muted">(${t.max} now${t.formula ? ` · formula: ${esc(t.formula)}` : ""})</small></span>
        <input type="number" class="small-num" min="0" data-tracker="${t.id}" value="${st.trackerMax[t.id]}" aria-label="${esc(t.name)} maximum">
      </div>`).join('');
    const added = st.newTrackers.map((t, i) => `
      <div class="wiz-tracker" data-i="${i}">
        <input type="text" data-tf="name" value="${esc(t.name)}" placeholder="Name" aria-label="Resource name">
        <input type="number" class="small-num" data-tf="max" min="0" value="${t.max}" aria-label="Maximum">
        <select data-tf="reset">${Object.entries(RESET_LABELS).map(([k, l]) => `<option value="${k}" ${t.reset === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
        <button type="button" class="icon-btn danger" data-remove-tracker="${i}" aria-label="Remove">✕</button>
      </div>`).join('');
    return `
      ${existing ? `<h4>Existing resources — new maximum</h4><div class="kv-list">${existing}</div>` : ''}
      <div class="section-head mt"><h4>New resource pools</h4>
        <div class="row gap">
          <select id="lu-preset">${RESOURCE_PRESETS.map((p, i) => `<option value="${i}">${p.name}</option>`).join('')}<option value="custom">Custom</option></select>
          <button type="button" class="btn btn-sm" id="lu-add-tracker">+ Add</button>
        </div></div>
      <div id="lu-trackers">${added || '<p class="empty">None added.</p>'}</div>`;
  }

  function stepSlots() {
    const inputs = [1, 2, 3, 4, 5, 6, 7, 8, 9].map((l) => `
      <label class="slot-input"><span>${l}</span>
        <input type="number" min="0" max="9" data-slot="${l}" value="${st.slotTotals[l] ?? 0}" aria-label="Level ${l} slots"></label>`).join('');
    return `
      <p class="muted">Set the total number of spell slots per spell level. Leave at 0 for non-casters.</p>
      <div class="slot-inputs">${inputs}</div>`;
  }

  function stepReview() {
    const items = [];
    items.push(`Level <strong>${c.level} → ${st.level}</strong>`);
    items.push(`Max HP <strong>${c.hp_max} → ${c.hp_max + hpGain()}</strong> (current HP +${hpGain()})`);
    if (st.hitDie !== c.hit_die) items.push(`Hit die → <strong>${st.hitDie}</strong>`);
    if (st.subclass !== (c.subclass || '')) items.push(`Subclass → <strong>${esc(st.subclass || '—')}</strong>`);
    st.features.filter((f) => f.name.trim()).forEach((f) => items.push(`New feature: <strong>${esc(f.name)}</strong>`));
    bundle.trackers.forEach((t) => {
      if (st.trackerMax[t.id] !== t.max) items.push(`${esc(t.name)} max <strong>${t.max} → ${st.trackerMax[t.id]}</strong>`);
    });
    st.newTrackers.filter((t) => t.name.trim()).forEach((t) => items.push(`New resource: <strong>${esc(t.name)}</strong> (${t.max})`));
    bundle.slots.forEach((s) => {
      if ((st.slotTotals[s.level] ?? 0) !== s.total) items.push(`Level ${s.level} slots <strong>${s.total} → ${st.slotTotals[s.level]}</strong>`);
    });
    return `<ul class="review-list">${items.map((i) => `<li>${i}</li>`).join('')}</ul>
      <p class="muted small">Nothing is saved until you press <strong>Apply level up</strong>.</p>`;
  }

  const RENDER = [stepLevel, stepFeatures, stepResources, stepSlots, stepReview];

  // ---- Collect form values into state ----------------------------------------

  function collect() {
    const body = m.body;
    switch (st.step) {
      case 0: {
        st.level = Math.min(20, Math.max(c.level, parseInt($('#lu-level', body).value, 10) || st.level));
        st.hitDie = $('#lu-die', body).value;
        st.hpMethod = $('input[name="lu-hp"]:checked', body)?.value || 'average';
        st.hpRoll = $('#lu-roll', body).value;
        st.hpManual = $('#lu-manual', body).value;
        break;
      }
      case 1: {
        st.subclass = $('#lu-subclass', body).value;
        $$('.wiz-feature', body).forEach((el) => {
          const f = st.features[Number(el.dataset.i)];
          $$('[data-ff]', el).forEach((inp) => { f[inp.dataset.ff] = inp.value; });
        });
        break;
      }
      case 2: {
        $$('[data-tracker]', body).forEach((inp) => {
          st.trackerMax[inp.dataset.tracker] = Math.max(0, parseInt(inp.value, 10) || 0);
        });
        $$('.wiz-tracker', body).forEach((el) => {
          const t = st.newTrackers[Number(el.dataset.i)];
          $$('[data-tf]', el).forEach((inp) => {
            t[inp.dataset.tf] = inp.dataset.tf === 'max' ? Math.max(0, parseInt(inp.value, 10) || 0) : inp.value;
          });
        });
        break;
      }
      case 3: {
        $$('[data-slot]', body).forEach((inp) => {
          st.slotTotals[inp.dataset.slot] = Math.min(9, Math.max(0, parseInt(inp.value, 10) || 0));
        });
        break;
      }
      default:
    }
  }

  // ---- Modal plumbing ---------------------------------------------------------

  const m = openModal({ title: `Level Up — ${c.name}`, wide: true });

  function paint() {
    const steps = STEPS.map((s, i) => `
      <li class="${i === st.step ? 'current' : ''} ${i < st.step ? 'done' : ''}">
        <span class="step-num">${i + 1}</span><span class="step-label">${s}</span></li>`).join('');
    m.body.innerHTML = `<ol class="wiz-steps">${steps}</ol><div class="wiz-body">${RENDER[st.step]()}</div>`;
    const last = st.step === STEPS.length - 1;
    m.footer.innerHTML = `
      <button type="button" class="btn" id="lu-back" ${st.step === 0 ? 'disabled' : ''}>Back</button>
      <button type="button" class="btn btn-gold" id="lu-next">${last ? 'Apply level up' : 'Next'}</button>`;
  }

  m.body.addEventListener('change', (e) => {
    // Live-refresh the HP preview / visible inputs on step 1.
    if (st.step === 0 && (e.target.name === 'lu-hp' || e.target.id === 'lu-die')) { collect(); paint(); }
  });
  m.body.addEventListener('input', (e) => {
    if (st.step === 0 && ['lu-roll', 'lu-manual', 'lu-level'].includes(e.target.id)) {
      collect();
      const p = $('.hp-preview', m.body);
      if (p) p.innerHTML = `Max HP: <strong>${c.hp_max}</strong> → <strong class="gold">${c.hp_max + hpGain()}</strong> <span class="muted">(+${hpGain()})</span>`;
    }
  });
  m.body.addEventListener('click', (e) => {
    const t = e.target;
    if (t.id === 'lu-add-feature') {
      collect();
      st.features.push({ category: 'class', activation: 'passive', name: '', description: '' });
      paint();
      $$('.wiz-feature input[data-ff="name"]', m.body).pop()?.focus();
    } else if (t.dataset.removeFeature != null) {
      collect();
      st.features.splice(Number(t.dataset.removeFeature), 1);
      paint();
    } else if (t.id === 'lu-add-tracker') {
      collect();
      const v = $('#lu-preset', m.body).value;
      const preset = v === 'custom' ? { name: '', reset: 'long' } : RESOURCE_PRESETS[Number(v)];
      st.newTrackers.push({ name: preset.name, max: 1, reset: preset.reset });
      paint();
    } else if (t.dataset.removeTracker != null) {
      collect();
      st.newTrackers.splice(Number(t.dataset.removeTracker), 1);
      paint();
    }
  });
  m.footer.addEventListener('click', async (e) => {
    if (e.target.id === 'lu-back') {
      collect();
      st.step -= 1;
      paint();
    } else if (e.target.id === 'lu-next') {
      collect();
      if (st.step < STEPS.length - 1) {
        st.step += 1;
        paint();
        return;
      }
      e.target.disabled = true;
      e.target.textContent = 'Applying…';
      try {
        await apply();
        m.close();
        toast(`${c.name} is now level ${st.level}!`, 'good');
        onApplied?.();
      } catch (err) {
        console.error(err);
        toast(err.message || 'Level up failed', 'bad');
        e.target.disabled = false;
        e.target.textContent = 'Apply level up';
      }
    }
  });

  paint();

  // ---- Apply ----------------------------------------------------------------

  async function apply() {
    const gain = hpGain();
    const ops = [];
    ops.push(supabase.from('characters').update({
      level: st.level,
      hit_die: st.hitDie,
      subclass: st.subclass.trim(),
      hp_max: c.hp_max + gain,
      hp_current: c.hp_current + gain,
      hit_dice_current: Math.min(st.level, c.hit_dice_current + (st.level - c.level)),
    }).eq('id', c.id));

    const features = st.features
      .filter((f) => f.name.trim())
      .map((f, i) => ({
        character_id: c.id, category: f.category, activation: f.activation || 'passive', name: f.name.trim(), description: f.description,
        sort_order: bundle.features.length + i,
      }));
    if (features.length) ops.push(supabase.from('features').insert(features));

    const trackers = st.newTrackers
      .filter((t) => t.name.trim())
      .map((t, i) => ({
        character_id: c.id, name: t.name.trim(), max: t.max, current: t.max, reset_on: t.reset,
        sort_order: bundle.trackers.length + i,
      }));
    if (trackers.length) ops.push(supabase.from('feature_trackers').insert(trackers));

    for (const t of bundle.trackers) {
      const max = st.trackerMax[t.id];
      if (max !== t.max) {
        const current = Math.min(max, Math.max(0, t.current + (max - t.max)));
        ops.push(supabase.from('feature_trackers').update({ max, current }).eq('id', t.id));
      }
    }
    for (const s of bundle.slots) {
      const total = st.slotTotals[s.level] ?? 0;
      if (total !== s.total) {
        ops.push(supabase.from('spell_slots').update({ total, used: Math.min(s.used, total) }).eq('id', s.id));
      }
    }

    const results = await Promise.all(ops);
    const failed = results.find((r) => r.error);
    if (failed) throw failed.error;
  }
}
