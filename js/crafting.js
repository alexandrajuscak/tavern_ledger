// Crafting v1 (docs/CRAFTING_V1.md). Loaded ONLY through a dynamic import() when js/config.js CRAFTING is not 'off' (dm-space.js,
// inventory-ui.js): with the shipped 'off' this file is never requested. The database authorizes everything itself: the DM
// RPCs need the campaign DM role, the player RPCs the character's owner and the campaign rule inventory.craft (off by default).
// The server never rolls: the player types the total of a physical roll, the DM confirms or corrects it.

import { supabase } from './supabase.js?v=32';
import { $, $$, esc, toast, openModal, confirmDialog, debounce, friendlyError } from './utils.js?v=32';
import { getEditorReference } from './dm-api.js?v=32';
import { icon } from './icons.js?v=32';
import { sectionHead } from './section.js?v=32';

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) { const e = new Error(friendlyError(error)); e.code = error.code; throw e; }
  return data;
}

// ---- API ------------------------------------------------------------------------------------------------------------------------
export const getCharacterRecipes = (characterId) => rpc('get_character_recipes', { p_character: characterId });
export const startCraft = (characterId, recipeId, selected, roll, requestId, natural, note) =>
  rpc('start_craft_attempt', { p_character: characterId, p_recipe: recipeId, p_selected: selected, p_roll_total: roll, p_request_id: requestId,
    p_natural: natural || null, p_note: note || null });
export const cancelCraft = (attemptId) => rpc('cancel_craft_attempt', { p_attempt: attemptId });
export const markRecipesSeen = (characterId) => rpc('mark_recipes_seen', { p_character: characterId });
export const getCampaignRecipes = (campaignId) => rpc('get_campaign_recipes', { p_campaign: campaignId });
export const getCraftAttempts = (campaignId, status = 'open') => rpc('get_campaign_craft_attempts', { p_campaign: campaignId, p_status: status });
export const pendingCraftCount = (campaignId) => rpc('get_campaign_pending_craft_count', { p_campaign: campaignId });
export const searchCraftItems = (campaignId, q) => rpc('get_campaign_craft_items', { p_campaign: campaignId, p_query: q || null });
export const saveRecipe = (campaignId, recipe, revision = null) => rpc('dm_save_recipe', { p_campaign: campaignId, p_recipe: recipe, p_expected_revision: revision });
export const setRecipeStatus = (recipeId, status) => rpc('dm_set_recipe_status', { p_recipe: recipeId, p_status: status });
export const grantRecipe = (recipeId, characterIds, grant = true) => rpc('dm_grant_recipe', { p_recipe: recipeId, p_characters: characterIds, p_grant: grant });
export const resolveAttempt = (attemptId, decision, o = {}) => rpc('dm_resolve_craft_attempt', { p_attempt: attemptId, p_decision: decision,
  p_outcome: o.outcome || null, p_dm_roll_total: o.roll ?? null, p_reply: o.reply || null, p_private_note: o.privateNote || null,
  p_failure_consumes: o.failureConsumes || null, p_expected_revision: o.revision ?? null });

const STATUS = { pending: ['Waiting for the DM', 'warn'], applied: ['Done', 'good'], rejected: ['Not accepted', 'bad'], cancelled: ['Cancelled', ''],
  apply_failed: ['Waiting for the DM', 'warn'] };
const OUTCOME = { success: 'Success', failure: 'Failure', critical_success: 'Critical success', critical_failure: 'Critical failure' };
const FAILURE = { keep: 'Keep the ingredients', lose_all: 'Lose the used-up ingredients', lose_half: 'Lose half of them' };
const VIS = { known: 'Known to every character', discoverable: 'To discover (players see that something is left to find)', secret: 'Secret (only who you grant it to)' };
const chip = (st) => { const [l, t] = STATUS[st] || [st, '']; return `<span class="req-chip cr-st-${esc(t)}" data-craft-status="${esc(st)}">${esc(l)}</span>`; };
const fmt = (t) => (t ? new Date(t).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '');
const list = (xs) => (xs || []).map((x) => `${esc(x.quantity)} × ${esc(x.name)}`).join(', ');

