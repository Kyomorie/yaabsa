import 'package:flutter_test/flutter_test.dart';
import 'package:yaabsa/models/internal_media.dart';
import 'package:yaabsa/util/audio_handler/chapter_sleep_timer_coordination.dart';

InternalMedia _media({
  required List<InternalChapter> chapters,
  double duration = 120,
  String itemId = 'item',
  String? episodeId,
}) {
  final media = InternalMedia(
    libraryId: 'library',
    itemId: itemId,
    episodeId: episodeId,
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
      final target = resolveChapterSleepTarget(
        media: _media(chapters: chapters),
        position: const Duration(seconds: 45),
      );

      expect(target, isNotNull);
      expect(target!.chapter.title, 'B');
      expect(target.startPosition, const Duration(seconds: 30));
      expect(target.endPosition, const Duration(seconds: 90));
      expect(target.remainingAt(const Duration(seconds: 70)), const Duration(seconds: 20));
    });

    test('seek within a chapter preserves the same target', () {
      final media = _media(chapters: chapters);
      final first = resolveChapterSleepTarget(media: media, position: const Duration(seconds: 35));
      final second = resolveChapterSleepTarget(media: media, position: const Duration(seconds: 75));

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(first!.sameChapter(second!.chapter), isTrue);
    });

    test('seek across chapters resolves the actual landed chapter', () {
      final media = _media(chapters: chapters);
      final first = resolveChapterSleepTarget(media: media, position: const Duration(seconds: 10));
      final second = resolveChapterSleepTarget(media: media, position: const Duration(seconds: 100));

      expect(first!.chapter.title, 'A');
      expect(second!.chapter.title, 'C');
    });

    test('uses the next chapter at an exact non-final boundary', () {
      final target = resolveChapterSleepTarget(
        media: _media(chapters: chapters),
        position: const Duration(seconds: 30),
      );

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

    test('remaining time clamps to zero after the target end', () {
      final target = resolveChapterSleepTarget(
        media: _media(chapters: chapters),
        position: const Duration(seconds: 45),
      );

      expect(target, isNotNull);
      expect(target!.remainingAt(const Duration(seconds: 95)), Duration.zero);
    });

    test('media identity includes episode id', () {
      final media = _media(chapters: chapters, itemId: 'podcast', episodeId: 'episode-a');
      final target = resolveChapterSleepTarget(media: media, position: const Duration(seconds: 10));

      expect(target, isNotNull);
      expect(target!.matchesMedia(media), isTrue);
      expect(
        target.media.matchesMedia(_media(chapters: chapters, itemId: 'podcast', episodeId: 'episode-b')),
        isFalse,
      );
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

    test('settling an operation does not create a newer navigation generation', () {
      final ledger = ChapterSleepNavigationLedger();
      expect(ledger.begin(11), isTrue);
      final generation = ledger.generation;

      expect(ledger.settle(11), isTrue);
      expect(ledger.hasActive, isFalse);
      expect(ledger.generation, generation);
    });
  });

  group('ChapterSleepReentryGate', () {
    test('natural leave expires exactly when no operation is active', () {
      final gate = ChapterSleepReentryGate();

      expect(
        gate.shouldExpire(
          isInArmedChapter: true,
          userNavigationActive: false,
          internalMutationActive: false,
        ),
        isFalse,
      );
      expect(
        gate.shouldExpire(
          isInArmedChapter: false,
          userNavigationActive: false,
          internalMutationActive: false,
        ),
        isTrue,
      );
    });

    test('user navigation and internal mutation suppress a boundary observation', () {
      final gate = ChapterSleepReentryGate();

      expect(
        gate.shouldExpire(
          isInArmedChapter: false,
          userNavigationActive: true,
          internalMutationActive: false,
        ),
        isFalse,
      );
      expect(
        gate.shouldExpire(
          isInArmedChapter: false,
          userNavigationActive: false,
          internalMutationActive: true,
        ),
        isFalse,
      );
    });

    test('smart rewind across a boundary waits for reentry before natural expiry', () {
      final gate = ChapterSleepReentryGate();
      gate.afterSmartRewind(isInArmedChapter: false);

      expect(gate.isAwaitingArmedChapter, isTrue);
      expect(
        gate.shouldExpire(
          isInArmedChapter: false,
          userNavigationActive: false,
          internalMutationActive: false,
        ),
        isFalse,
      );
      expect(gate.isAwaitingArmedChapter, isTrue);

      expect(
        gate.shouldExpire(
          isInArmedChapter: true,
          userNavigationActive: false,
          internalMutationActive: false,
        ),
        isFalse,
      );
      expect(gate.isAwaitingArmedChapter, isFalse);

      expect(
        gate.shouldExpire(
          isInArmedChapter: false,
          userNavigationActive: false,
          internalMutationActive: false,
        ),
        isTrue,
      );
    });

    test('smart rewind within the armed chapter does not enter reentry mode', () {
      final gate = ChapterSleepReentryGate();
      gate.afterSmartRewind(isInArmedChapter: true);

      expect(gate.isAwaitingArmedChapter, isFalse);
    });

    test('reset clears smart-rewind reentry ownership', () {
      final gate = ChapterSleepReentryGate();
      gate.afterSmartRewind(isInArmedChapter: false);
      expect(gate.isAwaitingArmedChapter, isTrue);

      gate.reset();

      expect(gate.isAwaitingArmedChapter, isFalse);
    });
  });

  group('ChapterSleepCompletionProtectionLedger', () {
    const mediaA = SleepTimerMediaIdentity(itemId: 'A', episodeId: null);
    const mediaB = SleepTimerMediaIdentity(itemId: 'B', episodeId: null);

    test('protects only the armed media and carries timer ownership', () {
      final ledger = ChapterSleepCompletionProtectionLedger();
      ledger.arm(media: mediaA, timerGeneration: 4);

      final armed = ledger.snapshotFor(mediaA);
      expect(armed, isNotNull);
      expect(armed!.timerGeneration, 4);
      expect(ledger.snapshotFor(mediaB), isNull);
    });

    test('protection remains valid until expiry explicitly clears it', () {
      final ledger = ChapterSleepCompletionProtectionLedger();
      final token = ledger.arm(media: mediaA, timerGeneration: 3);

      final claim = SleepTimerCompletionClaim(
        media: mediaA,
        completionGeneration: 1,
        navigationGeneration: 0,
        navigationActive: false,
        playbackActionGeneration: 0,
        protection: ledger.snapshotFor(mediaA),
      );

      expect(ledger.isCurrent(token), isTrue);
      expect(claim.suppressesAutoAdvance, isTrue);
    });

    test('navigation-active completion suppresses auto advance even without timer protection', () {
      const claim = SleepTimerCompletionClaim(
        media: mediaA,
        completionGeneration: 3,
        navigationGeneration: 5,
        navigationActive: true,
        playbackActionGeneration: 8,
        protection: null,
      );

      expect(claim.navigationActive, isTrue);
      expect(claim.suppressesAutoAdvance, isTrue);
    });

    test('unprotected completion outside navigation does not suppress normal auto advance', () {
      const claim = SleepTimerCompletionClaim(
        media: mediaA,
        completionGeneration: 3,
        navigationGeneration: 5,
        navigationActive: false,
        playbackActionGeneration: 8,
        protection: null,
      );

      expect(claim.suppressesAutoAdvance, isFalse);
    });

    test('completion captured during navigation still suppresses later auto advance', () {
      final ledger = ChapterSleepCompletionProtectionLedger();
      ledger.arm(media: mediaA, timerGeneration: 8);

      final claim = SleepTimerCompletionClaim(
        media: mediaA,
        completionGeneration: 5,
        navigationGeneration: 12,
        navigationActive: true,
        playbackActionGeneration: 7,
        protection: ledger.snapshotFor(mediaA),
      );

      expect(claim.navigationActive, isTrue);
      expect(claim.suppressesAutoAdvance, isTrue);
    });

    test('captured protected completion stays suppressive after ownership changes', () {
      final ledger = ChapterSleepCompletionProtectionLedger();
      final old = ledger.arm(media: mediaA, timerGeneration: 8);
      final claim = SleepTimerCompletionClaim(
        media: mediaA,
        completionGeneration: 5,
        navigationGeneration: 12,
        navigationActive: false,
        playbackActionGeneration: 7,
        protection: ledger.snapshotFor(mediaA),
      );

      expect(ledger.clear(old), isTrue);
      ledger.arm(media: mediaB, timerGeneration: 9);
      expect(claim.suppressesAutoAdvance, isTrue);
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

    test('clearing the current owner removes completion protection', () {
      final ledger = ChapterSleepCompletionProtectionLedger();
      final current = ledger.arm(media: mediaA, timerGeneration: 2);

      expect(ledger.snapshotFor(mediaA), isNotNull);
      expect(ledger.clear(current), isTrue);
      expect(ledger.snapshotFor(mediaA), isNull);
    });

    test('rearming for another media removes old completion protection', () {
      final ledger = ChapterSleepCompletionProtectionLedger();
      final old = ledger.arm(media: mediaA, timerGeneration: 1);
      final current = ledger.arm(media: mediaB, timerGeneration: 2);

      expect(ledger.snapshotFor(mediaA), isNull);
      expect(ledger.snapshotFor(mediaB), isNotNull);
      expect(ledger.isCurrent(old), isFalse);
      expect(ledger.isCurrent(current), isTrue);
    });
  });
}
