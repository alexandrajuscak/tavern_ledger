// Quest log (docs/QUEST_LOG.md, migration 20261114000400). Loaded through a dynamic import() only: by the sheet when the
// Quests tab opens, and by DM Space when its Quests section opens. Never part of a sheet open.
// The database decides everything: the player read get_character_quests returns only what that character may see (party
// quests, individual quests of the party, its own private quests) and never DM notes; the DM read and every write need the
// DM of the campaign. Quest data lives only in this module's memory (never in localStorage / the legacy bundle cache).

import { supabase } from './supabase.js?v=31';
import { $, $$, esc, toast, openModal, confirmDialog, friendlyError } from './utils.js?v=31';
import { sectionHead } from './section.js?v=31';

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) { const e = new Error(friendlyError(error)); e.code = error.code; throw e; }
  return data;
}

// ---- API ------------------------------------------------------------------------------------------------------------------------
export const getCharacterQuests = (characterId) => rpc('get_character_quests', { p_character: characterId });
export const getCampaignQuests = (campaignId, archived = false) => rpc('get_campaign_quests', { p_campaign: campaignId, p_include_archived: archived });
export const saveQuest = (campaignId, quest, revision = null) => rpc('dm_save_quest', { p_campaign: campaignId, p_quest: quest, p_expected_revision: revision });
export const setQuestStatus = (questId, status) => rpc('dm_set_quest_status', { p_quest: questId, p_status: status });
export const setObjective = (objectiveId, done) => rpc('dm_set_quest_objective', { p_objective: objectiveId, p_done: done });
export const archiveQuest = (questId, archived = true) => rpc('dm_archive_quest', { p_quest: questId, p_archived: archived });
export const reorderQuests = (campaignId, ids) => rpc('dm_reorder_quests', { p_campaign: campaignId, p_quests: ids });

export const STATUS = { active: 'Active', completed: 'Completed', failed: 'Failed' };
const STATUS_ORDER = ['active', 'completed', 'failed'];
const VIS = { party: 'Party', individual: 'Individual (party sees it)', private: 'Private (DM and one player)' };

const statusBadge = (s) => `<span class="badge quest-status quest-${esc(s)}">${esc(STATUS[s] || s)}</span>`;
const progress = (q) => {
  const all = q.objectives || [];
  return all.length ? `<span class="quest-progress small muted">${all.filter((o) => o.done).length}/${all.length}</span>` : '';
};
// who a quest belongs to, as the player sees it
function ownerBadge(q) {
  if (q.visibility === 'party') return '<span class="badge quest-vis">Party</span>';
  if (q.visibility === 'private') return '<span class="badge quest-vis quest-vis-private">Private</span>';
  return `<span class="badge quest-vis">${q.mine ? 'Yours' : esc(q.target_name || 'Party member')}</span>`;
}
const objectivesHTML = (q) => (q.objectives?.length ? `<ul class="quest-objectives">${q.objectives.map((o) => `<li class="${o.done ? 'is-done' : ''}">
    <span class="quest-check" aria-hidden="true">${o.done ? '✓' : ''}</span><span>${esc(o.text)}</span><span class="sr-only">${o.done ? '(done)' : '(open)'}</span></li>`).join('')}</ul>` : '');

