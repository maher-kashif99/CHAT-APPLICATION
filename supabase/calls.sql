-- ============================================================================
-- Calls table: policies, defaults and realtime
--
-- The `calls` table already exists. This script fills in what the app needs:
--   * a default for `caller_id` so the client does not have to send it
--   * RLS so a user can only see and update their own calls
--   * status-transition guards (ending a call twice is a no-op, not an error)
--   * realtime publication, without which no incoming call ever arrives
--
-- Run this in the Supabase SQL Editor. Idempotent — safe to run twice.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. caller_id defaults to the signed-in user.
--
-- The app inserts a call without caller_id (it would be spoofable if it sent
-- its own value). This makes the database fill it in instead.
-- ---------------------------------------------------------------------------
alter table public.calls
  alter column caller_id set default auth.uid();

-- Guard against a client explicitly trying to forge it.
create or replace function public.force_call_caller()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- On insert auth.uid() is the real caller.
  if tg_op = 'INSERT' then
    new.caller_id := auth.uid();
  end if;
  return new;
end;
$$;

drop trigger if exists calls_force_caller on public.calls;
create trigger calls_force_caller
  before insert on public.calls
  for each row execute function public.force_call_caller();

-- ---------------------------------------------------------------------------
-- 2. Status machine.
--
-- Transitions allowed:
--   ringing  -> accepted | declined | cancelled | missed | ended
--   accepted -> ended
--   declined / cancelled / missed / ended  -> (terminal, nothing further)
--
-- The app hangs up by writing 'cancelled' then 'ended'. Without this guard the
-- second write would fail on a call that was already declined, which is
-- harmless-but-noisy. With it, terminal states simply absorb further writes.
-- ---------------------------------------------------------------------------
create or replace function public.guard_call_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  -- Already finished: absorb any further change instead of erroring.
  if old.status in ('declined', 'cancelled', 'missed', 'ended') then
    new.status := old.status;
    return new;
  end if;

  -- Ring timeout: only the caller may mark a call missed.
  if new.status = 'missed' and old.status = 'ringing' then
    if new.ended_at is null then
      new.ended_at := now();
    end if;
    return new;
  end if;

  if new.status = 'accepted' then
    if new.answered_at is null then
      new.answered_at := now();
    end if;
    return new;
  end if;

  if new.status = 'ended' and new.ended_at is null then
    new.ended_at := now();
  end if;

  return new;
end;
$$;

drop trigger if exists calls_guard_status on public.calls;
create trigger calls_guard_status
  before update on public.calls
  for each row execute function public.guard_call_status();

-- ---------------------------------------------------------------------------
-- 3. RLS — a user may only see and touch calls they are party to.
-- ---------------------------------------------------------------------------
alter table public.calls enable row level security;

drop policy if exists "read own calls" on public.calls;
create policy "read own calls"
  on public.calls for select
  to authenticated
  using (auth.uid() = caller_id or auth.uid() = callee_id);

drop policy if exists "start own calls" on public.calls;
create policy "start own calls"
  on public.calls for insert
  to authenticated
  with check (auth.uid() = caller_id);

drop policy if exists "update own calls" on public.calls;
create policy "update own calls"
  on public.calls for update
  to authenticated
  using (auth.uid() = caller_id or auth.uid() = callee_id)
  with check (auth.uid() = caller_id or auth.uid() = callee_id);

-- ---------------------------------------------------------------------------
-- 4. Realtime.
--
-- CRITICAL: without this, incoming calls never fire. The app listens for
-- INSERTs on `calls` filtered by callee_id, and polls as a safety net.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'calls'
  ) then
    alter publication supabase_realtime add table public.calls;
    raise notice 'Added calls to the supabase_realtime publication.';
  else
    raise notice 'calls is already in the realtime publication.';
  end if;
end $$;