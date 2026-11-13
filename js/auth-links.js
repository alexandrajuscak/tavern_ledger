// Email account flows (docs/AUTH_EMAIL_FLOWS.md): links the user arrives with (password reset, email confirmation, magic link),
// the "Set new password" view, and the flag-gated "Forgot password?" and "Resend confirmation" controls.
//
// Always active (they only react to a link that is already in the URL): ?token_hash=…&type=… links behind a Continue button
// (a mail scanner that prefetches the link does not use it up), PASSWORD_RECOVERY -> "Set new password", friendly texts for
// expired / used links. Behind js/config.js AUTH_EMAIL_FLOWS = 'on' (they send mail): Forgot password, Resend confirmation.
import { supabase, redirectUrl, authArrival } from './supabase.js?v=29';
import { AUTH_EMAIL_FLOWS } from './config.js?v=29';
import { $, esc, toast, friendlyError } from './utils.js?v=29';
import { iconSrc } from './icons.js?v=29';

/** The one password minimum of the app: sign-up and reset use the same rule (the server may require more). */
export const PASSWORD_MIN = 6;
export const emailFlowsEnabled = () => AUTH_EMAIL_FLOWS === 'on';

// the email link types the app verifies itself (Supabase template: {{ .SiteURL }}?token_hash={{ .TokenHash }}&type=…)
const LINK_TYPES = new Set(['recovery', 'signup', 'email', 'magiclink']);
const RESEND_COOLDOWN_MS = 60000;   // Supabase allows one confirmation / recovery mail per address every 60 s

export const EXPIRED_LINK = 'This link has expired or was already used. Email links work once and only for a limited time.';
const NEW_LINK_HINT = ' You can request a new one below.';

/** A ?token_hash link the page arrived with (null when there is none or its type is not one of ours). */
export function pendingLink() {
  return authArrival.tokenHash && LINK_TYPES.has(authArrival.type) ? { tokenHash: authArrival.tokenHash, type: authArrival.type } : null;
}

// (token_hash / type are removed from the address by js/supabase.js as soon as they are read)

/** A password reset link is open for exactly this signed-in user. Any other user (or none) ends the recovery state, so whoever
 *  signs in next in this tab is never asked to change their password. */
export function recoveryFor(session) {
  if (authArrival.recovery && authArrival.recovery !== session?.user?.id) authArrival.recovery = false;
  return !!authArrival.recovery;
}

/** An error_code that comes from an email link (GoTrue /verify: otp_expired, flow_state_not_found / _expired). An OAuth
 *  (Google) failure carries other codes or none, and keeps its own description. */
export const isLinkErrorCode = (code) => /^(otp_|flow_state_)/i.test(code || '');

