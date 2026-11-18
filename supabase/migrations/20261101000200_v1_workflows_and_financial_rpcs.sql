-- V1 write boundary and business workflows. Financial state changes are
-- idempotent, tenant checked, transactional, and callable only by signed-in owners.

create extension if not exists pgcrypto with schema extensions;

alter table public.closure_rules
  drop constraint if exists closure_rules_rule_type_check,
  drop constraint if exists closure_rules_check;
alter table public.closure_rules
  add column if not exists month_day smallint,
  add column if not exists week_of_month smallint;
alter table public.closure_rules
  add constraint closure_rules_rule_type_check
    check (rule_type in ('date_range', 'daily', 'weekday', 'monthly_date', 'monthly_weekday', 'exception')),
  add constraint closure_rules_pattern_check check (
    (rule_type in ('date_range', 'daily')
      and starts_on is not null and ends_on is not null and ends_on >= starts_on
      and weekday is null and month_day is null and week_of_month is null)
    or (rule_type = 'weekday'
      and weekday is not null and weekday between 0 and 6
      and (ends_on is null or (starts_on is not null and ends_on >= starts_on))
      and month_day is null and week_of_month is null)
    or (rule_type = 'monthly_date'
      and month_day is not null and month_day between 1 and 31
      and (ends_on is null or (starts_on is not null and ends_on >= starts_on))
      and weekday is null and week_of_month is null)
    or (rule_type = 'monthly_weekday'
      and weekday is not null and weekday between 0 and 6
      and week_of_month is not null and week_of_month in (-1, 1, 2, 3, 4)
      and (ends_on is null or (starts_on is not null and ends_on >= starts_on))
      and month_day is null)
    or (rule_type = 'exception'
      and starts_on is not null and ends_on = starts_on
      and weekday is null and month_day is null and week_of_month is null)
  );
create index if not exists closure_rules_business_pattern_idx
  on public.closure_rules (business_id, rule_type, weekday, month_day, week_of_month);

-- Direct customer deletes, slot deletes, and reminder writes contradict the
-- archive/append-only rules. Those operations now go through constrained RPCs.
revoke delete on public.customers, public.slots from authenticated;
revoke insert, update, delete on public.reminder_events from authenticated;

create type private.idempotency_claim as (
  request_id uuid,
  cached_result jsonb
);

