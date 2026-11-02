import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';

/// Opens the fullscreen story settings: name, description, and key-art
/// cover generation. Name and description dispatch [StoryFieldChanged] as
/// they are typed; Save persists through [StorySaved] and closes on
/// success. Fullscreen so the cover preview reads at full width.
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
/// generates server-side and lands on the story when ready.
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

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: BlocBuilder<CreateBloc, CreateState>(
          builder: (context, state) {
            final busy = state.savingStory || state.generatingCover;
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
                          style: RamificaText.label,
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
                    decoration: _settingsInputDecoration(
                      labelText: 'Cover prompt (optional)',
                      hintText: 'A lighthouse at dawn…',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const ValueKey('story-settings-generate-cover'),
                    onPressed: busy ? null : _generate,
                    icon: state.generatingCover
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome, size: 18),
                    label: Text(
                      state.generatingCover ? 'Generating…' : 'Generate cover',
                    ),
                  ),
                  if (state.failure != null && !busy) ...[
                    const SizedBox(height: 8),
                    FailureText(message: state.failure!, onRetry: _generate),
                  ],
                ],
              ),
            );
          },
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
