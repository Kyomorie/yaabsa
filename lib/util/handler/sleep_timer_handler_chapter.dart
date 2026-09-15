// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of 'sleep_timer_handler.dart';

final Expando<_ChapterSleepTimerRuntime> _chapterSleepTimerRuntime = Expando<_ChapterSleepTimerRuntime>(
  'chapterSleepTimerRuntime',
);

class _ChapterSleepTimerRuntime {
  StreamSubscription<InternalChapter?>? watcher;
  StreamSubscription<Duration>? positionSubscription;
  StreamSubscription<SleepTimerPositionMutationEvent>? mutationSubscription;
  StreamSubscription<SleepTimerCompletionClaim>? completionSubscription;
  StreamSubscription<InternalMedia?>? mediaSubscription;
  StreamSubscription<bool>? castSubscription;

  final ChapterSleepReentryGate reentryGate = ChapterSleepReentryGate();

  int runGeneration = 0;
  int targetGeneration = 0;
  int expiryGeneration = 0;
  ChapterSleepExpiryState expiryState = ChapterSleepExpiryState.inactive;
  ChapterSleepTarget? armedTarget;
  SleepTimerCompletionProtectionToken? completionProtection;

  int fadeOwner = 0;
  double? fadeBaseVolume;
  int? fadeRestoreOwner;
  Future<void> volumeQueue = Future<void>.value();
}

class _ChapterSleepExpiryContext {
  const _ChapterSleepExpiryContext({
    required this.media,
    required this.sessionId,
    required this.binding,
    required this.runGeneration,
    required this.targetGeneration,
    required this.expiryGeneration,
    required this.navigationGeneration,
    required this.playbackActionGeneration,
    required this.protection,
    required this.target,
  });

  final SleepTimerMediaIdentity media;
  final String sessionId;
  final PlaybackSessionBinding? binding;
  final int runGeneration;
  final int targetGeneration;
  final int expiryGeneration;
  final int navigationGeneration;
  final int playbackActionGeneration;
  final SleepTimerCompletionProtectionToken protection;
  final ChapterSleepTarget target;
}

extension SleepTimerHandlerChapterEnd on SleepTimerHandler {
  _ChapterSleepTimerRuntime get _chapterRuntime {
    return _chapterSleepTimerRuntime[this] ??= _ChapterSleepTimerRuntime();
  }

  ChapterSleepTarget? get availableChapterSleepTarget {
    if (audioHandler.isCastControlActive) {
      return null;
    }
    final media = audioHandler.currentMediaItem;
    if (media == null) {
      return null;
    }
    return resolveChapterSleepTarget(media: media, position: audioHandler.position);
  }