create or replace function private.assert_active_membership(p_business_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
    or not private.has_active_membership(p_business_id) then
    raise exception 'active business membership required' using errcode = '42501';
  end if;
end;
$$;

create or replace function private.claim_idempotency(
  p_business_id uuid,
  p_key text,
  p_operation text,
  p_payload jsonb
)
returns private.idempotency_claim
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash bytea;
  v_id uuid;
  v_existing_hash bytea;
  v_result jsonb;
  v_claim private.idempotency_claim;
begin
  if p_key is null or length(p_key) not between 16 and 200 then
    raise exception 'a 16 to 200 character idempotency key is required';
  end if;
  v_hash := extensions.digest(convert_to(jsonb_build_object('operation', p_operation, 'payload', p_payload)::text, 'UTF8'), 'sha256');
  insert into public.idempotency_requests (business_id, idempotency_key, request_hash, operation_name, created_by)
  values (p_business_id, p_key, v_hash, p_operation, (select auth.uid()))
  on conflict (business_id, idempotency_key) do nothing;
  select id, request_hash, result_payload into v_id, v_existing_hash, v_result
  from public.idempotency_requests
  where business_id = p_business_id and idempotency_key = p_key
  for update;
  if v_existing_hash is distinct from v_hash then
    raise exception 'idempotency key was already used for a different request' using errcode = '22023';
  end if;
  v_claim.request_id := v_id;
  v_claim.cached_result := v_result;
  return v_claim;
end;
$$;

create or replace function private.complete_idempotency(p_request_id uuid, p_result jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.idempotency_requests set result_payload = p_result where id = p_request_id;
$$;

create or replace function private.is_slot_closed(
  p_business_id uuid,
  p_service_date date,
  p_slot_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.closure_rules r
    where r.business_id = p_business_id and r.action = 'closed'
      and (r.slot_id is null or r.slot_id = p_slot_id)
      and (r.starts_on is null or r.starts_on <= p_service_date)
      and (r.ends_on is null or r.ends_on >= p_service_date)
      and case r.rule_type
        when 'date_range' then p_service_date between r.starts_on and r.ends_on
        when 'daily' then true
        when 'weekday' then extract(dow from p_service_date)::smallint = r.weekday
        when 'monthly_date' then extract(day from p_service_date)::smallint = r.month_day
        when 'monthly_weekday' then
          extract(dow from p_service_date)::smallint = r.weekday
          and case when r.week_of_month = -1
            then (p_service_date + 7) > (date_trunc('month', p_service_date::timestamp) + interval '1 month')::date
            else ((extract(day from p_service_date)::integer - 1) / 7 + 1) = r.week_of_month end
        else false
      end
      and not exists (
        select 1 from public.closure_rules e
        where e.business_id = p_business_id and e.action = 'open_exception'
          and e.rule_type = 'exception' and e.starts_on = p_service_date
          and (e.slot_id is null or e.slot_id = p_slot_id)
      )
  );
$$;

create or replace function private.closure_reason(
  p_business_id uuid,
  p_service_date date,
  p_slot_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(nullif(trim(r.reason), ''), 'Closed for this date or slot')
  from public.closure_rules r
  where r.business_id = p_business_id and r.action = 'closed'
    and (r.slot_id is null or r.slot_id = p_slot_id)
    and (r.starts_on is null or r.starts_on <= p_service_date)
    and (r.ends_on is null or r.ends_on >= p_service_date)
    and case r.rule_type
      when 'date_range' then p_service_date between r.starts_on and r.ends_on
      when 'daily' then true
      when 'weekday' then extract(dow from p_service_date)::smallint = r.weekday
      when 'monthly_date' then extract(day from p_service_date)::smallint = r.month_day
      when 'monthly_weekday' then extract(dow from p_service_date)::smallint = r.weekday
        and case when r.week_of_month = -1
          then (p_service_date + 7) > (date_trunc('month', p_service_date::timestamp) + interval '1 month')::date
          else ((extract(day from p_service_date)::integer - 1) / 7 + 1) = r.week_of_month end
      else false
    end
    and not exists (
      select 1 from public.closure_rules e
      where e.business_id = p_business_id and e.action = 'open_exception'
        and e.rule_type = 'exception' and e.starts_on = p_service_date
        and (e.slot_id is null or e.slot_id = p_slot_id)
    )
  order by (r.slot_id is not null) desc, r.created_at desc
  limit 1;
$$;

-- Read-only derived money views. Tagged deposits stay reserved for their order;
-- untagged money pays the oldest delivered orders first.
create or replace view public.order_payment_status
with (security_invoker = true)
as
with delivered as (
  select o.id as order_id, o.business_id, o.customer_id, o.service_date,
    o.delivered_at, o.amount_minor
      + coalesce(sum(case a.adjustment_kind when 'charge_increase' then a.amount_minor else -a.amount_minor end), 0) as charge_minor
  from public.orders o
  left join public.order_adjustments a on a.business_id = o.business_id and a.order_id = o.id
  where o.status = 'delivered'
  group by o.id
), tagged as (
  select l.business_id, l.customer_id, l.tagged_order_id as order_id,
    sum(case l.entry_kind when 'received' then l.amount_minor else -l.amount_minor end) as tagged_minor
  from public.ledger_entries l where l.tagged_order_id is not null
  group by l.business_id, l.customer_id, l.tagged_order_id
), net as (
  select l.business_id, l.customer_id,
    sum(case l.entry_kind when 'received' then l.amount_minor else -l.amount_minor end) as total_net_minor,
    sum(case when l.tagged_order_id is null then
      case l.entry_kind when 'received' then l.amount_minor else -l.amount_minor end else 0 end) as general_net_minor,
    sum(case when l.tagged_order_id is not null then
      case l.entry_kind when 'received' then l.amount_minor else -l.amount_minor end else 0 end) as tagged_net_minor
  from public.ledger_entries l group by l.business_id, l.customer_id
), order_funds as (
  select d.*, coalesce(t.tagged_minor, 0) as tagged_minor,
    least(d.charge_minor, greatest(coalesce(t.tagged_minor, 0), 0)) as tagged_applied_minor
  from delivered d left join tagged t using (business_id, customer_id, order_id)
), tagged_release as (
  select t.business_id, t.customer_id,
    sum(case when o.status = 'cancelled' then t.tagged_minor
      when o.status = 'delivered' then greatest(t.tagged_minor - coalesce(f.tagged_applied_minor, 0), 0)
      else 0 end) as released_minor
  from tagged t
  join public.orders o on o.business_id = t.business_id and o.id = t.order_id
  left join order_funds f on f.business_id = t.business_id and f.customer_id = t.customer_id and f.order_id = t.order_id
  group by t.business_id, t.customer_id
), pools as (
  select n.business_id, n.customer_id,
    n.general_net_minor + coalesce(t.released_minor, 0) as general_pool_minor
  from net n left join tagged_release t using (business_id, customer_id)
), ordered as (
  select f.*, greatest(f.charge_minor - f.tagged_applied_minor, 0) as after_tagged_minor,
    coalesce(sum(greatest(f.charge_minor - f.tagged_applied_minor, 0)) over (
      partition by f.business_id, f.customer_id
      order by f.service_date, f.delivered_at, f.order_id
      rows between unbounded preceding and 1 preceding), 0) as older_due_minor,
    coalesce(p.general_pool_minor, 0) as general_pool_minor
  from order_funds f left join pools p using (business_id, customer_id)
)
select order_id, business_id, customer_id, service_date, delivered_at, charge_minor,
  tagged_applied_minor,
  least(after_tagged_minor, greatest(general_pool_minor - older_due_minor, 0)) as general_applied_minor,
  greatest(after_tagged_minor - least(after_tagged_minor, greatest(general_pool_minor - older_due_minor, 0)), 0) as unpaid_minor,
  case when greatest(after_tagged_minor - least(after_tagged_minor, greatest(general_pool_minor - older_due_minor, 0)), 0) = 0
    then 'paid'
    when tagged_applied_minor + least(after_tagged_minor, greatest(general_pool_minor - older_due_minor, 0)) > 0
    then 'partly_paid' else 'unpaid' end as payment_status
from ordered;

create or replace view public.customer_balances
with (security_invoker = true)
as
with charges as (
  select o.business_id, o.customer_id,
    sum(o.amount_minor + coalesce(a.adjustment_minor, 0))::bigint as delivered_charges_minor
  from public.orders o
  left join (
    select business_id, order_id,
      sum(case adjustment_kind when 'charge_increase' then amount_minor else -amount_minor end)::bigint as adjustment_minor
    from public.order_adjustments group by business_id, order_id
  ) a on a.business_id = o.business_id and a.order_id = o.id
  where o.status = 'delivered' group by o.business_id, o.customer_id
), money as (
  select business_id, customer_id,
    sum(case entry_kind when 'received' then amount_minor else -amount_minor end)::bigint as net_received_minor
  from public.ledger_entries group by business_id, customer_id
), scheduled as (
  select o.business_id, o.customer_id, count(*)::integer as booked_order_count,
    sum(o.amount_minor)::bigint as booked_minor,
    min(o.service_date) as next_booked_on
  from public.orders o
  join public.businesses b on b.id = o.business_id
  where o.status = 'scheduled' and o.service_date >= (now() at time zone b.time_zone)::date
  group by o.business_id, o.customer_id
), unpaid as (
  select business_id, customer_id, min(service_date) filter (where unpaid_minor > 0) as oldest_unpaid_on,
    sum(unpaid_minor)::bigint as allocated_unpaid_minor
  from public.order_payment_status group by business_id, customer_id
), reminders as (
  select r.business_id, r.customer_id, max(r.reminder_date) as last_reminded_on
  from public.reminder_events r
  where r.action in ('opened', 'copied')
    and not exists (select 1 from public.reminder_events u where u.undo_of_id = r.id and u.action = 'undone')
  group by r.business_id, r.customer_id
)
select c.business_id, c.id as customer_id, c.full_name, c.phone_e164, c.flat_number, c.building,
  c.address_text, c.status,
  coalesce(ch.delivered_charges_minor, 0) - coalesce(m.net_received_minor, 0) as total_owed_minor,
  coalesce(ch.delivered_charges_minor, 0) as delivered_charges_minor,
  coalesce(m.net_received_minor, 0) as net_received_minor,
  u.oldest_unpaid_on,
  coalesce(s.booked_order_count, 0) as booked_order_count,
  coalesce(s.booked_minor, 0) as booked_minor,
  s.next_booked_on,
  r.last_reminded_on,
  c.created_at
from public.customers c
left join charges ch on ch.business_id = c.business_id and ch.customer_id = c.id
left join money m on m.business_id = c.business_id and m.customer_id = c.id
left join scheduled s on s.business_id = c.business_id and s.customer_id = c.id
left join unpaid u on u.business_id = c.business_id and u.customer_id = c.id
left join reminders r on r.business_id = c.business_id and r.customer_id = c.id;

grant select on public.order_payment_status, public.customer_balances to authenticated;

create or replace function public.preview_week_booking(
  p_business_id uuid,
  p_customer_id uuid,
  p_starts_on date,
  p_week_count smallint,
  p_weekdays smallint[],
  p_slot_id uuid,
  p_extend_for_closures boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dates jsonb;
  v_target integer;
  v_end date;
begin
  perform private.assert_active_membership(p_business_id);
  if p_week_count not between 1 and 52 or cardinality(p_weekdays) not between 1 and 7
    or exists (select 1 from unnest(p_weekdays) d where d not between 0 and 6)
    or cardinality(p_weekdays) <> (select count(distinct d) from unnest(p_weekdays) d) then
    raise exception 'invalid week count or weekdays';
  end if;
  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.business_id = p_business_id and c.status = 'active') then
    raise exception 'active customer not found';
  end if;
  if p_slot_id is not null and not exists (select 1 from public.slots s where s.id = p_slot_id and s.business_id = p_business_id and s.is_active) then
    raise exception 'active slot not found';
  end if;
  v_target := p_week_count * cardinality(p_weekdays);
  v_end := p_starts_on + (case when p_extend_for_closures then p_week_count + 52 else p_week_count end) * 7 - 1;
  with candidates as (
    select d::date as service_date, floor((d::date - p_starts_on) / 7.0)::integer as week_index,
      private.is_slot_closed(p_business_id, d::date, p_slot_id) as is_closed,
      private.closure_reason(p_business_id, d::date, p_slot_id) as closure_reason
    from generate_series(p_starts_on::timestamp, v_end::timestamp, interval '1 day') d
    where extract(dow from d)::smallint = any(p_weekdays)
  ), ranked as (
    select *, count(*) filter (where not is_closed) over (order by service_date) as eligible_count
    from candidates
  ), last_target as (
    select max(service_date) as cutoff from ranked where not is_closed and eligible_count = v_target
  ), chosen as (
    select r.* from ranked r cross join last_target t
    where case when p_extend_for_closures then r.service_date <= coalesce(t.cutoff, v_end)
      else r.week_index < p_week_count end
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'service_date', service_date, 'is_closed', is_closed, 'closure_reason', closure_reason,
    'will_create', not is_closed and (not p_extend_for_closures or eligible_count <= v_target)
  ) order by service_date), '[]'::jsonb) into v_dates from chosen;
  return jsonb_build_object(
    'dates', v_dates,
    'order_count', (select count(*) from jsonb_array_elements(v_dates) x where (x->>'will_create')::boolean),
    'skipped_count', (select count(*) from jsonb_array_elements(v_dates) x where (x->>'is_closed')::boolean),
    'extends_for_closures', p_extend_for_closures
  );
end;
$$;

create or replace function public.create_order(
  p_business_id uuid,
  p_customer_id uuid,
  p_service_date date,
  p_slot_id uuid,
  p_description text,
  p_quantity numeric,
  p_amount_minor bigint,
  p_order_kind text,
  p_note text,
  p_allow_closed boolean,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim private.idempotency_claim;
  v_result jsonb;
  v_order_id uuid;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'create_order',
    jsonb_build_object('customer_id', p_customer_id, 'service_date', p_service_date, 'slot_id', p_slot_id,
      'description', p_description, 'quantity', p_quantity, 'amount_minor', p_amount_minor,
      'order_kind', p_order_kind, 'note', p_note, 'allow_closed', p_allow_closed));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.business_id = p_business_id and c.status = 'active') then
    raise exception 'active customer not found';
  end if;
  if p_slot_id is not null and not exists (select 1 from public.slots s where s.id = p_slot_id and s.business_id = p_business_id and s.is_active) then
    raise exception 'active slot not found';
  end if;
  if private.is_slot_closed(p_business_id, p_service_date, p_slot_id) and not coalesce(p_allow_closed, false) then
    raise exception using message = coalesce(private.closure_reason(p_business_id, p_service_date, p_slot_id), 'This slot is closed'), errcode = 'P0001';
  end if;  if p_slot_id is not null and not exists (
    select 1 from public.slots s where s.id = p_slot_id and s.business_id = p_business_id and s.is_active
  ) then raise exception 'choose an active delivery slot'; end if;
  insert into public.orders (business_id, customer_id, service_date, slot_id, description, quantity, amount_minor, order_kind, note, created_by)
  values (p_business_id, p_customer_id, p_service_date, p_slot_id, nullif(trim(p_description), ''), p_quantity, p_amount_minor, p_order_kind, nullif(trim(p_note), ''), (select auth.uid()))
  returning id into v_order_id;
  insert into public.order_events (business_id, order_id, actor_user_id, event_type, event_data)
  values (p_business_id, v_order_id, (select auth.uid()), 'created', jsonb_build_object('service_date', p_service_date, 'amount_minor', p_amount_minor));
  v_result := jsonb_build_object('order_id', v_order_id);
  perform private.complete_idempotency(v_claim.request_id, v_result);
  return v_result;
