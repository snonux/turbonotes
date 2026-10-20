import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/external_note_page.dart';
import 'screens/home_screen.dart';
import 'services/external_document.dart';
import 'services/listing_cache.dart';
import 'services/note_link.dart';
import 'services/preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Started by another app's "Edit" or "Open with" for one of its files.
  final document = await ExternalDocument.initial();
  // Notes other apps ask for (Player's "Note in TurboNotes"): the one the
  // app was started with, then any arriving while it runs. The stream
  // buffers them until the home screen has its notes folder open.
  final links = StreamController<NoteLink>();
  final link = await NoteLink.initial();
  if (link != null) links.add(link);
  NoteLink.listen(links.add);
  runApp(
    TurboNotesApp(
      preferences: PreferencesService(),
      document: document,
      links: links.stream,
    ),
  );
}

final _navigator = GlobalKey<NavigatorState>();

class TurboNotesApp extends StatefulWidget {
  const TurboNotesApp({
    super.key,
    required this.preferences,
    this.document,
    this.links,
  });

  final PreferencesService preferences;

  /// Notes other apps ask to open, see [HomeScreen.links].
  final Stream<NoteLink>? links;

  /// A file handed over by another app, edited instead of the notes folder.
  final ExternalDocument? document;

  @override
  State<TurboNotesApp> createState() => _TurboNotesAppState();
}

class _TurboNotesAppState extends State<TurboNotesApp> {
  @override
  void initState() {
    super.initState();
    // Another file handed over while TurboNotes is already open.
    ExternalDocument.listen(
      (document) => _navigator.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => ExternalNotePage(
            document: document,
            preferences: widget.preferences,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    return MaterialApp(
      title: 'TurboNotes',
      navigatorKey: _navigator,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: document != null
          ? ExternalNotePage(
              document: document,
              preferences: widget.preferences,
            )
          : HomeScreen(
              preferences: widget.preferences,
              listingCache: FileListingCache(),
              links: widget.links,
            ),
    );
  }
}
