from pathlib import Path
import textwrap


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def replace_between(text: str, start_marker: str, end_marker: str, replacement: str, label: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f"{label}: start marker not found")
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f"{label}: end marker not found")
    return text[:start] + replacement + text[end:]


helper = Path("lib/util/audio_handler/playback_start_attempt.dart")
helper.write_text(
    textwrap.dedent(
        """\
        import 'dart:async';

        import 'player_mutation_barrier.dart';

        enum PlaybackStartAttemptStatus { pending, started, superseded, rejected, failed, unsupported }

        class PlaybackStartAttempt {
          PlaybackStartAttempt._({
            required this.id,
            required this.lease,
            required this.sourceGeneration,
            required this.reservedQueueEntryId,
          });

          final int id;
          final PlayerMutationLease lease;
          final int sourceGeneration;
          final String? reservedQueueEntryId;
          PlaybackStartAttemptStatus _status = PlaybackStartAttemptStatus.pending;

          PlaybackStartAttemptStatus get status => _status;
          bool get isPending => _status == PlaybackStartAttemptStatus.pending;
        }

        class PlaybackStartAttemptLedger {
          int _sequence = 0;
          PlaybackStartAttempt? _active;

          PlaybackStartAttempt begin({
            required PlayerMutationLease lease,
            required int sourceGeneration,
            String? reservedQueueEntryId,
          }) {
            final previous = _active;
            if (previous != null && previous.isPending) {
              previous._status = PlaybackStartAttemptStatus.superseded;
            }
            final attempt = PlaybackStartAttempt._(
              id: ++_sequence,
              lease: lease,
              sourceGeneration: sourceGeneration,
              reservedQueueEntryId: reservedQueueEntryId,
            );
            _active = attempt;
            return attempt;
          }

          bool isCurrent(
            PlaybackStartAttempt attempt, {
            required PlayerMutationBarrier barrier,
            required int currentSourceGeneration,
            required bool isDisposing,
            required bool Function(String queueEntryId) reservationIsCurrent,
          }) {
            if (!identical(_active, attempt) ||
                !attempt.isPending ||
                isDisposing ||
                !barrier.isCurrent(attempt.lease) ||
                attempt.sourceGeneration != currentSourceGeneration) {
              return false;
            }
            final reservationId = attempt.reservedQueueEntryId;
            return reservationId == null || reservationIsCurrent(reservationId);
          }

          bool settle(PlaybackStartAttempt attempt, PlaybackStartAttemptStatus status) {
            if (status == PlaybackStartAttemptStatus.pending) {
              throw ArgumentError.value(status, 'status', 'Terminal playback-start status required');
            }
            if (!attempt.isPending) {
              return false;
            }
            attempt._status = status;
            if (identical(_active, attempt)) {
              _active = null;
            }
            return true;
          }

          PlaybackStartAttempt? get active => _active;
        }

        Future<T> awaitPlaybackStartOrLeaseInvalidated<T>({
          required PlayerMutationLease lease,
          required Future<T> backendResult,
          required T supersededValue,
        }) {
          if (lease.isInvalidated) {
            return Future<T>.value(supersededValue);
          }
          return Future.any<T>([
            backendResult,
            lease.invalidated.then((_) => supersededValue),
          ]);
        }
        """
    )
)