end;
$$;

create or replace function public.create_week_booking(
  p_business_id uuid,
  p_customer_id uuid,
  p_starts_on date,
  p_week_count smallint,
  p_weekdays smallint[],
  p_slot_id uuid,
  p_description text,
  p_amount_per_order_minor bigint,
  p_extend_for_closures boolean,
  p_advance_minor bigint,
  p_advance_method text,
  p_advance_date date,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim private.idempotency_claim;
  v_preview jsonb;
  v_booking_id uuid;
  v_order_ids uuid[] := array[]::uuid[];
  v_item jsonb;
  v_order_id uuid;
  v_ledger_id uuid;
  v_result jsonb;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'create_week_booking',
    jsonb_build_object('customer_id', p_customer_id, 'starts_on', p_starts_on, 'week_count', p_week_count,
      'weekdays', p_weekdays, 'slot_id', p_slot_id, 'description', p_description,
      'amount_per_order_minor', p_amount_per_order_minor, 'extend_for_closures', p_extend_for_closures,
      'advance_minor', p_advance_minor, 'advance_method', p_advance_method, 'advance_date', p_advance_date));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  if p_amount_per_order_minor <= 0 or coalesce(p_advance_minor, 0) < 0 then raise exception 'amounts must be valid positive minor units'; end if;
  v_preview := public.preview_week_booking(p_business_id, p_customer_id, p_starts_on, p_week_count, p_weekdays, p_slot_id, p_extend_for_closures);
  if (v_preview->>'order_count')::integer = 0 then raise exception 'booking preview contains no open delivery dates'; end if;
  insert into public.bookings (business_id, customer_id, slot_id, starts_on, week_count, weekdays, description, amount_per_order_minor, status, created_by)
  values (p_business_id, p_customer_id, p_slot_id, p_starts_on, p_week_count, p_weekdays, nullif(trim(p_description), ''), p_amount_per_order_minor, 'confirmed', (select auth.uid()))
  returning id into v_booking_id;
  for v_item in select value from jsonb_array_elements(v_preview->'dates') where (value->>'will_create')::boolean loop
    insert into public.orders (business_id, customer_id, booking_id, slot_id, service_date, description, amount_minor, order_kind, created_by)
    values (p_business_id, p_customer_id, v_booking_id, p_slot_id, (v_item->>'service_date')::date,
      nullif(trim(p_description), ''), p_amount_per_order_minor, 'regular', (select auth.uid())) returning id into v_order_id;
    v_order_ids := array_append(v_order_ids, v_order_id);
    insert into public.order_events (business_id, order_id, actor_user_id, event_type, event_data)
    values (p_business_id, v_order_id, (select auth.uid()), 'created_from_booking', jsonb_build_object('booking_id', v_booking_id));
  end loop;
  if coalesce(p_advance_minor, 0) > 0 then
    insert into public.ledger_entries (business_id, customer_id, entry_kind, amount_minor, occurred_on, payment_method, reference_note, created_by, idempotency_request_id)
    values (p_business_id, p_customer_id, 'received', p_advance_minor, coalesce(p_advance_date, current_date), p_advance_method, 'Advance with week booking', (select auth.uid()), v_claim.request_id)
    returning id into v_ledger_id;
  end if;
  v_result := jsonb_build_object('booking_id', v_booking_id, 'order_ids', to_jsonb(v_order_ids), 'advance_entry_id', v_ledger_id, 'preview', v_preview);
  perform private.complete_idempotency(v_claim.request_id, v_result);
  return v_result;
