# Working on TurboNotes

TurboNotes is a Flutter app (Android primary, Linux desktop for development)
that edits every Markdown file in one configured notes folder. It is a sibling
of snonux/quicklog and shares its toolchain, signing and release conventions,
and supports optional S3 sync. Sync is disabled by default and runs only when
the user chooses Sync now. The Android manifest has `INTERNET` permission for
this feature; do not introduce other network use or telemetry.

Before calling anything done: `flutter analyze` and `flutter test` must both be
clean. For anything touching the Android build, build a release APK too --
`flutter build apk --release --split-per-abi` -- because the debug build hides
signing and packaging problems. CI does all three plus a Linux release build.

Toolchain: JDK **17 or 21** only. Gradle 8.14 rejects JDK 25 outright.

## Layout

- `lib/services/note_store.dart` -- the `NoteStore` interface. Notes are
  addressed by relative POSIX paths (`projects/todo.md`), validated by
  `normalizeNotePath`. Two implementations: `DirectoryNoteStore` (dart:io,
  atomic writes) and `SafNoteStore` (Android document tree via the
  `org.buetow.turbonotes/saf-notes` channel, implemented in
  `android/.../SafNotes.kt`). Keep their behaviour identical: same filtering
  (`.md`/`.markdown`, no dot-folders), `create` and `rename` never overwrite.
- `lib/editor/` -- the WYSIWYG editor. `MarkdownStyler` paints the Markdown
  source; it must emit exactly one character per source character (a few are
  substituted 1:1, like `-` -> `•`), or the caret and selection drift. The
  test `emits exactly one character per source character` guards that. Never
  replace this with a converter to another document model: a lossy round trip
  silently reformats people's notes. An inline image off the active line
  hides its source and turns the closing `)` into the `WidgetSpan`
  placeholder, so the count still adds up. The WYSIWYG field needs
  `strutStyle: StrutStyle.disabled`: the default forced strut keeps lines
  from growing around images. Decoded images live in `AttachmentCache`
  (`lib/widgets/note_image.dart`), which relayouts the editor once one loads.
- `lib/editor/vi_engine.dart` -- vi's modal editing (Preferences: Vi keys,
  Linux only, since normal mode needs key events an on-screen keyboard does
  not send). A pure engine on the text controller, tested in
  `test/vi_engine_test.dart`; `NoteEditor` feeds it keys from its
  `FocusNode.onKeyEvent` and makes the field `readOnly` outside insert mode,
  so a command key can never type. The sidebar's own vi keys live in
  `NoteTreeView` and are always on.
- `lib/services/fuzzy.dart` -- the fuzzy matcher behind the finder.
- `lib/services/note_sync.dart` -- manual S3 sync of Markdown notes through
  immutable content-addressed revisions and parent links. Never replace this
  with overwriting a mutable remote note or manifest: Garage does not need
  conditional writes for the revision protocol. `text_merge.dart` combines
  independent edits against a common ancestor without reformatting source;
  unresolved versions go to `*-sync-conflict.md`, never overwriting a copy.
  Sync never propagates deletions. State is scoped to folder and destination
  in app support data, outside the notes. Editors must be saved and closed
  before sync runs; invalidate the search index afterwards.
- `lib/services/note_index.dart`, `text_search.dart`, `tags.dart` -- the
  in-memory text index of all notes behind full-text search (typo tolerant)
  and the `#tag` tree. `HomeScreen` keeps the index current through the
  editor's `onSaved`.
- `lib/services/note_export.dart` -- renders a note offscreen (its own
  `PipelineOwner`/`BuildOwner`; GlobalKeys do not work there) to one PNG or
  to an A4 PDF of page images, written by hand with `dart:io`'s zlib.
  `share_service.dart` hands the result to the Android share sheet, or to the
  clipboard and Downloads on Linux.
