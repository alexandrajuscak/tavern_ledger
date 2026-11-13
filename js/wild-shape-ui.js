// Wild Shape: the idle panel, the active-form mode, the form picker with filters / favorites / compare, the transformation
// review and the HP, healing and revert flows (docs/WILD_SHAPE_UI.md). Every number comes from get_character_transformation
// (the authoritative transformed sheet); this module renders and sends player decisions only. No class names in rules.
import { $, $$, esc, toast, openModal, confirmDialog } from './utils.js?v=26';
import * as api from './creature-api.js?v=26';
import { icon } from './icons.js?v=26';

const ABIL = ['str', 'dex', 'con', 'int', 'wis', 'cha'];
const AB = { str: 'STR', dex: 'DEX', con: 'CON', int: 'INT', wis: 'WIS', cha: 'CHA' };
const sgn = (n) => (Number(n) >= 0 ? `+${Number(n)}` : `−${Math.abs(Number(n))}`);
const crText = (v) => ({ 0.125: '1/8', 0.25: '1/4', 0.5: '1/2' }[Number(v)] || String(Number(v)));
const cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : '');
const MOVES = ['walk', 'climb', 'swim', 'fly', 'burrow'];
const MOVE_ICON = Object.fromEntries(['walk', 'climb', 'swim', 'fly', 'burrow'].map((k) => [k, icon(`movement.${k}`, { size: 16 })]));
const SENSE_LABEL = { darkvision: 'Darkvision', blindsight: 'Blindsight', tremorsense: 'Tremorsense', truesight: 'Truesight' };
const GROUPS = [['combat', 'Combat'], ['movement', 'Movement'], ['senses', 'Senses'], ['defense', 'Defense'], ['utility', 'Utility'], ['other', 'Other']];
const STATUS = {
  eligible_seen: { label: 'Seen · can take', icon: '✓', cls: 'ok' },
  eligible_unseen: { label: 'Can take · not marked seen', icon: '◐', cls: 'warn' },
  eligible_unrestricted: { label: 'Can take', icon: '✓', cls: 'ok' },
  dm_granted: { label: 'DM-granted exception', icon: '★', cls: 'grant' },
  unseen_locked: { label: 'Locked: not seen yet', icon: icon('ui.locked', { size: 14 }), cls: 'locked' },
  ineligible: { label: 'Locked', icon: icon('ui.locked', { size: 14 }), cls: 'locked' },
};
const speedText = (sp) => MOVES.filter((k) => sp?.[k]).map((k) => (k === 'walk' ? `${sp[k]} ft` : `${k} ${sp[k]} ft`)).join(' · ');
const avgDice = (d) => {        // "2d6+4" -> 11 (average, for the compact card only)
  const m = String(d || '').replace(/\s/g, '').match(/^(\d+)d(\d+)([+-]\d+)?$/);
  return m ? Math.floor(Number(m[1]) * (Number(m[2]) + 1) / 2 + Number(m[3] || 0)) : Number(d) || 0;
};
const dmgText = (a) => (a.damage || []).map((d) => `${esc(String(d.dice).replace('+', ' + '))} ${esc(d.type || '')}`).join(' plus ');

// ------------------------------------------------------------------------------------------------------------ idle panel
/** The Wild Shape panel: the active form (full mode or a compact link) or the idle state with the uses and limits. */
export function wildShapePanelHTML(tf, { editable = true, place = 'combat' } = {}) {
  if (!tf || !(tf.rules || []).length) return '';
  if (tf.active) return place === 'combat' ? activeFormHTML(tf, { editable }) : activeSummaryHTML(tf);
  const res = (tf.resources || [])[0];
  const beast = (tf.rules || []).filter((r) => (r.creature_types || []).includes('beast'));
  const maxCr = Math.max(...beast.map((r) => Number(r.max_cr ?? 0)));
  const swimFrom = Math.min(...beast.map((r) => r.swim_from ?? 0));
  const flyFrom = Math.min(...beast.map((r) => r.fly_from ?? 0));
  const lvl = tf.druid_level;
  const usable = (tf.options || []).filter((o) => o.allowed);
  const favs = usable.filter((o) => o.favorite).slice(0, 6);
  const out = res && !res.unlimited && res.remaining <= 0;
  return `<section class="ws-panel ws-idle" data-transform="idle" aria-labelledby="ws-idle-title">
    <div class="ws-idle-head">
      <h3 id="ws-idle-title">${esc(res?.name || 'Wild Shape')}</h3>
      <span class="ws-uses" data-ws-uses>${res ? (res.unlimited ? '<strong>Unlimited</strong>' : `<strong>${res.remaining} / ${res.max}</strong> uses`) : ''}</span>
    </div>
    <ul class="ws-limits small">
      <li>Druid level <strong>${lvl ?? '—'}</strong>${tf.total_level && tf.total_level !== lvl ? ` <span class="muted">(character level ${tf.total_level}: Wild Shape uses the Druid level)</span>` : ''}</li>
      <li>Beast forms up to <strong>CR ${crText(maxCr)}</strong>${tf.moon ? ' <span class="ws-tag">Circle of the Moon</span>' : ''}</li>
      <li>${lvl >= swimFrom ? '✓ Swimming forms' : `${icon('ui.locked', { size: 14 })}Swimming forms from Druid ${swimFrom}`} · ${lvl >= flyFrom ? '✓ Flying forms' : `${icon('ui.locked', { size: 14 })}Flying forms from Druid ${flyFrom}`}</li>
      ${(tf.options || []).some((o) => o.elemental) ? '<li>✓ Elemental Wild Shape (2 uses)</li>' : ''}
      <li class="muted">Seen forms: ${{ enforce: 'required', warn: 'warning only', unrestricted: 'not required (DM)' }[tf.settings?.seen_mode] || 'warning only'} · ${usable.length} form${usable.length === 1 ? '' : 's'} available</li>
    </ul>
    ${editable ? `<div class="ws-idle-actions">
      <button type="button" class="btn btn-gold" data-action="tf-pick" data-focus-key="tf-pick" ${out ? 'disabled aria-describedby="ws-out"' : ''}>Choose a form…</button>
      ${out ? '<span class="muted small" id="ws-out">No uses left: a short or long rest restores them.</span>' : ''}
      ${favs.length ? `<span class="ws-favs" role="group" aria-label="Favorite forms">${favs.map((o) => `<button type="button" class="btn btn-sm" data-action="tf-quick"
        data-creature="${esc(o.id)}" data-focus-key="tf-quick:${esc(o.id)}" ${out ? 'disabled' : ''}>★ ${esc(o.name)}</button>`).join('')}</span>` : ''}
    </div>` : ''}
  </section>`;
}

