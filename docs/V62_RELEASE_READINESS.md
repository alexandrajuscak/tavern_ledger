# V6.2 release readiness (2026-10-23)

Two questions with different bars:
- **Private table:** the owner, their DM and a handful of friends use it for their own campaign. The data is theirs and
  can be restored from a backup.
- **Public release:** strangers sign up, data belongs to people you do not know, and you are responsible for uptime,
  privacy and licensing.

Scores are 0–10 per category, based on evidence from this pass and V6 (tests named in the linked docs). "Not measured"
lowers a score; it is never assumed good.

## Scores

| Category | Private table | Public release | Evidence / what holds it back |
|---|---|---|---|
| Authorization (RLS, RPC roles) | 9 | 8 | 72-cell matrix measured across 6 actors (docs/V62_AUTHORIZATION_MATRIX.md). Every SECURITY DEFINER function pins its search_path (SQL suites). Public: no external penetration test and no rate limiting of the API. |
| Hidden DM data | 9 | 8 | Fixed the one leak (ADV-BLOCKER-001). A sweep of all 159 readable tables and views plus the read models finds no hidden marker before or after a reveal. Public: new features must keep the sweep in CI. |
| Data integrity | 9 | 8 | CHECK constraints for HP and coins, FK and integrity report all 0, atomic idempotent approvals, 4 concurrency scripts. Public: no point-in-time recovery or managed backup policy defined. |
| Error handling | 9 | 8 | Central friendly errors (toasts, load screen, unhandled rejections), injected-failure tests ERR1–4, LINK1–4, ASSET1. Public: no error reporting or telemetry to learn about failures in the field. |
| Offline / interrupted use | 8 | 6 | Autosave queue, offline status and sync (INT1, OFF1), reconnect resync (RT4). Public: no offline app shell; a never-opened sheet cannot be used offline. |
| Realtime and multi-session | 8 | 6 | 40/40 events delivered, 0 leaked channels, last-write-wins convergence (MS1–5, RT1–4). Public: measured on localhost only; unfiltered DELETE ids (ADV-FUTURE-015); no load test with many concurrent campaigns. |
| Import / export | 8 | 7 | Hostile files clamped, forged ownership ignored, core atomic, round trip identical (IMP0–7). Public: the enrichment phase is best effort (ADV-FUTURE-016). |
| Injection / XSS | 9 | 8 | Payloads in 7 fields inert on home and all six tabs (XSS1–3); all rendering goes through `esc()`. Public: no Content-Security-Policy header yet (depends on the hosting). |
| Performance | 9 | 5 | Local: home 0.16 s, open 0.05 s, tab ≤ 0.17 s, 300 tab switches with flat heap and DOM. Public: never measured over a real network or hosted Supabase. |
| Accessibility | 7 | 6 | V6: heading order, names, touch targets ≥ 24 px, focus handling. Not tested with a real screen reader. |
| Test coverage and isolation | 9 | 8 | Backend 3,429 suite checks plus 596 named checks; browser suites; isolation harness with fingerprints and a journal. Public: no CI. The suites run by hand on one machine. |
| Operations (backup, deploy, monitoring) | 6 | 2 | Local backups by hand; a restore from backup was exercised in V6. Nothing is deployed. No monitoring, no alerting, no documented restore drill on a host. |
| Licensing and legal | 7 | 2 | Fonts OFL and supabase-js MIT. The curated icons have **unknown licences**. Rules content needs an SRD / licence review. There is no privacy policy or terms. |
| **Overall** | **8.2 — ready for a private table** | **6.3 — not ready for a public release** | |

The overall figure is the plain mean of the category scores, rounded. It is a summary, not a gate: one category at 2 is
enough to block a public release.

## Private table: go, with these habits

1. Keep the local backup routine (a `.dump` before every change session; a real restore was exercised in V6, and V6.2 checks that a Supabase restart keeps the data).
2. Use the DM Space presets: **standard** for most tables, **relaxed** only with people you trust to edit their own builds.
3. After an update, run the 4 V6.2 suites (about 5 minutes). Run the full suites after backend changes.

## Public release: blockers in order

1. **Licensing:** replace or license the icons, review the rules content against its licence, and write a privacy policy
   and terms.
2. **Operations:** hosted Supabase with backups or point-in-time recovery, a restore drill, monitoring and error reporting.
3. **Performance and Realtime on a real network:** measure home, open and tab timings, and Realtime latency and fan-out with
   many campaigns.
4. **CI:** run the SQL suites and the V6.2 suites on every change, including the hidden-data sweep.
5. **Hardening for strangers:** rate limits / CAPTCHA on sign-up, email confirmation, a CSP header, and a
   penetration-test pass.
