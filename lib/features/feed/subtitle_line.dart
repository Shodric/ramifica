import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// The narrator line, drawn while the clip is muted. Two lines at most.
class SubtitleLine extends StatelessWidget {
  const SubtitleLine({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 2,
      overflow: .ellipsis,
      textAlign: .center,
      style: RamificaText.overVideo(RamificaText.body),
    );
  }
}
