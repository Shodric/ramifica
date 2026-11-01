import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/create_node_card.dart';

import 'clip_preview.dart';

/// Opens the Simulate preview for the open node. Plays the node's video
/// (or shows its end image) with the choice labels listed statically.
/// Nothing is committed, no run is created, no state changes, no timers.
Future<void> showCreatePreview(
  BuildContext context, {
  required DraftNode? node,
}) {
  return showDialog(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: RamificaColors.surface,
      child: CreatePreview(node: node),
    ),
  );
}

/// Read-only node preview dialog. Dismisses on tap outside or the close
/// button. When the node has no media, an empty-state box shows instead
/// of erroring.
class CreatePreview extends StatefulWidget {
  const CreatePreview({super.key, required this.node});

  final DraftNode? node;

  @override
  State<CreatePreview> createState() => _CreatePreviewState();
}

class _CreatePreviewState extends State<CreatePreview> {
  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final title = (node?.title.trim().isEmpty ?? true)
        ? '(untitled)'
        : node!.title.trim();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360, maxHeight: 560),
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Preview — $title',
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: RamificaText.labelSM,
                  ),
                ),
                IconButton(
                  tooltip: 'Close preview',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Flexible(child: _media(node)),
          if (node != null && !node.isEnding && node.choices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: .start,
                mainAxisSize: .min,
                children: [
                  Text(
                    'Choices',
                    style: RamificaText.caption.copyWith(
                      color: RamificaColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (var i = 0; i < node.choices.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${String.fromCharCode(65 + i)}. ${node.choices[i].label}',
                        style: RamificaText.bodySM,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _media(DraftNode? node) {
    final url = node?.videoUrl;
    if (url != null && url.isNotEmpty) {
      return ClipPreview(
        url: url,
        width: node?.videoWidth,
        height: node?.videoHeight,
        durationSeconds: node?.durationSeconds,
      );
    }
    final image = node?.endImageSourceUrl;
    if (image != null && image.isNotEmpty) {
      return CreateNodeThumb(url: image, iconSize: 32);
    }
    return SizedBox(
      height: 160,
      child: Center(
        child: Text(
          node == null ? 'No scene selected' : 'No media yet for $node',
          style: RamificaText.bodySM.copyWith(
            color: RamificaColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
