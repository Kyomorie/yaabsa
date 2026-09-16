import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaabsa/util/audio_handler/bg_audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real BGAudioHandler can be constructed in the Flutter test process', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final handler = BGAudioHandler(container);
    expect(handler, isA<BGAudioHandler>());
  });
}
