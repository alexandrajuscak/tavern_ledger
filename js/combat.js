// Combat Builder (docs/COMBAT_BUILDER_ARCHITECTURE.md): the DM's encounter workspace beside DM Space.
// Combat Home (#/combat) · Encounter builder / live tracker / summary (#/combat/e/<id>) · Monster Library (#/combat/library).
// Every rule runs in the database (combat_* RPCs); this module renders, sends one mutation at a time per control, and patches
// the view from the mutation's answer. One Realtime channel per open encounter (combat-api.js subscribeEncounter).

import { supabase } from './supabase.js?v=29';
import { $, $$, esc, toast, openModal, confirmDialog, debounce, focusByKey } from './utils.js?v=29';
import * as api from './combat-api.js?v=29';
import { icon, conditionIcon } from './icons.js?v=29';
import { glyph } from './combat-icons.js?v=29';
import { openMonsterLibrary, mountLibraryPage, openCreatureEditor, statblockHTML, crText } from './combat-library.js?v=29';
import { COMBAT_BUILDER } from './config.js?v=29';
import { compactActiveFeaturesHTML, loadPlayTiming } from './active-features.js?v=29';
import { onUserCachesCleared } from './read-layer.js?v=29';

/** Is the Combat Builder switched on for this browser (the server checks the DM role again on every call)? */
export const combatEnabled = () => (COMBAT_BUILDER || 'off') !== 'off';

const STATUS = { draft: 'Prepared', active: 'In combat', paused: 'Paused', completed: 'Finished' };
const HP_TEXT = { healthy: 'Healthy', bloodied: 'Bloodied', critical: 'Critical', down: 'Down', defeated: 'Defeated' };
const SCOPES = [['next_attack', 'Next attack'], ['attacks_turn', 'Attacks this turn'], ['attacks', 'All attacks'], ['melee_attacks', 'Melee attacks'],
  ['ranged_attacks', 'Ranged attacks'], ['attacks_against_target', 'Attacks against one target'], ['incoming_attacks', 'Attacks against it'],
  ['saves', 'Saving throws'], ['save', 'One saving throw'], ['checks', 'Ability checks'], ['skill', 'One skill or check'], ['initiative', 'Initiative'], ['custom', 'Other (note)']];
const ABIL = [['str', 'Strength'], ['dex', 'Dexterity'], ['con', 'Constitution'], ['int', 'Intelligence'], ['wis', 'Wisdom'], ['cha', 'Charisma']];
const DURATIONS = [['indefinite', 'Until removed'], ['rounds', 'Rounds'], ['minutes', 'Minutes'], ['until_turn_start', 'Until the start of a turn'],
  ['until_turn_end', 'Until the end of a turn'], ['save_ends', 'Until a save succeeds']];
const store = { get: (k) => { try { return localStorage.getItem(`tavern-ledger:combat-${k}`); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(`tavern-ledger:combat-${k}`, v); } catch { /* optional */ } } };

let root = null;
let seq = 0;              // render token: a view that is no longer shown never paints
let data = null;          // combat_get_encounter answer {encounter, participants, effects, reminders, difficulty, conditions}
let selected = null;      // participant id shown in the detail panel
let unsubscribe = null;
let lastChange = 0;       // highest combat_changes id seen
let connection = 'online';
let notices = [];         // turn notes of the latest moves (expired effects, saves, legendary, reminders)
let lastAction = null;    // {event, label}: what Undo undoes
let summaries = {};       // character id -> {derived, row}: AC, Initiative, Speed, passives (cached per encounter)
let busy = new Set();     // control keys with a request in flight (duplicate-click protection)
let drawer = false;       // the detail panel as a drawer (narrow screens)
let keyHandler = null;
let netHandler = null;

// =============================================================================================================== mount
export async function mountCombat(container, { section = 'home', id = null } = {}) {
  unmountCombat();
  root = document.createElement('div');
  root.className = 'cb';
  container.replaceChildren(root);
  root.addEventListener('click', onClick);
  root.addEventListener('change', onChange);
  root.addEventListener('input', onInput);
  root.addEventListener('keydown', onFieldKey);
  netHandler = () => setConnection(navigator.onLine ? 'online' : 'offline');
  window.addEventListener('online', netHandler);
  window.addEventListener('offline', netHandler);
  const my = ++seq;
  if (section === 'encounter' && id) return openEncounter(id, my);
  if (section === 'library') return mountLibraryPage(root, { campaignId: store.get('campaign'), onCreate: () => {} });
  return renderHome(my);
}

export function unmountCombat() {
  seq += 1;
  unsubscribe?.();
  unsubscribe = null;
  if (keyHandler) document.removeEventListener('keydown', keyHandler);
  keyHandler = null;
  if (netHandler) { window.removeEventListener('online', netHandler); window.removeEventListener('offline', netHandler); }
  netHandler = null;
  root?.removeEventListener('click', onClick);
  root?.removeEventListener('change', onChange);
  root?.removeEventListener('input', onInput);
  root?.removeEventListener('keydown', onFieldKey);
  root = null;
  announcer = null;
  data = null; selected = null; notices = []; lastAction = null; summaries = {}; busy = new Set(); lastChange = 0; drawer = false;
  clearDetailCaches();
  document.body.classList.remove('cb-drawer-open');
}

