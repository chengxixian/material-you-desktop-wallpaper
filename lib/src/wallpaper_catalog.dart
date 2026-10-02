import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 内置壁纸目录。
///
/// 设计要点（与 HTML 版 `material-you-wallpaper` 的 8 张壁纸对齐）：
/// * **完全程序化绘制**，不依赖任何图片资源 —— 离线可用、体积为零、任意分辨率不糊；
/// * 每张壁纸自带一个 **seed 色**，Material You 取色直接用它，
///   内置壁纸因此**不需要解码图片**（只有本地文件壁纸才走 `ColorScheme.fromImageProvider`）；
/// * 同一份 painter 既画全屏壁纸，也画设置页里的缩略图（相对坐标布局）。
class BuiltinWallpaper {
  const BuiltinWallpaper({
    required this.id,
    required this.name,
    required this.description,
    required this.seed,
    required this.painter,
  });

  final String id;
  final String name;
  final String description;

  /// Material You 种子色（内置壁纸无需从图片提取）。
  final Color seed;

  final CustomPainter Function() painter;
}

/// 按 id 取内置壁纸；找不到时返回 [defaultWallpaper]。
BuiltinWallpaper wallpaperById(String? id) {
  for (final w in builtinWallpapers) {
    if (w.id == id) {
      return w;
    }
  }
  return defaultWallpaper;
}

final BuiltinWallpaper defaultWallpaper = builtinWallpapers.first;

final List<BuiltinWallpaper> builtinWallpapers = <BuiltinWallpaper>[
  BuiltinWallpaper(
    id: 'mesh',
    name: '流体渐变',
    description: '深空紫底 + 青粉光斑',
    seed: const Color(0xff6750a4),
    painter: () => const _MeshWallpaper(),
  ),
  BuiltinWallpaper(
    id: 'aurora',
    name: '极光',
    description: '星空 + 青绿极光带',
    seed: const Color(0xff3ddc97),
    painter: () => const _AuroraWallpaper(),
  ),
  BuiltinWallpaper(
    id: 'forest',
    name: '森林',
    description: '雾中五层山脊',
    seed: const Color(0xff2e7d5b),
    painter: () => const _ForestWallpaper(),
  ),
  BuiltinWallpaper(
    id: 'ocean',
    name: '海洋',
    description: '深海蓝绿波浪',
    seed: const Color(0xff00696d),
    painter: () => const _OceanWallpaper(),
  ),
  BuiltinWallpaper(
    id: 'sunset',
    name: '日落',
    description: '橙粉地平线',
    seed: const Color(0xffff7043),
    painter: () => const _SunsetWallpaper(),
  ),
  BuiltinWallpaper(
    id: 'neon',
    name: '霓虹',
    description: '紫红霓虹网格',
    seed: const Color(0xffe040fb),
    painter: () => const _NeonWallpaper(),
  ),
  BuiltinWallpaper(
    id: 'geo',
    name: '几何',
    description: '低多边形色块',
    seed: const Color(0xff4a6cf7),
    painter: () => const _GeoWallpaper(),
  ),
  BuiltinWallpaper(
    id: 'mountain',
    name: '山峦',
    description: '内置风景（原默认）',
    seed: const Color(0xff9cbfa7),
    painter: () => const _MountainWallpaper(),
  ),
];

// ─────────────────────────────── 绘制工具 ───────────────────────────────

/// 用一组颜色铺满整个画布。
void _fillGradient(
  Canvas canvas,
  Size size,
  List<Color> colors, {
  Alignment begin = Alignment.topCenter,
  Alignment end = Alignment.bottomCenter,
  List<double>? stops,
}) {
  final rect = Offset.zero & size;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(begin: begin, end: end, colors: colors, stops: stops).createShader(rect),
  );
}

/// 柔光圆斑（用径向渐变模拟高斯模糊，比 `MaskFilter` 便宜得多）。
void _glow(Canvas canvas, Offset center, double radius, Color color) {
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius)),
  );
}

