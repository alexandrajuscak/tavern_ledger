// Read cancellation for the open character (docs/CHARACTER_LOAD_COORDINATOR.md, incident 2026-10-23).
// One load context per mounted sheet: a generation number and an AbortController. Closing the sheet (switching character,
// leaving the page, signing out) aborts every character read still in flight; PostgREST then cancels the statement, so an
// obsolete read stops costing database time (verified locally on PostgREST 14). Writes never get the signal: a damage,
// slot or approval call always completes or fails on the server, whatever the user opens next.
let current = null;      // { controller, characterId, generation }
let generation = 0;

/** Start the reads of one character sheet; aborts the reads of the previous one. */
export function beginSheetReads(characterId) {
  endSheetReads();
  current = { controller: new AbortController(), characterId, generation: ++generation };
  return current.generation;
}

/** Abort every read of the open sheet (sheet closed, other character, sign-out). */
export function endSheetReads() {
  current?.controller.abort();
  current = null;
}

/** True while `gen` is the open sheet's load. */
export const isCurrentLoad = (gen) => !!current && current.generation === gen;

/** The open sheet's AbortSignal (or undefined when no sheet is open). */
export const sheetReadSignal = () => current?.controller.signal;

/**
 * The signal for one RPC, or undefined. Only character reads (get_character_*) of the character whose sheet is open are
 * cancellable; every other call (writes, catalogs shared between characters, DM reads of other characters) is left alone.
 */
export function readSignalFor(fn, args) {
  if (!current || !/^get_character_/.test(fn)) return undefined;
  if (args?.p_character && args.p_character !== current.characterId) return undefined;
  return current.controller.signal;
}

/** A cancelled read: never a failure to show (no toast, no error state, no retry). */
export const isAbortError = (e) => /AbortError|aborted/i.test(`${e?.name || ''} ${e?.message || ''} ${e?.raw?.message || ''} ${e?.cause?.message || ''}`);
