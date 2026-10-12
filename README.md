# Connect

A multi-user chat app for Android — text, voice notes, and peer-to-peer voice
and video calling. Built with Flutter + Supabase.

---

## What changed from the old app

The previous version was a single `lib/main.dart` that hardcoded you to **one**
other person (`chat_members.select(...).limit(1)`). This version is a proper
multi-user app:

| Area | Before | Now |
|---|---|---|
| Conversations | One hardcoded chat | Full list, created on demand |
| Finding people | Manual dashboard insert | Search by username / name / email |
| Deleting | Not possible | Soft delete, both sides see it |
| Voice notes | Planned only | Record, upload, play, with a live meter |
| Calling | None | WebRTC voice + video, peer-to-peer |
| Notifications | None | System notifications, tap opens the chat |
| Theming | Light only | Light / dark / system, remembered |
| Access control | Open | Admin approves new users; admin role |

---

## Setup — run these in order

**Every step is required.** Running them out of order produces the confusing
errors described in Troubleshooting.

| # | File / action | Why |
|---|---|---|
| 1 | `supabase/schema.sql` | Tables, columns, RLS, `start_dm()`, storage bucket |
| 2 | `supabase/admin.sql` | Adds `is_admin` / `is_approved` and the admin functions |
| 3 | `select promote_first_admin('you@email');` | Makes you the first admin (needs step 2 done) |
| 4 | `supabase/admin_fix.sql` | New accounts default to un-approved; blocks self-promotion |
| 5 | `supabase/fix_start_dm.sql` | Re-points FKs from old `chat-conversations` to `conversations` |
| 6 | `supabase/fix_conversation_rls.sql` | Fixes the policy that hid every conversation |
| 7 | `supabase/admin_delete_user.sql` | Delete-user button |
| 8 | `supabase/calls.sql` | Calls RLS, status machine, **realtime publication** |
| 9 | Dashboard → **Authentication → URL Configuration** | Add `connectapp://login-callback` to Redirect URLs |
| 10 | `flutter pub get` then `flutter run` | — |

> `calls.sql` is what makes incoming calls work at all. Without the
> `supabase_realtime` publication entry, the app's listener never fires and no
> call can ever arrive — the phone simply never rings.

Steps 1–7 all go in the **Supabase dashboard → SQL Editor**, one at a time,
clicking **Run** each time. They are all idempotent, so re-running is safe.

Then in Android Studio / PowerShell:

```bash
flutter pub get
flutter run -d <your-device-id>
```

> **A note on the copy-paste trap.** Paste only the SQL. The `--` comment
> lines above each section are English headings — pasting those, or pasting a
> Windows file path instead of a file's contents, produces syntax errors that
> look like SQL problems.

### What each SQL file does

**`schema.sql`** — creates `conversations`, adds the `messages`/`profiles`
columns, writes all RLS policies, creates `start_dm()`, and creates the
`voice-notes` storage bucket.

**`admin.sql`** — adds `is_admin` and `is_approved` to `profiles`, plus
`list_all_users`, `list_pending_users`, `set_user_approved`,
`set_user_admin` and `promote_first_admin`. Run `promote_first_admin` after
this so you have an admin to approve others.

**`admin_fix.sql`** — repairs two defects in `admin.sql`:
1. New accounts were auto-approved (`is_approved` defaulted to `true`). The
   fix sets the default to `false`.
2. Self-promotion was possible — nothing stopped a client *inserting* its own
   profile with `is_admin: true`, because `revoke update` only covers UPDATE,
   not INSERT. The fix adds a `BEFORE INSERT/UPDATE` trigger that overwrites
   both flags server-side.

**`fix_start_dm.sql`** — re-points `chat_members.conversation_id` and
`messages.conversation_id` from your original `public."chat-conversations"`
table to `public.conversations`. Without this, starting a chat fails with an
FK violation.

**`fix_conversation_rls.sql`** — the `conversations` select policy used an
unqualified `id`, which Postgres resolved to `chat_members.id`, making the
policy always false. The conversation list stayed permanently empty. This
qualifies the column and audits for other policies with the same mistake.

**`admin_delete_user.sql`** — the delete-user function. Removes the profile
and memberships, keeps messages.

