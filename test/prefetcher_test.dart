import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/core/warm_slot.dart';
import 'package:ramifica/data/models/playback.dart';

void main() {
  test('warms the current clip and skips a secret', () {
    final mounted = <String>[];
    final prefetcher = _prefetcher(mounted, []);

    prefetcher.warm(_playback());

    expect(prefetcher.urls, [
      'https://example.com/a.mp4',
      'https://example.com/b.mp4',
    ]);
    expect(mounted, prefetcher.urls);
    expect(mounted, isNot(contains('https://example.com/voice.m4a')));
    expect(mounted, isNot(contains('data:image/webp;base64,abc')));
  });

  test('the cap drops the oldest clip that is not current', () {
    final disposed = <String>[];
    final prefetcher = _prefetcher([], disposed);
    prefetcher.warm(
      _playback(
        choices: [
          _open('b', 'https://example.com/b.mp4'),
          _open('c', 'https://example.com/c.mp4'),
          _open('d', 'https://example.com/d.mp4'),
        ],
      ),
    );

    expect(prefetcher.urls, [
      'https://example.com/a.mp4',
      'https://example.com/c.mp4',
      'https://example.com/d.mp4',
    ]);
    expect(disposed, ['https://example.com/b.mp4']);
  });

  test('promote keeps that destination when the queue is full', () {
    final prefetcher = _prefetcher([], []);
    prefetcher.warm(
      _playback(
        choices: [
          _open('b', 'https://example.com/b.mp4'),
          _open('c', 'https://example.com/c.mp4'),
        ],
      ),
    );
    prefetcher.promote('https://example.com/b.mp4');
    prefetcher.warm(
      _playback(
        choices: [
          _open('b', 'https://example.com/b.mp4'),
          _open('c', 'https://example.com/c.mp4'),
          _open('d', 'https://example.com/d.mp4'),
        ],
      ),
    );

    expect(prefetcher.urls, [
      'https://example.com/a.mp4',
      'https://example.com/b.mp4',
      'https://example.com/d.mp4',
    ]);
  });

  test('a new story drops the previous queue', () {
    final disposed = <String>[];
    final prefetcher = _prefetcher([], disposed);
    prefetcher.warm(_playback());
    prefetcher.warm(
      _playback(
        storyId: 'story_other',
        video: 'https://example.com/z.mp4',
        choices: [_open('y', 'https://example.com/y.mp4')],
      ),
    );

    expect(prefetcher.storyId, 'story_other');
    expect(prefetcher.urls, [
      'https://example.com/z.mp4',
      'https://example.com/y.mp4',
    ]);
    expect(disposed, [
      'https://example.com/a.mp4',
      'https://example.com/b.mp4',
    ]);
  });

  test('the next node keeps the warmed destination', () {
    final prefetcher = _prefetcher([], []);
    prefetcher.warm(
      _playback(
        choices: [
          _open('b', 'https://example.com/b.mp4'),
          _open('c', 'https://example.com/c.mp4'),
        ],
      ),
    );
    prefetcher.warm(
      _playback(
        video: 'https://example.com/b.mp4',
        choices: [
          _open('d', 'https://example.com/d.mp4'),
          _open('e', 'https://example.com/e.mp4'),
        ],
      ),
    );

    expect(prefetcher.urls, [
      'https://example.com/b.mp4',
      'https://example.com/d.mp4',
      'https://example.com/e.mp4',
    ]);
  });

  test('clear drops every slot', () {
    final disposed = <String>[];
    final prefetcher = _prefetcher([], disposed);
    prefetcher.warm(_playback());
    prefetcher.clear();

    expect(prefetcher.urls, isEmpty);
    expect(prefetcher.storyId, isNull);
    expect(disposed, [
      'https://example.com/a.mp4',
      'https://example.com/b.mp4',
    ]);
  });
}

Prefetcher _prefetcher(List<String> mounted, List<String> disposed) {
  return Prefetcher(open: () => _RecordingSlot(mounted, disposed));
}

class _RecordingSlot implements WarmSlot {
  _RecordingSlot(this.mounted, this.disposed);

  final List<String> mounted;
  final List<String> disposed;
  String? _url;

  @override
  void mount(String url) {
    _url = url;
    mounted.add(url);
  }

  @override
  void dispose() {
    final url = _url;
    if (url == null) return;
    disposed.add(url);
    _url = null;
  }
}

Playback _playback({
  String storyId = 'story_temple',
  String video = 'https://example.com/a.mp4',
  List<PlaybackChoice>? choices,
}) {
  return Playback(
    runId: 'run_1',
    status: .active,
    story: PlaybackStory(
      storyId: storyId,
      title: 'The temple secret',
      authorName: 'Alex Vance',
    ),
    node: PlaybackNode(
      nodeId: 'node_001',
      title: 'The temple door',
      isEnding: false,
      videoUrl: video,
      durationSeconds: 10,
      pauseAtSeconds: 9.967,
      windowSeconds: 6,
      videoFrameLastBlurData: 'data:image/webp;base64,abc',
      ttsAudioUrl: 'https://example.com/voice.m4a',
    ),
    choices: choices ?? [_open('b', 'https://example.com/b.mp4'), _secret()],
  );
}

PlaybackChoice _open(String id, String url) {
  return PlaybackChoice(
    choiceId: id,
    label: id,
    targetNodeId: id,
    isDefault: true,
    x: 0.2,
    y: 0.6,
    radius: 0.1,
    targetSecret: false,
    target: PlaybackTarget(nodeId: id, videoUrl: url),
  );
}

PlaybackChoice _secret() {
  return const PlaybackChoice(
    choiceId: 'secret',
    label: 'Secret',
    targetNodeId: 'node_secret',
    isDefault: false,
    x: 0.8,
    y: 0.6,
    radius: 0.1,
    targetSecret: true,
    target: null,
  );
}
