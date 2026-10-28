import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';

/// Hold-zone editor over the node's LAST frame (the E image, which is what
/// the player holds on). One circle per choice, positioned in 0-1 frame
/// coordinates like the player-side [ChoiceZone].
///
/// * tap a circle to select it, drag to move it (clamped to the frame);
///   the move commits through [onZoneMoved] on release, so a drag sends
///   one bloc event, not a stream;
/// * the selected zone shows its label field: 24 chars max with a live
///   counter ([onLabelChanged]), matching the publish checklist;
/// * add/remove zones through [onZoneAdded]/[onZoneRemoved]; adding needs
///   a target node, picked from [targets].
///
/// STATIC: no animation controllers, so tests can pumpAndSettle freely.
/// Nothing here touches the network — zones persist through `saveNode`
/// when the author taps the inspector Save.
class ZoneMarker extends StatefulWidget {
  const ZoneMarker({
    super.key,
    required this.nodeId,
    required this.choices,
    required this.targets,
    this.endImageUrl,
    this.busy = false,
    this.onZoneMoved,
    this.onZoneAdded,
    this.onZoneRemoved,
    this.onLabelChanged,
  });

  final String nodeId;

  /// The node's choices; each carries its zone (`x`, `y`, `radius`).
  final List<DraftChoice> choices;

  /// Nodes a new zone may point at (the view passes every node but this
  /// one; endings included, since choices lead there).
  final List<DraftNode> targets;

  /// The last frame to draw zones over; null while missing/generating.
  final String? endImageUrl;

  /// While a save or generation runs, editing disables.
  final bool busy;

  /// Committed drop point of a drag, in 0-1 frame coordinates.
  final void Function(String choiceId, double x, double y)? onZoneMoved;

  /// New zone pointing at the picked target.
  final ValueChanged<String>? onZoneAdded;

  final ValueChanged<String>? onZoneRemoved;

  final void Function(String choiceId, String label)? onLabelChanged;

  @override
  State<ZoneMarker> createState() => _ZoneMarkerState();
}

class _ZoneMarkerState extends State<ZoneMarker> {
  String? _selectedId;
  Offset? _dragging;
  final Map<String, TextEditingController> _labels = {};

  @override
  void dispose() {
    for (final controller in _labels.values) {
      controller.dispose();
    }
    super.dispose();
  }
  @override
  void initState() {
    super.initState();
    _syncLabels();
  }

  @override
  void didUpdateWidget(covariant ZoneMarker old) {
    super.didUpdateWidget(old);
    if (old.nodeId != widget.nodeId) {
      _selectedId = null;
      _dragging = null;
      for (final controller in _labels.values) {
        controller.dispose();
      }
      _labels.clear();
    } else if (_selectedId != null &&
        !widget.choices.any((choice) => choice.choiceId == _selectedId)) {
      _selectedId = null;
      _dragging = null;
    }
    _syncLabels();
  }

  /// Choice label controllers follow the choice list like the inspector:
  /// new choices get a controller, removed ones are disposed. Values
  /// resync only when the text differs, so typing keeps its caret.
  void _syncLabels() {
    final ids = {for (final choice in widget.choices) choice.choiceId};
    for (final id in _labels.keys.toList()) {
      if (!ids.contains(id)) _labels.remove(id)?.dispose();
    }
    for (final choice in widget.choices) {
      final controller = _labels.putIfAbsent(
        choice.choiceId,
        () => TextEditingController(text: choice.label),
      );
      if (controller.text != choice.label) controller.text = choice.label;
    }
  }