test_path = Path("test/util/playback_start_attempt_test.dart")
test_path.write_text(
    textwrap.dedent(
        r"""\
        import 'dart:async';
        import 'dart:io';

        import 'package:flutter_test/flutter_test.dart';
        import 'package:yaabsa/util/audio_handler/playback_start_attempt.dart';
        import 'package:yaabsa/util/audio_handler/player_mutation_barrier.dart';

        void main() {
          group('PlaybackStartAttemptLedger', () {
            test('currentness binds exact lease, source generation, and reservation', () {
              final barrier = PlayerMutationBarrier();
              final lease = barrier.acquire();
              final ledger = PlaybackStartAttemptLedger();
              final reservations = <String>{'q1'};
              final attempt = ledger.begin(
                lease: lease,
                sourceGeneration: 7,
                reservedQueueEntryId: 'q1',
              );

              bool current({int generation = 7, bool disposing = false}) => ledger.isCurrent(
                    attempt,
                    barrier: barrier,
                    currentSourceGeneration: generation,
                    isDisposing: disposing,
                    reservationIsCurrent: reservations.contains,
                  );

              expect(current(), isTrue);
              expect(current(generation: 8), isFalse);
              expect(current(disposing: true), isFalse);
              reservations.clear();
              expect(current(), isFalse);
            });

            test('newer attempt supersedes older attempt', () {
              final barrier = PlayerMutationBarrier();
              final ledger = PlaybackStartAttemptLedger();
              final first = ledger.begin(lease: barrier.acquire(), sourceGeneration: 1);
              final second = ledger.begin(lease: barrier.acquire(), sourceGeneration: 1);

              expect(first.status, PlaybackStartAttemptStatus.superseded);
              expect(first.isPending, isFalse);
              expect(identical(ledger.active, second), isTrue);
            });

            test('every non-start terminal releases the active attempt', () {
              for (final status in const [
                PlaybackStartAttemptStatus.superseded,
                PlaybackStartAttemptStatus.rejected,
                PlaybackStartAttemptStatus.failed,
                PlaybackStartAttemptStatus.unsupported,
              ]) {
                final barrier = PlayerMutationBarrier();
                final ledger = PlaybackStartAttemptLedger();
                final attempt = ledger.begin(lease: barrier.acquire(), sourceGeneration: 1);
                expect(ledger.settle(attempt, status), isTrue);
                expect(attempt.status, status);
                expect(ledger.active, isNull);
              }
            });

            test('stale reservation cannot be authorized by backend success', () {
              final barrier = PlayerMutationBarrier();
              final lease = barrier.acquire();
              final ledger = PlaybackStartAttemptLedger();
              final attempt = ledger.begin(
                lease: lease,
                sourceGeneration: 2,
                reservedQueueEntryId: 'q42',
              );

              expect(
                ledger.isCurrent(
                  attempt,
                  barrier: barrier,
                  currentSourceGeneration: 2,
                  isDisposing: false,
                  reservationIsCurrent: (_) => false,
                ),
                isFalse,
              );
            });
          });

          test('backend wait is interrupted by a newer lease without serializing the mutation barrier', () async {
            final barrier = PlayerMutationBarrier();
            final oldLease = barrier.acquire();
            final backend = Completer<String>();
            final waiting = awaitPlaybackStartOrLeaseInvalidated<String>(
              lease: oldLease,
              backendResult: backend.future,
              supersededValue: 'superseded',
            );

            final newerLease = barrier.acquire();
            var newerMutationRan = false;
            await barrier.run<void>(newerLease, () async {
              newerMutationRan = true;
            });

            expect(newerMutationRan, isTrue);
            expect(await waiting, 'superseded');
            backend.complete('started');
          });

          test('handler waits for backend confirmation outside the player mutation barrier', () {
            final source = File('lib/util/audio_handler/bg_audio_handler_playback_internal.dart').readAsStringSync();
            final start = source.indexOf('Future<PlaybackStartResult> _syncedPlay(');
            final end = source.indexOf('Future<void> _reconcileResumeProgressInBackground(', start);
            expect(start, greaterThanOrEqualTo(0));
            expect(end, greaterThan(start));
            final method = source.substring(start, end);
            expect(method, contains('_player.waitForPlaybackStart()'));
            expect(method, contains('awaitPlaybackStartOrLeaseInvalidated'));
            expect(method, isNot(contains('_playerMutationBarrier.run')));
          });

          test('queue consumption is guarded by exact reservation and confirmed start', () {
            final source = File('lib/util/audio_handler/bg_audio_handler.dart').readAsStringSync();
            expect(source, contains('reservedQueueEntryId: matchingCurrentQueueEntry?.id'));
            expect(source, contains('reservedQueueEntryId: nextEntry?.id'));
            expect(RegExp(r'if \(!attemptCurrent \|\| !startResult\.started\)').allMatches(source).length, 2);

            final currentStart = source.indexOf('reservedQueueEntryId: matchingCurrentQueueEntry?.id');
            final currentRemove = source.indexOf('queueList.removeAt(matchingIndex)', currentStart);
            expect(currentRemove, greaterThan(currentStart));

            final queuedStart = source.indexOf('reservedQueueEntryId: nextEntry?.id');
            final queuedRemove = source.indexOf('queueList.removeAt(reservedIndex)', queuedStart);
            expect(queuedRemove, greaterThan(queuedStart));
          });
        }
        """
    )
)

