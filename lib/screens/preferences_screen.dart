import 'dart:io' show Directory, FileSystemException, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../services/note_store.dart';
import '../services/preferences.dart';
import '../services/saf_note_store.dart';
import '../services/scoped_folder_service.dart';
import '../services/storage.dart';
import '../services/storage_access_service.dart';
import '../services/sync_config.dart';
import '../widgets/feedback.dart';

/// Notes folder and editor settings. Pops `true` when something was saved.
class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({
    super.key,
    required this.preferences,
    this.scopedFolderService,
  });

  final PreferencesService preferences;
  final ScopedFolderService? scopedFolderService;

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen>
    with WidgetsBindingObserver {
  PreferencesService get _prefs => widget.preferences;
  final TextEditingController _dirController = TextEditingController();
  final TextEditingController _defaultNoteController = TextEditingController();
  final _endpoint = TextEditingController();
  final _region = TextEditingController();
  final _bucket = TextEditingController();
  final _accessKey = TextEditingController();
  final _secretKey = TextEditingController();
  bool _syncEnabled = false;
  EditorMode _mode = EditorMode.raw;
  bool _viKeys = false;
  bool _loaded = false;
  // Whether the typed directory is actually usable: writable, and on
  // Android 11+ not a shared folder still missing All files access.
  bool _directoryWritable = true;
  ScopedFolder? _scopedFolder;
  final Set<String> _unsavedTreeUris = {};
  bool _scopedAccessible = true;
  int? _androidStorageApiLevel;

  ScopedFolderService get _folderPicker =>
      widget.scopedFolderService ?? const ScopedFolderService();

  bool get _canPickFolder =>
      Platform.isAndroid || widget.scopedFolderService != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dirController.dispose();
    _defaultNoteController.dispose();
    for (final controller in [
      _endpoint,
      _region,
      _bucket,
      _accessKey,
      _secretKey,
    ]) {
      controller.dispose();
    }
    // Grants picked but never saved are not kept.
    for (final uri in _unsavedTreeUris) {
      _folderPicker.release(uri);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The user may have just granted access in Settings, so re-probe rather
      // than trust what we found when the screen opened.
      _checkAccess();
    }
  }

  Future<void> _load() async {
    final directory = await _prefs.directory();
    final folder = await _prefs.scopedFolder();
    final mode = await _prefs.editorMode();
    final viKeys = await _prefs.viKeys();
    final defaultNote = await _prefs.defaultNote();
    final sync = await _prefs.syncConfig();
    final apiLevel = await StorageAccessService.storageApiLevel();
    // Closed while loading: the controllers are gone.
    if (!mounted) return;
    _dirController.text = directory;
    _scopedFolder = folder == null
        ? null
        : ScopedFolder(folder.uri, folder.name);
    _mode = mode;
    _viKeys = viKeys;
    _defaultNoteController.text = defaultNote;
    _syncEnabled = sync.enabled;
    _endpoint.text = sync.endpoint;
    _region.text = sync.region;
    _bucket.text = sync.bucket;
    _accessKey.text = sync.accessKey;
    _secretKey.text = sync.secretKey;
    _androidStorageApiLevel = apiLevel;
    await _checkAccess();
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  Future<void> _checkAccess() async {
    final folder = _scopedFolder;
    if (folder == null) {
      final path = _dirController.text;
      final writable = await _directoryUsable(path);
      // Typing re-checks on every change; only the latest answer counts.
      if (mounted && path == _dirController.text) {
        setState(() => _directoryWritable = writable);
      }
      return;
    }
    var accessible = true;
    try {
      await SafNoteStore(folder.uri, folder.name).list();
    } catch (_) {
      accessible = false;
    }
    if (mounted) setState(() => _scopedAccessible = accessible);
  }

  Future<bool> _directoryUsable(String path) async =>
      await canWriteToDirectory(path) &&
      !await StorageAccessService.needsAllFilesAccess(path);

  Future<void> _pickScopedFolder() async {
    ScopedFolder? picked;
    try {
      picked = await _folderPicker.pick();
      if (picked == null) return;
      final saved = await _prefs.scopedFolder();
      if (picked.uri != saved?.uri) _unsavedTreeUris.add(picked.uri);
      await SafNoteStore(picked.uri, picked.name).list();
      if (!mounted) return;
      setState(() {
        _scopedFolder = picked;
        _scopedAccessible = true;
      });
    } catch (e) {
      if (picked != null && _unsavedTreeUris.remove(picked.uri)) {
        await _folderPicker.release(picked.uri);
      }
      if (!mounted) return;
      showSnack(
        context,
        'Cannot use the selected folder: ${describeError(e)}',
        error: true,
      );
    }
  }

  Future<void> _requestStorageAccess() async {
    try {
      await StorageAccessService.requestStorageAccess();
      final writable = await _directoryUsable(_dirController.text);
      if (mounted) setState(() => _directoryWritable = writable);
    } on PlatformException catch (error) {
      if (!mounted) return;
      showSnack(
        context,
        error.message ?? 'Cannot open storage permissions.',
        error: true,
      );
    }
  }

  Future<void> _resetToDefault() async {
    final directory = await defaultNotesDirectory();
    if (!mounted) return;
    _dirController.text = directory;
    setState(() => _scopedFolder = null);
    await _checkAccess();
  }

  void _useDirectory(String path) {
    _dirController.text = path;
    setState(() => _scopedFolder = null);
    _checkAccess();
  }

  Future<void> _save() async {
    final sync = SyncConfig(
      enabled: _syncEnabled,
      endpoint: _endpoint.text.trim().replaceFirst(RegExp(r'/$'), ''),
      region: _region.text.trim(),
      bucket: _bucket.text.trim(),
      accessKey: _accessKey.text,
      secretKey: _secretKey.text,
    );
    if (sync.enabled && sync.error != null) {
      showSnack(context, sync.error!, error: true);
      return;
    }
    final folder = _scopedFolder;
    final directory = _dirController.text.trim();
    if (directory.isEmpty && folder == null) {
      showSnack(context, 'Enter a notes folder.', error: true);
      return;
    }
    final String defaultNote;
    try {
      final typed = _defaultNoteController.text.trim();
      defaultNote = typed.isEmpty ? kDefaultNotePath : normalizeNotePath(typed);
    } on InvalidNotePathException catch (e) {
      showSnack(context, 'Default note: ${e.message}', error: true);
      return;
    }
    final previous = await _prefs.scopedFolder();
    // The default stays "default", so it follows the platform's location.
    if (directory.isEmpty || directory == await defaultNotesDirectory()) {
      await _prefs.clearDirectory();
    } else {
      await _prefs.setDirectory(directory);
    }
    if (folder == null) {
      // Choosing a folder that does not exist yet means "start one here".
      try {
        await Directory(directory).create(recursive: true);
      } on FileSystemException {
        // The home screen reports a folder it cannot read.
      }
    }
    if (folder == null) {
      await _prefs.clearScopedFolder();
    } else {
      await _prefs.setScopedFolder(folder.uri, folder.name);
      _unsavedTreeUris.remove(folder.uri);
    }
    if (previous != null && previous.uri != folder?.uri) {
      await _folderPicker.release(previous.uri);
    }
    await _prefs.setEditorMode(_mode);
    await _prefs.setViKeys(_viKeys);
    await _prefs.setDefaultNote(defaultNote);
    await _prefs.setSyncConfig(sync);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preferences'),
        actions: [
          IconButton(
            key: const ValueKey('prefs.save'),
            tooltip: 'Save',
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_scopedFolder != null && !_scopedAccessible)
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.folder_off),
                title: const Text('Selected folder is unavailable'),
                subtitle: const Text(
                  'Access may have been revoked. Select the folder again.',
                ),
                onTap: _canPickFolder ? _pickScopedFolder : null,
              ),
            ),
          if (_scopedFolder == null && !_directoryWritable)
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.folder_off),
                title: const Text('Cannot write to this folder'),
                subtitle: Text(storageAccessWarning(_androidStorageApiLevel)),
                onTap: _androidStorageApiLevel == null
                    ? null
                    : _requestStorageAccess,
              ),
            ),
          const SizedBox(height: 8),
          const Text(
            'Notes folder:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('prefs.directory'),
            controller: _dirController,
            onChanged: (_) {
              setState(() => _scopedFolder = null);
              _checkAccess();
            },
            onSubmitted: (_) => _checkAccess(),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (Platform.isAndroid)
                    PopupMenuButton<String>(
                      tooltip: 'Common folders',
                      icon: const Icon(Icons.bolt),
                      onSelected: _useDirectory,
                      itemBuilder: (context) => [
                        for (final d in quickSwitchDirectories)
                          PopupMenuItem(value: d.path, child: Text(d.label)),
                      ],
                    ),
                  IconButton(
                    tooltip: 'Reset to default',
                    icon: const Icon(Icons.restore),
                    onPressed: _resetToDefault,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_canPickFolder) ...[
            OutlinedButton.icon(
              onPressed: _pickScopedFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(
                _scopedFolder == null
                    ? 'Choose folder with Android picker'
                    : 'Selected folder: ${_scopedFolder!.name} (change)',
              ),
            ),
            if (_scopedFolder != null)
              TextButton(
                onPressed: () => setState(() => _scopedFolder = null),
                child: const Text('Use the typed path instead'),
              ),
          ],
          const SizedBox(height: 4),
          Text(
            'Every .md and .markdown file in this folder and its subfolders '
            'shows up in the file tree. Folders starting with "." (like .git '
            'or .obsidian) are skipped.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          const Text(
            'Default note:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('prefs.default-note'),
            controller: _defaultNoteController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: kDefaultNotePath,
              suffixIcon: IconButton(
                tooltip: 'Reset to $kDefaultNotePath',
                icon: const Icon(Icons.restore),
                onPressed: () => _defaultNoteController.text = kDefaultNotePath,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The lightning bolt button (Ctrl+D) opens this note, relative '
            'to the notes folder, and creates it if it does not exist yet.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          const Text(
            'Open notes in:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          SegmentedButton<EditorMode>(
            segments: const [
              ButtonSegment(
                value: EditorMode.raw,
                label: Text('Raw'),
                icon: Icon(Icons.code),
              ),
              ButtonSegment(
                value: EditorMode.wysiwyg,
                label: Text('WYSIWYG'),
                icon: Icon(Icons.text_format),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.single),
          ),
          const SizedBox(height: 8),
          Text(
            'Both editors change the same markdown text, so switching between '
            'them never reformats a note. The editor remembers the last one '
            'you used.',
            style: theme.textTheme.bodySmall,
          ),
          // Vi's normal mode needs key presses, which an on-screen keyboard
          // does not send.
          if (theme.platform == TargetPlatform.linux) ...[
            const SizedBox(height: 16),
            SwitchListTile(
              key: const ValueKey('prefs.vi-keys'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Vi keys in the editor'),
              subtitle: const Text(
                'Notes open in normal mode: move with h j k l, edit with '
                'd, c, y and p, press i to type and Esc to stop.',
              ),
              value: _viKeys,
              onChanged: (v) => setState(() => _viKeys = v),
            ),
          ],
          const SizedBox(height: 24),
          SwitchListTile(
            key: const ValueKey('prefs.s3-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('S3 sync'),
            subtitle: const Text(
              'Sync Markdown notes when you choose Sync now in the file tree menu.',
            ),
            value: _syncEnabled,
            onChanged: (value) => setState(() => _syncEnabled = value),
          ),
          if (_syncEnabled) ...[
            for (final field in [
              ('endpoint', 'HTTPS endpoint', _endpoint),
              ('region', 'Region', _region),
              ('bucket', 'Bucket', _bucket),
              ('access-key', 'Access key', _accessKey),
              ('secret-key', 'Secret key', _secretKey),
            ]) ...[
              const SizedBox(height: 12),
              TextField(
                key: ValueKey('prefs.s3-${field.$1}'),
                controller: field.$3,
                obscureText: field.$1 == 'secret-key',
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: field.$2,
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Use the same bucket on every device. Independent edits merge; '
              'overlapping edits become -sync-conflict.md notes. '
              'Sync restores missing notes and does not delete them. Images stay local.',
            ),
          ],
        ],
      ),
    );
  }
}