  DraftChoice? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final choice in widget.choices) {
      if (choice.choiceId == id) return choice;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final nodeId = widget.nodeId;
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            // The editor frame: full width, 9:16 like the extracted E.
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 320.0;
            final height = width * 16 / 9;
            return SizedBox(
              width: width,
              height: height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: RamificaColors.glass,
                  borderRadius: .circular(8),
                  border: .all(color: RamificaColors.glassBorder),
                ),
                child: ClipRRect(
                  borderRadius: .circular(8),
                  child: Stack(
                    children: [
                      Positioned.fill(child: _frameImage()),
                      for (final choice in widget.choices)
                        _zoneCircle(choice, width, height),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        _selectedPanel(nodeId),
        _addRow(nodeId),
      ],
    );
  }

  Widget _frameImage() {
    final url = widget.endImageUrl;
    if (url == null) {
      return const Center(
        child: Text('Generate the end frame to place zones.', style: RamificaText.meta),
      );
    }
    return Image.network(
      url,
      fit: .cover,
      errorBuilder: (_, _, _) => const Center(
        child: Text('End frame unavailable.', style: RamificaText.meta),
      ),
    );
  }

  /// One hold-zone circle over the frame, mirroring the player ring.
  Widget _zoneCircle(DraftChoice choice, double width, double height) {
    final nodeId = widget.nodeId;
    final selected = choice.choiceId == _selectedId;
    final at = _dragging != null && selected
        ? _dragging!
        : Offset(choice.x, choice.y);
    final shortest = width < height ? width : height;
    final ring = choice.radius * shortest;
    final diameter = ring * 2;
    return Positioned(
      left: at.dx * width - ring,
      top: at.dy * height - ring,
      width: diameter,
      height: diameter,
      child: GestureDetector(
        key: ValueKey('zone-${choice.choiceId}'),
        behavior: .opaque,
        onPanDown: widget.busy
            ? null
            : (_) => setState(() {
                _selectedId = choice.choiceId;
                _dragging = Offset(choice.x, choice.y);
              }),
        onPanUpdate: widget.busy
            ? null
            : (details) => setState(() {
                _dragging = Offset(
                  ((details.localPosition.dx + at.dx * width - ring) / width)
                      .clamp(0, 1)
                      .toDouble(),
                  ((details.localPosition.dy + at.dy * height - ring) / height)
                      .clamp(0, 1)
                      .toDouble(),
                );
              }),
        onPanEnd: widget.busy
            ? null
            : (_) {
                final drop = _dragging;
                setState(() => _dragging = null);
                if (drop != null) {
                  widget.onZoneMoved?.call(choice.choiceId, drop.dx, drop.dy);
                }
              },
        onTap: widget.busy
            ? null
            : () => setState(() {
                _selectedId = selected ? null : choice.choiceId;
                _dragging = null;
              }),
        child: DecoratedBox(
          key: ValueKey('zone-ring-$nodeId-${choice.choiceId}'),
          decoration: BoxDecoration(
            shape: .circle,
            border: Border.all(
              color: selected
                  ? RamificaColors.nodeActive
                  : RamificaColors.hotspot,
              width: selected ? 3 : 2,
            ),
          ),
          child: Center(
            child: Text(
              choice.label.length > 24
                  ? choice.label.substring(0, 24)
                  : choice.label,
              maxLines: 1,
              overflow: .ellipsis,
              style: RamificaText.meta,
            ),
          ),
        ),
      ),
    );
  }

  /// Label + delete for the selected zone. The label field hard-caps at
  /// 24 characters with a live counter — the client-side half of the
  /// publish label rule (the backend `saveNode` check is the other half).
  Widget _selectedPanel(String nodeId) {
    final selected = _selected;
    if (selected == null) {
      return const Text(
        'Tap a circle to edit its label, drag to move it.',
        style: RamificaText.meta,
      );
    }
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        TextField(
          key: ValueKey('zone-label-${selected.choiceId}'),
          controller: _labels[selected.choiceId],
          enabled: !widget.busy,
          maxLength: 24,
          maxLengthEnforcement: .enforced,
          buildCounter: (
            _, {
            required int currentLength,
            required bool isFocused,
            required int? maxLength,
          }) =>
              Text('$currentLength/24', style: RamificaText.meta),
          decoration: const InputDecoration(labelText: 'Zone label'),
          onChanged: (label) =>
              widget.onLabelChanged?.call(selected.choiceId, label),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '(${selected.x.toStringAsFixed(2)}, ${selected.y.toStringAsFixed(2)})',
                style: RamificaText.meta,
              ),
            ),
            TextButton(
              key: ValueKey('zone-delete-${selected.choiceId}'),
              onPressed: widget.busy
                  ? null
                  : () {
                      setState(() {
                        _selectedId = null;
                        _dragging = null;
                      });
                      widget.onZoneRemoved?.call(selected.choiceId);
                    },
              child: const Text('Delete zone'),
            ),
          ],
        ),
      ],
    );
  }

  /// New zones while the node has fewer than two choices (the publish
  /// max). The target picker lists every candidate node by title.
  Widget _addRow(String nodeId) {
    if (widget.choices.length >= 2) return const SizedBox.shrink();
    if (widget.targets.isEmpty) {
      return const Text(
        'Add a node before zoning its choice.',
        style: RamificaText.meta,
      );
    }
    return Row(
      children: [
        Expanded(
          child: DropdownButton<String>(
            key: ValueKey('zone-target-$nodeId'),
            hint: const Text('Target node', style: RamificaText.meta),
            items: [
              for (final target in widget.targets)
                DropdownMenuItem(
                  value: target.nodeId,
                  child: Text(
                    target.title.trim().isEmpty
                        ? '(untitled)'
                        : target.title,
                    style: RamificaText.meta,
                  ),
                ),
            ],
            onChanged: widget.busy
                ? null
                : (targetId) {
                    if (targetId != null) widget.onZoneAdded?.call(targetId);
                  },
          ),
        ),
      ],
    );
  }
}