  bool startUntilChapterEnd() {
    final target = availableChapterSleepTarget;
    final media = audioHandler.currentMediaItem;
    if (target == null || media == null) {
      return false;
    }

    if (state.isActive) {
      stop(suppressAutoRestart: false, recordHistory: false);
    }

    _timer?.cancel();
    _timer = null;
    _countdownStartTime = null;
    _countdownRunDuration = null;
    _pauseTriggeredByPlayback = false;
    _cancelMarkerVisibilityTimers();
    unawaited(_restoreFadeVolumeIfNeeded());
    unawaited(_setAutoRestartSuppressed(false));

    final runtime = _chapterRuntime;
    _cancelChapterSubscriptions(runtime);
    _clearChapterCompletionProtection(runtime);
    runtime.runGeneration += 1;
    runtime.targetGeneration += 1;
    runtime.expiryGeneration += 1;
    runtime.expiryState = ChapterSleepExpiryState.armed;
    runtime.armedTarget = target;
    runtime.reentryGate.reset();
    runtime.fadeOwner += 1;
    runtime.fadeRestoreOwner = null;

    runtime.completionProtection = audioHandler.armSleepTimerCompletionProtection(
      itemId: target.media.itemId,
      episodeId: target.media.episodeId,
      timerGeneration: runtime.runGeneration,
    );

    final marker = _createMarker();
    final remaining = target.remainingAt(audioHandler.position);
    state = SleepTimerData(
      remainingTime: remaining,
      state: SleepTimerState.running,
      mode: SleepTimerMode.chapterEnd,
      chapterTarget: target,
      marker: marker,
      showMarkerPin: false,
      showMarkerRange: false,
    );
    unawaited(_persistMarker(marker));
    if (audioHandler.playerControlState.playing) {
      _scheduleMarkerPinHide();
    }

    _attachChapterSubscriptions(runtime);
    _startFreshChapterWatcher(runtime, media, target);
    _applyChapterPositionUpdate(runtime, audioHandler.position);

    logger(
      'Chapter sleep timer armed for ${target.chapter.title} at ${target.endPosition.inSeconds}s',
      tag: 'SleepTimer',
      level: InfoLevel.info,
    );
    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        PlayerHistoryType.sleepTimerStarted,
        details: <String, Object?>{
          'mode': SleepTimerMode.chapterEnd.name,
          'targetPositionSeconds': target.endPosition.inSeconds,
          'remainingSeconds': remaining.inSeconds,
        },
      ),
    );
    return true;
  }

  Duration _chapterRemainingTime() {
    final target = _chapterRuntime.armedTarget;
    if (target == null || state.mode != SleepTimerMode.chapterEnd) {
      return state.remainingTime;
    }
    return target.remainingAt(audioHandler.position);
  }

  void _disposeChapterSleepTimerRuntime() {
    final runtime = _chapterSleepTimerRuntime[this];
    if (runtime == null) {
      return;
    }
    _cancelChapterSubscriptions(runtime);
    _clearChapterCompletionProtection(runtime);
    runtime.runGeneration += 1;
    runtime.targetGeneration += 1;
    runtime.expiryGeneration += 1;
    runtime.expiryState = ChapterSleepExpiryState.inactive;
    runtime.armedTarget = null;
    runtime.reentryGate.reset();
    _restoreChapterFade(runtime, owner: runtime.fadeOwner);
  }

  void _deactivateChapterTimerRuntime({bool restoreFade = true}) {
    final runtime = _chapterSleepTimerRuntime[this];
    if (runtime == null || (state.mode != SleepTimerMode.chapterEnd && runtime.armedTarget == null)) {
      return;
    }

    _cancelChapterSubscriptions(runtime);
    _clearChapterCompletionProtection(runtime);
    runtime.runGeneration += 1;
    runtime.targetGeneration += 1;
    runtime.expiryGeneration += 1;
    runtime.expiryState = ChapterSleepExpiryState.inactive;
    runtime.armedTarget = null;
    runtime.reentryGate.reset();
    if (restoreFade) {
      _restoreChapterFadeForTransition(runtime, reason: 'chapter sleep timer deactivation');
    }
  }

  void _attachChapterSubscriptions(_ChapterSleepTimerRuntime runtime) {
    runtime.mutationSubscription = audioHandler.sleepTimerPositionMutationStream.listen(
      (event) => _handleChapterMutation(runtime, event),
    );
    runtime.completionSubscription = audioHandler.sleepTimerCompletionClaimStream.listen(
      (claim) => _handleChapterCompletionClaim(runtime, claim),
    );
    runtime.mediaSubscription = audioHandler.mediaItemStream.listen((media) {
      final target = runtime.armedTarget;
      if (!_chapterRuntimeIsArmed(runtime) || target == null) {
        return;
      }
      if (media == null || !target.matchesMedia(media)) {
        _failClosedChapterTimer('playback media changed');
      }
    });
    runtime.castSubscription = audioHandler.castControlActiveStream.listen((castActive) {
      if (castActive && _chapterRuntimeIsArmedOrExpiring(runtime)) {
        _failClosedChapterTimer('Cast control became active');
      }
    });
    runtime.positionSubscription = audioHandler.positionStream.listen((position) {
      _applyChapterPositionUpdate(runtime, position);
    });
  }

  void _cancelChapterSubscriptions(_ChapterSleepTimerRuntime runtime) {
    unawaited(runtime.watcher?.cancel());
    runtime.watcher = null;
    unawaited(runtime.positionSubscription?.cancel());
    runtime.positionSubscription = null;
    unawaited(runtime.mutationSubscription?.cancel());
    runtime.mutationSubscription = null;
    unawaited(runtime.completionSubscription?.cancel());
    runtime.completionSubscription = null;
    unawaited(runtime.mediaSubscription?.cancel());
    runtime.mediaSubscription = null;
    unawaited(runtime.castSubscription?.cancel());
    runtime.castSubscription = null;
  }

  bool _sameChapter(InternalChapter? left, InternalChapter? right) {
    if (identical(left, right)) {
      return true;
    }
    if (left == null || right == null) {
      return false;
    }
    return left.start == right.start && left.end == right.end && left.title == right.title;
  }

  void _startFreshChapterWatcher(_ChapterSleepTimerRuntime runtime, InternalMedia media, ChapterSleepTarget target) {
    unawaited(runtime.watcher?.cancel());
    runtime.watcher = null;

    final runGeneration = runtime.runGeneration;
    final targetGeneration = runtime.targetGeneration;
    runtime.watcher = audioHandler.positionStream.map(media.getChapterForDuration).distinct(_sameChapter).listen((
      chapter,
    ) {
      if (!_chapterTargetIsCurrent(runtime, runGeneration, targetGeneration, target)) {
        return;
      }
      final shouldExpire = runtime.reentryGate.shouldExpire(
        isInArmedChapter: target.sameChapter(chapter),
        userNavigationActive: audioHandler.hasActiveSleepTimerUserNavigation,
        internalMutationActive: audioHandler.hasActiveSleepTimerInternalMutation,
      );
      if (shouldExpire) {
        _claimChapterExpiry(runtime, runGeneration, targetGeneration, target);
      }
    });
  }

  void _handleChapterMutation(_ChapterSleepTimerRuntime runtime, SleepTimerPositionMutationEvent event) {
    if (!_chapterRuntimeIsArmedOrExpiring(runtime)) {
      return;
    }

    if (audioHandler.hasActiveSleepTimerUserNavigation || audioHandler.hasActiveSleepTimerInternalMutation) {
      return;
    }

    if (event.kind == SleepTimerPositionMutationKind.userNavigation) {
      if (runtime.expiryState == ChapterSleepExpiryState.armed) {
        _retargetAfterUserNavigation(runtime);
      }
      return;
    }

    if (runtime.expiryState != ChapterSleepExpiryState.armed) {
      return;
    }

    switch (event.kind) {
      case SleepTimerPositionMutationKind.smartRewind:
        _refreshAfterSmartRewind(runtime);
        break;
      case SleepTimerPositionMutationKind.resumeProgressReconcile:
        _validateResumeReconcile(runtime);
        break;
      case SleepTimerPositionMutationKind.chapterExpiry:
        break;
      case SleepTimerPositionMutationKind.otherInternal:
        _validateOtherInternalMutation(runtime);
        break;
      case SleepTimerPositionMutationKind.userNavigation:
        break;
    }
  }

  void _handleChapterCompletionClaim(_ChapterSleepTimerRuntime runtime, SleepTimerCompletionClaim claim) {
    if (runtime.expiryState != ChapterSleepExpiryState.armed) {
      return;
    }
    final target = runtime.armedTarget;
    final protection = claim.protection;
    final ownedProtection = runtime.completionProtection;
    if (target == null ||
        protection == null ||
        ownedProtection == null ||
        !identical(protection.token, ownedProtection) ||
        protection.timerGeneration != runtime.runGeneration ||
        claim.media != target.media) {
      return;
    }

    if (claim.navigationActive ||
        audioHandler.hasActiveSleepTimerUserNavigation ||
        audioHandler.hasActiveSleepTimerInternalMutation ||
        runtime.reentryGate.isAwaitingArmedChapter) {
      return;
    }

    _claimChapterExpiry(runtime, runtime.runGeneration, runtime.targetGeneration, target);
  }

  void _retargetAfterUserNavigation(_ChapterSleepTimerRuntime runtime) {
    if (runtime.expiryState != ChapterSleepExpiryState.armed || audioHandler.isCastControlActive) {
      return;
    }
    if (audioHandler.hasActiveSleepTimerUserNavigation || audioHandler.hasActiveSleepTimerInternalMutation) {
      return;
    }

    final previousTarget = runtime.armedTarget;
    final media = audioHandler.currentMediaItem;
    if (previousTarget == null || media == null || !previousTarget.matchesMedia(media)) {
      _failClosedChapterTimer('media changed during user navigation');
      return;
    }

    final nextTarget = resolveChapterSleepTarget(media: media, position: audioHandler.position);
    if (nextTarget == null) {
      _failClosedChapterTimer('user navigation landed outside a valid chapter');
      return;
    }

    _retargetChapterTimer(runtime, media, nextTarget, reason: 'user navigation');
  }

  void _retargetChapterTimer(
    _ChapterSleepTimerRuntime runtime,
    InternalMedia media,
    ChapterSleepTarget target, {
    required String reason,
  }) {
    if (runtime.expiryState != ChapterSleepExpiryState.armed) {
      return;
    }

    runtime.targetGeneration += 1;
    runtime.expiryGeneration += 1;
    runtime.armedTarget = target;
    runtime.reentryGate.reset();
    runtime.fadeOwner += 1;
    runtime.fadeRestoreOwner = null;
    _clearChapterCompletionProtection(runtime);
    runtime.completionProtection = audioHandler.armSleepTimerCompletionProtection(
      itemId: target.media.itemId,
      episodeId: target.media.episodeId,
      timerGeneration: runtime.runGeneration,
    );

    final remaining = target.remainingAt(audioHandler.position);
    state = state.copyWith(
      remainingTime: remaining,
      mode: SleepTimerMode.chapterEnd,
      chapterTarget: target,
      clearTotalDuration: true,
    );
    _startFreshChapterWatcher(runtime, media, target);
    _applyChapterPositionUpdate(runtime, audioHandler.position);
    logger(
      'Chapter sleep timer retargeted to ${target.endPosition.inSeconds}s after $reason',
      tag: 'SleepTimer',
      level: InfoLevel.debug,
    );
  }

  void _refreshAfterSmartRewind(_ChapterSleepTimerRuntime runtime) {
    final target = runtime.armedTarget;
    final media = audioHandler.currentMediaItem;
    if (target == null || media == null || !target.matchesMedia(media)) {
      _failClosedChapterTimer('media changed during smart rewind');
      return;
    }

    final actualChapter = media.getChapterForDuration(audioHandler.position);
    runtime.reentryGate.afterSmartRewind(isInArmedChapter: target.sameChapter(actualChapter));
    _startFreshChapterWatcher(runtime, media, target);
    _applyChapterPositionUpdate(runtime, audioHandler.position);
  }

  void _validateResumeReconcile(_ChapterSleepTimerRuntime runtime) {
    final target = runtime.armedTarget;
    final media = audioHandler.currentMediaItem;
    if (target == null || media == null || !target.matchesMedia(media)) {
      _failClosedChapterTimer('media changed during resume progress reconcile');
      return;
    }
    final actualChapter = media.getChapterForDuration(audioHandler.position);
    if (!target.sameChapter(actualChapter)) {
      _failClosedChapterTimer('resume progress reconcile crossed the armed chapter');
      return;
    }
    _startFreshChapterWatcher(runtime, media, target);
    _applyChapterPositionUpdate(runtime, audioHandler.position);
  }

  void _validateOtherInternalMutation(_ChapterSleepTimerRuntime runtime) {
    final target = runtime.armedTarget;
    final media = audioHandler.currentMediaItem;
    if (target == null || media == null || !target.matchesMedia(media)) {
      _failClosedChapterTimer('media changed during internal position mutation');
      return;
    }
    final actualChapter = media.getChapterForDuration(audioHandler.position);
    if (!target.sameChapter(actualChapter)) {
      _failClosedChapterTimer('unclassified internal position mutation crossed the armed chapter');
      return;
    }
    _startFreshChapterWatcher(runtime, media, target);
    _applyChapterPositionUpdate(runtime, audioHandler.position);
  }

  void _applyChapterPositionUpdate(_ChapterSleepTimerRuntime runtime, Duration position) {
    if (runtime.expiryState != ChapterSleepExpiryState.armed ||
        state.mode != SleepTimerMode.chapterEnd ||
        !state.isRunning) {
      return;
    }
    final target = runtime.armedTarget;
    final media = audioHandler.currentMediaItem;
    if (target == null || media == null || !target.matchesMedia(media)) {
      return;
    }

    final remaining = target.remainingAt(position);
    if ((state.remainingTime - remaining).abs() >= _sleepTimerUiUpdateInterval) {
      state = state.copyWith(remainingTime: remaining, chapterTarget: target);
    }
    _applyChapterFade(runtime, remaining);
  }

  void _applyChapterFade(_ChapterSleepTimerRuntime runtime, Duration remaining) {
    if (!_isFadeOutEnabled() || remaining > _sleepTimerFadeOutDuration) {
      _restoreChapterFadeForTransition(runtime, reason: 'chapter sleep timer fade restore');
      return;
    }
    if (runtime.expiryState != ChapterSleepExpiryState.armed) {
      return;
    }

    runtime.fadeRestoreOwner = null;
    runtime.fadeBaseVolume ??= audioHandler.volume;
    final base = runtime.fadeBaseVolume;
    if (base == null || base <= 0) {
      return;
    }
    final progress = remaining.inMilliseconds / _sleepTimerFadeOutDuration.inMilliseconds;
    final clampedProgress = progress.clamp(0.0, 1.0);
    final curvedProgress = math.pow(clampedProgress, _sleepTimerFadeCurveExponent).toDouble();
    final targetVolume = (base * curvedProgress).clamp(0.0, base).toDouble();
    _queueChapterVolume(runtime, owner: runtime.fadeOwner, volume: targetVolume, reason: 'chapter sleep timer fade');
  }

  void _restoreChapterFadeForTransition(_ChapterSleepTimerRuntime runtime, {required String reason}) {
    _queueChapterFadeRestore(runtime, owner: runtime.fadeOwner, reason: reason);
  }

  void _restoreChapterFade(_ChapterSleepTimerRuntime runtime, {required int owner}) {
    _queueChapterFadeRestore(runtime, owner: owner, reason: 'chapter sleep timer fade restore');
  }

  void _queueChapterFadeRestore(_ChapterSleepTimerRuntime runtime, {required int owner, required String reason}) {
    final base = runtime.fadeBaseVolume;
    if (base == null || runtime.fadeRestoreOwner == owner) {
      return;
    }
    runtime.fadeRestoreOwner = owner;
    runtime.volumeQueue = runtime.volumeQueue.catchError((_) {}).then((_) async {
      if (runtime.fadeOwner != owner || runtime.fadeRestoreOwner != owner || runtime.fadeBaseVolume != base) {
        if (runtime.fadeRestoreOwner == owner) {
          runtime.fadeRestoreOwner = null;
        }
        return;
      }
      await _setPlayerVolumeSafely(base, reason: reason);
      if (runtime.fadeOwner == owner && runtime.fadeRestoreOwner == owner && runtime.fadeBaseVolume == base) {
        runtime.fadeBaseVolume = null;
        runtime.fadeRestoreOwner = null;
      }
    });
  }

  void _queueChapterVolume(
    _ChapterSleepTimerRuntime runtime, {
    required int owner,
    required double volume,
    required String reason,
  }) {
    runtime.volumeQueue = runtime.volumeQueue.catchError((_) {}).then((_) async {
      if (runtime.fadeOwner != owner) {
        return;
      }
      await _setPlayerVolumeSafely(volume, reason: reason);
    });
  }

  void _claimChapterExpiry(
    _ChapterSleepTimerRuntime runtime,
    int runGeneration,
    int targetGeneration,
    ChapterSleepTarget target,
  ) {
    if (!_chapterTargetIsCurrent(runtime, runGeneration, targetGeneration, target) ||
        runtime.expiryState != ChapterSleepExpiryState.armed ||
        audioHandler.hasActiveSleepTimerUserNavigation ||
        audioHandler.hasActiveSleepTimerInternalMutation ||
        runtime.reentryGate.isAwaitingArmedChapter) {
      return;
    }

    final media = audioHandler.currentMediaItem;
    final protection = runtime.completionProtection;
    if (media == null || !target.matchesMedia(media) || protection == null) {
      _failClosedChapterTimer('expiry ownership is incomplete');
      return;
    }

    final binding = ref.read(sessionRepositoryProvider).currentSessionBinding;
    if (binding != null && binding.sessionId != media.sessionId) {
      _failClosedChapterTimer('playback session no longer matches the armed media');
      return;
    }

    runtime.expiryState = ChapterSleepExpiryState.expiring;
    final expiryGeneration = ++runtime.expiryGeneration;
    audioHandler.noteChapterSleepExpiryClaim();

    final context = _ChapterSleepExpiryContext(
      media: target.media,
      sessionId: media.sessionId,
      binding: binding,
      runGeneration: runGeneration,
      targetGeneration: targetGeneration,
      expiryGeneration: expiryGeneration,
      navigationGeneration: audioHandler.sleepTimerNavigationGeneration,
      playbackActionGeneration: audioHandler.sleepTimerPlaybackActionGeneration,
      protection: protection,
      target: target,
    );

    state = state.copyWith(remainingTime: Duration.zero, chapterTarget: target);
    unawaited(_executeChapterExpiry(runtime, context));
  }

  Future<void> _executeChapterExpiry(_ChapterSleepTimerRuntime runtime, _ChapterSleepExpiryContext context) async {
    try {
      if (!_chapterExpiryIsCurrent(runtime, context)) {
        _abortChapterExpiryIfOwned(runtime, context, 'ownership changed before expiry execution');
        return;
      }

      logger(
        'Chapter sleep timer reached chapter end; pausing playback first',
        tag: 'SleepTimer',
        level: InfoLevel.info,
      );
      final paused = await audioHandler.pauseForChapterSleepTimer(
        media: context.media,
        sessionId: context.sessionId,
        navigationGeneration: context.navigationGeneration,
        playbackActionGeneration: context.playbackActionGeneration,
      );
      if (!paused || !_chapterExpiryIsCurrent(runtime, context)) {
        _abortChapterExpiryIfOwned(runtime, context, 'ownership changed while pausing playback');
        return;
      }

      final rewoundPosition = await audioHandler.applyChapterSleepTimerRewind(
        media: context.media,
        sessionId: context.sessionId,
        navigationGeneration: context.navigationGeneration,
        playbackActionGeneration: context.playbackActionGeneration,
      );
      if (rewoundPosition == null || !_chapterExpiryIsCurrent(runtime, context)) {
        _abortChapterExpiryIfOwned(runtime, context, 'ownership changed during expiry rewind');
        return;
      }

      final actionSetting = ref
          .read(settingsManagerProvider.notifier)
          .getGlobalSetting<String>(SettingKeys.sleepTimerExpireAction);
      final action = SleepTimerExpireAction.fromSettingValue(actionSetting);
      final binding = context.binding;

      if (action == SleepTimerExpireAction.stop) {
        if (binding != null) {
          await audioHandler.flushChapterSleepTimerProgress(
            binding: binding,
            position: rewoundPosition,
            media: context.media,
            sessionId: context.sessionId,
            navigationGeneration: context.navigationGeneration,
            playbackActionGeneration: context.playbackActionGeneration,
            sessionClosing: true,
            forcePositionSync: true,
          );
          if (!_chapterExpiryIsCurrent(runtime, context)) {
            _abortChapterExpiryIfOwned(runtime, context, 'ownership changed during closing progress flush');
            return;
          }
          final stopped = await audioHandler.stopForChapterSleepTimer(
            binding: binding,
            stopPosition: rewoundPosition,
            media: context.media,
            sessionId: context.sessionId,
            navigationGeneration: context.navigationGeneration,
            playbackActionGeneration: context.playbackActionGeneration,
          );
          if (!stopped) {
            _abortChapterExpiryIfOwned(runtime, context, 'ownership changed while stopping playback');
            return;
          }
          if (!_chapterExpiryRuntimeOwnerIsCurrent(runtime, context)) {
            return;
          }
        } else {
          logger(
            'Chapter sleep timer could not capture a session binding; playback remains paused instead of performing an unbound stop',
            tag: 'SleepTimer',
            level: InfoLevel.warning,
          );
        }
      } else if (binding != null) {
        await audioHandler.flushChapterSleepTimerProgress(
          binding: binding,
          position: rewoundPosition,
          media: context.media,
          sessionId: context.sessionId,
          navigationGeneration: context.navigationGeneration,
          playbackActionGeneration: context.playbackActionGeneration,
        );
        if (!_chapterExpiryIsCurrent(runtime, context)) {
          _abortChapterExpiryIfOwned(runtime, context, 'ownership changed during progress flush');
          return;
        }
      }

      _finishChapterExpiry(runtime, context, action);
    } catch (e, s) {
      logger('Chapter sleep timer expiry failed: $e\n$s', tag: 'SleepTimer', level: InfoLevel.warning);
      _abortChapterExpiryIfOwned(runtime, context, 'expiry operation failed');
    }
  }

  void _abortChapterExpiryIfOwned(
    _ChapterSleepTimerRuntime runtime,
    _ChapterSleepExpiryContext context,
    String reason,
  ) {
    if (!_chapterExpiryRuntimeOwnerIsCurrent(runtime, context)) {
      return;
    }
    logger('Chapter sleep timer expiry aborted: $reason', tag: 'SleepTimer', level: InfoLevel.debug);
    stop(suppressAutoRestart: false, recordHistory: false);
  }

  void _finishChapterExpiry(
    _ChapterSleepTimerRuntime runtime,
    _ChapterSleepExpiryContext context,
    SleepTimerExpireAction action,
  ) {
    if (!_chapterExpiryRuntimeOwnerIsCurrent(runtime, context)) {
      return;
    }

    runtime.expiryState = ChapterSleepExpiryState.finished;
    _cancelChapterSubscriptions(runtime);
    _clearChapterCompletionProtection(runtime, expected: context.protection);
    _restoreChapterFadeForTransition(runtime, reason: 'chapter sleep timer expiry fade restore');
    runtime.armedTarget = null;
    runtime.reentryGate.reset();

    final marker = state.marker?.copyWith(endPosition: context.target.endPosition);
    state = SleepTimerData(
      remainingTime: Duration.zero,
      state: SleepTimerState.inactive,
      mode: SleepTimerMode.duration,
      marker: marker,
      showMarkerPin: marker?.endPosition != null,
      showMarkerRange: marker?.endPosition != null,
    );
    _showMarker();
    unawaited(_persistMarker(marker));
    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        PlayerHistoryType.sleepTimerExpired,
        details: <String, Object?>{'action': action.name, 'mode': SleepTimerMode.chapterEnd.name},
      ),
    );
  }

  void _failClosedChapterTimer(String reason) {
    if (state.mode != SleepTimerMode.chapterEnd || !state.isActive) {
      return;
    }
    logger('Chapter sleep timer disabled fail-closed: $reason', tag: 'SleepTimer', level: InfoLevel.warning);
    stop(suppressAutoRestart: false, recordHistory: false);
  }

  bool _chapterRuntimeIsArmed(_ChapterSleepTimerRuntime runtime) {
    return runtime.expiryState == ChapterSleepExpiryState.armed &&
        state.mode == SleepTimerMode.chapterEnd &&
        state.isRunning &&
        runtime.armedTarget != null;
  }

  bool _chapterRuntimeIsArmedOrExpiring(_ChapterSleepTimerRuntime runtime) {
    return (runtime.expiryState == ChapterSleepExpiryState.armed ||
            runtime.expiryState == ChapterSleepExpiryState.expiring) &&
        state.mode == SleepTimerMode.chapterEnd &&
        runtime.armedTarget != null;
  }

  bool _chapterTargetIsCurrent(
    _ChapterSleepTimerRuntime runtime,
    int runGeneration,
    int targetGeneration,
    ChapterSleepTarget target,
  ) {
    return runtime.runGeneration == runGeneration &&
        runtime.targetGeneration == targetGeneration &&
        runtime.expiryState == ChapterSleepExpiryState.armed &&
        identical(runtime.armedTarget, target) &&
        target.matchesMedia(audioHandler.currentMediaItem);
  }

  bool _chapterExpiryRuntimeOwnerIsCurrent(_ChapterSleepTimerRuntime runtime, _ChapterSleepExpiryContext context) {
    return runtime.runGeneration == context.runGeneration &&
        runtime.targetGeneration == context.targetGeneration &&
        runtime.expiryGeneration == context.expiryGeneration &&
        runtime.expiryState == ChapterSleepExpiryState.expiring &&
        identical(runtime.completionProtection, context.protection) &&
        audioHandler.isSleepTimerCompletionProtectionCurrent(context.protection);
  }

  bool _chapterExpiryIsCurrent(_ChapterSleepTimerRuntime runtime, _ChapterSleepExpiryContext context) {
    return _chapterExpiryRuntimeOwnerIsCurrent(runtime, context) &&
        !audioHandler.isCastControlActive &&
        context.media.matchesMedia(audioHandler.currentMediaItem) &&
        audioHandler.isChapterSleepOwnershipCurrent(
          media: context.media,
          sessionId: context.sessionId,
          navigationGeneration: context.navigationGeneration,
          playbackActionGeneration: context.playbackActionGeneration,
        );
  }

  void _clearChapterCompletionProtection(
    _ChapterSleepTimerRuntime runtime, {
    SleepTimerCompletionProtectionToken? expected,
  }) {
    final protection = runtime.completionProtection;
    if (protection == null) {
      return;
    }
    if (expected != null && !identical(protection, expected)) {
      return;
    }
    if (audioHandler.clearSleepTimerCompletionProtection(protection)) {
      runtime.completionProtection = null;
    }
  }
}