end;
$$;

create or replace function public.mark_order_delivered(
  p_business_id uuid, p_order_id uuid, p_idempotency_key text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_claim private.idempotency_claim; v_result jsonb; v_date date;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'mark_order_delivered', jsonb_build_object('order_id', p_order_id));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  update public.orders set status = 'delivered', delivered_at = now(), cancelled_at = null, row_version = row_version + 1
  where id = p_order_id and business_id = p_business_id and status = 'scheduled' returning service_date into v_date;
  if not found then raise exception 'scheduled order not found'; end if;
  insert into public.order_events (business_id, order_id, actor_user_id, event_type, event_data)
  values (p_business_id, p_order_id, (select auth.uid()), 'delivered', jsonb_build_object('service_date', v_date));
  v_result := jsonb_build_object('order_id', p_order_id, 'status', 'delivered');
  perform private.complete_idempotency(v_claim.request_id, v_result); return v_result;
end;
$$;

create or replace function public.undo_order_delivery(
  p_business_id uuid, p_order_id uuid, p_idempotency_key text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_claim private.idempotency_claim; v_result jsonb;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'undo_order_delivery', jsonb_build_object('order_id', p_order_id));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  perform 1 from public.orders where id = p_order_id and business_id = p_business_id and status = 'delivered' for update;
  if not found then raise exception 'delivered order not found'; end if;
  if (select e.event_type from public.order_events e where e.business_id = p_business_id and e.order_id = p_order_id order by e.created_at desc, e.id desc limit 1) <> 'delivered' then
    raise exception 'delivery can only be undone before a later order change';
  end if;
  update public.orders set status = 'scheduled', delivered_at = null, row_version = row_version + 1 where id = p_order_id and business_id = p_business_id;
  insert into public.order_events (business_id, order_id, actor_user_id, event_type)
  values (p_business_id, p_order_id, (select auth.uid()), 'delivery_undone');
  v_result := jsonb_build_object('order_id', p_order_id, 'status', 'scheduled');
  perform private.complete_idempotency(v_claim.request_id, v_result); return v_result;
