-- Let a signed-in user create their first workspace without exposing tenant
-- table inserts to the browser. The function is intentionally idempotent for
-- users who already have an active business membership.

create or replace function public.create_business_for_current_user(p_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_name text := pg_catalog.btrim(coalesce(p_name, ''));
  v_business_id uuid;
begin
  if v_user_id is null then
    raise exception 'Sign in before creating a business.' using errcode = '28000';
  end if;

  if pg_catalog.length(v_name) not between 1 and 120 then
    raise exception 'Enter a business name between 1 and 120 characters.' using errcode = '22023';
  end if;

  -- Serialize concurrent onboarding requests for the same account.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text, 0));

  select membership.business_id
    into v_business_id
    from public.business_memberships as membership
   where membership.user_id = v_user_id
     and membership.status = 'active'
   order by membership.created_at
   limit 1;

  if v_business_id is not null then
    return v_business_id;
  end if;

  if exists (
    select 1
      from public.business_memberships as membership
     where membership.user_id = v_user_id
  ) then
    raise exception 'This account already has a business membership. Sign in with the email linked to that business.' using errcode = '23505';
  end if;

  insert into public.businesses (name)
  values (v_name)
  returning id into v_business_id;

  insert into public.business_memberships (
    business_id, user_id, role, status, activated_at, created_by
  ) values (
    v_business_id, v_user_id, 'owner', 'active', pg_catalog.now(), v_user_id
  );

  return v_business_id;
end;
$$;

revoke all on function public.create_business_for_current_user(text) from public, anon;
grant execute on function public.create_business_for_current_user(text) to authenticated;

comment on function public.create_business_for_current_user(text) is
  'Creates a first business workspace for the authenticated user and grants only that user owner membership.';
