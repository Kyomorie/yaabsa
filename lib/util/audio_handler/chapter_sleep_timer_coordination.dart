import 'package:yaabsa/models/internal_media.dart';

enum SleepTimerMode { duration, chapterEnd }

enum ChapterSleepExpiryState { inactive, armed, expiring, finished }

enum SleepTimerPositionMutationKind {
  userNavigation,
  smartRewind,
  resumeProgressReconcile,
  chapterExpiry,
  otherInternal,
}

class SleepTimerMediaIdentity {
  const SleepTimerMediaIdentity({required this.itemId, required this.episodeId});

  final String itemId;
  final String? episodeId;

  factory SleepTimerMediaIdentity.fromMedia(InternalMedia media) {
    return SleepTimerMediaIdentity(itemId: media.itemId, episodeId: media.episodeId);
  }

  bool matches({required String itemId, required String? episodeId}) {
    return this.itemId == itemId && this.episodeId == episodeId;
  }

  bool matchesMedia(InternalMedia? media) {
    return media != null && matches(itemId: media.itemId, episodeId: media.episodeId);
  }

  @override
  bool operator ==(Object other) {
    return other is SleepTimerMediaIdentity && other.itemId == itemId && other.episodeId == episodeId;
  }

  @override
  int get hashCode => Object.hash(itemId, episodeId);
}

class ChapterSleepTarget {
  const ChapterSleepTarget({required this.media, required this.chapter});

  final SleepTimerMediaIdentity media;
  final InternalChapter chapter;

  Duration get startPosition => Duration(microseconds: (chapter.start * Duration.microsecondsPerSecond).round());

  Duration get endPosition => Duration(microseconds: (chapter.end * Duration.microsecondsPerSecond).round());

  bool matchesMedia(InternalMedia? candidate) => media.matchesMedia(candidate);

  bool sameChapter(InternalChapter? candidate) {
    return candidate != null &&
        candidate.start == chapter.start &&
        candidate.end == chapter.end &&
        candidate.title == chapter.title;
  }

  Duration remainingAt(Duration position) {
    final remaining = endPosition - position;
    return remaining.isNegative ? Duration.zero : remaining;
  }
}

ChapterSleepTarget? resolveChapterSleepTarget({required InternalMedia media, required Duration position}) {
  if (position < Duration.zero || position >= media.totalDuration) {
    return null;
  }

  final chapter = media.getChapterForDuration(position);
  if (chapter == null ||
      !chapter.start.isFinite ||
      !chapter.end.isFinite ||
      chapter.start < 0 ||
      chapter.end <= chapter.start) {
    return null;
  }

  final target = ChapterSleepTarget(media: SleepTimerMediaIdentity.fromMedia(media), chapter: chapter);
  if (target.startPosition < Duration.zero || target.endPosition > media.totalDuration) {
    return null;
  }
  if (position < target.startPosition || position >= target.endPosition) {
    return null;
  }

  return target;
}

class ChapterSleepReentryGate {
  bool _awaitingArmedChapter = false;

  bool get isAwaitingArmedChapter => _awaitingArmedChapter;

  void reset() {
    _awaitingArmedChapter = false;
  }

  void afterSmartRewind({required bool isInArmedChapter}) {
    _awaitingArmedChapter = !isInArmedChapter;
  }

  bool shouldExpire({
    required bool isInArmedChapter,
    required bool userNavigationActive,
    required bool internalMutationActive,
  }) {
    if (userNavigationActive || internalMutationActive) {
      return false;
    }

    if (_awaitingArmedChapter) {
      if (isInArmedChapter) {
        _awaitingArmedChapter = false;
      }
      return false;
    }

    return !isInArmedChapter;
  }
}

class SleepTimerPositionMutationEvent {
  const SleepTimerPositionMutationEvent({required this.kind});

  final SleepTimerPositionMutationKind kind;
}

class ChapterSleepNavigationLedger {
  final Set<int> _active = <int>{};
  int _generation = 0;

  int get generation => _generation;
  bool get hasActive => _active.isNotEmpty;

  bool begin(int operationId) {
    if (!_active.add(operationId)) {
      return false;
    }
    _generation += 1;
    return true;
  }

  bool settle(int operationId) => _active.remove(operationId);
}

class SleepTimerCompletionProtectionToken {
  const SleepTimerCompletionProtectionToken._(this.value);

  final int value;
}

class SleepTimerCompletionProtectionSnapshot {
  const SleepTimerCompletionProtectionSnapshot({
    required this.token,
    required this.media,
    required this.timerGeneration,
  });

  final SleepTimerCompletionProtectionToken token;
  final SleepTimerMediaIdentity media;
  final int timerGeneration;
}

class ChapterSleepCompletionProtectionLedger {
  int _sequence = 0;
  SleepTimerCompletionProtectionSnapshot? _active;

  SleepTimerCompletionProtectionSnapshot? get active => _active;

  SleepTimerCompletionProtectionToken arm({required SleepTimerMediaIdentity media, required int timerGeneration}) {
    final token = SleepTimerCompletionProtectionToken._(++_sequence);
    _active = SleepTimerCompletionProtectionSnapshot(token: token, media: media, timerGeneration: timerGeneration);
    return token;
  }

  SleepTimerCompletionProtectionSnapshot? snapshotFor(SleepTimerMediaIdentity media) {
    final current = _active;
    if (current == null || current.media != media) {
      return null;
    }
    return current;
  }

  bool isCurrent(SleepTimerCompletionProtectionToken token) {
    return _active?.token.value == token.value;
  }

  bool clear(SleepTimerCompletionProtectionToken token) {
    if (!isCurrent(token)) {
      return false;
    }
    _active = null;
    return true;
  }
}

class SleepTimerCompletionClaim {
  const SleepTimerCompletionClaim({
    required this.media,
    required this.completionGeneration,
    required this.navigationGeneration,
    required this.navigationActive,
    required this.playbackActionGeneration,
    required this.protection,
  });

  final SleepTimerMediaIdentity media;
  final int completionGeneration;
  final int navigationGeneration;
  final bool navigationActive;
  final int playbackActionGeneration;
  final SleepTimerCompletionProtectionSnapshot? protection;

  bool get suppressesAutoAdvance => navigationActive || protection != null;
}
