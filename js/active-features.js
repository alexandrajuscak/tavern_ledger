// Active class options in Play (docs/ACTIVE_CLASS_FEATURE_PRESENTATION.md). One shared presentation model, built from reads the
// sheet already has (get_character_class_features, get_character_resources, get_character_infusions): no extra request.
// Class features with a structured timing are rendered by sheet.js (classActions); this module adds the SELECTED OPTIONS of
// choice features (Eldritch Invocations, Metamagic, Fighting Style, Battle Master maneuvers, Hunter options, Pact Boon,
// Fiendish Resilience) using the option's catalog timing (data.activation, migration 20261107000400), and the Artificer
// infusions that are active on an item. Nothing is automated here: a reminder says so, and no Use button is invented.
//
// Lineage traits and feats (20261109000200, docs/ACTIVE_GAMEPLAY_FEATURE_AUDIT.md): sourceFeatures() builds the same compact card
// model from get_character_lineage, get_character_feats and get_character_resources plus the catalog table catalog_play_timing
// (the timing the catalog text states; read once per page session). No request per card and no rules evaluation here.
import { esc } from './utils.js?v=28';
import { icon } from './icons.js?v=28';
import { supabase } from './supabase.js?v=28';

export const PLAY_TIMINGS = ['action', 'bonus_action', 'reaction', 'special'];
const AUTOMATION = { automated: 'automatic', partially_automated: 'partly automatic', informational: 'reminder' };

/** Selected options with a timing, grouped: {action:[], bonus_action:[], reaction:[], special:[], passive:[], spell:[]}. */
export function selectedOptions(classFeatures, classResources) {
  const out = { action: [], bonus_action: [], reaction: [], special: [], passive: [], spell: [] };
  const res = classResources?.resources || classFeatures?.resources || [];
  for (const cls of classFeatures?.classes || []) {
    for (const c of cls.choices || []) {
      if (c.kind !== 'option' || !(c.values || []).length || c.enabled === false) continue;
      for (const v of c.values) {
        const o = (c.options || []).find((x) => x.id === v);
        const d = o?.data || {};
        const t = d.activation;
        if (!o || !t || t === 'item') continue;
        if (t === 'passive' && d.play !== 'reminder') continue;     // passive options stay on Build unless they matter in combat
        // the option's own counter (an invocation's daily cast): same feature unlock, named after the option (resource reads carry no option id)
        const uses = res.filter((r) => r.active !== false && r.unlock_id === c.unlock_id && (!r.character_class_id || r.character_class_id === cls.id)
          && String(r.name || '').toLowerCase().startsWith(String(o.label || '').toLowerCase()));
        (out[t] || out.special).push({
          key: `${c.key}:${v}`, name: o.label, summary: o.summary || '', feature: c.feature_name, className: cls.class_name,
          automation: d.automation || 'informational', cost: d.cost || null, uses, timing: t,
        });
      }
    }
  }
  return out;
}

const usesChips = (uses) => uses.filter((r) => r.max != null).map((r) =>
  `<span class="chip chip-quiet" data-action-uses="${esc(r.key)}">${esc(r.name)}: ${r.remaining} / ${r.max} left</span>`).join('');

/** One compact card: name, source, timing hint, concise effect, uses, automation tag. Details stay on Build. */
export function optionCardHTML(x) {
  const uses = usesChips(x.uses || []);
  const auto = AUTOMATION[x.automation] || 'reminder';
  return `<article class="entry action-card af-option" data-active-option="${esc(x.key)}">
    <div class="entry-head"><div class="entry-title"><h3 class="entry-name">${esc(x.name)}</h3>
      <div class="entry-sub">${esc(x.className)} · ${esc(x.feature)}${x.cost ? ` · ${esc(x.cost)} sorcery point${x.cost === '1' ? '' : 's'}` : ''}</div></div>
      <span class="badge af-auto af-${esc(x.automation)}" title="${auto === 'reminder' ? 'Not applied by the app: apply it yourself' : 'Applied by the app where it says so'}">${esc(auto)}</span></div>
    ${x.summary ? `<p class="entry-notes">${esc(x.summary)}</p>` : ''}
    ${uses ? `<div class="chip-row">${uses}</div>` : ''}
  </article>`;
}

/** "Passive and reminders" entries for options (combat-relevant passive choices). */
export function reminderListHTML(list) {
  if (!list.length) return '';
  return `<ul class="af-reminders small">${list.map((x) => `<li data-active-option="${esc(x.key)}"><strong>${esc(x.name)}</strong>
    <span class="muted">(${esc(x.className)} · ${esc(x.feature)})</span> ${esc(x.summary)}</li>`).join('')}</ul>`;
}

