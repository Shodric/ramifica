import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Photo, name, handle, and whether the person already follows. Explore and
/// Profile share it. Read-only: the follow state is display only, there is
/// no follow action. Tapping the row navigates via [onOpen]. No bloc, no
/// router, no repository.
class AuthorRow extends StatelessWidget {
  const AuthorRow({
    super.key,
    required this.name,
    required this.handle,
    required this.isFollowing,
    this.photoUrl,
    this.onOpen,
  });

  final String name;
  final String handle;
  final bool isFollowing;
  final String? photoUrl;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Author $name',
      button: onOpen != null,
      child: GestureDetector(
        onTap: onOpen,
        behavior: .opaque,
        child: Row(
          children: [
            _Avatar(photoUrl: photoUrl, name: name),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                mainAxisSize: .min,
                children: [
                  Text(
                    name,
                    style: RamificaText.label,
                    maxLines: 1,
                    overflow: .ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    handle,
                    style: RamificaText.meta,
                    maxLines: 1,
                    overflow: .ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              isFollowing ? 'Following' : 'Follow',
              style: RamificaText.meta.copyWith(
                color: isFollowing
                    ? RamificaColors.textSecondary
                    : RamificaColors.hotspot,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.photoUrl, required this.name});

  final String? photoUrl;
  final String name;

  @override
  Widget build(BuildContext context) {
    final uri = photoUrl?.trim();
    if (uri == null || uri.isEmpty) {
      return const CircleAvatar(
        radius: 20,
        backgroundColor: RamificaColors.nodeLocked,
        child: Icon(Icons.person, size: 20, color: RamificaColors.textPrimary),
      );
    }
    return CircleAvatar(
      radius: 20,
      backgroundColor: RamificaColors.nodeLocked,
      backgroundImage: NetworkImage(uri),
      onBackgroundImageError: (_, _) {},
    );
  }
}
