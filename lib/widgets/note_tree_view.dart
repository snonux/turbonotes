import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/note_tree.dart';
import '../services/tags.dart';

/// Sections of the side list that fold away.
enum SidebarSection { pinned, recent, tags }

/// How many recent notes the Recent section lists.
const kRecentShown = 5;

/// The row under the keyboard cursor, for commands [NoteTreeView.onKey]
/// handles: its note, and the folder new notes go into from there.
typedef TreeTarget = ({String? note, String? folder});

/// The notes folder as a collapsible tree, with Pinned, Recent and Tags
/// sections above it. Folders sort first; a folder row shows how many notes
/// it holds, recursively. With a [tagFilter], the tree only holds the notes
/// carrying that tag, every folder open.
///
/// With [focusNode] focused, vi keys move a cursor through the rows: `j`/`k`
/// (or the arrows), `gg`/`G`, `h`/`l` to close and open folders, Enter to
/// open. Other keys go to [onKey].
class NoteTreeView extends StatefulWidget {
  const NoteTreeView({
    super.key,
    required this.root,
    required this.expanded,
    required this.selected,
    required this.onToggleFolder,
    required this.onOpen,
    this.onNoteMenu,
    this.pinned = const [],
    this.recent = const [],
    this.tags,
    this.hasTags = false,
    this.tagFilter,
    this.onTagFilter,
    this.expandedTags = const {},
    this.onToggleTag,
    this.collapsed = const {},
    this.onToggleSection,
    this.focusNode,
    this.onOpenFocused,
    this.onKey,
  });

  final NoteFolder root;
  final Set<String> expanded;
  final String? selected;
  final ValueChanged<String> onToggleFolder;
  final ValueChanged<String> onOpen;

  /// Long-press / secondary-click on a note, e.g. for rename and delete.
  final void Function(String path, Offset globalPosition)? onNoteMenu;

  /// Pinned notes, in pin order; only ones that exist.
  final List<String> pinned;

  /// Recently opened notes, newest first; only ones that exist.
  final List<String> recent;

  /// The tag tree; null or empty hides the Tags section unless [hasTags].
  /// May be null while the section is collapsed.
  final TagNode? tags;

  /// Shows the Tags section header even without [tags], for a collapsed
  /// section whose tree has not been worked out.
  final bool hasTags;
  final String? tagFilter;

  /// Picks a tag to filter the tree by, or null to show every note.
  final ValueChanged<String?>? onTagFilter;
  final Set<String> expandedTags;
  final ValueChanged<String>? onToggleTag;

  final Set<SidebarSection> collapsed;
  final ValueChanged<SidebarSection>? onToggleSection;

  /// Takes the keyboard for the vi keys.
  final FocusNode? focusNode;

  /// Enter on a note: open it and put the keyboard in it. Falls back to
  /// [onOpen].
  final ValueChanged<String>? onOpenFocused;

  /// A key the tree does not handle itself (a character, or `<C-w>l`) with
  /// the row under the cursor; returns whether it did something.
  final bool Function(String key, TreeTarget target)? onKey;

  @override
  State<NoteTreeView> createState() => _NoteTreeViewState();
}

/// One row of the list, and what the keyboard can do with it.
class _Row {
  const _Row(
    this.child, {
    this.id,
    this.parent,
    this.open,
    this.activate,
    this.toggle,
    this.note,
    this.folder,
  });

  final Widget child;

  /// The row's key (`note:a.md`, `folder:x`, `section:tags`, ...); null
  /// for rows the cursor skips.
  final String? id;

  /// The row `h` goes to.
  final String? parent;

  /// Whether the row is open; null when it does not open.
  final bool? open;
  final VoidCallback? activate;
  final VoidCallback? toggle;
  final String? note;
  final String? folder;
}