// =================================================================================================================================
// Player: Inventory → Crafting
// =================================================================================================================================
/** The player's crafting panel. attach(slot) renders into the inventory's slot (re-created on every inventory render). */
export function createPlayerCrafting({ characterId, onInventoryChanged }) {
  const s = { data: null, error: null, loading: false, slot: null, destroyed: false };

  async function refresh() {
    if (s.loading || s.destroyed) return;
    s.loading = true;
    try { s.data = await getCharacterRecipes(characterId); s.error = null; } catch (err) { s.error = err; }
    finally { s.loading = false; }
    paint();
  }
  const refreshSoon = debounce(refresh, 300);

  function html() {
    if (s.error) return `<section class="tl-section inv-crafting" data-crafting aria-labelledby="inv-craft-title">${sectionHead({ id: 'inv-craft-title', icon: 'potion.flask', title: 'Crafting' })}
      <p class="small muted">${esc(s.error.message)}</p></section>`;
    if (!s.data) return `<section class="tl-section inv-crafting" data-crafting aria-labelledby="inv-craft-title">${sectionHead({ id: 'inv-craft-title', icon: 'potion.flask', title: 'Crafting' })}
      <p class="small muted">Loading recipes…</p></section>`;
    const d = s.data;
    const recipes = d.recipes || [];
    const fresh = recipes.filter((r) => r.new);
    const recent = (d.attempts || []).slice(0, 5);
    return `<section class="tl-section inv-crafting" data-crafting aria-labelledby="inv-craft-title">
      ${sectionHead({ id: 'inv-craft-title', icon: 'potion.flask', title: 'Crafting', count: recipes.length })}
      ${fresh.length ? `<div class="cr-new" role="status" data-craft-new>${icon('dm/approved', { size: 18 })}<span>New recipe learned: <strong>${esc(fresh.map((r) => r.name).join(', '))}</strong></span>
        <button type="button" class="btn btn-sm btn-ghost" data-cr="seen">Got it</button></div>` : ''}
      ${recipes.length ? `<ul class="cr-recipes">${recipes.map(recipeHTML).join('')}</ul>` : '<p class="empty">No recipes yet. Your DM shares them with you.</p>'}
      ${d.undiscovered ? `<p class="small muted" data-craft-undiscovered>${esc(d.undiscovered)} recipe${d.undiscovered === 1 ? '' : 's'} still to discover.</p>` : ''}
      ${recent.length ? `<details class="cr-recent"><summary class="small">Recent attempts</summary><ul class="inv-side-list">${recent.map((a) => `<li class="inv-side-row" data-craft-attempt="${esc(a.attempt_id)}">
        <span class="inv-side-name">${esc(a.recipe_name)} ${chip(a.status)}${a.outcome ? ` <span class="small muted">${esc(OUTCOME[a.outcome] || a.outcome)}</span>` : ''}
        ${a.produced?.length ? `<br><span class="small">Made: ${list(a.produced)}</span>` : ''}${a.consumed?.length ? `<br><span class="small muted">Used: ${list(a.consumed)}</span>` : ''}
        ${a.dm_reply ? `<br><span class="small">DM: ${esc(a.dm_reply)}</span>` : ''}</span>
        ${a.status === 'pending' ? `<span class="inv-side-actions"><button type="button" class="btn btn-sm btn-ghost" data-cr="cancel" data-id="${esc(a.attempt_id)}">Cancel</button></span>` : ''}</li>`).join('')}</ul></details>` : ''}
    </section>`;
  }

  function recipeHTML(r) {
    const out = r.output || {};
    return `<li class="cr-recipe" data-recipe="${esc(r.recipe_id)}">
      <p><strong>${esc(r.name)}</strong>${r.new ? ' <span class="req-chip">new</span>' : ''} <span class="small muted">→ ${esc(out.quantity)} × ${esc(out.name)}</span></p>
      ${r.description ? `<p class="small">${esc(r.description)}</p>` : ''}
      <ul class="small cr-ings">${(r.ingredients || []).map((g) => `<li class="${g.have >= g.quantity ? 'cr-have' : 'cr-miss'}">${esc(g.quantity)} × ${esc(g.label)}${g.consumed ? '' : ' <span class="muted">(kept)</span>'}
        <span class="muted">· you have ${esc(g.have)}</span></li>`).join('')}</ul>
      <p class="small muted">${r.check ? `Roll: ${esc(r.check.label)}. ` : ''}${r.dm_confirms ? 'Your DM confirms the result.' : 'Done at once.'}${r.time_note ? ` ${esc(r.time_note)}` : ''}</p>
      ${r.pending_attempt_id ? `<p class="small">${chip('pending')}</p>` : `<button type="button" class="btn btn-sm btn-good" data-cr="craft" data-id="${esc(r.recipe_id)}" ${r.can_craft ? '' : 'disabled'}>${r.can_craft ? 'Craft…' : 'Missing ingredients'}</button>`}
    </li>`;
  }

  function paint() {
    if (!s.slot?.isConnected) return;
    s.slot.innerHTML = html();
  }

  async function onClick(e) {
    const b = e.target.closest('[data-cr]');
    if (!b || !s.slot?.contains(b)) return;
    const a = b.dataset.cr;
    if (a === 'seen') { try { await markRecipesSeen(characterId); } catch (err) { toast(err.message, 'bad'); } refresh(); return; }
    if (a === 'cancel') {
      if (!(await confirmDialog('Cancel this crafting attempt? Nothing was used yet.', { okLabel: 'Cancel attempt' }))) return;
      try { await cancelCraft(b.dataset.id); toast('Attempt cancelled.'); } catch (err) { toast(err.message, 'bad'); }
      refresh(); return;
    }
    if (a === 'craft') craftDialog((s.data?.recipes || []).find((r) => r.recipe_id === b.dataset.id));
  }

  function craftDialog(r) {
    if (!r) return;
    const requestId = crypto.randomUUID();   // kept for retries of the same dialog: a repeated click is applied once
    const m = openModal({ title: `Craft: ${r.name}`, body: `
      <p class="small">${esc(r.output.quantity)} × ${esc(r.output.name)}. ${r.dm_confirms ? 'Your DM confirms the result.' : 'Done at once.'}</p>
      ${(r.ingredients || []).map((g) => `<label class="field"><span>${esc(g.quantity)} × ${esc(g.label)}${g.consumed ? '' : ' (kept)'}</span>
        <select data-cr-ing="${esc(g.seq)}" data-need="${esc(g.quantity)}">${(g.candidates || []).filter((c) => c.quantity >= g.quantity)
          .map((c) => `<option value="${esc(c.inventory_item_id)}">${esc(c.name)} (×${esc(c.quantity)})</option>`).join('') || '<option value="">No single stack has enough: combine your stacks first</option>'}</select></label>`).join('')}
      ${r.check ? `<label class="field"><span>Total of your ${esc(r.check.label)} roll</span><input type="number" data-cr-roll min="-10" max="60" required></label>
        <label class="field"><span>Natural roll</span><select data-cr-nat><option value="">—</option><option value="nat20">Natural 20</option><option value="nat1">Natural 1</option></select></label>` : ''}
      <label class="field"><span>Note for your DM (optional)</span><input type="text" data-cr-note maxlength="500"></label>`,
    footer: `<button type="button" class="btn" data-close>Close</button><button type="button" class="btn btn-gold" data-cr-go>${r.dm_confirms ? 'Send to my DM' : 'Craft'}</button>` });
    $('[data-cr-go]', m.el).addEventListener('click', async (ev) => {
      const sel = $$('[data-cr-ing]', m.el).map((x) => ({ seq: Number(x.dataset.crIng), inventory_item_id: x.value, quantity: Number(x.dataset.need) }));
      if (sel.some((x) => !x.inventory_item_id)) { toast('Choose a stack for every ingredient.', 'bad'); return; }
      const rollEl = $('[data-cr-roll]', m.el);
      const roll = rollEl ? (rollEl.value === '' ? null : Number(rollEl.value)) : null;
      if (rollEl && roll == null) { toast('Enter the total of your roll.', 'bad'); return; }
      ev.target.disabled = true;
      try {
        const res = await startCraft(characterId, r.recipe_id, sel, roll, requestId, $('[data-cr-nat]', m.el)?.value, $('[data-cr-note]', m.el).value.trim());
        toast(res.status === 'applied' ? `Crafted: ${list(res.produced) || r.name}` : 'Sent to your DM.', 'good');
        m.close();
        onInventoryChanged?.();
        refresh();
      } catch (err) { toast(err.message, 'bad', 5000); ev.target.disabled = false; }
    });
  }

  return {
    /** Render into the slot of the current inventory render (and load on first use). */
    attach(slot) {
      if (!slot) return;
      s.slot = slot;
      slot.addEventListener('click', onClick);
      paint();
      if (!s.data && !s.loading && !s.error) refresh();
    },
    refresh: refreshSoon,
    destroy() { s.destroyed = true; s.slot = null; },
  };
}