end;
$$;

create or replace function public.cancel_order(
  p_business_id uuid, p_order_id uuid, p_idempotency_key text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_claim private.idempotency_claim; v_result jsonb;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'cancel_order', jsonb_build_object('order_id', p_order_id));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  update public.orders set status = 'cancelled', cancelled_at = now(), row_version = row_version + 1
  where id = p_order_id and business_id = p_business_id and status = 'scheduled';
  if not found then raise exception 'only scheduled orders can be cancelled'; end if;
  insert into public.order_events (business_id, order_id, actor_user_id, event_type)
  values (p_business_id, p_order_id, (select auth.uid()), 'cancelled');
  v_result := jsonb_build_object('order_id', p_order_id, 'status', 'cancelled');
  perform private.complete_idempotency(v_claim.request_id, v_result); return v_result;
end;
$$;

create or replace function public.update_scheduled_order(
  p_business_id uuid, p_order_id uuid, p_service_date date, p_slot_id uuid,
  p_description text, p_quantity numeric, p_amount_minor bigint, p_order_kind text,
  p_note text, p_allow_closed boolean, p_idempotency_key text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_claim private.idempotency_claim; v_result jsonb;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'update_scheduled_order',
    jsonb_build_object('order_id', p_order_id, 'service_date', p_service_date, 'slot_id', p_slot_id,
      'description', p_description, 'quantity', p_quantity, 'amount_minor', p_amount_minor,
      'order_kind', p_order_kind, 'note', p_note, 'allow_closed', p_allow_closed));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  if private.is_slot_closed(p_business_id, p_service_date, p_slot_id) and not coalesce(p_allow_closed, false) then
    raise exception using message = coalesce(private.closure_reason(p_business_id, p_service_date, p_slot_id), 'This slot is closed'), errcode = 'P0001';
  end if;  if p_slot_id is not null and not exists (
    select 1 from public.slots s where s.id = p_slot_id and s.business_id = p_business_id and s.is_active
  ) then raise exception 'choose an active delivery slot'; end if;
  update public.orders set service_date = p_service_date, slot_id = p_slot_id,
    description = nullif(trim(p_description), ''), quantity = p_quantity, amount_minor = p_amount_minor,
    order_kind = p_order_kind, note = nullif(trim(p_note), ''), row_version = row_version + 1, updated_at = now(), updated_by = (select auth.uid())
  where id = p_order_id and business_id = p_business_id and status = 'scheduled';
  if not found then raise exception 'only scheduled orders can be edited'; end if;
  insert into public.order_events (business_id, order_id, actor_user_id, event_type, event_data)
  values (p_business_id, p_order_id, (select auth.uid()), 'updated', jsonb_build_object('service_date', p_service_date, 'amount_minor', p_amount_minor));
  v_result := jsonb_build_object('order_id', p_order_id, 'status', 'scheduled');
  perform private.complete_idempotency(v_claim.request_id, v_result); return v_result;
