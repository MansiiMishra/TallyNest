-- Run with: supabase test db
-- Exercises the first security boundary before financial RPCs are introduced.
begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(13);

insert into auth.users (id, email)
values
  ('10000000-0000-4000-8000-000000000001', 'owner-a@example.test'),
  ('20000000-0000-4000-8000-000000000002', 'owner-b@example.test');

insert into public.businesses (id, name)
values
  ('a0000000-0000-4000-8000-000000000001', 'Business A'),
  ('b0000000-0000-4000-8000-000000000002', 'Business B');

insert into public.business_memberships (business_id, user_id, role, status)
values
  ('a0000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'owner', 'active'),
  ('b0000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000002', 'owner', 'active');

insert into public.customers (id, business_id, full_name)
values
  ('a1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'Customer A'),
  ('b2000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000002', 'Customer B');

insert into public.orders
  (id, business_id, customer_id, service_date, amount_minor, status, delivered_at)
values
  ('a3000000-0000-4000-8000-000000000003',
   'a0000000-0000-4000-8000-000000000001',
   'a1000000-0000-4000-8000-000000000001', current_date, 5000, 'delivered', now());

insert into public.reminder_events
  (id, business_id, customer_id, reminder_date, channel, action, undo_of_id)
values
  ('a4000000-0000-4000-8000-000000000004',
   'a0000000-0000-4000-8000-000000000001',
   'a1000000-0000-4000-8000-000000000001', current_date, 'clipboard', 'prepared', null),
  ('a5000000-0000-4000-8000-000000000005',
   'a0000000-0000-4000-8000-000000000001',
   'a1000000-0000-4000-8000-000000000001', current_date, 'clipboard', 'undone',
   'a4000000-0000-4000-8000-000000000004'),
  ('a6000000-0000-4000-8000-000000000006',
   'a0000000-0000-4000-8000-000000000001',
   'a1000000-0000-4000-8000-000000000001', current_date, 'clipboard', 'prepared', null);

-- The same client key is valid once per tenant, but never shared across rows
-- inside the same tenant. Hash checking itself is enforced by the RPC layer.
insert into public.idempotency_requests (business_id, idempotency_key, request_hash, operation_name)
values
  ('a0000000-0000-4000-8000-000000000001', 'same-key-for-both-tenants', decode(repeat('a', 64), 'hex'), 'test.command'),
  ('b0000000-0000-4000-8000-000000000002', 'same-key-for-both-tenants', decode(repeat('b', 64), 'hex'), 'test.command');

select extensions.is(
  (select count(*)::integer from public.idempotency_requests
    where idempotency_key = 'same-key-for-both-tenants'),
  2,
  'The same opaque idempotency key is isolated per business'
);
select extensions.is(
  (select count(*)::integer from public.reminder_events
    where business_id = 'a0000000-0000-4000-8000-000000000001'),
  3,
  'An append-only undo permits a later same-day reminder attempt'
);
select extensions.throws_ok(
  $$update public.businesses set currency_code = 'USD'
    where id = 'a0000000-0000-4000-8000-000000000001'$$,
  'P0001',
  null,
  'Business currency is locked after transactional activity exists'
);

set local role authenticated;

select set_config(
  'request.jwt.claims',
  '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);

select extensions.is(
  (select count(*)::integer from public.customers),
  1,
  'Owner A sees only the customer in Business A'
);
select extensions.is(
  (select count(*)::integer from public.business_memberships),
  1,
  'Owner A sees only their own membership row'
);
select extensions.is(
  (select count(*)::integer from public.idempotency_requests),
  1,
  'Owner A sees only their own idempotency record'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"20000000-0000-4000-8000-000000000002","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '20000000-0000-4000-8000-000000000002', true);

select extensions.is(
  (select count(*)::integer from public.customers),
  1,
  'Owner B sees only the customer in Business B'
);
select extensions.is(
  (select count(*)::integer from public.customers
    where id = 'a1000000-0000-4000-8000-000000000001'),
  0,
  'Owner B cannot read a Business A customer by known UUID'
);
select extensions.is(
  (select count(*)::integer from public.idempotency_requests
    where business_id = 'a0000000-0000-4000-8000-000000000001'),
  0,
  'Owner B cannot read Business A idempotency data by business ID'
);

select extensions.throws_ok(
  $$insert into public.ledger_entries
      (business_id, customer_id, entry_kind, amount_minor, occurred_on, payment_method)
    values
      ('b0000000-0000-4000-8000-000000000002',
       'b2000000-0000-4000-8000-000000000002',
       'received', 10000, current_date, 'cash')$$,
  '42501',
  null,
  'Owner B cannot write the ledger directly'
);

select extensions.throws_ok(
  $$insert into public.customer_notes (business_id, customer_id, note)
    values
      ('a0000000-0000-4000-8000-000000000001',
       'a1000000-0000-4000-8000-000000000001', 'cross-tenant note')$$,
  '42501',
  null,
  'Owner B cannot write a note into Business A'
);

select extensions.throws_ok(
  $$insert into public.customer_notes (business_id, customer_id, note)
    values
      ('b0000000-0000-4000-8000-000000000002',
       'a1000000-0000-4000-8000-000000000001', 'mismatched customer')$$,
  '23503',
  null,
  'Composite foreign key rejects a Business B note for a Business A customer'
);

select extensions.throws_ok(
  $$insert into public.orders
      (business_id, customer_id, service_date, amount_minor)
    values
      ('b0000000-0000-4000-8000-000000000002',
       'b2000000-0000-4000-8000-000000000002', current_date, 10000)$$,
  '42501',
  null,
  'Bookings and orders are written only through reviewed RPCs'
);

select * from extensions.finish();
rollback;
