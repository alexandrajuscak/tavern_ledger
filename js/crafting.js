// Crafting v2 (docs/CRAFTING_V1.md). Loaded ONLY through a dynamic import() when js/config.js CRAFTING is not 'off' (dm-space.js,
// inventory-ui.js): with the shipped 'off' this file is never requested. The database authorizes everything itself: the DM
// RPCs need the campaign DM role, the player RPCs the character's owner and the campaign rule inventory.craft (off by default).
// The server never rolls: the player types the total of a physical roll, the DM confirms or corrects it.

import { supabase } from './supabase.js?v=42';
import { $, $$, esc, toast, openModal, confirmDialog, debounce, friendlyError } from './utils.js?v=42';
import { getEditorReference } from './dm-api.js?v=42';
import { icon } from './icons.js?v=42';
import { sectionHead } from './section.js?v=42';

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
// the simple flow (?v=42): N batches in one attempt (all or nothing), the stacks picked by pickStacks
export const startCraftBatch = (characterId, recipeId, selected, batches, roll, requestId, natural) =>
  rpc('start_craft_batch', { p_character: characterId, p_recipe: recipeId, p_selected: selected, p_batches: batches, p_roll_total: roll ?? null,
    p_request_id: requestId, p_natural: natural || null, p_note: null });
export const cancelCraft = (attemptId) => rpc('cancel_craft_attempt', { p_attempt: attemptId });
export const markRecipesSeen = (characterId) => rpc('mark_recipes_seen', { p_character: characterId });
export const learnRecipe = (inventoryItemId) => rpc('learn_recipe_from_item', { p_inventory_item: inventoryItemId });
export const getCampaignRecipes = (campaignId) => rpc('get_campaign_recipes', { p_campaign: campaignId });
export const getCraftAttempts = (campaignId, status = 'open') => rpc('get_campaign_craft_attempts', { p_campaign: campaignId, p_status: status });
export const pendingCraftCount = (campaignId) => rpc('get_campaign_pending_craft_count', { p_campaign: campaignId });
export const searchCraftItems = (campaignId, q) => rpc('get_campaign_craft_items', { p_campaign: campaignId, p_query: q || null });
export const saveModifier = (campaignId, modifier) => rpc('dm_save_campaign_modifier', { p_campaign: campaignId, p_modifier: modifier });
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
// an enhancement's effects as text ("Attack +1, Damage +2, Sheds light")
const FX = { attack_bonus: 'Attack', damage_bonus: 'Damage', ac_bonus: 'Armor Class', save_bonus: 'Saving throws' };
const sign = (v) => (Number(v) >= 0 ? `+${Number(v)}` : `${Number(v)}`);
const fxText = (fx) => (fx || []).map((e) => (e.type === 'custom' ? e.text : `${FX[e.type] || e.type} ${sign(e.value)}`)).filter(Boolean).join(', ');
const outText = (out) => (out?.enhancement ? `enhances the base item: ${out.name}${out.effects?.length ? ` (${fxText(out.effects)})` : ''}`
  : `${out?.quantity} × ${out?.name}`);

// =================================================================================================================================
// Player: Inventory → Crafting (a sub-tab of the inventory; v2)
// =================================================================================================================================
// Simple crafting (?v=42, docs/CRAFTING_V1.md "Simple crafting"): 1. a tool the character carries, 2. a recipe of that tool with
// have / missing, 3. how many, 4. Craft. The stacks are picked automatically (pickStacks); one click sends one request
// (start_craft_batch: N batches, all or nothing, one request id).
const NO_TOOL = '__none';
const toolKey = (r) => (r.tool ? r.tool.item_id : NO_TOOL);
const MAX_BATCHES = 20;

/**
 * The stacks for N batches of a recipe, picked from the read's candidates (known rows; for a used-up line only rows that may be
 * used up: never equipped, attuned, quest, charged or a container with contents). Disjoint across lines (the server refuses a
 * stack used for two ingredients). Order: the base of an enhancement first (the chosen row), then used-up lines, then kept lines
 * (tools); within a line the SMALLEST stack first (ties by row id), so partial stacks are used up before full ones.
 * Returns null when N batches cannot be covered.
 */
export function pickStacks(r, n, baseRow = null) {
  const used = new Set();
  const sel = [];
  const rank = (g) => (g.base ? 0 : g.consumed ? 1 : 2);
  const ings = [...(r?.ingredients || [])].sort((a, b) => (rank(a) - rank(b)) || (a.seq - b.seq));
  for (const g of ings) {
    const need = g.base ? 1 : Number(g.quantity) * (g.consumed ? n : 1);
    const cands = (g.candidates || []).filter((c) => !used.has(c.inventory_item_id) && (!g.base || !baseRow || c.inventory_item_id === baseRow))
      .sort((a, b) => (a.quantity - b.quantity) || String(a.inventory_item_id).localeCompare(String(b.inventory_item_id)));
    let got = 0;
    for (const c of cands) {
      if (got >= need) break;
      const take = Math.min(Number(c.quantity), need - got);
      if (take < 1) continue;
      sel.push({ seq: g.seq, inventory_item_id: c.inventory_item_id, quantity: take });
      used.add(c.inventory_item_id);
      got += take;
    }
    if (got < need) return null;
  }
  return sel.length && sel.length <= 40 ? sel : null;
}

/** How many times the character can craft the recipe now (0..20). */
export function maxBatches(r, baseRow = null) {
  if (!r?.can_craft) return 0;
  const cap = r.kind === 'enhancement' ? 1 : MAX_BATCHES;
  let n = 0;
  while (n < cap && pickStacks(r, n + 1, baseRow)) n += 1;
  return n;
}

/**
 * The player's Crafting tab. attach(slot) renders into the tab's slot (re-created on every inventory render); the recipes are read
 * only while the tab is shown: invalidate() re-reads (debounced) when shown, else marks the data stale for the next attach.
 * canCraft(): the viewer is the character's player and the campaign rule allows it (else the tab is read-only: the DM sees what the
 * character has and misses, and a link to the recipes). isDm(): the viewer is the campaign's DM.
 */
