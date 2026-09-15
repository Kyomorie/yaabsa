part of 'bg_audio_handler.dart';

final Expando<_ChapterSleepAudioCoordinationState> _chapterSleepCoordinationState =
    Expando<_ChapterSleepAudioCoordinationState>('chapterSleepCoordinationState');

class _ChapterSleepAudioCoordinationState {
  final ChapterSleepNavigationLedger navigation = ChapterSleepNavigationLedger();
  final ChapterSleepCompletionProtectionLedger completionProtection = ChapterSleepCompletionProtectionLedger();
  final StreamController<SleepTimerPositionMutationEvent> mutationEvents =
      StreamController<SleepTimerPositionMutationEvent>.broadcast(sync: true);
  final StreamController<SleepTimerCompletionClaim> completionClaims =
      StreamController<SleepTimerCompletionClaim>.broadcast(sync: true);
  final Set<int> activeInternalMutations = <int>{};

  int operationSequence = 0;
  int seekGeneration = 0;
  int completionGeneration = 0;
  int playbackActionGeneration = 0;
  bool disposed = false;
}

extension BGAudioHandlerChapterSleepTimer on BGAudioHandler {
  _ChapterSleepAudioCoordinationState get _chapterSleepState {
    return _chapterSleepCoordinationState[this] ??= _ChapterSleepAudioCoordinationState();
  }

  Stream<SleepTimerPositionMutationEvent> get sleepTimerPositionMutationStream => _chapterSleepState.mutationEvents.stream;
  Stream<SleepTimerCompletionClaim> get sleepTimerCompletionClaimStream => _chapterSleepState.completionClaims.stream;

  int get sleepTimerNavigationGeneration => _chapterSleepState.navigation.generation;
  bool get hasActiveSleepTimerUserNavigation => _chapterSleepState.navigation.hasActive;
  int get sleepTimerPlaybackActionGeneration => _chapterSleepState.playbackActionGeneration;
  int get sleepTimerCompletionGeneration => _chapterSleepState.completionGeneration;

  SleepTimerCompletionProtectionToken armSleepTimerCompletionProtection({
    required String itemId,
    required String? episodeId,
    required int timerGeneration,
  }) {
    return _chapterSleepState.completionProtection.arm(
      media: SleepTimerMediaIdentity(itemId: itemId, episodeId: episodeId),
      timerGeneration: timerGeneration,
    );
  }

  bool markSleepTimerCompletionProtectionExpiring(
    SleepTimerCompletionProtectionToken token, {
    required int expiryGeneration,
  }) {
    return _chapterSleepState.completionProtection.markExpiring(token, expiryGeneration: expiryGeneration);
  }

  bool isSleepTimerCompletionProtectionCurrent(SleepTimerCompletionProtectionToken token) {
    return _chapterSleepState.completionProtection.isCurrent(token);
  }

  bool clearSleepTimerCompletionProtection(SleepTimerCompletionProtectionToken token) {
    return _chapterSleepState.completionProtection.clear(token);
  }

  bool isChapterSleepOwnershipCurrent({
    required SleepTimerMediaIdentity media,
    required String sessionId,
    required int navigationGeneration,
    required int playbackActionGeneration,
  }) {
    final currentMedia = _currentMediaItem;
    if (!media.matchesMedia(currentMedia) || currentMedia?.sessionId != sessionId) {
      return false;
    }
    final state = _chapterSleepState;
    return state.navigation.generation == navigationGeneration &&
        !state.navigation.hasActive &&
        state.playbackActionGeneration == playbackActionGeneration;
  }

  Future<bool> pauseForChapterSleepTimer({
    required SleepTimerMediaIdentity media,
    required String sessionId,
    required int navigationGeneration,
    required int playbackActionGeneration,
  }) async {
    if (!isChapterSleepOwnershipCurrent(
      media: media,
      sessionId: sessionId,
      navigationGeneration: navigationGeneration,
      playbackActionGeneration: playbackActionGeneration,
    )) {
      return false;
    }

    PlayerUtils.disableWakelock(_ref);
    _resetStreamRecoveryState(clearWindow: true);
    await _player.pause();
    _clearSmartRewindPauseMarker();
    TrayManager.update();
    return true;
  }

