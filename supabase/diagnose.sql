-- ============================================================================
-- DIAGNOSTIC ONLY — this script changes nothing.
--
-- Paste this into the Supabase SQL Editor and Run. Then read the Results tab
-- and send me a screenshot (or the numbers).
--
-- Purpose: the earlier check showed a table called `chat-conversations`, but a
-- later query said it does not exist. These queries settle what is really
-- there, including relations a plain table listing can miss (views,
-- partitioned tables, case differences).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- QUERY 1 — every relation in the public schema, with its exact name.
--
-- The `quote_ident` column shows the name as you would have to write it,
-- which reveals invisible characters or unusual capitalisation.
-- ---------------------------------------------------------------------------
select
  quote_ident(c.relname) as exact_name,
  c.relname             as plain_name,
  c.relkind             as kind,          -- r=table, v=view, p=partitioned, f=foreign
  pg_size_pretty(pg_total_relation_size(c.oid)) as size
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind in ('r','v','p','f','m')
order by c.relname;

-- ---------------------------------------------------------------------------
-- QUERY 2 — exact name of the tables the app depends on.
-- ---------------------------------------------------------------------------
select to_regclass('public.conversations')            as new_conversations,
       to_regclass('public."chat-conversations"')     as old_conversations,
       to_regclass('public.messages')                 as messages,
       to_regclass('public.chat_members')             as chat_members;

-- ---------------------------------------------------------------------------
-- QUERY 3 — resolve the FK targets by OID.
--
-- If `target_name` comes back NULL, the constraint points at a relation that
-- no longer exists — a dangling reference, which is why the earlier error said
-- the table was missing.
-- ---------------------------------------------------------------------------
select
  con.conname                                as constraint_name,
  src.relname                                as on_table,
  con.confrelid                              as target_oid,
  tgt.relname                                as target_name,
  tgt_ns.nspname                             as target_schema
from pg_constraint con
join pg_class src       on src.oid = con.conrelid
left join pg_class tgt       on tgt.oid = con.confrelid
left join pg_namespace tgt_ns on tgt_ns.oid = tgt.relnamespace
where con.contype = 'f'
  and con.conrelid in (
    select oid from pg_class
    where relname in ('chat_members', 'messages')
  )
order by con.conname;

-- ---------------------------------------------------------------------------
-- QUERY 4 — row counts, so we know what data exists.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.profiles)            as profiles,
  (select count(*) from public.conversations)       as conversations,
  (select count(*) from public.messages)            as messages,
  (select count(*) from public.chat_members)        as chat_members;

-- ---------------------------------------------------------------------------
-- QUERY 5 — do any messages point at a conversation that is not in
-- public.conversations? Those are the rows the app cannot display.
-- ---------------------------------------------------------------------------
select count(*) as orphaned_messages
from public.messages m
where not exists (
  select 1 from public.conversations c where c.id = m.conversation_id
);