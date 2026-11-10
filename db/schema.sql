-- SmartRent BD: PostgreSQL schema (Phase 1 draft, PostgreSQL 14+)
-- Owner: SIDDIQIYA Technology
--
-- This is the reference schema the NestJS/Prisma backend (Phase 3) will be generated from.
-- It already enforces the rules that must never depend on application code:
--   * every organization-owned row carries org_id, and child rows must share the parent's
--     org_id (composite foreign keys), so cross-organization links are impossible;
--   * row-level security limits the application role to the organization set for the
--     current transaction (SET LOCAL app.org_id = '...');
--   * payments are append-only and can never exceed the invoice they pay;
--   * one invoice per lease per month, one active lease per unit, unique gateway
--     transaction IDs, meter readings that never go backwards;
--   * audit logs cannot be changed or deleted.
-- Money is numeric(12,2) in BDT. Timestamps are timestamptz. Primary keys are UUIDs.

begin;

-- ---------------------------------------------------------------- helpers
create or replace function app_org_id() returns uuid language sql stable as
$$ select nullif(current_setting('app.org_id', true), '')::uuid $$;
create or replace function app_is_super_admin() returns boolean language sql stable as
$$ select coalesce(current_setting('app.is_super_admin', true), '') = 'on' $$;

create or replace function touch_updated_at() returns trigger language plpgsql as
$$ begin new.updated_at := now(); return new; end $$;

create or replace function forbid_change() returns trigger language plpgsql as
$$ begin raise exception '% rows are append-only (%)', tg_table_name, tg_op using errcode = '55000'; end $$;

-- ---------------------------------------------------------------- platform: users and organizations
create table users (
  id uuid primary key default gen_random_uuid(),
  email text unique check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text unique check (phone is null or phone ~ '^(\+?88)?01[3-9][0-9]{8}$'),
  password_hash text,                       -- argon2id; never plain text
  full_name text not null check (char_length(full_name) between 1 and 120),
  locale text not null default 'bn' check (locale in ('bn','en')),
  is_super_admin boolean not null default false,
  status text not null default 'active' check (status in ('active','suspended','pending_verification')),
  two_factor_enabled boolean not null default false,
  two_factor_secret_enc bytea,              -- encrypted with an application key, never readable by the app role in plain
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (email is not null or phone is not null)
);

create table user_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  refresh_token_hash text not null unique,
  device text, ip inet,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index on user_sessions (user_id) where revoked_at is null;

