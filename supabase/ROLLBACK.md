# Migration rollback notes

## 20261101000100 initial schema and RLS

- This migration is a pre-pilot foundation. In development, reset the local database and reapply migrations to reverse it.
- Do not run a destructive down migration against production after business data exists. For a production defect, prefer a forward-fix migration reviewed against a production-like database.
- If a release causes data loss or corruption, pause writes, preserve logs, and restore to a new project from the selected backup/PITR point. Validate tenant isolation and balances there before switching the app to the restored project.
- Before each later migration, add a section here describing reversible DDL, required data backfills, and the forward-fix or restore path. Record who approved the rollback plan in the release record.