/// 一条横向波浪填充带：`y` 为基准高度（0–1），`amp` 为振幅（相对高度）。
Path _wavePath(Size size, double y, double amp, {bool flip = false}) {
  final dy = flip ? -1.0 : 1.0;
  final path = Path()..moveTo(0, size.height * y);
  path.cubicTo(
    size.width * .22,
    size.height * (y + amp * .38 * dy),
    size.width * .34,
    size.height * (y + amp * .12),
    size.width * .52,
    size.height * (y + amp * .05),
  );
  path.cubicTo(
    size.width * .70,
    size.height * (y - amp * .40 * dy),
    size.width * .86,
    size.height * (y + amp * .22),
    size.width,
    size.height * (y - amp * .18),
  );
  return path;
}

void _waveBand(Canvas canvas, Size size, double y, double amp, Color color, {bool flip = false}) {
  final path = _wavePath(size, y, amp, flip: flip)
    ..lineTo(size.width, size.height)
    ..lineTo(0, size.height)
    ..close();
  canvas.drawPath(path, Paint()..color = color);
}

abstract class _WallpaperPainter extends CustomPainter {
  const _WallpaperPainter();

  void draw(Canvas canvas, Size size);

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size);

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────────────────────── 8 张壁纸 ───────────────────────────────

class _MeshWallpaper extends _WallpaperPainter {
  const _MeshWallpaper();

  @override
  void draw(Canvas canvas, Size size) {
    _fillGradient(
      canvas,
      size,
      const [Color(0xff231c3d), Color(0xff3b2d5e), Color(0xff15122a)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    final d = size.shortestSide;
    _glow(canvas, Offset(size.width * .20, size.height * .26), d * .78, const Color(0xb37c4dff));
    _glow(canvas, Offset(size.width * .80, size.height * .16), d * .62, const Color(0xa600bfa5));
    _glow(canvas, Offset(size.width * .64, size.height * .86), d * .88, const Color(0x99ff6e9c));
    _glow(canvas, Offset(size.width * .08, size.height * .92), d * .60, const Color(0x8c3d5afe));
  }
}

class _AuroraWallpaper extends _WallpaperPainter {
  const _AuroraWallpaper();

  @override
  void draw(Canvas canvas, Size size) {
    _fillGradient(canvas, size, const [Color(0xff050b14), Color(0xff0b1c2c), Color(0xff071018)]);
    for (var i = 0; i < 90; i++) {
      final fx = ((i * 37) % 100) / 100;
      final fy = ((i * 61) % 55) / 100;
      canvas.drawCircle(
        Offset(size.width * fx, size.height * fy),
        i % 3 == 0 ? 1.6 : 1.0,
        Paint()..color = Colors.white.withValues(alpha: i % 4 == 0 ? .55 : .28),
      );
    }
    const bands = <(double, double, Color, double)>[
      (0.34, 0.30, Color(0x8833ffc4), 0.10),
      (0.44, 0.24, Color(0x7722d3ee), 0.06),
      (0.54, 0.20, Color(0x668f7bff), 0.02),
    ];
    for (final band in bands) {
      final top = size.height * (band.$1 - band.$2 * .5);
      final rect = Rect.fromLTWH(0, top, size.width, size.height * band.$2);
      final bottom = rect.bottom;
      canvas.drawPath(
        Path()
          ..moveTo(0, rect.center.dy)
          ..cubicTo(size.width * .25, rect.top, size.width * .45, bottom, size.width * .68, rect.center.dy)
          ..cubicTo(size.width * .82, rect.top + rect.height * .3, size.width * .92, bottom, size.width, rect.center.dy)
          ..lineTo(size.width, bottom + size.height * band.$4)
          ..cubicTo(size.width * .80, bottom, size.width * .50, rect.top + rect.height * .6, size.width * .20, rect.center.dy)
          ..cubicTo(size.width * .10, rect.top + rect.height * .4, size.width * .05, rect.center.dy, 0, rect.center.dy)
          ..close(),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [band.$3, band.$3.withValues(alpha: 0)],
          ).createShader(rect),
      );
    }
    _waveBand(canvas, size, .84, .05, const Color(0xff0d2233));
  }
}

class _ForestWallpaper extends _WallpaperPainter {
  const _ForestWallpaper();

