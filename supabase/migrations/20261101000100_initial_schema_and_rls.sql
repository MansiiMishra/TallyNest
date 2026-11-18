-- Initial database foundation for the Order and Payment Tracker.
-- Financial writes are deliberately unavailable to authenticated clients until
-- reviewed transactional RPCs are added in later migrations.

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  country_code text not null default 'IN' check (country_code ~ '^[A-Z]{2}$'),
  currency_code text not null default 'INR' check (currency_code ~ '^[A-Z]{3}$'),
  time_zone text not null default 'Asia/Kolkata',
  terminology jsonb not null default '{}'::jsonb check (jsonb_typeof(terminology) = 'object'),
  reminder_weekday smallint check (reminder_weekday between 0 and 6),
  reminder_day smallint check (reminder_day between 1 and 31),
  reminder_time time,
  reminder_template text check (length(reminder_template) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id)
);

create table public.business_memberships (
  business_id uuid not null references public.businesses(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  role text not null default 'owner' check (role = 'owner'),
  status text not null default 'invited' check (status in ('invited', 'active', 'revoked')),
  invited_at timestamptz,
  activated_at timestamptz,
  revoked_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (business_id, user_id),
  unique (business_id, user_id)
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  full_name text not null check (length(trim(full_name)) between 1 and 160),
  phone_e164 text,
  flat_number text,
  building text,
  address_text text,
  status text not null default 'active' check (status in ('active', 'archived')),
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (business_id, id)
);

create table public.customer_notes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  customer_id uuid not null,
  note text not null check (length(trim(note)) between 1 and 4000),
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id, customer_id)
    references public.customers(business_id, id) on delete restrict,
  unique (business_id, id)
);

create table public.slots (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null check (length(trim(name)) between 1 and 80),
  starts_at time,
  ends_at time,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, name)
);

create table public.closure_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  slot_id uuid,
  rule_type text not null check (rule_type in ('date_range', 'weekday')),
  starts_on date,
  ends_on date,
  weekday smallint check (weekday between 0 and 6),
  action text not null check (action in ('closed', 'open_exception')),
  reason text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, id),
  foreign key (business_id, slot_id)
    references public.slots(business_id, id) on delete restrict,
  check (
    (rule_type = 'date_range' and starts_on is not null and ends_on is not null
      and ends_on >= starts_on and weekday is null)
    or
    (rule_type = 'weekday' and weekday is not null and starts_on is null and ends_on is null)
  )
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  customer_id uuid not null,
  slot_id uuid,
  starts_on date not null,
  week_count smallint not null check (week_count between 1 and 52),
  weekdays smallint[] not null check (
    cardinality(weekdays) between 1 and 7
    and weekdays <@ array[0,1,2,3,4,5,6]::smallint[]
  ),
  description text,
  amount_per_order_minor bigint not null check (amount_per_order_minor > 0),
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'cancelled')),
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1 check (row_version > 0),
  unique (business_id, id),
  foreign key (business_id, customer_id)
    references public.customers(business_id, id) on delete restrict,
  foreign key (business_id, slot_id)
    references public.slots(business_id, id) on delete restrict
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  customer_id uuid not null,
  booking_id uuid,
  slot_id uuid,
  service_date date not null,
  description text,
  quantity numeric(10, 3) not null default 1 check (quantity > 0),
  amount_minor bigint not null check (amount_minor > 0),
  order_kind text not null default 'regular' check (order_kind in ('regular', 'bulk')),
  status text not null default 'scheduled' check (status in ('scheduled', 'delivered', 'cancelled')),
  delivered_at timestamptz,
  cancelled_at timestamptz,
  note text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1 check (row_version > 0),
  unique (business_id, id),
  foreign key (business_id, customer_id)
    references public.customers(business_id, id) on delete restrict,
  foreign key (business_id, booking_id)
    references public.bookings(business_id, id) on delete restrict,
  foreign key (business_id, slot_id)
    references public.slots(business_id, id) on delete restrict,
  check ((status = 'delivered') = (delivered_at is not null)),
  check ((status = 'cancelled') = (cancelled_at is not null))
);