end;
$$;

create or replace function public.record_payment(
  p_business_id uuid, p_customer_id uuid, p_amount_minor bigint, p_occurred_on date,
  p_payment_method text, p_reference_note text, p_tagged_order_id uuid, p_idempotency_key text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_claim private.idempotency_claim; v_result jsonb; v_entry_id uuid;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'record_payment',
    jsonb_build_object('customer_id', p_customer_id, 'amount_minor', p_amount_minor, 'occurred_on', p_occurred_on,
      'payment_method', p_payment_method, 'reference_note', p_reference_note, 'tagged_order_id', p_tagged_order_id));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.business_id = p_business_id) then raise exception 'customer not found'; end if;
  if p_tagged_order_id is not null and not exists (select 1 from public.orders o where o.id = p_tagged_order_id and o.business_id = p_business_id and o.customer_id = p_customer_id and o.status <> 'cancelled') then
    raise exception 'deposit order does not belong to this customer or is cancelled';
  end if;
  insert into public.ledger_entries (business_id, customer_id, tagged_order_id, entry_kind, amount_minor, occurred_on, payment_method, reference_note, created_by, idempotency_request_id)
  values (p_business_id, p_customer_id, p_tagged_order_id, 'received', p_amount_minor, p_occurred_on, p_payment_method, nullif(trim(p_reference_note), ''), (select auth.uid()), v_claim.request_id)
  returning id into v_entry_id;
  v_result := jsonb_build_object('ledger_entry_id', v_entry_id);
  perform private.complete_idempotency(v_claim.request_id, v_result); return v_result;
end;
$$;

create or replace function public.record_return(
  p_business_id uuid, p_customer_id uuid, p_amount_minor bigint, p_occurred_on date,
  p_reference_note text, p_tagged_order_id uuid, p_idempotency_key text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_claim private.idempotency_claim; v_result jsonb; v_entry_id uuid;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'record_return',
    jsonb_build_object('customer_id', p_customer_id, 'amount_minor', p_amount_minor, 'occurred_on', p_occurred_on,
      'reference_note', p_reference_note, 'tagged_order_id', p_tagged_order_id));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.business_id = p_business_id) then raise exception 'customer not found'; end if;
  if p_tagged_order_id is not null and not exists (select 1 from public.orders o where o.id = p_tagged_order_id and o.business_id = p_business_id and o.customer_id = p_customer_id) then raise exception 'order does not belong to this customer'; end if;
  insert into public.ledger_entries (business_id, customer_id, tagged_order_id, entry_kind, amount_minor, occurred_on, reference_note, created_by, idempotency_request_id)
  values (p_business_id, p_customer_id, p_tagged_order_id, 'returned', p_amount_minor, p_occurred_on, nullif(trim(p_reference_note), ''), (select auth.uid()), v_claim.request_id)
  returning id into v_entry_id;
  v_result := jsonb_build_object('ledger_entry_id', v_entry_id);
  perform private.complete_idempotency(v_claim.request_id, v_result); return v_result;
end;
$$;

create or replace function public.reverse_ledger_entry(
  p_business_id uuid, p_ledger_entry_id uuid, p_idempotency_key text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_claim private.idempotency_claim; v_result jsonb; v_original public.ledger_entries%rowtype; v_entry_id uuid;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'reverse_ledger_entry', jsonb_build_object('ledger_entry_id', p_ledger_entry_id));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  select * into v_original from public.ledger_entries where id = p_ledger_entry_id and business_id = p_business_id for update;
  if not found then raise exception 'ledger entry not found'; end if;
  if exists (select 1 from public.ledger_entries where business_id = p_business_id and reversal_of_id = p_ledger_entry_id) then raise exception 'ledger entry is already reversed'; end if;
  insert into public.ledger_entries (business_id, customer_id, tagged_order_id, entry_kind, amount_minor, occurred_on,
    payment_method, reference_note, reversal_of_id, created_by, idempotency_request_id)
  values (p_business_id, v_original.customer_id, v_original.tagged_order_id,
    case v_original.entry_kind when 'received' then 'returned' else 'received' end,
    v_original.amount_minor, current_date, v_original.payment_method,
    'Reversal of ledger entry ' || v_original.id::text, v_original.id, (select auth.uid()), v_claim.request_id)
  returning id into v_entry_id;
  v_result := jsonb_build_object('ledger_entry_id', v_entry_id, 'reversed_entry_id', p_ledger_entry_id);
  perform private.complete_idempotency(v_claim.request_id, v_result); return v_result;
