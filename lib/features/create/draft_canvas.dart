import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';

const _hGap = 120.0;
const _vGap = 150.0;
const _pad = 72.0;
const _nodeRadius = 24.0;

/// One drawn edge. [returns] marks a cycle: the child sits on the same or
/// a higher layer, so the edge curves back instead of dropping down.
class DraftEdge {
  const DraftEdge({
    required this.from,
    required this.to,
    required this.returns,
  });

  final String from;
  final String to;
  final bool returns;
}

class DraftLayout {
  const DraftLayout({
    required this.positions,
    required this.edges,
    required this.size,
  });

  final Map<String, Offset> positions;
  final List<DraftEdge> edges;
  final Size size;
}

/// Tree layout from [DraftNode.childIds]. Same algorithm as the map's
/// `layoutGraph`: the root is the node no other node points at (falling
/// back to the story root, then list order); depth comes from breadth
/// first search, so a node reached twice keeps its shallowest layer and
/// the second edge draws as a return curve. Nodes unreachable from the
/// root land on layer zero — the view passes them as [orphans] to draw
/// them distinctly.
DraftLayout layoutDraft(
  List<DraftNode> nodes, {
  String? rootNodeId,
}) {
  if (nodes.isEmpty) {
    return const DraftLayout(positions: {}, edges: [], size: Size(240, 240));
  }
  final byId = {for (final node in nodes) node.nodeId: node};
  final pointed = <String>{};
  for (final node in nodes) {
    for (final child in node.childIds) {
      if (byId.containsKey(child)) pointed.add(child);
    }
  }
  var root = nodes.first.nodeId;
  if (rootNodeId != null && byId.containsKey(rootNodeId)) {
    root = rootNodeId;
  } else {
    for (final node in nodes) {
      if (!pointed.contains(node.nodeId)) {
        root = node.nodeId;
        break;
      }
    }
  }
  final depth = <String, int>{root: 0};
  final queue = [root];
  while (queue.isNotEmpty) {
    final next = queue.removeAt(0);
    final parent = byId[next];
    if (parent == null) continue;
    for (final child in parent.childIds) {
      if (!byId.containsKey(child) || depth.containsKey(child)) continue;
      depth[child] = depth[next]! + 1;
      queue.add(child);
    }
  }
  for (final node in nodes) {
    depth.putIfAbsent(node.nodeId, () => 0);
  }
  final layers = <int, List<String>>{};
  for (final node in nodes) {
    layers.putIfAbsent(depth[node.nodeId]!, () => []).add(node.nodeId);
  }
  var widest = 1;
  var deepest = 0;
  for (final entry in layers.entries) {
    if (entry.value.length > widest) widest = entry.value.length;
    if (entry.key > deepest) deepest = entry.key;
  }
  final positions = <String, Offset>{};
  for (final entry in layers.entries) {
    final ids = entry.value;
    for (var i = 0; i < ids.length; i++) {
      positions[ids[i]] = Offset(
        _pad + (i - (ids.length - 1) / 2) * _hGap + (widest * _hGap) / 2,
        _pad + entry.key * _vGap,
      );
    }
  }
  final edges = <DraftEdge>[];
  for (final node in nodes) {
    final from = positions[node.nodeId];
    if (from == null) continue;
    for (final child in node.childIds) {
      final to = positions[child];
      if (to == null) continue;
      edges.add(
        DraftEdge(
          from: node.nodeId,
          to: child,
          returns: depth[child]! <= depth[node.nodeId]!,
        ),
      );
    }
  }
  return DraftLayout(
    positions: positions,
    edges: edges,
    size: Size(widest * _hGap + _pad * 2, deepest * _vGap + _pad * 2 + 40),
  );
}

/// Draft canvas: every node with its title, secrets included. Secrets get
/// a lock; orphans (unreachable from the root) draw dashed and dimmed so
/// the author sees what players would never reach. Taps select a node.
class DraftCanvas extends StatelessWidget {
  const DraftCanvas({
    super.key,
    required this.nodes,
    required this.orphans,
    this.openNodeId,
    this.rootNodeId,
    required this.onSelect,
  });