  Future<Duration?> applyChapterSleepTimerRewind({
    required SleepTimerMediaIdentity media,
    required String sessionId,
    required int navigationGeneration,
    required int playbackActionGeneration,
  }) async {
    if (!isChapterSleepOwnershipCurrent(
      media: media,
      sessionId: sessionId,
      navigationGeneration: navigationGeneration,
      playbackActionGeneration: playbackActionGeneration,
    )) {
      return null;
    }

    final rewindMinutes = _ref
        .read(settingsManagerProvider.notifier)
        .getGlobalSetting<int>(SettingKeys.sleepTimerAutoRewindMinutes);
    if (rewindMinutes <= 0) {
      return position;
    }

    final currentPosition = position;
    final targetPosition = _rewindPosition(currentPosition, Duration(minutes: rewindMinutes));
    if (targetPosition >= currentPosition) {
      return currentPosition;
    }

    await _seekForChapterSleepCoordination(
      targetPosition,
      kind: SleepTimerPositionMutationKind.chapterExpiry,
      applyChapterNotificationOffset: false,
      registerMutation: true,
    );

    if (!isChapterSleepOwnershipCurrent(
      media: media,
      sessionId: sessionId,
      navigationGeneration: navigationGeneration,
      playbackActionGeneration: playbackActionGeneration,
    )) {
      return null;
    }
    return position;
  }

  Future<bool> flushChapterSleepTimerProgress({
    required PlaybackSessionBinding binding,
    required Duration position,
    required SleepTimerMediaIdentity media,
    required String sessionId,
    required int navigationGeneration,
    required int playbackActionGeneration,
    bool sessionClosing = false,
  }) async {
    if (!isChapterSleepOwnershipCurrent(
      media: media,
      sessionId: sessionId,
      navigationGeneration: navigationGeneration,
      playbackActionGeneration: playbackActionGeneration,
    )) {
      return false;
    }

    return _syncService.flush(
      positionOverride: position,
      sessionClosing: sessionClosing,
      binding: binding,
    );
  }

  Future<bool> stopForChapterSleepTimer({
    required PlaybackSessionBinding binding,
    required Duration stopPosition,
    required SleepTimerMediaIdentity media,
    required String sessionId,
    required int navigationGeneration,
    required int playbackActionGeneration,
  }) async {
    if (!isChapterSleepOwnershipCurrent(
      media: media,
      sessionId: sessionId,
      navigationGeneration: navigationGeneration,
      playbackActionGeneration: playbackActionGeneration,
    )) {
      return false;
    }

    final stoppedMedia = _currentMediaItem;
    if (stoppedMedia == null) {
      return false;
    }

    unawaited(
      refreshPersonalizedShelfForCompletedItem(
        container: _ref,
        itemId: stoppedMedia.itemId,
        preferredLibraryId: stoppedMedia.libraryId,
        sourceTag: 'AudioHandler',
        reason: 'chapter sleep timer stop',
      ),
    );
    unawaited(
      PlayerHistoryHandler.addPlayerHistory(PlayerHistoryType.stop, media: stoppedMedia, position: stopPosition),
    );

    _setQueueTransitionLoading(false);
    _clearSmartRewindPauseMarker();
    _clearPausedManualSeekMarker();
    _resetStreamRecoveryState(clearWindow: true);
    _currentMediaItem = null;
    _restoredMediaItem = null;
    _restoredPosition = Duration.zero;
    mediaItem.add(null);
    _currentTrackIndex = 0;
    PlayerUtils.disableWakelock(_ref);

    if (!kIsWeb && Platform.isLinux) {
      await _player.pause();
      if (_chapterSleepState.playbackActionGeneration != playbackActionGeneration) {
        return false;
      }
      await _player.seek(Duration.zero);
    } else {
      await _player.stop();
    }
    TrayManager.update();

    // The local player no longer owns the media. From here on every operation
    // is explicitly bound to the captured session, so a newly opened session
    // cannot be flushed, closed, or cleared by this expiry.
    await _syncService.flush(
      positionOverride: stopPosition,
      sessionClosing: true,
      binding: binding,
    );
    await _ref.read(sessionRepositoryProvider).closeSessionBinding(binding);
    return true;
  }

