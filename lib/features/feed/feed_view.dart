import 'package:flutter/material.dart';

class FeedView extends StatelessWidget {
  const FeedView({super.key, this.storyId});

  final String? storyId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Semantics(
        label: storyId == null ? 'Feed' : 'Feed $storyId',
        child: const Center(child: Text('Feed')),
      ),
    );
  }
}
