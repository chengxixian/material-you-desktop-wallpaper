import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_desktop/main.dart';
import 'package:material_desktop/src/wallpaper_catalog.dart';
import 'package:material_desktop/src/weather.dart' as wx;

/// 模拟原生桥：把 Windows 侧（GSMTC 媒体会话 / 配置读写 / 窗口控制）替换成
/// 一份「真实网易云会话」的样本，测试只验证 Dart 侧行为。
var _pollCount = 0;
// 一张最小合法 PNG（1x1），保证 Image.memory 能真的解码成功
final _artworkBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void _mockNative() {
  _pollCount = 0;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(native, (call) async {
    switch (call.method) {
      case 'readConfig':
        return '';
      case 'wallpaper':
      case 'settingsWindow':
        return null;
      case 'windowInfo':
        return {'width': 2560, 'height': 1600, 'dpi': 168};
      case 'quitWallpaper':
        return false;
      case 'media':
        _pollCount++;
        return {
          'sources': ['cloudmusic.exe'],
          'available': true,
          'source': 'cloudmusic.exe',
          'title': '100种生活',
          'artist': '卢广仲',
          'album': '早安晨之美',
          'playing': false,
          'canPlay': true,
          'canPause': false,
          'canNext': true,
          'canPrevious': true,
          'canSeek': false,
          'position': 0.0,
          'duration': 0.0,
          // 原生协议：字节只在换歌那一次回传，其余轮询只回 key
          'artworkKey': 'cloudmusic.exe|100种生活|卢广仲',
          if (_pollCount == 1) 'artwork': _artworkBytes,
        };
      default:
        return null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_mockNative);

  group('启动模式（Wallpaper Engine 关键约定）', () {
    test('无参数 = 壁纸模式', () {
      expect(settingsModeFor(const []), isFalse);
      expect(settingsModeFor(const ['--wallpaper']), isFalse);
    });
    test('只有 --settings 才是控制中心', () {
      expect(settingsModeFor(const ['--settings']), isTrue);
      expect(settingsModeFor(const ['--settings', '--wallpaper']), isTrue);
    });
  });

  group('内置壁纸目录', () {
    test('8 张、id 唯一、种子色互不相同', () {
      expect(builtinWallpapers.length, 8);
      expect(builtinWallpapers.map((w) => w.id).toSet().length, 8);
      expect(builtinWallpapers.map((w) => w.seed.toARGB32()).toSet().length, 8);
    });
    test('按 id 查找，找不到时回退到默认壁纸', () {
      expect(wallpaperById('neon').name, '霓虹');
      expect(wallpaperById('nope').id, defaultWallpaper.id);
      expect(wallpaperById(null).id, defaultWallpaper.id);
    });
  });

  group('天气解析（离线样本，不联网）', () {
    final sample = jsonEncode({
      'current': {
        'time': '2026-10-02T14:00',
        'temperature_2m': 17.4,
        'apparent_temperature': 16.1,
        'relative_humidity_2m': 65,
        'wind_speed_10m': 3.2,
        'weather_code': 3,
      },
      'hourly': {
        'time': [for (var h = 12; h < 24; h++) '2026-10-02T${h.toString().padLeft(2, '0')}:00'],
        'temperature_2m': [for (var h = 12; h < 24; h++) 10.0 + h],
        'weather_code': [for (var h = 12; h < 24; h++) 3],
      },
      'daily': {
        'time': ['2026-10-02', '2026-10-03', '2026-10-04'],
        'weather_code': [3, 61, 0],
        'temperature_2m_max': [20.0, 18.5, 22.1],
        'temperature_2m_min': [11.0, 9.5, 12.0],
      },
    });

    test('当前 / 逐时 / 每日都解析出来，并从当前小时开始截取', () {
      final r = wx.parseWeather(jsonDecode(sample) as Map<String, dynamic>);
      expect(r.now.temperature, 17.4);
      expect(r.now.feelsLike, 16.1);
      expect(r.now.humidity, 65);
      expect(r.now.code, 3);
      // 样本只有 12–23 点，当前 14 点 → 从 14 点起共 10 条
      expect(r.hours.length, 10);
      expect(r.hours.first.time.hour, 14);
      expect(r.days.length, 3);
      expect(r.days[1].min, 9.5);
      expect(r.days[1].max, 18.5);
    });

    test('WMO 代码映射到中文与图标', () {
      expect(wx.weatherLabel(0), '晴');
      expect(wx.weatherLabel(3), '阴');
      expect(wx.weatherLabel(61), '降雨');
      expect(wx.weatherLabel(75), '降雪');
      expect(wx.weatherLabel(96), '雷暴');
      expect(wx.weatherIcon(0), Icons.wb_sunny_outlined);
      expect(wx.weatherIcon(3), Icons.cloud_outlined);
      expect(wx.weatherIcon(96), Icons.thunderstorm_outlined);
    });
  });

  group('颜色解析', () {
    test('#RRGGBB / #AARRGGBB / 非法输入', () {
      expect(parseHexColor('#6750a4'), const Color(0xff6750a4));
      expect(parseHexColor('6750a4'), const Color(0xff6750a4));
      expect(parseHexColor('#806750a4'), const Color(0x806750a4));
      expect(parseHexColor(''), isNull);
      expect(parseHexColor('nope'), isNull);
    });
  });

  group('专辑封面缓存（封面闪烁回归测试）', () {
    final art1 = Uint8List.fromList([1, 2, 3, 4]);
    final art2 = Uint8List.fromList([9, 9, 9, 9]);

    test('同一首歌的后续轮询必须复用同一个 Uint8List 实例', () {
      final c = ArtworkCache();
      c.update({'artworkKey': 'a', 'artwork': art1});
      expect(identical(c.bytes, art1), isTrue);
      // 关键：原生只在换歌时回传字节，其余轮询只回 key —— 缓存不能被清掉，
      // 更不能换成新实例（否则 MemoryImage 身份变化 → 每秒重解码 → 封面闪）。
      for (var i = 0; i < 5; i++) {
        c.update({'artworkKey': 'a'});
        expect(identical(c.bytes, art1), isTrue, reason: '第 $i 次轮询后封面实例被换掉了');
      }
    });

    test('换歌才换封面；取图失败则清空', () {
      final c = ArtworkCache();
      c.update({'artworkKey': 'a', 'artwork': art1});
      c.update({'artworkKey': 'b', 'artwork': art2});
      expect(identical(c.bytes, art2), isTrue);
      // 换歌但这次没带图（thumbnail 取不到）→ 清空，避免显示上一首的封面
      c.update({'artworkKey': 'c'});
      expect(c.bytes, isNull);
      // 明确回传空字节 = 取图失败，同样清空
      c.update({'artworkKey': 'c', 'artwork': Uint8List(0)});
      expect(c.bytes, isNull);
    });
  });

  testWidgets('控制中心：壁纸画廊与外观开关齐全', (tester) async {
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const DesktopApp(settingsMode: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('选择本地壁纸'), findsOneWidget);
    expect(find.text('壁纸自适应主题色'), findsOneWidget);
    expect(find.text('高对比度配色'), findsOneWidget);
    expect(find.text('内置壁纸'), findsOneWidget);
    for (final wp in builtinWallpapers) {
      expect(find.text(wp.name), findsOneWidget, reason: '画廊里应有「${wp.name}」');
    }
    // 画廊缩略图 = 8 张内置壁纸 + 顶部大预览
    expect(find.byType(CustomPaint), findsAtLeast(8));

    // 切一张内置壁纸，不应抛异常
    await tester.tap(find.text('霓虹'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('控制中心：组件页可关时钟/开关预报', (tester) async {
    tester.view.physicalSize = const Size(1800, 1600);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const DesktopApp(settingsMode: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('桌面组件'));
    await tester.pump();

    expect(find.text('显示秒'), findsOneWidget);
    expect(find.text('24 小时制'), findsOneWidget);
    expect(find.text('显示未来 5 天预报'), findsOneWidget);
    expect(find.text('显示未来 12 小时温度曲线'), findsOneWidget);
    expect(find.text('天气城市'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('控制中心：播放器页显示真实媒体元数据', (tester) async {
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const DesktopApp(settingsMode: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('播放器连接'));
    await tester.pump();

    expect(find.text('100种生活'), findsOneWidget);
    expect(find.text('卢广仲'), findsOneWidget);
    expect(find.text('早安晨之美'), findsOneWidget);
    expect(find.textContaining('不显示虚假进度'), findsOneWidget);
    final play = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.play_arrow_rounded));
    expect(play.onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('壁纸模式：三块组件用的是真实数据，没有演示数据', (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const DesktopApp(settingsMode: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('NOW PLAYING'), findsOneWidget);
    expect(find.text('LOCAL TIME'), findsOneWidget);
    expect(find.text('100种生活'), findsOneWidget);
    expect(find.text('卢广仲'), findsOneWidget);
    // 天气在测试环境里取不到网络 → 显示可点击的失败提示，而不是编造数据
    expect(find.textContaining('天气暂时不可用'), findsOneWidget);
    expect(find.text('演示模式'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('壁纸模式：连续轮询之间封面 provider 是同一个实例（不闪）', (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const DesktopApp(settingsMode: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Image.memory 每次 build 都会 new 一个 MemoryImage 外壳，但 MemoryImage 的
    // 相等性看的是 **bytes 的 identity**：只要 bytes 是同一个 Uint8List，
    // `Image` 就不会重新 resolve/decode（这才是「不闪」的真正条件）。
    Uint8List? firstBytes;
    MemoryImage? firstProvider;
    for (var i = 0; i < 4; i++) {
      final image = tester.widget<Image>(find.byType(Image).first);
      final provider = image.image as MemoryImage;
      firstBytes ??= provider.bytes;
      firstProvider ??= provider;
      expect(
        identical(provider.bytes, firstBytes),
        isTrue,
        reason: '第 $i 次轮询后封面字节换了实例 → Flutter 会重新解码 → 封面会闪',
      );
      expect(provider == firstProvider, isTrue, reason: '第 $i 次轮询后 MemoryImage 不相等');
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
