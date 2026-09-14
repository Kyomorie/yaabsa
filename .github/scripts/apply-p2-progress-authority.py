from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one match, found {count}')
    file.write_text(text.replace(old, new, 1))


Path('lib/util/audio_handler/playback_sync_service.dart').write_text(r'''import 'dart:async';
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

typedef PlaybackSyncDispatch =
    Future<bool> Function({required Duration position, required double listenedTime, required String sessionId});

/// Serializes progress writes and gives a backend-confirmed position authority
/// over older in-flight writes without discarding their listening-time delta.
class PlaybackSyncAuthorityQueue {
  Future<void> _tail = Future<void>.value();
  int _revision = 0;
  Duration? _authoritativePosition;
  String? _authoritativeSessionId;

  int get revision => _revision;

  Future<bool> enqueue({
    required Duration position,
    required double listenedTime,
    required String sessionId,
    required PlaybackSyncDispatch dispatch,
  }) {
    return _enqueue(
      position: position,
      listenedTime: listenedTime,
      sessionId: sessionId,
      capturedRevision: _revision,
      dispatch: dispatch,
    );
  }

  Future<bool> correct({
    required Duration position,
    required String sessionId,
    required PlaybackSyncDispatch dispatch,
  }) {
    final correctionRevision = ++_revision;
    _authoritativePosition = position;
    _authoritativeSessionId = sessionId;
    return _enqueue(
      position: position,
      listenedTime: 0,
      sessionId: sessionId,
      capturedRevision: correctionRevision,
      dispatch: dispatch,
    );
  }

  Future<bool> _enqueue({
    required Duration position,
    required double listenedTime,
    required String sessionId,
    required int capturedRevision,
    required PlaybackSyncDispatch dispatch,
  }) async {
    var result = false;
    final operation = _tail.catchError((_) {}).then((_) async {
      result = await dispatch(position: position, listenedTime: listenedTime, sessionId: sessionId);

      final latestPosition = _authoritativePosition;
      if (capturedRevision < _revision &&
          latestPosition != null &&
          _authoritativeSessionId == sessionId) {
        final correctionResult = await dispatch(position: latestPosition, listenedTime: 0, sessionId: sessionId);
        result = result && correctionResult;
      }
    });
    _tail = operation;
    await operation;
    return result;
  }

  Future<void> drain() async {
    await _tail.catchError((_) {});
  }
}

/// Periodically syncs the open playback session while audio is playing and
/// flushes a final sync when playback pauses or stops. Player-agnostic: it
/// only needs a control-state stream and a way to read the current position
/// on the item's global timeline.
class PlaybackSyncService {
  final ProviderContainer _ref;
  final Duration Function() _position;
  final PlaybackSyncAuthorityQueue _authorityQueue = PlaybackSyncAuthorityQueue();
  Timer? _syncTimer;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  int? _effectiveSyncIntervalSeconds;

  static const int _minimumSyncIntervalSeconds = 5;
  static const int _minimumIosSyncIntervalSeconds = 20;

  DateTime? _currentSegmentStartTime;
  bool _hasPlaybackSinceLastFlush = false;
  bool _effectivelyPlaying = false;
  Duration? _pausedAuthoritativePosition;
  String? _pausedAuthoritativeSessionId;

  PlaybackSyncService(this._ref, {required Stream<PlayerState> playerStateStream, required this._position}) {
    _currentSegmentStartTime = null;

    logger('PlaybackSyncService initialized', tag: 'PlaybackSyncService', level: InfoLevel.debug);

    _playerStateSubscription = playerStateStream.listen((playerState) {
      final bool isEffectivelyPlaying = playerState.playing && playerState.processingState == ProcessingState.ready;
      _effectivelyPlaying = isEffectivelyPlaying;

      if (isEffectivelyPlaying) {
        _pausedAuthoritativePosition = null;
        _pausedAuthoritativeSessionId = null;
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

  Future<bool> _dispatchSync({
    required Duration position,
    required double listenedTime,
    required String sessionId,
    required bool canReachServer,
  }) async {
    final repository = _ref.read(sessionRepositoryProvider);
    if (repository.currentSession?.id != sessionId) {
      return false;
    }

    return repository.syncOpenSession(
      position.inMicroseconds / Duration.microsecondsPerSecond,
      listenedTime,
      canReachServer: canReachServer,
      expectedSessionId: sessionId,
    );
  }

  PlaybackSyncDispatch _dispatcher(bool canReachServer) {
    return ({required Duration position, required double listenedTime, required String sessionId}) {
      return _dispatchSync(
        position: position,
        listenedTime: listenedTime,
        sessionId: sessionId,
        canReachServer: canReachServer,
      );
    };
  }

  Future<bool> _enqueueSync({Duration? positionOverride, bool force = false, String? expectedSessionId}) async {
    final repository = _ref.read(sessionRepositoryProvider);
    final sessionId = expectedSessionId ?? repository.currentSession?.id;
    if (sessionId == null || repository.currentSession?.id != sessionId) {
      return false;
    }

    final heldPosition = !_effectivelyPlaying && _pausedAuthoritativeSessionId == sessionId
        ? _pausedAuthoritativePosition
        : null;
    final Duration currentPositionDuration = heldPosition ?? positionOverride ?? _position();
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
    return _authorityQueue.enqueue(
      position: currentPositionDuration,
      listenedTime: listenedTime,
      sessionId: sessionId,
      dispatch: _dispatcher(canReachServer),
    );
  }

  /// Enqueues a zero-listening-time correction only after the player backend
  /// has reported where a seek actually landed. Older writes may still deliver
  /// their listening delta, but they are followed by the newest correction.
  Future<bool> correctAuthoritativePosition(Duration position, {String? expectedSessionId}) {
    final repository = _ref.read(sessionRepositoryProvider);
    final sessionId = expectedSessionId ?? repository.currentSession?.id;
    if (sessionId == null || repository.currentSession?.id != sessionId) {
      return Future<bool>.value(false);
    }

    if (!_effectivelyPlaying) {
      _pausedAuthoritativePosition = position;
      _pausedAuthoritativeSessionId = sessionId;
    }

    final bool canReachServer = _ref.read(serverReachabilityProvider);
    return _authorityQueue.correct(
      position: position,
      sessionId: sessionId,
      dispatch: _dispatcher(canReachServer),
    );
  }

  Future<bool> _stopSync({Duration? positionOverride, bool sessionClosing = false, String? expectedSessionId}) async {
    final repository = _ref.read(sessionRepositoryProvider);
    final sessionId = expectedSessionId ?? repository.currentSession?.id;
    final hadPlaybackSinceLastFlush = _hasPlaybackSinceLastFlush;

    _syncTimer?.cancel();
    _syncTimer = null;

    if (sessionClosing && !hadPlaybackSinceLastFlush) {
      _currentSegmentStartTime = null;
      return false;
    }

    final sync = _enqueueSync(positionOverride: positionOverride, force: true, expectedSessionId: sessionId);
    _hasPlaybackSinceLastFlush = false;

    final synced = await sync;
    if (!synced && sessionId != null && repository.currentSession?.id == sessionId && !_hasPlaybackSinceLastFlush) {
      _hasPlaybackSinceLastFlush = hadPlaybackSinceLastFlush;
    }
    return synced;
  }

  Future<bool> flush({Duration? positionOverride, bool sessionClosing = false, String? expectedSessionId}) {
    return _stopSync(
      positionOverride: positionOverride,
      sessionClosing: sessionClosing,
      expectedSessionId: expectedSessionId,
    );
  }

  void markProgressDirty() {
    _hasPlaybackSinceLastFlush = true;
  }

  Future<void> dispose() async {
    _syncTimer?.cancel();
    _syncTimer = null;
    await _playerStateSubscription?.cancel();
    _playerStateSubscription = null;
    await _authorityQueue.drain();
    _currentSegmentStartTime = null;
    _hasPlaybackSinceLastFlush = false;
    _pausedAuthoritativePosition = null;
    _pausedAuthoritativeSessionId = null;
  }
}
''')

