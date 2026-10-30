// Inventory tab: summary, equipment slots, item list, item detail and the catalog picker.
// All data comes from inventory-api.js; after every change the authoritative state is re-read from the server
// (no client-side simulation of splits, merges or quantities).
import * as api from './inventory-api.js?v=14';
import { $, esc, toast, confirmDialog, openModal, debounce, focusKeyOf, focusByKey, takePendingFocusKey } from './utils.js?v=14';
import { openHomebrewForm } from './homebrew-form.js?v=14';
import { isAnyDM } from './store.js?v=14';
import { icon, ITEM_ICONS } from './icons.js?v=14';
import { sectionHead } from './section.js?v=14';

const CATEGORIES = [
  ['all', 'All', () => true],
  ['weapons', 'Weapons', (r) => r.kind_id === 'weapon'],
  ['armor', 'Armor', (r) => r.kind_id === 'armor'],
  ['consumables', 'Consumables', (r) => r.is_consumable],
  ['magic', 'Magic', (r) => r.is_magic],
  ['ammunition', 'Ammunition', (r) => r.kind_id === 'ammunition'],
  ['tools', 'Tools', (r) => r.kind_id === 'tool'],
  ['gear', 'Gear', (r) => r.kind_id === 'gear'],
  ['containers', 'Containers', (r, ui) => ui.isContainer(r)],
];
const SLOT_ICONS = {
  main_hand: 'equipment-slots/main-hand', off_hand: 'equipment-slots/off-hand', armor: 'equipment-slots/armor', shield: 'equipment-slots/shield',
  head: 'equipment-slots/head', neck: 'equipment-slots/neck', cloak: 'equipment-slots/cloak', hands: 'equipment-slots/hands', belt: 'items/gear',
  feet: 'equipment-slots/legs', ring_1: 'equipment-slots/ring', ring_2: 'equipment-slots/ring', focus: 'equipment-slots/focus',
};
/** Category icon of an inventory row (kind first, then magic / container). */
const itemIcon = (r, ui) => (/shield/.test(r.category_id || '') ? 'equipment-slots/shield' : null) || ITEM_ICONS[r.kind_id] || (r.is_magic ? ITEM_ICONS.magic : ui?.isContainer?.(r) ? ITEM_ICONS.containers : ITEM_ICONS.gear);
const LOW_AMMO = 10;
const PAGE_SIZE = 50;
const fmtWeight = (w) => `${Math.round(Number(w || 0) * 100) / 100} lb`;
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const SOURCE_FILTERS = [['', 'All sources'], ['official', 'Official'], ['private', 'My homebrew'], ['campaign', 'Campaign homebrew']];
const EQUIP_REVIEW = ['equipped_pending', 'equipped_manual'];
const reviewText = (x) => (EQUIP_REVIEW.includes(x.category)
  ? 'Was equipped in the old sheet. Equip it in a slot, or mark it as not equipped.'
  : x.category.startsWith('qty0') ? 'Quantity 0 in the old sheet. Remove it, or link it and set a quantity.'
    : x.detail?.reason || x.category.replace(/_/g, ' '));
/** Text + icon (never colour alone) for where an item definition comes from. */
function sourceBadge(d) {
  if (!d || d.visibility === 'official') return '';
  const label = d.visibility === 'campaign' ? 'Campaign custom' : 'Homebrew';
  return `<span class="badge inv-b-homebrew" title="${d.visibility === 'campaign' ? 'Made by your DM for this campaign' : 'Only visible to its author'}">${icon('ui/custom-content', { size: 14 })}${label}</span>`;
}

/**
 * Mount the inventory UI.
 * opts: { characterId, getCharacter: () => character row, userId, getCampaigns: () => [{id, name}] (campaigns the user is a member of),
 *         onRows: (rows) => void }
 * Returns { refresh, scheduleRefresh, destroy }.
 */
