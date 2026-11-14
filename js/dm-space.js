// DM Space (docs/DM_SPACE.md): the DM's campaign workspace, separate from the character sheets. Overview (urgent work first),
// Approvals, Party, Content (custom content library + editors), Assign, Hidden, Rules (governance and content policy), Audit.
// Visible only to campaign DMs and admins; every read and write is checked again by the database.

import { supabase } from './supabase.js?v=37';
import { $, $$, esc, toast, openModal, confirmDialog, debounce, focusByKey } from './utils.js?v=37';
import * as dm from './dm-api.js?v=37';
import * as gov from './governance-api.js?v=37';
import { icon } from './icons.js?v=37';
import { diffHTML, stepHTML, statusChip, fieldLabel } from './request-ui.js?v=37';
import { openContentEditor, openDuplicateOfficial, openUsage, contentManagementEnabled, TYPE, STATUS as CSTATUS } from './content-editors.js?v=37';
import { CRAFTING } from './config.js?v=37';
import { openItemIconsDialog } from './custom-icons.js?v=37';

// Crafting (docs/CRAFTING_V1.md) only when js/config.js CRAFTING is not 'off'; its module is loaded on demand (never with 'off')
const craftingOn = () => (CRAFTING || 'off') !== 'off';
const SECTIONS = [['overview', 'Overview'], ['approvals', 'Approvals'], ['party', 'Party'], ['content', 'Content'], ['assign', 'Assign'],
  ['hidden', 'Hidden'], ['quests', 'Quests'], ...(craftingOn() ? [['crafting', 'Crafting']] : []), ['rules', 'Campaign rules'], ['audit', 'Audit log']];
const craftingModule = () => import('./crafting.js?v=37');
const CAT_LABEL = { identity: 'Character identity', core_build: 'Core build', feats_choices: 'Feats and choices', spells: 'Spells', inventory: 'Inventory',
  runtime: 'Gameplay', content: 'Content', dm_control: 'DM control' };
const MODES = {
  spell: [['known', 'Known spell'], ['spellbook', 'Wizard spellbook'], ['always_prepared', 'Always prepared'], ['innate', 'Innate gift (campaign source)']],
  item: [['inventory', 'Character inventory'], ['stash', 'Party stash']],
  feat: [['dm_grant', 'DM grant'], ['campaign_reward', 'Campaign reward']],
  creature: [['seen_form', 'Wild Shape form (grant as seen)'], ['companion', 'Companion']],
  companion: [['companion', 'Companion']], background: [['direct', 'Set as background']], lineage: [['direct', 'Set as lineage']],
  condition: [['visible', 'Visible condition'], ['hidden', 'Hidden effect (DM only)']],
};
const fmt = (t) => (t ? new Date(t).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '');
const store = { get: (k) => { try { return localStorage.getItem(`tavern-ledger:dm-${k}`); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(`tavern-ledger:dm-${k}`, v); } catch { /* optional */ } } };

let root = null;
let campaigns = [];
let campaignId = null;
let section = 'overview';
let channel = null;
let seq = 0;
let assignPreset = null;     // {contentId, characterIds}
let approvalFilter = { status: 'submitted', character: '', action: '' };

export async function mountDmSpace(container, { section: sec = 'overview', id = null } = {}) {
  unmountDmSpace();
  root = document.createElement('div');
  root.className = 'dm-space';
  container.replaceChildren(root);
  root.innerHTML = '<div class="center-wrap"><div class="spinner"></div></div>';
  try { campaigns = await dm.getMyDmCampaigns(); } catch (err) { root.innerHTML = `<p class="gov-error">${esc(err.message)}</p>`; return; }
  if (!campaigns.length) { root.innerHTML = '<div class="empty-state"><h2>DM Space</h2><p>You are not the DM of a campaign yet.</p></div>'; return; }
  const remembered = store.get('campaign');
  campaignId = campaigns.some((c) => c.id === remembered) ? remembered : campaigns[0].id;
  section = SECTIONS.some(([k]) => k === sec) ? sec : 'overview';
  if (id && section === 'approvals') setTimeout(() => openReview(id), 300);
  root.addEventListener('click', onClick);
  root.addEventListener('change', onChange);
  frame();
  subscribe();
  show(section);
  hiddenBadge();
}

export function unmountDmSpace() {
  if (channel) supabase.removeChannel(channel);
  channel = null;
  root?.removeEventListener('click', onClick);
  root?.removeEventListener('change', onChange);
  root = null;
}

const camp = () => campaigns.find((c) => c.id === campaignId);

// the number of open examine requests on the Hidden tab (20261112000400)
function setHiddenBadge(n) {
  const t = root && $('[data-dm-section="hidden"]', root);
  if (t) t.innerHTML = `Hidden${n ? ` <span class="dm-count" data-examine-count title="Examine requests waiting for you">${n}</span>` : ''}`;
}
async function hiddenBadge() {
  const forCampaign = campaignId;
  try {
    const n = await dm.getPendingExamineCount(forCampaign);   // a count only: this runs on every DM Space realtime event
    if (forCampaign === campaignId) setHiddenBadge(Number(n) || 0);
  } catch { /* the badge is optional */ }
  craftBadge();
}

// the number of crafting attempts waiting for the DM (only when Crafting is on)
function setCraftBadge(n) {
  const t = root && $('[data-dm-section="crafting"]', root);
  if (t) t.innerHTML = `Crafting${n ? ` <span class="dm-count" data-craft-count title="Crafting attempts waiting for you">${n}</span>` : ''}`;
}
async function craftBadge() {
  if (!craftingOn()) return;
  const forCampaign = campaignId;
  try {
    const n = await (await craftingModule()).pendingCraftCount(forCampaign);
    if (forCampaign === campaignId) setCraftBadge(Number(n) || 0);
  } catch { /* the badge is optional */ }
}

// ---- crafting (docs/CRAFTING_V1.md) --------------------------------------------------------------------------------------------
async function crafting(panel, alive) {
  const m = await craftingModule();
  if (!alive()) return;
  await m.dmCraftingPanel(panel, alive, { campaignId, onCount: setCraftBadge, reload: () => { if (alive()) show('crafting'); } });
}

// ---- quest log (docs/QUEST_LOG.md): its module is loaded only when this section opens ---------------------------------------
async function quests(panel, alive) {
  const m = await import('./quests.js?v=37');
  if (!alive()) return;
  await m.dmQuestPanel(panel, alive, { campaignId, reload: () => { if (alive()) show('quests'); } });
}

