// DM Space data (docs/DM_SPACE.md): campaigns, overview, party, the custom content library and its lifecycle, assignment and
// hidden information. Every function is a DM-only RPC that checks the campaign role itself (20261019000400-000600).

import { supabase } from './supabase.js?v=31';
import { friendlyError } from './utils.js?v=31';

export class DmError extends Error {
  constructor(message, raw) {
    super(message);
    this.code = raw?.code;
    this.raw = raw;
  }
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new DmError(friendlyError(error), error);
  return data;
}

export const getMyDmCampaigns = () => rpc('get_my_dm_campaigns', {});
export const getDmOverview = (campaignId) => rpc('get_dm_overview', { p_campaign: campaignId });
/** The party overview, computed in parallel batches (one row costs ~0.2 s on the server; a request is capped at 8 s). */
export async function getDmParty(campaignId, ids = null) {
  const all = ids || (await getCampaignCharacters(campaignId)).map((c) => c.id);
  const chunks = Array.from({ length: Math.ceil(all.length / 5) }, (_, i) => all.slice(i * 5, i * 5 + 5));
  const parts = await Promise.all(chunks.map((ch) => rpc('get_dm_party', { p_campaign: campaignId, p_characters: ch })));
  return { campaign_id: campaignId, characters: parts.flatMap((p) => p.characters).sort((a, b) => a.name.localeCompare(b.name)) };
}
/** Names only (pickers and filters). */
export async function getCampaignCharacters(campaignId) {
  const { data, error } = await supabase.from('characters').select('id, name, owner_id').eq('campaign_id', campaignId).order('name');
  if (error) throw new DmError(friendlyError(error), error);
  return data;
}

// ---- content -------------------------------------------------------------------------------------------------------------
export const getContentLibrary = (campaignId, type = null) => rpc('get_dm_content_library', { p_campaign: campaignId, p_type: type, p_include_archived: true });
export const getContent = (id) => rpc('get_dm_content', { p_content: id });
export const createContent = (type, campaignId, fields) => rpc('create_dm_content', { p_type: type, p_campaign: campaignId, p_fields: fields, p_request_id: crypto.randomUUID() });
export const saveContent = (id, fields, revision = null) => rpc('save_dm_content', { p_content: id, p_fields: fields, p_expected_revision: revision });
export const validateContent = (id) => rpc('validate_dm_content', { p_content: id });
export const previewContent = (id) => rpc('preview_dm_content', { p_content: id });
export const publishContent = (id, versionId = null) => rpc('publish_dm_content', { p_content: id, p_expected_version: versionId });
export const newContentVersion = (id) => rpc('new_dm_content_version', { p_content: id });
export const archiveContent = (id, reason = null) => rpc('archive_dm_content', { p_content: id, p_reason: reason });
export const restoreContent = (id) => rpc('restore_dm_content', { p_content: id });
export const duplicateContent = (id, campaignId = null) => rpc('duplicate_dm_content', { p_content: id, p_campaign: campaignId, p_keep_campaign: true });
export const deleteContent = (id) => rpc('delete_dm_content', { p_content: id });
/** Permanent delete of a published item that nothing uses (all versions; rechecked on the server). */
export const deleteUnusedItem = (id, confirmName) => rpc('delete_unused_dm_item', { p_content: id, p_confirm_name: confirmName });
// content management (20261109000300, docs/CONTENT_MANAGEMENT.md)
export const getContentUsage = (id) => rpc('get_dm_content_usage', { p_content: id });
/** WHERE content is used (characters, inventories / stashes, requests, encounters, other content): DM / admin only (20261112000100). */
export const getContentUsageDetail = (id) => rpc('get_dm_content_usage_detail', { p_content: id });
export const deleteUnusedContent = (id, confirmName) => rpc('delete_unused_dm_content', { p_content: id, p_confirm_name: confirmName });
export const duplicateOfficial = (type, ref, campaignId) => rpc('duplicate_official_as_homebrew', { p_type: type, p_ref: ref, p_campaign: campaignId });
export const assignContent = (id, characterIds, mode, options = {}) =>
  rpc('dm_assign_content', { p_content: id, p_characters: characterIds, p_mode: mode, p_options: options });

