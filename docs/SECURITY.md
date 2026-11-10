# SmartRent BD security

## Principles

1. Every organization's data is private to it. Isolation is enforced twice: by the API and by the database (composite foreign keys + row-level security).
2. Money records are append-only and audited. Nothing marks a payment successful except server-side verification with the gateway.
3. Secrets never reach the browser or the mobile app, and are never committed to Git.
4. Least privilege: tenants see only their own records; managers see only assigned properties and only what the landlord allows; Super Admin actions are logged.

## Controls (target, by phase)

| Area | Control |
|---|---|
| Passwords | Argon2id; breached-password check; rate-limited login; account lockout after repeated failures |
| Sessions | Short-lived access token, rotating refresh token stored hashed; "sign out other devices"; login history |
| 2FA | Optional TOTP for all, required for Super Admin and recommended for landlords |
| OTP | Phone OTP through the SMS gateway, with expiry, attempt limits and resend limits |
| Authorization | Role-based guards in NestJS plus row-level security; organization taken from the member record, never from the request body |
| Input | DTO validation (class-validator) on every endpoint; database check constraints as a second line |
| XSS | React escaping, strict Content-Security-Policy, no `dangerouslySetInnerHTML` with user content |
| CSRF | SameSite=strict cookies for the web session plus CSRF token on state-changing requests |
| SQL injection | Prisma parameterized queries only; raw SQL reviewed and parameterized |
| Rate limiting | Per-IP and per-user limits on auth, OTP, payments and public forms |
| Files | Private bucket, signed URLs with short expiry, type/size allow-list, virus scan |
| Sensitive fields | National ID encrypted at the application layer; masked in the UI; each reveal is audit-logged |
| Payments | Gateway verify API and signed webhooks only; idempotency keys; unique transaction IDs; no raw card data stored |
| Audit | Append-only `audit_logs` for every admin, money and permission action |
| Backups | Daily encrypted off-site backups, tested restore, retention policy |
| Monitoring | Error tracking, uptime checks, alerts on failed payments and unusual logins |
| Secrets | Environment variables from the server's secret store; `.env` files never committed |

## Phase 1 status

- `db/schema.sql` already enforces isolation, append-only payments and audit logs, payment verification, and the uniqueness rules; `db/tests.sql` checks them (38 checks).
- The prototype is browser-only and has **no** real security. It must not hold real tenant data, national IDs or money records.

## Reporting a problem

Report security issues privately to SIDDIQIYA Technology. Do not open a public GitHub issue for them.
