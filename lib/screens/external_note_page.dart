import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/external_document.dart';
import '../services/preferences.dart';
import '../widgets/note_editor.dart';

/// Edits one text file another app handed over (see [ExternalDocument]),
/// with the regular note editor. Saving writes back to that app; leaving
/// saves first and then returns to it.
class ExternalNotePage extends StatefulWidget {
  const ExternalNotePage({
    super.key,
    required this.document,
    required this.preferences,
    this.store,
    this.onClose,
  });

  final ExternalDocument document;
  final PreferencesService preferences;

  /// Defaults to an [ExternalNoteStore] on [document]; tests pass a fake.
  final ExternalNoteStore? store;

  /// Called once edits are saved and the page should go away. Defaults to
  /// popping it, or closing TurboNotes when it is the only page, which
  /// returns to the app the file came from.
  final VoidCallback? onClose;

  @override
  State<ExternalNotePage> createState() => _ExternalNotePageState();
}

class _ExternalNotePageState extends State<ExternalNotePage> {
  final GlobalKey<NoteEditorState> _editor = GlobalKey();
  late final ExternalNoteStore _store =
      widget.store ?? ExternalNoteStore(widget.document);
  EditorMode? _mode;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _loadMode();
  }

  Future<void> _loadMode() async {
    // Plain text has no Markdown to render.
    final mode = widget.document.isMarkdown
        ? await widget.preferences.editorMode()
        : EditorMode.raw;
    if (mounted) setState(() => _mode = mode);
  }

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      SystemNavigator.pop();
    }
  }

  Future<void> _onPop(bool didPop) async {
    if (didPop) return;
    final editor = _editor.currentState;
    if (editor != null && !await editor.saveBeforeLeave()) return;
    if (!mounted) return;
    setState(() => _dirty = false);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    final mode = _mode;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _onPop(didPop),
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${document.name}${_dirty ? ' •' : ''}',
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                document.writable
                    ? 'Saved back to the app it came from'
                    : 'Opened read-only',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        body: SafeArea(
          child: mode == null
              ? const Center(child: CircularProgressIndicator())
              : NoteEditor(
                  key: _editor,
                  store: _store,
                  path: document.name,
                  initialMode: mode,
                  onDirtyChanged: (d) => setState(() => _dirty = d),
                  onLeave: () => Navigator.of(context).maybePop(),
                ),
        ),
      ),
    );
  }
}