// ---- hidden information ----------------------------------------------------------------------------------------------------
export const getCharacterHidden = (characterId) => rpc('get_dm_character_hidden', { p_character: characterId });
export const saveDmNote = (characterId, title, body, noteId = null, revealNote = null) =>
  rpc('save_dm_note', { p_character: characterId, p_title: title, p_body: body, p_note: noteId, p_reveal_note: revealNote });
export const deleteDmNote = (noteId) => rpc('delete_dm_note', { p_note: noteId });
export const revealDmNote = (noteId) => rpc('reveal_dm_note', { p_note: noteId });
export const applyCondition = (characterId, { versionId = null, name = null, hidden = false, expiresAt = null, note = null } = {}) =>
  rpc('apply_character_condition', { p_character: characterId, p_version: versionId, p_name: name, p_hidden: hidden, p_expires: expiresAt, p_note: note });
export const removeCondition = (conditionId) => rpc('remove_character_condition', { p_condition: conditionId });
export const revealCondition = (conditionId) => rpc('reveal_character_condition', { p_condition: conditionId });
export const setConditionDmNote = (conditionId, note) => rpc('set_condition_dm_note', { p_condition: conditionId, p_note: note });
export const setItemKnowledge = (inventoryItemId, state, revealed = null, magicKnown = null) =>
  rpc('set_item_knowledge', { p_inventory_item: inventoryItemId, p_state: state, p_revealed: revealed, p_magic_known: magicKnown });
export const getCharacterConditions = (characterId) => rpc('get_character_conditions', { p_character: characterId });
// identification of disguised items, e.g. Herbs & Plants (20261112000300)
export const getIdentifyAttempts = (campaignId, status = 'pending') => rpc('get_campaign_identify_attempts', { p_campaign: campaignId, p_status: status });
/** success: true / false, or null = decide by the (corrected) roll against the DC. allowRetry on a failure lets the player try again. */
export const resolveIdentifyAttempt = (attemptId, { success = null, dmRoll = null, note = null, allowRetry = false, reveal = null } = {}) =>
  rpc('resolve_identify_attempt', { p_attempt: attemptId, p_success: success, p_dm_roll: dmRoll, p_note: note, p_allow_retry: allowRetry, p_reveal: reveal });
/** Reveal an item (all, or parts) to some characters; characterIds null = every character of the campaign. */
export const revealItem = (itemId, characterIds = null, reveal = null, campaignId = null) =>
  rpc('dm_reveal_item', { p_item: itemId, p_characters: characterIds, p_reveal: reveal, p_campaign: campaignId });
// per-character reveal (20261112000400): reveal is ['all'] | [] | parts ('name', 'description', 'details', 'magic', ...);
// mode 'raise' never lowers what a character knows, 'set' sets exactly that level (undo / hide). characterIds: always explicit.
export const setItemKnowledgeFor = (itemId, characterIds, reveal, mode = 'set', campaignId = null) =>
  rpc('dm_set_item_knowledge', { p_item: itemId, p_characters: characterIds, p_reveal: reveal, p_mode: mode, p_campaign: campaignId });
/** Who knows what about one item: every campaign character (record, rows, effective level), stash rows, history. */
export const getItemKnowledgeOverview = (itemId, campaignId) => rpc('get_item_knowledge_overview', { p_item: itemId, p_campaign: campaignId });
// party-wide identification (20261114000300): the campaign rule and the DM's holds
export const getIdentificationSharing = (campaignId) => rpc('get_campaign_identification_sharing', { p_campaign: campaignId });
export const setIdentificationSharing = (campaignId, on) => rpc('set_campaign_identification_sharing', { p_campaign: campaignId, p_on: !!on });
export const syncPartyKnowledge = (campaignId) => rpc('dm_sync_party_knowledge', { p_campaign: campaignId });
export const releaseKnowledgeHold = (itemId, characterIds, campaignId = null) =>
  rpc('dm_release_item_knowledge_hold', { p_item: itemId, p_characters: characterIds, p_campaign: campaignId });
