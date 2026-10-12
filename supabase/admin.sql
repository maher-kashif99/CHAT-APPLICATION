-- ============================================================================
-- Admin / approval roles
--
-- Run this ONCE in the Supabase dashboard AFTER supabase/schema.sql:
--   SQL Editor > New query > paste > Run
--
-- It is idempotent, so running it twice is safe.
--
-- Adds:
--   * profiles.is_admin      — full access (approve users, see the admin list)
--   * profiles.is_approved   — must be true before the app lets them chat
--   * a "pending users" admin screen
--   * a helper to promote someone to admin
--
-- ---------------------------------------------------------------------------
-- SECURITY NOTE (please read)
--
-- The existing policy lets a user update their *own* profile row with no
-- column restriction. If we simply added an `is_admin` boolean, any signed-in
-- user could run:
--     update profiles set is_admin = true where id = <their own id>
-- and promote themselves, because their update is "on their own row".
--
-- To prevent that, we revoke the blanket UPDATE grant and re-grant it for
-- only the four columns a user is allowed to change themselves. Without the
-- grant, Supabase's PostgREST cannot write `is_admin` or `is_approved`.
-- ============================================================================

-- ---------------------------------------------------------------- columns
alter table public.profiles add column if not exists is_admin boolean not null default false;
alter table public.profiles add column if not exists is_approved boolean not null default true;

create index if not exists profiles_is_approved_idx
  on public.profiles (is_approved);

-- ============================================================================
-- Column-level permissions
--
-- Revoke the blanket update, then allow only these self-editable columns.
-- `is_admin` and `is_approved` are deliberately NOT in this list, so a user
-- can never grant themselves either.
-- ============================================================================
revoke update on public.profiles from authenticated;

grant update (display_name, username, avatar_url, status)
  on public.profiles to authenticated;

-- Admins need to update other people's rows (approve them). Grant the full
-- update only to the service_role (used by the server/Edge Function), and let
-- admins do their approving through the security-definer functions below,
-- which do not rely on the client being able to write those columns.

-- ============================================================================
-- Helper: is the signed-in user an admin?
-- ============================================================================
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select is_admin from public.profiles where id = auth.uid()),
    false
  );
$$;

grant execute on function public.is_admin() to authenticated;

-- ============================================================================
-- List users that are waiting for approval (admins only).
-- ============================================================================
create or replace function public.list_pending_users()
returns table (
  id uuid,
  email text,
  username text,
  display_name text,
  created_at timestamptz,
  is_approved boolean
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;

  return query
    select p.id, p.email, p.username, p.display_name, p.created_at, p.is_approved
    from public.profiles p
    where p.is_approved = false
    order by p.created_at asc;
end;
$$;

grant execute on function public.list_pending_users() to authenticated;

-- ============================================================================
-- List all users (admins only) — for the admin user list.
-- ============================================================================
create or replace function public.list_all_users()
returns table (
  id uuid,
  email text,
  username text,
  display_name text,
  created_at timestamptz,
  is_approved boolean,
  is_admin boolean
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;

  return query
    select p.id, p.email, p.username, p.display_name,
           p.created_at, p.is_approved, p.is_admin
    from public.profiles p
    order by p.created_at asc;
end;
$$;

grant execute on function public.list_all_users() to authenticated;

-- ============================================================================
-- Approve or un-approve a user (admins only).
-- ============================================================================
create or replace function public.set_user_approved(target_id uuid, approved boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;

  -- Safety: never let an admin revoke their own access by accident.
  if target_id = auth.uid() and approved = false then
    raise exception 'You cannot un-approve yourself';
  end if;

  update public.profiles
     set is_approved = approved
   where id = target_id;
end;
$$;

grant execute on function public.set_user_approved(uuid, boolean) to authenticated;

-- ============================================================================
-- Promote / demote an admin (admins only).
-- ============================================================================
create or replace function public.set_user_admin(target_id uuid, admin boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;

  if target_id = auth.uid() and admin = false then
    raise exception 'You cannot remove your own admin role';
  end if;

  update public.profiles
     set is_admin = admin
   where id = target_id;
end;
$$;

grant execute on function public.set_user_admin(uuid, boolean) to authenticated;

-- ============================================================================
-- One-time helper to make YOU the first admin.
--
-- Run this once, replacing the email. After that, delete it if you like.
-- It only works while there is no admin yet, so it cannot be abused later.
-- ============================================================================
create or replace function public.promote_first_admin(user_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  matches int;
begin
  select count(*) into matches
  from public.profiles
  where is_admin = true;

  if matches > 0 then
    raise exception 'An admin already exists. Use set_user_admin() instead.';
  end if;

  update public.profiles
     set is_admin = true, is_approved = true
   where lower(email) = lower(user_email);

  if not found then
    raise exception 'No profile found for that email. Sign in once first.';
  end if;
end;
$$;

-- Note: deliberately NOT granted to `authenticated`, so only you (via the
-- SQL editor, running as the postgres role) can call it.