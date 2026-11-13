// Catalog pickers (docs/CATALOG_PICKER_LOADING.md, incident 2026-10-23): the dialog opens at once with a loading state, and
// the catalog read always ends in a final state: the results, or a short message with one Retry. Nothing spins forever,
// nothing retries by itself, and an answer that arrives after the dialog closed is ignored.
import { esc, toast } from './utils.js?v=29';
import { isAbortError } from './read-control.js?v=29';

// above the 8 s statement timeout of signed-in users: the client never gives up on a read the server would still finish
export const PICKER_TIMEOUT_MS = 15000;

const timeoutError = () => Object.assign(new Error('timeout'), { code: 'TL_TIMEOUT' });

/** Reject after `ms` (the read itself is shared and cached, so it is left to finish for the next opening). */
export function withTimeout(promise, ms = PICKER_TIMEOUT_MS) {
  let t;
  return Promise.race([promise, new Promise((_, reject) => { t = setTimeout(() => reject(timeoutError()), ms); })])
    .finally(() => clearTimeout(t));
}

/** What the player reads when a catalog cannot be shown (never a SQL text). */
export function catalogErrorText(err, label) {
  const text = `${err?.code || ''} ${err?.message || ''} ${err?.raw?.code || ''} ${err?.raw?.message || ''}`;
  if (err?.code === 'TL_TIMEOUT' || /57014|statement timeout|took too long|TimeoutError|timed out/i.test(text)) {
    return `The ${label} are taking too long to load. The server may be busy; try again in a moment.`;
  }
  if (/jwt expired|invalid jwt|PGRST301|session has expired/i.test(text)) return 'Your session has expired. Sign in again to see the ' + label + '.';
  if (/42501|permission denied|row-level security|not allowed/i.test(text)) {
    return `You cannot see these ${label}. Your campaign or DM settings may restrict them.`;
  }
  if (/failed to fetch|network|load failed|could not reach/i.test(text)) return `Could not reach the server to load the ${label}. Check the connection and try again.`;
  return `The ${label} could not be loaded. Try again in a moment.`;
}

/**
 * For a dialog that needs its catalog before it can open (class, spell): a "Loading …" notice when the read is slow and a
 * clear message when it fails, instead of a click that does nothing. Returns the data, or null (the player clicks again to retry).
 */
export async function catalogOrExplain(load, label) {
  const slow = setTimeout(() => toast(`Loading ${label}…`, 'info', 2500), 700);
  try {
    return await withTimeout(Promise.resolve().then(load));
  } catch (err) {
    if (!isAbortError(err)) {
      console.warn(`[${label}]`, err?.code || '', err?.message || err);
      toast(catalogErrorText(err, label), 'bad', 6000);
    }
    return null;
  } finally {
    clearTimeout(slow);
  }
}

/**
 * Show a loading state in `host`, run `load()` and hand the result to `onReady`. On failure the host shows the reason and
 * one Retry button (a second click while a retry runs does nothing). `isOpen()` false = the dialog closed: the answer is
 * dropped. Returns a function that starts the load again (Retry).
 */
export function loadIntoPicker(host, load, { label, onReady, isOpen = () => host.isConnected, timeoutMs = PICKER_TIMEOUT_MS }) {
  let running = false;
  let attempt = 0;
  const tag = /^(UL|OL)$/.test(host.tagName) ? 'li' : 'div';
  const run = async () => {
    if (running) return;
    running = true;
    const mine = ++attempt;
    host.setAttribute('aria-busy', 'true');
    host.innerHTML = `<${tag} class="picker-state" data-picker-state="loading" role="status" aria-live="polite">
      <span class="spinner spinner-inline" aria-hidden="true"></span> Loading ${esc(label)}…</${tag}>`;
    try {
      const data = await withTimeout(Promise.resolve().then(load), timeoutMs);
      if (mine !== attempt || !isOpen()) return;
      host.removeAttribute('aria-busy');
      host.innerHTML = '';
      onReady(data);
    } catch (err) {
      if (mine !== attempt || !isOpen() || isAbortError(err)) return;
      console.warn(`[${label}]`, err?.code || '', err?.message || err);
      host.removeAttribute('aria-busy');
      host.innerHTML = `<${tag} class="picker-state" data-picker-state="error" role="alert">
        <span>${esc(catalogErrorText(err, label))}</span>
        <button type="button" class="btn btn-sm" data-picker-retry>Retry</button></${tag}>`;
      host.querySelector('[data-picker-retry]').addEventListener('click', () => {
        run().then(() => host.querySelector('input, button')?.focus?.());
      }, { once: true });
    } finally {
      running = false;
    }
  };
  run();
  return run;
}
