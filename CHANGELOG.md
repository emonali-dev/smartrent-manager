# Changelog

## Phase 1 — architecture and design (2026-11-10)

- Rebranded the project as **SmartRent BD** by SIDDIQIYA Technology and removed the previous brand name everywhere.
- Moved the earlier single-browser demo to `legacy/smartrent-manager-v0.html`.
- Added the design prototype `prototype/index.html`. It covers:
  - Super Admin, Landlord, Property manager and Tenant views;
  - Bangla and English, light and dark mode;
  - the spec pricing (Free / ৳199 / ৳499 / ৳999 / custom), which Super Admin can edit;
  - invoices with meter readings and late fees;
  - payments with transaction IDs and receipts;
  - expenses, net income, reports and the daily collection report;
  - the maintenance workflow, notices, manager permissions, and the audit log.
- Added the PostgreSQL schema `db/schema.sql`. All spec entities are in it, along with organization isolation, append-only payments and audit logs, and verified-only online payments.
- Added `db/tests.sql` (38 checks) and `prototype/test_prototype.py` (354 checks), and CI to run both.
- Added docs: README, ARCHITECTURE, DATABASE_SCHEMA, SECURITY, TESTING, ROADMAP.
