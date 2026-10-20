import 'dart:io';

import 'package:flutter/services.dart';

const _linksChannel = MethodChannel('org.buetow.turbonotes/links');

/// A note another app asked TurboNotes to open (Android only), such as
/// Player's "Note in TurboNotes" button for the audiobook or podcast
/// episode playing. The Kotlin half is `NoteLinks.kt`: an
/// `org.buetow.turbonotes.OPEN_NOTE` intent with the note's path relative
/// to the notes folder and, optionally, a title for the heading of a new
/// note. A note that does not exist yet is created.
class NoteLink {
  const NoteLink({required this.path, this.title});

  /// The note's path in the notes folder, e.g. `Book-And-Podcast-Notes/Dune.md`.
  /// Not yet validated: it comes from another app.
  final String path;

  /// The heading for the note if it has to be created, e.g. `Dune`.
  final String? title;

  static NoteLink? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.trim().isEmpty) return null;
    final title = raw['title'];
    final heading = title is String
        ? title.replaceAll(RegExp(r'\s+'), ' ').trim()
        : '';
    return NoteLink(path: path, title: heading.isEmpty ? null : heading);
  }

  /// The link the app was started with, if any.
  static Future<NoteLink?> initial({MethodChannel? channel}) async {
    if (!Platform.isAndroid && channel == null) return null;
    try {
      return fromMap(
        await (channel ?? _linksChannel).invokeMethod<Object?>('initialLink'),
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Calls [onOpen] for links arriving while the app is running.
  static void listen(
    void Function(NoteLink link) onOpen, {
    MethodChannel? channel,
  }) {
    (channel ?? _linksChannel).setMethodCallHandler((call) async {
      if (call.method != 'open') return;
      final link = fromMap(call.arguments);
      if (link != null) onOpen(link);
    });
  }
}