  final List<DraftNode> nodes;
  final Set<String> orphans;
  final String? openNodeId;
  final String? rootNodeId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) return const SizedBox.shrink();
    final layout = layoutDraft(nodes, rootNodeId: rootNodeId);
    return SingleChildScrollView(
      scrollDirection: .horizontal,
      child: SingleChildScrollView(
        scrollDirection: .vertical,
        child: GestureDetector(
          onTapUp: (details) => _tap(details, layout),
          child: CustomPaint(
            size: layout.size,
            painter: _DraftPainter(
              nodes: nodes,
              layout: layout,
              orphans: orphans,
              openNodeId: openNodeId,
            ),
          ),
        ),
      ),
    );
  }

  void _tap(TapUpDetails details, DraftLayout layout) {
    double? best;
    String? bestId;
    for (final entry in layout.positions.entries) {
      final distance = (entry.value - details.localPosition).distance;
      if (distance <= _nodeRadius + 16 && (best == null || distance < best)) {
        best = distance;
        bestId = entry.key;
      }
    }
    if (bestId != null) onSelect(bestId);
  }
}

class _DraftPainter extends CustomPainter {
  const _DraftPainter({
    required this.nodes,
    required this.layout,
    required this.orphans,
    required this.openNodeId,
  });

  final List<DraftNode> nodes;
  final DraftLayout layout;
  final Set<String> orphans;
  final String? openNodeId;

  @override
  void paint(Canvas canvas, Size size) {
    final edgePaint = Paint()
      ..color = RamificaColors.nodeActive.withValues(alpha: 0.55)
      ..strokeWidth = 2
      ..style = .stroke;
    for (final edge in layout.edges) {
      final from = layout.positions[edge.from];
      final to = layout.positions[edge.to];
      if (from == null || to == null) continue;
      if (edge.returns) {
        final mid = Offset((from.dx + to.dx) / 2, from.dy - 64);
        canvas.drawPath(
          Path()
            ..moveTo(from.dx, from.dy)
            ..quadraticBezierTo(mid.dx, mid.dy, to.dx, to.dy),
          edgePaint,
        );
      } else {
        canvas.drawLine(from, to, edgePaint);
      }
    }
    final byId = {for (final node in nodes) node.nodeId: node};
    for (final entry in layout.positions.entries) {
      final node = byId[entry.key];
      if (node == null) continue;
      _paintNode(canvas, node, entry.value);
    }
  }

  void _paintNode(Canvas canvas, DraftNode node, Offset center) {
    final orphan = orphans.contains(node.nodeId);
    final open = node.nodeId == openNodeId;
    final base = node.secret
        ? RamificaColors.nodeLocked
        : RamificaColors.nodeActive;
    canvas.drawCircle(
      center,
      _nodeRadius,
      Paint()..color = orphan ? base.withValues(alpha: 0.35) : base,
    );
    if (node.isEnding) {
      canvas.drawCircle(
        center,
        _nodeRadius - 6,
        Paint()
          ..color = RamificaColors.surface
          ..style = .stroke
          ..strokeWidth = 2,
      );
    }
    if (orphan) {
      canvas.drawCircle(
        center,
        _nodeRadius + 5,
        Paint()
          ..color = RamificaColors.textSecondary.withValues(alpha: 0.7)
          ..style = .stroke
          ..strokeWidth = 2,
      );
    }
    if (node.secret) {
      _paintLock(canvas, center);
    }
    if (open) {
      canvas.drawCircle(
        center,
        _nodeRadius + 5,
        Paint()
          ..color = RamificaColors.hotspot
          ..style = .stroke
          ..strokeWidth = 3,
      );
    }
    final caption = node.title.trim().isEmpty ? '(untitled)' : node.title;
    final suffix = orphan ? ' • orphan' : (node.secret ? ' • secret' : '');
    final line = TextPainter(
      text: TextSpan(
        text: '$caption$suffix',
        style: RamificaText.meta.copyWith(
          color: orphan
              ? RamificaColors.textSecondary
              : RamificaColors.textPrimary,
        ),
      ),
      textAlign: .center,
      textDirection: .ltr,
      maxLines: 2,
    )..layout(maxWidth: 110);
    line.paint(canvas, center + Offset(-55, _nodeRadius + 8));
  }

  void _paintLock(Canvas canvas, Offset center) {
    final paint = Paint()
      ..color = RamificaColors.textSecondary
      ..style = .stroke
      ..strokeWidth = 2.5;
    canvas.drawRect(
      Rect.fromCenter(
        center: center + const Offset(0, 4),
        width: 16,
        height: 12,
      ),
      paint..style = .fill,
    );
    canvas.drawArc(
      Rect.fromCenter(
        center: center + const Offset(0, 1),
        width: 10,
        height: 10,
      ),
      3.14,
      3.14,
      false,
      paint..style = .stroke,
    );
  }

  @override
  bool shouldRepaint(_DraftPainter old) {
    return old.nodes != nodes ||
        old.openNodeId != openNodeId ||
        old.orphans != orphans;
  }
}
