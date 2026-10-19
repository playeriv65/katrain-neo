// The random numbers the game draws: teaching undo thresholds, AI move choices, self-play.

import 'dart:math' as math;

/// One source for all of them; tests replace it with a seeded one to make choices reproducible.
math.Random random = math.Random();