const alive = (my) => my === seq && root;
const E = () => data?.encounter;
const P = (pid) => data?.participants.find((p) => p.id === pid) || null;
const pname = (p) => (p ? `${p.name}${p.label ? ` ${p.label}` : ''}` : '');
const go = (hash) => { window.location.hash = hash; };
const isLive = () => ['active', 'paused'].includes(E()?.status);
const fmtTime = (s) => { const m = Math.floor((s || 0) / 60); return m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`; };
const signed = (n) => (n == null ? '—' : n >= 0 ? `+${n}` : `−${Math.abs(n)}`);
// one live region per mount, outside the re-rendered views, so a re-render never swallows an announcement
let announcer = null;
function announce(text) {
  if (!root) return;
  if (!announcer) {
    announcer = document.createElement('div');
    announcer.className = 'sr-only';
    announcer.setAttribute('aria-live', 'polite');
    announcer.dataset.cbAnnounce = '';
  }
  if (!announcer.isConnected) root.append(announcer);
  announcer.textContent = '';
  setTimeout(() => { if (announcer) announcer.textContent = text; }, 30);
}

function spinner() { return '<div class="center-wrap"><div class="spinner" role="status" aria-label="Loading"></div></div>'; }
function errorBox(err, retry = 'reload') {
  return `<div class="cb-error" role="alert"><p>${esc(err?.message || 'Something went wrong.')}</p>
    <button type="button" class="btn" data-cb="${retry}">Retry</button> <a class="btn btn-ghost" href="#/combat">Combat Home</a></div>`;
}

// ============================================================================================================ Combat Home
async function renderHome(my) {
  root.innerHTML = `<header class="cb-head"><div><span class="cb-kicker">${glyph('swords', { size: 16 })} Combat Builder</span><h1 class="cb-title">Encounters</h1></div></header>${spinner()}`;
  let list;
  try { list = await api.listEncounters(null, store.get('archived') === '1'); } catch (err) { if (alive(my)) root.innerHTML = errorBox(err, 'home'); return; }
  if (!alive(my)) return;
  const camps = list.campaigns || [];
  if (!camps.length) {
    root.innerHTML = '<div class="empty-state"><h1 class="cb-title">Combat Builder</h1><p>You are not the DM of a campaign yet. Encounters belong to a campaign you run.</p></div>';
    return;
  }
  const camp = camps.some((c) => c.id === store.get('campaign')) ? store.get('campaign') : '';
  const encs = (list.encounters || []).filter((e) => !camp || e.campaign_id === camp);
  const group = (st) => encs.filter((e) => st.includes(e.status) && !e.archived_at);
  const card = (e) => `<article class="cb-card cb-card-${esc(e.status)}${e.archived_at ? ' cb-card-archived' : ''}">
      <div class="cb-card-main">
        <h3 class="cb-card-title"><a href="#/combat/e/${esc(e.id)}">${esc(e.name)}</a></h3>
        <p class="small muted">${esc(e.campaign_name)} · ${esc(e.ruleset)} rules · ${e.counts.characters} characters, ${e.counts.monsters} monsters
          ${e.status === 'active' || e.status === 'paused' ? ` · <strong>Round ${e.round}</strong>` : ''}${e.archived_at ? ' · archived' : ''}</p>
      </div>
      <span class="cb-status cb-status-${esc(e.status)}">${esc(STATUS[e.status])}</span>
      <div class="cb-card-actions">
        <a class="btn btn-sm ${e.status === 'draft' ? '' : 'btn-gold'}" href="#/combat/e/${esc(e.id)}">${e.status === 'completed' ? 'View summary' : e.status === 'draft' ? 'Open' : 'Resume'}</a>
        <button type="button" class="btn btn-sm btn-ghost" data-cb="duplicate" data-id="${esc(e.id)}">Duplicate</button>
        ${e.status !== 'active' && e.status !== 'paused' ? `<button type="button" class="btn btn-sm btn-ghost" data-cb="archive" data-id="${esc(e.id)}" data-on="${e.archived_at ? '0' : '1'}">${e.archived_at ? 'Restore' : 'Archive'}</button>` : ''}
      </div></article>`;
  const sect = (title, items, empty) => `<section class="cb-section"><h2 class="cb-section-title">${esc(title)} <span class="count">${items.length}</span></h2>
    ${items.length ? `<div class="cb-cards">${items.map(card).join('')}</div>` : `<p class="muted small">${esc(empty)}</p>`}</section>`;
  root.innerHTML = `
    <header class="cb-head">
      <div><span class="cb-kicker">${glyph('swords', { size: 16 })} Combat Builder</span><h1 class="cb-title">Encounters</h1></div>
      <div class="cb-head-actions">
        <label class="field cb-camp"><span>Campaign</span><select data-cb-camp><option value="">All campaigns</option>
          ${camps.map((c) => `<option value="${esc(c.id)}" ${c.id === camp ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></label>
        <a class="btn" href="#/combat/library">${icon('dm.creature', { size: 18 })} Monster Library</a>
        <button type="button" class="btn btn-gold" data-cb="new" data-focus-key="cb-new">${glyph('plus', { size: 16 })} New encounter</button>
      </div>
    </header>
    ${sect('Active and paused', group(['active', 'paused']), 'No combat is running.')}
    ${sect('Prepared encounters', group(['draft']), 'Prepare an encounter before the session: add the party and the monsters, then start it at the table.')}
    ${sect('Recently finished', group(['completed']).slice(0, 12), 'Finished encounters and their summaries appear here.')}
    <label class="cb-toggle small"><input type="checkbox" data-cb-archived ${store.get('archived') === '1' ? 'checked' : ''}> Show archived encounters</label>
    ${store.get('archived') === '1' ? sect('Archived', encs.filter((e) => e.archived_at), 'Nothing archived.') : ''}`;
  root.dataset.campaigns = JSON.stringify(camps);
}

async function newEncounter() {
  const camps = JSON.parse(root.dataset.campaigns || '[]');
  const camp = camps.find((c) => c.id === store.get('campaign')) || camps[0];
  const m = openModal({
    title: 'New encounter',
    body: `<form class="form-grid" data-cb-form>
      <label class="field span-2"><span>Name</span><input name="name" maxlength="120" required placeholder="Goblin ambush at the ford"></label>
      <label class="field"><span>Campaign</span><select name="campaign">${camps.map((c) => `<option value="${esc(c.id)}" ${c.id === camp?.id ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></label>
      <label class="field"><span>Rules</span><select name="ruleset"><option value="campaign">Campaign default</option><option value="2024">2024 (SRD 5.2.1)</option><option value="2014">2014 (SRD 5.1)</option></select></label>
      <label class="field span-2"><span>Description (optional)</span><textarea name="description" rows="2" maxlength="4000"></textarea></label>
      <p class="muted small span-2" data-cb-rs></p>
    </form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Create</button>',
  });
  const hint = () => {
    const c = camps.find((x) => x.id === $('[name=campaign]', m.el).value);
    $('[data-cb-rs]', m.el).textContent = c ? `Campaign default for ${c.name}: ${c.ruleset} rules (allowed: ${(c.rulesets || []).join(', ')}).` : '';
  };
  hint();
  m.el.addEventListener('change', hint);
  $('[data-ok]', m.el).addEventListener('click', async (ev) => {
    const f = $('[data-cb-form]', m.el);
    const name = f.name.value.trim();
    if (!name) { f.name.focus(); toast('Give the encounter a name'); return; }
    const okBtn = ev.currentTarget; okBtn.disabled = true;
    try {
      const r = await api.createEncounter(f.campaign.value, name, f.ruleset.value, f.description.value);
      store.set('campaign', f.campaign.value);
      m.close();
      go(`#/combat/e/${r.encounter.id}`);
    } catch (err) { toast(err.message, 'bad'); okBtn.disabled = false; }
  });
}

// =============================================================================================================== encounter
async function openEncounter(id, my) {
  root.innerHTML = spinner();
  try { data = await api.getEncounter(id); } catch (err) { if (alive(my)) root.innerHTML = errorBox(err, 'reload'); return; }
  if (!alive(my)) return;
  lastChange = data.last_change_id || 0;
  root.dataset.encounter = id;
  if (data.last_event?.undoable) lastAction = { event: data.last_event.id, label: kindLabel(data.last_event.kind) };
  subscribe();
  render();
  loadSummaries();
  installKeys();
}

function render() {
  if (!root || !data) return;
  const st = E().status;
  if (st === 'draft') renderBuilder();
  else if (st === 'completed') renderSummary();
  else renderLive();
  setConnection(connection);
  if (announcer) root.append(announcer);   // keeps the last announcement across re-renders
}

async function reload() {
  const id = E()?.id || root?.dataset.encounter;
  if (!id) return;
  const my = seq;
  try {
    const fresh = await api.getEncounter(id);
    if (my !== seq || !root) return;
    const charsChanged = JSON.stringify(charIds(fresh)) !== JSON.stringify(charIds(data));
    const statusChanged = fresh.encounter.status !== data?.encounter.status;
    data = fresh;
    lastChange = Math.max(lastChange, fresh.last_change_id || 0);
    if (charsChanged) { subscribe(); loadSummaries(); }
    if (statusChanged || !$('.cb-live, .cb-builder, .cb-summary', root)) render(); else repaint();
  } catch (err) { toast(err.message, 'bad'); }
}

const charIds = (d) => (d?.participants || []).filter((p) => p.kind === 'character' && p.character_id).map((p) => p.character_id).sort();

/** Re-render the current view keeping focus on the same control (data-focus-key). */
function repaint() {
  const key = document.activeElement?.closest?.('[data-focus-key]')?.dataset.focusKey;
  const scroll = $('.cb-order-list', root)?.scrollTop;
  // work in progress survives a background re-render (summaries arriving, a Realtime refresh): an open quick popover and
  // an amount typed in the detail panel keep their value, mode and focus
  const pop = $('.cb-pop', root);
  const popState = pop ? { pid: pop.dataset.pid, op: pop.dataset.op, value: $('input', pop)?.value || '' } : null;
  const amt = $('[data-cb-amount]', root);
  const amtState = amt ? { pid: amt.dataset.cbAmount, value: amt.value, op: amt.dataset.op, focused: document.activeElement === amt } : null;
  render();
  if (scroll != null && $('.cb-order-list', root)) $('.cb-order-list', root).scrollTop = scroll;
  if (key) focusByKey(key, root);
  if (amtState) {
    const n = $(`[data-cb-amount="${CSS.escape(amtState.pid)}"]`, root);
    if (n) { n.value = amtState.value; if (amtState.op) n.dataset.op = amtState.op; if (amtState.focused) n.focus(); if (amtState.value) showPreview(amtState.pid, Number(amtState.value)); }
  }
  if (popState) {
    const b = $(`.cb-row[data-pid="${CSS.escape(popState.pid)}"] [data-cb="quick-hp"][data-op="${popState.op}"]`, root);
    if (b) quickHp(b, popState.pid, popState.op, popState.value);
  }
}

function patchParticipants(list) {
  for (const np of list || []) {
    const i = data.participants.findIndex((p) => p.id === np.id);
    if (i >= 0) data.participants[i] = np; else data.participants.push(np);
  }
}
function patchEffects(list) {
  for (const ne of list || []) {
    const i = data.effects.findIndex((x) => x.id === ne.id);
    if (i >= 0) data.effects[i] = ne; else data.effects.push(ne);
  }
}
function applyResult(r) {
  if (!r || !data) return;
  // a whole encounter read (combat_get_encounter shape: Undo, encounter edits) replaces the view's data
  if (r.encounter?.id && r.difficulty) { data = { ...data, ...r }; return; }
  if (r.encounter?.id) data.encounter = r.encounter;
  if (r.participant) patchParticipants([r.participant]);
  if (Array.isArray(r.participants)) patchParticipants(r.participants);
  if (Array.isArray(r.effects)) patchEffects(r.effects);
}

/** One mutation: refused while offline, guarded against a second click, conflicts reload the view. */
async function mutate(key, fn, { after, quiet = false } = {}) {
  if (connection !== 'online') { toast('No connection: the encounter is read-only until it reconnects. Nothing was changed.', 'bad'); return null; }
  if (busy.has(key)) return null;
  busy.add(key);
  $$(`[data-busy-key="${CSS.escape(key)}"]`, root).forEach((b) => b.setAttribute('aria-busy', 'true'));
  try {
    const r = await fn();
    if (!root) return r;
    applyResult(r);
    if (r?.event_id && !quiet) lastAction = { event: r.event_id, label: after || 'last change' };
    repaint();
    return r;
  } catch (err) {
    if (api.isConflict(err)) { toast(err.message, 'info', 4500); await reload(); }
    else toast(err.message, 'bad');
    return null;
  } finally {
    busy.delete(key);
    $$(`[data-busy-key="${CSS.escape(key)}"]`, root || document).forEach((b) => b.removeAttribute('aria-busy'));
  }
}

// ---------------------------------------------------------------------------------------------------- character summaries
// build-relevant columns of a linked character: when one of them changes (an ability base edited on the sheet, a level …)
// its combat numbers are re-read; HP-only updates are patched from the Realtime payload without any read
const SUMMARY_COLS = ['initiative_bonus', 'skill_proficiencies', 'save_proficiencies', 'speed', 'strength', 'dexterity', 'constitution',
  'intelligence', 'wisdom', 'charisma', 'ac_override', 'level', 'hp_max'];
// character_revisions sources that change AC, Speed, passives, maximum HP or Initiative (docs/COMBAT_BUILDER_FOLLOWUP.md)
// (only tables with a _bump_character_revision trigger emit these rows; an ASI change writes character_feature_choices)
const BUILD_SOURCES = new Set(['character_feats', 'character_feat_choices', 'character_classes', 'character_feature_choices',
  'character_optional_features', 'character_lineages', 'character_lineage_choices', 'character_backgrounds',
  'character_proficiencies', 'character_equipment', 'inventory_items']);

async function loadSummaries() {
  const ids = charIds(data).filter((id) => !summaries[id]);
  if (!ids.length) return;
  const { data: rows } = await supabase.from('characters').select(`id, ${SUMMARY_COLS.join(', ')}`).in('id', ids);
  for (const row of rows || []) summaries[row.id] = { row, derived: null };
  const queue = [...ids];
  const worker = async () => {
    while (queue.length && root) {
      const id = queue.shift();
      try { summaries[id] = { ...(summaries[id] || {}), derived: await api.characterSummary(id) }; } catch { /* the row values stay */ }
    }
  };
  await Promise.all([worker(), worker(), worker()]);   // at most three reads at a time
  if (root && data) { ids.forEach(syncInitiativeMod); repaint(); }
}

/** The sheet's Initiative modifier from the derived read (same formula as Add Party). */
const sheetInitMod = (s) => {
  if (!s?.derived) return null;            // no derived read (yet / failed): never write a modifier built from the base score
  const dex = s.derived.abilities?.dex?.score;
  return dex == null ? null : Math.floor((dex - 10) / 2) + (s.row?.initiative_bonus || 0) + (Number(s.derived?.initiative?.bonus) || 0);
};

/** A linked character's Initiative modifier follows the sheet until its Initiative is entered or rolled; a rolled Initiative is
 *  never recalculated during the combat (it is rolled once). Only the DM's window writes it. */
function syncInitiativeMod(cid) {
  const mod = sheetInitMod(summaries[cid]);
  if (mod == null || !data || ['completed', 'archived'].includes(E()?.status)) return;
  for (const p of data.participants || []) {
    if (p.character_id !== cid || p.initiative != null || p.initiative_mod === mod) continue;
    p.initiative_mod = mod;
    api.updateParticipant(p.id, { initiative_mod: mod }).then((r) => { if (r?.participant) patchParticipants([r.participant]); }).catch(() => { /* the next read corrects it */ });
  }
}

/** Re-read ONE linked character's combat numbers after a build change (no encounter reload): AC, Speed, passives (derived
 *  read, server-cached per revision) and its participant row (maximum HP with feats). */
const pendingSummary = new Set();
const flushSummaries = debounce(async () => {
  const ids = [...pendingSummary];
  pendingSummary.clear();
  if (!root || !data || !ids.length) return;
  const { data: rows } = await supabase.from('characters').select(`id, ${SUMMARY_COLS.join(', ')}`).in('id', ids);
  await Promise.all(ids.map(async (cid) => {
    let derived = summaries[cid]?.derived || null;
    try { derived = await api.characterSummary(cid); } catch { /* keep the last values */ }
    summaries[cid] = { row: (rows || []).find((r) => r.id === cid) || summaries[cid]?.row, derived };
    await Promise.all((data?.participants || []).filter((p) => p.character_id === cid).map(async (p) => {
      try { const r = await api.getParticipant(p.id); patchParticipants([r.participant]); } catch { /* removed meanwhile */ }
    }));
    syncInitiativeMod(cid);
  }));
  if (root && data) repaint();
}, 300);
function refreshSummary(cid) {
  if (!cid || !charIds(data).includes(cid)) return;
  pendingSummary.add(cid);
  flushSummaries();
  if (featureCache[cid]) refreshFeatures(cid);
}
const featureTimers = {};
/** Re-read the shown active features of ONE character (per-character debounce; other characters are not touched). */
function refreshFeatures(cid) {
  clearTimeout(featureTimers[cid]);
  featureTimers[cid] = setTimeout(() => { if (root && featureCache[cid]) loadFeatures(cid); }, 400);
}

/** Combat numbers of a participant: monsters from the snapshot / instance, characters from the sheet (derived stats).
 *  "Applied" effects (docs/COMBAT_EFFECTS_AND_CONDITIONS.md) change AC and Speed here; everything else is a reminder. */
function stats(p) {
  const s0 = statsBase(p);
  const spMod = effectsOf(p.id).filter((x) => x.application === 'applied' && x.modifier_target === 'speed').reduce((a, x) => a + (x.modifier_value || 0), 0);
  return spMod ? { ...s0, speed: `${s0.speed} (${spMod > 0 ? '+' : '−'}${Math.abs(spMod)} ft from effects)` } : s0;
}
function statsBase(p) {
  if (p.kind === 'monster') {
    const sb = p.statblock || {};
    const acMod = effectsOf(p.id).filter((x) => x.application === 'applied' && x.modifier_target === 'ac').reduce((a, x) => a + (x.modifier_value || 0), 0);
    return { ac: p.armor_class, acMod, speed: speedText(sb.speed), pp: sb.passive_perception, init: p.initiative_mod };
  }
  const s = summaries[p.character_id] || {};
  const d = s.derived; const row = s.row || {};
  const acMod = effectsOf(p.id).filter((x) => x.application === 'applied' && x.modifier_target === 'ac').reduce((a, x) => a + (x.modifier_value || 0), 0);
  const form = p.form;
  const wisMod = d?.abilities?.wis?.modifier ?? Math.floor(((row.wisdom || 10) - 10) / 2);
  const pb = d?.proficiency_bonus?.value ?? 2;
  const perc = d?.skills?.perception || {};
  const stored = Number(row.skill_proficiencies?.perception) || 0;
  const lvl = Math.max(perc.class_expertise ? 2 : perc.class_proficient ? 1 : 0, perc.lineage_proficient ? 1 : 0, stored > 1 ? 2 : stored);
  return {
    ac: form ? form.armor_class : d?.armor_class?.value, acMod,
    speed: form ? speedText(form.speed) : (d ? speedText(Object.fromEntries(Object.entries(d.speed?.movement || { walk: { value: d.speed?.value } })
      .filter(([, v]) => v?.active !== false).map(([k, v]) => [k, v?.value]))) : `${row.speed || 30} ft`),
    pp: d ? 10 + wisMod + lvl * pb + (perc.advantage ? 5 : 0) - (perc.disadvantage ? 5 : 0) : null,
    init: p.initiative_mod, derived: d,
  };
}
function speedText(sp) {
  if (!sp || typeof sp !== 'object') return '—';
  return Object.entries(sp).filter(([k, v]) => k !== 'hover' && v).sort(([a], [b]) => (a === 'walk' ? -1 : b === 'walk' ? 1 : 0)).map(([k, v]) => (k === 'walk' ? `${v} ft` : `${k} ${v} ft`)).join(', ') || '—';
}

// ---------------------------------------------------------------------------------------------------- hp and effects helpers
function hpOf(p) {
  if (p.kind === 'character' && p.form) {
    return { cur: p.form.hp_current, max: p.form.hp_max, temp: p.form.hp_temp || 0, form: p.form.name, normal: p.hp,
      expired: !!p.form.expires_at && Date.parse(p.form.expires_at) <= Date.now() };
  }
  return { cur: p.hp?.current ?? 0, max: p.hp?.max || 1, temp: p.hp?.temp || 0 };
}
function hpState(p) {
  const h = hpOf(p);
  if (p.kind === 'monster' && p.defeated) return 'defeated';
  if (h.cur <= 0) return 'down';
  return h.cur * 4 <= h.max ? 'critical' : h.cur * 2 <= h.max ? 'bloodied' : 'healthy';
}
const effectsOf = (pid) => (data?.effects || []).filter((x) => x.active && x.target_participant_id === pid);
const concentrationOf = (pid) => (data?.effects || []).find((x) => x.active && x.effect_type === 'concentration' && x.source_participant_id === pid) || null;

/** Advantage + Disadvantage on the same scope = a normal roll (5e). */
function advSummary(pid) {
  const by = new Map();
  for (const x of effectsOf(pid).filter((y) => y.effect_type === 'advantage')) {
    const key = `${x.adv_scope}:${x.adv_detail || ''}:${x.adv_target_id || ''}`;
    const v = by.get(key) || { scope: x.adv_scope, detail: x.adv_detail, target: x.adv_target_id, adv: false, dis: false, ids: [] };
    if (x.adv_mode === 'advantage') v.adv = true; else v.dis = true;
    v.ids.push(x.id);
    by.set(key, v);
  }
  return [...by.values()].map((v) => ({ ...v, net: v.adv && v.dis ? 'normal' : v.adv ? 'advantage' : 'disadvantage' }));
}
const scopeLabel = (s) => (SCOPES.find(([k]) => k === s) || [s, s])[1];
function durationText(x) {
  if (x.duration_type === 'rounds') return `${x.remaining_rounds ?? x.duration_rounds} rd${(x.remaining_rounds ?? x.duration_rounds) === 1 ? '' : 's'} left`;
  if (x.duration_type === 'until_turn_start') return `until start of ${pname(P(x.anchor_participant_id)) || 'turn'}`;
  if (x.duration_type === 'until_turn_end') return `until end of ${pname(P(x.anchor_participant_id)) || 'turn'}`;
  if (x.duration_type === 'save_ends') return `save ends (${(x.save_ability || '').toUpperCase()} DC ${x.save_dc})`;
  return '';
}

function chip(x) {
  const name = x.effect_type === 'condition' && x.condition_key === 'exhaustion' ? `${x.display_name} ${x.exhaustion_level || 1}` : x.display_name;
  const dur = durationText(x);
  const ic = x.effect_type === 'condition' ? conditionIcon(x.condition_key, { size: 14 }) : x.effect_type === 'advantage' ? glyph(x.adv_mode === 'advantage' ? 'adv' : 'dis', { size: 14 })
    : x.effect_type === 'concentration' ? icon('action.concentration', { size: 14 }) : icon('condition.generic-effect', { size: 14 });
  // advantage / disadvantage: the arrow glyph and the colour are visual; the word is spoken and in the tooltip (not colour only)
  const mode = x.effect_type === 'advantage' ? (x.adv_mode === 'advantage' ? 'Advantage' : 'Disadvantage') : '';
  return `<span class="cb-chip cb-chip-${esc(x.effect_type)}${x.visibility === 'dm' ? ' cb-chip-dm' : ''}" title="${esc([mode, x.condition?.summary || x.description, dur].filter(Boolean).join(' · '))}">
    ${ic}${mode ? `<span class="sr-only">${mode}: </span>` : ''}<span>${esc(name)}</span>${x.visibility === 'dm' ? '<span class="sr-only"> (hidden from players)</span>' : ''}${dur ? `<span class="cb-chip-dur">${esc(dur)}</span>` : ''}</span>`;
}

// ================================================================================================================ builder
function renderBuilder() {
  const e = E();
  const ps = data.participants.filter((p) => !p.removed);
  const chars = ps.filter((p) => p.kind === 'character');
  const mons = ps.filter((p) => p.kind === 'monster');
  const ties = tieGroups();
  const d = data.difficulty || {};
  root.innerHTML = `
  <div class="cb-builder">
    <header class="cb-head">
      <div><span class="cb-kicker">${glyph('swords', { size: 16 })} <a href="#/combat">Combat Builder</a> · Prepared encounter</span>
        <h1 class="cb-title">${esc(e.name)}</h1>
        <p class="small muted">${esc(e.campaign_name)} · <strong>${esc(e.ruleset)} rules</strong>${e.ruleset_source === 'campaign_default' ? ' (campaign default)' : ''}</p></div>
      <div class="cb-head-actions">
        <button type="button" class="btn btn-ghost" data-cb="edit-encounter" data-focus-key="cb-edit">Edit details</button>
        <button type="button" class="btn btn-ghost" data-cb="duplicate" data-id="${esc(e.id)}">Duplicate</button>
        <button type="button" class="btn btn-ghost" data-cb="delete-draft">Delete draft</button>
        <button type="button" class="btn btn-gold btn-lg" data-cb="start" data-busy-key="start" data-focus-key="cb-start">${glyph('play', { size: 16 })} Start combat</button>
      </div>
    </header>
    ${e.description ? `<p class="cb-desc">${esc(e.description)}</p>` : ''}
    <div class="cb-builder-grid">
      <section class="cb-panel">
        <div class="cb-panel-head"><h2 class="cb-section-title">${icon('action.initiative', { size: 20 })} Initiative</h2>
          <div class="cb-btns">
            <button type="button" class="btn btn-sm" data-cb="roll-monsters" data-busy-key="roll" data-focus-key="cb-roll">Roll all monsters</button>
            <button type="button" class="btn btn-sm btn-ghost" data-cb="sort" data-busy-key="sort">Sort</button>
            <button type="button" class="btn btn-sm btn-ghost" data-cb="clear-init">Clear</button>
          </div></div>
        ${ties.length ? `<p class="cb-warn small" role="status">${glyph('bolt', { size: 14 })} ${ties.length} tie${ties.length > 1 ? 's' : ''}: the default order uses the higher Initiative modifier, then Dexterity. Move combatants with the arrows if you or the players decide otherwise.</p>` : ''}
        ${ps.length ? `<p class="small muted cb-init-help" id="cb-init-help">Players: enter the total the player rolled, including all bonuses (type <strong>17</strong>, not +17).
          The modifier is shown for reference only and is never added. Monsters: <strong>Auto roll</strong> (d20 + modifier, rolled by the server) or
          <strong>Manual total</strong>. Press Enter to move to the next missing value.</p>
        <div class="cb-table-wrap"><table class="cb-init-table">
          <caption class="sr-only">Initiative of every combatant</caption>
          <thead><tr><th scope="col">Order</th><th scope="col">Combatant</th><th scope="col">Modifier <span class="cb-th-note">(reference)</span></th><th scope="col">Final Initiative</th><th scope="col">Group</th>
            <th scope="col"><span class="sr-only">Hidden</span>${glyph('hidden', { size: 14 })}</th><th scope="col">Surprised</th><th scope="col">Ready</th><th scope="col"><span class="sr-only">Actions</span></th></tr></thead>
          <tbody>${ps.map((p, i) => initRow(p, i, ps.length)).join('')}</tbody></table></div>` : '<p class="muted">Add the party and the monsters. Then enter or roll Initiative.</p>'}
        <div class="cb-btns cb-add-btns">
          <button type="button" class="btn" data-cb="add-party" data-focus-key="cb-add-party">${icon('dm.campaign', { size: 18 })} Add party</button>
          <button type="button" class="btn" data-cb="add-monsters" data-focus-key="cb-add-monsters">${icon('dm.creature', { size: 18 })} Add monsters</button>
          <button type="button" class="btn btn-ghost" data-cb="add-custom">Typed-in combatant</button>
        </div>
      </section>
      <aside class="cb-side">
        <section class="cb-panel"><h2 class="cb-section-title">Difficulty</h2>${difficultyHTML(d)}</section>
        <section class="cb-panel"><h2 class="cb-section-title">${glyph('bell', { size: 18 })} Reminders</h2>${remindersHTML(true)}
          <button type="button" class="btn btn-sm" data-cb="reminder-new">+ Reminder (lair action, reinforcements…)</button></section>
        <section class="cb-panel"><h2 class="cb-section-title">Settings</h2>
          <label class="field"><span>Monster HP when added</span><select data-cb-setting="hp_mode"><option value="average" ${e.settings.hp_mode !== 'rolled' ? 'selected' : ''}>Average (fixed)</option><option value="rolled" ${e.settings.hp_mode === 'rolled' ? 'selected' : ''}>Rolled from hit dice</option></select></label>
          <label class="field"><span>Future player view: enemy HP</span><select data-cb-setting="player_enemy_hp">
            ${[['state', 'Healthy / Bloodied only'], ['none', 'Hidden'], ['exact', 'Exact numbers']].map(([k, l]) => `<option value="${k}" ${(e.settings.player_enemy_hp || 'state') === k ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
          ${e.ruleset === '2024' ? `<label class="cb-toggle small"><input type="checkbox" data-cb-setting="fixed_initiative" ${e.settings.fixed_initiative ? 'checked' : ''}> Use the monsters' fixed Initiative scores instead of rolling</label>` : ''}
          <label class="field"><span>DM notes (only you)</span><textarea rows="3" data-cb-notes maxlength="8000">${esc(e.dm_notes || '')}</textarea></label>
        </section>
        <p class="muted small">${chars.length} characters · ${mons.length} monsters</p>
      </aside>
    </div>
  </div>`;
}

// Initiative entry mode of a monster (or its shared group): 'auto' = the server rolls d20 + modifier (or the 2024 fixed score),
// 'manual' = the DM types the final total. UI state only: every stored value is a final total either way, so switching the
// mode never reinterprets a value. Player characters always use a typed final total (the player rolls and dictates it).
const initModes = {};
const modeKey = (p) => (p.group_key ? `g:${p.group_key}` : p.id);
function initMode(p) {
  if (p.kind === 'character') return 'manual';
  return initModes[modeKey(p)] || (p.initiative_mode === 'manual' ? 'manual' : 'auto');
}
const groupSize = (p) => (data?.participants || []).filter((x) => !x.removed && x.active && x.group_key === p.group_key).length;

function initInput(p, label) {
  return `<input class="cb-init-input" type="number" inputmode="numeric" enterkeyhint="next" step="1" min="-20" max="60" value="${p.initiative ?? ''}"
      data-cb-init="${esc(p.id)}" aria-label="${esc(label)}" aria-describedby="cb-init-help" data-focus-key="init:${esc(p.id)}">`;
}

function initCell(p) {
  const nm = pname(p);
  if (p.kind === 'character') return initInput(p, `Final Initiative of ${nm} (total the player rolled)`);
  const mode = initMode(p);
  const fixed = E().ruleset === '2024' && !!E().settings.fixed_initiative;
  const grp = p.group_key ? ` (whole group of ${groupSize(p)})` : '';
  const select = `<select class="cb-imode" data-cb-imode="${esc(p.id)}" aria-label="Initiative mode of ${esc(nm)}${esc(grp)}" data-focus-key="imode:${esc(p.id)}">
      <option value="auto" ${mode === 'auto' ? 'selected' : ''}>${fixed ? 'Fixed score' : 'Auto roll'}</option>
      <option value="manual" ${mode === 'manual' ? 'selected' : ''}>Manual total</option></select>`;
  if (mode === 'manual') return `${select}${initInput(p, `Final Initiative of ${nm}${grp}`)}`;
  const how = p.initiative == null ? '' : p.initiative_mode === 'fixed' ? 'fixed score'
    : p.initiative_mode === 'rolled' && p.initiative_roll != null ? `d20 ${p.initiative_roll} ${p.initiative_mod < 0 ? '−' : '+'} ${Math.abs(p.initiative_mod)}` : 'typed total';
  return `${select}<span class="cb-init-final" aria-label="Final Initiative of ${esc(nm)}: ${p.initiative ?? 'not rolled yet'}">${p.initiative ?? '—'}</span>
    <button type="button" class="btn btn-sm btn-ghost" data-cb="roll-one" data-id="${esc(p.id)}" data-busy-key="roll:${esc(p.id)}" data-focus-key="roll:${esc(p.id)}"
      aria-label="${p.initiative == null ? 'Roll' : 'Reroll'} Initiative for ${esc(nm)}${esc(grp)}">${p.initiative == null ? 'Roll' : 'Reroll'}</button>
    ${how ? `<span class="small muted cb-init-how">${esc(how)}</span>` : ''}`;
}

/** Store a typed final total (no modifier is added). Skips an unchanged value, so Enter + change never sends it twice. */
async function saveInit(t) {
  const id = t.dataset.cbInit;
  const v = t.value.trim() === '' ? null : Number(t.value);
  if (v != null && (!Number.isInteger(v) || v < -20 || v > 60)) { toast('Final Initiative is a whole number from -20 to 60'); t.focus(); return false; }
  if ((P(id)?.initiative ?? null) === v) return true;
  const r = await mutate(`init:${id}`, () => api.setInitiative(E().id, [{ id, initiative: v }]), { quiet: true });
  if (r) await reload();
  return !!r;
}

/** Initiative correction in a running combat: final total + a reason, both kept in the history. */
function correctInitiative(pid) {
  const p = P(pid);
  if (!p) return;
  const m = openModal({
    title: `Correct Initiative: ${pname(p)}`,
    body: `<p class="small muted">Enter the corrected <strong>final</strong> Initiative (all bonuses included). The modifier ${esc(signed(p.initiative_mod))} is not added.
      ${p.group_key ? 'The whole group gets this value. ' : ''}The combatant moves to its new place; the change and the reason are kept in the history.</p>
      <form class="form-grid" data-f><label class="field"><span>Final Initiative</span><input name="init" type="number" inputmode="numeric" step="1" min="-20" max="60" value="${p.initiative ?? ''}" required></label>
      <label class="field span-2"><span>Reason (required)</span><input name="reason" maxlength="200" required placeholder="Misheard the total"></label></form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Save</button>',
  });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const f = $('[data-f]', m.el);
    const v = Number(f.init.value);
    if (f.init.value.trim() === '' || !Number.isInteger(v) || v < -20 || v > 60) { toast('Final Initiative is a whole number from -20 to 60'); f.init.focus(); return; }
    if (!f.reason.value.trim()) { toast('Give a reason for the correction'); f.reason.focus(); return; }
    const r = await mutate(`init:${pid}`, () => api.setInitiative(E().id, [{ id: pid, initiative: v, reason: f.reason.value.trim() }]), { after: 'Initiative correction' });
    if (r) { m.close(); await reload(); toast(`${pname(p)}: Initiative ${v}.`, 'good'); }
  });
}

