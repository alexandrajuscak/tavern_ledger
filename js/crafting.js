// Crafting v2 (docs/CRAFTING_V1.md). Loaded ONLY through a dynamic import() when js/config.js CRAFTING is not 'off' (dm-space.js,
// inventory-ui.js): with the shipped 'off' this file is never requested. The database authorizes everything itself: the DM
// RPCs need the campaign DM role, the player RPCs the character's owner and the campaign rule inventory.craft (off by default).
// The server never rolls: the player types the total of a physical roll, the DM confirms or corrects it.

import { supabase } from './supabase.js?v=37';
import { $, $$, esc, toast, openModal, confirmDialog, debounce, friendlyError } from './utils.js?v=37';
import { getEditorReference } from './dm-api.js?v=37';
import { icon } from './icons.js?v=37';
import { sectionHead } from './section.js?v=37';

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
export const learnRecipe = (inventoryItemId) => rpc('learn_recipe_from_item', { p_inventory_item: inventoryItemId });
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
// Player: Inventory → Crafting (a sub-tab of the inventory; v2)
// =================================================================================================================================
const toolHTML = (t) => (t ? `<span class="${t.have ? 'cr-have' : 'cr-miss'}" data-craft-tool="${t.have ? 'have' : 'missing'}">${icon('item.tools', { size: 16 })} ${esc(t.name)}: ${t.have ? 'you have it' : 'missing'}</span>` : '');

/**
 * The player's Crafting tab. attach(slot) renders into the tab's slot (re-created on every inventory render); the recipes are read
 * only while the tab is shown: invalidate() re-reads (debounced) when shown, else marks the data stale for the next attach.
 */