// =================================================================================================================================
// DM Space → Crafting
// =================================================================================================================================
export async function dmCraftingPanel(panel, alive, { campaignId, onCount, reload: again }) {
  const [rec, open, closed] = await Promise.all([getCampaignRecipes(campaignId), getCraftAttempts(campaignId, 'open'), getCraftAttempts(campaignId, 'closed')]);
  if (!alive()) return;
  onCount?.(open.length);
  const reload = () => again?.();   // DM Space shows the section again in a fresh panel (no listeners pile up)
  const on = rec.enabled === 'player_managed';
  panel.innerHTML = `
    ${on ? '' : `<div class="gov-banner" data-craft-off>Players cannot craft in this campaign yet. You can prepare recipes now; turn crafting on in
      Campaign rules → Inventory → Crafting.</div>`}
    <section class="card dm-card dm-wide" data-craft-queue><h2>Crafting attempts${open.length ? ` (${open.length})` : ''}</h2>
      ${open.length ? `<ul class="cr-queue">${open.map(attemptHTML).join('')}</ul>` : '<p class="muted">No attempts waiting for you.</p>'}</section>
    <section class="card dm-card dm-wide" data-craft-recipes><h2>Recipes</h2>
      <div class="dm-action-row"><button type="button" class="btn btn-gold btn-sm" data-crd="new">+ New recipe</button></div>
      ${rec.recipes.length ? `<table class="dm-rule-table cr-table"><thead><tr><th scope="col">Recipe</th><th scope="col">Makes</th><th scope="col">Check</th><th scope="col">Status</th><th scope="col"></th></tr></thead><tbody>
        ${rec.recipes.map((r) => `<tr data-recipe="${esc(r.id)}"><th scope="row">${esc(r.name)}<span class="small muted">${esc(VIS[r.visibility] || r.visibility)}${r.known_by.length ? ` · learned by ${esc(r.known_by.map((k) => k.name).join(', '))}` : ''}</span></th>
          <td class="small">${esc(r.output_quantity)} × ${esc(r.output_name)}${r.output_secret ? ' <span class="muted">(hidden item)</span>' : ''}</td>
          <td class="small">${r.check_key ? `${esc(r.check_label)}${r.check_dc ? ` DC ${esc(r.check_dc)}` : ''}` : '—'}${r.requires_dm_approval ? '' : ' · automatic'}</td>
          <td class="small">${esc(r.status)}${r.pending ? ` · ${esc(r.pending)} waiting` : ''}</td>
          <td class="dm-action-row">${r.status !== 'archived' ? `<button type="button" class="btn btn-xs" data-crd="edit" data-id="${esc(r.id)}">Edit</button>` : ''}
            ${r.status === 'draft' ? `<button type="button" class="btn btn-xs btn-gold" data-crd="status" data-st="published" data-id="${esc(r.id)}">Publish</button>` : ''}
            ${r.status === 'published' ? `<button type="button" class="btn btn-xs" data-crd="status" data-st="archived" data-id="${esc(r.id)}">Archive</button>` : ''}
            ${r.status === 'archived' ? `<button type="button" class="btn btn-xs" data-crd="status" data-st="published" data-id="${esc(r.id)}">Restore</button>` : ''}
            ${r.visibility !== 'known' && r.status !== 'archived' ? `<button type="button" class="btn btn-xs btn-ghost" data-crd="grant" data-id="${esc(r.id)}">Who knows it…</button>` : ''}</td></tr>`).join('')}
        </tbody></table>` : '<p class="muted">No recipes yet.</p>'}</section>
    <section class="card dm-card dm-wide"><details><summary><strong>History</strong> <span class="small muted">(${closed.length})</span></summary>
      ${closed.length ? `<ul class="cr-history small">${closed.slice(0, 50).map((a) => `<li>${esc(fmt(a.resolved_at || a.created_at))} · <strong>${esc(a.character_name)}</strong>: ${esc(a.recipe_name)} ${chip(a.status)}
        ${a.outcome ? esc(OUTCOME[a.outcome] || a.outcome) : ''}${a.produced?.length ? ` · made ${list(a.produced)}` : ''}${a.consumed?.length ? ` · used ${list(a.consumed)}` : ''}
        ${a.dm_private_note ? `<span class="muted">· note: ${esc(a.dm_private_note)}</span>` : ''}</li>`).join('')}</ul>` : '<p class="muted">Nothing yet.</p>'}</details></section>`;

  panel.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-crd]');
    if (!b) return;
    const a = b.dataset.crd;
    if (a === 'new') return recipeEditor(campaignId, null, reload);
    if (a === 'edit') return recipeEditor(campaignId, rec.recipes.find((r) => r.id === b.dataset.id), reload);
    if (a === 'grant') return grantDialog(rec.recipes.find((r) => r.id === b.dataset.id), rec.characters, reload);
    if (a === 'status') {
      try { await setRecipeStatus(b.dataset.id, b.dataset.st); toast(b.dataset.st === 'published' ? 'Published.' : 'Archived.', 'good'); reload(); } catch (err) { toast(err.message, 'bad'); }
      return;
    }
    if (a === 'approve' || a === 'reject') {
      const li = b.closest('[data-attempt]');
      const v = (k) => $(`[data-cra="${k}"]`, li)?.value ?? '';
      const roll = v('roll').trim();
      b.disabled = true;
      try {
        const res = await resolveAttempt(li.dataset.attempt, a, { outcome: v('outcome'), roll: roll === '' ? null : Number(roll), reply: v('reply').trim(),
          privateNote: v('private').trim(), failureConsumes: v('failure'), revision: Number(li.dataset.rev) });
        toast(res.status === 'applied' ? `Applied: ${OUTCOME[res.outcome] || res.outcome}.` : res.status === 'apply_failed' ? `Not applied: ${res.apply_error}` : 'Rejected.',
          res.status === 'apply_failed' ? 'bad' : 'good', 5000);
      } catch (err) { toast(err.message, 'bad', 5000); }
      reload();
    }
  });
}

