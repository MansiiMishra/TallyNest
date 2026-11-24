# TallyNest — Small Business Order and Payment Tracker

Self-service order and payment tracker for small businesses. Owners sign in with an email link, create a workspace, and manage their customers, orders, and payments. React, TypeScript, and Vite provide the installable PWA; Supabase Auth and Postgres are the online source of truth.

## V1 included

- Email-link sign-in and self-service workspace setup for business owners.
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
5. In Supabase Auth, enable email signups and set the Site URL and allowed redirect URLs to the local origin and deployed HTTPS origin. Configure email OTP/magic-link delivery.

The browser only receives the publishable/anon key. Never put a service-role key in `VITE_*` variables or commit it.

## Supabase setup

1. Link the intended project with the Supabase CLI and apply `supabase/migrations` in order (`supabase db push`). Review migrations before applying them to production. The new onboarding migration must be applied before self-service workspace creation works.
2. In Supabase Auth, enable email signups, set the Site URL to the deployed HTTPS origin, and add the production origin and local development origin to the redirect allowlist. Keep email confirmation enabled and configure email OTP/magic-link delivery.
3. Set `.env.local` with the project URL and publishable key, then start the app. On Vercel, set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` for Production and redeploy after changing them.

New users confirm their email through the sign-in link, then enter a business name once. The `create_business_for_current_user` database function creates the workspace and its owner membership in one transaction. It is executable only by authenticated users, does not accept a user ID from the browser, and returns an existing active workspace for repeat requests. The browser never receives a service-role or secret key.

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

The owner provisioning script remains available for operator-managed or recovery setup; ordinary signup does not require a service-role key. Supabase Auth sends account sign-in emails; the app never sends customer messages automatically.

## Database notes

- `supabase/migrations/20261101000100_initial_schema_and_rls.sql` creates the tenant schema, RLS, and audit foundation.
- `supabase/migrations/20261101000200_v1_workflows_and_financial_rpcs.sql` adds the workflow and ledger RPCs and derived balance views.
- `src/App.test.tsx` exercises the owner signup and core daily workflow in a browser-like test environment. Supabase Auth and data calls are mocked; it does not contact the live project.
- Run the app workflow test with `pnpm test`, and run the production typecheck/build with `pnpm build`.
- `supabase/tests/database/tenant_isolation.test.sql` is a draft database isolation test; it needs a local Supabase database and is not run by the frontend test command.
- See `supabase/ROLLBACK.md` for rollback guidance. Prefer forward-fix migrations once a migration has been applied.
