import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/you_are_here_pill.dart';
import 'package:ramifica/data/models/graph_stub.dart';

const _hGap = 176.0;
const _vGap = 216.0;
const _pad = 72.0;

const _rootCardSize = Size(204, 78);
const _branchCardSize = Size(164, 168);
const _endingCardSize = Size(88, 124);

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

/// The node nothing points at; ties fall back to list order (mirrors
/// [layoutGraph]).
String _rootId(List<GraphStub> stubs) {
  final ids = stubs.map((stub) => stub.nodeId).toSet();
  final pointed = <String>{};
  for (final stub in stubs) {
    for (final child in stub.childIds) {
      if (ids.contains(child)) pointed.add(child);
    }
  }
  for (final stub in stubs) {
    if (!pointed.contains(stub.nodeId)) return stub.nodeId;
  }
  return stubs.first.nodeId;
}

Size _cardSize(GraphStub stub, bool isRoot) {
  if (stub.isEnding) return _endingCardSize;
  if (isRoot) return _rootCardSize;
  return _branchCardSize;
}

/// Pan and zoom story map. Cards follow the Stitch decision-map look:
/// visited cards glow on the active path, locked ones dim, endings render
/// as trophy/lock/hidden seals, and the current node keeps a static
/// you-are-here pill. No timers, no motion.
class GraphCanvas extends StatefulWidget {
  const GraphCanvas({
    super.key,
    required this.stubs,
    required this.currentNodeId,
    this.selectedId,
    this.onSelected,
    this.onApproach,
  });

