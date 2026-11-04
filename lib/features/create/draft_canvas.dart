import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/you_are_here_pill.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/create_node_card.dart';
import 'package:ramifica/features/create/create_plus_node.dart';

/// Horizontal sibling gap and vertical row pitch. Gaps fit 170x240 cards
/// plus connector room, and the pad clears card halves, so nothing clips.
const _hGap = 220.0;
const _vGap = 320.0;
const _pad = 120.0;

/// One drawn edge. [returns] marks a cycle: the child sits on the same or
/// a higher layer, so the edge curves back instead of dropping down.
class DraftEdge {
  const DraftEdge({
    required this.from,
    required this.to,
    required this.returns,
    this.iconName,
    this.iconColorName,
    this.accent,
  });

  final String from;
  final String to;
  final bool returns;

  /// Persisted hotspot icon name of the parent choice leading to [to],
  /// or null for legacy/unset icons (the badge falls back to the
  /// per-slot glyph).
  final String? iconName;

  /// Persisted hotspot icon color name of that choice, or null for the
  /// per-slot accent fallback.
  final String? iconColorName;

  /// Resolved edge tint: the choice color, or the per-slot accent when
  /// unset. Null on minis and return edges, which stay neutral.
  final Color? accent;
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

/// Tree layout from [DraftNode.childIds]: a top-down pyramid. Leaves run left
/// to right; each parent centers over its children. Children order by slot:
/// unslotted legacy choices first (append order), then slot `A`, then `B`;
/// empty slots become `+` minis in place, so tapping a mini is always
/// replaced by its child on the same spot. Merged nodes keep their
/// shallowest depth and repeat edges draw as return curves; unreachable
/// nodes lay out as their own trees after the main one.
DraftLayout layoutDraft(List<DraftNode> nodes, {String? rootNodeId}) {
  if (nodes.isEmpty) {
    return const DraftLayout(positions: {}, edges: [], size: Size(240, 240));
  }
  final byId = {for (final node in nodes) node.nodeId: node};
  final root = _resolveRootId(nodes, rootNodeId);
  // Forest DFS from the root, then any unreachable nodes: first visit
  // wins the tree edge, so merges and cycles never double-place.
  final depth = <String, int>{};
  final treeKids = <String, List<String>>{};
  void visit(String id, int d) {
    depth[id] = d;
    final kids = <String>[];
    final node = byId[id];
    if (node != null) {
      // Slot-ordered children: unslotted legacy choices keep append order
      // first, then A, then B. Each free slot renders its own `+` mini in
      // place (up to the two-choice cap), so a tapped mini is always
      // replaced by its child on the same spot.
      final bySlot = <String, String>{};
      final unslotted = <String>[];
      for (final link in _orderedLinks(node)) {
        if (!byId.containsKey(link.target) || depth.containsKey(link.target)) {
          continue;
        }
        final raw = link.slot;
        final String? slot = (raw == 'A' || raw == 'B') ? raw : null;
        if (slot == null || bySlot.containsKey(slot)) {
          unslotted.add(link.target);
        } else {
          bySlot[slot] = link.target;
        }
      }
      kids.addAll(unslotted);
      if (!node.isEnding) {
        var remaining = 2 - node.choices.length;
        for (final s in node.openSlots) {
          final real = bySlot[s];
          if (real != null) {
            kids.add(real);
          } else if (remaining > 0) {
            final virtual = 'mini:$id:$s';
            if (!byId.containsKey(virtual)) {
              kids.add(virtual);
              remaining--;
            }
          }
        }
      }
    }
    treeKids[id] = kids;
    for (final kid in kids) {
      if (!depth.containsKey(kid)) visit(kid, d + 1);
    }
  }

  visit(root, 0);
  for (final node in nodes) {
    if (!depth.containsKey(node.nodeId)) visit(node.nodeId, 0);
  }
  // Leaves run left to right; each parent centers over first/last child.
  final left = <String, double>{};
  var leaf = 0.0;
  void place(String id) {
    final kids = treeKids[id] ?? const <String>[];
    if (kids.isEmpty) {
      left[id] = leaf;
      leaf += _hGap;
      return;
    }
    for (final kid in kids) {
      if (!left.containsKey(kid)) place(kid);
    }
    // Pivot over real children only: `+` minis keep their leaf slots (so
    // a tapped mini is replaced by its child on the same spot) but never
    // drag the parent sideways. Single-child runs stack vertically and
    // every connector keeps the same length.
    final real = [
      for (final kid in kids)
        if (!kid.startsWith('mini:')) kid,
    ];
    final span = real.isEmpty ? kids : real;
    left[id] = (left[span.first]! + left[span.last]!) / 2;
  }

  place(root);
  for (final node in nodes) {
    if (!left.containsKey(node.nodeId)) place(node.nodeId);
  }
  final positions = <String, Offset>{
    for (final entry in left.entries)
      entry.key: Offset(
        _pad + entry.value,
        _pad + (depth[entry.key] ?? 0) * _vGap,
      ),
  };
  final edges = <DraftEdge>[];
  for (final node in nodes) {
    for (final child in node.childIds) {
      if (!positions.containsKey(child)) continue;
      final choice = _edgeChoice(node, child);
      final slotAccent = choice?.slot == 'B'
          ? RamificaColors.nodeActive
          : RamificaColors.hotspot;
      final returns = (depth[child] ?? 0) <= (depth[node.nodeId] ?? 0);
      edges.add(
        DraftEdge(
          from: node.nodeId,
          to: child,
          returns: returns,
          iconName: choice?.icon,
          iconColorName: choice?.iconColor,
          // Return edges stay neutral (null accent); real forward edges
          // carry the resolved choice tint.
          accent: returns
              ? null
              : choiceIconColor(choice?.iconColor, slotAccent),
        ),
      );
    }
  }
  for (final entry in treeKids.entries) {
    for (final kid in entry.value) {
      if (!kid.startsWith('mini:') || byId.containsKey(kid)) continue;
      edges.add(DraftEdge(from: entry.key, to: kid, returns: false));
    }
  }
  var deepest = 0;
  var maxX = 0.0;
  for (final entry in positions.entries) {
    final d = depth[entry.key] ?? 0;
    if (d > deepest) deepest = d;
    if (entry.value.dx > maxX) maxX = entry.value.dx;
  }
  return DraftLayout(
    positions: positions,
    edges: edges,
    size: Size(maxX + _pad + 120, deepest * _vGap + _pad * 2 + 200),
  );
}

/// The parent choice leading to [childId], or null when no choice points
/// there (orphan links drawn from `childIds` alone).
DraftChoice? _edgeChoice(DraftNode node, String childId) {
  for (final choice in node.choices) {
    if (choice.targetNodeId == childId) return choice;
  }
  return null;
}

/// Midpoint of the forward-edge cubic at t=1/2: P=(P0+3·C1+3·C2+P3)/8
/// with C1=(from.x,from.y+60) and C2=(to.x,to.y-60) — the same curve
/// [_CanvasPainter] strokes. Badge widgets center here.
Offset edgeBadgeCenter(Offset from, Offset to) {
  final c1 = Offset(from.dx, from.dy + 60);
  final c2 = Offset(to.dx, to.dy - 60);
  return Offset(
    (from.dx + 3 * c1.dx + 3 * c2.dx + to.dx) / 8,
    (from.dy + 3 * c1.dy + 3 * c2.dy + to.dy) / 8,
  );
}

/// Ids the canvas shows in root mode: the root plus its direct children.
/// Null means show everything.
Set<String>? rootModeVisibleIds(
  List<DraftNode> nodes,
  String? rootNodeId,
  bool rootMode,
) {
  if (!rootMode || rootNodeId == null) return null;
  DraftNode? root;
  for (final node in nodes) {
    if (node.nodeId == rootNodeId) root = node;
  }
  if (root == null) return null;
  return {root.nodeId, ...root.childIds};
}

/// Root resolution shared by layout, paths, and numbering: explicit
/// [rootNodeId] when it exists, else the node nobody points at, else
/// list order. Empty string when there are no nodes.
String _resolveRootId(List<DraftNode> nodes, String? rootNodeId) {
  if (nodes.isEmpty) return '';
  final byId = {for (final node in nodes) node.nodeId: node};
  if (rootNodeId != null && byId.containsKey(rootNodeId)) return rootNodeId;
  final pointed = <String>{
    for (final node in nodes)
      for (final child in node.childIds)
        if (byId.containsKey(child)) child,
  };
  for (final node in nodes) {
    if (!pointed.contains(node.nodeId)) return node.nodeId;
  }
  return nodes.first.nodeId;
}

/// Child links in canvas order: unslotted legacy choices first (append
/// order), then slot `A`, then slot `B`. Targets repeat-safe: callers
/// dedupe by visit.
Iterable<({String target, String? slot})> _orderedLinks(DraftNode node) sync* {
  final seen = <String>{};
  for (final choice in node.choices) {
    if (choice.slot != 'A' &&
        choice.slot != 'B' &&
        seen.add(choice.targetNodeId)) {
      yield (target: choice.targetNodeId, slot: null);
    }
  }
  for (final s in const ['A', 'B']) {
    for (final choice in node.choices) {
      if (choice.slot == s && seen.add(choice.targetNodeId)) {
        yield (target: choice.targetNodeId, slot: s);
      }
    }
  }
}

/// Scene numbers in story order: depth-first from the root following
/// canvas order, then any unreachable nodes. The root is always 1, so a
/// chain reads 1, 2, 3… instead of fetch order.
Map<String, int> sceneIndexes(List<DraftNode> nodes, String? rootNodeId) {
  final byId = {for (final node in nodes) node.nodeId: node};
  final root = _resolveRootId(nodes, rootNodeId);
  final seen = <String>{};
  final order = <String>[];
  void walk(String id) {
    final node = byId[id];
    if (node == null || !seen.add(id)) return;
    order.add(id);
    for (final link in _orderedLinks(node)) {
      walk(link.target);
    }
  }

  if (root.isNotEmpty) walk(root);
  for (final node in nodes) {
    walk(node.nodeId);
  }
  return {for (var i = 0; i < order.length; i++) order[i]: i + 1};
}

/// Branch path per node from the root (`''` for the root itself, `'A'`
/// for the A child, `'ABA'` for the B child of the A child of A...).
/// Empty means the plain `Scene N` label; shown next to it otherwise.
/// Unreachable nodes keep an empty path. Cycles resolve to the first
/// visit, mirroring [layoutDraft].
Map<String, String> slotPaths(List<DraftNode> nodes, String? rootNodeId) {
  final byId = {for (final node in nodes) node.nodeId: node};
  final root = _resolveRootId(nodes, rootNodeId);
  final paths = <String, String>{};
  void walk(String id, String path) {
    if (paths.containsKey(id)) return;
    paths[id] = path;
    final node = byId[id];
    if (node == null) return;
    for (final link in _orderedLinks(node)) {
      if (link.target.isEmpty || !byId.containsKey(link.target)) continue;
      walk(link.target, path + (link.slot ?? ''));
    }
  }

  if (root.isNotEmpty) walk(root, '');
  for (final node in nodes) {
    paths.putIfAbsent(node.nodeId, () => '');
  }
  return paths;
}

/// Level badge per node from the root: `'root'` for the root itself,
/// `'1a'`/`'1b'` for its children, `'2aa'`... for grandchildren. Depth
/// counts edges; letters come from the slot when set, else from the
/// link order among siblings (first free of `a`/`b`). Unreachable nodes
/// keep an empty badge. Cycles resolve to the first visit, mirroring
/// [layoutDraft].
Map<String, String> levelBadges(List<DraftNode> nodes, String? rootNodeId) {
  final byId = {for (final node in nodes) node.nodeId: node};
  final root = _resolveRootId(nodes, rootNodeId);
  final badges = <String, String>{};
  void walk(String id, int depth, String path) {
    if (badges.containsKey(id)) return;
    badges[id] = depth == 0 ? 'root' : '$depth$path';
    final node = byId[id];
    if (node == null) return;
    final links = [
      for (final link in _orderedLinks(node))
        if (link.target.isNotEmpty && byId.containsKey(link.target)) link,
    ];
    final reserved = <String>{
      for (final link in links)
        if (link.slot == 'A' || link.slot == 'B') link.slot!.toLowerCase(),
    };
    var fallback = 0;
    for (final link in links) {
      var letter = '';
      if (link.slot == 'A' || link.slot == 'B') {
        letter = link.slot!.toLowerCase();
      } else {
        while (fallback < 2) {
          final candidate = 'ab'[fallback++];
          if (reserved.add(candidate)) {
            letter = candidate;
            break;
          }
        }
      }
      walk(link.target, depth + 1, path + letter);
    }
  }

  if (root.isNotEmpty) walk(root, 0, '');
  for (final node in nodes) {
    badges.putIfAbsent(node.nodeId, () => '');
  }
  return badges;
}

/// Pan transform (at 1x) landing [center] in the middle of a [viewport].
/// The focus button uses it to return to the root node; a missing
/// viewport or target falls back to identity.
Matrix4 recenterTransform(Size? viewport, Offset? center) {
  if (viewport == null || center == null) return Matrix4.identity();
  return Matrix4.identity()..setTranslationRaw(
    viewport.width / 2 - center.dx,
    viewport.height / 2 - center.dy,
    0,
  );
}

class _Mini {
  const _Mini({required this.id, required this.parentId, required this.slot});