// ---- player tab ------------------------------------------------------------------------------------------------------------------
/** The Quests tab of one character. refresh() re-reads (one request); destroy() drops the data. */
export function mountQuestTab(el, { characterId }) {
  let dead = false;
  let seq = 0;
  const open = new Set();   // quests the player expanded (kept across refreshes)
  el.innerHTML = `${sectionHead({ id: 'quests-title', icon: 'item.map', title: 'Quests',
      action: '<button type="button" class="btn btn-sm btn-ghost" data-quest-refresh>Refresh</button>' })}
    <div data-quest-list aria-live="polite"><div class="spinner" role="status" aria-label="Loading quests"></div></div>`;
  const list = $('[data-quest-list]', el);

  function render(data) {
    const quests = data?.quests || [];
    if (!data?.campaign_id) { list.innerHTML = '<p class="muted">This character is not in a campaign, so there is no quest log.</p>'; return; }
    if (!quests.length) { list.innerHTML = '<p class="muted">No quests yet. Your DM adds them here.</p>'; return; }
    list.innerHTML = STATUS_ORDER.map((s) => {
      const rows = quests.filter((q) => q.status === s);
      if (!rows.length) return '';
      return `<h3 class="quest-group">${esc(STATUS[s])} <span class="tl-count">${rows.length}</span></h3>
        <div class="quest-list">${rows.map((q) => `<details class="card quest-card quest-${esc(q.status)}" data-quest="${esc(q.id)}" ${open.has(q.id) ? 'open' : ''}>
          <summary><span class="quest-title">${esc(q.title)}</span><span class="quest-badges">${statusBadge(q.status)}${ownerBadge(q)}${progress(q)}</span></summary>
          <div class="quest-body">${q.description ? `<p class="quest-desc">${esc(q.description)}</p>` : ''}${objectivesHTML(q)}
            ${!q.description && !q.objectives?.length ? '<p class="muted small">No details yet.</p>' : ''}</div></details>`).join('')}</div>`;
    }).join('');
  }

  async function refresh() {
    const my = ++seq;
    try {
      const data = await getCharacterQuests(characterId);
      if (!dead && my === seq) render(data);
    } catch (err) {
      if (!dead && my === seq) list.innerHTML = `<p class="gov-error" role="alert">${esc(err.message)}</p>`;
    }
  }

  el.addEventListener('click', (e) => { if (e.target.closest('[data-quest-refresh]')) refresh(); });
  el.addEventListener('toggle', (e) => {
    const d = e.target.closest?.('[data-quest]');
    if (d) { if (d.open) open.add(d.dataset.quest); else open.delete(d.dataset.quest); }
  }, true);
  refresh();
  return { refresh, characterId, el, destroy() { dead = true; seq += 1; el.innerHTML = ''; } };
}

