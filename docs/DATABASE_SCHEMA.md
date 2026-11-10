# SmartRent BD database schema

Source of truth for Phase 1: [`db/schema.sql`](../db/schema.sql) (PostgreSQL 14+). Tests: [`db/tests.sql`](../db/tests.sql), run with `db/run-tests.sh`.

All primary keys are UUIDs (`gen_random_uuid()`), money is `numeric(12,2)` in BDT, times are `timestamptz`. Tables that customers can remove use `deleted_at` (soft delete); money and audit tables are never deleted.

## Entities

| Area | Tables |
|---|---|
| Platform | `users`, `user_sessions`, `organizations`, `organization_members`, `staff_assignments`, `system_settings`, `audit_logs`, `support_tickets` |
| Property | `properties`, `buildings`, `property_files`, `units`, `unit_charges` |
| People and leases | `tenants`, `tenant_family_members`, `leases`, `rent_changes`, `lease_documents` |
| Billing | `rent_invoices`, `invoice_items`, `utility_readings`, `utility_bills` |
| Money in | `payment_transactions` (gateway attempts), `payments` (ledger) |
| Money out | `expenses` |
| Service | `maintenance_requests`, `maintenance_comments`, `complaints`, `notices`, `notifications`, `notification_preferences` |
| SaaS | `subscription_plans`, `subscriptions`, `subscription_payments` |

```
organizations ─┬─ properties ─ buildings ─ units ─┬─ leases ─┬─ rent_invoices ─┬─ invoice_items
               │                                   │          │                 └─ payments ── payment_transactions
               │                                   │          └─ lease_documents, rent_changes
               │                                   ├─ utility_readings ─ utility_bills
               │                                   └─ maintenance_requests ─ maintenance_comments
               ├─ tenants ─ tenant_family_members, complaints
               ├─ organization_members ─ staff_assignments ─ properties
               ├─ expenses, notices
               └─ subscriptions ─ subscription_payments
```

## Rules enforced by the database

| Rule | How |
|---|---|
| No cross-organization links | Composite foreign keys `(parent_id, org_id)` |
| Organization isolation for the app role | Row-level security on every organization table, keyed on `SET LOCAL app.org_id` |
| One invoice per lease per month | Partial unique index on `(lease_id, period)` (void invoices excluded) |
| Invoice total = sum of items | Trigger `sync_invoice_total`; `amount = round(quantity × unit_price, 2)` check on items |
| No overpayment; invoice status follows payments | Trigger `apply_payment` locks the invoice row and updates `amount_paid` / `status` |
| Payments are append-only | Trigger rejects UPDATE and DELETE; corrections are negative rows with `reverses_payment_id` |
| Online payments must be verified | `apply_payment` requires a `verified` transaction with the same amount; non-cash needs a transaction |
| Gateway transaction used once | Unique `(provider, provider_txn_id)` and unique `payments.transaction_id` |
| Transaction status only moves forward | Trigger `guard_transaction` |
| One active lease per unit | Partial unique index |
| Meter readings never go backwards | Check `current_reading >= previous_reading`; one reading per unit, utility and month |
| One live subscription per organization | Partial unique index |
| Subscription "paid" needs a transaction | Check constraint |
| Audit log is append-only | Trigger rejects UPDATE and DELETE |
| Valid Bangladesh mobile numbers | Check `^(\+?88)?01[3-9][0-9]{8}$` |

## Sensitive data

- National ID numbers are stored encrypted (`tenants.nid_enc`) by the API with a key kept outside the database; only the last four digits (`nid_last4`) are stored in clear for display.
- Passwords are Argon2id hashes; refresh tokens are stored only as hashes.
- Files (documents, photos) live in private object storage; the database stores only the key.

## Moving to Prisma (Phase 3)

Prisma models will mirror these tables. Constructs Prisma cannot express (partial unique indexes, triggers, row-level security, composite foreign keys used for isolation) go into raw SQL migrations so the generated database is identical to `db/schema.sql`. The schema tests then run against the Prisma-migrated database in CI.
