// Fluent character read layer (docs/FRONTEND_READ_CACHE.md, docs/FLUENT_READ_ARCHITECTURE.md). Vanilla, in memory only.
//
// * One request per character open: get_character_view(character, tab) returns every read the mounted sheet makes; the
//   results are SEEDED here and each existing loader receives its value from the seed instead of the network (one-shot,
//   generation-bound, short-lived), so every loader keeps its own sequencing and stale-response guards.
// * Later reads of the open character (after a change, a Realtime event, a tab's first open) are COALESCED: every
//   get_character_* read issued in the same tick becomes one get_character_reads request with one rules evaluation.
// * In-flight deduplication: the same read joins the pending batch; the same view (Home prefetch, then open) is shared.
// * Nothing is written to localStorage. Everything is dropped when the sheet closes and on sign-out / session end.
// * Feature flag: js/config.js FLUENT_READS ('on' | 'off'); a browser can override it for controlled testing with
//   ?fluent=1 or ?fluent=0 (?fluent=default clears it). The flag changes only how data is fetched, never who may read it:
//   every read is authorized by the database. If the fluent read functions are missing or fail on the server, the page falls
//   back to the legacy read path for the rest of the session (never a mix inside one sheet).
import { FLUENT_READS } from './config.js?v=13';

const FLAG_KEY = 'tl-flag:fluent-reads';
let broken = null;   // the reason the fluent path was switched off for this page session

function flagOverride() {
  try {
    const q = new URLSearchParams(window.location.search).get('fluent');
    if (q === '1' || q === '0') localStorage.setItem(FLAG_KEY, q);
    else if (q === 'default') localStorage.removeItem(FLAG_KEY);
    return localStorage.getItem(FLAG_KEY);
  } catch { return null; }
}
const override = flagOverride();
const configured = override === '1' ? true : override === '0' ? false : FLUENT_READS === 'on';

/** Is the fluent read path active right now? */
export const fluentEnabled = () => configured && !broken;

/** Safe debug information (no data, no secrets): which read path serves this page and why. */
export function readPathInfo() {
  return { path: fluentEnabled() ? 'fluent' : 'legacy', configured: FLUENT_READS, override: override ?? null, fallback: broken };
}
function publishInfo() { try { window.__tavernLedgerReadPath = readPathInfo(); } catch { /* ignore */ } }
publishInfo();

/** A server-side failure of the fluent functions (missing migration, unexpected error): use the legacy path from now on. */
export function markFluentBroken(err) {
  broken = `${err?.code || ''} ${err?.message || err || 'unknown'}`.trim().slice(0, 160);
  console.warn('[reads] fluent read path disabled for this session:', broken);
  endReadScope();
  publishInfo();
}

/** Errors that mean "the fluent functions are not usable here", as opposed to "you may not read this character". */
export const isFluentUnavailable = (e) => ['PGRST202', 'PGRST203', '42883', '42P01', '0A000'].includes(e?.code)
  || /could not find the function|does not exist/i.test(e?.message || '');

// ---- reads of the open character ----------------------------------------------------------------------------------------
// The RPCs a mounted sheet calls with { p_character } only (get_character_change_requests also with p_include_closed false).
const BATCHABLE = new Set(['get_character_derived_stats', 'get_character_proficiencies', 'get_character_lineage',
  'get_character_background', 'get_character_feats', 'get_character_class_summary', 'get_character_spell_slots',
  'get_character_class_features', 'get_character_resources', 'get_character_states', 'get_character_transformation',
  'get_character_infusions', 'get_character_governance', 'get_character_change_requests', 'get_character_spellbook']);
const SEED_TTL_MS = 30000;

let scope = null;   // { characterId, seeds: Map(name -> {data, error, at}), batch, controller, known, stats }
let rawRpc = null;  // the unwrapped supabase.rpc (set by js/supabase.js)

export function setRawRpc(fn) { rawRpc = fn; }

