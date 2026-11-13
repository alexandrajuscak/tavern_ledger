// Inventory data access. The ONLY module that talks to Supabase about items, inventories and equipment.
// Reads come from views (RLS applies: they are security_invoker), every change goes through an RPC.
// Function names follow the database; where they differ the mapping is written next to the function.
import { supabase } from './supabase.js?v=30';
import { onUserCachesCleared } from './read-layer.js?v=30';

// ---- Errors -----------------------------------------------------------------------------------

export class InventoryError extends Error {
  constructor(kind, message, raw) {
    super(message);
    this.kind = kind; // authorization | validation | conflict | not_found | incompatible_slot | attunement_limit
    //                   | insufficient_quantity | concurrent | network | unknown
    this.raw = raw;
  }
}

// [kind, test against the server message or code, user message]
const ERROR_RULES = [
  ['authorization', /private homebrew/i, 'Private homebrew can only be in its author’s own characters. Share it with the campaign first.'],
  ['authorization', /official items cannot be changed/i, 'Official items cannot be changed.'],
  ['authorization', /only the author/i, 'Only the author can change who can see this item.'],
  ['authorization', /not a member of that campaign/i, 'You are not a member of that campaign.'],
  ['validation', /is archived|restore the item/i, 'This homebrew item is archived. Restore it first.'],
  ['conflict', /request id was already used/i, 'This request was already used. Reload and try again.'],
  ['attunement_limit', /attunement limit/i, 'This character is already attuned to 3 items. End an attunement first.'],
  ['validation', /does not require attunement/i, 'This item does not require attunement.'],
  ['incompatible_slot', /two-handed weapon needs the off hand/i, 'A two-handed weapon needs both hands: empty the off hand and the shield slot first.'],
  ['incompatible_slot', /main hand holds a two-handed weapon/i, 'The main hand holds a two-handed weapon, so the off hand and the shield slot must stay empty.'],
  ['incompatible_slot', /two-handed weapon cannot be held in the off hand/i, 'A two-handed weapon cannot be held in the off hand.'],
  ['incompatible_slot', /cannot be equipped in slot/i, 'This item cannot be equipped in this slot.'],
  ['conflict', /already occupied/i, 'That slot is already occupied.'],
  ['incompatible_slot', /does not belong to this character/i, 'The selected item is not in this character’s inventory.'],
  ['validation', /only catalog items/i, 'Link this item to the catalog first.'],
  ['validation', /does not stack/i, 'This item does not stack. Add another piece instead.'],
  ['validation', /at least 1/i, 'The quantity must be at least 1. Use Remove to delete the item.'],
  ['insufficient_quantity', /not enough items|invalid quantity|nothing left|cannot split/i, 'There are not enough pieces for that.'],
  ['validation', /unequip the item before putting it into a container/i, 'Unequip the item before putting it into a container.'],
  ['validation', /unequip the item before transferring/i, 'Unequip the item first.'],
  ['validation', /equipped item must have quantity 1|equipped item cannot/i, 'An equipped item is always a single piece. Unequip it first.'],
  ['validation', /cycle/i, 'An item cannot be put inside itself or inside its own contents.'],
  ['validation', /nested at most|nested level/i, 'Containers can only be nested 8 levels deep.'],
  ['validation', /container must be in the same inventory/i, 'The container must be in the same inventory.'],
  ['validation', /already linked/i, 'This item is already linked to the catalog.'],
  ['not_found', /unknown catalog item|unknown item/i, 'That catalog item does not exist.'],
  ['not_found', /23503|foreign key/i, 'That item definition was just deleted or changed. The list was refreshed; nothing was added.'],
  ['not_found', /not found|P0002|PGRST116/i, 'This item no longer exists. The inventory was refreshed.'],
  ['session', /jwt expired|invalid jwt|PGRST301|JWSError/i, 'Your session has expired. Sign in again; nothing was changed.'],
  ['authorization', /not allowed|permission denied|row-level security|42501|JWT/i, 'You are not allowed to change this inventory. Nothing was changed.'],
  ['concurrent', /40001|40P01|55P03|deadlock|could not serialize/i, 'Someone else changed this item at the same time. Please try again.'],
  ['conflict', /23505|duplicate key/i, 'That conflicts with an existing entry.'],
  ['network', /failed to fetch|networkerror|network request failed|load failed|fetch failed/i, 'Network problem. Check the connection and try again.'],
];

