// Combat Builder data access (docs/COMBAT_BUILDER_ARCHITECTURE.md). Every rule lives in the database (combat_* RPCs);
// this module only moves data. Mutations carry a request id, so a retry or a double click is applied once.
import { supabase } from './supabase.js?v=28';
import { friendlyError } from './utils.js?v=28';

export class CombatError extends Error {}

/** A conflict (TLCMB), a concentration question (TLCNC) or any refusal, as a message the DM can act on. */
function combatError(raw, fallback) {
  return Object.assign(new CombatError(friendlyError(raw, fallback)), { raw, code: raw?.code, hint: raw?.hint });
}

async function rpc(fn, args, fallback = 'The change was not saved. Nothing was changed.') {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw combatError(error, fallback);
  return data;
}
const rid = () => crypto.randomUUID();
export const isConflict = (e) => e?.code === 'TLCMB';
export const isConcentrationQuestion = (e) => e?.code === 'TLCNC';

// ---- reads ---------------------------------------------------------------------------------------------------------------
export const listEncounters = (campaignId = null, includeArchived = false) =>
  rpc('combat_list_encounters', { p_campaign: campaignId, p_include_archived: includeArchived }, 'The encounters could not be loaded.');
export const getEncounter = (id) => rpc('combat_get_encounter', { p_encounter: id }, 'The encounter could not be loaded.');
export const getParticipant = (id) => rpc('combat_get_participant', { p_participant: id }, 'The combatant could not be loaded.');
export const getChanges = (id, since) => rpc('combat_get_changes', { p_encounter: id, p_since: since ?? 0 }, 'Could not check for changes.');
export const getStatblock = (id) => rpc('combat_get_statblock', { p_statblock: id }, 'The stat block could not be loaded.');
export const getHistory = (id, before = null, limit = 50) => rpc('combat_get_history', { p_encounter: id, p_before: before, p_limit: limit }, 'The history could not be loaded.');
export const getSummary = (id) => rpc('combat_get_summary', { p_encounter: id }, 'The summary could not be loaded.');
export const monsterLibrary = (campaignId, query, filters = {}, limit = 60, offset = 0) =>
  rpc('combat_monster_library', { p_campaign: campaignId, p_query: query || null, p_filters: filters, p_limit: limit, p_offset: offset }, 'The monster library could not be loaded.');
export const monsterDetail = (ref, campaignId) => rpc('combat_monster_detail', { p_ref: ref, p_campaign: campaignId }, 'The stat block could not be loaded.');
export const recentMonsters = (campaignId) => rpc('combat_recent_monsters', { p_campaign: campaignId, p_limit: 12 }, 'Recent monsters could not be loaded.');
export const toggleFavorite = (ref, on) => rpc('combat_toggle_favorite', { p_ref: ref, p_on: on });

/** Character combat summary (AC, Initiative, Speed, passives, saves, defenses) from the cached per-character read. */
export async function characterSummary(characterId) {
  const { data, error } = await supabase.rpc('get_character_reads', { p_character: characterId, p_reads: ['get_character_derived_stats'] });
  if (error) throw combatError(error, 'The character summary could not be loaded.');
  return data?.reads?.get_character_derived_stats || null;
}

// ---- encounter lifecycle ---------------------------------------------------------------------------------------------------
export const createEncounter = (campaignId, name, ruleset = 'campaign', description = '', settings = {}) =>
  rpc('combat_create_encounter', { p_campaign: campaignId, p_name: name, p_ruleset: ruleset, p_description: description, p_settings: settings, p_request: rid() });
export const updateEncounter = (id, patch, expectedRev = null) => rpc('combat_update_encounter', { p_encounter: id, p_patch: patch, p_expected_rev: expectedRev });
export const archiveEncounter = (id, archived = true) => rpc('combat_archive_encounter', { p_encounter: id, p_archived: archived });
export const deleteDraft = (id) => rpc('combat_delete_draft', { p_encounter: id });
export const duplicateEncounter = (id, name = null) => rpc('combat_duplicate_encounter', { p_encounter: id, p_name: name, p_request: rid() });

// ---- participants ------------------------------------------------------------------------------------------------------------
export const addCharacters = (id, characterIds, options = {}) => rpc('combat_add_characters', { p_encounter: id, p_characters: characterIds, p_options: options, p_request: rid() });
export const addMonsters = (id, sourceKind, sourceId, options = {}) =>
  rpc('combat_add_monsters', { p_encounter: id, p_source_kind: sourceKind, p_source_id: sourceId, p_options: options, p_request: rid() });
export const addCustom = (id, def) => rpc('combat_add_custom', { p_encounter: id, p_def: def, p_request: rid() });
export const updateParticipant = (pid, patch, expectedRev = null) => rpc('combat_update_participant', { p_participant: pid, p_patch: patch, p_expected_rev: expectedRev });
export const setParticipantState = (pid, state, reason = null) => rpc('combat_set_participant_state', { p_participant: pid, p_state: state, p_reason: reason, p_request: rid() });