  final String id;
  final String parentId;
  final String slot;
}

/// Draft canvas: Stitch-style node cards plus `+` minis for missing choice
/// slots. Secrets show a lock; orphans (unreachable from the root) draw
/// dimmed so the author sees what players would never reach. Card taps
/// select a node; mini taps add a child under that parent. No hold
/// gestures, no timers, no animations.
class DraftCanvas extends StatelessWidget {
  const DraftCanvas({
    super.key,
    required this.nodes,
    required this.orphans,
    this.openNodeId,
    this.rootNodeId,
    this.currentNodeId,
    this.onSelect,
    this.onAdd,
    required this.transformationController,
    this.rootMode = false,
  });

  final List<DraftNode> nodes;
  final Set<String> orphans;
  final String? openNodeId;
  final String? rootNodeId;

  /// Run position on the read-only map: its card keeps the You-are-here
  /// pill. Null (the editor) marks nothing.
  final String? currentNodeId;

  /// Node tap. Null disables card taps for the read-only map.
  final ValueChanged<String>? onSelect;

  /// Parent id and slot for the new child. Both travel with the tap so the
  /// auto-link lands exactly on the tapped mini - never the open node by
  /// accident, never the wrong slot. Null hides the add minis: nothing
  /// can be added on the read-only map.
  final void Function(String parentId, String slot)? onAdd;
  final TransformationController transformationController;