/** Turn any Supabase / fetch error into an InventoryError with a user-facing message. */
export function normalizeError(err) {
  if (err instanceof InventoryError) return err;
  const text = `${err?.message || ''} ${err?.code || ''} ${err?.details || ''}`;
  // "in use: archive instead" and DM-only content rules are written for users (custom SQLSTATEs): show them as they are
  if (['TLUSE', 'TLDMO', 'TLDIS'].includes(err?.code) && err.message) return new InventoryError('validation', err.message, err);
  const hit = ERROR_RULES.find(([, re]) => re.test(text));
  // Validation messages raised by the homebrew / inventory RPCs (SQLSTATE 22023) are written for users: show them as they are.
  if (!hit && err?.code === '22023' && err.message) return new InventoryError('validation', err.message, err);
  // Technical details for developers only (no tokens are part of these errors).
  console.warn('[inventory]', err?.code || '', err?.message || err);
  return hit ? new InventoryError(hit[0], hit[2], err) : new InventoryError('unknown', 'The server could not complete this action.', err);
}

const retryable = (e) => ['network', 'concurrent'].includes(e.kind);

/** Run a read query; network/serialization failures are retried twice. Mutations are never retried. */
async function read(build, { retries = 2 } = {}) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      const { data, error, count } = await build();
      if (error) throw error;
      return { data, count };
    } catch (raw) {
      if (/abort/i.test(`${raw?.name} ${raw?.message}`)) throw raw; // a newer request replaced this one
      const e = normalizeError(raw);
      if (attempt >= retries || !retryable(e)) throw e;
      await new Promise((r) => setTimeout(r, 300 * (attempt + 1)));
    }
  }
}

async function rpc(fn, args) {
  try {
    const { data, error } = await supabase.rpc(fn, args);
    if (error) throw error;
    return data;
  } catch (raw) {
    throw normalizeError(raw);
  }
}

const PAGE = 500; // inventories are small; still read them in pages so nothing is cut off at the API row limit

async function readAll(build) {
  const out = [];
  for (let from = 0; ; from += PAGE) {
    const { data } = await read(() => build().range(from, from + PAGE - 1));
    out.push(...data);
    if (data.length < PAGE) return out;
  }
}

// ---- Reference data (cached for the session) -------------------------------------------------------

let lookupsPromise = null;

/** kinds, categories, rarities, source books, ammo types, equipment slots and slot rules. */
export function getLookups() {
  lookupsPromise ||= Promise.all([
    readAll(() => supabase.from('item_kinds').select('id, name, sort_order').order('sort_order')),
    readAll(() => supabase.from('item_categories').select('id, kind_id, name, sort_order').order('sort_order')),
    readAll(() => supabase.from('rarities').select('id, name, sort_order').order('sort_order')),
    readAll(() => supabase.from('source_books').select('id, code, name').order('name')),
    readAll(() => supabase.from('ammo_types').select('id, name').order('name')),
    readAll(() => supabase.from('equipment_slots').select('id, name, sort_order').order('sort_order')),
    readAll(() => supabase.from('equipment_slot_rules').select('slot_id, kind_id, category_id, item_id').order('id')),
    readAll(() => supabase.from('damage_types').select('id, name').order('name')),
    readAll(() => supabase.from('weapon_properties').select('id, name').order('name')),
    readAll(() => supabase.from('currencies').select('id, name, conversion_to_cp').order('conversion_to_cp')),
  ]).then(([kinds, categories, rarities, sourceBooks, ammoTypes, slots, slotRules, damageTypes, weaponProperties, currencies]) =>
    ({ kinds, categories, rarities, sourceBooks, ammoTypes, slots, slotRules, damageTypes, weaponProperties, currencies }))
    .catch((e) => { lookupsPromise = null; throw e; });
  return lookupsPromise;
}

// ---- Character inventory ------------------------------------------------------------------------------

/** The character's inventory id (created by the database together with the character). */
export async function getCharacterInventoryId(characterId) {
  const { data } = await read(() => supabase.from('inventories').select('id').eq('character_id', characterId).eq('kind', 'character').maybeSingle());
  if (!data) throw new InventoryError('not_found', 'This character has no inventory yet. Ask the DM to run the inventory migration.');
  return data.id;
}

/** All rows of one inventory from v_inventory_detail (equipped state derived from character_equipment). */
export function getInventoryRows(inventoryId) {
  return readAll(() => supabase.from('v_inventory_detail').select('*').eq('inventory_id', inventoryId)
    .order('sort_order').order('acquired_at').order('id'));
}

