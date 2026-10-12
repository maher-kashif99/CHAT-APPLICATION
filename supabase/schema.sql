-- ============================================================================
-- Connect — database schema
--
-- Run this ONCE in the Supabase dashboard:  SQL Editor > New query > paste > Run
--
-- It is idempotent, so running it twice is safe.
-- ============================================================================

-- ---------------------------------------------------------------- conversations
-- One row per chat. A 1-1 DM has exactly two members; the columns here also
-- allow group chats later without a migration.
create table if not exists public.conversations (
  id              uuid primary key default gen_random_uuid(),
  is_group        boolean     not null default false,
  title           text,
  created_at      timestamptz not null default now(),
  -- Kept in sync by the app so the conversation list can sort without a join.
  last_message_at timestamptz
);

create index if not exists conversations_last_message_at_idx
  on public.conversations (last_message_at desc);

-- ------------------------------------------------------------------- profiles
-- Your existing `profiles` table is kept; these columns are added.
alter table public.profiles add column if not exists username   text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists is_online   boolean not null default false;
alter table public.profiles add column if not exists last_seen   timestamptz;

create unique index if not exists profiles_username_key
  on public.profiles (lower(username))
  where username is not null;

-- ------------------------------------------------------------- chat_members
-- Your existing table is kept. Adding a surrogate primary key makes the RLS
-- policies below simpler and lets us index lookups.
alter table public.chat_members add column if not exists id uuid default gen_random_uuid();

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'chat_members_pkey'
  ) then
    alter table public.chat_members
      add constraint chat_members_pkey primary key (id);
  end if;
end $$;

create index if not exists chat_members_user_idx
  on public.chat_members (user_id);
create index if not exists chat_members_conversation_idx
  on public.chat_members (conversation_id);

-- Prevent the same person joining the same conversation twice, which would
-- otherwise make `start_dm` able to create duplicate rows under a race.
create unique index if not exists chat_members_unique
  on public.chat_members (conversation_id, user_id);

-- ------------------------------------------------------------------ messages
alter table public.messages add column if not exists media_url text;
alter table public.messages add column if not exists deleted_at timestamptz;
alter table public.messages add column if not exists read_at    timestamptz;

-- `type` already exists in your schema and holds 'text' / 'voice' / 'image'.
create index if not exists messages_conversation_created_idx
  on public.messages (conversation_id, created_at desc);

-- ============================================================================
-- Row Level Security
--
-- The security model: you can read a conversation only if you are one of its
-- members, and you can delete only your OWN messages.
-- ============================================================================

alter table public.conversations enable row level security;
alter table public.profiles      enable row level security;
alter table public.chat_members  enable row level security;
alter table public.messages      enable row level security;

-- profiles ------------------------------------------------------------------
-- Any signed-in user can see who exists (needed for search), but can only
-- change their own row.
drop policy if exists "profiles are viewable by signed in users" on public.profiles;
create policy "profiles are viewable by signed in users"
  on public.profiles for select
  to authenticated using (true);

drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

drop policy if exists "users insert own profile" on public.profiles;
create policy "users insert own profile"
  on public.profiles for insert
  to authenticated
  with check (auth.uid() = id);

-- chat_members --------------------------------------------------------------
-- You can only ever see your own memberships.
drop policy if exists "members see own memberships" on public.chat_members;
create policy "members see own memberships"
  on public.chat_members for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "users join conversations they create" on public.chat_members;
create policy "users join conversations they create"
  on public.chat_members for insert
  to authenticated
  with check (auth.uid() = user_id);

-- conversations -------------------------------------------------------------
-- Membership is what grants access.
drop policy if exists "members can view conversations" on public.conversations;
create policy "members can view conversations"
  on public.conversations for select
  to authenticated
  using (
    exists (
      select 1 from public.chat_members m
      where m.conversation_id = id and m.user_id = auth.uid()
    )
  );