create table organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 160),
  name_en text,
  slug text not null unique check (slug ~ '^[a-z0-9-]{3,60}$'),
  phone text, email text, address text, city text,
  status text not null default 'active' check (status in ('active','suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table organization_members (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id),
  user_id uuid not null references users(id),
  role text not null check (role in ('landlord','manager','staff','tenant')),
  permissions jsonb not null default '{}'::jsonb,   -- manager/staff switches set by the landlord
  status text not null default 'active' check (status in ('active','invited','removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, user_id, role),
  unique (id, org_id)
);
create index on organization_members (user_id);

-- ---------------------------------------------------------------- properties
create table properties (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id),
  name text not null check (char_length(name) between 1 and 160),
  address text, district text, latitude numeric(9,6), longitude numeric(9,6),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz,
  unique (id, org_id)
);
create index on properties (org_id) where deleted_at is null;

create table buildings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  property_id uuid not null,
  name text not null, floors int check (floors between 0 and 200),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz,
  foreign key (property_id, org_id) references properties(id, org_id),
  unique (id, org_id)
);
create index on buildings (org_id, property_id);

create table property_files (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  property_id uuid not null,
  kind text not null check (kind in ('image','document')),
  storage_key text not null,                -- private object storage; served through short-lived signed URLs
  content_type text not null, size_bytes int not null check (size_bytes between 1 and 20000000),
  uploaded_by uuid references users(id),
  created_at timestamptz not null default now(), deleted_at timestamptz,
  foreign key (property_id, org_id) references properties(id, org_id)
);

create table units (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  building_id uuid not null,
  unit_no text not null check (char_length(unit_no) between 1 and 20),
  floor int,
  bedrooms int check (bedrooms between 0 and 50), bathrooms int check (bathrooms between 0 and 50),
  area_sqft int check (area_sqft > 0),
  rent_amount numeric(12,2) not null check (rent_amount >= 0),
  security_deposit numeric(12,2) not null default 0 check (security_deposit >= 0),
  status text not null default 'vacant' check (status in ('vacant','occupied','maintenance','unavailable')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz,
  foreign key (building_id, org_id) references buildings(id, org_id),
  unique (id, org_id)
);
create unique index units_no_per_building on units (building_id, lower(unit_no)) where deleted_at is null;
create index on units (org_id, status);

create table unit_charges (                 -- fixed monthly charges and meter rates per unit
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  unit_id uuid not null,
  kind text not null check (kind in ('service','gas','water','internet','garbage','electricity','other')),
  billing text not null check (billing in ('fixed','metered')),
  amount numeric(12,2) check (amount >= 0),         -- fixed amount
  unit_rate numeric(10,4) check (unit_rate >= 0),   -- per meter unit
  label text,
  foreign key (unit_id, org_id) references units(id, org_id),
  check ((billing = 'fixed' and amount is not null) or (billing = 'metered' and unit_rate is not null)),
  unique (unit_id, kind, label)
);

-- ---------------------------------------------------------------- tenants and leases
create table tenants (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id),
  user_id uuid references users(id),        -- set once the tenant signs in to the portal
  full_name text not null check (char_length(full_name) between 1 and 120),
  phone text not null check (phone ~ '^(\+?88)?01[3-9][0-9]{8}$'),
  email text,
  nid_enc bytea,                            -- national ID, encrypted by the API with a key held outside the database
  nid_last4 text check (nid_last4 ~ '^[0-9]{4}$'),
  emergency_name text, emergency_phone text,
  household_size int check (household_size between 1 and 50),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz,
  unique (id, org_id)
);
create index on tenants (org_id) where deleted_at is null;
create index on tenants (user_id);

create table tenant_family_members (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null, tenant_id uuid not null,
  full_name text not null, relation text, age int check (age between 0 and 130),
  foreign key (tenant_id, org_id) references tenants(id, org_id)
);

create table leases (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  unit_id uuid not null,
  tenant_id uuid not null,
  start_date date not null,
  end_date date,
  move_in_date date, move_out_date date,
  rent_amount numeric(12,2) not null check (rent_amount >= 0),
  deposit_amount numeric(12,2) not null default 0 check (deposit_amount >= 0),
  advance_amount numeric(12,2) not null default 0 check (advance_amount >= 0),
  due_day int not null default 10 check (due_day between 1 and 28),
  late_fee_amount numeric(12,2) not null default 0 check (late_fee_amount >= 0),
  grace_days int not null default 0 check (grace_days between 0 and 31),
  status text not null default 'draft' check (status in ('draft','active','ended','terminated')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key (unit_id, org_id) references units(id, org_id),
  foreign key (tenant_id, org_id) references tenants(id, org_id),
  check (end_date is null or end_date > start_date),
  unique (id, org_id)
);
create unique index one_active_lease_per_unit on leases (unit_id) where status = 'active';
create index on leases (org_id, status);
create index on leases (tenant_id);

create table rent_changes (                 -- rent increase history
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null, lease_id uuid not null,
  old_amount numeric(12,2) not null, new_amount numeric(12,2) not null check (new_amount >= 0),
  effective_from date not null, reason text, changed_by uuid references users(id),
  created_at timestamptz not null default now(),
  foreign key (lease_id, org_id) references leases(id, org_id)
);

create table lease_documents (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null, lease_id uuid not null,
  language text not null check (language in ('bn','en')),
  template_version text not null,
  storage_key text not null,
  status text not null default 'draft' check (status in ('draft','sent','signed','superseded')),
  signed_by_landlord_at timestamptz, signed_by_tenant_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (lease_id, org_id) references leases(id, org_id)
);

-- ---------------------------------------------------------------- invoices, utilities, payments
create table rent_invoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  lease_id uuid not null,
  invoice_no text not null,
  period date not null check (extract(day from period) = 1),   -- first day of the billed month
  issue_date date not null default current_date,
  due_date date not null,
  total numeric(12,2) not null default 0 check (total >= 0),
  amount_paid numeric(12,2) not null default 0 check (amount_paid >= 0),
  status text not null default 'open' check (status in ('open','partially_paid','paid','void')),
  void_reason text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key (lease_id, org_id) references leases(id, org_id),
  unique (org_id, invoice_no),
  unique (id, org_id),
  check (amount_paid <= total),
  check (due_date >= issue_date)
);
create unique index one_invoice_per_lease_month on rent_invoices (lease_id, period) where status <> 'void';
create index on rent_invoices (org_id, period);
create index on rent_invoices (org_id, status) where status in ('open','partially_paid');

create table invoice_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  invoice_id uuid not null,
  kind text not null check (kind in ('rent','service','electricity','gas','water','internet','garbage','late_fee','discount','adjustment','other')),
  description text,
  quantity numeric(12,3) not null default 1,
  unit_price numeric(12,4) not null,
  amount numeric(12,2) not null,
  foreign key (invoice_id, org_id) references rent_invoices(id, org_id) on delete cascade,
  check ((kind = 'discount' and amount <= 0) or (kind <> 'discount')),
  check (amount = round(quantity * unit_price, 2))
);
create index on invoice_items (invoice_id);

