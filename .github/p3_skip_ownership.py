from pathlib import Path

PATH = Path('lib/util/audio_handler/bg_audio_handler.dart')


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    return source.replace(old, new, 1)


def transform_block(source: str, start_marker: str, end_marker: str, transform, label: str) -> str:
    start = source.find(start_marker)
    if start < 0:
        raise SystemExit(f'{label}: start marker missing')
    end = source.find(end_marker, start)
    if end < 0:
        raise SystemExit(f'{label}: end marker missing')
    block = source[start:end]
    updated = transform(block)
    if updated == block:
        raise SystemExit(f'{label}: transformation made no changes')
    return source[:start] + updated + source[end:]


def one(block: str, old: str, new: str, label: str) -> str:
    count = block.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    return block.replace(old, new, 1)


def transform_next(block: str) -> str:
    block = one(
        block,
        "    final operationId = _beginUserSeekNavigation();\n",
        "    final skipLease = _playerMutationBarrier.acquire();\n"
        "    final operationId = _beginUserSeekNavigation(mutationLease: skipLease);\n"
        "    bool ownsSkip() => _playerMutationBarrier.isCurrent(skipLease) && !_isDisposing;\n",
        'next: capture lease before queue wait',
    )
    block = one(
        block,
        "        if (_currentMediaItem == null) return;\n",
        "        if (!ownsSkip() || _currentMediaItem == null) return;\n",
        'next: post-wait ownership gate',
    )
    block = one(
        block,
        "          await _seekInternal(newPosition);\n          navigationSucceeded = position != fromPosition;\n",
        "          await _seekInternal(newPosition, mutationLease: skipLease);\n"
        "          if (!ownsSkip()) {\n"
        "            return;\n"
        "          }\n"
        "          navigationSucceeded = position != fromPosition;\n",
        'next: keep chapter seek on original lease',
    )
    block = one(
        block,
        "        if (queueList.isNotEmpty) {\n",
        "        if (!ownsSkip()) {\n"
        "          return;\n"
        "        }\n\n"
        "        if (queueList.isNotEmpty) {\n",
        'next: gate queue transition before mutation',
    )
    block = one(
        block,
        "          await play();\n          final afterMedia = _currentMediaItem;\n",
        "          await _playWithPlayerMutationLease(skipLease);\n"
        "          if (!ownsSkip()) {\n"
        "            return;\n"
        "          }\n"
        "          final afterMedia = _currentMediaItem;\n",
        'next: keep next-item play on original lease',
    )
    return block


def transform_previous(block: str) -> str:
    block = one(
        block,
        "    final operationId = _beginUserSeekNavigation();\n",
        "    final skipLease = _playerMutationBarrier.acquire();\n"
        "    final operationId = _beginUserSeekNavigation(mutationLease: skipLease);\n"
        "    bool ownsSkip() => _playerMutationBarrier.isCurrent(skipLease) && !_isDisposing;\n",
        'previous: capture lease before queue wait',
    )
    block = one(
        block,
        "        if (_currentMediaItem == null) return;\n",
        "        if (!ownsSkip() || _currentMediaItem == null) return;\n",
        'previous: post-wait ownership gate',
    )
    block = one(
        block,
        "          await _seekInternal(newPosition);\n          navigationSucceeded = position != fromPosition;\n",
        "          await _seekInternal(newPosition, mutationLease: skipLease);\n"
        "          if (!ownsSkip()) {\n"
        "            return;\n"
        "          }\n"
        "          navigationSucceeded = position != fromPosition;\n",
        'previous: keep chapter seek on original lease',
    )
    return block


