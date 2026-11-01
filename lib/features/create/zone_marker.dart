import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/data/models/draft_node.dart';

/// Hold-zone editor over the node's LAST frame (the E image, which is what
/// the player holds on). One circle per choice, positioned in 0-1 frame
/// coordinates like the player-side [ChoiceZone].
///
/// * tap a circle to select it (it stays selected), drag to move it
///   (clamped to the frame); the move commits through [onZoneMoved] on
///   release, so a drag sends one bloc event, not a stream;
/// * under the frame, one always-visible card per choice edits its name
///   — 24 chars max with a live counter ([onLabelChanged]), matching the
///   publish checklist — and its hotspot icon ([onIconChanged]); the
///   name rides in the badge under the puck, like the player HUD;
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
    this.onIconChanged,
    this.onIconColorChanged,
    this.choiceDestinations,
    this.onTune,
    this.onAddOption,
    this.onOpenChild,
    this.errorChoiceIds,
    this.focusChoiceId,
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

  /// Picked hotspot icon name for a choice, from the shared catalog.
  final void Function(String choiceId, String icon)? onIconChanged;

  /// Picked hotspot icon color name for a choice, from the shared palette.
  final void Function(String choiceId, String color)? onIconColorChanged;

  /// Full `Scene M (Title)` destination per choice id, shown on the
  /// fused option card. Null reads as the bare `Scene —` fallback.
  final Map<String, String>? choiceDestinations;

  /// Scrolls the choice preview into view (the tune action on the fused
  /// card). Null hides the tune button.
  final void Function(String choiceId)? onTune;

  /// Creates a child on the free branch [slot] (`A` or `B`) — the hotspot
  /// path. Null keeps the legacy target-picker row instead.
  final void Function(String slot)? onAddOption;

  /// Opens the existing child of an occupied slot. Null hides the
  /// `Option X ✓` shortcut on occupied slots.
  final void Function(String targetNodeId)? onOpenChild;

  /// Choice ids whose label fails the 1-24 rule while errors show: those
  /// cards draw a red border plus a ⚠ hint under the name field.
  final Set<String>? errorChoiceIds;

  /// Choice id that just gained focus (HotspotAdded): the label field
  /// requests focus once when this changes to a non-null id.
  final String? focusChoiceId;

  @override
  State<ZoneMarker> createState() => _ZoneMarkerState();
}

class _ZoneMarkerState extends State<ZoneMarker> {
  String? _selectedId;
  Offset? _dragging;
  var _showGrid = true;
  final Map<String, TextEditingController> _labels = {};
  final Map<String, FocusNode> _foci = {};

