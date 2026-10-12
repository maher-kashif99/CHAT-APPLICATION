-- ============================================================================
-- Approval / admin fixes
--
-- Run this ONCE in the Supabase dashboard (SQL Editor > New query > Run).
-- Idempotent — safe to run twice.
--
-- Fixes two bugs in the first version of admin.sql:
--
--   1. New accounts were auto-approved.
--      `is_approved` was created with DEFAULT true, so anybody who signed up
--      skipped the approval screen and could chat immediately.
--
--   2. `revoke update ... from authenticated` silently broke INSERT as well.
--      On a table, `revoke UPDATE` only affects UPDATE, so that part was fine —
--      but nothing stopped a client from *inserting* its own profile with
--      `is_admin: true`. That was a privilege-escalation hole: anyone could
--      POST their own row with is_admin set and become admin.
--
--      The trigger below makes those two columns server-controlled. No client,
--      however modified, can set them.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. New accounts start un-approved.
--
--    `not null default false` applies to rows inserted from here on.
--    Existing users are left alone — otherwise this would lock you out.
-- ---------------------------------------------------------------------------
alter table public.profiles
  alter column is_approved set default false;

-- ---------------------------------------------------------------------------
-- 2. Server-controlled columns.
--
--    A BEFORE INSERT/UPDATE trigger overwrites is_admin and is_approved with
--    safe values no matter what the client sent. This is stronger than RLS,
--    which is bypassed by the security-definer functions above.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_profile_flags()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Nothing may set these at insert time, not even the row's own owner.
  if tg_op = 'INSERT' then
    new.is_admin := false;
    new.is_approved := false;
    return new;
  end if;

  -- On update, only an existing admin may change these. Comparing against
  -- OLD means a normal user editing their display name cannot sneak in
  -- `is_admin = true`.
  if new.is_admin is distinct from old.is_admin
     or new.is_approved is distinct from old.is_approved then
    if not coalesce(
         (select p.is_admin from public.profiles p where p.id = auth.uid()),
         false
       ) then
      raise exception 'Not authorised to change admin or approval status';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_enforce_flags on public.profiles;
create trigger profiles_enforce_flags
  before insert or update on public.profiles
  for each row execute function public.enforce_profile_flags();

-- ---------------------------------------------------------------------------
-- 3. Make sure you are approved (so you are not locked out by change #1).
--
--    Run this AFTER the trigger exists. It works because the trigger allows an
--    existing admin to change flags — and if you are not an admin yet, run the
--    promote_first_admin() call below FIRST.
--
--    Typical order:
--      a) select promote_first_admin('you@example.com');   -- sets admin + approved
--      b) run this whole file
-- ---------------------------------------------------------------------------

-- Optional convenience: approve every currently-pending account in one go.
-- Uncomment and run only if that is what you want:
--
-- update public.profiles set is_approved = true where is_approved = false;