function activeSummaryHTML(tf) {
  const s = tf.active.sheet;
  return `<section class="ws-panel ws-active-mini" data-transform="active">
    <h3>In Wild Shape: ${esc(tf.active.name)}</h3>
    <p class="small">Form HP <strong>${s.hp.current} / ${s.hp.max}</strong> · AC ${s.armor_class.value} · ${esc(speedText(s.speed))}</p>
    <button type="button" class="btn btn-sm btn-gold" data-action="tf-open-combat" data-focus-key="tf-open-combat">Open the Wild Shape sheet (Play tab)</button>
  </section>`;
}

// ------------------------------------------------------------------------------------------------------------ active mode
function hpBlockHTML(s, { editable }) {
  const pct = Math.max(0, Math.min(100, Math.round((s.hp.current / s.hp.max) * 100)));
  const state = s.hp.state;
  return `<div class="ws-hp" data-hp-state="${state}">
    <div class="ws-hp-form">
      <span class="ws-label">Wild Shape HP</span>
      <span class="ws-hp-num" data-ws-form-hp><strong>${s.hp.current}</strong> / ${s.hp.max}${s.hp.temp ? ` <span class="ws-temp">+${s.hp.temp} temp</span>` : ''}</span>
      <meter class="ws-hpbar" min="0" max="${s.hp.max}" value="${s.hp.current}" low="${Math.ceil(s.hp.max / 4) + 0.5}" high="${Math.ceil(s.hp.max / 2) + 0.5}"
        optimum="${s.hp.max}" aria-label="Form hit points ${s.hp.current} of ${s.hp.max}, ${state}">${pct}%</meter>
      <span class="ws-hp-state">${state === 'critical' ? 'Critical: the form is close to ending; excess damage will hit your normal form.'
        : state === 'wounded' ? '◐ Wounded' : '● Healthy'}</span>
    </div>
    <div class="ws-hp-normal">
      <span class="ws-label">Normal form HP</span>
      <span data-ws-normal-hp><strong>${s.hp.normal_current}</strong> / ${s.hp.normal_max}${s.hp.normal_temp ? ` +${s.hp.normal_temp} temp` : ''}</span>
      <span class="muted small">Protected while transformed</span>
    </div>
    ${editable ? `<div class="ws-hp-controls" role="group" aria-label="Form hit points">
      <label class="ws-amount"><span class="sr-only">Amount</span><input type="number" min="1" max="999" inputmode="numeric" placeholder="Amount" data-tf-amount aria-label="Damage or healing amount"></label>
      <button type="button" class="btn btn-bad" data-action="tf-damage" data-focus-key="tf-damage">Damage</button>
      <button type="button" class="btn btn-good" data-action="tf-heal" data-focus-key="tf-heal">Heal</button>
      <button type="button" class="btn btn-sm" data-action="tf-adjust" data-focus-key="tf-adjust">Adjust…</button>
    </div>` : ''}
  </div>`;
}

function savesHTML(s) {
  return `<div class="ws-saves" role="list" aria-label="Saving throws">${ABIL.map((k) => {
    const x = s.saving_throws[k];
    const why = (x.candidates || []).map((c) => c.label).join('; ') || `${AB[k]} modifier ${sgn(x.modifier)}`;
    return `<div class="ws-save${x.character_proficient || x.creature_proficient ? ' is-prof' : ''}" role="listitem" title="${esc(why)}">
      <span class="ws-label">${AB[k]}</span><strong data-ws-save="${k}">${sgn(x.total)}</strong>
      <span class="muted small">${x.chosen === 'form_printed' ? 'form' : x.chosen === 'character' ? 'yours' : x.chosen === 'form_gained' ? 'gained' : ''}</span></div>`;
  }).join('')}</div>`;
}

function abilitiesHTML(s) {
  return `<div class="ws-abilities" role="list" aria-label="Ability scores">${ABIL.map((k) => {
    const a = s.abilities[k];
    return `<div class="ws-ability ws-src-${a.source}" role="listitem">
      <span class="ws-label">${AB[k]}</span><strong data-ws-ability="${k}">${a.score}</strong> <span class="small ws-mod">${sgn(a.modifier)}</span>
      <span class="ws-src small" title="${a.source === 'form' ? `From ${esc(a.source_name)}` : `Retained from ${esc(a.source_name)}`}">${a.source === 'form' ? 'Form' : 'Kept'}</span>
      <span class="sr-only">${a.source === 'form' ? `from ${esc(a.source_name)}` : `retained from ${esc(a.source_name)}`}</span></div>`;
  }).join('')}</div>`;
}

function skillsHTML(s) {
  const SK = Object.entries(s.skills).sort((a, b) => a[0].localeCompare(b[0]));
  const notable = SK.filter(([, x]) => x.character_level > 0 || x.creature_proficient || (x.advantage_traits || []).length);
  const row = ([k, x]) => `<li data-ws-skill="${esc(k)}"><span>${esc(cap(k.replace(/_/g, ' ')))} <span class="muted small">${AB[x.ability]}</span></span>
    <strong>${sgn(x.total)}</strong> <span class="muted small">${esc((x.candidates || []).find((c) => c.kind === x.chosen)?.label || 'ability only')}${
    (x.advantage_traits || []).length ? ` · advantage: ${esc(x.advantage_traits.join(', '))}` : ''}</span></li>`;
  return `<ul class="ws-skills">${notable.map(row).join('') || '<li class="muted small">No proficient skills.</li>'}</ul>
    <details class="ws-more" data-open-key="ws-all-skills"><summary>All skills</summary><ul class="ws-skills">${SK.map(row).join('')}</ul></details>`;
}

