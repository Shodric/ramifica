import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/models/graph_stub.dart';

/// Display projection of map stubs onto draft nodes so the map reuses
/// the create hub canvas. Titles, endings, locks, and edges survive;
/// run-only state (visited, play counts) has no hub equivalent and the
/// current node is marked separately through the canvas current id.
List<DraftNode> draftNodesFromStubs(List<GraphStub> stubs) {
  return [
    for (final stub in stubs)
      DraftNode(
        nodeId: stub.nodeId,
        title: stub.title ?? '',
        visibility: stub.locked ? 'secret' : 'visible',
        isEnding: stub.isEnding,
        endingType: stub.endingType,
        // The map carries one image per node; the hub card renders it
        // as the frame.
        videoFrameLastUrl: stub.thumbnailUrl,
        videoFrameLastBlurData: stub.imageBlurData,
        choices: [
          for (var i = 0; i < stub.childIds.length; i++)
            DraftChoice(
              choiceId: i < stub.choices.length
                  ? stub.choices[i].choiceId
                  : 'choice-${stub.childIds[i]}',
              label: i < stub.choices.length ? stub.choices[i].label : '',
              icon: i < stub.choices.length ? stub.choices[i].icon : null,
              iconColor: i < stub.choices.length
                  ? stub.choices[i].iconColor
                  : null,
              targetNodeId: stub.childIds[i],
              isDefault: i == 0,
            ),
        ],
        // The published structure is fixed: no free slots, so the hub
        // canvas lays out no add minis for the map.
        cutSlots: const {'A', 'B'},
      ),
  ];
}

/// Root: the node nothing points to, else the first stub.
String? draftRootIdFromStubs(List<GraphStub> stubs) {
  if (stubs.isEmpty) return null;
  final ids = stubs.map((stub) => stub.nodeId).toSet();
  final pointed = <String>{
    for (final stub in stubs)
      for (final child in stub.childIds)
        if (ids.contains(child)) child,
  };
  for (final stub in stubs) {
    if (!pointed.contains(stub.nodeId)) return stub.nodeId;
  }
  return stubs.first.nodeId;
}

/// Stubs unreachable from the root, dimmed like hub orphans.
Set<String> draftOrphansFromStubs(List<GraphStub> stubs) {
  if (stubs.isEmpty) return const {};
  final root = draftRootIdFromStubs(stubs);
  final byId = {for (final stub in stubs) stub.nodeId: stub};
  final reached = <String>{};
  void walk(String id) {
    if (!reached.add(id)) return;
    final stub = byId[id];
    if (stub == null) return;
    for (final child in stub.childIds) {
      if (byId.containsKey(child)) walk(child);
    }
  }
  walk(root!);
  return {
    for (final stub in stubs)
      if (!reached.contains(stub.nodeId)) stub.nodeId,
  };
}
