import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';

/// Opens the fullscreen story settings: name, description, key-art cover
/// generation, and the story actions (Hide when published, Delete for
/// drafts — both behind a confirmation in the unsaved-changes shape).
/// Name and description dispatch [StoryFieldChanged] as they are typed;
/// Save persists through [StorySaved] and closes on success. Fullscreen
/// so the cover preview reads at full width.
Future<void> showStorySettings(BuildContext context) {
  final bloc = context.read<CreateBloc>();
  return showDialog(
    context: context,
    builder: (_) => Dialog.fullscreen(
      backgroundColor: RamificaColors.surface,
      child: BlocProvider.value(
        value: bloc,
        child: const StorySettingsDialog(),
      ),
    ),
  );
}

/// Story settings dialog. Fields stay local until Save; the cover
/// generates server-side and lands on the story when ready. Delete pops
/// the dialog once the bloc marks [CreateState.deletedStoryId].
class StorySettingsDialog extends StatefulWidget {
  const StorySettingsDialog({super.key});

  @override
  State<StorySettingsDialog> createState() => _StorySettingsDialogState();
}

class _StorySettingsDialogState extends State<StorySettingsDialog> {
  late final TextEditingController _title;
  late final TextEditingController _synopsis;
  final _coverPrompt = TextEditingController();