// ---- DM Space section -----------------------------------------------------------------------------------------------------------
export async function dmQuestPanel(panel, alive, { campaignId, reload }) {
  let showArchived = false;
  try { showArchived = sessionStorage.getItem('tavern-ledger:dm-quests-archived') === '1'; } catch { /* optional */ }
  const data = await getCampaignQuests(campaignId, showArchived);
  if (!alive()) return;
  const live = data.quests.filter((q) => !q.archived_at);
  const archived = data.quests.filter((q) => q.archived_at);
  const who = (q) => (q.visibility === 'party' ? 'Whole party'
    : `${q.visibility === 'private' ? 'Private: ' : 'Individual: '}${q.target_name ? esc(q.target_name) : '<em>character deleted</em>'}${q.target_name && !q.target_in_campaign ? ' <span class="muted">(left the campaign)</span>' : ''}`);
  const row = (q, i, group) => `<li class="dm-item-know quest-dm-row" data-qid="${esc(q.id)}">
    <div class="quest-dm-head"><strong class="quest-title">${esc(q.title)}</strong> ${statusBadge(q.status)} ${progress(q)}</div>
    <p class="small muted">${who(q)}</p>
    ${q.objectives.length ? `<ul class="quest-objectives quest-dm-objectives">${q.objectives.map((o) => `<li class="${o.done ? 'is-done' : ''}"><label class="hb-inline">
      <input type="checkbox" data-qo="${esc(o.id)}" ${o.done ? 'checked' : ''} ${q.archived_at ? 'disabled' : ''}> ${esc(o.text)}</label></li>`).join('')}</ul>` : ''}
    ${q.dm_notes ? `<p class="small quest-dm-notes"><span class="muted">DM notes:</span> ${esc(q.dm_notes)}</p>` : ''}
    <div class="dm-action-row">
      ${q.archived_at ? `<button type="button" class="btn btn-xs" data-qa="restore">Restore</button>` : `
      <button type="button" class="btn btn-xs" data-qa="edit">Edit</button>
      <label class="sr-only" for="qs-${esc(q.id)}">Status</label>
      <select class="quest-status-select" id="qs-${esc(q.id)}" data-qa-status>${STATUS_ORDER.map((s) => `<option value="${s}" ${q.status === s ? 'selected' : ''}>${esc(STATUS[s])}</option>`).join('')}</select>
      <button type="button" class="btn btn-xs btn-ghost" data-qa="up" ${i === 0 ? 'disabled' : ''} aria-label="Move up">▲</button>
      <button type="button" class="btn btn-xs btn-ghost" data-qa="down" ${i === group.length - 1 ? 'disabled' : ''} aria-label="Move down">▼</button>
      <button type="button" class="btn btn-xs btn-ghost" data-qa="archive">Archive</button>`}
    </div></li>`;
  panel.innerHTML = `
    <section class="card dm-card dm-wide" data-quest-dm><h2>Quests</h2>
      <p class="small muted">Party quests are seen by every character of the campaign. Individual quests belong to one character and the rest
        of the party sees them too. Private quests are seen only by you and that character's player. DM notes are never shown to players;
        only you tick objectives.</p>
      <div class="dm-action-row"><button type="button" class="btn btn-gold btn-sm" data-qa="new">+ New quest</button>
        <label class="hb-inline small"><input type="checkbox" data-qa-archived ${showArchived ? 'checked' : ''}> Show archived</label></div>
      ${live.length ? STATUS_ORDER.map((s) => {
    const group = live.filter((q) => q.status === s);
    return group.length ? `<h3 class="quest-group">${esc(STATUS[s])} <span class="tl-count">${group.length}</span></h3><ul class="quest-dm-list">${group.map((q, i) => row(q, i, group)).join('')}</ul>` : '';
  }).join('') : '<p class="muted">No quests yet.</p>'}
      ${showArchived ? `<h3 class="quest-group">Archived <span class="tl-count">${archived.length}</span></h3>${archived.length
    ? `<ul class="quest-dm-list">${archived.map((q, i) => row(q, i, archived)).join('')}</ul>` : '<p class="muted small">Nothing archived.</p>'}` : ''}
    </section>`;

  const find = (id) => data.quests.find((q) => q.id === id);
  const run = async (fn, ok) => { try { await fn(); if (ok) toast(ok, 'good'); } catch (err) { toast(err.message, 'bad', 5000); } reload(); };

  panel.addEventListener('change', (e) => {
    if (e.target.matches('[data-qa-archived]')) {
      try { sessionStorage.setItem('tavern-ledger:dm-quests-archived', e.target.checked ? '1' : '0'); } catch { /* optional */ }
      reload();
      return;
    }
    const li = e.target.closest('[data-qid]');
    if (!li) return;
    if (e.target.matches('[data-qo]')) { e.target.disabled = true; run(() => setObjective(e.target.dataset.qo, e.target.checked)); return; }
    if (e.target.matches('[data-qa-status]')) run(() => setQuestStatus(li.dataset.qid, e.target.value), `Marked ${STATUS[e.target.value].toLowerCase()}.`);
  });
  panel.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-qa]');
    if (!b) return;
    const a = b.dataset.qa;
    if (a === 'new') return questEditor(campaignId, null, data.characters, reload);
    const q = find(b.closest('[data-qid]')?.dataset.qid);
    if (!q) return;
    if (a === 'edit') return questEditor(campaignId, q, data.characters, reload);
    if (a === 'restore') return run(() => archiveQuest(q.id, false), 'Restored.');
    if (a === 'archive') {
      if (!await confirmDialog(`Archive "${q.title}"? Players stop seeing it. Nothing is deleted: tick "Show archived" to restore it.`, { title: 'Archive quest', okLabel: 'Archive' })) return;
      return run(() => archiveQuest(q.id, true), 'Archived.');
    }
    if (a === 'up' || a === 'down') {
      const group = live.filter((x) => x.status === q.status);
      const i = group.indexOf(q);
      const j = a === 'up' ? i - 1 : i + 1;
      if (j < 0 || j >= group.length) return;
      [group[i], group[j]] = [group[j], group[i]];
      b.disabled = true;
      return run(() => reorderQuests(campaignId, group.map((x) => x.id)));
    }
  });
}

