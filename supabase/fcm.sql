-- ============================================================================
-- Push notification plumbing (FCM)
--
-- Run this in the Supabase SQL Editor. Idempotent -- safe to run twice.
--
-- WHY THIS IS NEEDED
--
-- Supabase Realtime only works while the app is RUNNING. When the app is closed,
-- Firebase Cloud Messaging (FCM) push notifications wake the app and deliver
-- notifications for messages and incoming calls.
-- ============================================================================

-- 1. Ensure fcm_token column exists on profiles
alter table public.profiles add column if not exists fcm_token text;

-- Index for FCM token lookup
create index if not exists profiles_fcm_token_idx
  on public.profiles (fcm_token)
  where fcm_token is not null;

-- Ensure signed in users can save their own FCM token
drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- ============================================================================
-- Server-Side Database Triggers (Optional / Recommended)
--
-- Note: The app also invokes `send-push` directly from Dart when sending
-- messages or initiating calls. The triggers below provide server-side
-- redundancy using the pg_net extension if enabled.
-- ============================================================================

-- Enable pg_net extension for async HTTP requests
create extension if not exists pg_net with schema extensions;

-- Function to send push notification on new message
create or replace function public.notify_message_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
  sender_name text;
begin
  select coalesce(nullif(display_name, ''), username, 'Someone') into sender_name
  from public.profiles where id = NEW.sender_id;

  for rec in
    select user_id from public.chat_members
    where conversation_id = NEW.conversation_id and user_id <> NEW.sender_id
  loop
    perform net.http_post(
      url := current_setting('app.settings.supabase_url', true) || '/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true)
      ),
      body := jsonb_build_object(
        'user_id', rec.user_id,
        'title', sender_name,
        'body', coalesce(NEW.body, 'Sent a media message'),
        'data', jsonb_build_object(
          'conversation_id', NEW.conversation_id,
          'sender_id', NEW.sender_id,
          'message_id', NEW.id,
          'type', 'message'
        )
      )
    );
  end loop;

  return NEW;
exception when others then
  return NEW;
end;
$$;

drop trigger if exists on_message_push on public.messages;
create trigger on_message_push
  after insert on public.messages
  for each row execute function public.notify_message_push();

-- Function to send push notification on new call
create or replace function public.notify_call_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_name text;
begin
  select coalesce(nullif(display_name, ''), username, 'Someone') into caller_name
  from public.profiles where id = NEW.caller_id;

  perform net.http_post(
    url := current_setting('app.settings.supabase_url', true) || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true)
    ),
    body := jsonb_build_object(
      'user_id', NEW.callee_id,
      'title', case when NEW.media = 'video' then 'Incoming video call' else 'Incoming voice call' end,
      'body', caller_name || ' is calling you',
      'data', jsonb_build_object(
        'conversation_id', NEW.conversation_id,
        'caller_id', NEW.caller_id,
        'call_id', NEW.id,
        'type', case when NEW.media = 'video' then 'video_call' else 'voice_call' end
      )
    )
  );

  return NEW;
exception when others then
  return NEW;
end;
$$;

drop trigger if exists on_call_push on public.calls;
create trigger on_call_push
  after insert on public.calls
  for each row execute function public.notify_call_push();
