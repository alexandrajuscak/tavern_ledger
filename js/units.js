// Measurement display (R-A, docs/MEASUREMENT_UNITS.md): US (feet, miles, pounds, inches) as stored, or Metric for the viewer.
// DISPLAY ONLY: stored data, RPC payloads, inputs and what the DM enters stay in US units. The official metric D&D convention:
// 5 ft = 1.5 m (1 ft = 0.3 m), 1 mile = 1.5 km, 1 lb = 0.5 kg, 1 inch = 2.5 cm. Gallons and pints stay as they are.
// * metricText(text): THE one conversion of free text (pure, unit-tested in supabase/tests/js/units.test.mjs).
// * The viewer's choice lives in localStorage ('tavern-ledger:units'); every access is wrapped (private mode, blocked storage:
//   the app keeps working, the choice then lasts for the page only). Default: US.
// * startUnitsDisplay(): while Metric is on, the visible text of the page is shown converted (each text node keeps its original
//   and is restored when the viewer switches back); new text is converted as it appears. Inputs, text areas, editable areas,
//   code and anything inside [data-units-skip] are never touched. With US (the default) nothing observes the page.
const KEY = 'tavern-ledger:units';
let memory = 'us';

/** 'us' or 'metric' (the viewer's choice; default 'us'). */
export function getUnits() {
  try {
    const v = globalThis.localStorage?.getItem(KEY);
    if (v === 'us' || v === 'metric') return v;
  } catch { /* storage blocked: the in-page choice */ }
  return memory;
}
export const isMetric = () => getUnits() === 'metric';

const listeners = new Set();
/** Call fn(units) after every change; returns the unsubscribe function. */
export function onUnitsChange(fn) { listeners.add(fn); return () => listeners.delete(fn); }

/** Switch the display units for this viewer, at once (no reload). */
export function setUnits(units) {
  const v = units === 'metric' ? 'metric' : 'us';
  memory = v;
  try { globalThis.localStorage?.setItem(KEY, v); } catch { /* storage blocked: kept for this page */ }
  applyDocument();
  listeners.forEach((fn) => { try { fn(v); } catch (err) { console.warn('[units]', err?.message || err); } });
}

// ---- numbers ---------------------------------------------------------------------------------------------------------------------
const round = (n) => Math.round(n * 100) / 100;
/** 1234.5 -> "1,234.5"; never more than two decimals. */
export const num = (n) => round(n).toLocaleString('en-US', { maximumFractionDigits: 2 });
export const feetToMeters = (ft) => round(Number(ft) * 0.3);
export const milesToKm = (mi) => round(Number(mi) * 1.5);
export const poundsToKg = (lb) => round(Number(lb) * 0.5);
export const inchesToCm = (inch) => round(Number(inch) * 2.5);

/** A distance stored in feet, in the viewer's units: "30 ft" / "9 m". */
export function fmtDistance(ft, metric = isMetric()) {
  if (ft == null || ft === '' || Number.isNaN(Number(ft))) return '';
  return metric ? `${num(feetToMeters(ft))} m` : `${num(Number(ft))} ft`;
}
/** Only the number of a distance in the viewer's units ("30" / "9"), for places that print the unit separately. */
export const distanceNumber = (ft, metric = isMetric()) => (ft == null || ft === '' ? '' : num(metric ? feetToMeters(ft) : Number(ft)));
export const distanceUnit = (metric = isMetric()) => (metric ? 'm' : 'ft');
/** A weight stored in pounds, in the viewer's units: "5 lb" / "2.5 kg". */
export function fmtWeight(lb, metric = isMetric()) {
  if (lb == null || lb === '' || Number.isNaN(Number(lb))) return '';
  return metric ? `${num(poundsToKg(lb))} kg` : `${num(Number(lb))} lb`;
}

