import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/playback.dart';
import 'package:ramifica/data/persistence/publication.dart';

Map<String, dynamic> nodeJson({Object? badge = 'https://cdn.example/b.png'}) {
  return {
    'nodeId': 'n1',
    'title': 'The last gate',
    'isEnding': true,
    'videoUrl': 'https://cdn.example/v.mp4',
    'durationSeconds': 6,
    'videoFrameLastBlurData': 'blur',
    'endingBadgeUrl': badge,
  };
}

void main() {
  test('PlaybackNode parses the ending badge URL', () {
    final node = PlaybackNode.fromJson(nodeJson());
    expect(node.endingBadgeUrl, 'https://cdn.example/b.png');
  });

  test('PlaybackNode without a badge parses as null (legacy payloads)', () {
    final node = PlaybackNode.fromJson(nodeJson(badge: null));
    expect(node.endingBadgeUrl, isNull);
    final missing = Map<String, dynamic>.from(nodeJson())..remove('endingBadgeUrl');
    expect(PlaybackNode.fromJson(missing).endingBadgeUrl, isNull);
  });

  test('playbackDocument passes the badge URL through', () {
    final doc = playbackDocument('n1', nodeJson(), {});
    expect(doc['endingBadgeUrl'], 'https://cdn.example/b.png');
  });
}
