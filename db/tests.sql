-- SmartRent BD schema tests. Run on a throwaway database only, via db/run-tests.sh.
-- Each check prints "ok - ..." or "FAIL - ...".
\set QUIET on
\pset tuples_only on
\pset format unaligned

create function pg_temp.expect_error(sql text, label text) returns text language plpgsql as $$
begin
  begin execute sql; exception when others then return 'ok - ' || label || ' [' || sqlstate || ']'; end;
  return 'FAIL - ' || label || ' was allowed';
end $$;
create function pg_temp.expect(cond boolean, label text) returns text language sql as
$$ select case when cond then 'ok - ' || label else 'FAIL - ' || label end $$;

-- ---------------------------------------------------------------- fixtures: two organizations
-- IDs: a* = organization A, b* = organization B
set app.is_super_admin = 'on';
insert into users (id, email, full_name) values
 ('a0000000-0000-0000-0000-000000000001','landlord.a@example.com','Landlord A'),
 ('b0000000-0000-0000-0000-000000000001','landlord.b@example.com','Landlord B');
insert into organizations (id, name, slug) values
 ('a1000000-0000-0000-0000-000000000001','Org A','org-a'),
 ('b1000000-0000-0000-0000-000000000001','Org B','org-b');
insert into properties (id, org_id, name) values
 ('a2000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','A Villa'),
 ('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','B Tower');
insert into buildings (id, org_id, property_id, name) values
 ('a3000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','Main'),
 ('b3000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b2000000-0000-0000-0000-000000000001','Main');
insert into units (id, org_id, building_id, unit_no, rent_amount) values
 ('a4000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a3000000-0000-0000-0000-000000000001','1A',15000),
 ('b4000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b3000000-0000-0000-0000-000000000001','1A',20000);
insert into tenants (id, org_id, full_name, phone) values
 ('a5000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','Tenant A','01711111111'),
 ('b5000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','Tenant B','01811111111');
insert into leases (id, org_id, unit_id, tenant_id, start_date, end_date, rent_amount, status) values
 ('a6000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','2026-01-01','2027-01-01',15000,'active'),
 ('b6000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b4000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-000000000001','2026-01-01','2027-01-01',20000,'active');
insert into rent_invoices (id, org_id, lease_id, invoice_no, period, issue_date, due_date) values
 ('a7000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','INV-A-0001','2026-11-01','2026-11-01','2026-11-10'),
 ('b7000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001','INV-B-0001','2026-11-01','2026-11-01','2026-11-10');
insert into invoice_items (org_id, invoice_id, kind, quantity, unit_price, amount) values
 ('a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','rent',1,15000,15000),
 ('a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','electricity',120,9.5,1140),
 ('b1000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001','rent',1,20000,20000);

-- ---------------------------------------------------------------- invoice maths
select pg_temp.expect((select total from rent_invoices where id='a7000000-0000-0000-0000-000000000001') = 16140, 'invoice total = sum of items (15000 + 120 kWh x 9.5)');
select pg_temp.expect_error($$insert into invoice_items (org_id, invoice_id, kind, quantity, unit_price, amount) values ('a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','water',1,500,600)$$, 'item amount must equal quantity x price');
select pg_temp.expect_error($$insert into rent_invoices (org_id, lease_id, invoice_no, period, due_date) values ('a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','INV-A-0002','2026-11-01','2026-11-10')$$, 'second invoice for the same lease and month');
select pg_temp.expect_error($$insert into rent_invoices (org_id, lease_id, invoice_no, period, due_date) values ('a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','INV-A-0001','2026-12-01','2026-12-10')$$, 'duplicate invoice number in an organization');
select pg_temp.expect_error($$insert into rent_invoices (org_id, lease_id, invoice_no, period, due_date) values ('a1000000-0000-0000-0000-000000000001','a6000000-0000-0000-0000-000000000001','INV-A-0009','2026-12-15','2026-12-20')$$, 'invoice period must be the first of a month');

