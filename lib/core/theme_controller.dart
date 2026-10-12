import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's light/dark/system preference and republishes it.
///
/// Exposed through [of] so settings can read the current mode without
/// needing the instance passed down.
class ThemeController extends ChangeNotifier {
  static const _key = 'theme_mode';

  /// Nearest controller in the tree.
  static ThemeController of(BuildContext context) {
    final c = context.dependOnInheritedWidgetOfExactType<_ThemeScope>();
    assert(c != null, 'ThemeController.of() called outside the app scope');
    return c!.notifier!;
  }

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  ThemeController._();

  static Future<ThemeController> load() async {
    final c = ThemeController._();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      c._mode = _fromString(raw);
    } catch (_) {
      c._mode = ThemeMode.system;
    }
    return c;
  }

  static ThemeMode _fromString(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, mode.name);
    } catch (_) {
      // Preference write failed; the in-memory value still applies this session.
    }
  }

  String get label {
    switch (_mode) {
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.system:
        return 'System';
    }
  }
}

/// Makes the controller available to descendant widgets.
class _ThemeScope extends InheritedNotifier<ThemeController> {
  const _ThemeScope({super.key, required super.notifier, required super.child});

  @override
  bool updateShouldNotify(_ThemeScope old) => notifier != old.notifier;
}

/// Installs a [ThemeController] into the tree.
class ThemeScope extends StatelessWidget {
  final ThemeController controller;
  final Widget child;

  const ThemeScope({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) =>
      _ThemeScope(notifier: controller, child: child);
}