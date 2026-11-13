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
// Character read path (docs/FRONTEND_READ_CACHE.md): 'on' = progressive open (Character Shell, then one domain request,
// server-side rules cache) with coalesced reloads and one Realtime table; 'off' = the legacy per-widget reads.
// Rollback of the frontend = 'off'.
// A browser may override it for controlled testing with ?fluent=1 / ?fluent=0 (?fluent=default clears the override).
export const FLUENT_READS = 'on';
// Combat Builder (docs/COMBAT_BUILDER_ARCHITECTURE.md "Feature flag"): 'off' hides it; 'dm' shows it to campaign DMs and admins.
// It never grants anything: every combat_* RPC checks the campaign DM role itself. A future 'players' value is reserved for
// the player combat view (get_combat_player_view already exists). The first production release shipped with 'off' (2026-11-08) and was then enabled for DMs.
export const COMBAT_BUILDER = 'dm';
// DM content management (docs/CONTENT_MANAGEMENT.md): 'off' keeps the earlier Content Library buttons (Delete draft, Delete unused
// item); 'on' adds the usage report, permanent delete of any unused custom content and "Duplicate official as homebrew". It never
// grants anything: every content RPC checks the campaign DM / admin role itself. Rollback of the frontend = 'off'.
export const CONTENT_MANAGEMENT = 'on';
// Email account flows (docs/AUTH_EMAIL_FLOWS.md): 'off' keeps the sign-in card exactly as before; 'on' adds "Forgot password?"
// (reset mail) and "Resend confirmation". Both send mail, so turn it on only after custom SMTP is set up in the Supabase dashboard
// (the built-in mailer delivers only to project team addresses). A link the user arrives with (reset, confirm, magic link) is
// handled with either value. Rollback of the frontend = 'off'.
export const AUTH_EMAIL_FLOWS = 'off';
// Crafting v1 (docs/CRAFTING_V1.md): 'off' = no crafting UI, no crafting request and js/crafting.js is never loaded (the app is
// exactly as before); 'dm' = DM Space shows Crafting (recipes, attempts) so a DM can prepare recipes; 'on' = also the player's
// Inventory panel, for characters whose campaign turned the rule "Crafting" on (Campaign rules; off in every preset). It never
// grants anything: every crafting RPC checks the DM role or the character's owner and the campaign rule itself.
export const CRAFTING = 'off';