-- ---------------------------------------------------------------- payments
insert into payments (org_id, invoice_id, receipt_no, amount, method) values ('a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','R-A-0001',6000,'cash');
select pg_temp.expect((select status||':'||amount_paid from rent_invoices where id='a7000000-0000-0000-0000-000000000001') = 'partially_paid:6000.00', 'partial payment marks invoice partially paid');
select pg_temp.expect_error($$insert into payments (org_id, invoice_id, receipt_no, amount, method) values ('a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','R-A-0002',99999,'cash')$$, 'overpayment is refused');
select pg_temp.expect_error($$insert into payments (org_id, invoice_id, receipt_no, amount, method) values ('a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','R-A-0003',100,'bkash')$$, 'bKash payment without a verified transaction');
insert into payment_transactions (id, org_id, provider, provider_txn_id, amount, status) values ('a8000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','bkash','TRX9A8B7C',10140,'pending');
select pg_temp.expect_error($$insert into payments (org_id, invoice_id, receipt_no, amount, method, transaction_id) values ('a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','R-A-0004',10140,'bkash','a8000000-0000-0000-0000-000000000001')$$, 'unverified gateway transaction cannot pay an invoice');
select pg_temp.expect_error($$update payment_transactions set status='verified' where id='a8000000-0000-0000-0000-000000000001'$$, 'verified needs verified_at');
update payment_transactions set status='verified', verified_at=now() where id='a8000000-0000-0000-0000-000000000001';
insert into payments (org_id, invoice_id, receipt_no, amount, method, transaction_id) values ('a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','R-A-0004',10140,'bkash','a8000000-0000-0000-0000-000000000001');
select pg_temp.expect((select status||':'||amount_paid from rent_invoices where id='a7000000-0000-0000-0000-000000000001') = 'paid:16140.00', 'verified bKash payment completes the invoice');
select pg_temp.expect_error($$insert into payment_transactions (org_id, provider, provider_txn_id, amount) values ('a1000000-0000-0000-0000-000000000001','bkash','TRX9A8B7C',50)$$, 'duplicate gateway transaction ID');
select pg_temp.expect_error($$update payment_transactions set amount=1 where id='a8000000-0000-0000-0000-000000000001'$$, 'transaction amount cannot change');
select pg_temp.expect_error($$update payments set amount=1 where receipt_no='R-A-0001'$$, 'payments cannot be edited');
select pg_temp.expect_error($$delete from payments where receipt_no='R-A-0001'$$, 'payments cannot be deleted');
insert into payments (org_id, invoice_id, receipt_no, amount, method, reverses_payment_id) select org_id, invoice_id, 'R-A-0005', -6000, 'cash', id from payments where receipt_no='R-A-0001';
select pg_temp.expect((select status||':'||amount_paid from rent_invoices where id='a7000000-0000-0000-0000-000000000001') = 'partially_paid:10140.00', 'correcting entry reverses a payment');
select pg_temp.expect_error($$insert into payments (org_id, invoice_id, receipt_no, amount, method) values ('a1000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000001','R-A-0006',-5,'cash')$$, 'negative payment without a reversed payment');
select pg_temp.expect_error($$delete from invoice_items where kind='rent' and invoice_id='a7000000-0000-0000-0000-000000000001'$$, 'invoice total cannot drop below the amount paid');

-- ---------------------------------------------------------------- leases, units, readings
select pg_temp.expect_error($$insert into leases (org_id, unit_id, tenant_id, start_date, rent_amount, status) values ('a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','2026-06-01',15000,'active')$$, 'second active lease on one unit');
select pg_temp.expect_error($$insert into leases (org_id, unit_id, tenant_id, start_date, end_date, rent_amount) values ('a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001','a5000000-0000-0000-0000-000000000001','2026-06-01','2026-05-01',15000)$$, 'lease ending before it starts');
select pg_temp.expect_error($$insert into units (org_id, building_id, unit_no, rent_amount) values ('a1000000-0000-0000-0000-000000000001','a3000000-0000-0000-0000-000000000001','1a',1)$$, 'duplicate unit number in a building (case-insensitive)');
select pg_temp.expect_error($$insert into utility_readings (org_id, unit_id, utility, period, previous_reading, current_reading) values ('a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001','electricity','2026-11-01',2000,1990)$$, 'meter reading cannot go backwards');
select pg_temp.expect_error($$insert into tenants (org_id, full_name, phone) values ('a1000000-0000-0000-0000-000000000001','X','12345')$$, 'invalid Bangladesh mobile number');