function frame() {
  root.innerHTML = `
  <header class="dm-head">
    <div class="dm-title"><span class="dm-kicker">DM Space</span><h1>${esc(camp()?.name || '')}</h1>
      <span class="small muted">${esc(gov.PRESET_TEXT[camp()?.preset] || '')}</span></div>
    <div class="dm-head-actions">
      <label class="field dm-camp"><span>Campaign</span><select data-dm-campaign>${campaigns.map((c) => `<option value="${esc(c.id)}" ${c.id === campaignId ? 'selected' : ''}>${esc(c.name)}${c.pending ? ` (${c.pending})` : ''}</option>`).join('')}</select></label>
      <button type="button" class="btn btn-gold" data-dm="create" data-focus-key="dm-create">+ Create content</button>
    </div>
  </header>
  <nav class="dm-nav" aria-label="DM Space sections">
    <div class="dm-tabs" role="tablist">${SECTIONS.map(([k, l]) => `<button type="button" role="tab" class="tab" data-dm-section="${k}" aria-selected="${k === section}"
      data-focus-key="dm-tab:${k}">${esc(l)}${k === 'approvals' && camp()?.pending ? ` <span class="dm-count">${camp().pending}</span>` : ''}</button>`).join('')}</div>
    <label class="dm-section-select"><span class="sr-only">Section</span><select data-dm-section-select>${SECTIONS.map(([k, l]) => `<option value="${k}" ${k === section ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
  </nav>
  <h2 class="sr-only" data-dm-heading>${esc((SECTIONS.find(([k]) => k === section) || SECTIONS[0])[1])}</h2>
  <section class="dm-panel" data-dm-panel aria-live="polite"></section>`;
}

function show(sec) {
  section = sec;
  store.set('section', sec);
  history.replaceState(null, '', `#/dm/${sec}`);
  $$('[data-dm-section]', root).forEach((b) => b.setAttribute('aria-selected', String(b.dataset.dmSection === sec)));
  const sel = $('[data-dm-section-select]', root);
  if (sel) sel.value = sec;
  const hd = $('[data-dm-heading]', root);   // the section's h2 (visually the selected tab), so card titles (h3) never skip a level
  if (hd) hd.textContent = (SECTIONS.find(([k]) => k === sec) || SECTIONS[0])[1];
  // a fresh panel element per section: listeners of the previous section never pile up
  const old = $('[data-dm-panel]', root);
  const panel = old.cloneNode(false);
  old.replaceWith(panel);
  panel.innerHTML = '<div class="center-wrap"><div class="spinner"></div></div>';
  const my = ++seq;
  const render = { overview, approvals, party, content, assign, hidden, quests, crafting, rules, audit }[sec];
  render(panel, () => my === seq && root).catch((err) => { if (my === seq && root) panel.innerHTML = `<p class="gov-error" role="alert">${esc(err.message)}</p>`; });
}

function subscribe() {
  if (channel) supabase.removeChannel(channel);
  const refresh = debounce(async () => {
    if (!root) return;
    try { campaigns = await dm.getMyDmCampaigns(); } catch { /* keep the old counts */ }
    const counter = $('[data-dm-section="approvals"]', root);
    if (counter) counter.innerHTML = `Approvals${camp()?.pending ? ` <span class="dm-count">${camp().pending}</span>` : ''}`;
    hiddenBadge();
    if (['overview', 'approvals', 'party'].includes(section) && !document.querySelector('.modal-backdrop:not([data-closing])')) show(section);
  }, 700);
  channel = supabase.channel(`dm-${campaignId}-${Math.random().toString(36).slice(2, 8)}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'change_requests', filter: `campaign_id=eq.${campaignId}` }, refresh)
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'characters', filter: `campaign_id=eq.${campaignId}` }, refresh)
    .subscribe();
}

// ---- events ------------------------------------------------------------------------------------------------------------------
function onChange(e) {
  if (e.target.matches('[data-dm-campaign]')) {
    campaignId = e.target.value;
    store.set('campaign', campaignId);
    frame();
    subscribe();
    show(section);
    hiddenBadge();
  } else if (e.target.matches('[data-dm-section-select]')) show(e.target.value);
}

async function onClick(e) {
  const tab = e.target.closest('[data-dm-section]');
  if (tab) { show(tab.dataset.dmSection); return; }
  const b = e.target.closest('[data-dm]');
  if (!b) return;
  const a = b.dataset.dm;
  if (a === 'create') return createMenu();
  if (a === 'review') return openReview(b.dataset.id);
  if (a === 'goto') { if (b.dataset.filter) approvalFilter = { ...approvalFilter, ...JSON.parse(b.dataset.filter) }; return show(b.dataset.to); }
  if (a === 'item-icons') return openItemIconsDialog({ campaignId });
  if (a === 'dup-official') return openDuplicateOfficial({ campaignId, onCreated: (c) => { show('content'); openContentEditor({ content: { id: c.id }, campaignId, onChanged: () => show('content') }); } });
  if (a === 'usage-content') return openUsage({ id: b.dataset.id }, { onChanged: () => show('content'), onDeleted: () => show('content') });
  if (a === 'edit-content') return openContentEditor({ content: { id: b.dataset.id }, campaignId, onChanged: () => show('content'), onAssign: (c) => { assignPreset = { contentId: c.id }; show('assign'); } });
  if (a === 'new-content') return openContentEditor({ content: { content_type: b.dataset.type, campaign_id: b.dataset.private ? null : campaignId }, campaignId,
    onChanged: () => { if (section === 'content') show('content'); }, onAssign: (c) => { assignPreset = { contentId: c.id }; show('assign'); } });
  if (a === 'assign-to') { assignPreset = { characterIds: [b.dataset.id] }; return show('assign'); }
  if (a === 'lock') return lockDialog(b.dataset.id, b.dataset.name, b.dataset.mode);
  if (a === 'setup') { try { await gov.setSetupComplete(b.dataset.id, b.dataset.complete === '1'); toast('Saved.', 'good'); show(section); } catch (err) { toast(err.message, 'bad'); } return; }
  if (a === 'condition') return conditionDialog(b.dataset.id, b.dataset.name, b.dataset.hidden === '1');
  if (a === 'note') return noteDialog(b.dataset.id, b.dataset.name);
  if (a === 'hidden-of') { store.set('hidden-character', b.dataset.id); return show('hidden'); }
}

function createMenu() {
  const m = openModal({ title: 'Create content', body: `<p class="muted small">Custom content starts as a draft that only DMs see. Publish it to make it available in
      ${esc(camp()?.name || 'the campaign')}.</p><div class="dm-create-grid">${Object.entries(TYPE).map(([k, t]) => `<button type="button" class="dm-create-tile" data-type="${k}">
      <span class="dm-ico" aria-hidden="true">${t.icon}</span><span>${esc(t.label)}</span></button>`).join('')}</div>
      <label class="check-field"><input type="checkbox" data-private><span>Keep it in my private library (reuse in several campaigns; copy it to a campaign to publish)</span></label>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button>' });
  m.el.addEventListener('click', (e) => {
    const t = e.target.closest('[data-type]');
    if (!t) return;
    const priv = $('[data-private]', m.el).checked;
    m.close();
    openContentEditor({ content: { content_type: t.dataset.type, campaign_id: priv ? null : campaignId }, campaignId,
      onChanged: () => { if (section === 'content' || section === 'overview') show(section); }, onAssign: (c) => { assignPreset = { contentId: c.id }; show('assign'); } });
  });
}

// ---- overview ------------------------------------------------------------------------------------------------------------------
async function overview(panel, alive) {
  const o = await dm.getDmOverview(campaignId);
  if (!alive()) return;
  const party = (await dm.getDmParty(campaignId, o.character_ids)).characters;
  if (!alive()) return;
  const governed = camp()?.preset && camp().preset !== 'relaxed';
  o.warnings = [
    ...party.filter((x) => x.hp.current <= 0).map((x) => ({ severity: 0, character_id: x.id, text: `${x.name} is at 0 HP (death saves ${x.death_saves.successes} / ${x.death_saves.failures})` })),
    ...party.filter((x) => x.hp.current > 0 && x.hp.current * 4 <= x.hp.max).map((x) => ({ severity: 1, character_id: x.id, text: `${x.name} is low on HP (${x.hp.current} / ${x.hp.max})` })),
    ...party.filter((x) => x.incomplete_choices > 0).map((x) => ({ severity: 2, character_id: x.id, text: `${x.name} has ${x.incomplete_choices} open choice(s)` })),
    ...(governed ? party.filter((x) => !x.setup_complete).map((x) => ({ severity: 3, character_id: x.id, text: `${x.name} is still in initial setup (builds freely)` })) : []),
  ];
  o.transformations = party.filter((x) => x.transformation).map((x) => ({ character_name: x.name, form: x.transformation }));
  o.conditions = party.filter((x) => partyConditionNames(x).length)
    .map((x) => ({ character_name: x.name, conditions: x.conditions, campaign_conditions: x.campaign_conditions }));
  o.locked = party.filter((x) => x.lock_mode !== 'unlocked').map((x) => ({ character_name: x.name, lock_mode: x.lock_mode }));
  const c = o.counts;
  const card = (n, label, to, cls = '', filter = null) => `<button type="button" class="dm-stat ${cls} ${n ? '' : 'is-zero'}" data-dm="goto" data-to="${to}" ${filter ? `data-filter='${esc(JSON.stringify(filter))}'` : ''}>
    <strong>${n}</strong><span>${esc(label)}</span></button>`;
  // one list, most urgent first: requests waiting, failed applies, characters at 0 / low HP, open choices, setup
  const needs = [
    ...o.pending.map((r) => `<li class="dm-need dm-sev-req"><span class="dm-need-kind">${icon('ui/pending', { size: 20 })}Request</span>
      <button type="button" class="dm-link" data-dm="review" data-id="${esc(r.id)}"><strong>${esc(r.character_name)}</strong>: ${esc(r.title)}</button>
      ${r.stale ? '<span class="req-chip req-stale">Changed meanwhile</span>' : ''}
      <button type="button" class="btn btn-sm btn-gold" data-dm="review" data-id="${esc(r.id)}">Review</button></li>`),
    ...(c.failed ? [`<li class="dm-need dm-sev-0"><span class="dm-need-kind">${icon('ui/incomplete', { size: 20 })}Not applied</span>
      <span>${c.failed} approved request${c.failed === 1 ? '' : 's'} could not be applied</span>
      <button type="button" class="btn btn-sm" data-dm="goto" data-to="approvals" data-filter='${esc(JSON.stringify({ status: 'apply_failed' }))}'>Open</button></li>`] : []),
    ...o.warnings.map((w) => `<li class="dm-need dm-sev-${w.severity}"><span class="dm-need-kind">${icon(w.severity <= 1 ? 'actions/death-saves' : 'ui/incomplete', { size: 20 })}${
      w.severity === 0 ? 'Down' : w.severity === 1 ? 'Low HP' : w.severity === 2 ? 'Choices' : 'Setup'}</span>
      <a href="#/c/${esc(w.character_id)}">${esc(w.text)}</a></li>`),
  ];
  panel.innerHTML = `
    ${o.governance?.report && !o.governance.updated_by ? `<div class="gov-banner">This campaign existed before campaign rules: it keeps the previous behavior (players manage their characters).
      <button type="button" class="btn btn-xs" data-dm="goto" data-to="rules">Review the rules</button></div>` : ''}
    <section class="card dm-card dm-needs" aria-labelledby="dm-needs-title">
      <h2 id="dm-needs-title">${icon('dm/campaign', { size: 24 })}Needs you</h2>
      ${needs.length ? `<ul class="dm-need-list">${needs.join('')}</ul>`
        : `<p class="calm-note">${icon('dm/approved', { size: 22 })}Everything is up to date: no requests waiting and nobody in trouble.</p>`}
    </section>
    <div class="dm-stats">
      ${card(c.pending, 'pending approvals', 'approvals', c.pending ? 'is-urgent' : '', { status: 'submitted' })}
      ${card(c.failed, 'could not be applied', 'approvals', c.failed ? 'is-warn' : '', { status: 'apply_failed' })}
      ${card(c.returned, 'returned to players', 'approvals', '', { status: 'returned_for_changes' })}
      ${card(c.characters, c.characters === 1 ? 'character' : 'characters', 'party')}
      ${card(c.content_drafts, 'content drafts', 'content')}
      ${card(c.content_published, 'published content', 'content')}
    </div>
    <div class="dm-columns">
      <section class="card dm-card"><h2>${icon('ui/play', { size: 22 })}At the table</h2>
        ${o.transformations.length ? `<p class="small"><strong>Wild Shape:</strong> ${o.transformations.map((t) => `${esc(t.character_name)} as ${esc(t.form.creature)} (${t.form.hp_current}/${t.form.hp_max})`).join(' · ')}</p>` : ''}
        ${o.conditions.length ? `<p class="small"><strong>Conditions:</strong> ${o.conditions.map((x) => `${esc(x.character_name)}: ${esc(partyConditionNames(x).join(', '))}`).join(' · ')}</p>` : ''}
        ${o.locked.length ? `<p class="small"><strong>Locked:</strong> ${o.locked.map((l) => `${esc(l.character_name)} (${esc(gov.LOCK_LABEL[l.lock_mode])})`).join(' · ')}</p>` : ''}
        ${!o.transformations.length && !o.conditions.length && !o.locked.length ? '<p class="muted">No active forms, conditions or locks.</p>' : ''}
        <button type="button" class="btn btn-sm btn-quiet" data-dm="goto" data-to="party">Open the party</button>
      </section>
      <section class="card dm-card"><h2>${icon('ui/custom-content', { size: 22 })}Recent content</h2>
        ${o.recent_content.length ? `<ul class="small">${o.recent_content.map((x) => `<li>${TYPE[x.content_type]?.icon || ''} <button type="button" class="dm-link" data-dm="edit-content" data-id="${esc(x.content_id)}">${esc(x.name)}</button>
          <span class="muted">${esc(x.event.replace(/_/g, ' '))} · ${esc(fmt(x.at))}</span></li>`).join('')}</ul>` : '<p class="muted">No custom content yet. Spells, items, feats and creatures you create appear here.</p>'}
        <button type="button" class="btn btn-sm btn-gold" data-dm="create">+ Create content</button>
      </section>
      <section class="card dm-card dm-wide"><h2>Recent activity</h2>${timelineHTML(o.recent_activity)}
        <button type="button" class="btn btn-sm btn-quiet" data-dm="goto" data-to="audit">Full audit log</button></section>
    </div>`;
}

function timelineHTML(list) {
  if (!list?.length) return '<p class="muted">Nothing yet.</p>';
  return `<ol class="dm-timeline">${list.map((e) => `<li><span class="dm-when">${esc(fmt(e.created_at))}</span>
    <span class="dm-what">${e.visibility === 'dm' ? `<span class="chip chip-secret">${icon('ui/dm-secret', { size: 14 })}DM only</span> ` : ''}<strong>${esc(e.character_name || 'Campaign')}</strong> · ${esc(e.summary)}</span>
    <span class="dm-who muted small">${esc(e.actor_name || 'system')}${e.reason ? ` — ${esc(e.reason)}` : ''}</span>
    ${e.before || e.after ? `<details class="small"><summary>Details</summary>${e.after?.diff || e.before?.diff ? diffHTML(e.before?.diff || e.after?.diff) : `<p>Before: ${esc(JSON.stringify(e.before ?? '—'))}</p><p>After: ${esc(JSON.stringify(e.after ?? '—'))}</p>`}</details>` : ''}</li>`).join('')}</ol>`;
}

// ---- approvals ---------------------------------------------------------------------------------------------------------------
async function approvals(panel, alive) {
  const statuses = approvalFilter.status === 'all' ? null : approvalFilter.status === 'done' ? ['applied', 'approved'] : [approvalFilter.status];
  const [list, chars] = await Promise.all([gov.getCampaignChangeRequests(campaignId, { statuses, characterId: approvalFilter.character || null, action: approvalFilter.action || null }),
    dm.getCampaignCharacters(campaignId)]);
  const party = { characters: chars };
  if (!alive()) return;
  const chips = [['submitted', 'Pending'], ['apply_failed', 'Failed'], ['returned_for_changes', 'Returned'], ['done', 'Approved'], ['rejected', 'Rejected'], ['cancelled', 'Cancelled'], ['all', 'All']];
  panel.innerHTML = `
    <div class="dm-filters">
      <div class="chip-row" role="group" aria-label="Status">${chips.map(([k, l]) => `<button type="button" class="chip ${approvalFilter.status === k ? 'is-on' : ''}" data-af-status="${k}" aria-pressed="${approvalFilter.status === k}">${esc(l)}</button>`).join('')}</div>
      <label class="field"><span>Character</span><select data-af-character><option value="">All</option>${party.characters.map((p) => `<option value="${esc(p.id)}" ${approvalFilter.character === p.id ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}</select></label>
      <label class="field"><span>Kind</span><select data-af-action><option value="">All</option>${Object.entries(CAT_LABEL).filter(([k]) => !['content', 'dm_control'].includes(k)).map(([k, l]) => `<option value="${k}" ${approvalFilter.action === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
    </div>
    ${list.length ? `<div class="dm-req-grid">${list.map((r) => `<article class="dm-req-card ${r.stale ? 'is-stale' : ''}">
        <header>${statusChip(r.status)} ${r.stale ? '<span class="req-chip req-stale">Character changed meanwhile</span>' : ''}${r.edited_by_dm ? '<span class="req-chip">Edited by DM</span>' : ''}</header>
        <h3>${esc(r.title)}</h3>
        <p class="small"><strong>${esc(r.character_name)}</strong> · ${esc(r.requested_by_name || '')} · ${esc(fmt(r.submitted_at || r.created_at))}</p>
        <ul class="req-steps small">${r.steps.slice(0, 4).map(stepHTML).join('')}${r.steps.length > 4 ? `<li class="muted">+ ${r.steps.length - 4} more</li>` : ''}</ul>
        ${r.preview?.warnings?.length ? `<p class="small warn">Opens ${r.preview.warnings.length} new choice(s): ${esc(r.preview.warnings.join(', '))}</p>` : ''}
        ${r.player_note ? `<p class="small"><em>“${esc(r.player_note)}”</em></p>` : ''}
        ${r.apply_error ? `<p class="small gov-error">${esc(r.apply_error)}</p>` : ''}
        <button type="button" class="btn btn-sm ${r.status === 'submitted' ? 'btn-gold' : ''}" data-dm="review" data-id="${esc(r.id)}">${r.status === 'submitted' ? 'Review' : 'Open'}</button>
      </article>`).join('')}</div>` : `<p class="calm-note">${icon('dm/approved', { size: 22 })}${approvalFilter.status === 'submitted'
        ? 'Everything is up to date: no requests are waiting for you.' : 'No requests match this filter.'}</p>`}`;
  panel.addEventListener('click', (e) => {
    const s = e.target.closest('[data-af-status]');
    if (s) { approvalFilter.status = s.dataset.afStatus; show('approvals'); }
  });
  $('[data-af-character]', panel).addEventListener('change', (e) => { approvalFilter.character = e.target.value; show('approvals'); });
  $('[data-af-action]', panel).addEventListener('change', (e) => { approvalFilter.action = e.target.value; show('approvals'); });
}

async function openReview(id) {
  let p;
  try { p = await gov.previewChangeRequest(id); } catch (err) { toast(err.message, 'bad'); return; }
  const r = p.request;
  const reviewable = r.status === 'submitted';
  const m = openModal({ title: `Request: ${r.title}`, wide: true, body: `
    <p class="small">${statusChip(r.status)} <strong>${esc(r.character_name)}</strong> · ${esc(r.requested_by_name || '')} · sent ${esc(fmt(r.submitted_at || r.created_at))}
      · <a href="#/c/${esc(r.character_id)}">Open the sheet</a></p>
    ${p.stale ? `<div class="gov-banner gov-returned" role="alert"><strong>The character changed after this request was made.</strong> Check the new preview below, then refresh the request to approve it.
      <ul class="small">${(p.changed_assumptions || []).map((c) => `<li>${esc(fieldLabel(c.key))}: ${esc(JSON.stringify(c.then))} → ${esc(JSON.stringify(c.now))}</li>`).join('')}</ul>
      <button type="button" class="btn btn-sm" data-rv="refresh">Refresh request</button></div>` : ''}
    <div class="dm-review-cols">
      <section><h3 class="small-h">Requested changes</h3><ul class="req-steps">${r.steps.map(stepHTML).join('')}</ul>
        ${r.player_note ? `<p><strong>Player:</strong> ${esc(r.player_note)}</p>` : ''}${r.reason ? `<p class="small"><strong>Reason:</strong> ${esc(r.reason)}</p>` : ''}
        <h3 class="small-h">Campaign rule</h3><ul class="small">${(p.policy || []).map((x) => `<li>${esc(x.label)}: ${esc(gov.DECISION_LABEL[x.decision] || x.decision)}</li>`).join('')}</ul></section>
      <section><h3 class="small-h">Result on the sheet ${p.preview?.ok ? '' : '(cannot be applied as it is)'}</h3>
        ${p.preview?.ok ? diffHTML(p.preview.diff) : `<p class="gov-error">${esc(p.preview?.error || '')}</p>`}
        ${p.preview?.warnings?.length ? `<p class="small warn">New open choices: ${esc(p.preview.warnings.join(', '))}</p>` : ''}</section>
    </div>
    ${r.apply_error ? `<p class="gov-error">Last attempt: ${esc(r.apply_error)}</p>` : ''}
    <details class="small"><summary>History</summary><ol class="dm-timeline">${r.history.map((h) => `<li><span class="dm-when">${esc(fmt(h.at))}</span> ${esc(h.actor || '')}: ${esc(h.event.replace(/_/g, ' '))}${h.note ? ` — ${esc(h.note)}` : ''}</li>`).join('')}</ol></details>
    ${reviewable || r.status === 'apply_failed' ? `<label class="field"><span>Note to the player (needed to return, reject or edit)</span><textarea data-rv-note rows="2" maxlength="2000"></textarea></label>
      <label class="field dm-only-field"><span>Private DM note (never shown to the player)</span><textarea data-rv-private rows="2" maxlength="2000">${esc(r.private_note || '')}</textarea></label>
      <div data-rv-edit hidden></div>` : r.review_note ? `<p><strong>Your note:</strong> ${esc(r.review_note)}</p>` : ''}`,
    footer: `
      ${reviewable ? `<button type="button" class="btn btn-bad" data-rv="reject">Reject</button><button type="button" class="btn" data-rv="return">Return for changes</button>
        <button type="button" class="btn" data-rv="edit">Edit…</button><button type="button" class="btn btn-gold" data-rv="approve" ${p.stale ? 'disabled title="Refresh the request first"' : ''}>Approve</button>` : ''}
      ${r.status === 'apply_failed' ? '<button type="button" class="btn btn-gold" data-rv="retry">Retry</button><button type="button" class="btn" data-rv="cancel">Cancel request</button>' : ''}
      <button type="button" class="btn btn-ghost" data-close>Close</button>` });
  let editing = null;
  m.el.addEventListener('click', async (e) => {
    const a = e.target.closest('[data-rv]')?.dataset.rv;
    if (!a) return;
    const note = $('[data-rv-note]', m.el)?.value.trim() || null;
    const priv = $('[data-rv-private]', m.el)?.value.trim() || null;
    try {
      if (a === 'refresh') { await gov.refreshChangeRequest(id); m.close(); openReview(id); return; }
      if (a === 'edit') {
        editing = structuredClone(r.ops);
        const box = $('[data-rv-edit]', m.el);
        box.hidden = false;
        box.innerHTML = `<h3 class="small-h">Edit before approving</h3>${editing.map((o, i) => `<fieldset class="ce-section"><legend>${esc(r.steps[i]?.label || o.op)}</legend>
          ${Object.entries(o.args).map(([k, v]) => `<label class="field"><span>${esc(k.replace(/^p_/, '').replace(/_/g, ' '))}</span>
            <input data-edit-op="${i}" data-edit-key="${esc(k)}" value="${esc(typeof v === 'object' ? JSON.stringify(v) : v)}"></label>`).join('')}
          <label class="check-field"><input type="checkbox" data-edit-drop="${i}"><span>Leave this change out</span></label></fieldset>`).join('')}
          <button type="button" class="btn btn-gold" data-rv="approve-edited">Approve edited version</button>`;
        return;
      }
      if (a === 'approve-edited') {
        $$('[data-edit-op]', m.el).forEach((inp) => {
          const o = editing[Number(inp.dataset.editOp)];
          const raw = inp.value.trim();
          let v = raw;
          try { v = JSON.parse(raw); } catch { /* plain text */ }
          o.args[inp.dataset.editKey] = v;
        });
        const ops = editing.filter((_, i) => !$(`[data-edit-drop="${i}"]`, m.el)?.checked);
        if (!note) { toast('Explain your edit to the player in the note.', 'bad'); return; }
        const res = await gov.reviewChangeRequest(id, 'approve', { note, revision: r.revision, editedOps: ops, privateNote: priv });
        doneToast(res);
      } else if (a === 'approve') {
        const res = await gov.reviewChangeRequest(id, 'approve', { note, revision: r.revision, privateNote: priv });
        if (res.refused === 'stale') { toast(res.message, 'bad', 6000); m.close(); openReview(id); return; }
        doneToast(res);
      } else if (a === 'reject' || a === 'return') {
        if (!note) { toast('Tell the player why in the note.', 'bad'); $('[data-rv-note]', m.el)?.focus(); return; }
        if (a === 'reject' && !(await confirmDialog('Reject this request?', { danger: true, okLabel: 'Reject' }))) return;
        await gov.reviewChangeRequest(id, a, { note, revision: r.revision, privateNote: priv });
        toast(a === 'reject' ? 'Rejected.' : 'Returned to the player.');
      } else if (a === 'retry') { doneToast(await gov.retryChangeRequest(id)); }
      else if (a === 'cancel') { await gov.cancelChangeRequest(id, note); toast('Cancelled.'); }
      m.close();
      if (root) show(section);
    } catch (err) { toast(err.message, 'bad', 6000); }
  });
  const doneToast = (res) => toast(res.status === 'applied' ? 'Approved and applied.' : res.status === 'apply_failed' ? `Approved, but it could not be applied: ${res.apply_error}` : 'Saved.',
    res.status === 'applied' ? 'good' : 'bad', 6000);
}

// ---- party ---------------------------------------------------------------------------------------------------------------------
async function party(panel, alive) {
  const p = await dm.getDmParty(campaignId);
  if (!alive()) return;
  panel.innerHTML = p.characters.length ? `<div class="dm-party">${p.characters.map((c) => {
    const pct = c.hp.max ? Math.max(0, Math.min(100, Math.round((c.hp.current / c.hp.max) * 100))) : 0;
    const conds = partyConditionNames(c);
    return `<article class="dm-pc">
      <header class="dm-pc-head"><h3><a href="#/c/${esc(c.id)}">${esc(c.name)}</a></h3>
        <span class="small muted">${esc(c.owner_name || '')}</span>
        ${c.lock_mode !== 'unlocked' ? `<span class="req-chip req-lock">${icon('ui.locked', { size: 14 })}${esc(gov.LOCK_LABEL[c.lock_mode])}</span>` : ''}
        ${!c.setup_complete && camp()?.preset !== 'relaxed' ? '<span class="req-chip">In setup</span>' : ''}</header>
      <p class="small">${esc(c.classes.map((k) => `${k.class} ${k.level}${k.subclass ? ` (${k.subclass})` : ''}`).join(' / ') || `Level ${c.level}`)}
        ${c.lineage ? ` · ${esc(c.lineage)}` : ''}${c.background ? ` · ${esc(c.background)}` : ''}</p>
      <div class="dm-pc-vitals">
        <div class="hp-bar small" role="img" aria-label="HP ${c.hp.current} of ${c.hp.max}"><div class="hp-fill ${pct <= 25 ? 'is-low' : ''}" style="width:${pct}%"></div></div>
        <span><strong>HP</strong> ${c.hp.current}/${c.hp.max}${c.hp.temp ? ` +${c.hp.temp}` : ''}</span><span><strong>AC</strong> ${c.ac ?? '—'}</span>
        ${c.hp.current <= 0 ? `<span class="warn">Death saves ✓${c.death_saves.successes} ✗${c.death_saves.failures}</span>` : ''}
      </div>
      ${conds.length ? `<p class="small">${conds.map((x) => `<span class="condition-chip small">${esc(x)}</span>`).join(' ')}</p>` : ''}
      ${c.transformation ? `<p class="small">${icon('action.wild-shape', { size: 16 })}Wild Shape: ${esc(c.transformation.creature)} ${c.transformation.hp_current}/${c.transformation.hp_max}</p>` : ''}
      ${c.companions.length ? `<p class="small">Companions: ${esc(c.companions.map((x) => `${x.name} ${x.hp_current}/${x.hp_max}`).join(', '))}</p>` : ''}
      ${c.depleted_resources.length ? `<p class="small muted">Spent: ${esc(c.depleted_resources.join(', '))}</p>` : ''}
      <p class="small">${c.pending_requests ? `<button type="button" class="dm-link" data-dm="goto" data-to="approvals" data-filter='${esc(JSON.stringify({ character: c.id, status: 'submitted' }))}'>${icon('ui.approval', { size: 16 })}${c.pending_requests} request(s)</button>` : ''}
        ${c.incomplete_choices ? `<span class="warn">${c.incomplete_choices} open choice(s)</span>` : ''}${c.hidden_notes ? ` <span class="muted">${icon('ui.dm-secret', { size: 14 })}${c.hidden_notes} hidden note(s)</span>` : ''}</p>
      <details class="dm-pc-actions"><summary>Actions</summary><div class="dm-action-row">
        <a class="btn btn-sm" href="#/c/${esc(c.id)}">Open sheet</a>
        <button type="button" class="btn btn-sm" data-dm="condition" data-id="${esc(c.id)}" data-name="${esc(c.name)}">Add condition</button>
        <button type="button" class="btn btn-sm" data-dm="condition" data-id="${esc(c.id)}" data-name="${esc(c.name)}" data-hidden="1">Add hidden effect</button>
        <button type="button" class="btn btn-sm" data-dm="note" data-id="${esc(c.id)}" data-name="${esc(c.name)}">Add DM note</button>
        <button type="button" class="btn btn-sm" data-dm="assign-to" data-id="${esc(c.id)}">Assign content</button>
        <button type="button" class="btn btn-sm" data-dm="lock" data-id="${esc(c.id)}" data-name="${esc(c.name)}" data-mode="${esc(c.lock_mode)}">Lock…</button>
        <button type="button" class="btn btn-sm" data-dm="setup" data-id="${esc(c.id)}" data-complete="${c.setup_complete ? '0' : '1'}">${c.setup_complete ? 'Reopen setup' : 'Finish setup'}</button>
        <button type="button" class="btn btn-sm" data-dm="hidden-of" data-id="${esc(c.id)}">Hidden info</button>
      </div></details>
    </article>`;
  }).join('')}</div>` : '<p class="muted">No characters in this campaign yet.</p>';
}

function lockDialog(id, name, mode) {
  const m = openModal({ title: `Lock ${name}`, body: `<fieldset class="field-multi"><legend>Lock</legend>${Object.entries(gov.LOCK_LABEL).map(([k, l]) =>
    `<label class="check-field"><input type="radio" name="lock" value="${k}" ${k === mode ? 'checked' : ''}><span><strong>${esc(l)}</strong>
      <span class="muted small">${esc({ unlocked: 'Normal campaign rules.', progression_locked: 'Level, feats, lineage, background and choices paused.',
        build_locked: 'All permanent changes paused; gameplay and equipping still work.', fully_locked: 'Only you can change the character.',
        archived: 'Read-only for everyone until you restore it.' }[k])}</span></span></label>`).join('')}</fieldset>
      <label class="field"><span>Reason (shown to the player)</span><input data-reason maxlength="300"></label>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Save</button>' });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    try { await gov.setCharacterLock(id, $('[name=lock]:checked', m.el).value, $('[data-reason]', m.el).value.trim() || null); toast('Lock saved.', 'good'); m.close(); show(section); }
    catch (err) { toast(err.message, 'bad'); }
  });
}

/** A character's conditions for the DM: the rows (hidden ones marked). Since 20261112000200 characters.conditions is only the
 *  mirror of the visible rows, so it is shown only when there are no rows (an older server, or nothing applied). */
function partyConditionNames(x) {
  const rows = x.campaign_conditions || [];
  if (rows.length) return rows.map((k) => (k.hidden ? `${k.name} (hidden)` : k.name));
  return (x.conditions || []).map((v) => (typeof v === 'string' ? v : v?.name || String(v)));
}

async function conditionDialog(id, name, hiddenMode) {
  let lib = [];
  try { lib = (await dm.getContentLibrary(campaignId, 'condition')).filter((x) => x.status === 'published'); } catch { /* none */ }
  const m = openModal({ title: `${hiddenMode ? 'Hidden effect' : 'Condition'} for ${name}`, body: `
    ${lib.length ? `<label class="field"><span>Custom condition</span><select data-c-version><option value="">— a named condition —</option>${lib.map((x) => `<option value="${esc(x.id)}">${esc(x.name)}</option>`).join('')}</select></label>` : ''}
    <label class="field"><span>Name</span><input data-c-name maxlength="80" placeholder="e.g. Poisoned, Cursed by the hag"></label>
    <label class="field"><span>Note${hiddenMode ? ' (shown when you reveal it)' : ''}</span><input data-c-note maxlength="500"></label>
    <label class="field"><span>Ends at (optional timer)</span><input type="datetime-local" data-c-exp></label>
    ${hiddenMode ? '<p class="muted small">Hidden effects are visible only to DMs until you reveal them.</p>' : ''}`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Apply</button>' });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const libId = $('[data-c-version]', m.el)?.value;
    try {
      const exp = $('[data-c-exp]', m.el).value ? new Date($('[data-c-exp]', m.el).value).toISOString() : null;
      if (libId) await dm.assignContent(libId, [id], hiddenMode ? 'hidden' : 'visible', { note: $('[data-c-note]', m.el).value || null, expires_at: exp });
      else await dm.applyCondition(id, { name: $('[data-c-name]', m.el).value, hidden: hiddenMode, note: $('[data-c-note]', m.el).value || null, expiresAt: exp });
      toast('Applied.', 'good'); m.close(); show(section);
    } catch (err) { toast(err.message, 'bad'); }
  });
}

function noteDialog(id, name, note = null) {
  const m = openModal({ title: `DM note: ${name}`, body: `
    <label class="field"><span>Title</span><input data-n-title maxlength="120" value="${esc(note?.title || '')}"></label>
    <label class="field dm-only-field"><span>Secret note</span><textarea data-n-body rows="4" maxlength="4000">${esc(note?.body || '')}</textarea></label>
    <label class="field"><span>What the player learns when you reveal it (optional)</span><input data-n-reveal maxlength="1000" value="${esc(note?.reveal_note || '')}"></label>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Save</button>' });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    try { await dm.saveDmNote(id, $('[data-n-title]', m.el).value, $('[data-n-body]', m.el).value, note?.id || null, $('[data-n-reveal]', m.el).value || null); toast('Note saved.', 'good'); m.close(); if (section === 'hidden') show('hidden'); }
    catch (err) { toast(err.message, 'bad'); }
  });
}

const rarityChipHTML = (r) => (r ? `<span class="badge inv-b-rarity${r.magic ? ' inv-b-magic' : ''} inv-r-${esc(r.id)}" title="Rarity: ${esc(r.id === 'unknown' ? 'Unknown rarity' : r.name)}">${esc(r.id === 'unknown' ? 'Unknown rarity' : r.name)}</span>` : '');

// ---- content -------------------------------------------------------------------------------------------------------------------
async function content(panel, alive) {
  const list = await dm.getContentLibrary(campaignId);
  // rarity chips of published items (a draft has no catalog row yet); a failed read only drops the chips
  const rarity = await dm.getItemRarities(list.filter((x) => x.content_type === 'item').map((x) => x.catalog_ref)).catch(() => new Map());
  if (!alive()) return;
  const f = { type: store.get('ctype') || '', status: store.get('cstatus') || '', q: '' };
  const draw = () => {
    const shown = list.filter((x) => (!f.type || x.content_type === f.type) && (!f.status || x.status === f.status || (f.status === 'draft' && ['draft', 'validation_failed', 'ready_for_review', 'revised'].includes(x.status)))
      && (!f.q || x.name.toLowerCase().includes(f.q)));
    $('[data-c-list]', panel).innerHTML = shown.length ? shown.map((x) => `<li class="dm-content-row">
      <button type="button" class="dm-content-btn" data-dm="edit-content" data-id="${esc(x.id)}">
        <span class="dm-ico" aria-hidden="true">${TYPE[x.content_type]?.icon || ''}</span>
        <span class="dm-content-name"><strong>${esc(x.name)}</strong><span class="small muted">${esc(TYPE[x.content_type]?.label || x.content_type)}${x.scope === 'private' ? ' · private library' : ''}
          · v${esc(x.version_no || 1)}${x.published_version_no && x.published_version_no !== x.version_no ? ` (v${x.published_version_no} published)` : ''}${x.content_type === 'item' && rarity.get(x.catalog_ref) ? ` ${rarityChipHTML(rarity.get(x.catalog_ref))}` : ''}</span>
          ${x.summary ? `<span class="small">${esc(x.summary)}</span>` : ''}</span>
        <span class="ce-chip ce-${esc(x.status)}">${esc(CSTATUS[x.status] || x.status)}</span>
        <span class="small muted">${x.usage_characters ? `${x.usage_characters} character${x.usage_characters === 1 ? '' : 's'}` : 'no characters'}</span>
      </button>${contentManagementEnabled() ? `<button type="button" class="btn btn-xs btn-ghost" data-dm="usage-content" data-id="${esc(x.id)}" aria-label="Usage of ${esc(x.name)}">Usage</button>` : ''}</li>`).join('') : '<li class="muted">Nothing here yet.</li>';
  };
  panel.innerHTML = `
    <div class="dm-filters">
      <div class="chip-row" role="group" aria-label="Type"><button type="button" class="chip ${!f.type ? 'is-on' : ''}" data-ct="">All</button>${Object.entries(TYPE).map(([k, t]) =>
        `<button type="button" class="chip ${f.type === k ? 'is-on' : ''}" data-ct="${k}">${t.icon} ${esc(t.label.split(' / ')[0])}</button>`).join('')}</div>
      <label class="field"><span>Status</span><select data-cs><option value="">Any</option><option value="draft">Drafts</option><option value="published">Published</option><option value="archived">Archived</option></select></label>
      <label class="field"><span>Search</span><input type="search" data-cq></label>
    </div>
    <div class="dm-create-inline" role="group" aria-label="Create new content"><span class="muted small">Create:</span>${Object.entries(TYPE).map(([k, t]) => `<button type="button" class="btn btn-sm btn-quiet" data-dm="new-content" data-type="${k}">${t.icon}${esc(t.label.split(' / ')[0])}</button>`).join('')}
      ${contentManagementEnabled() ? '<button type="button" class="btn btn-sm" data-dm="dup-official">Duplicate official…</button>' : ''}
      <button type="button" class="btn btn-sm" data-dm="item-icons">${icon('dm/item', { size: 18 })}Item icons…</button></div>
    <ul class="dm-content-list" data-c-list></ul>`;
  $('[data-cs]', panel).value = f.status;
  panel.addEventListener('click', (e) => {
    const t = e.target.closest('[data-ct]');
    if (!t) return;
    f.type = t.dataset.ct; store.set('ctype', f.type);
    $$('[data-ct]', panel).forEach((b) => b.classList.toggle('is-on', b.dataset.ct === f.type));
    draw();
  });
  $('[data-cs]', panel).addEventListener('change', (e) => { f.status = e.target.value; store.set('cstatus', f.status); draw(); });
  $('[data-cq]', panel).addEventListener('input', (e) => { f.q = e.target.value.trim().toLowerCase(); draw(); });
  draw();
}

// ---- assign ------------------------------------------------------------------------------------------------------------------------
async function assign(panel, alive) {
  const [lib, chars] = await Promise.all([dm.getContentLibrary(campaignId), dm.getCampaignCharacters(campaignId)]);
  if (!alive()) return;
  const p = { characters: chars.map((c) => ({ ...c, classes: [] })) };
  const published = lib.filter((x) => x.status === 'published' && x.scope !== 'private');
  const preset = assignPreset || {};
  assignPreset = null;
  panel.innerHTML = `
    <ol class="dm-steps">
      <li><h3>1. Content</h3><select data-as-content aria-label="Content"><option value="">Choose published content…</option>${Object.entries(TYPE).map(([k, t]) => {
        const items = published.filter((x) => x.content_type === k);
        return items.length ? `<optgroup label="${esc(t.label)}">${items.map((x) => `<option value="${esc(x.id)}" ${preset.contentId === x.id ? 'selected' : ''}>${esc(x.name)} (v${x.published_version_no})</option>`).join('')}</optgroup>` : '';
      }).join('')}</select>${published.length ? '' : '<p class="muted small">Publish content first (Content section).</p>'}</li>
      <li><h3>2. Characters</h3><div class="multi-opts">${p.characters.map((c) => `<label class="check-field"><input type="checkbox" data-as-char value="${esc(c.id)}"
        ${(preset.characterIds || []).includes(c.id) ? 'checked' : ''}><span>${esc(c.name)} <span class="muted small">${esc(c.classes.map((k) => `${k.class} ${k.level}`).join(' / '))}</span></span></label>`).join('')}</div></li>
      <li><h3>3. How</h3><div data-as-mode><p class="muted small">Choose the content first.</p></div></li>
      <li><h3>4. Check and assign</h3><p data-as-preview class="small"></p><button type="button" class="btn btn-gold" data-as-go>Assign</button><div data-as-result aria-live="polite"></div></li>
    </ol>`;
  const sel = () => published.find((x) => x.id === $('[data-as-content]', panel).value);
  const drawMode = () => {
    const x = sel();
    const box = $('[data-as-mode]', panel);
    if (!x) { box.innerHTML = '<p class="muted small">Choose the content first.</p>'; preview(); return; }
    const t = x.content_type;
    box.innerHTML = `<label class="field"><span>Assign as</span><select data-as-m>${(MODES[t] || []).map(([k, l]) => `<option value="${k}">${esc(l)}</option>`).join('')}</select></label>
      ${t === 'item' ? `<label class="field field-num"><span>Quantity</span><input type="number" min="1" value="1" data-as-qty></label>
        <label class="check-field"><input type="checkbox" data-as-unid><span>Unidentified (the player sees only the disguise)</span></label>
        <label class="field"><span>Custom name (optional)</span><input data-as-name maxlength="80"></label>` : ''}
      ${['creature', 'companion'].includes(t) ? '<label class="field"><span>Companion name (optional)</span><input data-as-name maxlength="80"></label>' : ''}
      ${t === 'background' ? `<label class="field"><span>2024 ability increases</span><select data-as-bgmode><option value="plus2_plus1">+2 / +1</option><option value="plus1_x3">+1 / +1 / +1</option></select></label>
        <p class="muted small">The ability allocation uses the first listed abilities; adjust it on the sheet afterwards if needed.</p>` : ''}
      ${['feat', 'condition'].includes(t) ? '<label class="field"><span>Note (optional)</span><input data-as-note maxlength="300"></label>' : ''}`;
    preview();
  };
  const preview = () => {
    const x = sel();
    const chars = $$('[data-as-char]:checked', panel).map((i) => p.characters.find((c) => c.id === i.value)?.name);
    const mode = $('[data-as-m]', panel);
    $('[data-as-preview]', panel).textContent = x && chars.length
      ? `${TYPE[x.content_type].label} “${x.name}” (version ${x.published_version_no}) → ${chars.join(', ')} as ${mode?.selectedOptions[0]?.textContent || ''}.`
      : 'Choose content and at least one character.';
  };
  panel.addEventListener('change', (e) => { if (e.target.matches('[data-as-content]')) drawMode(); else preview(); });
  $('[data-as-go]', panel).addEventListener('click', async (e) => {
    const x = sel();
    const ids = $$('[data-as-char]:checked', panel).map((i) => i.value);
    if (!x || !ids.length) { toast('Choose content and at least one character.', 'bad'); return; }
    const opt = {};
    const t = x.content_type;
    if (t === 'item') { opt.quantity = Number($('[data-as-qty]', panel).value) || 1; opt.identified = !$('[data-as-unid]', panel).checked; if ($('[data-as-name]', panel).value) opt.custom_name = $('[data-as-name]', panel).value; }
    if (['creature', 'companion'].includes(t) && $('[data-as-name]', panel).value) opt.name = $('[data-as-name]', panel).value;
    if (t === 'background') {
      const d = (await dm.getContent(x.id)).versions.find((v) => v.status === 'published')?.definition || {};
      const ab = d.abilities || [];
      opt.ability = $('[data-as-bgmode]', panel).value === 'plus1_x3' ? { mode: 'plus1_x3', allocation: Object.fromEntries(ab.map((a) => [a, 1])) }
        : { mode: 'plus2_plus1', allocation: { [ab[0]]: 2, [ab[1]]: 1 } };
    }
    if ($('[data-as-note]', panel)?.value) opt.note = $('[data-as-note]', panel).value;
    e.target.disabled = true;
    try {
      const r = await dm.assignContent(x.id, ids, $('[data-as-m]', panel).value, opt);
      $('[data-as-result]', panel).innerHTML = `<ul class="small">${r.results.map((x2) => `<li>${x2.ok ? '✓' : '✗'} ${esc(p.characters.find((c) => c.id === x2.character_id)?.name || '')}
        ${x2.ok ? 'done (recorded in the audit log)' : `— ${esc(x2.error)}`}</li>`).join('')}</ul>`;
      toast(r.results.every((x2) => x2.ok) ? 'Assigned.' : 'Some assignments failed.', r.results.every((x2) => x2.ok) ? 'good' : 'bad');
    } catch (err) { toast(err.message, 'bad'); }
    e.target.disabled = false;
  });
  if (preset.contentId) drawMode();
  preview();
}

// ---- hidden ------------------------------------------------------------------------------------------------------------------------
async function hidden(panel, alive) {
  const p = { characters: await dm.getCampaignCharacters(campaignId) };
  if (!alive()) return;
  const cid = p.characters.some((c) => c.id === store.get('hidden-character')) ? store.get('hidden-character') : p.characters[0]?.id;
  if (!cid) { panel.innerHTML = '<p class="muted">No characters yet.</p>'; return; }
  const [h, attempts, custom] = await Promise.all([dm.getCharacterHidden(cid), dm.getIdentifyAttempts(campaignId, null).catch(() => []),
    dm.getCampaignCustomItems(campaignId).catch(() => [])]);
  if (!alive()) return;
  const name = p.characters.find((c) => c.id === cid)?.name || '';
  setHiddenBadge((attempts || []).filter((a) => a.status === 'pending').length);
  panel.innerHTML = `
    ${identifyQueueHTML(attempts)}
    <section class="card dm-card dm-wide" data-reveal aria-label="Who knows what"></section>
    <label class="field"><span>Character</span><select data-h-char>${p.characters.map((c) => `<option value="${esc(c.id)}" ${c.id === cid ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></label>
    <p class="muted small">Everything here is visible only to DMs. Players see nothing of it until you reveal it.</p>
    <div class="dm-columns">
      <section class="card dm-card"><h2>Secret notes</h2>
        ${h.notes.length ? `<ul class="dm-notes">${h.notes.map((n) => `<li><strong>${esc(n.title)}</strong> ${n.revealed_at ? '<span class="req-chip req-applied">Revealed</span>' : ''}
          <p class="small">${esc(n.body)}</p>${n.reveal_note ? `<p class="small muted">Reveal text: ${esc(n.reveal_note)}</p>` : ''}
          <div class="dm-action-row">${n.revealed_at ? '' : `<button type="button" class="btn btn-xs" data-h="reveal-note" data-id="${esc(n.id)}">Reveal</button>`}
          <button type="button" class="btn btn-xs btn-ghost" data-h="delete-note" data-id="${esc(n.id)}">Delete</button></div></li>`).join('')}</ul>` : '<p class="muted">No notes.</p>'}
        <button type="button" class="btn btn-sm" data-dm="note" data-id="${esc(cid)}" data-name="${esc(name)}">+ Add note</button></section>
      <section class="card dm-card"><h2>Conditions and hidden effects</h2>
        ${h.conditions.length ? `<ul>${h.conditions.map((k) => `<li>${k.hidden ? `${icon('ui.dm-secret', { size: 14 })}<span class="dm-secret-text">Hidden:</span> ` : ''}<strong>${esc(k.name)}</strong>${k.expires_at ? ` <span class="small muted">until ${esc(fmt(k.expires_at))}</span>` : ''}
          ${k.note ? `<span class="small"> — ${esc(k.note)}</span>` : ''}<div class="dm-action-row">
          ${k.hidden ? `<button type="button" class="btn btn-xs" data-h="reveal-cond" data-id="${esc(k.id)}">Reveal</button>` : ''}
          <button type="button" class="btn btn-xs btn-ghost" data-h="remove-cond" data-id="${esc(k.id)}">Remove</button></div></li>`).join('')}</ul>` : '<p class="muted">None.</p>'}
        <button type="button" class="btn btn-sm" data-dm="condition" data-id="${esc(cid)}" data-name="${esc(name)}" data-hidden="1">+ Hidden effect</button></section>
      <section class="card dm-card dm-wide"><h2>Items and their secrets</h2>
        ${h.items.length ? h.items.map((it) => {
          const secret = h.item_secrets.find((s) => s.item_id === it.item_id) || {};
          const keys = ['magic', 'rarity', 'attunement', 'curse', ...((secret.properties || []).map((x) => x.key))];
          return `<div class="dm-item-know" data-ii="${esc(it.inventory_item_id)}"><p><strong>${esc(it.true_name)}</strong> <span class="small muted">player sees: ${esc(it.display_name)}</span></p>
            ${secret.curse ? `<p class="small warn">Curse: ${esc(secret.curse)}</p>` : ''}
            <label class="field"><span>Player knowledge</span><select data-k-state>${['unidentified', 'partially_identified', 'identified'].map((s) => `<option value="${s}" ${it.state === s ? 'selected' : ''}>${esc(s.replace('_', ' '))}</option>`).join('')}</select></label>
            <div class="multi-opts">${keys.map((k) => `<label class="check-field"><input type="checkbox" data-k-rev value="${esc(k)}" ${(it.revealed || []).includes(k) ? 'checked' : ''}><span>Reveal ${esc((secret.properties || []).find((x) => x.key === k)?.label || k)}</span></label>`).join('')}</div>
            <button type="button" class="btn btn-sm btn-gold" data-h="knowledge">Save what the player knows</button>
            ${identifySummaryHTML(it.identify)}
            <div class="dm-action-row">${it.identify?.content_id ? `<button type="button" class="btn btn-xs" data-h="identify-content" data-content="${esc(it.identify.content_id)}" title="DM Content: its identification is set in the Content editor">Identification settings (Content)…</button>`
              : it.identify?.secrets_editable ? `<button type="button" class="btn btn-xs" data-h="identify-opts" data-item="${esc(it.item_id)}" data-name="${esc(it.true_name)}">Identification settings…</button>` : ''}
              ${it.item_id ? `<button type="button" class="btn btn-xs" data-h="reveal-all" data-item="${esc(it.item_id)}" data-name="${esc(it.true_name)}">Reveal to every character</button>` : ''}</div></div>`;
        }).join('') : '<p class="muted">No unidentified or partly identified items. Assign an item as unidentified from Assign, or give one below.</p>'}
      </section>
      <section class="card dm-card dm-wide"><h2>Give a campaign item unidentified</h2>
        ${custom.length ? `<p class="muted small">Custom items of this campaign (DM Content and campaign homebrew, e.g. herbs). ${esc(name)} gets the disguise; set the decoy and the Examine check in Identification settings (for DM Content they open the Content editor: one place for its settings).</p>
        <div class="inv-form-row" data-give>
          <select data-give-item aria-label="Item">${custom.map((x) => `<option value="${esc(x.id)}">${esc(x.name)}${x.secrets?.identify_dc ? ` (DC ${esc(String(x.secrets.identify_dc))})` : x.secrets?.unidentified_name ? ' (disguised)' : ''}</option>`).join('')}</select>
          <input type="number" data-give-qty min="1" max="999" value="1" aria-label="Quantity" style="width:5em">
          <button type="button" class="btn btn-sm btn-gold" data-h="give">Give to ${esc(name)}</button>
          <button type="button" class="btn btn-sm" data-h="give-opts">Identification settings…</button>
        </div>` : '<p class="muted">No custom items in this campaign yet. Create one in Content, or with the Inventory homebrew form (campaign visibility).</p>'}
      </section>
    </div>`;
  revealPanel($('[data-reveal]', panel), alive).catch((err) => { const box = $('[data-reveal]', panel); if (box) box.innerHTML = `<h2>Who knows what</h2><p class="gov-error">${esc(err.message)}</p>`; });
  $('[data-h-char]', panel).addEventListener('change', (e) => { store.set('hidden-character', e.target.value); show('hidden'); });
  panel.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-h]');
    if (!b) return;
    try {
      if (b.dataset.h === 'reveal-note') await dm.revealDmNote(b.dataset.id);
      if (b.dataset.h === 'delete-note' && await confirmDialog('Delete this note?', { danger: true, okLabel: 'Delete' })) await dm.deleteDmNote(b.dataset.id);
      if (b.dataset.h === 'reveal-cond') await dm.revealCondition(b.dataset.id);
      if (b.dataset.h === 'remove-cond') await dm.removeCondition(b.dataset.id);
      if (b.dataset.h === 'knowledge') {
        const box = b.closest('[data-ii]');
        await dm.setItemKnowledge(box.dataset.ii, $('[data-k-state]', box).value, $$('[data-k-rev]:checked', box).map((x) => x.value));
      }
      if (b.dataset.h === 'identify-opts' || b.dataset.h === 'give-opts' || b.dataset.h === 'identify-content') {
        const id = b.dataset.item || $('[data-give-item]', panel).value;
        const item = custom.find((x) => x.id === id);
        // DM Content: ONE source of truth, the content definition (the server refuses the direct dialog for it)
        const contentId = b.dataset.content || (b.dataset.h === 'give-opts' ? item?.content_id : null);
        if (contentId) {
          await openContentEditor({ content: { id: contentId }, campaignId, focus: 'identify', onChanged: () => show('hidden'),
            onAssign: (c) => { assignPreset = { contentId: c.id }; show('assign'); } });
          return;
        }
        const own = h.item_secrets.find((x) => x.item_id === id);
        await identifyOptionsDialog(id, b.dataset.name || item?.name || '', item?.secrets || own || null);
        return;
      }
      if (b.dataset.h === 'reveal-all') {
        if (!await confirmDialog(`Reveal “${b.dataset.name}” to every character of the campaign?`, { okLabel: 'Reveal' })) return;
        const res = await dm.revealItem(b.dataset.item, null, null, campaignId);
        if (res?.busy) toast(busyText(res), 'bad', 8000);
      }
      if (b.dataset.h === 'give') {
        const res = await dm.giveItem($('[data-give-item]', panel).value, [cid], Number($('[data-give-qty]', panel).value) || 1, false);
        const bad = (res.results || []).find((x) => !x.ok);
        if (bad) throw new Error(bad.error);
      }
      if (b.dataset.h === 'id-resolve' || b.dataset.h === 'id-retry') {
        const box = b.closest('[data-attempt]');
        const roll = $('[data-id-roll]', box)?.value;
        await dm.resolveIdentifyAttempt(box.dataset.attempt, {
          success: b.dataset.h === 'id-retry' ? false : b.dataset.ok === '1' ? true : b.dataset.ok === '0' ? false : null,
          dmRoll: roll !== undefined && roll !== '' ? Number(roll) : null, note: $('[data-id-note]', box)?.value || null,
          allowRetry: b.dataset.h === 'id-retry' || !!$('[data-id-allow]', box)?.checked,
        });
      }
      toast('Saved.', 'good');
      show('hidden');
    } catch (err) { toast(err.message, 'bad'); }
  });
}

/** A DM call that met busy characters: they were NOT changed (20261114000300: nothing is queued for a DM decision). */
const busyText = (res) => `${(res.busy_names || []).join(', ') || res.busy} ${res.busy === 1 ? 'was' : 'were'} busy and ${res.busy === 1 ? 'was' : 'were'} NOT changed. Try again.`;

// ---- who knows what: per-character reveal of one item (20261112000400) ----------------------------------------------------------
// The levels use the identification vocabulary of 20261112000300 (no second one): [] / ['name'] / ['name', 'description'] / ['all'].
const LEVELS = [['none', 'Nothing (hidden)', []], ['name', 'Name only', ['name']], ['namedesc', 'Name + description', ['name', 'description']], ['all', 'Everything', ['all']]];
const SOURCE_TEXT = { undisguised_copy: 'holds an undisguised copy', rows: 'from the copies they hold', record: 'holds no copy (remembered)', none: 'has never learned it', not_hidden: 'the item is not hidden' };
function levelOf(st, rev) {
  const r = [...(rev || [])].sort();
  if (st === 'identified') return 'all';
  if (!r.length) return 'none';
  if (r.join() === 'name') return 'name';
  if (r.join() === 'description,name') return 'namedesc';
  return 'custom';
}
const levelText = (st, rev) => {
  const l = levelOf(st, rev);
  return l === 'custom' ? `Partly: ${(rev || []).join(', ')}` : LEVELS.find(([k]) => k === l)[1];
};
// 0 nothing .. 3 everything (the server's _ik_rank)
const rankOf = (st, rev) => (st === 'identified' ? 3 : (rev || []).includes('name') && (rev || []).includes('description') ? 2 : (rev || []).length ? 1 : 0);
const namesOf = (list) => list.map((c) => c.name).join(', ');
/** The confirm text when "Set" / "Hide" takes knowledge away, from the overview; null when no confirmation is needed. */
function hideWarning(ov, ids, level) {
  const it = ov.item;
  const reveal = LEVELS.find(([k]) => k === level)?.[2] || [];
  const target = reveal.includes('all') ? 3 : rankOf('partially_identified', reveal);
  const lowered = ov.characters.filter((c) => ids.includes(c.character_id) && rankOf(c.effective?.state, c.effective?.revealed) > target);
  if (!lowered.length) return null;
  // who still sees the real item: an undisguised copy, or copies whose knowledge is 'identified' (a stash row keeps the knowledge
  // it had when it was deposited; state 'identified' covers both cases, the overview reports a plain row as identified)
  const others = ov.characters.filter((c) => !ids.includes(c.character_id)
    && (c.plain_rows > 0 || (c.effective?.source === 'rows' && c.effective?.state === 'identified')));
  const stash = (ov.stash || []).filter((s) => s.state === 'identified');
  const equipped = lowered.filter((c) => c.equipped_rows > 0);
  if (it.secret && !others.length && !stash.length && !equipped.length) return null;
  const out = [`Hide “${it.name}” from ${namesOf(lowered)}? ${level === 'none' ? `They will see only “${it.decoy_name}”.`
    : `They will know only: ${LEVELS.find(([k]) => k === level)[1].toLowerCase()}.`}`];
  if (others.length) out.push(`${namesOf(others)} still ${others.length > 1 ? 'hold' : 'holds'} a copy that shows the real item and will still see it; their players keep it in the “Add item” catalog.`);
  if (stash.length) out.push(`${[...new Set(stash.map((s) => s.inventory_name || s.inventory_kind))].join(', ')} still ${stash.length > 1 ? 'hold' : 'holds'} a copy that shows the real item: every party member will still see it there, and it stays in their “Add item” catalog.`);
  if (!others.length && !stash.length && !it.secret) out.push('The item leaves the players’ “Add item” catalog in this campaign.');
  if (equipped.length) out.push(`${namesOf(equipped)} ${equipped.length > 1 ? 'have' : 'has'} it equipped: on the player’s sheet it stops counting until you reveal it again (armour falls back to unarmoured AC); your DM view still shows the full numbers.`);
  return out.join('\n');
}
async function revealPanel(box, alive) {
  if (!box) return;
  const items = await dm.getCampaignKnowledgeItems(campaignId);
  if (!alive()) return;
  let itemId = items.some((x) => x.id === store.get('reveal-item')) ? store.get('reveal-item') : '';
  box.innerHTML = `<h2>Who knows what</h2>
    <p class="muted small">Choose an item, then decide per character what they know about it. Each player sees only what their own character knows.</p>
    <label class="field"><span>Item</span><select data-rv-item><option value="">Choose an item…</option>${items.map((x) => `<option value="${esc(x.id)}" ${x.id === itemId ? 'selected' : ''}>${esc(x.name)}${x.disguised_rows || x.secret ? ' · hidden' : ''}${x.official ? ' · official' : ''}${x.holders ? ` · held by ${x.holders}` : ''}</option>`).join('')}</select></label>
    <div data-rv-body></div>`;
  let ov = null;
  const body = $('[data-rv-body]', box);
  const draw = async () => {
    if (!itemId) { body.innerHTML = ''; return; }
    body.innerHTML = '<div class="spinner"></div>';
    ov = await dm.getItemKnowledgeOverview(itemId, campaignId);
    if (!alive() || !box.isConnected) return;
    const it = ov.item;
    const opts = (cur) => [...LEVELS.filter(([k]) => it.can_hide || k === 'all').map(([k, l]) => `<option value="${k}" ${k === cur ? 'selected' : ''}>${esc(l)}</option>`),
      cur === 'custom' ? '<option value="custom" selected>Keep as it is (custom)</option>' : ''].join('');
    const party = ov.party_share === true;   // 20261114000300 (undefined on an older server: per character as before)
    body.innerHTML = `
      <p class="small">Characters who do not know it see <b>${esc(it.decoy_name)}</b>${it.decoy_description ? ` — <span class="muted">${esc(it.decoy_description)}</span>` : ''}.</p>
      ${party ? '<p class="small dm-party-note"><strong>Shared with the party</strong> (Campaign rules): a reveal or a player’s successful examine reaches every character, also characters who join later, except those you hold back. “Set” at any level (also Everything) changes only that character and holds them out of party sharing for this item until “let the party share” or a reveal of everything to a character who did not know everything yet; a partial reveal keeps the hold.</p>' : ''}
      ${it.official ? '<p class="small muted">Official item: you can reveal it, but hiding it again needs a campaign copy (Content → Duplicate official).</p>' : ''}
      ${!it.secret && it.can_hide ? '<p class="small muted">Not hidden yet. Lowering a character’s level disguises their copies and makes the item secret (before saving you see who will still see the real item).</p>' : ''}
      <table class="dm-rule-table dm-reveal-table"><thead><tr><th scope="col"><input type="checkbox" data-rv-all aria-label="Select every character"></th><th scope="col">Character</th>
        <th scope="col">Holds</th><th scope="col">Knows now</th><th scope="col">Set to</th><th scope="col"><span class="sr-only">Action</span></th></tr></thead>
      <tbody>${ov.characters.map((c) => { const e = c.effective || {}; const cur = levelOf(e.state, e.revealed); return `<tr data-rv-char="${esc(c.character_id)}">
        <td><input type="checkbox" data-rv-sel value="${esc(c.character_id)}" aria-label="Select ${esc(c.name)}"></td>
        <td><strong>${esc(c.name)}</strong>${c.is_creator ? ' <span class="small muted">(created it)</span>' : ''}</td>
        <td>${c.rows ? `${esc(String(c.quantity))}${c.shown_names?.length ? ` <span class="small muted">as ${esc(c.shown_names.join(', '))}</span>` : ''}` : '—'}</td>
        <td data-rv-now>${esc(levelText(e.state, e.revealed))}<br><span class="small muted">${esc(SOURCE_TEXT[e.source] || '')}</span>${c.diverges ? ' <span class="small warn">copies differ</span>' : ''}
          ${c.party_source && !c.held ? `<br><span class="small muted" data-rv-party>known by the party${c.party_source.from ? ` (identified by ${esc(c.party_source.from)})` : ''}</span>` : ''}
          ${c.held ? `<br><span class="small warn" data-rv-held>held back by you</span>${party ? ' <button type="button" class="btn-link small" data-rv="release">let the party share</button>' : ''}` : ''}</td>
        <td><select data-rv-level aria-label="Level for ${esc(c.name)}">${opts(cur)}</select></td>
        <td><button type="button" class="btn btn-xs" data-rv="set">Set</button></td></tr>`; }).join('')}</tbody></table>
      <div class="inv-form-row">
        <select data-rv-bulk aria-label="Level to reveal">${LEVELS.filter(([k]) => k !== 'none').map(([k, l]) => `<option value="${k}" ${k === 'all' ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>
        <button type="button" class="btn btn-sm btn-gold" data-rv="reveal-selected">Reveal to selected</button>
        <button type="button" class="btn btn-sm" data-rv="reveal-party">Reveal to the whole party</button>
        ${it.can_hide ? '<button type="button" class="btn btn-sm btn-ghost" data-rv="hide-selected">Hide from selected</button>' : ''}
      </div>
      <p class="muted small">“Reveal” only ever adds knowledge; “Set” and “Hide” can take it away again (undo).${party ? ' With party sharing on, “Reveal to selected” also reaches the rest of the party (except held-back characters).' : ''}</p>
      ${ov.stash?.length ? `<p class="small"><strong>Party stash / shop:</strong> ${ov.stash.map((s) => `${esc(s.shown_name)} ×${esc(String(s.quantity))} (${esc(s.inventory_name || s.inventory_kind)}: ${esc(levelText(s.state, s.revealed))})`).join('; ')}
        <span class="muted">— a stash copy keeps its own knowledge and every party member sees it.</span></p>` : ''}
      ${ov.history?.length ? `<details><summary class="small">History (${ov.history.length})</summary><ul class="small">${ov.history.map((h) => `<li>${esc(fmt(h.at))} · ${esc(h.character_name || '?')}:
        ${h.old_state ? `${esc(levelText(h.old_state, h.old_revealed))} → ` : ''}${esc(levelText(h.new_state, h.new_revealed))} <span class="muted">(${h.source === 'party_share'
          ? `shared by the party${h.source_character_name ? `, from ${esc(h.source_character_name)}` : ''}` : esc(h.actor || 'automatic')})</span></li>`).join('')}</ul></details>` : ''}`;
  };
  const apply = async (ids, level, mode) => {
    if (!ids.length) { toast('Choose at least one character.', 'bad'); return; }
    if (level === 'custom') return;
    const lowerMsg = mode === 'set' ? hideWarning(ov, ids, level) : null;
    if (lowerMsg && !await confirmDialog(lowerMsg, { okLabel: 'Hide' })) return;
    const res = await dm.setItemKnowledgeFor(itemId, ids, LEVELS.find(([k]) => k === level)[2], mode, campaignId);
    const warn = (res.results || []).find((x) => x.warning);
    const skipped = (res.results || []).filter((x) => x.skipped).length;
    const shared = res.shared_with ? ` Shared with ${res.shared_with} more character(s) of the party.` : '';
    // a character busy at that moment is neither waited for nor queued: nothing changed for them (reveal or hide), the DM retries
    if (res.busy) toast(busyText(res), 'bad', 8000);
    toast(warn ? warn.warning : res.changed || res.shared_with ? `Saved for ${res.changed} character(s).${shared}`
      : skipped ? 'Nothing changed: they already hold an undisguised copy and see everything.' : 'Nothing changed.', warn ? 'bad' : 'good');
    await draw();
  };
  box.addEventListener('change', (e) => {
    if (e.target.matches('[data-rv-item]')) { itemId = e.target.value; store.set('reveal-item', itemId); draw().catch((err) => toast(err.message, 'bad')); }
    if (e.target.matches('[data-rv-all]')) $$('[data-rv-sel]', box).forEach((x) => { x.checked = e.target.checked; });
  });
  box.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-rv]');
    if (!b || !ov) return;
    b.disabled = true;
    try {
      const sel = $$('[data-rv-sel]:checked', box).map((x) => x.value);
      if (b.dataset.rv === 'set') { const tr = b.closest('[data-rv-char]'); await apply([tr.dataset.rvChar], $('[data-rv-level]', tr).value, 'set'); }
      if (b.dataset.rv === 'reveal-selected') await apply(sel, $('[data-rv-bulk]', box).value, 'raise');
      if (b.dataset.rv === 'reveal-party') {
        const lv = $('[data-rv-bulk]', box).value;
        if (await confirmDialog(`Reveal “${ov.item.name}” (${LEVELS.find(([k]) => k === lv)[1].toLowerCase()}) to every character of the campaign?`, { okLabel: 'Reveal' })) {
          await apply(ov.characters.map((c) => c.character_id), lv, 'raise');
        }
      }
      if (b.dataset.rv === 'hide-selected') await apply(sel, 'none', 'set');
      if (b.dataset.rv === 'release') {
        const tr = b.closest('[data-rv-char]');
        const res = await dm.releaseKnowledgeHold(itemId, [tr.dataset.rvChar], campaignId);
        toast(res.busy ? busyText(res)
          : res.shared_with ? `Party sharing reaches them again (${res.shared_with} change(s)).` : 'Party sharing reaches them again.', res.busy ? 'bad' : 'good');
        await draw();
      }
    } catch (err) { toast(err.message, 'bad'); }
    if (b.isConnected) b.disabled = false;
  });
  await draw();
}

// ---- identification of disguised items (Herbs & Plants, 20261112000300) -------------------------------------------------------------
const RETRY_TEXT = { dm: 'another try only when you allow it', once: 'one attempt', per_long_rest: 'again after a long rest', unlimited: 'any number of tries' };
function identifySummaryHTML(x) {
  if (!x) return '';
  if (!x.dc) return '<p class="small muted">Players cannot examine it (no DC set).</p>';
  return `<p class="small">Examine: DC ${esc(String(x.dc))} · ${x.checks?.length ? esc(x.checks.map((c) => c.label).join(', ')) : 'any check'} ·
    ${x.auto ? 'reveals itself on a success' : 'you confirm'} · ${esc(RETRY_TEXT[x.retry] || x.retry || '')}${x.fail_hint ? ` · hint: “${esc(x.fail_hint)}”` : ''}</p>`;
}
function identifyQueueHTML(list) {
  const pending = (list || []).filter((a) => a.status === 'pending');
  const failed = (list || []).filter((a) => a.status === 'failed' && !a.retry_allowed).slice(0, 8);
  if (!pending.length && !failed.length) return '';
  const row = (a) => `<li class="dm-item-know" data-attempt="${esc(a.attempt_id)}">
      <p><strong>${esc(a.character_name)}</strong> examined <strong>${esc(a.true_name)}</strong> <span class="small muted">(player sees: ${esc(a.shown_name)})</span></p>
      <p class="small">${esc(a.check_label)}: <b>${esc(String(a.roll_total))}</b> against DC ${esc(String(a.dc ?? '—'))}${a.status === 'failed' ? ` · failed${a.dm_roll_total != null ? ` (corrected roll ${esc(String(a.dm_roll_total))})` : ''}` : ''} · ${esc(fmt(a.created_at))}</p>
      ${a.status === 'pending' ? `<div class="inv-form-row">
        <input type="number" data-id-roll min="-10" max="60" placeholder="Correct roll" aria-label="Corrected roll" style="width:7em">
        <input type="text" data-id-note maxlength="500" placeholder="Note for you (DM only)" aria-label="Note">
        <label class="check-field"><input type="checkbox" data-id-allow><span>Allow another try if it fails</span></label></div>
      <div class="dm-action-row"><button type="button" class="btn btn-xs btn-gold" data-h="id-resolve" data-ok="1">Success: reveal</button>
        <button type="button" class="btn btn-xs" data-h="id-resolve" data-ok="0">No success</button>
        <button type="button" class="btn btn-xs btn-ghost" data-h="id-resolve" data-ok="">Decide by the roll</button></div>`
        : '<div class="dm-action-row"><button type="button" class="btn btn-xs" data-h="id-retry">Allow another try</button></div>'}</li>`;
  return `<section class="card dm-card dm-wide" data-identify-queue><h2>Examine requests${pending.length ? ` (${pending.length})` : ''}</h2>
    ${pending.length ? `<ul>${pending.map(row).join('')}</ul>` : '<p class="muted">No open requests.</p>'}
    ${failed.length ? `<details><summary class="small">Recent failed attempts (${failed.length})</summary><ul>${failed.map(row).join('')}</ul></details>` : ''}</section>`;
}
async function identifyOptionsDialog(itemId, name, sec) {
  if (!itemId) return;
  const ref = await dm.getEditorReference();
  const x = sec || {};
  const checks = [...ref.skills.map((k) => [k.id, k.name]), ...ref.tools.map((k) => [k.id, k.name])];
  const reveal = [['all', 'Everything (identified)'], ['name', 'The true name'], ['description', 'The description'], ['details', 'Herb / potion details'],
    ['magic', 'That it is magical'], ['rarity', 'Rarity'], ['attunement', 'Attunement'], ['curse', 'The curse']];
  const box = (list, sel, attr) => `<div class="multi-opts">${list.map(([v, l]) => `<label class="check-field"><input type="checkbox" ${attr} value="${esc(v)}" ${(sel || []).includes(v) ? 'checked' : ''}><span>${esc(l)}</span></label>`).join('')}</div>`;
  const m = openModal({ title: `Identification: ${name}`, wide: true, body: `
    <p class="muted small">DM only. Players see the decoy until they identify the item (per character) or you reveal it.</p>
    <label class="field"><span>Name while unidentified</span><input data-o="unidentified_name" maxlength="80" value="${esc(x.unidentified_name || '')}"></label>
    <label class="field"><span>Description while unidentified</span><textarea data-o="unidentified_description" maxlength="1000" rows="2">${esc(x.unidentified_description || '')}</textarea></label>
    <label class="check-field"><input type="checkbox" data-o="show_kind" ${x.face_kind_id ? 'checked' : ''}><span>Players see its type (e.g. Herbs &amp; Plants)</span></label>
    <label class="field"><span>Examine DC (empty: players cannot examine it)</span><input type="number" data-o="identify_dc" min="1" max="40" value="${esc(String(x.identify_dc ?? ''))}"></label>
    <fieldset class="field-multi"><legend>Checks that can identify it (none: any check)</legend>${box(checks, x.identify_checks, 'data-o-check')}</fieldset>
    <fieldset class="field-multi"><legend>A success reveals</legend>${box(reveal, x.identify_reveal || ['all'], 'data-o-reveal')}</fieldset>
    <label class="check-field"><input type="checkbox" data-o="identify_auto" ${x.identify_auto ? 'checked' : ''}><span>Reveal at once when the roll meets the DC (no confirmation)</span></label>
    <label class="field"><span>Another attempt after a failure</span><select data-o="identify_retry">${Object.entries({ dm: 'Only when I allow it', once: 'Never (one attempt)', per_long_rest: 'After a long rest', unlimited: 'Any time' })
      .map(([k, l]) => `<option value="${k}" ${(x.identify_retry || 'dm') === k ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
    <label class="field"><span>Shown after a failed attempt (may be wrong but plausible)</span><textarea data-o="fail_hint" maxlength="500" rows="2">${esc(x.fail_hint || '')}</textarea></label>`,
  footer: '<button type="button" class="btn btn-gold" data-o-save>Save</button>' });
  $('[data-o-save]', m.el).addEventListener('click', async () => {
    const v = (k) => $(`[data-o="${k}"]`, m.el);
    const dc = v('identify_dc').value.trim();
    try {
      await dm.setItemIdentifyOptions(itemId, {
        unidentified_name: v('unidentified_name').value, unidentified_description: v('unidentified_description').value, show_kind: v('show_kind').checked,
        identify_dc: dc === '' ? null : Number(dc), identify_checks: $$('[data-o-check]:checked', m.el).map((c) => c.value),
        identify_reveal: $$('[data-o-reveal]:checked', m.el).map((c) => c.value), identify_auto: v('identify_auto').checked,
        identify_retry: v('identify_retry').value, fail_hint: v('fail_hint').value });
      toast('Identification settings saved.', 'good');
      m.close();
      show('hidden');
    } catch (err) { toast(err.message, 'bad'); }
  });
}

// ---- rules -------------------------------------------------------------------------------------------------------------------------
async function rules(panel, alive) {
  const g = await gov.getCampaignGovernance(campaignId);
  // party-wide identification (20261114000300); an older server has no such rule: the row is not shown
  const share = await dm.getIdentificationSharing(campaignId).catch(() => null);
  if (!alive()) return;
  const RANK = { player_managed: 0, approval_required: 1, dm_only: 2, disabled: 3 };
  const choices = (a) => Object.keys(RANK).filter((d) => RANK[d] >= RANK[a.max_player] && (d !== 'approval_required' || a.can_request));
  // the crafting rule is listed only when the Crafting feature is on (js/config.js): with 'off' this tab looks exactly as before
  // (the save sends only the selects that changed, so a hidden row keeps its value)
  if (!craftingOn()) g.actions = g.actions.filter((a) => a.key !== 'inventory.craft');
  const cats = [...new Set(g.actions.map((a) => a.category))];
  panel.innerHTML = `
    ${g.report ? `<div class="gov-banner">${esc(g.report.note)}</div>` : ''}${!g.configured ? '<div class="gov-banner">Not configured yet: the campaign behaves like “Relaxed”. Saving creates its rules.</div>' : ''}
    ${share ? `<fieldset class="ce-section" data-share-rule><legend>Item identification</legend>
      <label class="check-field"><input type="checkbox" data-share-toggle ${share.share_identification ? 'checked' : ''}><span>Identification is shared with the party</span></label>
      <p class="muted small">When one character identifies an item (or you reveal it), every character of the campaign knows it, also characters who join later. Characters you hold back in Hidden → Who knows what are skipped. Off: each character learns on their own; switching it off never takes knowledge away.${share.held ? ` Held back now: ${esc(String(share.held))}.` : ''}</p>
      <p class="small"><button type="button" class="btn btn-sm" data-share-sync>Sync party knowledge</button>
        <span class="muted">${share.pending ? `${esc(String(share.pending))} share(s) wait for a busy character. ` : ''}Brings every character up to what the party knows.</span></p></fieldset>` : ''}
    <form class="dm-rules" data-rules>
      <fieldset class="dm-presets"><legend>Preset</legend>${['relaxed', 'standard', 'strict', 'custom'].map((k) => `<label class="dm-preset ${g.preset === k ? 'is-on' : ''}">
        <input type="radio" name="preset" value="${k}" ${g.preset === k ? 'checked' : ''}><strong>${esc(k[0].toUpperCase() + k.slice(1))}</strong><span class="small">${esc(gov.PRESET_TEXT[k])}</span></label>`).join('')}</fieldset>
      <div class="ce-grid">
        <label class="field"><span>Feats with unmet prerequisites</span><select name="unmet_prerequisites">${[['propose', 'Players may still ask'], ['dm_override', 'Only with a DM override'], ['block', 'Blocked']].map(([k, l]) => `<option value="${k}" ${g.unmet_prerequisites === k ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
        <label class="check-field"><input type="checkbox" name="require_approval_note" ${g.require_approval_note ? 'checked' : ''}><span>Require a note on every approval</span></label>
        <label class="check-field"><input type="checkbox" name="allow_edit_and_approve" ${g.allow_edit_and_approve ? 'checked' : ''}><span>Allow “edit and approve”</span></label>
      </div>
      <fieldset class="ce-section"><legend>Content allowed for new picks</legend><div class="ce-grid">
        <label class="check-field"><input type="checkbox" name="ruleset_2014" ${g.content.rulesets.includes('2014') ? 'checked' : ''}><span>2014 rules</span></label>
        <label class="check-field"><input type="checkbox" name="ruleset_2024" ${g.content.rulesets.includes('2024') ? 'checked' : ''}><span>2024 rules</span></label>
        <label class="check-field"><input type="checkbox" name="allow_legacy" ${g.content.allow_legacy ? 'checked' : ''}><span>Legacy content</span></label>
        <label class="check-field"><input type="checkbox" name="allow_setting" ${g.content.allow_setting ? 'checked' : ''}><span>Setting-specific content</span></label>
        <label class="check-field"><input type="checkbox" name="allow_playtest" ${g.content.allow_playtest ? 'checked' : ''}><span>Playtest and unverified content</span></label>
        <label class="check-field"><input type="checkbox" name="allow_custom" ${g.content.allow_custom ? 'checked' : ''}><span>Campaign custom content</span></label>
      </div><p class="muted small">Existing selections stay; they are only no longer offered for new picks.</p></fieldset>
      ${cats.map((cat) => `<details class="dm-rule-cat" ${['core_build', 'feats_choices', 'spells'].includes(cat) ? 'open' : ''}><summary>${esc(CAT_LABEL[cat] || cat)}</summary>
        <table class="dm-rule-table"><thead><tr><th scope="col">Action</th><th scope="col">Decision</th><th scope="col" class="small">Preset</th></tr></thead><tbody>
        ${g.actions.filter((a) => a.category === cat).map((a) => `<tr><th scope="row">${esc(a.label)}${a.description ? `<span class="small muted">${esc(a.description)}</span>` : ''}</th>
          <td><select data-action="${esc(a.key)}" aria-label="${esc(a.label)}" ${choices(a).length < 2 ? 'disabled' : ''}>${choices(a).map((d) => `<option value="${d}" ${a.decision === d ? 'selected' : ''}>${esc(gov.DECISION_LABEL[d])}</option>`).join('')}</select>
            ${a.overridden ? '<span class="req-chip">changed</span>' : ''}</td><td class="small muted">${esc(gov.DECISION_LABEL[a.preset_decision])}</td></tr>`).join('')}</tbody></table></details>`).join('')}
      <div class="dm-action-row"><button type="submit" class="btn btn-gold">Save campaign rules</button>
        <button type="button" class="btn" data-backup>Download DM backup (includes hidden data)</button></div>
    </form>`;
  const form = $('[data-rules]', panel);
  $('[data-share-toggle]', panel)?.addEventListener('change', async (e) => {
    const box = e.target;
    const on = box.checked;
    if (!on && !await confirmDialog('Stop sharing identification with the party? What characters already know stays; from now on each character learns on their own.', { okLabel: 'Stop sharing' })) { box.checked = true; return; }
    box.disabled = true;
    try {
      const res = await dm.setIdentificationSharing(campaignId, on);
      toast(on ? `Identification is shared with the party.${res.caught_up ? ` ${res.caught_up} item(s) became known to more characters.` : ''}` : 'Identification is no longer shared with the party.', 'good');
    } catch (err) { box.checked = !on; toast(err.message, 'bad'); }
    box.disabled = false;
  });
  $('[data-share-sync]', panel)?.addEventListener('click', async (e) => {
    const b = e.currentTarget;
    b.disabled = true;
    try {
      const r = await dm.syncPartyKnowledge(campaignId);
      toast(`Party knowledge synced: ${r.applied} change(s)${r.pending ? `, ${r.pending} still waiting for a busy character` : ''}.`, 'good');
    } catch (err) { toast(err.message, 'bad'); }
    b.disabled = false;
  });
  form.addEventListener('change', (e) => { if (e.target.name === 'preset') $$('.dm-preset', form).forEach((l) => l.classList.toggle('is-on', l.contains(e.target))); });
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const fd = new FormData(form);
    const preset = fd.get('preset');
    const settings = { preset, unmet_prerequisites: fd.get('unmet_prerequisites'), require_approval_note: !!fd.get('require_approval_note'),
      allow_edit_and_approve: !!fd.get('allow_edit_and_approve'),
      content: { rulesets: ['2014', '2024'].filter((r) => fd.get(`ruleset_${r}`)), allow_legacy: !!fd.get('allow_legacy'), allow_setting: !!fd.get('allow_setting'),
                 allow_playtest: !!fd.get('allow_playtest'), allow_custom: !!fd.get('allow_custom') } };
    if (preset === g.preset || preset === 'custom') {
      const overrides = {};
      $$('[data-action]', form).forEach((s) => { const a = g.actions.find((x) => x.key === s.dataset.action); if (a && s.value !== a.decision) overrides[a.key] = s.value; });
      if (Object.keys(overrides).length) settings.overrides = overrides;
    }
    try { await gov.setCampaignGovernance(campaignId, settings, g.configured ? g.revision : null); toast('Campaign rules saved.', 'good'); campaigns = await dm.getMyDmCampaigns(); frame(); show('rules'); }
    catch (err) { toast(err.message, 'bad', 6000); }
  });
  $('[data-backup]', panel).addEventListener('click', async () => {
    try {
      const data = await dm.exportDmBackup(campaignId);
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
      a.download = `${(camp()?.name || 'campaign').replace(/[^a-z0-9]+/gi, '-').toLowerCase()}-dm-backup.json`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    } catch (err) { toast(err.message, 'bad'); }
  });
}

// ---- audit ---------------------------------------------------------------------------------------------------------------------------
async function audit(panel, alive) {
  const p = { characters: await dm.getCampaignCharacters(campaignId) };
  const f = { character: store.get('audit-character') || '', type: store.get('audit-type') || '' };
  const list = await gov.getCampaignAudit(campaignId, { characterId: f.character || null, types: f.type ? [f.type] : null, limit: 300 });
  if (!alive()) return;
  const types = ['request_submitted', 'request_returned', 'request_approved', 'request_rejected', 'request_applied', 'request_apply_failed', 'level_changed', 'feat_added',
    'feat_removed', 'spell_learned', 'item_assigned', 'content_published', 'content_archived', 'hidden_effect_added', 'hidden_effect_revealed', 'character_lock_changed',
    'governance_changed', 'dm_override_used', 'item_revealed', 'condition_added'];
  panel.innerHTML = `<div class="dm-filters">
      <label class="field"><span>Character</span><select data-au-char><option value="">All</option>${p.characters.map((c) => `<option value="${esc(c.id)}" ${f.character === c.id ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></label>
      <label class="field"><span>Event</span><select data-au-type><option value="">All</option>${types.map((t) => `<option value="${t}" ${f.type === t ? 'selected' : ''}>${esc(t.replace(/_/g, ' '))}</option>`).join('')}</select></label>
    </div>${timelineHTML(list)}`;
  $('[data-au-char]', panel).addEventListener('change', (e) => { store.set('audit-character', e.target.value); show('audit'); });
  $('[data-au-type]', panel).addEventListener('change', (e) => { store.set('audit-type', e.target.value); show('audit'); });
}

export { openReview, focusByKey };