handler = Path('lib/util/audio_handler/bg_audio_handler.dart')
handler_text = handler.read_text()
start_marker = '  Future<void> _seekResolved(\n'
end_marker = '  bool _isSeekOwnershipCurrent(PlayerMutationLease lease, int seekGeneration, String mediaKey) {'
start = handler_text.find(start_marker)
end = handler_text.find(end_marker, start)
if start < 0 or end < 0 or handler_text.find(start_marker, start + 1) >= 0:
    raise SystemExit('bg_audio_handler.dart: could not isolate _seekResolved exactly once')
new_seek = r'''  Future<void> _seekResolved(
    Duration requestedPosition, {
    required bool positionIsAbsolute,
    required bool userNavigation,
    required bool recordManualSeek,
    bool authoritativeProgressCorrection = false,
    PlayerMutationLease? mutationLease,
  }) async {
    final media = _currentMediaItem;
    if (media == null) {
      return;
    }

    final fromPosition = position;
    var resolvedPosition = requestedPosition;
    if (_chapterNotificationEnabled && !positionIsAbsolute) {
      resolvedPosition = _chapterNotificationOffset + requestedPosition;
    }

    final maxPosition = media.totalDuration;
    final boundedPosition = resolvedPosition < Duration.zero
        ? Duration.zero
        : (resolvedPosition > maxPosition ? maxPosition : resolvedPosition);
    final shouldRetarget = boundedPosition != fromPosition;
    final operationId = userNavigation ? _beginUserSeekNavigation(mutationLease: mutationLease) : null;
    final lease =
        mutationLease ??
        (userNavigation
            ? _playerMutationBarrier.currentLease ?? _playerMutationBarrier.acquire()
            : _playerMutationBarrier.acquire());
    final seekGeneration = ++_seekGeneration;
    final mediaKey = _mediaKey(media);
    var navigationSucceeded = false;

    try {
      if (recordManualSeek && (boundedPosition - fromPosition).abs() >= const Duration(seconds: 1)) {
        _syncService.markProgressDirty();
      }

      final shouldRecordPausedManualSeek =
          _internalSeekGuardDepth == 0 &&
          !playerControlState.playing &&
          (playerControlState.processingState == ProcessingState.ready ||
              playerControlState.processingState == ProcessingState.completed);
      if (shouldRecordPausedManualSeek) {
        _markPausedManualSeek(boundedPosition);
      }

      if (isCastControlActive) {
        if (!_playerMutationBarrier.isCurrent(lease)) {
          return;
        }
        final relativePosition = _absoluteToCastRelativePosition(boundedPosition);
        await GoogleCastRemoteMediaClient.instance.seek(GoogleCastMediaSeekOption(position: relativePosition));
        navigationSucceeded = true;
        if (!_playerMutationBarrier.isCurrent(lease) || seekGeneration != _seekGeneration) {
          return;
        }
        _refreshPlayerControlState();
        _refreshChapterNotificationState(customPosition: boundedPosition);
        _updateMediaItemForChapterNotification(customPosition: boundedPosition);
        await _updatePlaybackState();
        if (recordManualSeek) {
          _recordManualSeekIfNeeded(fromPosition, boundedPosition);
        }
        return;
      }

      final newTrackIndex = media.getIndexForDuration(boundedPosition);
      if (newTrackIndex < 0) {
        logger(
          'Ignoring seek with invalid track index for position: $boundedPosition',
          tag: 'AudioHandler',
          level: InfoLevel.warning,
        );
        return;
      }
      logger(
        'Seeking to position: $boundedPosition, track index: $newTrackIndex',
        tag: 'AudioHandler',
        level: InfoLevel.debug,
      );
      final relativeTrackPosition = boundedPosition - media.startDurationForTrack(newTrackIndex);
      final trackChanged = newTrackIndex != _currentTrackIndex;

      final seekResult = await _playerMutationBarrier.run<SeekConfirmationResult>(
        lease,
        () => _player.seekConfirmed(relativeTrackPosition, index: newTrackIndex),
      );
      if (seekResult == null || !_isSeekOwnershipCurrent(lease, seekGeneration, mediaKey)) {
        return;
      }

      Duration settledPosition;
      if (seekResult.status == SeekConfirmationStatus.reached) {
        final actualPosition = seekResult.actualPosition;
        final actualIndex = seekResult.actualIndex;
        if (actualPosition == null || actualIndex == null || actualIndex < 0 || actualIndex >= media.tracks.length) {
          logger(
            'Confirmed seek returned reached without a valid actual position/index.',
            tag: 'AudioHandler',
            level: InfoLevel.warning,
          );
          return;
        }

        final actualAbsolutePosition = media.startDurationForTrack(actualIndex) + actualPosition;
        settledPosition = _clampDuration(actualAbsolutePosition, Duration.zero, media.totalDuration);
        _currentTrackIndex = actualIndex;
        navigationSucceeded = settledPosition != fromPosition;

        if (authoritativeProgressCorrection && _isSeekOwnershipCurrent(lease, seekGeneration, mediaKey)) {
          unawaited(_syncService.correctAuthoritativePosition(settledPosition));
        }
      } else if (seekResult.status == SeekConfirmationStatus.unsupported) {
        // The compatibility implementation already performed the legacy seek.
        // Preserve existing UX, but do not treat the optimistic Dart position
        // as authoritative for progress synchronization.
        _currentTrackIndex = newTrackIndex;
        navigationSucceeded = true;
        settledPosition = boundedPosition;

        if (trackChanged && !kIsWeb && (Platform.isWindows || Platform.isLinux)) {
          final correctionReady = await _waitForDesktopCorrectiveSeek(
            lease: lease,
            seekGeneration: seekGeneration,
            mediaKey: mediaKey,
            trackIndex: newTrackIndex,
          );
          if (!correctionReady) {
            return;
          }
          await _playerMutationBarrier.run<void>(lease, () => _player.seek(relativeTrackPosition, index: newTrackIndex));
          if (!_isSeekOwnershipCurrent(lease, seekGeneration, mediaKey)) {
            return;
          }
        }
      } else {
        final level = seekResult.status == SeekConfirmationStatus.superseded ? InfoLevel.debug : InfoLevel.warning;
        logger(
          'Seek was not authoritatively reached: ${seekResult.status}${seekResult.errorMessage == null ? '' : ' (${seekResult.errorMessage})'}',
          tag: 'AudioHandler',
          level: level,
        );
        return;
      }

      if (!_isSeekOwnershipCurrent(lease, seekGeneration, mediaKey)) {
        return;
      }
      _refreshChapterNotificationState(customPosition: settledPosition);
      _updateMediaItemForChapterNotification(customPosition: settledPosition);
      unawaited(_updatePlaybackState());
      if (recordManualSeek) {
        _recordManualSeekIfNeeded(fromPosition, settledPosition);
      }
    } finally {
      if (operationId != null) {
        _settleUserSeekNavigation(operationId, shouldRetarget: navigationSucceeded && shouldRetarget);
      }
    }
  }

'''
handler_text = handler_text[:start] + new_seek + handler_text[end:]
old_internal = '''  Future<void> _seekInternal(Duration position, {bool userNavigation = false, PlayerMutationLease? mutationLease}) {
    return _seekResolved(
      position,
      positionIsAbsolute: true,
      userNavigation: userNavigation,
      recordManualSeek: false,
      mutationLease: mutationLease,
    );
  }
'''
new_internal = '''  Future<void> _seekInternal(
    Duration position, {
    bool userNavigation = false,
    bool authoritativeProgressCorrection = false,
    PlayerMutationLease? mutationLease,
  }) {
    return _seekResolved(
      position,
      positionIsAbsolute: true,
      userNavigation: userNavigation,
      recordManualSeek: false,
      authoritativeProgressCorrection: authoritativeProgressCorrection || userNavigation,
      mutationLease: mutationLease,
    );
  }
'''
if handler_text.count(old_internal) != 1:
    raise SystemExit(f'bg_audio_handler.dart: expected one _seekInternal block, found {handler_text.count(old_internal)}')
