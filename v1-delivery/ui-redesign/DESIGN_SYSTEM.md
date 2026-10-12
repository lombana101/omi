# Design system

Original privacy-app system. It does not copy the reference product’s layouts, portraits, or contact profiles.

## Color

Semantic tokens live in `privacy_theme.dart`: background, surface, secondary surface, text, secondary text, accent, on-accent, border, success, warning, destructive, disabled, focus, recording, interrupted, suggestion, machine, and owner.

Signal Green is the default: near-black background, charcoal cards, luminous green accent.

## Type

System font. Scale: display 40, title 28, section 18, body 16, meta 13, caption 12.

## Space and radius

4, 8, 12, 16, 24, 32, 48. Control radius 16. Card radius 22. Touch targets are at least 44 points.

## Components

`privacy_widgets.dart`: scaffold, header, section label, buttons, card, badge, capture orb, field, choice row, empty state, theme tile.

Recording glow appears only while the controller reports Recording, and is omitted when Reduce Motion is on. Every state also has text and an icon.