function actionCardHTML(a, s, { editable }) {
  if (a.multiattack) {
    return `<li class="ws-action ws-multi" data-ws-action-card="Multiattack"><details open data-open-key="ws-multi"><summary><strong>Multiattack</strong>
      <span class="muted small">${a.multiattack.map((m) => `${m.count} × ${esc(m.action)}`).join(' + ')}</span></summary>
      <ul>${a.multiattack.map((m) => {
        const x = (s.actions || []).find((y) => y.name === m.action);
        return `<li>${m.count} × <strong>${esc(m.action)}</strong>${x ? ` · ${x.attack_bonus != null ? `${sgn(x.attack_bonus)} to hit · ` : ''}${dmgText(x)}` : ''}</li>`;
      }).join('')}</ul><p class="muted small">Roll each attack separately; nothing is applied to a target automatically.</p></details></li>`;
  }
  const lim = a.usage ? (a.usage.type === 'recharge on roll' ? `Recharge ${a.usage.min_value}–6` : a.usage.type === 'recharge after rest' ? 'Once per rest (this form)' : esc(a.usage.type)) : '';
  return `<li class="ws-action${a.usage && !a.available ? ' is-spent' : ''}" data-ws-action-card="${esc(a.name)}">
    <div class="ws-action-head"><strong>${esc(a.name)}</strong>
      ${a.kind ? `<span class="ws-tag">${esc(cap(a.kind.replace('_or_', ' or ')))}</span>` : ''}
      ${a.attack_bonus != null ? `<span class="ws-hit">${sgn(a.attack_bonus)} to hit</span>` : ''}
      ${lim ? `<span class="ws-tag ws-lim">${lim}: ${a.available ? 'available' : 'used'}</span>` : ''}</div>
    <p class="small">${[a.reach ? `reach ${a.reach} ft` : '', a.range ? `range ${a.range.join('/')} ft` : '', a.targets || ''].filter(Boolean).map(esc).join(' · ')}
      ${(a.damage || []).length ? `<br><span class="ws-dmg">Hit: ${dmgText(a)}</span>` : ''}${s.primal_strike && a.attack_bonus != null ? ' <span class="muted small">(magical: Primal Strike)</span>' : ''}</p>
    ${a.save ? `<p class="small ws-dc"><strong>DC ${a.save.dc} ${esc(a.save.ability)}</strong> ${a.save.kind === 'check' ? 'check' : 'save'}</p>` : ''}
    ${a.summary ? `<p class="small">${esc(a.summary)}</p>` : ''}
    ${(a.conditions || []).length ? `<p class="ws-conds">${a.conditions.map((c) => `<span class="ws-cond">${esc(cap(c))}</span>`).join('')}</p>` : ''}
    ${editable && a.usage ? `<div class="ws-action-btns">
      <button type="button" class="btn btn-sm" data-action="tf-ability" data-ability="${esc(a.name)}" data-op="use" data-focus-key="tf-ability:${esc(a.name)}" ${a.available ? '' : 'disabled'}>Use</button>
      ${a.usage.type === 'recharge on roll' ? `<button type="button" class="btn btn-sm" data-action="tf-ability" data-ability="${esc(a.name)}" data-op="roll" data-focus-key="tf-roll:${esc(a.name)}" ${a.available ? 'disabled' : ''}>Roll recharge (d6)</button>` : ''}
      <button type="button" class="btn btn-sm btn-ghost" data-action="tf-ability" data-ability="${esc(a.name)}" data-op="restore" data-focus-key="tf-restore:${esc(a.name)}" ${a.available ? 'disabled' : ''}>Restore</button></div>` : ''}
  </li>`;
}

function traitsHTML(s) {
  const by = {};
  for (const t of s.traits || []) (by[t.group || 'other'] ||= []).push(t);
  const resist = [...(s.resistances || []).map((x) => `Resistant: ${x}`), ...(s.immunities || []).map((x) => `Immune: ${x}`),
    ...(s.vulnerabilities || []).map((x) => `Vulnerable: ${x}`), ...(s.condition_immunities || []).map((x) => `Immune to ${x}`)];
  if (resist.length) (by.defense ||= []).unshift(...resist.map((r) => ({ name: r, summary: '' })));
  const gs = GROUPS.filter(([g]) => (by[g] || []).length);
  if (!gs.length) return '<p class="muted small">No special traits.</p>';
  return gs.map(([g, label]) => `<div class="ws-trait-group" data-ws-traits="${g}"><h5>${label}</h5><ul>${by[g].map((t) =>
    `<li><strong>${esc(t.name)}</strong>${t.summary ? ` <span class="small">${esc(t.summary)}</span>` : ''}</li>`).join('')}</ul></div>`).join('');
}

