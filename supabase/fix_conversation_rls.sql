-- ============================================================================
-- Fix: conversations RLS policy never matches (empty conversation list)
--
-- Run this in the Supabase SQL Editor. Idempotent — safe to run twice.
--
-- ---------------------------------------------------------------------------
-- THE BUG
--
-- The policy reads:
--
--     exists (
--       select 1 from public.chat_members m
--       where m.conversation_id = id and m.user_id = auth.uid()
--     )
--
-- `id` is unqualified. Inside a subquery, SQL resolves an unqualified column
-- to the INNERMOST scope first, so Postgres reads it as `chat_members.id` —
-- not `conversations.id`. The condition became:
--
--     m.conversation_id = m.id
--
-- Those are unrelated values (a conversation uuid vs. a membership uuid), so
-- the policy was always false. Effect: nobody could ever SELECT a
-- conversation, so the conversation list stayed empty forever, even though
-- starting a chat still worked (that runs as a security-definer function,
-- which bypasses RLS).
--
-- The fix is to qualify the column: `conversations.id`.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- SELECT
-- ---------------------------------------------------------------------------
drop policy if exists "members can view conversations" on public.conversations;
create policy "members can view conversations"
  on public.conversations for select
  to authenticated
  using (
    exists (
      select 1
      from public.chat_members m
      where m.conversation_id = conversations.id
        and m.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- UPDATE — same unqualified `id`, same bug.
-- ---------------------------------------------------------------------------
drop policy if exists "members can update conversations" on public.conversations;
create policy "members can update conversations"
  on public.conversations for update
  to authenticated
  using (
    exists (
      select 1
      from public.chat_members m
      where m.conversation_id = conversations.id
        and m.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.chat_members m
      where m.conversation_id = conversations.id
        and m.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- Audit: catch any OTHER policy with the same unqualified-column mistake.
-- Run this after applying the fix. Expect zero rows.
-- ---------------------------------------------------------------------------
do $$
declare
  bad record;
begin
  for bad in
    select pol.polname as policy_name,
           cls.relname as table_name
    from pg_policy pol
    join pg_class cls on cls.oid = pol.polrelid
    where pol.polqual is not null
      and cls.relname in ('conversations', 'messages', 'chat_members', 'profiles')
      -- a bare `= id` (not `= conversations.id`, `= messages.id`, ...)
      and pol.polqual::text ~ '=\s*id\b'
      and pol.polqual::text !~ '\w+\.id'
  loop
    raise notice 'REVIEW: policy % on % may have an unqualified id reference', bad.policy_name, bad.table_name;
  end loop;

  raise notice 'Audit complete.';
end $$;