function questEditor(campaignId, quest, characters, reload) {
  const q = quest || { title: '', description: '', status: 'active', visibility: 'party', target_character_id: null, dm_notes: '', objectives: [] };
  const objRow = (o = {}) => `<li class="inv-form-row quest-obj-edit" data-obj="${esc(o.id || '')}">
    <input type="checkbox" data-obj-done ${o.done ? 'checked' : ''} aria-label="Done">
    <input type="text" data-obj-text maxlength="300" value="${esc(o.text || '')}" placeholder="Objective" aria-label="Objective" required style="flex:1;min-width:12em">
    <button type="button" class="btn btn-xs btn-ghost" data-obj-remove aria-label="Remove objective">✕</button></li>`;
  const m = openModal({
    title: quest ? 'Edit quest' : 'New quest',
    wide: true,
    body: `<form class="quest-editor" data-quest-form novalidate>
      <label class="field"><span>Title</span><input type="text" name="title" maxlength="120" required value="${esc(q.title)}"></label>
      <label class="field"><span>Description (players see it)</span><textarea name="description" rows="4" maxlength="4000">${esc(q.description)}</textarea></label>
      <div class="inv-form-row">
        <label class="field"><span>Who sees it</span><select name="visibility">${Object.entries(VIS).map(([k, l]) => `<option value="${k}" ${q.visibility === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
        <label class="field" data-target-field ${q.visibility === 'party' ? 'hidden' : ''}><span>Character</span><select name="target">
          <option value="">— choose —</option>${characters.map((c) => `<option value="${esc(c.id)}" ${q.target_character_id === c.id ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}
          ${q.target_character_id && !characters.some((c) => c.id === q.target_character_id) ? `<option value="${esc(q.target_character_id)}" selected>${esc(q.target_name || 'Former member')}</option>` : ''}</select></label>
        <label class="field"><span>Status</span><select name="status">${STATUS_ORDER.map((s) => `<option value="${s}" ${q.status === s ? 'selected' : ''}>${esc(STATUS[s])}</option>`).join('')}</select></label>
      </div>
      <fieldset class="field-multi"><legend class="small">Objectives (only you tick them; players see the ticks)</legend>
        <ul class="quest-obj-list" data-obj-list>${(q.objectives || []).map(objRow).join('')}</ul>
        <button type="button" class="btn btn-xs" data-obj-add>+ Objective</button></fieldset>
      <label class="field"><span>DM notes (hidden: never shown to players)</span><textarea name="dm_notes" rows="3" maxlength="4000">${esc(q.dm_notes || '')}</textarea></label>
      <p class="gov-error" data-quest-err hidden role="alert"></p>
    </form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-quest-save>Save</button>',
  });
  const form = $('[data-quest-form]', m.el);
  const err = $('[data-quest-err]', m.el);
  form.addEventListener('change', (e) => {
    if (e.target.name === 'visibility') $('[data-target-field]', form).hidden = e.target.value === 'party';
  });
  form.addEventListener('click', (e) => {
    if (e.target.closest('[data-obj-add]')) {
      $('[data-obj-list]', form).insertAdjacentHTML('beforeend', objRow());
      $$('[data-obj-text]', form).pop()?.focus();
    } else if (e.target.closest('[data-obj-remove]')) e.target.closest('[data-obj]').remove();
  });
  $('[data-quest-save]', m.el).addEventListener('click', async (e) => {
    const f = form.elements;
    const vis = f.visibility.value;
    const payload = {
      ...(quest ? { id: quest.id } : {}),
      title: f.title.value.trim(), description: f.description.value, visibility: vis, status: f.status.value,
      target_character_id: vis === 'party' ? null : (f.target.value || null), dm_notes: f.dm_notes.value,
      objectives: $$('[data-obj]', form).map((li) => ({ ...(li.dataset.obj ? { id: li.dataset.obj } : {}),
        text: $('[data-obj-text]', li).value.trim(), done: $('[data-obj-done]', li).checked })).filter((o) => o.text),
    };
    const fail = (msg) => { err.textContent = msg; err.hidden = false; };
    if (!payload.title) return fail('A quest needs a title.');
    if (vis !== 'party' && !payload.target_character_id) return fail('Choose the character this quest belongs to.');
    e.target.disabled = true;
    try {
      await saveQuest(campaignId, payload, quest ? quest.revision : null);
      toast('Quest saved.', 'good');
      m.close();
      reload();
    } catch (ex) { fail(ex.message); e.target.disabled = false; }
  });
}