create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  customer_id uuid not null,
  tagged_order_id uuid,
  entry_kind text not null check (entry_kind in ('received', 'returned')),
  amount_minor bigint not null check (amount_minor > 0),
  occurred_on date not null,
  payment_method text check (payment_method in ('cash', 'upi', 'bank_transfer', 'other')),
  reference_note text,
  reversal_of_id uuid,
  idempotency_request_id uuid,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (business_id, customer_id, id),
  foreign key (business_id, customer_id)
    references public.customers(business_id, id) on delete restrict,
  foreign key (business_id, tagged_order_id)
    references public.orders(business_id, id) on delete restrict,
  foreign key (business_id, customer_id, reversal_of_id)
    references public.ledger_entries(business_id, customer_id, id) on delete restrict,
  check (reversal_of_id is null or reversal_of_id <> id)
);

create unique index ledger_entries_one_reversal_per_entry
  on public.ledger_entries (business_id, customer_id, reversal_of_id)
  where reversal_of_id is not null;

create table public.idempotency_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  idempotency_key text not null check (length(idempotency_key) between 16 and 200),
  request_hash bytea not null check (octet_length(request_hash) = 32),
  operation_name text not null,
  result_payload jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (business_id, idempotency_key),
  unique (business_id, id)
);

create table public.order_adjustments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  customer_id uuid not null,
  order_id uuid not null,
  adjustment_kind text not null check (adjustment_kind in ('charge_increase', 'charge_reduction')),
  amount_minor bigint not null check (amount_minor > 0),
  reason text not null check (length(trim(reason)) between 1 and 1000),
  idempotency_request_id uuid not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (business_id, customer_id)
    references public.customers(business_id, id) on delete restrict,
  foreign key (business_id, order_id)
    references public.orders(business_id, id) on delete restrict,
  foreign key (business_id, idempotency_request_id)
    references public.idempotency_requests(business_id, id) on delete restrict
);

alter table public.ledger_entries
  add constraint ledger_entries_idempotency_request_fk
  foreign key (business_id, idempotency_request_id)
  references public.idempotency_requests(business_id, id) on delete restrict;

create table public.reminder_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  customer_id uuid not null,
  reminder_date date not null,
  channel text not null check (channel in ('whatsapp', 'clipboard')),
  action text not null default 'prepared' check (action in ('prepared', 'opened', 'copied', 'cancelled', 'undone')),
  undo_of_id uuid,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (business_id, customer_id)
    references public.customers(business_id, id) on delete restrict,
  unique (business_id, customer_id, id),
  foreign key (business_id, customer_id, undo_of_id)
    references public.reminder_events(business_id, customer_id, id) on delete restrict,
  check (undo_of_id is null or (action = 'undone' and undo_of_id <> id)),
  check ((action = 'undone') = (undo_of_id is not null))
);

create unique index reminder_events_one_undo_per_event
  on public.reminder_events (business_id, customer_id, undo_of_id)
  where undo_of_id is not null;

create or replace function private.validate_reminder_undo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.action = 'undone' and not exists (
    select 1 from public.reminder_events prior
    where prior.business_id = new.business_id
      and prior.customer_id = new.customer_id
      and prior.id = new.undo_of_id
      and prior.reminder_date = new.reminder_date
      and prior.channel = new.channel
      and prior.action <> 'undone'
  ) then
    raise exception 'undo must reference a matching reminder attempt';
  end if;
  return new;
end;
$$;
create trigger reminder_events_validate_undo
  before insert on public.reminder_events
  for each row execute function private.validate_reminder_undo();