handler_path = Path("lib/util/audio_handler/bg_audio_handler.dart")
handler = handler_path.read_text()
handler = replace_once(
    handler,
    "import 'package:yaabsa/util/audio_handler/player_mutation_barrier.dart';\n",
    "import 'package:yaabsa/util/audio_handler/player_mutation_barrier.dart';\n"
    "import 'package:yaabsa/util/audio_handler/playback_start_attempt.dart';\n",
    "handler import",
)
handler = replace_once(
    handler,
    "  final PlayerMutationBarrier _playerMutationBarrier = PlayerMutationBarrier();\n",
    "  final PlayerMutationBarrier _playerMutationBarrier = PlayerMutationBarrier();\n"
    "  final PlaybackStartAttemptLedger _playbackStartAttemptLedger = PlaybackStartAttemptLedger();\n"
    "  int _audioSourceGeneration = 0;\n",
    "handler fields",
)

current_start = "      _queueTransitionLoadingOwner = null;\n      _setQueueTransitionLoading(false);\n      await _syncedPlay("
current_end = "\n    final PlayerQueueEntry? nextEntry = queueList.isNotEmpty ? queueList.first : null;"
current_replacement = textwrap.dedent(
    """\
          final startAttempt = _beginPlaybackStartAttempt(
            playLease,
            reservedQueueEntryId: matchingCurrentQueueEntry?.id,
          );
          final startResult = await _syncedPlay(
            restoreProgress: !ignoreProgress,
            skipResumeProgressReconcile: skipResumeProgressReconcile,
            mutationLease: playLease,
          );
          final attemptCurrent = ownsPlay() && _isPlaybackStartAttemptCurrent(startAttempt);
          if (!attemptCurrent || !startResult.started) {
            _settlePlaybackStartAttempt(
              startAttempt,
              attemptCurrent ? _statusForPlaybackStartResult(startResult) : PlaybackStartAttemptStatus.superseded,
            );
            abandonPlayLoading();
            PlayerUtils.disableWakelock(_ref);
            return Future.value();
          }
          try {
            if (matchingCurrentQueueEntry != null) {
              final matchingIndex = queueList.indexWhere((entry) => entry.id == matchingCurrentQueueEntry!.id);
              if (matchingIndex >= 0) {
                final removed = queueList.removeAt(matchingIndex);
                _originalQueueList.removeWhere((entry) => entry.id == removed.id);
                _emitQueueState();
                _maybePrefetchAutoQueue();
              }
              _markManualQueueItemPlayed(matchingCurrentQueueEntry);
            }
            _queueTransitionLoadingOwner = null;
            _setQueueTransitionLoading(false);
          } finally {
            _settlePlaybackStartAttempt(startAttempt, PlaybackStartAttemptStatus.started);
          }
          return Future.value();
        }
    """
)
handler = replace_between(handler, current_start, current_end, current_replacement, "current-item start block")

