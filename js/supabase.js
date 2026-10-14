import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './config.js?v=6';

const key = SUPABASE_PUBLISHABLE_KEY;

if (typeof key === 'string' && key.startsWith('sb_secret_')) {
  throw new Error('js/config.js contains a SECRET key. Use the publishable key (sb_publishable_…) and rotate the secret key in Supabase.');
}

export const isConfigured =
  typeof SUPABASE_URL === 'string' &&
  SUPABASE_URL.startsWith('https://') &&
  !SUPABASE_URL.includes('YOUR-PROJECT') &&
  typeof key === 'string' &&
  !key.includes('YOUR-KEY') &&
  key.length > 20;

export const supabase = isConfigured
  ? createClient(SUPABASE_URL, key, {
      auth: {
        flowType: 'pkce',
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null;

// Where OAuth / magic links send the user back to (works on GitHub Pages sub-paths).
export const redirectUrl = () => window.location.origin + window.location.pathname;
