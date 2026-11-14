// Campaign governance, change requests and the campaign audit (docs/DM_GOVERNANCE.md, APPROVAL_WORKFLOWS.md).
// Thin wrappers around the RPCs of 20261019000100 / 000200; the database decides, the UI only explains.

import { supabase } from './supabase.js?v=36';
import { friendlyError } from './utils.js?v=36';

export class GovError extends Error {
  constructor(message, raw) {
    super(message);
    this.code = raw?.code;
    this.raw = raw;
  }
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new GovError(friendlyError(error), error);
  return data;
}

// ---- policy ------------------------------------------------------------------------------------------------------------
export const getCharacterGovernance = (characterId) => rpc('get_character_governance', { p_character: characterId });
export const getCampaignGovernance = (campaignId) => rpc('get_campaign_governance', { p_campaign: campaignId });
export const setCampaignGovernance = (campaignId, settings, expectedRevision = null) =>
  rpc('set_campaign_governance', { p_campaign: campaignId, p_settings: settings, p_expected_revision: expectedRevision });
export const setCharacterLock = (characterId, mode, reason = null) => rpc('set_character_lock', { p_character: characterId, p_mode: mode, p_reason: reason });
export const setSetupComplete = (characterId, complete = true) => rpc('set_character_setup_complete', { p_character: characterId, p_complete: complete });

// ---- requests ----------------------------------------------------------------------------------------------------------
let opsPromise = null;
/** The registry of requestable operations: {op: {label, args: {p_x: 'int!'}, character_param}}. */
export function getRequestOps() {
  opsPromise ||= supabase.from('change_request_ops').select('op, function_name, label, args, character_param, action_key').then(({ data, error }) => {
    if (error) { opsPromise = null; throw new GovError(friendlyError(error), error); }
    return Object.fromEntries(data.map((o) => [o.function_name, o]));
  });
  return opsPromise;
}

/** The op of a refused RPC call, or null when that call cannot be requested. */
export async function opForCall(fn, args) {
  const ops = await getRequestOps();
  const spec = ops[fn];
  if (!spec) return null;
  const out = {};
  for (const [k, t] of Object.entries(spec.args)) {
    if (t.startsWith('char_inventory')) continue;          // the server always uses the character's own inventory
    if (args?.[k] !== undefined && args[k] !== null) out[k] = args[k];
  }
  return { op: spec.op, args: out, label: spec.label };
}

export const createChangeRequest = (characterId, ops, { title = null, reason = null, note = null, submit = true, idempotencyKey = null } = {}) =>
  rpc('create_change_request', { p_character: characterId, p_ops: ops, p_title: title, p_reason: reason, p_player_note: note, p_submit: submit,
                                 p_idempotency_key: idempotencyKey || crypto.randomUUID() });
export const addChangeRequestOp = (characterId, op, title = null) => rpc('add_change_request_op', { p_character: characterId, p_op: op, p_title: title });
export const updateChangeRequest = (id, { ops = null, title = null, reason = null, note = null, revision = null } = {}) =>
  rpc('update_change_request', { p_request: id, p_ops: ops, p_title: title, p_reason: reason, p_player_note: note, p_expected_revision: revision });
export const submitChangeRequest = (id, revision = null) => rpc('submit_change_request', { p_request: id, p_expected_revision: revision });
export const cancelChangeRequest = (id, reason = null) => rpc('cancel_change_request', { p_request: id, p_reason: reason });
export const previewChangeRequest = (id) => rpc('preview_change_request', { p_request: id });
export const refreshChangeRequest = (id) => rpc('refresh_change_request', { p_request: id });
export const reviewChangeRequest = (id, decision, { note = null, revision = null, editedOps = null, privateNote = null } = {}) =>
  rpc('review_change_request', { p_request: id, p_decision: decision, p_note: note, p_expected_revision: revision, p_edited_ops: editedOps, p_private_note: privateNote });
export const retryChangeRequest = (id) => rpc('retry_change_request', { p_request: id });
export const getCharacterChangeRequests = (characterId, includeClosed = false) =>
  rpc('get_character_change_requests', { p_character: characterId, p_include_closed: includeClosed });
export const getCampaignChangeRequests = (campaignId, { statuses = null, characterId = null, action = null, limit = 100 } = {}) =>
  rpc('get_campaign_change_requests', { p_campaign: campaignId, p_statuses: statuses, p_character: characterId, p_action: action, p_limit: limit });
export const getCampaignAudit = (campaignId, { characterId = null, types = null, limit = 200, before = null } = {}) =>
  rpc('get_campaign_audit', { p_campaign: campaignId, p_character: characterId, p_types: types, p_limit: limit, p_before: before });

// ---- labels ------------------------------------------------------------------------------------------------------------
export const DECISION_LABEL = {
  player_managed: 'Players manage it', approval_required: 'Needs approval', dm_only: 'DM only', disabled: 'Turned off', locked: 'Locked',
};
export const STATUS_LABEL = {
  draft: 'Not sent yet', submitted: 'Waiting for the DM', returned_for_changes: 'Returned for changes', approved: 'Approved',
  rejected: 'Rejected', cancelled: 'Cancelled', superseded: 'Replaced', applied: 'Applied', apply_failed: 'Could not be applied',
};
export const LOCK_LABEL = {
  unlocked: 'Unlocked', progression_locked: 'Progression locked', build_locked: 'Build locked', fully_locked: 'Fully locked', archived: 'Archived',
};
export const LOCK_TEXT = {
  progression_locked: 'Your DM has paused progression: level, feats, lineage, background and other permanent choices are locked. Gameplay still works.',
  build_locked: 'Your DM has locked the build: permanent changes are paused. Gameplay and equipping still work.',
  fully_locked: 'Your DM has locked this character. Only the DM can change it now.',
  archived: 'This character is archived and read-only.',
};
export const PRESET_TEXT = {
  relaxed: 'Players manage most of their characters. Creating game content and hidden information stay with the DM.',
  standard: 'Gameplay is up to the players; level-ups, feats, new spells and magic items need your approval.',
  strict: 'Nearly every permanent change and new item needs approval. Only ordinary gameplay stays with the players.',
  custom: 'Custom rules: each kind of change is set individually (see Campaign rules).',
};