/** The active Wild Shape mode: a temporary playable sheet. */
export function activeFormHTML(tf, { editable = true } = {}) {
  const s = tf.active.sheet;
  if (!s) return '<p class="muted small">Loading the form…</p>';
  const c = s.creature;
  const dur = s.duration || {};
  const fmt = (t) => (t ? new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '');
  const senses = Object.entries(s.senses || {}).filter(([k]) => k !== 'passive_perception');
  const res = (tf.resources || [])[0];
  const moonHeal = tf.moon && !c.elemental;
  return `<section class="ws-panel ws-active" data-transform="active" data-elemental="${c.elemental ? 'true' : 'false'}" aria-labelledby="ws-active-title">
    <header class="ws-head">
      <div><span class="ws-kicker">${c.elemental ? 'Elemental Wild Shape' : 'Wild Shape'}</span>
        <h3 id="ws-active-title" data-ws-name>${esc(c.name)}</h3>
        <span class="small muted">CR ${esc(c.cr_text)} · ${esc(c.size)} ${esc(c.type)} · ${esc(c.source)}${c.license ? ` (${esc(c.license)})` : ''}</span></div>
      <div class="ws-head-side">
        <span class="small" data-ws-duration>${dur.max_minutes ? `Up to ${dur.max_minutes / 60} h · started ${fmt(dur.started_at)} · ends by ${fmt(dur.expires_at)}` : 'Duration not tracked'}
          ${dur.expired ? '<strong class="ws-warn"> · duration over</strong>' : ''}</span>
        ${res ? `<span class="small">${res.unlimited ? 'Wild Shape: unlimited' : `Wild Shape: ${res.remaining} / ${res.max} left`}</span>` : ''}
        ${editable ? '<button type="button" class="btn btn-gold" data-action="tf-end" data-focus-key="tf-end">Revert to normal form</button>' : ''}
      </div>
    </header>
    <p class="ws-status small" id="ws-status" role="status" aria-live="polite"></p>
    ${hpBlockHTML(s, { editable })}
    ${editable && moonHeal ? '<button type="button" class="btn btn-sm" data-action="tf-combat-heal" data-focus-key="tf-combat-heal">Combat Wild Shape: heal with a spell slot…</button>' : ''}
    <div class="ws-grid">
      <section class="ws-card" aria-labelledby="ws-def"><h4 id="ws-def">Defense</h4>
        <p class="ws-ac"><span class="ws-label">Armor Class</span> <strong data-ws-ac>${s.armor_class.value}</strong>
          <span class="small">${esc(s.armor_class.selected?.label || '')}${s.armor_class.selected?.shield ? ' + shield 2' : ''}</span></p>
        ${(s.armor_class.options || []).length > 1 ? `<details class="ws-more" data-open-key="ws-ac"><summary>Other AC options</summary><ul class="small">${
          s.armor_class.options.map((o) => `<li>${esc(o.label)}: ${o.value}${o.note ? ` <span class="muted">(${esc(o.note)})</span>` : ''}</li>`).join('')}</ul></details>` : ''}
        <h5>Saving throws</h5>${savesHTML(s)}
      </section>
      <section class="ws-card" aria-labelledby="ws-move"><h4 id="ws-move">Movement and senses</h4>
        <ul class="ws-moves">${MOVES.map((k) => `<li class="${s.speed?.[k] ? 'is-on' : 'is-off'}"><span aria-hidden="true">${MOVE_ICON[k]}</span>
          ${cap(k)} <strong>${s.speed?.[k] ? `${s.speed[k]} ft` : '—'}</strong></li>`).join('')}</ul>
        <ul class="ws-senses">${senses.map(([k, v]) => `<li><strong>${esc(SENSE_LABEL[k] || cap(k))}</strong> ${esc(String(v))} ft</li>`).join('')}
          <li><strong>Passive Perception</strong> ${s.senses.passive_perception}</li></ul>
        <p class="muted small">${esc(s.size.size)}: ${s.size.space_ft} ft space${s.size.notes ? `. ${esc(s.size.notes)}` : ''}</p>
      </section>
      <section class="ws-card ws-wide" aria-labelledby="ws-acts"><h4 id="ws-acts">Actions</h4>
        <ul class="ws-actions">${(s.actions || []).map((a) => actionCardHTML(a, s, { editable })).join('') || '<li class="muted small">No actions.</li>'}</ul>
      </section>
      <section class="ws-card" aria-labelledby="ws-abil"><h4 id="ws-abil">Abilities</h4>${abilitiesHTML(s)}</section>
      <section class="ws-card" aria-labelledby="ws-skl"><h4 id="ws-skl">Skills</h4>${skillsHTML(s)}</section>
      <section class="ws-card ws-wide" aria-labelledby="ws-trt"><h4 id="ws-trt">Traits</h4>${traitsHTML(s)}</section>
      <section class="ws-card" aria-labelledby="ws-spl"><h4 id="ws-spl">Spells and concentration</h4>
        <p class="ws-cast ${s.spellcasting.can_cast ? 'is-yes' : 'is-no'}" data-ws-cast><strong>${s.spellcasting.can_cast ? '✓ Can cast in this form' : '✗ Cannot cast in this form'}</strong>
          ${s.spellcasting.feature ? `<span class="ws-tag">${esc(s.spellcasting.feature)}</span>` : ''}</p>
        <p class="small">${esc(s.spellcasting.rule)}</p>
        ${s.concentration.active ? `<div class="ws-conc" data-ws-concentration><strong>Concentrating</strong>${s.concentration.note ? `: ${esc(s.concentration.note)}` : ''}
          <p class="small">${esc(s.concentration.reminder)}</p>
          ${editable ? '<button type="button" class="btn btn-sm" data-action="tf-end-concentration" data-focus-key="tf-end-conc">End concentration</button>' : ''}</div>`
          : '<p class="muted small">Not concentrating on a spell.</p>'}
      </section>
      <section class="ws-card" aria-labelledby="ws-eq"><h4 id="ws-eq">Equipment</h4>
        ${(s.equipment || []).length ? `<ul class="ws-equip">${s.equipment.map((e) => `<li><span>${esc(e.name)}</span>
          <span class="ws-tag">${e.dropped ? 'Dropped' : e.mode === 'wear' ? 'Worn by the form' : 'Merged'}</span>
          <span class="small muted">${e.effects_active ? 'effects active' : 'no effect'}</span>
          ${editable && !e.dropped ? `<button type="button" class="btn btn-sm btn-ghost" data-action="tf-equip" data-item="${esc(e.inventory_item_id)}" data-mode="${e.mode === 'wear' ? 'merge' : 'wear'}"
            data-focus-key="tf-equip:${esc(e.inventory_item_id)}">${e.mode === 'wear' ? 'Merge' : 'Wear (DM)'}</button>` : ''}</li>`).join('')}</ul>`
          : '<p class="muted small">Nothing equipped.</p>'}
        <p class="muted small">Merged and dropped items have no effect while you are transformed. Dropped items are not re-equipped automatically.</p>
      </section>
      <section class="ws-card ws-wide" aria-labelledby="ws-ret"><h4 id="ws-ret">Retained features</h4>
        <details class="ws-more" data-open-key="ws-retained"><summary>${(s.retained_features || []).length} features: what still works</summary><ul class="small">${
          (s.retained_features || []).map((f) => `<li><strong>${esc(f.feature)}</strong> <span class="muted">(${esc(f.class || '')})</span> ·
            ${{ retained: 'kept', retained_if_capable: 'kept if the form can use it', needs_dm: 'ask your DM (not applied)', not_retained: 'not kept in this form',
                informational: 'reminder' }[f.status] || esc(f.status)}${f.applied ? ' · applied' : ''}</li>`).join('')}</ul></details>
      </section>
    </div>
    ${(tf.events || []).length ? `<details class="ws-more ws-history" data-open-key="ws-history"><summary>Recent Wild Shape history</summary><ul class="small">${
      tf.events.slice(0, 8).map((e) => `<li>${esc(new Date(e.at).toLocaleString())}: ${esc(e.type.replace(/_/g, ' '))}${e.creature_id ? ` (${esc(e.creature_id)})` : ''}${
        e.metadata?.amount ? ` ${e.metadata.amount}` : ''}${e.metadata?.carryover ? `, ${e.metadata.carryover} carried over` : ''}</li>`).join('')}</ul></details>` : ''}
  </section>`;
}

