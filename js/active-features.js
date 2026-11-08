// Active class options in Play (docs/ACTIVE_CLASS_FEATURE_PRESENTATION.md). One shared presentation model, built from reads the
// sheet already has (get_character_class_features, get_character_resources, get_character_infusions): no extra request.
// Class features with a structured timing are rendered by sheet.js (classActions); this module adds the SELECTED OPTIONS of
// choice features (Eldritch Invocations, Metamagic, Fighting Style, Battle Master maneuvers, Hunter options, Pact Boon,
// Fiendish Resilience) using the option's catalog timing (data.activation, migration 20261107000400), and the Artificer
// infusions that are active on an item. Nothing is automated here: a reminder says so, and no Use button is invented.
import { esc } from './utils.js?v=18';
import { icon } from './icons.js?v=18';

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