// ---- initiative --------------------------------------------------------------------------------------------------------------
export const setInitiative = (id, values) => rpc('combat_set_initiative', { p_encounter: id, p_values: values, p_request: rid() });
export const rollInitiative = (id, participants = null, options = {}) => rpc('combat_roll_initiative', { p_encounter: id, p_participants: participants, p_options: options, p_request: rid() });
export const clearInitiative = (id, scope = 'all') => rpc('combat_clear_initiative', { p_encounter: id, p_scope: scope });
export const sortInitiative = (id) => rpc('combat_sort_initiative', { p_encounter: id });
export const reorder = (id, order, reason = null, expectedTurnRev = null) =>
  rpc('combat_reorder', { p_encounter: id, p_order: order, p_reason: reason, p_expected_turn_rev: expectedTurnRev, p_request: rid() });

// ---- turns -------------------------------------------------------------------------------------------------------------------
export const startCombat = (id, acceptTies = false) => rpc('combat_start', { p_encounter: id, p_accept_ties: acceptTies, p_request: rid() });
/** request: pass the same id for a retry of the same click (the server applies it once). */
export const nextTurn = (id, turnRev, mode = 'next', request = rid()) => rpc('combat_next_turn', { p_encounter: id, p_expected_turn_rev: turnRev, p_mode: mode, p_request: request });
export const previousTurn = (id, turnRev, confirm = false) => rpc('combat_previous_turn', { p_encounter: id, p_expected_turn_rev: turnRev, p_confirm: confirm, p_request: rid() });
export const gotoTurn = (id, pid, turnRev, round = null, reason = null) =>
  rpc('combat_goto_turn', { p_encounter: id, p_participant: pid, p_expected_turn_rev: turnRev, p_round: round, p_reason: reason, p_request: rid() });
export const pauseCombat = (id) => rpc('combat_pause', { p_encounter: id, p_request: rid() });
export const resumeCombat = (id) => rpc('combat_resume', { p_encounter: id, p_request: rid() });
export const finishCombat = (id, notes, decisions = {}, confirm = false) =>
  rpc('combat_finish', { p_encounter: id, p_notes: notes, p_decisions: decisions, p_confirm: confirm, p_request: rid() });

// ---- hit points, effects, reactions ------------------------------------------------------------------------------------------
export const applyHp = (pid, op, amount, reason = null, request = rid()) =>
  rpc('combat_apply_hp', { p_participant: pid, p_op: op, p_amount: amount, p_reason: reason, p_request: request }, 'Hit points were not changed.');
export const applyHpBulk = (id, op, items, includeCharacters = false) =>
  rpc('combat_apply_hp_bulk', { p_encounter: id, p_op: op, p_items: items, p_include_characters: includeCharacters, p_reason: null, p_request: rid() }, 'Hit points were not changed.');
export const addEffect = (id, effect) => rpc('combat_add_effect', { p_encounter: id, p_effect: effect, p_request: rid() }, 'The effect was not added.');
export const updateEffect = (effectId, patch) => rpc('combat_update_effect', { p_effect: effectId, p_patch: patch });
export const endEffect = (effectId, reason = 'removed') => rpc('combat_end_effect', { p_effect: effectId, p_reason: reason, p_request: rid() });
export const resolveConcentration = (effectId, checkId, result) =>
  rpc('combat_resolve_concentration', { p_effect: effectId, p_check: checkId, p_result: result, p_request: rid() });
export const setReaction = (pid, used) => rpc('combat_set_reaction', { p_participant: pid, p_used: used, p_request: rid() });
export const spendLegendary = (pid, delta, action = null) => rpc('combat_spend_legendary', { p_participant: pid, p_delta: delta, p_action: action, p_request: rid() });
export const undo = (eventId) => rpc('combat_undo', { p_event: eventId, p_request: rid() }, 'Nothing was undone.');

// ---- reminders ---------------------------------------------------------------------------------------------------------------
export const saveReminder = (id, reminder) => rpc('combat_save_reminder', { p_encounter: id, p_reminder: reminder });
export const deleteReminder = (reminderId) => rpc('combat_delete_reminder', { p_reminder: reminderId });
export const ackReminder = (reminderId) => rpc('combat_ack_reminder', { p_reminder: reminderId });

// ---- Realtime: ONE channel per open encounter (docs/COMBAT_REALTIME.md) --------------------------------------------------------
// bindings: the encounter's change log (ids only), the linked characters' rows (HP from the sheet), and their revision log
// (Wild Shape forms). handlers: {change(row), character(row), revision(row), status(state)}.
export function subscribeEncounter(encounterId, characterIds, handlers) {
  let ch = supabase.channel(`combat-${encounterId}-${Math.random().toString(36).slice(2, 8)}`)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'combat_changes', filter: `encounter_id=eq.${encounterId}` }, (p) => handlers.change?.(p.new));
  const ids = [...new Set(characterIds)].filter(Boolean).slice(0, 100);
  if (ids.length) {
    ch = ch.on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'characters', filter: `id=in.(${ids.join(',')})` }, (p) => handlers.character?.(p.new))
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'character_revisions', filter: `character_id=in.(${ids.join(',')})` }, (p) => handlers.revision?.(p.new));
  }
  ch.subscribe((status) => handlers.status?.(status));
  return () => supabase.removeChannel(ch);
}
