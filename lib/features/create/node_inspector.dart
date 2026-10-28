import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';

/// Inspector for the open draft node: manual editing fields, the
/// per-node [StatusPill], and what is missing for publish.
///
/// Manual editing is the point. Every keystroke writes bloc state through
/// the callbacks; nothing reaches the server until [onSave]. Controllers
/// resync from [node] only when the text differs (a proposal or a
/// reload), so typing never loses its caret: the bloc echoes each
/// keystroke back unchanged.
class NodeInspector extends StatefulWidget {
  const NodeInspector({
    super.key,
    required this.node,
    required this.status,
    required this.missing,
    this.busy = false,
    this.onTitleChanged,
    this.onLineChanged,
    this.onChoiceLabelChanged,
    this.onVisibilityChanged,
    this.onSave,
    this.onGenerate,
    this.onRegenerate,
  });

  final DraftNode node;
  final StatusPillState status;
  final List<String> missing;

  /// A save or generation is in flight: fields and buttons disable.
  final bool busy;

  final ValueChanged<String>? onTitleChanged;
  final ValueChanged<String>? onLineChanged;
  final void Function(String choiceId, String label)? onChoiceLabelChanged;
  final ValueChanged<String>? onVisibilityChanged;
  final VoidCallback? onSave;
  final VoidCallback? onGenerate;
  final VoidCallback? onRegenerate;

  @override
  State<NodeInspector> createState() => _NodeInspectorState();
}

class _NodeInspectorState extends State<NodeInspector> {
  late final TextEditingController _title = TextEditingController(
    text: widget.node.title,
  );
  late final TextEditingController _line = TextEditingController(
    text: widget.node.ttsText,
  );
  final Map<String, TextEditingController> _labels = {};

  @override
  void initState() {
    super.initState();
    _syncLabels(force: true);
  }

  @override
  void didUpdateWidget(covariant NodeInspector old) {
    super.didUpdateWidget(old);
    if (old.node.nodeId != widget.node.nodeId) {
      _title.text = widget.node.title;
      _line.text = widget.node.ttsText;
      _syncLabels(force: true);
    } else {
      _setIfDifferent(_title, widget.node.title);
      _setIfDifferent(_line, widget.node.ttsText);
      _syncLabels();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _line.dispose();
    for (final controller in _labels.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  node.title.trim().isEmpty ? '(untitled)' : node.title,
                  style: RamificaText.label,
                  maxLines: 1,
                  overflow: .ellipsis,
                ),
              ),
              StatusPill(status: widget.status),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: ValueKey('title-${node.nodeId}'),
            controller: _title,
            enabled: !widget.busy,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Title',
              hintText: 'The temple door',
            ),
            onChanged: widget.onTitleChanged,
          ),
          const SizedBox(height: 8),
          TextField(
            key: ValueKey('line-${node.nodeId}'),
            controller: _line,
            enabled: !widget.busy,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Narrator line',
              hintText: 'What should they do next?',
            ),
            onChanged: widget.onLineChanged,
          ),
          for (final choice in node.choices) ...[
            const SizedBox(height: 8),
            TextField(
              key: ValueKey('choice-${choice.choiceId}'),
              controller: _labels[choice.choiceId],
              enabled: !widget.busy,
              maxLength: 24,
              decoration: const InputDecoration(
                labelText: 'Choice',
                hintText: 'Enter the temple',
              ),
              onChanged: (label) =>
                  widget.onChoiceLabelChanged?.call(choice.choiceId, label),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Secret', style: RamificaText.meta),
              const SizedBox(width: 8),
              Switch(
                value: node.secret,
                onChanged: widget.busy
                    ? null
                    : (secret) => widget.onVisibilityChanged?.call(
                        secret ? 'secret' : 'visible',
                      ),
              ),
            ],
          ),
          if (widget.missing.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final item in widget.missing)
              Padding(
                padding: const .symmetric(vertical: 2),
                child: Text(item, style: RamificaText.meta),
              ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: widget.busy ? null : widget.onSave,
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.busy ? null : widget.onGenerate,
                  child: const Text('Spark'),
                ),
              ),
              TextButton(
                onPressed: widget.busy ? null : widget.onRegenerate,
                child: const Text('Regenerate'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Choice label controllers follow the choice list: new choices get a
  /// controller, removed ones are disposed. Values resync only when the
  /// text differs, so typing keeps its caret.
  void _syncLabels({bool force = false}) {
    final ids = {for (final choice in widget.node.choices) choice.choiceId};
    for (final id in _labels.keys.toList()) {
      if (!ids.contains(id)) _labels.remove(id)?.dispose();
    }
    for (final choice in widget.node.choices) {
      final controller = _labels.putIfAbsent(
        choice.choiceId,
        () => TextEditingController(text: choice.label),
      );
      if (force || controller.text != choice.label) {
        controller.text = choice.label;
      }
    }
  }
}

void _setIfDifferent(TextEditingController controller, String value) {
  if (controller.text != value) controller.text = value;
}