  final List<GraphStub> stubs;
  final String? currentNodeId;
  final String? selectedId;
  final ValueChanged<String>? onSelected;
  final ValueChanged<String>? onApproach;

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
    final byId = {for (final stub in widget.stubs) stub.nodeId: stub};
    final rootId = widget.stubs.isEmpty ? null : _rootId(widget.stubs);
    return InteractiveViewer(
      transformationController: _controller,
      minScale: 0.5,
      maxScale: 3,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      constrained: false,
      child: SizedBox(
        key: const ValueKey('graphCanvas'),
        width: layout.size.width,
        height: layout.size.height,
        child: Stack(
          children: [
            CustomPaint(
              size: layout.size,
              painter: _GraphBackground(
                stubs: widget.stubs,
                layout: layout,
                byId: byId,
                rootId: rootId,
              ),
            ),
            for (final entry in layout.positions.entries)
              if (byId[entry.key] case final stub?)
                Positioned(
                  left:
                      entry.value.dx -
                      _cardSize(stub, stub.nodeId == rootId).width / 2,
                  top:
                      entry.value.dy -
                      _cardSize(stub, stub.nodeId == rootId).height / 2,
                  width: _cardSize(stub, stub.nodeId == rootId).width,
                  height: _cardSize(stub, stub.nodeId == rootId).height,
                  child: Stack(
                    clipBehavior: .none,
                    children: [
                      _GraphNodeCard(
                        stub: stub,
                        isRoot: stub.nodeId == rootId,
                        isCurrent: stub.nodeId == widget.currentNodeId,
                        isSelected: stub.nodeId == widget.selectedId,
                        onTap: () => widget.onSelected?.call(stub.nodeId),
                        onBranch: () {
                          if (stub.locked) {
                            (widget.onApproach ?? widget.onSelected)?.call(
                              stub.nodeId,
                            );
                          } else {
                            widget.onSelected?.call(stub.nodeId);
                          }
                        },
                      ),
                      if (stub.nodeId == widget.currentNodeId)
                        const Positioned(
                          top: -14,
                          left: 0,
                          right: 0,
                          child: Center(child: YouAreHerePill()),
                        ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// One map card. Titles render as widgets except on the selected card:
/// the detail sheet below already carries the selected title, and widget
/// tests pin each title to a single finder.
class _GraphNodeCard extends StatelessWidget {
  const _GraphNodeCard({
    required this.stub,
    required this.isRoot,
    required this.isCurrent,
    required this.isSelected,
    required this.onTap,
    required this.onBranch,
  });

  final GraphStub stub;
  final bool isRoot;
  final bool isCurrent;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onBranch;

  @override
  Widget build(BuildContext context) {
    final card = stub.isEnding
        ? _EndingCard(stub: stub, isSelected: isSelected, onTap: onTap)
        : isRoot
        ? _RootCard(stub: stub, isSelected: isSelected, onTap: onTap)
        : _BranchCard(
            stub: stub,
            isSelected: isSelected,
            onTap: onTap,
            onBranch: onBranch,
          );
    final framed = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: isSelected
            ? Border.all(color: RamificaColors.hotspot, width: 2)
            : Border.all(color: RamificaColors.glassBorder),
        boxShadow: [
          if (isCurrent)
            const BoxShadow(color: RamificaColors.glowCyan, blurRadius: 16)
          else
            const BoxShadow(
              color: Color(0x66000000),
              blurRadius: 16,
              offset: Offset(0, 8),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: InkWell(onTap: onTap, child: card),
      ),
    );
    if (stub.visited || isSelected) return framed;
    return Opacity(opacity: 0.8, child: framed);
  }
}

class _CardThumbnail extends StatelessWidget {
  const _CardThumbnail({
    required this.stub,
    required this.width,
    required this.height,
  });

  final GraphStub stub;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final url = stub.thumbnailUrl?.trim() ?? '';
    final placeholder = Container(
      width: width,
      height: height,
      color: RamificaColors.inputFill,
      child: Icon(
        stub.locked ? Icons.lock : Icons.image,
        size: 20,
        color: RamificaColors.textSecondary,
        semanticLabel: stub.locked ? 'Locked' : 'No image',
      ),
    );
    if (url.isEmpty) {
      final blur = _decodeBlur(stub.imageBlurData);
      if (blur == null) return placeholder;
      final image = Image.memory(
        blur,
        width: width,
        height: height,
        fit: .cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => placeholder,
      );
      if (!stub.locked) return image;
      return Stack(
        children: [
          image,
          Positioned.fill(
            child: Container(
              color: .fromARGB(90, 0, 0, 0),
              child: const Icon(
                Icons.lock,
                size: 20,
                color: Colors.white,
                semanticLabel: 'Locked',
              ),
            ),
          ),
        ],
      );
    }
    return Image.network(
      url,
      width: width,
      height: height,
      fit: .cover,
      errorBuilder: (context, error, stack) => placeholder,
    );
  }
}

Uint8List? _decodeBlur(String? source) {
  if (source == null || source.isEmpty) return null;
  try {
    final comma = source.indexOf(',');
    final payload = comma < 0 ? source : source.substring(comma + 1);
    if (payload.isEmpty) return null;
    return base64Decode(payload);
  } catch (_) {
    return null;
  }
}

class _RootCard extends StatelessWidget {
  const _RootCard({
    required this.stub,
    required this.isSelected,
    required this.onTap,
  });

  final GraphStub stub;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = stub.title?.trim() ?? '';
    return Container(
      width: _rootCardSize.width,
      height: _rootCardSize.height,
      color: RamificaColors.containerHigh,
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _CardThumbnail(stub: stub, width: 52, height: 62),
              ),
              if (stub.visited)
                const Positioned(
                  right: 3,
                  bottom: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: RamificaColors.hotspot,
                      shape: .circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(
                        Icons.check,
                        size: 12,
                        color: RamificaColors.onSecondary,
                        semanticLabel: 'Completed',
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              mainAxisAlignment: .center,
              children: [
                const Text(
                  'Start',
                  style: TextStyle(
                    fontFamily: RamificaText.sans,
                    fontWeight: FontWeight.w700,
                    fontSize: 10,
                    height: 14 / 10,
                    letterSpacing: 0.6,
                    color: RamificaColors.onPrimaryContainer,
                  ),
                ),
                if (title.isNotEmpty && !isSelected)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: RamificaText.label,
                  ),
                Text(
                  stub.visited ? 'Completed' : 'Locked',
                  style: RamificaText.meta.copyWith(
                    color: stub.visited
                        ? RamificaColors.nodeActive
                        : RamificaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchCard extends StatelessWidget {
  const _BranchCard({
    required this.stub,
    required this.isSelected,
    required this.onTap,
    required this.onBranch,
  });

  final GraphStub stub;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onBranch;

  @override
  Widget build(BuildContext context) {
    final title = stub.title?.trim() ?? '';
    return Container(
      width: _branchCardSize.width,
      height: _branchCardSize.height,
      color: stub.visited
          ? RamificaColors.containerHighest
          : RamificaColors.containerLow,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: .start,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _CardThumbnail(
                  stub: stub,
                  width: _branchCardSize.width - 20,
                  height: 76,
                ),
              ),
              if (stub.locked)
                const Positioned.fill(
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: RamificaColors.glass,
                        shape: .circle,
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(
                          Icons.call_split,
                          size: 16,
                          color: RamificaColors.textSecondary,
                          semanticLabel: 'Locked branch',
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (title.isNotEmpty && !isSelected)
            Text(
              title,
              maxLines: 1,
              overflow: .ellipsis,
              style: RamificaText.label,
            ),
          const Spacer(),
          if (stub.visited)
            const Row(
              children: [
                Icon(
                  Icons.radio_button_checked,
                  size: 13,
                  color: RamificaColors.nodeActive,
                  semanticLabel: 'Chosen',
                ),
                SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Chosen branch',
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: TextStyle(
                      fontFamily: RamificaText.sans,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      height: 16 / 12,
                      color: RamificaColors.nodeActive,
                    ),
                  ),
                ),
              ],
            )
          else
            InkWell(
              onTap: onBranch,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: RamificaColors.containerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: const Row(
                  mainAxisAlignment: .center,
                  children: [
                    Icon(
                      Icons.replay,
                      size: 12,
                      color: RamificaColors.onPrimaryContainer,
                    ),
                    SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Play branch',
                        maxLines: 1,
                        overflow: .ellipsis,
                        style: RamificaText.labelSM,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EndingCard extends StatelessWidget {
  const _EndingCard({
    required this.stub,
    required this.isSelected,
    required this.onTap,
  });

  final GraphStub stub;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = stub.title?.trim() ?? '';
    final name = title.isEmpty ? 'Secret' : title;
    final discovered = stub.visited;
    final hidden = stub.locked;
    return Container(
      width: _endingCardSize.width,
      height: _endingCardSize.height,
      color: RamificaColors.containerLow,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      child: Column(
        mainAxisAlignment: .center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: discovered
                  ? RamificaColors.rewardGold.withValues(alpha: 0.2)
                  : RamificaColors.containerHighest,
              shape: .circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(9),
              child: Icon(
                discovered
                    ? Icons.workspace_premium
                    : hidden
                    ? Icons.visibility_off
                    : Icons.lock,
                size: 18,
                color: discovered
                    ? RamificaColors.rewardGold
                    : hidden
                    ? RamificaColors.nodeActive
                    : RamificaColors.textSecondary,
                semanticLabel: discovered
                    ? 'Discovered ending'
                    : hidden
                    ? 'Hidden ending'
                    : 'Locked ending',
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (!isSelected)
            Text(
              name,
              maxLines: 2,
              overflow: .ellipsis,
              textAlign: .center,
              style: RamificaText.caption.copyWith(
                color: RamificaText.body.color,
                fontWeight: .w700,
              ),
            ),
          const SizedBox(height: 2),
          Text(
            discovered
                ? 'Discovered'
                : hidden
                ? 'Hidden'
                : 'Locked',
            style: RamificaText.caption.copyWith(
              fontSize: 9,
              height: 12 / 9,
              letterSpacing: 0.4,
              fontWeight: .w700,
              color: discovered
                  ? RamificaColors.rewardGold
                  : hidden
                  ? RamificaColors.nodeActive
                  : RamificaColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _GraphBackground extends CustomPainter {
  const _GraphBackground({
    required this.stubs,
    required this.layout,
    required this.byId,
    required this.rootId,
  });

  final List<GraphStub> stubs;
  final GraphLayout layout;
  final Map<String, GraphStub> byId;
  final String? rootId;

  @override
  void paint(Canvas canvas, Size size) {
    _paintDots(canvas, size);
    for (final edge in layout.edges) {
      final from = byId[edge.from];
      final to = byId[edge.to];
      final fromPos = layout.positions[edge.from];
      final toPos = layout.positions[edge.to];
      if (from == null || to == null || fromPos == null || toPos == null) {
        continue;
      }
      _paintEdge(canvas, edge, from, to, fromPos, toPos);
    }
  }

  void _paintDots(Canvas canvas, Size size) {
    const step = 26.0;
    final paint = Paint()
      ..color = RamificaColors.hotspot.withValues(alpha: 0.08);
    for (var x = step / 2; x < size.width; x += step) {
      for (var y = step / 2; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.2, paint);
      }
    }
  }

  void _paintEdge(
    Canvas canvas,
    GraphEdge edge,
    GraphStub from,
    GraphStub to,
    Offset fromPos,
    Offset toPos,
  ) {
    final fromSize = _cardSize(from, from.nodeId == rootId);
    final toSize = _cardSize(to, to.nodeId == rootId);
    final start = Offset(fromPos.dx, fromPos.dy + fromSize.height / 2 - 2);
    final end = Offset(toPos.dx, toPos.dy - toSize.height / 2 + 2);
    final Path path;
    if (edge.returns) {
      final mid = Offset((start.dx + end.dx) / 2, start.dy - 64);
      path = Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(mid.dx, mid.dy, end.dx, end.dy);
    } else {
      final cy = (start.dy + end.dy) / 2;
      path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(start.dx, cy, end.dx, cy, end.dx, end.dy);
    }
    final active = from.visited && to.visited && !edge.returns;
    if (active) {
      final glow = Paint()
        ..color = RamificaColors.hotspot.withValues(alpha: 0.18)
        ..strokeWidth = 8
        ..style = .stroke
        ..strokeCap = .round;
      canvas.drawPath(path, glow);
    }
    final Paint stroke;
    if (active) {
      final golden = to.visited && to.isEnding;
      stroke = Paint()
        ..shader = LinearGradient(
          begin: .topCenter,
          end: .bottomCenter,
          colors: golden
              ? const [RamificaColors.nodeActive, RamificaColors.rewardGold]
              : const [RamificaColors.hotspot, RamificaColors.nodeActive],
        ).createShader(Rect.fromPoints(start, end))
        ..strokeWidth = active && !to.isEnding ? 3 : 2.5
        ..style = .stroke
        ..strokeCap = .round;
      canvas.drawPath(path, stroke);
    } else {
      stroke = Paint()
        ..color = RamificaColors.textSecondary.withValues(alpha: 0.4)
        ..strokeWidth = 2
        ..style = .stroke
        ..strokeCap = .round;
      canvas.drawPath(_dashed(path), stroke);
    }
  }

  Path _dashed(Path source) {
    const on = 5.0;
    const off = 5.0;
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        out.addPath(
          metric.extractPath(distance, math.min(distance + on, metric.length)),
          Offset.zero,
        );
        distance += on + off;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(_GraphBackground old) {
    return old.stubs != stubs || old.layout != layout;
  }
}
