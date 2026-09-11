import 'package:yaabsa/models/internal_media.dart';

enum SleepTimerMode { duration, chapterEnd }

class ChapterSleepTarget {
  const ChapterSleepTarget({required this.itemId, required this.episodeId, required this.endPosition});

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
      // Fail closed only when the finite side of malformed metadata shows that
      // the interval could contain the current position. Malformed entries
      // that are demonstrably elsewhere must not disable otherwise valid
      // chapter metadata for the whole book.
      final couldContainCurrent =
          (start.isFinite && start <= positionSeconds && !end.isFinite) ||
          (!start.isFinite && end.isFinite && positionSeconds < end);
      if (couldContainCurrent) {
        return null;
      }
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

  final endPosition = Duration(microseconds: (end * Duration.microsecondsPerSecond).round());
  if (endPosition <= position || endPosition > mediaDuration) {
    return null;
  }

  return ChapterSleepTarget(itemId: itemId, episodeId: episodeId, endPosition: endPosition);
}