function initRow(p, i, n) {
  const mismatch = p.statblock?.rules_version && p.statblock.rules_version !== E().ruleset;
  const ready = p.initiative != null || (p.joins_round && p.joins_round > 1);
  return `<tr class="${p.kind === 'character' ? 'cb-pc' : 'cb-mon'}${p.hidden ? ' cb-is-hidden' : ''}" data-pid="${esc(p.id)}">
    <td class="cb-ord"><button type="button" class="icon-btn" data-cb="move" data-dir="-1" data-id="${esc(p.id)}" ${i === 0 ? 'disabled' : ''} aria-label="Move ${esc(pname(p))} up">▲</button>
      <button type="button" class="icon-btn" data-cb="move" data-dir="1" data-id="${esc(p.id)}" ${i === n - 1 ? 'disabled' : ''} aria-label="Move ${esc(pname(p))} down">▼</button></td>
    <th scope="row" class="cb-who">${avatar(p, 28)}<span><strong>${esc(pname(p))}</strong>
      <span class="small muted">${p.kind === 'character' ? esc(p.character?.classes || 'Player character') : `${esc(p.statblock?.source_kind === 'custom' ? 'Typed in' : (p.statblock?.creature_type || 'monster'))} · CR ${esc(crText(p.statblock?.challenge_rating))}`}
      ${mismatch ? ` · <span class="cb-badge-warn" title="This stat block uses the ${esc(p.statblock.rules_version)} rules; the encounter uses ${esc(E().ruleset)}.">${esc(p.statblock.rules_version)} stat block</span>` : ''}
      ${p.joins_round > 1 ? ` · joins in round ${p.joins_round}` : ''}</span></span></th>
    <td data-label="Modifier (reference)"><span class="cb-mod-ref" title="Reference only: never added to a typed total">${esc(signed(p.initiative_mod))}</span>
      <span class="sr-only">Initiative modifier ${esc(signed(p.initiative_mod))}, reference only</span></td>
    <td class="cb-init-cell" data-label="Final Initiative">${initCell(p)}</td>
    <td class="small" data-label="Group">${p.group_key ? `one Initiative for ${groupSize(p)}` : '—'}</td>
    <td data-label="Hidden"><input type="checkbox" data-cb-flag="hidden" data-id="${esc(p.id)}" ${p.hidden ? 'checked' : ''} aria-label="Hidden from players: ${esc(pname(p))}"></td>
    <td data-label="Surprised"><input type="checkbox" data-cb-flag="surprised" data-id="${esc(p.id)}" ${p.surprised ? 'checked' : ''} aria-label="Surprised: ${esc(pname(p))}"></td>
    <td data-label="Ready">${ready ? `<span class="cb-ready" aria-label="Ready">✓</span>` : '<span class="cb-notready">Needs Initiative</span>'}</td>
    <td><button type="button" class="btn btn-sm btn-ghost" data-cb="remove" data-id="${esc(p.id)}" aria-label="Remove ${esc(pname(p))}">Remove</button></td></tr>`;
}

function avatar(p, size = 32) {
  if (p.kind === 'character' && p.character?.portrait_url) return `<img class="cb-avatar" src="${esc(p.character.portrait_url)}" alt="" width="${size}" height="${size}" loading="lazy">`;
  if (p.kind === 'character') return `<span class="cb-avatar cb-avatar-pc" style="width:${size}px;height:${size}px">${icon('ui.abilities', { size: size - 8 })}</span>`;
  const t = p.statblock?.creature_type;
  const name = t === 'dragon' ? 'creature.dragon' : t === 'beast' ? 'creature.bear-head' : 'dm.creature';
  return `<span class="cb-avatar cb-avatar-mon" style="width:${size}px;height:${size}px">${icon(name, { size: size - 8 })}</span>`;
}

function tieGroups() {
  const by = new Map();
  for (const p of data.participants.filter((x) => !x.removed && x.active && x.initiative != null)) {
    const k = p.initiative;
    if (!by.has(k)) by.set(k, []);
    by.get(k).push(p);
  }
  return [...by.entries()].filter(([, list]) => new Set(list.map((p) => p.group_key || p.id)).size > 1).map(([init, list]) => ({ init, list }));
}

function difficultyHTML(d) {
  if (!d || d.available === false) return `<p class="small muted">${esc(d?.reason || 'Add player characters to see an estimate.')}</p>`;
  const lbl = { low: 'Low', moderate: 'Moderate', high: 'High', above_high: 'Above High' }[d.rating] || '—';
  const max = Math.max(d.budget.high, d.xp, 1);
  return `<p><span class="cb-diff cb-diff-${esc(d.rating)}">${esc(lbl)}</span> <span class="small muted">${d.xp.toLocaleString()} XP for ${d.party} characters</span></p>
    <div class="cb-diff-bar" role="img" aria-label="Monster XP ${d.xp}; budget Low ${d.budget.low}, Moderate ${d.budget.moderate}, High ${d.budget.high}">
      <span class="cb-diff-fill" style="width:${Math.min(100, (d.xp / max) * 100)}%"></span>
      ${['low', 'moderate', 'high'].map((k) => `<span class="cb-diff-mark" style="left:${(d.budget[k] / max) * 100}%" title="${k} ${d.budget[k]}"></span>`).join('')}</div>
    <p class="small muted">Budget: Low ${d.budget.low.toLocaleString()} · Moderate ${d.budget.moderate.toLocaleString()} · High ${d.budget.high.toLocaleString()}${d.uncounted ? ` · ${d.uncounted} without XP not counted` : ''}</p>
    <p class="small muted">${esc(d.note)}</p>`;
}

function remindersHTML(editable) {
  const rs = data.reminders || [];
  if (!rs.length) return '<p class="small muted">None. Lair actions, hazards and reinforcements are reminders only.</p>';
  return `<ul class="cb-rem-list">${rs.map((r) => `<li class="${r.active ? '' : 'muted'}"><strong>${esc(r.title)}</strong>
    <span class="small muted">${[r.trigger_round ? `round ${r.trigger_round}${r.repeat_every ? `, every ${r.repeat_every}` : ''}` : 'every round', r.trigger_initiative != null ? `at Initiative ${r.trigger_initiative}` : ''].filter(Boolean).join(' · ')}${r.hidden ? ' · DM only' : ''}</span>
    ${editable ? `<button type="button" class="btn btn-sm btn-ghost" data-cb="reminder-edit" data-id="${esc(r.id)}">Edit</button>` : ''}</li>`).join('')}</ul>`;
}

// ================================================================================================================= live
function orderList() {
  return data.participants.filter((p) => !p.removed).sort((a, b) => (a.order ?? 9e9) - (b.order ?? 9e9));
}

function renderLive() {
  const e = E();
  const cur = P(e.current_participant_id);
  if (!selected || !P(selected)) selected = cur?.id || data.participants[0]?.id || null;
  const list = orderList();
  const pos = list.findIndex((p) => p.id === cur?.id) + 1;
  const undoLbl = lastAction ? `Undo ${lastAction.label}` : 'Undo';
  root.innerHTML = `
  <div class="cb-live${e.status === 'paused' ? ' cb-paused' : ''}">
    <header class="cb-top">
      <div class="cb-top-id"><span class="cb-kicker">${glyph('swords', { size: 14 })} <a href="#/combat">Combat Builder</a><span class="cb-hide-sm"> · ${esc(e.campaign_name)} · ${esc(e.ruleset)} rules</span></span>
        <h1 class="cb-title cb-title-live">${esc(e.name)}</h1></div>
      <div class="cb-round" aria-label="Round ${e.round}"><span class="cb-round-label">Round</span><span class="cb-round-num">${e.round}</span></div>
      <div class="cb-turn-now"><span class="cb-round-label">Current turn</span><strong data-cb-current>${esc(pname(cur) || '—')}</strong>
        <span class="small muted">${pos ? `${pos} of ${list.length}` : ''} · ${fmtTime(e.elapsed_seconds)}</span></div>
      <div class="cb-top-actions">
        <span class="cb-conn" data-cb-conn role="status"></span>
        ${e.status === 'paused' ? `<button type="button" class="btn btn-gold" data-cb="resume" data-busy-key="resume">${glyph('play', { size: 16 })} Resume</button>`
          : `<button type="button" class="btn" data-cb="pause" data-busy-key="pause">${glyph('pause', { size: 16 })} Pause</button>`}
        <button type="button" class="btn btn-ghost" data-cb="reminders" aria-label="Reminders">${glyph('bell', { size: 16 })}<span class="cb-hide-sm"> Reminders</span></button>
        <button type="button" class="btn btn-ghost" data-cb="history" aria-label="History">${glyph('history', { size: 16 })}<span class="cb-hide-sm"> History</span></button>
        <button type="button" class="btn btn-ghost" data-cb="help" aria-label="Keyboard shortcuts">${glyph('help', { size: 16 })}</button>
        <button type="button" class="btn btn-bad" data-cb="finish" aria-label="Finish combat">${glyph('flag', { size: 16 })}<span class="cb-hide-sm"> Finish</span></button>
      </div>
    </header>
    <div class="cb-banner" data-cb-banner hidden></div>
    ${e.status === 'paused' ? '<p class="cb-paused-note" role="status">Combat is paused. Everything is kept exactly; Resume continues the same turn.</p>' : ''}
    ${noticesHTML()}
    <div class="cb-live-grid">
      <section class="cb-order" aria-labelledby="cb-order-h">
        <div class="cb-panel-head"><h2 class="cb-section-title" id="cb-order-h">${icon('action.initiative', { size: 18 })} Initiative order</h2>
          <label class="cb-search"><span class="sr-only">Find a combatant</span><input type="search" placeholder="Find…" data-cb-find data-focus-key="cb-find"></label></div>
        <ol class="cb-order-list" role="list">${list.map((p) => rowHTML(p, cur)).join('')}</ol>
        <div class="cb-btns"><button type="button" class="btn btn-sm" data-cb="add-monsters">${glyph('plus', { size: 14 })} Add combatant</button>
          <button type="button" class="btn btn-sm btn-ghost" data-cb="add-party">Add character</button>
          <button type="button" class="btn btn-sm btn-ghost" data-cb="bulk">Area damage…</button>
          <button type="button" class="btn btn-sm btn-ghost" data-cb="goto">Choose turn…</button></div>
      </section>
      <aside class="cb-detail${drawer ? ' cb-drawer-open' : ''}" aria-label="Selected combatant" data-cb-detail>${detailHTML(P(selected))}</aside>
    </div>
    <nav class="cb-dock" aria-label="Turn controls">
      <button type="button" class="btn cb-dock-prev" data-cb="prev" data-busy-key="turn" data-focus-key="cb-prev" aria-label="Previous turn">${glyph('prev', { size: 18 })}<span> Previous</span></button>
      <button type="button" class="btn btn-ghost" data-cb="undo" ${lastAction ? '' : 'disabled'} data-busy-key="undo" title="${esc(undoLbl)}" aria-label="${esc(undoLbl)}">${glyph('undo', { size: 16 })}<span class="cb-hide-sm"> ${esc(undoLbl)}</span></button>
      <button type="button" class="btn btn-ghost" data-cb="effect" data-id="${esc(selected || '')}" aria-label="Add a condition or effect to the selected combatant">${icon('ui.condition', { size: 16 })}<span class="cb-hide-sm"> Effect</span></button>
      <button type="button" class="btn btn-ghost" data-cb="skip" data-busy-key="turn" ${e.status === 'paused' ? 'disabled' : ''} aria-label="Skip this turn (recorded as skipped)">${glyph('next', { size: 16 })}<span class="cb-hide-sm"> Skip</span></button>
      <button type="button" class="btn btn-gold cb-dock-next" data-cb="next" data-busy-key="turn" data-focus-key="cb-next" ${e.status === 'paused' ? 'disabled' : ''}>
        <span>End turn · Next</span> ${glyph('next', { size: 18 })}</button>
    </nav>
  </div>`;
  document.body.classList.toggle('cb-drawer-open', drawer);
}