/** An error Supabase Auth put into the fragment (#error=…&error_code=otp_expired…): read it and give the router its hash back. */
export function takeHashError() {
  const h = window.location.hash || '';
  if (!/^#(error|error_code|error_description)=/.test(h)) return null;
  const p = new URLSearchParams(h.slice(1));
  history.replaceState(null, '', window.location.pathname + window.location.search);
  return { code: p.get('error_code') || '', error: p.get('error') || '', description: p.get('error_description') || '' };
}

const isExpired = (e) => /otp_expired|flow_state_expired|flow_state_not_found|bad_code_verifier/i.test(`${e?.code || ''} ${e?.error_code || ''}`)
  || /expired|invalid|already (been )?used|not found/i.test(`${e?.message || ''} ${e?.description || ''}`);

/** The text shown for a failed email link (expired, used, other device). The message test is for verifyOtp errors only (the
 *  caller knows it is an email link); errors in the address are routed here only with an isLinkErrorCode code. */
export function linkErrorText(e) {
  if (isExpired(e)) return EXPIRED_LINK + (emailFlowsEnabled() ? NEW_LINK_HINT : '');
  return friendlyError(e?.message ? e : { message: e?.description || '' }, 'This link could not be used.');
}

/** GoTrue refuses a second reset / confirmation mail to an EXISTING address (60 s per address, also the hourly mail limit)
 *  with 429 over_email_send_rate_limit, but answers 200 for an unknown address (checked on the local stack). Treated as the
 *  neutral success, so the answer never tells existing and unknown addresses apart. (over_request_rate_limit is per IP and the
 *  same for every address: it keeps the "Too many" text.) */
export const isPerAddressLimit = (e) => e?.code === 'over_email_send_rate_limit';

/** Mail-sending errors (reset, resend) in plain words; never says whether an account exists. */
export function mailErrorText(e) {
  const t = `${e?.code || ''} ${e?.message || ''}`;
  if (e?.status === 429 || /rate.?limit|too many|for security purposes/i.test(t)) return 'Too many emails were sent recently. Wait a minute and try again.';
  if (/not authorized|email_address_not_authorized/i.test(t)) return 'Email is not available for this address yet. Ask your DM for help.';
  return friendlyError(e, 'The email could not be sent. Please try again later.');
}

/** A button that may be pressed once per cooldown (the server refuses faster repeats anyway). */
function cooldown(btn, label) {
  let left = Math.round(RESEND_COOLDOWN_MS / 1000);
  btn.disabled = true;
  btn.textContent = `${label} (${left}s)`;
  const t = setInterval(() => {
    left -= 1;
    if (!btn.isConnected) return clearInterval(t);
    if (left <= 0) { clearInterval(t); btn.disabled = false; btn.textContent = label; return; }
    btn.textContent = `${label} (${left}s)`;
  }, 1000);
}

/** Resend the sign-up confirmation mail (flag 'on' only). */
export async function resendConfirmation(email, btn) {
  if (!email) { toast('Enter your email first', 'bad'); return; }
  btn.disabled = true;
  const { error } = await supabase.auth.resend({ type: 'signup', email, options: { emailRedirectTo: redirectUrl() } });
  if (error && isPerAddressLimit(error)) console.warn('[auth mail]', error.code);
  else if (error) { btn.disabled = false; toast(mailErrorText(error), 'bad', 6000); return; }
  toast('If this email is waiting for confirmation, a new link is on its way.', 'good', 6000);
  cooldown(btn, btn.dataset.label || btn.textContent);
}

const card = (inner) => `<div class="center-wrap"><div class="card auth-card">${inner}</div></div>`;

/** "Forgot password?" (flag 'on' only): one email field, a neutral answer whether or not the account exists. */
export function renderForgot(app, { email = '', onBack }) {
  app.innerHTML = card(`
      <h1 class="title">Reset your password</h1>
      <p class="muted center">Enter the email of your account and we will send you a link to choose a new password.</p>
      <form id="forgot-form" class="stack" novalidate>
        <label class="field"><span>Email</span>
          <input type="email" name="email" autocomplete="email" required value="${esc(email)}"></label>
        <button class="btn btn-gold btn-block" type="submit" id="btn-send-reset" data-label="Send reset link">Send reset link</button>
        <p class="auth-notice" id="forgot-sent" role="status" hidden></p>
        <button type="button" class="btn-link" id="btn-forgot-back">Back to sign in</button>
      </form>`);
  const form = $('#forgot-form');
  $('#btn-forgot-back').addEventListener('click', () => onBack(form.email.value.trim()));
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const addr = form.email.value.trim();
    if (!addr) { form.email.focus(); toast('Enter your email', 'bad'); return; }
    const btn = $('#btn-send-reset');
    btn.disabled = true;
    const { error } = await supabase.auth.resetPasswordForEmail(addr, { redirectTo: redirectUrl() });
    if (error && isPerAddressLimit(error)) console.warn('[auth mail]', error.code);
    else if (error) { btn.disabled = false; toast(mailErrorText(error), 'bad', 6000); return; }
    const sent = $('#forgot-sent');
    sent.textContent = 'If an account exists for this email, a reset link is on its way. Open it on any device; it works once.';
    sent.hidden = false;
    cooldown(btn, 'Send reset link');
  });
  form.email.focus();
}

