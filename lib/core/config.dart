/// Supabase project credentials.
///
/// The anon key is a *public* client key — it is safe to ship inside an app.
/// Your data is protected by the Row Level Security policies in the database,
/// not by hiding this key.
///
/// You can override both at build time without editing this file:
///   flutter run --dart-define=SUPABASE_URL=https://xxx.supabase.co
///               --dart-define=SUPABASE_ANON_KEY=eyJ...
class AppConfig {
  AppConfig._();

  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://venlpnwgjcgvziowwpcs.supabase.co',
  );

  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZlbmxwbndnamNndnppb3d3cGNzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2MjczNzIsImV4cCI6MjEwNzIwMzM3Mn0.gjo3aG-E5bfDXNsJdeLdTOzY9feSWxlR3Io77N5ZkBk',
  );

  /// Supabase Storage bucket that holds voice notes.
  /// Created by `supabase/schema.sql`.
  static const voiceBucket = 'voice-notes';

  /// Supabase Realtime channel used to carry WebRTC signalling.
  static const callChannelPrefix = 'call';

  /// Custom URL scheme for this app, used for the email-confirmation deep
  /// link.
  ///
  /// The confirmation email links to Supabase, which redirects to this URI.
  /// Android matches it via the `<data android:scheme="...">` intent-filter in
  /// AndroidManifest.xml, so tapping the link opens the app instead of a
  /// browser sitting on localhost:3000.
  ///
  /// Must also be added to Supabase → Authentication → URL Configuration →
  /// Redirect URLs, otherwise Supabase rejects the redirect and silently falls
  /// back to the Site URL.
  static const scheme = 'connectapp';

  /// Full redirect target for email confirmation links.
  static const emailRedirectUrl = '$scheme://login-callback';
}