export async function getCharacterInventory(characterId) {
  const inventoryId = await getCharacterInventoryId(characterId);
  return { inventoryId, rows: await getInventoryRows(inventoryId) };
}

/** character_equipment rows: [{slot_id, inventory_item_id, equipped_at}] */
export function getCharacterEquipment(characterId) {
  return readAll(() => supabase.from('character_equipment').select('slot_id, inventory_item_id, equipped_at').eq('character_id', characterId).order('slot_id'));
}

export async function getAttunement(characterId) {
  const { data } = await read(() => supabase.from('v_character_attunement').select('*').eq('character_id', characterId).maybeSingle());
  return data || { attuned_count: 0, attunement_limit: 3, slots_free: 3 };
}

export async function getInventoryWeight(inventoryId) {
  const { data } = await read(() => supabase.from('v_inventory_weight').select('*').eq('inventory_id', inventoryId).maybeSingle());
  return data || { stacks: 0, pieces: 0, total_weight_lb: 0 };
}

export function getContainerContents(inventoryId) {
  return readAll(() => supabase.from('v_container_contents').select('*').eq('inventory_id', inventoryId).order('container_item_id'));
}

/** Legacy rows waiting for a decision (equipped flags that could not be migrated, quantity-0 rows, equipment review after a link). */
export function getLegacyReview(characterId) {
  return readAll(() => supabase.from('legacy_inventory_review').select('inventory_item_id, category, status, detail')
    .eq('character_id', characterId).in('status', ['pending', 'manual_review']).order('id'));
}

// ---- Catalog ------------------------------------------------------------------------------------------------

export const CATALOG_COLUMNS = 'id, name, kind_id, kind_name, category_id, category_name, rarity_id, is_magic, requires_attunement, '
  + 'is_consumable, stackable, weight_lb, cost_value, cost_unit, source_book_id, source_book_name, source_label, owner_id, campaign_id, '
  + 'visibility, is_mine, can_edit, archived_at, description, data_source_id, '
  + 'weapon_group, damage_dice, damage_type_id, versatile_damage, is_ranged, range_type, range_normal, range_max, weapon_ammo_type_id, '
  + 'reload, misfire, weapon_properties, base_ac, ac_bonus, dex_modifier_mode, dex_cap, strength_requirement, stealth_disadvantage, '
  + 'is_shield, ammo_type_id, pack_size, capacity_weight_lb, capacity_volume_cuft, weightless_contents, extradimensional, '
  + 'icon_key, details';   // 20261107000300 (deploy the migration before this frontend)

const detailCache = new Map();
// catalog rows as the signed-in user may see them (a DM sees secret items in full): forgotten on a user switch
onUserCachesCleared(() => detailCache.clear());

/** Forget cached catalog rows (after a homebrew item was created, edited, archived or restored). */
export function invalidateCatalogItems(ids = null) {
  if (!ids) detailCache.clear();
  else ids.forEach((id) => detailCache.delete(id));
}

/** Catalog rows that arrived with a bundle (same columns as CATALOG_COLUMNS): replace the cached copies. */
export function primeCatalogItems(rows) { rows.forEach((r) => detailCache.set(r.id, r)); }
export const cachedCatalogItem = (id) => detailCache.get(id) || null;

/** Catalog details for the given item ids (cached). */
export async function getCatalogItems(ids, { fresh = false } = {}) {
  if (fresh) invalidateCatalogItems(ids);
  const missing = [...new Set(ids)].filter((id) => id && !detailCache.has(id));
  for (let i = 0; i < missing.length; i += 100) {
    const chunk = missing.slice(i, i + 100);
    const { data } = await read(() => supabase.from('v_item_catalog').select(CATALOG_COLUMNS).in('id', chunk));
    data.forEach((r) => detailCache.set(r.id, r));
  }
  return new Map(ids.filter((id) => detailCache.has(id)).map((id) => [id, detailCache.get(id)]));
}

/** What the signed-in user knows about the (partly) unidentified items of a character: [{inventory_item_id, state, facts, …}].
 *  Players get the disguise and the revealed facts only (get_character_item_knowledge strips the rest on the server). */
