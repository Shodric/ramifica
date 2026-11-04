import 'package:ramifica/data/models/draft_node.dart';

/// Author fields a save may merge. Pipeline media stays out.
///
/// When [storedText] differs from the line, the stored voice is idled:
/// it still speaks the old words. Approval flags (`lineApproved`,
/// `ttsApproved`, `startImageApproved`) are ignored
/// legacy and are never written here.
Map<String, dynamic> nodeSavePatch(DraftNode node, String storedText) {
  String? clean(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  final fields = <String, dynamic>{
    'title': node.title.trim(),
    'visibility': node.visibility,
    'isEnding': node.isEnding,
    'endingType': clean(node.endingType),
    'endingBadgeUrl': clean(node.endingBadgeUrl),
    'ttsText': node.ttsText.trim(),
    'choices': [for (final choice in node.choices) choice.toJson()],
    'cutSlots': [
      for (final slot in const ['A', 'B'])
        if (node.cutSlots.contains(slot)) slot,
    ],
    'startImagePrompt': clean(node.startImagePrompt),
    'startImageReferenceUrl': clean(node.startImageReferenceUrl),
    'videoPrompt': clean(node.videoPrompt),
    'sceneDirection': clean(node.sceneDirection),
  };
  if (fields['ttsText'] != storedText) {
    fields['ttsStatus'] = 'idle';
    fields['ttsAudioUrl'] = null;
    fields['ttsDurationSeconds'] = null;
  }
  return fields;
}