function attemptHTML(a) {
  const roll = a.roll_total != null ? `${esc(a.check_label || 'Roll')}: <b>${esc(a.roll_total)}</b>${a.natural ? ` (${a.natural === 'nat20' ? 'natural 20' : 'natural 1'})` : ''}` : 'No roll';
  return `<li class="dm-item-know" data-attempt="${esc(a.attempt_id)}" data-rev="${esc(a.revision)}">
    <p><strong>${esc(a.character_name)}</strong> · ${esc(a.recipe_name)} ${chip(a.status)}${a.recipe_revision !== a.current_revision ? ' <span class="req-chip">recipe changed since</span>' : ''}</p>
    <p class="small">${roll}${a.check_dc ? ` against DC ${esc(a.check_dc)}` : ''} · ${esc(fmt(a.created_at))}</p>
    <ul class="small">${(a.selected || []).map((x) => `<li>${esc(x.quantity)} × ${esc(x.true_name || x.shown_name || 'a removed item')}${x.shown_name && x.true_name && x.shown_name !== x.true_name ? ` <span class="muted">(player sees: ${esc(x.shown_name)})</span>` : ''}${x.known ? '' : ' <span class="req-chip">unidentified</span>'}</li>`).join('')}</ul>
    ${a.player_note ? `<p class="small">Player: ${esc(a.player_note)}</p>` : ''}
    ${a.status === 'apply_failed' ? `<p class="small gov-error">${esc(a.apply_error)}</p>` : ''}
    <div class="inv-form-row">
      <input type="number" data-cra="roll" min="-10" max="60" placeholder="Correct roll" aria-label="Corrected roll" value="${esc(a.dm_roll_total ?? '')}" style="width:7em">
      <select data-cra="outcome" aria-label="Outcome"><option value="">${a.check_dc ? 'By the roll' : 'Success'}</option>${Object.entries(OUTCOME).map(([k, l]) => `<option value="${k}" ${a.outcome === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>
      <select data-cra="failure" aria-label="On a failure"><option value="">On a failure: recipe rule (${esc(FAILURE[a.failure_mode] || a.failure_mode)})</option>${Object.entries(FAILURE).map(([k, l]) => `<option value="${k}">${esc(l)}</option>`).join('')}</select></div>
    <div class="inv-form-row"><input type="text" data-cra="reply" maxlength="500" placeholder="Reply to the player (they see it)" aria-label="Reply to the player">
      <input type="text" data-cra="private" maxlength="500" placeholder="Private note (DM only)" aria-label="Private note" value="${esc(a.dm_private_note || '')}"></div>
    <div class="dm-action-row"><button type="button" class="btn btn-xs btn-gold" data-crd="approve">${a.status === 'apply_failed' ? 'Try again' : 'Approve'}</button>
      <button type="button" class="btn btn-xs" data-crd="reject">Reject</button></div></li>`;
}

// one item field: a search box and a select with the matches (official items and items of this campaign)
const pickHTML = (key, id, name, optional = false) => `<span class="cr-pick" data-pick="${esc(key)}">
  <input type="search" data-pick-q placeholder="Search items" aria-label="Search items" value="">
  <select data-pick-sel aria-label="Item">${optional ? '<option value="">— none —</option>' : ''}${id ? `<option value="${esc(id)}" selected>${esc(name || id)}</option>` : ''}</select></span>`;

function wirePickers(root, campaignId) {
  root.addEventListener('input', debounce(async (e) => {
    const q = e.target.closest('[data-pick-q]');
    if (!q) return;
    const sel = $('[data-pick-sel]', q.parentElement);
    try {
      const items = await searchCraftItems(campaignId, q.value.trim());
      const keep = sel.value;
      const none = sel.querySelector('option[value=""]') ? '<option value="">— none —</option>' : '';
      sel.innerHTML = none + items.map((i) => `<option value="${esc(i.id)}" ${i.id === keep ? 'selected' : ''}>${esc(i.name)}${i.official ? '' : ' (campaign)'}${i.secret ? ' · hidden' : ''}</option>`).join('');
      if (!keep && items.length && !none) sel.value = items[0].id;
    } catch (err) { toast(err.message, 'bad'); }
  }, 300));
}

async function recipeEditor(campaignId, r, reload) {
  let ref = { skills: [], tools: [] };
  try { ref = await getEditorReference(); } catch { /* checks fall back to free text */ }
  const x = r || { visibility: 'known', output_quantity: 1, requires_dm_approval: true, failure_mode: 'keep', output_identified: true, ingredients: [{ quantity: 1, consumed: true }] };
  const checks = [...(ref.skills || []).map((k) => [k.id, k.name]), ...(ref.tools || []).map((k) => [k.id, k.name])];
  const ingRow = (g) => `<fieldset class="cr-ing-row" data-ing>
    <select data-ing-kind aria-label="Ingredient type"><option value="item" ${g.tag ? '' : 'selected'}>Item</option><option value="tag" ${g.tag ? 'selected' : ''}>Any item with tag</option></select>
    <span data-ing-item ${g.tag ? 'hidden' : ''}>${pickHTML('ing', g.item_id, g.item_name)}</span>
    <input type="text" data-ing-tag maxlength="40" placeholder="tag, e.g. silver" value="${esc(g.tag || '')}" ${g.tag ? '' : 'hidden'} aria-label="Tag">
    <input type="number" data-ing-qty min="1" max="99" value="${esc(g.quantity || 1)}" aria-label="Quantity" style="width:5em">
    <label class="check-field"><input type="checkbox" data-ing-consumed ${g.consumed === false ? '' : 'checked'}><span>Used up</span></label>
    <input type="text" data-ing-label maxlength="120" placeholder="Label players see (for a hidden item)" value="${esc(g.label || '')}" aria-label="Player label">
    <button type="button" class="btn btn-xs btn-ghost" data-ing-del aria-label="Remove ingredient">✕</button></fieldset>`;
  const m = openModal({ title: r ? `Recipe: ${r.name}` : 'New recipe', wide: true, body: `
    <p class="muted small">Players see the name, description, result and ingredients (a hidden item shows the label you write). The DC and your notes stay with you.</p>
    <label class="field"><span>Name</span><input data-r="name" maxlength="120" value="${esc(x.name || '')}" required></label>
    <label class="field"><span>Description (players see it)</span><textarea data-r="description" maxlength="2000" rows="2">${esc(x.description || '')}</textarea></label>
    <fieldset class="ce-section"><legend>Result</legend><div class="ce-grid">
      <label class="field"><span>Makes</span>${pickHTML('output', x.output_item_id, x.output_name)}</label>
      <label class="field"><span>Quantity</span><input type="number" data-r="output_quantity" min="1" max="99" value="${esc(x.output_quantity || 1)}"></label>
      <label class="field"><span>Shown to players who do not know the item yet</span><input data-r="output_label" maxlength="120" value="${esc(x.output_label || '')}" placeholder="e.g. a shimmering draught"></label>
      <label class="check-field"><input type="checkbox" data-r="output_identified" ${x.output_identified === false ? '' : 'checked'}><span>The crafter knows what they made (otherwise it arrives unidentified)</span></label>
      <label class="field"><span>Critical success: another result (optional)</span>${pickHTML('crit', x.crit_output_item_id, x.crit_output_name, true)}</label>
      <label class="field"><span>Critical success: extra quantity</span><input type="number" data-r="crit_bonus_quantity" min="0" max="99" value="${esc(x.crit_bonus_quantity || 0)}"></label>
    </div></fieldset>
    <fieldset class="ce-section"><legend>Ingredients</legend><div data-ings>${(x.ingredients || []).map(ingRow).join('')}</div>
      <button type="button" class="btn btn-xs" data-ing-add>+ Ingredient</button></fieldset>
    <fieldset class="ce-section"><legend>Check and approval</legend><div class="ce-grid">
      <label class="field"><span>Roll (skill or tool)</span><select data-r="check_key"><option value="">No roll</option>${checks.map(([k, l]) => `<option value="${esc(k)}" ${x.check_key === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}
        ${x.check_key && !checks.some(([k]) => k === x.check_key) ? `<option value="${esc(x.check_key)}" selected>${esc(x.check_key)}</option>` : ''}</select></label>
      <label class="field"><span>DC (DM only; empty: none)</span><input type="number" data-r="check_dc" min="1" max="40" value="${esc(x.check_dc ?? '')}"></label>
      <label class="check-field"><input type="checkbox" data-r="requires_dm_approval" ${x.requires_dm_approval === false ? '' : 'checked'}><span>I confirm every attempt (always with a DC)</span></label>
      <label class="field"><span>On a failure</span><select data-r="failure_mode">${Object.entries(FAILURE).map(([k, l]) => `<option value="${k}" ${x.failure_mode === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
      <label class="field"><span>Failure gives (optional junk item)</span>${pickHTML('failure', x.failure_output_item_id, x.failure_output_name, true)}</label>
      <label class="field"><span>Time (a note)</span><input data-r="time_note" maxlength="200" value="${esc(x.time_note || '')}" placeholder="e.g. one hour"></label>
    </div></fieldset>
    <label class="field"><span>Who knows it</span><select data-r="visibility">${Object.entries(VIS).map(([k, l]) => `<option value="${k}" ${x.visibility === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
    <label class="field"><span>Your notes (DM only)</span><textarea data-r="dm_notes" maxlength="2000" rows="2">${esc(x.dm_notes || '')}</textarea></label>`,
  footer: `<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn" data-r-save>Save draft${r ? ' / changes' : ''}</button>
    ${!r || r.status === 'draft' ? '<button type="button" class="btn btn-gold" data-r-save data-publish>Save and publish</button>' : ''}` });
  wirePickers(m.el, campaignId);
  m.el.addEventListener('change', (e) => {
    const k = e.target.closest('[data-ing-kind]');
    if (k) { const row = k.closest('[data-ing]'); $('[data-ing-item]', row).hidden = k.value !== 'item'; $('[data-ing-tag]', row).hidden = k.value !== 'tag'; }
  });
  m.el.addEventListener('click', async (e) => {
    if (e.target.closest('[data-ing-add]')) { $('[data-ings]', m.el).insertAdjacentHTML('beforeend', ingRow({ quantity: 1, consumed: true })); return; }
    if (e.target.closest('[data-ing-del]')) { e.target.closest('[data-ing]').remove(); return; }
    const save = e.target.closest('[data-r-save]');
    if (!save) return;
    const v = (k) => $(`[data-r="${k}"]`, m.el);
    const pick = (k) => $(`[data-pick="${k}"] [data-pick-sel]`, m.el)?.value || null;
    const num = (el) => (el.value === '' ? null : Number(el.value));
    const recipe = { id: r?.id || null, name: v('name').value.trim(), description: v('description').value, dm_notes: v('dm_notes').value,
      visibility: v('visibility').value, output_item_id: pick('output'), output_quantity: num(v('output_quantity')) || 1, output_label: v('output_label').value,
      output_identified: v('output_identified').checked, crit_output_item_id: pick('crit'), crit_bonus_quantity: num(v('crit_bonus_quantity')) || 0,
      failure_mode: v('failure_mode').value, failure_output_item_id: pick('failure'), check_key: v('check_key').value || null, check_dc: num(v('check_dc')),
      requires_dm_approval: v('requires_dm_approval').checked || num(v('check_dc')) != null, time_note: v('time_note').value,
      ingredients: $$('[data-ing]', m.el).map((row) => {
        const kind = $('[data-ing-kind]', row).value;
        return { item_id: kind === 'item' ? ($('[data-pick-sel]', row).value || null) : null, tag: kind === 'tag' ? $('[data-ing-tag]', row).value.trim() : null,
          quantity: num($('[data-ing-qty]', row)) || 1, consumed: $('[data-ing-consumed]', row).checked, label: $('[data-ing-label]', row).value };
      }) };
    save.disabled = true;
    try {
      const saved = await saveRecipe(campaignId, recipe, r?.revision ?? null);
      if (save.dataset.publish != null && saved.status === 'draft') await setRecipeStatus(saved.id, 'published');
      toast(save.dataset.publish != null ? 'Recipe published.' : 'Recipe saved.', 'good');
      m.close();
      reload();
    } catch (err) { toast(err.message, 'bad', 6000); save.disabled = false; }
  });
}

function grantDialog(r, characters, reload) {
  if (!r) return;
  const known = new Set(r.known_by.map((k) => k.character_id));
  const m = openModal({ title: `Who knows “${r.name}”`, body: `
    <p class="small muted">A character you tick learns the recipe (they see “New recipe learned”${r.status === 'published' ? '' : ' once it is published'}).</p>
    ${characters.map((c) => `<label class="check-field"><input type="checkbox" data-gr value="${esc(c.id)}" ${known.has(c.id) ? 'checked' : ''}><span>${esc(c.name)}</span></label>`).join('') || '<p class="muted">No characters in this campaign.</p>'}`,
  footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-gr-save>Save</button>' });
  $('[data-gr-save]', m.el).addEventListener('click', async () => {
    const want = new Set($$('[data-gr]:checked', m.el).map((x) => x.value));
    const add = [...want].filter((id) => !known.has(id));
    const del = [...known].filter((id) => !want.has(id));
    try {
      if (add.length) await grantRecipe(r.id, add, true);
      if (del.length) await grantRecipe(r.id, del, false);
      toast('Saved.', 'good'); m.close(); reload();
    } catch (err) { toast(err.message, 'bad'); }
  });
}
