# SmartRent BD

**Your Property, Smarter Management.**
Rental and property management SaaS for Bangladesh, by **SIDDIQIYA Technology**.

SmartRent BD lets landlord organizations run their buildings in one place: units, tenants and leases, monthly rent and utility invoices, payments and receipts, expenses, maintenance, notices and reports. Tenants get their own portal, property managers get a scoped panel, and SIDDIQIYA Technology runs the platform from a Super Admin dashboard with monthly subscriptions (Free, Starter ৳199, Business ৳499, Professional ৳999, Enterprise custom).

## Status: Phase 1 (architecture and design)

| Part | State |
|---|---|
| Design prototype (`prototype/index.html`) | Done. Clickable, Bangla/English, light/dark, all four roles. Browser-only sample data, **not** for real customers. |
| Database schema (`db/schema.sql`) | Phase 1 draft. Loads on PostgreSQL 16; 38 automated checks pass. |
| Architecture, security, schema docs (`docs/`) | Done for Phase 1. |
| Backend API, real login, payment gateways, notifications, PDF, Android app, public website | **Not built yet.** See [docs/ROADMAP.md](docs/ROADMAP.md). |

Nothing here is production-ready. Do not store real tenant data or money records in the prototype.

## Repository layout

```
prototype/          Design prototype (single HTML file) and its end-to-end test
db/                 PostgreSQL schema, schema tests and test runner
docs/               ARCHITECTURE, DATABASE_SCHEMA, SECURITY, TESTING, ROADMAP
legacy/             The earlier single-browser demo, kept for reference
.github/workflows/  CI: schema tests on PostgreSQL and prototype tests in Chromium
```

The planned application layout (Phase 2 onward) is described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): `apps/web` (Next.js), `apps/api` (NestJS + Prisma), `apps/mobile` (React Native + Expo) and `packages/shared`.

## Run the checks

```bash
# Database schema tests (needs a throwaway PostgreSQL 14+; never a real database)
db/run-tests.sh -h localhost -p 5432 -U postgres

# Prototype tests (Python 3 + Playwright with Chromium)
pip install playwright==1.48.0 && python -m playwright install chromium
python3 prototype/test_prototype.py
```

To look at the prototype, open `prototype/index.html` in a browser. Use the "View as" menu to switch between Super Admin, Landlord, Property manager and Tenant.

## What is still needed from the owner

- A server (VPS) and a **separate** PostgreSQL database for SmartRent BD.
- bKash and Nagad merchant accounts (sandbox, then live), an SMS gateway, the WhatsApp Business API, an email service, a Firebase project and a Google Play developer account.
- Bangla and English rental agreement templates reviewed by a lawyer.
- Network access for package installs in the build environment (needed for Next.js, NestJS and Prisma).

## Ownership

© 2026 SIDDIQIYA Technology. All rights reserved.