// ---- free text --------------------------------------------------------------------------------------------------------------------
// A number: 1,000 / 1000 / 2.5 / .5 is not used in the rules; never part of a word, a dice expression (1d10), a fraction or a range
// handled elsewhere (the look-behind refuses a letter, digit, '.', '/', ',' right before it, or a hyphen right after a word or
// digit: "1d10", "CR 1/2", "x-5", "5-6"). A minus sign before the number is fine: "Speed -10 ft", "Speed −10 ft".
const N = String.raw`(?<![\w./,])(?<!\w[-–])(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)`;
const M = String.raw`(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)`;   // the second number of a pair
const parse = (s) => Number(String(s).replace(/,/g, ''));
const RULES = [
  // ranges with a unit: "150/600 ft", "20/60 feet"
  [new RegExp(`${N}\\s*/\\s*(\\d{1,3}(?:,\\d{3})+|\\d+)(\\s*)(feet|foot|ft)(?![a-z])`, 'gi'),
    (m, a, b, sp, u) => `${num(feetToMeters(parse(a)))}/${num(feetToMeters(parse(b)))}${sp}${/^ft$/i.test(u) ? 'm' : 'meters'}`],
  // "range 150/600" without a unit (weapon property text): always feet in the rules
  [/\b(range\s+)(\d{1,4})\s*\/\s*(\d{1,4})\b(?!\s*(?:\/|ft|feet|foot|m\b|meters?|km))/gi,
    (m, pre, a, b) => `${pre}${num(feetToMeters(parse(a)))}/${num(feetToMeters(parse(b)))} m`],
  // two numbers sharing one unit: "5-by-5-foot", "10 x 10 ft", "10 × 10 ft", "10 by 10 feet", "2 or 3 feet", "15-20 ft", "15–20 ft"
  [new RegExp(`${N}-by-${M}-(foot|feet|ft)(?![a-z])`, 'gi'),
    (m, a, b) => `${num(feetToMeters(parse(a)))}-by-${num(feetToMeters(parse(b)))}-meter`],
  [new RegExp(`${N}(\\s*(?:x|×|by|or|to)\\s*|\\s*[-–]\\s*)${M}(\\s*)(feet|foot|ft)(?![a-z])`, 'gi'),
    (m, a, mid, b, sp, u) => `${num(feetToMeters(parse(a)))}${mid}${num(feetToMeters(parse(b)))}${sp}${/^ft$/i.test(u) ? 'm' : 'meters'}`],
  // "5-foot", "10-foot-radius", "60-foot-long", "1-mile"
  [new RegExp(`${N}-(foot|feet|ft)(?![a-z])`, 'gi'), (m, a) => `${num(feetToMeters(parse(a)))}-meter`],
  [new RegExp(`${N}-(miles?)(?![a-z])`, 'gi'), (m, a) => `${num(milesToKm(parse(a)))}-km`],
  [new RegExp(`${N}-(inch(?:es)?)(?![a-z])`, 'gi'), (m, a) => `${num(inchesToCm(parse(a)))}-cm`],
  [new RegExp(`${N}-(pounds?|lbs?)(?![a-z])`, 'gi'), (m, a) => `${num(poundsToKg(parse(a)))}-kg`],
  // "60 feet", "30 ft.", "1 foot", "5ft" ("100 square feet" / "2 cubic feet" were set aside by metricText: not linear)
  [new RegExp(`${N}(\\s*)(feet|foot|ft)(?![a-z])`, 'gi'), (m, a, sp, u) => {
    const v = feetToMeters(parse(a));
    return `${num(v)}${sp}${/^ft$/i.test(u) ? 'm' : v === 1 ? 'meter' : 'meters'}`;
  }],
  [new RegExp(`${N}(\\s*)(miles?|mi\\.)(?![a-z])`, 'gi'), (m, a, sp, u) => `${num(milesToKm(parse(a)))}${sp}km${u === 'mi.' ? '.' : ''}`],
  [new RegExp(`${N}(\\s*)(inch(?:es)?)(?![a-z])`, 'gi'), (m, a, sp) => `${num(inchesToCm(parse(a)))}${sp}cm`],
  // "12 in." only with the period followed by a space, the end or punctuation: never the word "in" ("3 in a row")
  [new RegExp(`${N}(\\s*)in\\.(?=\\s|$|[,;:)])`, 'gi'), (m, a, sp) => `${num(inchesToCm(parse(a)))}${sp}cm.`],
  [new RegExp(`${N}(\\s*)(lbs?\\.?|pounds?)(?![a-z])`, 'gi'), (m, a, sp, u) => {
    const v = poundsToKg(parse(a));
    if (/^pound/i.test(u)) return `${num(v)}${sp}${v === 1 ? 'kilogram' : 'kilograms'}`;
    return `${num(v)}${sp}kg${u.endsWith('.') ? '.' : ''}`;
  }],
];

/** Free text with every US measurement converted to metric (dice, DCs, levels, money, area / volume units untouched). */
export function metricText(text) {
  if (text == null) return text;
  let s = String(text);
  if (!/\d/.test(s) || !/(ft|feet|foot|mile|mi\.|inch|in\.|lb|pound|range)/i.test(s)) return s;
  // "square feet" / "cubic feet": protect the whole measure first
  const kept = [];
  s = s.replace(/\d[\d,.]*\s*(?:square|cubic|sq\.?|cu\.?)\s*(?:feet|foot|ft)\b/gi, (m) => { kept.push(m); return `\u0000${kept.length - 1}\u0000`; });
  for (const [re, fn] of RULES) s = s.replace(re, fn);
  return s.replace(/\u0000(\d+)\u0000/g, (m, i) => kept[Number(i)]);
}
/** The text in the viewer's units. */
export const displayText = (text, metric = isMetric()) => (metric ? metricText(text) : text);