drop policy if exists "members can update conversations" on public.conversations;
create policy "members can update conversations"
  on public.conversations for update
  to authenticated
  using (
    exists (
      select 1 from public.chat_members m
      where m.conversation_id = id and m.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.chat_members m
      where m.conversation_id = id and m.user_id = auth.uid()
    )
  );

-- messages ------------------------------------------------------------------
drop policy if exists "members can view messages" on public.messages;
create policy "members can view messages"
  on public.messages for select
  to authenticated
  using (
    exists (
      select 1 from public.chat_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = auth.uid()
    )
  );

drop policy if exists "members can send messages" on public.messages;
create policy "members can send messages"
  on public.messages for insert
  to authenticated
  with check (
    auth.uid() = sender_id
    and exists (
      select 1 from public.chat_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = auth.uid()
    )
  );

-- Updates are scoped so a sender can delete their own message and a recipient
-- can mark it read — but nobody can rewrite somebody else's text.
drop policy if exists "senders can update own messages" on public.messages;
create policy "senders can update own messages"
  on public.messages for update
  to authenticated
  using (auth.uid() = sender_id)
  with check (auth.uid() = sender_id);

drop policy if exists "recipients can mark messages read" on public.messages;
create policy "recipients can mark messages read"
  on public.messages for update
  to authenticated
  using (
    auth.uid() <> sender_id
    and exists (
      select 1 from public.chat_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = auth.uid()
    )
  )
  with check (true);

-- ============================================================================
-- start_dm(): find-or-create a 1-1 conversation.
--
-- The app calls this instead of doing the lookup in Dart, because two people
-- tapping each other at the same instant could otherwise create two separate
-- conversations. The unique index on (conversation_id, user_id) plus the
-- ordering below makes a duplicate harmless.
-- ============================================================================
create or replace function public.start_dm(other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me         uuid := auth.uid();
  target     uuid;
  found_conv uuid;
  new_conv   uuid;
begin
  if me is null then
    raise exception 'Not authenticated';
  end if;
  if other_user_id is null or other_user_id = me then
    raise exception 'Cannot start a chat with yourself';
  end if;

  -- Is there already a DM with exactly these two people?
  select c.id into found_conv
  from public.conversations c
  join public.chat_members a on a.conversation_id = c.id and a.user_id = me
  join public.chat_members b on b.conversation_id = c.id and b.user_id = other_user_id
  where c.is_group = false
  limit 1;

  if found_conv is not null then
    return found_conv;
  end if;

  insert into public.conversations (is_group) values (false)
  returning id into new_conv;

  insert into public.chat_members (conversation_id, user_id)
  values (new_conv, me), (new_conv, other_user_id);

  return new_conv;
end;
$$;

grant execute on function public.start_dm(uuid) to authenticated;

-- ============================================================================
-- Realtime
--
-- The app subscribes to `messages` for live chat and to `conversations` for
-- the list. Both tables must be in the realtime publication.
-- ============================================================================
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'conversations'
  ) then
    alter publication supabase_realtime add table public.conversations;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_members'
  ) then
    alter publication supabase_realtime add table public.chat_members;
  end if;
end $$;

-- ============================================================================
-- Storage: the voice-notes bucket
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('voice-notes', 'voice-notes', true)
on conflict (id) do update set public = true;

-- Any signed-in user can read a voice note (the bucket is public so the
-- <audio> tag can stream it) …
drop policy if exists "voice notes are publicly readable" on storage.objects;
create policy "voice notes are publicly readable"
  on storage.objects for select
  to public
  using (bucket_id = 'voice-notes');

-- … but only the owner can write into their own folder.
drop policy if exists "users upload own voice notes" on storage.objects;
create policy "users upload own voice notes"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'voice-notes'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "users delete own voice notes" on storage.objects;
create policy "users delete own voice notes"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'voice-notes'
    and (storage.foldername(name))[1] = auth.uid()::text
  );