class _NoteTreeViewState extends State<NoteTreeView> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _cursorKey = GlobalKey();

  /// The id of the row under the cursor.
  String? _cursor;
  int _cursorIndex = 0;
  bool _focused = false;

  /// The cursor shows once the keyboard is used here, not for a tap.
  bool _keyboard = false;

  /// Keys of a command typed so far: a count, `g`, or Ctrl+W.
  String _pending = '';
  List<_Row> _rows = const [];

  NoteTreeView get w => widget;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = <_Row>[];
    final filter = w.tagFilter;
    final pinned = w.pinned;
    final recent = w.recent;
    final collapsed = w.collapsed;

    if (filter != null) rows.add(_filterBar(context, filter));
    if (pinned.isNotEmpty) {
      rows.add(
        _header(context, SidebarSection.pinned, 'Pinned', Icons.push_pin),
      );
      if (!collapsed.contains(SidebarSection.pinned)) {
        for (final path in pinned) {
          rows.add(_noteRow(context, path, 0, prefix: 'pinned'));
        }
      }
    }
    if (recent.isNotEmpty) {
      rows.add(
        _header(context, SidebarSection.recent, 'Recent', Icons.history),
      );
      if (!collapsed.contains(SidebarSection.recent)) {
        for (final path in recent.take(kRecentShown)) {
          rows.add(_noteRow(context, path, 0, prefix: 'recent'));
        }
      }
    }
    final tagRoot = w.tags;
    if (w.hasTags || (tagRoot != null && tagRoot.children.isNotEmpty)) {
      rows.add(_header(context, SidebarSection.tags, 'Tags', Icons.tag));
      if (tagRoot != null && !collapsed.contains(SidebarSection.tags)) {
        void walkTags(TagNode node, int depth) {
          for (final child in node.children) {
            rows.add(
              _tagRow(
                context,
                child,
                depth,
                depth == 0 ? 'section:tags' : 'tag:${node.tag}',
              ),
            );
            if (w.expandedTags.contains(child.tag)) {
              walkTags(child, depth + 1);
            }
          }
        }

        walkTags(tagRoot, 0);
      }
    }
    final sections = rows.isNotEmpty;
    final firstNote = rows.length;
    void walk(NoteFolder folder, int depth) {
      for (final child in folder.folders) {
        rows.add(_folderRow(context, child, depth));
        if (filter != null || w.expanded.contains(child.path)) {
          walk(child, depth + 1);
        }
      }
      for (final note in folder.notes) {
        rows.add(_noteRow(context, note, depth));
      }
    }

    walk(w.root, 0);
    final noNotes = rows.length == firstNote;
    if (noNotes && filter == null && !sections) {
      _rows = const [];
      return _keys(
        const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No markdown notes in this folder yet.\nUse the new-note button to create one.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    if (sections) {
      rows.insert(
        firstNote,
        _Row(_plainHeader(context, 'Notes', Icons.folder_outlined)),
      );
    }
    if (noNotes) {
      rows.add(
        _Row(
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              filter == null
                  ? 'No markdown notes in this folder yet.'
                  : 'No notes tagged #$filter.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ),
      );
    }
    _rows = rows;
    _keepCursor();
    final showCursor = _focused && _keyboard;
    final outline = Theme.of(context).colorScheme.primary;
    return _keys(
      ListView.builder(
        key: const PageStorageKey('note-tree'),
        controller: _scroll,
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final row = rows[i];
          final id = row.id;
          if (id == null) return row.child;
          final current = id == _cursor;
          return Listener(
            key: current ? _cursorKey : null,
            onPointerDown: (_) {
              _cursor = id;
              if (_keyboard) setState(() => _keyboard = false);
            },
            child: current && showCursor
                ? Container(
                    key: const ValueKey('tree-cursor'),
                    foregroundDecoration: BoxDecoration(
                      border: Border.all(color: outline, width: 1.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: row.child,
                  )
                : row.child,
          );
        },
      ),
    );
  }

  // ----------------------------------------------------------- keyboard

  Widget _keys(Widget child) => Focus(
    focusNode: w.focusNode,
    onFocusChange: _onFocusChange,
    onKeyEvent: _onKey,
    child: child,
  );

  List<_Row> get _nav => [
    for (final r in _rows)
      if (r.id != null) r,
  ];

  void _onFocusChange(bool focused) {
    // Focus that arrives with a key down (Esc or Ctrl+W h in the editor)
    // came from the keyboard.
    final byKey = HardwareKeyboard.instance.logicalKeysPressed.isNotEmpty;
    setState(() {
      _focused = focused;
      if (focused && byKey) _keyboard = true;
      if (focused) {
        _pending = '';
        _cursor ??= w.selected == null ? null : 'note:${w.selected}';
        _keepCursor();
      }
    });
    if (focused) _reveal();
  }

  /// Keeps the cursor on a row that exists: one that went away (a deleted
  /// note, a closed folder) leaves the cursor on the row now at its place.
  void _keepCursor() {
    final nav = _nav;
    if (nav.isEmpty) {
      _cursor = null;
      return;
    }
    final i = nav.indexWhere((r) => r.id == _cursor);
    if (i >= 0) {
      _cursorIndex = i;
      return;
    }
    _cursorIndex = _cursorIndex.clamp(0, nav.length - 1);
    _cursor = nav[_cursorIndex].id;
  }

  _Row? get _current {
    final nav = _nav;
    final i = nav.indexWhere((r) => r.id == _cursor);
    return i < 0 ? null : nav[i];
  }

  void _moveTo(int index) {
    final nav = _nav;
    if (nav.isEmpty) return;
    setState(() {
      _cursorIndex = index.clamp(0, nav.length - 1);
      _cursor = nav[_cursorIndex].id;
    });
    _reveal();
  }

  void _moveToId(String id) {
    final i = _nav.indexWhere((r) => r.id == id);
    if (i >= 0) _moveTo(i);
  }

  /// Scrolls the cursor's row into view.
  void _reveal({bool estimate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final row = _cursorKey.currentContext;
      if (row != null) {
        Scrollable.ensureVisible(
          row,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
        Scrollable.ensureVisible(
          row,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        return;
      }
      // Not built yet, far off screen: jump near it, then align.
      if (!estimate || !_scroll.hasClients) return;
      final i = _rows.indexWhere((r) => r.id == _cursor);
      if (i < 0) return;
      final position = _scroll.position;
      _scroll.jumpTo(
        (position.maxScrollExtent * i / _rows.length).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
      _reveal(estimate: false);
    });
  }

  static final _named = {
    LogicalKeyboardKey.arrowDown: 'j',
    LogicalKeyboardKey.arrowUp: 'k',
    LogicalKeyboardKey.arrowLeft: 'h',
    LogicalKeyboardKey.arrowRight: 'l',
    LogicalKeyboardKey.enter: '<CR>',
    LogicalKeyboardKey.numpadEnter: '<CR>',
    LogicalKeyboardKey.escape: '<Esc>',
    LogicalKeyboardKey.home: '<Home>',
    LogicalKeyboardKey.end: 'G',
    LogicalKeyboardKey.pageDown: '<PageDown>',
    LogicalKeyboardKey.pageUp: '<PageUp>',
    LogicalKeyboardKey.contextMenu: 'm',
  };

  static final _modifiers = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_modifiers.contains(key)) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    if (_pending == '<C-w>') {
      _pending = '';
      if (key == LogicalKeyboardKey.keyL ||
          key == LogicalKeyboardKey.keyW ||
          key == LogicalKeyboardKey.keyP) {
        w.onKey?.call('<C-w>l', _target);
      }
      return KeyEventResult.handled;
    }
    if (hw.isControlPressed || hw.isAltPressed || hw.isMetaPressed) {
      if (key == LogicalKeyboardKey.keyW &&
          hw.isControlPressed &&
          !hw.isShiftPressed) {
        _pending = '<C-w>';
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // Ctrl+P and friends: the screen's.
    }
    final c = event.character;
    final name =
        _named[key] ??
        (c != null && c.isNotEmpty && c.codeUnitAt(0) >= 0x20 ? c : null);
    if (name == null) return KeyEventResult.ignored;
    if (!_keyboard) setState(() => _keyboard = true);
    return _command(name) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  TreeTarget get _target {
    final row = _current;
    final note = row?.note;
    return (
      note: note,
      folder: row?.folder ?? (note == null ? null : parentPath(note)),
    );
  }

  bool _command(String key) {
    // A count before j and k: 5j.
    final digit = key.length == 1 && '0123456789'.contains(key);
    if (digit && !(key == '0' && _pending.isEmpty)) {
      if (_pending == 'g') _pending = '';
      setState(() => _pending += key);
      return true;
    }
    final count = int.tryParse(_pending) ?? 1;
    final pending = _pending;
    _pending = '';
    if (pending == 'g' && key == 'g') {
      _moveTo(0);
      return true;
    }
    final row = _current;
    switch (key) {
      case 'j':
        _moveTo(_cursorIndex + count);
      case 'k':
        _moveTo(_cursorIndex - count);
      case '<PageDown>':
        _moveTo(_cursorIndex + 10);
      case '<PageUp>':
        _moveTo(_cursorIndex - 10);
      case '<Home>':
        _moveTo(0);
      case 'g':
        setState(() => _pending = 'g');
      case 'G':
        _moveTo(_nav.length - 1);
      case '<CR>':
      case 'o':
      case ' ':
        _activate(row);
      case 'l':
        if (row == null) return true;
        if (row.open == false) {
          row.toggle?.call();
        } else if (row.open == true) {
          final next = _cursorIndex + 1;
          final nav = _nav;
          if (next < nav.length && nav[next].parent == row.id) _moveTo(next);
        } else {
          _activate(row);
        }
      case 'h':
        if (row == null) return true;
        if (row.open == true && row.toggle != null) {
          row.toggle!();
        } else if (row.parent != null) {
          _moveToId(row.parent!);
        }
      case 'm':
        final note = row?.note;
        final at = _cursorKey.currentContext;
        if (note != null && at != null) {
          w.onNoteMenu?.call(note, _boxOf(at));
        }
      case '<Esc>':
        if (w.tagFilter == null) return pending.isNotEmpty;
        w.onTagFilter?.call(null);
      default:
        final handled = w.onKey?.call(key, _target) ?? false;
        // Unbound letters are swallowed too, so nothing else reacts to them.
        return handled || key.length == 1;
    }
    return true;
  }

  void _activate(_Row? row) {
    if (row == null) return;
    final note = row.note;
    if (note != null) {
      (w.onOpenFocused ?? w.onOpen)(note);
    } else {
      row.activate?.call();
    }
  }

  _Row _filterBar(BuildContext context, String filter) {
    final child = Padding(
      key: const ValueKey('tag-filter'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InputChip(
          avatar: const Icon(Icons.filter_alt_outlined, size: 18),
          label: Text('#$filter'),
          tooltip: 'Showing notes tagged #$filter',
          onDeleted: () => w.onTagFilter?.call(null),
          deleteButtonTooltipMessage: 'Show all notes',
        ),
      ),
    );
    return _Row(
      child,
      id: 'tag-filter',
      activate: () => w.onTagFilter?.call(null),
    );
  }

  _Row _header(
    BuildContext context,
    SidebarSection section,
    String title,
    IconData icon,
  ) {
    final open = !w.collapsed.contains(section);
    final toggle = w.onToggleSection == null
        ? null
        : () => w.onToggleSection!(section);
    return _Row(
      InkWell(
        key: ValueKey('section:${section.name}'),
        canRequestFocus: false,
        onTap: toggle,
        child: _headerContent(
          context,
          title,
          icon,
          trailing: Icon(
            open ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
        ),
      ),
      id: 'section:${section.name}',
      open: open,
      toggle: toggle,
      activate: toggle,
    );
  }

  Widget _plainHeader(BuildContext context, String title, IconData icon) =>
      _headerContent(context, title, icon);

  Widget _headerContent(
    BuildContext context,
    String title,
    IconData icon, {
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  _Row _tagRow(BuildContext context, TagNode node, int depth, String parent) {
    final theme = Theme.of(context);
    final active = node.tag == w.tagFilter;
    final hasChildren = node.children.isNotEmpty;
    final open = w.expandedTags.contains(node.tag);
    void filter() => w.onTagFilter?.call(active ? null : node.tag);
    final child = Material(
      color: active ? theme.colorScheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        key: ValueKey('tag:${node.tag}'),
        canRequestFocus: false,
        onTap: filter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(8.0 + depth * 16.0, 4, 12, 4),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: hasChildren
                    ? IconButton(
                        key: ValueKey('tag-toggle:${node.tag}'),
                        padding: EdgeInsets.zero,
                        iconSize: 20,
                        tooltip: open ? 'Collapse' : 'Expand',
                        onPressed: () => w.onToggleTag?.call(node.tag),
                        icon: Icon(
                          open ? Icons.expand_more : Icons.chevron_right,
                        ),
                      )
                    : null,
              ),
              Text(
                '#',
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  node.name,
                  overflow: TextOverflow.ellipsis,
                  style: active
                      ? const TextStyle(fontWeight: FontWeight.w600)
                      : null,
                ),
              ),
              Text(
                '${node.notes.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return _Row(
      child,
      id: 'tag:${node.tag}',
      parent: parent,
      open: hasChildren ? open : null,
      toggle: hasChildren ? () => w.onToggleTag?.call(node.tag) : null,
      activate: filter,
    );
  }

  _Row _folderRow(BuildContext context, NoteFolder folder, int depth) {
    final theme = Theme.of(context);
    final indent = 8.0 + depth * 16.0;
    final filtered = w.tagFilter != null;
    final open = filtered || w.expanded.contains(folder.path);
    final toggle = filtered ? null : () => w.onToggleFolder(folder.path);
    final parent = parentPath(folder.path);
    final child = InkWell(
      key: ValueKey('folder:${folder.path}'),
      canRequestFocus: false,
      onTap: toggle,
      child: Padding(
        padding: EdgeInsets.fromLTRB(indent, 8, 12, 8),
        child: Row(
          children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right, size: 20),
            const SizedBox(width: 2),
            Icon(
              open ? Icons.folder_open : Icons.folder,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(folder.name, overflow: TextOverflow.ellipsis)),
            Text(
              '${folder.noteCount}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
    return _Row(
      child,
      id: 'folder:${folder.path}',
      parent: parent.isEmpty ? null : 'folder:$parent',
      open: filtered ? null : open,
      toggle: toggle,
      activate: toggle,
      folder: folder.path,
    );
  }

  /// A note row. Pinned and recent rows ([prefix]) show the folder too,
  /// since they sit outside the tree.
  _Row _noteRow(
    BuildContext context,
    String path,
    int depth, {
    String prefix = 'note',
  }) {
    final theme = Theme.of(context);
    final indent = 8.0 + depth * 16.0;
    final isSelected = path == w.selected;
    final inTree = prefix == 'note';
    final folder = parentPath(path);
    final onNoteMenu = w.onNoteMenu;
    final child = Material(
      color: isSelected && inTree
          ? theme.colorScheme.secondaryContainer
          : Colors.transparent,
      child: Builder(
        builder: (rowContext) => InkWell(
          key: ValueKey('$prefix:$path'),
          canRequestFocus: false,
          onTap: () => w.onOpen(path),
          onLongPress: onNoteMenu == null
              ? null
              : () => onNoteMenu(path, _boxOf(rowContext)),
          onSecondaryTapUp: onNoteMenu == null
              ? null
              : (d) => onNoteMenu(path, d.globalPosition),
          child: Padding(
            padding: EdgeInsets.fromLTRB(indent + 22, 8, 12, 8),
            child: Row(
              children: [
                Icon(
                  prefix == 'pinned'
                      ? Icons.push_pin_outlined
                      : prefix == 'recent'
                      ? Icons.schedule
                      : Icons.description_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: displayName(path),
                      style: isSelected
                          ? const TextStyle(fontWeight: FontWeight.w600)
                          : null,
                      children: [
                        if (!inTree && folder.isNotEmpty)
                          TextSpan(
                            text: '  $folder',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                      ],
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return _Row(
      child,
      id: '$prefix:$path',
      parent: inTree
          ? (folder.isEmpty ? null : 'folder:$folder')
          : 'section:$prefix',
      note: path,
    );
  }
}

/// The middle of [context]'s box on screen, where its menu opens.
Offset _boxOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null) return Offset.zero;
  return box.localToGlobal(box.size.center(Offset.zero));
}
