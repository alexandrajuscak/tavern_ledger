// Coin calculator (docs/GAMEPLAY_POLISH_AUDIT.md, "Coins"): spend or gain coins in one atomic server transaction
// (adjust_character_coins, migration 20261031000100). The preview below uses the SAME deterministic algorithm as the server;
// the server is authoritative (it re-reads the wallet under a row lock and refuses a wallet that changed meanwhile).
import { supabase } from './supabase.js?v=16';
import { $, $$, esc, toast, openModal, friendlyError } from './utils.js?v=16';

export const COINS = ['pp', 'gp', 'ep', 'sp', 'cp'];                 // display order
const ASC = ['cp', 'sp', 'ep', 'gp', 'pp'];                          // ascending value
export const VALUE = { cp: 1, sp: 10, ep: 50, gp: 100, pp: 1000 };
const NAMES = { pp: 'platinum', gp: 'gold', ep: 'electrum', sp: 'silver', cp: 'copper' };
const MAX_INPUT = 9999999;

export const wallet = (c) => Object.fromEntries(ASC.map((k) => [k, Number(c?.[k]) || 0]));
export const totalCp = (w) => ASC.reduce((t, k) => t + (Number(w[k]) || 0) * VALUE[k], 0);

/** "3 gp, 4 sp" (largest first; nothing = "nothing"). */
export function coinText(w) {
  const parts = COINS.filter((k) => Number(w[k]) > 0).map((k) => `${Number(w[k]).toLocaleString()} ${k}`);
  return parts.length ? parts.join(', ') : 'nothing';
}

/** Readable total of an amount in gold (exact: 1 cp = 0.01 gp). */
export const goldText = (cp) => `${Math.floor(cp / 100).toLocaleString()}${cp % 100 ? `.${String(cp % 100).padStart(2, '0')}` : ''} gp worth`;

/**
 * The result of a spend: (1) each requested denomination from the same coins; (2) the rest from the remaining coins, smallest
 * first, whole coins; (3) if still owed, ONE coin of the smallest denomination worth more than the rest is broken, the change
 * returned largest first in the standard coins below it (never electrum). Same steps as adjust_character_coins.
 * Returns { ok, after, error }.
 */
export function spend(w0, amount) {
  const n = { ...wallet(w0) };
  const a = wallet(amount);
  const owedTotal = totalCp(a);
  if (owedTotal === 0) return { ok: false, error: 'Enter an amount.' };
  if (owedTotal > totalCp(n)) return { ok: false, error: `Not enough coins: you have ${goldText(totalCp(n))}, this costs ${goldText(owedTotal)}.` };
  let owed = 0;
  for (const k of ASC) { const take = Math.min(n[k], a[k]); n[k] -= take; owed += (a[k] - take) * VALUE[k]; }
  for (const k of ASC) {
    if (!owed) break;
    const take = Math.min(n[k], Math.floor(owed / VALUE[k]));
    n[k] -= take; owed -= take * VALUE[k];
  }
  if (owed > 0) {
    const brk = ASC.find((k) => n[k] > 0 && VALUE[k] > owed);
    n[brk] -= 1;
    let chg = VALUE[brk] - owed;
    for (const k of ASC.slice(0, ASC.indexOf(brk)).reverse()) {
      if (k === 'ep') continue;
      n[k] += Math.floor(chg / VALUE[k]); chg %= VALUE[k];
    }
  }
  return { ok: true, after: n };
}

export function gain(w0, amount) {
  const a = wallet(amount);
  if (totalCp(a) === 0) return { ok: false, error: 'Enter an amount.' };
  const w = wallet(w0);
  return { ok: true, after: Object.fromEntries(ASC.map((k) => [k, w[k] + a[k]])) };
}

/** Coins that differ between two wallets: { removed, added } (for the preview). */
function diff(before, after) {
  const removed = {}; const added = {};
  for (const k of ASC) {
    const d = after[k] - before[k];
    if (d < 0) removed[k] = -d; else if (d > 0) added[k] = d;
  }
  return { removed, added };
}

/** Read one denomination field: a whole number 0..9,999,999, or an error text. */
function readCoin(input) {
  const raw = input.value.trim();
  if (raw === '') return { v: 0 };
  if (!/^\d+$/.test(raw)) return { err: `${input.dataset.coin.toUpperCase()}: whole coins only` };
  const v = Number(raw);
  if (v > MAX_INPUT) return { err: `${input.dataset.coin.toUpperCase()}: at most ${MAX_INPUT.toLocaleString()}` };
  return { v };
}

/**
 * Open the calculator. getWallet(): the current stored coins; onApplied(after): the sheet shows the new coins (the other
 * sessions get them through Realtime). Returns the modal.
 */
