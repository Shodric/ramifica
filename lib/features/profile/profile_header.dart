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
    final verified =
        (displayName?.trim().isNotEmpty ?? false) || tag.isNotEmpty;
    return Semantics(
      label: isOwn ? 'Your profile' : 'Author $name',
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          SizedBox(
            height: 244,
            child: Stack(
              children: [
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 176,
                  child: _Banner(),
                ),
                Positioned(
                  left: 12,
                  bottom: 0,
                  child: _AvatarRing(photoUrl: photoUrl, name: name),
                ),
                // Name + verified check ride beside the avatar (bottom
                // aligned, in the empty strip below the banner) instead
                // of below it, so they take no extra vertical space.
                // Avatar spans x 12..108; 12px gap, 12px outer margin.
                Positioned(
                  left: 120,
                  right: 12,
                  bottom: 0,
                  child: _NameRow(name: name, verified: verified),
                ),
              ],
            ),
          ),
          if (tag.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '@$tag',
              style: RamificaText.meta,
              maxLines: 1,
              overflow: .ellipsis,
            ),
          ],
          if (!isOwn) ...[
            const SizedBox(height: 16),
            _FollowCta(
              isFollowing: isFollowing,
              toggling: toggling,
              onFollowToggle: onFollowToggle,
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

class _NameRow extends StatelessWidget {
  const _NameRow({required this.name, required this.verified});

  final String name;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            style: RamificaText.headlineSM,
            maxLines: 2,
            overflow: .ellipsis,
          ),
        ),
        if (verified) ...[
          const SizedBox(width: 6),
          const Icon(Icons.verified, size: 18, color: RamificaColors.hotspot),
        ],
      ],
    );
  }
}

/// Static cinematic banner: token gradient only, no remote art (the profile
/// carries no cover source). Fully static, settles immediately.
class _Banner extends StatelessWidget {
  const _Banner();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 176,
      decoration: BoxDecoration(
        borderRadius: .circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            RamificaColors.containerHigh,
            RamificaColors.containerLowest,
          ],
        ),
        border: .all(color: RamificaColors.glassBorder),
      ),
      child: const Center(
        child: Icon(
          Icons.auto_stories_outlined,
          size: 56,
          color: RamificaColors.glassBorder,
        ),
      ),
    );
  }
}

/// Avatar with the Stitch cyan gradient ring and hub dot. Photo only from
/// state; otherwise (and on load error) a static placeholder icon.
class _AvatarRing extends StatelessWidget {
  const _AvatarRing({required this.photoUrl, required this.name});

  final String? photoUrl;
  final String name;

  @override
  Widget build(BuildContext context) {
    final uri = photoUrl?.trim() ?? '';
    final Widget face = uri.isEmpty
        ? const ColoredBox(
            color: RamificaColors.nodeLocked,
            child: Icon(
              Icons.person,
              size: 40,
              color: RamificaColors.textPrimary,
            ),
          )
        : Image.network(
            uri,
            fit: .cover,
            errorBuilder: (_, _, _) => const ColoredBox(
              color: RamificaColors.nodeLocked,
              child: Icon(
                Icons.person,
                size: 40,
                color: RamificaColors.textPrimary,
              ),
            ),
          );
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        children: [
          Container(
            width: 96,
            height: 96,
            padding: const .all(2.5),
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.all(Radius.circular(22)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [RamificaColors.hotspot, RamificaColors.nodeActive],
              ),
            ),
            child: ClipRRect(borderRadius: .circular(19), child: face),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: .circle,
                color: RamificaColors.containerLowest,
                border: .all(color: RamificaColors.glassBorder),
              ),
              child: const Icon(
                Icons.hub,
                size: 13,
                color: RamificaColors.hotspot,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Foreign-only follow CTA in the Stitch action-hub style: cyan gradient
/// while unfollowed, quiet container once following. Taps leave through
/// [onFollowToggle]; disabled while [toggling].
class _FollowCta extends StatelessWidget {
  const _FollowCta({
    required this.isFollowing,
    required this.toggling,
    this.onFollowToggle,
  });

  final bool isFollowing;
  final bool toggling;
  final VoidCallback? onFollowToggle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: .circular(12),
      child: Ink(
        height: 48,
        decoration: BoxDecoration(
          borderRadius: .circular(12),
          gradient: isFollowing
              ? null
              : const LinearGradient(
                  colors: [RamificaColors.hotspot, RamificaColors.nodeActive],
                ),
          color: isFollowing ? RamificaColors.containerHigh : null,
        ),
        child: InkWell(
          key: const Key('profileFollowButton'),
          borderRadius: .circular(12),
          onTap: toggling ? null : onFollowToggle,
          child: Row(
            mainAxisAlignment: .center,
            children: [
              Icon(
                isFollowing ? Icons.check_circle : Icons.add_circle,
                color: isFollowing
                    ? RamificaColors.hotspot
                    : RamificaColors.onSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                isFollowing ? 'Following' : 'Follow',
                style: RamificaText.label.copyWith(
                  color: isFollowing
                      ? RamificaColors.hotspot
                      : RamificaColors.onSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
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
