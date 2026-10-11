import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'note_store.dart';
import 'sync_objects.dart';
import 'sync_state.dart';
import 'text_merge.dart';

const kSyncPrefix = 'turbonotes-sync/v1/';
final _revisionId = RegExp(r'^[0-9a-f]{64}$');

class UnsyncableNotePathException implements Exception {
  const UnsyncableNotePathException(this.path);
  final String path;
}

class SyncResult {
  int notes = 0;
  final List<String> conflicts = [];
}

/// Manual two-way sync. Revisions form a content-addressed DAG: simultaneous
/// uploads create branches, never overwrite another device's text. There is
/// no mutable manifest, server-side lock or requirement for conditional PUT.
/// Deletions are deliberately not propagated; missing files are restored.
class NoteSync {
  NoteSync({required this.store, required this.objects, required this.state});

  final NoteStore store;
  final SyncObjects objects;
  final SyncState state;
  bool _running = false;

  Future<SyncResult> run() async {
    if (_running) throw StateError('Sync is already running.');
    _running = true;
    try {
      return await _run();
    } finally {
      _running = false;
    }
  }

  Future<SyncResult> _run() async {
    final known = await state.load();
    final localPaths = (await store.list()).toSet();
    for (final path in localPaths) {
      _validateLocalPath(path);
    }
    final graph = <String, Map<String, _Revision>>{};
    final keys = await objects.list(kSyncPrefix);
    for (final key in keys) {
      if (!key.startsWith(kSyncPrefix)) {
        throw const FormatException('Invalid sync object listing.');
      }
      final parts = key.substring(kSyncPrefix.length).split('/');
      if (parts.length != 2 || !parts[1].endsWith('.json')) {
        throw const FormatException('Invalid sync revision key.');
      }
      final id = parts[1].substring(0, parts[1].length - 5);
      final revision = await _readRevision(parts[0], id);
      graph.putIfAbsent(revision.path, () => {})[id] = revision;
    }
    // Lists are not snapshots: a parent may not have appeared on the page
    // already read. Fetch it by its immutable key before considering heads.
    for (final entry in graph.entries) {
      final pending = entry.value.values.expand((r) => r.parents).toList();
      for (var i = 0; i < pending.length; i++) {
        final id = pending[i];
        if (entry.value.containsKey(id)) continue;
        final revision = await _readRevision(_encodePath(entry.key), id);
        entry.value[id] = revision;
        pending.addAll(revision.parents);
      }
    }
    final result = SyncResult();
    final paths = {...localPaths, ...graph.keys}.toList()..sort();
    for (final path in paths) {
      final revisions = graph.putIfAbsent(path, () => {});
      final previousId = known[path];
      if (previousId != null && !revisions.containsKey(previousId)) {
        throw const FormatException(
          'Sync history is missing. Restore the bucket or use a new bucket.',
        );
      }
      final local = await _localText(path);
      final previous = previousId == null ? null : revisions[previousId];
      String? preferred;
      if (local != null) {
        if (previous?.text == local) {
          preferred = previousId;
        } else {
          // Persist the exact local version before attempting any merge.
          final revision = _Revision(path, local, [?previousId]);
          await _publish(path, revision, revisions);
          preferred = revision.id;
        }
      }
      final parents = revisions.values.expand((r) => r.parents).toSet();
      final heads = revisions.keys.where((id) => !parents.contains(id)).toList()
        ..sort();
      if (heads.isEmpty) continue;
      if (heads.remove(preferred)) heads.insert(0, preferred!);
      var text = revisions[heads.first]!.text;
      final combined = <String>[heads.first];
      for (final id in heads.skip(1)) {
        final ancestor = _commonAncestor(revisions, combined, id);
        final remote = revisions[id]!.text;
        final merged = mergeNoteText(ancestor?.text, text, remote);
        if (merged == null) {
          final copy = await _conflictCopy(path, remote);
          if (!result.conflicts.contains(copy)) result.conflicts.add(copy);
          // A conflict copy is part of this sync, not left for the next run.
          final copyRevision = _Revision(copy, remote, const []);
          await _publish(copy, copyRevision, <String, _Revision>{});
        } else {
          text = merged;
        }
        combined.add(id);
      }
      // The app keeps its editors away while sync runs; a native capture or
      // external writer can still change the folder. Stop rather than clobber.
      if (await _localText(path) != local) {
        throw FileSystemException('Note changed during sync; sync again', path);
      }
      if (local == null) {
        await store.create(path, text);
      } else if (local != text) {
        await store.replaceForSync(path, local, text);
      }
      final head = heads.length == 1
          ? revisions[heads.single]!
          : _Revision(path, text, heads);
      if (heads.length > 1) await _publish(path, head, revisions);
      known[path] = head.id;
      // Per-note durable checkpoint; a later error never advances other notes.
      await state.save(known);
      result.notes++;
    }
    return result;
  }