def verify(source: str) -> None:
    def block(start_marker: str, end_marker: str) -> str:
        start = source.index(start_marker)
        end = source.index(end_marker, start)
        return source[start:end]

    next_block = block(
        '  Future<void> skipToNextInApp() async {',
        '\n  @override\n  Future<void> skipToPrevious()',
    )
    previous_block = block(
        '  Future<void> skipToPreviousInApp() async {',
        '\n  Future<void> _queueSkipOperation(',
    )

    required_global = {
        'public play wrapper': 'Future<void> play() => _playInternal();',
        'authorized play wrapper': 'Future<void> _playWithPlayerMutationLease(PlayerMutationLease lease)',
        'authorized play internal': 'Future<void> _playInternal({PlayerMutationLease? mutationLease}) async',
        'lease reuse': 'final playLease = mutationLease ?? _playerMutationBarrier.acquire();',
        'authorized fallback rejection': 'if (mutationLease != null && nextEntry == null)',
    }
    for label, snippet in required_global.items():
        if source.count(snippet) != 1:
            raise SystemExit(f'{label} contract failed: count={source.count(snippet)}')

    required_next = {
        'capture before wait': 'final skipLease = _playerMutationBarrier.acquire();',
        'navigation binds lease': '_beginUserSeekNavigation(mutationLease: skipLease)',
        'post-wait currentness': 'if (!ownsSkip() || _currentMediaItem == null) return;',
        'chapter seek carries lease': 'await _seekInternal(newPosition, mutationLease: skipLease);',
        'next-item play carries lease': 'await _playWithPlayerMutationLease(skipLease);',
    }
    for label, snippet in required_next.items():
        if next_block.count(snippet) != 1:
            raise SystemExit(f'next {label} contract failed: count={next_block.count(snippet)}')
    if 'await play();' in next_block:
        raise SystemExit('next skip still contains an authority-reacquiring public play call')

    required_previous = {
        'capture before wait': 'final skipLease = _playerMutationBarrier.acquire();',
        'navigation binds lease': '_beginUserSeekNavigation(mutationLease: skipLease)',
        'post-wait currentness': 'if (!ownsSkip() || _currentMediaItem == null) return;',
        'chapter seek carries lease': 'await _seekInternal(newPosition, mutationLease: skipLease);',
    }
    for label, snippet in required_previous.items():
        if previous_block.count(snippet) != 1:
            raise SystemExit(f'previous {label} contract failed: count={previous_block.count(snippet)}')


def main() -> None:
    text = PATH.read_text()

    text = replace_once(
        text,
        "  @override\n  Future<void> play() async {\n    final ignoreProgress = _ignoreProgressOnNextPlay || _activeMusicLibraryId != null;\n",
        "  @override\n  Future<void> play() => _playInternal();\n\n"
        "  Future<void> _playWithPlayerMutationLease(PlayerMutationLease lease) {\n"
        "    if (!_playerMutationBarrier.isCurrent(lease) || _isDisposing) {\n"
        "      return Future.value();\n"
        "    }\n"
        "    return _playInternal(mutationLease: lease);\n"
        "  }\n\n"
        "  Future<void> _playInternal({PlayerMutationLease? mutationLease}) async {\n"
        "    if (mutationLease != null && (!_playerMutationBarrier.isCurrent(mutationLease) || _isDisposing)) {\n"
        "      return;\n"
        "    }\n"
        "    final ignoreProgress = _ignoreProgressOnNextPlay || _activeMusicLibraryId != null;\n",
        'split public and lease-authorized play',
    )

    text = replace_once(
        text,
        "    var playContextGeneration = ++_playbackContextGeneration;\n"
        "    final playLease = _playerMutationBarrier.acquire();\n",
        "    if (mutationLease != null && (!_playerMutationBarrier.isCurrent(mutationLease) || _isDisposing)) {\n"
        "      return;\n"
        "    }\n\n"
        "    var playContextGeneration =\n"
        "        mutationLease == null ? ++_playbackContextGeneration : _playbackContextGeneration;\n"
        "    final playLease = mutationLease ?? _playerMutationBarrier.acquire();\n",
        'reuse authorized play lease',
    )

    text = replace_once(
        text,
        "      playContextGeneration = _playbackContextGeneration;\n",
        "      if (mutationLease == null) {\n"
        "        playContextGeneration = _playbackContextGeneration;\n"
        "      }\n",
        'do not rebase authorized play context',
    )

    text = replace_once(
        text,
        "    QueueItem? nextItem = nextEntry?.item;\n\n"
        "    if (nextEntry == null && _restoredMediaItem != null) {\n",
        "    QueueItem? nextItem = nextEntry?.item;\n\n"
        "    if (mutationLease != null && nextEntry == null) {\n"
        "      abandonPlayLoading();\n"
        "      return;\n"
        "    }\n\n"
        "    if (nextEntry == null && _restoredMediaItem != null) {\n",
        'forbid fallback during lease-authorized play',
    )

    text = transform_block(
        text,
        '  Future<void> skipToNextInApp() async {',
        '\n  @override\n  Future<void> skipToPrevious()',
        transform_next,
        'skipToNextInApp',
    )
    text = transform_block(
        text,
        '  Future<void> skipToPreviousInApp() async {',
        '\n  Future<void> _queueSkipOperation(',
        transform_previous,
        'skipToPreviousInApp',
    )

    verify(text)
    PATH.write_text(text)


if __name__ == '__main__':
    main()
