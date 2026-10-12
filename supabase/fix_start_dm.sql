-- ============================================================================
-- Migrate conversation FKs -> public.conversations
--
-- Run this in the Supabase SQL Editor. Idempotent — safe to run twice.
--
-- ---------------------------------------------------------------------------
-- THE SITUATION
--
-- Two foreign keys reference the old conversation table:
--
--     chat_members.conversation_id  ->  "chat-conversations"
--     messages.conversation_id      ->  "chat-conversations"
--
-- The app now uses public.conversations. Until the FKs are re-pointed, starting
-- a chat fails and old message history is invisible.
--
-- Earlier diagnostics showed the old table as `chat-conversations`, but a later
-- run reported it missing. Rather than assume which is true, this script checks
-- at runtime and adapts: if the old table exists it copies the conversations
-- across first, and if it does not, it skips straight to re-pointing the FKs.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- STEP 1 — Copy old conversations across, but only if the old table exists.
-- ---------------------------------------------------------------------------
do $$
declare
  v_exists boolean;
  v_copied int;
begin
  select to_regclass('public."chat-conversations"') is not null into v_exists;

  if not v_exists then
    raise notice 'Old table chat-conversations not present — nothing to migrate.';
    return;
  end if;

  insert into public.conversations (id, created_at)
  select
    old.id,
    coalesce(
      case
        when old.j ->> 'created_at' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
        then (old.j ->> 'created_at')::timestamptz
      end,
      now()
    )
  from (
    select to_jsonb(cc) as j, cc.id as id
    from public."chat-conversations" cc
  ) old
  on conflict (id) do nothing;

  get diagnostics v_copied = row_count;
  raise notice 'Copied % conversation(s) from chat-conversations.', v_copied;
end $$;

-- ---------------------------------------------------------------------------
-- STEP 2 — Report current state, before changing any constraint.
-- ---------------------------------------------------------------------------
do $$
declare
  v_conv   int;
  v_msg    int;
  v_mem    int;
  v_badmsg int;
begin
  select count(*) into v_conv from public.conversations;
  select count(*) into v_msg  from public.messages;
  select count(*) into v_mem  from public.chat_members;
  select count(*) into v_badmsg
    from public.messages m
   where not exists (select 1 from public.conversations c where c.id = m.conversation_id);

  raise notice 'conversations      : %', v_conv;
  raise notice 'messages           : %', v_msg;
  raise notice 'chat_members       : %', v_mem;
  raise notice 'orphaned messages  : %', v_badmsg;
end $$;

-- ---------------------------------------------------------------------------
-- STEP 3 — Drop both foreign keys.
--
-- Unconditional. If the old table is gone these constraints are dangling
-- references, and dropping them is the only way forward.
-- ---------------------------------------------------------------------------
alter table public.messages
  drop constraint if exists messages_conversation_id_fkey;

alter table public.chat_members
  drop constraint if exists chat_members_conversation_id_fkey;

-- ---------------------------------------------------------------------------
-- STEP 4 — Remove chat_members links that point at nothing.
--
-- These are unusable by the app and are recreated the moment someone starts a
-- new chat. Messages are NOT touched.
-- ---------------------------------------------------------------------------
delete from public.chat_members cm
where not exists (
  select 1 from public.conversations c where c.id = cm.conversation_id
);

-- ---------------------------------------------------------------------------
-- STEP 5 — Re-add both FKs against public.conversations.
--
-- NOT VALID means existing rows are not re-checked, so orphaned history cannot
-- block this. New inserts and updates are still fully enforced.
-- ---------------------------------------------------------------------------
alter table public.messages
  add constraint messages_conversation_id_fkey
  foreign key (conversation_id)
  references public.conversations(id)
  on delete cascade
  not valid;

alter table public.chat_members
  add constraint chat_members_conversation_id_fkey
  foreign key (conversation_id)
  references public.conversations(id)
  on delete cascade
  not valid;

-- ---------------------------------------------------------------------------
-- STEP 6 — Recreate start_dm with clear error messages.
-- ---------------------------------------------------------------------------
create or replace function public.start_dm(other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me         uuid := auth.uid();
  found_conv uuid;
  new_conv   uuid;
begin
  if me is null then
    raise exception 'Not authenticated';
  end if;
  if other_user_id is null then
    raise exception 'No user supplied';
  end if;
  if other_user_id = me then
    raise exception 'Cannot start a chat with yourself';
  end if;

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

  if new_conv is null then
    raise exception 'Could not create conversation row';
  end if;

  insert into public.chat_members (conversation_id, user_id)
  values (new_conv, me), (new_conv, other_user_id);

  return new_conv;
end;
$$;

grant execute on function public.start_dm(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- STEP 7 — Report the final state.
-- ---------------------------------------------------------------------------
do $$
declare
  v_badmsg int;
begin
  select count(*) into v_badmsg
    from public.messages m
   where not exists (select 1 from public.conversations c where c.id = m.conversation_id);

  if v_badmsg = 0 then
    raise notice 'DONE — no orphaned messages, all history is reachable.';
  else
    raise notice 'DONE — % message(s) reference a conversation that no longer exists.', v_badmsg;
    raise notice 'They are retained but hidden. To keep history, recreate those conversations:';
    raise notice '  insert into public.conversations (id) select distinct conversation_id from public.messages m';
    raise notice '  where not exists (select 1 from public.conversations c where c.id = m.conversation_id);';
  end if;
end $$;