end;
$$;

create or replace function public.update_business_settings(
  p_business_id uuid, p_name text, p_country_code text, p_currency_code text, p_time_zone text,
  p_reminder_weekday smallint, p_reminder_day smallint, p_reminder_time time,
  p_reminder_template text, p_terminology jsonb
)
returns public.businesses
language plpgsql security definer set search_path = ''
as $$
declare v_business public.businesses%rowtype;
begin
  perform private.assert_active_membership(p_business_id);
  update public.businesses set name = p_name, country_code = p_country_code, currency_code = p_currency_code,
    time_zone = p_time_zone, reminder_weekday = p_reminder_weekday, reminder_day = p_reminder_day,
    reminder_time = p_reminder_time, reminder_template = p_reminder_template,
    terminology = coalesce(p_terminology, '{}'::jsonb), updated_at = now()
  where id = p_business_id returning * into v_business;
  if not found then raise exception 'business not found'; end if;
  return v_business;
end;
$$;

create or replace function public.save_closure_rule(
  p_business_id uuid, p_rule_id uuid, p_rule jsonb
)
returns public.closure_rules
language plpgsql security definer set search_path = ''
as $$
declare v_rule public.closure_rules%rowtype;
begin
  perform private.assert_active_membership(p_business_id);
  if p_rule_id is null then
    insert into public.closure_rules (business_id, slot_id, rule_type, starts_on, ends_on, weekday, month_day, week_of_month, action, reason, created_by)
    values (p_business_id, nullif(p_rule->>'slot_id','')::uuid, p_rule->>'rule_type', nullif(p_rule->>'starts_on','')::date,
      nullif(p_rule->>'ends_on','')::date, nullif(p_rule->>'weekday','')::smallint, nullif(p_rule->>'month_day','')::smallint,
      nullif(p_rule->>'week_of_month','')::smallint, p_rule->>'action', nullif(trim(p_rule->>'reason'),''), (select auth.uid()))
    returning * into v_rule;
  else
    update public.closure_rules set slot_id = nullif(p_rule->>'slot_id','')::uuid, rule_type = p_rule->>'rule_type',
      starts_on = nullif(p_rule->>'starts_on','')::date, ends_on = nullif(p_rule->>'ends_on','')::date,
      weekday = nullif(p_rule->>'weekday','')::smallint, month_day = nullif(p_rule->>'month_day','')::smallint,
      week_of_month = nullif(p_rule->>'week_of_month','')::smallint, action = p_rule->>'action',
      reason = nullif(trim(p_rule->>'reason'),''), updated_by = (select auth.uid()), updated_at = now()
    where id = p_rule_id and business_id = p_business_id returning * into v_rule;
  end if;
  if not found then raise exception 'closure rule not found'; end if;
  return v_rule;
end;
$$;

create or replace function public.delete_closure_rule(p_business_id uuid, p_rule_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.assert_active_membership(p_business_id);
  delete from public.closure_rules where id = p_rule_id and business_id = p_business_id;
  if not found then raise exception 'closure rule not found'; end if;
end;
$$;

create or replace function public.record_reminder(
  p_business_id uuid, p_customer_id uuid, p_reminder_date date, p_channel text,
  p_action text, p_idempotency_key text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_claim private.idempotency_claim; v_result jsonb; v_event_id uuid;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'record_reminder',
    jsonb_build_object('customer_id', p_customer_id, 'reminder_date', p_reminder_date, 'channel', p_channel, 'action', p_action));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text || ':' || p_customer_id::text || ':' || p_reminder_date::text || ':' || p_channel, 0));
  select r.id into v_event_id from public.reminder_events r
  where r.business_id = p_business_id and r.customer_id = p_customer_id and r.reminder_date = p_reminder_date and r.channel = p_channel
    and r.action in ('opened','copied')
    and not exists (select 1 from public.reminder_events u where u.undo_of_id = r.id and u.action = 'undone')
  order by r.created_at desc limit 1;
  if v_event_id is null then
    insert into public.reminder_events (business_id, customer_id, reminder_date, channel, action, created_by)
    values (p_business_id, p_customer_id, p_reminder_date, p_channel, p_action, (select auth.uid())) returning id into v_event_id;
  end if;
  v_result := jsonb_build_object('reminder_event_id', v_event_id);
  perform private.complete_idempotency(v_claim.request_id, v_result); return v_result;
end;
$$;