function rowHTML(p, cur) {
  const h = hpOf(p);
  const st = hpState(p);
  const isCur = cur && cur.id === p.id;
  const fx = effectsOf(p.id).filter((x) => x.effect_type !== 'advantage' && x.effect_type !== 'concentration');
  const adv = advSummary(p.id);
  const conc = concentrationOf(p.id);
  const s = stats(p);
  const inactive = !p.active || (p.joins_round && p.joins_round > E().round);
  const pct = Math.max(0, Math.min(100, (h.cur / Math.max(1, h.max)) * 100));
  const tpct = Math.max(0, Math.min(100 - pct, (h.temp / Math.max(1, h.max)) * 100));
  return `<li class="cb-row cb-${p.kind}${isCur ? ' cb-current' : ''}${selected === p.id ? ' cb-selected' : ''} cb-st-${st}${inactive ? ' cb-inactive' : ''}${p.hidden ? ' cb-is-hidden' : ''}"
      data-pid="${esc(p.id)}" ${isCur ? 'aria-current="step"' : ''}>
    <button type="button" class="cb-row-main" data-cb="select" data-id="${esc(p.id)}" data-focus-key="row:${esc(p.id)}"
      aria-label="${esc(`${pname(p)}, ${p.kind === 'character' ? 'player character' : 'monster'}, Initiative ${p.initiative ?? 'none'}, HP ${h.cur} of ${h.max}${h.temp ? ` plus ${h.temp} temporary` : ''}, ${HP_TEXT[st]}${isCur ? ', current turn' : ''}${p.hidden ? ', hidden from players' : ''}`)}">
      <span class="cb-turn-arrow" aria-hidden="true">${isCur ? '▶' : ''}</span>
      <span class="cb-init" aria-hidden="true">${p.initiative ?? '—'}</span>
      ${avatar(p, 34)}
      <span class="cb-row-body">
        <span class="cb-row-name"><strong>${esc(pname(p))}</strong>
          <span class="cb-kind cb-kind-${p.kind}">${p.kind === 'character' ? 'PC' : 'Monster'}</span>
          ${p.hidden ? `<span class="cb-flag" title="Hidden from players">${glyph('hidden', { size: 14, label: 'Hidden' })}</span>` : ''}
          ${conc ? `<span class="cb-flag cb-flag-conc" title="Concentrating: ${esc(conc.display_name)}">${icon('action.concentration', { size: 14, label: 'Concentrating' })}</span>` : ''}
          ${p.reaction_used ? '<span class="cb-flag cb-flag-react" title="Reaction used">R✕</span>' : ''}
          ${p.legendary_max ? `<span class="cb-flag" title="Legendary Actions ${p.legendary_left}/${p.legendary_max}">${glyph('crown', { size: 14 })}${p.legendary_left}</span>` : ''}
          ${isCur ? '<span class="cb-now">Current turn</span>' : ''}</span>
        <span class="cb-hpline">
          <span class="cb-hpbar" aria-hidden="true"><span class="cb-hpfill" style="width:${pct}%"></span><span class="cb-hptemp" style="left:${pct}%;width:${tpct}%"></span></span>
          <span class="cb-hpnum">${h.form ? `${glyph('heart', { size: 12 })}` : ''}${h.cur}/${h.max}${h.temp ? ` <span class="cb-temp">+${h.temp}</span>` : ''}</span>
          <span class="cb-hpstate cb-hpstate-${st}">${HP_TEXT[st]}</span>
          <span class="cb-ac" title="Armor Class">${glyph('shield', { size: 13 })}${s.ac ?? '—'}${s.acMod ? `<sup>${signed(s.acMod)}</sup>` : ''}</span>
        </span>
        ${h.form ? `<span class="small cb-form">Wild Shape: ${esc(h.form)}</span>` : ''}
        ${fx.length || adv.length ? `<span class="cb-chips">${fx.slice(0, 4).map(chip).join('')}${fx.length > 4 ? `<span class="cb-chip">+${fx.length - 4}</span>` : ''}
          ${adv.map((a) => `<span class="cb-chip cb-chip-${a.net}" title="${a.net === 'advantage' ? 'Advantage' : a.net === 'disadvantage' ? 'Disadvantage' : 'Advantage and disadvantage'}: ${esc(scopeLabel(a.scope))}">${glyph(a.net === 'advantage' ? 'adv' : a.net === 'disadvantage' ? 'dis' : 'round', { size: 13 })}${a.net !== 'normal' ? `<span class="sr-only">${a.net === 'advantage' ? 'Advantage' : 'Disadvantage'}: </span>` : ''}${esc(scopeLabel(a.scope))}${a.net === 'normal' ? ' (both: normal)' : ''}</span>`).join('')}</span>` : ''}
      </span>
    </button>
    <span class="cb-quick">
      <button type="button" class="btn btn-sm btn-bad" data-cb="quick-hp" data-op="damage" data-id="${esc(p.id)}" data-focus-key="qd:${esc(p.id)}" aria-label="Damage ${esc(pname(p))}">−</button>
      <button type="button" class="btn btn-sm btn-good" data-cb="quick-hp" data-op="heal" data-id="${esc(p.id)}" data-focus-key="qh:${esc(p.id)}" aria-label="Heal ${esc(pname(p))}">+</button>
    </span>
  </li>`;
}

function noticesHTML() {
  if (!notices.length) return '';
  const label = (n) => {
    switch (n.kind) {
      case 'expired': return `${n.effect} ended on ${n.target}.`;
      case 'tick': return `${n.effect} on ${n.target}: ${n.remaining} round${n.remaining === 1 ? '' : 's'} left.`;
      case 'save': return `${n.target}: ${String(n.ability).toUpperCase()} save DC ${n.dc} against ${n.effect} (reminder; you decide).`;
      case 'legendary': return `Legendary Action available: ${n.target} (${n.left}/${n.max}).`;
      case 'legendary_reset': return `${n.target} regains its Legendary Action uses.`;
      case 'surprised': return `${n.target}: ${n.text}`;
      case 'reminder': return `${n.title}${n.note ? `: ${n.note}` : ''}`;
      case 'round': return `Round ${n.round} begins.`;
      case 'concentration_at_risk': return `${n.target} is ${n.condition}: Concentration on ${n.effect} ends.`;
      case 'immune': return `${n.target} is immune to ${n.effect} (stat block).`;
      case 'reverted': return n.manual?.length ? `Turn moved back. Check by hand: ${n.manual.map((m) => m.name).join(', ')}.` : 'Turn moved back; effect clocks restored.';
      default: return n.text || '';
    }
  };
  return `<section class="cb-notices" aria-label="Turn notes"><ul>${notices.map((n, i) => `<li class="cb-notice cb-notice-${esc(n.kind)}">
    ${n.kind === 'reminder' ? glyph('bell', { size: 14 }) : n.kind === 'legendary' || n.kind === 'legendary_reset' ? glyph('crown', { size: 14 }) : glyph('bolt', { size: 14 })}
    <span>${esc(label(n))}</span>
    ${n.kind === 'reminder' ? `<button type="button" class="btn btn-sm btn-ghost" data-cb="ack" data-id="${esc(n.reminder_id)}" data-i="${i}">Done</button>` : ''}
    ${n.kind === 'concentration_at_risk' ? `<button type="button" class="btn btn-sm" data-cb="end-effect" data-id="${esc(n.effect_id)}">End concentration</button>` : ''}
    </li>`).join('')}</ul><button type="button" class="btn btn-sm btn-ghost" data-cb="clear-notices">Clear notes</button></section>`;
}

// ---------------------------------------------------------------------------------------------------------------- detail
function detailHTML(p) {
  if (!p) return '<p class="muted">Select a combatant.</p>';
  const h = hpOf(p);
  const st = hpState(p);
  const s = stats(p);
  const fx = effectsOf(p.id);
  const conc = concentrationOf(p.id);
  const adv = advSummary(p.id);
  const isCur = E().current_participant_id === p.id;
  const defenses = p.kind === 'character' ? charDefenses(s.derived) : null;
  return `
    <div class="cb-detail-head">
      ${avatar(p, 48)}
      <div><h2 class="cb-detail-name">${esc(pname(p))}</h2>
        <p class="small muted">${p.kind === 'character' ? `${esc(p.character?.classes || p.character?.class_name || 'Player character')} · level ${p.character?.level ?? ''}`
          : `${esc(p.statblock?.size || '')} ${esc(p.statblock?.creature_type || '')} · CR ${esc(crText(p.statblock?.challenge_rating))}${p.statblock?.rules_version ? ` · ${esc(p.statblock.rules_version)}` : ''}`}
          ${isCur ? ' · <strong class="cb-now">Current turn</strong>' : ''}</p></div>
      <button type="button" class="icon-btn cb-drawer-close" data-cb="close-drawer" aria-label="Close details">✕</button>
    </div>
    <div class="cb-statline">
      <div class="cb-stat"><span class="cb-stat-label">HP</span><span class="cb-stat-val cb-hpstate-${st}">${h.cur}<small>/${h.max}</small></span>${h.temp ? `<span class="cb-temp">+${h.temp} temp</span>` : ''}<span class="small">${HP_TEXT[st]}</span></div>
      <div class="cb-stat"><span class="cb-stat-label">AC</span><span class="cb-stat-val">${s.ac ?? '—'}${s.acMod ? `<small> ${signed(s.acMod)} = ${(s.ac || 0) + s.acMod}</small>` : ''}</span></div>
      <div class="cb-stat"><span class="cb-stat-label">Initiative</span><span class="cb-stat-val">${p.initiative ?? '—'}</span><span class="small" title="Initiative modifier (reference)">mod ${esc(signed(s.init))}</span>
        ${E().status !== 'draft' && E().status !== 'completed' ? `<button type="button" class="btn btn-sm btn-ghost cb-stat-btn" data-cb="correct-init" data-id="${esc(p.id)}" aria-label="Correct the Initiative of ${esc(pname(p))}">Correct</button>` : ''}</div>
      <div class="cb-stat"><span class="cb-stat-label">Speed</span><span class="cb-stat-txt">${esc(s.speed)}</span></div>
      <div class="cb-stat"><span class="cb-stat-label">Passive Perc.</span><span class="cb-stat-val">${s.pp ?? '—'}</span></div>
    </div>
    ${h.form ? `<p class="cb-form-note small">Wild Shape: <strong>${esc(h.form)}</strong> ${h.cur}/${h.max} HP. Damage goes to the form first; normal HP ${h.normal?.current}/${h.normal?.max} stays protected and only the excess carries over.${
      h.expired ? ' <strong class="cb-warn">Duration over:</strong> the form ends after the next change; heal or correct it on the normal form.' : ''}</p>` : ''}
    ${p.kind === 'character' && h.cur <= 0 ? `<p class="cb-down-note small">Down at 0 HP. Death saves are tracked on the character sheet (${p.hp?.death_successes || 0} successes, ${p.hp?.death_failures || 0} failures).</p>` : ''}
    <div class="cb-hp-ctl" role="group" aria-label="Hit points of ${esc(pname(p))}">
      <label class="cb-amount"><span class="sr-only">Amount</span><input type="number" inputmode="numeric" min="0" max="10000" placeholder="0" data-cb-amount="${esc(p.id)}"
        aria-label="Amount of damage or healing for ${esc(pname(p))}" data-focus-key="amount"></label>
      <button type="button" class="btn btn-bad" data-cb="hp" data-op="damage" data-id="${esc(p.id)}" data-busy-key="hp:${esc(p.id)}" data-focus-key="hp-damage">${icon('action.damage', { size: 16 })} Damage</button>
      <button type="button" class="btn btn-good" data-cb="hp" data-op="heal" data-id="${esc(p.id)}" data-busy-key="hp:${esc(p.id)}" data-focus-key="hp-heal">${icon('action.heal', { size: 16 })} Heal</button>
      <button type="button" class="btn btn-ghost" data-cb="hp" data-op="temp" data-id="${esc(p.id)}" data-busy-key="hp:${esc(p.id)}">${icon('ui.temp-hp', { size: 16 })} Temp HP</button>
      <button type="button" class="btn btn-ghost" data-cb="hp-set" data-id="${esc(p.id)}">Correct…</button>
    </div>
    <p class="cb-preview small" data-cb-preview aria-live="polite"></p>
    ${conc ? concentrationHTML(conc) : ''}
    <section class="cb-dsec"><h3 class="cb-dsec-title">Conditions and effects <span class="count">${fx.filter((x) => x.effect_type !== 'concentration').length}</span></h3>
      <ul class="cb-fx-list">${fx.filter((x) => x.effect_type !== 'concentration').map((x) => `<li>${chip(x)}
        <span class="small muted">${x.application === 'applied' ? 'applied to the tracker' : 'reminder'}${x.source_participant_id ? ` · from ${esc(pname(P(x.source_participant_id)))}` : ''}${x.concentration_id ? ' · concentration' : ''}</span>
        <button type="button" class="btn btn-sm btn-ghost" data-cb="end-effect" data-id="${esc(x.id)}" aria-label="Remove ${esc(x.display_name)}">Remove</button></li>`).join('') || '<li class="muted small">None.</li>'}</ul>
      ${adv.length ? `<p class="small">${adv.map((a) => `<span class="cb-adv cb-adv-${a.net}">${esc(a.net === 'normal' ? 'Normal (Advantage and Disadvantage cancel)' : a.net === 'advantage' ? 'Advantage' : 'Disadvantage')}: ${esc(scopeLabel(a.scope))}${a.detail ? ` (${esc(a.detail)})` : ''}${a.target ? ` against ${esc(pname(P(a.target)))}` : ''}</span>`).join('<br>')}</p>` : ''}
      <div class="cb-btns">
        <button type="button" class="btn btn-sm" data-cb="effect" data-tab="condition" data-id="${esc(p.id)}" data-focus-key="add-cond">${icon('ui.condition', { size: 14 })} Condition</button>
        <button type="button" class="btn btn-sm" data-cb="effect" data-tab="custom" data-id="${esc(p.id)}">Effect</button>
        <button type="button" class="btn btn-sm" data-cb="adv" data-mode="advantage" data-id="${esc(p.id)}" data-focus-key="add-adv">${glyph('adv', { size: 14 })} Advantage</button>
        <button type="button" class="btn btn-sm" data-cb="adv" data-mode="disadvantage" data-id="${esc(p.id)}">${glyph('dis', { size: 14 })} Disadvantage</button>
        <button type="button" class="btn btn-sm btn-ghost" data-cb="effect" data-tab="concentration" data-id="${esc(p.id)}">${icon('action.concentration', { size: 14 })} Concentration</button>
      </div>
      ${defenses ? `<p class="small muted">${defenses}</p>` : ''}
    </section>
    <section class="cb-dsec"><h3 class="cb-dsec-title">Turn resources</h3>
      <div class="cb-btns">
        <button type="button" class="btn btn-sm ${p.reaction_used ? '' : 'btn-ghost'}" data-cb="reaction" data-id="${esc(p.id)}" aria-pressed="${p.reaction_used}">${icon('ui.reaction', { size: 14 })} Reaction: ${p.reaction_used ? 'used' : 'available'}</button>
        ${p.legendary_max ? legendaryHTML(p) : ''}
      </div>
    </section>
    <section class="cb-dsec"><h3 class="cb-dsec-title">Notes</h3>
      <textarea rows="2" class="cb-notes" data-cb-pnotes="${esc(p.id)}" maxlength="4000" aria-label="Notes about ${esc(pname(p))} (DM only)" placeholder="DM-only notes">${esc(p.notes || '')}</textarea></section>
    <div class="cb-btns cb-detail-foot">
      ${p.kind === 'character' && p.character_id ? `<a class="btn btn-sm btn-ghost" href="#/c/${esc(p.character_id)}">Open sheet</a>` : ''}
      <button type="button" class="btn btn-sm btn-ghost" data-cb="toggle-hidden" data-id="${esc(p.id)}">${glyph(p.hidden ? 'shown' : 'hidden', { size: 14 })} ${p.hidden ? 'Reveal to players' : 'Hide from players'}</button>
      ${p.kind === 'monster' ? `<button type="button" class="btn btn-sm btn-ghost" data-cb="state" data-state="${p.defeated ? 'restore' : 'defeat'}" data-id="${esc(p.id)}">${glyph('skull', { size: 14 })} ${p.defeated ? 'Restore' : 'Mark defeated'}</button>` : ''}
      <button type="button" class="btn btn-sm btn-ghost" data-cb="state" data-state="${p.active ? 'deactivate' : 'activate'}" data-id="${esc(p.id)}">${p.active ? 'Skip its turns' : 'Back in the order'}</button>
      <button type="button" class="btn btn-sm btn-ghost" data-cb="rename" data-id="${esc(p.id)}" ${p.kind === 'character' ? 'hidden' : ''}>Rename</button>
      <button type="button" class="btn btn-sm btn-bad" data-cb="remove" data-id="${esc(p.id)}">Remove</button>
    </div>
    ${p.kind === 'character' && p.character_id ? `<section class="cb-dsec cb-af-sec"><h3 class="cb-dsec-title">Active features</h3><div data-cb-active-features="${esc(p.character_id)}">${
      featureCache[p.character_id] ? compactActiveFeaturesHTML(featureCache[p.character_id])
        : `<button type="button" class="btn btn-sm" data-cb="load-features" data-id="${esc(p.character_id)}">Show actions, reactions and uses</button>`}</div></section>` : ''}
    ${p.statblock_id ? `<section class="cb-dsec cb-statblock-sec"><h3 class="cb-dsec-title">Stat block</h3><div data-cb-statblock="${esc(p.statblock_id)}">${statblockCache[p.statblock_id] ? statblockHTML(statblockCache[p.statblock_id].snapshot, { compact: true }) : '<button type="button" class="btn btn-sm" data-cb="load-statblock" data-id="' + esc(p.statblock_id) + '">Show stat block</button>'}</div></section>` : ''}`;
}
const statblockCache = {};
// linked characters' active features (class features and options, lineage traits, feats, uses): loaded on request with ONE
// get_character_reads (server-cached per revision), re-read only for that character after one of its build changes
const featureCache = {};
const FEATURE_READS = ['get_character_class_features', 'get_character_resources', 'get_character_feats', 'get_character_lineage'];
// both hold data the signed-in DM may see (stat block snapshots, character features): forget them on unmount / user switch
function clearDetailCaches() { for (const c of [statblockCache, featureCache]) for (const k of Object.keys(c)) delete c[k]; }
onUserCachesCleared(clearDetailCaches);

