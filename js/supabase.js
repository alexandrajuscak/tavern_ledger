// supabase-js 2.117.2 is self-hosted (vendor/supabase-js, loaded by index.html as a classic script): no CDN request at runtime.
const { createClient } = globalThis.supabase;
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, PRODUCTION_HOSTS } from './config.js?v=22';
import { readSignalFor } from './read-control.js?v=22';
import { interceptRpc, setRawRpc } from './read-layer.js?v=22';

// Local development only. When the app is served from localhost / 127.0.0.1 it talks ONLY to the local Supabase
// stack, never to the hosted project in js/config.js. The local URL and anon key come from js/config.local.js,
// which scripts/start-local.ps1 writes from `supabase status` (git-ignored, never deployed). Tests may instead set
//   localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({ url: 'http://127.0.0.1:54321', key: '<local anon key>' }))
// Both are ignored on every other host, so the deployed site always uses js/config.js.
const LOCAL_HOSTS = ['localhost', '127.0.0.1'];
const isLocalOrigin = LOCAL_HOSTS.includes(window.location.hostname);
const isLocalApi = (o) => !!o && /^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(o.url) && typeof o.key === 'string';
async function localConfig() {
  try {
    const o = JSON.parse(localStorage.getItem('tavern-ledger:local-supabase') || 'null');
    if (isLocalApi(o)) return o;
  } catch { /* no override */ }
  try {
    const m = await import('./config.local.js');
    const o = { url: m.LOCAL_SUPABASE_URL, key: m.LOCAL_SUPABASE_ANON_KEY };
    if (isLocalApi(o)) return o;
  } catch { /* not generated: run scripts/start-local.ps1 */ }
  return null;
}
// Staging (docs/DEPLOYMENT_FRONTEND_CONFIGURATION.md): only from a local origin with ?env=staging, from the git-ignored
// js/config.staging.js (a hosted project URL and its publishable key). It can never be reached from the deployed site.
const wantsStaging = isLocalOrigin && new URLSearchParams(window.location.search).get('env') === 'staging';
async function stagingConfig() {
  try {
    const m = await import('./config.staging.js');
    const o = { url: m.STAGING_SUPABASE_URL, key: m.STAGING_SUPABASE_PUBLISHABLE_KEY };
    if (/^https:\/\/[a-z0-9]+\.supabase\.co$/.test(o.url) && typeof o.key === 'string') return o;
  } catch { /* not created: see the deployment docs */ }
  return null;
}
// The environment is chosen by where the page is served from, never by a fallback:
//   local origin            -> the local stack only (no hosted fallback)
//   local origin + staging  -> the staging project only
//   a production host       -> js/config.js
//   any other host          -> nothing (a clear message instead of a silent connection)
const isProductionHost = PRODUCTION_HOSTS.includes(window.location.hostname);
export const environment = wantsStaging ? 'staging' : isLocalOrigin ? 'local' : isProductionHost ? 'production' : 'unknown-host';
const local = environment === 'local' ? await localConfig() : null;
const staging = environment === 'staging' ? await stagingConfig() : null;
const chosen = environment === 'local' ? local : environment === 'staging' ? staging
  : environment === 'production' ? { url: SUPABASE_URL, key: SUPABASE_PUBLISHABLE_KEY } : null;
const url = chosen?.url;
const key = chosen?.key;

// Never run with a privileged key in the browser (secret keys and service_role JWTs bypass Row Level Security).
function isPrivilegedKey(k) {
  if (typeof k !== 'string') return false;
  if (k.startsWith('sb_secret_')) return true;
  try {
    const payload = JSON.parse(atob(k.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
    return payload?.role === 'service_role';
  } catch {
    return false;
  }
}
if (isPrivilegedKey(key)) {
  throw new Error('A SECRET / service_role key is configured. Use the publishable (anon) key and rotate the secret key in Supabase.');
}
// Allowlist (2026-10-23): besides refusing known privileged keys, only a publishable key or a JWT whose role is "anon" is
// accepted at all, so an unknown kind of credential (an access token, a new secret-key format) never reaches the client.
function isBrowserSafeKey(k) {
  if (typeof k !== 'string') return false;
  if (k.startsWith('sb_publishable_')) return true;
  try {
    return JSON.parse(atob(k.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')))?.role === 'anon';
  } catch {
    return false;
  }
}
if (typeof key === 'string' && !isBrowserSafeKey(key)) {
  throw new Error('The configured Supabase key is not a publishable (anon) key. Only browser-safe keys belong in the frontend configuration.');
}

export const isConfigured =
  typeof url === 'string' &&
  (url.startsWith('https://') || !!local) &&
  !url.includes('YOUR-PROJECT') &&
  typeof key === 'string' &&
  !key.includes('YOUR-KEY') &&
  key.length > 20;

export const supabase = isConfigured
  ? createClient(url, key, {
      auth: {
        flowType: 'pkce',
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null;
// one client (one Auth session, one Realtime socket) per page: counted so the tests can assert it (no credential involved)
if (supabase) globalThis.__tavernLedgerClients = (globalThis.__tavernLedgerClients || 0) + 1;

// Campaign governance (docs/DM_GOVERNANCE.md): a governed call the campaign refuses (approval required, DM only, disabled,
// locked) is announced once as a 'tavern:governance' event with the exact call, so the sheet can offer an approval request.
// The result is returned unchanged; every caller still handles the error as before.
const GOVERNANCE_CODES = new Set(['TLAPR', 'TLDMO', 'TLDIS', 'TLLCK']);
export const isGovernanceError = (e) => GOVERNANCE_CODES.has(e?.code) || GOVERNANCE_CODES.has(e?.cause?.code) || GOVERNANCE_CODES.has(e?.raw?.code);
export function announceGovernance(fn, args, error) {
  window.dispatchEvent(new CustomEvent('tavern:governance', { detail: { fn, args, error } }));
}
if (supabase) {
  const rawRpc = supabase.rpc.bind(supabase);
  setRawRpc(rawRpc);
  supabase.rpc = (fn, args, options) => {
    // reads of the open character: from the character view's seed or one coalesced request (js/read-layer.js)
    const served = options ? null : interceptRpc(fn, args);
    if (served) return served;
    const builder = rawRpc(fn, args, options);
    // character reads of the open sheet are cancelled when it closes (js/read-control.js); writes never are
    const signal = readSignalFor(fn, args);
    if (signal) builder.abortSignal(signal);
    const then = builder.then.bind(builder);
    builder.then = (onOk, onErr) => then((res) => {
      if (res?.error && GOVERNANCE_CODES.has(res.error.code)) announceGovernance(fn, args, res.error);
      return res;
    }).then(onOk, onErr);
    return builder;
  };
}

export const isLocalSupabase = !!local;
export { isLocalOrigin };

// Where OAuth / magic links send the user back to (works on GitHub Pages sub-paths; staging keeps its ?env=staging).
export const redirectUrl = () => window.location.origin + window.location.pathname + (environment === 'staging' ? '?env=staging' : '');
