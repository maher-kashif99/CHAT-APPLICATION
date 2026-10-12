import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

/// Single shared handle on the Supabase client.
SupabaseClient get supabase => Supabase.instance.client;

/// The signed-in user's id, or null when signed out.
String? get currentUserId => supabase.auth.currentUser?.id;

/// Convenience for "did this row belong to me?".
bool isMine(String? ownerId) =>
    ownerId != null && ownerId == supabase.auth.currentUser?.id;