create table public.app_runtime_settings (
  singleton_id smallint primary key default 1 check (singleton_id = 1),
  minimum_client_version text not null default '1.0.0',
  updated_at timestamptz not null default now()
);
insert into public.app_runtime_settings (singleton_id, minimum_client_version)
values (1, '1.0.0');

create table public.order_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  order_id uuid not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  event_type text not null,
  event_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (business_id, order_id)
    references public.orders(business_id, id) on delete restrict
);

create table public.business_audit_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  entity_type text not null,
  entity_id uuid not null,
  action text not null check (action in ('insert', 'update', 'delete')),
  actor_user_id uuid references auth.users(id) on delete set null,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

-- Tenant membership check used by policies. The function is intentionally
-- placed in a non-API schema and its search_path is fixed.
create or replace function private.has_active_membership(target_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.business_memberships as membership
    where membership.business_id = target_business_id
      and membership.user_id = (select auth.uid())
      and membership.status = 'active'
  );
$$;

revoke all on function private.has_active_membership(uuid) from public, anon;
grant execute on function private.has_active_membership(uuid) to authenticated;

-- Actor/timestamp values cannot be supplied or overwritten by the browser.
create or replace function private.set_actor_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := (select auth.uid());
    new.created_at := coalesce(new.created_at, now());
  end if;
  new.updated_by := (select auth.uid());
  new.updated_at := now();
  return new;
end;
$$;

create trigger customers_set_actor before insert or update on public.customers
  for each row execute function private.set_actor_columns();
create trigger customer_notes_set_actor before insert or update on public.customer_notes
  for each row execute function private.set_actor_columns();
create trigger slots_set_actor before insert or update on public.slots
  for each row execute function private.set_actor_columns();
create trigger closure_rules_set_actor before insert or update on public.closure_rules
  for each row execute function private.set_actor_columns();

-- Immutable ledger backstop. Corrections are new compensating rows, never edits.
create or replace function private.reject_ledger_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'ledger entries are append-only; create a reversal entry'
    using errcode = '55000';
end;
$$;

create or replace function private.reject_financial_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'financial records are append-only'
    using errcode = '55000';
end;
$$;

create trigger ledger_entries_append_only
  before update or delete on public.ledger_entries
  for each row execute function private.reject_ledger_mutation();
create trigger order_adjustments_append_only
  before update or delete on public.order_adjustments
  for each row execute function private.reject_financial_mutation();
create trigger order_events_append_only
  before update or delete on public.order_events
  for each row execute function private.reject_financial_mutation();
create trigger business_audit_events_append_only
  before update or delete on public.business_audit_events
  for each row execute function private.reject_financial_mutation();
create trigger reminder_events_append_only
  before update or delete on public.reminder_events
  for each row execute function private.reject_financial_mutation();

-- Country, currency, and timezone are immutable after business activity exists.
create or replace function private.guard_business_financial_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (new.country_code, new.currency_code, new.time_zone)
       is distinct from (old.country_code, old.currency_code, old.time_zone)
     and (
       exists (select 1 from public.bookings b where b.business_id = old.id)
       or exists (select 1 from public.orders o where o.business_id = old.id)
       or exists (select 1 from public.ledger_entries l where l.business_id = old.id)
     ) then
    raise exception 'country, currency, and timezone are locked after business activity';
  end if;
  return new;
end;
$$;
create trigger businesses_guard_financial_settings
  before update on public.businesses
  for each row execute function private.guard_business_financial_settings();

-- Audit membership, closure, and business-setting changes. Access to the audit
-- table is read-only for clients; only this fixed-path trigger can append rows.
create or replace function private.capture_business_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  prior_data jsonb;
  next_data jsonb;
  target_business_id uuid;
  target_entity_id uuid;