export function mountInventory(el, opts) {
  const s = {
    inventoryId: null, rows: [], equipment: [], attunement: null, weight: null, containers: new Map(), review: new Map(),
    details: new Map(), lookups: null, filter: 'all', status: 'loading', error: null, busy: new Set(),
    refreshing: null, again: false, destroyed: false, eqOpen: window.matchMedia?.('(min-width: 900px)').matches ?? true,
  };

  // ---- derived helpers ------------------------------------------------------------------------------
  const detail = (r) => (r.item_id ? s.details.get(r.item_id) : null);
  const rowById = (id) => s.rows.find((r) => r.id === id);
  const slotName = (id) => s.lookups?.slots.find((x) => x.id === id)?.name || id;
  const kindName = (id) => s.lookups?.kinds.find((k) => k.id === id)?.name || '';
  const categoryName = (id) => s.lookups?.categories.find((c) => c.id === id)?.name || '';
  const rarityName = (id) => s.lookups?.rarities.find((r) => r.id === id)?.name || '';
  const occupant = (slotId) => {
    const e = s.equipment.find((x) => x.slot_id === slotId);
    return e ? rowById(e.inventory_item_id) || { id: e.inventory_item_id, display_name: 'Unknown item' } : null;
  };
  const isLegacy = (r) => !r.item_id;
  const isContainer = (r) => {
    const d = detail(r);
    return !!(d && (d.capacity_weight_lb != null || d.capacity_volume_cuft != null || d.weightless_contents))
      || (s.containers.get(r.id)?.items_inside || 0) > 0;
  };
  // Legacy rows are read-only until they are linked or converted: no +/- and no quantity changes except removal.
  const canStack = (r) => !r.equipped && !isLegacy(r) && r.stackable;
  const reviewOf = (r) => (s.review.get(r.id) || []);
  const needsEquipReview = (r) => !r.equipped && reviewOf(r).some((x) => EQUIP_REVIEW.includes(x.category));
  const ui = { isContainer };

  function compatibleSlots(r) {
    if (isLegacy(r) || !s.lookups) return [];
    const ids = new Set(s.lookups.slotRules
      .filter((x) => x.item_id === r.item_id || (!x.item_id && x.kind_id === r.kind_id && (!x.category_id || x.category_id === r.category_id)))
      .map((x) => x.slot_id));
    return s.lookups.slots.filter((x) => ids.has(x.id));
  }

  function descendants(id, acc = new Set()) {
    s.rows.filter((r) => r.container_item_id === id && !acc.has(r.id)).forEach((r) => { acc.add(r.id); descendants(r.id, acc); });
    return acc;
  }

  function ammoInfo(r) {
    const d = detail(r);
    if (!d || d.kind_id !== 'weapon') return null;
    const props = d.weapon_properties || [];
    if (!d.weapon_ammo_type_id) return props.includes('ammunition') ? { unknown: true } : null;
    const typeName = s.lookups.ammoTypes.find((a) => a.id === d.weapon_ammo_type_id)?.name || d.weapon_ammo_type_id;
    const stacks = s.rows.filter((x) => detail(x)?.ammo_type_id === d.weapon_ammo_type_id);
    return { typeName, stacks, total: stacks.reduce((n, x) => n + x.quantity, 0) };
  }

  // ---- data -------------------------------------------------------------------------------------------
  async function load() {
    s.lookups ||= await api.getLookups();
    // fluent read path: the whole inventory state in one request (get_character_bundle 'inventory'), same rows as below
    if (opts.loadBundle) {
      const b = await opts.loadBundle();
      if (!b) throw new api.InventoryError('not_found', 'This character has no inventory yet. Ask the DM to run the inventory migration.');
      s.inventoryId = b.inventory_id;
      const ids = [...new Set((b.rows || []).map((r) => r.item_id).filter(Boolean))];
      api.invalidateCatalogItems(ids);              // fresh, as below: a shared homebrew definition may have changed
      api.primeCatalogItems(b.catalog_items || []);
      const details = new Map(ids.filter((id) => api.cachedCatalogItem(id)).map((id) => [id, api.cachedCatalogItem(id)]));
      const reviewMap = new Map();
      (b.review || []).forEach((x) => reviewMap.set(x.inventory_item_id, [...(reviewMap.get(x.inventory_item_id) || []), x]));
      return { rows: b.rows || [], equipment: b.equipment || [], attunement: b.attunement || { attuned_count: 0, attunement_limit: 3, slots_free: 3 },
        weight: b.weight || { stacks: 0, pieces: 0, total_weight_lb: 0 }, details,
        containers: new Map((b.containers || []).map((c) => [c.container_item_id, c])), review: reviewMap };
    }
    s.inventoryId ||= await api.getCharacterInventoryId(opts.characterId);
    const [rows, equipment, attunement, weight, containers, review] = await Promise.all([
      api.getInventoryRows(s.inventoryId), api.getCharacterEquipment(opts.characterId), api.getAttunement(opts.characterId),
      api.getInventoryWeight(s.inventoryId), api.getContainerContents(s.inventoryId), api.getLegacyReview(opts.characterId),
    ]);
    // fresh: a campaign member may have edited or archived a shared homebrew definition meanwhile
    const details = await api.getCatalogItems([...new Set(rows.map((r) => r.item_id).filter(Boolean))], { fresh: true });
    const reviewMap = new Map();
    review.forEach((x) => reviewMap.set(x.inventory_item_id, [...(reviewMap.get(x.inventory_item_id) || []), x]));
    return { rows, equipment, attunement, weight, details, containers: new Map(containers.map((c) => [c.container_item_id, c])), review: reviewMap };
  }

  async function refresh() {
    if (s.refreshing) { s.again = true; return s.refreshing; }
    s.refreshing = (async () => {
      do {
        s.again = false;
        try {
          const data = await load();
          if (s.destroyed) return;
          Object.assign(s, data, { status: 'ready', error: null });
          opts.onRows?.(s.rows);
        } catch (raw) {
          if (s.destroyed) return;
          s.error = api.normalizeError(raw);
          if (s.status === 'ready') toast(s.error.message, 'bad');
          else s.status = 'error';
        }
      } while (s.again && !s.destroyed);
      render();
    })();
    try { await s.refreshing; } finally { s.refreshing = null; }
  }
  const scheduleRefresh = debounce(() => { if (!s.destroyed) refresh(); }, 400);

  /** Run a mutation once per key (double-click safe), report errors, then re-read the server state. */
  async function act(key, fn, { refreshAfter = true } = {}) {
    if (s.busy.has(key)) return undefined;
    s.busy.add(key);
    render();
    try {
      return await fn();
    } catch (raw) {
      const e = api.normalizeError(raw);
      toast(e.message, 'bad', 4500);
      return undefined;
    } finally {
      s.busy.delete(key);
      if (refreshAfter) await refresh(); else render();
    }
  }
  const busy = (key) => (s.busy.has(key) ? 'disabled aria-busy="true"' : '');

  // ---- rendering ---------------------------------------------------------------------------------------
  function render() {
    if (s.destroyed) return;
    if (s.status === 'loading') {
      el.innerHTML = '<div class="card inv-state"><div class="spinner"></div><p class="muted">Loading inventory…</p></div>';
      return;
    }
    if (s.status === 'error') {
      el.innerHTML = `<div class="card inv-state"><p>${esc(s.error?.message || 'The inventory could not be loaded.')}</p>
        <button type="button" class="btn btn-gold btn-sm" data-inv="retry">Try again</button></div>`;
      return;
    }
    const scrollKeep = window.scrollY;
    const focusKeep = el.contains(document.activeElement) ? focusKeyOf(document.activeElement) : null;
    el.innerHTML = `
      <div class="inv">
        ${summaryHTML()}
        <div class="inv-layout">
          <div class="inv-side">
            ${equipmentHTML()}
            ${attunementHTML()}
            ${quickUseHTML()}
            ${containersHTML()}
            ${legacyHTML()}
          </div>
          ${listSectionHTML()}
        </div>
      </div>`;
    assignFocusKeys();
    window.scrollTo(0, scrollKeep);
    // keep focus on the same control across re-renders; a modal closed meanwhile may be waiting to return focus here
    const pending = takePendingFocusKey();
    const key = (pending && !document.querySelector('.modal-backdrop:not([data-closing])') ? pending : null) || focusKeep;
    const lost = !document.activeElement || document.activeElement === document.body; // never steal focus from elsewhere
    if (key && lost) restoreFocusTo(key);
  }

  /** Stable data-focus-key on every action control, so focus survives innerHTML re-renders. */
  function assignFocusKeys() {
    el.querySelectorAll('[data-inv]:not([data-focus-key])').forEach((b) => {
      const d = b.dataset;
      const action = d.inv === 'detail' && b.classList.contains('inv-item-main') ? 'details' : d.inv;
      b.dataset.focusKey = d.id ? `inventory-item:${d.id}:${action}`
        : d.slot ? `slot:${d.slot}:${action}` : d.filter ? `filter:${d.filter}` : d.inv === 'add-item' ? 'add-item-button' : `inventory:${action}`;
    });
  }

  /** Focus the control with this key, else the item row's main button, the Items heading, then Add item. */
  function restoreFocusTo(key) {
    const item = /^inventory-item:([^:]+):/.exec(key)?.[1];
    [key, item && `inventory-item:${item}:details`, 'inventory-heading', 'add-item-button']
      .some((k) => k && focusByKey(k, el));
  }

  // Inventory summary (v6): four metric cards with one shared anatomy (icon, label, prominent value, short note). Coins keep
  // every denomination: the largest one is the value, the others are listed below it; Edit jumps to the Coins section.
  function summaryHTML() {
    const c = opts.getCharacter?.() || {};
    const held = ['pp', 'gp', 'ep', 'sp', 'cp'].filter((k) => Number(c[k]) > 0);
    const a = s.attunement || { attuned_count: 0, attunement_limit: 3 };
    const w = s.weight || { stacks: 0, pieces: 0, total_weight_lb: 0 };
    const [wNum, wUnit] = (() => { const t = fmtWeight(w.total_weight_lb); const i = t.lastIndexOf(' '); return i > 0 ? [t.slice(0, i), t.slice(i + 1)] : [t, '']; })();
    const free = a.attunement_limit - a.attuned_count;
    const card = (cls, ic, label, value, note, extra = '') => `
        <div class="inv-metric ${cls}" role="group" aria-label="${esc(label)}">
          <span class="inv-metric-icon" aria-hidden="true">${icon(ic, { size: 28 })}</span>
          <span class="inv-metric-label">${esc(label)}</span>
          <span class="inv-metric-value">${value}</span>
          <span class="inv-metric-note">${note}</span>${extra}
        </div>`;
    return `
      <section class="inv-summary" aria-label="Inventory summary">
        ${card('inv-m-items', 'section.inventory', 'Items', `<b class="inv-metric-num">${w.stacks || 0}</b>`, esc(plural(w.pieces || 0, 'piece', 'pieces')))}
        ${card('inv-m-weight', 'item.gear', 'Weight', `<b class="inv-metric-num">${esc(wNum)}</b>${wUnit ? `<span class="inv-metric-unit">${esc(wUnit)}</span>` : ''}`, 'carried')}
        ${card(`inv-m-attuned${free < 0 ? ' is-over' : ''}`, 'item.magic', 'Attuned', `<b class="inv-metric-num">${a.attuned_count}<span class="inv-metric-sep">/</span>${a.attunement_limit}</b>`,
          free < 0 ? `${-free} over the limit` : free === 0 ? 'limit reached' : `${free} slot${free === 1 ? '' : 's'} free`,
          `<button type="button" class="inv-metric-action" data-inv="attuned-list">Show</button>`)}
        ${card('inv-m-coins', 'section.coins', 'Coins', held.length ? `<b class="inv-metric-num">${esc(c[held[0]])}</b><span class="inv-metric-unit">${held[0]}</span>` : '<b class="inv-metric-num">0</b><span class="inv-metric-unit">gp</span>',
          held.length > 1 ? esc(held.slice(1).map((k) => `${c[k]} ${k}`).join(' · ')) : held.length ? 'all coins' : 'no coins',
          `<button type="button" class="inv-metric-action" data-inv="edit-coins">Edit</button>`)}
      </section>`;
  }

  function equipmentHTML() {
    const slots = s.lookups?.slots || [];
    const used = slots.filter((x) => occupant(x.id));
    const empty = slots.filter((x) => !occupant(x.id));
    return `
      <section class="tl-section inv-equipment" aria-label="Equipped">
        <details class="inv-eq" ${s.eqOpen ? 'open' : ''}>
          <summary>${sectionHead({ icon: 'section.equipped', title: 'Equipped', desc: `${used.length} of ${slots.length} slots in use` })}</summary>
          ${used.length ? '' : '<p class="empty">Nothing equipped yet. Equip armor, weapons and magic items from your items, or choose a slot below.</p>'}
          <div class="inv-slots">${used.map(slotHTML).join('')}</div>
          ${empty.length ? `<details class="inv-empty-slots" ${s.emptyOpen ? 'open' : ''}><summary>Empty slots <span class="count">${empty.length}</span></summary>
            <div class="inv-slots">${empty.map(slotHTML).join('')}</div></details>` : ''}
        </details>
      </section>`;
  }

  // ---- smaller sections beside the item list: shown only when they have something in them --------------------------
  const sideRow = (r, extra, actions) => `<li class="inv-side-row">
      ${icon(itemIcon(r, ui), { size: 22 })}<span class="inv-side-name">${esc(r.display_name || 'Unnamed item')}${extra ? ` <span class="muted small">${extra}</span>` : ''}</span>
      <span class="inv-side-actions">${actions}</span></li>`;

  function attunementHTML() {
    const list = s.rows.filter((r) => r.requires_attunement && !isLegacy(r));
    if (!list.length) return '';
    const a = s.attunement || { attuned_count: 0, attunement_limit: 3 };
    const sorted = [...list].sort((x, y) => Number(!!y.is_attuned) - Number(!!x.is_attuned));
    return `<section class="tl-section inv-attunement" aria-labelledby="inv-attune-title">
      ${sectionHead({ id: 'inv-attune-title', icon: 'section.attunement', title: 'Attunement', count: `${a.attuned_count} / ${a.attunement_limit}` })}
      <ul class="inv-side-list">${sorted.map((r) => sideRow(r, esc(r.is_attuned ? 'Attuned' : 'Not attuned'),
        `<button type="button" class="btn btn-sm btn-ghost" data-inv="detail" data-id="${r.id}" data-focus-key="attune:${r.id}">Details</button>`)).join('')}</ul>
    </section>`;
  }

  function quickUseHTML() {
    const list = s.rows.filter((r) => r.is_consumable && !isLegacy(r) && r.quantity > 0);
    if (!list.length) return '';
    return `<section class="tl-section inv-quick-use" aria-labelledby="inv-quick-title">
      ${sectionHead({ id: 'inv-quick-title', icon: 'section.quick-use', title: 'Quick use', count: list.length })}
      <ul class="inv-side-list">${list.map((r) => sideRow(r, `×${r.quantity}`,
        `<button type="button" class="btn btn-sm btn-good" data-inv="use" data-id="${r.id}" data-focus-key="quick:${r.id}:use" ${busy(r.id)}>${s.busy.has(r.id) ? 'Using…' : 'Use'}</button>`)).join('')}</ul>
    </section>`;
  }

  function containersHTML() {
    const list = s.rows.filter((r) => isContainer(r) && !isLegacy(r));
    if (!list.length) return '';
    return `<section class="tl-section inv-containers" aria-labelledby="inv-cont-title">
      ${sectionHead({ id: 'inv-cont-title', icon: 'section.containers', title: 'Containers', count: list.length })}
      <ul class="inv-side-list">${list.map((r) => {
        const c = s.containers.get(r.id);
        const inside = c ? `${plural(c.items_inside || 0, 'item', 'items')}, ${fmtWeight(c.contents_weight_lb || 0)}${c.over_capacity ? ' · over capacity' : ''}` : '';
        return sideRow(r, esc(inside), `<button type="button" class="btn btn-sm btn-ghost" data-inv="show-row" data-id="${r.id}" data-focus-key="container:${r.id}">Show</button>`);
      }).join('')}</ul>
    </section>`;
  }

  function legacyHTML() {
    const list = s.rows.filter(isLegacy);
    if (!list.length) return '';
    return `<section class="tl-section tl-section-warn inv-legacy" aria-labelledby="inv-legacy-title">
      ${sectionHead({ id: 'inv-legacy-title', icon: 'section.legacy', title: 'Old sheet items', count: list.length,
        desc: 'Written on the old sheet and not linked to the item catalog yet. Review each one to link or convert it.' })}
      <ul class="inv-side-list">${list.map((r) => sideRow(r, '',
        `<button type="button" class="btn btn-sm btn-ghost" data-inv="detail" data-id="${r.id}" data-focus-key="legacy:${r.id}">Review…</button>`)).join('')}</ul>
    </section>`;
  }

  /** Short text notes from the derived stats (proficiency, Strength, Stealth) for one equipped item. */
  function slotNotes(inventoryItemId) {
    const notes = (opts.getEquipmentNotes?.(inventoryItemId) || []);
    return notes.length ? `<span class="inv-slot-note">${notes.map(esc).join(' · ')}</span>` : '';
  }

  function slotHTML(slot) {
    const o = occupant(slot.id);
    const key = `slot:${slot.id}`;
    return `
      <div class="inv-slot ${o ? 'filled' : ''}">
        <button type="button" class="inv-slot-main" data-inv="slot" data-slot="${slot.id}">
          <span class="inv-slot-icon" aria-hidden="true">${icon(SLOT_ICONS[slot.id] || 'ui/inventory', { size: 26 })}</span>
          <span class="inv-slot-text"><span class="inv-slot-name">${esc(slot.name)}</span>
            <span class="inv-slot-item">${o ? esc(o.display_name) : '<em>Empty</em>'}</span>
            ${o ? slotNotes(o.id) : ''}</span>
        </button>
        <div class="inv-slot-actions">
          <button type="button" class="btn btn-sm" data-inv="slot-equip" data-slot="${slot.id}" ${busy(key)}>${o ? 'Change' : 'Equip'}</button>
          ${o ? `<button type="button" class="btn btn-sm btn-ghost" data-inv="slot-unequip" data-slot="${slot.id}" ${busy(key)}>Unequip</button>` : ''}
        </div>
      </div>`;
  }

  function listSectionHTML() {
    const counts = Object.fromEntries(CATEGORIES.map(([k, , fn]) => [k, s.rows.filter((r) => fn(r, ui)).length]));
    const [, label, fn] = CATEGORIES.find(([k]) => k === s.filter) || CATEGORIES[0];
    let body;
    if (!s.rows.length) {
      body = '<div class="inv-empty"><p>This character has no items yet.</p><p class="muted">Add an item from the catalog to get started.</p></div>';
    } else if (s.filter === 'all') {
      const ids = new Set(s.rows.map((r) => r.id));
      body = s.rows.filter((r) => !r.container_item_id || !ids.has(r.container_item_id)).map((r) => itemHTML(r, 0)).join('');
    } else {
      const list = s.rows.filter((r) => fn(r, ui));
      body = list.length ? list.map((r) => itemHTML(r, -1)).join('') : `<p class="empty">No ${esc(label.toLowerCase())} in this inventory.</p>`;
    }
    return `
      <section class="tl-section inv-main" aria-labelledby="inv-items-title">
        <div class="tl-section-head">
          <h2 class="tl-section-title" id="inv-items-title" tabindex="-1" data-focus-key="inventory-heading">${icon('section.inventory', { size: 22, cls: 'tl-section-icon' })}<span>Items you carry</span><span class="tl-count">${s.rows.length}</span></h2>
          <p class="tl-section-desc">Everything in this inventory, equipped or not. Containers show what is inside them.</p>
          <div class="tl-section-action inv-head-actions">
            <button type="button" class="btn btn-gold btn-sm" data-inv="add-item">+ Add item</button>
          </div>
        </div>
        <div class="inv-filters" role="tablist" aria-label="Item categories">
          ${CATEGORIES.map(([k, l]) => `<button type="button" role="tab" class="inv-chip" data-inv="filter" data-filter="${k}" aria-selected="${s.filter === k}">${icon(ITEM_ICONS[k] || 'ui/inventory', { size: 18 })}${l}<span class="count">${counts[k]}</span></button>`).join('')}
        </div>
        <div class="inv-list">${body}</div>
      </section>`;
  }

  function badgesHTML(r) {
    const d = detail(r);
    const b = [];
    if (r.equipped) b.push(`<span class="badge inv-b-equipped">Equipped · ${esc(slotName(r.equipped_slot))}</span>`);
    if (r.is_attuned) b.push('<span class="badge inv-b-attuned">Attuned</span>');
    else if (r.requires_attunement) b.push('<span class="badge">Attunement</span>');
    if (r.is_magic) b.push(`<span class="badge inv-b-magic inv-r-${esc(r.rarity_id || '')}">${esc(rarityName(r.rarity_id) || 'Magic')}</span>`);
    if (isLegacy(r)) b.push('<span class="badge inv-b-legacy" title="From the old sheet; not linked to an item definition yet">Old sheet item</span>');
    b.push(sourceBadge(d));
    if (d?.archived_at) b.push('<span class="badge inv-b-archived" title="The homebrew definition is archived; this entry still works">Archived definition</span>');
    if (needsEquipReview(r)) b.push('<span class="badge inv-b-warn">Check where it is equipped</span>');
    if (isLegacy(r) && r.quantity === 0) b.push('<span class="badge inv-b-warn">Quantity 0 (legacy)</span>');
    if (isContainer(r)) b.push('<span class="badge">Container</span>');
    if (d?.weightless_contents) b.push('<span class="badge" title="Contents do not count toward carried weight">Weightless</span>');
    if (s.containers.get(r.id)?.over_capacity) b.push('<span class="badge inv-b-warn">Over capacity</span>');
    if (r.is_quest_item) b.push('<span class="badge">Quest item</span>');
    if (r.modifier_ids?.length) b.push(...r.modifier_ids.map((m) => `<span class="badge inv-b-magic">${esc(m.replace(/-plus-/, ' +').replace(/^\w/, (c) => c.toUpperCase()))}</span>`));
    return b.filter(Boolean).join(' ');
  }

  function metaText(r) {
    if (isLegacy(r)) return [r.unit_weight_lb ? `${fmtWeight(r.unit_weight_lb)} each` : '', r.description ? r.description.slice(0, 80) : ''].filter(Boolean).join(' · ');
    const parent = r.container_item_id ? rowById(r.container_item_id) : null;
    const w = detail(r)?.weight_lb; // null = the catalog does not know the weight (not 0 lb)
    return [kindName(r.kind_id), categoryName(r.category_id), w != null ? `${fmtWeight(w)} each` : 'weight unknown',
      s.filter !== 'all' && parent ? `in ${parent.display_name}` : ''].filter(Boolean).join(' · ');
  }

  function itemHTML(r, depth) {
    const amm = ammoInfo(r);
    const cont = s.containers.get(r.id);
    const slots = compatibleSlots(r);
    const rb = busy(r.id);
    const qty = canStack(r)
      ? `<div class="inv-qty" aria-label="Quantity">
           <button type="button" class="step" data-inv="dec" data-id="${r.id}" ${rb} aria-label="${r.quantity === 1 ? 'Remove the last one' : 'One less'}" title="${r.quantity === 1 ? 'Remove the last one' : 'One less'}">−</button>
           <span class="inv-qty-n">${r.quantity}</span>
           <button type="button" class="step" data-inv="inc" data-id="${r.id}" ${rb} aria-label="One more">+</button>
         </div>`
      : `<div class="inv-qty"><span class="inv-qty-n">×${r.quantity}</span></div>`;
    const quick = [];
    if (r.equipped) quick.push(`<button type="button" class="btn btn-sm" data-inv="unequip" data-id="${r.id}" ${rb}>Unequip</button>`);
    else if (slots.length) quick.push(`<button type="button" class="btn btn-sm" data-inv="equip" data-id="${r.id}" ${rb}>${needsEquipReview(r) ? 'Equip…' : 'Equip'}</button>`);
    if (r.is_consumable && !isLegacy(r)) quick.push(`<button type="button" class="btn btn-sm btn-good" data-inv="use" data-id="${r.id}" ${rb}>${s.busy.has(r.id) ? 'Using…' : 'Use'}</button>`);
    if (isLegacy(r)) quick.push(`<button type="button" class="btn btn-sm btn-ghost" data-inv="detail" data-id="${r.id}">Review…</button>`);
    if (needsEquipReview(r) && !slots.length) quick.push(`<button type="button" class="btn btn-sm btn-ghost" data-inv="not-equipped" data-id="${r.id}" ${rb}>Not equipped</button>`);
    const children = depth >= 0 ? s.rows.filter((x) => x.container_item_id === r.id) : [];
    return `
      <article class="inv-item ${isLegacy(r) ? 'legacy' : ''} ${r.equipped ? 'equipped' : ''}" data-row="${r.id}" style="--depth:${Math.max(depth, 0)}">
        <div class="inv-item-row">
          <button type="button" class="inv-item-main" data-inv="detail" data-id="${r.id}">
            ${icon(itemIcon(r, ui), { size: 30, cls: 'inv-item-icon' })}
            <span class="inv-item-name">${esc(r.display_name || 'Unnamed item')}</span>
            <span class="inv-item-badges">${badgesHTML(r)}</span>
            <span class="inv-item-meta">${esc(metaText(r))}</span>
          </button>
          ${qty}
        </div>
        ${quick.length ? `<div class="inv-quick">${quick.join('')}</div>` : ''}
        ${amm ? ammoHTML(amm) : ''}
        ${cont && (cont.items_inside || cont.capacity_weight_lb != null) ? containerLineHTML(cont) : ''}
        ${children.length && depth < 8 ? `<div class="inv-children">${children.map((c) => itemHTML(c, depth + 1)).join('')}</div>` : ''}
      </article>`;
  }

  function ammoHTML(a) {
    if (a.unknown) return '<p class="inv-note warn">Uses ammunition, but its type is not in the catalog data.</p>';
    if (!a.total) return `<p class="inv-note warn">No compatible ammunition (${esc(a.typeName)}) in this inventory.</p>`;
    return `<p class="inv-note ${a.total < LOW_AMMO ? 'warn' : ''}">Ammunition: ${esc(a.typeName)} ×${a.total}${a.total < LOW_AMMO ? ' — running low' : ''}
      <button type="button" class="btn-link" data-inv="show-row" data-id="${a.stacks[0].id}">Show</button></p>`;
  }

  function containerLineHTML(c) {
    const cap = c.capacity_weight_lb != null ? ` / ${fmtWeight(c.capacity_weight_lb)}` : '';
    const warn = c.over_capacity ? ' — over capacity' : '';
    const nest = c.extradimensional_nesting ? ' — an extradimensional container inside another one is dangerous' : '';
    return `<p class="inv-note ${c.over_capacity || c.extradimensional_nesting ? 'warn' : ''}">Contents: ${plural(c.items_inside, 'item', 'items')}, ${fmtWeight(c.contents_weight_lb)}${cap}${c.weightless_contents ? ' (weightless)' : ''}${warn}${nest}</p>`;
  }

  // ---- actions --------------------------------------------------------------------------------------------
  async function changeQty(r, delta) {
    if (delta < 0 && r.quantity <= 1) {
      const ok = await confirmDialog(`Remove “${r.display_name}”? This is the last one.`, { okLabel: 'Remove', danger: true });
      if (!ok) return;
      await act(r.id, async () => { await api.removeInventoryItem(r.id, null); toast(`Removed ${r.display_name}.`); });
      return;
    }
    if (delta < 0) {
      await act(r.id, () => api.removeInventoryItem(r.id, 1));
    } else if (canStack(r)) {
      await act(r.id, () => api.setInventoryItemQuantity(r.id, r.quantity + 1));
    } else {
      await act(r.id, async () => { await api.addInventoryItem(s.inventoryId, r.item_id, 1); toast(`Added another ${r.display_name}.`, 'good'); });
    }
  }

  async function equip(r, slot, replace) {
    const res = await act(r.id, () => api.equipInventoryItem(r.id, slot.id, { replace }));
    if (res) toast(`Equipped ${r.display_name} (${slot.name})${res.split_from ? ' — one piece was taken from the stack' : ''}.`, 'good');
  }

  async function equipFlow(r) {
    if (isLegacy(r)) { toast('Link this legacy item or convert it to homebrew first.', 'bad'); return; }
    if (needsEquipReview(r)) { openEquipReview(r); return; }
    const slots = compatibleSlots(r);
    if (!slots.length) { toast('This item cannot be equipped.', 'bad'); return; }
    if (slots.length === 1) {
      const slot = slots[0];
      const o = occupant(slot.id);
      if (o && !(await confirmDialog(`${slot.name} holds ${o.display_name}. Replace it with ${r.display_name}?`, { okLabel: 'Replace' }))) return;
      await equip(r, slot, !!o);
      return;
    }
    chooseSlot(r, slots);
  }

  function chooseSlot(r, slots) {
    const m = openModal({
      title: `Equip ${r.display_name}`,
      body: `<p class="muted">Choose a slot.</p><div class="inv-pick">${slots.map((x) => {
        const o = occupant(x.id);
        return `<button type="button" class="inv-pick-item" data-slot="${x.id}"><b>${esc(x.name)}</b><span class="muted">${o ? `replaces ${esc(o.display_name)}` : 'empty'}</span></button>`;
      }).join('')}</div>`,
    });
    m.body.addEventListener('click', async (e) => {
      const b = e.target.closest('[data-slot]');
      if (!b) return;
      const slot = slots.find((x) => x.id === b.dataset.slot);
      m.close();
      await equip(r, slot, !!occupant(slot.id));
    });
  }

  function openSlot(slotId) {
    const slot = s.lookups.slots.find((x) => x.id === slotId);
    const o = occupant(slotId);
    if (!o) { openSlotPicker(slot); return; }
    const m = openModal({
      title: slot.name,
      body: `<p><b>${esc(o.display_name)}</b></p><p class="muted">${esc(o.kind_id ? `${kindName(o.kind_id)} · ${categoryName(o.category_id)}` : '')}</p>`,
      footer: `<button type="button" class="btn" data-x="detail">Details</button>
        <button type="button" class="btn" data-x="replace">Replace</button>
        <button type="button" class="btn btn-gold" data-x="unequip">Unequip</button>`,
    });
    m.footer.addEventListener('click', (e) => {
      const x = e.target.closest('[data-x]')?.dataset.x;
      if (!x) return;
      m.close();
      if (x === 'detail') openDetail(o.id);
      if (x === 'replace') openSlotPicker(slot);
      if (x === 'unequip') act(`slot:${slotId}`, async () => { await api.unequipInventoryItem(o.id); toast(`Unequipped ${o.display_name}.`); });
    });
  }

  function openSlotPicker(slot) {
    const current = occupant(slot.id);
    const candidates = s.rows.filter((r) => r.id !== current?.id && compatibleSlots(r).some((x) => x.id === slot.id));
    const m = openModal({
      title: `${current ? 'Replace' : 'Equip'}: ${slot.name}`,
      body: candidates.length
        ? `<div class="inv-pick">${candidates.map((r) => `<button type="button" class="inv-pick-item" data-id="${r.id}">
            <b>${esc(r.display_name)}</b><span class="muted">${r.quantity > 1 ? `×${r.quantity} — one piece will be equipped` : ''}${r.equipped ? ` currently in ${esc(slotName(r.equipped_slot))} — it will move` : ''}</span></button>`).join('')}</div>`
        : `<p class="empty">No item in this character’s inventory fits the ${esc(slot.name)} slot.</p>`,
    });
    m.body.addEventListener('click', async (e) => {
      const b = e.target.closest('[data-id]');
      if (!b) return;
      const r = rowById(b.dataset.id);
      m.close();
      await equip(r, slot, !!current);
    });
  }

  async function doUse(r) {
    const res = await act(r.id, () => api.useInventoryItem(r.id));
    if (!res) return;
    const lines = (res.effects || []).map((fx) => {
      const amount = [fx.dice_expression, fx.flat_value ? `${fx.flat_value}` : ''].filter(Boolean).join(' + ');
      const label = fx.effect_type.replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());
      return `<li><b>${esc(label)}${amount ? `: ${esc(amount)}` : ''}</b>${fx.damage_type_id ? ` ${esc(fx.damage_type_id)}` : ''}${fx.duration ? ` · ${esc(fx.duration)}` : ''}</li>`;
    }).join('');
    const spell = res.state?.spell ? `<p>Scroll: <b>${esc(res.state.spell)}</b>${res.state.level != null ? ` (level ${esc(res.state.level)})` : ''}. The spell is not cast automatically.</p>` : '';
    const left = res.consumed
      ? (res.deleted ? '<p class="muted">That was the last one; it was removed from the inventory.</p>' : `<p class="muted">${res.remaining} left.</p>`)
      : '<p class="muted">Nothing was used up: this item is not consumable.</p>';
    openModal({
      title: res.consumed ? `Used: ${res.name}` : res.name,
      body: `${lines ? `<ul class="inv-effects">${lines}</ul>` : (res.consumed && !spell ? '<p>No automatic effect.</p>' : '')}${spell}
        ${lines.includes('Healing') ? '<p class="muted small">Hit points are not changed automatically. Roll the dice and apply the healing on the combat bar.</p>' : ''}${left}`,
      footer: '<button type="button" class="btn btn-gold" data-close>OK</button>',
    });
  }

  function openAttunedList() {
    const list = s.rows.filter((r) => r.is_attuned);
    const a = s.attunement || { attuned_count: 0, attunement_limit: 3 };
    const m = openModal({
      title: `Attuned items (${a.attuned_count} / ${a.attunement_limit})`,
      body: list.length
        ? `<div class="inv-pick">${list.map((r) => `<div class="inv-pick-item"><b>${esc(r.display_name)}</b>
            <button type="button" class="btn btn-sm" data-id="${r.id}">End attunement</button></div>`).join('')}</div>`
        : '<p class="empty">No item is attuned. Attune from an item’s details.</p>',
    });
    m.body.addEventListener('click', async (e) => {
      const b = e.target.closest('button[data-id]');
      if (!b) return;
      const r = rowById(b.dataset.id);
      m.close();
      await act(r.id, async () => { await api.unattuneInventoryItem(r.id); toast(`Attunement to ${r.display_name} ended.`); });
    });
  }

  async function attune(r) {
    const a = s.attunement;
    if (a && a.attuned_count >= a.attunement_limit) {
      toast('This character is already attuned to 3 items. End an attunement first.', 'bad', 4500);
      openAttunedList();
      return;
    }
    const res = await act(r.id, () => api.attuneInventoryItem(r.id));
    if (res) toast(`Attuned to ${r.display_name}.`, 'good');
  }

  function highlight(id) {
    if (!rowById(id)) return;
    s.filter = 'all';
    render();
    const card = $(`[data-row="${id}"]`, el);
    card?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    card?.classList.add('flash');
    setTimeout(() => card?.classList.remove('flash'), 1400);
  }

  // ---- item detail -------------------------------------------------------------------------------------------
  function propsHTML(r) {
    const d = detail(r);
    if (!d) return '';
    const rows = [
      ['Type', [d.kind_name, d.category_name].filter(Boolean).join(' · ')],
      ['Rarity', d.is_magic ? rarityName(d.rarity_id) : ''],
      ['Attunement', d.requires_attunement ? 'required' : ''],
      ['Weight', d.weight_lb != null ? fmtWeight(d.weight_lb) : ''],
      ['Cost', d.cost_value != null ? `${d.cost_value} ${d.cost_unit}` : ''],
      ['Damage', d.damage_dice ? `${d.damage_dice} ${d.damage_type_id || ''}${d.versatile_damage ? ` (versatile ${d.versatile_damage})` : ''}` : ''],
      ['Range', d.range_normal ? `${d.range_normal}/${d.range_max} ft${d.range_type ? ` (${d.range_type})` : ''}` : ''],
      ['Properties', (d.weapon_properties || []).join(', ')],
      ['Firearm', d.reload ? `reload ${d.reload}, misfire ${d.misfire}` : ''],
      ['Armor class', d.base_ac != null ? `${d.base_ac}${d.dex_modifier_mode === 'full' ? ' + Dex' : d.dex_modifier_mode === 'capped' ? ` + Dex (max ${d.dex_cap})` : ''}` : d.ac_bonus != null ? `+${d.ac_bonus}` : ''],
      ['Strength', d.strength_requirement ? `${d.strength_requirement}+` : ''],
      ['Stealth', d.stealth_disadvantage ? 'disadvantage' : ''],
      ['Capacity', [d.capacity_weight_lb != null ? fmtWeight(d.capacity_weight_lb) : '', d.capacity_volume_cuft != null ? `${d.capacity_volume_cuft} cu ft` : '', d.weightless_contents ? 'weightless contents' : ''].filter(Boolean).join(', ')],
      ['Pack', d.pack_size ? `${d.pack_size} per pack` : ''],
      ['Source', d.source_book_name || d.source_label || ''],
    ].filter(([, v]) => v);
    return `<dl class="inv-props">${rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl>`;
  }

  function openDetail(id) {
    const r = rowById(id);
    if (!r) return;
    if (isLegacy(r)) { openLegacyDetail(r); return; }
    const d = detail(r);
    const homebrew = !!d && d.visibility !== 'official';
    const slots = compatibleSlots(r);
    const cont = s.containers.get(r.id);
    const exclude = descendants(r.id).add(r.id);
    const containers = s.rows.filter((x) => isContainer(x) && !exclude.has(x.id));
    const actions = [];
    if (r.equipped) actions.push('<button type="button" class="btn" data-x="unequip">Unequip</button>');
    else if (slots.length) actions.push('<button type="button" class="btn" data-x="equip">Equip</button>');
    if (needsEquipReview(r)) actions.push('<button type="button" class="btn" data-x="not-equipped">Not equipped</button>');
    if (r.requires_attunement) actions.push(`<button type="button" class="btn" data-x="${r.is_attuned ? 'unattune' : 'attune'}">${r.is_attuned ? 'End attunement' : 'Attune'}</button>`);
    if (r.is_consumable) actions.push('<button type="button" class="btn btn-good" data-x="use">Use</button>');
    actions.push('<button type="button" class="btn btn-bad" data-x="remove">Remove</button>');
    const definition = homebrew ? `
        <section class="inv-def" aria-label="Homebrew definition">
          <h4>Homebrew item</h4>
          <p class="muted small">${d.visibility === 'campaign' ? 'Shared with the campaign.' : 'Private: only you can see it.'}
            Changes to the definition affect every inventory entry that uses it.</p>
          ${d.archived_at ? `<p class="inv-note">${icon('ui.incomplete', { size: 16 })}Archived definition: it cannot be added again, but this entry keeps working.</p>` : ''}
          ${d.can_edit && isAnyDM() ? `<div class="inv-form-row">
            ${d.archived_at ? '<button type="button" class="btn btn-sm" data-x="restore-def">Restore definition</button>'
              : `<button type="button" class="btn btn-sm" data-x="edit-def">Edit homebrew definition</button>
                 <button type="button" class="btn btn-sm" data-x="archive-def">Archive definition</button>`}
          </div>` : ''}
        </section>` : '';

    const m = openModal({
      title: r.display_name || 'Item',
      wide: true,
      body: `
        <div class="inv-detail-badges">${badgesHTML(r)}</div>
        ${r.custom_name ? `<p class="muted small">Custom name of <b>${esc(r.name)}</b>.</p>` : ''}
        ${propsHTML(r)}
        ${d?.description ? `<p class="inv-desc">${esc(d.description)}</p>` : ''}
        ${definition}
        ${reviewOf(r).map((x) => `<p class="inv-note warn">${esc(reviewText(x))}</p>`).join('')}
        ${cont ? containerLineHTML(cont) : ''}
        <form class="inv-form" data-form="qty">
          <h4>Quantity: ${r.quantity}</h4>
          <div class="inv-form-row">
            <input type="number" name="n" min="1" step="1" inputmode="numeric" value="1" aria-label="Number of pieces">
            ${canStack(r) ? '<button type="submit" class="btn btn-sm" data-q="set">Set to</button>' : ''}
            <button type="submit" class="btn btn-sm" data-q="add">Add</button>
            <button type="submit" class="btn btn-sm" data-q="remove">Remove</button>
          </div>
        </form>
        <form class="inv-form" data-form="text">
          <h4>Edit this item</h4>
          <p class="muted small">Only this inventory entry changes, not the item definition.</p>
          <label class="field"><span>Custom name</span><input type="text" name="custom_name" value="${esc(r.custom_name || '')}" maxlength="120" placeholder="${esc(r.name)}"></label>
          <label class="field"><span>Personal notes</span><textarea name="notes" rows="2" maxlength="4000">${esc(r.notes || '')}</textarea></label>
          <label class="hb-inline"><input type="checkbox" name="is_quest_item" ${r.is_quest_item ? 'checked' : ''}> Quest item</label>
          <div class="inv-form-row"><button type="submit" class="btn btn-sm">Save</button></div>
        </form>
        ${containers.length || r.container_item_id ? `
        <form class="inv-form" data-form="move">
          <h4>Container</h4>
          <div class="inv-form-row">
            <select name="container" aria-label="Container">
              <option value="">Not in a container</option>
              ${containers.map((c) => `<option value="${c.id}" ${c.id === r.container_item_id ? 'selected' : ''}>${esc(c.display_name)}</option>`).join('')}
            </select>
            <button type="submit" class="btn btn-sm">Move</button>
          </div>
        </form>` : ''}`,
      footer: actions.join(''),
    });

    m.el.addEventListener('click', async (e) => {
      const x = e.target.closest('[data-x]')?.dataset.x;
      if (!x) return;
      if (x === 'remove') {
        const ok = await confirmDialog(`Remove “${r.display_name}”${r.quantity > 1 ? ` (all ${r.quantity})` : ''} from the inventory?`, { okLabel: 'Remove', danger: true });
        if (!ok) return;
        m.close();
        await act(r.id, async () => { await api.removeInventoryItem(r.id, null); toast(`Removed ${r.display_name}.`); });
        return;
      }
      m.close();
      if (x === 'equip') equipFlow(r);
      if (x === 'unequip') act(r.id, async () => { await api.unequipInventoryItem(r.id); toast(`Unequipped ${r.display_name}.`); });
      if (x === 'not-equipped') notEquipped(r);
      if (x === 'attune') attune(r);
      if (x === 'unattune') act(r.id, async () => { await api.unattuneInventoryItem(r.id); toast(`Attunement to ${r.display_name} ended.`); });
      if (x === 'use') doUse(r);
      if (x === 'edit-def') openEditDefinition(r);
      if (x === 'archive-def') archiveDefinition(r);
      if (x === 'restore-def') act(r.id, async () => { await api.restoreHomebrewItem(d.id); toast(`Restored ${d.name}.`, 'good'); });
    });

    m.body.addEventListener('submit', async (e) => {
      e.preventDefault();
      const form = e.target;
      if (form.dataset.form === 'qty') {
        const n = api.parseQuantity(form.elements.n.value);
        if (n == null) { toast('Enter a whole number of at least 1.', 'bad'); return; }
        const mode = e.submitter?.dataset.q || 'add';
        if (mode === 'remove' && n >= r.quantity) {
          const ok = await confirmDialog(`Remove all ${r.quantity} × ${r.display_name}?`, { okLabel: 'Remove', danger: true });
          if (!ok) return;
        }
        m.close();
        await act(r.id, async () => {
          if (mode === 'set') await api.setInventoryItemQuantity(r.id, n);
          else if (mode === 'remove') await api.removeInventoryItem(r.id, Math.min(n, r.quantity));
          else if (canStack(r)) await api.setInventoryItemQuantity(r.id, r.quantity + n);
          else await api.addInventoryItem(s.inventoryId, r.item_id, n);
          toast('Quantity updated.', 'good');
        });
      } else if (form.dataset.form === 'text') {
        const f = form.elements;
        const details = { custom_name: f.custom_name.value.trim() || null, notes: f.notes.value.trim() ? f.notes.value : null, is_quest_item: f.is_quest_item.checked };
        m.close();
        await act(r.id, async () => { await api.updateInventoryItemDetails(r.id, details); toast('Saved.', 'good'); });
      } else if (form.dataset.form === 'move') {
        const target = form.elements.container.value || null;
        m.close();
        await act(r.id, async () => {
          await api.moveInventoryItem(r.id, target);
          toast(target ? `Moved into ${rowById(target)?.display_name || 'the container'}.` : 'Taken out of the container.', 'good');
        });
      }
    });
  }

  // ---- legacy items: read-only until linked or converted ----------------------------------------------------------
  function openLegacyDetail(r) {
    const reviews = reviewOf(r);
    const m = openModal({
      title: r.display_name || r.name || 'Legacy item',
      wide: true,
      body: `
        <div class="inv-detail-badges">${badgesHTML(r)}</div>
        <p class="inv-note warn" role="note">Legacy item from the old sheet. It is not linked to an item definition, so it cannot be
          equipped, used or stacked. Link it to an existing item, or convert it into a homebrew item.</p>
        <dl class="inv-props">
          <dt>Name</dt><dd>${esc(r.name)}</dd>
          <dt>Quantity</dt><dd>${r.quantity}</dd>
          <dt>Weight</dt><dd>${r.unit_weight_lb ? `${fmtWeight(r.unit_weight_lb)} each` : '—'}</dd>
          ${r.description ? `<dt>Description</dt><dd class="inv-pre">${esc(r.description)}</dd>` : ''}
          ${r.notes ? `<dt>Personal notes</dt><dd class="inv-pre">${esc(r.notes)}</dd>` : ''}
        </dl>
        ${reviews.map((x) => `<p class="inv-note warn">${esc(reviewText(x))}</p>`).join('')}
        ${r.quantity > 0 ? '<section class="inv-link" data-link aria-live="polite"><h4>Link to an existing item</h4><p class="muted">Looking for matching items…</p></section>' : ''}`,
      footer: `
        ${needsEquipReview(r) ? '<button type="button" class="btn" data-x="not-equipped">Not equipped</button>' : ''}
        ${r.quantity > 0 && isAnyDM() ? '<button type="button" class="btn" data-x="convert">Convert to homebrew…</button>' : ''}
        <button type="button" class="btn btn-bad" data-x="remove">Remove</button>`,
    });
    if (r.quantity > 0) fillLinkCandidates(r, $('[data-link]', m.el));
    m.el.addEventListener('click', async (e) => {
      const cmp = e.target.closest('[data-compare]');
      if (cmp) { m.close(); openLinkPreview(r, cmp.dataset.compare); return; }
      if (e.target.closest('[data-link-search]')) { m.close(); openCatalogPicker({ linkRow: r }); return; }
      const x = e.target.closest('[data-x]')?.dataset.x;
      if (x === 'remove') {
        const ok = await confirmDialog(`Remove the legacy item “${r.display_name}”${r.quantity > 1 ? ` (all ${r.quantity})` : ''}? This cannot be undone.`, { okLabel: 'Remove', danger: true });
        if (!ok) return;
        m.close();
        await act(r.id, async () => { await api.removeInventoryItem(r.id, null); toast(`Removed ${r.display_name}.`); });
      }
      if (x === 'not-equipped') { m.close(); notEquipped(r); }
      if (x === 'convert') { m.close(); openConvert(r); }
    });
  }

  async function fillLinkCandidates(r, box) {
    const head = '<h4>Link to an existing item</h4>';
    const search = '<button type="button" class="btn btn-sm" data-link-search>Search the catalog…</button>';
    try {
      const list = (await api.getLinkCandidates(r.id)) || [];
      box.innerHTML = `${head}${list.length
        ? `<p class="muted small">Suggestions are never linked automatically. Compare first.</p>
          <div class="inv-pick">${list.map((c) => `
            <div class="inv-pick-item"><span><b>${esc(c.name)}</b>
              <span class="badge ${c.confidence === 'exact' ? 'inv-b-match' : ''}">${c.confidence === 'exact' ? '✓ Exact name' : '≈ Probable match'}</span>
              ${sourceBadge(c)}
              <span class="muted small">${esc([kindName(c.kind_id), categoryName(c.category_id), c.is_magic ? rarityName(c.rarity_id) : ''].filter(Boolean).join(' · '))}</span></span>
              <button type="button" class="btn btn-sm" data-compare="${esc(c.item_id)}" aria-label="Compare with ${esc(c.name)}">Compare…</button></div>`).join('')}</div>`
        : '<p class="muted">No item with a similar name was found.</p>'}${search}`;
    } catch (raw) {
      box.innerHTML = `${head}<p class="muted">${esc(api.normalizeError(raw).message)}</p>${search}`;
    }
  }

  const FIELD_LABEL = { name: 'Name', description: 'Description', weight: 'Weight (lb)' };
  const showValue = (v) => (v == null || v === '' ? '—' : String(v));

  async function openLinkPreview(r, catalogItemId) {
    let p;
    try { p = await api.previewLink(r.id, catalogItemId); } catch (raw) { toast(api.normalizeError(raw).message, 'bad', 4500); return; }
    const c = p.catalog;
    const changes = (p.changes || []).map((x) => `<tr><th scope="row">${esc(FIELD_LABEL[x.field] || x.field)}</th>
      <td>${esc(showValue(x.legacy))}</td><td>${esc(showValue(x.catalog))}</td><td>${esc(x.result)}</td></tr>`).join('');
    const kept = [`Quantity: ${p.preserved.quantity}`, p.preserved.custom_name ? `Custom name: ${p.preserved.custom_name}` : '',
      p.preserved.notes ? 'Personal notes (including anything moved there)' : '', p.preserved.is_quest_item ? 'Quest item' : ''].filter(Boolean);
    const m = openModal({
      title: `Link “${r.name}”`,
      wide: true,
      body: `
        <p>Link this legacy item to <b>${esc(c.name)}</b> ${sourceBadge(c)}<span class="muted small"> ${esc([kindName(c.kind_id), categoryName(c.category_id)].filter(Boolean).join(' · '))}</span>?
          Nothing changes until you confirm.</p>
        ${changes ? `<div class="inv-table-wrap"><table class="inv-compare"><caption>What changes</caption>
          <thead><tr><th scope="col">Field</th><th scope="col">Legacy item</th><th scope="col">Linked item</th><th scope="col">After linking</th></tr></thead>
          <tbody>${changes}</tbody></table></div>` : '<p class="muted">The name, description and weight match.</p>'}
        <h4>Kept</h4><ul class="inv-kept">${kept.map((k) => `<li>${esc(k)}</li>`).join('')}</ul>
        ${(p.warnings || []).map((w) => `<p class="inv-note warn">${esc(w)}</p>`).join('')}`,
      footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Link</button>',
    });
    $('[data-ok]', m.el).addEventListener('click', async (e) => {
      e.currentTarget.disabled = true;
      m.close();
      const res = await act(r.id, () => api.linkInventoryItem(r.id, catalogItemId));
      if (!res) return;
      toast(`Linked to ${c.name}.`, 'good');
      const linked = rowById(r.id);
      if (res.equipment_review_required && linked) openEquipReview(linked);
    }, { once: true });
  }

  function openEquipReview(r) {
    const slots = compatibleSlots(r);
    const m = openModal({
      title: `Equipment review: ${r.display_name}`,
      body: `<p>This item was equipped in the old sheet. Equip it again, or mark it as not equipped.</p>
        ${slots.length ? `<div class="inv-pick">${slots.map((x) => {
          const o = occupant(x.id);
          return `<button type="button" class="inv-pick-item" data-slot="${x.id}"><b>${esc(x.name)}</b><span class="muted">${o ? `replaces ${esc(o.display_name)}` : 'empty'}</span></button>`;
        }).join('')}</div>` : '<p class="muted">This item does not fit any equipment slot.</p>'}`,
      footer: '<button type="button" class="btn" data-close>Decide later</button><button type="button" class="btn btn-gold" data-not>Not equipped</button>',
    });
    m.el.addEventListener('click', async (e) => {
      const b = e.target.closest('[data-slot]');
      if (b) {
        const slot = slots.find((x) => x.id === b.dataset.slot);
        m.close();
        await equip(r, slot, !!occupant(slot.id));
      } else if (e.target.closest('[data-not]')) {
        m.close();
        await notEquipped(r);
      }
    });
  }

  const notEquipped = (r) => act(r.id, async () => { await api.resolveEquipmentReview(r.id); toast(`${r.display_name}: marked as not equipped.`); });

  // ---- homebrew items ------------------------------------------------------------------------------------------------
  function formDefaults() {
    const c = opts.getCharacter?.() || {};
    return { campaignId: c.campaign_id || '', allowPrivate: !!opts.userId && c.owner_id === opts.userId };
  }
  const campaigns = () => (opts.getCampaigns?.() || []).map((k) => ({ id: k.id, name: k.name }));

  function openCreateHomebrew(name = '') {
    let addedItem = null; // a retry after a lost response must not add the item twice
    openHomebrewForm({
      mode: 'create', lookups: s.lookups, campaigns: campaigns(), defaults: formDefaults(), initial: { item: { name } },
      onSubmit: async (def, stats, requestId) => {
        const item = await api.createHomebrewItem(requestId, def, stats);
        if (addedItem !== item.id) { await api.addInventoryItem(s.inventoryId, item.id, 1); addedItem = item.id; }
        toast(`Created ${item.name} and added it to the inventory.`, 'good');
        await refresh();
      },
    });
  }

  function openConvert(r) {
    openHomebrewForm({
      mode: 'convert', lookups: s.lookups, campaigns: campaigns(), defaults: formDefaults(),
      initial: { item: { name: r.name, description: r.description, weight_lb: r.unit_weight_lb || null, kind_id: 'gear', stackable: r.quantity > 1 } },
      onSubmit: async (def, stats, requestId) => {
        const res = await api.convertLegacyToHomebrew(r.id, requestId, def, stats);
        toast(`${res.item?.name || def.name} is now a homebrew item.`, 'good');
        await refresh();
        const linked = rowById(r.id);
        if (res.link?.equipment_review_required && linked && needsEquipReview(linked)) openEquipReview(linked);
      },
    });
  }

  async function openEditDefinition(r) {
    const d = detail(r);
    let def; let usage = 0;
    try {
      [def, usage] = await Promise.all([api.getHomebrewDefinition(d.id), api.getHomebrewUsage(d.id).catch(() => 0)]);
    } catch (raw) { toast(api.normalizeError(raw).message, 'bad', 4500); return; }
    openHomebrewForm({
      mode: 'edit', lookups: s.lookups, campaigns: campaigns(), defaults: { allowPrivate: true }, initial: def, usageCount: usage,
      onSubmit: async (dd, stats) => {
        await api.updateHomebrewItem(d.id, dd, stats);
        toast('Homebrew definition saved.', 'good');
        await refresh();
      },
    });
  }

  async function archiveDefinition(r) {
    const d = detail(r);
    const usage = await api.getHomebrewUsage(d.id).catch(() => null);
    const msg = usage > 0
      ? `This definition is used by ${usage} inventory ${usage === 1 ? 'entry' : 'entries'}. Archiving hides “${d.name}” from the item picker; existing entries keep working. Archive it?`
      : `Archive “${d.name}”? It will no longer appear in the item picker.`;
    if (!(await confirmDialog(msg, { okLabel: 'Archive', danger: true }))) return;
    await act(r.id, async () => { await api.archiveHomebrewItem(d.id); toast(`Archived ${d.name}.`); });
  }

  // ---- catalog picker -------------------------------------------------------------------------------------------
  function openCatalogPicker({ linkRow = null } = {}) {
    const L = s.lookups;
    const f = { search: linkRow ? linkRow.name : '', kindId: '', categoryId: '', rarityId: '', magic: '', sourceBookId: '', visibility: '' };
    const st = { rows: [], ids: new Set(), total: 0, offset: 0, token: 0, controller: null, loading: false, error: null };
    const opt = (list, sel, label = (x) => x.name) => list.map((x) => `<option value="${esc(x.id)}" ${x.id === sel ? 'selected' : ''}>${esc(label(x))}</option>`).join('');
    const m = openModal({
      title: linkRow ? `Link “${linkRow.name}” to an existing item` : 'Add an item',
      wide: true,
      body: `
        <div class="inv-picker">
          ${linkRow ? '' : isAnyDM() ? `<div class="inv-picker-modes"><span class="muted small">Search the catalog below. Campaign items are created in
            <a href="#/dm/content">DM Space › Content</a>, or</span> <button type="button" class="btn btn-sm" data-create>+ Quick private item</button></div>`
            : '<p class="muted small inv-picker-modes">Search the catalog below. Missing something? Ask your DM: custom items are created in their DM Space.</p>'}
          <input type="search" name="search" placeholder="Search by name…" value="${esc(f.search)}" aria-label="Search the catalog" autocomplete="off">
          <div class="inv-picker-filters">
            <select name="visibility" aria-label="Source">${SOURCE_FILTERS.map(([v, l]) => `<option value="${v}">${l}</option>`).join('')}</select>
            <select name="kindId" aria-label="Kind"><option value="">All kinds</option>${opt(L.kinds, '')}</select>
            <select name="categoryId" aria-label="Category"><option value="">All categories</option></select>
            <select name="rarityId" aria-label="Rarity"><option value="">Any rarity</option>${opt(L.rarities, '')}</select>
            <select name="magic" aria-label="Magic"><option value="">Magic and mundane</option><option value="magic">Magic only</option><option value="mundane">Mundane only</option></select>
            <select name="sourceBookId" aria-label="Book"><option value="">Any book</option>${opt(L.sourceBooks, '', (x) => `${x.name} (${x.code})`)}</select>
          </div>
          <p class="muted small" data-status role="status" aria-live="polite"></p>
          <div class="inv-results" data-results></div>
          <div class="inv-picker-more"><button type="button" class="btn btn-sm" data-more hidden>Load more</button></div>
        </div>`,
      onClose: () => { st.controller?.abort(); },
    });
    const results = $('[data-results]', m.el);
    const status = $('[data-status]', m.el);
    const more = $('[data-more]', m.el);
    const catSelect = $('select[name="categoryId"]', m.el);
    $('[data-create]', m.el)?.addEventListener('click', () => { m.close(); openCreateHomebrew(f.search.trim()); });

    const fillCategories = () => {
      const list = L.categories.filter((c) => !f.kindId || c.kind_id === f.kindId);
      catSelect.innerHTML = `<option value="">All categories</option>${opt(list, f.categoryId)}`;
    };

    function renderResults() {
      status.textContent = st.error ? st.error.message
        : st.loading && !st.rows.length ? 'Searching…'
          : st.total ? `Showing ${st.rows.length} of ${st.total} item${st.total === 1 ? '' : 's'}` : '';
      if (!st.loading && !st.error && !st.rows.length) {
        results.innerHTML = `<p class="empty">No items match the selected filters.</p>
          ${linkRow || !isAnyDM() ? '' : '<p><button type="button" class="btn btn-sm" data-create-empty>+ Quick private item</button></p>'}`;
      } else {
        results.innerHTML = st.rows.map((c) => `
          <div class="inv-result" data-id="${esc(c.id)}">
            <div class="inv-result-text"><b>${esc(c.name)}</b> ${sourceBadge(c)}
              <span class="muted small">${esc([c.kind_name, c.category_name, c.is_magic ? rarityName(c.rarity_id) : '', c.weight_lb != null ? fmtWeight(c.weight_lb) : '', c.cost_value != null ? `${c.cost_value} ${c.cost_unit}` : ''].filter(Boolean).join(' · '))}</span></div>
            ${linkRow
              ? '<button type="button" class="btn btn-sm btn-gold" data-pick>Compare…</button>'
              : `<input type="number" min="1" step="1" value="1" inputmode="numeric" aria-label="Quantity of ${esc(c.name)}" data-qty>
                 <button type="button" class="btn btn-sm btn-gold" data-pick>Add</button>`}
          </div>`).join('');
      }
      more.hidden = st.loading || st.rows.length >= st.total;
      more.textContent = st.loading && st.rows.length ? 'Loading…' : 'Load more';
    }

    async function loadPage(reset) {
      if (reset) { st.offset = 0; st.rows = []; st.ids = new Set(); st.total = 0; }
      st.controller?.abort();
      st.controller = new AbortController();
      const token = ++st.token;
      st.loading = true; st.error = null;
      renderResults();
      try {
        const { rows, total } = await api.getCatalogPage({ ...f, offset: st.offset, limit: PAGE_SIZE, signal: st.controller.signal });
        if (token !== st.token) return; // a newer search started: ignore this response
        rows.forEach((r) => { if (!st.ids.has(r.id)) { st.ids.add(r.id); st.rows.push(r); } });
        st.total = total;
        st.offset += rows.length;
      } catch (raw) {
        if (token !== st.token || /abort/i.test(`${raw?.name} ${raw?.message}`)) return;
        st.error = api.normalizeError(raw);
      }
      st.loading = false;
      renderResults();
    }

    const searchLater = debounce(() => loadPage(true), 300);
    $('input[name="search"]', m.el).addEventListener('input', (e) => { f.search = e.target.value; searchLater(); });
    $('.inv-picker-filters', m.el).addEventListener('change', (e) => {
      f[e.target.name] = e.target.value;
      if (e.target.name === 'kindId') { f.categoryId = ''; fillCategories(); }
      loadPage(true);
    });
    more.addEventListener('click', () => loadPage(false));
    results.addEventListener('click', async (e) => {
      if (e.target.closest('[data-create-empty]')) { m.close(); openCreateHomebrew(f.search.trim()); return; }
      const b = e.target.closest('[data-pick]');
      if (!b || b.disabled) return;
      const box = b.closest('[data-id]');
      const item = st.rows.find((r) => r.id === box.dataset.id);
      if (linkRow) { m.close(); openLinkPreview(linkRow, item.id); return; }
      const qty = api.parseQuantity($('[data-qty]', box).value);
      if (qty == null) { toast('Enter a whole number of at least 1.', 'bad'); return; }
      b.disabled = true;
      b.textContent = 'Adding…';
      try {
        await api.addInventoryItem(s.inventoryId, item.id, qty);
        toast(`Added ${qty} × ${item.name}.`, 'good');
        scheduleRefresh();
      } catch (raw) {
        toast(api.normalizeError(raw).message, 'bad', 4500);
      } finally {
        b.disabled = false;
        b.textContent = 'Add';
      }
    });
    fillCategories();
    loadPage(true);
  }

  // ---- events ------------------------------------------------------------------------------------------------------
  const ACTIONS = {
    retry: () => { s.status = 'loading'; render(); return refresh(); },
    filter: (b) => { s.filter = b.dataset.filter; render(); },
    'add-item': () => openCatalogPicker(),
    detail: (b) => openDetail(b.dataset.id),
    inc: (b) => changeQty(rowById(b.dataset.id), 1),
    dec: (b) => changeQty(rowById(b.dataset.id), -1),
    equip: (b) => equipFlow(rowById(b.dataset.id)),
    unequip: (b) => { const r = rowById(b.dataset.id); return act(r.id, async () => { await api.unequipInventoryItem(r.id); toast(`Unequipped ${r.display_name}.`); }); },
    use: (b) => doUse(rowById(b.dataset.id)),
    'not-equipped': (b) => notEquipped(rowById(b.dataset.id)),
    slot: (b) => openSlot(b.dataset.slot),
    'slot-equip': (b) => openSlotPicker(s.lookups.slots.find((x) => x.id === b.dataset.slot)),
    'slot-unequip': (b) => {
      const o = occupant(b.dataset.slot);
      if (o) return act(`slot:${b.dataset.slot}`, async () => { await api.unequipInventoryItem(o.id); toast(`Unequipped ${o.display_name}.`); });
      return undefined;
    },
    'show-row': (b) => highlight(b.dataset.id),
    'attuned-list': () => openAttunedList(),
    'edit-coins': () => {
      const sec = document.querySelector('.inv-coins');
      sec?.scrollIntoView({ block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
      (sec?.querySelector('.coin-gp input') || sec?.querySelector('input'))?.focus({ preventScroll: true });   // gold first
    },
  };

  async function onClick(e) {
    const b = e.target.closest('[data-inv]');
    if (!b || !el.contains(b) || b.disabled) return;
    const fn = ACTIONS[b.dataset.inv];
    if (!fn) return;
    if (b.dataset.id && !rowById(b.dataset.id)) { scheduleRefresh(); return; } // row vanished meanwhile
    try { await fn(b); } catch (raw) { toast(api.normalizeError(raw).message, 'bad'); }
  }
  const onToggle = (e) => {
    if (e.target.matches?.('details.inv-eq')) s.eqOpen = e.target.open;
    if (e.target.matches?.('details.inv-empty-slots')) s.emptyOpen = e.target.open;
  };

  el.addEventListener('click', onClick);
  el.addEventListener('toggle', onToggle, true);
  render();
  refresh();

  return {
    refresh,
    scheduleRefresh,
    render,
    /** Only the summary cards (coin edits on the sheet): the item list and its focus stay untouched. */
    renderSummary() {
      const box = el.querySelector('.inv-summary');
      if (box && !s.destroyed && s.status === 'ready') box.outerHTML = summaryHTML();
    },
    destroy() {
      s.destroyed = true;
      el.removeEventListener('click', onClick);
      el.removeEventListener('toggle', onToggle, true);
    },
  };
}
