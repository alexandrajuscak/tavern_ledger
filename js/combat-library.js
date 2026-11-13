// Combat Builder: Monster Library and homebrew creature editor (docs/COMBAT_HOMEBREW_CREATURES.md).
// The library lists SRD 5.2.1 (2024), SRD 5.1 (2014) and the campaign's published homebrew in light rows; a stat block is
// loaded only when previewed. Homebrew creatures use the existing DM content lifecycle (draft -> validate -> publish ->
// new version -> archive): the server validates (_dm_try + _combat_creature_errors) and materializes the catalog row.

import { $, $$, esc, toast, openModal, debounce } from './utils.js?v=28';
import * as api from './combat-api.js?v=28';
import * as dm from './dm-api.js?v=28';
import { icon } from './icons.js?v=28';
import { glyph } from './combat-icons.js?v=28';

const SIZES = ['Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Gargantuan'];
const TYPES = ['aberration', 'beast', 'celestial', 'construct', 'dragon', 'elemental', 'fey', 'fiend', 'giant', 'humanoid', 'monstrosity', 'ooze', 'plant', 'undead'];
const DMG = ['acid', 'bludgeoning', 'cold', 'fire', 'force', 'lightning', 'necrotic', 'piercing', 'poison', 'psychic', 'radiant', 'slashing', 'thunder'];
const ABIL = ['str', 'dex', 'con', 'int', 'wis', 'cha'];
const CRS = ['0', '0.125', '0.25', '0.5', ...Array.from({ length: 30 }, (_, i) => String(i + 1))];
export const crText = (v) => (v == null ? '—' : ({ 0.125: '1/8', 0.25: '1/4', 0.5: '1/2' }[Number(v)] || String(Number(v))));
const mod = (s) => Math.floor((Number(s || 10) - 10) / 2);
const signed = (n) => (n >= 0 ? `+${n}` : `−${Math.abs(n)}`);
const ATTRIBUTION = 'This work includes material from the System Reference Document 5.2.1 ("SRD 5.2.1") by Wizards of the Coast LLC, available at https://www.dndbeyond.com/srd. The SRD 5.2.1 is licensed under the Creative Commons Attribution 4.0 International License, available at https://creativecommons.org/licenses/by/4.0/legalcode.';