  @override
  void dispose() {
    for (final controller in _labels.values) {
      controller.dispose();
    }
    for (final focus in _foci.values) {
      focus.dispose();
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
      for (final focus in _foci.values) {
        focus.dispose();
      }
      _foci.clear();
    } else if (_selectedId != null &&
        !widget.choices.any((choice) => choice.choiceId == _selectedId)) {
      _selectedId = null;
      _dragging = null;
    }
    _syncLabels();
    if (old.focusChoiceId != widget.focusChoiceId &&
        widget.focusChoiceId != null &&
        _foci.containsKey(widget.focusChoiceId)) {
      final target = _foci[widget.focusChoiceId]!;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => target.requestFocus(),
      );
    }
  }

  /// Choice label controllers and focus nodes follow the choice list:
  /// new choices get both, removed ones are disposed. Values resync
  /// only when the text differs, so typing keeps its caret.
  void _syncLabels() {
    final ids = {for (final choice in widget.choices) choice.choiceId};
    for (final id in _labels.keys.toList()) {
      if (!ids.contains(id)) _labels.remove(id)?.dispose();
    }
    for (final id in _foci.keys.toList()) {
      if (!ids.contains(id)) _foci.remove(id)?.dispose();
    }
    for (final choice in widget.choices) {
      final controller = _labels.putIfAbsent(
        choice.choiceId,
        () => TextEditingController(text: choice.label),
      );
      if (controller.text != choice.label) controller.text = choice.label;
      _foci.putIfAbsent(choice.choiceId, FocusNode.new);
    }
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
                decoration: const BoxDecoration(
                  color: RamificaColors.containerLowest,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  border: Border.fromBorderSide(RamificaColors.inputBorder),
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  child: Stack(
                    children: [
                      Positioned.fill(child: _frameImage()),
                      if (_showGrid)
                        const Positioned.fill(
                          child: CustomPaint(painter: _DotGridPainter()),
                        ),
                      for (final choice in widget.choices)
                        _zoneCircle(choice, width, height),
                      Positioned(top: 8, right: 8, child: _gridToggle()),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        _choiceCards(),
        _addRow(nodeId),
      ],
    );
  }

  /// Dot-grid overlay toggle. Only hides the coordinate overlay;
  /// zone positions never change with it.
  Widget _gridToggle() {
    return GestureDetector(
      key: const ValueKey('zone-grid-toggle'),
      onTap: widget.busy ? null : () => setState(() => _showGrid = !_showGrid),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: RamificaColors.containerLowest.withValues(alpha: 0.8),
        ),
        child: Icon(
          Icons.grid_4x4,
          size: 16,
          color: _showGrid
              ? RamificaColors.hotspot
              : RamificaColors.textPrimary,
        ),
      ),
    );
  }

  Widget _frameImage() {
    final url = widget.endImageUrl;
    if (url == null) {
      return const Center(
        child: Text(
          'Generate the end frame to place zones.',
          style: RamificaText.meta,
        ),
      );
    }
    return Opacity(
      opacity: 0.8,
      child: Image.network(
        url,
        fit: .cover,
        errorBuilder: (_, _, _) => const Center(
          child: Text('End frame unavailable.', style: RamificaText.meta),
        ),
      ),
    );
  }

  /// One hold-zone over the frame. The drag geometry stays the zone disc
  /// (center + radius in 0-1 frame coordinates); the visual is the suite
  /// hotspot: a glass icon puck with a numbered label badge under it.
  Widget _zoneCircle(DraftChoice choice, double width, double height) {
    final nodeId = widget.nodeId;
    final selected = choice.choiceId == _selectedId;
    final index = widget.choices.indexOf(choice);
    final accent = index % 2 == 0
        ? RamificaColors.hotspot
        : RamificaColors.nodeActive;
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
                // Accumulate the per-event delta instead of deriving the
                // centre from localPosition: that position is expressed in
                // the coordinate space captured when the drag started, so
                // re-adding the current centre on every update compounds
                // the displacement and slams the zone into a corner.
                final current = _dragging ?? Offset(choice.x, choice.y);
                _dragging = Offset(
                  (current.dx + details.delta.dx / width)
                      .clamp(0, 1)
                      .toDouble(),
                  (current.dy + details.delta.dy / height)
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
                // Select only, never toggle off: onPanDown already
                // selected this zone on the same pointer-down, so a
                // toggle would read that fresh selection and undo it
                // before the tap even lands.
                _selectedId = choice.choiceId;
                _dragging = null;
              }),
        child: Column(
          mainAxisAlignment: .center,
          mainAxisSize: .min,
          children: [
            Container(
              key: ValueKey('zone-ring-$nodeId-${choice.choiceId}'),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: .circle,
                color: RamificaColors.containerLowest.withValues(alpha: 0.9),
                border: Border.all(color: accent, width: selected ? 2 : 1),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.45),
                    blurRadius: selected ? 16 : 10,
                  ),
                ],
              ),
              child: Icon(
                choiceIconData(choice.icon, index),
                size: 20,
                color: choiceIconColor(choice.iconColor, accent),
              ),
            ),
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxWidth: 120),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: RamificaColors.containerLowest.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
                border: selected ? Border.all(color: accent) : null,
              ),
              child: Row(
                mainAxisSize: .min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '${index + 1}. ${choice.label}',
                      maxLines: 1,
                      overflow: .ellipsis,
                      style: RamificaText.labelSM.copyWith(fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One always-visible editor card per choice, in choice order: name
  /// field, icon picker, coordinates, delete. Editing never depends on
  /// which zone happens to be selected on the frame — the card number
  /// and accent match the puck badge, so the pairing stays obvious.
  Widget _choiceCards() {
    if (widget.choices.isEmpty) {
      return const Text(
        'Add a zone below to edit its hotspot.',
        style: RamificaText.meta,
      );
    }
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        for (var i = 0; i < widget.choices.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _choiceCard(widget.choices[i], i),
        ],
      ],
    );
  }

  /// One fused card per option: preview mini, slot badge, editable label
  /// with a live 24-char counter, icon picker, destination
  /// (`Scene M (Title)`), tune shortcut, and zone delete. Editing never
  /// depends on which zone is selected on the frame — the card number and
  /// accent match the puck badge, so the pairing stays obvious.
  Widget _choiceCard(DraftChoice choice, int index) {
    final accent = index % 2 == 0
        ? RamificaColors.hotspot
        : RamificaColors.nodeActive;
    final slot = choice.slot ?? String.fromCharCode(65 + index);
    final dest = widget.choiceDestinations?[choice.choiceId] ?? 'Scene —';
    final hasError = widget.errorChoiceIds?.contains(choice.choiceId) ?? false;
    return Container(
      key: ValueKey('zone-card-${choice.choiceId}'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: RamificaColors.containerBase,
        borderRadius: BorderRadius.circular(8),
        border: hasError ? Border.all(color: RamificaColors.error) : null,
      ),
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              _previewMini(accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: .start,
                  mainAxisSize: .min,
                  children: [
                    Text(
                      'Option $slot',
                      style: RamificaText.labelSM.copyWith(color: accent),
                      maxLines: 1,
                      overflow: .ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(
                          Icons.alt_route,
                          size: 13,
                          color: RamificaColors.nodeActive,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            dest,
                            style: RamificaText.bodySM.copyWith(
                              fontSize: 12,
                              color: RamificaColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Text(
                '(${choice.x.toStringAsFixed(2)}, ${choice.y.toStringAsFixed(2)})',
                style: RamificaText.meta,
              ),
              if (widget.onTune != null)
                IconButton(
                  key: ValueKey('zone-tune-${choice.choiceId}'),
                  icon: const Icon(Icons.tune, size: 18),
                  tooltip: 'Edit hotspot',
                  onPressed: widget.busy
                      ? null
                      : () => widget.onTune?.call(choice.choiceId),
                  color: RamificaColors.textSecondary,
                  style: IconButton.styleFrom(
                    backgroundColor: RamificaColors.containerHigh,
                    fixedSize: const Size(32, 32),
                    minimumSize: const Size(32, 32),
                    padding: .zero,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Current icon left of the name field; tapping it opens the
          // icon picker modal. The label field hard-caps at 24 chars
          // with a live counter — the client-side half of the publish
          // label rule (the backend `saveNode` check is the other half).
          Row(
            crossAxisAlignment: .start,
            children: [
              _iconButton(choice, index, accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: .stretch,
                  mainAxisSize: .min,
                  children: [
                    TextField(
                      key: ValueKey('zone-label-${choice.choiceId}'),
                      controller: _labels[choice.choiceId],
                      focusNode: _foci[choice.choiceId],
                      enabled: !widget.busy,
                      maxLength: 24,
                      maxLengthEnforcement: .enforced,
                      buildCounter: (
                        _, {
                        required int currentLength,
                        required bool isFocused,
                        required int? maxLength,
                      }) => Text('$currentLength/24', style: RamificaText.meta),
                      decoration: _zoneInputDecoration(),
                      onChanged: (label) =>
                          widget.onLabelChanged?.call(choice.choiceId, label),
                    ),
                    if (hasError) ...[
                      const SizedBox(height: 4),
                      Text(
                        '⚠ The Option needs a name (1-24)',
                        style: RamificaText.meta.copyWith(
                          color: RamificaColors.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          Align(
            alignment: .centerRight,
            child: TextButton(
              key: ValueKey('zone-delete-${choice.choiceId}'),
              onPressed: widget.busy
                  ? null
                  : () {
                      setState(() {
                        if (_selectedId == choice.choiceId) {
                          _selectedId = null;
                          _dragging = null;
                        }
                      });
                      widget.onZoneRemoved?.call(choice.choiceId);
                    },
              child: const Text('Delete zone'),
            ),
          ),
        ],
      ),
    );
  }

  /// 40px frame thumb for the fused card: the end frame when present, a
  /// hotspot glyph placeholder otherwise.
  Widget _previewMini(Color accent) {
    final url = widget.endImageUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 40,
        height: 40,
        color: RamificaColors.containerLowest,
        child: url == null
            ? Icon(Icons.image, size: 20, color: accent)
            : Image.network(
                url,
                fit: .cover,
                errorBuilder: (_, _, _) =>
                    Icon(Icons.image_not_supported, size: 20, color: accent),
              ),
      ),
    );
  }

  /// The choice's current icon (or the legacy fallback when none is
  /// stored), left of the name field. Tapping opens the picker modal;
  /// the pick commits its persisted name through [onIconChanged].
  Widget _iconButton(DraftChoice choice, int index, Color accent) {
    return IconButton(
      key: ValueKey('zone-icon-${choice.choiceId}'),
      tooltip: 'Hotspot icon',
      icon: Icon(choiceIconData(choice.icon, index), size: 20),
      onPressed: widget.busy ? null : () => _pickIcon(choice, index, accent),
      color: choiceIconColor(choice.iconColor, accent),
      style: IconButton.styleFrom(
        backgroundColor: accent.withValues(alpha: 0.2),
        fixedSize: const Size(40, 40),
        minimumSize: const Size(40, 40),
        padding: .zero,
        side: BorderSide(color: accent),
      ),
    );
  }

  /// Icon + color picker as a draggable modal sheet: it opens tall and
  /// drags up to near full screen over the full catalog grid. Picking a
  /// color commits at once and keeps the sheet open (the tile glyphs
  /// preview it); picking an icon closes the sheet and reports the
  /// persisted name. Dismissing keeps any color already picked.
  Future<void> _pickIcon(DraftChoice choice, int index, Color accent) async {
    var pickedColor = choice.iconColor;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (sheetContext, scrollController) {
            return StatefulBuilder(
              builder: (sheetContext, setSheetState) {
                final tint = choiceIconColor(pickedColor, accent);
                return SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: .stretch,
                      children: [
                        const Text('Hotspot icon', style: RamificaText.label),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final option in choiceColorOptions)
                              _colorSwatch(
                                choice,
                                option,
                                selected: isChoiceColorSelected(
                                  pickedColor,
                                  index,
                                  option.name,
                                ),
                                onTap: () {
                                  setSheetState(
                                    () => pickedColor = option.name,
                                  );
                                  widget.onIconColorChanged?.call(
                                    choice.choiceId,
                                    option.name,
                                  );
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: GridView.builder(
                            controller: scrollController,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 4,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                  childAspectRatio: 0.85,
                                ),
                            itemCount: choiceIconOptions.length,
                            itemBuilder: (context, i) {
                              final option = choiceIconOptions[i];
                              final selected = isChoiceIconSelected(
                                choice.icon,
                                index,
                                option.name,
                              );
                              return InkWell(
                                key: ValueKey(
                                  'zone-icon-${choice.choiceId}-${option.name}',
                                ),
                                borderRadius: BorderRadius.circular(8),
                                onTap: () =>
                                    Navigator.pop(sheetContext, option.name),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? tint.withValues(alpha: 0.2)
                                        : RamificaColors.containerHigh,
                                    borderRadius: BorderRadius.circular(8),
                                    border: selected
                                        ? Border.all(color: tint)
                                        : null,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: .center,
                                    children: [
                                      Icon(
                                        option.icon,
                                        size: 22,
                                        color: selected
                                            ? tint
                                            : RamificaColors.textSecondary,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        option.label,
                                        style: RamificaText.caption.copyWith(
                                          fontSize: 10,
                                          color: selected
                                              ? tint
                                              : RamificaColors.textSecondary,
                                        ),
                                        maxLines: 1,
                                        overflow: .ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
    if (picked != null) {
      widget.onIconChanged?.call(choice.choiceId, picked);
    }
  }

  /// One color in the picker's palette row. The selected swatch carries
  /// a light ring plus a check whose ink flips with the swatch luminance.
  Widget _colorSwatch(
    DraftChoice choice,
    ChoiceColorOption option, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: ValueKey('zone-icon-color-${choice.choiceId}-${option.name}'),
      customBorder: const CircleBorder(),
      onTap: widget.busy ? null : onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: .circle,
          color: option.color,
          border: selected
              ? Border.all(color: RamificaColors.textPrimary, width: 2)
              : Border.all(color: RamificaColors.glassBorder),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 16,
                color: option.color.computeLuminance() > 0.6
                    ? Colors.black87
                    : Colors.white,
              )
            : null,
      ),
    );
  }

  /// One row per branch slot: free slots show `Add Option A/B` (the
  /// hotspot path — a tap creates the child and focuses its label),
  /// occupied slots show `Option X ✓` opening the existing child. The
  /// two-choice cap hides the row once both slots are taken. Without an
  /// [onAddOption] callback the legacy target picker renders instead, so
  /// callers that never wired the hotspot path keep working.
  Widget _addRow(String nodeId) {
    final add = widget.onAddOption;
    if (add == null) return _legacyAddRow(nodeId);
    final open = widget.onOpenChild;
    final taken = <String, DraftChoice>{
      for (final choice in widget.choices)
        if (choice.slot == 'A' || choice.slot == 'B') choice.slot!: choice,
    };
    if (taken.length >= 2) return const SizedBox.shrink();
    return Row(
      children: [
        for (final slot in const ['A', 'B'])
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                left: slot == 'B' ? 4 : 0,
                right: slot == 'A' ? 4 : 0,
              ),
              child: taken.containsKey(slot)
                  ? OutlinedButton(
                      key: ValueKey('open-option-$nodeId-$slot'),
                      onPressed: widget.busy || open == null
                          ? null
                          : () => open(taken[slot]!.targetNodeId),
                      child: Text('Option $slot ✓'),
                    )
                  : OutlinedButton(
                      key: ValueKey('add-option-$nodeId-$slot'),
                      onPressed: widget.busy ? null : () => add(slot),
                      child: Text('Add Option $slot'),
                    ),
            ),
          ),
      ],
    );
  }

  /// Legacy new-zone row: picks an existing target node for the zone.
  /// Renders only when no [onAddOption] callback is wired.
  Widget _legacyAddRow(String nodeId) {
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
                    target.title.trim().isEmpty ? '(untitled)' : target.title,
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

/// Creator input styling: 6% white fill with a hotspot focus edge.
InputDecoration _zoneInputDecoration() {
  return const InputDecoration(
    labelText: 'Zone label',
    filled: true,
    fillColor: RamificaColors.inputFill,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: RamificaColors.inputBorder,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: RamificaColors.inputFocusedBorder,
    ),
  );
}

/// Faint coordinate dot grid over the frame (24px pitch, suite style).
/// Static paint only: no controllers, so tests settle freely.
class _DotGridPainter extends CustomPainter {
  const _DotGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = RamificaColors.hotspot.withValues(alpha: 0.25);
    for (var x = 12.0; x < size.width; x += 24) {
      for (var y = 12.0; y < size.height; y += 24) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter oldDelegate) => false;
}
