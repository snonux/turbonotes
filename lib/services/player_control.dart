import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

const _playerChannel = MethodChannel('org.buetow.turbonotes/player');

/// What the Player app has open: the title, and whether it plays.
@immutable
class PlayerStatus {
  const PlayerStatus({required this.title, required this.playing});

  final String title;
  final bool playing;

  static PlayerStatus? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    if (title is! String || title.trim().isEmpty) return null;
    return PlayerStatus(title: title, playing: raw['playing'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerStatus && other.title == title && other.playing == playing;

  @override
  int get hashCode => Object.hash(title, playing);
}

/// Remote control for the Player app (snonux/player), so an audiobook can be
/// paused, rewound and continued while taking notes on it. Android only: it
/// follows Player's media session, which Android shows to apps with
/// notification access (granted once, see [requestAccess]).
///
/// [status] is null while Player is not running or has no title open; the
/// note editor shows its controls only otherwise.
class PlayerControl extends ChangeNotifier {
  PlayerControl({MethodChannel? channel, bool? supported})
    : _channel = channel ?? _playerChannel,
      supported = supported ?? Platform.isAndroid;

  /// The app-wide instance the note editor uses.
  static final PlayerControl instance = PlayerControl();

  final MethodChannel _channel;

  /// False on platforms without Player (everything but Android).
  final bool supported;

  bool _started = false;
  bool _accessGranted = false;
  PlayerStatus? _status;
  AppLifecycleListener? _lifecycle;

  /// Whether TurboNotes may see Player's media session.
  bool get accessGranted => _accessGranted;

  PlayerStatus? get status => _status;

  /// Starts following Player; later calls do nothing. Access granted in
  /// Android's settings shows up when the app comes back to the foreground.
  void start() {
    if (_started || !supported) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'changed') return;
      // Only a granted session listener reports changes.
      _accessGranted = true;
      _setStatus(PlayerStatus.fromMap(call.arguments));
    });
    _lifecycle = AppLifecycleListener(onResume: refresh);
    refresh();
  }

  /// Asks Android again for access and Player's state.
  Future<void> refresh() async {
    if (!supported) return;
    final Object? raw;
    try {
      raw = await _channel.invokeMethod<Object?>('status');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    if (raw is! Map) return;
    final access = raw['access'] == true;
    final status = PlayerStatus.fromMap(raw['player']);
    if (access == _accessGranted && status == _status) return;
    _accessGranted = access;
    _status = status;
    notifyListeners();
  }

  /// Opens Android's notification access page for TurboNotes.
  Future<void> requestAccess() => _call('requestAccess');

  Future<void> pause() async {
    if (await _call('pause')) _optimistic(playing: false);
  }

  Future<void> play() async {
    if (await _call('play')) _optimistic(playing: true);
  }

  /// Pauses while playing, continues otherwise.
  Future<void> togglePlayback() => _status?.playing == true ? pause() : play();

  /// Jumps back [seconds] in the current title.
  Future<void> rewind([int seconds = 10]) =>
      _call('rewind', {'seconds': seconds});

  Future<bool> _call(String method, [Map<String, Object?>? args]) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<Object?>(method, args) == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Shows the new state at once; Player's session confirms it shortly.
  void _optimistic({required bool playing}) {
    final status = _status;
    if (status != null) {
      _setStatus(PlayerStatus(title: status.title, playing: playing));
    }
  }

  void _setStatus(PlayerStatus? status) {
    if (status == _status) return;
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    if (_started) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