handler_text = handler_text.replace(old_internal, new_internal, 1)
old_public_seek = '''    return _seekResolved(position, positionIsAbsolute: false, userNavigation: true, recordManualSeek: true);'''
new_public_seek = '''    return _seekResolved(
      position,
      positionIsAbsolute: false,
      userNavigation: true,
      recordManualSeek: true,
      authoritativeProgressCorrection: true,
    );'''
if handler_text.count(old_public_seek) != 1:
    raise SystemExit(f'bg_audio_handler.dart: expected one public seek call, found {handler_text.count(old_public_seek)}')
handler_text = handler_text.replace(old_public_seek, new_public_seek, 1)
old_skip = '          await _seekInternal(newPosition, mutationLease: skipLease);'
new_skip = '''          await _seekInternal(
            newPosition,
            mutationLease: skipLease,
            authoritativeProgressCorrection: true,
          );'''
if handler_text.count(old_skip) != 2:
    raise SystemExit(f'bg_audio_handler.dart: expected two chapter skip seeks, found {handler_text.count(old_skip)}')
handler_text = handler_text.replace(old_skip, new_skip)
handler.write_text(handler_text)

resume = Path('lib/util/audio_handler/bg_audio_handler_resume.dart')
resume_text = resume.read_text()
old_resume_call = '    await _seekInternal(targetPosition, mutationLease: mutationLease);'
new_resume_call = '''    await _seekInternal(
      targetPosition,
      mutationLease: mutationLease,
      authoritativeProgressCorrection: true,
    );'''