// =============================================================================================================== stat block
export function statblockHTML(s, { compact = false } = {}) {
  if (!s) return '<p class="muted">No stat block.</p>';
  const sec = (title, list, open = false) => (list?.length ? `<details class="cb-sb-sec" ${open || !compact ? 'open' : ''}><summary>${esc(title)}</summary>
    ${list.map((e) => `<p class="cb-sb-entry"><strong>${esc(e.name)}${e.usage?.type === 'recharge' ? ` (Recharge ${e.usage.min}–6)` : e.usage?.type === 'per_day' ? ` (${e.usage.times}/Day)` : ''}${e.cost > 1 ? ` (Costs ${e.cost} Actions)` : ''}.</strong>
      ${esc(e.text || e.summary || '')}${!e.text && !e.summary && e.attack_bonus != null ? ` ${signed(e.attack_bonus)} to hit` : ''}
      ${!e.text && e.damage?.length ? ` ${esc(e.damage.map((d) => `${d.dice || d.average} ${d.type || ''}`).join(' + '))}` : ''}</p>`).join('')}</details>` : '');
  const list = (label, arr) => (arr?.length ? `<p><strong>${label}</strong> ${esc(arr.join(', '))}</p>` : '');
  const sp = Object.entries(s.speed || {}).filter(([k, v]) => k !== 'hover' && v).map(([k, v]) => (k === 'walk' ? `${v} ft.` : `${k} ${v} ft.`)).join(', ');
  const senses = Object.entries(s.senses || {}).filter(([k]) => k !== 'passive_perception').map(([k, v]) => `${k} ${v} ft.`);
  const leg = s.legendary;
  const ini = s.initiative || {};
  return `<article class="cb-sb">
    <header class="cb-sb-head"><h3 class="cb-sb-name">${esc(s.name)}</h3>
      <p class="cb-sb-type"><em>${esc(s.size_text || s.size || '')} ${esc(s.creature_type || '')}${s.subtype ? ` (${esc(s.subtype)})` : ''}${s.alignment ? `, ${esc(s.alignment)}` : ''}</em></p></header>
    <div class="cb-sb-core">
      <span><strong>AC</strong> ${esc(s.armor_class)}${s.armor_type ? ` (${esc(s.armor_type)})` : ''}</span>
      <span><strong>HP</strong> ${esc(s.hit_points)}${s.hit_dice ? ` (${esc(s.hit_dice)})` : ''}</span>
      <span><strong>Speed</strong> ${esc(sp || '—')}</span>
      <span><strong>Initiative</strong> ${ini.modifier != null ? signed(ini.modifier) : signed(mod(s.abilities?.dex))}${ini.score != null ? ` (${ini.score})` : ''}</span>
    </div>
    <table class="cb-sb-abil"><caption class="sr-only">Ability scores, modifiers and saving throws</caption>
      <thead><tr>${ABIL.map((a) => `<th scope="col">${a.toUpperCase()}</th>`).join('')}</tr></thead>
      <tbody><tr>${ABIL.map((a) => `<td>${esc(s.abilities?.[a] ?? '—')}<span class="small"> ${signed(mod(s.abilities?.[a]))}</span>${s.saving_throws?.[a] != null ? `<span class="cb-sb-save"> save ${signed(Number(s.saving_throws[a]))}</span>` : ''}</td>`).join('')}</tr></tbody></table>
    <div class="cb-sb-props">
      ${Object.keys(s.skills || {}).length ? `<p><strong>Skills</strong> ${esc(Object.entries(s.skills).map(([k, v]) => `${k.replace(/_/g, ' ')} ${signed(Number(v))}`).join(', '))}</p>` : ''}
      ${list('Vulnerabilities', s.damage_vulnerabilities)}${list('Resistances', s.damage_resistances)}${list('Immunities', s.damage_immunities)}${list('Condition immunities', s.condition_immunities)}
      <p><strong>Senses</strong> ${esc([...senses, `Passive Perception ${s.senses?.passive_perception ?? 10 + mod(s.abilities?.wis)}`].join('; '))}</p>
      ${s.languages ? `<p><strong>Languages</strong> ${esc(s.languages)}</p>` : ''}
      <p><strong>CR</strong> ${esc(crText(s.challenge_rating))}${s.xp != null ? ` (XP ${Number(s.xp).toLocaleString()}${s.xp_in_lair ? `, or ${Number(s.xp_in_lair).toLocaleString()} in lair` : ''})` : ''}${s.proficiency_bonus ? `; PB ${signed(s.proficiency_bonus)}` : ''}</p>
      ${s.gear ? `<p><strong>Gear</strong> ${esc(s.gear)}</p>` : ''}
    </div>
    ${sec('Traits', s.traits)}${sec('Actions', s.actions, true)}${sec('Bonus Actions', s.bonus_actions)}${sec('Reactions', s.reactions)}
    ${leg ? `<details class="cb-sb-sec" ${compact ? '' : 'open'}><summary>Legendary Actions</summary><p class="small">Uses: ${esc(leg.uses ?? '—')}${leg.uses_in_lair ? ` (${esc(leg.uses_in_lair)} in lair)` : ''}; regained at the start of its turn; one after another creature's turn.</p>
      ${(leg.actions || []).map((e) => `<p class="cb-sb-entry"><strong>${esc(e.name)}${(e.cost || 1) > 1 ? ` (Costs ${e.cost})` : ''}.</strong> ${esc(e.text || e.summary || '')}</p>`).join('')}</details>` : ''}
    ${s.spellcasting && !(s.actions || []).some((a) => a.spellcasting) ? `<details class="cb-sb-sec"><summary>Spellcasting</summary><p>${esc(s.spellcasting.text || s.spellcasting.spells || '')}
      ${s.spellcasting.save_dc ? ` Spell save DC ${esc(s.spellcasting.save_dc)}.` : ''}${s.spellcasting.attack_bonus != null && s.spellcasting.attack_bonus !== '' ? ` ${signed(Number(s.spellcasting.attack_bonus))} to hit with spell attacks.` : ''}</p></details>` : ''}
    ${s.notes ? `<p class="small"><strong>Notes</strong> ${esc(s.notes)}</p>` : ''}
    <footer class="cb-sb-src small muted">${esc(s.source_label || '')}${s.license ? ` · ${esc(s.license)}` : ''}${s.homebrew ? ' · homebrew' : ''}${s.mechanics_status === 'partial' ? ' · some details summarized' : ''}
      ${s.source_label === 'SRD 5.2.1' ? `<span class="cb-attrib">${esc(ATTRIBUTION)}</span>` : ''}</footer>
  </article>`;
}

// =============================================================================================================== browser
function browserHTML(withAdd) {
  return `<div class="cb-lib">
    <div class="cb-lib-filters">
      <label class="field cb-lib-q"><span>Search</span><input type="search" data-q placeholder="Goblin, dragon, undead…" autocomplete="off" data-focus-key="lib-q"></label>
      <label class="field"><span>CR from</span><select data-f="cr_min"><option value="">Any</option>${CRS.map((c) => `<option value="${c}">${crText(c)}</option>`).join('')}</select></label>
      <label class="field"><span>to</span><select data-f="cr_max"><option value="">Any</option>${CRS.map((c) => `<option value="${c}">${crText(c)}</option>`).join('')}</select></label>
      <label class="field"><span>Type</span><select data-f="type"><option value="">Any</option>${TYPES.map((t) => `<option>${t}</option>`).join('')}</select></label>
      <label class="field"><span>Size</span><select data-f="size"><option value="">Any</option>${SIZES.map((t) => `<option>${t}</option>`).join('')}</select></label>
      <label class="field"><span>Source</span><select data-f="source"><option value="">All</option><option value="srd2024">SRD 5.2.1</option><option value="srd2014">SRD 5.1</option><option value="homebrew">Campaign homebrew</option></select></label>
      <label class="field"><span>Rules</span><select data-f="rules"><option value="">Both</option><option value="2024">2024</option><option value="2014">2014</option></select></label>
      <label class="cb-toggle small"><input type="checkbox" data-f="favorites"> Favorites</label>
      <label class="cb-toggle small"><input type="checkbox" data-f="legendary"> Legendary</label>
    </div>
    <div class="cb-lib-recent" data-recent></div>
    <div class="cb-lib-body">
      <div class="cb-lib-results"><p class="small muted" data-count role="status"></p><ul class="cb-lib-list" data-list></ul>
        <button type="button" class="btn btn-sm btn-ghost" data-more hidden>Show more</button></div>
      <div class="cb-lib-preview" data-preview aria-live="polite"><p class="muted">Choose a creature to see its stat block${withAdd ? ' and add it' : ''}.</p></div>
    </div>
    <p class="cb-attrib small muted">${esc(ATTRIBUTION)} SRD 5.1 creatures: System Reference Document 5.1 by Wizards of the Coast LLC (CC-BY-4.0).</p>
  </div>`;
}