/** Start the read scope of a mounted sheet (called with beginSheetReads). */
export function beginReadScope(characterId) {
  endReadScope();
  scope = { characterId, seeds: new Map(), batch: null, controller: new AbortController(), known: {}, stats: { batches: 0, reads: 0, seeded: 0 } };
}

/** Drop the scope: pending batch callers get an abort, seeds are forgotten. */
export function endReadScope() {
  if (!scope) return;
  const s = scope;
  scope = null;
  s.controller.abort();
  if (s.batch) { clearTimeout(s.batch.timer); s.batch.waiters.forEach((list) => list.forEach((w) => w(abortResult()))); }
}

const abortResult = () => ({ data: null, error: { name: 'AbortError', message: 'AbortError: the sheet was closed', code: '' } });

/** Seed the scope with a view / bundle response: {reads, errors}. */
export function seedReads(characterId, payload) {
  if (!scope || scope.characterId !== characterId || !payload) return;
  const at = Date.now();
  for (const [k, v] of Object.entries(payload.reads || {})) scope.seeds.set(k, { data: v, error: null, at });
  for (const [k, e] of Object.entries(payload.errors || {})) scope.seeds.set(k, { data: null, error: e, at });
  if (payload.reads?.revisions) noteRevisions(payload.reads.revisions);
}

/** One-shot seeded value for this character: { hit: true, data, error } or { hit: false }. */
export function takeSeed(name, characterId) {
  const s = scope?.seeds.get(name);
  if (!s || scope.characterId !== characterId) return { hit: false };
  scope.seeds.delete(name);
  if (Date.now() - s.at > SEED_TTL_MS) return { hit: false };
  scope.stats.seeded += 1;
  return { hit: true, data: s.data, error: s.error };
}

/** Last known change counters per source table (from the view, events and reconciliations). */
export function noteRevisions(revs) { if (scope) for (const [t, r] of Object.entries(revs || {})) scope.known[t] = Math.max(scope.known[t] || 0, r); }
export const knownRevision = (table) => scope?.known[table] || 0;
export const readStats = () => (scope ? { ...scope.stats } : null);

/** A Promise that also accepts the PostgREST builder's .abortSignal() (callers may chain it). */
function builderLike(promise) { promise.abortSignal = () => promise; return promise; }

/**
 * Called by the supabase.rpc wrapper. Returns a builder-like promise of {data, error} when the read layer serves the call
 * (seed or coalesced batch), or null to let the normal request go out.
 */
export function interceptRpc(fn, args) {
  if (!fluentEnabled() || !scope || !rawRpc || !BATCHABLE.has(fn) || !args) return null;
  const keys = Object.keys(args);
  const shape = fn === 'get_character_change_requests'
    ? keys.length === 2 && args.p_include_closed === false && 'p_character' in args
    : keys.length === 1 && keys[0] === 'p_character';
  if (!shape || args.p_character !== scope.characterId) return null;
  const seed = takeSeed(fn, args.p_character);
  if (seed.hit) return builderLike(Promise.resolve(seed.error ? { data: null, error: seed.error } : { data: seed.data, error: null }));
  return builderLike(enqueue(fn));
}

/** Coalesce reads of the open character into one get_character_reads request (flushed after the current tick). */
function enqueue(name) {
  const s = scope;
  if (!s.batch) {
    s.batch = { waiters: new Map(), timer: null };
    s.batch.timer = setTimeout(() => flush(s), 0);
  }
  return new Promise((resolve) => {
    const list = s.batch.waiters.get(name) || [];
    list.push(resolve);
    s.batch.waiters.set(name, list);
  });
}

