import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:yaabsa/api/me/user.dart';
import 'package:yaabsa/database/settings_manager.dart';
import 'package:yaabsa/provider/core/server_reachability_provider.dart';
import 'package:yaabsa/provider/core/user_providers.dart';
import 'package:yaabsa/provider/player/session_provider.dart';
import 'package:yaabsa/util/logger.dart';
import 'package:yaabsa/util/setting_key.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

/// Periodically syncs the open playback session while audio is playing and
/// flushes a final sync when playback pauses or stops. Player-agnostic: it
/// only needs a control-state stream and a way to read the current position
/// on the item's global timeline.
class PlaybackSyncService {
  final ProviderContainer _ref;
  final Duration Function() _position;
  Timer? _syncTimer;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  Future<void> _syncQueue = Future<void>.value();
  int? _effectiveSyncIntervalSeconds;

  static const int _minimumSyncIntervalSeconds = 5;
  static const int _minimumIosSyncIntervalSeconds = 20;

  DateTime? _currentSegmentStartTime;
  bool _hasPlaybackSinceLastFlush = false;

  PlaybackSyncService(this._ref, {required Stream<PlayerState> playerStateStream, required this._position}) {
    _currentSegmentStartTime = null;

    logger('PlaybackSyncService initialized', tag: 'PlaybackSyncService', level: InfoLevel.debug);

    _playerStateSubscription = playerStateStream.listen((playerState) {
      final bool isEffectivelyPlaying = playerState.playing && playerState.processingState == ProcessingState.ready;

      if (isEffectivelyPlaying) {
        if (_ref.read(sessionRepositoryProvider).currentSession != null) {
          _hasPlaybackSinceLastFlush = true;
        }
        _currentSegmentStartTime ??= DateTime.now();
        unawaited(_startSync());
      } else {
        if (_currentSegmentStartTime != null) {
          unawaited(_stopSync());
        } else {
          _syncTimer?.cancel();
          _syncTimer = null;
        }
      }
    });
  }

  int _resolvedSyncIntervalSeconds() {
    final User? user = _ref.read(currentUserProvider).value;
    final configuredInterval = _ref
        .read(settingsManagerProvider.notifier)
        .getUserSetting<int>(user?.id, SettingKeys.syncInterval);
    final normalizedInterval = configuredInterval < _minimumSyncIntervalSeconds
        ? _minimumSyncIntervalSeconds
        : configuredInterval;

    if (!kIsWeb && Platform.isIOS && normalizedInterval < _minimumIosSyncIntervalSeconds) {
      return _minimumIosSyncIntervalSeconds;
    }

    return normalizedInterval;
  }

  Future<void> _startSync() async {
    final intervalSeconds = _resolvedSyncIntervalSeconds();
    if ((_syncTimer?.isActive ?? false) && _effectiveSyncIntervalSeconds == intervalSeconds) {
      return;
    }

    _syncTimer?.cancel();
    _effectiveSyncIntervalSeconds = intervalSeconds;
    _syncTimer = Timer.periodic(Duration(seconds: intervalSeconds), (_) {
      unawaited(_enqueueSync());
    });

    logger('Playback sync timer running every ${intervalSeconds}s', tag: 'PlaybackSyncService', level: InfoLevel.debug);
  }

  Future<bool> _enqueueSync({
    Duration? positionOverride,
    bool force = false,
    String? expectedSessionId,
  }) async {
    final repository = _ref.read(sessionRepositoryProvider);
    final sessionId = expectedSessionId ?? repository.currentSession?.id;
    if (sessionId == null || repository.currentSession?.id != sessionId) {
      return false;
    }

    final Duration currentPositionDuration = positionOverride ?? _position();
    final double currentPositionSeconds = currentPositionDuration.inMicroseconds / Duration.microsecondsPerSecond;
    double listenedTime = 0;

    final segmentStartTime = _currentSegmentStartTime;
    if (segmentStartTime != null) {
      final DateTime now = DateTime.now();
      final Duration elapsedSinceLastMark = now.difference(segmentStartTime);
      listenedTime = elapsedSinceLastMark.inMicroseconds / Duration.microsecondsPerSecond;

      if (_syncTimer?.isActive ?? false) {
        _currentSegmentStartTime = now;
      } else {
        _currentSegmentStartTime = null;
      }
    }

    if (!force && listenedTime < 0.3) {
      logger(
        'Syncing skipped: listenedTime is too small: $listenedTime',
        tag: 'PlaybackSyncService',
        level: InfoLevel.warning,
      );
      return false;
    }

    final bool canReachServer = _ref.read(serverReachabilityProvider);
    var result = false;

    _syncQueue = _syncQueue.catchError((_) {}).then((_) async {
      result = await repository.syncOpenSession(
        currentPositionSeconds,
        listenedTime,
        canReachServer: canReachServer,
        expectedSessionId: sessionId,
      );
    });

    await _syncQueue;
    return result;
  }

  Future<bool> _stopSync({Duration? positionOverride, bool sessionClosing = false}) async {
    final repository = _ref.read(sessionRepositoryProvider);
    final expectedSessionId = repository.currentSession?.id;
    final hadPlaybackSinceLastFlush = _hasPlaybackSinceLastFlush;

    _syncTimer?.cancel();
    _syncTimer = null;

    if (sessionClosing && !hadPlaybackSinceLastFlush) {
      _currentSegmentStartTime = null;
      return false;
    }

    final sync = _enqueueSync(
      positionOverride: positionOverride,
      force: true,
      expectedSessionId: expectedSessionId,
    );
    _hasPlaybackSinceLastFlush = false;

    final synced = await sync;
    if (!synced &&
        expectedSessionId != null &&
        repository.currentSession?.id == expectedSessionId &&
        !_hasPlaybackSinceLastFlush) {
      _hasPlaybackSinceLastFlush = hadPlaybackSinceLastFlush;
    }
    return synced;
  }

  Future<bool> flush({Duration? positionOverride, bool sessionClosing = false}) {
    return _stopSync(positionOverride: positionOverride, sessionClosing: sessionClosing);
  }

  void markProgressDirty() {
    _hasPlaybackSinceLastFlush = true;
  }

  Future<void> dispose() async {
    _syncTimer?.cancel();
    _syncTimer = null;
    await _playerStateSubscription?.cancel();
    _playerStateSubscription = null;
    _currentSegmentStartTime = null;
    _hasPlaybackSinceLastFlush = false;
  }
}
