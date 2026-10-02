import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_desktop/main.dart';
import 'package:material_desktop/src/wallpaper_catalog.dart';
import 'package:material_desktop/src/weather.dart' as wx;

/// 模拟原生桥：把 Windows 侧（GSMTC 媒体会话 / 配置读写 / 窗口控制）替换成
/// 一份「真实网易云会话」的样本，测试只验证 Dart 侧行为。
var _mockConfig = '';
var _pollCount = 0;
var _pickStarts = 0;
var _pickPolls = 0;
List<String> _wallpaperSets = [];
// 一张最小合法 PNG（1x1），保证 Image.memory 能真的解码成功
final _artworkBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void _mockNative() {
  _mockConfig = '';
  _pollCount = 0;
  _pickStarts = 0;
  _pickPolls = 0;
  _wallpaperSets = [];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(native, (call) async {
    switch (call.method) {
      case 'readConfig':
        return _mockConfig;
      case 'wallpaper':
      case 'settingsWindow':
      case 'desktopOverlay':
      case 'reapplyTransparency':
      case 'setAutostart':
        return null;
      case 'pickWallpaper':
        _pickStarts++;
        return true;
      case 'pickWallpaperResult':
        // 前两次返回 pending（模拟对话框还开着），第三次才给出结果
        _pickPolls++;
        if (_pickPolls < 3) {
          return {'pending': true, 'path': ''};
        }
        return {'pending': false, 'path': r'C:\Users\Public\Pictures\chosen.jpg'};
      case 'setWallpaperImage':
        _wallpaperSets.add('${(call.arguments as Map)['path']}');
        return true;
      case 'getWallpaperImage':
        return r'C:\Users\Public\Pictures\original.jpg';
      case 'windowInfo':
        return {'width': 2560, 'height': 1600, 'dpi': 168, 'monitorWidth': 2560, 'monitorHeight': 1600};
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
  setUp(() {
    _mockNative();
    // 测试产物别写进真实配置目录
    configDirOverride = Directory.systemTemp.createTempSync('mdesk-test-').path;
    // widget 测试跑在 FakeAsync 区域里，`Picture.toImage()` 永远不会完成，
    // 所以静态壁纸的 PNG 渲染换成同步桩；真实渲染由下面的 runAsync 测试覆盖。
    wallpaperPngRenderer = (wallpaper, w, h) async => _artworkBytes;
  });

  group('启动模式', () {
    test('无参数 = 桌面组件模式（默认，可交互）', () {
      expect(launchModeFor(const []), LaunchMode.desktop);
      expect(launchModeFor(const ['--desktop']), LaunchMode.desktop);
      expect(settingsModeFor(const []), isFalse);
    });
    test('--wallpaper = 全屏壁纸窗口（Wallpaper Engine / 预览用）', () {
      expect(launchModeFor(const ['--wallpaper']), LaunchMode.wallpaperWindow);
      expect(settingsModeFor(const ['--wallpaper']), isFalse);
    });
    test('只有 --settings 才是控制中心', () {
      expect(launchModeFor(const ['--settings']), LaunchMode.settings);
      expect(launchModeFor(const ['--settings', '--wallpaper']), LaunchMode.settings);
      expect(settingsModeFor(const ['--settings']), isTrue);
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

  testWidgets('内置壁纸能渲染成 PNG（静态壁纸的输入，真实渲染）', (tester) async {
    // toImage 依赖引擎真实异步任务 → 必须放进 runAsync，FakeAsync 里会挂住
    await tester.runAsync(() async {
      final bytes = await renderWallpaperPng(builtinWallpapers.first, 320, 200);
      expect(bytes.length, greaterThan(200));
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]); // PNG 魔数
    });
  });

  testWidgets('桌面组件模式：只有组件条 + 把壁纸交给系统（不实时渲染）', (tester) async {
    tester.view.physicalSize = const Size(430, 1040);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const DesktopApp(mode: LaunchMode.desktop));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 三块组件都在（而且这个窗口是可以点的）
    expect(find.text('LOCAL TIME'), findsOneWidget);
    expect(find.text('NOW PLAYING'), findsOneWidget);
    // 桌面模式**不画全屏壁纸层**：wallpaperLayer() 用的 AnimatedSwitcher 不该出现
    expect(find.byType(AnimatedSwitcher), findsNothing);
    // 壁纸被渲染成 PNG 交给 Windows —— 这是「不卡」的关键
    expect(_wallpaperSets, isNotEmpty);
    expect(_wallpaperSets.last, contains('wallpaper-mesh-'));
    expect(File(_wallpaperSets.last).existsSync(), isTrue, reason: '应已生成静态壁纸 PNG');
    await tester.pumpWidget(const SizedBox());
  });

  group('文件选择对话框必须非阻塞（「再次点击后窗口卡死」回归测试）', () {
    testWidgets('对话框开着时轮询等待，拿到路径才返回', (tester) async {
      late String picked;
      await tester.runAsync(() async {
        picked = await pickWallpaperInteractively();
      });
      expect(_pickStarts, 1, reason: '应只启动一次对话框');
      expect(_pickPolls, greaterThanOrEqualTo(3), reason: '开着时应持续轮询');
      expect(picked, r'C:\Users\Public\Pictures\chosen.jpg');
    });
  });

  group('高对比度必须真的改变配色', () {
    const seed = Color(0xff6750a4);

    test('记录事实：fromSeed 的 contrastLevel 在 3.47.5 上不起作用', () {
      final a = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
      final b = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
        contrastLevel: 0.5,
      );
      // 完全一样 → 所以高对比度必须自己算（applyHighContrast）
      expect(b.surface.toARGB32(), a.surface.toARGB32());
    });

    test('applyHighContrast 真的拉开明暗差', () {
      double spread(ColorScheme s) =>
          (HSLColor.fromColor(s.onSurface).lightness - HSLColor.fromColor(s.surface).lightness)
              .abs();

      for (final brightness in [Brightness.dark, Brightness.light]) {
        final base = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
        final hc = applyHighContrast(base, brightness);
        expect(hc.surface.toARGB32(), isNot(base.surface.toARGB32()), reason: '$brightness surface');
        expect(
          hc.onSurface.toARGB32(),
          isNot(base.onSurface.toARGB32()),
          reason: '$brightness onSurface',
        );
        expect(spread(hc), greaterThan(0.8), reason: '$brightness 高对比度的明暗差应接近 1');
      }
    });

    testWidgets('设置真的到达界面：开高对比度后组件卡片变成不透明（且不描边）', (tester) async {
      tester.view.physicalSize = const Size(430, 1040);
      tester.view.devicePixelRatio = 1;

      Future<Card> firstCard() async {
        await tester.pumpWidget(const DesktopApp(mode: LaunchMode.desktop));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        return tester.widget<Card>(find.byType(Card).first);
      }

      _mockConfig = '';
      final normal = await firstCard();
      await tester.pumpWidget(const SizedBox());

      _mockConfig = '{"highContrast":true}';
      final high = await firstCard();
      await tester.pumpWidget(const SizedBox());

      // 高对比度：卡片不透明（alpha=1）+ 有描边
      expect((normal.color!.a * 255).round(), lessThan(255), reason: '普通模式卡片是半透明的');
      expect((high.color!.a * 255).round(), 255, reason: '高对比度下卡片应完全不透明');
      // 按用户要求：不要描边 —— 两种情况都不画边框
      expect((normal.shape as RoundedRectangleBorder).side.width, 0);
      expect(
        (high.shape as RoundedRectangleBorder).side.width,
        0,
        reason: '高对比度也不要描边',
      );
    });
  });

  group('本地壁纸取色必须走小图（「选完本地壁纸卡死」回归测试）', () {
    test('colorSourceImage 是 ResizeImage 且尺寸很小', () {
      final p = colorSourceImage(r'C:\x\big.jpg');
      expect(p, isA<ResizeImage>());
      final r = p as ResizeImage;
      expect(r.width, lessThanOrEqualTo(256));
      expect(r.height, lessThanOrEqualTo(256));
      expect(r.imageProvider, isA<FileImage>());
      expect(r.allowUpscaling, isFalse);
    });

    test('displayImage 也限制了解码宽度', () {
      final r = displayImage(r'C:\x\big.jpg') as ResizeImage;
      expect(r.width, 3840);
      expect(r.allowUpscaling, isFalse);
    });

    testWidgets('真的拿一张大图取色：必须几秒内完成（不能退化成全图量化）', (tester) async {
      await tester.runAsync(() async {
        // 造一张 3000x2000 的纯青绿 PNG 当作「用户的本地壁纸」
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 3000, 2000),
          Paint()..color = const Color(0xff00695c),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(3000, 2000);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        final file = File('${Directory.systemTemp.path}/mdesk-big-wallpaper.png')..writeAsBytesSync(png);
        expect(file.lengthSync(), greaterThan(10000));

        final sw = Stopwatch()..start();
        final scheme = await ColorScheme.fromImageProvider(
          provider: colorSourceImage(file.path),
          brightness: Brightness.dark,
        );
        sw.stop();
        // 走 112x112 小图时是毫秒级；若有人改回原图，这里会是几十秒
        expect(sw.elapsedMilliseconds, lessThan(5000), reason: '取色必须走小图路径，否则会卡死');
        // 纯青绿种子 → 主色色相应仍是青绿系
        final hue = HSLColor.fromColor(scheme.primary).hue;
        final expected = HSLColor.fromColor(const Color(0xff00695c)).hue;
        expect((hue - expected).abs(), lessThan(40));

        image.dispose();
        picture.dispose();
        file.deleteSync();
      });
    });
  });

  testWidgets('控制中心：壁纸画廊与外观开关齐全', (tester) async {
    // 这一页内容很长（画廊 + 主题 + 桌面组件设置），把测试视口放高一点，
    // 免得 ListView 只构建可见部分导致断言找不到控件。
    tester.view.physicalSize = const Size(1800, 2600);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const DesktopApp(mode: LaunchMode.settings));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('选择本地壁纸'), findsOneWidget);
    expect(find.text('壁纸自适应主题色'), findsOneWidget);
    expect(find.text('高对比度配色'), findsOneWidget);
    expect(find.text('内置壁纸'), findsOneWidget);
    for (final wp in builtinWallpapers) {
      expect(find.text(wp.name), findsOneWidget, reason: '画廊里应有「${wp.name}」');
    }
    // 缩略图是**预渲染的图片**，不是每帧重画的 CustomPaint
    // （CustomPaint 版实测会让控制中心常驻内存从 ~300MB 涨到 ~890MB）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(Image), findsAtLeast(8), reason: '8 张缩略图应是预渲染图片');

    // 切一张内置壁纸，不应抛异常
    await tester.tap(find.text('霓虹'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('控制中心：组件页可关时钟/开关预报', (tester) async {
    tester.view.physicalSize = const Size(1800, 1600);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const DesktopApp(mode: LaunchMode.settings));
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
    await tester.pumpWidget(const DesktopApp(mode: LaunchMode.settings));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('播放器连接'));
    await tester.pump();

    expect(find.text('100种生活'), findsOneWidget);
    expect(find.text('卢广仲'), findsOneWidget);
    expect(find.text('早安晨之美'), findsOneWidget);
    // 播放器声明 canSeek=false / duration=0 → 不能出现（假的）进度条
    expect(find.byType(Slider), findsNothing, reason: '没有时间轴就不该画进度条');
    final play = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.play_arrow_rounded));
    expect(play.onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('壁纸模式：三块组件用的是真实数据，没有演示数据', (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const DesktopApp(mode: LaunchMode.wallpaperWindow));
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
    await tester.pumpWidget(const DesktopApp(mode: LaunchMode.wallpaperWindow));
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