**`calls.sql`** — policies and triggers for the `calls` table: `caller_id`
defaults to `auth.uid()` (so the client can't forge it), a status machine so
terminal states absorb further writes, RLS limiting calls to their two
parties, and — critically — adds `calls` to the `supabase_realtime`
publication.

### Also required in the dashboard

**Authentication → Sign In / Providers → Email**

- For testing: turn **off** "Confirm email". Supabase's built-in email
  service allows only **2 emails per hour**, which makes creating test
  accounts nearly impossible. With confirmation off no email is sent at all.
- Before real users: turn it back on and configure **custom SMTP**
  (Authentication → Emails → SMTP Settings). Resend's free tier is enough.

**Authentication → URL Configuration**

- **Redirect URLs**: add `connectapp://login-callback`
- **Site URL**: change it off `http://localhost:3000`

Run `promote_first_admin(...)` **before** running the fix file, so the new
trigger recognises you as an admin.

### 4. Run `supabase/admin_delete_user.sql`

Adds the delete-user function used by **Admin dashboard → ⋮ → Delete user**.
It removes the person's `profiles` row and their `chat_members`
memberships, but **keeps their messages** so other people's chat history is
not destroyed.

It cannot delete the `auth.users` row — that needs the service-role key,
which must never ship inside a mobile app. For a full account removal use the
Supabase dashboard (**Authentication → Users → Delete**). Note that fails
while messages reference the user, because `messages.sender_id` is a foreign
key to `auth.users`.

**How it works**

- New accounts are **not** approved by default (`is_approved = false`). They
  see a "Waiting for approval" screen.
- **Settings → Admin dashboard** lists pending users with approve/reject and
  grant/remove-admin actions (visible only to admins).
- Approving someone flips them through immediately — no re-login needed.

> **Security.** The obvious way to add an admin flag — a boolean plus your
> existing "users update own profile" policy — is **exploitable**: that policy
> allows a user to update their own row, so anyone could run
> `update profiles set is_admin = true` and promote themselves. `admin.sql`
> therefore revokes the blanket UPDATE grant and re-grants it for only the four
> columns a user may change on themselves (`display_name`, `username`,
> `avatar_url`, `status`). `is_admin` and `is_approved` are unreachable from the
> client; every privileged change goes through `security definer` functions that
> re-check the caller's role on the server.

### 2. Fetch the packages

```bash
flutter pub get
```

### 3. Run it

```bash
flutter run
```

### 4. Test with two devices

You need **two real phones** (or one phone + one emulator for text only).
Video calling on an emulator is unreliable because the emulator's camera and
microphone do not behave like real hardware.

---

## How the features work

### Multi-user chat

`start_dm(other_user_id)` is a Postgres function that finds an existing 1-1
conversation or creates one. It runs server-side so two people tapping each
other at the same moment cannot create duplicate conversations.

### Deleting a message

Long-press your own message → **Delete**. This is a *soft* delete: the row
stays, `deleted_at` is set, and both people see "This message was deleted".
A hard delete would make the bubble vanish mid-scroll for the other person.

The RLS policy only lets a sender modify their own rows, so the client cannot
delete somebody else's message even if the check were bypassed.

### Voice notes

Tap the microphone, record, then send. Audio is uploaded to the
`voice-notes` Storage bucket under a path prefixed with your user id, so the
RLS policy lets you write only into your own folder.

### Calls

Peer-to-peer WebRTC. Supabase Realtime carries **only the signalling** — the
offer, answer and ICE candidates. Audio and video go directly between the two
phones and never touch a Supabase server.

> **Read this before blaming the code.** Calls use Google's public STUN plus
> the *free public* OpenRelay TURN servers. Those relays are unofficial and
> rate-limited, so roughly 10-20% of real-world networks (symmetric NAT,
> some mobile carriers) will fail to connect. There is no free option that
> avoids this. For reliability, deploy your own [coturn](https://github.com/coturn/coturn)
> and replace the TURN entries in `lib/services/call_service.dart`.

### Notifications

Uses `awesome_notifications`. When a message arrives while you are in a
different chat, a system notification appears; tapping it opens that chat.

> **Why not `flutter_local_notifications`?** It is the usual choice, but it
> depends on the `timezone` package, and **no version of `timezone` resolves on
> Dart 3.8** — 0.9/0.10 cap at `<3.0.0` and 0.11 requires `^3.10.0`. Your
> Flutter 3.32.4 ships Dart 3.8.1, so that plugin cannot be installed at all.
> `awesome_notifications` has no such dependency.

---

## Project layout

```
lib/
  main.dart                     app root, auth gate, approval gate, call routing
  core/
    config.dart                 Supabase URL/key
    supabase_client.dart        shared client handle
    theme.dart                  light + dark Material 3 themes
    theme_controller.dart       persists the theme choice
  models/
    models.dart                 Profile, Conversation, Message
  services/
    chat_service.dart           all database reads/writes, admin RPCs
    storage_service.dart        voice note upload/download
    notification_service.dart   system notifications
    call_service.dart           WebRTC + signalling
  screens/
    auth/       auth_screen.dart
    home/       conversation_list_screen.dart, new_chat_screen.dart,
                pending_approval_screen.dart
    chat/       chat_screen.dart
    profile/    profile_screen.dart, user_profile_screen.dart
    settings/   settings_screen.dart
    admin/      admin_screen.dart
    call/       call_screen.dart
  widgets/
    common.dart, message_bubble.dart, audio_player.dart
```

---

## Dependency versions are deliberately pinned

Flutter 3.32.4 ships Dart 3.8.1. Several current releases require newer Dart
and **will not resolve**. The versions in `pubspec.yaml` were each checked
against Dart 3.8.1. Do not casually run `flutter pub upgrade` — it will pull
in packages that need Dart 3.10+ and break the build.

| Package | Pinned | Why not newer |
|---|---|---|
| `supabase_flutter` | `2.15.4` | 2.16+ needs Dart `^3.9` |
| `record` | `6.2.1` | 7.x needs Dart `^3.12` |
| `permission_handler` | `12.0.3` | 13.x pulls `permission_handler_android` 14.x, which requires **AGP 9**; this project is on AGP 8.7.3 |

## Android SDK 36 is required

`flutter_webrtc` and `awesome_notifications` both compile against
`compileSdk 36`. `android/app/build.gradle.kts` is set to 36 for that reason.
If Gradle cannot find SDK 36, install it in Android Studio under
**SDK Manager → SDK Platforms → Android 16 (API 36)**.

The Gradle toolchain is pinned too:

| Setting | Value | Reason |
|---|---|---|
| AGP | `8.7.3` | AGP 9 plugins fail to compile their `.kts` scripts |
| Kotlin | `2.1.0` | must match AGP 8 |
| Gradle | `8.12` | required by AGP 8.7 |
| `compileSdk` | `36` | `flutter_webrtc` + `awesome_notifications` compile against it |
| `targetSdk` | `36` | matches the plugins |
| `minSdk` | `24` | `audio_session` (via `just_audio`) needs 24; `flutter_webrtc` needs 23 |
| `ndkVersion` | `27.0.12077973` | every plugin wants 27; Flutter's default is 26.3 |

> `minSdk 24` means the app will not run on Android 6 or older. That affects
> well under 1% of active devices. Do not lower it — the manifest merger will
> fail on `audio_session`.

---

## Reducing the APK size

A default `flutter build apk` produced a **104.6 MB** APK. Measured breakdown:

| Part | Size | Notes |
|---|---|---|
| `x86_64` | 33.5 MB | **emulator only** |
| `arm64-v8a` | 28.7 MB | real phones |
| `armeabi-v7a` | 21.0 MB | old 32-bit phones |
| `x86` | 12.2 MB | **emulator only** |
| everything else | 9.1 MB | resources, dex |

WebRTC's native engine (`libjingle_peerconnection_so.so`) is ~11.7 MB *per ABI*,
which is why four ABIs is so expensive.

Two changes are already applied in `android/app/build.gradle.kts`:

1. **`abiFilters += listOf("arm64-v8a")`** — drops both x86 ABIs (45.7 MB).
   If you need an x86_64 emulator, change it to `listOf("x86_64")`.
2. **`isMinifyEnabled = true` + `isShrinkResources = true`** — R8 shrinks the
   Java/Kotlin side and unused resources. Flutter already tree-shakes Dart.

That should bring it to roughly **30 MB**.

### Build commands

```bash
# Smallest APK, one ABI (~30 MB) — what you want for sideloading
flutter build apk --release --target-platform android-arm64

# Separate APKs per ABI; the phone installs the right one automatically
flutter build apk --release --split-per-abi

# Play Store — deliver per-device automatically, smallest download
flutter build appbundle --release
```

For a Play Store release, prefer `--split-per-abi` or an app bundle. A single
fat APK has to contain every ABI, because the store cannot know which device
will download it.

### If R8 breaks something at runtime

Minification is the one change here that can cause a release-only crash, because
plugins reached through JNI or reflection are invisible to the static analyser.
The keep rules in `android/app/proguard-rules.pro` cover WebRTC, Supabase,
awesome_notifications, just_audio and record. If a release build crashes while
`flutter run` (debug, unminified) is fine, the fix is to add a `-keep` rule for
the class named in the stack trace.

**Always test the release build after enabling minification** — especially
placing and answering a call, which is the most JNI-dependent code in the app.

The long-term fix is to upgrade Flutter to 3.44+ (Dart 3.10+), which
unlocks current versions of everything.

---

## Troubleshooting

**"Could not load your conversations"**
The schema was not run. Go back to step 1.

**Search returns nobody**
The other person must have signed up *and* signed in once so their
`profiles` row exists. It is created on first login. Search matches
`username`; if that column is missing the app falls back to `email`.

**"Could not start chat: ..." after tapping a search result**
The message is the server's actual reason, not a generic failure. Common ones:

| Message | Meaning |
|---|---|
| `Not authenticated` | The session expired — sign out and back in |
| `permission denied for function start_dm` | `schema.sql` was not run |
| `column ... does not exist` | `schema.sql` was only partially run — re-run it |
| `You cannot start a chat with yourself` | You tapped your own row |
| `violates foreign key constraint chat_members_conversation_id_fkey` | The FK points at the wrong table — run `supabase/fix_start_dm.sql` |

Search itself and opening the chat are separate steps: tapping a result calls
`start_dm()`, which is what can fail. If search returns the person fine but the
chat will not open, the error above is the one to act on.

**Voice notes fail to upload**
Confirm the bucket exists: dashboard → **Storage**. It should show
`voice-notes`. If not, re-run `schema.sql`.

**Voice notes and calls both fail in a release build, but text works**
This is R8 minification stripping plugin classes. Flutter tree-shakes Dart
code correctly, but the Java/Kotlin side of plugins reached through JNI or
reflection is not visible to the static analyser. The keep rules in
`android/app/proguard-rules.pro` cover `record`, `just_audio`, `audio_session`,
WebRTC, Supabase and `awesome_notifications`.

If a plugin still breaks, add a `-keep class <its package>.** { *; }` line.
The package names are in the plugin source under
`%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\<plugin>\android\src\main\`.

**Always confirm whether you are on a debug or release build.** `flutter run`
is debug (no minification) and `flutter build apk` is release (minified). A
feature working in debug but failing in release almost always means a missing
keep rule, not a bug in your Dart code.

**A call never connects**
Expected on some networks — see the TURN note above. Also confirm both phones
have the **same version** of the app; the signalling payload is not
version-tolerant.

**"Setup required" screen on launch**
`supabase/schema.sql` has not been run. See step 1 above.

**The confirmation email opens `localhost:3000` in a browser**
Two things are required:

1. **Supabase dashboard → Authentication → URL Configuration → Redirect URLs** —
   add `connectapp://login-callback`. Supabase silently ignores any
   `redirect_to` that is not on this list and falls back to the Site URL, which
   is why this step is easy to miss.
2. **The app must pass the redirect** — done via `emailRedirectTo` in
   `auth_screen.dart`, plus the `connectapp://` intent-filter in
   `AndroidManifest.xml` so Android routes the URI to the app instead of a
   browser.

Also set **Site URL** to something other than `http://localhost:3000` while you
are there, so the fallback is not a dead page.

**Notifications never appear**
Work through these in order — they are separate failure points.

1. **Settings → Send a test notification.** This is the diagnostic that
   matters. If the test notification appears, the notification layer is fine
   and the problem is *delivery* — go to step 3. If it does not, it is the
   permission or the channel — go to step 2.

2. **Permission and channel.** Android 13+ needs explicit permission. If the
   test says "Blocked by Android", enable notifications for the app in the
   Android settings. Also note that Android only reads a channel's sound and
   vibration settings **when the channel is first created** — later changes in
   the app are ignored. If you changed the channel config, uninstall and
   reinstall the app so the channel is rebuilt.

3. **Realtime delivery.** The app listens for INSERTs on `messages`, which
   only works if the table is in the realtime publication. Verify in the SQL
   editor:

   ```sql
   select tablename from pg_publication_tables
   where pubname = 'supabase_realtime';
   ```

   It must list `messages`, `calls`, `conversations` and `chat_members`. If
   `messages` is missing, no message will ever raise a notification.

4. **Battery optimisation.** If the app is put to sleep by Android, Supabase
   Realtime does not deliver the message at all, so nothing can notify.
   Exempt the app from battery optimisation in Android settings.

**Call never connects**
Expected on some networks. See the TURN note above. Test on two phones
first; if it fails on your wifi, try mobile data.

**Build fails on `desugar_jdk_libs`**
Core library desugaring is required by `flutter_webrtc` and
`awesome_notifications`. It is configured in `android/app/build.gradle.kts`;
make sure you did not replace that file.

**`uses-sdk:minSdkVersion 23 cannot be smaller than 24`**
Some plugin raised the minimum. Check which one and set `minSdk` to at least
that value. Currently `audio_session` needs 24.

**`Your project is configured with Android NDK 26.x, but plugin(s) require 27.x`**
Set `ndkVersion = "27.0.12077973"` in `android/app/build.gradle.kts`. Install
the NDK via **SDK Manager → NDK (Side by side)** if Gradle cannot find it.

---

## A note on testing in Chrome

You can run `flutter run -d chrome` to check that the UI compiles and the
theme/auth screens render, but this is **not** a valid test of the real app:

- `flutter_webrtc` uses a different implementation on web, and the ICE
  server list and permissions behave differently.
- Voice recording on web needs browser permission prompts and produces a
  different blob than the Android file path.
- The `voice-notes` Storage upload path assumes Android file I/O.

Test the real features on an Android device or emulator via Android Studio.