  @override
  void initState() {
    super.initState();
    final story = context.read<CreateBloc>().state.story;
    _title = TextEditingController(text: story?.title ?? '');
    _synopsis = TextEditingController(text: story?.synopsis ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _synopsis.dispose();
    _coverPrompt.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final bloc = context.read<CreateBloc>();
    final completion = Completer<bool>();
    bloc.add(StorySaved(completion: completion));
    final saved = await completion.future;
    if (saved && mounted) Navigator.of(context).pop();
  }

  void _generate() {
    final prompt = _coverPrompt.text.trim();
    context.read<CreateBloc>().add(
      CoverGenerateRequested(prompt: prompt.isEmpty ? null : prompt),
    );
  }

  /// Confirmation in the unsaved-changes shape: neutral Cancel plus one
  /// confirming action; destructive confirms carry the danger ink.
  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    required String confirmKey,
    bool destructive = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            key: const ValueKey('confirm-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          if (destructive)
            TextButton(
              key: ValueKey(confirmKey),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                confirmLabel,
                style: TextStyle(color: RamificaColors.danger),
              ),
            )
          else
            FilledButton(
              key: ValueKey(confirmKey),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(confirmLabel),
            ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _hide() async {
    final confirmed = await _confirm(
      title: 'Hide story',
      message:
          'Players lose access: the story leaves the catalog and '
          'returns to draft. You can publish it again.',
      confirmLabel: 'Hide story',
      confirmKey: 'confirm-hide-story',
    );
    if (confirmed && mounted) {
      context.read<CreateBloc>().add(const StoryUnpublished());
    }
  }

  Future<void> _delete() async {
    final confirmed = await _confirm(
      title: 'Delete story',
      message:
          'This permanently deletes the draft and its scenes. '
          'This cannot be undone.',
      confirmLabel: 'Delete story',
      confirmKey: 'confirm-delete-story',
      destructive: true,
    );
    if (confirmed && mounted) {
      context.read<CreateBloc>().add(const StoryDeleted());
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<CreateBloc, CreateState>(
      listenWhen: (previous, next) =>
          previous.deletedStoryId != next.deletedStoryId &&
          next.deletedStoryId != null,
      listener: (context, state) {
        if (state.deletedStoryId == null) return;
        if (mounted) Navigator.of(context).pop();
      },
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: BlocBuilder<CreateBloc, CreateState>(
            builder: (context, state) {
              final busy = state.savingStory || state.generatingCover;
              final published = state.story?.status == 'published';
              // No scroll: everything fits the fullscreen dialog and the
              // preview takes the leftover height.
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: .stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          key: const ValueKey('close-story-settings'),
                          tooltip: 'Close settings',
                          onPressed: busy
                              ? null
                              : () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close, size: 20),
                        ),
                        const Expanded(
                          child: Text(
                            'Story settings',
                            style: RamificaText.headlineSM,
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('story-settings-save'),
                          tooltip: 'Save settings',
                          onPressed: busy ? null : _save,
                          icon: state.savingStory
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('story-settings-title'),
                      controller: _title,
                      maxLength: 40,
                      style: RamificaText.bodySM,
                      decoration: _settingsInputDecoration(
                        labelText: 'Name',
                        hintText: 'Untitled story',
                      ),
                      onChanged: (value) => context.read<CreateBloc>().add(
                        StoryFieldChanged(title: value),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('story-settings-synopsis'),
                      controller: _synopsis,
                      minLines: 3,
                      maxLines: 5,
                      style: RamificaText.bodySM,
                      decoration: _settingsInputDecoration(
                        labelText: 'Description',
                        hintText: 'What is this story about?',
                      ),
                      onChanged: (value) => context.read<CreateBloc>().add(
                        StoryFieldChanged(synopsis: value),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Cover', style: RamificaText.labelSM),
                    const SizedBox(height: 8),
                    Expanded(child: _CoverPreview(url: state.story?.coverUrl)),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('story-settings-cover-prompt'),
                      controller: _coverPrompt,
                      minLines: 2,
                      maxLines: 2,
                      style: RamificaText.bodySM,
                      decoration: _settingsInputDecoration(
                        labelText: 'Cover prompt (optional)',
                        hintText: 'A lighthouse at dawn…',
                      ),
                    ),
                    const SizedBox(height: 8),
                    // The cover action reads like the wizard Continue:
                    // one full-width rectangular filled button.
                    SizedBox(
                      height: 48,
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('story-settings-generate-cover'),
                        onPressed: busy ? null : _generate,
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: state.generatingCover
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_awesome, size: 18),
                        label: Text(
                          state.generatingCover
                              ? 'Generating…'
                              : 'Generate cover',
                        ),
                      ),
                    ),
                    if (state.failure != null && !busy) ...[
                      const SizedBox(height: 8),
                      FailureText(message: state.failure!, onRetry: _generate),
                    ],
                    const SizedBox(height: 16),
                    const Divider(
                      height: 1,
                      color: RamificaColors.outlineVariant,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          published ? 'Published' : 'Draft',
                          style: RamificaText.meta,
                        ),
                        const Spacer(),
                        if (published)
                          OutlinedButton.icon(
                            key: const ValueKey('story-settings-hide'),
                            onPressed: busy ? null : _hide,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: RamificaColors.textPrimary,
                              side: const BorderSide(
                                color: RamificaColors.glassBorder,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(
                              Icons.visibility_off_outlined,
                              size: 18,
                            ),
                            label: const Text('Hide'),
                          )
                        else
                          OutlinedButton.icon(
                            key: const ValueKey('story-settings-delete'),
                            onPressed: busy ? null : _delete,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: RamificaColors.danger,
                              side: const BorderSide(
                                color: RamificaColors.glassBorder,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('Delete'),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Current key art, or the empty placeholder when no cover exists yet.
/// The image always fits whole inside the area (`contain`), never cropped.
class _CoverPreview extends StatelessWidget {
  const _CoverPreview({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: RamificaColors.inputFill,
        width: double.infinity,
        child: url == null || url!.isEmpty
            ? const Icon(
                Icons.image_outlined,
                size: 32,
                color: RamificaColors.textSecondary,
              )
            : Image.network(
                url!,
                fit: .contain,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  size: 32,
                  color: RamificaColors.textSecondary,
                ),
              ),
      ),
    );
  }
}

InputDecoration _settingsInputDecoration({
  required String labelText,
  required String hintText,
}) {
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    filled: true,
    fillColor: RamificaColors.inputFill,
    isDense: true,
    enabledBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: RamificaColors.inputBorder,
    ),
    focusedBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: RamificaColors.inputFocusedBorder,
    ),
  );
}