create or replace function public.undo_reminder(p_business_id uuid, p_event_id uuid, p_idempotency_key text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_claim private.idempotency_claim; v_result jsonb; v_event public.reminder_events%rowtype; v_undo_id uuid;
begin
  perform private.assert_active_membership(p_business_id);
  v_claim := private.claim_idempotency(p_business_id, p_idempotency_key, 'undo_reminder', jsonb_build_object('event_id', p_event_id));
  if v_claim.cached_result is not null then return v_claim.cached_result; end if;
  select * into v_event from public.reminder_events where id = p_event_id and business_id = p_business_id for update;
  if not found or v_event.action not in ('opened','copied') then raise exception 'reminder event not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text || ':' || v_event.customer_id::text || ':' || v_event.reminder_date::text || ':' || v_event.channel, 0));
  if exists (select 1 from public.reminder_events where undo_of_id = p_event_id) then raise exception 'reminder was already undone'; end if;
  insert into public.reminder_events (business_id, customer_id, reminder_date, channel, action, undo_of_id, created_by)
  values (p_business_id, v_event.customer_id, v_event.reminder_date, v_event.channel, 'undone', p_event_id, (select auth.uid())) returning id into v_undo_id;
  v_result := jsonb_build_object('undo_event_id', v_undo_id, 'reminder_event_id', p_event_id);
  perform private.complete_idempotency(v_claim.request_id, v_result); return v_result;
end;
$$;

revoke all on function private.assert_active_membership(uuid) from public, anon, authenticated;
revoke all on function private.claim_idempotency(uuid,text,text,jsonb) from public, anon, authenticated;
revoke all on function private.complete_idempotency(uuid,jsonb) from public, anon, authenticated;
revoke all on function private.is_slot_closed(uuid,date,uuid) from public, anon, authenticated;
revoke all on function private.closure_reason(uuid,date,uuid) from public, anon, authenticated;
revoke all on function public.preview_week_booking(uuid,uuid,date,smallint,smallint[],uuid,boolean) from public, anon;
revoke all on function public.create_order(uuid,uuid,date,uuid,text,numeric,bigint,text,text,boolean,text) from public, anon;
revoke all on function public.create_week_booking(uuid,uuid,date,smallint,smallint[],uuid,text,bigint,boolean,bigint,text,date,text) from public, anon;
revoke all on function public.mark_order_delivered(uuid,uuid,text) from public, anon;
revoke all on function public.undo_order_delivery(uuid,uuid,text) from public, anon;
revoke all on function public.cancel_order(uuid,uuid,text) from public, anon;
revoke all on function public.update_scheduled_order(uuid,uuid,date,uuid,text,numeric,bigint,text,text,boolean,text) from public, anon;
revoke all on function public.record_payment(uuid,uuid,bigint,date,text,text,uuid,text) from public, anon;
revoke all on function public.record_return(uuid,uuid,bigint,date,text,uuid,text) from public, anon;
revoke all on function public.reverse_ledger_entry(uuid,uuid,text) from public, anon;
revoke all on function public.update_business_settings(uuid,text,text,text,text,smallint,smallint,time,text,jsonb) from public, anon;
revoke all on function public.save_closure_rule(uuid,uuid,jsonb) from public, anon;
revoke all on function public.delete_closure_rule(uuid,uuid) from public, anon;
revoke all on function public.record_reminder(uuid,uuid,date,text,text,text) from public, anon;
revoke all on function public.undo_reminder(uuid,uuid,text) from public, anon;
grant execute on function public.preview_week_booking(uuid,uuid,date,smallint,smallint[],uuid,boolean) to authenticated;
grant execute on function public.create_order(uuid,uuid,date,uuid,text,numeric,bigint,text,text,boolean,text) to authenticated;
grant execute on function public.create_week_booking(uuid,uuid,date,smallint,smallint[],uuid,text,bigint,boolean,bigint,text,date,text) to authenticated;
grant execute on function public.mark_order_delivered(uuid,uuid,text) to authenticated;
grant execute on function public.undo_order_delivery(uuid,uuid,text) to authenticated;
grant execute on function public.cancel_order(uuid,uuid,text) to authenticated;
grant execute on function public.update_scheduled_order(uuid,uuid,date,uuid,text,numeric,bigint,text,text,boolean,text) to authenticated;
grant execute on function public.record_payment(uuid,uuid,bigint,date,text,text,uuid,text) to authenticated;
grant execute on function public.record_return(uuid,uuid,bigint,date,text,uuid,text) to authenticated;
grant execute on function public.reverse_ledger_entry(uuid,uuid,text) to authenticated;
grant execute on function public.update_business_settings(uuid,text,text,text,text,smallint,smallint,time,text,jsonb) to authenticated;
grant execute on function public.save_closure_rule(uuid,uuid,jsonb) to authenticated;
grant execute on function public.delete_closure_rule(uuid,uuid) to authenticated;
grant execute on function public.record_reminder(uuid,uuid,date,text,text,text) to authenticated;
grant execute on function public.undo_reminder(uuid,uuid,text) to authenticated;

notify pgrst, 'reload schema';
