// lib/provider/sleep_timer_handler.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:yaabsa/database/settings_manager.dart';
import 'package:yaabsa/models/internal_media.dart';
import 'package:yaabsa/provider/player/session_provider.dart';
import 'package:yaabsa/util/audio_handler/bg_audio_handler.dart';
import 'package:yaabsa/util/audio_handler/chapter_sleep_timer_coordination.dart';
import 'package:yaabsa/util/audio_handler/player_history_handler.dart';
import 'package:yaabsa/util/globals.dart';
import 'package:yaabsa/util/logger.dart';
import 'package:yaabsa/util/setting_key.dart';

part 'sleep_timer_handler.g.dart';

enum SleepTimerState { inactive, running, paused }

const Duration _sleepTimerTickInterval = Duration(seconds: 1);
const Duration _sleepTimerUiUpdateInterval = Duration(milliseconds: 500);
const Duration _sleepTimerFadeOutDuration = Duration(seconds: 30);
const Duration _sleepTimerMarkerPinVisibilityDuration = Duration(seconds: 10);
const double _sleepTimerFadeCurveExponent = 1.8;

class SleepTimerData {
  final Duration remainingTime;
  final SleepTimerState state;
  final SleepTimerMode mode;
  final ChapterSleepExpiryState expiryState;
  final Duration? totalDuration;
  final SleepTimerMarker? marker;
  final String? chapterTitle;
  final bool? _showMarkerPinValue;
  final bool? _showMarkerRangeValue;
  final bool? _forceMarkerVisibilityValue;

  const SleepTimerData({
    required this.remainingTime,
    required this.state,
    this.mode = SleepTimerMode.duration,
    this.expiryState = ChapterSleepExpiryState.inactive,
    this.totalDuration,
    this.marker,
    this.chapterTitle,
    bool showMarkerPin = true,
    bool showMarkerRange = true,
    bool forceMarkerVisibility = false,
  }) : _showMarkerPinValue = showMarkerPin,
       _showMarkerRangeValue = showMarkerRange,
       _forceMarkerVisibilityValue = forceMarkerVisibility;

  bool get showMarkerPin => _showMarkerPinValue ?? marker?.endPosition != null;
  bool get showMarkerRange => _showMarkerRangeValue ?? marker?.endPosition != null;
  bool get forceMarkerVisibility => _forceMarkerVisibilityValue ?? false;

  bool get isActive => state != SleepTimerState.inactive;
  bool get isRunning => state == SleepTimerState.running;
  bool get isChapterEnd => mode == SleepTimerMode.chapterEnd;

  SleepTimerData copyWith({
    Duration? remainingTime,
    SleepTimerState? state,
    SleepTimerMode? mode,
    ChapterSleepExpiryState? expiryState,
    Duration? totalDuration,
    SleepTimerMarker? marker,
    String? chapterTitle,
    bool? showMarkerPin,
    bool? showMarkerRange,
    bool? forceMarkerVisibility,
  }) {
    return SleepTimerData(
      remainingTime: remainingTime ?? this.remainingTime,
      state: state ?? this.state,
      mode: mode ?? this.mode,
      expiryState: expiryState ?? this.expiryState,
      totalDuration: totalDuration ?? this.totalDuration,
      marker: marker ?? this.marker,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      showMarkerPin: showMarkerPin ?? this.showMarkerPin,
      showMarkerRange: showMarkerRange ?? this.showMarkerRange,
      forceMarkerVisibility: forceMarkerVisibility ?? this.forceMarkerVisibility,
    );
  }
}

class SleepTimerMarker {
  const SleepTimerMarker({
    required this.itemId,
    required this.episodeId,
    required this.startPosition,
    this.endPosition,
  });

  final String itemId;
  final String? episodeId;
  final Duration startPosition;
  final Duration? endPosition;

  SleepTimerMarker copyWith({Duration? endPosition, bool clearEndPosition = false}) {
    return SleepTimerMarker(
      itemId: itemId,
      episodeId: episodeId,
      startPosition: startPosition,
      endPosition: clearEndPosition ? null : endPosition ?? this.endPosition,
    );
  }

  bool matches({required String itemId, required String? episodeId}) {
    return this.itemId == itemId && this.episodeId == episodeId;
  }

  String toRawJson() {
    return jsonEncode(<String, Object?>{
      'itemId': itemId,
      'episodeId': episodeId,
      'startPositionMicros': startPosition.inMicroseconds,
      'endPositionMicros': endPosition?.inMicroseconds,
    });
  }

