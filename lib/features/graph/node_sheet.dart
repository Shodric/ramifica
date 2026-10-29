import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/ending_badge.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';
import 'package:ramifica/data/models/graph_stub.dart';

/// Visited node sheet: title, ending badge, per-path share bars, continue
/// and rewind. A locked node shows a lock instead: tapping it plays the
/// visited parent approach.
class NodeSheet extends StatelessWidget {
  const NodeSheet({
    super.key,
    required this.stub,
    required this.stubs,
    required this.isCurrent,
    this.busy = false,
    this.failure,
    required this.onContinue,
    required this.onRewind,
    required this.onApproach,
    required this.onRetry,
    this.onSelectChild,
  });

  final GraphStub stub;
  final List<GraphStub> stubs;
  final bool isCurrent;
  final bool busy;
  final String? failure;
  final VoidCallback onContinue;
  final VoidCallback onRewind;
  final VoidCallback onApproach;
  final VoidCallback onRetry;
  final ValueChanged<String>? onSelectChild;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .start,
        children: [
          if (stub.locked) ...[
            Row(
              children: [
                DecoratedBox(
                  decoration: const BoxDecoration(
                    color: RamificaColors.nodeLocked,
                    shape: .circle,
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(
                      Icons.lock,
                      size: 20,
                      color: RamificaColors.textSecondary,
                      semanticLabel: 'Locked',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Locked path', style: RamificaText.body),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Finish the story around it to unlock this node.',
              style: RamificaText.meta,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : onApproach,
                child: Text(busy ? 'Loading…' : 'Play approach'),
              ),
            ),
          ] else ...[
            const _SheetEyebrow(label: 'Selected scene'),
            const SizedBox(height: 4),
            Text(
              stub.title ?? 'Untitled node',
              maxLines: 2,
              overflow: .ellipsis,
              style: RamificaText.screenTitle.copyWith(
                fontSize: 20,
                height: 26 / 20,
              ),
            ),
            if (stub.isEnding) ...[
              const SizedBox(height: 8),
              EndingBadge(type: stub.endingType),
            ],
            const SizedBox(height: 12),
            ..._consensusBlock(),
            ..._pathRows(context),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _GradientButton(
                    onPressed: onContinue,
                    icon: Icons.play_arrow,
                    label: 'Continue',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onRewind,
                    child: Text(busy ? 'Working…' : 'Rewind'),
                  ),
                ),
              ],
            ),
          ],
          if (failure != null) ...[
            const SizedBox(height: 12),
            FailureText(message: failure!, onRetry: onRetry),
          ],
        ],
      ),
    );
  }

  /// Stitch community-consensus panel from the real per-exit counts.
  /// Labels stay in the rows below, so this shows the top share only.
  List<Widget> _consensusBlock() {
    if (stub.choices.isEmpty) return const [];
    var sum = 0;
    var top = 0;
    for (final exit in stub.choices) {
      sum += exit.count;
      if (exit.count > top) top = exit.count;
    }
    if (sum <= 0) return const [];
    final percent = (top / sum * 100).round();
    return [
      Container(
        decoration: BoxDecoration(
          color: RamificaColors.containerLowest,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(
                  Icons.group,
                  size: 14,
                  color: RamificaColors.nodeActive,
                  semanticLabel: 'Community',
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('Community consensus', style: RamificaText.meta),
                ),
                Text(
                  '$percent%',
                  style: RamificaText.labelSM.copyWith(
                    color: RamificaColors.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: SizedBox(
                height: 8,
                child: Row(
                  children: [
                    Expanded(
                      flex: top,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              RamificaColors.hotspot,
                              RamificaColors.nodeActive,
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (sum > top)
                      Expanded(
                        flex: sum - top,
                        child: Container(
                          color: RamificaColors.containerHighest,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _pathRows(BuildContext context) {
    final byId = {for (final node in stubs) node.nodeId: node};
    if (stub.choices.isNotEmpty) {
      return _choiceRows(byId);
    }
    final children = [
      for (final id in stub.childIds)
        if (byId.containsKey(id)) byId[id]!,
    ];
    if (children.isEmpty) {
      return const [
        Text('No paths leave this node.', style: RamificaText.meta),
      ];
    }
    return [
      for (final child in children)
        _PathRow(
          label: child.title ?? 'Secret path',
          locked: child.locked,
          onTap: onSelectChild == null
              ? null
              : () => onSelectChild!(child.nodeId),
        ),
    ];
  }

  /// Share bars from the parent's own per-exit counts. `choices[i]`
  /// targets `childIds[i]`; the child stub supplies the lock mark and
  /// the tap destination.
  List<Widget> _choiceRows(Map<String, GraphStub> byId) {
    var sum = 0;
    for (final exit in stub.choices) {
      sum += exit.count;
    }
    if (sum <= 0) {
      return const [Text('No plays yet.', style: RamificaText.meta)];
    }
    return [
      for (var i = 0; i < stub.choices.length; i++)
        _PathRow(
          label: _exitLabel(stub.choices[i], _childAt(byId, i)),
          locked: _childAt(byId, i)?.locked ?? false,
          count: stub.choices[i].count,
          sum: sum,
          onTap: _exitTap(byId, i),
        ),
    ];
  }

  /// The child a choice row points at, via the shared choices order.
  GraphStub? _childAt(Map<String, GraphStub> byId, int index) {
    if (index >= stub.childIds.length) return null;
    return byId[stub.childIds[index]];
  }

  /// The choice label, falling back to the child title for old stubs.
  String _exitLabel(GraphChoice exit, GraphStub? child) {
    if (exit.label.isNotEmpty) return exit.label;
    return child?.title ?? 'Secret path';
  }

  /// Taps select the child; locked children play their approach.
  VoidCallback? _exitTap(Map<String, GraphStub> byId, int index) {
    if (onSelectChild == null) return null;
    final child = _childAt(byId, index);
    if (child == null) return null;
    return () => onSelectChild!(child.nodeId);
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({
    required this.label,
    required this.locked,
    this.count,
    this.sum,
    this.onTap,
  });

  final String label;
  final bool locked;
  final int? count;
  final int? sum;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final count = this.count;
    final sum = this.sum;
    final double? share;
    if (count != null && sum != null && sum > 0) {
      share = count / sum;
    } else {
      share = null;
    }
    final percent = share == null ? 0 : (share * 100).round();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Row(
              children: [
                if (locked)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.lock,
                      size: 14,
                      color: RamificaColors.textSecondary,
                      semanticLabel: 'Locked',
                    ),
                  ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: RamificaText.label,
                  ),
                ),
                if (share != null) ...[
                  const SizedBox(width: 8),
                  Text('$count/$sum ($percent%)', style: RamificaText.meta),
                ],
              ],
            ),
            if (share != null) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: .circular(999),
                child: LinearProgressIndicator(
                  value: share,
                  minHeight: 6,
                  backgroundColor: RamificaColors.nodeLocked,
                  valueColor: const AlwaysStoppedAnimation(
                    RamificaColors.nodeActive,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SheetEyebrow extends StatelessWidget {
  const _SheetEyebrow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: RamificaColors.hotspot,
            shape: .circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontFamily: RamificaText.sans,
            fontWeight: FontWeight.w700,
            fontSize: 10,
            height: 14 / 10,
            letterSpacing: 0.8,
            color: RamificaColors.onPrimaryContainer,
          ),
        ),
      ],
    );
  }
}

/// Stitch gradient playback CTA. Static: no timers, no motion.
class _GradientButton extends StatelessWidget {
  const _GradientButton({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [RamificaColors.hotspot, RamificaColors.nodeActive],
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: .center,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: RamificaColors.onSecondary,
                  semanticLabel: label,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: RamificaText.label.copyWith(
                    color: RamificaColors.onSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
