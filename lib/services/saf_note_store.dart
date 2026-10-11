import 'dart:io';

import 'package:flutter/services.dart';

import 'note_store.dart';

/// Notes inside an Android document tree picked with the system folder
/// picker. The read/write grant was persisted when the user selected it; the
/// URI is an opaque provider identifier, never a filesystem path.
class SafNoteStore implements NoteStore {
  SafNoteStore(this.treeUri, this.label, {MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('org.buetow.turbonotes/saf-notes') {
    if (treeUri.isEmpty) throw ArgumentError.value(treeUri, 'treeUri');
  }

  final String treeUri;
  @override
  final String label;
  final MethodChannel _channel;

  Future<T?> _call<T>(String method, [Map<String, Object>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, {
        'treeUri': treeUri,
        ...?args,
      });
    } on PlatformException catch (e) {
      // For a rename, what is missing is the source; what exists, the target.
      String path(String renameKey) =>
          (args?['path'] ?? args?[renameKey] ?? '') as String;
      switch (e.code) {
        case 'not_found':
          throw PathNotFoundException(
            path('from'),
            OSError(e.message ?? 'Not found'),
          );
        case 'exists':
          throw NoteExistsException(path('to'));
      }
      rethrow;
    }
  }

  @override
  Future<List<String>> list() async {
    final paths = await _call<List<Object?>>('list');
    if (paths == null) {
      throw StateError('The document provider returned no listing.');
    }
    return paths.whereType<String>().where(isNotePath).toList()..sort();
  }

  @override
  Future<String> read(String path) async {
    final text = await _call<String>('read', {'path': normalizeNotePath(path)});
    if (text == null) {
      throw StateError('The document provider returned no note.');
    }
    return text;
  }

  @override
  Future<void> write(String path, String text) =>
      _call<void>('write', {'path': normalizeNotePath(path), 'text': text});

  @override
  Future<void> replaceForSync(String path, String expected, String text) =>
      _call<void>('replaceForSync', {
        'path': normalizeNotePath(path),
        'expected': expected,
        'text': text,
      });

  @override
  Future<void> create(String path, String text) =>
      _call<void>('create', {'path': normalizeNotePath(path), 'text': text});

  @override
  Future<void> delete(String path) =>
      _call<void>('delete', {'path': normalizeNotePath(path)});

  @override
  Future<void> rename(String from, String to) => _call<void>('rename', {
    'from': normalizeNotePath(from),
    'to': normalizeNotePath(to),
  });

  @override
  Future<Uint8List> readBytes(String path) async {
    final bytes = await _call<Uint8List>('readBytes', {
      'path': normalizeAttachmentPath(path),
    });
    if (bytes == null) {
      throw StateError('The document provider returned no file.');
    }
    return bytes;
  }

  @override
  Future<void> createBytes(String path, Uint8List bytes) => _call<void>(
    'createBytes',
    {'path': normalizeAttachmentPath(path), 'bytes': bytes},
  );
}
