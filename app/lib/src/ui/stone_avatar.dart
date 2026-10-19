// A player's stone as a round badge.

import 'package:flutter/material.dart';

import '../theme.dart';

/// A stone of [player]'s colour (`B` or `W`), outlined so that a white stone shows on a light surface and a black
/// one on a dark surface; [child] sits on it, e.g. the captures.
class StoneAvatar extends StatelessWidget {
  final String player;
  final double radius;
  final Widget? child;
  const StoneAvatar({super.key, required this.player, required this.radius, this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground, // over the stone, which would hide it
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: CircleAvatar(radius: radius, backgroundColor: KTheme.stoneColors[player], child: child),
  );
}