begin
  if tg_op <> 'INSERT' then prior_data := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then next_data := to_jsonb(new); end if;
  if tg_op = 'DELETE' then
    target_business_id := old.business_id;
    target_entity_id := coalesce((to_jsonb(old)->>'id')::uuid, old.user_id);
  else
    target_business_id := new.business_id;
    target_entity_id := coalesce((to_jsonb(new)->>'id')::uuid, new.user_id);
  end if;
  insert into public.business_audit_events (
    business_id, entity_type, entity_id, action, actor_user_id, before_data, after_data
  ) values (
    target_business_id,
    case tg_table_name
      when 'businesses' then 'business'
      when 'business_memberships' then 'membership'
      else 'closure_rule'
    end,
    target_entity_id,
    lower(tg_op),
    (select auth.uid()),
    prior_data,
    next_data
  );
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger businesses_audit after insert or update or delete on public.businesses
  for each row execute function private.capture_business_audit();
create trigger business_memberships_audit after insert or update or delete on public.business_memberships
  for each row execute function private.capture_business_audit();
create trigger closure_rules_audit after insert or update or delete on public.closure_rules
  for each row execute function private.capture_business_audit();

-- Index tenant filters, joins, date views, and policy joins.
create index business_memberships_user_status_idx
  on public.business_memberships (user_id, status, business_id);
create index customers_business_status_name_idx
  on public.customers (business_id, status, full_name);
create index customer_notes_business_customer_created_idx
  on public.customer_notes (business_id, customer_id, created_at desc);
create index slots_business_active_order_idx
  on public.slots (business_id, is_active, sort_order);
create index closure_rules_business_dates_idx
  on public.closure_rules (business_id, starts_on, ends_on, slot_id);
create index bookings_business_customer_status_start_idx
  on public.bookings (business_id, customer_id, status, starts_on);
create index orders_business_customer_status_date_idx
  on public.orders (business_id, customer_id, status, service_date);
create index orders_business_status_date_idx
  on public.orders (business_id, status, service_date);
create index ledger_entries_business_customer_date_idx
  on public.ledger_entries (business_id, customer_id, occurred_on, created_at);
create index order_adjustments_business_customer_idx
  on public.order_adjustments (business_id, customer_id, created_at);
create index order_adjustments_business_order_idx
  on public.order_adjustments (business_id, order_id, created_at);
create index reminders_business_customer_date_idx
  on public.reminder_events (business_id, customer_id, reminder_date, channel);
create index order_events_business_order_created_idx
  on public.order_events (business_id, order_id, created_at);
create index business_audit_events_business_created_idx
  on public.business_audit_events (business_id, created_at desc);

-- Only customer, note, slot, and reminder records allow scoped direct client
-- writes. Closure changes and all booking/order/financial writes are RPC-only.
revoke all on all tables in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;
revoke insert, update, delete on public.app_runtime_settings from authenticated;
grant insert (business_id, full_name, phone_e164, flat_number, building, address_text)
  on public.customers to authenticated;
grant update (full_name, phone_e164, flat_number, building, address_text, status, archived_at)
  on public.customers to authenticated;
grant delete on public.customers to authenticated;
grant insert (business_id, customer_id, note) on public.customer_notes to authenticated;
grant update (note) on public.customer_notes to authenticated;
grant delete on public.customer_notes to authenticated;
grant insert (business_id, name, starts_at, ends_at, sort_order, is_active)
  on public.slots to authenticated;
grant update (name, starts_at, ends_at, sort_order, is_active)
  on public.slots to authenticated;
grant delete on public.slots to authenticated;
-- Closure-rule changes are RPC-only so conflicting scheduled orders can be
-- surfaced and explicitly cancelled or rescheduled atomically.
-- Reminder events are written through an RPC that serializes same-day attempts.

alter table public.businesses enable row level security;
alter table public.business_memberships enable row level security;
alter table public.customers enable row level security;
alter table public.customer_notes enable row level security;
alter table public.slots enable row level security;
alter table public.closure_rules enable row level security;
alter table public.bookings enable row level security;
alter table public.orders enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.order_adjustments enable row level security;
alter table public.idempotency_requests enable row level security;
alter table public.reminder_events enable row level security;
alter table public.order_events enable row level security;
alter table public.business_audit_events enable row level security;
alter table public.app_runtime_settings enable row level security;

