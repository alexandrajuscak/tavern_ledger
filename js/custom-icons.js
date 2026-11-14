// The DM's own item icons (docs/CUSTOM_ICONS.md, migration 20261114000200). The browser shrinks the chosen image to ~128 px
// WebP (PNG if this browser cannot encode WebP) and uploads it to the public Storage bucket `item-icons` under a random name
// (<campaign>/<uuid>.webp: no item id or name in it); the database stores only that object path per campaign and item
// (dm_set_item_icon, DM of the campaign only). A player receives the path only for a copy they know (v_inventory_detail
// custom_icon is NULL on a hidden / unidentified copy), so the URL below is built only from what the server gave the viewer.
// Nothing here ever deletes a file: Remove unlinks the icon, the uploaded object stays (custom content is never deleted).
import { supabase } from './supabase.js?v=35';
import { $, esc, toast, openModal, confirmDialog } from './utils.js?v=35';
import { icon, ITEM_ICONS } from './icons.js?v=35';
import { galleryIcon } from './item-icon-gallery.js?v=35';

export const ICON_BUCKET = 'item-icons';
export const ICON_MAX_BYTES = 65536;   // the bucket's file_size_limit (checked again by Storage and dm_set_item_icon)
const ICON_PX = 128;
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const PATH_RE = new RegExp(`^${UUID}/${UUID}\\.(webp|png)$`);

/** Public URL of a stored icon path, or null for anything that is not a well-formed icon path. Never requests anything. */
export function customIconUrl(path) {
  if (!path || !PATH_RE.test(path)) return null;
  return supabase.storage.from(ICON_BUCKET).getPublicUrl(path).data.publicUrl || null;
}

/** The default (registry) icon of a catalog item: its gallery key, then the category default (same order as the inventory). */
export function defaultItemIcon(it) {
  return galleryIcon(it?.icon_key) || (/shield/.test(it?.category_id || '') ? 'equipment-slots/shield' : null)
    || ITEM_ICONS[it?.kind_id] || (it?.is_magic ? ITEM_ICONS.magic : ITEM_ICONS.gear);
}

/**
 * Shrink an image file to at most 128 px on its longest side. WebP (quality 0.85, lower if needed to stay under 64 KB);
 * canvas.toBlob silently returns PNG where WebP encoding is missing, so the result type decides the extension.
 * The image is always re-encoded through a canvas: SVG markup or metadata never reaches Storage.
 */
