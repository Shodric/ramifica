import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// View-mode profile header: avatar, name, handle, locale badge, the
/// own-only following count, and the foreign-only follow button.
///
/// Pure view of bloc state: follow taps leave through [onFollowToggle],
/// which the view wires to `FollowToggled`. No bloc, no repository.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    this.displayName,
    this.handle,
    this.photoUrl,
    required this.locale,
    required this.isOwn,
    required this.isFollowing,
    this.followingCount,
    this.toggling = false,
    this.onFollowToggle,
  });

  final String? displayName;
  final String? handle;
  final String? photoUrl;
  final String locale;
  final bool isOwn;
  final bool isFollowing;
  final int? followingCount;
  final bool toggling;
  final VoidCallback? onFollowToggle;

  @override
  Widget build(BuildContext context) {
    final name = _titleOf(displayName, handle);
    final tag = handle?.trim() ?? '';
    final area = locale.trim();
    return Semantics(
      label: isOwn ? 'Your profile' : 'Author $name',
      child: Row(
        crossAxisAlignment: .start,
        children: [
          _Avatar(photoUrl: photoUrl, name: name),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              mainAxisSize: .min,
              children: [
                Text(
                  name,
                  style: RamificaText.label,
                  maxLines: 2,
                  overflow: .ellipsis,
                ),
                if (tag.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '@$tag',
                    style: RamificaText.meta,
                    maxLines: 1,
                    overflow: .ellipsis,
                  ),
                ],
                if (area.isNotEmpty || followingCount != null) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: .center,
                    children: [
                      if (area.isNotEmpty) _LocaleBadge(locale: area),
                      if (followingCount != null)
                        Text(
                          '$followingCount following',
                          style: RamificaText.meta,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (!isOwn) ...[
            const SizedBox(width: 12),
            FilledButton(
              key: const Key('profileFollowButton'),
              onPressed: toggling ? null : onFollowToggle,
              child: Text(isFollowing ? 'Following' : 'Follow'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Foreign profiles may load minimal (names null under owner-only reads),
/// so the title falls back from name to handle to a placeholder.
String _titleOf(String? displayName, String? handle) {
  final name = displayName?.trim() ?? '';
  if (name.isNotEmpty) return name;
  final tag = handle?.trim() ?? '';
  if (tag.isNotEmpty) return '@$tag';
  return 'Unknown author';
}

class _LocaleBadge extends StatelessWidget {
  const _LocaleBadge({required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const .symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: .all(color: RamificaColors.glassBorder),
        borderRadius: .circular(999),
      ),
      child: Text(
        locale,
        style: RamificaText.meta.copyWith(color: RamificaColors.textSecondary),
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
    final uri = photoUrl?.trim() ?? '';
    if (uri.isEmpty) {
      return const CircleAvatar(
        radius: 28,
        backgroundColor: RamificaColors.nodeLocked,
        child: Icon(Icons.person, size: 28, color: RamificaColors.textPrimary),
      );
    }
    return CircleAvatar(
      radius: 28,
      backgroundColor: RamificaColors.nodeLocked,
      backgroundImage: NetworkImage(uri),
      onBackgroundImageError: (_, _) {},
    );
  }
}

/// Own-profile editor: the four writable fields plus save and cancel.
/// Save leaves through [onSave]; the bloc owns validation and persistence.
/// A save failure arrives back in [failure] and stays visible in the form.
class ProfileEditForm extends StatefulWidget {
  const ProfileEditForm({
    super.key,
    this.initialDisplayName,
    this.initialHandle,
    this.initialPhotoUrl,
    required this.initialLocale,
    this.saving = false,
    this.failure,
    this.onSave,
    this.onCancel,
  });

  final String? initialDisplayName;
  final String? initialHandle;
  final String? initialPhotoUrl;
  final String initialLocale;
  final bool saving;
  final String? failure;
  final void Function({
    required String displayName,
    required String handle,
    required String photoUrl,
    required String locale,
  })?
  onSave;
  final VoidCallback? onCancel;

  @override
  State<ProfileEditForm> createState() => _ProfileEditFormState();
}

class _ProfileEditFormState extends State<ProfileEditForm> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialDisplayName ?? '',
  );
  late final TextEditingController _handle = TextEditingController(
    text: widget.initialHandle ?? '',
  );
  late final TextEditingController _photo = TextEditingController(
    text: widget.initialPhotoUrl ?? '',
  );
  late final TextEditingController _locale = TextEditingController(
    text: widget.initialLocale,
  );

  @override
  void dispose() {
    _name.dispose();
    _handle.dispose();
    _photo.dispose();
    _locale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        TextField(
          key: const Key('profileNameField'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
          textInputAction: .next,
          enabled: !widget.saving,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('profileHandleField'),
          controller: _handle,
          decoration: const InputDecoration(labelText: 'Handle'),
          textInputAction: .next,
          enabled: !widget.saving,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('profilePhotoField'),
          controller: _photo,
          decoration: const InputDecoration(labelText: 'Photo URL'),
          textInputAction: .next,
          enabled: !widget.saving,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('profileLocaleField'),
          controller: _locale,
          decoration: const InputDecoration(labelText: 'Locale'),
          textInputAction: .done,
          enabled: !widget.saving,
          onSubmitted: (_) => _submit(),
        ),
        if (widget.failure != null) ...[
          const SizedBox(height: 12),
          Text(
            widget.failure!,
            style: RamificaText.body.copyWith(color: RamificaColors.error),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            TextButton(
              key: const Key('profileCancelButton'),
              onPressed: widget.saving ? null : widget.onCancel,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 12),
            FilledButton(
              key: const Key('profileSaveButton'),
              onPressed: widget.saving ? null : _submit,
              child: Text(widget.saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ],
    );
  }

  void _submit() {
    widget.onSave?.call(
      displayName: _name.text.trim(),
      handle: _handle.text.trim(),
      photoUrl: _photo.text.trim(),
      locale: _locale.text.trim(),
    );
  }
}
