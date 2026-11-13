// Wild Shape (transformation) panel and Companions card. Data from get_character_transformation and character_companions;
// the forms a character may take, their cost and the hit point carry-over are decided by the server. No class names here.
import { $, $$, esc, toast, openModal, confirmDialog } from './utils.js?v=32';
import * as api from './creature-api.js?v=32';

const ABIL = ['str', 'dex', 'con', 'int', 'wis', 'cha'];
const mod = (s) => Math.floor((Number(s) - 10) / 2);
const sgn = (n) => (n >= 0 ? `+${n}` : `−${Math.abs(n)}`);
const cr = (v) => ({ 0.125: '1/8', 0.25: '1/4', 0.5: '1/2' }[Number(v)] || String(Number(v)));
const REASON = {
  challenge_rating: 'challenge rating too high', flying_speed: 'flying speed not allowed yet', swimming_speed: 'swimming speed not allowed yet',
  not_allowed_type: 'not a form you can take',
};
const speedText = (sp) => Object.entries(sp || {}).filter(([, v]) => v && v !== true).map(([k, v]) => (k === 'walk' ? `${v} ft` : `${k} ${v} ft`)).join(', ');

function attacksHTML(actions) {
  const list = (actions || []).filter((a) => a.attack_bonus != null || a.damage || a.dc);
  if (!list.length) return '';
  return `<ul class="small cr-attacks">${list.map((a) => `<li><strong>${esc(a.name)}</strong>${a.attack_bonus != null ? ` ${sgn(a.attack_bonus)} to hit` : ''}${
    a.reach ? `, reach ${a.reach} ft` : ''}${a.range ? `, range ${a.range.join('/')} ft` : ''}${
    (a.damage || []).length ? ` · ${a.damage.map((d) => `${esc(d.dice)} ${esc(d.type || '')}`).join(' + ')}` : ''}${
    a.dc ? ` · DC ${a.dc.value} ${esc(String(a.dc.ability || '').toUpperCase())}` : ''}</li>`).join('')}</ul>`;
}

/** Compact stat block of a catalog creature (mechanics only). */
export function statBlockHTML(c) {
  if (!c) return '';
  return `<div class="cr-stat" data-creature="${esc(c.id)}">
    <p class="small"><strong>AC ${c.armor_class}</strong> · HP ${c.hit_points}${c.hit_dice ? ` (${esc(c.hit_dice)})` : ''} · ${esc(speedText(c.speed))}</p>
    <div class="cr-abil small">${ABIL.map((a) => `<span><abbr title="${a.toUpperCase()}">${a.toUpperCase()}</abbr> ${c.abilities?.[a] ?? '—'} (${sgn(mod(c.abilities?.[a] ?? 10))})</span>`).join('')}</div>
    ${Object.keys(c.senses || {}).length ? `<p class="small muted">Senses: ${Object.entries(c.senses).map(([k, v]) => `${esc(k.replace(/_/g, ' '))} ${esc(String(v))}`).join(', ')}</p>` : ''}
    ${attacksHTML(c.actions)}
    ${(c.traits || []).length ? `<p class="small muted">Traits: ${c.traits.map((t) => esc(t.name)).join(', ')}</p>` : ''}
    <p class="muted small">${esc(c.source_label || '')}${c.license ? ` (${esc(c.license)})` : ''}</p>
  </div>`;
}

/** The transformation panel: the current form with its hit points, or the button to choose one. */
export function transformHTML(tf, { editable = true } = {}) {
  if (!tf || !(tf.rules || []).length) return '';
  const res = (tf.resources || [])[0];
  const left = res ? (res.unlimited ? 'unlimited uses' : `${res.remaining} / ${res.max} uses left`) : '';
  const a = tf.active;
  if (a) {
    const pct = Math.round((a.hp_current / a.hp_max) * 100);
    return `<section class="cr-transform is-active" data-transform="active">
      <h4>${esc(a.name)} <span class="cf-badge cf-auto-automated">Current form</span> <span class="muted small">CR ${cr(a.creature.challenge_rating)} · ${esc(left)}</span></h4>
      <div class="cr-hp"><span data-tf-hp><strong>${a.hp_current} / ${a.hp_max}</strong> form hit points</span>
        <span class="cr-hpbar" role="img" aria-label="Form hit points ${a.hp_current} of ${a.hp_max}"><span style="width:${pct}%"></span></span></div>
      ${editable ? `<div class="cr-hp-actions"><label><span class="sr-only">Amount</span><input type="number" min="1" max="999" value="1" data-tf-amount></label>
        <button type="button" class="btn btn-sm btn-bad" data-action="tf-damage" data-focus-key="tf-damage">Damage</button>
        <button type="button" class="btn btn-sm" data-action="tf-heal" data-focus-key="tf-heal">Heal</button>
        <button type="button" class="btn btn-sm" data-action="tf-end" data-focus-key="tf-end">Return to normal form</button></div>` : ''}
      <p class="muted small">Damage that drops the form to 0 ends it; the rest carries over to your own hit points.</p>
      ${statBlockHTML(a.creature)}
    </section>`;
  }
  const can = (tf.options || []).filter((o) => o.allowed).length;
  const out = res && !res.unlimited && res.remaining <= 0;
  return `<section class="cr-transform" data-transform="idle">
    <h4>${esc(res?.name || tf.rules[0].feature_name)} <span class="muted small">${esc(left)} · ${can} form${can === 1 ? '' : 's'} available · max CR ${cr(Math.max(...tf.rules.map((r) => r.max_cr ?? 0)))}</span></h4>
    ${editable ? `<button type="button" class="btn btn-sm btn-gold" data-action="tf-pick" data-focus-key="tf-pick" ${out ? 'disabled title="No uses left"' : ''}>Choose a form…</button>` : ''}
  </section>`;
}

