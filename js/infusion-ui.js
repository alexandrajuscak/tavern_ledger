// Infused items card: the infusions a character knows (a class feature choice), the items that hold them, and the dialog that
// infuses an item, replicates a magic item or creates a companion. The rules (known infusions, item limit, which items
// qualify, the bonus of each level) live in the database (migration 20261017000900); this module only moves data.
import { $, esc, toast, openModal, confirmDialog } from './utils.js?v=19';
import { supabase } from './supabase.js?v=19';
import { normalizeError } from './inventory-api.js?v=19';

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.code === '22023' || error.code === '42501' ? error.message : normalizeError(error).message);
  return data;
}
export const getInfusions = (characterId) => rpc('get_character_infusions', { p_character: characterId });
const apply = (characterId, infusion, item = null, replicate = null) =>
  rpc('apply_infusion', { p_character: characterId, p_infusion: infusion, p_inventory_item: item, p_replicate_item: replicate });
const remove = (characterId, row) => rpc('remove_infusion', { p_character: characterId, p_infusion_row: row });
const refresh = (characterId) => rpc('refresh_infusions', { p_character: characterId });

const words = (id) => String(id || '').replace(/-/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

/** Card body; empty when the character has no infusion feature. */
export function infusionsHTML(state, { editable = true } = {}) {
  const ch = state?.choices || [];
  if (!ch.length) return '';
  const c = ch[0];
  const active = state.active || [];
  const outdated = active.some((a) => a.outdated);
  return `<section class="card" id="infusions-card" data-infusions>
    <h3>Infused items <span class="hint">${c.active_count} / ${c.max_items} items · ${c.known.length} infusions known</span></h3>
    ${outdated && editable ? `<p class="sp-warn small" data-inf-outdated>Your level changed: some infusions have a stronger version now.
      <button type="button" class="btn btn-sm" data-action="inf-refresh">Update infusions</button></p>` : ''}
    ${active.length ? `<ul class="entry-list cr-infused">${active.map((a) => `<li class="entry card" data-infused="${esc(a.id)}">
        <div class="entry-head"><strong>${esc(a.label)}</strong> <span class="muted small">${a.item_name ? `in ${esc(a.item_name)}` : ''}${
          a.created_item ? ' (replicated item)' : ''}${a.companion_id ? ' (companion created)' : ''}${a.attunement ? ` · ${a.attuned ? 'attuned' : 'needs attunement'}` : ''}</span></div>
        ${a.known ? '' : '<p class="sp-warn small">You no longer know this infusion; end it when you are ready.</p>'}
        ${editable ? `<button type="button" class="btn btn-sm" data-action="inf-remove" data-id="${esc(a.id)}">End infusion</button>` : ''}
      </li>`).join('')}</ul>` : '<p class="muted small">No infused items yet. Infuse items after a long rest.</p>'}
    ${editable ? `<button type="button" class="btn btn-sm btn-gold" data-action="inf-add" data-focus-key="inf-add" ${c.active_count >= c.max_items ? 'disabled title="All infused item slots are in use"' : ''}>Infuse an item…</button>` : ''}
    ${!c.known.length ? '<p class="muted small">Choose the infusions you know on the class page (Infuse Item).</p>' : ''}
  </section>`;
}

export function openInfuse({ characterId, state, onDone }) {
  const c = state.choices[0];
  const m = openModal({
    title: 'Infuse an item',
    wide: true,
    body: `<form class="form-grid" data-inf-form>
      <label class="field span-2"><span>Infusion</span><select name="infusion">${c.known.map((k) => `<option value="${esc(k.id)}">${esc(k.label)}</option>`).join('')}</select></label>
      <p class="small span-2" data-inf-summary></p>
      <div class="span-2" data-inf-target></div>
    </form>`,
    footer: '<button type="button" class="btn" data-close>Cancel</button><button type="button" class="btn btn-gold" data-inf-ok>Infuse</button>',
  });
  const f = $('[data-inf-form]', m.el);
  const ok = $('[data-inf-ok]', m.el);
  const cur = () => c.known.find((k) => k.id === f.elements.infusion.value);
  const draw = () => {
    const k = cur();
    $('[data-inf-summary]', m.el).textContent = k.summary || '';
    const inf = k.infusion || {};
    let html = '';
    if (inf.item?.none) {
      html = `<label class="field"><span>Magic item to replicate</span><select name="replicate">${(k.replicable || []).map((x) => `<option value="${esc(x)}">${esc(words(x))}</option>`).join('')}</select></label>
        <p class="muted small">The item is created in your inventory and vanishes when the infusion ends.</p>`;
    } else if (inf.companion) {
      html = `<p class="small">Creates <strong>${esc(inf.companion.name)}</strong> on your Companions card.</p>`;
    } else {
      const ok2 = (k.candidates || []).filter((x) => !x.refusal);
      const no = (k.candidates || []).filter((x) => x.refusal);
      html = `<label class="field"><span>Item${inf.item?.note ? ` (${esc(inf.item.note)})` : ''}</span><select name="target">${
        ok2.map((x) => `<option value="${esc(x.inventory_item_id)}">${esc(x.name)}</option>`).join('')}</select></label>
        ${!ok2.length ? '<p class="sp-warn small">No item in your inventory can take this infusion.</p>' : ''}
        ${no.length ? `<details class="small"><summary>Items that cannot take it (${no.length})</summary><ul>${no.map((x) => `<li>${esc(x.name)}: ${esc(x.refusal)}</li>`).join('')}</ul></details>` : ''}
        ${inf.attunement ? '<p class="muted small">This infusion requires attunement: attune to the item on the Inventory tab.</p>' : ''}`;
    }
    $('[data-inf-target]', m.el).innerHTML = html;
    ok.disabled = !inf.item?.none && !inf.companion && !(k.candidates || []).some((x) => !x.refusal);
  };
  f.addEventListener('change', (e) => { if (e.target.name === 'infusion') draw(); });
  draw();
  ok.addEventListener('click', async () => {
    ok.disabled = true;
    try {
      await apply(characterId, cur().id, f.elements.namedItem('target')?.value || null, f.elements.namedItem('replicate')?.value || null);
      toast(`${cur().label} infused.`, 'good');
      m.close();
      await onDone?.();
    } catch (err) { toast(err.message, 'bad'); ok.disabled = false; }
  });
  return m;
}

export async function endInfusion(characterId, state, id) {
  const a = (state?.active || []).find((x) => x.id === id);
  if (!a || !(await confirmDialog(`End ${a.label}${a.item_name ? ` in ${a.item_name}` : ''}?${a.created_item ? ' The replicated item vanishes.' : ''}${
    a.companion_id ? ' The companion it created goes too.' : ''}`, { title: 'End infusion', okLabel: 'End infusion', danger: true }))) return false;
  await remove(characterId, id);
  toast('Infusion ended.', 'good');
  return true;
}

export async function refreshInfusions(characterId) {
  await refresh(characterId);
  toast('Infusions updated to your level.', 'good');
}
