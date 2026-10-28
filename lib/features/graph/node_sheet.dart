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
            ..._pathRows(context),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onRewind,
                    child: Text(busy ? 'Working…' : 'Rewind'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: onContinue,
                    child: const Text('Continue'),
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
      return const [
        Text('No plays yet.', style: RamificaText.meta),
      ];
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
                  Text(
                    '$count/$sum ($percent%)',
                    style: RamificaText.meta,
                  ),
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