export const getItemKnowledge = (characterId) => rpc('get_character_item_knowledge', { p_character: characterId });
/** Examine an unidentified item with the TOTAL of a physical roll (the server never rolls and never returns the DC):
 *  {status: 'pending' | 'succeeded' | 'failed', hint?, revealed?} (20261112000300). requestId makes a retried call idempotent. */
export const examineItem = (inventoryItemId, checkKey, rollTotal, requestId) =>
  rpc('examine_inventory_item', { p_inventory_item: inventoryItemId, p_check: checkKey, p_roll: rollTotal, p_request: requestId || null });

const modifierRarityCache = new Map();
// item_modifiers are read with the user's RLS (homebrew modifiers): forgotten on a user switch
onUserCachesCleared(() => modifierRarityCache.clear());

/** Rarity of item modifiers (a +1 on a mundane weapon is uncommon): Map(modifier id → rarity id or null), cached. */
export async function getModifierRarities(ids) {
  const missing = [...new Set(ids)].filter((id) => id && !modifierRarityCache.has(id));
  if (missing.length) {
    const { data } = await read(() => supabase.from('item_modifiers').select('id, rarity_id').in('id', missing));
    missing.forEach((id) => modifierRarityCache.set(id, null));
    data.forEach((m) => modifierRarityCache.set(m.id, m.rarity_id || null));
  }
  return new Map(ids.map((id) => [id, modifierRarityCache.get(id) ?? null]));
}

/** PostgREST `ilike` pattern for a free-text search: % and _ are escaped, * would be a wildcard. */
const likeTerm = (s) => String(s).replace(/[*]/g, ' ').replace(/[\\%_]/g, (c) => `\\${c}`).trim();

/**
 * One page of the catalog. Stable order (name, id), range-based paging with an exact total count.
 * options: { search, kindId, categoryId, rarityId, magic: 'magic'|'mundane'|'', sourceBookId,
 *            visibility: 'official'|'private'|'campaign'|'', offset, limit, signal }
 * Archived homebrew is never returned (it cannot be added any more).
 * Returns { rows, total }.
 */
export async function getCatalogPage({ search = '', kindId = '', categoryId = '', rarityId = '', magic = '', sourceBookId = '',
  visibility = '', offset = 0, limit = 50, signal } = {}) {
  const term = likeTerm(search);
  const { data, count } = await read(() => {
    let q = supabase.from('v_item_catalog').select(CATALOG_COLUMNS, { count: 'exact' });
    if (term) q = q.ilike('name', `%${term}%`);
    if (kindId) q = q.eq('kind_id', kindId);
    if (categoryId) q = q.eq('category_id', categoryId);
    if (rarityId) q = q.eq('rarity_id', rarityId);
    if (magic === 'magic') q = q.eq('is_magic', true);
    if (magic === 'mundane') q = q.eq('is_magic', false);
    if (sourceBookId) q = q.eq('source_book_id', sourceBookId);
    if (visibility) q = q.eq('visibility', visibility);
    q = q.is('archived_at', null);
    q = q.order('name').order('id').range(offset, offset + limit - 1);
    return signal ? q.abortSignal(signal) : q;
  });
  data.forEach((r) => detailCache.set(r.id, r));
  return { rows: data, total: count ?? data.length };
}

/** searchCatalog(query, filters, page) — convenience wrapper over getCatalogPage with page numbers (0-based). */
export function searchCatalog(query, filters = {}, page = 0, pageSize = 50) {
  return getCatalogPage({ ...filters, search: query, offset: page * pageSize, limit: pageSize });
}

// ---- Mutations (RPC only, except the two legacy-compatible free-text writes at the end) -------------------------

/** add_inventory_item: adds `quantity` pieces; merges into an identical stack; returns the row id. */
export const addInventoryItem = (inventoryId, itemId, quantity = 1, { customName = null, notes = null, state = {} } = {}) =>
  rpc('add_inventory_item', { p_inventory: inventoryId, p_item: itemId, p_quantity: quantity, p_custom_name: customName, p_notes: notes, p_state: state });

/** remove_inventory_item: removes `quantity` pieces (null = all); returns {removed, remaining, deleted}. */
export const removeInventoryItem = (inventoryItemId, quantity = null) =>
  rpc('remove_inventory_item', { p_item: inventoryItemId, p_quantity: quantity });

/** set_inventory_item_quantity: exact quantity >= 1; returns {inventory_item_id, previous_quantity, quantity}. */
export const setInventoryItemQuantity = (inventoryItemId, quantity) =>
  rpc('set_inventory_item_quantity', { p_item: inventoryItemId, p_quantity: quantity });

