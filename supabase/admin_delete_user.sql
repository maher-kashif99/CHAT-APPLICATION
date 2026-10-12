-- ============================================================================
-- Admin: delete a user
--
-- Run this in the Supabase SQL Editor. Idempotent — safe to run twice.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES
--
-- Removes the person's `profiles` row and their `chat_members` memberships.
--
-- It deliberately KEEPS their `messages`, so the other participants' chat
-- history is not destroyed. Those messages stay readable; they simply show
-- without a name.
--
-- It does NOT delete the `auth.users` row. That requires the service_role
-- key, which must never ship inside a mobile app. To fully remove the login
-- account, delete it in the Supabase dashboard:
--
--     Authentication -> Users -> select user -> Delete
--
-- (That will fail while messages reference the user, because
--  messages.sender_id has a foreign key to auth.users. Delete their messages
--  first, or accept that the auth account remains.)
--
-- After removal the person can still sign in, but with no profile row they
-- land back in "Waiting for approval" — the app recreates the profile on next
-- login with is_approved = false. So removal is effectively a revoke.
-- ============================================================================

create or replace function public.delete_user(target_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;

  if target_id = auth.uid() then
    raise exception 'You cannot delete your own account';
  end if;

  select p.email into v_email from public.profiles p where p.id = target_id;
  if v_email is null then
    raise exception 'No profile found for that user';
  end if;

  -- Remove memberships first (they reference auth.users, not profiles, so
  -- order does not strictly matter, but this keeps the audit trail clean).
  delete from public.chat_members where user_id = target_id;

  -- Remove the profile. The BEFORE INSERT/UPDATE trigger on profiles does not
  -- interfere with DELETE.
  delete from public.profiles where id = target_id;

  raise notice 'Removed user % (%)', v_email, target_id;
end;
$$;

grant execute on function public.delete_user(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Bulk revoke: un-approve everyone currently pending.
-- Useful if a batch of signups slipped through before the default was fixed.
-- ---------------------------------------------------------------------------
create or replace function public.revoke_all_pending()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;

  update public.profiles set is_approved = false where is_approved = true
    and id <> auth.uid();
  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.revoke_all_pending() to authenticated;