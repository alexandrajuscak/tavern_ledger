// Class levels, spell slots, Pact Magic, resources and rests (migration 20261015001700). The rules (total level, proficiency
// bonus, effective caster level, slot maximums, limits) live in the database; this module only moves data.
import { supabase } from './supabase.js?v=19';
import { awaitSeed } from './read-layer.js?v=19';
import { friendlyError } from './utils.js?v=19';

export class ClassError extends Error {
  constructor(message, raw) { super(message); this.raw = raw; this.needsConfirm = raw?.hint === 'confirm_required'; }
}

function classError(raw) {
  if (raw instanceof ClassError) return raw;
  // server-written messages (22023, P0001/P0002, TL…, explained 42501) stay; technical texts are translated (docs/V62_ERROR_BOUNDARY_REVIEW.md)
  return new ClassError(friendlyError(raw, 'The class could not be changed. Nothing was changed.'), raw);
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw classError(error);
  return data;
}

async function select(build) {
  const { data, error } = await build();
  if (error) throw classError(error);
  return data;
}

// ---- catalog (cached for the session) -------------------------------------------------------------------------------------
let catalogPromise = null;
/** Classes with their versions (current first) and the one-third caster subclass progressions. */
export function getClassCatalog() {
  catalogPromise ||= Promise.all([
    select(() => supabase.from('classes').select('id, name, sort_order').order('sort_order')),
    select(() => supabase.from('class_versions').select('id, class_id, name, rules_label, source_label, source_url, status, hit_die, spellcasting_ability, multiclass_contribution, spellcasting_start_level, is_pact_magic, multiclass_prerequisite, limitations, subclass_level').order('status').order('id')),
    select(() => supabase.from('subclass_versions').select('id, class_id, name, source_label, source_url, status, spellcasting_ability, multiclass_contribution, spellcasting_start_level, limitations, implementation_status').order('name')),
  ]).then(([classes, versions, subclasses]) => ({
    classes: classes.map((c) => ({ ...c, versions: versions.filter((v) => v.class_id === c.id), subclasses: subclasses.filter((s) => s.class_id === c.id) })),
    versions, subclasses,
  })).catch((e) => { catalogPromise = null; throw e; });
  return catalogPromise;
}

// ---- character -------------------------------------------------------------------------------------------------------------
export const getClassSummary = (characterId) => rpc('get_character_class_summary', { p_character: characterId });
export const getSpellSlots = (characterId) => rpc('get_character_spell_slots', { p_character: characterId });

/** Add a class, or change level / subclass / primary of the class row (pass `row` to change its version explicitly). */
export const setCharacterClass = (characterId, { version, level, subclass = null, primary = null, row = null, notes = null }) =>
  rpc('set_character_class', { p_character: characterId, p_class_version: version, p_level: level, p_subclass_version: subclass,
    p_is_primary: primary, p_character_class: row, p_notes: notes });
export const removeCharacterClass = (rowId, confirm = false) => rpc('remove_character_class', { p_character_class: rowId, p_confirm: confirm });

// ---- active states (migration 20261017000700): Rage and similar ---------------------------------------------------------------
export const getStates = (characterId) => rpc('get_character_states', { p_character: characterId });
/** Start a state; spends a use of its resource unless `spend` is false (paid some other way). */
export const startState = (characterId, key, spend = true) => rpc('start_character_state', { p_character: characterId, p_state: key, p_spend: spend });
export const endState = (characterId, key) => rpc('end_character_state', { p_character: characterId, p_state: key });

// ---- guided setup (migration 20261017000600) ---------------------------------------------------------------------------------
/** What adding this class would bring (nothing is stored): features, proficiencies, choices, slots, prerequisites. */
export const previewClassAdd = (characterId, version, level = 1, subclass = null) =>
  rpc('preview_character_class_add', { p_character: characterId, p_class_version: version, p_level: level, p_subclass_version: subclass });
const equipmentCache = new Map();
/** Starting equipment options of a class version (groups, options, items with catalog candidates). Cached per session. */
export function getStartingEquipment(version) {
  if (!equipmentCache.has(version)) {
    equipmentCache.set(version, rpc('get_class_starting_equipment', { p_class_version: version }).catch((e) => { equipmentCache.delete(version); throw e; }));
  }
  return equipmentCache.get(version);
}
/** Adds the chosen starting equipment to the character's inventory (once; first class only). */
export const applyStartingEquipment = (characterId, version, selections) =>
  rpc('apply_class_starting_equipment', { p_character: characterId, p_class_version: version, p_selections: selections });
/** {class_version_id, applied, has_options} for the primary class row of the summary. */
export async function getStartingEquipmentState(characterId, summary) {
  const primary = (summary?.classes || []).find((k) => k.is_primary);
  if (!primary) return null;
  // fluent read path: both parts came with the character view (seeded once; otherwise the normal reads below)
  const [seedApplied, seedEq] = await Promise.all([awaitSeed('starting_equipment_applied', characterId),
    awaitSeed('primary_class_starting_equipment', characterId)]);
  if (seedApplied.hit && !seedApplied.error && seedEq.hit && !seedEq.error && seedEq.data?.class_version_id === primary.class_version_id) {
    if (!equipmentCache.has(primary.class_version_id)) equipmentCache.set(primary.class_version_id, Promise.resolve(seedEq.data.equipment));
    const eq = seedEq.data.equipment;
    return { class_version_id: primary.class_version_id, class_name: primary.class_name, applied: !!seedApplied.data, has_options: (eq?.groups || []).length > 0 };
  }
  const [applied, eq] = await Promise.all([
    select(() => supabase.from('character_starting_equipment').select('class_version_id').eq('character_id', characterId).maybeSingle()),
    getStartingEquipment(primary.class_version_id),
  ]);
  return { class_version_id: primary.class_version_id, class_name: primary.class_name, applied: !!applied, has_options: (eq?.groups || []).length > 0 };
}

