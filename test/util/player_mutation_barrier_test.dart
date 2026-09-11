import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaabsa/util/audio_handler/player_mutation_barrier.dart';

void main() {
  group('PlayerMutationBarrier', () {
    test('a newer lease invalidates queued work before it is issued', () async {
      final barrier = PlayerMutationBarrier();
      final first = barrier.acquire();
      final blocker = Completer<void>();
      final firstIssued = Completer<void>();

      final running = barrier.run(first, () async {
        firstIssued.complete();
        await blocker.future;
      });
      await firstIssued.future;

      final stale = barrier.acquire();
      final staleResult = barrier.run(stale, () async => 1);
      final current = barrier.acquire();
      final currentResult = barrier.run(current, () async => 2);

      blocker.complete();
      await running;

      expect(await staleResult, isNull);
      expect(await currentResult, 2);
    });

    test('a newer mutation waits for an already issued mutation to drain', () async {
      final barrier = PlayerMutationBarrier();
      final first = barrier.acquire();
      final blocker = Completer<void>();
      final firstIssued = Completer<void>();
      var secondIssued = false;

      final firstRun = barrier.run(first, () async {
        firstIssued.complete();
        await blocker.future;
      });
      await firstIssued.future;

      final second = barrier.acquire();
      final secondRun = barrier.run(second, () async {
        secondIssued = true;
      });

      expect(secondIssued, isFalse);
      expect(first.isInvalidated, isTrue);
      await expectLater(first.invalidated, completes);

      blocker.complete();
      await firstRun;
      await secondRun;
      expect(secondIssued, isTrue);
    });

    test('explicit invalidation wakes lease waiters exactly once', () async {
      final barrier = PlayerMutationBarrier();
      final lease = barrier.acquire();
      var wakeups = 0;
      lease.invalidated.then((_) => wakeups += 1);

      expect(barrier.invalidate(lease), isTrue);
      expect(barrier.invalidate(lease), isFalse);
      await lease.invalidated;

      expect(lease.isInvalidated, isTrue);
      expect(wakeups, 1);
    });

    test('failed mutations do not poison the drain chain', () async {
      final barrier = PlayerMutationBarrier();
      final first = barrier.acquire();

      await expectLater(barrier.run<void>(first, () async => throw StateError('boom')), throwsStateError);

      final second = barrier.acquire();
      expect(await barrier.run(second, () async => 7), 7);
      await barrier.drained;
    });
  });
}