// ------------------------------------------------------------------------------------------------------------ picker
function cardHTML(o, { selected = false, editable = true }) {
  const st = STATUS[o.status] || STATUS.ineligible;
  const atk = (o.attacks || []).filter((a) => a.bonus != null).sort((a, b) => avgDice(b.damage?.[0]?.dice) - avgDice(a.damage?.[0]?.dice))[0];
  const multi = (o.attacks || []).find((a) => a.multiattack);
  const senses = Object.entries(o.senses || {}).filter(([k]) => k !== 'passive_perception').map(([k, v]) => `${SENSE_LABEL[k] || k} ${v}`);
  return `<li class="ws-form-card ws-st-${st.cls}" data-ws-form="${esc(o.id)}" data-status="${esc(o.status)}">
    <div class="ws-form-top"><span class="ws-type" aria-hidden="true">${icon(o.elemental ? 'condition.generic-effect' : 'action.wild-shape', { size: 20 })}</span>
      <strong class="ws-form-name">${esc(o.name)}</strong>
      ${editable ? `<button type="button" class="ws-fav" data-ws-fav="${esc(o.id)}" aria-pressed="${!!o.favorite}" aria-label="${o.favorite ? 'Remove from' : 'Add to'} favorites: ${esc(o.name)}">${o.favorite ? '★' : '☆'}</button>` : ''}</div>
    <p class="ws-form-stats small">CR ${esc(o.cr_text)} · ${esc(o.size)} · <strong>HP ${o.hit_points}</strong> · <strong>AC ${o.armor_class}</strong></p>
    <p class="small">${esc(speedText(o.speed))}${senses.length ? ` · ${esc(senses.join(', '))}` : ''}</p>
    ${atk ? `<p class="small">${multi ? `Multiattack (${multi.multiattack.map((m) => `${m.count} ${esc(m.action)}`).join(', ')}) · ` : ''}${esc(atk.name)} ${sgn(atk.bonus)}, ${
      (atk.damage || []).map((d) => `${esc(d.dice)} ${esc(d.type)}`).join(' + ')}${atk.save ? ` · DC ${atk.save.dc} ${esc(atk.save.ability)}` : ''}</p>` : ''}
    ${(o.traits || []).length ? `<p class="small muted">${o.traits.slice(0, 4).map((t) => esc(t.name)).join(' · ')}</p>` : ''}
    <p class="ws-form-status small"><span aria-hidden="true">${st.icon}</span> ${esc(st.label)}${o.cost > 1 ? ` · costs ${o.cost} uses` : ''}</p>
    ${(o.reasons || []).length ? `<ul class="ws-reasons small">${o.reasons.map((r) => `<li>${esc(r)}</li>`).join('')}</ul>` : ''}
    <div class="ws-form-btns">
      <label class="check-field small"><input type="checkbox" data-ws-compare="${esc(o.id)}" ${selected ? 'checked' : ''}><span>Compare</span></label>
      ${editable && (o.status === 'eligible_unseen' || o.status === 'unseen_locked') ? `<button type="button" class="btn btn-sm btn-ghost" data-ws-seen="${esc(o.id)}">Mark seen</button>` : ''}
      ${editable ? `<button type="button" class="btn btn-sm btn-gold" data-ws-take="${esc(o.id)}" ${o.allowed ? '' : 'disabled'} aria-label="Transform into ${esc(o.name)}">Transform…</button>` : ''}
    </div>
  </li>`;
}