export function createPlayerCrafting({ characterId, onInventoryChanged, canCraft = () => true, isDm = () => false }) {
  const s = { data: null, error: null, loading: false, slot: null, destroyed: false, stale: false,
    tool: null, recipe: null, qty: 1, roll: '', natural: '', base: '', busy: false, req: null };
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

  // step 1: the tools the character carries that have recipes (+ "No tool needed"); a tool the character lacks is not a choice
  function groups(recipes) {
    const g = new Map();
    const lacking = new Map();
    for (const r of recipes) {
      if (r.tool && !r.tool.have) { lacking.set(r.tool.item_id, r.tool.name); continue; }
      const k = toolKey(r);
      if (!g.has(k)) g.set(k, { key: k, name: r.tool ? r.tool.name : 'No tool needed', recipes: [] });
      g.get(k).recipes.push(r);
    }
    const list = [...g.values()].sort((a, b) => (a.key === NO_TOOL) - (b.key === NO_TOOL) || a.name.localeCompare(b.name));
    return { list, lacking: [...lacking.values()].sort() };
  }

  function html() {
    if (s.error) return shell(`<p class="small muted">${esc(s.error.message)}</p>`);
    if (!s.data) return shell('<p class="small muted">Loading recipes…</p>');
    const d = s.data;
    const acts = canCraft();
    const recipes = d.recipes || [];
    const fresh = recipes.filter((r) => r.new);
    const recent = (d.attempts || []).slice(0, 5);
    const manuals = d.manuals || [];
    const { list: glist, lacking } = groups(recipes);
    if (!glist.some((x) => x.key === s.tool)) { s.tool = glist[0]?.key ?? null; s.recipe = null; }
    const cur = glist.find((x) => x.key === s.tool);
    if (s.recipe && !cur?.recipes.some((r) => r.recipe_id === s.recipe)) s.recipe = null;
    return shell(`
      ${!acts ? `<p class="small muted crs-dmview" data-craft-dmview>${isDm() ? 'You are the DM: this is what this character can craft, with what it has and misses. Only the character\'s player crafts.' : 'Only the character\'s player crafts.'}
        ${isDm() ? ' <a href="#/dm/crafting" data-craft-editor>Edit recipes in DM Space</a>' : ''}</p>`
        : isDm() ? '<p class="small"><a href="#/dm/crafting" data-craft-editor>Edit recipes in DM Space</a></p>' : ''}
      ${fresh.length ? `<div class="cr-new" role="status" data-craft-new>${icon('dm/approved', { size: 18 })}<span>New recipe learned: <strong>${esc(fresh.map((r) => r.name).join(', '))}</strong></span>
        ${acts ? '<button type="button" class="btn btn-sm btn-ghost" data-cr="seen">Got it</button>' : ''}</div>` : ''}
      ${glist.length ? `<div class="crs-step" data-craft-step="tool"><h3 class="small">1. Choose a tool</h3>
        <div class="crs-tools" role="group" aria-label="Tools">${glist.map((x) => `<button type="button" class="inv-chip" data-cr="tool" data-key="${esc(x.key)}" aria-pressed="${x.key === s.tool}" data-craft-tool-choice="${esc(x.key)}">
          ${icon(x.key === NO_TOOL ? 'potion.flask' : 'item.tools', { size: 16 })}${esc(x.name)} <span class="small muted">(${x.recipes.length})</span></button>`).join('')}</div></div>
        <div class="crs-step" data-craft-step="recipe"><h3 class="small">2. Choose a recipe</h3>
        <ul class="cr-recipes">${(cur?.recipes || []).map((r) => recipeHTML(r, acts)).join('')}</ul></div>`
        : `<p class="empty">${recipes.length ? 'You carry none of the tools these recipes need.' : 'No recipes yet. Your DM shares them with you, or you learn them from a recipe book.'}</p>`}
      ${lacking.length ? `<p class="small muted" data-craft-lacking>Recipes for tools you do not carry: ${esc(lacking.join(', '))}.</p>` : ''}
      ${d.undiscovered ? `<p class="small muted" data-craft-undiscovered>${esc(d.undiscovered)} recipe${d.undiscovered === 1 ? '' : 's'} still to discover.</p>` : ''}
      ${manuals.length ? `<details class="cr-manuals" data-craft-manuals ${manuals.some((m) => m.unlearned) ? 'open' : ''}><summary class="small">Recipe books and scrolls</summary><ul class="inv-side-list">${manuals.map((m) => `<li class="inv-side-row" data-craft-manual="${esc(m.inventory_item_id)}">
          <span class="inv-side-name">${esc(m.name)} <span class="small muted">· ${m.unlearned ? `${esc(m.unlearned)} recipe${m.unlearned === 1 ? '' : 's'} to learn${m.consumed_on_learn ? ' (used up when read)' : ''}` : 'you know everything in it'}</span></span>
          ${m.unlearned && acts ? `<span class="inv-side-actions"><button type="button" class="btn btn-sm btn-gold" data-cr="learn" data-id="${esc(m.inventory_item_id)}" data-consume="${m.consumed_on_learn ? 1 : 0}">Learn recipe</button></span>` : ''}</li>`).join('')}</ul></details>` : ''}
      ${recent.length ? `<details class="cr-recent"><summary class="small">Recent attempts</summary><ul class="inv-side-list">${recent.map((a) => `<li class="inv-side-row" data-craft-attempt="${esc(a.attempt_id)}">
        <span class="inv-side-name">${esc(a.recipe_name)} ${chip(a.status)}${a.outcome ? ` <span class="small muted">${esc(OUTCOME[a.outcome] || a.outcome)}</span>` : ''}
        ${a.produced?.length ? `<br><span class="small">Made: ${list(a.produced)}</span>` : ''}${a.consumed?.length ? `<br><span class="small muted">Used: ${list(a.consumed)}</span>` : ''}
        ${a.dm_reply ? `<br><span class="small">DM: ${esc(a.dm_reply)}</span>` : ''}</span>
        ${a.status === 'pending' && acts ? `<span class="inv-side-actions"><button type="button" class="btn btn-sm btn-ghost" data-cr="cancel" data-id="${esc(a.attempt_id)}">Cancel</button></span>` : ''}</li>`).join('')}</ul></details>` : ''}`,
    recipes.length);
  }

  function recipeHTML(r, acts) {
    const out = r.output || {};
    const open = s.recipe === r.recipe_id;
    const bases = (r.ingredients || []).find((g) => g.base)?.candidates || [];
    const baseRow = bases.some((c) => c.inventory_item_id === s.base) ? s.base : (bases[0]?.inventory_item_id || null);
    const max = maxBatches(r, baseRow);
    const qty = Math.min(Math.max(1, s.qty), Math.max(1, max));
    const dc = r.check?.dc;
    const status = r.pending_attempt_id ? chip('pending') : max ? `<span class="req-chip cr-st-good" data-craft-max="${max}">can make ${max}${max === MAX_BATCHES ? '+' : ''}</span>`
      : `<span class="req-chip cr-st-warn" data-craft-max="0">${(r.ingredients || []).some((g) => g.have < g.quantity) ? 'Missing ingredients' : 'Cannot craft yet'}</span>`;
    const outQty = (n) => (out.enhancement ? outText(out) : `${Number(out.quantity || 1) * n} × ${out.name}`);
    return `<li class="cr-recipe crs-recipe${open ? ' is-open' : ''}" data-recipe="${esc(r.recipe_id)}">
      <button type="button" class="crs-recipe-head" data-cr="pick" data-id="${esc(r.recipe_id)}" aria-expanded="${open}">
        <strong>${esc(r.name)}</strong>${r.new ? ' <span class="req-chip">new</span>' : ''} <span class="small muted" data-craft-output>→ ${esc(outText(out))}</span> ${status}</button>
      <ul class="small cr-ings">${(r.ingredients || []).map((g) => `<li class="${g.have >= g.quantity ? 'cr-have' : 'cr-miss'}" data-craft-ing="${esc(g.seq)}">${esc(g.label)}${g.base ? ' <span class="muted" data-craft-base>(base item: gets the enhancement)</span>' : g.consumed ? '' : ' <span class="muted">(kept)</span>'}
        <span class="cr-count">${esc(Math.min(g.have, g.quantity))} / ${esc(g.quantity)}</span>${g.have > g.quantity ? ` <span class="muted">(you have ${esc(g.have)})</span>` : ''}${g.have < g.quantity ? ` <span data-craft-missing>· missing ${esc(g.quantity - g.have)}</span>` : ''}</li>`).join('')}</ul>
      ${open ? `<div class="crs-go" data-craft-go-row>
        ${out.enhancement && out.description ? `<p class="small muted">${esc(out.description)}</p>` : ''}
        ${r.description ? `<p class="small">${esc(r.description)}</p>` : ''}
        <p class="small">${dc != null ? `Roll a d20 for <b>${esc(r.check.label)}</b> at the table: <b data-craft-dc>DC ${esc(dc)}</b>. ` : ''}${r.dm_confirms ? 'Your DM confirms the result.' : 'Done at once.'}${r.time_note ? ` ${esc(r.time_note)}` : ''}</p>
        ${r.pending_attempt_id ? `<p class="small">Waiting for your DM.${acts ? ` <button type="button" class="btn btn-sm btn-ghost" data-cr="cancel" data-id="${esc(r.pending_attempt_id)}">Cancel</button>` : ''}</p>`
          : acts && max ? `<div class="crs-controls">
          ${bases.length > 1 ? `<label class="field crs-field"><span>Base item</span><select data-cr-in="base">${bases.map((c) => `<option value="${esc(c.inventory_item_id)}" ${c.inventory_item_id === baseRow ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select></label>` : ''}
          ${max > 1 ? `<span class="crs-qty" role="group" aria-label="How many"><button type="button" class="btn btn-sm" data-cr="qty" data-d="-1" ${qty <= 1 ? 'disabled' : ''} aria-label="One less">−</button>
            <output data-craft-qty aria-live="polite">${qty}</output><button type="button" class="btn btn-sm" data-cr="qty" data-d="1" ${qty >= max ? 'disabled' : ''} aria-label="One more">+</button></span>` : ''}
          ${dc != null ? `<label class="field crs-field"><span>Your roll (total)</span><input type="number" data-cr-in="roll" min="-10" max="60" inputmode="numeric" value="${esc(s.roll)}" style="width:6em"></label>
            <label class="field crs-field"><span>Natural</span><select data-cr-in="natural"><option value="">—</option><option value="nat20" ${s.natural === 'nat20' ? 'selected' : ''}>20</option><option value="nat1" ${s.natural === 'nat1' ? 'selected' : ''}>1</option></select></label>` : ''}
          <button type="button" class="btn btn-gold" data-cr="craft" data-id="${esc(r.recipe_id)}" ${s.busy ? 'disabled' : ''}>${r.dm_confirms ? 'Send to my DM' : 'Craft'}${out.enhancement ? '' : ` <span class="small">(${esc(outQty(qty))})</span>`}</button></div>`
          : !max ? `<p class="small muted">${r.tool && !r.tool.have ? `Needs ${esc(r.tool.name)}.` : 'Gather the missing ingredients first.'}</p>` : ''}
      </div>` : ''}
    </li>`;
  }

  function paint() {
    if (!shown()) return;
    s.slot.innerHTML = html();
  }

  async function craft(r) {
    if (!r || s.busy || !canCraft()) return;
    const bases = (r.ingredients || []).find((g) => g.base)?.candidates || [];
    const baseRow = bases.some((c) => c.inventory_item_id === s.base) ? s.base : (bases[0]?.inventory_item_id || null);
    const max = maxBatches(r, baseRow);
    const n = Math.min(Math.max(1, s.qty), max);
    const sel = max ? pickStacks(r, n, baseRow) : null;
    if (!sel) { toast('You do not have all the ingredients.', 'bad'); return; }
    let roll = null;
    if (r.check?.dc != null) {
      roll = s.roll === '' ? null : Number(s.roll);
      if (roll == null || !Number.isInteger(roll) || roll < -10 || roll > 60) { toast('Enter the total of your roll (-10 to 60).', 'bad'); return; }
    }
    // one request id per intent (recipe, quantity, roll, base): a repeated click or a retry after a lost answer replays the first attempt
    const key = JSON.stringify([r.recipe_id, n, roll, s.natural, baseRow]);   // not the stacks: they change after a lost answer
    if (s.req?.key !== key) s.req = { key, id: crypto.randomUUID() };
    s.busy = true; paint();
    try {
      const res = await startCraftBatch(characterId, r.recipe_id, sel, n, roll, s.req.id, r.check?.dc != null ? s.natural : null);
      s.req = null; s.roll = ''; s.natural = ''; s.qty = 1;
      toast(res.status === 'applied' ? `Crafted: ${list(res.produced) || r.name}` : 'Sent to your DM.', 'good');
      onInventoryChanged?.();
    } catch (err) { toast(err.message, 'bad', 5000); }
    finally { s.busy = false; }
    refresh();
  }

  async function onClick(e) {
    const b = e.target.closest('[data-cr]');
    if (!b || !s.slot?.contains(b)) return;
    const a = b.dataset.cr;
    if (a === 'tool') { s.tool = b.dataset.key; s.recipe = null; s.qty = 1; paint(); return; }
    if (a === 'pick') { s.recipe = s.recipe === b.dataset.id ? null : b.dataset.id; s.qty = 1; s.roll = ''; s.natural = ''; s.base = ''; paint(); return; }
    if (a === 'qty') { s.qty = Math.max(1, s.qty + Number(b.dataset.d)); paint(); return; }
    if (a === 'craft') { craft((s.data?.recipes || []).find((r) => r.recipe_id === b.dataset.id)); return; }
    if (!canCraft()) return;
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
      refresh();
    }
  }
  function onInput(e) {
    const k = e.target.closest('[data-cr-in]')?.dataset.crIn;
    if (!k || !s.slot?.contains(e.target)) return;
    s[k] = e.target.value;
    if (k === 'base') paint();
  }

  return {
    /** Render into the Crafting tab's slot of the current inventory render (and read on first use or when stale). */
    attach(slot) {
      if (!slot) return;
      s.slot = slot;
      slot.addEventListener('click', onClick);
      slot.addEventListener('input', onInput);
      slot.addEventListener('change', onInput);
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
      <p class="small muted">Players open Inventory → Crafting, pick a tool they carry, then a recipe, how many, and Craft. A new recipe is done at once and
        visible to everyone unless you set a DC, "I confirm every attempt" or "Known only". Start from a template or duplicate a recipe.</p>
      <div class="dm-action-row"><button type="button" class="btn btn-gold btn-sm" data-crd="new">+ New recipe</button></div>
      ${rec.recipes.length ? `<table class="dm-rule-table cr-table"><thead><tr><th scope="col">Recipe</th><th scope="col">Makes</th><th scope="col">Tool / roll</th><th scope="col">Status</th><th scope="col"></th></tr></thead><tbody>
        ${rec.recipes.map((r) => `<tr data-recipe="${esc(r.id)}"><th scope="row">${esc(r.name)}<span class="small muted">${esc(VIS[r.visibility] || r.visibility)}${r.known_by.length ? ` · learned by ${esc(r.known_by.map((k) => k.name).join(', '))}` : ''}</span></th>
          <td class="small">${r.kind === 'enhancement' ? `Enhancement: ${esc(r.enhance_modifier_name)} <span class="muted">(on the base item)</span>`
            : `${esc(r.output_quantity)} × ${esc(r.output_name)}${r.output_secret ? ' <span class="muted">(hidden item)</span>' : ''}`}</td>
          <td class="small">${r.check_key ? `${esc(r.check_label)}${r.check_dc ? ` DC ${esc(r.check_dc)}` : ''}` : '—'}${r.requires_dm_approval ? ' · you confirm' : ' · automatic'}</td>
          <td class="small">${esc(r.status)}${r.pending ? ` · ${esc(r.pending)} waiting` : ''}</td>
          <td class="dm-action-row">${r.status !== 'archived' ? `<button type="button" class="btn btn-xs" data-crd="edit" data-id="${esc(r.id)}">Edit</button>` : ''}
            <button type="button" class="btn btn-xs btn-ghost" data-crd="dup" data-id="${esc(r.id)}" title="A new draft with the same fields">Duplicate</button>
            ${r.status === 'draft' ? `<button type="button" class="btn btn-xs btn-gold" data-crd="status" data-st="published" data-id="${esc(r.id)}">Publish</button>` : ''}
            ${r.status === 'published' ? `<button type="button" class="btn btn-xs" data-crd="status" data-st="archived" data-id="${esc(r.id)}">Archive</button>` : ''}
            ${r.status === 'archived' ? `<button type="button" class="btn btn-xs" data-crd="status" data-st="published" data-id="${esc(r.id)}">Restore</button>` : ''}
            ${r.visibility !== 'known' && r.status !== 'archived' ? `<button type="button" class="btn btn-xs btn-ghost" data-crd="grant" data-id="${esc(r.id)}">Who knows it…</button>` : ''}</td></tr>`).join('')}
        </tbody></table>` : '<p class="muted">No recipes yet.</p>'}</section>
    <section class="card dm-card dm-wide" data-craft-mods><h2>Enhancements</h2>
      <p class="small muted">An enhancement (for example a rune or a +1) is attached to the base item of an enhancement recipe: the same item, with its
        bonuses. Players see it on the item once it is theirs.</p>
      <div class="dm-action-row"><button type="button" class="btn btn-sm" data-crd="mod-new">+ New enhancement</button></div>
      ${(rec.modifiers || []).length ? `<ul class="inv-side-list">${rec.modifiers.map((x) => `<li class="inv-side-row" data-mod="${esc(x.id)}"><span class="inv-side-name"><strong>${esc(x.name)}</strong>
        <span class="small muted">${esc(fxText(x.effects) || 'no automatic effect')}${x.applies_to_kind_id ? ` · ${esc(x.applies_to_kind_id)} only` : ''}${x.attached ? ` · on ${esc(x.attached)} item${x.attached === 1 ? '' : 's'}` : ''}</span></span>
        <span class="inv-side-actions"><button type="button" class="btn btn-xs" data-crd="mod-edit" data-id="${esc(x.id)}">Edit</button></span></li>`).join('')}</ul>` : '<p class="muted">No enhancements yet.</p>'}</section>
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
    if (a === 'new') return recipeEditor(campaignId, null, reload, rec.modifiers || []);
    if (a === 'edit') return recipeEditor(campaignId, rec.recipes.find((r) => r.id === b.dataset.id), reload, rec.modifiers || []);
    if (a === 'dup') return recipeEditor(campaignId, null, reload, rec.modifiers || [], duplicateSeed(rec.recipes.find((r) => r.id === b.dataset.id)));
    if (a === 'mod-new') return modifierEditor(campaignId, null, reload);
    if (a === 'mod-edit') return modifierEditor(campaignId, (rec.modifiers || []).find((x) => x.id === b.dataset.id), reload);
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
    <p><strong>${esc(a.character_name)}</strong> · ${esc(a.recipe_name)}${a.batches > 1 ? ` <span class="req-chip" data-craft-batches>× ${esc(a.batches)}</span>` : ''} ${chip(a.status)}${a.recipe_revision !== a.current_revision ? ' <span class="req-chip">recipe changed since</span>' : ''}</p>
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
const pickHTML = (key, id, name, optional = false) => `<span class="cr-pick" data-pick="${esc(key)}"${key === 'teach' ? ' data-pick-campaign' : ''}>
  <input type="search" data-pick-q placeholder="Search items" aria-label="Search items" value="">
  <select data-pick-sel aria-label="Item">${optional ? '<option value="">— none —</option>' : ''}${id ? `<option value="${esc(id)}" selected>${esc(name || id)}</option>` : ''}</select></span>`;

function wirePickers(root, campaignId) {
  root.addEventListener('input', debounce(async (e) => {
    const q = e.target.closest('[data-pick-q]');
    if (!q) return;
    const sel = $('[data-pick-sel]', q.parentElement);
    try {
      // recipe items: campaign items only (official catalog items are refused by the server, review m4)
      const items = (await searchCraftItems(campaignId, q.value.trim())).filter((i) => !(q.parentElement.hasAttribute('data-pick-campaign') && i.official));
      const keep = sel.value;
      const none = sel.querySelector('option[value=""]') ? '<option value="">— none —</option>' : '';
      sel.innerHTML = none + items.map((i) => `<option value="${esc(i.id)}" ${i.id === keep ? 'selected' : ''}>${esc(i.name)}${i.official ? '' : ' (campaign)'}${i.secret ? ' · hidden' : ''}</option>`).join('');
      if (!keep && items.length && !none) sel.value = items[0].id;
    } catch (err) { toast(err.message, 'bad'); }
  }, 300));
}

// Ready-made starting points (?v=42): FRONTEND constants only. Choosing one fills the editor; nothing is written until the DM saves,
// and no item or recipe is ever created by a template. Official SRD items are referenced by id (Potion of Healing, Acid,
// Antitoxin); the raw and intermediate items are the DM's own (a hint says what to choose). Short neutral wording of our own.
export const RECIPE_TEMPLATES = [
  { key: 'extract', title: 'Plant extract (intermediate)', name: 'Plant extract', check_key: 'herbalism-kit',
    description: 'Crush and steep the plant to draw out its essence.',
    ingredients: [{ quantity: 2, hint: 'your plant (an herb item)' }], output: { hint: 'your extract item (make one in DM Space → Content)' } },
  { key: 'healing', title: 'Potion of Healing from an extract', name: 'Potion of Healing', check_key: 'herbalism-kit',
    description: 'Blend the extract into a restorative draught.',
    ingredients: [{ quantity: 1, hint: 'your extract item' }], output: { item_id: 'potion-of-healing-common', item_name: 'Potion of Healing' } },
  { key: 'salts', title: 'Mineral salts (intermediate)', name: 'Mineral salts', check_key: 'alchemists-supplies',
    description: 'Heat and dry the raw material until fine salts remain.',
    ingredients: [{ quantity: 2, hint: 'your raw material' }], output: { hint: 'your salts item (make one in DM Space → Content)' } },
  { key: 'acid', title: 'Acid from salts', name: 'Acid', check_key: 'alchemists-supplies',
    description: 'Dissolve the salts into a biting liquid and seal it in a vial.',
    ingredients: [{ quantity: 1, hint: 'your salts item' }], output: { item_id: 'acid-vial', item_name: 'Acid (vial)' } },
  { key: 'antitoxin', title: 'Antitoxin from an extract', name: 'Antitoxin', check_key: 'herbalism-kit',
    description: 'Thin the extract into a draught that settles the stomach against poison.',
    ingredients: [{ quantity: 1, hint: 'your extract item' }], output: { item_id: 'antitoxin-vial', item_name: 'Antitoxin (vial)' } },
];

const templateSeed = (t) => ({ kind: 'item', visibility: 'known', requires_dm_approval: false, failure_mode: 'keep', output_identified: true,
  output_quantity: 1, name: t.name, description: t.description, check_key: t.check_key,
  output_item_id: t.output.item_id || null, output_name: t.output.item_name || null, output_hint: t.output.hint || null,
  ingredients: t.ingredients.map((g) => ({ quantity: g.quantity, consumed: true, hint: g.hint })) });

/** A new draft with the editable fields of a recipe ("Copy of …"): no id, no attempts, no known rows, no recipe items (teachers). */
export function duplicateSeed(r) {
  const keep = ['kind', 'enhance_modifier_id', 'description', 'dm_notes', 'visibility', 'output_item_id', 'output_name', 'output_quantity', 'output_label',
    'output_identified', 'crit_output_item_id', 'crit_output_name', 'crit_bonus_quantity', 'failure_mode', 'failure_output_item_id', 'failure_output_name',
    'failure_output_quantity', 'check_key', 'check_dc', 'requires_dm_approval', 'time_note'];
  const x = Object.fromEntries(keep.filter((k) => r[k] !== undefined).map((k) => [k, r[k]]));
  return { ...x, name: `Copy of ${r.name}`.slice(0, 120), teachers: [],
    ingredients: (r.ingredients || []).map((g) => ({ item_id: g.item_id, item_name: g.item_name, tag: g.tag, label: g.label, quantity: g.quantity, consumed: g.consumed, base: g.base })) };
}

/**
 * The recipe editor. Simple part: name, tool (or a skill check / none), ingredients (item + quantity), result (item + quantity),
 * optional DC, "I confirm every attempt", "Known only". Everything else of v2 (description, visibility, teachers, critical /
 * failure results, output label / identified, tags and labels, enhancement, time note, DM notes) stays in ONE collapsed
 * "More options": every field is in the DOM, so saving round-trips the values it does not show.
 * r: the saved recipe (edit) or null (new); seed: prefill for a new recipe (template, duplicate).
 */
async function recipeEditor(campaignId, r, reload, modifiers = [], seed = null) {
  let ref = { skills: [], tools: [] };
  try { ref = await getEditorReference(); } catch { /* checks fall back to the stored key */ }
  // a NEW recipe: instant (no DM approval), no DC, visible to all (the existing rows keep their values)
  const x = r || seed || { kind: 'item', visibility: 'known', output_quantity: 1, requires_dm_approval: false, failure_mode: 'keep', output_identified: true, ingredients: [{ quantity: 1, consumed: true }] };
  const enh = x.kind === 'enhancement';
  const tools = (ref.tools || []).map((k) => [k.id, k.name]);
  const skills = (ref.skills || []).map((k) => [k.id, k.name]);
  const knownKey = !x.check_key || tools.some(([k]) => k === x.check_key) || skills.some(([k]) => k === x.check_key);
  const advIng = (g) => !!(g.tag || (g.label && String(g.label).trim()) || g.consumed === false || g.base);
  const advanced = enh || x.visibility === 'secret' || (x.teachers || []).length > 0 || (x.ingredients || []).some(advIng);
  const ingRow = (g) => `<fieldset class="cr-ing-row" data-ing>
    <span data-ing-item ${g.tag ? 'hidden' : ''}>${pickHTML('ing', g.item_id, g.item_name)}</span>
    <input type="text" data-ing-tag maxlength="40" placeholder="tag, e.g. silver" value="${esc(g.tag || '')}" ${g.tag ? '' : 'hidden'} aria-label="Tag">
    <label class="crs-inline"><span class="small muted">×</span><input type="number" data-ing-qty min="1" max="99" value="${esc(g.quantity || 1)}" aria-label="Quantity" style="width:4.5em"></label>
    ${g.hint && !g.item_id ? `<span class="small muted" data-ing-hint>Choose ${esc(g.hint)}</span>` : ''}
    <span class="crs-adv" data-adv-ing>
      <select data-ing-kind aria-label="Ingredient type"><option value="item" ${g.tag ? '' : 'selected'}>Item</option><option value="tag" ${g.tag ? 'selected' : ''}>Any item with tag</option></select>
      <label class="check-field"><input type="checkbox" data-ing-consumed ${g.consumed === false ? '' : 'checked'}><span>Used up</span></label>
      <input type="text" data-ing-label maxlength="120" placeholder="Label players see (for a hidden item)" value="${esc(g.label || '')}" aria-label="Player label">
      <label class="check-field" data-ing-base-wrap ${enh ? '' : 'hidden'}><input type="radio" name="cr-base" data-ing-base ${g.base ? 'checked' : ''}><span>Base item (gets the enhancement, kept)</span></label></span>
    <button type="button" class="btn btn-xs btn-ghost" data-ing-del aria-label="Remove ingredient">✕</button></fieldset>`;
  const teachRow = (t) => `<fieldset class="cr-ing-row" data-teach>
    <span>${pickHTML('teach', t.item_id, t.item_name)}</span>
    <select data-teach-consumed aria-label="When read"><option value="" ${t.item_id ? '' : 'selected'}>Default (a scroll is used up, a book is kept)</option>
      <option value="true" ${t.item_id && t.consume_on_learn ? 'selected' : ''}>Used up when read</option><option value="false" ${t.item_id && t.consume_on_learn === false ? 'selected' : ''}>Kept when read</option></select>
    <button type="button" class="btn btn-xs btn-ghost" data-teach-del aria-label="Remove recipe item">✕</button></fieldset>`;
  const m = openModal({ title: r ? `Recipe: ${r.name}` : 'New recipe', wide: true, body: `
    <div class="cr-editor${advanced ? ' cr-adv-open' : ''}" data-cr-editor>
    ${!r ? `<label class="field"><span>Start from a template (optional; nothing is saved until you click Save)</span><select data-r-template>
      <option value="">— empty recipe —</option>${RECIPE_TEMPLATES.map((t) => `<option value="${esc(t.key)}">${esc(t.title)}</option>`).join('')}</select></label>` : ''}
    <div class="ce-grid">
      <label class="field"><span>Name</span><input data-r="name" maxlength="120" value="${esc(x.name || '')}" required></label>
      <label class="field"><span>Tool</span><select data-r="check_key"><option value="">No tool needed</option>
        <optgroup label="Tool (the character must carry it)">${tools.map(([k, l]) => `<option value="${esc(k)}" ${x.check_key === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</optgroup>
        <optgroup label="Skill check (no tool; only with a DC)">${skills.map(([k, l]) => `<option value="${esc(k)}" ${x.check_key === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</optgroup>
        ${knownKey ? '' : `<option value="${esc(x.check_key)}" selected>${esc(x.check_label || x.check_key)}</option>`}</select></label>
    </div>
    <fieldset class="ce-section"><legend>Ingredients</legend><div data-ings>${(x.ingredients || []).map(ingRow).join('')}</div>
      <button type="button" class="btn btn-xs" data-ing-add>+ Ingredient</button></fieldset>
    <fieldset class="ce-section" data-noenh ${enh ? 'hidden' : ''}><legend>Result</legend><div class="ce-grid">
      <label class="field"><span>Makes</span>${pickHTML('output', x.output_item_id, x.output_name)}${x.output_hint && !x.output_item_id ? `<span class="small muted" data-out-hint>Choose ${esc(x.output_hint)}</span>` : ''}</label>
      <label class="field"><span>Quantity</span><input type="number" data-r="output_quantity" min="1" max="99" value="${esc(x.output_quantity || 1)}"></label>
    </div></fieldset>
    <div class="ce-grid">
      <label class="field"><span>DC (optional; players see it and roll at the table)</span><input type="number" data-r="check_dc" min="1" max="40" value="${esc(x.check_dc ?? '')}"></label>
      <label class="check-field"><input type="checkbox" data-r="requires_dm_approval" ${x.requires_dm_approval ? 'checked' : ''} ${x.check_dc != null ? 'checked disabled' : ''}><span>I confirm every attempt <span class="small muted" data-dc-note>${x.check_dc != null ? '(always with a DC)' : '(off: done at once)'}</span></span></label>
      <label class="check-field"><input type="checkbox" data-r-knownonly ${x.visibility && x.visibility !== 'known' ? 'checked' : ''} ${x.visibility === 'secret' ? 'disabled' : ''}><span>Known only <span class="small muted">(${x.visibility === 'secret' ? 'secret: only who you grant it to, see More options' : 'shown only to characters who learned it; off: everyone sees it'})</span></span></label>
    </div>
    <details class="ce-section crs-more" data-cr-more ${advanced ? 'open' : ''}><summary><strong>More options</strong> <span class="small muted">(description, who knows it, recipe books, critical / failure results, enhancement, notes)</span></summary>
      <label class="field"><span>Description (players see it)</span><textarea data-r="description" maxlength="2000" rows="2">${esc(x.description || '')}</textarea></label>
      <label class="field"><span>Who knows it</span><select data-r="visibility">${Object.entries(VIS).map(([k, l]) => `<option value="${k}" ${(x.visibility || 'known') === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
      <fieldset class="ce-section"><legend>Result details</legend><div class="ce-grid">
        <label class="field"><span>The recipe</span><select data-r="kind"><option value="item" ${enh ? '' : 'selected'}>makes an item</option>
          <option value="enhancement" ${enh ? 'selected' : ''}>enhances an item (the base item gets an enhancement)</option></select></label>
        <label class="field" data-enh ${enh ? '' : 'hidden'}><span>Enhancement</span><select data-r="enhance_modifier_id"><option value="">— choose —</option>
          ${modifiers.map((md) => `<option value="${esc(md.id)}" ${x.enhance_modifier_id === md.id ? 'selected' : ''}>${esc(md.name)}${md.effects?.length ? ` (${esc(fxText(md.effects))})` : ''}</option>`).join('')}</select>
          <span class="small muted">Make one first under Enhancements. Mark one ingredient as the base item; it is kept and gets the enhancement. A critical
            success counts as a success; a failure never touches the base item.</span></label>
        <label class="field"><span>Shown to players who do not know the item yet (an enhancement: instead of its name and effects)</span><input data-r="output_label" maxlength="120" value="${esc(x.output_label || '')}" placeholder="e.g. a shimmering draught"></label>
        <label class="check-field" data-noenh ${enh ? 'hidden' : ''}><input type="checkbox" data-r="output_identified" ${x.output_identified === false ? '' : 'checked'}><span>The crafter knows what they made (otherwise it arrives unidentified)</span></label>
        <label class="field" data-noenh ${enh ? 'hidden' : ''}><span>Critical success: another result (optional)</span>${pickHTML('crit', x.crit_output_item_id, x.crit_output_name, true)}</label>
        <label class="field" data-noenh ${enh ? 'hidden' : ''}><span>Critical success: extra quantity</span><input type="number" data-r="crit_bonus_quantity" min="0" max="99" value="${esc(x.crit_bonus_quantity || 0)}"></label>
        <label class="field"><span>On a failure</span><select data-r="failure_mode">${Object.entries(FAILURE).map(([k, l]) => `<option value="${k}" ${(x.failure_mode || 'keep') === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>
        <label class="field"><span>Failure gives (optional junk item)</span>${pickHTML('failure', x.failure_output_item_id, x.failure_output_name, true)}</label>
        <label class="field"><span>Failure: how many</span><input type="number" data-r="failure_output_quantity" min="1" max="99" value="${esc(x.failure_output_quantity || 1)}"></label>
        <label class="field"><span>Time (a note)</span><input data-r="time_note" maxlength="200" value="${esc(x.time_note || '')}" placeholder="e.g. one hour"></label>
      </div></fieldset>
      <p class="small muted">Ingredients: with More options open each line also has its type (an item or any item with a tag), "Used up" (off: a
        reusable tool) and a label players see for a hidden item.</p>
      <fieldset class="ce-section" data-teachers><legend>Recipe items (books, scrolls)</legend>
        <p class="small muted">A character who reads one of these items (Inventory → Crafting, or the item's details) learns this recipe for good, also a
          secret one. You can still grant it yourself ("Who knows it…"). Only items of this campaign (DM content or your campaign homebrew) can teach.</p>
        <div data-teach-rows>${(x.teachers || []).map(teachRow).join('')}</div>
        <button type="button" class="btn btn-xs" data-teach-add>+ Recipe item</button></fieldset>
      <label class="field"><span>Your notes (DM only)</span><textarea data-r="dm_notes" maxlength="2000" rows="2">${esc(x.dm_notes || '')}</textarea></label>
    </details></div>`,
  footer: `<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn" data-r-save>Save draft${r ? ' / changes' : ''}</button>
    ${!r || r.status === 'draft' ? '<button type="button" class="btn btn-gold" data-r-save data-publish>Save and publish</button>' : ''}` });
  wirePickers(m.el, campaignId);
  const v = (k) => $(`[data-r="${k}"]`, m.el);
  const more = $('[data-cr-more]', m.el);
  more.addEventListener('toggle', () => $('[data-cr-editor]', m.el).classList.toggle('cr-adv-open', more.open));
  const syncDc = () => {
    const has = v('check_dc').value !== '';
    const ap = v('requires_dm_approval');
    if (has) { ap.checked = true; ap.disabled = true; } else ap.disabled = false;
    $('[data-dc-note]', m.el).textContent = has ? '(always with a DC)' : '(off: done at once)';
  };
  m.el.addEventListener('input', (e) => {
    if (e.target.matches('[data-r="check_dc"]')) syncDc();
    if (e.target.matches('[data-pick-q]')) { e.target.closest('[data-ing]')?.querySelector('[data-ing-hint]')?.remove(); if (e.target.closest('[data-pick="output"]')) $('[data-out-hint]', m.el)?.remove(); }
  });
  m.el.addEventListener('change', (e) => {
    if (e.target.matches('[data-r-template]')) {
      const t = RECIPE_TEMPLATES.find((y) => y.key === e.target.value);
      if (!t) return;
      m.close();
      recipeEditor(campaignId, null, reload, modifiers, templateSeed(t));
      return;
    }
    // "Known only" and the full visibility select are one value: the select is the source of truth (secret stays secret)
    if (e.target.matches('[data-r-knownonly]')) { v('visibility').value = e.target.checked ? 'discoverable' : 'known'; }
    if (e.target.matches('[data-r="visibility"]')) {
      const ko = $('[data-r-knownonly]', m.el);
      ko.checked = e.target.value !== 'known'; ko.disabled = e.target.value === 'secret';
    }
    const k = e.target.closest('[data-ing-kind]');
    if (k) { const row = k.closest('[data-ing]'); $('[data-ing-item]', row).hidden = k.value !== 'item'; $('[data-ing-tag]', row).hidden = k.value !== 'tag'; }
    if (e.target.matches('[data-pick-sel]')) { e.target.closest('[data-ing]')?.querySelector('[data-ing-hint]')?.remove(); if (e.target.closest('[data-pick="output"]')) $('[data-out-hint]', m.el)?.remove(); }
    if (e.target.matches('[data-r="kind"]')) {
      const on = e.target.value === 'enhancement';
      $$('[data-enh], [data-ing-base-wrap]', m.el).forEach((el) => { el.hidden = !on; });
      $$('[data-noenh]', m.el).forEach((el) => { el.hidden = on; });
    }
  });
  m.el.addEventListener('click', async (e) => {
    if (e.target.closest('[data-ing-add]')) {
      $('[data-ings]', m.el).insertAdjacentHTML('beforeend', ingRow({ quantity: 1, consumed: true }));
      const on = v('kind').value === 'enhancement';
      $$('[data-ing-base-wrap]', m.el).forEach((el) => { el.hidden = !on; });
      return;
    }
    if (e.target.closest('[data-ing-del]')) { e.target.closest('[data-ing]').remove(); return; }
    if (e.target.closest('[data-teach-add]')) { $('[data-teach-rows]', m.el).insertAdjacentHTML('beforeend', teachRow({})); return; }
    if (e.target.closest('[data-teach-del]')) { e.target.closest('[data-teach]').remove(); return; }
    const save = e.target.closest('[data-r-save]');
    if (!save) return;
    const pick = (k) => $(`[data-pick="${k}"] [data-pick-sel]`, m.el)?.value || null;
    const num = (el) => (el.value === '' ? null : Number(el.value));
    const isEnh = v('kind').value === 'enhancement';
    const dc = num(v('check_dc'));
    const recipe = { id: r?.id || null, name: v('name').value.trim(), description: v('description').value, dm_notes: v('dm_notes').value,
      kind: isEnh ? 'enhancement' : 'item', enhance_modifier_id: isEnh ? (v('enhance_modifier_id').value || null) : null,
      visibility: v('visibility').value, output_item_id: isEnh ? null : pick('output'), output_quantity: num(v('output_quantity')) || 1, output_label: v('output_label').value,
      output_identified: v('output_identified').checked, crit_output_item_id: isEnh ? null : pick('crit'), crit_bonus_quantity: isEnh ? 0 : (num(v('crit_bonus_quantity')) || 0),
      failure_mode: v('failure_mode').value, failure_output_item_id: pick('failure'), failure_output_quantity: num(v('failure_output_quantity')) || 1,
      check_key: v('check_key').value || null, check_dc: dc,
      requires_dm_approval: v('requires_dm_approval').checked || dc != null, time_note: v('time_note').value,
      ingredients: $$('[data-ing]', m.el).map((row) => {
        const kind = $('[data-ing-kind]', row).value;
        const base = isEnh && $('[data-ing-base]', row).checked;
        return { item_id: kind === 'item' ? ($('[data-pick-sel]', row).value || null) : null, tag: kind === 'tag' ? $('[data-ing-tag]', row).value.trim() : null,
          quantity: base ? 1 : (num($('[data-ing-qty]', row)) || 1), consumed: base ? false : $('[data-ing-consumed]', row).checked, label: $('[data-ing-label]', row).value,
          ...(base ? { base: true } : {}) };
      }),
      teachers: $$('[data-teach]', m.el).map((row) => ({ item_id: $('[data-pick-sel]', row).value || null,
        consumed: { true: true, false: false }[$('[data-teach-consumed]', row).value] ?? null })).filter((t) => t.item_id) };
    // friendly checks before the server's (it checks the same and more)
    if (!recipe.name) { toast('Give the recipe a name.', 'bad'); return; }
    if (!recipe.ingredients.length || recipe.ingredients.some((g) => !g.item_id && !g.tag)) { toast('Choose an item for every ingredient (search, then pick).', 'bad'); return; }
    if (!isEnh && !recipe.output_item_id) { toast('Choose what the recipe makes.', 'bad'); return; }
    if (dc != null && !recipe.check_key) { toast('A DC needs something to roll: choose a tool or a skill check.', 'bad'); v('check_key').focus(); return; }
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

// a campaign enhancement (item modifier): name, description, what it fits, rarity and effects the sheet applies automatically
function modifierEditor(campaignId, md, reload) {
  const x = md || { effects: [{ type: 'attack_bonus', value: 1 }, { type: 'damage_bonus', value: 1 }] };
  const frozen = !!md?.attached;
  const fxRow = (e) => `<fieldset class="cr-ing-row" data-fx>
    <select data-fx-type aria-label="Effect" ${frozen ? 'disabled' : ''}>${[['attack_bonus', 'Attack rolls + (this item)'], ['damage_bonus', 'Damage + (this item)'], ['ac_bonus', 'Armor Class +'],
      ['save_bonus', 'Saving throws + (all)'], ['custom', 'Note (not automatic)']].map(([k, l]) => `<option value="${k}" ${e.type === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>
    <input type="number" data-fx-value min="-10" max="10" value="${esc(e.value ?? 1)}" aria-label="Bonus" style="width:5em" ${e.type === 'custom' ? 'hidden' : ''} ${frozen ? 'disabled' : ''}>
    <input type="text" data-fx-text maxlength="300" placeholder="What it does" value="${esc(e.text || '')}" aria-label="Note" ${e.type === 'custom' ? '' : 'hidden'} ${frozen ? 'disabled' : ''}>
    ${frozen ? '' : '<button type="button" class="btn btn-xs btn-ghost" data-fx-del aria-label="Remove effect">✕</button>'}</fieldset>`;
  const m = openModal({ title: md ? `Enhancement: ${md.name}` : 'New enhancement', body: `
    <p class="muted small">Players see the name, the description and the effects on their item once it is enhanced (not on a copy they do not know).
      ${frozen ? '<b>It is already on an item: its effects stay as they are</b> (make a new enhancement for other effects).' : ''}</p>
    <label class="field"><span>Name</span><input data-m="name" maxlength="80" value="${esc(x.name || '')}" required></label>
    <label class="field"><span>Description (players see it)</span><textarea data-m="description" maxlength="1000" rows="2">${esc(x.description || '')}</textarea></label>
    <div class="ce-grid">
      <label class="field"><span>Fits</span><select data-m="applies_to_kind_id" ${frozen ? 'disabled' : ''}><option value="weapon" ${x.applies_to_kind_id === 'weapon' || !md ? 'selected' : ''}>Weapons</option>
        <option value="armor" ${x.applies_to_kind_id === 'armor' ? 'selected' : ''}>Armor and shields</option><option value="" ${md && !x.applies_to_kind_id ? 'selected' : ''}>Any item</option></select></label>
      <label class="field"><span>Rarity (optional)</span><select data-m="rarity_id"><option value="">—</option>${['common', 'uncommon', 'rare', 'very_rare', 'legendary'].map((k) => `<option value="${k}" ${x.rarity_id === k ? 'selected' : ''}>${esc(k.replace('_', ' '))}</option>`).join('')}</select></label>
    </div>
    <fieldset class="ce-section"><legend>Effects (applied automatically while the item is equipped)</legend><div data-fxs>${(x.effects || []).map(fxRow).join('')}</div>
      ${frozen ? '' : '<button type="button" class="btn btn-xs" data-fx-add>+ Effect</button>'}</fieldset>`,
  footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-m-save>Save</button>' });
  m.el.addEventListener('change', (e) => {
    const t = e.target.closest('[data-fx-type]');
    if (t) { const row = t.closest('[data-fx]'); $('[data-fx-value]', row).hidden = t.value === 'custom'; $('[data-fx-text]', row).hidden = t.value !== 'custom'; }
  });
  m.el.addEventListener('click', async (e) => {
    if (e.target.closest('[data-fx-add]')) { $('[data-fxs]', m.el).insertAdjacentHTML('beforeend', fxRow({ type: 'attack_bonus', value: 1 })); return; }
    if (e.target.closest('[data-fx-del]')) { e.target.closest('[data-fx]').remove(); return; }
    const save = e.target.closest('[data-m-save]');
    if (!save) return;
    const v = (k) => $(`[data-m="${k}"]`, m.el).value;
    const modifier = { id: md?.id || null, name: v('name').trim(), description: v('description'), applies_to_kind_id: v('applies_to_kind_id') || null,
      rarity_id: v('rarity_id') || null,
      effects: $$('[data-fx]', m.el).map((row) => {
        const type = $('[data-fx-type]', row).value;
        return type === 'custom' ? { type, text: $('[data-fx-text]', row).value.trim() } : { type, value: Number($('[data-fx-value]', row).value) };
      }) };
    save.disabled = true;
    try { await saveModifier(campaignId, modifier); toast('Enhancement saved.', 'good'); m.close(); reload(); }
    catch (err) { toast(err.message, 'bad', 6000); save.disabled = false; }
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