- Platform channels besides SAF: `org.buetow.turbonotes/clipboard` (image
  paste; `MainActivity.kt` and `linux/runner/clipboard_channel.cc`),
  `org.buetow.turbonotes/images` (gallery pick and camera, Android only;
  `MainActivity.kt` and `DeviceImages.kt`; the camera writes into a
  `ShareProvider` capture file, so no camera permission is needed) and
  `org.buetow.turbonotes/share` (`MainActivity.kt`, files served by
  `ShareProvider.kt`).
- Files other apps hand over (`ACTION_EDIT`/`ACTION_VIEW` of a `text/*`
  content URI, e.g. File Browser's "Edit in TurboNotes"): `MainActivity`'s
  intent filter, `ExternalDocuments.kt` and the
  `org.buetow.turbonotes/external` channel (`initialDocument`, `read`,
  `write`, and `open` for one arriving while running).
  `lib/services/external_document.dart` wraps the URI in a one-note
  `ExternalNoteStore`, so `ExternalNotePage` reuses `NoteEditor` and its
  autosave and conflict check; `main.dart` opens it instead of
  `HomeScreen`. Writing back to the URI is the whole contract: the other app
  takes it from there.
- Android quick capture is native Kotlin, not Flutter, so it opens without
  starting the engine: `CaptureWidget.kt` (home-screen widget) and
  `CaptureActivity.kt` (the dialog, also the share target) append through
  `DefaultNote.kt`, which reads the Flutter preferences
  (`flutter.ScopedTreeUri`, `flutter.Directory`, `flutter.DefaultNote`).
  Keep those keys in sync with `lib/services/preferences.dart`.
- `lib/screens/home_screen.dart` -- tree plus editor side by side at 760 px
  and wider; narrower, a note opens on its own `NotePage`. Note dialogs
  (path prompt, delete confirmation) live in `lib/widgets/note_dialogs.dart`,
  snackbars and user-facing error text in `lib/widgets/feedback.dart`.
- `lib/widgets/note_editor.dart` -- saves on its own: `saveBeforeLeave()`
  before anything closes the note, and a quiet save when the app goes to the
  background or its window closes. That background save must never overwrite
  a note changed on disk (Syncthing); it writes a conflict copy instead
  (`conflictCopyPath`). Interactive saves ask in the "Changed on disk" dialog.
- User docs: `README.md` (kept short; install points to F-Droid),
  `docs/usage.md` and `docs/install.md`, screenshots in `docs/images/`.
  Screenshots are phone shots only (`phone-*.png`, 400x760), plus tablet
  shots (`tablet-*.png`, 1280x800) only where the wide layout differs; no
  desktop shots except `linux-vi.png` (1280x800), for the Linux-only vi
  keys. Update the docs and shots when the UI changes.

## Releasing

The steps for a new release are in [docs/release.md](docs/release.md). What
must not break in the build:

- The `applicationVariants` block at the bottom of
  `android/app/build.gradle.kts` sets the per-ABI version codes,
  `counter * 10 + abi` (1 armeabi-v7a, 2 arm64-v8a, 3 x86_64). Do not drop it.
- Never remove the `dependenciesInfo` block from that file: F-Droid's scanner
  rejects the Google Play dependency-metadata signing block.
- Release builds are path-sensitive if they are ever to be reproducible on
  F-Droid: build from `/tmp/build` against an SDK at `/opt/android-sdk`, as
  `.github/workflows/release.yml` does.
- Without the git-ignored `android/key.properties`, a local release build
  falls back to the debug keys and says so.

## Testing gotchas

**No `dart:io` directly in a `testWidgets` body.** The body runs on a fake
clock where those futures never complete, and the test hangs. Widget tests use
`test/support/memory_note_store.dart`; filesystem tests are plain `test()`s
(`test/note_store_test.dart`).

**`pumpAndSettle` times out while a save is pending**: the Save button shows a
spinner, which never settles. Pump a fixed duration instead.

Sync replacements use `NoteStore.replaceForSync`: preserve the displaced file
as a hidden recovery backup (including open external writers), then create the
replacement without truncating. Never revert this to a read/check/write sequence.
Directory paths reject symlink components, consistently with note listing.
