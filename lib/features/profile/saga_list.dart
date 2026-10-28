import 'package:flutter/material.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/lock_mark.dart';
import 'package:ramifica/core/widgets/story_card.dart';

/// One saga entry in order. The owner assembles the list from the
/// `sagas/{sagaId}` doc (ordered `storyIds`) plus the viewer's own
/// `storyState`: `unlocked` is true for the entry story or when that
/// story's `sagaUnlocked` flag is set. A locked entry carries no title:
/// rendering it must never leak one (like map locks).
class SagaStory {
  const SagaStory({required this.storyId, required this.unlocked, this.title, this.coverUrl, this.authorName});

  /// The story to open on tap (`/story/{storyId}`).
  final String storyId;

  /// True while the row opens: the entry story or an unlocked sequel.
  final bool unlocked;

  /// Shown only when [unlocked]; stays null for locked entries.
  final String? title;

  final String? coverUrl;
  final String? authorName;
}

/// Ordered saga stories. Unlocked rows render a [StoryCard] (cover,
/// title, author); tapping one reports its story id through [onOpen]
/// and the owner navigates to Feed. Locked rows render only a
/// [LockMark]: no title, no nodes, no tap. Pure: data in via params,
/// actions out via callback. No bloc, no router, no repository, and
/// no reward display (rewards are write-only here). Empty shows text
/// only, no CTA.
class SagaList extends StatelessWidget {
  const SagaList({super.key, required this.stories, required this.onOpen});

  final List<SagaStory> stories;

  /// Called with the tapped story's [SagaStory.storyId]. Locked rows
  /// never call it.
  final void Function(String storyId) onOpen;

  @override
  Widget build(BuildContext context) {
    if (stories.isEmpty) {
      return const EmptyState(message: 'No saga stories yet.');
    }
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        for (var i = 0; i < stories.length; i++) ...[
          if (stories[i].unlocked)
            _OpenRow(story: stories[i], onOpen: () => onOpen(stories[i].storyId))
          else
            const _LockedRow(),
          if (i != stories.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _OpenRow extends StatelessWidget {
  const _OpenRow({required this.story, required this.onOpen});

  final SagaStory story;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return StoryCard(
      title: story.title ?? story.storyId,
      authorName: story.authorName ?? '',
      coverUrl: story.coverUrl,
      onOpen: onOpen,
    );
  }
}

class _LockedRow extends StatelessWidget {
  const _LockedRow();

  @override
  Widget build(BuildContext context) {
    return Semantics(label: 'Locked story', child: const Row(children: [LockMark()]));
  }
}