queued_start = "      _clearQueueTransitionLoadingIfOwned(playLease);\n      await _syncedPlay(restoreProgress: !ignoreProgress, mutationLease: playLease);"
queued_end = "\n    } catch (e) {"
queued_replacement = textwrap.dedent(
    """\
          final startAttempt = _beginPlaybackStartAttempt(
            playLease,
            reservedQueueEntryId: nextEntry?.id,
          );
          final startResult = await _syncedPlay(restoreProgress: !ignoreProgress, mutationLease: playLease);
          final attemptCurrent = ownsPlay() && _isPlaybackStartAttemptCurrent(startAttempt);
          if (!attemptCurrent || !startResult.started) {
            _settlePlaybackStartAttempt(
              startAttempt,
              attemptCurrent ? _statusForPlaybackStartResult(startResult) : PlaybackStartAttemptStatus.superseded,
            );
            abandonPlayLoading();
            PlayerUtils.disableWakelock(_ref);
            return;
          }
          try {
            if (nextEntry != null) {
              final reservedIndex = queueList.indexWhere((entry) => entry.id == nextEntry.id);
              if (reservedIndex >= 0) {
                final removed = queueList.removeAt(reservedIndex);
                _originalQueueList.removeWhere((entry) => entry.id == removed.id);
                _emitQueueState();
                if (!isPendingManualEntry) {
                  _maybePrefetchAutoQueue();
                }
                final loopMode = _ref
                    .read(settingsManagerProvider.notifier)
                    .getGlobalSetting<String>(SettingKeys.loopMode, defaultValue: 'off');
                final isLoopOn = loopMode == 'on';
                if (_activeMusicLibraryId != null && !isLoopOn) {
                  unawaited(_refillMusicQueue(_activeMusicLibraryId!, filter: _activeMusicLibraryFilter));
                }
              }
              _markManualQueueItemPlayed(nextEntry);
            } else {
              unawaited(_setupAutoQueueOnResume(itemId: nextItem.itemId, episodeId: nextItem.episodeId));
            }
            _clearQueueTransitionLoadingIfOwned(playLease);
          } finally {
            _settlePlaybackStartAttempt(startAttempt, PlaybackStartAttemptStatus.started);
          }
    """
)
handler = replace_between(handler, queued_start, queued_end, queued_replacement, "queued-item start block")
handler_path.write_text(handler)

source_path = Path("lib/util/audio_handler/bg_audio_handler_source.dart")
source = source_path.read_text()
source = replace_once(
    source,
    "        if (!ownsSourceLoad()) {\n"
    "          throw PlayerInterruptedException('Source loading superseded before the player mutation was issued');\n"
    "        }\n"
    "        return player.setAudioSources(\n",
    "        if (!ownsSourceLoad()) {\n"
    "          throw PlayerInterruptedException('Source loading superseded before the player mutation was issued');\n"
    "        }\n"
    "        _audioSourceGeneration += 1;\n"
    "        return player.setAudioSources(\n",
    "source generation",
)
source_path.write_text(source)

playback_path = Path("lib/util/audio_handler/bg_audio_handler_playback_internal.dart")
playback = playback_path.read_text()
local_start = "      _clearQueueTransitionLoadingIfOwned(lease);\n      if (isCastControlActive) {"
local_end = "\n      TrayManager.update();"
local_replacement = textwrap.dedent(
    """\
          if (isCastControlActive) {
            _clearQueueTransitionLoadingIfOwned(lease);
            await play();
            if (!ownsPlayback()) {
              return false;
            }
          } else {
            final startAttempt = _beginPlaybackStartAttempt(lease);
            final startResult = await _syncedPlay(mutationLease: lease);
            final attemptCurrent = ownsPlayback() && _isPlaybackStartAttemptCurrent(startAttempt);
            _settlePlaybackStartAttempt(
              startAttempt,
              attemptCurrent ? _statusForPlaybackStartResult(startResult) : PlaybackStartAttemptStatus.superseded,
            );
            if (!attemptCurrent || !startResult.started) {
              _abandonQueueTransitionLoadingIfOwned(lease);
              PlayerUtils.disableWakelock(_ref);
              return false;
            }
            _clearQueueTransitionLoadingIfOwned(lease);
          }
    """
)
playback = replace_between(playback, local_start, local_end, local_replacement, "playItemFromPosition start block")

