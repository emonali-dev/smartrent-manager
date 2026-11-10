# SmartRent BD testing

## Phase 1 suites

| Suite | Command | What it checks |
|---|---|---|
| Database schema | `db/run-tests.sh -h <host> -p <port> -U postgres` | 38 checks:<br>• invoice maths;<br>• one invoice per lease per month;<br>• no overpayment;<br>• verified-only online payments;<br>• duplicate transaction IDs refused;<br>• append-only payments and audit log;<br>• correcting entries;<br>• one active lease per unit;<br>• meter readings;<br>• mobile number format;<br>• cross-organization links refused;<br>• one live subscription;<br>• initial plan prices;<br>• row-level security as the application role. |
| Prototype | `python3 prototype/test_prototype.py` | 354 checks:<br>• every view for every role, in both languages, at 1366 px and 390 px wide (no page errors, no sideways scrolling, no "undefined/NaN");<br>• payment rules;<br>• tenant validation;<br>• meter readings;<br>• expenses;<br>• maintenance workflow;<br>• manager scope and permissions;<br>• expired-plan read-only mode;<br>• organization isolation;<br>• Super Admin verified payments;<br>• tenant sees only own invoices;<br>• online payment never simulated. |

Both run in CI on every pull request (`.github/workflows/checks.yml`).

Run the database suite only against a throwaway database. It drops and recreates `smartrent_test`.

## Later phases

- **Unit tests:** Jest for the money maths in `packages/shared`, and for NestJS services.
- **Integration tests:** the API against a real PostgreSQL, rebuilt by Prisma migrations, with the schema suite rerun on it.
- **End-to-end tests:** Playwright for the web app and Detox or Maestro for Android, covering:
  - registration, login and password reset;
  - invoices, partial payments and duplicate prevention;
  - webhook verification and reconciliation;
  - subscription renewal, grace periods and expiry;
  - PDF generation.
- **Release rule:** critical and high-severity defects are fixed before any release.
