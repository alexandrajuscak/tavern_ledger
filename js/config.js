// Supabase project settings for PRODUCTION (docs/DEPLOYMENT_FRONTEND_CONFIGURATION.md).
// Find them in: Supabase Dashboard → Project Settings → API Keys.
//
// Only BROWSER-SAFE values belong here:
//   SUPABASE_URL             https://<project-ref>.supabase.co
//   SUPABASE_PUBLISHABLE_KEY the PUBLISHABLE key ("sb_publishable_…"); Row Level Security protects the data.
// NEVER put the secret key ("sb_secret_…"), the legacy service_role key, a database password or an access token here:
// the app refuses to start with anything but a publishable / anon key, and supabase/tests/browser/deployment_environment_test.py
// fails if this file contains one.
//
// This configuration is used only on the hosts below. Local development uses js/config.local.js, staging uses
// js/config.staging.js (both git-ignored, never deployed). Until the production values are set at release time, the app
// shows its "Almost there" setup screen and connects to nothing. (Release 2026-10-23: the existing production project.)
export const SUPABASE_ENV = 'production';
export const PRODUCTION_HOSTS = ['alexandrajuscak.github.io'];
export const SUPABASE_URL = 'https://pfgzbzzouvwvobftwlsc.supabase.co';
export const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_8pUE0WNlOpKZAhm9jHAeZg_YglBmUY8';
