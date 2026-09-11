import 'package:flutter_test/flutter_test.dart';
import 'package:yaabsa/util/audio_handler/sleep_timer_completion_gate.dart';

void main() {
  group('SleepTimerCompletionGateLedger', () {
    test('only the current owner can clear an armed gate', () {
      final ledger = SleepTimerCompletionGateLedger();
      final first = ledger.arm(itemId: 'book-a');
      final second = ledger.arm(itemId: 'book-a');

      expect(ledger.clear(first), isFalse);
      expect(ledger.armedToken, same(second));
      expect(ledger.clear(second), isTrue);
      expect(ledger.hasArmedGate, isFalse);
    });

    test('claim freezes the matched gate and removes it from the slot', () {
      final ledger = SleepTimerCompletionGateLedger();
      final token = ledger.arm(itemId: 'book-a', episodeId: 'episode-a');

      final claim = ledger.claimWhere(
        (itemId, episodeId) => itemId == 'book-a' && episodeId == 'episode-a',
      );

      expect(claim, isNotNull);
      expect(claim!.token, same(token));
      expect(claim.itemId, 'book-a');
      expect(claim.episodeId, 'episode-a');
      expect(ledger.hasArmedGate, isFalse);
    });

    test('non-matching completion cannot consume the current gate', () {
      final ledger = SleepTimerCompletionGateLedger();
      final token = ledger.arm(itemId: 'book-a', episodeId: 'episode-a');

      final claim = ledger.claimWhere(
        (itemId, episodeId) => itemId == 'book-b' && episodeId == 'episode-a',
      );

      expect(claim, isNull);
      expect(ledger.armedToken, same(token));
    });

    test('an old claimed owner cannot clear a newer gate', () {
      final ledger = SleepTimerCompletionGateLedger();
      final first = ledger.arm(itemId: 'book-a');
      final firstClaim = ledger.claimWhere((itemId, _) => itemId == 'book-a');
      expect(firstClaim, isNotNull);

      final second = ledger.arm(itemId: 'book-a');

      expect(ledger.clear(first), isFalse);
      expect(ledger.armedToken, same(second));
      expect(firstClaim!.token, same(first));
    });
  });
}