create table utility_readings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  unit_id uuid not null,
  utility text not null check (utility in ('electricity','gas','water')),
  period date not null check (extract(day from period) = 1),
  previous_reading numeric(12,2) not null check (previous_reading >= 0),
  current_reading numeric(12,2) not null,
  recorded_by uuid references users(id),
  created_at timestamptz not null default now(),
  foreign key (unit_id, org_id) references units(id, org_id),
  check (current_reading >= previous_reading),
  unique (unit_id, utility, period),
  unique (id, org_id)
);

create table utility_bills (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  unit_id uuid not null,
  invoice_id uuid,
  reading_id uuid,
  utility text not null check (utility in ('electricity','gas','water','internet','service','garbage','other')),
  period date not null,
  amount numeric(12,2) not null check (amount >= 0),
  created_at timestamptz not null default now(),
  foreign key (unit_id, org_id) references units(id, org_id),
  foreign key (invoice_id, org_id) references rent_invoices(id, org_id),
  foreign key (reading_id, org_id) references utility_readings(id, org_id)
);

create table payment_transactions (       -- one row per gateway attempt; verified only from the gateway on the server
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id),
  provider text not null check (provider in ('bkash','nagad','sslcommerz','bank','manual')),
  provider_txn_id text not null,
  amount numeric(12,2) not null check (amount > 0),
  status text not null default 'initiated' check (status in ('initiated','pending','verified','failed','refunded')),
  verified_at timestamptz,
  webhook_payload jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, provider_txn_id),
  unique (id, org_id),
  check (status <> 'verified' or verified_at is not null)
);

create table payments (                   -- append-only ledger of money received against invoices
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  invoice_id uuid not null,
  receipt_no text not null,
  amount numeric(12,2) not null check (amount <> 0),   -- a correction is a negative row that reverses an earlier one
  method text not null check (method in ('cash','bkash','nagad','bank','card','other')),
  transaction_id uuid,
  reverses_payment_id uuid references payments(id),
  received_at timestamptz not null default now(),
  recorded_by uuid references users(id),
  note text,
  created_at timestamptz not null default now(),
  foreign key (invoice_id, org_id) references rent_invoices(id, org_id),
  foreign key (transaction_id, org_id) references payment_transactions(id, org_id),
  unique (org_id, receipt_no),
  check (amount > 0 or reverses_payment_id is not null),
  check (method = 'cash' or transaction_id is not null or reverses_payment_id is not null)
);
create unique index one_payment_per_transaction on payments (transaction_id) where transaction_id is not null;
create index on payments (org_id, received_at);
create index on payments (invoice_id);

