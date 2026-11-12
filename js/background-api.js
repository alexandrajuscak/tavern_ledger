// Background data access (migration 20261017001200): the catalog and the character RPCs. The rules live in the database
// (set_character_background validates; get_character_background resolves); this module only moves data.
import { supabase } from './supabase.js?v=23';
import { friendlyError } from './utils.js?v=23';
import { PICKER_TIMEOUT_MS } from './catalog-load.js?v=23';
import { fluentEnabled, isFluentUnavailable, onUserCachesCleared } from './read-layer.js?v=23';

/** Validation messages (SQLSTATE 22023 / 23505) are written for users; everything else is mapped. */
function bgError(raw) {
  // server-written messages (22023, P0001/P0002, TL…, explained 42501) stay; technical texts are translated (docs/V62_ERROR_BOUNDARY_REVIEW.md)
  return Object.assign(new Error(friendlyError(raw, 'The background could not be changed. Nothing was changed.')), { raw, code: raw?.code });
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw bgError(error);
  return data;
}

let catalogPromise = null;
/**
 * Every background version (2024 and legacy, with their grants, choices, feat, equipment and tables), cached per session.
 * The request has its own time limit: a read that never answers (stalled network) fails and is dropped from the cache, so
 * the picker's Retry sends a new request instead of waiting on the old one.
 */
export function getBackgroundCatalog() {
  catalogPromise ||= supabase.rpc('get_background_catalog', {}).abortSignal(AbortSignal.timeout(PICKER_TIMEOUT_MS))
    .then(({ data, error }) => { if (error) throw bgError(error); return data; })
    .catch((e) => { catalogPromise = null; throw e; });
  return catalogPromise;
}

// ---- compact picker (fluent read path, docs/CATALOG_LIST_DETAIL_API.md): ~9 KB list, one version on selection ----------
let listPromise = null;
let listFromCatalog = false;   // the database has no compact list (older migration): details come from the catalog too
const detailCache = new Map();
onUserCachesCleared(() => { listPromise = null; listFromCatalog = false; detailCache.clear(); catalogPromise = null; });
const timed = (fn, args) => supabase.rpc(fn, args).abortSignal(AbortSignal.timeout(PICKER_TIMEOUT_MS))
  .then(({ data, error }) => { if (error) throw bgError(error); return data; });

/** Picker list: {versions: [{id, name, ruleset, skills, ...}], tools: [{id, name}]}. Legacy path: derived from the catalog. */
export function getBackgroundList() {
  if (!fluentEnabled()) return getBackgroundCatalog().then(catalogAsList);
  listPromise ||= timed('get_background_list', {}).catch((e) => {
    listPromise = null;
    if (isFluentUnavailable(e?.raw || e)) { listFromCatalog = true; return getBackgroundCatalog().then(catalogAsList); }   // older database
    throw e;
  });
  return listPromise;
}

/** One complete background version (the object get_background_catalog lists), cached per session. */
export function getBackgroundDetail(versionId) {
  if (!fluentEnabled() || listFromCatalog) {
    return getBackgroundCatalog().then((c) => (c.versions || []).find((v) => v.id === versionId) || null);
  }
  if (!detailCache.has(versionId)) {
    detailCache.set(versionId, timed('get_background_detail', { p_version: versionId }).catch((e) => {
      detailCache.delete(versionId);
      if (isFluentUnavailable(e?.raw || e)) return getBackgroundCatalog().then((c) => (c.versions || []).find((v) => v.id === versionId) || null);
      throw e;
    }));
  }
  return detailCache.get(versionId);
}

/** The catalog in the list shape (legacy path and fallback). */
function catalogAsList(c) {
  const tools = new Map();
  for (const v of c.versions || []) {
    for (const ch of v.choices || []) for (const o of ch.options || []) if (o.kind === 'tool') tools.set(o.id, o.name);
    for (const g of v.grants || []) if (g.kind === 'tool') tools.set(g.id, g.name);
  }
  return { versions: (c.versions || []).map((v) => ({ ...v, skills: (v.grants || []).filter((g) => g.kind === 'skill').map((g) => g.name) })),
    tools: [...tools].map(([id, name]) => ({ id, name })), full: true };
}

export const getCharacterBackground = (characterId) => rpc('get_character_background', { p_character: characterId });

/**
 * ability: {mode: 'plus2_plus1' | 'plus1_x3', allocation: {str: 2, con: 1}} or null (legacy)
 * choices: {choiceKey: [optionId | 'tool:id' | 'language:id']}; replacements: [{kind, original, replacement}]
 * options: {bonuses_included, allow_playtest, characteristics, notes}
 */
export const setCharacterBackground = (characterId, version, { ability = null, choices = {}, replacements = [], options = {} } = {}) =>
  rpc('set_character_background', { p_character: characterId, p_version: version, p_ability: ability, p_choices: choices,
    p_replacements: replacements, p_options: options });

export const clearCharacterBackground = (characterId) => rpc('clear_character_background', { p_character: characterId });
export const previewBackgroundEquipment = (characterId, pkg) => rpc('preview_background_equipment', { p_character: characterId, p_package: pkg });
export const applyBackgroundEquipment = (characterId, pkg, picks = {}) =>
  rpc('apply_background_equipment', { p_character: characterId, p_package: pkg, p_picks: picks });