  Future<String?> _localText(String path) async {
    try {
      return await store.read(path);
    } on PathNotFoundException {
      return null;
    }
  }

  Future<_Revision> _readRevision(String pathHash, String id) async {
    if (!_revisionId.hasMatch(id) || !_revisionId.hasMatch(pathHash)) {
      throw const FormatException('Invalid sync revision key.');
    }
    final bytes = await objects.read('$kSyncPrefix$pathHash/$id.json');
    if (bytes.length > 8 * 1024 * 1024 ||
        sha256.convert(bytes).toString() != id) {
      throw const FormatException('Damaged sync revision.');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['v'] != 1 ||
        value['path'] is! String ||
        value['text'] is! String ||
        value['parents'] is! List ||
        (value['parents'] as List).any(
          (id) => id is! String || !_revisionId.hasMatch(id),
        )) {
      throw const FormatException('Invalid sync revision.');
    }
    final path = value['path'] as String;
    if (!isNotePath(path) ||
        normalizeNotePath(path) != path ||
        _encodePath(path) != pathHash) {
      throw const FormatException('Invalid sync note path.');
    }
    final revision = _Revision(
      path,
      value['text'] as String,
      (value['parents'] as List).cast<String>(),
    );
    if (revision.id != id) {
      throw const FormatException('Noncanonical sync revision.');
    }
    return revision;
  }

  Future<void> _publish(
    String path,
    _Revision revision,
    Map<String, _Revision> graph,
  ) async {
    _validateLocalPath(path);
    if (revision.bytes.length > 8 * 1024 * 1024) {
      throw FileSystemException(
        'Note is too large to sync (8 MiB revision limit)',
        path,
      );
    }
    if (!graph.containsKey(revision.id)) {
      await objects.write(_key(path, revision.id), revision.bytes);
      graph[revision.id] = revision;
    }
  }

  Future<String> _conflictCopy(String path, String text) async {
    for (var i = 1; ; i++) {
      final copy = _conflictPath(path, i);
      final existing = await _localText(copy);
      if (existing == text) return copy;
      if (existing != null) continue;
      try {
        await store.create(copy, text);
        return copy;
      } on NoteExistsException {
        // Another writer used the name after the read. Try the next one.
      }
    }
  }
}

void _validateLocalPath(String path) {
  try {
    if (isNotePath(path) && normalizeNotePath(path) == path) return;
  } on InvalidNotePathException {
    // A store listing must round-trip exactly, before reading or publishing it.
  }
  throw UnsyncableNotePathException(path);
}

// Common filesystems cap each name at 255 UTF-8 bytes. Keep the requested
// suffix, and disambiguate shortened stems by the original path's hash.
String _conflictPath(String path, int index) {
  final stem = p.posix.basenameWithoutExtension(path);
  var suffix = '${index == 1 ? '' : '-$index'}-sync-conflict.md';
  var name = '$stem$suffix';
  if (utf8.encode(name).length > 255) {
    suffix = '-${_encodePath(path).substring(0, 12)}$suffix';
    final budget = 255 - utf8.encode(suffix).length;
    final shortened = StringBuffer();
    var used = 0;
    for (final rune in stem.runes) {
      final character = String.fromCharCode(rune);
      final size = utf8.encode(character).length;
      if (used + size > budget) break;
      shortened.write(character);
      used += size;
    }
    name = '$shortened$suffix';
  }
  final folder = p.posix.dirname(path);
  return folder == '.' ? name : p.posix.join(folder, name);
}

String _encodePath(String path) => sha256.convert(utf8.encode(path)).toString();
String _key(String path, String id) =>
    '$kSyncPrefix${_encodePath(path)}/$id.json';

class _Revision {
  _Revision(this.path, this.text, List<String> parents)
    : parents = parents.toSet().toList()..sort();
  final String path;
  final String text;
  final List<String> parents;
  late final List<int> bytes = utf8.encode(
    jsonEncode({'v': 1, 'path': path, 'text': text, 'parents': parents}),
  );
  late final String id = sha256.convert(bytes).toString();
}

Set<String> _ancestors(Map<String, _Revision> graph, Iterable<String> heads) {
  final seen = <String>{};
  final pending = heads.toList();
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (seen.add(id)) pending.addAll(graph[id]!.parents);
  }
  return seen;
}

_Revision? _commonAncestor(
  Map<String, _Revision> graph,
  List<String> left,
  String right,
) {
  // For a partially combined set, only ancestors shared by every branch can
  // serve as a base. Multiple incomparable bases are conservatively conflicts.
  var common = _ancestors(graph, [right]);
  for (final id in left) {
    common = common.intersection(_ancestors(graph, [id]));
  }
  final older = <String>{};
  for (final id in common) {
    older.addAll(_ancestors(graph, graph[id]!.parents));
  }
  final newest = common.difference(older);
  return newest.length == 1 ? graph[newest.single] : null;
}
