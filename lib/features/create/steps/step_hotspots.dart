import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/zone_marker.dart';

/// S5 Options: hotspot header and the [ZoneMarker] preview, which holds
/// one card per option plus one styled add button per free slot. Zones
/// persist with the scene Save button or generation; there is no
/// separate Save zones button.
/// [showErrors] flags options whose label is not 1-24 characters.
/// Delete has no affordance for now; [onDelete] and
/// [deleteBlockedReason] stay wired for its return.
class StepHotspots extends StatefulWidget {
  const StepHotspots({
    super.key,
    required this.node,
    this.bloc,
    required this.busy,
    required this.showErrors,
    this.isRoot = false,
    this.targets = const [],
    this.targetTitles = const {},
    this.focusChoiceId,
    this.onZoneMoved,
    this.onZoneAdded,
    this.onZoneRemoved,
    this.onChoiceLabelChanged,
    this.onChoiceIconChanged,
    this.onChoiceIconColorChanged,
    this.onAddBranch,
    this.onAddHotspot,
    this.onOpenChild,
    this.onCutToggled,
    this.onEndingToggled,
    this.onEndingTypeChanged,
    this.onEndingBadgeRequested,
    this.onDelete,
    this.deleteBlockedReason,
    this.active = true,
    this.continueAction,
  });

  final DraftNode node;

  /// Live source forwarded to the ending-setup popup so the badge
  /// preview swaps in as soon as generation lands.
  final CreateBloc? bloc;

  /// Offstage steps skip the continue action so a single one mounts.
  final bool active;

  /// Continue action placed at the step's end. Null renders nothing.
  final Widget? continueAction;

  /// Full `Scene M (Title)` target per choice id, shown on the fused
  /// option cards.
  final Map<String, String> targetTitles;
  final bool busy;
  final bool showErrors;
  final bool isRoot;

  /// Every node but the open one: candidates a new zone may point at.
  final List<DraftNode> targets;

  /// Choice id that just gained focus (HotspotAdded), forwarded to the
  /// fused label fields.
  final String? focusChoiceId;
  final void Function(String choiceId, double x, double y)? onZoneMoved;
  final ValueChanged<String>? onZoneAdded;
  final ValueChanged<String>? onZoneRemoved;
  final void Function(String choiceId, String label)? onChoiceLabelChanged;
  final void Function(String choiceId, String icon)? onChoiceIconChanged;
  final void Function(String choiceId, String color)? onChoiceIconColorChanged;

  /// Adds a child under the open node. No affordance for now: the slot
  /// buttons add through [onAddHotspot], so this stays wired for the
  /// standalone action's return.
  final VoidCallback? onAddBranch;

  /// Creates a child on the free branch slot. Null falls back to the
  /// legacy target picker inside the marker.
  final void Function(String slot)? onAddHotspot;

  /// Opens the existing child of an occupied slot. No affordance for
  /// now; stays wired for the shortcut's return.
  final void Function(String targetNodeId)? onOpenChild;

  /// Cuts (or restores) branch [slot] (`A` or `B`), from a long-press on
  /// its add button or cut chip.
  final void Function(String slot)? onCutToggled;

  /// Marks the node final (`true`) or reopens it (`false`). Final nodes
  /// drop their options, so enabling with options asks first.
  final ValueChanged<bool>? onEndingToggled;

  /// Fires when the author picks an ending-type code in the setup popup.
  final ValueChanged<String>? onEndingTypeChanged;

  /// Runs the badge generation from the setup popup; the dialog shows a
  /// loader until the returned future completes.
  final Future<void> Function()? onEndingBadgeRequested;

  /// Deletes the open node. Null while no draft guards apply.
  final VoidCallback? onDelete;

  /// Why the open node cannot be deleted, or null when it can go.
  final String? deleteBlockedReason;

  @override
  State<StepHotspots> createState() => _StepHotspotsState();
}

