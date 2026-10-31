import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// One pickable hotspot icon. [name] is the persisted value stored on the
class ChoiceIconOption {
  const ChoiceIconOption(this.name, this.icon, this.label);

  /// Persisted icon name, e.g. `mountain`.
  final String name;

  final IconData icon;

  /// Picker tooltip / semantics label.
  final String label;
}

/// The hotspot icons an author may pick for a choice, in picker order.
const choiceIconOptions = <ChoiceIconOption>[
  ChoiceIconOption('mountain', Icons.terrain, 'Mountain'),
  ChoiceIconOption('forest', Icons.forest, 'Forest'),
  ChoiceIconOption('lightning', Icons.bolt, 'Lightning'),
  ChoiceIconOption('key', Icons.key, 'Key'),
  ChoiceIconOption('unlock', Icons.lock_open, 'Unlock'),
  ChoiceIconOption('shield', Icons.shield, 'Shield'),
  ChoiceIconOption('fingerprint', Icons.fingerprint, 'Fingerprint'),
  ChoiceIconOption('compass', Icons.explore, 'Compass'),
  ChoiceIconOption('door', Icons.door_front_door, 'Door'),
  ChoiceIconOption('star', Icons.star, 'Star'),
  ChoiceIconOption('heart', Icons.favorite, 'Heart'),
  ChoiceIconOption('eye', Icons.visibility, 'Eye'),
  ChoiceIconOption('sun', Icons.wb_sunny, 'Sun'),
  ChoiceIconOption('moon', Icons.dark_mode, 'Moon'),
  ChoiceIconOption('fire', Icons.local_fire_department, 'Fire'),
  ChoiceIconOption('water', Icons.water_drop, 'Water'),
  ChoiceIconOption('castle', Icons.castle, 'Castle'),
  ChoiceIconOption('anchor', Icons.anchor, 'Anchor'),
  ChoiceIconOption('ship', Icons.sailing, 'Ship'),
  ChoiceIconOption('plane', Icons.flight, 'Plane'),
  ChoiceIconOption('car', Icons.directions_car, 'Car'),
  ChoiceIconOption('run', Icons.directions_run, 'Run'),
  ChoiceIconOption('walk', Icons.directions_walk, 'Walk'),
  ChoiceIconOption('diamond', Icons.diamond, 'Diamond'),
  ChoiceIconOption('flag', Icons.flag, 'Flag'),
  ChoiceIconOption('map', Icons.map, 'Map'),
  ChoiceIconOption('home', Icons.home, 'Home'),
  ChoiceIconOption('beach', Icons.beach_access, 'Beach'),
  ChoiceIconOption('snow', Icons.ac_unit, 'Snow'),
  ChoiceIconOption('trophy', Icons.emoji_events, 'Trophy'),
  ChoiceIconOption('rocket', Icons.rocket_launch, 'Rocket'),
  ChoiceIconOption('bulb', Icons.lightbulb, 'Idea'),
  ChoiceIconOption('pets', Icons.pets, 'Pets'),
  ChoiceIconOption('leaf', Icons.eco, 'Leaf'),
  ChoiceIconOption('music', Icons.music_note, 'Music'),
  ChoiceIconOption('dice', Icons.casino, 'Dice'),
  ChoiceIconOption('puzzle', Icons.extension, 'Puzzle'),
  ChoiceIconOption('camera', Icons.camera_alt, 'Camera'),
  ChoiceIconOption('food', Icons.restaurant, 'Food'),
  ChoiceIconOption('coffee', Icons.local_cafe, 'Coffee'),
  ChoiceIconOption('masks', Icons.theater_comedy, 'Masks'),
  ChoiceIconOption('sparkles', Icons.auto_awesome, 'Sparkles'),
  ChoiceIconOption('question', Icons.help, 'Question'),
  ChoiceIconOption('lock', Icons.lock, 'Lock'),
  ChoiceIconOption('clock', Icons.alarm, 'Clock'),
  ChoiceIconOption('tree', Icons.park, 'Tree'),
  ChoiceIconOption('gift', Icons.card_giftcard, 'Gift'),
  ChoiceIconOption('book', Icons.menu_book, 'Book'),
];

/// Glyph for a persisted icon [name]. Legacy choices carry no icon (and
/// unknown names fail closed the same way): fall back to the index pair
/// the suite always drew, so old drafts look unchanged until the author
/// picks an icon.
IconData choiceIconData(String? name, int index) {
  for (final option in choiceIconOptions) {
    if (option.name == name) return option.icon;
  }
  return index % 2 == 0 ? Icons.fingerprint : Icons.shield;
}

/// Whether [optionName] is the icon a choice at [index] currently draws —
/// drives the picker's selected state, where an unset icon counts as its
/// fallback.
bool isChoiceIconSelected(String? name, int index, String optionName) {
  final effective = name ?? (index % 2 == 0 ? 'fingerprint' : 'shield');
  return effective == optionName;
}

/// One pickable hotspot icon color. [name] is persisted on the choice
/// next to the icon name; the backend `saveNode` whitelist mirrors these
/// names — keep them in sync.
class ChoiceColorOption {
  const ChoiceColorOption(this.name, this.color, this.label);

  /// Persisted color name, e.g. `gold`.
  final String name;

  final Color color;

  /// Picker tooltip / semantics label.
  final String label;
}

/// Icon colors an author may pick, in picker order. The first two match
/// the per-index accent fallback, so unset reads as cyan/blue.
const choiceColorOptions = <ChoiceColorOption>[
  ChoiceColorOption('cyan', RamificaColors.hotspot, 'Cyan'),
  ChoiceColorOption('blue', RamificaColors.nodeActive, 'Blue'),
  ChoiceColorOption('violet', RamificaColors.brandViolet, 'Violet'),
  ChoiceColorOption('pink', Color(0xFFFF5DA2), 'Pink'),
  ChoiceColorOption('red', Color(0xFFFF5252), 'Red'),
  ChoiceColorOption('orange', Color(0xFFFF9F43), 'Orange'),
  ChoiceColorOption('gold', RamificaColors.rewardGold, 'Gold'),
  ChoiceColorOption('green', Color(0xFF3DDC84), 'Green'),
  ChoiceColorOption('mint', Color(0xFF64FFDA), 'Mint'),
  ChoiceColorOption('white', RamificaColors.textPrimary, 'White'),
];

/// Color for a persisted icon color [name]; null or unknown names fall
/// back to [fallback] (the caller's per-index accent).
Color choiceIconColor(String? name, Color fallback) {
  for (final option in choiceColorOptions) {
    if (option.name == name) return option.color;
  }
  return fallback;
}

/// Whether [optionName] is the color a choice at [index] currently
/// draws, where an unset color counts as its accent fallback.
bool isChoiceColorSelected(String? name, int index, String optionName) {
  final effective = name ?? (index % 2 == 0 ? 'cyan' : 'blue');
  return effective == optionName;
}