/**
 * equip_item: equips ONE piece. A stack is split first, so the equipped row id can differ from inventoryItemId.
 * Returns {inventory_item_id, split_from, slot}. replace = true unequips the slot's current item first.
 */
export const equipInventoryItem = (inventoryItemId, slotId, { replace = false } = {}) =>
  rpc('equip_item', { p_item: inventoryItemId, p_slot: slotId, p_replace: replace });

/** unequip_item: returns the id of the row the piece ended up in (it may rejoin an identical stack). */
export const unequipInventoryItem = (inventoryItemId) => rpc('unequip_item', { p_item: inventoryItemId });

/** unequipInventorySlot: maps a slot to its equipped row, then calls unequip_item. */
export async function unequipInventorySlot(characterId, slotId) {
  const equipment = await getCharacterEquipment(characterId);
  const hit = equipment.find((e) => e.slot_id === slotId);
  if (!hit) throw new InventoryError('not_found', 'Nothing is equipped in that slot.');
  return unequipInventoryItem(hit.inventory_item_id);
}

/** use_inventory_item: consumes one piece (if consumable) and returns the effect; never changes HP. */
export const useInventoryItem = (inventoryItemId) => rpc('use_inventory_item', { p_item: inventoryItemId, p_quantity: 1 });

export const attuneInventoryItem = (inventoryItemId) => rpc('attune_item', { p_item: inventoryItemId });
export const unattuneInventoryItem = (inventoryItemId) => rpc('unattune_item', { p_item: inventoryItemId });

/** move_inventory_item: into a container of the same inventory, or out of it (containerId = null). */
export const moveInventoryItem = (inventoryItemId, containerId) =>
  rpc('move_inventory_item', { p_item: inventoryItemId, p_container: containerId });

// ---- Customized inventory instance ----------------------------------------------------------------------

/** update_inventory_item_details: per-piece fields only (custom_name, notes, is_quest_item, durability, charges_*, state). */
export const updateInventoryItemDetails = (inventoryItemId, details) =>
  rpc('update_inventory_item_details', { p_item: inventoryItemId, p_details: details });

// ---- Homebrew catalog items -----------------------------------------------------------------------------------
// requestId: crypto.randomUUID() created once per form; repeating the call returns the same item (no duplicates).

/** Items with a similar name (official, my homebrew, campaign homebrew), for the duplicate warning. */
export async function findSimilarItems(name) {
  const term = likeTerm(name);
  if (term.length < 2) return [];
  const { data } = await read(() => supabase.from('v_item_catalog').select('id, name, kind_name, visibility, is_mine')
    .ilike('name', `%${term}%`).is('archived_at', null).order('name').limit(10));
  return data;
}

/** A homebrew definition for the edit form: catalog row + container and effect. */
export async function getHomebrewDefinition(itemId) {
  const [{ data: item }, { data: container }, { data: effects }] = await Promise.all([
    read(() => supabase.from('v_item_catalog').select(CATALOG_COLUMNS).eq('id', itemId).single()),
    read(() => supabase.from('container_stats').select('*').eq('item_id', itemId).maybeSingle()),
    read(() => supabase.from('consumable_effects').select('*').eq('item_id', itemId).order('seq')),
  ]);
  return { item, container, effect: effects[0] || null };
}

export async function createHomebrewItem(requestId, definition, stats = {}) {
  const res = await rpc('create_homebrew_item', { p_request_id: requestId, p_definition: definition, p_stats: stats });
  invalidateCatalogItems([res.id]);
  return res;
}

/** update_homebrew_item: the type cannot change; the change affects every inventory entry using the item. */
export async function updateHomebrewItem(itemId, definition, stats = {}) {
  const res = await rpc('update_homebrew_item', { p_item: itemId, p_definition: definition, p_stats: stats });
  invalidateCatalogItems([itemId]);
  return res;
}

export async function archiveHomebrewItem(itemId) {
  const res = await rpc('archive_homebrew_item', { p_item: itemId });
  invalidateCatalogItems([itemId]);
  return res;
}

/** Would a permanent delete be allowed? Lists what uses the definition (docs/CUSTOM_ITEM_DELETION.md). */
export const previewItemDeletion = (itemId) => rpc('preview_item_deletion', { p_item: itemId });

