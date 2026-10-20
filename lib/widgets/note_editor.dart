import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/markdown_controller.dart';
import '../editor/vi_engine.dart';
import '../services/clipboard_image.dart';
import '../services/device_images.dart';
import '../services/note_store.dart';
import '../services/note_tree.dart';
import '../services/player_control.dart';
import '../services/preferences.dart';
import 'feedback.dart';
import 'format_toolbar.dart';
import 'note_image.dart';

enum _Conflict { cancel, reload, overwrite }

enum _ImageSource { gallery, camera, clipboard }

/// Editor for one note, with a Raw / WYSIWYG switch.
///
/// Both modes edit the same markdown source (see [MarkdownEditingController]),
/// so switching is instant and never reformats anything. Saving writes back
/// to the same path. If the file changed on disk since it was opened --
/// Syncthing delivering an edit from another device, say -- the save asks
/// before overwriting it.
///
/// Edits are saved automatically when the note is left ([saveBeforeLeave])
/// and when the app goes to the background or its window closes. With
/// nobody there to ask about a conflict, the background save writes the
/// edits to a conflict copy next to the note instead of overwriting it.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.store,
    required this.path,
    required this.initialMode,
    this.onModeChanged,
    this.onDirtyChanged,
    this.onSaved,
    this.autofocus = false,
    this.initialSelection,
    this.viKeys = false,
    this.onLeave,
    this.cachedText,
    this.player,
  });

  final NoteStore store;
  final String path;
  final EditorMode initialMode;
  final ValueChanged<EditorMode>? onModeChanged;
  final ValueChanged<bool>? onDirtyChanged;

  /// Called with the note's text whenever it was written to (or reloaded
  /// from) disk, e.g. to keep the search index current.
  final void Function(String path, String text)? onSaved;

  /// What to select once loaded (a search match), focusing the field.
  final TextSelection? initialSelection;

  /// Focus the field with the caret at the end once loaded, e.g. for a note
  /// that was just created.
  final bool autofocus;

  /// Edit with vi's modal keys (see [ViEngine]).
  final bool viKeys;

  /// Moves the keyboard away from the note: Ctrl+W h (or w, p), `:q`, and
  /// Esc unless [viKeys] is on. Null keeps the keyboard here.
  final VoidCallback? onLeave;

  /// The note's text as last seen (the search index holds every note), or
  /// null. With it the note shows at once, without waiting for the disk;
  /// the read that follows only brings in changes made meanwhile.
  final String? Function(String path)? cachedText;

  /// Remote control for the Player app; [PlayerControl.instance] if null.
  /// Its controls show while Player has a title open.
  final PlayerControl? player;

  @override
  State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> {
  final MarkdownEditingController _controller = MarkdownEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  late final ViEngine _vi = ViEngine(
    _controller,
    onYank: (text) => Clipboard.setData(ClipboardData(text: text)),
    onPrompt: _openPrompt,
    onWrite: () => _writing = save(),
    onQuit: _quit,
  );

  /// The save `:w` started, which `:wq` waits for before leaving.
  Future<bool>? _writing;

  Future<void> _quit() async {
    final writing = _writing;
    _writing = null;
    if (writing != null && !await writing) return;
    if (mounted) widget.onLeave?.call();
  }

  /// The line typed after `/`, `?` or `:` in vi's normal mode, while open.
  ViPrompt? _prompt;
  final TextEditingController _promptText = TextEditingController();
  final FocusNode _promptFocus = FocusNode();

  /// Ctrl+W was pressed; the next key picks where the keyboard goes.
  bool _windowChord = false;
  final ScrollController _scroll = ScrollController();
  late EditorMode _mode = widget.initialMode;
  late AttachmentCache _images = _newCache();

  PlayerControl get _player => widget.player ?? PlayerControl.instance;

  AttachmentCache _newCache() =>
      AttachmentCache(widget.store, onLoaded: _controller.relayout);

  /// The text on disk as last loaded or saved; "dirty" means the field
  /// differs from it.
  String _original = '';
  bool _loading = true;
  Object? _loadError;
  bool _saving = false;
  bool _lastDirty = false;

  /// The text last written to a conflict copy, so repeated background saves
  /// of the same edits do not pile up copies.
  String? _conflictCopyOf;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onInactive: _saveInBackground,
    onHide: _saveInBackground,
    onPause: _saveInBackground,
    onResume: _refreshFromDisk,
    onExitRequested: () async {
      await _saveInBackground();
      return AppExitResponse.exit;
    },
  );

  /// The text in the field, unsaved edits included.
  String get text => _controller.text;

  bool get dirty =>
      !_loading && _loadError == null && _controller.text != _original;

  @override
  void initState() {
    super.initState();
    _controller.wysiwyg = _mode == EditorMode.wysiwyg;
    _controller.imageBuilder = _inlineImage;
    _controller.addListener(_onChanged);
    _focus.addListener(_onFocus);
    _vi.addListener(_onViChanged);
    _player.addListener(_onPlayerChanged);
    _player.start();
    _lifecycle; // Created lazily; touch it so it starts listening.
    _load();
  }

  @override
  void didUpdateWidget(NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another note's images would only take up memory.
    if (oldWidget.store != widget.store || oldWidget.path != widget.path) {
      _images.dispose();
      _images = _newCache();
    }
    if (oldWidget.player != widget.player) {
      (oldWidget.player ?? PlayerControl.instance).removeListener(
        _onPlayerChanged,
      );
      _player.addListener(_onPlayerChanged);
      _player.start();
    }
    if (oldWidget.viKeys != widget.viKeys) {
      _vi.reset();
      _prompt = null;
    }
    if (oldWidget.path != widget.path || oldWidget.store != widget.store) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
      _load();
    }
  }

  @override
  void dispose() {
    if (dirty) {
      unawaited(_saveOnDispose(widget.store, widget.path, _controller.text));
    }
    _lifecycle.dispose();
    _images.dispose();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _vi.removeListener(_onViChanged);
    _vi.dispose();
    _player.removeListener(_onPlayerChanged);
    _promptText.dispose();
    _promptFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFocus() => _controller.focused = _focus.hasFocus;

  void _onViChanged() {
    if (mounted) setState(() {});
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  static final _modifierKeys = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  static final _leaveKeys = {
    LogicalKeyboardKey.keyH,
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyP,
  };

  /// Key presses reach this before the field: Ctrl+W chords, Esc, and in
  /// vi mode every command key, so none of them types into the note.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final hw = HardwareKeyboard.instance;
    if (_windowChord) {
      if (_modifierKeys.contains(key)) return KeyEventResult.ignored;
      _windowChord = false;
      if (_leaveKeys.contains(key)) widget.onLeave?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyW &&
        hw.isControlPressed &&
        !hw.isShiftPressed &&
        !hw.isAltPressed &&
        widget.onLeave != null) {
      _windowChord = true;
      return KeyEventResult.handled;
    }
    if (!widget.viKeys) {
      if (key == LogicalKeyboardKey.escape &&
          widget.onLeave != null &&
          hw.logicalKeysPressed.length <= 1) {
        widget.onLeave!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final name = _viKeyName(event);
    if (name == null) return KeyEventResult.ignored;
    return _vi.handle(name) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// The key as [ViEngine.handle] takes it, or null for keys vi leaves to
  /// the field (arrows, Ctrl shortcuts, and everything typed in insert mode).
  String? _viKeyName(KeyEvent event) {
    final key = event.logicalKey;
    final hw = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.escape) return '<Esc>';
    if (hw.isControlPressed) {
      if (key == LogicalKeyboardKey.bracketLeft) return '<Esc>';
      if (key == LogicalKeyboardKey.keyR && !hw.isShiftPressed) return '<C-r>';
      return null;
    }
    if (hw.isAltPressed || hw.isMetaPressed) return null;
    if (_vi.mode == ViMode.insert) return null;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return '<CR>';
    }
    if (key == LogicalKeyboardKey.backspace) return '<BS>';
    final c = event.character;
    if (c == null || c.isEmpty || c.codeUnitAt(0) < 0x20) return null;
    return c;
  }

  void _openPrompt(ViPrompt prompt) {
    setState(() => _prompt = prompt);
    _promptText.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _prompt != null) _promptFocus.requestFocus();
    });
  }

  void _closePrompt() {
    setState(() => _prompt = null);
    _focus.requestFocus();
  }

  void _submitPrompt(String line) {
    final prompt = _prompt;
    _closePrompt();
    switch (prompt) {
      case ViPrompt.searchForward:
      case ViPrompt.searchBackward:
        _vi.search(line, forward: prompt == ViPrompt.searchForward);
      case ViPrompt.command:
        _vi.command(line);
      case null:
    }
  }

  void _onChanged() {
    final d = dirty;
    if (d != _lastDirty) {
      _lastDirty = d;
      widget.onDirtyChanged?.call(d);
      setState(() {});
    }
  }

  Future<void> _load() async {
    final path = widget.path;
    _vi.reset();
    _prompt = null;
    final cached = widget.cachedText?.call(path);
    if (cached != null) {
      // Show the cached text now and check the disk behind it. Edits made
      // before that read returns are safe: [_original] stays the cached
      // text, so saving over a note that differs on disk still asks first.
      _show(path, cached);
      unawaited(_refreshFromDisk());
      return;
    }
    try {
      final text = await widget.store.read(path);
      if (!mounted || path != widget.path) return;
      _show(path, text);
      setState(() {});
      widget.onSaved?.call(path, text);
    } catch (e) {
      // Show the reason instead of an empty editor: saving an empty buffer
      // over a note that merely could not be read would destroy it.
      if (!mounted || path != widget.path) return;
      _loadError = e;
      setState(() => _loading = false);
      _onChanged();
    }
  }

  /// Puts [text], the note at [path], in the field as loaded.
  void _show(String path, String text) {
    _original = text;
    _controller.value = TextEditingValue(
      text: text,
      selection: _clamp(
        widget.initialSelection ??
            TextSelection.collapsed(offset: widget.autofocus ? text.length : 0),
        text.length,
      ),
    );
    _loadError = null;
    // No setState: from initState or didUpdateWidget a build follows anyway.
    _loading = false;
    _onChanged();
    if ((widget.autofocus || widget.initialSelection != null) &&
        _loadError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  /// Gives the field the keyboard, leaving the caret where it was.
  void focus() {
    if (_loading || _loadError != null) return;
    _focus.requestFocus();
  }

  /// Puts the caret at the end of the note and focuses the field.
  void focusAtEnd() {
    if (_loading || _loadError != null) return;
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    _focus.requestFocus();
  }

  /// Selects [selection] (a search match) and focuses the field.
  void select(TextSelection selection) {
    if (_loading || _loadError != null) return;
    _controller.selection = _clamp(selection, _controller.text.length);
    _focus.requestFocus();
  }

  static TextSelection _clamp(TextSelection s, int length) => TextSelection(
    baseOffset: s.baseOffset.clamp(0, length),
    extentOffset: s.extentOffset.clamp(0, length),
  );

  /// Shows edits made outside the app (the home-screen widget, Syncthing)
  /// when it comes back, as long as nothing typed here would be lost.
  Future<void> _refreshFromDisk() async {
    if (_saving || _loading || _loadError != null || dirty) return;
    final path = widget.path;
    final String onDisk;
    try {
      onDisk = await widget.store.read(path);
    } catch (_) {
      return; // Gone or unreadable: the next save reports it.
    }
    if (!mounted || path != widget.path || dirty || onDisk == _original) {
      return;
    }
    _original = onDisk;
    _replaceText(onDisk);
    widget.onSaved?.call(path, onDisk);
  }

  Widget? _inlineImage(String target, String alt) {
    final path = resolveNoteLink(widget.path, target);
    if (path == null || !isImagePath(path)) return null;
    return NoteImage(cache: _images, path: path, alt: alt);
  }

  /// Pastes text as usual; with no text but an image on the clipboard, the
  /// image is stored next to the note and linked at the caret.
  Future<void> paste() async {
    final path = widget.path;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || path != widget.path) return;
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _controller.replaceSelection(text);
      return;
    }
    await pasteImage();
  }

  /// Inserts the clipboard's image, or says there is none.
  Future<void> pasteImage() async {
    final path = widget.path;
    final ImageBytes? image;
    try {
      image = await readClipboardImage();
    } catch (e) {
      _snack('Could not paste the image: ${describeError(e)}', error: true);
      return;
    }
    if (!mounted || path != widget.path) return;
    if (image == null) {
      _snack('The clipboard holds no image.');
      return;
    }
    await insertImage(image.bytes, image.extension);
  }

  /// Inserts images picked from the gallery, one after another.
  Future<void> pickImages() async {
    final path = widget.path;
    final List<ImageBytes> images;
    try {
      images = await pickGalleryImages();
    } catch (e) {
      _snack('Could not add the image: ${describeError(e)}', error: true);
      return;
    }
    for (final image in images) {
      if (!mounted || path != widget.path) return;
      await insertImage(image.bytes, image.extension);
    }
  }

  /// Inserts a photo taken with the camera app.
  Future<void> takePhoto() async {
    final path = widget.path;
    final ImageBytes? image;
    try {
      image = await takeCameraPhoto();
    } catch (e) {
      _snack('Could not add the photo: ${describeError(e)}', error: true);
      return;
    }
    if (image == null || !mounted || path != widget.path) return;
    await insertImage(image.bytes, image.extension);
  }

  /// Stores [bytes] as an image next to the note and links it at the caret.
  Future<void> insertImage(Uint8List bytes, String extension) async {
    if (_loading || _loadError != null) return;
    final path = widget.path;
    final store = widget.store;
    final now = DateTime.now();
    ({String path, String link}) target;
    for (var n = 0; ; n++) {
      target = attachmentPathFor(path, extension, now, suffix: n);
      try {
        await store.createBytes(target.path, bytes);
        break;
      } on NoteExistsException {
        // Another image this second; try the next name.
        if (n < 99) continue;
        _snack('Could not store the image: too many this second', error: true);
        return;
      } catch (e) {
        _snack('Could not store the image: ${describeError(e)}', error: true);
        return;
      }
    }
    // The note was switched meanwhile: the image is stored, but its link
    // belongs to a note no longer open here.
    if (!mounted || path != widget.path || store != widget.store) return;
    await _images.put(target.path, bytes).catchError((_) {});
    if (!mounted || path != widget.path) return;
    _controller.insertBlock('![](${target.link})');
    _focus.requestFocus();
  }

  void _onContentInserted(KeyboardInsertedContent content) {
    final bytes = content.data;
    final ext = imageExtensionFor(content.mimeType);
    if (bytes == null || ext == null) return;
    insertImage(bytes, ext);
  }

  void setMode(EditorMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _controller.wysiwyg = mode == EditorMode.wysiwyg;
    });
    widget.onModeChanged?.call(mode);
    _focus.requestFocus();
  }

  /// The save running now. Saves never overlap: the next one waits for it,
  /// so leaving a note or closing the app never skips the edits.
  Future<void>? _inFlight;

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    while (_inFlight != null) {
      await _inFlight;
    }
    final done = Completer<void>();
    _inFlight = done.future;
    try {
      return await body();
    } finally {
      _inFlight = null;
      done.complete();
    }
  }

  /// Saves; returns whether the note on disk now holds the field's text
  /// (after Reload in the conflict dialog it does: the field took the disk's).
  /// [announce] shows a "Saved" snackbar; automatic saves stay quiet.
  Future<bool> save({bool announce = true}) =>
      _exclusive(() => _save(announce: announce));

  Future<bool> _save({required bool announce}) async {
    if (!mounted || _loading || _loadError != null) return false;
    if (!dirty) return true;
    final store = widget.store;
    final path = widget.path;
    final text = _controller.text;
    setState(() => _saving = true);
    try {
      final onDisk = await store.read(path);
      if (onDisk != _original && onDisk != text) {
        if (!mounted) return false;
        final choice = await _confirmOverwrite();
        if (!mounted) return false;
        if (choice != _Conflict.overwrite) {
          setState(() => _saving = false);
          if (choice == _Conflict.reload) {
            _original = onDisk;
            widget.onSaved?.call(path, onDisk);
            _replaceText(onDisk);
            return true;
          }
          return false;
        }
      }
      await store.write(path, text);
    } catch (e) {
      // Stay in the editor so nothing typed is lost.
      if (mounted) {
        setState(() => _saving = false);
        _snack('Could not save: ${describeError(e)}', error: true);
      }
      return false;
    }
    widget.onSaved?.call(path, text);
    // Before the mounted check: a save that outlives the editor still tells
    // the save in dispose() what is on disk now.
    _original = text;
    if (!mounted) return true;
    setState(() => _saving = false);
    _onChanged();
    if (announce) _snack('Saved $path');
    return true;
  }

  /// Saves without asking anything, for when the app goes to the background
  /// or closes. A note changed on disk meanwhile is left alone; the edits go
  /// to a conflict copy and stay unsaved here, so Save can still settle it.
  Future<void> _saveInBackground() => _exclusive(() async {
    if (!mounted || !dirty) return;
    final store = widget.store;
    final path = widget.path;
    final text = _controller.text;
    _saving = true;
    try {
      final copy = await _writeQuietly(store, path, text);
      if (copy != null) {
        _snack('$path changed on disk; your edits are saved as $copy');
      }
    } catch (e) {
      _snack('Could not save $path: ${describeError(e)}', error: true);
    } finally {
      _saving = false;
      if (mounted) {
        setState(() {});
        _onChanged();
      }
    }
  });

  /// Writes [text] over the note if it still holds [_original], or to a
  /// conflict copy if it changed on disk; returns the copy's path, if any.
  Future<String?> _writeQuietly(
    NoteStore store,
    String path,
    String text,
  ) async {
    final onDisk = await store.read(path);
    if (onDisk == _original || onDisk == text) {
      await store.write(path, text);
      if (!mounted || path == widget.path) _original = text;
      widget.onSaved?.call(path, text);
      return null;
    }
    if (_conflictCopyOf == text) return null;
    final copy = conflictCopyPath(path, DateTime.now());
    await store.create(copy, text);
    _conflictCopyOf = text;
    return copy;
  }

  /// Saves edits still unsaved when the editor goes away without a save
  /// (the window got too narrow for two panes, a reload lost the note), by
  /// the background save's rules. Nobody is left to tell, so failures stay
  /// quiet; a note that is gone was deleted on purpose.
  Future<void> _saveOnDispose(NoteStore store, String path, String text) async {
    while (_inFlight != null) {
      await _inFlight;
    }
    if (text == _original) return;
    try {
      await _writeQuietly(store, path, text);
    } catch (e) {
      debugPrint('TurboNotes: unsaved edits to $path not written: $e');
    }
  }

  /// Shows [text] in the field, keeping the caret where it was.
  void _replaceText(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: _controller.selection.baseOffset.clamp(0, text.length),
      ),
    );
  }

  /// Puts the field back to the text loaded from disk.
  void revert() {
    _controller.value = TextEditingValue(
      text: _original,
      selection: TextSelection.collapsed(offset: _original.length),
    );
  }

  /// Saves unsaved edits before the note is closed; true means it is fine
  /// to leave. False only when the save failed or a conflict was cancelled,
  /// so nothing typed is lost.
  Future<bool> saveBeforeLeave() async {
    if (_loading || _loadError != null || !dirty) return true;
    return save(announce: false);
  }

  Future<_Conflict> _confirmOverwrite() async {
    final answer = await showDialog<_Conflict>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Changed on disk'),
        content: Text(
          '${widget.path} was changed outside TurboNotes since you opened it. '
          'Overwrite replaces those changes with yours; Reload discards '
          'your edits and shows the version on disk.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_Conflict.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_Conflict.reload),
            child: const Text('Reload'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_Conflict.overwrite),
            child: const Text('Overwrite'),
          ),
        ],
      ),
    );
    return answer ?? _Conflict.cancel;
  }

  void _snack(String message, {bool error = false}) {
    if (mounted) showSnack(context, message, error: error);
  }

  /// Outside insert mode the field is read-only to vi's command keys, and
  /// the editing shortcuts must not get around that.
  bool get _canEdit => !widget.viKeys || _vi.mode == ViMode.insert;

  void _ifEditable(VoidCallback edit) {
    if (_canEdit) edit();
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): save,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
        _ifEditable(paste),
    const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
        _ifEditable(() => _controller.toggleWrap('**')),
    const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
        _ifEditable(() => _controller.toggleWrap('*')),
    const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
        setMode(_mode == EditorMode.raw ? EditorMode.wysiwyg : EditorMode.raw),
    if (_player.status != null) ...{
      const SingleActivator(LogicalKeyboardKey.keyP, alt: true):
          _player.togglePlayback,
      const SingleActivator(LogicalKeyboardKey.keyR, alt: true): () =>
          _player.rewind(),
    },
  };

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not read ${widget.path}: ${describeError(_loadError!)}',
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final wysiwyg = _mode == EditorMode.wysiwyg;
    final viCommands = widget.viKeys && _vi.mode != ViMode.insert;
    final base = wysiwyg
        ? theme.textTheme.bodyLarge!.copyWith(height: 1.45)
        : theme.textTheme.bodyMedium!.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Noto Sans Mono', 'DejaVu Sans Mono'],
            height: 1.4,
          );
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(theme),
          if (wysiwyg) FormatToolbar(controller: _controller, focus: _focus),
          const Divider(height: 1),
          Expanded(
            child: TextField(
              key: const ValueKey('note-editor-field'),
              controller: _controller,
              focusNode: _focus,
              // Vi's normal and visual modes take keys as commands; nothing
              // may type into the note meanwhile.
              readOnly: viCommands,
              showCursor: viCommands ? true : null,
              cursorWidth: viCommands ? _blockWidth(base) : 2,
              cursorColor: viCommands
                  ? theme.colorScheme.primary.withValues(alpha: 0.45)
                  : null,
              scrollController: _scroll,
              expands: true,
              maxLines: null,
              minLines: null,
              keyboardType: TextInputType.multiline,
              textAlignVertical: TextAlignVertical.top,
              style: base,
              // The default strut locks every line to the body text height;
              // WYSIWYG lines grow for headings and inline images.
              strutStyle: wysiwyg ? StrutStyle.disabled : null,
              inputFormatters: [if (wysiwyg) ListContinuationFormatter()],
              contentInsertionConfiguration: ContentInsertionConfiguration(
                allowedMimeTypes: const [
                  'image/png',
                  'image/jpeg',
                  'image/gif',
                  'image/webp',
                ],
                onContentInserted: _onContentInserted,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.fromLTRB(16, 18, 16, 48),
                hintText: 'Empty note',
              ),
            ),
          ),
          if (_player.status case final status?) _playerBar(theme, status),
          if (widget.viKeys) _viBar(theme, base),
        ],
      ),
    );
  }

  /// Controls for the audiobook playing in Player, next to the keyboard.
  /// Counted as part of the field, so tapping them keeps the keyboard up.
  Widget _playerBar(ThemeData theme, PlayerStatus status) {
    return TextFieldTapRegion(
      child: Material(
        key: const ValueKey('player-bar'),
        color: theme.colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            children: [
              Icon(
                Icons.headphones,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status.title,
                  key: const ValueKey('player-title'),
                  style: theme.textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                key: const ValueKey('player-rewind'),
                tooltip: 'Rewind 10 seconds (Alt+R)',
                icon: const Icon(Icons.replay_10),
                onPressed: () => _player.rewind(),
              ),
              IconButton(
                key: const ValueKey('player-play-pause'),
                tooltip: status.playing ? 'Pause (Alt+P)' : 'Continue (Alt+P)',
                icon: Icon(status.playing ? Icons.pause : Icons.play_arrow),
                onPressed: _player.togglePlayback,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The width of vi's block cursor: one character of [style].
  static double _blockWidth(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: 'n', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// Vi's status line: the mode and the command typed so far, or the line
  /// typed after `/`, `?` or `:`.
  Widget _viBar(ThemeData theme, TextStyle base) {
    final style = theme.textTheme.labelMedium?.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Noto Sans Mono', 'DejaVu Sans Mono'],
    );
    final prompt = _prompt;
    final Widget content;
    if (prompt != null) {
      content = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _closePrompt,
        },
        child: TextField(
          key: const ValueKey('vi-prompt'),
          controller: _promptText,
          focusNode: _promptFocus,
          style: style,
          onSubmitted: _submitPrompt,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            prefixText: prompt.prefix,
            prefixStyle: style,
          ),
        ),
      );
    } else {
      final insert = _vi.mode == ViMode.insert;
      content = Row(
        children: [
          Text(
            key: const ValueKey('vi-mode'),
            '-- ${_vi.mode.label} --',
            style: style?.copyWith(
              fontWeight: FontWeight.w600,
              color: insert
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              _vi.message ?? '',
              style: style?.copyWith(color: theme.colorScheme.error),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(_vi.pending, key: const ValueKey('vi-pending'), style: style),
        ],
      );
    }
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: SizedBox(height: 22, child: Center(child: content)),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          _headerRow(theme, compact: constraints.maxWidth < 520),
    );
  }

  /// Adds an image to the note in either mode. Android offers the gallery
  /// and the camera besides the clipboard; the desktop pastes right away.
  Widget _imageButton() {
    const icon = Icon(Icons.add_photo_alternate_outlined);
    if (defaultTargetPlatform != TargetPlatform.android) {
      return IconButton(
        tooltip: 'Paste image from clipboard',
        icon: icon,
        onPressed: pasteImage,
      );
    }
    PopupMenuItem<_ImageSource> item(
      _ImageSource value,
      IconData icon,
      String label,
    ) => PopupMenuItem(
      value: value,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        contentPadding: EdgeInsets.zero,
      ),
    );
    return PopupMenuButton<_ImageSource>(
      tooltip: 'Insert image',
      icon: icon,
      onSelected: (source) => switch (source) {
        _ImageSource.gallery => pickImages(),
        _ImageSource.camera => takePhoto(),
        _ImageSource.clipboard => pasteImage(),
      },
      itemBuilder: (context) => [
        item(_ImageSource.gallery, Icons.photo_library_outlined, 'Gallery'),
        item(_ImageSource.camera, Icons.photo_camera_outlined, 'Camera'),
        item(_ImageSource.clipboard, Icons.content_paste, 'Clipboard'),
      ],
    );
  }

  /// [compact] drops the mode labels (the tooltips stay) so the header fits
  /// one row on a phone.
  Widget _headerRow(ThemeData theme, {required bool compact}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        spacing: 8,
        runSpacing: 4,
        children: [
          SegmentedButton<EditorMode>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(
                value: EditorMode.raw,
                icon: const Icon(Icons.code),
                label: compact ? null : const Text('Raw'),
                tooltip: 'Raw: plain markdown source (Ctrl+E toggles)',
              ),
              ButtonSegment(
                value: EditorMode.wysiwyg,
                icon: const Icon(Icons.text_format),
                label: compact ? null : const Text('WYSIWYG'),
                tooltip: 'WYSIWYG: formatted markdown (Ctrl+E toggles)',
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setMode(s.first),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dirty)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    'Unsaved',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ),
              _imageButton(),
              IconButton(
                tooltip: 'Revert to saved',
                icon: const Icon(Icons.undo),
                onPressed: dirty && !_saving ? revert : null,
              ),
              FilledButton.icon(
                key: const ValueKey('note-save'),
                onPressed: dirty && !_saving ? save : null,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