function charDefenses(d) {
  if (!d) return '';
  const parts = [];
  if (d.resistances?.length) parts.push(`Resistant: ${d.resistances.map((r) => r.damage_type).join(', ')}`);
  if (d.immunities?.length) parts.push(`Immune: ${d.immunities.map((r) => r.damage_type || r).join(', ')}`);
  if (d.condition_immunities?.length) parts.push(`Condition immunities: ${d.condition_immunities.map((r) => r.condition || r).join(', ')}`);
  const senses = Object.entries(d.senses || {}).map(([k, v]) => `${k} ${v?.value ?? v} ft`);
  if (senses.length) parts.push(`Senses: ${senses.join(', ')}`);
  return esc(parts.join(' · '));
}

function concentrationHTML(c) {
  const linked = (data.effects || []).filter((x) => x.active && x.concentration_id === c.id);
  return `<section class="cb-dsec cb-conc" aria-label="Concentration">
    <h3 class="cb-dsec-title">${icon('action.concentration', { size: 16 })} Concentrating: ${esc(c.display_name)}</h3>
    <p class="small muted">${linked.length ? `Linked: ${linked.map((x) => `${esc(x.display_name)} on ${esc(pname(P(x.target_participant_id)))}`).join(', ')}` : 'No linked effects.'} ${esc(durationText(c))}</p>
    ${(c.pending_checks || []).map((k) => `<div class="cb-conc-check" role="group" aria-label="Concentration check">
      <span>Took ${k.damage} damage: <strong>CON save DC ${k.dc}</strong></span>
      <button type="button" class="btn btn-sm btn-good" data-cb="conc" data-result="success" data-id="${esc(c.id)}" data-check="${esc(k.id)}">Success</button>
      <button type="button" class="btn btn-sm btn-bad" data-cb="conc" data-result="failure" data-id="${esc(c.id)}" data-check="${esc(k.id)}">Failure</button></div>`).join('')}
    <button type="button" class="btn btn-sm btn-ghost" data-cb="end-effect" data-id="${esc(c.id)}">End concentration</button></section>`;
}

function legendaryHTML(p) {
  const acts = statblockCache[p.statblock_id]?.snapshot?.legendary?.actions || [];
  return `<span class="cb-leg" role="group" aria-label="Legendary Actions ${p.legendary_left} of ${p.legendary_max}">${glyph('crown', { size: 14 })}
    <span class="cb-pips">${Array.from({ length: p.legendary_max }, (_, i) => `<span class="cb-pip${i < p.legendary_left ? ' on' : ''}"></span>`).join('')}</span>
    <span class="small">${p.legendary_left}/${p.legendary_max}</span>
    <button type="button" class="btn btn-sm" data-cb="legendary" data-delta="-1" data-id="${esc(p.id)}" ${p.legendary_left ? '' : 'disabled'}>Spend 1</button>
    ${acts.filter((a) => (a.cost || 1) > 1).map((a) => `<button type="button" class="btn btn-sm btn-ghost" data-cb="legendary" data-delta="-${a.cost}" data-action="${esc(a.name)}" data-id="${esc(p.id)}" ${p.legendary_left >= a.cost ? '' : 'disabled'}>${esc(a.name)} (${a.cost})</button>`).join('')}
    <button type="button" class="btn btn-sm btn-ghost" data-cb="legendary" data-delta="1" data-id="${esc(p.id)}" ${p.legendary_left < p.legendary_max ? '' : 'disabled'} aria-label="Give one use back">+1</button></span>`;
}

// ================================================================================================================ summary
async function renderSummary() {
  const e = E();
  root.innerHTML = `<div class="cb-summary">${spinner()}</div>`;
  const my = seq;
  let s;
  try { s = await api.getSummary(e.id); } catch (err) { if (root) root.innerHTML = errorBox(err); return; }
  if (my !== seq || !root) return;
  const sm = s.summary || {};
  const ps = sm.participants || [];
  root.innerHTML = `<div class="cb-summary">
    <header class="cb-head"><div><span class="cb-kicker">${glyph('flag', { size: 14 })} <a href="#/combat">Combat Builder</a> · Finished encounter</span>
      <h1 class="cb-title">${esc(e.name)}</h1><p class="small muted">${esc(e.campaign_name)} · ${esc(e.ruleset)} rules · finished ${e.completed_at ? new Date(e.completed_at).toLocaleString() : ''}</p></div>
      <div class="cb-head-actions"><button type="button" class="btn btn-gold" data-cb="duplicate" data-id="${esc(e.id)}">Run again (duplicate)</button>
        ${e.archived_at ? '' : `<button type="button" class="btn btn-ghost" data-cb="archive" data-id="${esc(e.id)}" data-on="1">Archive</button>`}</div></header>
    <div class="cb-sum-stats">
      <div class="cb-stat"><span class="cb-stat-label">Rounds</span><span class="cb-stat-val">${sm.rounds ?? e.round}</span></div>
      <div class="cb-stat"><span class="cb-stat-label">Duration</span><span class="cb-stat-txt">${fmtTime(sm.duration_seconds)}</span></div>
      <div class="cb-stat"><span class="cb-stat-label">Damage dealt</span><span class="cb-stat-val">${sm.damage_total ?? 0}</span></div>
      <div class="cb-stat"><span class="cb-stat-label">Healing</span><span class="cb-stat-val">${sm.healing_total ?? 0}</span></div>
      <div class="cb-stat"><span class="cb-stat-label">Effects</span><span class="cb-stat-val">${sm.effects_applied ?? 0}</span></div>
    </div>
    <div class="cb-builder-grid">
      <section class="cb-panel"><h2 class="cb-section-title">Participants</h2>
        <table class="cb-init-table"><thead><tr><th scope="col">Combatant</th><th scope="col">Final HP</th><th scope="col">Outcome</th></tr></thead>
        <tbody>${ps.map((p) => `<tr><th scope="row">${esc(p.name)} <span class="small muted">${p.kind === 'character' ? 'PC' : 'Monster'}</span></th><td>${p.hp ?? '—'}/${p.max ?? '—'}</td>
          <td>${p.removed ? 'Removed' : p.kind === 'monster' ? (p.defeated ? 'Defeated' : 'Survived') : (p.down ? 'Down' : 'Standing')}</td></tr>`).join('')}</tbody></table>
        ${sm.conditions?.length ? `<p class="small">Conditions used: ${esc(sm.conditions.join(', '))}</p>` : ''}
        ${sm.carried_effects?.length ? `<p class="small">Moved to the character sheet: ${esc(sm.carried_effects.map((x) => `${x.name} (${x.target})`).join(', '))}</p>` : ''}
        ${sm.kept_effects?.length ? `<p class="small">Still running after the fight (track them yourself): ${esc(sm.kept_effects.map((x) => `${x.name} (${x.target})`).join(', '))}</p>` : ''}
      </section>
      <aside class="cb-side">
        <section class="cb-panel"><h2 class="cb-section-title">DM notes</h2>
          <textarea rows="4" data-cb-finish-notes maxlength="8000" aria-label="Notes about this fight">${esc(e.finish_notes || '')}</textarea>
          <button type="button" class="btn btn-sm" data-cb="save-finish-notes">Save notes</button></section>
        <section class="cb-panel"><h2 class="cb-section-title">Major events</h2><ul class="cb-hist">${(sm.major_events || []).map((x) => `<li><span class="small muted">R${x.round ?? ''}</span> ${esc(eventText(x))}</li>`).join('') || '<li class="muted small">None.</li>'}</ul></section>
      </aside>
    </div>
    <section class="cb-panel"><h2 class="cb-section-title">${glyph('history', { size: 18 })} History</h2><ul class="cb-hist">${(s.history || []).map(histItem).join('')}</ul></section>
  </div>`;
}

const KIND = { damage: 'damage', heal: 'healing', temp_hp: 'Temporary HP', hp_set: 'HP correction', effect_added: 'effect', effect_ended: 'effect removal',
  turn_advanced: 'turn', turn_jumped: 'turn choice', reaction: 'Reaction', legendary: 'Legendary Action', concentration_failed: 'concentration failure',
  concentration_ended: 'concentration end', initiative_rolled: 'Initiative roll', initiative_set: 'Initiative', initiative_changed: 'Initiative',
  initiative_cleared: 'clearing Initiative', participant_defeat: 'defeat', participant_restore: 'restore', participant_deactivate: 'skip', participant_activate: 'return' };
const kindLabel = (k) => KIND[k] || k.replace(/_/g, ' ');
function eventText(x) {
  const who = x.participant ? `${x.participant}: ` : '';
  if (x.kind === 'damage') return `${who}took ${x.amount ?? x.details?.amount} damage`;
  if (x.kind === 'heal') return `${who}healed ${x.amount ?? x.details?.amount}`;
  if (x.kind === 'participant_defeat') return `${who}defeated`;
  if (x.kind === 'participants_added') return 'Combatants joined';
  if (x.kind === 'participant_revealed') return `${who}revealed`;
  if (x.kind === 'concentration_failed') return `${who}lost concentration`;
  return `${who}${kindLabel(x.kind)}`;
}
function histItem(x) {
  const d = x.details || {};
  let t = eventText({ ...x, amount: d.amount });
  if (x.kind === 'turn_advanced') t = `Turn → ${x.participant || ''}`;
  if (x.kind === 'effect_added') t = `${x.participant ? `${x.participant}: ` : ''}${d.name || 'effect'} added`;
  if (x.kind === 'hp_set') t = `${x.participant}: HP set (${d.reason || ''})`;
  if (x.kind === 'undo') t = `Undo of ${kindLabel(d.kind || '')}`;
  t = t.charAt(0).toUpperCase() + t.slice(1);
  return `<li class="${x.undone ? 'cb-undone' : ''}"><span class="small muted">R${x.round ?? 0} · ${new Date(x.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
    ${esc(t)}${x.undone ? ' <span class="small muted">(undone)</span>' : ''}
    ${x.undoable && isLive() ? `<button type="button" class="btn btn-sm btn-ghost" data-cb="undo-event" data-id="${x.id}">Undo</button>` : ''}</li>`;
}

// ================================================================================================================ events
async function onClick(ev) {
  const b = ev.target.closest('[data-cb]');
  if (!b || !root?.contains(b)) return;
  const id = b.dataset.id;
  const enc = E()?.id;
  switch (b.dataset.cb) {
    case 'home': return renderHome(++seq);
    case 'reload': return root.dataset.encounter ? openEncounter(root.dataset.encounter, ++seq) : renderHome(++seq);
    case 'new': return newEncounter();
    case 'duplicate': {
      const r = await api.duplicateEncounter(id).catch((err) => { toast(err.message, 'bad'); return null; });
      if (r) { toast('Duplicated as a new prepared encounter.', 'good'); go(`#/combat/e/${r.encounter.id}`); }
      return undefined;
    }
    case 'archive':
      try { await api.archiveEncounter(id, b.dataset.on === '1'); toast(b.dataset.on === '1' ? 'Archived.' : 'Restored.'); } catch (err) { toast(err.message, 'bad'); }
      return root.dataset.encounter ? reload() : renderHome(++seq);
    case 'delete-draft':
      if (!(await confirmDialog('Delete this prepared encounter? Started or finished encounters are archived instead.', { title: 'Delete draft', okLabel: 'Delete', danger: true }))) return undefined;
      try { await api.deleteDraft(enc); go('#/combat'); } catch (err) { toast(err.message, 'bad'); }
      return undefined;
    case 'edit-encounter': return editEncounter();
    case 'add-party': return addParty();
    case 'add-monsters': return openMonsterLibrary({ encounter: E(), onAdded: async (r) => { notices = r?.ruleset_mismatch ? [{ kind: 'text', text: `${r.name} uses the ${r.rules_version} rules; this encounter uses ${E().ruleset}. Shown with a badge, never mixed silently.` }] : notices; await reload(); } });
    case 'add-custom': return addCustom();
    case 'roll-monsters': return mutate('roll', () => api.rollInitiative(enc, null, { reroll: false, fixed: !!E().settings.fixed_initiative }), { quiet: true }).then(() => reload());
    case 'roll-one': return P(id)?.kind === 'monster'
      ? mutate(`roll:${id}`, () => api.rollInitiative(enc, [id], { fixed: !!E().settings.fixed_initiative }), { quiet: true }).then(() => reload())
      : undefined;   // a player's Initiative is the total the player rolled: typed, never rolled here
    case 'correct-init': return correctInitiative(id);
    case 'sort': return mutate('sort', () => api.sortInitiative(enc), { quiet: true }).then(() => reload());
    case 'clear-init':
      if (!(await confirmDialog('Clear every Initiative value?', { okLabel: 'Clear' }))) return undefined;
      return mutate('clear', () => api.clearInitiative(enc), { quiet: true }).then(() => reload());
    case 'move': return moveRow(id, Number(b.dataset.dir));
    case 'remove': return removeParticipant(id);
    case 'start': return startFlow();
    case 'reminder-new': return editReminder(null);
    case 'reminder-edit': return editReminder((data.reminders || []).find((r) => r.id === id));
    case 'reminders': return remindersModal();
    case 'select': return selectRow(id, true);
    case 'close-drawer': drawer = false; repaint(); return focusByKey(`row:${selected}`, root);
    case 'next': return nextTurn();
    case 'skip': return nextTurn('skip');
    case 'prev': return previousTurn();
    case 'pause': return mutate('pause', () => api.pauseCombat(enc), { quiet: true }).then(() => announce('Combat paused.'));
    case 'resume': return mutate('resume', () => api.resumeCombat(enc), { quiet: true }).then(() => announce('Combat resumed.'));
    case 'finish': return finishFlow();
    case 'undo': return lastAction ? undoEvent(lastAction.event) : undefined;
    case 'undo-event': return undoEvent(Number(id));
    case 'history': return historyModal();
    case 'help': return helpModal();
    case 'goto': return gotoModal();
    case 'bulk': return bulkModal();
    case 'hp': return applyHpFromDetail(id, b.dataset.op);
    case 'hp-set': return correctHp(id);
    case 'quick-hp': return quickHp(b, id, b.dataset.op);
    case 'effect': return effectModal(id || selected, b.dataset.tab || 'condition');
    case 'adv': return advModal(id, b.dataset.mode);
    case 'end-effect': return mutate(`fx:${id}`, () => api.endEffect(id), { after: 'effect removal' });
    case 'conc': return mutate(`conc:${id}`, () => api.resolveConcentration(id, b.dataset.check, b.dataset.result), { after: 'concentration result' })
      .then((r) => { if (r?.result === 'failure') announce('Concentration ended.'); });
    case 'reaction': return mutate(`react:${id}`, () => api.setReaction(id, !P(id).reaction_used), { after: 'Reaction' });
    case 'legendary': return mutate(`leg:${id}`, () => api.spendLegendary(id, Number(b.dataset.delta), b.dataset.action || null), { after: 'Legendary Action' });
    case 'toggle-hidden': return mutate(`hide:${id}`, () => api.updateParticipant(id, { hidden: !P(id).hidden }), { quiet: true });
    case 'state': return mutate(`state:${id}`, () => api.setParticipantState(id, b.dataset.state), { after: b.dataset.state });
    case 'rename': return renameParticipant(id);
    case 'load-statblock': return loadStatblock(id);
    case 'load-features': return loadFeatures(id);
    case 'ack': {
      const i = Number(b.dataset.i);
      notices.splice(i, 1);
      repaint();
      return api.ackReminder(id).catch(() => {});
    }
    case 'clear-notices': notices = []; return repaint();
    case 'save-finish-notes': return mutate('fnotes', () => api.updateEncounter(enc, { finish_notes: $('[data-cb-finish-notes]', root).value }), { quiet: true }).then(() => toast('Notes saved.', 'good'));
    default: return undefined;
  }
}

