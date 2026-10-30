export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ESC[c]);

export const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));

export function debounce(fn, ms) {
  let t;
  return (...args) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
}

// ---- LocalStorage cache (never the source of truth) -------------------------

const CACHE_PREFIX = 'tavern-ledger:';

export function cacheGet(key) {
  try {
    const raw = localStorage.getItem(CACHE_PREFIX + key);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

export function cacheSet(key, value) {
  try {
    localStorage.setItem(CACHE_PREFIX + key, JSON.stringify(value));
  } catch {
    /* quota exceeded or storage blocked — the cache is optional */
  }
}

export function cacheClear() {
  try {
    Object.keys(localStorage)
      .filter((k) => k.startsWith(CACHE_PREFIX))
      .forEach((k) => localStorage.removeItem(k));
  } catch {
    /* ignore */
  }
}

/** Remove the cached entries whose key starts with one of `prefixes` (e.g. 'bundle:' = the legacy offline copies). */
export function cacheClearPrefix(...prefixes) {
  try {
    Object.keys(localStorage)
      .filter((k) => k.startsWith(CACHE_PREFIX) && prefixes.some((p) => k.slice(CACHE_PREFIX.length).startsWith(p)))
      .forEach((k) => localStorage.removeItem(k));
  } catch {
    /* ignore */
  }
}

// ---- Pickers ----------------------------------------------------------------
/** Secondary filters of a picker start open on wide screens and folded on phones (the results stay above the fold). */
export const filtersOpenAttr = () => (window.matchMedia?.('(min-width: 701px)').matches ? 'open' : '');

// ---- Toasts -----------------------------------------------------------------

export function toast(message, type = 'info', ms = 3200) {
  const host = $('#toasts');
  if (!host) return;
  // the last line of defence (V6.2): an error toast never shows constraint, relation, JWT or network texts, whichever of the
  // ~70 call sites raised it; the original goes to the console (friendlyError)
  if (type === 'bad') message = friendlyError({ message: String(message ?? '') }, String(message ?? '') || 'Something went wrong. Nothing was changed.');
  // one operation, one message: an identical toast that is still showing is not stacked again; at most three stay visible
  if ([...host.children].some((t) => t.textContent === String(message) && !t.dataset.leaving)) return;
  while (host.children.length >= 3) host.firstElementChild.remove();
  if (type === 'bad') ms = Math.max(ms, 6500);   // errors stay long enough to be read
  const el = document.createElement('div');
  el.className = `toast toast-${type}`;
  if (type === 'bad') el.setAttribute('role', 'alert');   // errors interrupt; everything else is a polite status
  el.textContent = message;
  host.append(el);
  requestAnimationFrame(() => el.classList.add('show'));
  setTimeout(() => {
    el.dataset.leaving = '1';
    el.classList.remove('show');
    setTimeout(() => el.remove(), 300);
  }, ms);
}

// ---- Error messages (docs/ERROR_MESSAGE_REVIEW.md) ------------------------------------------------------------------
// Server functions raise messages written for players (22023, P0001, P0002, TL…, most 42501): those are shown as they are.
// Technical texts from PostgREST / Postgres (constraint, relation and function names, RLS, JWT, timeouts, network) are
// replaced by what happened and what to do; the original goes to the developer console only.
const TECHNICAL = [
  [/failed to fetch|networkerror|network request failed|load failed|fetch failed/i, 'Could not reach the server. Nothing was changed; check the connection and try again.'],
  [/jwt expired|invalid jwt|PGRST301|JWSError/i, 'Your session has expired. Sign in again; nothing was changed.'],
  [/could not serialize|deadlock detected|40001|40P01|55P03|lock not available/i, 'Someone else changed this at the same time. Nothing was changed; please try again.'],
  [/statement timeout|canceling statement|57014/i, 'The server took too long. Nothing was changed; please try again.'],
  [/violates row-level security|permission denied for (table|function|schema|relation|sequence)/i, 'You are not allowed to do that here. Nothing was changed.'],
  [/duplicate key value violates unique constraint/i, 'That already exists. Nothing was changed.'],
  [/violates (foreign key|check|not-null) constraint|null value in column|invalid input syntax|out of range for type/i, 'Some of the data is not valid. Nothing was changed.'],
  [/PGRST116|JSON object requested, multiple \(or no\) rows returned/i, 'This was not found: it may have been deleted, or you may not have access to it.'],
  [/could not find the function|function .* does not exist|relation .* does not exist|column .* does not exist|PGRST20[0-9]/i, 'This action is not available on this server version. Nothing was changed.'],
];

/** A player-facing message for any Supabase / fetch error; `fallback` names the action when nothing better is known. */
export function friendlyError(raw, fallback = 'The server could not complete this action. Nothing was changed.') {
  const text = `${raw?.message || raw || ''} ${raw?.code || ''} ${raw?.details || ''}`;
  const hit = TECHNICAL.find(([re]) => re.test(text));
  if (hit) {
    console.warn('[server]', raw?.code || '', raw?.message || raw, raw?.details || '');
    return hit[1];
  }
  return raw?.message || fallback;
}

// ---- Focus restoration --------------------------------------------------------
// Controls that may be re-rendered carry a stable data-focus-key. A modal remembers its opener's key; if the opener
// is gone when the modal closes, the key waits in pendingFocusKey until the owning view re-renders and consumes it.

let pendingFocusKey = null;

export const focusKeyOf = (el) => el?.closest?.('[data-focus-key]')?.dataset.focusKey || null;

export function focusByKey(key, root = document) {
  const el = key ? root.querySelector(`[data-focus-key="${CSS.escape(key)}"]`) : null;
  el?.focus({ preventScroll: true });
  return !!el && document.activeElement === el;
}

/** For views that re-render: the focus key waiting for this render (if any). */
export function takePendingFocusKey() {
  const k = pendingFocusKey;
  pendingFocusKey = null;
  return k;
}

function restoreFocus(el, key) {
  pendingFocusKey = key; // a re-render that is already queued will move focus to the replacement
  if (el?.isConnected) { el.focus({ preventScroll: true }); if (document.activeElement === el) return; }
  if (focusByKey(key)) return;
}

// ---- Modals -----------------------------------------------------------------

export function openModal({ title, body = '', footer = '', wide = false, onClose } = {}) {
  const wrap = document.createElement('div');
  wrap.className = 'modal-backdrop';
  wrap.innerHTML = `
    <div class="modal ${wide ? 'modal-wide' : ''}" role="dialog" aria-modal="true" aria-label="${esc(title)}" tabindex="-1">
      <header class="modal-header">
        <h2>${esc(title)}</h2>
        <button type="button" class="icon-btn" data-close aria-label="Close">✕</button>
      </header>
      <div class="modal-body">${body}</div>
      <footer class="modal-footer">${footer}</footer>
    </div>`;

  const previousFocus = document.activeElement;
  const previousKey = focusKeyOf(previousFocus);
  // Escape closes; Tab / Shift+Tab stay inside the dialog (focus trap). Only the top-most modal reacts.
  const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"]), summary';
  const onKey = (e) => {
    if (e.defaultPrevented || [...document.querySelectorAll('.modal-backdrop:not([data-closing])')].pop() !== wrap) return;
    // one Escape closes one modal: the parent's listener sees defaultPrevented and ignores this key press
    if (e.key === 'Escape') { e.preventDefault(); close(); return; }
    if (e.key !== 'Tab') return;
    const items = [...wrap.querySelectorAll(FOCUSABLE)].filter((el) => el.offsetParent !== null || el === document.activeElement);
    if (!items.length) return;
    const first = items[0];
    const last = items[items.length - 1];
    if (e.shiftKey && (document.activeElement === first || !wrap.contains(document.activeElement))) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && (document.activeElement === last || !wrap.contains(document.activeElement))) { e.preventDefault(); first.focus(); }
  };
  let closed = false;

  function close() {
    if (closed) return;
    closed = true;
    document.removeEventListener('keydown', onKey);
    wrap.classList.remove('show');
    setTimeout(() => wrap.remove(), 180);
    wrap.dataset.closing = '1'; // still in the DOM for the fade-out, but no longer the top-most modal
    if (!document.querySelector('.modal-backdrop:not([data-closing])')) document.body.classList.remove('modal-open');
    // the opener, or its re-rendered replacement (stable data-focus-key); a child modal returns focus into its parent
    restoreFocus(previousFocus, previousKey);
    onClose?.();
  }

  wrap.addEventListener('mousedown', (e) => { if (e.target === wrap) close(); });
  wrap.addEventListener('click', (e) => { if (e.target.closest('[data-close]')) close(); });
  document.addEventListener('keydown', onKey);
  document.body.append(wrap);
  document.body.classList.add('modal-open');
  requestAnimationFrame(() => wrap.classList.add('show'));
  // initial focus, unless the user already moved focus into this modal or another modal is now on top / this one closed
  const isTop = () => !closed && [...document.querySelectorAll('.modal-backdrop:not([data-closing])')].pop() === wrap;
  // a dialog without a field (confirmations) takes focus itself, so keyboard and screen-reader users are inside it
  setTimeout(() => { if (isTop() && !wrap.contains(document.activeElement)) ($('input, select, textarea', wrap) || $('.modal', wrap))?.focus(); }, 50);

  return { el: wrap, body: $('.modal-body', wrap), footer: $('.modal-footer', wrap), close, isTop };
}

export function confirmDialog(message, { title = 'Are you sure?', okLabel = 'Confirm', danger = false } = {}) {
  return new Promise((resolve) => {
    let answered = false;
    const m = openModal({
      title,
      body: String(message).split('\n').map((line) => `<p>${esc(line)}</p>`).join(''),   // one paragraph per line
      footer: `
        <button type="button" class="btn" data-close>Cancel</button>
        <button type="button" class="btn ${danger ? 'btn-bad' : 'btn-gold'}" data-ok>${esc(okLabel)}</button>`,
      onClose: () => { if (!answered) resolve(false); },
    });
    $('[data-ok]', m.el).addEventListener('click', () => {
      answered = true;
      resolve(true);
      m.close();
    });
    setTimeout(() => { if (m.isTop()) $('[data-ok]', m.el)?.focus(); }, 60);
  });
}

export function autoResize(textarea) {
  textarea.style.height = 'auto';
  textarea.style.height = `${textarea.scrollHeight + 2}px`;
}

// ---- Unhandled failures (V6.2) ---------------------------------------------------------------------------------------
// A promise that fails without a handler (a click handler that forgot its try/catch) is told to the player in words instead
// of failing silently; the original stays in the console. Aborts from navigation are not errors.
if (typeof window !== 'undefined') {
  window.addEventListener('unhandledrejection', (e) => {
    const r = e.reason;
    if (r?.name === 'AbortError') return;
    console.error('[unhandled]', r);
    toast(friendlyError(r, 'Something went wrong. Nothing was changed; please try again.'), 'bad');
  });
}