-- Keep invoice.amount_paid/status in step with the ledger, under a row lock, and refuse overpayment.
create or replace function apply_payment() returns trigger language plpgsql as $$
declare inv rent_invoices; new_paid numeric(12,2); tx payment_transactions;
begin
  select * into inv from rent_invoices where id = new.invoice_id for update;
  if inv.status = 'void' then raise exception 'invoice % is void', inv.invoice_no using errcode = '23514'; end if;
  if new.transaction_id is not null then
    select * into tx from payment_transactions where id = new.transaction_id;
    if tx.status <> 'verified' then raise exception 'payment transaction is not verified' using errcode = '23514'; end if;
    if tx.amount <> new.amount then raise exception 'payment amount differs from the verified transaction' using errcode = '23514'; end if;
  end if;
  new_paid := inv.amount_paid + new.amount;
  if new_paid > inv.total then raise exception 'payment exceeds the balance due on %', inv.invoice_no using errcode = '23514'; end if;
  if new_paid < 0 then raise exception 'correction larger than the amount paid' using errcode = '23514'; end if;
  update rent_invoices set amount_paid = new_paid,
    status = case when new_paid = 0 then 'open' when new_paid < total then 'partially_paid' else 'paid' end
   where id = inv.id;
  return new;
end $$;
create trigger payments_apply before insert on payments for each row execute function apply_payment();
create trigger payments_append_only before update or delete on payments for each row execute function forbid_change();

-- Invoice total always equals the sum of its items.
create or replace function sync_invoice_total() returns trigger language plpgsql as $$
declare inv_id uuid := coalesce(new.invoice_id, old.invoice_id); s numeric(12,2);
begin
  select coalesce(sum(amount), 0) into s from invoice_items where invoice_id = inv_id;
  update rent_invoices set total = greatest(s, 0) where id = inv_id;
  return null;
end $$;
create trigger invoice_items_total after insert or update or delete on invoice_items for each row execute function sync_invoice_total();

-- Gateway transactions: only status/verification fields may change, and only forwards.
create or replace function guard_transaction() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'payment_transactions are append-only' using errcode = '55000'; end if;
  if (new.provider, new.provider_txn_id, new.amount, new.org_id) is distinct from (old.provider, old.provider_txn_id, old.amount, old.org_id) then
    raise exception 'only the status of a payment transaction can change' using errcode = '55000'; end if;
  if old.status in ('failed','refunded') or (old.status = 'verified' and new.status not in ('verified','refunded')) then
    raise exception 'payment transaction status cannot go from % to %', old.status, new.status using errcode = '55000'; end if;
  new.updated_at := now(); return new;
end $$;
create trigger payment_transactions_guard before update or delete on payment_transactions for each row execute function guard_transaction();

-- ---------------------------------------------------------------- expenses
create table expenses (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  property_id uuid not null,
  category text not null check (category in ('maintenance','electricity','water','salary','security','cleaning','repair','other')),
  amount numeric(12,2) not null check (amount > 0),
  spent_on date not null,
  note text,
  created_by uuid references users(id),
  created_at timestamptz not null default now(), deleted_at timestamptz,
  foreign key (property_id, org_id) references properties(id, org_id)
);
create index on expenses (org_id, spent_on);

-- ---------------------------------------------------------------- maintenance, complaints, notices
create table maintenance_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  unit_id uuid not null,
  tenant_id uuid,
  category text not null check (category in ('electrical','plumbing','water','security','cleaning','general')),
  priority text not null default 'medium' check (priority in ('low','medium','high')),
  status text not null default 'submitted' check (status in ('submitted','reviewed','assigned','in_progress','completed','closed')),
  title text not null check (char_length(title) between 1 and 160),
  description text,
  assigned_to uuid references users(id),
  resolution_note text,
  tenant_rating int check (tenant_rating between 1 and 5),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key (unit_id, org_id) references units(id, org_id),
  foreign key (tenant_id, org_id) references tenants(id, org_id),
  check (status in ('submitted','reviewed') or assigned_to is not null),
  unique (id, org_id)
);
create index on maintenance_requests (org_id, status);