  @override
  void draw(Canvas canvas, Size size) {
    _fillGradient(canvas, size, const [Color(0xff9fb8a8), Color(0xffd8d6bd), Color(0xff6f8a76)]);
    _glow(canvas, Offset(size.width * .72, size.height * .22), size.shortestSide * .34, const Color(0x88fff3c4));
    const ridges = <(double, double, Color)>[
      (0.52, 0.10, Color(0xff8fa895)),
      (0.62, 0.11, Color(0xff74907c)),
      (0.72, 0.12, Color(0xff577363)),
      (0.82, 0.12, Color(0xff3c5849)),
      (0.92, 0.10, Color(0xff22392e)),
    ];
    for (var i = 0; i < ridges.length; i++) {
      _waveBand(canvas, size, ridges[i].$1, ridges[i].$2, ridges[i].$3, flip: i.isOdd);
    }
  }
}

class _OceanWallpaper extends _WallpaperPainter {
  const _OceanWallpaper();

  @override
  void draw(Canvas canvas, Size size) {
    _fillGradient(canvas, size, const [Color(0xffbfe6e4), Color(0xff5fb6b8), Color(0xff03474f)]);
    _glow(canvas, Offset(size.width * .30, size.height * .26), size.shortestSide * .26, const Color(0x99ffffff));
    const bands = <(double, double, Color)>[
      (0.56, 0.06, Color(0xcc1f8f96)),
      (0.66, 0.07, Color(0xdd14727c)),
      (0.76, 0.08, Color(0xee0a5a63)),
      (0.86, 0.08, Color(0xff04424b)),
    ];
    for (final band in bands) {
      _waveBand(canvas, size, band.$1, band.$2, band.$3);
      canvas.drawPath(
        _wavePath(size, band.$1, band.$2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.height * .003
          ..color = Colors.white.withValues(alpha: .35),
      );
    }
  }
}

class _SunsetWallpaper extends _WallpaperPainter {
  const _SunsetWallpaper();

  @override
  void draw(Canvas canvas, Size size) {
    _fillGradient(
      canvas,
      size,
      const [Color(0xff2b1055), Color(0xff7b2d6b), Color(0xffff8a5b), Color(0xffffd28a)],
      stops: const [0, .38, .68, 1],
    );
    final sun = Offset(size.width * .68, size.height * .62);
    _glow(canvas, sun, size.shortestSide * .55, const Color(0x99ffd28a));
    canvas.drawCircle(sun, size.shortestSide * .13, Paint()..color = const Color(0xfffff0c2));
    final sea = Rect.fromLTWH(0, size.height * .74, size.width, size.height * .26);
    canvas.drawRect(
      sea,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xcc3b1a4a), Color(0xff180a26)],
        ).createShader(sea),
    );
    for (var i = 0; i < 7; i++) {
      final y = size.height * (.76 + i * .032);
      final w = size.shortestSide * (.34 - i * .035);
      if (w <= 0) {
        continue;
      }
      canvas.drawLine(
        Offset(sun.dx - w / 2, y),
        Offset(sun.dx + w / 2, y),
        Paint()
          ..strokeWidth = size.height * .006
          ..color = const Color(0xffffd28a).withValues(alpha: .34 - i * .04),
      );
    }
  }
}

class _NeonWallpaper extends _WallpaperPainter {
  const _NeonWallpaper();

