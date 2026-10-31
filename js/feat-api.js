// Feat catalog and character feats (docs/FEATS.md, FEAT_DATA_MODEL.md): wrappers around the RPCs of 20261019000300 plus the
// small reference lists the choice editors need. No feat rule is evaluated here.

import { supabase } from './supabase.js?v=16';
import { friendlyError } from './utils.js?v=16';

export class FeatError extends Error {
  constructor(message, raw) {
    super(message);
    this.code = raw?.code;
    this.raw = raw;
  }
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new FeatError(friendlyError(error), error);
  return data;
}

async function rows(build) {
  const { data, error } = await build();
  if (error) throw new FeatError(friendlyError(error), error);
  return data;
}

export const getFeatCatalog = (characterId = null) => rpc('get_feat_catalog', { p_character: characterId });
export const getFeatDetail = (versionId) => rpc('get_feat_detail', { p_version: versionId });
export const getCharacterFeats = (characterId) => rpc('get_character_feats', { p_character: characterId });
export const assignFeat = (characterId, versionId, choices = {}, { sourceType = 'direct', note = null, overrideReason = null, notes = null } = {}) =>
  rpc('assign_character_feat', { p_character: characterId, p_version: versionId, p_choices: choices, p_source_type: sourceType,
                                 p_source_note: note, p_override_reason: overrideReason, p_notes: notes });
export const removeFeat = (characterFeatId, reason = null) => rpc('remove_character_feat', { p_character_feat: characterFeatId, p_reason: reason });
export const setFeatChoices = (characterId, grantKey, choices) => rpc('set_character_feat_choices', { p_character: characterId, p_grant_key: grantKey, p_choices: choices });
export const setFeatNotes = (characterFeatId, notes) => rpc('set_character_feat_notes', { p_character_feat: characterFeatId, p_notes: notes });
export const exportFeats = (characterId) => rpc('export_character_feats', { p_character: characterId });
export const importFeats = (characterId, feats) => rpc('import_character_feats', { p_character: characterId, p_feats: feats });

// ---- reference lists for choice editors (cached per session) ---------------------------------------------------------------
let refPromise = null;
export function getChoiceReference() {
  refPromise ||= Promise.all([
    rows(() => supabase.from('skills').select('id, name, ability').order('name')),
    rows(() => supabase.from('items').select('id, name, category_id').eq('kind_id', 'tool').is('owner_id', null).order('name')),
    rows(() => supabase.from('languages').select('id, name').order('name')),
    rows(() => supabase.from('damage_types').select('id, name').order('name')),
    rows(() => supabase.from('items').select('id, name').eq('kind_id', 'weapon').is('owner_id', null).order('name')),
  ]).then(([skills, tools, languages, damageTypes, weapons]) => ({ skills, tools, languages, damageTypes, weapons }))
    .catch((e) => { refPromise = null; throw e; });
  return refPromise;
}

/** Spells for a spell choice: by level, optional class list and schools (visible versions only). */
export async function getSpellOptions({ level = null, listId = null, schools = null } = {}) {
  let ids = null;
  if (listId) {
    const entries = await rows(() => supabase.from('class_spell_list_entries').select('spell_version_id').eq('list_id', listId).limit(2000));
    ids = entries.map((e) => e.spell_version_id);
    if (!ids.length) return [];
  }
  const out = [];
  const chunks = ids ? Array.from({ length: Math.ceil(ids.length / 150) }, (_, i) => ids.slice(i * 150, i * 150 + 150)) : [null];
  for (const chunk of chunks) {
    let q = supabase.from('spell_versions').select('id, name, level, school_id, status, rule_status, archived_at').order('name').limit(1000);
    if (level !== null && level !== undefined) q = q.eq('level', level);
    if (chunk) q = q.in('id', chunk);
    if (schools?.length) q = q.in('school_id', schools);
    out.push(...(await rows(() => q)));
  }
  return out.filter((s) => !s.archived_at && s.status === 'current').sort((a, b) => a.name.localeCompare(b.name));
}
