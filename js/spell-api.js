// Spell data access (migration 20261015001600): catalog reads, the resolved spellbook and the spell write RPCs.
// The rules (source resolution, Save DC, attack bonus, list eligibility) live in the database; this module moves data.
import { supabase } from './supabase.js?v=23';
import { friendlyError } from './utils.js?v=23';
import { onUserCachesCleared } from './read-layer.js?v=23';

export class SpellError extends Error {
  constructor(message, raw) { super(message); this.raw = raw; }
}

function spellError(raw) {
  if (raw instanceof SpellError) return raw;
  // server-written messages (22023, P0001/P0002, TL…, explained 42501) stay; technical texts are translated (docs/V62_ERROR_BOUNDARY_REVIEW.md)
  return new SpellError(friendlyError(raw, 'The spells could not be changed. Nothing was changed.'), raw);
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw spellError(error);
  return data;
}

async function readAll(build) {
  const out = [];
  for (let from = 0; ; from += 500) {
    const { data, error } = await build().range(from, from + 499);
    if (error) throw spellError(error);
    out.push(...data);
    if (data.length < 500) return out;
  }
}

// ---- catalog (cached for the session) -------------------------------------------------------------------------------------
let catalogPromise = null;
/** Every visible spell version with the fields the filters need. */
export function getSpellCatalog() {
  catalogPromise ||= readAll(() => supabase.from('v_spell_catalog')
    .select('id, spell_id, name, level, school_id, school, casting_time, casting_time_unit, range, duration, concentration, ritual, verbal, somatic, material, material_cost_gp, material_consumed, mechanism, save_ability, attack_type, automation, source_label, source_book_id, status, rule_status, source_marker, setting, scope, damage_types, damage_choice, class_lists')
    .order('level').order('name').order('id'))
    .then(withCustomEffects)
    .catch((e) => { catalogPromise = null; throw e; });
  return catalogPromise;
}

/**
 * Campaign custom spells store their damage only as effect rows (the catalog's damage_types come from the official
 * damage-type links). Attach the effect rows, so the spell icon, the damage chips and the Damage filter read the same
 * structured data as for official spells. Only the few custom rows without links are fetched.
 */
async function withCustomEffects(rows) {
  const custom = rows.filter((r) => r.scope === 'campaign' && !(r.damage_types || []).length);
  await Promise.all(custom.map(async (r) => {
    try {
      const d = await getSpellDetail(r.id);
      r.effects = d?.effects || [];
      r.damage_types = [...new Set(r.effects.filter((e) => e.category === 'damage').flatMap((e) => e.damage_types || []))];
      r.damage_choice = r.effects.some((e) => e.category === 'damage' && e.damage_mode === 'choice');
    } catch { /* the row still works; it shows its school icon */ }
  }));
  return rows;
}

let refPromise = null;
/** Schools, damage types, classes with their versions and spell lists (for filters and the source editor). */
export function getSpellReference() {
  refPromise ||= Promise.all([
    readAll(() => supabase.from('spell_schools').select('id, name, sort_order').order('sort_order')),
    readAll(() => supabase.from('damage_types').select('id, name').order('id')),
    readAll(() => supabase.from('class_versions').select('id, class_id, name, source_label, status, spellcasting_ability, preparation_mode, ritual_mode, caster_type, spell_list_id, classes(name, sort_order)').order('id')),
    readAll(() => supabase.from('class_spell_lists').select('id, name, class_version_id').order('id')),
  ]).then(([schools, damageTypes, classVersions, lists]) => ({ schools, damageTypes, classVersions, lists }))
    .catch((e) => { refPromise = null; throw e; });
  return refPromise;
}

const detailCache = new Map();
// The catalog and the details hold what the signed-in user may see (campaign custom spells): another user signing in on the
// same page must not get them (RLS decides again on the next read).
onUserCachesCleared(() => { catalogPromise = null; detailCache.clear(); });
export function getSpellDetail(versionId) {
  if (!detailCache.has(versionId)) {
    detailCache.set(versionId, rpc('get_spell_detail', { p_version: versionId }).catch((e) => { detailCache.delete(versionId); throw e; }));
  }
  return detailCache.get(versionId);
}

// ---- character -------------------------------------------------------------------------------------------------------------
/** Sources with per-source Save DC / attack bonus, spells merged per version with every grant, free-text spells, slots. */
export const getSpellbook = (characterId) => rpc('get_character_spellbook', { p_character: characterId });

/** Create (no id) or update a spellcasting source; only the documented fields are accepted by the server. */
export const saveSpellcastingSource = (characterId, source) => rpc('save_character_spellcasting_source', { p_character: characterId, p_source: source });
export const deleteSpellcastingSource = (sourceId) => rpc('delete_character_spellcasting_source', { p_source: sourceId });

export const setCharacterSpell = (characterId, { source, spell, known = true, prepared = false, alwaysPrepared = false,
  castingAbility = null, ritualAllowed = null, notes = null }) => rpc('set_character_spell', {
  p_character: characterId, p_source: source, p_spell_version: spell, p_known: known, p_prepared: prepared,
  p_always_prepared: alwaysPrepared, p_casting_ability: castingAbility, p_ritual_allowed: ritualAllowed, p_notes: notes,
});
export const setSpellPrepared = (characterSpellId, prepared) => rpc('set_character_spell_prepared', { p_character_spell: characterSpellId, p_prepared: prepared });
export const removeCharacterSpell = (characterSpellId) => rpc('remove_character_spell', { p_character_spell: characterSpellId });

/** How a spell entered a spellbook (starting, level_up, copied, scroll, feature, other): display and review only. */
export const setSpellAcquisition = (characterSpellId, acquisition, level = null, notes = null) =>
  rpc('set_character_spell_acquisition', { p_character_spell: characterSpellId, p_acquisition: acquisition || null, p_level: level, p_notes: notes });
/** The stored acquisition record of one spellbook spell (RLS: the character's owner, its DM, admins). */
export async function getSpellAcquisition(characterSpellId) {
  const { data, error } = await supabase.from('character_spells').select('acquisition, acquired_at_level, acquisition_notes').eq('id', characterSpellId).maybeSingle();
  if (error) throw spellError(error);
  return data;
}
