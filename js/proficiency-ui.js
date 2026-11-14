// Proficiencies on the Abilities tab, from the authoritative resolver get_character_proficiencies (20261017001100).
// Three states: active from a grant (class, lineage, background, feature), active by a manual mark, inactive.
// Derived grants are never removed from here: a click explains where they come from (and where to change them);
// manual marks stay editable. Nothing is copied into manual rows. docs/PROFICIENCY_RESOLUTION.md
import { esc, openModal } from './utils.js?v=36';

const KIND_ORDER = { class: 0, feature: 1, background: 2, lineage: 3, item: 4, import: 5, manual: 6 };
const KIND_WORD = { class: 'class', feature: 'class feature', background: 'background', lineage: 'lineage', item: 'item', manual: 'your manual mark',
  import: 'an imported sheet' };
const WHERE = { class: 'classes', feature: 'classes', background: 'background', lineage: 'lineage' };

const sorted = (sources) => [...(sources || [])].sort((a, b) => (KIND_ORDER[a.kind] ?? 9) - (KIND_ORDER[b.kind] ?? 9) || String(a.label).localeCompare(b.label));
export const derivedSources = (e) => sorted((e?.sources || []).filter((s) => s.kind !== 'manual' && s.kind !== 'import'));

/** "Fighter · Mountain Dwarf · Manual" badges (text, never color only). */
export function sourceBadgesHTML(sources, { max = 3 } = {}) {
  const list = sorted(sources);
  if (!list.length) return '';
  const shown = list.slice(0, max).map((s) => `<span class="src-badge src-${esc(s.kind)}"${s.expertise ? ' data-expertise' : ''}>${esc(s.label)}${s.expertise ? ' (expertise)' : ''}</span>`);
  if (list.length > max) {
    const rest = list.slice(max).map((s) => s.label).join(', ');
    shown.push(`<span class="src-badge src-more" title="${esc(rest)}" aria-label="and ${esc(rest)}">+${list.length - max}</span>`);
  }
  return `<span class="src-badges">${shown.join('')}</span>`;
}

/** Plain words for a tooltip / aria-label: "Proficient: Fighter, Manual". */
export function sourceText(e) {
  if (!e?.effective) return 'Not proficient';
  const lvl = e.level === 2 ? 'Expertise' : 'Proficient';
  return `${lvl}: ${sorted(e.sources).map((s) => `${s.label}${s.kind !== 'manual' && s.kind !== 'feature' ? ` (${KIND_WORD[s.kind] || s.kind})` : ''}${
    s.expertise ? ', expertise' : ''}`).join('; ')}`;
}

/** The weapon / armor group chips. `flagOf` maps a group id to the old manual flag key (data-k). */
export function proficiencyChipsHTML(state, groups, { flagOf, pendingManual = {} } = {}) {
  return groups.map((g) => {
    const e = state?.groups?.find((x) => x.id === g.id);
    const flag = flagOf(g.id);
    const manual = flag in pendingManual ? pendingManual[flag] : !!e?.manual;
    const derived = derivedSources(e);
    const active = manual || derived.length > 0;
    const st = derived.length ? 'derived' : manual ? 'manual' : 'off';
    const label = `${g.label}: ${active ? `active, ${[...derived.map((s) => s.label), ...(manual ? ['Manual'] : [])].join(', ')}` : 'not proficient'}`;
    return `<button type="button" class="chip-toggle prof-chip${active ? ' on' : ''}" data-action="toggle-equip" data-k="${esc(flag)}" data-state="${st}"
      data-focus-key="prof-chip:${esc(flag)}" aria-pressed="${active}" aria-label="${esc(label)}" title="${esc(label)}">
      <span class="prof-chip-name">${esc(g.label)}</span>${sourceBadgesHTML([...derived, ...(manual ? [{ kind: 'manual', label: 'Manual' }] : [])], { max: 3 })}</button>`;
  }).join('');
}

/** Specific weapons / armor / tools and languages, each with its sources; Remove only for a manual mark. */
export function proficiencyDetailsHTML(state, { editable = true } = {}) {
  if (!state) return '<p class="muted small">Loading…</p>';
  const TYPE = { weapon: 'Weapon', armor: 'Armor', shield: 'Shield', tool: 'Tool' };
  const items = state.items || [];
  const row = (e) => `<li data-prof-item="${esc(e.id)}"><span>${esc(e.name)} <span class="muted small">${TYPE[e.type] || ''}${e.expertise ? ' · expertise' : ''}</span>
      ${sourceBadgesHTML(e.sources)}</span>
      ${editable && e.manual ? `<button type="button" class="btn btn-sm btn-ghost" data-action="prof-remove" data-item="${esc(e.id)}" data-focus-key="prof-remove:${esc(e.id)}" aria-label="Remove your manual ${esc(e.name)} proficiency${e.derived ? ' (it stays: also granted)' : ''}">Remove manual</button>` : ''}</li>`;
  const langs = state.languages || [];
  return `${items.length ? `<h4 class="prof-sub">Specific weapons, armor and tools</h4><ul class="prof-items">${items.map(row).join('')}</ul>`
    : '<p class="muted small">No specific weapon, armor or tool proficiencies.</p>'}
    ${langs.length ? `<h4 class="prof-sub">Languages</h4><ul class="prof-items" data-prof-languages>${langs.map((l) => `<li data-prof-language="${esc(l.id)}"><span>${esc(l.name)} ${sourceBadgesHTML(l.sources)}</span></li>`).join('')}</ul>` : ''}`;
}

/**
 * A click on a granted proficiency: explain where it comes from instead of deleting anything.
 * onGoto(where) opens the source (classes | lineage | background); onManual(enabled) adds or removes the manual mark.
 */
export function openProficiencySource(entry, name, { onGoto, onManual } = {}) {
  const derived = derivedSources(entry);
  const where = [...new Set(derived.map((s) => WHERE[s.kind]).filter(Boolean))];
  const m = openModal({
    title: name,
    body: `<p>${esc(name)} is active because of:</p>
      <ul class="prof-why">${derived.map((s) => `<li><strong>${esc(s.label)}</strong> <span class="muted small">(${esc(KIND_WORD[s.kind] || s.kind)}${s.detail && s.detail !== s.label ? `: ${esc(s.detail)}` : ''})</span></li>`).join('')}
        ${entry?.manual ? '<li><strong>Manual</strong> <span class="muted small">(your own mark)</span></li>' : ''}</ul>
      <p class="muted small">A granted proficiency cannot be switched off here. It goes away when its source changes
        ${where.length ? `(${where.map((w) => `your ${w}`).join(', ')})` : ''}. ${entry?.manual
          ? 'Removing your manual mark keeps the granted proficiency.' : 'You can also mark it manually, so it stays if the source changes later.'}</p>`,
    footer: `${where.map((w) => `<button type="button" class="btn" data-goto="${w}">Open ${w}</button>`).join('')}
      <button type="button" class="btn" data-manual="${entry?.manual ? 'off' : 'on'}">${entry?.manual ? 'Remove manual mark' : 'Also mark manually'}</button>
      <button type="button" class="btn btn-gold" data-close>OK</button>`,
  });
  m.el.addEventListener('click', async (e) => {
    const g = e.target.closest('[data-goto]');
    const man = e.target.closest('[data-manual]');
    if (g) { m.close(); onGoto?.(g.dataset.goto); }
    if (man) { man.disabled = true; await onManual?.(man.dataset.manual === 'on'); m.close(); }
  });
  setTimeout(() => { if (m.isTop()) m.el.querySelector('[data-close].btn')?.focus(); }, 60);
  return m;
}