  static SleepTimerMarker? fromRawJson(String? rawValue) {
    if (rawValue == null || rawValue.trim().isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is! Map) {
        return null;
      }

      final itemId = decoded['itemId'];
      final episodeId = decoded['episodeId'];
      final startPositionMicros = decoded['startPositionMicros'];
      final endPositionMicros = decoded['endPositionMicros'];
      if (itemId is! String || itemId.trim().isEmpty || startPositionMicros is! num) {
        return null;
      }

      return SleepTimerMarker(
        itemId: itemId.trim(),
        episodeId: episodeId is String && episodeId.trim().isNotEmpty ? episodeId.trim() : null,
        startPosition: Duration(microseconds: startPositionMicros.toInt()),
        endPosition: endPositionMicros is num ? Duration(microseconds: endPositionMicros.toInt()) : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class _ChapterExpiryContext {
  const _ChapterExpiryContext({
    required this.media,
    required this.sessionId,
    required this.sessionBinding,
    required this.runGeneration,
    required this.expiryGeneration,
    required this.navigationGeneration,
    required this.playbackActionGeneration,
    required this.completionProtection,
    required this.fadeOwner,
  });

  final SleepTimerMediaIdentity media;
  final String sessionId;
  final PlaybackSessionBinding sessionBinding;
  final int runGeneration;
  final int expiryGeneration;
  final int navigationGeneration;
  final int playbackActionGeneration;
  final SleepTimerCompletionProtectionToken completionProtection;
  final int fadeOwner;
}

@riverpod
class SleepTimerHandler extends _$SleepTimerHandler {
  Timer? _timer;
  DateTime? _countdownStartTime;
  Duration? _countdownRunDuration;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<InternalMedia?>? _mediaSubscription;
  StreamSubscription<bool>? _castSubscription;
  StreamSubscription<SleepTimerPositionMutationEvent>? _positionMutationSubscription;
  StreamSubscription<SleepTimerCompletionClaim>? _completionClaimSubscription;
  StreamSubscription<InternalChapter?>? _chapterWatcherSubscription;
  StreamSubscription<Duration>? _chapterPositionSubscription;
  bool _wasPlaybackRunning = false;
  bool _pauseTriggeredByPlayback = false;

  double? _fadeBaseVolume;
  int? _fadeOwner;
  int _fadeOwnerSequence = 0;
  Future<void> _fadeMutationQueue = Future<void>.value();

  Timer? _markerPinHideTimer;
  Timer? _markerRangeHideTimer;

  ChapterSleepTarget? _armedChapter;
  int _runGeneration = 0;
  int _targetGeneration = 0;
  int _expiryGeneration = 0;
  ChapterSleepExpiryState _expiryState = ChapterSleepExpiryState.inactive;
  final Set<int> _activeUserNavigations = <int>{};
  final Map<int, SleepTimerPositionMutationKind> _activeInternalMutations =
      <int, SleepTimerPositionMutationKind>{};
  SleepTimerCompletionProtectionToken? _completionProtection;

  @override
  SleepTimerData build() {
    _attachPlaybackStateListener();
    _attachChapterCoordinationListeners();

    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _countdownStartTime = null;
      _countdownRunDuration = null;
      _markerPinHideTimer?.cancel();
      _markerPinHideTimer = null;
      _markerRangeHideTimer?.cancel();
      _markerRangeHideTimer = null;

      unawaited(_playerStateSubscription?.cancel());
      _playerStateSubscription = null;
      unawaited(_mediaSubscription?.cancel());
      _mediaSubscription = null;
      unawaited(_castSubscription?.cancel());
      _castSubscription = null;
      unawaited(_positionMutationSubscription?.cancel());
      _positionMutationSubscription = null;
      unawaited(_completionClaimSubscription?.cancel());
      _completionClaimSubscription = null;
      _cancelChapterWatcher();

      final protection = _completionProtection;
      if (protection != null) {
        audioHandler.clearSleepTimerCompletionProtection(protection);
      }
      _completionProtection = null;
      final owner = _fadeOwner;
      if (owner != null) {
        unawaited(_restoreFadeVolumeIfOwned(owner));
      }
    });

    final markerRawValue = ref
        .read(settingsManagerProvider.notifier)
        .getGlobalSetting<String>(SettingKeys.sleepTimerMarker, defaultValue: '');
    final marker = SleepTimerMarker.fromRawJson(markerRawValue);
    final hasEnded = marker?.endPosition != null;
    return SleepTimerData(
      remainingTime: Duration.zero,
      state: SleepTimerState.inactive,
      marker: marker,
      showMarkerPin: hasEnded,
      showMarkerRange: hasEnded,
    );
  }

  void _attachPlaybackStateListener() {
    try {
      _wasPlaybackRunning = audioHandler.playerControlState.playing;
      _playerStateSubscription = audioHandler.playerControlStateStream.listen(_handlePlayerStateChanged);
    } catch (e) {
      logger('Failed to attach sleep timer playback listener: $e', tag: 'SleepTimer', level: InfoLevel.warning);
    }
  }

  void _attachChapterCoordinationListeners() {
    try {
      _mediaSubscription = audioHandler.mediaItemStream.listen(_handleMediaChanged);
      _castSubscription = audioHandler.castControlActiveStream.listen(_handleCastChanged);
      _positionMutationSubscription = audioHandler.sleepTimerPositionMutationStream.listen(_handlePositionMutation);
      _completionClaimSubscription = audioHandler.sleepTimerCompletionClaimStream.listen(_handleCompletionClaim);
    } catch (e) {
      logger('Failed to attach chapter sleep timer listeners: $e', tag: 'SleepTimer', level: InfoLevel.warning);
    }
  }

  void _handlePlayerStateChanged(PlayerState playerState) {
    final isRunning = playerState.playing;
    final wasRunning = _wasPlaybackRunning;
    _wasPlaybackRunning = isRunning;

    if (state.isChapterEnd) {
      return;
    }

    if (wasRunning && !isRunning && state.isRunning) {
      pause(triggeredByPlaybackPause: true);
      return;
    }

    if (!wasRunning && isRunning) {
      if (_pauseTriggeredByPlayback && state.state == SleepTimerState.paused) {
        resume();
        _scheduleMarkerPinHide();
        return;
      }

      _scheduleMarkerPinHide();
      unawaited(_tryAutoRestartSleepTimerOnPlaybackStart());
    }
  }

  void _handleMediaChanged(InternalMedia? media) {
    if (!state.isChapterEnd || _expiryState == ChapterSleepExpiryState.inactive) {
      return;
    }

    final armed = _armedChapter;
    if (armed == null) {
      return;
    }

    if (media == null && _expiryState == ChapterSleepExpiryState.expiring) {
      return;
    }

    if (!armed.matchesMedia(media)) {
      _failClosedChapterTimer('media identity changed');
    }
  }

  void _handleCastChanged(bool castActive) {
    if (castActive && state.isChapterEnd && state.isActive) {
      _failClosedChapterTimer('cast became active');
    }
  }

  void _handlePositionMutation(SleepTimerPositionMutationEvent event) {
    if (!state.isChapterEnd || !state.isActive) {
      return;
    }

    if (event.phase == SleepTimerPositionMutationPhase.began) {
      if (event.kind == SleepTimerPositionMutationKind.userNavigation) {
        _activeUserNavigations.add(event.operationId);
      } else {
        _activeInternalMutations[event.operationId] = event.kind;
      }
      return;
    }

    if (event.kind == SleepTimerPositionMutationKind.userNavigation) {
      _activeUserNavigations.remove(event.operationId);
      if (_activeUserNavigations.isEmpty && _expiryState == ChapterSleepExpiryState.armed) {
        _retargetChapterFromActualPosition('user navigation settled');
      }
      return;
    }

    _activeInternalMutations.remove(event.operationId);
    if (_activeUserNavigations.isNotEmpty || _activeInternalMutations.isNotEmpty) {
      return;
    }
    if (_expiryState != ChapterSleepExpiryState.armed) {
      return;
    }

    switch (event.kind) {
      case SleepTimerPositionMutationKind.smartRewind:
        _restartChapterWatcherKeepingTarget('smart rewind settled');
        break;
      case SleepTimerPositionMutationKind.resumeProgressReconcile:
        final armed = _armedChapter;
        final media = audioHandler.currentMediaItem;
        final currentTarget = media == null
            ? null
            : resolveChapterSleepTarget(media: media, position: audioHandler.position);
        if (armed == null || currentTarget == null || !armed.matchesMedia(media) || !armed.sameChapter(currentTarget.chapter)) {
          _failClosedChapterTimer('resume progress reconcile crossed chapter boundary');
        } else {
          _restartChapterWatcherKeepingTarget('resume progress reconcile settled');
        }
        break;
      case SleepTimerPositionMutationKind.chapterExpiry:
        break;
      case SleepTimerPositionMutationKind.otherInternal:
        final armed = _armedChapter;
        final media = audioHandler.currentMediaItem;
        final currentTarget = media == null
            ? null
            : resolveChapterSleepTarget(media: media, position: audioHandler.position);
        if (armed == null || currentTarget == null || !armed.matchesMedia(media) || !armed.sameChapter(currentTarget.chapter)) {
          _failClosedChapterTimer('unclassified internal seek crossed chapter boundary');
        } else {
          _restartChapterWatcherKeepingTarget('internal seek settled');
        }
        break;
      case SleepTimerPositionMutationKind.userNavigation:
        break;
    }
  }

  void _handleCompletionClaim(SleepTimerCompletionClaim claim) {
    if (!state.isChapterEnd || _expiryState != ChapterSleepExpiryState.armed) {
      return;
    }

    final armed = _armedChapter;
    final protection = _completionProtection;
    if (armed == null || protection == null || claim.protection?.token.value != protection.value) {
      return;
    }
    if (claim.media != armed.media) {
      return;
    }

    if (claim.navigationActive || _activeUserNavigations.isNotEmpty || _activeInternalMutations.isNotEmpty) {
      return;
    }

    _claimChapterExpiry('processing completed before watcher transition');
  }

  bool _isFadeOutEnabled() {
    return ref.read(settingsManagerProvider.notifier).getGlobalSetting<bool>(SettingKeys.sleepTimerFadeOutEnabled);
  }

  Duration _remainingForCurrentRun() {
    final countdownStartTime = _countdownStartTime;
    final countdownRunDuration = _countdownRunDuration;
    if (countdownStartTime == null || countdownRunDuration == null) {
      return state.remainingTime;
    }

    final elapsed = DateTime.now().difference(countdownStartTime);
    final remaining = countdownRunDuration - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<void> _setPlayerVolumeSafely(double volume, {required String reason}) async {
    try {
      await audioHandler.setVolume(volume);
    } catch (e) {
      logger('Failed to set volume during $reason: $e', tag: 'SleepTimer', level: InfoLevel.warning);
    }
  }

  int _beginFadeOwner() {
    final inheritedBase = _fadeBaseVolume ?? audioHandler.volume;
    final owner = ++_fadeOwnerSequence;
    _fadeBaseVolume = inheritedBase;
    _fadeOwner = owner;
    return owner;
  }

  Future<void> _queueFadeVolume(int owner, double volume, {bool clearAfter = false, required String reason}) {
    final next = _fadeMutationQueue.catchError((_) {}).then((_) async {
      if (_fadeOwner != owner) {
        return;
      }
      await _setPlayerVolumeSafely(volume, reason: reason);
      if (clearAfter && _fadeOwner == owner) {
        _fadeOwner = null;
        _fadeBaseVolume = null;
      }
    });
    _fadeMutationQueue = next.catchError((_) {});
    return next;
  }

  Future<void> _restoreFadeVolumeIfOwned(int owner) async {
    if (_fadeOwner != owner) {
      return;
    }
    final fadeBaseVolume = _fadeBaseVolume;
    if (fadeBaseVolume == null) {
      if (_fadeOwner == owner) {
        _fadeOwner = null;
      }
      return;
    }
    await _queueFadeVolume(
      owner,
      fadeBaseVolume,
      clearAfter: true,
      reason: 'sleep timer fade volume restore',
    );
  }

  void _applyFadeOutIfNeeded(Duration remaining, int owner) {
    if (_fadeOwner != owner) {
      return;
    }
    final fadeBaseVolume = _fadeBaseVolume;
    if (fadeBaseVolume == null) {
      return;
    }

    if (!_isFadeOutEnabled() || remaining > _sleepTimerFadeOutDuration) {
      unawaited(
        _queueFadeVolume(owner, fadeBaseVolume, reason: 'sleep timer fade reset outside fade window'),
      );
      return;
    }

    if (fadeBaseVolume <= 0) {
      return;
    }

    final progress = remaining.inMilliseconds / _sleepTimerFadeOutDuration.inMilliseconds;
    final clampedProgress = progress.clamp(0.0, 1.0);
    final curvedProgress = math.pow(clampedProgress, _sleepTimerFadeCurveExponent).toDouble();
    final targetVolume = (fadeBaseVolume * curvedProgress).clamp(0.0, fadeBaseVolume).toDouble();

    unawaited(_queueFadeVolume(owner, targetVolume, reason: 'sleep timer fade out'));
  }

  int _normalizeMinutesOfDay(int value) {
    final modulo = value % (24 * 60);
    return modulo < 0 ? modulo + (24 * 60) : modulo;
  }

  bool _isWithinAutoRestartTimeRange() {
    final settingManager = ref.read(settingsManagerProvider.notifier);
    final useTimeRange = settingManager.getGlobalSetting<bool>(SettingKeys.sleepTimerAutoRestartUseTimeRange);
    if (!useTimeRange) {
      return true;
    }

    final startMinutesRaw = settingManager.getGlobalSetting<int>(SettingKeys.sleepTimerAutoRestartRangeStartMinutes);
    final endMinutesRaw = settingManager.getGlobalSetting<int>(SettingKeys.sleepTimerAutoRestartRangeEndMinutes);
    final startMinutes = _normalizeMinutesOfDay(startMinutesRaw);
    final endMinutes = _normalizeMinutesOfDay(endMinutesRaw);

    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;

    if (startMinutes == endMinutes) {
      return true;
    }

    if (startMinutes < endMinutes) {
      return nowMinutes >= startMinutes && nowMinutes < endMinutes;
    }

    return nowMinutes >= startMinutes || nowMinutes < endMinutes;
  }

  Future<void> _setAutoRestartSuppressed(bool value) async {
    try {
      await ref
          .read(settingsManagerProvider.notifier)
          .setGlobalSetting<bool>(SettingKeys.sleepTimerAutoRestartSuppressed, value);
    } catch (e) {
      logger('Failed to update sleep timer auto-restart suppression: $e', tag: 'SleepTimer', level: InfoLevel.warning);
    }
  }

  Future<void> _persistLastDuration(Duration duration) async {
    final minutes = duration.inMinutes < 1 ? 1 : duration.inMinutes;
    try {
      await ref
          .read(settingsManagerProvider.notifier)
          .setGlobalSetting<int>(SettingKeys.sleepTimerLastDurationMinutes, minutes);
    } catch (e) {
      logger('Failed to persist last sleep timer duration: $e', tag: 'SleepTimer', level: InfoLevel.warning);
    }
  }

  Future<void> _persistMarker(SleepTimerMarker? marker) async {
    try {
      await ref
          .read(settingsManagerProvider.notifier)
          .setGlobalSetting<String>(SettingKeys.sleepTimerMarker, marker?.toRawJson() ?? '');
    } catch (e) {
      logger('Failed to persist sleep timer marker: $e', tag: 'SleepTimer', level: InfoLevel.warning);
    }
  }

  void _cancelMarkerVisibilityTimers() {
    _markerPinHideTimer?.cancel();
    _markerPinHideTimer = null;
    _markerRangeHideTimer?.cancel();
    _markerRangeHideTimer = null;
  }

  void _setMarkerVisibility({bool? showPin, bool? showRange, bool? forceMarkerVisibility}) {
    final marker = state.marker;
    if (marker == null) {
      return;
    }

    final nextShowPin = showPin ?? state.showMarkerPin;
    final nextShowRange = showRange ?? state.showMarkerRange;
    final nextForceMarkerVisibility = forceMarkerVisibility ?? state.forceMarkerVisibility;
    if (nextShowPin == state.showMarkerPin &&
        nextShowRange == state.showMarkerRange &&
        nextForceMarkerVisibility == state.forceMarkerVisibility) {
      return;
    }

    state = SleepTimerData(
      remainingTime: state.remainingTime,
      state: state.state,
      mode: state.mode,
      expiryState: state.expiryState,
      totalDuration: state.totalDuration,
      marker: marker,
      chapterTitle: state.chapterTitle,
      showMarkerPin: nextShowPin,
      showMarkerRange: nextShowRange,
      forceMarkerVisibility: nextForceMarkerVisibility,
    );
  }

  void _showMarker({bool showPin = true}) {
    final marker = state.marker;
    if (marker == null) {
      return;
    }

    _markerPinHideTimer?.cancel();
    _markerPinHideTimer = null;
    _markerRangeHideTimer?.cancel();
    _markerRangeHideTimer = null;
    final hasEnded = marker.endPosition != null;
    _setMarkerVisibility(showPin: showPin && hasEnded, showRange: hasEnded);
  }

  void _scheduleMarkerPinHide() {
    if (state.marker == null || !state.showMarkerPin) {
      return;
    }

    _markerPinHideTimer?.cancel();
    _markerPinHideTimer = Timer(_sleepTimerMarkerPinVisibilityDuration, () {
      _markerPinHideTimer = null;
      _setMarkerVisibility(showPin: false, showRange: false, forceMarkerVisibility: false);
    });
  }

  void dismissMarkerPin() {
    if (state.marker == null) {
      return;
    }

    _markerPinHideTimer?.cancel();
    _markerPinHideTimer = null;
    _markerRangeHideTimer?.cancel();
    _setMarkerVisibility(showPin: false, showRange: true, forceMarkerVisibility: false);
    _markerRangeHideTimer = Timer(_sleepTimerMarkerPinVisibilityDuration, () {
      _markerRangeHideTimer = null;
      _setMarkerVisibility(showRange: false);
    });
  }

  bool toggleSleepTimerMarker() {
    final marker = state.marker;
    final media = audioHandler.currentMediaItem;
    if (marker == null || media == null || !marker.matches(itemId: media.itemId, episodeId: media.episodeId)) {
      return false;
    }

    final showMarkerSetting = ref
        .read(settingsManagerProvider.notifier)
        .getGlobalSetting<bool>(SettingKeys.sleepTimerShowMarker);
    final isMarkerVisible =
        state.forceMarkerVisibility || (showMarkerSetting && (state.showMarkerPin || state.showMarkerRange));
    if (isMarkerVisible) {
      _cancelMarkerVisibilityTimers();
      state = state.copyWith(showMarkerPin: false, showMarkerRange: false, forceMarkerVisibility: false);
      return true;
    }

    final markerWithEnd = marker.endPosition == null ? _completeMarkerAtCurrentPosition() : marker;
    if (markerWithEnd == null) {
      return false;
    }

    _cancelMarkerVisibilityTimers();
    state = state.copyWith(
      marker: markerWithEnd,
      showMarkerPin: markerWithEnd.endPosition != null,
      showMarkerRange: markerWithEnd.endPosition != null,
      forceMarkerVisibility: true,
    );
    unawaited(_persistMarker(markerWithEnd));
    return true;
  }

  SleepTimerMarker? _createMarker() {
    final media = audioHandler.currentMediaItem;
    if (media == null) {
      return null;
    }

    return SleepTimerMarker(itemId: media.itemId, episodeId: media.episodeId, startPosition: audioHandler.position);
  }

  SleepTimerMarker? _completeMarkerAtCurrentPosition() {
    final marker = state.marker;
    final media = audioHandler.currentMediaItem;
    if (marker == null || media == null || !marker.matches(itemId: media.itemId, episodeId: media.episodeId)) {
      return marker;
    }

    return marker.copyWith(endPosition: audioHandler.position);
  }

  Future<void> _tryAutoRestartSleepTimerOnPlaybackStart() async {
    if (state.isActive) {
      return;
    }

    final settingManager = ref.read(settingsManagerProvider.notifier);
    final autoRestartEnabled = settingManager.getGlobalSetting<bool>(SettingKeys.sleepTimerAutoRestartEnabled);
    if (!autoRestartEnabled) {
      return;
    }

    final autoRestartSuppressed = settingManager.getGlobalSetting<bool>(SettingKeys.sleepTimerAutoRestartSuppressed);
    if (autoRestartSuppressed) {
      logger('Sleep timer auto-restart is suppressed after manual stop', tag: 'SleepTimer', level: InfoLevel.debug);
      return;
    }

    if (!_isWithinAutoRestartTimeRange()) {
      logger(
        'Sleep timer auto-restart skipped outside configured time range',
        tag: 'SleepTimer',
        level: InfoLevel.debug,
      );
      return;
    }

    final rememberedMinutes = settingManager.getGlobalSetting<int>(SettingKeys.sleepTimerLastDurationMinutes);
    final safeMinutes = rememberedMinutes < 1 ? 30 : rememberedMinutes;

    logger('Auto-restarting sleep timer for $safeMinutes minutes', tag: 'SleepTimer', level: InfoLevel.info);
    start(Duration(minutes: safeMinutes), automatic: true);
  }

  void _cancelDurationTimer() {
    _timer?.cancel();
    _timer = null;
    _countdownStartTime = null;
    _countdownRunDuration = null;
    _pauseTriggeredByPlayback = false;
  }

  void _cancelChapterWatcher() {
    final chapterWatcher = _chapterWatcherSubscription;
    _chapterWatcherSubscription = null;
    if (chapterWatcher != null) {
      unawaited(chapterWatcher.cancel());
    }
    final positionWatcher = _chapterPositionSubscription;
    _chapterPositionSubscription = null;
    if (positionWatcher != null) {
      unawaited(positionWatcher.cancel());
    }
  }

  void _clearChapterCoordination({required bool clearProtection}) {
    _runGeneration += 1;
    _targetGeneration += 1;
    _cancelChapterWatcher();
    _activeUserNavigations.clear();
    _activeInternalMutations.clear();
    _armedChapter = null;
    _expiryState = ChapterSleepExpiryState.inactive;
    if (clearProtection) {
      final protection = _completionProtection;
      if (protection != null) {
        audioHandler.clearSleepTimerCompletionProtection(protection);
      }
      _completionProtection = null;
    }
  }

  void start(Duration duration, {bool automatic = false}) {
    if (duration <= Duration.zero) {
      return;
    }

    if (state.isActive) {
      stop(suppressAutoRestart: false, recordHistory: false);
    }

    _clearChapterCoordination(clearProtection: true);
    _pauseTriggeredByPlayback = false;

    final oldFadeOwner = _fadeOwner;
    if (oldFadeOwner != null) {
      unawaited(_restoreFadeVolumeIfOwned(oldFadeOwner));
    }
    final fadeOwner = _beginFadeOwner();

    unawaited(_setAutoRestartSuppressed(false));
    unawaited(_persistLastDuration(duration));

    logger('Sleep timer started for ${duration.inMinutes} minutes', tag: 'SleepTimer', level: InfoLevel.info);

    _cancelMarkerVisibilityTimers();
    final marker = _createMarker();
    state = SleepTimerData(
      remainingTime: duration,
      state: SleepTimerState.running,
      mode: SleepTimerMode.duration,
      totalDuration: duration,
      marker: marker,
      showMarkerPin: false,
      showMarkerRange: false,
    );
    unawaited(_persistMarker(marker));

    if (audioHandler.playerControlState.playing) {
      _scheduleMarkerPinHide();
    }

    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        automatic ? PlayerHistoryType.sleepTimerAutoStarted : PlayerHistoryType.sleepTimerStarted,
        details: <String, Object?>{'durationSeconds': duration.inSeconds},
      ),
    );

    _startTimer(duration, fadeOwner);
  }