/** Infused items in Play: the infusion, the item that holds it and what it does (from the known infusion's text). */
export function infusionsPlayHTML(infusionState) {
  const active = infusionState?.active || [];
  if (!active.length) return '';
  const known = new Map((infusionState.choices?.[0]?.known || []).map((k) => [k.id, k]));
  return `<section class="play-section af-infusions" aria-labelledby="play-infusions" data-play-infusions>
    <h2 class="play-title" id="play-infusions">${icon('item.magic', { size: 24 })}Infused items <span class="hint">Artificer infusions in use</span></h2>
    <div class="entry-list">${active.map((a) => `<article class="entry action-card" data-play-infusion="${esc(a.id)}">
      <div class="entry-head"><div class="entry-title"><h3 class="entry-name">${esc(a.label)}</h3>
        <div class="entry-sub">Artificer Infusion · ${a.item_name ? `on ${esc(a.item_name)}` : a.companion_id ? 'companion created' : a.created_item ? 'replicated item' : 'no item'}${
          a.attunement ? ` · ${a.attuned ? 'attuned' : '<strong>needs attunement</strong>'}` : ''}</div></div></div>
      ${known.get(a.infusion_id)?.summary ? `<p class="entry-notes">${esc(known.get(a.infusion_id).summary)}</p>` : ''}
      ${a.known ? '' : '<p class="sp-warn small">You no longer know this infusion; end it on the Build page.</p>'}
    </article>`).join('')}</div>
    <p class="muted small">Bonuses an infusion gives to the item (attack, damage, AC) are already in your numbers; charges and special uses are reminders. Change infusions on the Build page.</p>
  </section>`;
}

/** Spells tab: class options that let you cast a spell (source "Warlock: Eldritch Invocations"). Automated ones are already
 *  in your spell list as granted spells, so only the others are listed here (no duplicate spell source). */
export function optionSpellsHTML(list) {
  const rest = list.filter((x) => x.automation !== 'automated');
  if (!rest.length) return '';
  return `<section class="card af-spell-options" data-option-spells><h3>From your class options <span class="hint">casts you track yourself</span></h3>
    <ul class="small">${rest.map((x) => `<li data-active-option="${esc(x.key)}"><strong>${esc(x.name)}</strong> <span class="muted">(${esc(x.className)}: ${esc(x.feature)})</span> ${esc(x.summary)}${
      usesChips(x.uses) ? ` ${usesChips(x.uses)}` : ''}</li>`).join('')}</ul></section>`;
}

/** inventory_item_id -> infusion label, for the Inventory badge. */
export function infusedItemMap(infusionState) {
  const m = new Map();
  for (const a of infusionState?.active || []) if (a.inventory_item_id) m.set(a.inventory_item_id, { label: a.label, attunement: a.attunement, attuned: a.attuned });
  return m;
}

// ---- lineage traits and feats in Play -------------------------------------------------------------------------------------------
let timingPromise = null;
/** Map 'lineage_trait:<id>' | 'feat_version:<id>' -> { timing, play }. Cached for the page session; empty when unavailable
 *  (an older database without the table): Play then simply shows no lineage / feat cards, as before. */
export function loadPlayTiming() {
  timingPromise ||= supabase.from('catalog_play_timing').select('source_kind, source_id, timing, play').limit(5000)
    .then(({ data, error }) => {
      if (error) { timingPromise = null; return new Map(); }
      return new Map((data || []).map((r) => [`${r.source_kind}:${r.source_id}`, { timing: r.timing, play: r.play }]));
    }, () => { timingPromise = null; return new Map(); });
  return timingPromise;
}

const LINEAGE_AUTOMATION = { automatic: 'automated', partial: 'partially_automated', informational: 'informational' };
const RECHARGE = { short_rest: 'short rest', long_rest: 'long rest', short_or_long_rest: 'short or long rest', special: 'special' };

/**
 * Lineage traits and feats that matter during play, as compact cards:
 * { key, featureId, versionId, name, sourceType: 'lineage'|'feat', sourceName, timing, play: 'card'|'resource'|'reminder',
 *   summary, uses: [resource], recovery, automation, state, spells: [names] },
 * grouped {action, bonus_action, reaction, special, passive, resource}.
 */
export function sourceFeatures({ lineage, feats, resources, timing }) {
  const out = { action: [], bonus_action: [], reaction: [], special: [], passive: [], resource: [] };
  const map = timing instanceof Map ? timing : new Map();
  const res = resources?.resources || [];
  const lineageName = lineage?.subversion?.name || lineage?.version?.name || lineage?.lineage?.name || 'Lineage';
  for (const t of lineage?.traits || []) {
    if (t.status && t.status !== 'active') continue;
    const tm = map.get(`lineage_trait:${t.id}`);
    if (!tm) continue;
    const uses = res.filter((r) => r.source_type === 'lineage' && r.source_id === t.id && r.active !== false);
    place(out, { key: `lin:${t.id}`, featureId: t.id, versionId: t.version_id, name: t.name, sourceType: 'lineage', sourceName: lineageName,
      timing: tm.timing, play: tm.play, summary: t.summary || '', uses, recovery: RECHARGE[t.recharge] || null,
      automation: LINEAGE_AUTOMATION[t.automation] || 'informational', state: 'applied', spells: [] });
  }
  for (const g of feats?.feats || []) {
    if (!g.active) continue;
    const f = g.feat || {};
    const tm = map.get(`feat_version:${f.id}`);
    const uses = res.filter((r) => r.source_type === 'feat' && r.source_id === g.grant_key && r.active !== false && !r.spell_version_id);
    if (!tm && !uses.length) continue;
    place(out, { key: `feat:${g.grant_key}`, featureId: g.grant_key, versionId: f.id, name: f.name, sourceType: 'feat',
      sourceName: g.source_label || 'Feat', timing: tm?.timing || null, play: tm?.play || 'resource', summary: f.summary || '', uses,
      recovery: uses[0]?.recharge ? (RECHARGE[uses[0].recharge] || null) : null,
      automation: f.automation || 'informational', state: g.state || (g.open_choices ? 'incomplete' : 'applied'),
      spells: (g.spells || []).map((s) => s.name) });
  }
  return out;
}

