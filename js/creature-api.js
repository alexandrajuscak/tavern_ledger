// Creature catalog, transformations (Wild Shape) and companions (migration 20261017000800). The rules (which forms are
// allowed, costs, hit point carry-over) live in the database; this module only moves data.
import { supabase } from './supabase.js?v=33';
import { awaitSeed, onUserCachesCleared } from './read-layer.js?v=33';
import { friendlyError } from './utils.js?v=33';

class CreatureError extends Error {}

function creatureError(raw) {
  // server-written messages (22023, P0001/P0002, TL…, explained 42501) stay; technical texts are translated (docs/V62_ERROR_BOUNDARY_REVIEW.md)
  return Object.assign(new CreatureError(friendlyError(raw, 'The form could not be changed. Nothing was changed.')), { raw, code: raw?.code });
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw creatureError(error);
  return data;
}

let catalog = null;
onUserCachesCleared(() => { catalog = null; });   // includes campaign custom creatures the signed-in user may see
/** All catalog creatures (summary columns), cached for the session. */
export function getCreatures() {
  catalog ||= supabase.from('creatures')
    .select('id, name, size, creature_type, subtype, challenge_rating, armor_class, hit_points, speed, source_label')
    .order('name')
    .then(({ data, error }) => { if (error) { catalog = null; throw creatureError(error); } return data; });
  return catalog;
}
export async function getCreature(id) {
  const { data, error } = await supabase.from('creatures').select('*').eq('id', id).maybeSingle();
  if (error) throw creatureError(error);
  return data;
}

export const getTransformation = (characterId) => rpc('get_character_transformation', { p_character: characterId });
/** options: {equipment: {mode: 'merge' | 'drop' | 'wear', items: {inventoryItemId: mode}}, notes}. The server decides the rest. */
export const startTransformation = (characterId, creature, options = {}) =>
  rpc('start_transformation', { p_character: characterId, p_creature: creature, p_options: options });
/** Negative = damage, positive = healing. The result has `ended` and `carryover` when the form drops to 0. */
export const changeTransformationHp = (characterId, delta) => rpc('change_transformation_hp', { p_character: characterId, p_delta: delta });
export const damageForm = (characterId, amount, note = null) => rpc('damage_active_transformation', { p_character: characterId, p_amount: amount, p_note: note });
export const healForm = (characterId, amount, note = null) => rpc('heal_active_transformation', { p_character: characterId, p_amount: amount, p_note: note });
export const setFormHp = (characterId, hp, temp = null, reason = null) =>
  rpc('set_transformation_hp', { p_character: characterId, p_hp: hp, p_temp: temp, p_reason: reason });
export const endTransformation = (characterId, reason = 'manual') => rpc('end_transformation', { p_character: characterId, p_reason: reason });
/** Combat Wild Shape: a slot heals 1d8 per level; roll = the player's own dice total, or null for a server roll. */
export const combatWildShapeHeal = (characterId, slotLevel, pool = 'standard', roll = null) =>
  rpc('combat_wild_shape_heal', { p_character: characterId, p_slot_level: slotLevel, p_pool: pool, p_roll: roll });
export const useFormAbility = (characterId, ability, action = 'use', roll = null) =>
  rpc('use_form_ability', { p_character: characterId, p_ability: ability, p_action: action, p_roll: roll });
export const setSeenForms = (characterId, creatures, seen = true, source = 'seen', note = null) =>
  rpc('set_seen_forms', { p_character: characterId, p_creatures: creatures, p_seen: seen, p_source: source, p_note: note });
export const setFormFavorite = (characterId, creature, favorite = true) =>
  rpc('set_form_favorite', { p_character: characterId, p_creature: creature, p_favorite: favorite });
export const setWildShapeSettings = (characterId, { seenMode = null, defaultEquipment = null, confirmLethal = null } = {}) =>
  rpc('set_wild_shape_settings', { p_character: characterId, p_seen_mode: seenMode, p_default_equipment: defaultEquipment, p_confirm_lethal: confirmLethal });
export const setFormEquipment = (characterId, item, mode) => rpc('set_transformation_equipment', { p_character: characterId, p_item: item, p_mode: mode });

/** The character's equipped items (id, name, slot) for the transformation review. */
export async function getEquipped(characterId) {
  const { data, error } = await supabase.from('character_equipment')
    .select('inventory_item_id, slot_id, item:inventory_items(custom_name, catalog:items(name))').eq('character_id', characterId);
  if (error) throw creatureError(error);
  return (data || []).map((r) => ({ id: r.inventory_item_id, slot: r.slot_id, name: r.item?.custom_name || r.item?.catalog?.name || 'Item' }));
}

export async function getCompanions(characterId) {
  const seed = await awaitSeed('companions', characterId);    // fluent read path: came with the open's domain request
  if (seed.hit && !seed.error) return seed.data;
  const { data, error } = await supabase.from('character_companions')
    .select('id, name, source, hp_max, hp_current, notes, active, creature_id, creature:creatures(id, name, size, creature_type, challenge_rating, armor_class, speed, actions, abilities)')
    .eq('character_id', characterId).order('created_at');
  if (error) throw creatureError(error);
  return data;
}
export const addCompanion = (characterId, { creature = null, name = null, source = null, hpMax = null }) =>
  rpc('add_character_companion', { p_character: characterId, p_creature: creature, p_name: name, p_source: source, p_hp_max: hpMax });
export const updateCompanion = (id, patch) => rpc('update_character_companion', { p_companion: id, p_patch: patch });
export const removeCompanion = (id) => rpc('remove_character_companion', { p_companion: id });
