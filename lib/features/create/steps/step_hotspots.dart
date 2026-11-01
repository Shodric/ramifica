import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/zone_marker.dart';

/// S3 Options: hotspot header, the [ZoneMarker] preview, one card per
/// option, the add-option action, and the red delete at the end (non-root
/// only). Zones persist with the scene Save button or generation; there is no
/// separate Save zones button. [showErrors] flags options whose label is
/// not 1-24 characters.
class StepHotspots extends StatefulWidget {
  const StepHotspots({
    super.key,
    required this.node,
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
    this.onDelete,
    this.deleteBlockedReason,
  });

  final DraftNode node;

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

  /// Adds a child under the open node. Null hides the action.
  final VoidCallback? onAddBranch;

  /// Creates a child on the free branch slot. Null falls back to the
  /// legacy target picker inside the marker.
  final void Function(String slot)? onAddHotspot;

  /// Opens the existing child of an occupied slot. Null hides the
  /// `Option X ✓` shortcuts.
  final void Function(String targetNodeId)? onOpenChild;

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
        if (node.isEnding)
          const Text(
            'Endings have no Options, so there are no zones.',
            style: RamificaText.meta,
          )
        else
          Container(
            key: _previewKey,
            child: ZoneMarker(
              nodeId: node.nodeId,
              choices: node.choices,
              targets: widget.targets,
              endImageUrl: node.endImageSourceUrl,
              busy: widget.busy,
              choiceDestinations: widget.targetTitles,
              errorChoiceIds: errorIds,
              focusChoiceId: widget.focusChoiceId,
              onTune: (_) => _scrollToPreview(),
              onAddOption: widget.onAddHotspot,
              onOpenChild: widget.onOpenChild,
              onZoneMoved: widget.onZoneMoved,
              onZoneAdded: widget.onZoneAdded,
              onZoneRemoved: widget.onZoneRemoved,
              onLabelChanged: widget.onChoiceLabelChanged,
              onIconChanged: widget.onChoiceIconChanged,
              onIconColorChanged: widget.onChoiceIconColorChanged,
            ),
          ),
        if (widget.showErrors && !node.isEnding && node.choices.isEmpty) ...[
          const SizedBox(height: 4),
          const Text(
            '⚠ Add at least one Option to continue',
            style: TextStyle(color: RamificaColors.error, fontSize: 12),
          ),
        ],
        const SizedBox(height: 24),
        _AddOptionButton(busy: widget.busy, onAddBranch: widget.onAddBranch),
        if (!widget.isRoot) ...[
          const SizedBox(height: 24),
          _DeleteNode(
            node: node,
            busy: widget.busy,
            onDelete: widget.onDelete,
            deleteBlockedReason: widget.deleteBlockedReason,
          ),
        ],
      ],
    );
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

/// Standalone add-branch button. Same event as the canvas mini; the author
/// opens the new scene from the canvas.
class _AddOptionButton extends StatelessWidget {
  const _AddOptionButton({required this.busy, required this.onAddBranch});

  final bool busy;
  final VoidCallback? onAddBranch;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: busy ? null : onAddBranch,
        style: FilledButton.styleFrom(
          backgroundColor: RamificaColors.containerBase,
          foregroundColor: RamificaColors.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: const Row(
          mainAxisAlignment: .center,
          mainAxisSize: .min,
          children: [
            Icon(Icons.add_circle, size: 20, color: RamificaColors.hotspot),
            SizedBox(width: 8),
            Text('Add Option (+)', style: RamificaText.label),
          ],
        ),
      ),
    );
  }
}

/// Full-width red delete at the end of the options step. The caller skips
/// it on the root (which can never be deleted). Tapping asks for
/// confirmation first; the reason explains a disabled button on
/// targeted nodes.
class _DeleteNode extends StatelessWidget {
  const _DeleteNode({
    required this.node,
    required this.busy,
    required this.onDelete,
    required this.deleteBlockedReason,
  });

  final DraftNode node;
  final bool busy;
  final VoidCallback? onDelete;
  final String? deleteBlockedReason;

  @override
  Widget build(BuildContext context) {
    final blocked = busy || deleteBlockedReason != null;
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        if (deleteBlockedReason != null)
          Text(deleteBlockedReason!, style: RamificaText.meta),
        if (deleteBlockedReason != null) const SizedBox(height: 4),
        SizedBox(
          height: 48,
          width: double.infinity,
          child: FilledButton(
            key: ValueKey('delete-node-${node.nodeId}'),
            onPressed: blocked ? null : () => _confirmDelete(context),
            style: FilledButton.styleFrom(
              backgroundColor: RamificaColors.danger,
              foregroundColor: RamificaColors.textPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Delete scene'),
          ),
        ),
      ],
    );
  }

  /// Delete confirmation for a non-root node. Confirming calls
  /// [onDelete]; dismissing does nothing.
  Future<void> _confirmDelete(BuildContext context) async {
    final title = node.title.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this scene?'),
        content: Text(
          title.isEmpty
              ? 'This cannot be undone.'
              : 'Delete "$title"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: ValueKey('confirm-delete-${node.nodeId}'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              'Delete',
              style: TextStyle(color: RamificaColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) onDelete?.call();
  }
}