/** The form picker. onTransform(creatureId) opens the review; onChanged(newState) after favorites / seen changes. */
export function openFormPicker({ characterId, tf, onTransform, onChanged, editable = true }) {
  let state = tf;
  const compare = new Set();
  const m = openModal({
    title: 'Choose a form',
    wide: true,
    body: `<div class="ws-picker" data-ws-picker>
      <div data-ws-filter-box><label class="field ws-q"><span>Search (name, trait)</span><input type="search" data-f="q" placeholder="wolf, pack tactics…" autocomplete="off"></label>
      <details class="ws-filters" ${matchMedia('(max-width: 600px)').matches ? '' : 'open'}><summary>Filters and sort</summary>
        <div class="ws-filter-grid">
          <label class="field"><span>Status</span><select data-f="status"><option value="usable">Can take now</option><option value="seen">Seen only</option>
            <option value="favorites">Favorites</option><option value="all">All forms (show locked)</option></select></label>
          <label class="field"><span>Max CR</span><select data-f="cr"><option value="">Any</option>${['0', '0.125', '0.25', '0.5', '1', '2', '3', '4', '5', '6'].map((v) =>
            `<option value="${v}">${crText(v)}</option>`).join('')}</select></label>
          <label class="field"><span>Size</span><select data-f="size"><option value="">Any</option>${['Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Gargantuan'].map((v) =>
            `<option>${v}</option>`).join('')}</select></label>
          <label class="field"><span>Movement</span><select data-f="move"><option value="">Any</option>${['swim', 'fly', 'climb', 'burrow'].map((v) =>
            `<option value="${v}">${cap(v)}</option>`).join('')}</select></label>
          <label class="field"><span>Sense</span><select data-f="sense"><option value="">Any</option><option value="darkvision">Darkvision</option>
            <option value="blindsight">Blindsight</option><option value="tremorsense">Tremorsense</option></select></label>
          <label class="field"><span>Damage type</span><select data-f="dmg"><option value="">Any</option>${['bludgeoning', 'piercing', 'slashing', 'poison', 'acid', 'fire', 'cold']
            .map((v) => `<option value="${v}">${cap(v)}</option>`).join('')}</select></label>
          <label class="field"><span>Sort</span><select data-f="sort"><option value="cr">CR, then name</option><option value="hp">HP (high first)</option>
            <option value="ac">AC (high first)</option><option value="recent">Recently used</option></select></label>
          <label class="check-field"><input type="checkbox" data-f="multi"><span>Multiattack</span></label>
        </div>
      </details></div>
      <p class="small muted" data-ws-count role="status" aria-live="polite"></p>
      <div data-ws-results></div>
      <div class="ws-compare-bar" data-ws-compare-bar hidden><span data-ws-compare-count></span>
        <button type="button" class="btn btn-sm btn-gold" data-ws-compare-open>Compare</button>
        <button type="button" class="btn btn-sm btn-ghost" data-ws-compare-clear>Clear</button></div>
    </div>`,
    footer: '<button type="button" class="btn" data-close>Close</button>',
  });
  const f = (k) => $(`[data-f="${k}"]`, m.el);
  const results = $('[data-ws-results]', m.el);
  const render = () => {
    const q = f('q').value.trim().toLowerCase();
    const status = f('status').value;
    let rows = (state.options || []).filter((o) => {
      if (status === 'usable' && !o.allowed) return false;
      if (status === 'seen' && !o.seen) return false;
      if (status === 'favorites' && !o.favorite) return false;
      if (f('cr').value !== '' && Number(o.challenge_rating) > Number(f('cr').value)) return false;
      if (f('size').value && o.size !== f('size').value) return false;
      if (f('move').value && !o.speed?.[f('move').value]) return false;
      if (f('sense').value && !o.senses?.[f('sense').value]) return false;
      if (f('dmg').value && !(o.damage_types || []).includes(f('dmg').value)) return false;
      if (f('multi').checked && !(o.attacks || []).some((a) => a.multiattack)) return false;
      return !q || o.name.toLowerCase().includes(q) || (o.traits || []).some((t) => t.name.toLowerCase().includes(q));
    });
    const sort = f('sort').value;
    rows = rows.sort((a, b) => (Number(!!b.favorite && b.allowed) - Number(!!a.favorite && a.allowed))
      || (sort === 'hp' ? b.hit_points - a.hit_points : sort === 'ac' ? b.armor_class - a.armor_class
        : sort === 'recent' ? String(b.last_used || '').localeCompare(String(a.last_used || '')) : a.challenge_rating - b.challenge_rating)
      || a.name.localeCompare(b.name));
    const beasts = rows.filter((o) => !o.elemental);
    const elementals = rows.filter((o) => o.elemental);
    const recent = (state.options || []).filter((o) => o.last_used && o.allowed).sort((a, b) => String(b.last_used).localeCompare(String(a.last_used))).slice(0, 4);
    const html = `${recent.length && status === 'usable' && !q ? `<p class="small ws-recent">Recently used: ${recent.map((o) => `<button type="button" class="btn-link" data-ws-take="${esc(o.id)}">${esc(o.name)}</button>`).join(', ')}</p>` : ''}
      ${beasts.length ? `<h4 class="ws-group-title">Beast forms (${beasts.length})</h4><ul class="ws-form-list">${beasts.map((o) => cardHTML(o, { selected: compare.has(o.id), editable })).join('')}</ul>` : ''}
      ${elementals.length ? `<h4 class="ws-group-title">Elemental Wild Shape (2 uses each)</h4><ul class="ws-form-list">${elementals.map((o) => cardHTML(o, { selected: compare.has(o.id), editable })).join('')}</ul>` : ''}
      ${!rows.length ? `<p class="muted">No form matches.${status === 'usable' ? ' Choose "All forms" to see the locked ones and why.' : ''}</p>` : ''}`;
    if (results.__html !== html) { results.innerHTML = html; results.__html = html; }
    $('[data-ws-count]', m.el).textContent = `${rows.length} form${rows.length === 1 ? '' : 's'} shown`;
    const bar = $('[data-ws-compare-bar]', m.el);
    bar.hidden = compare.size < 2;
    $('[data-ws-compare-count]', m.el).textContent = `${compare.size} selected`;
  };
  m.el.addEventListener('input', (e) => { if (e.target.closest('[data-ws-filter-box]')) render(); });
  m.el.addEventListener('change', (e) => {
    if (e.target.closest('[data-ws-filter-box]')) render();
    const cmp = e.target.closest('[data-ws-compare]');
    if (cmp) { if (cmp.checked) compare.add(cmp.dataset.wsCompare); else compare.delete(cmp.dataset.wsCompare); render(); }
  });
  m.el.addEventListener('click', async (e) => {
    const take = e.target.closest('[data-ws-take]');
    const fav = e.target.closest('[data-ws-fav]');
    const seen = e.target.closest('[data-ws-seen]');
    if (take && !take.disabled) { m.close(); onTransform?.(take.dataset.wsTake, state); return; }
    if (e.target.closest('[data-ws-compare-open]')) { openCompare([...compare].map((id) => state.options.find((o) => o.id === id)).filter(Boolean)); return; }
    if (e.target.closest('[data-ws-compare-clear]')) { compare.clear(); render(); return; }
    if (fav) {
      const o = state.options.find((x) => x.id === fav.dataset.wsFav);
      fav.disabled = true;
      try {
        await api.setFormFavorite(characterId, o.id, !o.favorite);
        o.favorite = !o.favorite;
        render();
        $(`[data-ws-fav="${CSS.escape(o.id)}"]`, m.el)?.focus();
        onChanged?.();
      } catch (err) { toast(err.message, 'bad'); fav.disabled = false; }
    }
    if (seen) {
      seen.disabled = true;
      try {
        state = await api.setSeenForms(characterId, [seen.dataset.wsSeen]);
        toast('Marked as seen.', 'good');
        render();
        $(`[data-ws-take="${CSS.escape(seen.dataset.wsSeen)}"]`, m.el)?.focus();
        onChanged?.(state);
      } catch (err) { toast(err.message, 'bad'); seen.disabled = false; }
    }
  });
  render();
  setTimeout(() => f('q')?.focus(), 60);
  return m;
}

