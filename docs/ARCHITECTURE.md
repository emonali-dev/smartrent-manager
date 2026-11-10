# SmartRent BD architecture

Phase 1 document. It records the target design so later phases build against one plan.

## 1. Repository audit (10 November 2026)

| Item | Finding |
|---|---|
| Files | `index.html` (17 KB) and `README.md`; one commit, 8 November 2026. |
| Stack | One static HTML page with inline JavaScript; data in the browser's `localStorage`. |
| Features | Dashboard, property and tenant records, rent payment recording, printable receipts, expenses, CSV export, JSON backup. |
| Missing | Backend, database, authentication, roles, multi-tenancy, payment gateways, notifications, PDF, Android app, public website, tests, docs. |
| Branding | The page title and README carried a previous brand name. Removed; the old page now lives in `legacy/` under the SmartRent BD name. |
| Security | No server, so nothing is protected: anyone with the device sees all data; data is lost when browser storage is cleared. |
| Database readiness | None. |
| Deployment readiness | Static page only (GitHub Pages); cannot run the required backend. |

Conclusion: the existing code is a single-device demo. It is kept for reference, and the platform is built fresh.

## 2. Components

```
                ┌──────────────────────────── apps/web (Next.js, TypeScript, Tailwind) ─────────────────────────────┐
 Browser ──────▶│ Public site · Landlord dashboard · Property manager panel · Tenant portal · Super Admin dashboard │
                └───────────────────────────────────────────────┬────────────────────────────────────────────────────┘
 Android app ─── apps/mobile (React Native + Expo) ─────────────┤  HTTPS, REST + OpenAPI (Swagger)
                                                                 ▼
                ┌──────────────────────── apps/api (NestJS) ─────────────────────────┐
                │ Auth · Orgs & members · Properties · Tenants & leases · Billing    │──▶ PostgreSQL (Prisma)
                │ Payments · Expenses · Maintenance · Notifications · Subscriptions  │──▶ Private object storage (signed URLs)
                │ Reports & PDF · Audit · AI service (suggestions only)              │──▶ Redis (queues, rate limits)
                └────────────────────────────────┬───────────────────────────────────┘
                                                 ▼
          bKash · Nagad · SSLCommerz · SMS gateway · WhatsApp Business API · Email · Firebase Cloud Messaging
```

- **apps/web**: one Next.js app with route groups: `(public)`, `(landlord)`, `(manager)`, `(tenant)` and `(admin)`. It renders on the server and keeps no secrets in the browser.
- **apps/api**: NestJS with one module per domain. It is the only thing that talks to the database or to outside providers.
- **apps/mobile**: Expo app for landlords and tenants. It uses the same API and the same rules, and keeps tokens in SecureStore. Its cache is read-only and works offline.
- **packages/shared**: TypeScript types, the invoice and late-fee maths, and Bangla/English strings, used by web, mobile and the API. The money rules then exist in one place.
- **Workers**: a BullMQ queue on Redis runs monthly invoice generation, reminders, subscription renewals, notification delivery and PDF rendering.

## 3. Multi-tenancy

- **What an organization is.** An *organization* is one landlord business, and every customer record belongs to exactly one organization (`org_id`).
- **Rows can't cross organizations.** Child tables reference their parent by `(id, org_id)`. A unit in organization A can therefore never point at a building in organization B; the database refuses it.
- **The API sets the organization on every request.** Each request runs in a transaction that starts with `SET LOCAL app.org_id`. This is taken from the signed-in member's own membership and never from a value the client sends.
- **Row-level security is the second guard.** PostgreSQL policies limit the `smartrent_app` role to that organization, so a bug in a query still returns nothing from other organizations.
- **Managers see only their properties.** Property managers are limited to the properties in `staff_assignments`, and to the permissions the landlord grants: collect payments, generate invoices, edit tenants, record expenses, view national ID.
- **Tenants see only their own records.** Tenants reach just their own lease, invoices, receipts and requests.

## 4. Money rules

- **Monthly invoices.** Invoices are generated once per lease per month, which is a database constraint. The invoice total is always the sum of its line items.
- **Utility bills.** Meter readings never go backwards, and the electricity line is the units used × the unit's rate.
- **Payments are append-only.** They cannot exceed the balance due and cannot be edited or deleted. A mistake is fixed with a negative *correcting entry* that points at the original payment.
- **Online payments.** A bKash/Nagad/card payment needs a `payment_transactions` row that the API has verified with the gateway on the server, through its verify API or a signed webhook. Each gateway transaction ID can be used only once. The app never marks a payment successful from anything the browser or a screenshot says.
- **Subscriptions follow the same rule.** A subscription payment can be "paid" only with a verified transaction.
- **When a subscription expires,** the organization's data stays readable and nothing is deleted. Changes are blocked until a verified payment arrives.

## 5. Subscription lifecycle

`trialing → active → (payment due) grace → expired`, plus `suspended` (Super Admin) and `canceled`. Trial and grace periods are settings (14 and 7 days to start). Plan limits are checked by the API whenever something is created: properties, units, active tenants, staff. Only one live subscription per organization is allowed.

## 6. Technology choices

| Concern | Choice |
|---|---|
| Web | Next.js (App Router), TypeScript, Tailwind CSS |
| API | Node.js LTS, NestJS, class-validator, OpenAPI via @nestjs/swagger |
| Database | PostgreSQL 16, Prisma ORM. `db/schema.sql` is the reference that Prisma migrations must reproduce, including the triggers and policies, which go in raw SQL migrations. |
| Auth | Argon2id password hashes, short-lived access token + rotating refresh token (hashed in `user_sessions`), optional TOTP 2FA, phone OTP through the SMS gateway |
| Files | S3-compatible private bucket, signed URLs, type and size checks, virus scan before use |
| PDF | Server-side rendering with embedded Hind Siliguri for Bangla |
| Notifications | In-app, email, SMS, WhatsApp Business API (official), FCM push, with per-user preferences |
| Hosting | VPS with Docker Compose (api, web, worker, Redis, Caddy for TLS), managed or self-hosted PostgreSQL with encrypted off-site backups |
| CI/CD | GitHub Actions: lint, unit, integration (real PostgreSQL), end-to-end (Playwright); deploy only on an approved release |

Exact versions are pinned when the projects are created in Phase 2 and listed in each `package.json`.

## 7. Design system

The design system follows spec 21 and is shown in `prototype/index.html`.
- **Colors:** royal blue primary (`#1d4ed8`), white surfaces, a light-gray background, and status colors (green paid, amber due, red overdue).
- **Fonts:** Hind Siliguri for Bangla and Inter for English and numbers.
- **Building blocks:**
  - a sidebar that turns into a tab strip on phones;
  - number cards;
  - searchable, filterable tables with pages;
  - modal forms with field checks;
  - toasts, empty states and confirmation steps.
- **Modes:** light and dark.
