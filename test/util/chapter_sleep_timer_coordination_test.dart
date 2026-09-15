import 'package:flutter_test/flutter_test.dart';
import 'package:yaabsa/models/internal_media.dart';
import 'package:yaabsa/util/audio_handler/chapter_sleep_timer_coordination.dart';

InternalMedia _media({required List<InternalChapter> chapters, double duration = 120}) {
  final media = InternalMedia(
    libraryId: 'library',
    itemId: 'item',
    episodeId: null,
    sessionId: 'session',
    title: 'Book',
    tracks: [
      InternalTrack(
        index: 0,
        duration: duration,
        url: 'https://example.invalid/audio.mp3',
        mimeType: 'audio/mpeg',
        start: 0,
        end: duration,
      ),
    ],
    chapters: chapters,
    local: false,
    saf: false,
  );
  media.populateFields();
  return media;
}

void main() {
  group('resolveChapterSleepTarget', () {
    final chapters = const [
      InternalChapter(start: 0, end: 30, title: 'A'),
      InternalChapter(start: 30, end: 90, title: 'B'),
      InternalChapter(start: 90, end: 120, title: 'C'),
    ];

    test('resolves the chapter containing the actual position', () {
      final target = resolveChapterSleepTarget(media: _media(chapters: chapters), position: const Duration(seconds: 45));

      expect(target, isNotNull);
      expect(target!.chapter.title, 'B');
      expect(target.startPosition, const Duration(seconds: 30));
      expect(target.endPosition, const Duration(seconds: 90));
      expect(target.remainingAt(const Duration(seconds: 70)), const Duration(seconds: 20));
    });

    test('uses the next chapter at an exact non-final boundary', () {
      final target = resolveChapterSleepTarget(media: _media(chapters: chapters), position: const Duration(seconds: 30));

      expect(target, isNotNull);
      expect(target!.chapter.title, 'B');
    });

    test('fails closed in a chapter gap', () {
      final media = _media(
        chapters: const [
          InternalChapter(start: 0, end: 30, title: 'A'),
          InternalChapter(start: 40, end: 80, title: 'B'),
        ],
      );

      expect(resolveChapterSleepTarget(media: media, position: const Duration(seconds: 35)), isNull);
    });

    test('fails closed at media end and on invalid chapter bounds', () {
      final media = _media(chapters: chapters);
      expect(resolveChapterSleepTarget(media: media, position: const Duration(seconds: 120)), isNull);

      final invalid = _media(
        chapters: const [InternalChapter(start: 0, end: 121, title: 'invalid')],
      );
      expect(resolveChapterSleepTarget(media: invalid, position: const Duration(seconds: 10)), isNull);
    });
  });

  group('ChapterSleepNavigationLedger', () {
    test('overlapping operations keep navigation active until the final settle', () {
      final ledger = ChapterSleepNavigationLedger();

      expect(ledger.begin(1), isTrue);
      expect(ledger.begin(2), isTrue);
      expect(ledger.hasActive, isTrue);
      expect(ledger.generation, 2);

      expect(ledger.settle(1), isTrue);
      expect(ledger.hasActive, isTrue);
      expect(ledger.activeSnapshot, {2});

      expect(ledger.settle(2), isTrue);
      expect(ledger.hasActive, isFalse);
    });

    test('duplicate begin and stale settle are ignored', () {
      final ledger = ChapterSleepNavigationLedger();

      expect(ledger.begin(7), isTrue);
      expect(ledger.begin(7), isFalse);
      expect(ledger.generation, 1);
      expect(ledger.settle(8), isFalse);
      expect(ledger.settle(7), isTrue);
    });
  });

  group('ChapterSleepCompletionProtectionLedger', () {
    const mediaA = SleepTimerMediaIdentity(itemId: 'A', episodeId: null);
    const mediaB = SleepTimerMediaIdentity(itemId: 'B', episodeId: null);

    test('protects only the armed media and carries expiry ownership', () {
      final ledger = ChapterSleepCompletionProtectionLedger();
      final token = ledger.arm(media: mediaA, timerGeneration: 4);

      final armed = ledger.snapshotFor(mediaA);
      expect(armed, isNotNull);
      expect(armed!.timerGeneration, 4);
      expect(armed.expiring, isFalse);
      expect(ledger.snapshotFor(mediaB), isNull);

      expect(ledger.markExpiring(token, expiryGeneration: 9), isTrue);
      final expiring = ledger.snapshotFor(mediaA)!;
      expect(expiring.expiring, isTrue);
      expect(expiring.expiryGeneration, 9);
    });

    test('stale cleanup cannot clear a newer owner', () {
      final ledger = ChapterSleepCompletionProtectionLedger();
      final stale = ledger.arm(media: mediaA, timerGeneration: 1);
      final current = ledger.arm(media: mediaA, timerGeneration: 2);

      expect(ledger.clear(stale), isFalse);
      expect(ledger.isCurrent(current), isTrue);
      expect(ledger.clear(current), isTrue);
      expect(ledger.active, isNull);
    });
  });
}
