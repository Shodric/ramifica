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
  }

  final storyId = _oneSegment(path, '${AppRoutes.story}/');
  if (storyId != null) {
    return FeedLocation(storyId: storyId);
  }

  final graphId = _oneSegment(path, '${AppRoutes.graph}/');
  if (graphId != null) {
    return GraphLocation(graphId);
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
    ProfileLocation() => AppRoutes.profile,
    AccessLocation() => AppRoutes.access,
    CreateLocation() => AppRoutes.create,
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
  static const access = '/access';
  static const create = '/create';

  static String storyPath(String storyId) => '$story/$storyId';

  static String graphPath(String storyId) => '$graph/$storyId';
}

final class CreateLocation extends AppLocation {
  const CreateLocation();
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
  const ProfileLocation();
}

final class UnknownLocation extends AppLocation {
  const UnknownLocation([this.path = '']);

  final String path;
}
