import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config.dart';
import '../core/supabase_client.dart';

/// Uploads voice notes to Supabase Storage and returns a playable URL.
///
/// Paths are namespaced per user so the storage RLS policy can enforce
/// "you may only read your own folder".
class StorageService {
  StorageService._();
  static final instance = StorageService._();

  String _pathFor(String userId, String extension) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return '$userId/$stamp.$extension';
  }

  /// Uploads [file] and returns its public URL.
  Future<String> uploadVoiceNote({
    required String userId,
    required File file,
  }) async {
    final path = _pathFor(userId, file.path.split('.').last);
    final bytes = await file.readAsBytes();

    await supabase.storage.from(AppConfig.voiceBucket).uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: const FileOptions(
            upsert: false,
            contentType: 'audio/mp4',
          ),
        );

    // getPublicUrl is synchronous and returns the URL directly.
    return supabase.storage.from(AppConfig.voiceBucket).getPublicUrl(path);
  }

  /// Best-effort cleanup so a cancelled send doesn't leave an orphan file.
  Future<void> deleteVoiceNote(String url) async {
    try {
      final marker = '/object/public/${AppConfig.voiceBucket}/';
      final i = url.indexOf(marker);
      if (i < 0) return;
      final path = url.substring(i + marker.length);
      await supabase.storage.from(AppConfig.voiceBucket).remove([path]);
    } catch (_) {
      // Non-fatal.
    }
  }

  /// Creates a temp path to record into (record needs a real file path).
  Future<File> newRecordingFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
    return f;
  }
}