  @override
  void draw(Canvas canvas, Size size) {
    _fillGradient(
      canvas,
      size,
      const [Color(0xff10061f), Color(0xff250a3a), Color(0xff0a0417)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    final grid = Paint()
      ..strokeWidth = 1
      ..color = const Color(0x33ff5cf0);
    for (var i = 1; i < 14; i++) {
      final x = size.width * i / 14;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var i = 1; i < 9; i++) {
      final y = size.height * i / 9;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    _glow(canvas, Offset(size.width * .28, size.height * .34), size.shortestSide * .55, const Color(0xaa22e1ff));
    _glow(canvas, Offset(size.width * .74, size.height * .68), size.shortestSide * .60, const Color(0xaaff2fb4));
    const bars = <(double, double, double, Color)>[
      (.16, .30, .012, Color(0xffff2fb4)),
      (.26, .52, .008, Color(0xff22e1ff)),
      (.44, .38, .010, Color(0xffb14bff)),
    ];
    for (final bar in bars) {
      final rect = Rect.fromLTWH(size.width * bar.$1, size.height * .18, size.width * bar.$3, size.height * bar.$2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.width)),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bar.$4.withValues(alpha: 0), bar.$4, bar.$4.withValues(alpha: 0)],
          ).createShader(rect),
      );
    }
  }
}

class _GeoWallpaper extends _WallpaperPainter {
  const _GeoWallpaper();

  static const _palette = [
    Color(0xff4a6cf7),
    Color(0xff7c4dff),
    Color(0xff00b8d4),
    Color(0xff2ecc8f),
    Color(0xffffb300),
    Color(0xffff5f6d),
  ];

  @override
  void draw(Canvas canvas, Size size) {
    _fillGradient(
      canvas,
      size,
      const [Color(0xff0f1b3d), Color(0xff243b6b), Color(0xff101a33)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    // 确定性伪随机：同一张壁纸每次渲染结果一致（截图可比对）。
    var seed = 20261002;
    double rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return (seed % 10000) / 10000;
    }

    for (var i = 0; i < 26; i++) {
      final cx = size.width * rnd();
      final cy = size.height * rnd();
      final r = size.shortestSide * (.10 + rnd() * .22);
      final path = Path();
      final points = 3 + (i % 2);
      for (var p = 0; p < points; p++) {
        final a = (p / points) * 2 * math.pi + rnd() * .6;
        final radius = r * (0.7 + rnd() * .5);
        final pt = Offset(cx + radius * math.cos(a), cy + radius * math.sin(a));
        if (p == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      path.close();
      canvas.drawPath(path, Paint()..color = _palette[(i * 7) % _palette.length].withValues(alpha: .16 + rnd() * .18));
    }
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          radius: .9,
          colors: [Color(0x00000000), Color(0xcc060c1c)],
        ).createShader(rect),
    );
  }
}

class _MountainWallpaper extends _WallpaperPainter {
  const _MountainWallpaper();

  @override
  void draw(Canvas canvas, Size size) {
    _fillGradient(canvas, size, const [Color(0xff788e88), Color(0xffc5c6ad), Color(0xff304d46)]);
    canvas.drawCircle(
      Offset(size.width * .38, size.height * .31),
      size.height * .11,
      Paint()..color = const Color(0xffdfd9b8).withValues(alpha: .6),
    );
    const layers = [
      Color(0xff81958a),
      Color(0xff687f74),
      Color(0xff48675b),
      Color(0xff2b4c40),
      Color(0xff18382d),
    ];
    for (var layer = 0; layer < layers.length; layer++) {
      final y = size.height * (.48 + layer * .10);
      final p = Path()..moveTo(0, y);
      p.cubicTo(size.width * .2, y - size.height * .18, size.width * .3, y + size.height * .08, size.width * .48, y - size.height * .04);
      p.cubicTo(size.width * .64, y - size.height * .2, size.width * .84, y + size.height * .06, size.width, y - size.height * .08);
      p
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(p, Paint()..color = layers[layer]);
    }
  }
}