if resume_text.count(old_resume_call) != 1:
    raise SystemExit(f'bg_audio_handler_resume.dart: expected one rewind seek, found {resume_text.count(old_resume_call)}')
resume_text = resume_text.replace(old_resume_call, new_resume_call, 1)
old_flush = '''
    try {
      await _syncService.flush(positionOverride: targetPosition);
    } catch (e) {
      logger('Failed to sync sleep timer rewind after expiry: $e', tag: 'AudioHandler', level: InfoLevel.warning);
    }
'''
if resume_text.count(old_flush) != 1:
    raise SystemExit(f'bg_audio_handler_resume.dart: expected one optimistic rewind flush, found {resume_text.count(old_flush)}')
resume_text = resume_text.replace(old_flush, '\n', 1)
resume.write_text(resume_text)

app_db = Path('lib/database/app_database.dart')
app_db_text = app_db.read_text()
insert_before = '''  Future<void> deleteSync(String sessionId) {
'''
ack_method = r'''  /// Atomically acknowledges only the listening-time portion represented by
  /// [replayed]. If the row changed while the network replay was in flight,
  /// newer position/progress data is retained and only the replayed listening
  /// delta is subtracted.
  Future<bool> acknowledgeReplayedSync(StoredSyncEntry replayed) {
    return transaction(() async {
      final current = await (select(storedSyncs)..where((tbl) => tbl.sessionId.equals(replayed.sessionId)))
          .getSingleOrNull();
      if (current == null) {
        return true;
      }

      final sameIdentity =
          current.sessionId == replayed.sessionId &&
          current.itemId == replayed.itemId &&
          current.userId == replayed.userId &&
          current.episodeId == replayed.episodeId;
      if (!sameIdentity) {
        return false;
      }

      final unchangedSnapshot =
          current.currentTime == replayed.currentTime &&
          current.timeListened == replayed.timeListened &&
          current.duration == replayed.duration &&
          current.sessionLocal == replayed.sessionLocal &&
          current.lastUpdated == replayed.lastUpdated &&
          current.mediaProgress == replayed.mediaProgress;
      if (unchangedSnapshot) {
        await (delete(storedSyncs)..where((tbl) => tbl.sessionId.equals(replayed.sessionId))).go();
        return true;
      }

      const epsilon = 0.000001;
      if (current.timeListened + epsilon < replayed.timeListened) {
        return false;
      }

      final remainingListened = current.timeListened - replayed.timeListened;
      await (update(storedSyncs)..where((tbl) => tbl.sessionId.equals(replayed.sessionId))).write(
        StoredSyncsCompanion(timeListened: Value(remainingListened < epsilon ? 0.0 : remainingListened)),
      );
      return true;
    });
  }

'''
if app_db_text.count(insert_before) != 1:
    raise SystemExit(f'app_database.dart: expected one deleteSync insertion point, found {app_db_text.count(insert_before)}')