async function onChange(ev) {
  const t = ev.target;
  if (t.matches('[data-cb-camp]')) { store.set('campaign', t.value); return renderHome(++seq); }
  if (t.matches('[data-cb-archived]')) { store.set('archived', t.checked ? '1' : '0'); return renderHome(++seq); }
  const enc = E()?.id;
  if (t.matches('[data-cb-init]')) return saveInit(t);
  if (t.matches('[data-cb-imode]')) {
    const p = P(t.dataset.cbImode);
    if (p) { initModes[modeKey(p)] = t.value; repaint(); focusByKey(t.value === 'manual' ? `init:${p.id}` : `roll:${p.id}`, root); }
    return undefined;
  }
  if (t.matches('[data-cb-flag]')) return mutate(`flag:${t.dataset.id}`, () => api.updateParticipant(t.dataset.id, { [t.dataset.cbFlag]: t.checked }), { quiet: true });
  if (t.matches('[data-cb-setting]')) {
    const v = t.type === 'checkbox' ? t.checked : t.value;
    return mutate('setting', () => api.updateEncounter(enc, { settings: { [t.dataset.cbSetting]: v } }), { quiet: true }).then((r) => { if (r) data = r; });
  }
  if (t.matches('[data-cb-notes]')) return mutate('notes', () => api.updateEncounter(enc, { dm_notes: t.value }), { quiet: true }).then((r) => { if (r) { data = r; toast('DM notes saved.', 'good'); } });
  if (t.matches('[data-cb-pnotes]')) return mutate(`pnotes:${t.dataset.cbPnotes}`, () => api.updateParticipant(t.dataset.cbPnotes, { notes: t.value }), { quiet: true });
  return undefined;
}

function onInput(ev) {
  const t = ev.target;
  if (t.matches('[data-cb-amount]')) return showPreview(t.dataset.cbAmount, Number(t.value));
  if (t.matches('[data-cb-find]')) {
    const q = t.value.trim().toLowerCase();
    $$('.cb-row', root).forEach((li) => { li.hidden = !!q && !pname(P(li.dataset.pid)).toLowerCase().includes(q); });
  }
  return undefined;
}

function onFieldKey(ev) {
  const t = ev.target;
  if (t.matches('[data-cb-init]') && ev.key === 'Enter') {   // save, then the next combatant still missing a value
    ev.preventDefault();
    const all = $$('[data-cb-init]', root);
    const next = all.slice(all.indexOf(t) + 1).find((x) => x.value.trim() === '') || all.find((x) => x !== t && x.value.trim() === '');
    const nextKey = next?.dataset.focusKey;
    saveInit(t).then((ok) => { if (ok) focusByKey(nextKey || 'cb-start', root); });
    return;
  }
  if (t.matches('[data-cb-amount]') && ev.key === 'Enter') {
    ev.preventDefault();
    const op = ev.shiftKey ? 'heal' : (t.dataset.op || 'damage');
    delete t.dataset.op;
    applyHpFromDetail(t.dataset.cbAmount, op);
  }
  if (t.matches('[data-cb-amount]') && ev.key === 'Escape') { t.value = ''; delete t.dataset.op; showPreview(t.dataset.cbAmount, 0); }
}

// ---------------------------------------------------------------------------------------------------------------- builder actions
async function editEncounter() {
  const e = E();
  const m = openModal({
    title: 'Encounter details',
    body: `<form class="form-grid" data-f>
      <label class="field span-2"><span>Name</span><input name="name" maxlength="120" value="${esc(e.name)}"></label>
      <label class="field"><span>Rules</span><select name="ruleset"><option value="2024" ${e.ruleset === '2024' ? 'selected' : ''}>2024 (SRD 5.2.1)</option><option value="2014" ${e.ruleset === '2014' ? 'selected' : ''}>2014 (SRD 5.1)</option><option value="campaign">Campaign default</option></select></label>
      <label class="cb-toggle"><input type="checkbox" name="is_template" ${e.is_template ? 'checked' : ''}> Keep as a reusable template</label>
      <label class="field span-2"><span>Description</span><textarea name="description" rows="3" maxlength="4000">${esc(e.description)}</textarea></label></form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Save</button>',
  });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const f = $('[data-f]', m.el);
    const patch = { name: f.name.value, description: f.description.value, is_template: f.is_template.checked };
    if (f.ruleset.value !== e.ruleset) patch.ruleset = f.ruleset.value;
    try { data = await api.updateEncounter(e.id, patch, e.rev); m.close(); repaint(); } catch (err) { toast(err.message, 'bad'); if (api.isConflict(err)) { m.close(); reload(); } }
  });
}

async function addParty() {
  const e = E();
  const { data: chars, error } = await supabase.from('characters').select('id, name, level, class_name, portrait_url, dexterity, initiative_bonus, hp_current, hp_max')
    .eq('campaign_id', e.campaign_id).order('name');
  if (error) { toast('The party could not be loaded.', 'bad'); return; }
  const inside = new Set(charIds(data));
  const m = openModal({
    title: 'Add party',
    body: `<p class="small muted">Characters of ${esc(e.campaign_name)}. Their HP stays on the character sheet; the tracker reads and changes the real value.</p>
      <ul class="cb-pick">${chars.map((c) => `<li><label class="cb-toggle"><input type="checkbox" value="${esc(c.id)}" ${inside.has(c.id) ? 'disabled checked' : 'checked'}>
        <strong>${esc(c.name)}</strong> <span class="small muted">level ${c.level} ${esc(c.class_name)} · HP ${c.hp_current}/${c.hp_max}${inside.has(c.id) ? ' · already in' : ''}</span></label></li>`).join('') || '<li class="muted">No characters in this campaign.</li>'}</ul>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Add selected</button>',
  });
  $('[data-ok]', m.el).addEventListener('click', async (ev) => {
    const ids = $$('input[type=checkbox]:checked:not(:disabled)', m.el).map((x) => x.value);
    if (!ids.length) { m.close(); return; }
    const okBtn = ev.currentTarget; okBtn.disabled = true;
    // the sheet's Initiative modifier: DEX modifier + misc bonus + item / feature bonus (derived stats, cached server read)
    const mods = {};
    await Promise.all(ids.map(async (cid) => {
      const c = chars.find((x) => x.id === cid);
      let d = null;
      try { d = await api.characterSummary(cid); } catch { /* the stored values below */ }
      const dex = d?.abilities?.dex?.score ?? c.dexterity;
      mods[cid] = { initiative_mod: Math.floor((dex - 10) / 2) + (c.initiative_bonus || 0) + (Number(d?.initiative?.bonus) || 0), dexterity: dex };
    }));
    try {
      const r = await api.addCharacters(e.id, ids, { mods });
      m.close();
      if (r.skipped?.length) toast(`${r.skipped.length} not added: ${r.skipped.map((s) => s.name || s.reason).join(', ')}`);
      await reload();
    } catch (err) { toast(err.message, 'bad'); okBtn.disabled = false; }
  });
}

function addCustom() {
  const m = openModal({
    title: 'Typed-in combatant',
    body: `<p class="small muted">A quick stand-in for this encounter only (no catalog entry). For a reusable creature use the Monster Library → New homebrew creature.</p>
      <form class="form-grid" data-f>
      <label class="field span-2"><span>Name</span><input name="name" maxlength="100" required></label>
      <label class="field"><span>Hit points</span><input name="hp" type="number" min="1" max="5000" required></label>
      <label class="field"><span>Armor Class</span><input name="ac" type="number" min="0" max="50" required></label>
      <label class="field"><span>Initiative modifier</span><input name="init" type="number" min="-10" max="20" value="0"></label>
      <label class="field"><span>XP (optional)</span><input name="xp" type="number" min="0"></label>
      <label class="cb-toggle span-2"><input type="checkbox" name="hidden"> Hidden from players</label></form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Add</button>',
  });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const f = $('[data-f]', m.el);
    try {
      await api.addCustom(E().id, { name: f.name.value, hp: Number(f.hp.value), ac: f.ac.value === '' ? null : Number(f.ac.value), initiative_mod: Number(f.init.value) || 0,
        xp: f.xp.value === '' ? null : Number(f.xp.value), hidden: f.hidden.checked });
      m.close();
      await reload();
    } catch (err) { toast(err.message, 'bad'); }
  });
}

async function moveRow(pid, dir) {
  const list = data.participants.filter((p) => !p.removed).sort((a, b) => (a.order ?? 9e9) - (b.order ?? 9e9)).map((p) => p.id);
  const i = list.indexOf(pid);
  const j = i + dir;
  if (i < 0 || j < 0 || j >= list.length) return;
  [list[i], list[j]] = [list[j], list[i]];
  await mutate('order', () => api.reorder(E().id, list, isLive() ? 'Moved in the order' : null, isLive() ? E().turn_rev : null), { quiet: true });
  await reload();
  focusByKey(`init:${pid}`, root);
}

async function removeParticipant(pid) {
  const p = P(pid);
  const live = isLive();
  const msg = live ? `Remove ${pname(p)} from the combat? It leaves the turn order; its history stays.${p.kind === 'character' ? ' The character itself is not changed.' : ''}`
    : `Remove ${pname(p)} from this encounter?`;
  if (!(await confirmDialog(msg, { title: 'Remove combatant', okLabel: 'Remove', danger: true }))) return;
  await mutate(`state:${pid}`, () => api.setParticipantState(pid, 'remove'), { quiet: true });
  if (selected === pid) selected = null;
  await reload();
}

async function startFlow() {
  const e = E();
  let r;
  try { r = await api.startCombat(e.id); } catch (err) { toast(err.message, 'bad'); if (err.hint === 'initiative') $('.cb-init-input[value=""]', root)?.focus(); return; }
  if (r?.needs_tie_review) { await reload(); return tieReview(r.ties); }
  afterTurnResult(r, 'Round 1');
  await reload();
}

function tieReview(ties) {
  const groups = ties.map((t) => ({ init: t.initiative, ids: [...t.participants] }));
  const draw = (m) => {
    $('[data-ties]', m.el).innerHTML = groups.map((g, gi) => `<div class="cb-tie"><h3 class="cb-dsec-title">Initiative ${g.init}</h3><ol>${g.ids.map((pid, i) => `<li>
      <span>${esc(pname(P(pid)))} <span class="small muted">${P(pid)?.kind === 'character' ? 'player' : 'monster'} · mod ${signed(P(pid)?.initiative_mod)} · DEX ${P(pid)?.tiebreak}</span></span>
      <button type="button" class="icon-btn" data-up="${gi}:${i}" ${i === 0 ? 'disabled' : ''} aria-label="Move ${esc(pname(P(pid)))} up">▲</button></li>`).join('')}</ol></div>`).join('');
  };
  const m = openModal({
    title: 'Ties in the Initiative order',
    body: `<p class="small">The players decide the order among their tied characters, you decide among monsters and between a monster and a character.
      The default below puts the higher Initiative modifier first, then the higher Dexterity, then characters. Change it if needed.</p><div data-ties></div>`,
    footer: '<button type="button" class="btn" data-close>Back</button><button type="button" class="btn btn-gold" data-ok>Accept order and start</button>',
  });
  draw(m);
  m.el.addEventListener('click', (ev) => {
    const u = ev.target.closest('[data-up]');
    if (!u) return;
    const [gi, i] = u.dataset.up.split(':').map(Number);
    const g = groups[gi];
    [g.ids[i - 1], g.ids[i]] = [g.ids[i], g.ids[i - 1]];
    draw(m);
  });
  $('[data-ok]', m.el).addEventListener('click', async (ev) => {
    const okBtn = ev.currentTarget; okBtn.disabled = true;
    try {
      const order = data.participants.filter((p) => !p.removed).sort((a, b) => (a.order ?? 9e9) - (b.order ?? 9e9)).map((p) => p.id);
      for (const g of groups) {   // within each tie group, the order chosen here
        const pos = g.ids.map((pid) => order.indexOf(pid)).sort((a, b) => a - b);
        pos.forEach((at, k) => { order[at] = g.ids[k]; });
      }
      await api.reorder(E().id, order);
      const r = await api.startCombat(E().id, true);
      m.close();
      afterTurnResult(r, 'Round 1');
      await reload();
    } catch (err) { toast(err.message, 'bad'); okBtn.disabled = false; }
  });
}

function editReminder(r) {
  const m = openModal({
    title: r ? 'Edit reminder' : 'New reminder',
    body: `<form class="form-grid" data-f>
      <label class="field"><span>Kind</span><select name="kind">${[['lair', 'Lair action'], ['hazard', 'Hazard'], ['reinforcement', 'Reinforcements'], ['environment', 'Environment'], ['custom', 'Custom']]
        .map(([k, l]) => `<option value="${k}" ${r?.kind === k ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
      <label class="field"><span>Title</span><input name="title" maxlength="120" value="${esc(r?.title || '')}" placeholder="Lair Action"></label>
      <label class="field"><span>Round (empty = every round)</span><input name="round" type="number" min="1" value="${r?.trigger_round ?? ''}"></label>
      <label class="field"><span>Repeat every … rounds</span><input name="repeat" type="number" min="1" value="${r?.repeat_every ?? ''}"></label>
      <label class="field"><span>At Initiative count (e.g. 20)</span><input name="init" type="number" min="-20" max="60" value="${r?.trigger_initiative ?? ''}"></label>
      <label class="cb-toggle"><input type="checkbox" name="hidden" ${r?.hidden !== false ? 'checked' : ''}> DM only</label>
      <label class="cb-toggle"><input type="checkbox" name="active" ${r?.active !== false ? 'checked' : ''}> Active</label>
      <label class="field span-2"><span>Note</span><textarea name="note" rows="2" maxlength="2000">${esc(r?.note || '')}</textarea></label></form>
      <p class="small muted">A reminder appears in the turn notes when the turn passes its round or Initiative count. Nothing is applied automatically.</p>`,
    footer: `${r ? '<button type="button" class="btn btn-bad" data-del>Delete</button>' : ''}<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Save</button>`,
  });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const f = $('[data-f]', m.el);
    const n = (x) => (x.value === '' ? null : Number(x.value));
    try {
      await api.saveReminder(E().id, { id: r?.id, kind: f.kind.value, title: f.title.value, note: f.note.value, trigger_round: n(f.round), repeat_every: n(f.repeat),
        trigger_initiative: n(f.init), hidden: f.hidden.checked, active: f.active.checked });
      m.close();
      await reload();
    } catch (err) { toast(err.message, 'bad'); }
  });
  $('[data-del]', m.el)?.addEventListener('click', async () => { try { await api.deleteReminder(r.id); m.close(); await reload(); } catch (err) { toast(err.message, 'bad'); } });
}

function remindersModal() {
  const m = openModal({ title: 'Round and lair reminders', body: `${remindersHTML(false)}<button type="button" class="btn btn-sm" data-new>+ Reminder</button>`,
    footer: '<button type="button" class="btn" data-close>Close</button>' });
  $('[data-new]', m.el).addEventListener('click', () => { m.close(); editReminder(null); });
}

// ---------------------------------------------------------------------------------------------------------------- live actions
function selectRow(pid, openDrawer = false) {
  selected = pid;
  if (openDrawer && window.matchMedia('(max-width: 899px)').matches) drawer = true;
  repaint();
  if (drawer) setTimeout(() => $('[data-cb-amount]', root)?.focus(), 30);
  else focusByKey(`row:${pid}`, root);
}

let nextRequest = null;   // the request id of a Next click whose answer has not arrived: a retry reuses it
async function nextTurn(mode = 'next') {
  const e = E();
  if (!e || e.status !== 'active') return;
  const key = 'turn';
  if (busy.has(key)) return;
  nextRequest ||= { id: crypto.randomUUID(), rev: e.turn_rev };
  const req = nextRequest;
  const r = await mutate(key, () => api.nextTurn(e.id, req.rev, mode, req.id), { after: mode === 'skip' ? 'skipped turn' : 'turn' });
  nextRequest = null;
  if (r) afterTurnResult(r);
}

function afterTurnResult(r, prefix = '') {
  if (!r) return;
  const n = (r.notices || []).filter((x) => x.kind !== 'reverted' || x.manual?.length);
  notices = n.length ? n : [];
  const e = E();
  if (r.encounter) data.encounter = r.encounter;
  if (r.participants) patchParticipants(r.participants);
  if (r.effects) patchEffects(r.effects);
  const cur = P(E().current_participant_id);
  selected = cur?.id || selected;
  drawer = false;
  repaint();
  announce(`${prefix || (E().round !== e?.round ? `Round ${E().round}.` : '')} ${pname(cur)}'s turn.`.trim());
  focusByKey('cb-next', root);
}

async function previousTurn() {
  const e = E();
  if (!e || busy.has('turn')) return;
  busy.add('turn');
  try {
    let r = await api.previousTurn(e.id, e.turn_rev, false);
    if (r?.needs_confirmation) {
      const restore = (r.effects || []).map((x) => x.name);
      const manual = (r.manual || []).map((x) => x.name);
      const ok = await confirmDialog(`Go back one turn?\n${restore.length ? `Effect clocks put back: ${restore.join(', ')}.` : ''}${manual.length ? `\nChanged since, check by hand: ${manual.join(', ')}.` : ''}`,
        { title: 'Previous turn', okLabel: 'Go back' });
      if (!ok) return;
      r = await api.previousTurn(e.id, e.turn_rev, true);
    }
    busy.delete('turn');
    lastAction = null;
    afterTurnResult(r, 'Back:');
  } catch (err) {
    if (api.isConflict(err)) { toast(err.message, 'info', 4500); await reload(); } else toast(err.message, 'bad');
  } finally { busy.delete('turn'); }
}

