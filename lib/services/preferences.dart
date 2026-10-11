import 'package:shared_preferences/shared_preferences.dart';

import 'storage.dart';
import 'sync_config.dart';

const _kDirectory = 'Directory';
const _kScopedTreeUri = 'ScopedTreeUri';
const _kScopedTreeName = 'ScopedTreeName';
const _kEditorMode = 'EditorMode';
const _kDefaultNote = 'DefaultNote';
const _kPinned = 'PinnedNotes';
const _kRecent = 'RecentNotes';
const _kViKeys = 'ViKeys';

/// How many recently opened notes are remembered.
const kRecentLimit = 20;

/// The note the lightning bolt button opens unless Preferences names another.
const kDefaultNotePath = 'TurboNote.md';

/// Which editor a note opens in.
enum EditorMode {
  /// Plain text: the markdown source exactly as it is on disk.
  raw,

  /// Rendered, editable markdown (headings, lists, bold... as you type).
  wysiwyg;

  static EditorMode parse(String? raw) =>
      raw == 'wysiwyg' ? EditorMode.wysiwyg : EditorMode.raw;
}

class PreferencesService {
  Future<SyncConfig> syncConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return SyncConfig(
      enabled: prefs.getBool('S3SyncEnabled') ?? false,
      endpoint:
          prefs.getString('S3Endpoint') ?? 'https://garage.f3s.buetow.org',
      region: prefs.getString('S3Region') ?? 'garage',
      bucket: prefs.getString('S3Bucket') ?? 'turbonotes',
      accessKey: prefs.getString('S3AccessKey') ?? '',
      secretKey: prefs.getString('S3SecretKey') ?? '',
    );
  }

  Future<void> setSyncConfig(SyncConfig config) async {
    final error = config.error;
    if (config.enabled && error != null) throw FormatException(error);
    final prefs = await SharedPreferences.getInstance();
    // Enable last, so incomplete first-time settings never enable sync.
    await prefs.setBool('S3SyncEnabled', false);
    await prefs.setString('S3Endpoint', config.endpoint);
    await prefs.setString('S3Region', config.region);
    await prefs.setString('S3Bucket', config.bucket);
    await prefs.setString('S3AccessKey', config.accessKey);
    await prefs.setString('S3SecretKey', config.secretKey);
    await prefs.setBool('S3SyncEnabled', config.enabled);
  }

  Future<String> directory() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kDirectory);
    if (stored != null && stored.isNotEmpty) return stored;
    return defaultNotesDirectory();
  }

  /// The directory exactly as stored, or null while the default applies.
  Future<String?> storedDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kDirectory);
    return stored == null || stored.isEmpty ? null : stored;
  }

  Future<void> setDirectory(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDirectory, value);
  }

  /// Forget the chosen directory so [directory] falls back to the default.
  Future<void> clearDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDirectory);
  }

  /// An Android folder picked with the system picker, or null when the
  /// typed [directory] is in use.
  Future<({String uri, String name})?> scopedFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final uri = prefs.getString(_kScopedTreeUri);
    if (uri == null || uri.isEmpty) return null;
    return (
      uri: uri,
      name: prefs.getString(_kScopedTreeName) ?? 'Selected folder',
    );
  }

  Future<void> setScopedFolder(String uri, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kScopedTreeUri, uri);
    await prefs.setString(_kScopedTreeName, name);
  }

  Future<void> clearScopedFolder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kScopedTreeUri);
    await prefs.remove(_kScopedTreeName);
  }

  Future<EditorMode> editorMode() async {
    final prefs = await SharedPreferences.getInstance();
    return EditorMode.parse(prefs.getString(_kEditorMode));
  }

  Future<void> setEditorMode(EditorMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEditorMode, mode.name);
  }

  /// Whether the editor uses vi's modal keys (normal, insert, visual).
  Future<bool> viKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kViKeys) ?? false;
  }

  Future<void> setViKeys(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kViKeys, value);
  }

  /// The note the lightning bolt button opens, relative to the notes folder.
  Future<String> defaultNote() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kDefaultNote);
    return stored == null || stored.isEmpty ? kDefaultNotePath : stored;
  }

  Future<void> setDefaultNote(String path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == kDefaultNotePath) {
      await prefs.remove(_kDefaultNote);
    } else {
      await prefs.setString(_kDefaultNote, path);
    }
  }

  /// Pinned notes, in the order they were pinned.
  Future<List<String>> pinned() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kPinned) ?? const [];
  }

  Future<void> setPinned(List<String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPinned, paths);
  }

  /// Recently opened notes, most recent first.
  Future<List<String>> recent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kRecent) ?? const [];
  }

  Future<void> setRecent(List<String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kRecent, paths.take(kRecentLimit).toList());
  }
}