app_db.write_text(app_db_text.replace(insert_before, ack_method + insert_before, 1))

replace_once(
    'lib/provider/core/server_status_provider.dart',
    '''        final synced = await sessionRepository.replayStoredSync(sync);
        if (synced) {
          await db.deleteSync(sync.sessionId);
          logger('Sync completed successfully for session ID: ${sync.sessionId}', tag: 'ServerStatusProvider');
        }
''',
    '''        final synced = await sessionRepository.replayStoredSync(sync);
        if (synced) {
          final acknowledged = await db.acknowledgeReplayedSync(sync);
          if (acknowledged) {
            logger(
              'Sync replay acknowledged for session ID: ${sync.sessionId}; concurrent updates were retained if present.',
              tag: 'ServerStatusProvider',
            );
          } else {
            logger(
              'Sync replay for ${sync.sessionId} succeeded remotely but local acknowledgement failed closed.',
              tag: 'ServerStatusProvider',
              level: InfoLevel.warning,
            );
          }
        }
''',
)

Path('test/util/playback_sync_authority_queue_test.dart').write_text(r'''import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaabsa/util/audio_handler/playback_sync_service.dart';

void main() {
  test('online A/B race delivers A listening time once and leaves B position authoritative', () async {
    final queue = PlaybackSyncAuthorityQueue();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    var callCount = 0;
    var serverPosition = Duration.zero;
    var serverListening = 0.0;

    Future<bool> dispatch({required Duration position, required double listenedTime, required String sessionId}) async {
      if (callCount++ == 0) {
        firstStarted.complete();
        await releaseFirst.future;
      }
      serverPosition = position;
      serverListening += listenedTime;
      return true;
    }

    final a = queue.enqueue(
      position: const Duration(seconds: 10),
      listenedTime: 5,
      sessionId: 'session',
      dispatch: dispatch,
    );
    await firstStarted.future;

    final b = queue.correct(
      position: const Duration(seconds: 80),
      sessionId: 'session',
      dispatch: dispatch,
    );
    releaseFirst.complete();

    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(serverListening, 5);
    expect(serverPosition, const Duration(seconds: 80));
    expect(callCount, greaterThanOrEqualTo(3));
  });

  test('offline A/B race accumulates A time while zero-time B replaces position', () async {
    final queue = PlaybackSyncAuthorityQueue();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    var callCount = 0;
    var storedPosition = Duration.zero;
    var storedListening = 0.0;

    Future<bool> store({required Duration position, required double listenedTime, required String sessionId}) async {
      if (callCount++ == 0) {
        firstStarted.complete();
        await releaseFirst.future;
      }
      storedListening += listenedTime;
      storedPosition = position;
      return true;
    }

    final a = queue.enqueue(
      position: const Duration(seconds: 12),
      listenedTime: 7,
      sessionId: 'session',
      dispatch: store,
    );
    await firstStarted.future;

    final b = queue.correct(
      position: const Duration(seconds: 65),
      sessionId: 'session',
      dispatch: store,
    );
    releaseFirst.complete();

    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(storedListening, 7);
    expect(storedPosition, const Duration(seconds: 65));
  });

  test('newest authoritative correction wins when confirmed seeks race', () async {
    final queue = PlaybackSyncAuthorityQueue();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    var callCount = 0;
    var finalPosition = Duration.zero;

    Future<bool> dispatch({required Duration position, required double listenedTime, required String sessionId}) async {
      if (callCount++ == 0) {
        firstStarted.complete();
        await releaseFirst.future;
      }
      finalPosition = position;
      return true;
    }

    final a = queue.enqueue(
      position: const Duration(seconds: 5),
      listenedTime: 4,
      sessionId: 'session',
      dispatch: dispatch,
    );
    await firstStarted.future;
    final b = queue.correct(
      position: const Duration(seconds: 40),
      sessionId: 'session',
      dispatch: dispatch,
    );
    final c = queue.correct(
      position: const Duration(seconds: 90),
      sessionId: 'session',
      dispatch: dispatch,
    );
    releaseFirst.complete();

    await Future.wait([a, b, c]);
    expect(finalPosition, const Duration(seconds: 90));
  });
}
''')

