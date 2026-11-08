// Combat Builder glyphs (docs/ICON_ASSET_INVENTORY.md "Combat Builder"): small project-authored inline SVG line icons, drawn
// for Tavern Ledger (private-table use, no third-party source, no runtime URL). Concepts the WebP set has no icon for;
// everything else uses the central registry (icons.js): initiative, concentration, damage, heal, conditions, reaction.
const P = {
  swords: '<path d="M4 4l9 9M4 4v4M4 4h4M20 4l-9 9M20 4v4M20 4h-4M7.5 14.5l-3 3M16.5 14.5l3 3M6 19l-2 2M18 19l2 2"/>',
  round: '<path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v4h-4"/>',
  next: '<path d="M5 12h12M13 7l5 5-5 5"/>',
  prev: '<path d="M19 12H7M11 7l-5 5 5 5"/>',
  adv: '<path d="M7 14l5-5 5 5M7 19l5-5 5 5"/>',
  dis: '<path d="M7 5l5 5 5-5M7 10l5 5 5-5"/>',
  hidden: '<path d="M3 12s3.5-6 9-6c2 0 3.7.8 5 1.8M21 12s-3.5 6-9 6c-2 0-3.7-.8-5-1.8M4 20L20 4"/>',
  shown: '<path d="M2.5 12s3.5-6 9.5-6 9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6z"/><circle cx="12" cy="12" r="2.5"/>',
  crown: '<path d="M4 18h16M5 18l-1-9 5 4 3-6 3 6 5-4-1 9"/>',
  shield: '<path d="M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z"/>',
  heart: '<path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.5A4 4 0 0 1 19 10c0 5.6-7 10-7 10z"/>',
  pause: '<path d="M9 5v14M15 5v14"/>',
  play: '<path d="M7 5l12 7-12 7z"/>',
  flag: '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>',
  undo: '<path d="M9 7L4 12l5 5M4 12h10a6 6 0 0 1 0 12"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  bolt: '<path d="M13 3L5 14h6l-1 7 8-11h-6z"/>',
  skull: '<path d="M6 16v-4a6 6 0 1 1 12 0v4l-2 1v3H8v-3z"/><circle cx="9.5" cy="12" r="1.2"/><circle cx="14.5" cy="12" r="1.2"/>',
  bell: '<path d="M6 16V11a6 6 0 1 1 12 0v5l2 2H4zM10 21h4"/>',
  history: '<path d="M4 12a8 8 0 1 0 2.3-5.6M4 4v4h4M12 8v4l3 2"/>',
  wifi_off: '<path d="M3 3l18 18M8.5 16.5a5 5 0 0 1 7 0M5 13a10 10 0 0 1 4-2.4M19 13a10 10 0 0 0-3-2M2 9.5a15 15 0 0 1 4.5-2.6M12 20h.01"/>',
  help: '<circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6M12 17h.01"/>',
};

/** An inline glyph; label makes it meaningful, otherwise it is decorative. */
export function glyph(name, { size = 18, label = '', cls = '' } = {}) {
  const body = P[name] || P.plus;
  const a11y = label ? `role="img" aria-label="${label.replace(/"/g, '&quot;')}"` : 'aria-hidden="true" focusable="false"';
  return `<svg class="cb-glyph ${cls}" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"
    stroke-linecap="round" stroke-linejoin="round" ${a11y}>${body}</svg>`;
}
export const GLYPHS = Object.keys(P);
