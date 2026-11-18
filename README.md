# TallyNest — Small Business Order and Payment Tracker

Invite-only order and payment tracker for one small business. React, TypeScript, and Vite provide the installable PWA; Supabase Auth and Postgres are the online source of truth.

## V1 included

- Email magic-link sign-in for invited owners, with tenant-scoped reads and writes.
- Today delivery list grouped by slot, with delivered, undo, edit, and cancel actions.
- Month and week calendar, one-off and recurring closures, and open exceptions.
- Customer directory and account detail with scheduled orders, delivered history, notes, balances, and ledger.
- Single orders, repeat-last-order, weekly booking preview with closure skips, and bulk/event orders.
- Append-only payment and return ledger, tagged deposits, general payment allocation, and reversals.
- Weekly/monthly reminder lists with prefilled WhatsApp or copy, one-tap log, undo, and same-day deduplication.
- Business, currency, timezone, delivery slots, terminology, and reminder settings; customer/order/payment CSV exports.
- PWA manifest and app-shell service worker. Business data writes need an internet connection.

Online transactional writes are implemented as security-checked Postgres RPCs in the second migration. The browser does not write directly to the financial ledger.

## Local setup

1. Install Node.js 20 or newer and pnpm (or npm).
2. Run `pnpm install` (or `npm install`).
3. Copy `.env.example` to `.env.local`; set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` to the project URL and publishable key.
4. Start with `pnpm dev -- --host 127.0.0.1 --port 3000` and open `http://127.0.0.1:3000`.
5. In Supabase Auth, set the Site URL and allowed redirect URLs to the local origin and deployed HTTPS origin. Keep signup disabled and configure email OTP/magic-link delivery.

The browser only receives the publishable/anon key. Never put a service-role key in `VITE_*` variables or commit it.

## Supabase setup

1. Link the intended project with the Supabase CLI and apply `supabase/migrations` in order (`supabase db push`). Review both migrations before applying them to production; they have not been applied to a live project from this workspace.
2. Set the Auth Site URL and redirect allowlist. Email magic-link sign-in is configured to disallow self-signup.
3. Set the four provisioning variables in a private PowerShell session, then run `node scripts/provision-owner.mjs` once to create the business and invite its owner. Use the service-role secret only in this server-side provisioning step; do not paste it into chat, `.env.local`, or the browser.
4. Set `.env.local` with the project URL and publishable key, then start the app.

Example PowerShell (replace values locally; do not save the service secret in source control):

```powershell
$env:SUPABASE_URL = 'https://your-project.supabase.co'
$env:SUPABASE_SERVICE_ROLE_KEY = Read-Host 'Supabase service-role secret'
$env:BUSINESS_NAME = 'My Business'
$env:OWNER_EMAIL = 'owner@example.com'
$env:AUTH_REDIRECT_URL = 'http://127.0.0.1:3000'
node .\scripts\provision-owner.mjs
Remove-Item Env:\SUPABASE_SERVICE_ROLE_KEY
```

For production, set `AUTH_REDIRECT_URL` to the deployed HTTPS origin. Supabase Auth sends the invite/sign-in email; the app never sends customer messages automatically.

## Database notes

- `supabase/migrations/20261101000100_initial_schema_and_rls.sql` creates the tenant schema, RLS, and audit foundation.
- `supabase/migrations/20261101000200_v1_workflows_and_financial_rpcs.sql` adds the workflow and ledger RPCs and derived balance views.
- `supabase/tests/database/tenant_isolation.test.sql` is a draft database isolation test; it needs a local Supabase database and is not run by the frontend build.
- See `supabase/ROLLBACK.md` for rollback guidance. Prefer forward-fix migrations once a migration has been applied.