export function createPlayerCrafting({ characterId, onInventoryChanged }) {
  const s = { data: null, error: null, loading: false, slot: null, destroyed: false, stale: false };
  const shown = () => !!s.slot?.isConnected;
  let refreshSoon = () => {};

  async function refresh() {
    if (s.destroyed) return;
    if (s.loading) { s.stale = true; return; }
    s.loading = true; s.stale = false;
    try { s.data = await getCharacterRecipes(characterId); s.error = null; } catch (err) { s.error = err; }
    finally { s.loading = false; }
    if (s.stale && shown()) refreshSoon();
    paint();
  }
  refreshSoon = debounce(() => { if (shown()) refresh(); else s.stale = true; }, 600);

  const shell = (inner, count) => `<section class="tl-section inv-crafting" data-crafting aria-labelledby="inv-craft-title">
      ${sectionHead({ id: 'inv-craft-title', icon: 'potion.flask', title: 'Crafting', count })}${inner}</section>`;

  function html() {
    if (s.error) return shell(`<p class="small muted">${esc(s.error.message)}</p>`);
    if (!s.data) return shell('<p class="small muted">Loading recipes…</p>');
    const d = s.data;
    const recipes = d.recipes || [];
    const fresh = recipes.filter((r) => r.new);
    const recent = (d.attempts || []).slice(0, 5);
    const tools = d.tools || [];
    const manuals = d.manuals || [];
    return shell(`
      <div class="cr-tools" data-craft-tools><h3 class="small">Tools you carry</h3>
        ${tools.length ? `<ul class="cr-chips">${tools.map((t) => `<li class="req-chip">${icon('item.tools', { size: 16 })} ${esc(t.name)}${t.quantity > 1 ? ` ×${esc(t.quantity)}` : ''}</li>`).join('')}</ul>`
          : '<p class="small muted">No tools. Recipes that need a tool (for example an herbalism kit) cannot be crafted yet.</p>'}</div>
      ${manuals.length ? `<div class="cr-manuals" data-craft-manuals><h3 class="small">Recipe books and scrolls</h3><ul class="inv-side-list">${manuals.map((m) => `<li class="inv-side-row" data-craft-manual="${esc(m.inventory_item_id)}">
          <span class="inv-side-name">${esc(m.name)} <span class="small muted">· ${m.unlearned ? `${esc(m.unlearned)} recipe${m.unlearned === 1 ? '' : 's'} to learn${m.consumed_on_learn ? ' (used up when read)' : ''}` : 'you know everything in it'}</span></span>
          ${m.unlearned ? `<span class="inv-side-actions"><button type="button" class="btn btn-sm btn-gold" data-cr="learn" data-id="${esc(m.inventory_item_id)}" data-consume="${m.consumed_on_learn ? 1 : 0}">Learn recipe</button></span>` : ''}</li>`).join('')}</ul></div>` : ''}
      ${fresh.length ? `<div class="cr-new" role="status" data-craft-new>${icon('dm/approved', { size: 18 })}<span>New recipe learned: <strong>${esc(fresh.map((r) => r.name).join(', '))}</strong></span>
        <button type="button" class="btn btn-sm btn-ghost" data-cr="seen">Got it</button></div>` : ''}
      ${recipes.length ? `<ul class="cr-recipes">${recipes.map(recipeHTML).join('')}</ul>` : '<p class="empty">No recipes yet. Your DM shares them with you, or you learn them from a recipe book.</p>'}
      ${d.undiscovered ? `<p class="small muted" data-craft-undiscovered>${esc(d.undiscovered)} recipe${d.undiscovered === 1 ? '' : 's'} still to discover.</p>` : ''}
      ${recent.length ? `<details class="cr-recent"><summary class="small">Recent attempts</summary><ul class="inv-side-list">${recent.map((a) => `<li class="inv-side-row" data-craft-attempt="${esc(a.attempt_id)}">
        <span class="inv-side-name">${esc(a.recipe_name)} ${chip(a.status)}${a.outcome ? ` <span class="small muted">${esc(OUTCOME[a.outcome] || a.outcome)}</span>` : ''}
        ${a.produced?.length ? `<br><span class="small">Made: ${list(a.produced)}</span>` : ''}${a.consumed?.length ? `<br><span class="small muted">Used: ${list(a.consumed)}</span>` : ''}
        ${a.dm_reply ? `<br><span class="small">DM: ${esc(a.dm_reply)}</span>` : ''}</span>
        ${a.status === 'pending' ? `<span class="inv-side-actions"><button type="button" class="btn btn-sm btn-ghost" data-cr="cancel" data-id="${esc(a.attempt_id)}">Cancel</button></span>` : ''}</li>`).join('')}</ul></details>` : ''}`,
    recipes.length);
  }

  function recipeHTML(r) {
    const out = r.output || {};
    const missingIng = (r.ingredients || []).some((g) => g.have < g.quantity);
    const why = missingIng ? 'Missing ingredients' : r.tool && !r.tool.have ? `Needs ${r.tool.name}` : '';
    return `<li class="cr-recipe" data-recipe="${esc(r.recipe_id)}">
      <p><strong>${esc(r.name)}</strong>${r.new ? ' <span class="req-chip">new</span>' : ''} <span class="small muted">→ ${esc(out.quantity)} × ${esc(out.name)}</span></p>
      ${r.description ? `<p class="small">${esc(r.description)}</p>` : ''}
      <ul class="small cr-ings">${(r.ingredients || []).map((g) => `<li class="${g.have >= g.quantity ? 'cr-have' : 'cr-miss'}" data-craft-ing="${esc(g.seq)}">${esc(g.label)}${g.consumed ? '' : ' <span class="muted">(kept)</span>'}
        <span class="cr-count">${esc(Math.min(g.have, g.quantity))} / ${esc(g.quantity)}</span>${g.have > g.quantity ? ` <span class="muted">(you have ${esc(g.have)})</span>` : ''}</li>`).join('')}</ul>
      <p class="small">${r.check ? `Roll: <b>${esc(r.check.label)}</b>${r.check.dc != null ? ` · <b data-craft-dc>DC ${esc(r.check.dc)}</b>` : ''}. ` : ''}${toolHTML(r.tool)}</p>
      <p class="small muted">${r.dm_confirms ? 'Your DM confirms the result.' : 'Done at once.'}${r.time_note ? ` ${esc(r.time_note)}` : ''}</p>
      ${r.pending_attempt_id ? `<p class="small">${chip('pending')}</p>` : `<button type="button" class="btn btn-sm btn-good" data-cr="craft" data-id="${esc(r.recipe_id)}" ${r.can_craft ? '' : 'disabled'}>${r.can_craft ? 'Craft…' : esc(why || 'Cannot craft yet')}</button>`}
    </li>`;
  }

  function paint() {
    if (!shown()) return;
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
    if (a === 'learn') {
      if (b.dataset.consume === '1' && !(await confirmDialog('Reading it uses it up. Learn the recipe?', { okLabel: 'Learn recipe' }))) return;
      b.disabled = true;
      try { const res = await learnRecipe(b.dataset.id); toast(learnedText(res), 'good', 5000); onInventoryChanged?.(); }
      catch (err) { toast(err.message, 'bad', 5000); }
      refresh(); return;
    }
    if (a === 'craft') craftDialog((s.data?.recipes || []).find((r) => r.recipe_id === b.dataset.id));
  }

  function craftDialog(r) {
    if (!r || !r.can_craft) return;
    const requestId = crypto.randomUUID();   // kept for retries of the same dialog: a repeated click is applied once
    const m = openModal({ title: `Craft: ${r.name}`, body: `
      <p class="small">${esc(r.output.quantity)} × ${esc(r.output.name)}. ${r.dm_confirms ? 'Your DM confirms the result.' : 'Done at once.'}</p>
      ${(r.ingredients || []).map((g) => `<label class="field"><span>${esc(g.quantity)} × ${esc(g.label)}${g.consumed ? '' : ' (kept)'}</span>
        <select data-cr-ing="${esc(g.seq)}" data-need="${esc(g.quantity)}">${(g.candidates || []).filter((c) => c.quantity >= g.quantity)
          .map((c) => `<option value="${esc(c.inventory_item_id)}">${esc(c.name)} (×${esc(c.quantity)})</option>`).join('') || '<option value="">No single stack has enough: combine your stacks first</option>'}</select></label>`).join('')}
      ${r.check ? `<p class="small">Roll a d20 for <b>${esc(r.check.label)}</b> at the table${r.check.dc != null ? ` (<b data-craft-dc>DC ${esc(r.check.dc)}</b>)` : ''} and type the total.</p>
        <label class="field"><span>Total of your ${esc(r.check.label)} roll</span><input type="number" data-cr-roll min="-10" max="60" inputmode="numeric" required></label>
        <label class="field"><span>Natural roll</span><select data-cr-nat><option value="">—</option><option value="nat20">Natural 20</option><option value="nat1">Natural 1</option></select></label>` : ''}
      <label class="field"><span>Note for your DM (optional)</span><input type="text" data-cr-note maxlength="500"></label>`,
    footer: `<button type="button" class="btn" data-close>Close</button><button type="button" class="btn btn-gold" data-cr-go>${r.dm_confirms ? 'Send to my DM' : 'Craft'}</button>` });
    $('[data-cr-go]', m.el).addEventListener('click', async (ev) => {
      const sel = $$('[data-cr-ing]', m.el).map((x) => ({ seq: Number(x.dataset.crIng), inventory_item_id: x.value, quantity: Number(x.dataset.need) }));
      if (sel.some((x) => !x.inventory_item_id)) { toast('Choose a stack for every ingredient.', 'bad'); return; }
      const rollEl = $('[data-cr-roll]', m.el);
      const roll = rollEl ? (rollEl.value === '' ? null : Number(rollEl.value)) : null;
      if (rollEl && (roll == null || !Number.isInteger(roll) || roll < -10 || roll > 60)) { toast('Enter the total of your roll (-10 to 60).', 'bad'); return; }
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
    /** Render into the Crafting tab's slot of the current inventory render (and read on first use or when stale). */
    attach(slot) {
      if (!slot) return;
      s.slot = slot;
      slot.addEventListener('click', onClick);
      paint();
      if ((!s.data && !s.error) || s.stale) refresh();
    },
    /** The tab is not shown (its slot is gone with the render). */
    hide() { s.slot = null; },
    /** The inventory or a crafting answer changed: re-read if shown (debounced), else on the next attach. */
    invalidate() { if (shown()) refreshSoon(); else s.stale = true; },
    refresh: () => refreshSoon(),
    destroy() { s.destroyed = true; s.slot = null; },
  };
}

const learnedText = (res) => (res?.learned?.length ? `New recipe learned: ${res.learned.map((x) => x.name).join(', ')}${res.consumed ? ' (the item was used up)' : ''}`
  : res?.message || 'Nothing new to learn.');

/** "Learn recipe" inside an item's detail (only for a known row; the server answers with counts only). */
export async function learnSection(slot, inventoryItemId, { onLearned } = {}) {
  let info;
  try { info = await rpc('get_inventory_item_recipes', { p_inventory_item: inventoryItemId }); } catch { return; }
  if (!slot.isConnected || !info?.recipes) return;
  slot.innerHTML = `<section class="inv-form cr-learn" data-craft-learn><h4>Recipe</h4>
    <p class="small">${info.unlearned ? `Reading it teaches you ${esc(info.unlearned)} crafting recipe${info.unlearned === 1 ? '' : 's'}${info.consumed_on_learn ? '; it is used up when read' : ''}.` : 'You already know every recipe in it.'}</p>
    ${info.unlearned ? '<button type="button" class="btn btn-sm btn-gold" data-learn-go>Learn recipe</button>' : ''}</section>`;
  $('[data-learn-go]', slot)?.addEventListener('click', async (e) => {
    e.target.disabled = true;
    try { const res = await learnRecipe(inventoryItemId); toast(learnedText(res), 'good', 5000); onLearned?.(); }
    catch (err) { toast(err.message, 'bad', 5000); e.target.disabled = false; }
  });
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

  // the suggestion follows a corrected roll until the DM picks an outcome himself
  panel.addEventListener('change', (e) => { if (e.target.matches('[data-cra="outcome"]')) e.target.dataset.touched = '1'; });
  panel.addEventListener('input', (e) => {
    const inp = e.target.closest('[data-cra="roll"]');
    if (!inp) return;
    const li = inp.closest('[data-attempt]');
    const raw = inp.value.trim() === '' ? li.dataset.playerRoll : inp.value.trim();
    const sug = suggestOutcome(raw === '' ? null : Number(raw), li.dataset.natural || null, li.dataset.dc === '' ? null : Number(li.dataset.dc));
    const lab = $('[data-sug-label]', li);
    if (lab) lab.textContent = OUTCOME[sug] || 'choose the outcome';
    const sel = $('[data-cra="outcome"]', li);
    if (sel && sel.dataset.touched !== '1') {
      sel.value = sug;
      [...sel.options].forEach((o) => { if (o.value) o.textContent = OUTCOME[o.value] + (o.value === sug ? ' (suggested)' : ''); });
    }
  });
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

// the outcome offered to the DM (as the server's _craft_suggest): nat20 / nat1 first, else the roll against the DC
function suggestOutcome(roll, natural, dc) {
  if (natural === 'nat20') return 'critical_success';
  if (natural === 'nat1') return 'critical_failure';
  if (dc == null) return 'success';
  if (roll == null || Number.isNaN(roll)) return '';
  return roll >= dc ? 'success' : 'failure';
}

function attemptHTML(a) {
  const roll = a.roll_total != null ? `${esc(a.check_label || 'Roll')}: <b>${esc(a.roll_total)}</b>${a.natural ? ` (${a.natural === 'nat20' ? 'natural 20' : 'natural 1'})` : ''}` : 'No roll';
  const sug = a.status === 'apply_failed' && a.outcome ? a.outcome : (a.suggested_outcome ?? suggestOutcome(a.dm_roll_total ?? a.roll_total, a.natural, a.check_dc));
  return `<li class="dm-item-know" data-attempt="${esc(a.attempt_id)}" data-rev="${esc(a.revision)}" data-dc="${esc(a.check_dc ?? '')}" data-natural="${esc(a.natural || '')}" data-player-roll="${esc(a.roll_total ?? '')}">
    <p><strong>${esc(a.character_name)}</strong> · ${esc(a.recipe_name)} ${chip(a.status)}${a.recipe_revision !== a.current_revision ? ' <span class="req-chip">recipe changed since</span>' : ''}</p>
    <p class="small">${roll}${a.check_dc ? ` against DC ${esc(a.check_dc)}` : ''} · ${esc(fmt(a.created_at))}</p>
    <p class="small" data-craft-suggest>Suggested: <b data-sug-label>${esc(OUTCOME[sug] || 'choose the outcome')}</b>${a.tool_ok === false ? ' · <span class="req-chip cr-st-warn">the tool is missing now</span>' : ''}</p>
    <ul class="small">${(a.selected || []).map((x) => `<li>${esc(x.quantity)} × ${esc(x.true_name || x.shown_name || 'a removed item')}${x.shown_name && x.true_name && x.shown_name !== x.true_name ? ` <span class="muted">(player sees: ${esc(x.shown_name)})</span>` : ''}${x.known ? '' : ' <span class="req-chip">unidentified</span>'}</li>`).join('')}</ul>
    ${a.player_note ? `<p class="small">Player: ${esc(a.player_note)}</p>` : ''}
    ${a.status === 'apply_failed' ? `<p class="small gov-error">${esc(a.apply_error)}</p>` : ''}
    <div class="inv-form-row">
      <input type="number" data-cra="roll" min="-10" max="60" placeholder="Correct roll" aria-label="Corrected roll" value="${esc(a.dm_roll_total ?? '')}" style="width:7em">
      <select data-cra="outcome" aria-label="Outcome" data-touched="0"><option value="">${a.check_dc ? 'By the roll (no natural 20 / 1)' : 'Success'}</option>${Object.entries(OUTCOME).map(([k, l]) => `<option value="${k}" ${sug === k ? 'selected' : ''}>${esc(l)}${k === sug ? ' (suggested)' : ''}</option>`).join('')}</select>
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
  const teachRow = (t) => `<fieldset class="cr-ing-row" data-teach>
    <span>${pickHTML('teach', t.item_id, t.item_name)}</span>
    <select data-teach-consumed aria-label="When read"><option value="" ${t.item_id ? '' : 'selected'}>Default (a scroll is used up, a book is kept)</option>
      <option value="true" ${t.item_id && t.consume_on_learn ? 'selected' : ''}>Used up when read</option><option value="false" ${t.item_id && t.consume_on_learn === false ? 'selected' : ''}>Kept when read</option></select>
    <button type="button" class="btn btn-xs btn-ghost" data-teach-del aria-label="Remove recipe item">✕</button></fieldset>`;
  const m = openModal({ title: r ? `Recipe: ${r.name}` : 'New recipe', wide: true, body: `
    <p class="muted small">Players see the name, description, result, ingredients (a hidden item shows the label you write), the roll and its DC. Your notes stay with you.</p>
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
    <fieldset class="ce-section" data-teachers><legend>Recipe items (books, scrolls)</legend>
      <p class="small muted">A character who reads one of these items (Inventory → Crafting, or the item's details) learns this recipe for good, also a
        secret one. You can still grant it yourself ("Who knows it…").</p>
      <div data-teach-rows>${(x.teachers || []).map(teachRow).join('')}</div>
      <button type="button" class="btn btn-xs" data-teach-add>+ Recipe item</button></fieldset>
    <fieldset class="ce-section"><legend>Check and approval</legend><div class="ce-grid">
      <label class="field"><span>Roll (skill or tool)</span><select data-r="check_key"><option value="">No roll</option>${checks.map(([k, l]) => `<option value="${esc(k)}" ${x.check_key === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}
        ${x.check_key && !checks.some(([k]) => k === x.check_key) ? `<option value="${esc(x.check_key)}" selected>${esc(x.check_key)}</option>` : ''}</select></label>
      <label class="field"><span>DC (players see it; empty: none). A tool check also needs the tool in the inventory.</span><input type="number" data-r="check_dc" min="1" max="40" value="${esc(x.check_dc ?? '')}"></label>
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
    if (e.target.closest('[data-teach-add]')) { $('[data-teach-rows]', m.el).insertAdjacentHTML('beforeend', teachRow({})); return; }
    if (e.target.closest('[data-teach-del]')) { e.target.closest('[data-teach]').remove(); return; }
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
      }),
      teachers: $$('[data-teach]', m.el).map((row) => ({ item_id: $('[data-pick-sel]', row).value || null,
        consumed: { true: true, false: false }[$('[data-teach-consumed]', row).value] ?? null })).filter((t) => t.item_id) };
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