/** A ?token_hash link: explain, wait for Continue, then verify. Resolves with the new session, or null (back / failed). */
export function renderLinkContinue(app, link) {
  const what = link.type === 'recovery'
    ? { title: 'Reset your password', text: 'Press Continue to choose a new password.' }
    : link.type === 'magiclink'
      ? { title: 'Sign in', text: 'Press Continue to sign in to Tavern Ledger.' }
      : { title: 'Confirm your email', text: 'Press Continue to confirm your email and sign in.' };
  return new Promise((resolve) => {
    app.innerHTML = card(`
      <img class="auth-logo" src="${iconSrc('classes/fighter')}" alt="" width="72" height="72">
      <h1 class="title">${esc(what.title)}</h1>
      <p class="muted center" id="link-text">${esc(what.text)}</p>
      <button type="button" class="btn btn-gold btn-block" id="btn-link-continue">Continue</button>
      <div class="stack" id="link-failed" hidden></div>
      <button type="button" class="btn-link" id="btn-link-back">Cancel</button>`);
    $('#btn-link-back').addEventListener('click', () => resolve(null));
    $('#btn-link-continue').addEventListener('click', async (ev) => {
      ev.currentTarget.disabled = true;
      const { data, error } = await supabase.auth.verifyOtp({ token_hash: link.tokenHash, type: link.type });
      if (!error && data?.session) {
        if (link.type === 'recovery') authArrival.recovery = data.session.user?.id || false;
        resolve(data.session);
        return;
      }
      if (error) console.warn('[auth link]', error.code || '', error.message);
      $('#btn-link-continue').remove();
      $('#link-text').textContent = linkErrorText(error || { message: 'expired' });
      $('#link-text').setAttribute('role', 'alert');
      $('#btn-link-back').textContent = 'Back';
      const failed = $('#link-failed');
      if (link.type === 'recovery' && emailFlowsEnabled()) {
        failed.innerHTML = '<button type="button" class="btn btn-block" id="btn-link-new">Send a new reset link</button>';
        failed.hidden = false;
        $('#btn-link-new').addEventListener('click', () => resolve({ wantsReset: true }));
      }
    }, { once: true });
  });
}

/** After a password-reset link: choose the new password (updateUser). `onDone` continues to the app. */
export function renderSetPassword(app, { onDone, onNewLink }) {
  app.innerHTML = card(`
      <h1 class="title">Choose a new password</h1>
      <p class="muted center">You opened a password reset link. Pick a new password for your account.</p>
      <form id="newpw-form" class="stack" novalidate>
        <label class="field"><span>New password</span>
          <input type="password" name="password" autocomplete="new-password" minlength="${PASSWORD_MIN}" required></label>
        <label class="field"><span>Repeat new password</span>
          <input type="password" name="confirm" autocomplete="new-password" minlength="${PASSWORD_MIN}" required></label>
        <button class="btn btn-gold btn-block" type="submit" id="btn-save-password">Save new password</button>
        <button type="button" class="btn-link" id="btn-newpw-later">Not now</button>
      </form>`);
  const form = $('#newpw-form');
  const leave = () => { authArrival.recovery = false; onDone(); };
  $('#btn-newpw-later').addEventListener('click', leave);
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const password = form.password.value;
    if (password.length < PASSWORD_MIN) { toast(`Password must be at least ${PASSWORD_MIN} characters`, 'bad'); return; }
    if (password !== form.confirm.value) { toast('The two passwords do not match', 'bad'); return; }
    const btn = $('#btn-save-password');
    btn.disabled = true;
    const { error } = await supabase.auth.updateUser({ password });
    btn.disabled = false;
    if (!error) {
      toast('Password updated. Use it the next time you sign in.', 'good', 6000);
      leave();
      return;
    }
    console.warn('[auth reset]', error.code || '', error.message);
    if (error.code === 'same_password') toast('That is already your password. Choose a different one.', 'bad');
    else if (error.code === 'weak_password') toast(error.message || 'Choose a stronger password.', 'bad');
    else if (error.name === 'AuthSessionMissingError' || /session/i.test(`${error.code || ''} ${error.message || ''}`)) {
      toast('The reset session has ended. Request a new reset link.', 'bad');
      if (emailFlowsEnabled() && onNewLink) { authArrival.recovery = false; onNewLink(); }
    } else toast(friendlyError(error, 'The password could not be changed. Please try again.'), 'bad');
  });
  form.password.focus();
}
