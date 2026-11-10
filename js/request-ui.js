// Player side of campaign governance on the character sheet (docs/APPROVAL_WORKFLOWS.md, CHARACTER_LOCKS.md):
// the lock / setup banner, the "pending changes" tray, the request list, and the dialog that turns a refused change
// (approval required) into a request for the DM. The database decides what needs approval; this module only reacts.

import { supabase } from './supabase.js?v=21';
import { $, $$, esc, toast, openModal, confirmDialog } from './utils.js?v=21';
import { icon } from './icons.js?v=21';
import {
  getCharacterGovernance, getCharacterChangeRequests, opForCall, addChangeRequestOp, createChangeRequest, submitChangeRequest,
  updateChangeRequest, cancelChangeRequest, previewChangeRequest, STATUS_LABEL, LOCK_TEXT,
} from './governance-api.js?v=21';

const fmtTime = (t) => (t ? new Date(t).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '');
const OPEN = new Set(['draft', 'submitted', 'returned_for_changes', 'apply_failed']);

/** A structured diff ({label, kind, before, after, added, removed}) as readable lines. Shared with DM Space. */
export function diffHTML(diff) {
  if (!diff?.length) return '<p class="muted small">No visible change to the character sheet.</p>';
  return `<ul class="diff-list">${diff.map((d) => d.kind === 'list'
    ? `<li><span class="diff-label">${esc(d.label)}</span>
         ${(d.added || []).map((x) => `<span class="diff-add">+ ${esc(x)}</span>`).join('')}
         ${(d.removed || []).map((x) => `<span class="diff-del">− ${esc(x)}</span>`).join('')}</li>`
    : `<li><span class="diff-label">${esc(d.label)}</span> <span class="diff-before">${esc(d.before ?? '—')}</span>
         <span aria-hidden="true">→</span><span class="sr-only">changes to</span> <span class="diff-after">${esc(d.after ?? '—')}</span></li>`).join('')}</ul>`;
}

// "tough-2024" -> "Tough (2024)": a readable version id when the request carries no name
const versionLabel = (id) => {
  const m = /^(.+)-(2014|2024|ua)$/.exec(String(id));
  if (!m || m[1].startsWith('cc-')) return id;
  return `${m[1].split('-').map((w) => (w.length > 2 || w === m[1] ? w[0].toUpperCase() + w.slice(1) : w)).join(' ')} (${m[2] === 'ua' ? 'playtest' : m[2]})`;
};
const PATCH_LABEL = { hp_max: 'Maximum HP', speed: 'Speed', ac: 'AC', initiative_bonus: 'Initiative bonus', strength: 'STR', dexterity: 'DEX',
  constitution: 'CON', intelligence: 'INT', wisdom: 'WIS', charisma: 'CHA', abilities: 'Ability scores', classes: 'Classes', feats: 'Feats',
  known_spells: 'Known spells', proficiencies: 'Proficiencies', companions: 'Companions', lineage: 'Lineage', background: 'Background',
  choices: 'Class feature choices', feat_choices: 'Feat choices' };
export const fieldLabel = (k) => PATCH_LABEL[k] || k.replace(/_/g, ' ');

/** One request step in words. */
export function stepHTML(s) {
  const a = s.args || {};
  const bits = [];
  if (a.p_class_version) bits.push(`${a.p_class_version} → level ${a.p_level ?? '?'}`);
  if (a.p_version) bits.push(versionLabel(a.p_version));
  if (a.p_spell_version) bits.push(a.p_spell_version);
  if (a.p_item) bits.push(`${a.p_item}${a.p_quantity > 1 ? ` ×${a.p_quantity}` : ''}`);
  if (a.p_values) bits.push(a.p_values.join(', '));
  if (a.p_patch) bits.push(Object.entries(a.p_patch).map(([k, v]) => `${fieldLabel(k)} ${v}`).join(', '));
  if (a.p_creatures) bits.push(a.p_creatures.join(', '));
  if (a.p_creature) bits.push(a.p_creature);
  return `<li><strong>${esc(s.label || s.op)}</strong>${bits.length ? ` <span class="muted small">${esc(bits.join(' · '))}</span>` : ''}</li>`;
}

