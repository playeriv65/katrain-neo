// The textures KaTrain draws the board with (katrain/img, MIT), loaded once (drawing.py's cached_texture).

import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../../theme.dart';

class BoardImages {
  final Map<String, ui.Image> _images;
  BoardImages._(this._images);

  static Future<BoardImages>? _loading;

  static Future<BoardImages> load([AssetBundle? bundle]) => _loading ??= _load(bundle ?? rootBundle);

  static Future<BoardImages> _load(AssetBundle bundle) async {
    final paths = [
      ...KTheme.stoneTexture.values,
      ...KTheme.circleTexture.values,
      KTheme.evalDotTexture,
      KTheme.lastMoveTexture,
      KTheme.topMoveTexture,
      KTheme.boardTexture,
      KTheme.graphTexture,
    ];
    final images = <String, ui.Image>{};
    for (final path in paths) {
      final data = await bundle.load(path);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      images[path] = (await codec.getNextFrame()).image;
    }
    return BoardImages._(images);
  }

  ui.Image operator [](String path) => _images[path]!;

  ui.Image stone(String player) => this[KTheme.stoneTexture[player]!];
}

/// Draws [image] stretched over [rect], multiplied by [tint] as Kivy's `Color` multiplies a texture.
void drawTexture(ui.Canvas canvas, ui.Image image, ui.Rect rect, [ui.Color? tint]) {
  final paint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium
    ..isAntiAlias = true;
  if (tint != null) paint.colorFilter = ui.ColorFilter.mode(tint, ui.BlendMode.modulate);
  canvas.drawImageRect(image, ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), rect, paint);
}
