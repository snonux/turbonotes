import 'package:flutter/material.dart';

import 'screens/external_note_page.dart';
import 'screens/home_screen.dart';
import 'services/external_document.dart';
import 'services/preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Started by another app's "Edit" or "Open with" for one of its files.
  final document = await ExternalDocument.initial();
  runApp(TurboNotesApp(preferences: PreferencesService(), document: document));
}

final _navigator = GlobalKey<NavigatorState>();

class TurboNotesApp extends StatefulWidget {
  const TurboNotesApp({super.key, required this.preferences, this.document});

  final PreferencesService preferences;

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
          : HomeScreen(preferences: widget.preferences),
    );
  }
}