create table maintenance_comments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null, request_id uuid not null,
  author_id uuid not null references users(id),
  body text not null check (char_length(body) between 1 and 2000),
  attachment_key text,
  created_at timestamptz not null default now(),
  foreign key (request_id, org_id) references maintenance_requests(id, org_id) on delete cascade
);

create table complaints (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  tenant_id uuid not null,
  subject text not null, body text not null,
  status text not null default 'open' check (status in ('open','in_review','resolved','closed')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key (tenant_id, org_id) references tenants(id, org_id)
);

create table notices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id),
  property_id uuid,
  title text not null, body text not null,
  published_at timestamptz not null default now(),
  created_by uuid references users(id),
  foreign key (property_id, org_id) references properties(id, org_id)
);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references organizations(id),
  user_id uuid not null references users(id),
  channel text not null check (channel in ('in_app','email','sms','whatsapp','push')),
  kind text not null,
  title text not null, body text not null,
  status text not null default 'queued' check (status in ('queued','sent','failed','read')),
  sent_at timestamptz, read_at timestamptz,
  created_at timestamptz not null default now()
);
create index on notifications (user_id, created_at desc);

create table notification_preferences (
  user_id uuid not null references users(id) on delete cascade,
  kind text not null,
  channel text not null check (channel in ('in_app','email','sms','whatsapp','push')),
  enabled boolean not null default true,
  primary key (user_id, kind, channel)
);

-- ---------------------------------------------------------------- SaaS subscriptions
create table subscription_plans (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z0-9_]{2,30}$'),
  name text not null,
  price_monthly numeric(12,2) check (price_monthly >= 0),   -- null = custom (Enterprise)
  price_yearly numeric(12,2) check (price_yearly >= 0),
  limit_properties int, limit_units int, limit_tenants int, limit_staff int,   -- null = unlimited
  features jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table subscriptions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id),
  plan_id uuid not null references subscription_plans(id),
  billing_cycle text not null default 'monthly' check (billing_cycle in ('monthly','yearly')),
  status text not null check (status in ('trialing','active','grace','expired','canceled','suspended')),
  current_period_start date not null,
  current_period_end date not null,
  trial_ends_at date, grace_ends_at date,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (current_period_end > current_period_start),
  unique (id, org_id)
);
create unique index one_live_subscription_per_org on subscriptions (org_id) where status in ('trialing','active','grace','suspended');

create table subscription_payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  subscription_id uuid not null,
  invoice_no text not null unique,
  amount numeric(12,2) not null,
  period_start date not null, period_end date not null,
  status text not null default 'pending' check (status in ('pending','paid','failed','refunded')),
  transaction_id uuid,
  created_at timestamptz not null default now(),
  foreign key (subscription_id, org_id) references subscriptions(id, org_id),
  foreign key (transaction_id, org_id) references payment_transactions(id, org_id),
  check (status <> 'paid' or transaction_id is not null)     -- paid only with a verified gateway/bank transaction
);

create table staff_assignments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  member_id uuid not null,
  property_id uuid not null,
  permissions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (member_id, org_id) references organization_members(id, org_id) on delete cascade,
  foreign key (property_id, org_id) references properties(id, org_id),
  unique (member_id, property_id)
);