export function openCoinCalculator({ characterId, getWallet, onApplied }) {
  let mode = 'spend';
  let busy = false;
  let last = null;   // { before, after } of the last applied transaction (Undo)
  const m = openModal({
    title: 'Add or spend coins',
    body: `<div class="coin-calc" data-coin-calc>
      <fieldset class="coin-calc-mode"><legend>Transaction</legend>
        <label class="check-field"><input type="radio" name="coin-mode" value="spend" checked><span>Spend</span></label>
        <label class="check-field"><input type="radio" name="coin-mode" value="gain"><span>Gain</span></label>
      </fieldset>
      <p class="small muted" data-coin-wallet></p>
      <div class="coin-calc-inputs">${COINS.map((k) => `<label class="coin coin-${k}"><span>${k.toUpperCase()}</span>
        <input type="text" inputmode="numeric" pattern="[0-9]*" autocomplete="off" data-coin="${k}" aria-label="${NAMES[k]} pieces (${k})" placeholder="0"></label>`).join('')}</div>
      <div class="coin-calc-preview" data-coin-preview role="status" aria-live="polite"></div>
    </div>`,
    footer: `<button type="button" class="btn" data-close>Close</button>
      <button type="button" class="btn" data-coin-undo hidden>Undo</button>
      <button type="button" class="btn btn-gold" data-coin-apply disabled>Spend</button>`,
  });
  const preview = $('[data-coin-preview]', m.el);
  const apply = $('[data-coin-apply]', m.el);
  const undo = $('[data-coin-undo]', m.el);
  const inputs = $$('[data-coin]', m.el);
  const read = () => {
    const amount = {}; const errs = [];
    inputs.forEach((i) => { const r = readCoin(i); if (r.err) errs.push(r.err); else amount[i.dataset.coin] = r.v; i.toggleAttribute('aria-invalid', !!r.err); });
    return { amount, errs };
  };
  const plan = () => {
    const { amount, errs } = read();
    if (errs.length) return { ok: false, error: errs.join('. ') + '.' };
    return mode === 'spend' ? spend(getWallet(), amount) : gain(getWallet(), amount);
  };
  const render = () => {
    const w = getWallet();
    $('[data-coin-wallet]', m.el).textContent = `Your coins: ${coinText(w)} (${goldText(totalCp(w))}).`;
    apply.textContent = mode === 'spend' ? 'Spend' : 'Add';
    const p = plan();
    if (!p.ok) {
      const empty = p.error === 'Enter an amount.';
      preview.innerHTML = empty ? '<p class="muted small">Enter the coins, for example 7 SP and 3 CP.</p>'
        : `<p class="bg-eq-warn" data-coin-error>${esc(p.error)}</p>`;
      apply.disabled = true;
      return;
    }
    const { removed, added } = diff(w, p.after);
    preview.innerHTML = `<dl class="coin-calc-dl">
        ${Object.keys(removed).length ? `<dt>Taken from your coins</dt><dd data-coin-removed>${esc(coinText(removed))}</dd>` : ''}
        ${Object.keys(added).length ? `<dt>${mode === 'spend' ? 'Change you get back' : 'Added'}</dt><dd data-coin-added>${esc(coinText(added))}</dd>` : ''}
        <dt>Afterwards</dt><dd data-coin-after>${esc(coinText(p.after))} (${esc(goldText(totalCp(p.after)))})</dd></dl>`;
    apply.disabled = busy;
  };
  const run = async (fn, args, done) => {
    if (busy) return;
    busy = true; apply.disabled = true; undo.disabled = true;
    try {
      const { data, error } = await supabase.rpc(fn, args);
      if (error) throw error;
      onApplied?.(data.after);
      done(data);
    } catch (err) {
      console.warn('[coins]', err?.code || '', err?.message || err);
      const msg = err?.code === '40001' || err?.code === '22023' || /approval|DM|locked|governance/i.test(err?.message || '')
        ? err.message : friendlyError(err, 'The coins could not be changed. Nothing was changed.');
      preview.insertAdjacentHTML('afterbegin', `<p class="bg-eq-warn" role="alert" data-coin-error>${esc(msg)}</p>`);
    } finally {
      busy = false; undo.disabled = false;
      render();
    }
  };
  m.el.addEventListener('input', (e) => { if (e.target.matches('[data-coin]')) render(); });
  m.el.addEventListener('change', (e) => { if (e.target.name === 'coin-mode') { mode = e.target.value; render(); } });
  apply.addEventListener('click', () => {
    const before = getWallet();
    const { amount } = read();
    run('adjust_character_coins', { p_character: characterId, p_mode: mode, p_amount: amount, p_expected: before }, (data) => {
      last = { before: data.before, after: data.after };
      inputs.forEach((i) => { i.value = ''; });
      undo.hidden = false;
      toast(`${mode === 'spend' ? 'Spent' : 'Added'}: ${coinText(amount)}. Now ${coinText(data.after)}.`, 'good');
    });
  });
  undo.addEventListener('click', () => {
    if (!last) return;
    run('adjust_character_coins', { p_character: characterId, p_mode: 'set', p_amount: last.before, p_expected: last.after }, () => {
      last = null; undo.hidden = true;
      toast('Coin change undone.', 'good');
    });
  });
  render();
  setTimeout(() => inputs.find((i) => i.dataset.coin === 'gp')?.focus(), 60);
  return m;
}