class _StepHotspotsState extends State<StepHotspots> {
  final GlobalKey _previewKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    // Label errors surface only on demand: while `showErrors` is set,
    // every option whose label is not 1-24 chars flags its fused card.
    final errorIds = widget.showErrors && !node.isEnding
        ? {
            for (final choice in node.choices)
              if (choice.label.trim().isEmpty || choice.label.length > 24)
                choice.choiceId,
          }
        : const <String>{};
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        _HotspotHeader(node: node),
        const SizedBox(height: 8),
        // The HUD always shows: endings keep the preview and swap the
        // option buttons for the final-scene container inside the marker.
        Container(
          key: _previewKey,
          child: ZoneMarker(
            nodeId: node.nodeId,
            bloc: widget.bloc,
            choices: node.choices,
            targets: widget.targets,
            // Options sits after Clip: the backdrop is always the
            // finished clip's last frame, never the start frame.
            frameUrl: node.videoFrameLastUrl,
            busy: widget.busy,
            cutSlots: node.cutSlots,
            isEnding: node.isEnding,
            endingType: node.endingType,
            endingBadgeUrl: node.endingBadgeUrl,
            onEndingTypeChanged: widget.onEndingTypeChanged,
            onEndingBadgeRequested: widget.onEndingBadgeRequested,
            choiceDestinations: widget.targetTitles,
            errorChoiceIds: errorIds,
            focusChoiceId: widget.focusChoiceId,
            onTune: (_) => _scrollToPreview(),
            onAddOption: widget.onAddHotspot,
            onOpenChild: widget.onOpenChild,
            onCutToggled: widget.onCutToggled,
            onZoneMoved: widget.onZoneMoved,
            onZoneAdded: widget.onZoneAdded,
            onZoneRemoved: widget.onZoneRemoved,
            onLabelChanged: widget.onChoiceLabelChanged,
            onIconChanged: widget.onChoiceIconChanged,
            onIconColorChanged: widget.onChoiceIconColorChanged,
          ),
        ),
        if (widget.showErrors && !node.isEnding && node.choices.isEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            '⚠ Add at least one Option to continue',
            style: TextStyle(color: RamificaColors.error, fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        _endingToggle(node),
        // No delete affordance for now: [onDelete] and
        // [deleteBlockedReason] stay wired so the flow can return
        // without touching the bloc or the screen.
        if (widget.active && widget.continueAction != null) ...[
          const SizedBox(height: 16),
          widget.continueAction!,
        ],
      ],
    );
  }

  /// Final-scene toggle at the bottom of Options. Turning it on with
  /// options present asks first: making the node final deletes them.
  Widget _endingToggle(DraftNode node) {
    final setEnding = widget.onEndingToggled;
    // Same gray container as the Add Option buttons above: containerBase
    // fill with a 12px radius. Material (not DecoratedBox): ListTile
    // paints on its nearest Material ancestor, so a DecoratedBox would
    // hide its ink effects and trip a framework assertion.
    return Material(
      color: RamificaColors.containerBase,
      borderRadius: BorderRadius.circular(12),
      child: SwitchListTile(
        key: ValueKey('ending-toggle-${node.nodeId}'),
        title: const Text('Final scene'),
        subtitle: const Text('No options: the story ends here.'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        value: node.isEnding,
        onChanged: setEnding == null
            ? null
            : (value) {
                if (value && node.choices.isNotEmpty) {
                  _confirmMakeFinal(node, setEnding);
                } else {
                  setEnding(value);
                }
              },
      ),
    );
  }

  /// Warns that finalizing deletes [node]'s options before confirming.
  Future<void> _confirmMakeFinal(
    DraftNode node,
    ValueChanged<bool> setEnding,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Make this the final scene?'),
        content: Text(
          'This scene has ${node.choices.length} '
          '${node.choices.length == 1 ? 'option' : 'options'}. '
          'Making it final will delete them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Make final'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) setEnding(true);
  }

  /// Scrolls the hotspot preview into view. Tune buttons call this; the
  /// zone itself is edited by drag on the preview.
  void _scrollToPreview() {
    final context = _previewKey.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 300),
      );
    }
  }
}

/// Suite section header over the scene preview: title plus the live
/// count of placed hotspots.
class _HotspotHeader extends StatelessWidget {
  const _HotspotHeader({required this.node});

  final DraftNode node;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.touch_app, color: RamificaColors.hotspot, size: 20),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Hotspots and Options',
            style: TextStyle(
              fontFamily: RamificaText.display,
              fontWeight: FontWeight.w600,
              fontSize: 18,
              height: 24 / 18,
              color: RamificaColors.textPrimary,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: RamificaColors.containerBase,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: .min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: RamificaColors.hotspot,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${node.choices.length} active hotspots',
                style: RamificaText.caption.copyWith(
                  color: RamificaColors.hotspot,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