/** Permanent delete of an UNUSED custom item; the server rechecks every dependency under the item lock. */
export async function deleteCustomItem(itemId, confirmName) {
  const res = await rpc('delete_custom_item', { p_item: itemId, p_confirm_name: confirmName });
  invalidateCatalogItems([itemId]);
  return res;
}

export async function restoreHomebrewItem(itemId) {
  const res = await rpc('restore_homebrew_item', { p_item: itemId });
  invalidateCatalogItems([itemId]);
  return res;
}

/** Number of inventory entries (all characters, aggregate only) using a homebrew item. Author / DM only. */
export const getHomebrewUsage = (itemId) => rpc('homebrew_usage_count', { p_item: itemId });

// ---- Legacy items -------------------------------------------------------------------------------------------------

/** Catalog candidates for a legacy row: [{item_id, name, kind_id, category_id, visibility, confidence: 'exact'|'probable'}] */
export const getLinkCandidates = (inventoryItemId) => rpc('find_link_candidates', { p_item: inventoryItemId });

/** What linking would do (legacy vs catalog values, preserved fields, warnings). Changes nothing. */
export const previewLink = (inventoryItemId, catalogItemId) =>
  rpc('preview_link_inventory_item', { p_item: inventoryItemId, p_catalog_item: catalogItemId });

/** link_inventory_item (only after the user confirmed the comparison). Returns preserved/changed fields and warnings. */
export const linkInventoryItem = (inventoryItemId, catalogItemId) =>
  rpc('link_inventory_item', { p_item: inventoryItemId, p_catalog_item: catalogItemId });

/** One transaction: create a homebrew item from the legacy data and link the row to it (idempotent per requestId). */
export async function convertLegacyToHomebrew(inventoryItemId, requestId, definition, stats = {}) {
  const res = await rpc('convert_legacy_item_to_homebrew', { p_item: inventoryItemId, p_request_id: requestId, p_definition: definition, p_stats: stats });
  invalidateCatalogItems();
  return res;
}

/** "This legacy item is not equipped" for an open equipment review. */
export const resolveEquipmentReview = (inventoryItemId) => rpc('resolve_equipment_review', { p_item: inventoryItemId });

/** JSON import: catalog matches or homebrew items, never legacy rows. Returns {matched, homebrew_created, skipped[]}. */
export const importInventoryItems = (characterId, items) => rpc('import_inventory_items', { p_character: characterId, p_items: items });
/** Apply this character's pending party shares (20261114000100; counts only). An older server has no such RPC: callers ignore errors. */
export const syncPartyKnowledge = (characterId) => rpc('sync_party_knowledge', { p_character: characterId });

// ---- Derived character stats and proficiencies (migration 20261015001400) ---------------------------------------

/** Authoritative derived state: AC with breakdown, speed, armor consequences, equipped weapon attacks, tools, warnings. */
export const getDerivedStats = (characterId) => rpc('get_character_derived_stats', { p_character: characterId });

/** Every proficiency with all its active sources (manual, class, feature, lineage, background): get_character_proficiencies. */
export const getProficiencies = (characterId) => rpc('get_character_proficiencies', { p_character: characterId });

/** Add (enabled) or remove one proficiency: a group id ('martial-weapons') or one catalog item id ('longsword'). */
export const setCharacterProficiency = (characterId, { group = null, item = null, enabled = true } = {}) =>
  rpc('set_character_proficiency', { p_character: characterId, p_group: group, p_item: item, p_enabled: enabled });

let groupsPromise = null;
export function getProficiencyGroups() {
  groupsPromise ||= readAll(() => supabase.from('proficiency_groups').select('id, name, proficiency_type, sort_order').order('sort_order'))
    .catch((e) => { groupsPromise = null; throw e; });
  return groupsPromise;
}

/** Weapons, armor, shields or tools by name, for the specific-proficiency picker. */
export async function searchProficiencyItems(kind, query) {
  const { data } = await read(() => {
    let q = supabase.from('items').select('id, name, kind_id, category_id').eq('kind_id', kind).is('archived_at', null).order('name').limit(20);
    if (query) q = q.ilike('name', `%${query.replace(/[%_,()]/g, ' ')}%`);
    return q;
  });
  return data;
}

/** Parse a user-entered quantity: a whole number >= 1, otherwise null. */
export function parseQuantity(value) {
  const s = String(value ?? '').trim();
  if (!/^\d+$/.test(s)) return null;
  const n = Number(s);
  return Number.isSafeInteger(n) && n >= 1 ? n : null;
}