synced_start = "  Future<void> _syncedPlay({"
synced_end = "\n  Future<void> _reconcileResumeProgressInBackground("
synced_replacement = textwrap.dedent(
    """\
      PlaybackStartAttempt _beginPlaybackStartAttempt(
        PlayerMutationLease lease, {
        String? reservedQueueEntryId,
      }) {
        return _playbackStartAttemptLedger.begin(
          lease: lease,
          sourceGeneration: _audioSourceGeneration,
          reservedQueueEntryId: reservedQueueEntryId,
        );
      }

      bool _isPlaybackStartAttemptCurrent(PlaybackStartAttempt attempt) {
        return _playbackStartAttemptLedger.isCurrent(
          attempt,
          barrier: _playerMutationBarrier,
          currentSourceGeneration: _audioSourceGeneration,
          isDisposing: _isDisposing,
          reservationIsCurrent: (queueEntryId) => queueList.any((entry) => entry.id == queueEntryId),
        );
      }

      PlaybackStartAttemptStatus _statusForPlaybackStartResult(PlaybackStartResult result) {
        return switch (result.status) {
          PlaybackStartStatus.started => PlaybackStartAttemptStatus.started,
          PlaybackStartStatus.superseded => PlaybackStartAttemptStatus.superseded,
          PlaybackStartStatus.rejected => PlaybackStartAttemptStatus.rejected,
          PlaybackStartStatus.failed => PlaybackStartAttemptStatus.failed,
          PlaybackStartStatus.unsupported => PlaybackStartAttemptStatus.unsupported,
        };
      }

      void _settlePlaybackStartAttempt(PlaybackStartAttempt attempt, PlaybackStartAttemptStatus status) {
        _playbackStartAttemptLedger.settle(attempt, status);
      }

      Future<PlaybackStartResult> _syncedPlay({
        bool restoreProgress = false,
        bool skipResumeProgressReconcile = false,
        PlayerMutationLease? mutationLease,
      }) async {
        final lease = mutationLease ?? _playerMutationBarrier.acquire();
        if (!_playerMutationBarrier.isCurrent(lease)) {
          return const PlaybackStartResult(PlaybackStartStatus.superseded);
        }

        if (_chapterNotificationEnabled) {
          _updateMediaItemForChapterNotification();
        } else {
          mediaItem.add(_currentMediaItem?.toMediaItem());
        }

        if (_currentMediaItem == null) {
          return const PlaybackStartResult(PlaybackStartStatus.rejected);
        }
        final resumeItem = _currentMediaItem!;
        final startPosition = position;
        final shouldReconcileProgress = restoreProgress && !skipResumeProgressReconcile && !isCastControlActive;
        logger(
          'Starting playback for item: ${resumeItem.itemId} (${resumeItem.episodeId ?? 'item'}) from position: $startPosition (restoreProgress=$restoreProgress, castControl=$isCastControlActive)',
          tag: 'AudioHandler',
          level: InfoLevel.info,
        );

        if (restoreProgress && skipResumeProgressReconcile) {
          logger(
            'Resume progress reconcile skipped because playback position was manually changed while paused.',
            tag: 'AudioHandler',
            level: InfoLevel.debug,
          );
        }

        if (!_playerMutationBarrier.isCurrent(lease)) {
          return const PlaybackStartResult(PlaybackStartStatus.superseded);
        }

        try {
          final playFuture = _player.play();
          unawaited(
            playFuture.catchError((error, stackTrace) {
              logger('Failed to start player playback: $error\\n$stackTrace', tag: 'AudioHandler', level: InfoLevel.error);
            }),
          );
          final result = await awaitPlaybackStartOrLeaseInvalidated<PlaybackStartResult>(
            lease: lease,
            backendResult: _player.waitForPlaybackStart(),
            supersededValue: const PlaybackStartResult(PlaybackStartStatus.superseded),
          );
          if (result.started && shouldReconcileProgress && _playerMutationBarrier.isCurrent(lease)) {
            unawaited(_reconcileResumeProgressInBackground(resumeItem, startPosition, mutationLease: lease));
          }
          return result;
        } catch (error, stackTrace) {
          logger(
            'Failed while waiting for backend-confirmed playback start: $error\\n$stackTrace',
            tag: 'AudioHandler',
            level: InfoLevel.error,
          );
          return PlaybackStartResult(PlaybackStartStatus.failed, errorMessage: error.toString());
        }
      }
    """
)
playback = replace_between(playback, synced_start, synced_end, synced_replacement, "synced play method")
playback_path.write_text(playback)

print("P1 source integration patch applied")
