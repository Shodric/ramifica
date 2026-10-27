import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/routes.dart';

void main() {
  test('public paths are English', () {
    expect(AppRoutes.feed, '/');
    expect(AppRoutes.story, '/story');
    expect(AppRoutes.explore, '/explore');
    expect(AppRoutes.graph, '/graph');
    expect(AppRoutes.profile, '/profile');
    expect(AppRoutes.access, '/access');
    expect(AppRoutes.create, '/create');
    expect(AppRoutes.storyPath('story_temple'), '/story/story_temple');
    expect(AppRoutes.graphPath('story_1'), '/graph/story_1');
  });

  test('parses the public paths', () {
    expect(parseLocation('/'), isA<FeedLocation>());
    expect(parseLocation('/?source=pwa'), isA<FeedLocation>());
    expect(parseLocation(null), isA<FeedLocation>());

    final story = parseLocation('/story/story_temple');
    expect(story, isA<FeedLocation>());
    expect((story as FeedLocation).storyId, 'story_temple');

    final encoded = parseLocation('/story/a%20b');
    expect((encoded as FeedLocation).storyId, 'a b');

    expect(parseLocation('/explore'), isA<ExploreLocation>());
    expect(parseLocation('/explore/'), isA<ExploreLocation>());
    expect(parseLocation('/explore?q=1'), isA<ExploreLocation>());

    final graph = parseLocation('/graph/story_1');
    expect(graph, isA<GraphLocation>());
    expect((graph as GraphLocation).storyId, 'story_1');

    expect(parseLocation('/access'), isA<AccessLocation>());
    expect(parseLocation('/create'), isA<CreateLocation>());
    expect(parseLocation('/profile'), isA<ProfileLocation>());
  });

  test('rejects paths that are missing an id', () {
    expect(parseLocation('/story'), isA<UnknownLocation>());
    expect(parseLocation('/story/'), isA<UnknownLocation>());
    expect(parseLocation('/graph'), isA<UnknownLocation>());
    expect(parseLocation('/graph/'), isA<UnknownLocation>());
    expect(parseLocation('/story/a/b'), isA<UnknownLocation>());
    expect(parseLocation('/nope'), isA<UnknownLocation>());
  });

  test('rejects the old Spanish paths', () {
    expect(parseLocation('/h/story_temple'), isA<UnknownLocation>());
    expect(parseLocation('/explorar'), isA<UnknownLocation>());
    expect(parseLocation('/grafo/story_1'), isA<UnknownLocation>());
    expect(parseLocation('/entrar'), isA<UnknownLocation>());
    expect(parseLocation('/crear'), isA<UnknownLocation>());
    expect(parseLocation('/perfil'), isA<UnknownLocation>());
  });
}