-- ---------------------------------------------------------------- cross-organization links are impossible
select pg_temp.expect_error($$insert into units (org_id, building_id, unit_no, rent_amount) values ('a1000000-0000-0000-0000-000000000001','b3000000-0000-0000-0000-000000000001','9Z',1)$$, 'unit of org A in a building of org B');
select pg_temp.expect_error($$insert into leases (org_id, unit_id, tenant_id, start_date, rent_amount) values ('a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-000000000001','2027-02-01',1)$$, 'lease linking org A unit to org B tenant');
select pg_temp.expect_error($$insert into payments (org_id, invoice_id, receipt_no, amount, method) values ('a1000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001','R-X',1,'cash')$$, 'org A paying an org B invoice');

-- ---------------------------------------------------------------- subscriptions
insert into subscriptions (org_id, plan_id, status, current_period_start, current_period_end) select 'a1000000-0000-0000-0000-000000000001', id, 'active', '2026-11-01', '2026-12-01' from subscription_plans where code='business';
select pg_temp.expect_error($$insert into subscriptions (org_id, plan_id, status, current_period_start, current_period_end) select 'a1000000-0000-0000-0000-000000000001', id, 'trialing', '2026-11-01', '2026-11-15' from subscription_plans where code='free'$$, 'two live subscriptions for one organization');
select pg_temp.expect_error($$insert into subscription_payments (org_id, subscription_id, invoice_no, amount, period_start, period_end, status) select org_id, id, 'SUB-1', 499, '2026-11-01','2026-12-01','paid' from subscriptions where org_id='a1000000-0000-0000-0000-000000000001'$$, 'subscription marked paid without a transaction');
select pg_temp.expect((select string_agg(code||'='||coalesce(price_monthly::text,'custom'), ',' order by sort_order) from subscription_plans) = 'free=0.00,starter=199.00,business=499.00,professional=999.00,enterprise=custom', 'initial plan prices from the spec');

-- ---------------------------------------------------------------- audit log is append-only
insert into audit_logs (org_id, action, entity) values ('a1000000-0000-0000-0000-000000000001','payment.recorded','payments');
select pg_temp.expect_error($$update audit_logs set action='x'$$, 'audit log cannot be edited');
select pg_temp.expect_error($$delete from audit_logs$$, 'audit log cannot be deleted');

-- ---------------------------------------------------------------- row-level security as the application role
reset app.is_super_admin;
set role smartrent_app;
set app.org_id = 'a1000000-0000-0000-0000-000000000001';
select pg_temp.expect((select count(*) from tenants) = 1 and (select min(full_name) from tenants) = 'Tenant A', 'org A sees only its own tenants');
select pg_temp.expect((select count(*) from rent_invoices) = 1 and (select count(*) from payments where org_id <> 'a1000000-0000-0000-0000-000000000001') = 0, 'org A sees only its own invoices and payments');
select pg_temp.expect((select count(*) from audit_logs) = 1, 'org A sees only its own audit entries');
select pg_temp.expect_error($$insert into tenants (org_id, full_name, phone) values ('b1000000-0000-0000-0000-000000000001','Sneaky','01711111112')$$, 'org A cannot write rows for org B');
select pg_temp.expect_error($$update payments set note='x'$$, 'application role cannot edit payments either');
update tenants set full_name = 'Hacked' where org_id = 'b1000000-0000-0000-0000-000000000001';
reset app.org_id; set app.org_id = 'b1000000-0000-0000-0000-000000000001';
select pg_temp.expect((select full_name from tenants) = 'Tenant B', 'org A could not change org B data');
reset app.org_id;
select pg_temp.expect((select count(*) from tenants) = 0, 'no organization set means no rows');
reset role;