create table support_tickets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references organizations(id),
  user_id uuid not null references users(id),
  subject text not null, body text not null,
  priority text not null default 'normal' check (priority in ('low','normal','high')),
  status text not null default 'open' check (status in ('open','pending','resolved','closed')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table audit_logs (
  id bigint generated always as identity primary key,
  org_id uuid references organizations(id),
  actor_user_id uuid references users(id),
  action text not null,
  entity text not null,
  entity_id uuid,
  before_data jsonb, after_data jsonb,
  ip inet, user_agent text,
  created_at timestamptz not null default now()
);
create index on audit_logs (org_id, created_at desc);
create trigger audit_logs_append_only before update or delete on audit_logs for each row execute function forbid_change();

create table system_settings (
  key text primary key,
  value jsonb not null,
  updated_by uuid references users(id),
  updated_at timestamptz not null default now()
);

-- updated_at maintenance
do $$ declare t text; begin
  foreach t in array array['users','organizations','organization_members','properties','buildings','units','tenants','leases','rent_invoices','expenses','maintenance_requests','complaints','subscription_plans','subscriptions','support_tickets'] loop
    execute format('create trigger %I before update on %I for each row execute function touch_updated_at()', t||'_touch', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- row-level security (defence in depth)
-- The API connects as smartrent_app (no BYPASSRLS) and runs every request inside a transaction that
-- starts with: SET LOCAL app.org_id = '<org>'; and, for Super Admin only, SET LOCAL app.is_super_admin = 'on'.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'smartrent_app') then create role smartrent_app nologin; end if;
end $$;
grant usage on schema public to smartrent_app;

do $$ declare t text; begin
  foreach t in array array['properties','buildings','property_files','units','unit_charges','tenants','tenant_family_members','leases','rent_changes','lease_documents',
                           'rent_invoices','invoice_items','utility_readings','utility_bills','payment_transactions','payments','expenses',
                           'maintenance_requests','maintenance_comments','complaints','notices','subscriptions','subscription_payments','staff_assignments','organization_members'] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
    execute format('create policy org_isolation on %I using (org_id = app_org_id() or app_is_super_admin()) with check (org_id = app_org_id() or app_is_super_admin())', t);
    execute format('grant select, insert, update, delete on %I to smartrent_app', t);
  end loop;
end $$;
-- organization-optional tables
alter table notifications enable row level security; alter table notifications force row level security;
create policy org_isolation on notifications using (org_id is null or org_id = app_org_id() or app_is_super_admin()) with check (org_id is null or org_id = app_org_id() or app_is_super_admin());
alter table audit_logs enable row level security; alter table audit_logs force row level security;
create policy org_read on audit_logs for select using (org_id = app_org_id() or app_is_super_admin());
create policy org_write on audit_logs for insert with check (org_id is null or org_id = app_org_id() or app_is_super_admin());
grant select, insert on audit_logs to smartrent_app;
grant select, insert, update on notifications, notification_preferences, support_tickets, user_sessions to smartrent_app;
grant select on subscription_plans, system_settings to smartrent_app;
grant select, update (full_name, locale, last_login_at, two_factor_enabled, two_factor_secret_enc, password_hash, status) on users to smartrent_app;
grant insert on users to smartrent_app;
grant select on organizations to smartrent_app;
grant usage, select on all sequences in schema public to smartrent_app;

-- ---------------------------------------------------------------- initial plans (Super Admin can change them)
insert into subscription_plans (code, name, price_monthly, limit_properties, limit_units, limit_tenants, limit_staff, sort_order, features) values
 ('free','Free',0,1,5,5,0,1,'{"tenant_portal":true}'),
 ('starter','Starter',199,2,20,20,1,2,'{"tenant_portal":true,"utility_billing":true,"notices":true}'),
 ('business','Business',499,5,60,60,3,3,'{"tenant_portal":true,"utility_billing":true,"notices":true,"maintenance":true,"expenses":true,"reports":true}'),
 ('professional','Professional',999,15,200,200,10,4,'{"tenant_portal":true,"utility_billing":true,"notices":true,"maintenance":true,"expenses":true,"reports":true,"managers":true,"reminders":true}'),
 ('enterprise','Enterprise',null,null,null,null,null,5,'{"all":true,"api":true,"priority_support":true,"branding":true}');
insert into system_settings (key, value) values ('trial_days','14'), ('grace_days','7');

commit;
