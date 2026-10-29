import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Stitch-style canvas ribbon: status pill + story title with the Simulate
/// and Publish actions on row one; tree-mode toggle and zoom cluster on row
/// two; publish blockers on row three (only when the draft has issues).
/// All copy is final EN — no hold, timing, or tap-to-choose affordances.
class CreateRibbon extends StatelessWidget {
  const CreateRibbon({
    super.key,
    required this.title,
    required this.rootMode,
    required this.onModeChanged,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onRecenter,
    required this.onSimulate,
    required this.onPublish,
    required this.canPublish,
    required this.problems,
    required this.onClose,
  });

  final String title;
  final bool rootMode;
  final ValueChanged<bool> onModeChanged;
  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onRecenter;
  final VoidCallback onSimulate;
  final VoidCallback? onPublish;

  /// Publish CTA enabled exactly when the draft has no missing items and
  /// no job is running.
  final bool canPublish;

  /// Story-level publish blockers shown under the actions. Empty hides
  /// the row entirely.
  final List<String> problems;

  /// Leaves the fullscreen canvas back to Explore.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('ribbon-close'),
              tooltip: 'Back to Create',
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title.isEmpty ? 'Create' : title,
                maxLines: 1,
                overflow: .ellipsis,
                style: RamificaText.headlineSM.copyWith(fontSize: 18),
              ),
            ),
            IconButton(
              onPressed: onSimulate,
              icon: const Icon(Icons.remove_red_eye_rounded),
            ),
            const SizedBox(width: 8),
            _PublishButton(onPressed: canPublish ? onPublish : null),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: RamificaColors.inputFill,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: RamificaColors.outlineVariant),
              ),
              child: Row(
                mainAxisSize: .min,
                children: [
                  _ModeTab(
                    label: 'Full Tree',
                    selected: !rootMode,
                    onTap: () => onModeChanged(false),
                  ),
                  _ModeTab(
                    label: 'Root Mode',
                    selected: rootMode,
                    onTap: () => onModeChanged(true),
                  ),
                ],
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Zoom out',
              onPressed: onZoomOut,
              icon: const Icon(Icons.remove, size: 18),
            ),
            SizedBox(
              width: 52,
              child: Text(
                '${(zoom * 100).round()}%',
                textAlign: .center,
                style: RamificaText.labelSM,
              ),
            ),
            IconButton(
              tooltip: 'Zoom in',
              onPressed: onZoomIn,
              icon: const Icon(Icons.add, size: 18),
            ),
            IconButton(
              key: const ValueKey('ribbon-recenter'),
              tooltip: 'Recenter on root',
              onPressed: onRecenter,
              icon: const Icon(Icons.filter_center_focus, size: 18),
            ),
          ],
        ),
        if (problems.isNotEmpty) ...[
          const SizedBox(height: 8),
          _ProblemsCard(problems: problems),
        ],
      ],
    );
  }
}

/// Story-level publish blockers, Stitch-card styled. Expanded by default
/// so authors see why publishing is gated; the header toggles it shut.
/// Static content only — no timers, animations, or navigation.
class _ProblemsCard extends StatefulWidget {
  const _ProblemsCard({required this.problems});

  final List<String> problems;

  @override
  State<_ProblemsCard> createState() => _ProblemsCardState();
}

class _ProblemsCardState extends State<_ProblemsCard> {
  var _expanded = true;

  @override
  Widget build(BuildContext context) {
    final count = widget.problems.length;
    return Container(
      key: const ValueKey('publish-problems'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: RamificaColors.containerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RamificaColors.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: RamificaColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  count == 1
                      ? '1 issue to publish'
                      : '$count issues to publish',
                  style: RamificaText.labelSM,
                ),
              ),
              IconButton(
                key: const ValueKey('publish-problems-toggle'),
                tooltip: _expanded ? 'Hide issues' : 'Show issues',
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
              ),
            ],
          ),
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 168),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.problems.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(top: 5),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: RamificaColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.problems[index],
                            style: RamificaText.caption.copyWith(
                              color: RamificaColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? RamificaColors.hotspot.withValues(alpha: 0.25)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: RamificaText.labelSM.copyWith(
            color: selected
                ? RamificaColors.textPrimary
                : RamificaColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _PublishButton extends StatelessWidget {
  const _PublishButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: onPressed == null
            ? null
            : const LinearGradient(
                colors: [RamificaColors.nodeActive, RamificaColors.brandViolet],
              ),
      ),
      child: ElevatedButton(
        key: const ValueKey('ribbon-publish'),
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          disabledBackgroundColor: RamificaColors.inputFill,
        ),
        child: const Text('Publish'),
      ),
    );
  }
}