  /// When true, only the root and its direct children render.
  final bool rootMode;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) return const SizedBox.shrink();
    // Free slots join the layout as virtual children in place, so each
    // mini sits exactly where its child will land.
    final layout = layoutDraft(nodes, rootNodeId: rootNodeId);
    final visible = rootModeVisibleIds(nodes, rootNodeId, rootMode);
    bool shown(String id) => visible == null || visible.contains(id);

    final scene = sceneIndexes(nodes, rootNodeId);
    final paths = slotPaths(nodes, rootNodeId);
    final minis = <_Mini>[];
    // Without an add target the map shows no minis: its structure is
    // fixed, so free slots are unknown children, not add buttons.
    if (onAdd != null) {
      for (final node in nodes) {
        if (!shown(node.nodeId)) continue;
        if (rootMode && node.nodeId != rootNodeId) continue;
        for (final s in const ['A', 'B']) {
          final id = 'mini:${node.nodeId}:$s';
          if (!layout.positions.containsKey(id)) continue;
          minis.add(_Mini(id: id, parentId: node.nodeId, slot: s));
        }
      }
    }
    final add = onAdd;
    final virtualIds = {for (final mini in minis) mini.id};
    final positions = <String, Offset>{
      for (final node in nodes)
        if (shown(node.nodeId) && layout.positions.containsKey(node.nodeId))
          node.nodeId: layout.positions[node.nodeId]!,
      for (final mini in minis) mini.id: layout.positions[mini.id]!,
    };
    // First incoming edge wins the parent: merges attach to one side.
    final parentOf = <String, String>{};
    for (final edge in layout.edges) {
      parentOf.putIfAbsent(edge.to, () => edge.from);
    }
    // Dodges the incoming edge: an A-side child hangs left of its
    // parent, so the pill hugs the outer side. Roots stay centered.
    Alignment pillAlignment(String nodeId) {
      final parent = parentOf[nodeId];
      final here = positions[nodeId];
      final there = parent == null ? null : positions[parent];
      if (here == null || there == null) return .center;
      if (here.dx < there.dx - 1) return .centerLeft;
      if (here.dx > there.dx + 1) return .centerRight;
      return .center;
    }
    final size = layout.size;
    return InteractiveViewer(
      transformationController: transformationController,
      minScale: 0.25,
      maxScale: 1.0,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      constrained: false,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          children: [
            CustomPaint(
              size: size,
              painter: _CanvasPainter(
                positions: positions,
                edges: layout.edges,
                virtualIds: virtualIds,
                nodes: nodes,
              ),
            ),
            for (final node in nodes)
              if (positions.containsKey(node.nodeId))
                Positioned(
                  left: positions[node.nodeId]!.dx - createCardWidth / 2,
                  top: positions[node.nodeId]!.dy - createCardHeight / 2,
                  child: Stack(
                    clipBehavior: .none,
                    children: [
                      CreateNodeCard(
                        key: ValueKey('canvas-node-${node.nodeId}'),
                        node: node,
                        sceneIndex: scene[node.nodeId] ?? 0,
                        slotPath: paths[node.nodeId] ?? '',
                        isRoot: node.nodeId == rootNodeId,
                        isOpen: node.nodeId == openNodeId,
                        isOrphan: orphans.contains(node.nodeId),
                        onTap: onSelect == null
                            ? null
                            : () => onSelect!(node.nodeId),
                      ),
                      if (node.nodeId == currentNodeId)
                        Positioned(
                          top: -14,
                          left: 0,
                          right: 0,
                          child: Align(
                            alignment: pillAlignment(node.nodeId),
                            child: const YouAreHerePill(),
                          ),
                        ),
                    ],
                  ),
                ),
            for (final edge in layout.edges)
              if (!edge.returns &&
                  !virtualIds.contains(edge.to) &&
                  positions.containsKey(edge.from) &&
                  positions.containsKey(edge.to))
                _EdgeBadge(
                  key: ValueKey('edge-badge-${edge.from}-${edge.to}'),
                  center: edgeBadgeCenter(
                    positions[edge.from]!,
                    positions[edge.to]!,
                  ),
                  edge: edge,
                  index: _badgeIndex(nodes, edge),
                ),
            if (add != null)
            for (final mini in minis)
              Positioned(
                left: positions[mini.id]!.dx - createMiniWidth / 2,
                top: positions[mini.id]!.dy - createMiniHeight / 2,
                child: CreatePlusNode(
                  key: ValueKey('canvas-add-${mini.parentId}-${mini.slot}'),
                  parentId: mini.parentId,
                  slot: mini.slot,
                  onAdd: (_) => add(mini.parentId, mini.slot),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Choice index of the parent choice leading along [edge], for the legacy
/// icon fallback in [choiceIconData]. Unknown links read as the first.
int _badgeIndex(List<DraftNode> nodes, DraftEdge edge) {
  for (final node in nodes) {
    if (node.nodeId != edge.from) continue;
    for (var i = 0; i < node.choices.length; i++) {
      if (node.choices[i].targetNodeId == edge.to) return i;
    }
  }
  return 0;
}

/// Mid-edge hotspot badge: a tinted circle with the choice glyph at the
/// cubic midpoint. Display-only ([IgnorePointer]) — the curve carries no
/// hit testing and fonts never enter the painter.
class _EdgeBadge extends StatelessWidget {
  const _EdgeBadge({
    super.key,
    required this.center,
    required this.edge,
    required this.index,
  });

  final Offset center;
  final DraftEdge edge;
  final int index;

  @override
  Widget build(BuildContext context) {
    final accent = edge.accent ?? RamificaColors.nodeActive;
    return Positioned(
      left: center.dx - 14,
      top: center.dy - 14,
      width: 28,
      height: 28,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent,
            border: Border.all(
              color: RamificaColors.containerLowest.withValues(alpha: 0.9),
              width: 2,
            ),
          ),
          child: Icon(
            choiceIconData(edge.iconName, index),
            size: 14,
            color: accent.computeLuminance() > 0.6
                ? Colors.black87
                : Colors.white,
          ),
        ),
      ),
    );
  }
}

class _CanvasPainter extends CustomPainter {
  const _CanvasPainter({
    required this.positions,
    required this.edges,
    required this.virtualIds,
    required this.nodes,
  });

  final Map<String, Offset> positions;
  final List<DraftEdge> edges;
  final Set<String> virtualIds;
  final List<DraftNode> nodes;

  @override
  void paint(Canvas canvas, Size size) {
    final returnPaint = Paint()
      ..color = RamificaColors.textSecondary.withValues(alpha: 0.6)
      ..strokeWidth = 2
      ..style = .stroke;
    final miniPaint = Paint()
      ..color = RamificaColors.textSecondary.withValues(alpha: 0.55)
      ..strokeWidth = 1.5
      ..style = .stroke;
    for (final edge in edges) {
      final from = positions[edge.from];
      final to = positions[edge.to];
      if (from == null || to == null) continue;
      // Empty slots hang off their parent on a dashed line; they take no
      // arrowhead because nothing flows yet.
      if (virtualIds.contains(edge.to)) {
        _dashed(canvas, from, to, miniPaint);
        continue;
      }
      if (edge.returns) {
        final mid = Offset((from.dx + to.dx) / 2, from.dy - 64);
        canvas.drawPath(
          Path()
            ..moveTo(from.dx, from.dy)
            ..quadraticBezierTo(mid.dx, mid.dy, to.dx, to.dy),
          returnPaint,
        );
      } else {
        // Real forward edges draw in the choice tint: the resolved icon
        // color, or the per-slot accent when unset.
        final accent = edge.accent ?? RamificaColors.nodeActive;
        canvas.drawPath(
          Path()
            ..moveTo(from.dx, from.dy)
            ..cubicTo(from.dx, from.dy + 60, to.dx, to.dy - 60, to.dx, to.dy),
          Paint()
            ..color = accent
            ..strokeWidth = 2
            ..style = .stroke,
        );
        _arrow(canvas, from, to, Paint()..color = accent);
      }
    }
  }

  void _arrow(Canvas canvas, Offset from, Offset to, Paint paint) {
    final angle = (to - from).direction;
    const len = 10.0;
    const half = 4.5;
    final back = to - Offset(math.cos(angle), math.sin(angle)) * len;
    final perp = Offset(-math.sin(angle), math.cos(angle)) * half;
    canvas.drawPath(
      Path()
        ..moveTo(to.dx, to.dy)
        ..lineTo(back.dx + perp.dx, back.dy + perp.dy)
        ..lineTo(back.dx - perp.dx, back.dy - perp.dy)
        ..close(),
      paint..style = .fill,
    );
  }

  void _dashed(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 6.0;
    const gap = 4.0;
    final total = (to - from).distance;
    if (total <= 0) return;
    var d = 0.0;
    while (d < total) {
      final a = from + (to - from) * (d / total);
      final b = from + (to - from) * (math.min(d + dash, total) / total);
      canvas.drawLine(a, b, paint);
      d += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_CanvasPainter old) {
    return !identical(old.nodes, nodes) ||
        old.positions.length != positions.length;
  }
}

/// Viewport-space dot grid behind the canvas. It paints in screen space
/// (repainting on every [controller] change) so the dots cover the whole
/// viewport at any pan or zoom, no matter how small the content box is.
class CanvasViewportGrid extends StatelessWidget {
  const CanvasViewportGrid({super.key, required this.controller});

  final TransformationController controller;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ViewportGridPainter(controller),
      child: const SizedBox.expand(),
    );
  }
}

class _ViewportGridPainter extends CustomPainter {
  _ViewportGridPainter(this.controller) : super(repaint: controller);

  final TransformationController controller;

  @override
  void paint(Canvas canvas, Size size) {
    final forward = controller.value;
    if (forward.determinant() == 0) return;
    final inverse = Matrix4.inverted(forward);
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(
      inverse,
      size.bottomRight(Offset.zero),
    );
    final dot = Paint()..color = RamificaColors.hotspot.withValues(alpha: 0.16);
    for (var x = (topLeft.dx ~/ 32) * 32.0; x <= bottomRight.dx; x += 32) {
      for (var y = (topLeft.dy ~/ 32) * 32.0; y <= bottomRight.dy; y += 32) {
        canvas.drawCircle(
          MatrixUtils.transformPoint(forward, Offset(x, y)),
          0.75,
          dot,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ViewportGridPainter old) =>
      !identical(old.controller, controller);
}
