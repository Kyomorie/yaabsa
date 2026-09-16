import 'package:flutter_test/flutter_test.dart';
import 'package:yaabsa/models/internal_media.dart';
import 'package:yaabsa/util/audio_handler/bg_audio_handler.dart';
import 'package:yaabsa/util/audio_handler/chapter_sleep_timer_coordination.dart';
import 'package:yaabsa/util/globals.dart' as globals;

class _HarnessAudioHandler implements BGAudioHandler {
  _HarnessAudioHandler(this.media);

  final InternalMedia media;

  @override
  InternalMedia? get currentMediaItem => media;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final member = invocation.memberName.toString();
    if (invocation.isGetter && member.contains('currentMediaItem')) {
      return media;
    }
    throw UnsupportedError('Unexpected BGAudioHandler access in harness probe: $member');
  }
}

InternalMedia _media() {
  final media = InternalMedia(
    libraryId: 'library',
    itemId: 'item-a',
    sessionId: 'session-a',
    title: 'Harness book',
    tracks: const [
      InternalTrack(
        index: 0,
        duration: 120,
        url: 'https://example.invalid/audio.mp3',
        mimeType: 'audio/mpeg',
        start: 0,
        end: 120,
      ),
    ],
    chapters: const [
      InternalChapter(start: 0, end: 60, title: 'A'),
      InternalChapter(start: 60, end: 120, title: 'B'),
    ],
    local: false,
    saf: false,
  );
  media.populateFields();
  return media;
}

void main() {
  test('test fake can exercise real chapter-sleep ownership extension', () {
    final media = _media();
    final handler = _HarnessAudioHandler(media);
    globals.audioHandler = handler;
    const identity = SleepTimerMediaIdentity(itemId: 'item-a', episodeId: null);

    expect(handler.sleepTimerNavigationGeneration, 0);
    expect(handler.sleepTimerPlaybackActionGeneration, 0);
    expect(
      handler.isChapterSleepOwnershipCurrent(
        media: identity,
        sessionId: 'session-a',
        navigationGeneration: 0,
        playbackActionGeneration: 0,
      ),
      isTrue,
    );

    final protection = handler.armSleepTimerCompletionProtection(
      itemId: 'item-a',
      episodeId: null,
      timerGeneration: 7,
    );
    expect(handler.isSleepTimerCompletionProtectionCurrent(protection), isTrue);

    handler.noteChapterSleepExpiryClaim();
    expect(handler.sleepTimerPlaybackActionGeneration, 1);
    expect(
      handler.isChapterSleepOwnershipCurrent(
        media: identity,
        sessionId: 'session-a',
        navigationGeneration: 0,
        playbackActionGeneration: 0,
      ),
      isFalse,
    );
    expect(
      handler.isChapterSleepOwnershipCurrent(
        media: identity,
        sessionId: 'session-a',
        navigationGeneration: 0,
        playbackActionGeneration: 1,
      ),
      isTrue,
    );

    expect(handler.clearSleepTimerCompletionProtection(protection), isTrue);
  });
}