/** Side-by-side comparison of 2-4 forms; differences highlighted, no ranking. */
export function openCompare(forms) {
  const list = forms.slice(0, 4);
  const row = (label, fn) => {
    const vals = list.map((o) => String(fn(o) ?? '—'));
    const diff = new Set(vals).size > 1;
    return `<tr class="${diff ? 'is-diff' : ''}"><th scope="row">${esc(label)}${diff ? ' <span class="sr-only">(differs)</span>' : ''}</th>${vals.map((v) => `<td>${v}</td>`).join('')}</tr>`;
  };
  const atks = (o) => (o.attacks || []).filter((a) => a.bonus != null).map((a) => `${esc(a.name)} ${sgn(a.bonus)} (${(a.damage || []).map((d) => esc(d.dice)).join(' + ')})`).join('<br>');
  openModal({
    title: 'Compare forms',
    wide: true,
    body: `<div class="ws-compare-wrap"><table class="ws-compare"><thead><tr><th scope="col"><span class="sr-only">Statistic</span></th>${list.map((o) => `<th scope="col">${esc(o.name)}</th>`).join('')}</tr></thead><tbody>
      ${row('Status', (o) => esc((STATUS[o.status] || STATUS.ineligible).label))}
      ${row('Cost', (o) => `${o.cost} use${o.cost === 1 ? '' : 's'}`)}
      ${row('CR', (o) => esc(o.cr_text))}${row('Size', (o) => esc(o.size))}${row('Hit points', (o) => o.hit_points)}${row('Armor Class', (o) => o.armor_class)}
      ${MOVES.map((k) => row(cap(k), (o) => (o.speed?.[k] ? `${o.speed[k]} ft` : '—'))).join('')}
      ${row('Senses', (o) => esc(Object.entries(o.senses || {}).map(([k, v]) => `${k.replace(/_/g, ' ')} ${v}`).join(', ')))}
      ${row('Multiattack', (o) => esc((o.attacks || []).find((a) => a.multiattack)?.multiattack.map((x) => `${x.count} ${x.action}`).join(', ') || '—'))}
      ${row('Attacks', atks)}
      ${row('Traits', (o) => esc((o.traits || []).map((t) => t.name).join(', ') || '—'))}
      ${row('Restrictions', (o) => esc((o.reasons || []).join('; ') || 'none'))}
    </tbody></table></div><p class="muted small">Highlighted rows differ. Nothing here ranks the forms: choose by the situation.</p>`,
    footer: '<button type="button" class="btn btn-gold" data-close>Done</button>',
  });
}

// ------------------------------------------------------------------------------------------------------------ review
/** Review before transforming: cost, duration, seen status, equipment behavior. Resolves to the server state or null. */
export async function openTransformReview({ characterId, tf, creatureId, onDone }) {
  const o = (tf.options || []).find((x) => x.id === creatureId);
  if (!o) return;
  const res = (tf.resources || [])[0];
  const equipped = await api.getEquipped(characterId).catch(() => []);
  const mode = tf.settings?.default_equipment || 'merge';
  const m = openModal({
    title: `Transform into ${o.name}?`,
    body: `<div class="stack ws-review">
      <p><strong>${esc(o.name)}</strong> · CR ${esc(o.cr_text)} · ${esc(o.size)} · HP ${o.hit_points} · AC ${o.armor_class}</p>
      <ul class="small">
        <li>Cost: <strong>${o.cost} Wild Shape use${o.cost === 1 ? '' : 's'}</strong> (${res ? (res.unlimited ? 'unlimited' : `${res.remaining} left`) : '?'})</li>
        <li>Duration: up to ${o.duration_minutes ? `${o.duration_minutes / 60} hours` : '—'}</li>
        <li>Your normal HP stays as it is and is protected while transformed.</li>
        ${o.status === 'eligible_unseen' ? '<li class="ws-warn">You have not marked this beast as seen (your table allows it with a warning).</li>' : ''}
        ${o.status === 'dm_granted' ? '<li>DM-granted exception.</li>' : ''}
      </ul>
      <fieldset class="ws-equip-choice"><legend>Your equipment</legend>
        ${['merge', 'drop', 'wear'].map((k) => `<label class="check-field"><input type="radio" name="eqmode" value="${k}" ${k === mode ? 'checked' : ''}>
          <span>${{ merge: 'Merges into the form (no effect until you revert)', drop: 'Falls to the ground (stays in your inventory, unequipped)',
                    wear: 'Worn by the form (only if it fits: DM decides)' }[k]}</span></label>`).join('')}
        ${equipped.length ? `<details class="ws-more"><summary>Per item (${equipped.length} equipped)</summary>${equipped.map((e) => `<label class="field small"><span>${esc(e.name)}</span>
          <select data-eq-item="${esc(e.id)}" aria-label="${esc(e.name)}"><option value="">Same as above</option><option value="merge">Merge</option><option value="drop">Drop</option>
          <option value="wear">Wear</option></select></label>`).join('')}</details>` : '<p class="muted small">Nothing equipped.</p>'}
      </fieldset>
    </div>`,
    footer: `<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ws-confirm>${o.cost > 1 ? `Spend ${o.cost} uses and transform` : 'Transform'}</button>`,
  });
  $('[data-ws-confirm]', m.el).addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    if (btn.disabled) return;
    btn.disabled = true;
    const items = {};
    for (const s of $$('[data-eq-item]', m.el)) if (s.value) items[s.dataset.eqItem] = s.value;
    try {
      const r = await api.startTransformation(characterId, creatureId, { equipment: { mode: $('[name=eqmode]:checked', m.el).value, items } });
      m.close();
      toast(`You take the form of ${o.name}.`, 'good');
      await onDone?.(r);
    } catch (err) { toast(err.message, 'bad'); btn.disabled = false; }
  });
  setTimeout(() => $('[data-ws-confirm]', m.el)?.focus(), 60);
}