  Future<void> _disposeChapterSleepTimerCoordination() async {
    final state = _chapterSleepCoordinationState[this];
    if (state == null || state.disposed) {
      return;
    }
    state.disposed = true;
    await state.mutationEvents.close();
    await state.completionClaims.close();
  }

  void _chapterSleepNotePlaybackAction() {
    _chapterSleepState.playbackActionGeneration += 1;
  }

  int _beginChapterSleepPositionMutation(SleepTimerPositionMutationKind kind) {
    final state = _chapterSleepState;
    final operationId = ++state.operationSequence;
    if (kind == SleepTimerPositionMutationKind.userNavigation) {
      state.navigation.begin(operationId);
      state.playbackActionGeneration += 1;
    } else {
      state.activeInternalMutations.add(operationId);
    }
    if (!state.mutationEvents.isClosed) {
      state.mutationEvents.add(
        SleepTimerPositionMutationEvent(
          operationId: operationId,
          kind: kind,
          phase: SleepTimerPositionMutationPhase.began,
          navigationGeneration: state.navigation.generation,
          didMutate: false,
        ),
      );
    }
    return operationId;
  }

  void _settleChapterSleepPositionMutation(
    int operationId,
    SleepTimerPositionMutationKind kind, {
    required bool didMutate,
  }) {
    final state = _chapterSleepState;
    if (kind == SleepTimerPositionMutationKind.userNavigation) {
      state.navigation.settle(operationId);
    } else {
      state.activeInternalMutations.remove(operationId);
    }
    if (!state.mutationEvents.isClosed) {
      state.mutationEvents.add(
        SleepTimerPositionMutationEvent(
          operationId: operationId,
          kind: kind,
          phase: SleepTimerPositionMutationPhase.settled,
          navigationGeneration: state.navigation.generation,
          didMutate: didMutate,
        ),
      );
    }
  }

  SleepTimerCompletionClaim _claimChapterSleepCompletion(InternalMedia media) {
    final state = _chapterSleepState;
    final claim = SleepTimerCompletionClaim(
      media: SleepTimerMediaIdentity.fromMedia(media),
      completionGeneration: ++state.completionGeneration,
      navigationGeneration: state.navigation.generation,
      navigationActive: state.navigation.hasActive,
      playbackActionGeneration: state.playbackActionGeneration,
      protection: state.completionProtection.snapshotFor(SleepTimerMediaIdentity.fromMedia(media)),
    );
    if (!state.completionClaims.isClosed) {
      state.completionClaims.add(claim);
    }
    return claim;
  }

  bool _isChapterSleepCompletionClaimCurrent(SleepTimerCompletionClaim claim) {
    final state = _chapterSleepState;
    if (claim.completionGeneration != state.completionGeneration ||
        claim.navigationGeneration != state.navigation.generation ||
        claim.playbackActionGeneration != state.playbackActionGeneration ||
        !claim.media.matchesMedia(_currentMediaItem) ||
        _player.processingState != ProcessingState.completed) {
      return false;
    }
    final protection = claim.protection;
    return protection == null || state.completionProtection.isCurrent(protection.token);
  }

