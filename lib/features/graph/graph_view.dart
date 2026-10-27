import 'package:flutter/material.dart';

class GraphView extends StatelessWidget {
  const GraphView({super.key, required this.storyId});

  final String storyId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Semantics(
        label: 'Map $storyId',
        child: const Center(child: Text('Map')),
      ),
    );
  }
}