function place(out, card) {
  if (card.play === 'card' && card.timing && out[card.timing]) out[card.timing].push(card);
  else if (card.play === 'reminder') out.passive.push(card);
  else out.resource.push(card);
}

const AUTOMATION_LABEL = { automated: 'automatic', partially_automated: 'partly automatic', informational: 'reminder only' };
const TIMING_LABEL = { action: 'Action', bonus_action: 'Bonus action', reaction: 'Reaction', special: 'Special' };

/** A lineage trait or feat card for Play: name, source, timing, concise effect, uses, automation. No Use button on the card: a
 *  counter's Use button is in Ready to use, and a reminder says that the app does not apply it. */
export function sourceCardHTML(x) {
  const uses = usesChips(x.uses || []);
  const auto = AUTOMATION_LABEL[x.automation] || 'reminder only';
  return `<article class="entry action-card af-source af-${esc(x.sourceType)}" data-active-feature="${esc(x.key)}" data-source-type="${esc(x.sourceType)}">
    <div class="entry-head"><div class="entry-title"><h3 class="entry-name">${esc(x.name)}</h3>
      <div class="entry-sub">${esc(x.sourceName)}${x.timing ? ` · ${esc(TIMING_LABEL[x.timing] || x.timing)}` : ''}${x.recovery ? ` · recovers on a ${esc(x.recovery)}` : ''}</div></div>
      <span class="badge af-auto af-${esc(x.automation)}" title="${auto === 'reminder only' ? 'Not applied by the app: apply it yourself' : 'Applied by the app where it says so'}">${esc(auto)}</span></div>
    ${x.summary ? `<p class="entry-notes">${esc(x.summary)}</p>` : ''}
    ${x.state === 'incomplete' || x.state === 'invalidated' ? '<p class="sp-warn small">Choices are still open: finish them on the Build tab.</p>' : ''}
    ${uses ? `<div class="chip-row">${uses}</div>` : ''}
  </article>`;
}

/** Passive reminders of lineage traits and feats (one line each). */
export function sourceReminderListHTML(list) {
  if (!list.length) return '';
  return `<ul class="af-reminders small">${list.map((x) => `<li data-active-feature="${esc(x.key)}"><strong>${esc(x.name)}</strong>
    <span class="muted">(${esc(x.sourceName)})</span> ${esc(x.summary)}</li>`).join('')}</ul>`;
}

const usesText = (uses) => (uses || []).filter((r) => r.max != null).map((r) => `${r.remaining}/${r.max}`).join(', ');

/** Compact list for the Combat Builder character detail: what the linked character can use, by timing (names and uses). */
export function compactActiveFeaturesHTML({ classFeatures, classResources, feats, lineage, timing }) {
  const opts = selectedOptions(classFeatures, classResources);
  const src = sourceFeatures({ lineage, feats, resources: classResources, timing });
  const classRes = classResources?.resources || classFeatures?.resources || [];
  const item = (name, uses) => `${esc(name)}${uses ? ` <span class="muted">${esc(uses)}</span>` : ''}`;
  const rows = [];
  for (const key of PLAY_TIMINGS) {
    const names = [];
    for (const cls of classFeatures?.classes || []) {
      for (const f of cls.features || []) {
        if (f.status !== 'active' || f.activation !== key) continue;
        names.push(item(f.name, usesText(classRes.filter((r) => r.unlock_id === f.unlock_id && r.character_class_id === cls.id && r.active))));
      }
    }
    for (const x of [...(opts[key] || []), ...(src[key] || [])]) names.push(item(x.name, usesText(x.uses)));
    if (names.length) rows.push(`<div class="cb-af-row" data-cb-af="${key}"><dt>${key === 'special' ? 'Free / special' : `${TIMING_LABEL[key]}s`}</dt><dd>${names.join(' · ')}</dd></div>`);
  }
  const limited = src.resource.filter((x) => usesText(x.uses));
  if (limited.length) rows.push(`<div class="cb-af-row" data-cb-af="resource"><dt>Limited uses</dt><dd>${limited.map((x) => item(x.name, usesText(x.uses))).join(' · ')}</dd></div>`);
  return rows.length ? `<dl class="cb-active-features">${rows.join('')}</dl>` : '<p class="muted small">No features with an action timing.</p>';
}