Path('test/database').mkdir(parents=True, exist_ok=True)
Path('test/database/stored_sync_ack_test.dart').write_text(r'''import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaabsa/database/app_database.dart';

StoredSyncsCompanion _sync({
  required double position,
  required double listened,
  required DateTime updatedAt,
  required String progress,
}) {
  return StoredSyncsCompanion(
    sessionId: const Value('session'),
    itemId: const Value('item'),
    userId: const Value('user'),
    episodeId: const Value<String?>(null),
    currentTime: Value(position),
    timeListened: Value(listened),
    duration: const Value(300),
    sessionLocal: const Value(false),
    lastUpdated: Value(updatedAt),
    mediaProgress: Value(progress),
  );
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.connect(DatabaseConnection(NativeDatabase.memory()));
  });

  tearDown(() async {
    await db.close();
  });

  test('unchanged replay snapshot is deleted after acknowledgement', () async {
    final t0 = DateTime.utc(2026, 9, 14, 8);
    await db.addOrUpdateSync(_sync(position: 30, listened: 12, updatedAt: t0, progress: 'old'));
    final snapshot = (await db.getSync('session'))!;

    expect(await db.acknowledgeReplayedSync(snapshot), isTrue);
    expect(await db.getSync('session'), isNull);
  });

  test('concurrent zero-time correction survives replay acknowledgement', () async {
    final t0 = DateTime.utc(2026, 9, 14, 8);
    final t1 = t0.add(const Duration(seconds: 1));
    await db.addOrUpdateSync(_sync(position: 30, listened: 12, updatedAt: t0, progress: 'old'));
    final snapshot = (await db.getSync('session'))!;

    await db.addOrUpdateSync(_sync(position: 90, listened: 0, updatedAt: t1, progress: 'new'));
    expect(await db.acknowledgeReplayedSync(snapshot), isTrue);

    final remaining = await db.getSync('session');
    expect(remaining, isNotNull);
    expect(remaining!.currentTime, 90);
    expect(remaining.timeListened, 0);
    expect(remaining.mediaProgress, 'new');
    expect(remaining.lastUpdated, t1);
  });

  test('concurrent new listening is retained without replaying old delta twice', () async {
    final t0 = DateTime.utc(2026, 9, 14, 8);
    final t1 = t0.add(const Duration(seconds: 1));
    await db.addOrUpdateSync(_sync(position: 30, listened: 12, updatedAt: t0, progress: 'old'));
    final snapshot = (await db.getSync('session'))!;

    await db.addOrUpdateSync(_sync(position: 95, listened: 5, updatedAt: t1, progress: 'new'));
    expect(await db.acknowledgeReplayedSync(snapshot), isTrue);

    final remaining = await db.getSync('session');
    expect(remaining, isNotNull);
    expect(remaining!.currentTime, 95);
    expect(remaining.timeListened, 5);
    expect(remaining.mediaProgress, 'new');
  });
}
''')