  bool get canStartChapterEnd {
    if (audioHandler.isCastControlActive) {
      return false;
    }
    final media = audioHandler.currentMediaItem;
    if (media == null) {
      return false;
    }
    return resolveChapterSleepTarget(media: media, position: audioHandler.position) != null;
  }

  bool startChapterEnd() {
    if (audioHandler.isCastControlActive) {
      logger('Chapter sleep timer is unavailable while casting', tag: 'SleepTimer', level: InfoLevel.debug);
      return false;
    }

    final media = audioHandler.currentMediaItem;
    if (media == null) {
      return false;
    }
    final target = resolveChapterSleepTarget(media: media, position: audioHandler.position);
    if (target == null) {
      logger('Chapter sleep timer refused invalid/gap chapter target', tag: 'SleepTimer', level: InfoLevel.warning);
      return false;
    }

    if (state.isActive) {
      stop(suppressAutoRestart: false, recordHistory: false);
    }
    _cancelDurationTimer();
    _clearChapterCoordination(clearProtection: true);
    _cancelMarkerVisibilityTimers();

    _runGeneration += 1;
    _expiryState = ChapterSleepExpiryState.armed;
    _armedChapter = target;
    _completionProtection = audioHandler.armSleepTimerCompletionProtection(
      itemId: media.itemId,
      episodeId: media.episodeId,
      timerGeneration: _runGeneration,
    );
    final fadeOwner = _beginFadeOwner();

    final remaining = target.remainingAt(audioHandler.position);
    final marker = _createMarker();
    state = SleepTimerData(
      remainingTime: remaining,
      state: SleepTimerState.running,
      mode: SleepTimerMode.chapterEnd,
      expiryState: ChapterSleepExpiryState.armed,
      totalDuration: target.endPosition - target.startPosition,
      marker: marker,
      chapterTitle: target.chapter.title,
      showMarkerPin: false,
      showMarkerRange: false,
    );
    unawaited(_persistMarker(marker));
    unawaited(_setAutoRestartSuppressed(false));
    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        PlayerHistoryType.sleepTimerStarted,
        details: <String, Object?>{
          'mode': 'chapterEnd',
          'chapterTitle': target.chapter.title,
          'remainingSeconds': remaining.inSeconds,
        },
      ),
    );

    _startFreshChapterWatcher(target, fadeOwner, reason: 'chapter timer started');
    logger('Chapter sleep timer armed for ${target.chapter.title}', tag: 'SleepTimer', level: InfoLevel.info);
    return true;
  }

  void _startFreshChapterWatcher(ChapterSleepTarget target, int fadeOwner, {required String reason}) {
    if (!state.isChapterEnd || _expiryState != ChapterSleepExpiryState.armed) {
      return;
    }

    _cancelChapterWatcher();
    _targetGeneration += 1;
    final runGeneration = _runGeneration;
    final targetGeneration = _targetGeneration;
    final capturedMedia = audioHandler.currentMediaItem;
    if (capturedMedia == null || !target.matchesMedia(capturedMedia)) {
      _failClosedChapterTimer('watcher could not bind current media');
      return;
    }

    final directChapter = capturedMedia.getChapterForDuration(audioHandler.position);
    InternalChapter? previousChapter = directChapter;

    _chapterWatcherSubscription = audioHandler.positionStream
        .map(capturedMedia.getChapterForDuration)
        .distinct((previous, next) => target.sameChapter(previous) && target.sameChapter(next) || previous == next)
        .listen((nextChapter) {
          if (runGeneration != _runGeneration || targetGeneration != _targetGeneration) {
            return;
          }
          final previous = previousChapter;
          previousChapter = nextChapter;

          if (_expiryState != ChapterSleepExpiryState.armed ||
              _activeUserNavigations.isNotEmpty ||
              _activeInternalMutations.isNotEmpty ||
              !target.matchesMedia(audioHandler.currentMediaItem)) {
            return;
          }

          if (target.sameChapter(previous) && !target.sameChapter(nextChapter)) {
            _claimChapterExpiry('natural chapter transition');
          }
        });

    _chapterPositionSubscription = audioHandler.positionStream.listen((position) {
      if (runGeneration != _runGeneration || targetGeneration != _targetGeneration) {
        return;
      }
      if (_expiryState != ChapterSleepExpiryState.armed ||
          _activeUserNavigations.isNotEmpty ||
          _activeInternalMutations.isNotEmpty) {
        return;
      }
      final remaining = target.remainingAt(position);
      _applyFadeOutIfNeeded(remaining, fadeOwner);
      if ((state.remainingTime - remaining).abs() >= _sleepTimerUiUpdateInterval) {
        state = state.copyWith(remainingTime: remaining);
      }
    });

    final remaining = target.remainingAt(audioHandler.position);
    _applyFadeOutIfNeeded(remaining, fadeOwner);
    state = SleepTimerData(
      remainingTime: remaining,
      state: SleepTimerState.running,
      mode: SleepTimerMode.chapterEnd,
      expiryState: ChapterSleepExpiryState.armed,
      totalDuration: target.endPosition - target.startPosition,
      marker: state.marker,
      chapterTitle: target.chapter.title,
      showMarkerPin: state.showMarkerPin,
      showMarkerRange: state.showMarkerRange,
      forceMarkerVisibility: state.forceMarkerVisibility,
    );
    logger('Chapter sleep watcher refreshed: $reason', tag: 'SleepTimer', level: InfoLevel.debug);
  }

  void _retargetChapterFromActualPosition(String reason) {
    if (!state.isChapterEnd || _expiryState != ChapterSleepExpiryState.armed) {
      return;
    }
    final media = audioHandler.currentMediaItem;
    if (media == null || audioHandler.isCastControlActive) {
      _failClosedChapterTimer('$reason: no valid local media');
      return;
    }

    final target = resolveChapterSleepTarget(media: media, position: audioHandler.position);
    if (target == null) {
      _failClosedChapterTimer('$reason: invalid/gap chapter');
      return;
    }

    final oldProtection = _completionProtection;
    _runGeneration += 1;
    _armedChapter = target;
    _completionProtection = audioHandler.armSleepTimerCompletionProtection(
      itemId: media.itemId,
      episodeId: media.episodeId,
      timerGeneration: _runGeneration,
    );
    if (oldProtection != null) {
      audioHandler.clearSleepTimerCompletionProtection(oldProtection);
    }
    final fadeOwner = _beginFadeOwner();
    _startFreshChapterWatcher(target, fadeOwner, reason: reason);
  }

  void _restartChapterWatcherKeepingTarget(String reason) {
    final target = _armedChapter;
    if (target == null || !target.matchesMedia(audioHandler.currentMediaItem)) {
      _failClosedChapterTimer('$reason: armed media no longer current');
      return;
    }
    final owner = _fadeOwner ?? _beginFadeOwner();
    _startFreshChapterWatcher(target, owner, reason: reason);
  }

  void _failClosedChapterTimer(String reason) {
    if (!state.isChapterEnd) {
      return;
    }
    logger('Chapter sleep timer disabled fail-closed: $reason', tag: 'SleepTimer', level: InfoLevel.warning);
    final owner = _fadeOwner;
    _clearChapterCoordination(clearProtection: true);
    _cancelMarkerVisibilityTimers();
    if (owner != null) {
      unawaited(_restoreFadeVolumeIfOwned(owner));
    }
    state = const SleepTimerData(
      remainingTime: Duration.zero,
      state: SleepTimerState.inactive,
      mode: SleepTimerMode.chapterEnd,
      expiryState: ChapterSleepExpiryState.inactive,
      showMarkerPin: false,
      showMarkerRange: false,
    );
    unawaited(_persistMarker(null));
  }

  void _claimChapterExpiry(String reason) {
    if (!state.isChapterEnd || _expiryState != ChapterSleepExpiryState.armed) {
      return;
    }
    if (_activeUserNavigations.isNotEmpty || _activeInternalMutations.isNotEmpty) {
      return;
    }

    final target = _armedChapter;
    final protection = _completionProtection;
    final currentMedia = audioHandler.currentMediaItem;
    final sessionRepository = ref.read(sessionRepositoryProvider);
    final sessionBinding = sessionRepository.currentSessionBinding;
    if (target == null ||
        protection == null ||
        currentMedia == null ||
        !target.matchesMedia(currentMedia) ||
        sessionBinding == null ||
        sessionBinding.sessionId != currentMedia.sessionId) {
      _failClosedChapterTimer('$reason: expiry context could not be bound');
      return;
    }

    final expiryGeneration = ++_expiryGeneration;
    _expiryState = ChapterSleepExpiryState.expiring;
    audioHandler.markSleepTimerCompletionProtectionExpiring(protection, expiryGeneration: expiryGeneration);
    _cancelChapterWatcher();

    final fadeOwner = _fadeOwner ?? _beginFadeOwner();
    final context = _ChapterExpiryContext(
      media: target.media,
      sessionId: currentMedia.sessionId,
      sessionBinding: sessionBinding,
      runGeneration: _runGeneration,
      expiryGeneration: expiryGeneration,
      navigationGeneration: audioHandler.sleepTimerNavigationGeneration,
      playbackActionGeneration: audioHandler.sleepTimerPlaybackActionGeneration,
      completionProtection: protection,
      fadeOwner: fadeOwner,
    );

    state = state.copyWith(
      remainingTime: Duration.zero,
      expiryState: ChapterSleepExpiryState.expiring,
    );
    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        PlayerHistoryType.sleepTimerExpired,
        details: <String, Object?>{'mode': 'chapterEnd', 'reason': reason},
      ),
    );

    logger('Chapter sleep timer expiry claimed: $reason', tag: 'SleepTimer', level: InfoLevel.info);
    unawaited(_executeChapterExpiry(context));
  }

  bool _isExpiryContextCurrent(_ChapterExpiryContext context) {
    return state.isChapterEnd &&
        _expiryState == ChapterSleepExpiryState.expiring &&
        context.runGeneration == _runGeneration &&
        context.expiryGeneration == _expiryGeneration &&
        identical(context.completionProtection, _completionProtection) &&
        audioHandler.isSleepTimerCompletionProtectionCurrent(context.completionProtection) &&
        audioHandler.isChapterSleepOwnershipCurrent(
          media: context.media,
          sessionId: context.sessionId,
          navigationGeneration: context.navigationGeneration,
          playbackActionGeneration: context.playbackActionGeneration,
        );
  }

  bool _stillOwnsExpiryRun(_ChapterExpiryContext context) {
    return state.isChapterEnd &&
        _expiryState == ChapterSleepExpiryState.expiring &&
        context.runGeneration == _runGeneration &&
        context.expiryGeneration == _expiryGeneration &&
        identical(context.completionProtection, _completionProtection) &&
        audioHandler.isSleepTimerCompletionProtectionCurrent(context.completionProtection) &&
        audioHandler.sleepTimerNavigationGeneration == context.navigationGeneration &&
        audioHandler.sleepTimerPlaybackActionGeneration == context.playbackActionGeneration;
  }

  Future<void> _executeChapterExpiry(_ChapterExpiryContext context) async {
    final actionSetting = ref
        .read(settingsManagerProvider.notifier)
        .getGlobalSetting<String>(SettingKeys.sleepTimerExpireAction);
    final action = SleepTimerExpireAction.fromSettingValue(actionSetting);

    try {
      if (!_isExpiryContextCurrent(context)) {
        return;
      }

      // Pause first: this is the first asynchronous player operation. No
      // network request is started while playback may continue past the target.
      final paused = await audioHandler.pauseForChapterSleepTimer(
        media: context.media,
        sessionId: context.sessionId,
        navigationGeneration: context.navigationGeneration,
        playbackActionGeneration: context.playbackActionGeneration,
      );
      if (!paused || !_isExpiryContextCurrent(context)) {
        return;
      }

      final rewoundPosition = await audioHandler.applyChapterSleepTimerRewind(
        media: context.media,
        sessionId: context.sessionId,
        navigationGeneration: context.navigationGeneration,
        playbackActionGeneration: context.playbackActionGeneration,
      );
      if (rewoundPosition == null || !_isExpiryContextCurrent(context)) {
        return;
      }

      if (action == SleepTimerExpireAction.pause) {
        await audioHandler.flushChapterSleepTimerProgress(
          binding: context.sessionBinding,
          position: rewoundPosition,
          media: context.media,
          sessionId: context.sessionId,
          navigationGeneration: context.navigationGeneration,
          playbackActionGeneration: context.playbackActionGeneration,
        );
        if (!_isExpiryContextCurrent(context)) {
          return;
        }
      } else {
        await audioHandler.stopForChapterSleepTimer(
          binding: context.sessionBinding,
          stopPosition: rewoundPosition,
          media: context.media,
          sessionId: context.sessionId,
          navigationGeneration: context.navigationGeneration,
          playbackActionGeneration: context.playbackActionGeneration,
        );
        if (!_stillOwnsExpiryRun(context)) {
          return;
        }
      }

      _finishChapterExpiry(context);
    } catch (e, s) {
      logger('Failed to run chapter sleep timer expiry: $e\n$s', tag: 'SleepTimer', level: InfoLevel.warning);
      if (_stillOwnsExpiryRun(context)) {
        _finishChapterExpiry(context);
      }
    }
  }

  void _finishChapterExpiry(_ChapterExpiryContext context) {
    if (!_stillOwnsExpiryRun(context)) {
      return;
    }

    _expiryState = ChapterSleepExpiryState.finished;
    state = state.copyWith(expiryState: ChapterSleepExpiryState.finished);

    audioHandler.clearSleepTimerCompletionProtection(context.completionProtection);
    _completionProtection = null;
    _armedChapter = null;
    _activeUserNavigations.clear();
    _activeInternalMutations.clear();
    _cancelChapterWatcher();
    unawaited(_restoreFadeVolumeIfOwned(context.fadeOwner));

    final marker = _completeMarkerAtCurrentPosition();
    state = SleepTimerData(
      remainingTime: Duration.zero,
      state: SleepTimerState.inactive,
      mode: SleepTimerMode.chapterEnd,
      expiryState: ChapterSleepExpiryState.finished,
      marker: marker,
      chapterTitle: state.chapterTitle,
      showMarkerPin: marker?.endPosition != null,
      showMarkerRange: marker?.endPosition != null,
    );
    _showMarker();
    unawaited(_persistMarker(marker));
    _scheduleMarkerPinHide();
  }

  void stop({bool suppressAutoRestart = true, bool recordHistory = true}) {
    final wasChapterEnd = state.isChapterEnd;
    final remainingTime = wasChapterEnd
        ? state.remainingTime
        : state.isRunning
        ? _remainingForCurrentRun()
        : state.remainingTime;
    _cancelDurationTimer();
    _cancelMarkerVisibilityTimers();

    final owner = _fadeOwner;
    _clearChapterCoordination(clearProtection: true);
    if (owner != null) {
      unawaited(_restoreFadeVolumeIfOwned(owner));
    }

    if (suppressAutoRestart) {
      unawaited(_setAutoRestartSuppressed(true));
    }

    logger('Sleep timer stopped', tag: 'SleepTimer', level: InfoLevel.info);

    state = SleepTimerData(
      remainingTime: Duration.zero,
      state: SleepTimerState.inactive,
      mode: wasChapterEnd ? SleepTimerMode.chapterEnd : SleepTimerMode.duration,
      showMarkerPin: false,
      showMarkerRange: false,
    );
    unawaited(_persistMarker(null));

    if (recordHistory) {
      unawaited(
        PlayerHistoryHandler.addPlayerHistory(
          PlayerHistoryType.sleepTimerStopped,
          details: <String, Object?>{
            'remainingSeconds': remainingTime.inSeconds,
            'source': 'manual',
            if (wasChapterEnd) 'mode': 'chapterEnd',
          },
        ),
      );
    }
  }

  void pause({bool triggeredByPlaybackPause = false}) {
    if (!state.isRunning || state.isChapterEnd) return;

    final remainingTime = _remainingForCurrentRun();

    _cancelDurationTimer();
    _pauseTriggeredByPlayback = triggeredByPlaybackPause;

    final owner = _fadeOwner;
    if (owner != null) {
      unawaited(_restoreFadeVolumeIfOwned(owner));
    }

    logger('Sleep timer paused', tag: 'SleepTimer', level: InfoLevel.info);

    final marker = _completeMarkerAtCurrentPosition();
    state = state.copyWith(remainingTime: remainingTime, state: SleepTimerState.paused, marker: marker);
    _showMarker(showPin: false);
    unawaited(_persistMarker(marker));
    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        PlayerHistoryType.sleepTimerStopped,
        details: <String, Object?>{
          'remainingSeconds': remainingTime.inSeconds,
          'source': triggeredByPlaybackPause ? 'playback' : 'manual',
        },
      ),
    );
  }

  void resume() {
    if (state.isChapterEnd || state.state != SleepTimerState.paused || state.remainingTime <= Duration.zero) {
      return;
    }

    _pauseTriggeredByPlayback = false;
    unawaited(_setAutoRestartSuppressed(false));

    logger('Sleep timer resumed', tag: 'SleepTimer', level: InfoLevel.info);

    final marker = state.marker?.copyWith(clearEndPosition: true);
    state = state.copyWith(state: SleepTimerState.running, marker: marker, forceMarkerVisibility: false);
    _showMarker(showPin: false);
    unawaited(_persistMarker(marker));
    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        PlayerHistoryType.sleepTimerStarted,
        details: <String, Object?>{'durationSeconds': state.remainingTime.inSeconds, 'source': 'resume'},
      ),
    );
    final fadeOwner = _beginFadeOwner();
    _startTimer(state.remainingTime, fadeOwner);
  }

  void extend(Duration additionalTime) {
    if (!state.isActive || state.isChapterEnd || additionalTime <= Duration.zero) return;

    final isRunning = state.isRunning;
    final baseRemainingTime = isRunning ? _remainingForCurrentRun() : state.remainingTime;
    final newRemainingTime = baseRemainingTime + additionalTime;
    final newTotalDuration = (state.totalDuration ?? baseRemainingTime) + additionalTime;

    logger('Sleep timer extended by ${additionalTime.inMinutes} minutes', tag: 'SleepTimer', level: InfoLevel.info);

    state = state.copyWith(remainingTime: newRemainingTime, totalDuration: newTotalDuration);
    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        PlayerHistoryType.sleepTimerExtended,
        details: <String, Object?>{
          'additionalSeconds': additionalTime.inSeconds,
          'remainingSeconds': newRemainingTime.inSeconds,
        },
      ),
    );

    if (isRunning) {
      final owner = _fadeOwner ?? _beginFadeOwner();
      _startTimer(newRemainingTime, owner);
      _applyFadeOutIfNeeded(newRemainingTime, owner);
    }

    unawaited(_persistLastDuration(newTotalDuration));
  }

  void reset() {
    if (!state.isActive || state.isChapterEnd) return;

    final totalDuration = state.totalDuration ?? state.remainingTime;
    if (totalDuration <= Duration.zero) return;

    logger('Sleep timer reset to ${totalDuration.inMinutes} minutes', tag: 'SleepTimer', level: InfoLevel.info);

    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        PlayerHistoryType.sleepTimerStopped,
        details: <String, Object?>{'remainingSeconds': totalDuration.inSeconds, 'source': 'reset'},
      ),
    );

    _pauseTriggeredByPlayback = false;
    final previousOwner = _fadeOwner;
    if (previousOwner != null) {
      unawaited(_restoreFadeVolumeIfOwned(previousOwner));
    }

    _cancelDurationTimer();
    _cancelMarkerVisibilityTimers();

    final marker = state.marker?.copyWith(clearEndPosition: true);
    if (state.state == SleepTimerState.paused) {
      state = state.copyWith(
        remainingTime: totalDuration,
        totalDuration: totalDuration,
        marker: marker,
        forceMarkerVisibility: false,
      );
      _showMarker(showPin: false);
      unawaited(_persistMarker(marker));
      return;
    }

    state = SleepTimerData(
      remainingTime: totalDuration,
      state: SleepTimerState.running,
      mode: SleepTimerMode.duration,
      totalDuration: totalDuration,
      marker: marker,
      forceMarkerVisibility: false,
    );
    _showMarker(showPin: false);
    unawaited(_persistMarker(marker));

    final fadeOwner = _beginFadeOwner();
    _startTimer(totalDuration, fadeOwner);
    unawaited(_setAutoRestartSuppressed(false));
    unawaited(_persistLastDuration(totalDuration));
  }

  void _startTimer(Duration duration, int fadeOwner) {
    _timer?.cancel();
    _countdownStartTime = DateTime.now();
    _countdownRunDuration = duration;

    _timer = Timer.periodic(_sleepTimerTickInterval, (timer) {
      final remaining = _remainingForCurrentRun();

      if (remaining <= Duration.zero) {
        _onTimerExpired(fadeOwner);
        timer.cancel();
      } else {
        _applyFadeOutIfNeeded(remaining, fadeOwner);

        if ((state.remainingTime - remaining).abs() >= _sleepTimerUiUpdateInterval) {
          state = state.copyWith(remainingTime: remaining);
        }
      }
    });
  }

  void _onTimerExpired(int fadeOwner) {
    final actionSetting = ref
        .read(settingsManagerProvider.notifier)
        .getGlobalSetting<String>(SettingKeys.sleepTimerExpireAction);
    final action = SleepTimerExpireAction.fromSettingValue(actionSetting);

    _timer = null;
    _countdownStartTime = null;
    _countdownRunDuration = null;
    _pauseTriggeredByPlayback = false;
    _cancelMarkerVisibilityTimers();

    final marker = _completeMarkerAtCurrentPosition();
    state = SleepTimerData(
      remainingTime: Duration.zero,
      state: SleepTimerState.inactive,
      mode: SleepTimerMode.duration,
      marker: marker,
      forceMarkerVisibility: false,
    );
    _showMarker();
    unawaited(_persistMarker(marker));

    unawaited(
      PlayerHistoryHandler.addPlayerHistory(
        PlayerHistoryType.sleepTimerExpired,
        details: <String, Object?>{'action': action.name},
      ),
    );

    unawaited(_executeExpireAction(action, fadeOwner));
  }

  Future<void> _executeExpireAction(SleepTimerExpireAction action, int fadeOwner) async {
    try {
      if (action == SleepTimerExpireAction.pause) {
        logger('Sleep timer expired, pausing playback', tag: 'SleepTimer', level: InfoLevel.info);
        await audioHandler.applySleepTimerAutoRewindNow();
        await audioHandler.pause();
      } else {
        logger('Sleep timer expired, stopping playback', tag: 'SleepTimer', level: InfoLevel.info);
        await audioHandler.applySleepTimerAutoRewindNow();
        await audioHandler.stop();
      }
    } catch (e) {
      logger('Failed to run sleep timer expiry action: $e', tag: 'SleepTimer', level: InfoLevel.warning);
    } finally {
      await _restoreFadeVolumeIfOwned(fadeOwner);
    }
  }
}

@riverpod
Duration sleepTimerRemainingTime(Ref ref) {
  return ref.watch(sleepTimerHandlerProvider).remainingTime;
}

@riverpod
SleepTimerState sleepTimerState(Ref ref) {
  return ref.watch(sleepTimerHandlerProvider).state;
}

@riverpod
bool sleepTimerIsActive(Ref ref) {
  return ref.watch(sleepTimerHandlerProvider).isActive;
}