export async function shrinkIcon(file) {
  if (!file || !/^image\//.test(file.type || '')) throw new Error('Choose an image file (PNG, JPEG, WebP or GIF).');
  if (file.size > 15 * 1024 * 1024) throw new Error('That image is very large: choose one under 15 MB.');
  let bmp;
  try { bmp = await createImageBitmap(file); } catch { throw new Error('This image could not be read. Try a PNG, JPEG or WebP file.'); }
  const scale = Math.min(1, ICON_PX / Math.max(bmp.width, bmp.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(bmp.width * scale));
  canvas.height = Math.max(1, Math.round(bmp.height * scale));
  const g = canvas.getContext('2d');
  g.imageSmoothingQuality = 'high';
  g.drawImage(bmp, 0, 0, canvas.width, canvas.height);
  bmp.close?.();
  const encode = (type, q) => new Promise((res) => canvas.toBlob(res, type, q));
  for (const q of [0.85, 0.7, 0.5]) {
    const b = await encode('image/webp', q);
    if (!b || b.type !== 'image/webp') break;            // no WebP encoder here: PNG below
    if (b.size <= ICON_MAX_BYTES) return { blob: b, type: 'image/webp', ext: 'webp' };
  }
  const png = await encode('image/png');
  if (png && png.size <= ICON_MAX_BYTES) return { blob: png, type: 'image/png', ext: 'png' };
  throw new Error('The icon is still larger than 64 KB after shrinking. Try a simpler image.');
}

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(error.message || 'Something went wrong. Nothing was changed.');
  return data;
}

/** DM: shrink, upload under a new random name, then link it to the item in this campaign (replaces the previous link). */
export async function uploadItemIcon(campaignId, itemId, file) {
  const { blob, type, ext } = await shrinkIcon(file);
  const path = `${campaignId}/${crypto.randomUUID()}.${ext}`;
  const { error } = await supabase.storage.from(ICON_BUCKET).upload(path, blob, { contentType: type, cacheControl: '31536000', upsert: false });
  if (error) throw new Error(error.message || 'The upload failed. Nothing was changed.');
  return rpc('dm_set_item_icon', { p_campaign: campaignId, p_item: itemId, p_path: path });
}

/** DM: unlink the icon (the item shows its default icon again). The uploaded file is kept. */
export const removeItemIcon = (campaignId, itemId) => rpc('dm_set_item_icon', { p_campaign: campaignId, p_item: itemId, p_path: null });

/** DM: the campaign's items (its own content and every item held in it) with their current icon path. */
export const getCampaignItemIcons = (campaignId) => rpc('get_campaign_item_icons', { p_campaign: campaignId });

const SHOWN = 80;
/**
 * DM Space dialog: search the campaign's items, upload / replace / remove an icon. focusItemId puts that item first
 * (opened from the Content editor). onChanged() after every change.
 */
export function openItemIconsDialog({ campaignId, focusItemId = null, onChanged = null } = {}) {
  const m = openModal({ title: 'Item icons', wide: true, body: `
    <p class="small muted">Your own picture replaces an item's icon for everyone in this campaign who knows the item (inventory, weapon
      cards, DM Space). Players who hold a hidden or unidentified copy keep seeing the default icon. The image is shrunk to
      ${ICON_PX} px in your browser (WebP or PNG, at most 64 KB). Remove brings the default icon back.</p>
    <label class="field"><span>Search items</span><input type="search" data-ii-q autocomplete="off"></label>
    <ul class="ii-list" data-ii-list aria-live="polite"><li class="muted">Loading…</li></ul>
    <input type="file" accept="image/png,image/jpeg,image/webp,image/gif" data-ii-file hidden>`,
  footer: '<button type="button" class="btn btn-ghost" data-close>Close</button>' });
  let items = [];
  let q = '';
  let target = null;
  const busy = new Set();
  const list = $('[data-ii-list]', m.el);
  const file = $('[data-ii-file]', m.el);

  function rowHTML(x) {
    const def = defaultItemIcon(x);
    const url = customIconUrl(x.custom_icon);
    const b = busy.has(x.id) ? 'disabled' : '';
    return `<li class="ii-row${x.id === focusItemId ? ' is-focus' : ''}" data-ii-item="${esc(x.id)}">
      <span class="ii-prev" title="Default icon">${icon(def, { size: 32, label: 'Default icon' })}</span>
      <span class="ii-prev" title="${url ? 'Your icon' : 'No own icon'}">${url ? icon(def, { size: 32, src: url, label: 'Your icon' }) : '<span class="ii-none" aria-label="No own icon">—</span>'}</span>
      <span class="ii-name"><strong>${esc(x.name)}</strong> <span class="small muted">${x.official ? 'Official' : x.content_id ? 'DM Content' : 'Campaign custom'}</span></span>
      <span class="ii-acts"><button type="button" class="btn btn-sm" data-ii-up ${b}>${url ? 'Replace…' : 'Upload…'}</button>
        ${url ? `<button type="button" class="btn btn-sm btn-bad" data-ii-rm ${b}>Remove</button>` : ''}</span></li>`;
  }
  function draw() {
    const needle = q.toLowerCase();
    const hits = items.filter((x) => !needle || x.name.toLowerCase().includes(needle));
    hits.sort((a, b) => (b.id === focusItemId) - (a.id === focusItemId) || !!b.custom_icon - !!a.custom_icon);
    list.innerHTML = hits.length ? hits.slice(0, SHOWN).map(rowHTML).join('')
      + (hits.length > SHOWN ? `<li class="small muted">${hits.length - SHOWN} more: refine the search.</li>` : '')
      : '<li class="muted">No item of this campaign matches. Items appear here once they are campaign content or someone in the campaign holds them.</li>';
  }
  async function load() {
    try { items = await getCampaignItemIcons(campaignId) || []; draw(); }
    catch (err) { list.innerHTML = `<li class="gov-error">${esc(err.message)}</li>`; }
  }
  async function run(id, fn, ok) {
    busy.add(id); draw();
    try { await fn(); toast(ok, 'good'); onChanged?.(); } catch (err) { toast(err.message, 'bad', 6000); }
    busy.delete(id);
    await load();
  }
  m.el.addEventListener('input', (e) => { if (e.target.matches('[data-ii-q]')) { q = e.target.value.trim(); draw(); } });
  m.el.addEventListener('click', async (e) => {
    const id = e.target.closest('[data-ii-item]')?.dataset.iiItem;
    if (!id) return;
    if (e.target.closest('[data-ii-up]')) { target = id; file.value = ''; file.click(); return; }
    if (e.target.closest('[data-ii-rm]')) {
      const x = items.find((i) => i.id === id);
      if (!(await confirmDialog(`Remove your icon from “${x?.name || 'this item'}”? It shows its default icon again.`, { okLabel: 'Remove' }))) return;
      run(id, () => removeItemIcon(campaignId, id), 'Icon removed. The default icon is back.');
    }
  });
  file.addEventListener('change', () => {
    const f = file.files?.[0];
    const id = target;
    target = null;
    if (f && id) run(id, () => uploadItemIcon(campaignId, id, f), 'Icon saved. Players see it the next time their inventory loads.');
  });
  load();
  return m;
}
