import 'package:yaabsa/models/internal_media.dart';

enum SleepTimerMode { duration, chapterEnd }

class ChapterSleepTarget {
  const ChapterSleepTarget({
    required this.itemId,
    required this.episodeId,
    required this.endPosition,
  });

  final String itemId;
  final String? episodeId;
  final Duration endPosition;

  bool matchesMedia({required String itemId, required String? episodeId}) {
    return this.itemId == itemId && this.episodeId == episodeId;
  }

  Duration remainingAt(Duration position) {
    final remaining = endPosition - position;
    return remaining.isNegative ? Duration.zero : remaining;
  }
}

ChapterSleepTarget? resolveChapterSleepTarget({
  required List<InternalChapter>? chapters,
  required Duration mediaDuration,
  required Duration position,
  required String itemId,
  required String? episodeId,
}) {
  if (chapters == null || chapters.isEmpty || mediaDuration <= Duration.zero) {
    return null;
  }
  if (position < Duration.zero || position >= mediaDuration) {
    return null;
  }

  final mediaDurationSeconds = mediaDuration.inMicroseconds / Duration.microsecondsPerSecond;
  final positionSeconds = position.inMicroseconds / Duration.microsecondsPerSecond;

  InternalChapter? matchingChapter;
  for (final chapter in chapters) {
    final start = chapter.start;
    final end = chapter.end;

    if (!start.isFinite || !end.isFinite) {
      continue;
    }
    if (positionSeconds < start || positionSeconds >= end) {
      continue;
    }

    if (matchingChapter != null) {
      return null;
    }
    matchingChapter = chapter;
  }

  if (matchingChapter == null) {
    return null;
  }

  final start = matchingChapter.start;
  final end = matchingChapter.end;
  if (start < 0 || end <= start || end > mediaDurationSeconds) {
    return null;
  }

  final endPosition = Duration(
    microseconds: (end * Duration.microsecondsPerSecond).round(),
  );
  if (endPosition <= position || endPosition > mediaDuration) {
    return null;
  }

  return ChapterSleepTarget(
    itemId: itemId,
    episodeId: episodeId,
    endPosition: endPosition,
  );
}

ChapterSleepTarget? resolveFollowingChapterSleepTarget({
  required List<InternalChapter>? chapters,
  required Duration mediaDuration,
  required ChapterSleepTarget currentTarget,
}) {
  if (chapters == null || chapters.isEmpty || mediaDuration <= Duration.zero) {
    return null;
  }
  if (currentTarget.endPosition <= Duration.zero || currentTarget.endPosition >= mediaDuration) {
    return null;
  }

  final mediaDurationSeconds = mediaDuration.inMicroseconds / Duration.microsecondsPerSecond;
  final boundarySeconds = currentTarget.endPosition.inMicroseconds / Duration.microsecondsPerSecond;

  InternalChapter? candidate;
  for (final chapter in chapters) {
    final start = chapter.start;
    final end = chapter.end;
    if (!start.isFinite || !end.isFinite || start < 0 || end <= start || end > mediaDurationSeconds) {
      continue;
    }

    // A chapter that crosses the armed boundary makes the next boundary
    // ambiguous. Fail closed rather than extending to an arbitrary chapter.
    if (start < boundarySeconds && end > boundarySeconds) {
      return null;
    }
    if (start < boundarySeconds || end <= boundarySeconds) {
      continue;
    }

    if (candidate == null || start < candidate.start) {
      candidate = chapter;
      continue;
    }
    if (start == candidate.start) {
      return null;
    }
  }

  if (candidate == null) {
    return null;
  }

  final endPosition = Duration(
    microseconds: (candidate.end * Duration.microsecondsPerSecond).round(),
  );
  if (endPosition <= currentTarget.endPosition || endPosition > mediaDuration) {
    return null;
  }

  return ChapterSleepTarget(
    itemId: currentTarget.itemId,
    episodeId: currentTarget.episodeId,
    endPosition: endPosition,
  );
}
