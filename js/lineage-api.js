// Lineage data access (migration 20261015001500): catalog reads and the three character RPCs.
// The rules live in the database (get_character_lineage, get_character_derived_stats); this module only moves data.
import { supabase } from './supabase.js?v=36';
import { friendlyError } from './utils.js?v=36';
import { normalizeError } from './inventory-api.js?v=36';
import { onUserCachesCleared } from './read-layer.js?v=36';

export class LineageError extends Error {
  constructor(message, raw) { super(message); this.raw = raw; }
}

/** Validation messages of the lineage RPCs (SQLSTATE 22023) are written for users; everything else is mapped. */
function lineageError(raw) {
  if (raw instanceof LineageError) return raw;
  // server-written messages (22023, P0001/P0002, TL…, explained 42501) stay; technical texts are translated (docs/V62_ERROR_BOUNDARY_REVIEW.md)
  return new LineageError(friendlyError(raw, 'The lineage could not be changed. Nothing was changed.'), raw);
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw lineageError(error);
  return data;
}

async function read(build, retries = 2) {
  for (let attempt = 0; ; attempt += 1) {
    const { data, error } = await build();
    if (!error) return data;
    const e = normalizeError(error);
    if (attempt >= retries || e.kind !== 'network') throw lineageError(error);
    await new Promise((r) => setTimeout(r, 300 * (attempt + 1)));
  }
}

// ---- Catalog (cached for the session; the catalog only changes with a new seed) ------------------------------------

let catalogPromise = null;
/** All lineages with category, version and sub-lineage counts, source labels and a search text. */
export function getLineageCatalog() {
  catalogPromise ||= read(() => supabase.from('v_lineage_catalog')
    .select('id, name, category_id, category_name, category_sort, summary, source_url, sort_order, version_count, child_count, sources, search_text')
    .order('category_sort').order('sort_order').order('name'))
    .catch((e) => { catalogPromise = null; throw e; });
  return catalogPromise;
}

const detailCache = new Map();
/** One lineage with every version, sub-lineage, trait, effect, choice and option. */
export function getLineageDetail(lineageId) {
  if (!detailCache.has(lineageId)) {
    detailCache.set(lineageId, rpc('get_lineage_detail', { p_lineage: lineageId })
      .catch((e) => { detailCache.delete(lineageId); throw e; }));
  }
  return detailCache.get(lineageId);
}

// The catalog and the details include campaign custom lineages the signed-in user may see: forgotten on a user switch.
onUserCachesCleared(() => { catalogPromise = null; detailCache.clear(); });

let refPromise = null;
/** Skills, languages and the mundane tools and weapons a choice can offer. */
export function getLineageReference() {
  refPromise ||= Promise.all([
    read(() => supabase.from('skills').select('id, name, ability').order('sort_order')),
    read(() => supabase.from('languages').select('id, name, kind').order('sort_order')),
    read(() => supabase.from('items').select('id, name, kind_id, category_id, weapon_stats(weapon_group)')
      .in('kind_id', ['tool', 'weapon']).is('owner_id', null).eq('is_magic', false).order('name')),
  ]).then(([skills, languages, items]) => ({
    skills, languages,
    items: items.map((i) => ({ id: i.id, name: i.name, kind: i.kind_id, category: i.category_id,
      weaponGroup: (Array.isArray(i.weapon_stats) ? i.weapon_stats[0] : i.weapon_stats)?.weapon_group || null })),
  })).catch((e) => { refPromise = null; throw e; });
  return refPromise;
}

// ---- Character selection ---------------------------------------------------------------------------------------------

/** Resolved lineage: versions, traits with automation status, choices with status, effects. {selected: false} without one. */
export const getCharacterLineage = (characterId) => rpc('get_character_lineage', { p_character: characterId });

/**
 * Replace the character's whole lineage selection. choices = {choice_id: [values]}.
 * Incomplete selections are saved (and reported) unless requireComplete is set; invalid values are always rejected.
 */
export const setCharacterLineage = (characterId, { version, subversion = null, choices = {}, abilityBonusesIncluded = false,
  requireComplete = false }) => rpc('set_character_lineage', {
  p_character: characterId, p_version: version, p_subversion: subversion, p_choices: choices,
  p_ability_bonuses_included: abilityBonusesIncluded, p_require_complete: requireComplete,
});

/** Remove the lineage and its choices only; everything else on the character stays. */
export const clearCharacterLineage = (characterId) => rpc('clear_character_lineage', { p_character: characterId });
