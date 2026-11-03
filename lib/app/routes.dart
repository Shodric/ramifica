AppLocation parseLocation(String? name) {
  if (name == null || name.isEmpty) {
    return const FeedLocation();
  }

  final Uri uri;
  try {
    uri = Uri.parse(name);
  } on FormatException {
    return const UnknownLocation();
  }

  var path = uri.path;
  if (path.isEmpty) {
    return const FeedLocation();
  }
  if (!path.startsWith('/')) {
    path = '/$path';
  }
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }

  switch (path) {
    case '/':
      return const FeedLocation();
    case AppRoutes.explore:
      return const ExploreLocation();
    case AppRoutes.profile:
      return const ProfileLocation();
    case AppRoutes.access:
      return const AccessLocation();
    case AppRoutes.create:
      return const CreateLocation();
    case AppRoutes.createNew:
      return const CreateCanvasLocation();
  }

  final draftId = _oneSegment(path, '${AppRoutes.create}/');
  if (draftId != null) {
    return CreateCanvasLocation(storyId: draftId);
  }

  final storyId = _oneSegment(path, '${AppRoutes.story}/');
  if (storyId != null) {
    return FeedLocation(storyId: storyId);
  }

  final graphId = _oneSegment(path, '${AppRoutes.graph}/');
  if (graphId != null) {
    return GraphLocation(graphId);
  }

  final profileTab = _oneSegment(path, '${AppRoutes.profile}/');
  if (profileTab != null) {
    if (AppRoutes.profileTabs.contains(profileTab)) {
      return ProfileLocation(tab: profileTab);
    }
    return UnknownLocation(path);
  }

  return UnknownLocation(path);
}

String pathOf(AppLocation location) {
  return switch (location) {
    FeedLocation(:final storyId) =>
      storyId == null || storyId.isEmpty
          ? AppRoutes.feed
          : AppRoutes.storyPath(Uri.encodeComponent(storyId)),
    ExploreLocation() => AppRoutes.explore,
    GraphLocation(:final storyId) => AppRoutes.graphPath(
      Uri.encodeComponent(storyId),
    ),
    CreateLocation() => AppRoutes.create,
    CreateCanvasLocation(:final storyId) =>
        storyId == null || storyId.isEmpty
            ? AppRoutes.createNew
            : AppRoutes.createFor(Uri.encodeComponent(storyId)),
    AccessLocation() => AppRoutes.access,
    ProfileLocation(:final tab) => AppRoutes.profileTab(tab),
    UnknownLocation(:final path) => path.isEmpty ? '/' : path,
  };
}

String? _oneSegment(String path, String prefix) {
  if (!path.startsWith(prefix)) {
    return null;
  }
  final rest = path.substring(prefix.length);
  if (rest.isEmpty || rest.contains('/')) {
    return null;
  }
  try {
    final id = Uri.decodeComponent(rest);
    if (id.isEmpty) {
      return null;
    }
    return id;
  } on ArgumentError {
    return null;
  }
}

final class AccessLocation extends AppLocation {
  const AccessLocation();
}

sealed class AppLocation {
  const AppLocation();
}

abstract final class AppRoutes {
  static const feed = '/';
  static const story = '/story';
  static const explore = '/explore';
  static const graph = '/graph';
  static const profile = '/profile';
  static const create = '/create';
  static const createNew = '/create/new-creation';
  static const access = '/access';

  /// Profile content tabs addressable as `/profile/<tab>`.
  static const profileTabs = ['sagas', 'endings', 'creations'];

  static String storyPath(String storyId) => '$story/$storyId';

  static String graphPath(String storyId) => '$graph/$storyId';

  /// Profile path with an optional content tab selected. Unknown or null
  /// tabs fall back to the plain profile route.
  static String profileTab(String? tab) =>
      tab != null && profileTabs.contains(tab) ? '$profile/$tab' : profile;

  /// Deep link that opens a creation straight on the canvas editor.
  static String createFor(String storyId) => '$create/$storyId';
}

final class CreateLocation extends AppLocation {
  const CreateLocation();
}

/// Fullscreen canvas at `/create/new-creation`: same create tab, but the
/// shell hides the bottom bar and the view skips the entry screen.
/// With [storyId], the canvas opens that creation directly.
final class CreateCanvasLocation extends AppLocation {
  const CreateCanvasLocation({this.storyId});

  final String? storyId;
}

final class ExploreLocation extends AppLocation {
  const ExploreLocation();
}

final class FeedLocation extends AppLocation {
  final String? storyId;

  const FeedLocation({this.storyId});
}

final class GraphLocation extends AppLocation {
  final String storyId;

  const GraphLocation(this.storyId);
}

final class ProfileLocation extends AppLocation {
  const ProfileLocation({this.tab});

  /// Content tab to select (`sagas`, `endings`, `creations`), or null
  /// for the default tab.
  final String? tab;
}

final class UnknownLocation extends AppLocation {
  const UnknownLocation([this.path = '']);

  final String path;
}