function gotoModal() {
  const list = orderList();
  const m = openModal({
    title: 'Choose turn',
    body: `<p class="small muted">Point the turn at a combatant (for example a forgotten turn). Effect clocks, Reactions and Legendary uses are not changed; it is logged.</p>
      <form class="form-grid" data-f><label class="field span-2"><span>Combatant</span><select name="pid">${list.map((p) => `<option value="${esc(p.id)}" ${p.id === E().current_participant_id ? 'selected' : ''}>${esc(pname(p))} (${p.initiative ?? '—'})</option>`).join('')}</select></label>
      <label class="field"><span>Round</span><input name="round" type="number" min="1" value="${E().round}"></label>
      <label class="field"><span>Reason (optional)</span><input name="reason" maxlength="200"></label></form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Go</button>',
  });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const f = $('[data-f]', m.el);
    const r = await mutate('turn', () => api.gotoTurn(E().id, f.pid.value, E().turn_rev, Number(f.round.value) || null, f.reason.value || null), { after: 'turn choice' });
    m.close();
    if (r) afterTurnResult(r);
  });
}

function hpPreviewText(p, op, amt) {
  if (!p || !amt || amt < 0) return '';
  const h = hpOf(p);
  if (op === 'heal') { const n = Math.min(h.max, h.cur + amt); return `Heal ${amt}: ${h.cur} → ${Math.max(n, h.cur)} / ${h.max}${h.form ? ' (form)' : ''}`; }
  const abs = Math.min(h.temp, amt);
  const rest = amt - abs;
  const n = Math.max(0, h.cur - rest);
  let t = `Damage ${amt}: ${abs ? `${abs} from temporary HP, ` : ''}${h.cur} → ${n} / ${h.max}`;
  if (h.form && rest >= h.cur) {
    const ex = rest - h.cur;
    const nn = h.normal ? Math.max(0, h.normal.current - Math.max(0, ex - (h.normal.temp || 0))) : null;
    t += ex ? ` · the form ends; only the excess ${ex} reaches normal HP${nn != null ? ` (${h.normal.current} → ${nn})` : ''}` : ' · the form ends; no damage carries over';
  } else if (h.form && h.expired) t += ' · the form’s duration is over, so it ends after this damage';
  else if (n === 0) t += p.kind === 'monster' ? ' · Defeated' : ' · Down';
  const conc = concentrationOf(p.id);
  if (conc) t += ` · Concentration check DC ${E().ruleset === '2024' ? Math.min(30, Math.max(10, Math.floor(amt / 2))) : Math.max(10, Math.floor(amt / 2))}`;
  return t;
}
function showPreview(pid, amt) {
  const el = $('[data-cb-preview]', root);
  if (el) el.textContent = amt > 0 ? `${hpPreviewText(P(pid), 'damage', amt)}` : '';
}

async function applyHpFromDetail(pid, op) {
  const inp = $(`[data-cb-amount="${CSS.escape(pid)}"]`, root);
  const amt = parseInt(inp?.value, 10);
  if (!(amt >= 0) || (op !== 'temp' && !amt)) { inp?.focus(); toast('Enter an amount first'); return; }
  await doHp(pid, op, amt, null, inp);
}

async function doHp(pid, op, amt, reason = null, inp = null) {
  const p = P(pid);
  const r = await mutate(`hp:${pid}`, () => api.applyHp(pid, op, amt, reason), { after: op === 'damage' ? 'damage' : op === 'heal' ? 'healing' : 'HP change' });
  if (!r) return;
  if (inp) inp.value = '';
  if (r.applied === false) { toast(r.message || 'Nothing was changed.', 'bad', 8000); announce(r.message || ''); return; }
  const np = P(pid);
  const h = hpOf(np);
  const ws = r.wild_shape;
  if (op === 'damage' && ws?.ended) {   // a Wild Shape form: one clear sentence (form HP used, excess, resulting normal HP)
    const form = hpOf(p).form || 'Wild Shape';
    const text = ws.reason === 'zero_hp'
      ? `${form} form took ${amt} damage. The form ended${ws.carryover ? `, and ${ws.carryover} excess damage was applied to ${pname(p)} (${ws.normal_hp_before} → ${ws.normal_hp_after} HP)` : '; no damage carried over'}.`
      : `${form} form took ${amt} damage (${ws.form_hp_after} HP left). Its duration was over, so it ended; ${pname(p)}'s normal HP is unchanged.`;
    toast(text, 'info', 8000);
    announce(text);
    if (r.concentration_checks?.length) {
      notices = [...notices, ...r.concentration_checks.map((c) => ({ kind: 'text', text: `${pname(p)} must make a CON save DC ${c.dc} to keep concentrating on ${c.effect}.` }))];
      repaint();
    }
    return;
  }
  const msg = op === 'damage' ? `${pname(p)} took ${amt} damage${r.absorbed ? ` (${r.absorbed} from temporary HP)` : ''}: ${h.cur}/${h.max}.`
    : op === 'heal' ? `${pname(p)} healed: ${h.cur}/${h.max}.` : op === 'temp' ? `${pname(p)}: ${amt} temporary HP.` : `${pname(p)}: HP set to ${h.cur}.`;
  toast(msg, op === 'heal' ? 'good' : 'info');
  if (r.concentration_checks?.length) {
    notices = [...notices, ...r.concentration_checks.map((c) => ({ kind: 'text', text: `${pname(p)} must make a CON save DC ${c.dc} to keep concentrating on ${c.effect}.` }))];
    repaint();
  }
  if (np.kind === 'monster' && np.defeated && !p.defeated) announce(`${pname(np)} is defeated.`);
  else if (np.kind === 'character' && h.cur <= 0 && hpOf(p).cur > 0) announce(`${pname(np)} is down.`);
}

function correctHp(pid) {
  const p = P(pid);
  const h = hpOf(p);
  const m = openModal({
    title: `Correct HP: ${pname(p)}`,
    body: `<form class="form-grid" data-f><label class="field"><span>Hit points${h.form ? ' (form)' : ''}</span><input name="hp" type="number" min="${h.form ? 1 : 0}" max="${h.max}" value="${h.cur}"></label>
      <label class="field"><span>Temporary HP</span><input name="temp" type="number" min="0" max="5000" value="${h.temp}"></label>
      <label class="field span-2"><span>Reason (required, kept in the history)</span><input name="reason" maxlength="200" required placeholder="Misread the damage roll"></label></form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Save correction</button>',
  });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const f = $('[data-f]', m.el);
    if (!f.reason.value.trim()) { f.reason.focus(); toast('A correction needs a reason'); return; }
    m.close();
    if (Number(f.hp.value) !== h.cur) await doHp(pid, 'set', Number(f.hp.value), f.reason.value.trim());
    if (Number(f.temp.value) !== h.temp) await doHp(pid, 'temp', Number(f.temp.value), f.reason.value.trim());
  });
}

/** Row quick damage / healing: a small popover; Enter applies, Escape cancels, focus goes back to the button. */
function quickHp(btn, pid, op, initial = '') {
  $('.cb-pop', root)?.remove();
  const p = P(pid);
  const pop = document.createElement('div');
  pop.className = 'cb-pop';
  pop.dataset.pid = pid;
  pop.dataset.op = op;
  pop.setAttribute('role', 'dialog');
  pop.setAttribute('aria-label', `${op === 'damage' ? 'Damage' : 'Heal'} ${pname(p)}`);
  pop.innerHTML = `<label><span class="sr-only">${op === 'damage' ? 'Damage' : 'Healing'} amount</span><input type="number" min="1" max="10000" inputmode="numeric" placeholder="${op === 'damage' ? 'Damage' : 'Heal'}"></label>
    <button type="button" class="btn btn-sm ${op === 'damage' ? 'btn-bad' : 'btn-good'}" data-apply>Apply</button><span class="small cb-pop-prev" aria-live="polite"></span>`;
  btn.closest('.cb-row').append(pop);
  const inp = $('input', pop);
  inp.value = initial;
  inp.focus();
  const close = () => { pop.remove(); focusByKey(`${op === 'damage' ? 'qd' : 'qh'}:${pid}`, root); };
  const apply = async () => {
    const amt = parseInt(inp.value, 10);
    if (!amt) { inp.focus(); return; }
    $('[data-apply]', pop).disabled = true;
    pop.remove();
    await doHp(pid, op, amt);
    focusByKey(`${op === 'damage' ? 'qd' : 'qh'}:${pid}`, root);
  };
  inp.addEventListener('input', () => { $('.cb-pop-prev', pop).textContent = hpPreviewText(p, op, parseInt(inp.value, 10)); });
  inp.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); apply(); } if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); close(); } });
  $('[data-apply]', pop).addEventListener('click', apply);
  // clicking elsewhere closes it (a re-render that replaces the row re-opens it with the typed value, see repaint)
  pop.addEventListener('focusout', (ev) => { if (ev.relatedTarget && !pop.contains(ev.relatedTarget)) setTimeout(() => pop.isConnected && pop.remove(), 150); });
  const outside = (ev) => {
    if (!pop.isConnected) { document.removeEventListener('mousedown', outside, true); return; }
    if (!pop.contains(ev.target) && !ev.target.closest?.('[data-cb="quick-hp"]')) { pop.remove(); document.removeEventListener('mousedown', outside, true); }
  };
  document.addEventListener('mousedown', outside, true);
}

function bulkModal() {
  const mons = orderList().filter((p) => p.active && !p.removed && !(p.kind === 'monster' && p.defeated));
  const m = openModal({
    title: 'Area damage or healing',
    wide: true,
    body: `<form data-f><div class="form-grid"><label class="field"><span>Change</span><select name="op"><option value="damage">Damage</option><option value="heal">Healing</option></select></label>
      <label class="field"><span>Amount for each</span><input name="amount" type="number" min="1" max="10000"></label></div>
      <p class="small muted">Tick the targets and adjust single amounts (a successful save: half). You review the list before anything is applied.</p>
      <table class="cb-init-table"><thead><tr><th scope="col">Target</th><th scope="col">Amount</th></tr></thead><tbody>
      ${mons.map((p) => `<tr><th scope="row"><label class="cb-toggle"><input type="checkbox" data-t="${esc(p.id)}" ${p.kind === 'monster' ? '' : 'data-pc="1"'}> ${esc(pname(p))} <span class="small muted">${p.kind === 'character' ? 'player character' : ''}</span></label></th>
        <td><input type="number" min="0" max="10000" data-a="${esc(p.id)}" aria-label="Amount for ${esc(pname(p))}"></td></tr>`).join('')}</tbody></table>
      <label class="cb-toggle"><input type="checkbox" name="pcs"> Include the ticked player characters (their real HP changes)</label></form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Review</button>',
  });
  const f = $('[data-f]', m.el);
  f.amount.addEventListener('input', () => $$('[data-a]', m.el).forEach((x) => { x.value = f.amount.value; }));
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const items = $$('[data-t]:checked', m.el).map((x) => ({ id: x.dataset.t, amount: Number($(`[data-a="${CSS.escape(x.dataset.t)}"]`, m.el).value || f.amount.value), pc: !!x.dataset.pc }))
      .filter((x) => x.amount > 0);
    if (!items.length) { toast('Tick at least one target with an amount'); return; }
    if (items.some((x) => x.pc) && !f.pcs.checked) { toast('Tick "Include the ticked player characters" to change their HP'); return; }
    const ok = await confirmDialog(`${f.op.value === 'damage' ? 'Damage' : 'Heal'}:\n${items.map((x) => `${pname(P(x.id))}: ${x.amount}`).join('\n')}`, { title: 'Apply to all of these?', okLabel: 'Apply' });
    if (!ok) return;
    const r = await mutate('bulk', () => api.applyHpBulk(E().id, f.op.value, items.map(({ id, amount }) => ({ id, amount })), f.pcs.checked), { quiet: true });
    if (r) { m.close(); await reload(); toast(`Applied to ${r.results.length} combatants.`, 'good'); }
  });
}

// ---------------------------------------------------------------------------------------------------------------- effects
function participantOptions(sel, { none = false } = {}) {
  return `${none ? '<option value="">—</option>' : ''}${orderList().map((p) => `<option value="${esc(p.id)}" ${p.id === sel ? 'selected' : ''}>${esc(pname(p))}</option>`).join('')}`;
}