export const statusChip = (st) => `<span class="req-chip req-${esc(st)}">${esc(STATUS_LABEL[st] || st)}</span>`;

/**
 * Mount the governance bar of one character. host: an element on the sheet; opts: {characterId, reload, onRefused}.
 * Returns {destroy, refresh, decision(actionKey)}.
 */
export function mountGovernance(host, { characterId, reload, onRefused, onState } = {}) {
  let gov = null;
  let requests = [];
  let seq = 0;
  let channel = null;
  let destroyed = false;

  const decision = (key) => gov?.decisions?.[key] || 'player_managed';

  async function refresh() {
    const my = ++seq;
    try {
      const [g, r] = await Promise.all([getCharacterGovernance(characterId), getCharacterChangeRequests(characterId, false)]);
      if (destroyed || my !== seq) return;
      gov = g;
      requests = r || [];
      render();
    } catch (err) {
      if (!destroyed) console.warn('Governance unavailable:', err.message);
    }
  }

  function render() {
    if (!host || !gov) return;
    const draft = requests.find((r) => r.status === 'draft');
    const waiting = requests.filter((r) => r.status === 'submitted').length;
    const returned = requests.filter((r) => r.status === 'returned_for_changes').length;
    const parts = [];
    if (gov.lock_mode && gov.lock_mode !== 'unlocked') {
      parts.push(`<div class="gov-banner gov-lock" role="status">${icon('ui/locked', { size: 22 })}
        <span>${esc(LOCK_TEXT[gov.lock_mode] || 'Locked by your DM.')}${gov.lock_reason ? ` <em>${esc(gov.lock_reason)}</em>` : ''}</span></div>`);
    }
    if (gov.governed && !gov.is_dm && !gov.setup_complete && gov.preset && gov.preset !== 'relaxed') {
      parts.push(`<div class="gov-banner gov-setup" role="status">${icon('ui/build', { size: 22 })}
        <span>Initial setup: build your character freely. Once your DM marks the setup complete, permanent changes go through requests.</span></div>`);
    }
    if (gov.governed && (draft || waiting || returned)) {
      parts.push(`<div class="gov-tray">
        ${draft ? `<span><strong>${draft.ops.length}</strong> change${draft.ops.length === 1 ? '' : 's'} not sent yet</span>
                   <button type="button" class="btn btn-sm btn-gold" data-gov="review-draft" data-focus-key="gov-review-draft">Review &amp; send</button>` : ''}
        ${waiting ? `<span class="req-chip req-submitted">${waiting} waiting for the DM</span>` : ''}
        ${returned ? `<span class="req-chip req-returned_for_changes">${returned} returned to you</span>` : ''}
        <button type="button" class="btn btn-sm" data-gov="list" data-focus-key="gov-list">Requests</button>
      </div>`);
    } else if (gov.governed) {
      parts.push(`<div class="gov-tray gov-tray-quiet"><button type="button" class="btn btn-sm btn-ghost" data-gov="list" data-focus-key="gov-list">Requests</button></div>`);
    }
    host.innerHTML = parts.join('');
    host.hidden = !parts.length;
    onState?.({ gov, requests });
  }

  // ---- dialogs -----------------------------------------------------------------------------------------------------------
  async function askApproval({ fn, args, error }) {
    if (!gov?.governed || gov.is_dm) return;
    const op = await opForCall(fn, args).catch(() => null);
    if (!op) return;
    const m = openModal({
      title: 'Ask your DM',
      body: `
        <p>${esc(error?.message || 'This change needs your DM\'s approval.')}</p>
        <ul class="req-steps">${stepHTML(op)}</ul>
        <label class="field"><span>Note for your DM (optional)</span><textarea data-note rows="2" maxlength="2000"
          placeholder="Why, or what happened in the story"></textarea></label>
        <p class="muted small">Add it to your pending changes to send several changes together (for example a level-up with its new spells),
          or send it now.</p>`,
      footer: `
        <button type="button" class="btn" data-close>Cancel</button>
        <button type="button" class="btn" data-add>Add to pending changes</button>
        <button type="button" class="btn btn-gold" data-send>Send to DM now</button>`,
    });
    const busy = (on) => $$('button', m.el).forEach((b) => { b.disabled = on; });
    $('[data-add]', m.el).addEventListener('click', async () => {
      busy(true);
      try {
        await addChangeRequestOp(characterId, { op: op.op, args: op.args }, op.label);
        toast('Added to your pending changes.', 'good');
        m.close();
        refresh();
      } catch (err) { busy(false); toast(err.message, 'bad'); }
    });
    $('[data-send]', m.el).addEventListener('click', async () => {
      busy(true);
      try {
        await createChangeRequest(characterId, [{ op: op.op, args: op.args }], { title: op.label, note: $('[data-note]', m.el).value.trim() || null });
        toast('Sent to your DM.', 'good');
        m.close();
        refresh();
      } catch (err) { busy(false); toast(err.message, 'bad'); }
    });
  }

  async function reviewRequest(req) {
    const m = openModal({
      title: req.status === 'returned_for_changes' ? 'Revise your request' : 'Your pending changes',
      wide: true,
      body: `
        ${req.review_note ? `<div class="gov-banner gov-returned"><strong>Your DM:</strong> ${esc(req.review_note)}</div>` : ''}
        <h3 class="small-h">Changes</h3>
        <ul class="req-steps" data-steps>${req.steps.map((s, i) => stepHTML(s).replace('</li>',
          `${req.steps.length > 1 ? ` <button type="button" class="btn btn-xs btn-ghost" data-remove="${i}" aria-label="Remove ${esc(s.label)}">Remove</button>` : ''}</li>`)).join('')}</ul>
        <h3 class="small-h">What changes on your sheet</h3>
        <div data-preview><p class="muted small">Calculating…</p></div>
        <label class="field"><span>Note for your DM</span><textarea data-note rows="2" maxlength="2000">${esc(req.player_note || '')}</textarea></label>`,
      footer: `
        <button type="button" class="btn btn-bad" data-discard>${req.status === 'draft' ? 'Discard' : 'Cancel request'}</button>
        <button type="button" class="btn" data-close>Close</button>
        <button type="button" class="btn btn-gold" data-send>${req.status === 'draft' ? 'Send to DM' : 'Send again'}</button>`,
    });
    let current = req;
    const loadPreview = async () => {
      try {
        const p = await previewChangeRequest(current.id);
        const el = $('[data-preview]', m.el);
        if (!el) return;
        el.innerHTML = p.preview?.ok ? diffHTML(p.preview.diff)
          : `<p class="gov-error" role="alert">This cannot be sent as it is: ${esc(p.preview?.error || 'unknown problem')}</p>`;
      } catch (err) { $('[data-preview]', m.el).innerHTML = `<p class="gov-error">${esc(err.message)}</p>`; }
    };
    loadPreview();
    m.el.addEventListener('click', async (e) => {
      const rm = e.target.closest('[data-remove]');
      if (!rm) return;
      const ops = current.ops.filter((_, i) => i !== Number(rm.dataset.remove));
      try {
        current = await updateChangeRequest(current.id, { ops, revision: current.revision });
        $('[data-steps]', m.el).innerHTML = current.steps.map((s) => stepHTML(s)).join('');
        loadPreview();
      } catch (err) { toast(err.message, 'bad'); }
    });
    $('[data-send]', m.el).addEventListener('click', async (e) => {
      e.target.disabled = true;
      try {
        const note = $('[data-note]', m.el).value.trim();
        if (note !== (current.player_note || '')) current = await updateChangeRequest(current.id, { note, revision: current.revision });
        await submitChangeRequest(current.id, current.revision);
        toast('Sent to your DM.', 'good');
        m.close();
        refresh();
      } catch (err) { e.target.disabled = false; toast(err.message, 'bad'); }
    });
    $('[data-discard]', m.el).addEventListener('click', async () => {
      if (!(await confirmDialog(current.status === 'draft' ? 'Discard these pending changes?' : 'Cancel this request?', { danger: true, okLabel: 'Yes' }))) return;
      try { await cancelChangeRequest(current.id); m.close(); refresh(); } catch (err) { toast(err.message, 'bad'); }
    });
  }

  async function listRequests() {
    let all = [];
    try { all = await getCharacterChangeRequests(characterId, true); } catch (err) { toast(err.message, 'bad'); return; }
    const m = openModal({
      title: 'Requests to your DM',
      wide: true,
      body: all.length ? `<ul class="req-list">${all.map((r) => `
        <li class="req-item">
          <div class="req-head">${statusChip(r.status)} <strong>${esc(r.title)}</strong>
            <span class="muted small">${esc(fmtTime(r.submitted_at || r.created_at))}</span></div>
          ${r.review_note ? `<p class="req-note"><strong>DM:</strong> ${esc(r.review_note)}</p>` : ''}
          ${r.status === 'apply_failed' ? '<p class="muted small">Approved, but it could not be applied yet. Your DM will retry.</p>' : ''}
          <details><summary>Changes</summary><ul class="req-steps">${r.steps.map(stepHTML).join('')}</ul>
            ${r.preview?.diff ? diffHTML(r.preview.diff) : ''}</details>
          <div class="req-actions">
            ${['draft', 'returned_for_changes'].includes(r.status) ? `<button type="button" class="btn btn-sm btn-gold" data-open="${esc(r.id)}">${r.status === 'draft' ? 'Review & send' : 'Revise'}</button>` : ''}
            ${r.status === 'submitted' ? `<button type="button" class="btn btn-sm" data-cancel="${esc(r.id)}">Cancel request</button>` : ''}
          </div>
        </li>`).join('')}</ul>` : '<p class="muted">No requests yet. When a change needs your DM\'s approval, the sheet offers to send it.</p>',
      footer: '<button type="button" class="btn" data-close>Close</button>',
    });
    m.el.addEventListener('click', async (e) => {
      const open = e.target.closest('[data-open]');
      const cancel = e.target.closest('[data-cancel]');
      if (open) { m.close(); reviewRequest(all.find((r) => r.id === open.dataset.open)); }
      if (cancel && (await confirmDialog('Cancel this request?', { okLabel: 'Cancel request', danger: true }))) {
        try { await cancelChangeRequest(cancel.dataset.cancel); m.close(); refresh(); } catch (err) { toast(err.message, 'bad'); }
      }
    });
  }

  // ---- wiring --------------------------------------------------------------------------------------------------------
  const onClick = (e) => {
    const b = e.target.closest('[data-gov]');
    if (!b) return;
    if (b.dataset.gov === 'list') listRequests();
    if (b.dataset.gov === 'review-draft') { const d = requests.find((r) => r.status === 'draft'); if (d) reviewRequest(d); }
  };
  const onGovernance = (e) => {
    const { fn, args, error } = e.detail || {};
    if (error?.code !== 'TLAPR') return;
    if (args?.p_character && args.p_character !== characterId) return;
    askApproval({ fn, args, error });
  };
  const onRefusedSave = (e) => { if (e.detail?.id === characterId || e.detail?.table !== 'characters') onRefused?.(e.detail); };
  host?.addEventListener('click', onClick);
  window.addEventListener('tavern:governance', onGovernance);
  window.addEventListener('tavern:save-refused', onRefusedSave);
  channel = supabase.channel(`requests-${characterId}-${Math.random().toString(36).slice(2, 8)}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'change_requests', filter: `character_id=eq.${characterId}` }, (p) => {
      const was = p.old?.status;
      const now = p.new?.status;
      if (now && now !== was && !OPEN.has(now) && now !== 'cancelled') {
        toast(`Your DM ${now === 'applied' ? 'approved' : now === 'rejected' ? 'rejected' : 'answered'}: ${p.new.title}`, now === 'rejected' ? 'bad' : 'good', 5000);
        if (now === 'applied') reload?.();
      } else if (now === 'returned_for_changes' && was !== now) {
        toast(`Your DM returned "${p.new.title}" for changes.`, 'info', 5000);
      }
      refresh();
    })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'character_governance', filter: `character_id=eq.${characterId}` }, () => refresh())
    .subscribe();
  refresh();

  return {
    refresh,
    decision,
    openRequests: () => listRequests(),
    get state() { return gov; },
    destroy() {
      destroyed = true;
      host?.removeEventListener('click', onClick);
      window.removeEventListener('tavern:governance', onGovernance);
      window.removeEventListener('tavern:save-refused', onRefusedSave);
      if (channel) supabase.removeChannel(channel);
      channel = null;
    },
  };
}
