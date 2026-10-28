import 'package:ramifica/data/models/app_failure.dart';

/// One exit of a visited node from `graphStubs`: the choice label plus
/// how many recorded plays took it. `choices[i]` on a stub targets that
/// stub's `childIds[i]`; both follow the node `choices` order.
class GraphChoice {
  const GraphChoice({
    required this.choiceId,
    required this.label,
    required this.count,
  });

  factory GraphChoice.fromJson(Map<String, dynamic> json) {
    return GraphChoice(
      choiceId: _requiredString(json['choiceId']),
      label: _optionalString(json['label']) ?? '',
      count: _optionalCount(json['count']),
    );
  }

  final String choiceId;
  final String label;
  final int count;

  @override
  bool operator ==(Object other) {
    return other is GraphChoice &&
        other.choiceId == choiceId &&
        other.label == label &&
        other.count == count;
  }

  @override
  int get hashCode => Object.hash(choiceId, label, count);
}

/// One map stub from `graphStubs`. Unvisited secret nodes carry only an
/// id: no title, no image. `choiceCount` is the total recorded choice
/// events on that node; `childIds` drives the map edges. `choices` is
/// the parent's own per-exit breakdown for the sheet share bars, sent
/// for visited non-endings only.
class GraphStub {
  const GraphStub({
    required this.nodeId,
    this.title,
    required this.isEnding,
    required this.visited,
    required this.secret,
    this.thumbnailUrl,
    this.endingType,
    this.choiceCount = 0,
    this.childIds = const [],
    this.choices = const [],
  });

  factory GraphStub.fromJson(Map<String, dynamic> json) {
    final childIds = json['childIds'];
    return GraphStub(
      nodeId: _requiredString(json['nodeId']),
      title: _optionalString(json['title']),
      isEnding: _requiredBool(json['isEnding']),
      visited: _requiredBool(json['visited']),
      secret: _optionalBool(json['secret']),
      thumbnailUrl: _optionalString(json['thumbnailUrl']),
      endingType: _optionalString(json['endingType']),
      choiceCount: _optionalCount(json['choiceCount']),
      childIds: childIds == null
          ? const []
          : [
              for (final id in (childIds as List)) _requiredString(id),
            ],
      choices: _optionalChoices(json['choices']),
    );
  }

  final String nodeId;
  final String? title;
  final bool isEnding;
  final bool visited;
  final bool secret;
  final String? thumbnailUrl;
  final String? endingType;
  final int choiceCount;
  final List<String> childIds;
  final List<GraphChoice> choices;

  /// True while the map must hide the body: never visited and secret.
  bool get locked => !visited && secret;

  @override
  bool operator ==(Object other) {
    return other is GraphStub &&
        other.nodeId == nodeId &&
        other.title == title &&
        other.isEnding == isEnding &&
        other.visited == visited &&
        other.secret == secret &&
        other.thumbnailUrl == thumbnailUrl &&
        other.endingType == endingType &&
        other.choiceCount == choiceCount &&
        _sameStrings(other.childIds, childIds) &&
        _sameChoices(other.choices, choices);
  }

  @override
  int get hashCode => Object.hash(
    nodeId,
    title,
    isEnding,
    visited,
    secret,
    thumbnailUrl,
    endingType,
    choiceCount,
    Object.hashAll(childIds),
    Object.hashAll(choices),
  );
}

/// The `graphStubs` payload: every node of the story plus the run's
/// current node.
class GraphStubsResult {
  const GraphStubsResult({required this.nodes, required this.currentNodeId});

  factory GraphStubsResult.fromJson(Map<String, dynamic> json) {
    final rawNodes = json['nodes'];
    if (rawNodes is! List) throw const AppFailure(.invalid);
    return GraphStubsResult(
      nodes: [
        for (final node in rawNodes)
          GraphStub.fromJson(_objectMap(node)),
      ],
      currentNodeId: _requiredString(json['currentNodeId']),
    );
  }

  final List<GraphStub> nodes;
  final String currentNodeId;

  @override
  bool operator ==(Object other) {
    return other is GraphStubsResult &&
        other.currentNodeId == currentNodeId &&
        _sameStubs(other.nodes, nodes);
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(nodes), currentNodeId);
}

Map<String, dynamic> _objectMap(Object? value) {
  if (value is! Map) throw const AppFailure(.invalid);
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String _requiredString(Object? value) {
  if (value is! String) throw const AppFailure(.invalid);
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw const AppFailure(.invalid);
  return trimmed;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const AppFailure(.invalid);
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

bool _requiredBool(Object? value) {
  if (value is! bool) throw const AppFailure(.invalid);
  return value;
}

bool _optionalBool(Object? value) {
  if (value == null) return false;
  return _requiredBool(value);
}

int _optionalCount(Object? value) {
  if (value == null) return 0;
  if (value is! num) throw const AppFailure(.invalid);
  final number = value.toDouble();
  if (!number.isFinite || number < 0 || number != number.roundToDouble()) {
    throw const AppFailure(.invalid);
  }
  return number.toInt();
}

/// The stub's own per-exit breakdown. Malformed entries are skipped so
/// one bad choice cannot sink the whole map.
List<GraphChoice> _optionalChoices(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const AppFailure(.invalid);
  final choices = <GraphChoice>[];
  for (final entry in value) {
    try {
      choices.add(GraphChoice.fromJson(_objectMap(entry)));
    } on AppFailure {
      continue;
    }
  }
  return choices;
}

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameChoices(List<GraphChoice> a, List<GraphChoice> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameStubs(List<GraphStub> a, List<GraphStub> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