// ---- the page --------------------------------------------------------------------------------------------------------------------
const SKIP = new Set(['SCRIPT', 'STYLE', 'TEXTAREA', 'INPUT', 'SELECT', 'CODE', 'PRE', 'NOSCRIPT', 'TEMPLATE']);
const originals = new WeakMap();   // text node -> { us: original text, shown: what we wrote }
const touched = new Set();         // weak-enough: nodes we changed, to restore them (pruned when detached)
let observer = null;
let started = false;

function skipped(node) {
  for (let el = node.parentElement; el; el = el.parentElement) {
    if (SKIP.has(el.tagName) || el.isContentEditable || el.hasAttribute?.('data-units-skip')) return true;
  }
  return false;
}
function convertNode(t) {
  const prev = originals.get(t);
  if (prev && t.data === prev.shown) return;              // our own text
  const us = t.data;                                      // new text written by the app (always US)
  const shown = metricText(us);
  if (shown === us) { if (prev) { originals.delete(t); touched.delete(t); } return; }
  originals.set(t, { us, shown });
  touched.add(t);
  t.data = shown;
}
function walk(root) {
  if (!root) return;
  if (root.nodeType === 3) { if (!skipped(root)) convertNode(root); return; }
  if (root.nodeType !== 1 && root.nodeType !== 9 && root.nodeType !== 11) return;
  if (root.nodeType === 1 && (SKIP.has(root.tagName) || root.hasAttribute('data-units-skip') || skipped(root))) return;
  const it = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => (/\d/.test(n.data) && !skipped(n) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT),
  });
  for (let n = it.nextNode(); n; n = it.nextNode()) convertNode(n);
}
function restoreAll() {
  for (const t of touched) {
    const o = originals.get(t);
    if (o && t.data === o.shown) t.data = o.us;
    originals.delete(t);
  }
  touched.clear();
}
function applyDocument() {
  if (!started || typeof document === 'undefined') return;
  const metric = isMetric();
  document.documentElement.classList.toggle('units-metric', metric);
  if (metric) {
    walk(document.body);
    if (!observer) {
      observer = new MutationObserver((list) => {
        for (const m of list) {
          if (m.type === 'characterData') { if (!skipped(m.target)) convertNode(m.target); continue; }
          m.addedNodes.forEach(walk);
        }
        if (touched.size > 5000) for (const t of touched) if (!t.isConnected) touched.delete(t);
      });
      observer.observe(document.body, { subtree: true, childList: true, characterData: true });
    }
  } else {
    observer?.disconnect();
    observer = null;
    restoreAll();
  }
}
/** Start the display layer once (js/app.js boot). Nothing is observed while the viewer uses US units. */
export function startUnitsDisplay() {
  if (started || typeof document === 'undefined') return;
  started = true;
  applyDocument();
}

/** The viewer's switch (US / Metric) as a small segmented control; wire it with bindUnitsSwitch(container). */
export function unitsSwitchHTML() {
  const m = isMetric();
  return `<div class="units-switch" role="radiogroup" aria-label="Measurement units" data-units-switch>
    <button type="button" role="radio" class="btn btn-sm${m ? '' : ' is-on'}" aria-checked="${!m}" data-units="us">US (feet, pounds)</button>
    <button type="button" role="radio" class="btn btn-sm${m ? ' is-on' : ''}" aria-checked="${m}" data-units="metric">Metric (meters, kilograms)</button>
  </div>`;
}
/** Clicks (and arrow keys) on [data-units] inside container switch the units; every switch on the page follows. */
export function bindUnitsSwitch(container) {
  if (!container || container.__unitsBound) return;
  container.__unitsBound = true;
  container.addEventListener('click', (e) => {
    const b = e.target.closest?.('[data-units]');
    if (b && container.contains(b)) setUnits(b.dataset.units);
  });
  container.addEventListener('keydown', (e) => {
    const b = e.target.closest?.('[data-units]');
    if (!b || !['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(e.key)) return;
    e.preventDefault();
    const next = b.dataset.units === 'us' ? 'metric' : 'us';
    setUnits(next);
    container.querySelector(`[data-units="${next}"]`)?.focus();
  });
}
/** Keep every rendered switch in sync with the current choice. */
onUnitsChange((u) => {
  if (typeof document === 'undefined') return;
  document.querySelectorAll('[data-units-switch] [data-units]').forEach((b) => {
    const on = b.dataset.units === u;
    b.classList.toggle('is-on', on);
    b.setAttribute('aria-checked', String(on));
  });
});