// ------------------------------------------------------------------------------------------------------------ HP flows
/** What damage would do, for the confirmation (the server computes the real result). */
export function damagePreview(sheet, amount) {
  const t = Math.min(sheet.hp.temp || 0, amount);
  const after = sheet.hp.current - (amount - t);
  if (after > 0) return { lethal: false, after };
  return { lethal: true, carry: -after, normalAfter: Math.max(0, sheet.hp.normal_current - Math.max(0, -after - (sheet.hp.normal_temp || 0))) };
}

export async function confirmLethal(sheet, amount) {
  const p = damagePreview(sheet, amount);
  if (!p.lethal) return true;
  return confirmDialog([`Incoming damage: ${amount}`, `Form HP remaining: ${sheet.hp.current}${sheet.hp.temp ? ` (+${sheet.hp.temp} temp)` : ''}`,
    'Wild Shape will end.', `${p.carry} damage will carry over to your normal form (${sheet.hp.normal_current} → ${p.normalAfter}).`].join('\n'),
  { title: 'This damage ends Wild Shape', okLabel: 'Apply damage', danger: true });
}

export function openAdjust({ characterId, sheet, onDone }) {
  const m = openModal({
    title: 'Adjust form hit points',
    body: `<form class="stack" data-ws-adjust>
      <label class="field"><span>Form HP (1–${sheet.hp.max})</span><input type="number" name="hp" min="1" max="${sheet.hp.max}" value="${sheet.hp.current}" required></label>
      <label class="field"><span>Temporary HP</span><input type="number" name="temp" min="0" max="999" value="${sheet.hp.temp || 0}"></label>
      <label class="field"><span>Reason (kept in the history)</span><input type="text" name="reason" maxlength="200" placeholder="e.g. forgot a hit" required></label>
    </form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok>Save</button>',
  });
  $('[data-ok]', m.el).addEventListener('click', async () => {
    const f = $('[data-ws-adjust]', m.el);
    if (!f.reportValidity()) return;
    try {
      const r = await api.setFormHp(characterId, Number(f.elements.hp.value), Number(f.elements.temp.value), f.elements.reason.value.trim());
      m.close();
      toast('Form hit points corrected.', 'good');
      await onDone?.(r);
    } catch (err) { toast(err.message, 'bad'); }
  });
}

/** Combat Wild Shape healing: pick a slot (no default), see the formula, roll by the app or enter your own roll, confirm. */
export async function openCombatHeal({ characterId, sheet, slots, onDone }) {
  const std = (slots?.standard || []).filter((s) => s.max > 0);
  const pact = slots?.pact_magic;
  const m = openModal({
    title: 'Combat Wild Shape: heal with a spell slot',
    body: `<form class="stack" data-ws-heal>
      <p class="small">Spend one spell slot: the form regains <strong>1d8 per slot level</strong>. Form HP ${sheet.hp.current} / ${sheet.hp.max}.</p>
      <fieldset><legend>Slot</legend>${std.map((s) => `<label class="check-field"><input type="radio" name="slot" value="standard:${s.slot_level}" ${s.remaining > 0 ? '' : 'disabled'}>
        <span>${s.slot_level}${['', 'st', 'nd', 'rd'][s.slot_level] || 'th'} level: ${s.slot_level}d8 · ${s.remaining} / ${s.max} left</span></label>`).join('')}
        ${pact ? `<label class="check-field"><input type="radio" name="slot" value="pact:${pact.slot_level}" ${pact.remaining > 0 ? '' : 'disabled'}>
          <span>Pact Magic slot (level ${pact.slot_level}): ${pact.slot_level}d8 · ${pact.remaining} / ${pact.max} left <span class="muted">(only if your table counts Pact slots for this)</span></span></label>` : ''}
        ${!std.length && !pact ? '<p class="muted small">You have no spell slots.</p>' : ''}</fieldset>
      <label class="field"><span>Your own roll (optional, leave empty to let the app roll)</span><input type="number" name="roll" min="1" max="72" inputmode="numeric"></label>
      <p class="small muted" data-heal-preview role="status" aria-live="polite">Choose a slot.</p>
    </form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-ok disabled>Spend the slot and heal</button>',
  });
  const f = $('[data-ws-heal]', m.el);
  const ok = $('[data-ok]', m.el);
  f.addEventListener('change', () => {
    const v = f.elements.slot.value;
    ok.disabled = !v;
    if (v) { const n = Number(v.split(':')[1]); $('[data-heal-preview]', m.el).textContent = `${n}d8 (${n}–${8 * n}); the form cannot go above ${sheet.hp.max}.`; }
  });
  ok.addEventListener('click', async () => {
    const [pool, lvl] = f.elements.slot.value.split(':');
    ok.disabled = true;
    try {
      const r = await api.combatWildShapeHeal(characterId, Number(lvl), pool, f.elements.roll.value ? Number(f.elements.roll.value) : null);
      m.close();
      toast(`Rolled ${r.result.roll} on ${r.result.dice}: the form regains ${r.result.healed} HP (${r.result.form_hp_after} / ${sheet.hp.max}).`, 'good', 6000);
      await onDone?.(r);
    } catch (err) { toast(err.message, 'bad'); ok.disabled = false; }
  });
}

/** Revert review: what ends, what is restored. */
export function confirmRevert(tf) {
  const s = tf.active.sheet;
  const dropped = (s.equipment || []).filter((e) => e.dropped).map((e) => e.name);
  return confirmDialog([`Revert from ${s.creature.name} (form HP ${s.hp.current} / ${s.hp.max})?`,
    `Your normal form returns with ${s.hp.normal_current} / ${s.hp.normal_max} HP.`,
    'The form\'s actions, senses, movement and limited abilities end. Merged equipment works again.',
    dropped.length ? `Dropped and not re-equipped: ${dropped.join(', ')}.` : '',
    s.concentration.active ? 'Your concentration continues.' : '', 'No Wild Shape use is spent.'].filter(Boolean).join('\n'),
  { title: 'Revert to normal form', okLabel: 'Revert' });
}
