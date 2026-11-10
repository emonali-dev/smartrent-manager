# SmartRent BD roadmap

| Phase | Scope | State |
|---|---|---|
| 1 | Repository audit, architecture, UI/UX design, database schema draft | **Done** (this pull request) |
| 2 | Monorepo setup; Next.js web app with the public website and all dashboards built from the prototype design | Next. Needs package installs enabled in the build environment |
| 3 | NestJS API, Prisma migrations matching `db/schema.sql`, authentication (email, mobile + OTP, 2FA), roles | Needs a separate PostgreSQL database |
| 4 | Properties, buildings, units, tenants, leases, documents | |
| 5 | Rent engine, invoices, utility bills, payments, receipts; bKash/Nagad sandbox | Needs merchant sandbox credentials |
| 6 | Maintenance, complaints, notices, notifications (in-app, email, SMS, WhatsApp, push) | Needs SMS, WhatsApp Business, email and Firebase accounts |
| 7 | Super Admin and the monthly subscription system | |
| 8 | Android app (React Native + Expo) | Needs a Google Play developer account |
| 9 | AI assistance (suggestions only, human confirmation) and other integrations | |
| 10 | Security audit, performance tests, production deployment | Needs a VPS and the owner's explicit approval to deploy |

## Open items for the owner

- **Server:** a VPS, and a PostgreSQL database separate from every other company project.
- **Payment gateways:** bKash and Nagad merchant accounts, sandbox and live.
- **Messaging accounts:**
  - SMS gateway;
  - WhatsApp Business API;
  - email sender domain;
  - Firebase project.
- **Rental agreements:** Bangla and English templates reviewed by a lawyer before use.
- **Pricing details:** final plan limits. The current limits are proposals that Super Admin can change.