/** Form picker: search, "only forms I can take", reasons for the others; choosing spends the cost. */
export function openFormPicker({ characterId, tf, onDone }) {
  const opts = tf.options || [];
  const m = openModal({
    title: 'Choose a form',
    wide: true,
    body: `<div data-tf-picker>
      <div class="form-grid"><label class="field"><span>Search</span><input type="search" data-tf-q placeholder="Wolf, bear…" autocomplete="off"></label>
        <label class="check-field"><input type="checkbox" data-tf-allowed checked><span>Only forms I can take now</span></label></div>
      <ul class="cr-options" data-tf-list role="listbox" aria-label="Forms"></ul>
      <div data-tf-detail aria-live="polite"></div>
    </div>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-tf-ok disabled>Take this form</button>',
  });
  const list = $('[data-tf-list]', m.el);
  const ok = $('[data-tf-ok]', m.el);
  let picked = null;
  const draw = () => {
    const q = $('[data-tf-q]', m.el).value.trim().toLowerCase();
    const only = $('[data-tf-allowed]', m.el).checked;
    const rows = opts.filter((o) => (!only || o.allowed) && (!q || o.name.toLowerCase().includes(q))).slice(0, 150);
    list.innerHTML = rows.length ? rows.map((o) => `<li><button type="button" class="cr-option ${o.allowed ? '' : 'is-disabled'}" data-tf-option="${esc(o.id)}"
        ${o.allowed ? '' : 'aria-disabled="true"'} aria-pressed="${picked === o.id}">
        <strong>${esc(o.name)}</strong> <span class="muted small">CR ${cr(o.challenge_rating)} · ${esc(o.size)} · AC ${o.armor_class} · HP ${o.hit_points} · ${esc(speedText(o.speed))}</span>
        ${o.allowed ? (o.cost > 1 ? ` <span class="cf-badge">${o.cost} uses</span>` : '') : ` <span class="sp-warn small">${esc(REASON[o.reason] || o.reason || '')}</span>`}
      </button></li>`).join('') : '<li class="muted small">No form matches.</li>';
  };
  m.el.addEventListener('input', (e) => { if (e.target.matches('[data-tf-q]')) draw(); });
  m.el.addEventListener('change', (e) => { if (e.target.matches('[data-tf-allowed]')) draw(); });
  list.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-tf-option]');
    if (!b) return;
    const o = opts.find((x) => x.id === b.dataset.tfOption);
    picked = o.allowed ? o.id : null;
    ok.disabled = !picked;
    draw();
    const c = await api.getCreature(o.id).catch(() => null);
    $('[data-tf-detail]', m.el).innerHTML = c ? `<h4>${esc(c.name)}</h4>${statBlockHTML(c)}` : '';
  });
  ok.addEventListener('click', async () => {
    ok.disabled = true;
    try {
      const r = await api.startTransformation(characterId, picked);
      toast(`You take the form of ${r.active?.name || 'the creature'}.`, 'good');
      m.close();
      await onDone?.(r);
    } catch (err) { toast(err.message, 'bad'); ok.disabled = false; }
  });
  draw();
  setTimeout(() => $('[data-tf-q]', m.el)?.focus(), 50);
  return m;
}

/** Damage / heal the form from the panel's amount field; returns the server result. */
export async function changeFormHp(root, characterId, sign) {
  const n = Math.max(1, Math.floor(Number($('[data-tf-amount]', root)?.value) || 1));
  const r = await api.changeTransformationHp(characterId, sign * n);
  if (r.ended) toast(`The form drops to 0 hit points and ends.${r.carryover ? ` ${r.carryover} damage carries over to you.` : ''}`, 'bad');
  else toast(`Form hit points: ${r.active.hp_current} / ${r.active.hp_max}`, 'good');
  return r;
}

// ------------------------------------------------------------------------------------------------------------ companions
export function companionsHTML(list, { editable = true } = {}) {
  const rows = (list || []).map((c) => `<article class="cr-companion ${c.active ? '' : 'is-inactive'}" data-companion="${esc(c.id)}">
      <div class="cr-companion-head"><strong>${esc(c.name)}</strong>
        <span class="muted small">${c.creature ? `${esc(c.creature.name)} · ${esc(c.creature.size)} ${esc(c.creature.creature_type)} · CR ${cr(c.creature.challenge_rating)} · AC ${c.creature.armor_class}` : 'Custom'}${
          c.source ? ` · ${esc(c.source)}` : ''}</span></div>
      <div class="cr-hp"><span><strong>${c.hp_current} / ${c.hp_max}</strong> HP</span>
        ${editable ? `<label><span class="sr-only">Amount for ${esc(c.name)}</span><input type="number" min="1" max="999" value="1" data-comp-amount></label>
          <button type="button" class="btn btn-sm btn-bad" data-action="comp-hp" data-id="${esc(c.id)}" data-sign="-1" data-focus-key="comp-dmg:${esc(c.id)}">Damage</button>
          <button type="button" class="btn btn-sm" data-action="comp-hp" data-id="${esc(c.id)}" data-sign="1" data-focus-key="comp-heal:${esc(c.id)}">Heal</button>
          <button type="button" class="btn btn-sm" data-action="comp-remove" data-id="${esc(c.id)}">Remove</button>` : ''}</div>
      ${c.creature ? attacksHTML(c.creature.actions) : ''}
      ${c.notes ? `<p class="small">${esc(c.notes)}</p>` : ''}
    </article>`).join('');
  return `${rows || '<p class="muted small">No companions. Familiars, steeds and other creatures that travel with you can be tracked here.</p>'}
    ${editable ? '<button type="button" class="btn btn-sm" data-action="comp-add" data-focus-key="comp-add">+ Add companion</button>' : ''}`;
}

export async function openAddCompanion({ characterId, onDone }) {
  const all = await api.getCreatures();
  const m = openModal({
    title: 'Add a companion',
    wide: true,
    body: `<form class="form-grid" data-comp-form>
      <label class="field span-2"><span>Creature (catalog)</span><input type="search" data-comp-q placeholder="Owl, warhorse, imp…" autocomplete="off"></label>
      <ul class="cr-options span-2" data-comp-list role="listbox" aria-label="Creatures"></ul>
      <label class="field"><span>Name</span><input name="name" maxlength="80" placeholder="Name (optional for a catalog creature)"></label>
      <label class="field"><span>Hit points (custom companion)</span><input name="hp" type="number" min="1" max="2000"></label>
      <label class="field span-2"><span>Where it comes from</span><input name="source" maxlength="120" placeholder="Find Familiar, Find Steed, animal companion…"></label>
      <p class="muted small span-2" data-comp-picked>No creature chosen: a custom companion needs a name and hit points.</p>
    </form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-comp-ok>Add companion</button>',
  });
  let picked = null;
  const list = $('[data-comp-list]', m.el);
  const draw = () => {
    const q = $('[data-comp-q]', m.el).value.trim().toLowerCase();
    const rows = q ? all.filter((c) => c.name.toLowerCase().includes(q)).slice(0, 40) : [];
    list.innerHTML = rows.map((c) => `<li><button type="button" class="cr-option" data-comp-option="${esc(c.id)}" aria-pressed="${picked === c.id}">
      <strong>${esc(c.name)}</strong> <span class="muted small">${esc(c.size)} ${esc(c.creature_type)} · CR ${cr(c.challenge_rating)} · HP ${c.hit_points}</span></button></li>`).join('');
  };
  m.el.addEventListener('input', (e) => { if (e.target.matches('[data-comp-q]')) draw(); });
  list.addEventListener('click', (e) => {
    const b = e.target.closest('[data-comp-option]');
    if (!b) return;
    picked = b.dataset.compOption;
    const c = all.find((x) => x.id === picked);
    $('[data-comp-picked]', m.el).textContent = `Chosen: ${c.name} (${c.hit_points} HP).`;
    draw();
  });
  $('[data-comp-ok]', m.el).addEventListener('click', async (e) => {
    const f = $('[data-comp-form]', m.el);
    e.target.disabled = true;
    try {
      await api.addCompanion(characterId, { creature: picked, name: f.elements.name.value.trim() || null, source: f.elements.source.value.trim() || null,
        hpMax: f.elements.hp.value ? Number(f.elements.hp.value) : null });
      toast('Companion added.', 'good');
      m.close();
      await onDone?.();
    } catch (err) { toast(err.message, 'bad'); e.target.disabled = false; }
  });
  setTimeout(() => $('[data-comp-q]', m.el)?.focus(), 50);
  return m;
}

export async function changeCompanionHp(el, list) {
  const c = (list || []).find((x) => x.id === el.dataset.id);
  if (!c) return null;
  const n = Math.max(1, Math.floor(Number(el.closest('[data-companion]')?.querySelector('[data-comp-amount]')?.value) || 1));
  return api.updateCompanion(c.id, { hp_current: c.hp_current + Number(el.dataset.sign) * n });
}

export async function removeCompanionConfirm(el, list) {
  const c = (list || []).find((x) => x.id === el.dataset.id);
  if (!c || !(await confirmDialog(`Remove ${c.name}?`, { title: 'Remove companion', okLabel: 'Remove', danger: true }))) return false;
  await api.removeCompanion(c.id);
  toast(`${c.name} removed.`, 'good');
  return true;
}
