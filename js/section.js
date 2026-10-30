// Page sections (docs/UI_COMPONENTS.md "Section"): one pattern for the major groups of a sheet section.
// Level 1 surface, h2 title with a decorative icon (the title carries the meaning), optional short description, count and
// one contextual action. Nested groups inside use h3 (sectionHead({ level: 3 })).
import { esc } from './utils.js?v=14';
import { icon } from './icons.js?v=14';

/**
 * Section header. title and desc are trusted HTML fragments built by the caller; count is a number or short text.
 * variant: 'fantasy' (default: the medieval display face) or 'interface' (functional headings such as Notes, Backup, Reminders:
 * the readable UI face). Typography follows meaning, not the heading level (docs/UI_TYPOGRAPHY.md).
 */
export function sectionHead({ id = '', icon: ic = '', title, desc = '', count = null, action = '', level = 2, variant = 'fantasy' }) {
  const h = level === 3 ? 'h3' : 'h2';
  return `<div class="tl-section-head">
    <${h} class="tl-section-title ${variant === 'interface' ? 'interface-section-title' : 'fantasy-section-title'}"${id ? ` id="${esc(id)}"` : ''}>${ic ? icon(ic, { size: level === 3 ? 18 : 22, cls: 'tl-section-icon' }) : ''}<span>${title}</span>${
  count != null && count !== '' ? `<span class="tl-count">${esc(count)}</span>` : ''}</${h}>
    ${desc ? `<p class="tl-section-desc">${desc}</p>` : ''}
    ${action ? `<div class="tl-section-action">${action}</div>` : ''}
  </div>`;
}

/**
 * A whole section. tone: '' (default), 'emph' (needs attention, e.g. Next steps with open items) or 'warn'.
 * attrs: extra attributes for the <section> (id, data-*, hidden).
 */
export function sectionHTML({ id = '', headId = '', cls = '', tone = '', attrs = '', body = '', ...head }) {
  const hid = headId || (id ? `${id}-title` : '');
  return `<section class="tl-section${tone ? ` tl-section-${tone}` : ''}${cls ? ` ${cls}` : ''}"${id ? ` id="${esc(id)}"` : ''}${
    hid ? ` aria-labelledby="${esc(hid)}"` : ''} ${attrs}>
    ${sectionHead({ id: hid, ...head })}
    <div class="tl-section-body">${body}</div>
  </section>`;
}
