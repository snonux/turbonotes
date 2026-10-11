import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../services/active_store.dart';
import '../services/app_version.dart';
import '../services/directory_note_store.dart';
import '../services/note_export.dart';
import '../services/note_index.dart';
import '../services/note_store.dart';
import '../services/note_sync.dart';
import '../services/note_tree.dart';
import '../services/preferences.dart';
import '../services/share_service.dart';
import '../services/storage_access_service.dart';
import '../services/sync_config.dart';
import '../services/sync_objects.dart';
import '../services/sync_state.dart';
import '../widgets/feedback.dart';
import '../widgets/note_dialogs.dart';
import '../widgets/note_editor.dart';
import '../widgets/note_tree_view.dart';
import 'fuzzy_finder.dart';
import 'note_page.dart';
import 'preferences_screen.dart';
import 'search_dialog.dart';

/// Window width from which the tree and the editor sit side by side.
const double kTwoPaneWidth = 760;

enum _MenuAction {
  sync,
  refresh,
  collapse,
  pin,
  share,
  rename,
  delete,
  preferences,
  about,
}

/// The notes folder as a file tree, plus the editor. On wide windows the
/// editor sits next to the tree; on phones a note opens on its own screen.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.preferences,
    this.storeFactory,
    this.shareService = const ShareService(),
    this.syncRunner,
  });

  final PreferencesService preferences;

  /// Hands notes to other apps; replaced in tests.
  final ShareService shareService;

  /// Replaces the live S3 sync in widget tests.
  final Future<SyncResult> Function(NoteStore, SyncConfig)? syncRunner;

  /// Optional override for tests; defaults to the folder in Preferences.
  final Future<NoteStore> Function()? storeFactory;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  NoteStore? _store;
  List<String> _notes = const [];
  NoteFolder _tree = NoteFolder.build(const []);
  final Set<String> _expanded = {};
  bool _loading = true;
  Object? _error;
  String? _selected;
  EditorMode _mode = EditorMode.raw;
  bool _editorDirty = false;
  String _defaultNote = kDefaultNotePath;
  List<String> _pinned = const [];
  List<String> _recent = const [];
  bool _viKeys = false;
  bool _syncEnabled = false;
  bool _syncing = false;

  /// Every note's text, for search and tags; null until first read.
  final ValueNotifier<NoteIndex?> _index = ValueNotifier(null);
  int _indexGeneration = 0;

  /// Only notes with this tag (or one below it) show in the tree.
  String? _tagFilter;
  final Set<String> _expandedTags = {};
  final Set<SidebarSection> _collapsedSections = {};

  /// A search match to put the caret on when its note opens.
  SearchTarget? _jumpOnOpen;

  /// A note to open focused with the caret at the end: one just created
  /// here, or the default note, which is there for jotting things down.
  String? _focusOnOpen;
  final GlobalKey<NoteEditorState> _editorKey = GlobalKey();

  /// A note is open on its own [NotePage]. Should the window widen
  /// meanwhile, the two-pane editor stays away: two editors on one note
  /// would each take the other's saves for changes on disk.
  bool _notePageOpen = false;

  PreferencesService get _prefs => widget.preferences;

  /// Holds focus for the screen's shortcuts when nothing inside has it.
  final FocusNode _rootFocus = FocusNode(debugLabel: 'home');

  /// The sidebar's focus, for its vi keys; it has the keyboard whenever
  /// nothing else does.
  final FocusNode _treeFocus = FocusNode(debugLabel: 'tree');

  /// When the focused widget goes away (the editor of a deleted note, say),
  /// focus falls back to the route's scope, which sits above [_rootFocus],
  /// so Ctrl+P and friends would stop working until something is clicked.
  void _keepShortcutsReachable() {
    final primary = FocusManager.instance.primaryFocus;
    final fallback = _treeFocus.context != null ? _treeFocus : _rootFocus;
    if ((primary is FocusScopeNode && _rootFocus.ancestors.contains(primary)) ||
        (primary == _rootFocus && fallback == _treeFocus)) {
      fallback.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_keepShortcutsReachable);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_keepShortcutsReachable);
    _rootFocus.dispose();
    _treeFocus.dispose();
    _index.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Notes may have arrived (Syncthing) or gone while the app was away.
    if (state == AppLifecycleState.resumed &&
        !_loading &&
        !_syncing &&
        _store != null) {
      _reload();
    }
  }

  Future<void> _init() async {
    _mode = await _prefs.editorMode();
    _defaultNote = await _prefs.defaultNote();
    _pinned = await _prefs.pinned();
    _recent = await _prefs.recent();
    _viKeys = await _prefs.viKeys();
    _syncEnabled = (await _prefs.syncConfig()).enabled;
    if (mounted) await _reload(reopenStore: true);
  }

  /// Counts reloads, so one that finishes after a newer one (a slow folder,
  /// or a store swapped by Preferences) does not overwrite its result.
  int _reloadGeneration = 0;

  Future<void> _reload({
    bool reopenStore = false,
    bool afterSync = false,
  }) async {
    if (_syncing && !afterSync) return;
    final generation = ++_reloadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (reopenStore || _store == null) {
        _store =
            await (widget.storeFactory?.call() ?? configuredNoteStore(_prefs));
        _index.value = null;
        _tagFilter = null;
      }
      if (generation != _reloadGeneration) return;
      final store = _store!;
      // Without All files access Android 11+ lists such a folder as empty.
      if (store is DirectoryNoteStore &&
          await StorageAccessService.needsAllFilesAccess(store.root)) {
        throw FileSystemException(
          'TurboNotes needs All files access to see the notes in this folder. '
          'Grant it in Preferences',
          store.root,
        );
      }
      final notes = await store.list();
      if (!mounted || generation != _reloadGeneration) return;
      setState(() {
        _notes = notes;
        _tree = _buildTree();
        if (_selected != null && !notes.contains(_selected)) _selected = null;
        _loading = false;
      });
      // The tree is back; let it have the keyboard if nothing else does.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _keepShortcutsReachable(),
      );
      _buildIndex(store, notes);
    } catch (e) {
      if (!mounted || generation != _reloadGeneration) return;
      _indexGeneration++;
      _index.value = null;
      setState(() {
        _error = e;
        _notes = const [];
        _tree = NoteFolder.build(const []);
        _selected = null;
        _loading = false;
      });
    }
  }

  /// Reads every note for search and tags, in the background. The previous
  /// index stays usable meanwhile; a newer reload wins.
  Future<void> _buildIndex(NoteStore store, List<String> notes) async {
    final generation = ++_indexGeneration;
    final index = await NoteIndex.load(store, notes);
    if (!mounted || generation != _indexGeneration) return;
    // Keep whatever the open editor holds as saved: it may be newer than a
    // read that raced a save.
    final previous = _index.value;
    final selected = _selected;
    if (previous != null && selected != null) {
      final text = previous[selected]?.text;
      if (text != null) index.put(selected, text);
    }
    _index.value = index;
    setState(() => _tree = _buildTree());
  }

  /// The tree of every note, or of those carrying [_tagFilter].
  NoteFolder _buildTree() {
    final filter = _tagFilter;
    final index = _index.value;
    if (filter == null || index == null) return NoteFolder.build(_notes);
    final tagged = index.notesTagged(filter);
    return NoteFolder.build(_notes.where(tagged.contains));
  }

  void _setTagFilter(String? tag) {
    // The chip's delete button had focus; without this the shortcuts would
    // stop working until something is clicked.
    if (tag == null && !_treeFocus.hasFocus) _treeFocus.requestFocus();
    setState(() {
      _tagFilter = tag;
      _tree = _buildTree();
    });
  }

  /// Keeps the index (and with it the tags) current as the editor saves.
  void _onSaved(String path, String text) {
    final index = _index.value;
    if (index == null || index[path]?.text == text) return;
    index.put(path, text);
    if (mounted) setState(() => _tree = _buildTree());
  }

  /// A note's text from the search index, so it opens without a disk read.
  String? _cachedText(String path) => _index.value?[path]?.text;

  List<String> _existing(List<String> paths) => [
    for (final p in paths)
      if (_notes.contains(p)) p,
  ];

  void _remember(String path) {
    _recent = [
      path,
      ..._recent.where((p) => p != path),
    ].take(kRecentLimit).toList();
    _prefs.setRecent(_recent);
  }

  bool _isPinned(String path) => _pinned.contains(path);

  void _togglePin(String path) {
    setState(() {
      _pinned = _isPinned(path)
          ? [..._pinned.where((p) => p != path)]
          : [..._pinned, path];
    });
    _prefs.setPinned(_pinned);
  }

  /// Carries pins and recents over a rename ([to] set) or delete.
  void _forget(String path, {String? to}) {
    List<String> move(List<String> list) =>
        <String?>[for (final p in list) p == path ? to : p].nonNulls.toList();
    _pinned = move(_pinned);
    _recent = move(_recent);
    _prefs.setPinned(_pinned);
    _prefs.setRecent(_recent);
    final index = _index.value;
    if (to == null) {
      index?.remove(path);
    } else {
      index?.rename(path, to);
    }
  }

  bool get _twoPane => MediaQuery.sizeOf(context).width >= kTwoPaneWidth;

  void _setMode(EditorMode mode) {
    _mode = mode;
    _prefs.setEditorMode(mode);
  }

  /// Opens [path]; with [match] (a search hit) that text is selected. With
  /// [focus] (Enter in the tree) the editor takes the keyboard.
  Future<void> _open(
    String path, {
    TextSelection? match,
    bool focus = false,
  }) async {
    if (_syncing) return;
    final store = _store;
    if (store == null) return;
    if (_twoPane && path == _selected && match == null && focus) {
      _editorKey.currentState?.focus();
      return;
    }
    // Opening with the keyboard puts the caret at the top, focused.
    match ??= focus ? const TextSelection.collapsed(offset: 0) : null;
    _jumpOnOpen = match == null ? null : (path: path, match: match);
    _remember(path);
    setState(() {
      for (final folder in ancestorFolders(path)) {
        _expanded.add(folder);
      }
    });
    if (_twoPane) {
      if (path == _selected) {
        if (match != null) _editorKey.currentState?.select(match);
        return;
      }
      final editor = _editorKey.currentState;
      if (editor != null && !await editor.saveBeforeLeave()) return;
      if (!mounted) return;
      setState(() {
        _selected = path;
        _editorDirty = false;
      });
      return;
    }
    setState(() {
      _selected = path;
      _notePageOpen = true;
    });
    await Navigator.of(context).push(
      _NoteRoute(
        builder: (_) => NotePage(
          store: store,
          path: path,
          initialMode: _mode,
          autofocus: _focusOnOpen == path,
          initialSelection: match,
          viKeys: _viKeys,
          onModeChanged: _setMode,
          onSaved: _onSaved,
          cachedText: _cachedText,
          pinned: _isPinned(path),
          onTogglePin: () => _togglePin(path),
          onShare: (text) => _share(path, text: text),
          onRename: () => _rename(path, fromNotePage: true),
          onDelete: () => _delete(path, fromNotePage: true),
        ),
      ),
    );
    if (mounted) setState(() => _notePageOpen = false);
  }

  /// The folder new notes go into by default: that of the open note.
  String get _currentFolder {
    final selected = _selected;
    return selected == null ? '' : parentPath(selected);
  }

  Future<void> _findNote() async {
    if (_syncing) return;
    if (_notes.isEmpty) return;
    // Recent notes first, so an empty query is a quick switcher.
    final recent = _existing(_recent);
    final path = await showFuzzyFinder(context, [
      ...recent,
      ..._notes.where((p) => !recent.contains(p)),
    ]);
    // Picked with the keyboard, so the keyboard goes on into the note.
    if (path != null && mounted) await _open(path, focus: true);
  }

  Future<void> _searchText() async {
    if (_syncing) return;
    if (_store == null || _error != null) return;
    final target = await showSearchDialog(context, _index);
    if (target != null && mounted) {
      await _open(target.path, match: target.match);
    }
  }

  /// Shares [path] as text, PDF or image. [text] is what the open editor
  /// holds, unsaved edits included; otherwise the note is read from disk.
  Future<void> _share(String path, {String? text}) async {
    final store = _store;
    if (store == null) return;
    final desktop = !Platform.isAndroid;
    final format = await askShareFormat(context, path, desktop: desktop);
    if (format == null || !mounted) return;
    final share = widget.shareService;
    final subject = displayName(path);
    try {
      final body =
          text ??
          (path == _selected ? _editorKey.currentState?.text : null) ??
          await store.read(path);
      final ShareOutcome outcome;
      switch (format) {
        case ShareFormat.text:
          outcome = await share.shareText(body, subject: subject);
        case ShareFormat.pdf:
          _snack('Preparing the PDF…');
          final bytes = await NoteExporter(
            store: store,
            path: path,
            text: body,
          ).pdf(title: subject);
          outcome = await share.shareFile(
            bytes,
            fileName: shareFileName(subject, '.pdf'),
            mime: 'application/pdf',
            subject: subject,
          );
        case ShareFormat.image:
          _snack('Preparing the image…');
          final bytes = await NoteExporter(
            store: store,
            path: path,
            text: body,
          ).png();
          outcome = await share.shareFile(
            bytes,
            fileName: shareFileName(subject, '.png'),
            mime: 'image/png',
            subject: subject,
          );
      }
      if (!mounted) return;
      switch (outcome) {
        case SharedViaSheet():
          ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
        case CopiedToClipboard():
          _snack('Copied $path to the clipboard');
        case SavedFile(:final path):
          _savedSnack(path);
      }
    } catch (e) {
      _snack('Could not share $path: ${describeError(e)}', error: true);
    }
  }

  void _savedSnack(String path) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    // Clear, not just hide: "Preparing…" may still be queued.
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Saved $path'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () async {
            if (!await widget.shareService.open(path)) {
              _snack('No app to open $path with', error: true);
            }
          },
        ),
      ),
    );
  }

  /// Asks for a new note's path, starting in [folder] or the open note's.
  Future<void> _newNote({String? folder}) async {
    if (_syncing) return;
    final store = _store;
    if (store == null) return;
    folder ??= _currentFolder;
    final path = await askNotePath(
      context,
      title: 'New note',
      action: 'Create',
      initial: folder.isEmpty ? '' : '$folder/',
      exists: _notes.contains,
    );
    if (path == null || !mounted) return;
    final text = '# ${displayName(path)}\n\n';
    try {
      await store.create(path, text);
    } catch (e) {
      _snack('Could not create $path: ${describeError(e)}', error: true);
      return;
    }
    _index.value?.put(path, text);
    _focusOnOpen = path;
    await _reload();
    if (mounted) await _open(path);
  }

  /// Opens the default note from Preferences, creating it on first use.
  Future<void> _openDefaultNote() async {
    if (_syncing) return;
    final store = _store;
    if (store == null || _error != null) return;
    final path = _defaultNote;
    _focusOnOpen = path;
    if (_twoPane && path == _selected) {
      _editorKey.currentState?.focusAtEnd();
      return;
    }
    if (!_notes.contains(path)) {
      try {
        await store.create(path, '# ${displayName(path)}\n\n');
      } on NoteExistsException {
        // Created elsewhere since the last refresh: just open it.
      } catch (e) {
        _snack('Could not create $path: ${describeError(e)}', error: true);
        return;
      }
      await _reload();
    }
    if (mounted) await _open(path);
  }

  /// Renames or moves [path]. From the phone note page, that page closes
  /// and the note reopens under its new name.
  Future<void> _rename(String path, {bool fromNotePage = false}) async {
    if (_syncing) return;
    final store = _store;
    if (store == null) return;
    if (!fromNotePage && path == _selected) {
      final editor = _editorKey.currentState;
      if (editor != null && !await editor.saveBeforeLeave()) return;
    }
    if (!mounted) return;
    final target = await askNotePath(
      context,
      title: 'Rename note',
      action: 'Rename',
      initial: path,
      exists: _notes.contains,
    );
    if (target == null || target == path || !mounted) return;
    try {
      await store.rename(path, target);
    } catch (e) {
      _snack('Could not rename $path: ${describeError(e)}', error: true);
      return;
    }
    if (!mounted) return;
    if (fromNotePage) Navigator.of(context).pop();
    _forget(path, to: target);
    setState(() {
      if (_selected == path) _selected = target;
      _expanded.addAll(ancestorFolders(target));
    });
    await _reload();
    if (fromNotePage && mounted) await _open(target);
  }

  Future<void> _delete(String path, {bool fromNotePage = false}) async {
    if (_syncing) return;
    final store = _store;
    if (store == null) return;
    if (!await confirmDeleteNote(context, path) || !mounted) return;
    try {
      await store.delete(path);
    } catch (e) {
      _snack('Could not delete $path: ${describeError(e)}', error: true);
      return;
    }
    if (!mounted) return;
    if (fromNotePage) Navigator.of(context).pop();
    _forget(path);
    setState(() {
      if (_selected == path) {
        _selected = null;
        _editorDirty = false;
      }
    });
    _snack('Deleted $path');
    await _reload();
  }

  Future<void> _noteMenu(String path, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<_MenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: _MenuAction.pin,
          child: Text(_isPinned(path) ? 'Unpin' : 'Pin'),
        ),
        const PopupMenuItem(value: _MenuAction.share, child: Text('Share…')),
        const PopupMenuItem(
          value: _MenuAction.rename,
          child: Text('Rename / move'),
        ),
        const PopupMenuItem(value: _MenuAction.delete, child: Text('Delete')),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case _MenuAction.pin:
        _togglePin(path);
      case _MenuAction.share:
        await _share(path);
      case _MenuAction.rename:
        await _rename(path);
      case _MenuAction.delete:
        await _delete(path);
      default:
    }
  }

  Future<void> _openPreferences() async {
    if (_syncing) return;
    final editor = _editorKey.currentState;
    if (editor != null && !await editor.saveBeforeLeave()) return;
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PreferencesScreen(preferences: _prefs)),
    );
    if (changed == true && mounted) {
      setState(() {
        _selected = null;
        _editorDirty = false;
        _expanded.clear();
      });
      await _init();
    }
  }

  Future<void> _showAbout() async {
    // The version comes from the bundled pubspec.yaml, never a literal here.
    String? version;
    try {
      version = await loadAppVersion(DefaultAssetBundle.of(context));
    } catch (e, st) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: st,
          library: 'turbonotes',
          context: ErrorDescription('while loading the app version for About'),
        ),
      );
    }
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'TurboNotes',
      applicationVersion: version,
      applicationIcon: Image.asset('logo-small.png', width: 48, height: 48),
      applicationLegalese:
          'Edit a folder of markdown notes. Optional S3 sync; no telemetry.',
    );
  }

  void _snack(String message, {bool error = false}) {
    if (mounted) showSnack(context, message, error: error);
  }

  /// Puts the keyboard in the open note's editor.
  void _focusEditor() => _editorKey.currentState?.focus();

  /// The sidebar's keys beyond moving around; see [NoteTreeView.onKey].
  bool _treeKey(String key, TreeTarget target) {
    final note = target.note;
    switch (key) {
      case '/':
        _findNote();
      case '?':
        _searchText();
      case 'a':
        _newNote(folder: target.folder);
      case 'R':
        _reload();
      case 'i':
      case '<C-w>l':
        if (_twoPane && _selected != null) {
          _focusEditor();
        } else if (note != null) {
          _open(note, focus: true);
        }
      case 'r' when note != null:
        _rename(note);
      case 'd' when note != null:
        _delete(note);
      case 'p' when note != null:
        _togglePin(note);
      case 's' when note != null:
        _share(note);
      case 'W':
        setState(_expanded.clear);
      default:
        return false;
    }
    return true;
  }

  void _onMenu(_MenuAction action) {
    final selected = _selected;
    switch (action) {
      case _MenuAction.sync:
        _sync();
      case _MenuAction.refresh:
        _reload();
      case _MenuAction.collapse:
        setState(_expanded.clear);
      case _MenuAction.pin:
        if (selected != null) _togglePin(selected);
      case _MenuAction.share:
        if (selected != null) _share(selected);
      case _MenuAction.rename:
        if (selected != null) _rename(selected);
      case _MenuAction.delete:
        if (selected != null) _delete(selected);
      case _MenuAction.preferences:
        _openPreferences();
      case _MenuAction.about:
        _showAbout();
    }
  }

  Future<void> _sync() async {
    final store = _store;
    if (_syncing || _loading || store == null || _notePageOpen) return;
    // Lock the UI before awaiting the save, so shortcuts cannot open another
    // editor or change the destination during the operation.
    setState(() => _syncing = true);
    _rootFocus.requestFocus();
    try {
      final editor = _editorKey.currentState;
      if (editor != null && !await editor.saveBeforeLeave()) return;
      if (!mounted) return;
      setState(() {
        _selected = null;
        _editorDirty = false;
      });
      // Unmount the saved editor before sync can write to its note.
      await WidgetsBinding.instance.endOfFrame;
      final config = await _prefs.syncConfig();
      if (!config.enabled) return;
      final runner = widget.syncRunner;
      final SyncResult result;
      if (runner != null) {
        result = await runner(store, config);
      } else {
        final folder = await _prefs.scopedFolder();
        final identity = folder?.uri ?? await _prefs.directory();
        final support = await getApplicationSupportDirectory();
        final objects = S3SyncObjects(config);
        try {
          result = await NoteSync(
            store: store,
            objects: objects,
            state: FileSyncState(support.path, config.scope(identity)),
          ).run();
        } finally {
          objects.close();
        }
      }
      _snack(
        result.conflicts.isEmpty
            ? 'Synced ${result.notes} notes'
            : 'Synced ${result.notes} notes; ${result.conflicts.length} conflict copies: ${result.conflicts.join(', ')}',
      );
    } on UnsyncableNotePathException catch (error) {
      _snack(
        'Sync cannot use "${error.path}". Rename it to remove spaces at the '
        'ends, backslashes or hidden path components, then sync again.',
        error: true,
      );
    } catch (_) {
      // Server/transport exceptions can contain authentication details.
      _snack(
        'Sync could not finish. Your notes are kept. Check the connection '
        'and S3 settings, then sync again.',
        error: true,
      );
    } finally {
      if (mounted) {
        // Drop stale cached text before building the post-sync search index.
        _indexGeneration++;
        _index.value = null;
        await _reload(afterSync: true);
        if (mounted) setState(() => _syncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final twoPane = _twoPane;
    final title = _selected != null && twoPane
        // Asks the editor too: one that went away (the window narrowed)
        // never reports that it is no longer dirty.
        ? '${displayName(_selected!)}${_editorDirty && (_editorKey.currentState?.dirty ?? false) ? ' •' : ''}'
        : 'TurboNotes';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP, control: true):
            _findNote,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _findNote,
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          shift: true,
        ): _searchText,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newNote,
        const SingleActivator(LogicalKeyboardKey.keyD, control: true):
            _openDefaultNote,
        const SingleActivator(LogicalKeyboardKey.f5): _reload,
      },
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, overflow: TextOverflow.ellipsis),
                if (_store != null)
                  Text(
                    _selected != null && twoPane ? _selected! : _store!.label,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            actions: [
              IconButton(
                key: const ValueKey('default-note'),
                tooltip: 'Open $_defaultNote (Ctrl+D)',
                icon: const Icon(Icons.electric_bolt),
                onPressed: _store == null || _error != null
                    ? null
                    : _openDefaultNote,
              ),
              IconButton(
                key: const ValueKey('find-note'),
                tooltip: 'Find note (Ctrl+P)',
                icon: const Icon(Icons.search),
                onPressed: _notes.isEmpty ? null : _findNote,
              ),
              IconButton(
                key: const ValueKey('search-text'),
                tooltip: 'Search in notes (Ctrl+Shift+F)',
                icon: const Icon(Icons.manage_search),
                onPressed: _store == null || _error != null
                    ? null
                    : _searchText,
              ),
              IconButton(
                key: const ValueKey('new-note'),
                tooltip: 'New note (Ctrl+N)',
                icon: const Icon(Icons.note_add_outlined),
                onPressed: _store == null || _error != null ? null : _newNote,
              ),
              PopupMenuButton<_MenuAction>(
                onSelected: _onMenu,
                itemBuilder: (_) => [
                  if (_syncEnabled)
                    PopupMenuItem(
                      value: _MenuAction.sync,
                      enabled: !_syncing && !_loading && _error == null,
                      child: Text(_syncing ? 'Syncing…' : 'Sync now'),
                    ),
                  const PopupMenuItem(
                    value: _MenuAction.refresh,
                    child: Text('Refresh (F5)'),
                  ),
                  const PopupMenuItem(
                    value: _MenuAction.collapse,
                    child: Text('Collapse all folders'),
                  ),
                  if (twoPane && _selected != null) ...[
                    PopupMenuItem(
                      value: _MenuAction.pin,
                      child: Text(
                        _isPinned(_selected!) ? 'Unpin note' : 'Pin note',
                      ),
                    ),
                    const PopupMenuItem(
                      value: _MenuAction.share,
                      child: Text('Share note…'),
                    ),
                    const PopupMenuItem(
                      value: _MenuAction.rename,
                      child: Text('Rename / move note'),
                    ),
                    const PopupMenuItem(
                      value: _MenuAction.delete,
                      child: Text('Delete note'),
                    ),
                  ],
                  const PopupMenuItem(
                    value: _MenuAction.preferences,
                    child: Text('Preferences'),
                  ),
                  const PopupMenuItem(
                    value: _MenuAction.about,
                    child: Text('About'),
                  ),
                ],
              ),
            ],
          ),
          body: _syncing && _selected == null
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Syncing notes…'),
                    ],
                  ),
                )
              : AbsorbPointer(
                  absorbing: _syncing,
                  child: twoPane ? _twoPaneBody() : _treePane(),
                ),
        ),
      ),
    );
  }

  Widget _treePane() {
    // A refresh keeps showing the tree (and the keyboard cursor in it).
    if (_loading && _notes.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Cannot read the notes folder:\n${describeError(error)}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _openPreferences,
                child: const Text('Choose notes folder'),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: NoteTreeView(
        root: _tree,
        expanded: _expanded,
        selected: _selected,
        onToggleFolder: (path) => setState(() {
          if (!_expanded.remove(path)) _expanded.add(path);
        }),
        onOpen: _open,
        onOpenFocused: (path) => _open(path, focus: true),
        onKey: _treeKey,
        focusNode: _treeFocus,
        onNoteMenu: _noteMenu,
        pinned: _existing(_pinned),
        recent: _existing(_recent),
        tags: _index.value?.tagTree,
        tagFilter: _tagFilter,
        onTagFilter: _setTagFilter,
        expandedTags: _expandedTags,
        onToggleTag: (tag) => setState(() {
          if (!_expandedTags.remove(tag)) _expandedTags.add(tag);
        }),
        collapsed: _collapsedSections,
        onToggleSection: (section) => setState(() {
          if (!_collapsedSections.remove(section)) {
            _collapsedSections.add(section);
          }
        }),
      ),
    );
  }

  Widget _twoPaneBody() {
    final store = _store;
    final selected = _selected;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 300, child: _treePane()),
        const VerticalDivider(width: 1),
        Expanded(
          // A refresh keeps the open note: unmounting the editor would drop
          // its unsaved edits and its caret.
          child:
              _error != null || _notePageOpen || (_loading && selected == null)
              ? const SizedBox.shrink()
              : store == null || selected == null
              ? Center(
                  child: Text(
                    _notes.isEmpty
                        ? 'Create a note with Ctrl+N.'
                        : 'Pick a note, or press Ctrl+P to find one.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                )
              : NoteEditor(
                  key: _editorKey,
                  store: store,
                  path: selected,
                  initialMode: _mode,
                  autofocus: _focusOnOpen == selected,
                  initialSelection: _jumpOnOpen?.path == selected
                      ? _jumpOnOpen!.match
                      : null,
                  viKeys: _viKeys,
                  onLeave: _treeFocus.requestFocus,
                  onModeChanged: _setMode,
                  onSaved: _onSaved,
                  cachedText: _cachedText,
                  onDirtyChanged: (d) {
                    if (mounted) setState(() => _editorDirty = d);
                  },
                ),
        ),
      ],
    );
  }
}

/// A note's own screen, sliding in quicker than Material's default page
/// transition (450 ms on Android), which made opening a note feel slow.
class _NoteRoute extends MaterialPageRoute<void> {
  _NoteRoute({required super.builder});

  static const _duration = Duration(milliseconds: 200);

  @override
  Duration get transitionDuration => _duration;

  @override
  Duration get reverseTransitionDuration => _duration;
}
