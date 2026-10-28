import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/graph_stub.dart';

const _hGap = 120.0;
const _vGap = 150.0;
const _pad = 72.0;
const _nodeRadius = 24.0;
const _hitRadius = 40.0;

/// One drawn edge. [returns] marks a cycle: the child sits on the same or
/// a higher layer, so the edge curves back instead of dropping down.
class GraphEdge {
  const GraphEdge({
    required this.from,
    required this.to,
    required this.returns,
  });

  final String from;
  final String to;
  final bool returns;
}

class GraphLayout {
  const GraphLayout({
    required this.positions,
    required this.edges,
    required this.size,
  });

  final Map<String, Offset> positions;
  final List<GraphEdge> edges;
  final Size size;
}

/// Tree layout from [GraphStub.childIds]. The root is the node no other
/// node points at; ties fall back to list order. Depth comes from breadth
/// first search, so a node reached twice keeps its shallowest layer and
/// the second edge draws as a return curve.
GraphLayout layoutGraph(List<GraphStub> stubs) {
  if (stubs.isEmpty) {
    return const GraphLayout(positions: {}, edges: [], size: Size(240, 240));
  }
  final byId = {for (final stub in stubs) stub.nodeId: stub};
  final pointed = <String>{};
  for (final stub in stubs) {
    for (final child in stub.childIds) {
      if (byId.containsKey(child)) pointed.add(child);
    }
  }
  var root = stubs.first.nodeId;
  for (final stub in stubs) {
    if (!pointed.contains(stub.nodeId)) {
      root = stub.nodeId;
      break;
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
  for (final stub in stubs) {
    depth.putIfAbsent(stub.nodeId, () => 0);
  }
  final layers = <int, List<String>>{};
  for (final stub in stubs) {
    layers.putIfAbsent(depth[stub.nodeId]!, () => []).add(stub.nodeId);
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
  final edges = <GraphEdge>[];
  for (final stub in stubs) {
    final from = positions[stub.nodeId];
    if (from == null) continue;
    for (final child in stub.childIds) {
      final to = positions[child];
      if (to == null) continue;
      edges.add(
        GraphEdge(
          from: stub.nodeId,
          to: child,
          returns: depth[child]! <= depth[stub.nodeId]!,
        ),
      );
    }
  }
  return GraphLayout(
    positions: positions,
    edges: edges,
    size: Size(widest * _hGap + _pad * 2, deepest * _vGap + _pad * 2 + 40),
  );
}

/// Pan and zoom map. Visited nodes draw in node-active, locked ones in
/// node-locked, and the current node gets the hotspot you-are-here dot.
class GraphCanvas extends StatefulWidget {
  const GraphCanvas({
    super.key,
    required this.stubs,
    required this.currentNodeId,
    this.selectedId,
    this.onSelected,
  });

  final List<GraphStub> stubs;
  final String? currentNodeId;
  final String? selectedId;
  final ValueChanged<String>? onSelected;

  @override
  State<GraphCanvas> createState() => _GraphCanvasState();
}

class _GraphCanvasState extends State<GraphCanvas> {
  final _controller = TransformationController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = layoutGraph(widget.stubs);
    return GestureDetector(
      behavior: .opaque,
      onTapUp: (details) {
        final tapped = widget.onSelected;
        final scene = _controller.toScene(details.localPosition);
        String? bestId;
        var best = _hitRadius;
        for (final entry in layout.positions.entries) {
          final distance = (entry.value - scene).distance;
          if (distance < best) {
            best = distance;
            bestId = entry.key;
          }
        }
        if (bestId != null) tapped?.call(bestId);
      },
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 0.5,
        maxScale: 3,
        boundaryMargin: const EdgeInsets.all(double.infinity),
        constrained: false,
        child: CustomPaint(
          key: const ValueKey('graphCanvas'),
          size: layout.size,
          painter: _GraphPainter(
            stubs: widget.stubs,
            layout: layout,
            currentNodeId: widget.currentNodeId,
            selectedId: widget.selectedId,
          ),
        ),
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  const _GraphPainter({
    required this.stubs,
    required this.layout,
    required this.currentNodeId,
    required this.selectedId,
  });

  final List<GraphStub> stubs;
  final GraphLayout layout;
  final String? currentNodeId;
  final String? selectedId;

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
    final byId = {for (final stub in stubs) stub.nodeId: stub};
    for (final entry in layout.positions.entries) {
      final stub = byId[entry.key];
      if (stub == null) continue;
      _paintNode(canvas, stub, entry.value);
    }
  }

  void _paintNode(Canvas canvas, GraphStub stub, Offset center) {
    final locked = stub.locked;
    final current = stub.nodeId == currentNodeId;
    final selected = stub.nodeId == selectedId;
    canvas.drawCircle(
      center,
      _nodeRadius,
      Paint()
        ..color = locked
            ? RamificaColors.nodeLocked
            : RamificaColors.nodeActive,
    );
    if (stub.isEnding) {
      canvas.drawCircle(
        center,
        _nodeRadius - 6,
        Paint()
          ..color = RamificaColors.surface
          ..style = .stroke
          ..strokeWidth = 2,
      );
    }
    if (locked) {
      _paintLock(canvas, center);
    } else if (current) {
      canvas.drawCircle(center, 7, Paint()..color = RamificaColors.hotspot);
    }
    if (selected) {
      canvas.drawCircle(
        center,
        _nodeRadius + 5,
        Paint()
          ..color = RamificaColors.textPrimary
          ..style = .stroke
          ..strokeWidth = 3,
      );
    }
    final title = stub.title;
    if (title != null && title.isNotEmpty) {
      final line = TextPainter(
        text: TextSpan(
          text: current ? '$title • you are here' : title,
          style: RamificaText.meta.copyWith(
            color: current
                ? RamificaColors.hotspot
                : RamificaColors.textPrimary,
          ),
        ),
        textAlign: .center,
        textDirection: .ltr,
        maxLines: 2,
      )..layout(maxWidth: 110);
      line.paint(canvas, center + Offset(-55, _nodeRadius + 8));
    }
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
  bool shouldRepaint(_GraphPainter old) {
    return old.stubs != stubs ||
        old.currentNodeId != currentNodeId ||
        old.selectedId != selectedId;
  }
}
