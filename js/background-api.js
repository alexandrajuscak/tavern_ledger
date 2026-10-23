// Background data access (migration 20261017001200): the catalog and the character RPCs. The rules live in the database
// (set_character_background validates; get_character_background resolves); this module only moves data.
import { supabase } from './supabase.js?v=10';
import { friendlyError } from './utils.js?v=10';

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
/** Every background version (2024 and legacy, with their grants, choices, feat, equipment and tables), cached per session. */
export function getBackgroundCatalog() {
  catalogPromise ||= rpc('get_background_catalog', {}).catch((e) => { catalogPromise = null; throw e; });
  return catalogPromise;
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