export const getCampaignKnowledgeItems = (campaignId) => rpc('get_campaign_knowledge_items', { p_campaign: campaignId });
/** The number of examine requests waiting for the DM (the Hidden tab's badge; a count, not the list). */
export const getPendingExamineCount = (campaignId) => rpc('get_campaign_pending_examine_count', { p_campaign: campaignId });
export const setItemIdentifyOptions = (itemId, options) => rpc('set_item_identify_options', { p_item: itemId, p_options: options });
export const giveItem = (itemId, characterIds, quantity = 1, identified = false) =>
  rpc('dm_give_item', { p_item: itemId, p_characters: characterIds, p_quantity: quantity, p_identified: identified });
/** Custom items of the campaign (DM Content and campaign homebrew) with their DM-only identification options. */
export async function getCampaignCustomItems(campaignId) {
  const { data, error } = await supabase.from('items').select('id, name, kind_id, archived_at').eq('campaign_id', campaignId)
    .not('owner_id', 'is', null).is('archived_at', null).order('name');
  if (error) throw new DmError(friendlyError(error), error);
  const ids = data.map((x) => x.id);
  const secrets = ids.length ? await supabase.from('item_secrets').select('*').in('item_id', ids) : { data: [] };
  if (secrets.error) throw new DmError(friendlyError(secrets.error), secrets.error);
  const by = new Map((secrets.data || []).map((x) => [x.item_id, x]));
  // DM Content keeps its identification options in the content definition (edited in the Content editor, 20261112000300)
  const versions = ids.length ? await supabase.from('dm_content_versions').select('content_id, catalog_ref').in('catalog_ref', ids) : { data: [] };
  if (versions.error) throw new DmError(friendlyError(versions.error), versions.error);
  const content = new Map((versions.data || []).map((x) => [x.catalog_ref, x.content_id]));
  return data.map((x) => ({ ...x, secrets: by.get(x.id) || null, content_id: content.get(x.id) || null }));
}
export const exportDmBackup = (campaignId) => rpc('export_campaign_dm_backup', { p_campaign: campaignId });

// ---- reference data for the editors ---------------------------------------------------------------------------------------
let refPromise = null;
export function getEditorReference() {
  const rows = async (q) => { const { data, error } = await q; if (error) throw new DmError(friendlyError(error), error); return data; };
  refPromise ||= Promise.all([
    rows(supabase.from('spell_schools').select('id, name').order('name')),
    rows(supabase.from('damage_types').select('id, name').order('name')),
    rows(supabase.from('class_spell_lists').select('id, name').order('name')),
    rows(supabase.from('skills').select('id, name').order('name')),
    rows(supabase.from('items').select('id, name').eq('kind_id', 'tool').is('owner_id', null).order('name')),
    rows(supabase.from('languages').select('id, name').order('name')),
    rows(supabase.from('feat_versions').select('id, name, ruleset').eq('category', 'origin').eq('status', 'official').order('name')),
    rows(supabase.from('item_kinds').select('id, name').order('sort_order')),
    rows(supabase.from('rarities').select('id, name').order('sort_order')),
    rows(supabase.from('ammo_types').select('id, name').order('name')),
  ]).then(([schools, damageTypes, spellLists, skills, tools, languages, originFeats, itemKinds, rarities, ammoTypes]) =>
    ({ schools, damageTypes, spellLists, skills, tools, languages, originFeats, itemKinds, rarities, ammoTypes }))
    .catch((e) => { refPromise = null; throw e; });
  return refPromise;
}

/** Rarity of published custom items (their catalog rows; the DM may read them): Map(item id → {id, name, magic}). */
export async function getItemRarities(itemIds) {
  const ids = [...new Set(itemIds.filter(Boolean))];
  if (!ids.length) return new Map();
  const { data, error } = await supabase.from('items').select('id, rarity_id, is_magic, rarity:rarities(name)').in('id', ids).not('rarity_id', 'is', null);
  if (error) throw new DmError(friendlyError(error), error);
  return new Map(data.map((x) => [x.id, { id: x.rarity_id, name: x.rarity?.name || x.rarity_id, magic: !!x.is_magic }]));
}
