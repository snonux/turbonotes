import 'dart:io';

import 'package:flutter/services.dart';

import 'note_store.dart';

const _externalChannel = MethodChannel('org.buetow.turbonotes/external');

/// A text file another app handed over with "Edit" or "Open with" (Android
/// only), such as a file in File Browser. Edits are written back to the
/// same URI, so the app that owns the file sees every save.
class ExternalDocument {
  const ExternalDocument({
    required this.uri,
    required this.name,
    required this.writable,
  });

  /// The document's content:// URI.
  final String uri;

  /// The file name the owning app reports, e.g. `todo.md`.
  final String name;

  /// False when the file was only opened for viewing.
  final bool writable;

  static ExternalDocument? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final uri = raw['uri'];
    if (uri is! String || uri.isEmpty) return null;
    final name = raw['name'];
    return ExternalDocument(
      uri: uri,
      name: name is String && name.isNotEmpty ? name : 'Untitled.txt',
      writable: raw['writable'] == true,
    );
  }

  /// Markdown files open in the preferred editor mode, other text raw.
  bool get isMarkdown => isNotePath(name);

  /// The document the app was started with, if any.
  static Future<ExternalDocument?> initial({MethodChannel? channel}) async {
    if (!Platform.isAndroid && channel == null) return null;
    try {
      return fromMap(
        await (channel ?? _externalChannel).invokeMethod<Object?>(
          'initialDocument',
        ),
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Calls [onOpen] for documents handed over while the app is running.
  static void listen(
    void Function(ExternalDocument document) onOpen, {
    MethodChannel? channel,
  }) {
    (channel ?? _externalChannel).setMethodCallHandler((call) async {
      if (call.method != 'open') return;
      final document = fromMap(call.arguments);
      if (document != null) onOpen(document);
    });
  }
}

/// [NoteStore] over one [ExternalDocument], so the regular note editor (with
/// its autosave and its check for changes made meanwhile) edits it. Its only
/// note is [ExternalDocument.name]; anything else, like adding images next
/// to it, is not possible through a single-file URI.
class ExternalNoteStore implements NoteStore {
  ExternalNoteStore(this.document, {MethodChannel? channel})
    : _channel = channel ?? _externalChannel;

  final ExternalDocument document;
  final MethodChannel _channel;

  @override
  String get label => document.name;

  void _check(String path) {
    if (path != document.name) {
      throw UnsupportedError(
        '${document.name} was opened from another app; '
        'other files next to it cannot be reached.',
      );
    }
  }

  Future<T?> _call<T>(String method, [Map<String, Object>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, {
        'uri': document.uri,
        ...?args,
      });
    } on PlatformException catch (e) {
      if (e.code == 'not_found') {
        throw PathNotFoundException(
          document.name,
          OSError(e.message ?? 'Not found'),
        );
      }
      if (e.code == 'access_denied' && method == 'write') {
        throw FileSystemException(
          '${document.name} was opened read-only; '
          'the app that owns it does not allow saving',
        );
      }
      rethrow;
    }
  }

  @override
  Future<List<String>> list() async => [document.name];

  @override
  Future<String> read(String path) async {
    _check(path);
    final text = await _call<String>('read');
    if (text == null) throw StateError('The app returned no text.');
    return text;
  }

  @override
  Future<void> write(String path, String text) {
    _check(path);
    return _call<void>('write', {'text': text});
  }

  Never _unsupported() => throw UnsupportedError(
    '${document.name} was opened from another app; '
    'only its text can be edited here.',
  );

  @override
  Future<void> replaceForSync(String path, String expected, String text) =>
      _unsupported();

  @override
  Future<void> create(String path, String text) => _unsupported();

  @override
  Future<void> delete(String path) => _unsupported();

  @override
  Future<void> rename(String from, String to) => _unsupported();

  @override
  Future<Uint8List> readBytes(String path) => _unsupported();

  @override
  Future<void> createBytes(String path, Uint8List bytes) => _unsupported();
}