create policy businesses_member_read on public.businesses
  for select to authenticated
  using ((select private.has_active_membership(id)));

create policy memberships_read_self on public.business_memberships
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy customers_member_read on public.customers
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy customers_member_insert on public.customers
  for insert to authenticated
  with check ((select private.has_active_membership(business_id)));
create policy customers_member_update on public.customers
  for update to authenticated
  using ((select private.has_active_membership(business_id)))
  with check ((select private.has_active_membership(business_id)));
create policy customers_member_delete on public.customers
  for delete to authenticated
  using ((select private.has_active_membership(business_id)));

create policy customer_notes_member_read on public.customer_notes
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy customer_notes_member_insert on public.customer_notes
  for insert to authenticated
  with check ((select private.has_active_membership(business_id)));
create policy customer_notes_member_update on public.customer_notes
  for update to authenticated
  using ((select private.has_active_membership(business_id)))
  with check ((select private.has_active_membership(business_id)));
create policy customer_notes_member_delete on public.customer_notes
  for delete to authenticated
  using ((select private.has_active_membership(business_id)));

create policy slots_member_read on public.slots
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy slots_member_insert on public.slots
  for insert to authenticated
  with check ((select private.has_active_membership(business_id)));
create policy slots_member_update on public.slots
  for update to authenticated
  using ((select private.has_active_membership(business_id)))
  with check ((select private.has_active_membership(business_id)));
create policy slots_member_delete on public.slots
  for delete to authenticated
  using ((select private.has_active_membership(business_id)));

create policy closure_rules_member_read on public.closure_rules
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy closure_rules_member_insert on public.closure_rules
  for insert to authenticated
  with check ((select private.has_active_membership(business_id)));
create policy closure_rules_member_update on public.closure_rules
  for update to authenticated
  using ((select private.has_active_membership(business_id)))
  with check ((select private.has_active_membership(business_id)));
create policy closure_rules_member_delete on public.closure_rules
  for delete to authenticated
  using ((select private.has_active_membership(business_id)));

create policy bookings_member_read on public.bookings
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy orders_member_read on public.orders
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy ledger_entries_member_read on public.ledger_entries
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy order_adjustments_member_read on public.order_adjustments
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy idempotency_member_read on public.idempotency_requests
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy reminders_member_read on public.reminder_events
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy reminders_member_insert on public.reminder_events
  for insert to authenticated
  with check ((select private.has_active_membership(business_id)));
create policy order_events_member_read on public.order_events
  for select to authenticated
  using ((select private.has_active_membership(business_id)));
create policy business_audit_events_member_read on public.business_audit_events
  for select to authenticated
  using ((select private.has_active_membership(business_id)));

create policy runtime_settings_authenticated_read on public.app_runtime_settings
  for select to authenticated using (true);

comment on table public.ledger_entries is
  'Append-only financial ledger. Authenticated clients read only; reviewed RPCs append entries.';
comment on table public.idempotency_requests is
  'RPC-owned idempotency records. Unique key per business and SHA-256 request hash.';
comment on column public.businesses.time_zone is
  'IANA business timezone used for Today, reminder dates, and local date interpretation.';
comment on column public.businesses.terminology is
  'Small business-specific display labels; not used to alter database semantics.';
comment on table public.app_runtime_settings is
  'Operator-managed compatibility floor for versioned authenticated RPC calls.';
comment on table public.reminder_events is
  'Append-only reminder attempts and explicit undo events; RPC enforces one active attempt per local date/channel.';

-- No private trigger function or future public function is callable by API roles
-- merely because PostgreSQL defaults function EXECUTE to PUBLIC.
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.has_active_membership(uuid) to authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from public;