async function flush(s) {
  const batch = s.batch;
  s.batch = null;
  const names = [...batch.waiters.keys()];
  s.stats.batches += 1;
  s.stats.reads += names.length;
  let res;
  try {
    res = await rawRpc('get_character_reads', { p_character: s.characterId, p_reads: names }).abortSignal(s.controller.signal);
  } catch (e) {
    res = { data: null, error: e };
  }
  if (res.error && scope === s && isFluentUnavailable(res.error)) markFluentBroken(res.error);
  for (const [name, list] of batch.waiters) {
    let out;
    if (res.error) out = { data: null, error: res.error };
    else if (res.data?.reads && name in res.data.reads) out = { data: res.data.reads[name], error: null };
    else if (res.data?.errors?.[name]) out = { data: null, error: res.data.errors[name] };
    else out = { data: null, error: { code: 'TLMISS', message: `No result for ${name}` } };
    list.forEach((w) => w(out));
  }
}

/** Arbitrary reads of the open character (table lists, revisions, inventory) in one request, outside the rpc wrapper. */
export async function readNow(characterId, names, signal) {
  const { data, error } = await rawRpc('get_character_reads', { p_character: characterId, p_reads: names })
    .abortSignal(signal || scope?.controller.signal);
  if (error) { if (isFluentUnavailable(error)) markFluentBroken(error); throw error; }
  return data;   // revisions are recorded by the caller (it compares them with the known ones first)
}

// ---- character view (open) and Home prefetch -----------------------------------------------------------------------------
const PREFETCH_TTL_MS = 5000;
const PREFETCH_MAX = 2;
const views = new Map();   // `${userId}:${characterId}:${tab}` -> { promise, at, controller, prefetch }
let viewUser = null;

/** The character view (shell + active tab). A prefetched or in-flight request for the same view is shared (dedupe). */
export function fetchView(userId, characterId, tab, { signal, prefetch = false } = {}) {
  if (viewUser !== userId) { clearReadCaches(); viewUser = userId; }
  const key = `${userId}:${characterId}:${tab}`;
  const hit = views.get(key);
  if (hit && Date.now() - hit.at < PREFETCH_TTL_MS) {
    if (!prefetch) views.delete(key);   // consumed by the open
    return hit.promise;
  }
  if (prefetch) {
    for (const [k, v] of views) if (v.prefetch && k !== key) { v.controller.abort(); views.delete(k); }   // newest hover wins
    if (views.size >= PREFETCH_MAX) return null;
  }
  const controller = new AbortController();
  signal?.addEventListener('abort', () => controller.abort(), { once: true });
  const at = Date.now();
  const promise = rawRpc('get_character_view', { p_character: characterId, p_tab: tab }).abortSignal(controller.signal)
    .then(({ data, error }) => {
      if (error) throw Object.assign(new Error(error.message || 'The character could not be loaded.'), { code: error.code, raw: error });
      return { ...data, fetched_at: at };
    });
  if (prefetch) {
    views.set(key, { promise, at, controller, prefetch: true });
    promise.catch(() => views.delete(key));
  }
  return promise;
}

/** Hover / focus / pointer-down on a Home card: fetch that character's view once, cancellable, never more than two. */
export function prefetchView(userId, characterId, tab) {
  if (!fluentEnabled() || !rawRpc) return;
  if (navigator.connection?.saveData || /(^|-)2g$/.test(navigator.connection?.effectiveType || '')) return;
  fetchView(userId, characterId, tab, { prefetch: true })?.catch(() => {});
}

/** Abort prefetches (navigation); the one for `keepCharacterId` (the character being opened) is kept for the open to use. */
export function cancelPrefetches(keepCharacterId = null) {
  for (const [k, v] of views) if (v.prefetch && !(keepCharacterId && k.split(':')[1] === keepCharacterId)) { v.controller.abort(); views.delete(k); }
}

const clearHooks = new Set();
/** Modules with their own user-scoped caches (picker lists, details) register here; cleared together with the reads. */
export function onUserCachesCleared(fn) { clearHooks.add(fn); }

/** Sign-out / session end / user switch: forget every user-scoped read. */
export function clearReadCaches() {
  cancelPrefetches();
  views.clear();
  endReadScope();
  viewUser = null;
  clearHooks.forEach((fn) => { try { fn(); } catch { /* ignore */ } });
}
