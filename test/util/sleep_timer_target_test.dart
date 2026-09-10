import 'package:flutter_test/flutter_test.dart';
import 'package:yaabsa/models/internal_media.dart';
import 'package:yaabsa/util/handler/sleep_timer_target.dart';

void main() {
  group('resolveChapterSleepTarget', () {
    test('resolves the current chapter to an absolute media target', () {
      final target = resolveChapterSleepTarget(
        chapters: const [
          InternalChapter(start: 600, end: 1200, title: 'Chapter 1'),
          InternalChapter(start: 1200, end: 1860, title: 'Chapter 2'),
        ],
        mediaDuration: const Duration(minutes: 40),
        position: const Duration(minutes: 15),
        itemId: 'book-1',
        episodeId: null,
      );

      expect(target, isNotNull);
      expect(target!.endPosition, const Duration(minutes: 20));
      expect(target.remainingAt(const Duration(minutes: 17)), const Duration(minutes: 3));
      expect(target.matchesMedia(itemId: 'book-1', episodeId: null), isTrue);
    });

    test('allows one chapter spanning the whole audiobook', () {
      final target = resolveChapterSleepTarget(
        chapters: const [InternalChapter(start: 0, end: 34200, title: 'Book')],
        mediaDuration: const Duration(hours: 9, minutes: 30),
        position: const Duration(hours: 2),
        itemId: 'book-1',
        episodeId: null,
      );

      expect(target?.endPosition, const Duration(hours: 9, minutes: 30));
    });

    test('allows a very short remaining distance', () {
      final target = resolveChapterSleepTarget(
        chapters: const [InternalChapter(start: 0, end: 10, title: 'Short')],
        mediaDuration: const Duration(seconds: 20),
        position: const Duration(seconds: 9, milliseconds: 900),
        itemId: 'book-1',
        episodeId: null,
      );

      expect(target?.remainingAt(const Duration(seconds: 9, milliseconds: 900)), const Duration(milliseconds: 100));
    });

    test('uses the following chapter at a shared boundary', () {
      final target = resolveChapterSleepTarget(
        chapters: const [
          InternalChapter(start: 0, end: 10, title: 'Chapter 1'),
          InternalChapter(start: 10, end: 20, title: 'Chapter 2'),
        ],
        mediaDuration: const Duration(seconds: 30),
        position: const Duration(seconds: 10),
        itemId: 'book-1',
        episodeId: null,
      );

      expect(target?.endPosition, const Duration(seconds: 20));
    });

    test('does not start at the final chapter end', () {
      final target = resolveChapterSleepTarget(
        chapters: const [InternalChapter(start: 0, end: 10, title: 'Chapter 1')],
        mediaDuration: const Duration(seconds: 10),
        position: const Duration(seconds: 10),
        itemId: 'book-1',
        episodeId: null,
      );

      expect(target, isNull);
    });

    test('returns null without chapters or inside a chapter gap', () {
      expect(
        resolveChapterSleepTarget(
          chapters: const [],
          mediaDuration: const Duration(seconds: 30),
          position: const Duration(seconds: 5),
          itemId: 'book-1',
          episodeId: null,
        ),
        isNull,
      );

      expect(
        resolveChapterSleepTarget(
          chapters: const [
            InternalChapter(start: 0, end: 10, title: 'Chapter 1'),
            InternalChapter(start: 15, end: 20, title: 'Chapter 2'),
          ],
          mediaDuration: const Duration(seconds: 30),
          position: const Duration(seconds: 12),
          itemId: 'book-1',
          episodeId: null,
        ),
        isNull,
      );
    });

    test('rejects ambiguous overlapping chapters at the current position', () {
      final target = resolveChapterSleepTarget(
        chapters: const [
          InternalChapter(start: 0, end: 20, title: 'Chapter 1'),
          InternalChapter(start: 10, end: 30, title: 'Chapter 2'),
        ],
        mediaDuration: const Duration(seconds: 40),
        position: const Duration(seconds: 15),
        itemId: 'book-1',
        episodeId: null,
      );

      expect(target, isNull);
    });

    test('rejects a malformed chapter containing the current position', () {
      final target = resolveChapterSleepTarget(
        chapters: const [InternalChapter(start: -5, end: 10, title: 'Broken')],
        mediaDuration: const Duration(seconds: 30),
        position: const Duration(seconds: 5),
        itemId: 'book-1',
        episodeId: null,
      );

      expect(target, isNull);
    });

    test('rejects non-finite and out-of-bounds current chapter metadata', () {
      final infiniteTarget = resolveChapterSleepTarget(
        chapters: const [InternalChapter(start: 0, end: double.infinity, title: 'Broken')],
        mediaDuration: const Duration(seconds: 30),
        position: const Duration(seconds: 5),
        itemId: 'book-1',
        episodeId: null,
      );
      final outOfBoundsTarget = resolveChapterSleepTarget(
        chapters: const [InternalChapter(start: 0, end: 31, title: 'Broken')],
        mediaDuration: const Duration(seconds: 30),
        position: const Duration(seconds: 5),
        itemId: 'book-1',
        episodeId: null,
      );

      expect(infiniteTarget, isNull);
      expect(outOfBoundsTarget, isNull);
    });

    test('does not reject unrelated malformed chapters elsewhere in the book', () {
      final target = resolveChapterSleepTarget(
        chapters: const [
          InternalChapter(start: 0, end: 10, title: 'Chapter 1'),
          InternalChapter(start: double.nan, end: double.infinity, title: 'Broken elsewhere'),
        ],
        mediaDuration: const Duration(seconds: 30),
        position: const Duration(seconds: 5),
        itemId: 'book-1',
        episodeId: null,
      );

      expect(target?.endPosition, const Duration(seconds: 10));
    });

    test('preserves podcast episode identity', () {
      final target = resolveChapterSleepTarget(
        chapters: const [InternalChapter(start: 0, end: 10, title: 'Episode chapter')],
        mediaDuration: const Duration(seconds: 20),
        position: const Duration(seconds: 5),
        itemId: 'podcast-1',
        episodeId: 'episode-7',
      );

      expect(target, isNotNull);
      expect(target!.matchesMedia(itemId: 'podcast-1', episodeId: 'episode-7'), isTrue);
      expect(target.matchesMedia(itemId: 'podcast-1', episodeId: 'episode-8'), isFalse);
    });

    test('remainingAt clamps positions beyond the target to zero', () {
      const target = ChapterSleepTarget(
        itemId: 'book-1',
        episodeId: null,
        endPosition: Duration(seconds: 10),
      );

      expect(target.remainingAt(const Duration(seconds: 12)), Duration.zero);
    });
  });

  group('resolveFollowingChapterSleepTarget', () {
    test('advances to a contiguous following chapter', () {
      const currentTarget = ChapterSleepTarget(
        itemId: 'book-1',
        episodeId: null,
        endPosition: Duration(seconds: 10),
      );

      final target = resolveFollowingChapterSleepTarget(
        chapters: const [
          InternalChapter(start: 0, end: 10, title: 'Chapter 1'),
          InternalChapter(start: 10, end: 20, title: 'Chapter 2'),
        ],
        mediaDuration: const Duration(seconds: 30),
        currentTarget: currentTarget,
      );

      expect(target?.endPosition, const Duration(seconds: 20));
      expect(target?.itemId, 'book-1');
    });

    test('advances across a chapter gap', () {
      const currentTarget = ChapterSleepTarget(
        itemId: 'book-1',
        episodeId: null,
        endPosition: Duration(seconds: 10),
      );

      final target = resolveFollowingChapterSleepTarget(
        chapters: const [
          InternalChapter(start: 0, end: 10, title: 'Chapter 1'),
          InternalChapter(start: 15, end: 20, title: 'Chapter 2'),
        ],
        mediaDuration: const Duration(seconds: 30),
        currentTarget: currentTarget,
      );

      expect(target?.endPosition, const Duration(seconds: 20));
    });

    test('can advance repeatedly from the armed boundary', () {
      const currentTarget = ChapterSleepTarget(
        itemId: 'book-1',
        episodeId: null,
        endPosition: Duration(seconds: 20),
      );

      final target = resolveFollowingChapterSleepTarget(
        chapters: const [
          InternalChapter(start: 0, end: 10, title: 'Chapter 1'),
          InternalChapter(start: 10, end: 20, title: 'Chapter 2'),
          InternalChapter(start: 20, end: 30, title: 'Chapter 3'),
        ],
        mediaDuration: const Duration(seconds: 40),
        currentTarget: currentTarget,
      );

      expect(target?.endPosition, const Duration(seconds: 30));
    });

    test('returns null when the current target is the media end', () {
      const currentTarget = ChapterSleepTarget(
        itemId: 'book-1',
        episodeId: null,
        endPosition: Duration(seconds: 30),
      );

      final target = resolveFollowingChapterSleepTarget(
        chapters: const [InternalChapter(start: 20, end: 30, title: 'Final chapter')],
        mediaDuration: const Duration(seconds: 30),
        currentTarget: currentTarget,
      );

      expect(target, isNull);
    });

    test('fails closed when another chapter crosses the armed boundary', () {
      const currentTarget = ChapterSleepTarget(
        itemId: 'book-1',
        episodeId: null,
        endPosition: Duration(seconds: 10),
      );

      final target = resolveFollowingChapterSleepTarget(
        chapters: const [
          InternalChapter(start: 0, end: 10, title: 'Chapter 1'),
          InternalChapter(start: 9, end: 20, title: 'Overlapping chapter'),
        ],
        mediaDuration: const Duration(seconds: 30),
        currentTarget: currentTarget,
      );

      expect(target, isNull);
    });

    test('fails closed for duplicate next chapter starts', () {
      const currentTarget = ChapterSleepTarget(
        itemId: 'podcast-1',
        episodeId: 'episode-7',
        endPosition: Duration(seconds: 10),
      );

      final target = resolveFollowingChapterSleepTarget(
        chapters: const [
          InternalChapter(start: 0, end: 10, title: 'Chapter 1'),
          InternalChapter(start: 10, end: 20, title: 'Chapter 2a'),
          InternalChapter(start: 10, end: 25, title: 'Chapter 2b'),
        ],
        mediaDuration: const Duration(seconds: 30),
        currentTarget: currentTarget,
      );

      expect(target, isNull);
    });
  });
}