function attachBrowser(host, { campaignId, encounter = null, onAdded = null, onNew = null }) {
  let offset = 0;
  let items = [];
  let picked = null;
  const filters = () => {
    const f = {};
    $$('[data-f]', host).forEach((el) => {
      const v = el.type === 'checkbox' ? el.checked : el.value;
      if (v && v !== '') f[el.dataset.f] = el.type === 'checkbox' ? true : (['cr_min', 'cr_max'].includes(el.dataset.f) ? Number(v) : v);
    });
    return f;
  };
  const row = (x) => `<li><button type="button" class="cb-lib-item${picked?.ref === x.ref ? ' on' : ''}" data-ref="${esc(x.ref)}" aria-pressed="${picked?.ref === x.ref}">
      <span class="cb-lib-name"><strong>${esc(x.name)}</strong> <span class="small muted">${esc(x.size)} ${esc(x.creature_type)}</span></span>
      <span class="cb-lib-meta"><span class="cb-cr">CR ${esc(crText(x.cr))}</span> <span class="small">AC ${x.ac} · HP ${x.hp}</span>
        <span class="cb-rules cb-rules-${esc(x.rules || 'x')}">${esc(x.homebrew ? 'Homebrew' : x.rules)}</span>${x.legendary ? glyph('crown', { size: 13, label: 'Legendary' }) : ''}</span></button>
      <button type="button" class="icon-btn cb-fav${x.favorite ? ' on' : ''}" data-fav="${esc(x.ref)}" aria-pressed="${x.favorite}" aria-label="${x.favorite ? 'Remove from' : 'Add to'} favorites: ${esc(x.name)}">${x.favorite ? '★' : '☆'}</button></li>`;
  const load = async (append = false) => {
    if (!append) offset = 0;
    $('[data-count]', host).textContent = 'Searching…';
    try {
      const r = await api.monsterLibrary(campaignId, $('[data-q]', host).value.trim(), filters(), 60, offset);
      items = append ? [...items, ...r.items] : r.items;
      $('[data-list]', host).innerHTML = items.map(row).join('') || '<li class="muted small">No creature matches. Try fewer filters, or create a homebrew creature.</li>';
      $('[data-count]', host).textContent = `${r.total} creature${r.total === 1 ? '' : 's'}`;
      $('[data-more]', host).hidden = items.length >= r.total;
    } catch (err) { $('[data-count]', host).textContent = err.message; }
  };
  const preview = async (ref) => {
    picked = items.find((x) => x.ref === ref) || { ref };
    $$('.cb-lib-item', host).forEach((b) => { const on = b.dataset.ref === ref; b.classList.toggle('on', on); b.setAttribute('aria-pressed', String(on)); });
    const pv = $('[data-preview]', host);
    pv.innerHTML = '<div class="spinner-inline" role="status" aria-label="Loading"></div>';
    try {
      const s = await api.monsterDetail(ref, campaignId);
      picked.statblock = s;
      const mismatch = encounter && s.rules_version && s.rules_version !== encounter.ruleset;
      const lairUses = s.legendary?.uses_in_lair;
      pv.innerHTML = `${encounter ? `<form class="cb-add-form" data-add>
          ${mismatch ? `<p class="cb-warn small">This stat block uses the ${esc(s.rules_version)} rules; the encounter uses ${esc(encounter.ruleset)}. It is added with a badge (never mixed silently).</p>` : ''}
          <div class="form-grid">
            <label class="field"><span>How many</span><input name="qty" type="number" min="1" max="30" value="1"></label>
            <label class="field"><span>Initiative</span><select name="group"><option value="shared">One roll for the group</option><option value="separate">Each rolls</option></select></label>
            <label class="field"><span>Hit points</span><select name="hp"><option value="average" ${encounter.settings?.hp_mode !== 'rolled' ? 'selected' : ''}>Average (${esc(s.hit_points)})</option><option value="rolled" ${encounter.settings?.hp_mode === 'rolled' ? 'selected' : ''}>Rolled (${esc(s.hit_dice || '—')})</option></select></label>
            <label class="field"><span>Name (optional)</span><input name="name" maxlength="100" placeholder="${esc(s.name)}"></label>
            <label class="field"><span>Joins in round (optional)</span><input name="joins" type="number" min="1"></label>
            ${['active', 'paused'].includes(encounter.status) ? '<label class="field"><span>Initiative (empty = roll)</span><input name="init" type="number" min="-20" max="60"></label>' : ''}
            <label class="cb-toggle"><input type="checkbox" name="hidden"> Hidden from players</label>
            ${lairUses ? `<label class="cb-toggle"><input type="checkbox" name="lair"> In its lair (${esc(lairUses)} Legendary uses)</label>` : ''}
          </div>
          <button type="submit" class="btn btn-gold" data-busy-key="add">${glyph('plus', { size: 14 })} Add to encounter</button></form>` : ''}
        ${statblockHTML(s)}
        ${picked.homebrew && picked.content_id ? `<button type="button" class="btn btn-sm btn-ghost" data-edit="${esc(picked.content_id)}">Edit (new version)</button>` : ''}`;
      $('[data-add]', pv)?.addEventListener('submit', async (ev) => {
        ev.preventDefault();
        const f = ev.currentTarget;
        const btn = $('button[type=submit]', f);
        if (btn.disabled) return;
        btn.disabled = true;
        const qty = Math.max(1, Math.min(30, Number(f.qty.value) || 1));
        try {
          const kind = ref.startsWith('srd52:') ? 'srd2024' : picked.homebrew ? 'homebrew' : 'creature';
          const sid = ref.slice(ref.indexOf(':') + 1);
          const r = await api.addMonsters(encounter.id, kind, sid, { quantity: qty, group: f.group.value, hp_mode: f.hp.value, name: f.name.value || null,
            hidden: f.hidden.checked, joins_round: f.joins.value ? Number(f.joins.value) : null, in_lair: !!f.lair?.checked,
            initiative: f.init && f.init.value !== '' ? Number(f.init.value) : null });
          toast(`Added ${qty} × ${f.name.value || s.name}.`, 'good');
          await onAdded?.(r);
        } catch (err) { toast(err.message, 'bad'); }
        btn.disabled = false;
      });
      $('[data-edit]', pv)?.addEventListener('click', () => openCreatureEditor({ campaignId, contentId: picked.content_id, onDone: () => load() }));
    } catch (err) { pv.innerHTML = `<p class="cb-error" role="alert">${esc(err.message)}</p>`; }
  };
  const recent = async () => {
    try {
      const r = await api.recentMonsters(campaignId);
      $('[data-recent]', host).innerHTML = r.length ? `<span class="small muted">Recent:</span> ${r.map((x) => `<button type="button" class="btn btn-sm btn-ghost" data-recent-ref="${esc(x.ref)}">${esc(x.name)}</button>`).join(' ')}` : '';
    } catch { /* optional */ }
  };
  const debounced = debounce(() => load(), 220);
  host.addEventListener('input', (ev) => { if (ev.target.matches('[data-q]')) debounced(); });
  host.addEventListener('change', (ev) => { if (ev.target.matches('[data-f]')) load(); });
  host.addEventListener('click', async (ev) => {
    const it = ev.target.closest('[data-ref]');
    if (it) return preview(it.dataset.ref);
    const rr = ev.target.closest('[data-recent-ref]');
    if (rr) { if (!items.some((x) => x.ref === rr.dataset.recentRef)) items.push({ ref: rr.dataset.recentRef }); return preview(rr.dataset.recentRef); }
    const fav = ev.target.closest('[data-fav]');
    if (fav) {
      const on = fav.getAttribute('aria-pressed') !== 'true';
      try { await api.toggleFavorite(fav.dataset.fav, on); const x = items.find((y) => y.ref === fav.dataset.fav); if (x) x.favorite = on; fav.outerHTML = row(x).match(/<button type="button" class="icon-btn cb-fav[\s\S]*?<\/button>/)[0]; } catch (err) { toast(err.message, 'bad'); }
      return undefined;
    }
    if (ev.target.closest('[data-more]')) { offset += 60; return load(true); }
    if (ev.target.closest('[data-new-creature]')) return onNew?.();
    return undefined;
  });
  load();
  recent();
  return { reload: load };
}

/** The library as a dialog from an encounter: add several copies, then keep browsing. */
export function openMonsterLibrary({ encounter, onAdded }) {
  const m = openModal({
    title: 'Monster Library',
    wide: true,
    body: browserHTML(true),
    footer: '<button type="button" class="btn btn-ghost" data-new-creature>+ New homebrew creature</button><button type="button" class="btn" data-close>Done</button>',
  });
  m.el.querySelector('.modal').classList.add('cb-lib-modal');
  const b = attachBrowser(m.body, { campaignId: encounter.campaign_id, encounter, onAdded });
  $('[data-new-creature]', m.el).addEventListener('click', () => openCreatureEditor({ campaignId: encounter.campaign_id, onDone: () => b.reload() }));
}

/** #/combat/library: browse, preview and create homebrew without an encounter. */
export async function mountLibraryPage(root, { campaignId }) {
  let camps = [];
  try { camps = (await api.listEncounters(null, false)).campaigns || []; } catch (err) { root.innerHTML = `<p class="cb-error" role="alert">${esc(err.message)}</p>`; return; }
  if (!camps.length) { root.innerHTML = '<div class="empty-state"><h1 class="cb-title">Monster Library</h1><p>You are not the DM of a campaign yet.</p></div>'; return; }
  let camp = camps.some((c) => c.id === campaignId) ? campaignId : camps[0].id;
  const draw = () => {
    root.innerHTML = `<header class="cb-head"><div><span class="cb-kicker">${glyph('swords', { size: 14 })} <a href="#/combat">Combat Builder</a></span><h1 class="cb-title">Monster Library</h1></div>
      <div class="cb-head-actions"><label class="field cb-camp"><span>Campaign (homebrew)</span><select data-lib-camp>${camps.map((c) => `<option value="${esc(c.id)}" ${c.id === camp ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></label>
      <button type="button" class="btn btn-gold" data-new-creature>${icon('dm.creature', { size: 18 })} New homebrew creature</button></div></header>${browserHTML(false)}`;
    const b = attachBrowser(root, { campaignId: camp, onNew: () => openCreatureEditor({ campaignId: camp, onDone: () => b.reload() }) });
    $('[data-lib-camp]', root).addEventListener('change', (ev) => { camp = ev.target.value; try { localStorage.setItem('tavern-ledger:combat-campaign', camp); } catch { /* optional */ } draw(); });
  };
  draw();
}

// =============================================================================================================== editor
const blankAction = (kind = 'melee') => ({ name: '', kind, attack_bonus: '', reach: 5, range: '', damage: [{ dice: '', type: '' }], save: { ability: '', dc: '' }, recharge: { enabled: false, min: '' }, summary: '' });

function defaults() {
  return { name: '', summary: '', dm_notes: '', ruleset: '2024',
    d: { combat: { mode: 'quick' }, size: 'Medium', creature_type: 'humanoid', challenge_rating: 0.25, xp: '', armor_class: 12, armor_type: '', hit_points: 11, hit_dice: '',
      speed: { walk: 30 }, abilities: { str: 10, dex: 12, con: 10, int: 10, wis: 10, cha: 10 }, initiative_bonus: '', saving_throws: {}, skills: {},
      senses: { darkvision: '', passive_perception: '' }, languages: '', damage_resistances: [], damage_immunities: [], damage_vulnerabilities: [], condition_immunities: [],
      traits: [], actions: [blankAction()], bonus_actions: [], reactions: [], legendary: { enabled: false, uses: 3, actions: [] },
      spellcasting: { enabled: false, ability: 'int', save_dc: '', attack_bonus: '', spells: '' }, wild_shape_eligible: false, companion_eligible: false } };
}

/** Quick (name, HP, AC, Initiative, Speed, one attack) or Advanced (full stat block). Only relevant fields are shown. */
export async function openCreatureEditor({ campaignId, contentId = null, onDone = null }) {
  let model = defaults();
  let content = null;
  if (contentId) {
    try {
      content = await dm.getContent(contentId);
      if (content.status === 'published' || content.status === 'archived') content = await dm.newContentVersion(contentId);
      const v = content.versions.find((x) => x.id === content.current_version_id) || content.versions[0];
      model = { name: v.name, summary: v.summary || '', dm_notes: v.dm_notes || '', ruleset: v.ruleset || '2024', d: { ...defaults().d, ...structuredClone(v.definition || {}) } };
      model.d.combat ||= { mode: 'advanced' };
    } catch (err) { toast(err.message, 'bad'); return; }
  }
  const m = openModal({ title: contentId ? 'Edit homebrew creature' : 'New homebrew creature', wide: true, body: '<div data-ed></div>',
    footer: `<span class="cb-ed-status small" data-status role="status"></span><button type="button" class="btn" data-close>Close</button>
      <button type="button" class="btn" data-save>Save draft</button><button type="button" class="btn" data-validate>Check</button><button type="button" class="btn btn-gold" data-publish>Publish</button>` });
  m.el.querySelector('.modal').classList.add('cb-ed-modal');
  const host = $('[data-ed]', m.el);
  const d = () => model.d;
  const quick = () => d().combat?.mode === 'quick';
  const num = (path, label, attrs = '') => `<label class="field"><span>${label}</span><input type="number" data-p="${path}" value="${esc(get(path) ?? '')}" ${attrs}></label>`;
  const txt = (path, label, attrs = '') => `<label class="field"><span>${label}</span><input data-p="${path}" value="${esc(get(path) ?? '')}" ${attrs}></label>`;
  const sel = (path, label, opts) => `<label class="field"><span>${label}</span><select data-p="${path}">${opts.map(([v, l]) => `<option value="${esc(v)}" ${String(get(path) ?? '') === String(v) ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>`;
  function get(path) { return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), model); }
  function set(path, v) {
    const ks = path.split('.');
    let o = model;
    for (let i = 0; i < ks.length - 1; i += 1) o = (o[ks[i]] ??= /^\d+$/.test(ks[i + 1]) ? [] : {});   // an index next: an array
    o[ks[ks.length - 1]] = v;
  }
  const actionRow = (sect, a, i) => {
    const p = `d.${sect}.${i}`;
    const k = a.kind || 'other';
    return `<fieldset class="cb-ed-row"><legend class="sr-only">${esc(sect)} ${i + 1}</legend>
      ${txt(`${p}.name`, 'Name', 'maxlength="80" required')}
      ${sel(`${p}.kind`, 'Kind', [['melee', 'Melee attack'], ['ranged', 'Ranged attack'], ['save', 'Saving throw effect'], ['other', 'Other / text only']])}
      ${k === 'melee' || k === 'ranged' ? num(`${p}.attack_bonus`, 'To hit', 'min="-5" max="30"') : ''}
      ${k === 'melee' ? num(`${p}.reach`, 'Reach (ft)', 'min="0" max="120"') : ''}
      ${k === 'ranged' ? txt(`${p}.range`, 'Range (ft, e.g. 80/320)', 'maxlength="20"') : ''}
      ${k === 'save' ? sel(`${p}.save.ability`, 'Save', [['', '—'], ...ABIL.map((x) => [x, x.toUpperCase()])]) + num(`${p}.save.dc`, 'DC', 'min="1" max="40"') : ''}
      ${k !== 'other' ? txt(`${p}.damage.0.dice`, 'Damage (e.g. 1d6+2)', 'maxlength="30"') + sel(`${p}.damage.0.type`, 'Damage type', [['', '—'], ...DMG.map((x) => [x, x])]) : ''}
      ${k === 'melee' || k === 'ranged' ? `<label class="cb-toggle small"><input type="checkbox" data-p="${p}.no_damage" ${a.no_damage ? 'checked' : ''}> No damage</label>` : ''}
      ${!quick() ? `<label class="cb-toggle small"><input type="checkbox" data-p="${p}.recharge.enabled" ${a.recharge?.enabled ? 'checked' : ''}> Recharge</label>
        ${a.recharge?.enabled ? sel(`${p}.recharge.min`, 'Recharges on', [['', '—'], ...['2', '3', '4', '5', '6'].map((x) => [x, `${x}–6`])]) : ''}` : ''}
      <label class="field cb-ed-wide"><span>What it does</span><input data-p="${p}.summary" value="${esc(a.summary || '')}" maxlength="500"></label>
      ${!quick() || i > 0 ? `<button type="button" class="btn btn-sm btn-ghost" data-del="${sect}:${i}" aria-label="Remove ${esc(a.name || 'entry')}">Remove</button>` : ''}</fieldset>`;
  };
  const listRows = (sect, title, withKind = true) => `<section class="cb-ed-sec"><h3 class="cb-dsec-title">${title}</h3>
    ${(d()[sect] || []).map((a, i) => (withKind ? actionRow(sect, a, i) : `<fieldset class="cb-ed-row">${txt(`d.${sect}.${i}.name`, 'Name', 'maxlength="80"')}
      <label class="field cb-ed-wide"><span>What it does</span><input data-p="d.${sect}.${i}.summary" value="${esc(a.summary || '')}" maxlength="500"></label>
      <button type="button" class="btn btn-sm btn-ghost" data-del="${sect}:${i}">Remove</button></fieldset>`)).join('')}
    <button type="button" class="btn btn-sm" data-addrow="${sect}">+ ${title.replace(/s$/, '')}</button></section>`;
  const draw = () => {
    const key = document.activeElement?.dataset?.p;
    host.innerHTML = `
      <div class="cb-tabs dm-tabs" role="tablist"><button type="button" class="tab" role="tab" data-mode="quick" aria-selected="${quick()}">Quick creature</button>
        <button type="button" class="tab" role="tab" data-mode="advanced" aria-selected="${!quick()}">Full stat block</button></div>
      <p class="small muted">${quick() ? 'The essentials for a simple enemy. Other ability scores are 10 (you can change them in the full stat block).' : 'Every field is optional unless it is switched on. Hidden sections never block saving.'}</p>
      <div class="cb-ed-errors" data-errors role="alert" hidden></div>
      <section class="cb-ed-sec"><h3 class="cb-dsec-title">Identity</h3><div class="form-grid">
        ${txt('name', 'Name', 'maxlength="80" required')}
        ${sel('d.size', 'Size', SIZES.map((x) => [x, x]))}${sel('d.creature_type', 'Type', TYPES.map((x) => [x, x]))}
        ${sel('ruleset', 'Rules', [['2024', '2024'], ['2014', '2014']])}
        ${sel('d.challenge_rating', 'Challenge rating', CRS.map((c) => [c, crText(c)]))}${num('d.xp', 'XP (for difficulty)', 'min="0"')}
        ${!quick() ? txt('d.alignment', 'Alignment', 'maxlength="40"') : ''}</div></section>
      <section class="cb-ed-sec"><h3 class="cb-dsec-title">Combat</h3><div class="form-grid">
        ${num('d.hit_points', 'Hit points', 'min="1" max="2000" required')}${txt('d.hit_dice', 'Hit dice (e.g. 3d8+3)', 'maxlength="20"')}
        ${num('d.armor_class', 'Armor Class', 'min="0" max="40" required')}${!quick() ? txt('d.armor_type', 'Armor (text)', 'maxlength="40"') : ''}
        ${num('d.speed.walk', 'Speed (ft)', 'min="0" max="300"')}${!quick() ? ['fly', 'swim', 'climb', 'burrow'].map((k) => num(`d.speed.${k}`, `${k[0].toUpperCase()}${k.slice(1)} (ft)`, 'min="0" max="300"')).join('') : ''}
        ${num('d.abilities.dex', 'Dexterity', 'min="1" max="30"')}${num('d.initiative_bonus', 'Initiative modifier (empty = DEX)', 'min="-10" max="20"')}</div></section>
      ${!quick() ? `<section class="cb-ed-sec"><h3 class="cb-dsec-title">Abilities and saves</h3><div class="form-grid cb-ed-abil">
        ${ABIL.filter((a) => a !== 'dex').map((a) => num(`d.abilities.${a}`, a.toUpperCase(), 'min="1" max="30"')).join('')}
        ${ABIL.map((a) => num(`d.saving_throws.${a}`, `${a.toUpperCase()} save (if proficient)`, 'min="-10" max="30"')).join('')}</div>
        <div class="form-grid">${txt('skills_text', 'Skills (e.g. perception:4, stealth:6)', 'maxlength="300"')}${num('d.senses.darkvision', 'Darkvision (ft)', 'min="0"')}
        ${num('d.senses.passive_perception', 'Passive Perception', 'min="0" max="40"')}${txt('d.languages', 'Languages', 'maxlength="200"')}
        ${txt('res_text', 'Resistances (comma separated)', 'maxlength="200"')}${txt('imm_text', 'Damage immunities', 'maxlength="200"')}
        ${txt('vul_text', 'Vulnerabilities', 'maxlength="200"')}${txt('ci_text', 'Condition immunities', 'maxlength="200"')}</div></section>` : ''}
      ${quick() ? `<section class="cb-ed-sec"><h3 class="cb-dsec-title">Basic attack</h3>${actionRow('actions', d().actions[0] || blankAction(), 0)}</section>` : `
        ${listRows('traits', 'Traits', false)}${listRows('actions', 'Actions')}${listRows('bonus_actions', 'Bonus Actions')}${listRows('reactions', 'Reactions')}
        <section class="cb-ed-sec"><h3 class="cb-dsec-title"><label class="cb-toggle"><input type="checkbox" data-p="d.legendary.enabled" ${d().legendary?.enabled ? 'checked' : ''}> Legendary Actions</label></h3>
          ${d().legendary?.enabled ? `<div class="form-grid">${num('d.legendary.uses', 'Uses per round', 'min="1" max="5"')}</div>
            ${(d().legendary.actions || []).map((a, i) => `<fieldset class="cb-ed-row">${txt(`d.legendary.actions.${i}.name`, 'Option', 'maxlength="80"')}${num(`d.legendary.actions.${i}.cost`, 'Cost', 'min="1" max="3"')}
              <label class="field cb-ed-wide"><span>What it does</span><input data-p="d.legendary.actions.${i}.summary" value="${esc(a.summary || '')}" maxlength="500"></label>
              <button type="button" class="btn btn-sm btn-ghost" data-del="legendary.actions:${i}">Remove</button></fieldset>`).join('')}
            <button type="button" class="btn btn-sm" data-addrow="legendary.actions">+ Legendary option</button>` : ''}</section>
        <section class="cb-ed-sec"><h3 class="cb-dsec-title"><label class="cb-toggle"><input type="checkbox" data-p="d.spellcasting.enabled" ${d().spellcasting?.enabled ? 'checked' : ''}> Spellcasting</label></h3>
          ${d().spellcasting?.enabled ? `<div class="form-grid">${sel('d.spellcasting.ability', 'Ability', [['int', 'Intelligence'], ['wis', 'Wisdom'], ['cha', 'Charisma']])}
            ${num('d.spellcasting.save_dc', 'Spell save DC', 'min="1" max="40"')}${num('d.spellcasting.attack_bonus', 'Spell attack bonus', 'min="-5" max="30"')}
            <label class="field span-2"><span>Spells (e.g. At will: Light; 1/day: Sleep)</span><textarea data-p="d.spellcasting.spells" rows="2" maxlength="1000">${esc(d().spellcasting.spells || '')}</textarea></label></div>` : ''}</section>`}
      <section class="cb-ed-sec"><h3 class="cb-dsec-title">Notes</h3><div class="form-grid">
        ${txt('summary', 'Short summary', 'maxlength="400"')}<label class="field span-2"><span>DM notes (never shown to players)</span><textarea data-p="dm_notes" rows="2" maxlength="4000">${esc(model.dm_notes || '')}</textarea></label></div></section>
      <section class="cb-ed-sec"><h3 class="cb-dsec-title">Preview</h3><div data-pv>${statblockHTML(previewStatblock())}</div></section>`;
    if (key) $(`[data-p="${CSS.escape(key)}"]`, host)?.focus();
  };
  // free-text list fields <-> arrays
  const textOf = (arr) => (arr || []).join(', ');
  model.skills_text = Object.entries(d().skills || {}).map(([k, v]) => `${k}:${v}`).join(', ');
  model.res_text = textOf(d().damage_resistances); model.imm_text = textOf(d().damage_immunities);
  model.vul_text = textOf(d().damage_vulnerabilities); model.ci_text = textOf(d().condition_immunities);
  function definition() {
    const x = structuredClone(d());
    const n = (v) => (v === '' || v == null ? null : Number(v));
    x.armor_class = n(x.armor_class); x.hit_points = n(x.hit_points); x.xp = n(x.xp); x.challenge_rating = Number(x.challenge_rating) || 0;
    x.initiative_bonus = n(x.initiative_bonus);
    if (x.initiative_bonus == null) delete x.initiative_bonus;
    for (const a of ABIL) x.abilities[a] = n(x.abilities[a]) ?? 10;
    x.speed = Object.fromEntries(Object.entries(x.speed || {}).filter(([, v]) => v !== '' && v != null).map(([k, v]) => [k, Number(v)]));
    x.saving_throws = Object.fromEntries(Object.entries(x.saving_throws || {}).filter(([, v]) => v !== '' && v != null).map(([k, v]) => [k, Number(v)]));
    x.senses = Object.fromEntries(Object.entries(x.senses || {}).filter(([, v]) => v !== '' && v != null).map(([k, v]) => [k, Number(v)]));
    const list = (s) => String(s || '').split(',').map((y) => y.trim().toLowerCase()).filter(Boolean);
    x.skills = Object.fromEntries(list(model.skills_text).map((y) => y.split(':')).filter(([k, v]) => k && v !== undefined).map(([k, v]) => [k.trim().replace(/\s+/g, '_'), Number(v)]));
    x.damage_resistances = list(model.res_text); x.damage_immunities = list(model.imm_text); x.damage_vulnerabilities = list(model.vul_text); x.condition_immunities = list(model.ci_text);
    const clean = (a) => {
      const k = a.kind || 'other';
      const o = { name: (a.name || '').trim(), kind: k, summary: a.summary || '' };
      if (k === 'melee' || k === 'ranged') { o.attack_bonus = n(a.attack_bonus); if (a.no_damage) o.no_damage = true; }
      if (k === 'melee') o.reach = n(a.reach) ?? 5;
      if (k === 'ranged') o.range = a.range || null;
      if (k === 'save') o.save = { ability: a.save?.ability || '', dc: n(a.save?.dc) };
      if (k !== 'other' && a.damage?.[0]?.dice) o.damage = [{ dice: a.damage[0].dice.replace(/\s+/g, ''), type: a.damage[0].type || null }];
      if (a.recharge?.enabled) { o.recharge = { enabled: true, min: n(a.recharge.min) }; o.usage = { type: 'recharge', min: n(a.recharge.min) }; }
      return o;
    };
    x.actions = (x.actions || []).map(clean); x.bonus_actions = (x.bonus_actions || []).map(clean); x.reactions = (x.reactions || []).map(clean);
    x.traits = (x.traits || []).filter((t) => t.name).map((t) => ({ name: t.name, summary: t.summary || '' }));
    if (!x.legendary?.enabled) x.legendary = { enabled: false };
    else x.legendary = { enabled: true, uses: n(x.legendary.uses), actions: (x.legendary.actions || []).map((a) => ({ name: a.name, cost: n(a.cost) ?? 1, summary: a.summary || '' })) };
    if (!x.spellcasting?.enabled) x.spellcasting = { enabled: false };
    if (x.spellcasting.enabled) { x.spellcasting.save_dc = n(x.spellcasting.save_dc); x.spellcasting.attack_bonus = n(x.spellcasting.attack_bonus); }
    x.wild_shape_eligible = false;
    return x;
  }
  function previewStatblock() {
    const x = definition();
    return { ...x, name: model.name || 'Unnamed creature', initiative: { modifier: x.initiative_bonus ?? mod(x.abilities.dex) }, homebrew: true, source_label: 'Campaign custom',
      bonus_actions: x.bonus_actions, legendary: x.legendary.enabled ? x.legendary : null, spellcasting: x.spellcasting.enabled ? { ...x.spellcasting, text: x.spellcasting.spells } : null,
      actions: x.actions.map((a) => ({ ...a, text: [a.attack_bonus != null ? `${a.kind === 'ranged' ? 'Ranged' : 'Melee'} attack ${signed(a.attack_bonus)}` : '', a.save ? `${a.save.ability?.toUpperCase()} save DC ${a.save.dc ?? '?'}` : '',
        a.damage ? `${a.damage[0].dice} ${a.damage[0].type || ''} damage` : '', a.summary].filter(Boolean).join('. ') })) };
  }
  const fields = () => ({ name: model.name, summary: model.summary, dm_notes: model.dm_notes, ruleset: model.ruleset, definition: definition() });
  const status = (t) => { $('[data-status]', m.el).textContent = t; };
  const showErrors = (v) => {
    const el = $('[data-errors]', host);
    const errs = v?.errors || [];
    el.hidden = !errs.length && !(v?.warnings || []).length;
    el.innerHTML = errs.length ? `<p><strong>Fix before publishing:</strong></p><ul>${errs.map((e) => `<li>${esc(e)}</li>`).join('')}</ul>` : (v?.warnings || []).map((w) => `<p class="small">${esc(w)}</p>`).join('');
  };
  const save = async () => {
    if (!model.name.trim()) { status('Give it a name first.'); $('[data-p="name"]', host)?.focus(); return null; }
    try {
      if (!content) content = await dm.createContent('creature', campaignId, fields());
      else {
        const v = content.versions.find((x) => x.id === content.current_version_id);
        content = await dm.saveContent(content.id, fields(), v?.revision ?? null);
      }
      status('Draft saved.');
      return content;
    } catch (err) { status(''); toast(err.message, 'bad'); return null; }
  };
  host.addEventListener('input', (ev) => {
    const p = ev.target.dataset.p;
    if (!p) return;
    set(p, ev.target.type === 'checkbox' ? ev.target.checked : ev.target.value);
    $('[data-pv]', host).innerHTML = statblockHTML(previewStatblock());
  });
  host.addEventListener('change', (ev) => {
    const p = ev.target.dataset.p;
    if (!p) return;
    set(p, ev.target.type === 'checkbox' ? ev.target.checked : ev.target.value);
    if (/\.kind$|enabled$/.test(p)) draw();   // show only the fields that now matter
  });
  host.addEventListener('click', (ev) => {
    const t = ev.target.closest('[data-mode], [data-addrow], [data-del]');
    if (!t) return;
    if (t.dataset.mode) { d().combat = { mode: t.dataset.mode }; if (!d().actions.length) d().actions.push(blankAction()); }
    if (t.dataset.addrow) {
      const path = t.dataset.addrow.split('.');
      const arr = path.reduce((o, k) => o[k], d());
      arr.push(t.dataset.addrow === 'traits' ? { name: '', summary: '' } : t.dataset.addrow === 'legendary.actions' ? { name: '', cost: 1, summary: '' } : blankAction(t.dataset.addrow === 'actions' ? 'melee' : 'other'));
    }
    if (t.dataset.del) { const [sect, i] = t.dataset.del.split(':'); sect.split('.').reduce((o, k) => o[k], d()).splice(Number(i), 1); }
    draw();
  });
  $('[data-save]', m.el).addEventListener('click', save);
  $('[data-validate]', m.el).addEventListener('click', async () => {
    const c = await save();
    if (!c) return;
    try { const r = await dm.validateContent(c.id); content = r; showErrors(r.validation); status(r.validation?.ok ? 'Ready to publish.' : 'Needs fixes.'); } catch (err) { toast(err.message, 'bad'); }
  });
  $('[data-publish]', m.el).addEventListener('click', async (ev) => {
    const btn = ev.currentTarget;
    if (btn.disabled) return;
    btn.disabled = true;
    const c = await save();
    if (!c) { btn.disabled = false; return; }
    try {
      const v = await dm.validateContent(c.id);
      showErrors(v.validation);
      if (!v.validation?.ok) { status('Needs fixes.'); btn.disabled = false; return; }
      content = await dm.publishContent(c.id, v.current_version_id);
      toast(`${model.name} published to the campaign library.`, 'good');
      m.close();
      onDone?.(content);
    } catch (err) { toast(err.message, 'bad'); btn.disabled = false; }
  });
  draw();
}