  Future<void> _seekForChapterSleepCoordination(
    Duration requestedPosition, {
    required SleepTimerPositionMutationKind kind,
    required bool applyChapterNotificationOffset,
    bool registerMutation = true,
  }) async {
    final mediaAtStart = _currentMediaItem;
    if (mediaAtStart == null) {
      return;
    }

    final fromPosition = position;
    final operationId = registerMutation ? _beginChapterSleepPositionMutation(kind) : null;
    final isInternal = kind != SleepTimerPositionMutationKind.userNavigation;
    if (isInternal) {
      _internalSeekGuardDepth += 1;
      _isInternalSeek = true;
    }
    final seekGeneration = ++_chapterSleepState.seekGeneration;
    final mediaIdentity = SleepTimerMediaIdentity.fromMedia(mediaAtStart);
    var didMutate = false;

    bool contextIsCurrent() {
      return seekGeneration == _chapterSleepState.seekGeneration && mediaIdentity.matchesMedia(_currentMediaItem);
    }

    try {
      Duration resolvedPosition = requestedPosition;
      if (_chapterNotificationEnabled && applyChapterNotificationOffset) {
        resolvedPosition = _chapterNotificationOffset + requestedPosition;
      }

      final maxPosition = mediaAtStart.totalDuration;
      final boundedPosition = resolvedPosition < Duration.zero
          ? Duration.zero
          : (resolvedPosition > maxPosition ? maxPosition : resolvedPosition);

      if (!isInternal && (boundedPosition - fromPosition).abs() >= const Duration(seconds: 1)) {
        _syncService.markProgressDirty();
      }

      final shouldRecordPausedManualSeek =
          !isInternal &&
          !playerControlState.playing &&
          (playerControlState.processingState == ProcessingState.ready ||
              playerControlState.processingState == ProcessingState.completed);
      if (shouldRecordPausedManualSeek) {
        _markPausedManualSeek(boundedPosition);
      }

      if (isCastControlActive) {
        final relativePosition = _absoluteToCastRelativePosition(boundedPosition);
        await GoogleCastRemoteMediaClient.instance.seek(GoogleCastMediaSeekOption(position: relativePosition));
        if (!contextIsCurrent()) {
          return;
        }
        _refreshPlayerControlState();
        _refreshChapterNotificationState(customPosition: boundedPosition);
        _updateMediaItemForChapterNotification(customPosition: boundedPosition);
        await _updatePlaybackState();
        if (!isInternal) {
          _recordManualSeekIfNeeded(fromPosition, boundedPosition, internal: false);
        }
        didMutate = this.position != fromPosition;
        return;
      }

      final targetTrackIndex = mediaAtStart.getIndexForDuration(boundedPosition);
      if (targetTrackIndex < 0) {
        logger(
          'Ignoring seek with invalid track index for position: $boundedPosition',
          tag: 'AudioHandler',
          level: InfoLevel.warning,
        );
        return;
      }

      logger(
        'Seeking to position: $boundedPosition, track index: $targetTrackIndex',
        tag: 'AudioHandler',
        level: InfoLevel.debug,
      );
      final relativeTargetPosition = boundedPosition - mediaAtStart.startDurationForTrack(targetTrackIndex);
      final trackChanged = targetTrackIndex != _currentTrackIndex;

      if (trackChanged) {
        _currentTrackIndex = targetTrackIndex;
        await _player.seek(relativeTargetPosition, index: targetTrackIndex);
        if (!contextIsCurrent()) {
          return;
        }

        if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
          var ready = _player.playerState.processingState == ProcessingState.ready;
          if (!ready) {
            final state = await _player.playerStateStream.firstWhere(
              (state) =>
                  state.processingState == ProcessingState.ready ||
                  state.processingState == ProcessingState.completed ||
                  state.processingState == ProcessingState.idle,
            );
            ready = state.processingState == ProcessingState.ready;
          }
          if (!ready || !contextIsCurrent()) {
            return;
          }
          await _player.seek(relativeTargetPosition, index: targetTrackIndex);
          if (!contextIsCurrent()) {
            return;
          }
        }
      } else {
        await _player.seek(relativeTargetPosition, index: targetTrackIndex);
        if (!contextIsCurrent()) {
          return;
        }
      }

      _refreshChapterNotificationState(customPosition: boundedPosition);
      _updateMediaItemForChapterNotification(customPosition: boundedPosition);
      unawaited(_updatePlaybackState());
      if (!isInternal) {
        _recordManualSeekIfNeeded(fromPosition, boundedPosition, internal: false);
      }
      didMutate = this.position != fromPosition;
    } finally {
      if (isInternal) {
        _internalSeekGuardDepth -= 1;
        if (_internalSeekGuardDepth < 0) {
          _internalSeekGuardDepth = 0;
        }
        _isInternalSeek = _internalSeekGuardDepth > 0;
      }
      if (operationId != null) {
        _settleChapterSleepPositionMutation(operationId, kind, didMutate: didMutate);
      }
    }
  }
}