function effectModal(pid, tab = 'condition') {
  const target = P(pid);
  const conds = data.conditions || [];
  const cur = E().current_participant_id;
  const m = openModal({
    title: `Effect on ${pname(target)}`,
    wide: true,
    body: `<div class="dm-tabs cb-tabs" role="tablist">${[['condition', 'Condition'], ['custom', 'Custom effect'], ['concentration', 'Concentration']]
        .map(([k, l]) => `<button type="button" class="tab" role="tab" data-tab="${k}" aria-selected="${k === tab}">${l}</button>`).join('')}</div>
      <form class="form-grid" data-f>
        <div class="span-2" data-only="condition"><p class="small muted">${esc(E().ruleset)} rules. Conditions are reminders: they never change a number by themselves.</p>
          <div class="cb-cond-grid">${conds.map((k) => `<label class="cb-cond"><input type="radio" name="condition" value="${esc(k.key)}">${conditionIcon(k.key, { size: 22 })}
            <span><strong>${esc(k.name)}</strong><span class="small">${esc(k.summary)}</span></span></label>`).join('')}</div>
          <label class="field" data-exh hidden><span>Exhaustion level</span><input name="exhaustion" type="number" min="1" max="6" value="1"></label></div>
        <label class="field span-2" data-only="custom concentration"><span>Name</span><input name="name" maxlength="120" placeholder="Blessed, Hunter's Mark, Cover…"></label>
        <label class="field span-2" data-only="custom"><span>What it does (reminder text)</span><input name="description" maxlength="2000"></label>
        <label class="field" data-only="custom condition"><span>Source</span><select name="source">${participantOptions(cur, { none: true })}</select></label>
        <label class="field" data-only="custom condition"><span>Visible to</span><select name="visibility"><option value="players">Players and DM</option><option value="dm">DM only (hidden)</option></select></label>
        <label class="field" data-only="custom condition concentration"><span>Duration</span><select name="duration">${DURATIONS.map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></label>
        <label class="field" data-dur="rounds"><span>Rounds</span><input name="rounds" type="number" min="1" max="1000" value="1"></label>
        <label class="field" data-dur="minutes"><span>Minutes (1 = 10 rounds)</span><input name="minutes" type="number" min="1" value="1"></label>
        <label class="field" data-dur="rounds minutes"><span>Counts down at</span><select name="expires"><option value="turn_start">the start of the anchor's turn</option><option value="turn_end">the end of the anchor's turn</option></select></label>
        <label class="field" data-dur="rounds minutes until_turn_start until_turn_end"><span>Whose turn (anchor)</span><select name="anchor"><option value="source">the source's</option><option value="target">the target's</option></select></label>
        <label class="cb-toggle" data-dur="until_turn_end"><input type="checkbox" name="this_turn"> This turn (not the next one)</label>
        <label class="field" data-dur="save_ends" data-also="saves"><span>Save ability</span><select name="save_ability"><option value="">—</option>${ABIL.map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></label>
        <label class="field" data-dur="save_ends" data-also="saves"><span>Save DC</span><input name="save_dc" type="number" min="1" max="40"></label>
        <label class="cb-toggle span-2" data-only="custom condition"><input type="checkbox" name="has_save"> Repeat a saving throw each turn (reminder)</label>
        <label class="field" data-only="custom"><span>Modifier</span><select name="mod_target"><option value="">None (reminder only)</option><option value="ac">Armor Class (applied in the tracker)</option>
          <option value="speed">Speed (applied in the tracker)</option><option value="attack">Attack rolls (reminder)</option><option value="save">Saving throws (reminder)</option><option value="damage">Damage (reminder)</option></select></label>
        <label class="field" data-only="custom"><span>Modifier value</span><input name="mod_value" type="number" min="-50" max="50"></label>
        <label class="field" data-only="custom"><span>Defense reminder</span><select name="defense_kind"><option value="">—</option><option value="resistance">Resistance</option><option value="immunity">Immunity</option><option value="vulnerability">Vulnerability</option></select></label>
        <label class="field" data-only="custom"><span>Damage type</span><input name="defense_type" maxlength="40" placeholder="fire"></label>
        <label class="cb-toggle span-2" data-only="custom condition"><input type="checkbox" name="conc"> Depends on the source's Concentration</label>
        <label class="field span-2" data-conc><span>Concentration spell or effect</span><input name="conc_name" maxlength="120" placeholder="Bless, Hold Person…"></label>
        <label class="field span-2" data-only="custom condition"><span>Also on (more targets)</span><select name="more" multiple size="4">${orderList().filter((p) => p.id !== pid).map((p) => `<option value="${esc(p.id)}">${esc(pname(p))}</option>`).join('')}</select></label>
      </form>
      <p class="small muted" data-only="concentration">Concentration on ${esc(pname(target))}: when it takes damage you get a Constitution save reminder with the ${esc(E().ruleset)} DC; Failure ends everything linked to it.</p>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Apply</button>',
  });
  const f = $('[data-f]', m.el);
  const sync = () => {
    $$('[data-only]', m.el).forEach((x) => { x.hidden = !x.dataset.only.split(' ').includes(tab); });
    const d = f.duration.value;
    $$('[data-dur]', m.el).forEach((x) => { x.hidden = !(x.dataset.dur.split(' ').includes(d) || (x.dataset.also && f.has_save.checked && tab !== 'concentration')); });
    $('[data-conc]', m.el).hidden = !(tab === 'concentration' || f.conc.checked);
    $('[data-exh]', m.el).hidden = !(tab === 'condition' && f.condition.value === 'exhaustion');
    $$('[role=tab]', m.el).forEach((t) => t.setAttribute('aria-selected', String(t.dataset.tab === tab)));
  };
  m.el.addEventListener('click', (ev) => { const t = ev.target.closest('[role=tab]'); if (t) { tab = t.dataset.tab; sync(); } });
  m.el.addEventListener('change', sync);
  sync();
  $('[data-ok]', m.el).addEventListener('click', async (ev) => {
    const more = [...f.more.selectedOptions].map((o) => o.value);
    const eff = {
      effect_type: tab, targets: [pid, ...more], source: tab === 'concentration' ? pid : (f.source.value || null),
      condition_key: tab === 'condition' ? f.condition.value : undefined, exhaustion_level: Number(f.exhaustion.value) || 1,
      name: tab === 'concentration' ? (f.conc_name.value || f.name.value) : f.name.value || undefined, description: f.description.value,
      visibility: f.visibility.value, duration_type: f.duration.value, duration_rounds: Number(f.rounds.value) || null, duration_minutes: Number(f.minutes.value) || null,
      expires_on: f.expires.value, anchor: f.anchor.value, this_turn: f.this_turn.checked,
      save_ability: (f.duration.value === 'save_ends' || f.has_save.checked) ? f.save_ability.value || null : null,
      save_dc: (f.duration.value === 'save_ends' || f.has_save.checked) ? Number(f.save_dc.value) || null : null,
      modifier_target: f.mod_target.value || null, modifier_value: f.mod_value.value === '' ? null : Number(f.mod_value.value),
      defense_kind: f.defense_kind.value || null, defense_type: f.defense_type.value || null,
      concentration: tab !== 'concentration' && f.conc.checked, concentration_name: f.conc_name.value || null,
    };
    if (tab === 'condition' && !eff.condition_key) { toast('Choose a condition'); return; }
    if (tab !== 'condition' && !eff.name) { f.name.focus(); toast('Give the effect a name'); return; }
    if (eff.concentration && !eff.source) { toast('Choose the source (who concentrates)'); return; }
    const okBtn = ev.currentTarget; okBtn.disabled = true;
    const send = (e2) => api.addEffect(E().id, e2);
    let r;
    try { r = await send(eff); } catch (err) {
      if (api.isConcentrationQuestion(err) && await confirmDialog(`${err.message}\nStarting a new Concentration ends the old one and everything linked to it.`, { title: 'Replace concentration?', okLabel: 'Replace' })) {
        try { r = await send({ ...eff, replace_concentration: true }); } catch (err2) { toast(err2.message, 'bad'); }
      } else if (!api.isConcentrationQuestion(err)) toast(err.message, 'bad');
    }
    okBtn.disabled = false;
    if (!r) return;
    m.close();
    applyResult(r);
    lastAction = { event: r.event_id, label: 'effect' };
    if (r.notices?.length) notices = [...notices, ...r.notices];
    repaint();
    toast(`${r.effects.filter((x) => x.active).map((x) => x.display_name)[0] || 'Effect'} applied.`, 'good');
  });
}

function advModal(pid, mode) {
  const target = P(pid);
  const m = openModal({
    title: `${mode === 'advantage' ? 'Advantage' : 'Disadvantage'}: ${pname(target)}`,
    body: `<form class="form-grid" data-f>
      <label class="field span-2"><span>Applies to</span><select name="scope">${SCOPES.map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></label>
      <label class="field" data-s="save"><span>Saving throw</span><select name="save">${ABIL.map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></label>
      <label class="field" data-s="skill custom"><span>Skill, check or note</span><input name="detail" maxlength="60" placeholder="Perception, Stealth…"></label>
      <label class="field" data-s="attacks_against_target"><span>Target</span><select name="target">${participantOptions(null)}</select></label>
      <label class="field"><span>Until</span><select name="duration"><option value="indefinite">Removed by hand (e.g. after the attack)</option><option value="until_turn_end">The end of this turn</option>
        <option value="until_turn_start">The start of its next turn</option><option value="rounds">A number of rounds</option></select></label>
      <label class="field" data-d="rounds"><span>Rounds</span><input name="rounds" type="number" min="1" value="1"></label>
      <label class="field"><span>Source</span><select name="source">${participantOptions(E().current_participant_id, { none: true })}</select></label>
      <label class="field"><span>Visible to</span><select name="visibility"><option value="players">Players and DM</option><option value="dm">DM only</option></select></label></form>
      <p class="small muted">Shown in the tracker only, for this scope. Advantage and Disadvantage on the same roll cancel: the tracker shows "Normal (both)".</p>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Apply</button>',
  });
  const f = $('[data-f]', m.el);
  const sync = () => {
    $$('[data-s]', m.el).forEach((x) => { x.hidden = !x.dataset.s.split(' ').includes(f.scope.value); });
    $$('[data-d]', m.el).forEach((x) => { x.hidden = x.dataset.d !== f.duration.value; });
  };
  m.el.addEventListener('change', sync);
  sync();
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const scope = f.scope.value;
    const eff = { effect_type: 'advantage', adv_mode: mode, adv_scope: scope, targets: [pid], source: f.source.value || null, visibility: f.visibility.value,
      adv_detail: scope === 'save' ? f.save.value : ['skill', 'custom'].includes(scope) ? f.detail.value || null : null,
      adv_target: scope === 'attacks_against_target' ? f.target.value : null,
      duration_type: f.duration.value, duration_rounds: f.duration.value === 'rounds' ? Number(f.rounds.value) || 1 : null, anchor: 'target', expires_on: 'turn_end' };
    const r = await mutate(`adv:${pid}`, () => api.addEffect(E().id, eff), { after: 'Advantage state' });
    if (r) m.close();
  });
}

// ---------------------------------------------------------------------------------------------------------------- misc
async function renameParticipant(pid) {
  const p = P(pid);
  const m = openModal({
    title: `Rename ${pname(p)}`,
    body: `<form class="form-grid" data-f><label class="field"><span>Name</span><input name="name" maxlength="120" value="${esc(p.name)}"></label>
      <label class="field"><span>Letter / label</span><input name="label" maxlength="12" value="${esc(p.label || '')}"></label>
      <label class="field span-2"><span>Name for players (disguise, future player view)</span><input name="player_label" maxlength="120" value="${esc(p.player_label || '')}" placeholder="Hooded figure"></label></form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Save</button>',
  });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const f = $('[data-f]', m.el);
    const r = await mutate(`rename:${pid}`, () => api.updateParticipant(pid, { display_name: f.name.value, instance_label: f.label.value, player_label: f.player_label.value }), { quiet: true });
    if (r) m.close();
  });
}

async function loadFeatures(cid) {
  try {
    const [{ data: res, error }, timing] = await Promise.all([
      supabase.rpc('get_character_reads', { p_character: cid, p_reads: FEATURE_READS }), loadPlayTiming()]);
    if (error) throw error;
    const r = res?.reads || {};
    featureCache[cid] = { classFeatures: r.get_character_class_features, classResources: r.get_character_resources,
      feats: r.get_character_feats, lineage: r.get_character_lineage, timing };
    if (root) repaint();
  } catch (err) { toast('The active features could not be loaded.', 'bad'); console.warn('[combat features]', err?.message || err); }
}

async function loadStatblock(sid) {
  try {
    statblockCache[sid] = await api.getStatblock(sid);
    repaint();
  } catch (err) { toast(err.message, 'bad'); }
}

async function undoEvent(eventId) {
  const r = await mutate('undo', () => api.undo(eventId), { quiet: true });
  if (!r) return;
  if (r.encounter && r.difficulty) data = r;
  lastAction = null;
  repaint();
  toast(`Undone: ${kindLabel(r.undone || '')}.`, 'good');
  announce('Last change undone.');
}

async function historyModal() {
  const m = openModal({ title: 'Encounter history', wide: true, body: spinner(), footer: '<button type="button" class="btn" data-close>Close</button>' });
  try {
    const h = await api.getHistory(E().id, null, 100);
    m.body.innerHTML = `<ul class="cb-hist">${h.map(histItem).join('') || '<li class="muted">Nothing yet.</li>'}</ul>`;
    m.body.addEventListener('click', async (ev) => {
      const b = ev.target.closest('[data-cb="undo-event"]');
      if (!b) return;
      ev.stopPropagation();
      m.close();
      await undoEvent(Number(b.dataset.id));
    });
  } catch (err) { m.body.innerHTML = errorBox(err); }
}

function helpModal() {
  openModal({ title: 'Keyboard shortcuts', body: `<dl class="cb-keys">
    <dt><kbd>N</kbd></dt><dd>Next turn (End turn)</dd><dt><kbd>P</kbd></dt><dd>Previous turn</dd>
    <dt><kbd>D</kbd> / <kbd>H</kbd></dt><dd>Damage / heal the selected combatant (type the amount, Enter applies)</dd>
    <dt><kbd>C</kbd></dt><dd>Condition on the selected combatant</dd><dt><kbd>A</kbd></dt><dd>Advantage / Disadvantage</dd>
    <dt><kbd>F</kbd></dt><dd>Find a combatant</dd><dt><kbd>↑</kbd> <kbd>↓</kbd></dt><dd>Select the previous / next combatant</dd>
    <dt><kbd>U</kbd></dt><dd>Undo the last change</dd><dt><kbd>Esc</kbd></dt><dd>Close a dialog or popover</dd></dl>
    <p class="small muted">Shortcuts never fire while you type in a field. Everything also works with mouse and touch.</p>`,
  footer: '<button type="button" class="btn" data-close>Close</button>' });
}

async function finishFlow() {
  const m = openModal({
    title: 'Finish combat',
    body: `<p>Finishing keeps everything as it is: player HP stays the real current HP, nothing is healed or restored (rests are separate). Monsters keep their final state.</p>
      <label class="field"><span>Notes (optional)</span><textarea rows="3" data-n maxlength="8000"></textarea></label>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-bad" data-ok>Finish combat</button>',
  });
  $('[data-ok]', m.el).addEventListener('click', async (ev) => {
    const okBtn = ev.currentTarget; okBtn.disabled = true;
    const notes = $('[data-n]', m.el).value;
    try {
      let r = await api.finishCombat(E().id, notes);
      m.close();
      if (r.needs_review) r = await reviewLasting(r.effects, notes);
      if (r?.encounter) { data.encounter = r.encounter; notices = []; render(); toast('Combat finished.', 'good'); }
    } catch (err) { toast(err.message, 'bad'); okBtn.disabled = false; }
  });
}

function reviewLasting(effects, notes) {
  return new Promise((resolve) => {
    const m = openModal({
      title: 'Effects that may outlast the fight',
      wide: true,
      body: `<p class="small">Decide for each one. "Move to the sheet" adds it to the character's conditions (hidden if it was DM-only). Nothing is removed without your choice.</p>
        <table class="cb-init-table"><thead><tr><th scope="col">Effect</th><th scope="col">On</th><th scope="col">Decision</th></tr></thead><tbody>
        ${effects.map((x) => `<tr><th scope="row">${esc(x.name)} <span class="small muted">${x.visibility === 'dm' ? 'DM only' : ''}</span></th><td>${esc(x.target)}</td>
          <td><select data-d="${esc(x.id)}" aria-label="Decision for ${esc(x.name)} on ${esc(x.target)}"><option value="end">End it</option><option value="keep">Keep (track it yourself)</option>
          ${x.can_carry ? '<option value="carry">Move to the character sheet</option>' : ''}</select></td></tr>`).join('')}</tbody></table>`,
      footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-bad" data-ok>Finish combat</button>',
      onClose: () => resolve(null),
    });
    $('[data-ok]', m.el).addEventListener('click', async () => {
      const decisions = Object.fromEntries($$('[data-d]', m.el).map((s) => [s.dataset.d, s.value]));
      try { const r = await api.finishCombat(E().id, notes, decisions, true); resolve(r); m.close(); } catch (err) { toast(err.message, 'bad'); }
    });
  });
}

// ================================================================================================================ keyboard
function installKeys() {
  if (keyHandler) document.removeEventListener('keydown', keyHandler);
  keyHandler = (ev) => {
    if (!root || !data || !isLive()) return;
    if (ev.defaultPrevented || ev.ctrlKey || ev.metaKey || ev.altKey) return;
    const t = ev.target;
    if (t.closest('input, textarea, select, [contenteditable]') || document.querySelector('.modal-backdrop:not([data-closing])')) return;
    const list = orderList();
    const i = list.findIndex((p) => p.id === selected);
    const k = ev.key.toLowerCase();
    const act = {
      n: () => nextTurn(), p: () => previousTurn(),
      d: () => { $('[data-cb-amount]', root)?.focus(); }, h: () => { const el = $('[data-cb-amount]', root); if (el) { el.focus(); el.dataset.op = 'heal'; } },
      c: () => selected && effectModal(selected, 'condition'), a: () => selected && advModal(selected, 'advantage'),
      f: () => $('[data-cb-find]', root)?.focus(), u: () => lastAction && undoEvent(lastAction.event),
      arrowdown: () => list[i + 1] && selectRow(list[i + 1].id), arrowup: () => i > 0 && selectRow(list[i - 1].id),
    }[k];
    if (act) { ev.preventDefault(); act(); }
  };
  document.addEventListener('keydown', keyHandler);
}

// ================================================================================================================ Realtime
function subscribe() {
  unsubscribe?.();
  const id = E()?.id;
  if (!id) return;
  const refreshParticipants = new Set();
  let full = false;
  const flush = debounce(async () => {
    if (!root || !data) return;
    const ids = [...refreshParticipants];
    refreshParticipants.clear();
    if (full) { full = false; await reload(); return; }
    await Promise.all(ids.map(async (pid) => {
      try { const r = await api.getParticipant(pid); patchParticipants([r.participant]); patchEffects(r.effects); } catch { /* removed meanwhile */ }
    }));
    repaint();
  }, 180);
  unsubscribe = api.subscribeEncounter(id, charIds(data), {
    change: (row) => {
      if (!row || row.id <= lastChange) return;
      lastChange = row.id;
      if (row.domain === 'hp' && row.participant_id) refreshParticipants.add(row.participant_id);
      else full = true;
      flush();
    },
    character: (row) => {   // HP changed on the character sheet (or by us): patch from the payload, no read
      const before = summaries[row.id]?.row;
      if (before && SUMMARY_COLS.some((k) => k in row && JSON.stringify(row[k]) !== JSON.stringify(before[k]))) refreshSummary(row.id);
      let hit = false;
      for (const p of data?.participants || []) {
        if (p.character_id === row.id && p.hp) {
          if (p.hp.current !== row.hp_current || p.hp.temp !== row.hp_temp) hit = true;
          p.hp = { ...p.hp, current: row.hp_current, temp: row.hp_temp, death_successes: row.death_successes, death_failures: row.death_failures };
        }
      }
      if (hit) repaint();
    },
    revision: (row) => {
      if (BUILD_SOURCES.has(row.source_table)) { refreshSummary(row.character_id); return; }   // feats, classes, equipment …
      if (row.source_table === 'character_resources' && featureCache[row.character_id]) { refreshFeatures(row.character_id); return; }   // uses spent
      if (row.source_table !== 'character_transformations') return;
      const p = data?.participants.find((x) => x.character_id === row.character_id);
      if (p) { refreshParticipants.add(p.id); flush(); }
    },
    status: async (s) => {
      if (s === 'SUBSCRIBED') {
        if (connection !== 'online') {
          setConnection('reconnecting');
          try {
            const c = await api.getChanges(id, lastChange);
            if (c.domains?.length || c.turn_rev !== E()?.turn_rev) await reload();
          } catch { /* reload below */ }
        }
        setConnection(navigator.onLine ? 'online' : 'offline');
      } else if (s === 'CHANNEL_ERROR' || s === 'TIMED_OUT' || s === 'CLOSED') {
        if (root) setConnection('offline');
      }
    },
  });
}

function setConnection(state) {
  connection = state;
  if (!root) return;
  root.classList.toggle('cb-offline', state !== 'online');
  const el = $('[data-cb-conn]', root);
  if (el) el.innerHTML = state === 'online' ? '<span class="cb-dot cb-dot-ok"></span><span class="sr-only">Connected</span>'
    : state === 'reconnecting' ? '<span class="cb-dot cb-dot-warn"></span> Reconnecting…' : `${glyph('wifi_off', { size: 14 })} Offline`;
  const ban = $('[data-cb-banner]', root);
  if (ban) {
    ban.hidden = state === 'online';
    ban.innerHTML = state === 'online' ? '' : `<span>${state === 'offline' ? 'Connection lost. The encounter is read-only: nothing you click is sent until it reconnects.' : 'Reconnecting: checking what changed…'}</span>
      <button type="button" class="btn btn-sm" data-cb="reload">Retry</button>`;
    ban.setAttribute('role', 'alert');
  }
  $$('.cb-dock button, .cb-hp-ctl button, .cb-quick button', root).forEach((b) => { if (state !== 'online') b.setAttribute('aria-disabled', 'true'); else b.removeAttribute('aria-disabled'); });
}