export const expendStandardSlot = (characterId, level) => rpc('expend_standard_spell_slot', { p_character: characterId, p_slot_level: level });
export const restoreStandardSlot = (characterId, level) => rpc('restore_standard_spell_slot', { p_character: characterId, p_slot_level: level });
export const expendPactSlot = (characterId) => rpc('expend_pact_magic_slot', { p_character: characterId });
export const restorePactSlot = (characterId) => rpc('restore_pact_magic_slot', { p_character: characterId });
/** Authorized manual correction; recorded as such (a reason is required). */
export const setSlotState = (characterId, pool, level, expended, reason) =>
  rpc('set_spell_slot_state', { p_character: characterId, p_pool: pool, p_slot_level: level, p_expended: expended, p_reason: reason });

const newRestId = () => (crypto?.randomUUID ? crypto.randomUUID() : null);
/** A rest id makes a retried request safe: the server applies the same id once. */
export const shortRest = (characterId, restId = newRestId()) => rpc('short_rest_character', { p_character: characterId, p_rest_id: restId });
export const longRest = (characterId, restId = newRestId()) => rpc('long_rest_character', { p_character: characterId, p_rest_id: restId });

export const saveResource = (characterId, resource) => rpc('save_character_resource', { p_character: characterId, p_resource: resource });
export const changeResource = (resourceId, delta, reason = null) => rpc('change_character_resource', { p_resource: resourceId, p_delta: delta, p_reason: reason });
export const deleteResource = (resourceId) => rpc('delete_character_resource', { p_resource: resourceId });

// ---- class feature engine (migration 20261015001800): features, choices, subclass, resources, previews -------------------
/** The resolved class features of a character (authoritative; the UI never works out eligibility itself). */
export const getClassFeatures = (characterId) => rpc('get_character_class_features', { p_character: characterId });
export const setFeatureChoice = (characterId, row, unlock, choice, values, manualStatus = null) =>
  rpc('set_character_feature_choice', { p_character: characterId, p_character_class: row, p_unlock: unlock, p_choice: choice,
    p_values: values, p_manual_status: manualStatus });
export const setOptionalFeature = (characterId, row, unlock, enabled) =>
  rpc('set_character_optional_feature', { p_character: characterId, p_character_class: row, p_unlock: unlock, p_enabled: enabled });
export const setSubclass = (characterId, row, subclassVersion) =>
  rpc('set_character_subclass', { p_character: characterId, p_character_class: row, p_subclass_version: subclassVersion || null });
/** Read only: what a level and / or class version change would do (computed in a rolled-back savepoint). */
export const previewClassChange = (characterId, row, { level = null, version = null } = {}) =>
  rpc('preview_character_class_change', { p_character: characterId, p_character_class: row, p_level: level, p_class_version: version });

/** Class resources (derived maximum) and manual resources; keys "f:<class row>:<resource>" or "r:<uuid>". */
export const getResources = (characterId) => rpc('get_character_resources', { p_character: characterId });
export const expendResource = (characterId, key, amount = 1) =>
  rpc('expend_character_resource', { p_character: characterId, p_resource_key: key, p_amount: amount });
export const restoreResource = (characterId, key, amount = 1) =>
  rpc('restore_character_resource', { p_character: characterId, p_resource_key: key, p_amount: amount });
export const setResourceState = (characterId, key, expended, reason, { temporaryBonus = null, maxAdjustment = null } = {}) =>
  rpc('set_character_resource_state', { p_character: characterId, p_resource_key: key, p_expended: expended, p_reason: reason,
    p_temporary_bonus: temporaryBonus, p_max_adjustment: maxAdjustment });

// slot recovery (Arcane Recovery, Natural Recovery, Harness Divine Power) and slot <-> points conversion (Font of Magic):
// one server transaction each; the server checks the budget, the levels, the uses and the resource it also spends
export const recoverSpellSlots = (characterId, key, levels) =>
  rpc('recover_spell_slots', { p_character: characterId, p_resource_key: key, p_slot_levels: levels });
export const convertSpellSlot = (characterId, key, direction, level, pool = 'standard') =>
  rpc('convert_spell_slot', { p_character: characterId, p_resource_key: key, p_direction: direction, p_slot_level: level, p_pool: pool });
export const useTemporarySlot = (characterId, slotId) => rpc('use_temporary_spell_slot', { p_character: characterId, p_slot: slotId });
export const restoreTemporarySlot = (characterId, slotId) => rpc('restore_temporary_spell_slot', { p_character: characterId, p_slot: slotId });

export const exportClassFeatures = (characterId) => rpc('export_character_class_features', { p_character: characterId });
export const importClassFeatures = (characterId, payload) =>
  rpc('import_character_class_features', { p_character: characterId, p_payload: payload });

let spellListCache = {};
/** Spells of one class spell list (for spell choices), optionally of one spell level. */
export function getSpellListOptions(listId, level = null) {
  const k = `${listId}:${level}`;
  spellListCache[k] ||= select(() => {
    let q = supabase.from('class_spell_list_entries').select('spell_version_id, spell_level, spell_versions(name)').eq('list_id', listId);
    if (level != null) q = q.eq('spell_level', level);
    return q.order('spell_level');
  }).then((rows) => rows.map((r) => ({ id: r.spell_version_id, level: r.spell_level, name: r.spell_versions?.name || r.spell_version_id }))
    .sort((a, b) => a.level - b.level || a.name.localeCompare(b.name)))
    .catch((e) => { delete spellListCache[k]; throw e; });
  return spellListCache[k];
}
