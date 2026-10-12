-- ============================================================================
-- Fix: conversation list shows blank/wrong names, chats appear to be missing
--
-- Run this in the Supabase SQL Editor. Idempotent -- safe to run twice.
--
-- THE BUG
--
-- The `chat_members` select policy was:
--
--     create policy "members see own memberships"
--       on public.chat_members for select to authenticated
--       using (auth.uid() = user_id);
--
-- That lets a user see ONLY their own membership row. That is fine for
-- "which conversations am I in?", but the app also needs to know WHO ELSE is
-- in each conversation, in order to show an avatar and a name in the chat
-- list. That query comes back with a single row -- the caller's own -- so
-- `otherUser` resolves to null and every conversation renders with the
-- fallback title "Chat".
--
-- The fix is to allow a user to see the membership rows of any conversation
-- they are themselves a member of. This leaks only the fact that a specific
-- user is in a specific conversation, to another member of that same
-- conversation -- which is inherent to a 1-1 chat and not sensitive.
--
-- NOTE: `messages` and `conversations` policies are also re-asserted here
-- because they depend on `chat_members` and were fixed in separate files.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Helper: is the caller a member of this conversation?
--
-- SECURITY DEFINER so the policy below can query `chat_members` without
-- recursing into the policy that is currently being evaluated (RLS policies
-- that reference their own table infinitely recurse otherwise).
-- ---------------------------------------------------------------------------
create or replace function public.is_conversation_member(conv_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.chat_members m
    where m.conversation_id = conv_id
      and m.user_id = auth.uid()
  );
$$;

grant execute on function public.is_conversation_member(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- chat_members: see your own rows, plus the other members of conversations
-- you are already in.
-- ---------------------------------------------------------------------------
drop policy if exists "members see own memberships" on public.chat_members;
create policy "members see own memberships"
  on public.chat_members for select
  to authenticated
  using (
    auth.uid() = user_id
    or public.is_conversation_member(chat_members.conversation_id)
  );

drop policy if exists "users join conversations they create" on public.chat_members;
create policy "users join conversations they create"
  on public.chat_members for insert
  to authenticated
  with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- conversations: `conversations.id` MUST be qualified. Unqualified `id`
-- resolves to the inner `chat_members` scope and silently never matches.
-- ---------------------------------------------------------------------------
drop policy if exists "members can view conversations" on public.conversations;
create policy "members can view conversations"
  on public.conversations for select
  to authenticated
  using (public.is_conversation_member(conversations.id));

drop policy if exists "members can update conversations" on public.conversations;
create policy "members can update conversations"
  on public.conversations for update
  to authenticated
  using (public.is_conversation_member(conversations.id))
  with check (public.is_conversation_member(conversations.id));

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------
drop policy if exists "members can view messages" on public.messages;
create policy "members can view messages"
  on public.messages for select
  to authenticated
  using (public.is_conversation_member(messages.conversation_id));

drop policy if exists "members can send messages" on public.messages;
create policy "members can send messages"
  on public.messages for insert
  to authenticated
  with check (
    auth.uid() = sender_id
    and public.is_conversation_member(messages.conversation_id)
  );

-- ---------------------------------------------------------------------------
-- Realtime publication.
--
-- Without this the app subscribes successfully but receives ZERO events:
-- no live messages, no notifications, no incoming calls. This is the single
-- most common cause of "chat works but never updates".
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'conversations'
  ) then
    alter publication supabase_realtime add table public.conversations;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_members'
  ) then
    alter publication supabase_realtime add table public.chat_members;
  end if;
end $$;