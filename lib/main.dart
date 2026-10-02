import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/wallpaper_catalog.dart';
import 'src/weather.dart' as wx;

const native = MethodChannel('material.desktop/native');

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(DesktopApp(mode: launchModeFor(args), initialTab: initialTabFor(args)));
  // 诊断/自动化用：启动后自动弹一次文件选择框（用来验证「对话框不阻塞窗口」）
  if (args.contains('--pick-test')) {
    Future<void>.delayed(
      const Duration(milliseconds: 800),
      () => pickWallpaperInteractively(),
    );
  }
}

/// 启动模式。
///
/// | 命令行 | 模式 | 说明 |
/// |---|---|---|
/// | 无参数 / `--desktop` | [LaunchMode.desktop] | **默认**：Windows 静态壁纸 + 可交互组件条 |
/// | `--wallpaper` | [LaunchMode.wallpaperWindow] | 全屏壁纸窗口（给 Wallpaper Engine / 预览用，不可交互） |
/// | `--settings` | [LaunchMode.settings] | 控制中心 |
///
/// 「无参数」为什么是桌面组件模式：双击 exe 的用户要的就是桌面上的那套东西；
/// 而 Wallpaper Engine 的「应用程序壁纸」不传参数，所以它拿到的是
/// [LaunchMode.desktop] —— 但 WE 壁纸在设计上不接受鼠标交互（官方 Web API 没有
/// 鼠标接口，只有 Scene 壁纸有 cursor 事件），要交互就得用桌面模式本身。
enum LaunchMode { desktop, wallpaperWindow, settings }

LaunchMode launchModeFor(List<String> args) {
  if (args.contains('--settings')) {
    return LaunchMode.settings;
  }
  if (args.contains('--wallpaper')) {
    return LaunchMode.wallpaperWindow;
  }
  return LaunchMode.desktop;
}

/// 只有显式传 `--settings` 才是控制中心（单元测试锁死这条约定）。
bool settingsModeFor(List<String> args) => launchModeFor(args) == LaunchMode.settings;

/// `--tab=N`：控制中心直接落在第 N 个页签（截图/自动化验证用，越界回 0）。
int initialTabFor(List<String> args) {
  for (final a in args) {
    if (a.startsWith('--tab=')) {
      final n = int.tryParse(a.substring(6));
      if (n != null && n >= 0 && n < 3) {
        return n;
      }
    }
  }
  return 0;
}

/// 默认配置。新增字段时只要写进这里，老配置文件缺项也能自动补齐。
const Map<String, dynamic> defaultConfig = {
  'wallpaper': '', // 本地图片路径；非空时优先于内置壁纸
  'wallpaperId': 'mesh', // 内置壁纸 id（见 src/wallpaper_catalog.dart）
  'rotate': false, // 定时轮换内置壁纸
  'rotateMinutes': 30,
  'dark': true,
  'autoColor': true, // 跟随壁纸取色
  'highContrast': false,
  'seedColor': '', // 固定主题色 #RRGGBB，关闭自动取色时生效
  'clock': true,
  'clock24h': true,
  'clockSeconds': false,
  'weather': true,
  'weatherDays': true, // 5 天预报
  'weatherChart': true, // 未来 12 小时温度曲线
  'music': true,
  'source': 'cloudmusic.exe',
  'city': '北京',
  'latitude': 39.9075,
  'longitude': 116.3972,
  // ── 桌面组件模式 ──
  'panelOpacity': 0.88, // 组件卡片的背景不透明度（窗口本身是真透明的）
  'acrylic': false, // 组件条用亚克力模糊而不是纯透明
  'autostart': false, // 开机自动启动（写 HKCU\...\Run）
  'prevWallpaper': '', // 首次进入桌面模式时记下用户原来的壁纸，退出时还原
};

/// 预设固定主题色（取自 Material 3 常用种子色）。
const List<(String, Color)> presetSeeds = [
  ('紫', Color(0xff6750a4)),
  ('蓝', Color(0xff0b57d0)),
  ('青', Color(0xff00696d)),
  ('绿', Color(0xff2e7d5b)),
  ('黄', Color(0xff8a6d00)),
  ('橙', Color(0xffb3261e)),
  ('粉', Color(0xffb90063)),
  ('灰', Color(0xff5a5f66)),
];

/// 专辑封面缓存。
///
/// **为什么要它**：原生桥只在「换歌」时回传 `artwork` 字节，其余轮询只回
/// `artworkKey`。如果每秒都把字节塞进新的 `Uint8List`，`MemoryImage` 的相等性
/// （看 bytes 的 identity）就会每秒变化一次，Flutter 于是每秒重新解码图片 ——
/// 表现就是**封面一直在闪**，同时白白消耗 CPU。
/// 这里缓存住同一个 `Uint8List` 实例，只在曲目变化时才换。
class ArtworkCache {
  Uint8List? bytes;
  String key = '';

  /// 用一次 `media` 响应更新缓存。`artwork` 存在 = 这一次原生真的去取图了
  /// （`Uint8List(0)` 表示取图失败）。
  void update(Map<String, dynamic> media) {
    final nextKey = '${media['artworkKey'] ?? ''}';
    final art = media['artwork'];
    if (art is Uint8List) {
      key = nextKey;
      bytes = art.isEmpty ? null : art;
    } else if (nextKey != key) {
      // 换歌了但这次没带封面（取图失败）→ 清掉旧封面，避免张冠李戴
      key = nextKey;
      bytes = null;
    }
  }

  void clear() {
    bytes = null;
    key = '';
  }
}

class DesktopApp extends StatefulWidget {
  final LaunchMode mode;
  final int initialTab;
  const DesktopApp({super.key, required this.mode, this.initialTab = 0});
  @override
  State<DesktopApp> createState() => _DesktopAppState();
}

class _DesktopAppState extends State<DesktopApp> {
  Map<String, dynamic> config = Map<String, dynamic>.of(defaultConfig);
  Map<String, dynamic> media = {};
  final artworkCache = ArtworkCache();
  wx.WeatherReport? report;
  String? mediaError, weatherError;
  Color seed = const Color(0xff6750a4);
  DateTime now = DateTime.now();
  Timer? timer, rotateTimer;
  bool busy = false;
  DateTime? _pollStartedAt;
  int tab = 0;
  int _rotation = 0;
  String _appliedWallpaperKey = '';
  // 画廊缩略图 / 大预览：**预渲染成 PNG 缓存**，不在每帧重画 CustomPaint。
  // 实测：8 张内置壁纸若用 CustomPaint 直接画，控制中心常驻内存会从 ~300MB 涨到 ~890MB
  // （每帧重画渐变/光斑不断产生离屏层），换成预渲染图片后回到 ~300MB。
  final Map<String, Uint8List> _thumbs = {};
  final Map<String, Uint8List> _previews = {};
  bool _renderingThumbs = false;
  bool _renderingPreview = false;
  final cityController = TextEditingController();

  bool get isWallpaper => widget.mode == LaunchMode.wallpaperWindow;
  bool get isDesktop => widget.mode == LaunchMode.desktop;
  bool get isSettings => widget.mode == LaunchMode.settings;

  @override
  void initState() {
    super.initState();
    tab = widget.initialTab;
    load();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => now = DateTime.now());
      }
      poll();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    rotateTimer?.cancel();
    cityController.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final text = await native.invokeMethod<String>('readConfig');
      if (text != null && text.isNotEmpty) {
        final saved = jsonDecode(text) as Map<String, dynamic>;
        // 只接受已知字段，避免老配置里的垃圾键把默认值带偏。
        saved.forEach((k, v) {
          if (defaultConfig.containsKey(k)) {
            config[k] = v;
          }
        });
      }
    } catch (e) {
      mediaError = '读取配置失败：$e';
    }
    cityController.text = '${config['city']}';
    try {
      if (isDesktop) {
        // 只占右侧组件条那么大，透明 + 钉在桌面层（详见原生 desktopOverlay）
        await native.invokeMethod('desktopOverlay', {
          'width': desktopRailWidth,
          'height': desktopRailHeight,
          'acrylic': config['acrylic'] == true,
        });
        await applyDesktopWallpaper(); // 静态壁纸：桌面不再实时渲染 → 不卡
      } else if (isWallpaper) {
        await native.invokeMethod('wallpaper');
      } else {
        await native.invokeMethod('settingsWindow');
      }
    } catch (e) {
      mediaError = '窗口初始化失败：$e';
    }
    await extractColor();
    if (mounted) {
      setState(() {});
    }
    scheduleRotation();
    poll();
    fetchWeather();
  }

  /// 把当前壁纸交给 Windows 当**静态壁纸**。
  ///
  /// 这是解决「卡」的关键：桌面由系统自己绘制，我们的进程只在右侧小窗口里画组件，
  /// 不再有一块全屏 Flutter 画面在跑。内置壁纸按显示器物理分辨率渲染成 PNG。
  Future<void> applyDesktopWallpaper({bool force = false}) async {
    final userPath = '${config['wallpaper']}';
    try {
      final info = await native.invokeMapMethod<String, dynamic>('windowInfo');
      final w = ((info?['monitorWidth'] as num?)?.toInt() ?? 2560).clamp(640, 7680);
      final h = ((info?['monitorHeight'] as num?)?.toInt() ?? 1600).clamp(480, 4320);
      final wp = currentWallpaper;
      final key = userPath.isNotEmpty ? 'file:$userPath' : 'builtin:${wp.id}:${w}x$h';
      // 同一个壁纸不重复设置：SPI_SETDESKWALLPAPER 会刷新桌面并写注册表，没必要每次都做
      if (!force && key == _appliedWallpaperKey) {
        return;
      }
      // ⚠️ 必须在**设置之前**记录用户原来的壁纸，否则读回来的是我们自己刚设进去的 PNG。
      //   另外要排除我们自己生成的路径（配置目录里那些 wallpaper-*.png）。
      if ('${config['prevWallpaper']}'.isEmpty) {
        final prev = await native.invokeMethod<String>('getWallpaperImage');
        final isOurs = prev == null || prev.isEmpty || prev.contains('MaterialDesktop');
        if (!isOurs) {
          config['prevWallpaper'] = prev;
          await native.invokeMethod('writeConfig', {'json': jsonEncode(config)});
        }
      }
      if (userPath.isNotEmpty && File(userPath).existsSync()) {
        await native.invokeMethod('setWallpaperImage', {'path': userPath});
      } else {
        final file = File('${configDirPath()}${Platform.pathSeparator}wallpaper-${wp.id}-${w}x$h.png');
        // 缓存文件要校验：太小说明是坏文件/占位文件（比如测试桩写进去的 1x1 PNG）
        if (!file.existsSync() || file.lengthSync() < 4096) {
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(await wallpaperPngRenderer(wp, w, h));
        }
        await native.invokeMethod('setWallpaperImage', {'path': file.path});
      }
      _appliedWallpaperKey = key;
    } catch (e) {
      mediaError = '设置桌面壁纸失败：$e';
    }
  }

  /// 退出桌面组件模式：还原原壁纸 + 关掉组件进程。
  Future<void> exitDesktopMode() async {
    final prev = '${config['prevWallpaper']}';
    try {
      if (prev.isNotEmpty) {
        await native.invokeMethod('setWallpaperImage', {'path': prev});
      }
    } catch (_) {}
    config['prevWallpaper'] = '';
    await native.invokeMethod('writeConfig', {'json': jsonEncode(config)});
    await native.invokeMethod('quitWallpaper');
  }

  /// 预渲染 8 张内置壁纸的缩略图（只做一次，之后画廊用 `Image.memory` 显示）。
  Future<void> ensureThumbnails() async {
    if (_renderingThumbs || _thumbs.length == builtinWallpapers.length) {
      return;
    }
    _renderingThumbs = true;
    try {
      for (final wp in builtinWallpapers) {
        if (_thumbs.containsKey(wp.id)) {
          continue;
        }
        try {
          final bytes = await wallpaperPngRenderer(wp, 480, 300);
          if (!mounted) {
            return;
          }
          setState(() => _thumbs[wp.id] = bytes);
        } catch (_) {
          // 单张失败不影响其它缩略图
        }
      }
    } finally {
      _renderingThumbs = false;
    }
  }

  /// 预渲染当前内置壁纸的大预览图。
  Future<void> ensurePreview() async {
    final id = currentWallpaper.id;
    if (_renderingPreview || '${config['wallpaper']}'.isNotEmpty || _previews.containsKey(id)) {
      return;
    }
    _renderingPreview = true;
    try {
      final bytes = await wallpaperPngRenderer(currentWallpaper, 1000, 625);
      if (mounted) {
        setState(() => _previews[id] = bytes);
      }
    } catch (_) {
      // 失败就显示占位块
    } finally {
      _renderingPreview = false;
    }
  }

  Future<void> save() async {
    await native.invokeMethod('writeConfig', {'json': jsonEncode(config)});
    await extractColor();
    scheduleRotation();
    // 桌面模式：改了壁纸就把新的 PNG 重新交给系统（内容变了才真正写盘/刷新桌面）
    if (isDesktop) {
      await applyDesktopWallpaper();
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// 主题种子色的优先级：
  ///   1. 关掉「自适应」且设了固定色 → 用固定色
  ///   2. 自适应 + 本地图片壁纸       → 用 `ColorScheme.fromImageProvider` 真取色
  ///   3. 其它                       → 用内置壁纸自带的 seed（无需解码图片）
  Future<void> extractColor() async {
    final fixed = parseHexColor('${config['seedColor']}');
    if (config['autoColor'] != true && fixed != null) {
      seed = fixed;
      return;
    }
    final path = '${config['wallpaper']}';
    if (config['autoColor'] == true && path.isNotEmpty && File(path).existsSync()) {
      try {
        // 注意这里是 112x112 的小图，不是原图（原因见 colorSourceImage 的注释）
        final palette = await ColorScheme.fromImageProvider(
          provider: colorSourceImage(path),
          brightness: config['dark'] == true ? Brightness.dark : Brightness.light,
        );
        seed = palette.primary;
        return;
      } catch (_) {
        // 取色失败就退回内置 seed，不留白。
      }
    }
    seed = wallpaperById('${config['wallpaperId']}').seed;
  }

  BuiltinWallpaper get currentWallpaper => wallpaperById('${config['wallpaperId']}');

  void scheduleRotation() {
    rotateTimer?.cancel();
    final minutes = (config['rotateMinutes'] as num?)?.toInt() ?? 30;
    if (config['rotate'] != true || minutes <= 0) {
      return;
    }
    rotateTimer = Timer.periodic(Duration(minutes: minutes), (_) {
      if (!mounted || '${config['wallpaper']}'.isNotEmpty) {
        return;
      }
      final list = builtinWallpapers;
      _rotation = (_rotation + 1) % list.length;
      config['wallpaperId'] = list[_rotation].id;
      extractColor();
      setState(() {});
      // 桌面模式：换壁纸 = 重新生成 PNG 交给系统（不是实时渲染）
      if (isDesktop) {
        applyDesktopWallpaper();
      }
    });
  }

  Future<void> poll([String action = 'poll', double seconds = 0]) async {
    if (busy) {
      // 兜底：平台调用万一长时间不返回（文件对话框是模态的、驱动/系统调用卡住等），
      // busy 会永远为 true → 媒体再也不会刷新。超过 6 秒就当作超时，放行一次。
      final started = _pollStartedAt;
      if (started != null && DateTime.now().difference(started) < const Duration(seconds: 6)) {
        return;
      }
      busy = false;
    }
    if (config['music'] != true && tab != 2 && action == 'poll') {
      return;
    }
    busy = true;
    _pollStartedAt = DateTime.now();
    try {
      final result = await native.invokeMapMethod<String, dynamic>('media', {
        'action': action,
        'source': config['source'] ?? '',
        'seconds': seconds,
      });
      // 常驻进程（全屏壁纸窗口 / 桌面组件条）都要跟着控制中心改配置。
      // ⚠️ 这里曾经只判断 isWallpaper（全屏壁纸窗口），结果**桌面组件模式完全不生效**：
      //    控制中心换了壁纸/主题/组件开关，桌面上的组件条毫无反应
      //    （「切本地壁纸不生效」「高对比度没效果」都是这个原因）。
      if (isWallpaper || isDesktop) {
        final text = await native.invokeMethod<String>('readConfig');
        if (text != null && text.isNotEmpty) {
          final next = jsonDecode(text) as Map<String, dynamic>;
          final prevWallpaper = '${config['wallpaper']}';
          final prevId = '${config['wallpaperId']}';
          final needsColor =
              next['wallpaper'] != config['wallpaper'] ||
              next['wallpaperId'] != config['wallpaperId'] ||
              next['autoColor'] != config['autoColor'] ||
              next['seedColor'] != config['seedColor'];
          next.forEach((k, v) {
            if (defaultConfig.containsKey(k)) {
              config[k] = v;
            }
          });
          if (needsColor) {
            await extractColor();
          }
          // 桌面模式：换壁纸要重新渲染 PNG 并交给 Windows —— 组件条进程才是
          // 真正设置桌面壁纸的那个，所以必须在这里重新应用。
          if (isDesktop && (prevWallpaper != '${config['wallpaper']}' || prevId != '${config['wallpaperId']}')) {
            await applyDesktopWallpaper(force: true);
          }
          // 高对比度 / 深浅色 / 不透明度这类变化 → 重建界面
          if (mounted) {
            setState(() {});
          }
        }
      }
      if (mounted) {
        setState(() {
          media = result ?? {};
          artworkCache.update(media);
          mediaError = action != 'poll' && media['commandAccepted'] != true ? '播放器未接受该指令' : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => mediaError = '媒体接口不可用：$e');
      }
    } finally {
      busy = false;
    }
  }

  Future<void> fetchWeather() async {
    if (config['weather'] != true) {
      return;
    }
    try {
      final data = await wx.fetchWeather(
        latitude: (config['latitude'] as num).toDouble(),
        longitude: (config['longitude'] as num).toDouble(),
      );
      if (mounted) {
        setState(() {
          report = data;
          weatherError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          report = null;
          weatherError = '天气暂时不可用 · 点击重试';
        });
      }
    }
  }

  Future<void> changeCity() async {
    try {
      final place = await wx.geocodeCity(cityController.text.trim());
      config['city'] = place.name;
      config['latitude'] = place.latitude;
      config['longitude'] = place.longitude;
      await save();
      await fetchWeather();
    } catch (e) {
      if (mounted) {
        setState(() => weatherError = '城市查询失败：$e');
      }
    }
  }

  // ─────────────────────────────── 主题 ───────────────────────────────

  ThemeData theme() {
    final dark = config['dark'] == true;
    final brightness = dark ? Brightness.dark : Brightness.light;
    var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    if (config['highContrast'] == true) {
      // fromSeed 的 contrastLevel 实测无效，见 applyHighContrast 注释
      scheme = applyHighContrast(scheme, brightness);
    }
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Microsoft YaHei UI',
      colorScheme: scheme,
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.mode) {
      LaunchMode.settings => 'Material Desktop · 控制中心',
      LaunchMode.desktop => 'Material Desktop Desktop Widgets',
      LaunchMode.wallpaperWindow => 'Material Desktop Wallpaper',
    };
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: title,
      theme: theme(),
      home: Builder(
        builder: (context) => switch (widget.mode) {
          LaunchMode.settings => controlCenter(context),
          LaunchMode.wallpaperWindow => wallpaper(context),
          LaunchMode.desktop => desktopWidgets(context),
        },
      ),
    );
  }

  // ─────────────────────────── 桌面组件模式 ───────────────────────────
  //
  // 窗口只有右侧一条（原生 desktopOverlay 设置成透明 + 钉在桌面层），
  // 所以这里**不能**铺任何全屏背景：背景留空 = 透明 = 看到 Windows 壁纸。
  // 壁纸本身由 applyDesktopWallpaper() 交给系统静态显示。

  Widget desktopWidgets(BuildContext context) {
    return Scaffold(
      // 关键：窗口背景必须透明，否则整块变成不透明方块
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (config['clock'] == true) clockCard(context),
              if (config['weather'] == true) ...[
                const SizedBox(height: 14),
                weatherCard(context),
              ],
              if (config['music'] == true) ...[
                const SizedBox(height: 14),
                musicCard(context),
              ],
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton.filledTonal(
                    tooltip: '控制中心',
                    onPressed: () => native.invokeMethod('settings'),
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────── 壁纸层 ───────────────────────────────

  Widget wallpaperLayer({int previewMaxWidth = 3840}) {
    final path = '${config['wallpaper']}';
    // 交叉淡入：换壁纸不闪白。
    // ⚠️ AnimatedSwitcher 内部是 `Stack`，给子节点的约束是 **loose** 的：
    // 不显式撑满的话 `CustomPaint` 会按 `Size.zero` 布局 —— 结果就是
    // 「壁纸层整块不画」，只剩 Scaffold 的黑底。所以这里必须 size: infinity /
    // width+height: infinity。
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 480),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: path.isNotEmpty
          ? Image(
              key: ValueKey('file:$path'),
              image: displayImage(path, maxWidth: previewMaxWidth),
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => CustomPaint(
                key: ValueKey('builtin:${currentWallpaper.id}'),
                size: Size.infinite,
                painter: currentWallpaper.painter(),
              ),
            )
          : CustomPaint(
              key: ValueKey('builtin:${currentWallpaper.id}'),
              size: Size.infinite,
              painter: currentWallpaper.painter(),
            ),
    );
  }

  Widget wallpaper(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, box) {
          final w = (box.maxWidth * .23).clamp(300.0, 400.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              wallpaperLayer(),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0x00000000), Color(0x770b1513)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
              ),
              Positioned(
                top: 36,
                right: 36,
                width: w,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (config['clock'] == true) clockCard(context),
                      if (config['weather'] == true) ...[
                        const SizedBox(height: 16),
                        weatherCard(context),
                      ],
                      if (config['music'] == true) ...[
                        const SizedBox(height: 16),
                        musicCard(context),
                      ],
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 36,
                bottom: 28,
                child: IconButton.filledTonal(
                  tooltip: '控制中心',
                  onPressed: () => native.invokeMethod('settings'),
                  icon: const Icon(Icons.tune_rounded),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget panel(BuildContext context, Widget child) {
    final cs = Theme.of(context).colorScheme;
    final highContrast = config['highContrast'] == true;
    // 高对比度下卡片改为**不透明**（靠配色本身拉开对比，不加描边）：
    // 组件条是浮在壁纸上的半透明卡片，透明度是深色壁纸上看不清的主因。
    final opacity = highContrast
        ? 1.0
        : ((config['panelOpacity'] as num?)?.toDouble() ?? .94).clamp(.3, 1.0);
    return Card(
      color: cs.surfaceContainer.withValues(alpha: opacity),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      margin: EdgeInsets.zero,
      child: Padding(padding: const EdgeInsets.all(24), child: child),
    );
  }

  // ─────────────────────────────── 时钟组件 ───────────────────────────────

  Widget clockCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final h24 = config['clock24h'] != false;
    final seconds = config['clockSeconds'] == true;
    final hour12 = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final hh = h24 ? now.hour.toString().padLeft(2, '0') : hour12.toString().padLeft(2, '0');
    final suffix = h24 ? '' : (now.hour < 12 ? ' AM' : ' PM');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    return panel(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text('LOCAL TIME', style: TextStyle(fontSize: 10, letterSpacing: 2, color: cs.primary)),
              const Spacer(),
              Text('${now.month} 月 ${now.day} 日', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 16),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$hh:$mm${seconds ? ':$ss' : ''}$suffix',
              style: TextStyle(
                fontSize: 76,
                height: 1.1,
                fontWeight: FontWeight.w300,
                letterSpacing: -4,
                // 等宽数字：走秒时整行不抖动。
                fontFeatures: const [FontFeature.tabularFigures()],
                color: cs.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            wx.weekdayLabel(now),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────── 天气组件 ───────────────────────────────

  Widget weatherCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final code = r?.now.code ?? 0;
    if (config['weather'] != true) {
      return const SizedBox.shrink();
    }
    return panel(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(r == null ? Icons.cloud_outlined : wx.weatherIcon(code), size: 42, color: cs.primary),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r == null ? '${config['city']}' : '${config['city']}  ·  ${wx.weatherLabel(code)}',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      r != null ? '${r.now.temperature.round()}°' : '—',
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w400),
                    ),
                    if (r != null)
                      Text(
                        '体感 ${r.now.feelsLike.round()}°  ·  风 ${r.now.wind.toStringAsFixed(1)} m/s',
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              if (r != null)
                Text(
                  '${r.now.humidity.round()}%\n湿度',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, height: 1.6, color: cs.onSurfaceVariant),
                ),
            ],
          ),
          if (weatherError != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: InkWell(
                onTap: fetchWeather,
                child: Text(weatherError!, style: TextStyle(fontSize: 10, color: cs.error)),
              ),
            ),
          if (r != null && config['weatherDays'] == true && r.days.isNotEmpty) ...[
            const SizedBox(height: 14),
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: .4)),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final day in r.days.take(5))
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          day.date.day == now.day ? '今天' : wx.weekdayLabel(day.date).substring(2),
                          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(height: 6),
                        Icon(wx.weatherIcon(day.code), size: 18, color: cs.primary),
                        const SizedBox(height: 6),
                        Text('${day.max.round()}°', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        Text(
                          '${day.min.round()}°',
                          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
          if (r != null && config['weatherChart'] == true && r.hours.length > 1) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 56,
              child: CustomPaint(
                size: Size.infinite,
                painter: _SparklinePainter(
                  values: r.hours.map((h) => h.temperature).toList(),
                  labels: r.hours.map((h) => '${h.time.hour}').toList(),
                  color: cs.primary,
                  gridColor: cs.outlineVariant,
                  textColor: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─────────────────────────────── 音乐组件 ───────────────────────────────

  Widget musicCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final available = media['available'] == true;
    final playing = media['playing'] == true;
    final duration = (media['duration'] as num?)?.toDouble() ?? 0;
    final pos = (media['position'] as num?)?.toDouble() ?? 0;
    final art = artworkCache.bytes;
    Widget button(
      IconData icon,
      String label,
      String action,
      bool enabled, {
      bool primary = false,
    }) => IconButton(
      style: primary
          ? IconButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              disabledBackgroundColor: cs.surfaceContainerHighest,
            )
          : null,
      tooltip: label,
      onPressed: enabled ? () => poll(action) : null,
      icon: Icon(icon, size: primary ? 28 : 22),
    );
    return panel(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('NOW PLAYING', style: TextStyle(fontSize: 10, letterSpacing: 2, color: cs.primary)),
              const Spacer(),
              Text(
                media['source'] == 'cloudmusic.exe'
                    ? '网易云音乐'
                    : available
                    ? '系统媒体'
                    : '未连接',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: art != null
                    ? Image.memory(
                        art,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        // 同一个 Uint8List 实例会在多次轮询间复用，所以这里其实
                        // 不会重新解码；gaplessPlayback 只是换歌那一帧的保险。
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => artFallback(cs),
                      )
                    : artFallback(cs),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      available && '${media['title']}'.isNotEmpty ? '${media['title']}' : '未播放',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      available ? '${media['artist'] ?? ''}' : '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                    if (available && '${media['album'] ?? ''}'.isNotEmpty)
                      Text(
                        '${media['album']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (duration > 0) ...[
            Slider(
              value: pos.clamp(0.0, duration),
              max: duration,
              onChanged: media['canSeek'] == true ? (v) => poll('seek', v) : null,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(timeText(pos), style: const TextStyle(fontSize: 10)),
                Text(timeText(duration), style: const TextStyle(fontSize: 10)),
              ],
            ),
          ] else
            const SizedBox(height: 4),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              button(Icons.skip_previous_rounded, '上一首', 'previous', media['canPrevious'] == true),
              const SizedBox(width: 18),
              button(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                playing ? '暂停' : '播放',
                playing ? 'pause' : 'play',
                playing ? media['canPause'] == true : media['canPlay'] == true,
                primary: true,
              ),
              const SizedBox(width: 18),
              button(Icons.skip_next_rounded, '下一首', 'next', media['canNext'] == true),
            ],
          ),
          if (mediaError != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(mediaError!, style: TextStyle(fontSize: 10, color: cs.error)),
            ),
        ],
      ),
    );
  }

  Widget artFallback(ColorScheme cs) => Container(
    width: 72,
    height: 72,
    color: cs.primaryContainer,
    child: Icon(Icons.music_note_rounded, color: cs.onPrimaryContainer, size: 32),
  );

  String timeText(double seconds) => '${seconds ~/ 60}:${(seconds.toInt() % 60).toString().padLeft(2, '0')}';

  // ─────────────────────────────── 控制中心 ───────────────────────────────

  Widget controlCenter(BuildContext context) {
    // 标题就是导航栏那一项的名字：只用来定位，不放任何说明性文案
    const titles = ['壁纸与外观', '桌面组件', '播放器连接'];
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            extended: true,
            minExtendedWidth: 220,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('Material Desktop', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            ),
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.wallpaper_rounded), label: Text('壁纸与外观')),
              NavigationRailDestination(icon: Icon(Icons.widgets_rounded), label: Text('桌面组件')),
              NavigationRailDestination(icon: Icon(Icons.library_music_rounded), label: Text('播放器连接')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(40),
              children: [
                Text(titles[tab], style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w400)),
                const SizedBox(height: 28),
                ...switch (tab) { 0 => _appearanceTab(context), 1 => _widgetsTab(context), _ => _playerTab(context) },
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 桌面组件模式设置 ──
  Widget _desktopSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('桌面组件模式', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: () => Process.start(Platform.resolvedExecutable, const []),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('打开桌面组件'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await exitDesktopMode();
                messenger.showSnackBar(const SnackBar(content: Text('已退出桌面组件并还原原壁纸')));
              },
              icon: const Icon(Icons.logout_rounded),
              label: const Text('退出桌面组件（还原原壁纸）'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(width: 16),
            const Text('组件背景不透明度'),
            Expanded(
              child: Slider(
                value: ((config['panelOpacity'] as num?)?.toDouble() ?? .88).clamp(.3, 1.0),
                min: .3,
                max: 1,
                divisions: 14,
                label: '${(((config['panelOpacity'] as num?)?.toDouble() ?? .88) * 100).round()}%',
                onChanged: (v) {
                  setState(() => config['panelOpacity'] = v);
                },
                onChangeEnd: (_) => save(),
              ),
            ),
          ],
        ),
        SwitchListTile(
          title: const Text('组件条用亚克力模糊'),
          subtitle: const Text('重开桌面组件后生效'),
          value: config['acrylic'] == true,
          onChanged: (v) async {
            setState(() => config['acrylic'] = v);
            await save();
            await native.invokeMethod('reapplyTransparency', {'acrylic': v});
          },
        ),
        SwitchListTile(
          title: const Text('开机自动启动桌面组件'),
          value: config['autostart'] == true,
          onChanged: (v) async {
            setState(() => config['autostart'] = v);
            await save();
            await native.invokeMethod('setAutostart', {'enable': v});
          },
        ),
      ],
    );
  }

  // ── 页签 0：壁纸与外观 ──
  List<Widget> _appearanceTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLocal = '${config['wallpaper']}'.isNotEmpty;
    // 进来就补渲染（异步，渲染好会 setState 刷新）
    if (!isLocal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ensureThumbnails();
        ensurePreview();
      });
    }
    final preview = _previews[currentWallpaper.id];
    return [
      SizedBox(
        height: 270,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: isLocal
              ? wallpaperLayer(previewMaxWidth: 1600)
              : (preview != null
                    ? Image.memory(preview, fit: BoxFit.cover, gaplessPlayback: true)
                    : const ColoredBox(color: Color(0xFF3A3A3A))),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        isLocal
            ? '当前：本地图片 · ${config['wallpaper']}'
            : '当前：${currentWallpaper.name}',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      const SizedBox(height: 20),
      Text('内置壁纸', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
      const SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.55,
        children: [
          for (final wp in builtinWallpapers)
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                config['wallpaper'] = '';
                config['wallpaperId'] = wp.id;
                save();
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: _thumbs[wp.id] != null
                        ? Image.memory(_thumbs[wp.id]!, fit: BoxFit.cover, gaplessPlayback: true)
                        : const ColoredBox(color: Color(0xFF3A3A3A)),
                  ),
                  if (!isLocal && config['wallpaperId'] == wp.id)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: cs.primary, width: 3),
                      ),
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.check_circle_rounded, size: 20, color: cs.primary),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      color: Colors.black.withValues(alpha: .45),
                      child: Text(
                        wp.name,
                        style: const TextStyle(fontSize: 11, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FilledButton.icon(
            onPressed: () async {
              // 非阻塞：对话框在原生侧独立线程里跑，这里轮询结果
              final path = await pickWallpaperInteractively();
              if (path.isNotEmpty) {
                config['wallpaper'] = path;
                await save();
              }
            },
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('选择本地壁纸'),
          ),
          OutlinedButton.icon(
            onPressed: () {
              config['wallpaper'] = '';
              save();
            },
            icon: const Icon(Icons.restore),
            label: const Text('恢复内置壁纸'),
          ),
          OutlinedButton.icon(
            onPressed: () => Process.start(Platform.resolvedExecutable, ['--wallpaper']),
            icon: const Icon(Icons.desktop_windows),
            label: const Text('启动全屏壁纸窗口'),
          ),
          OutlinedButton.icon(
            onPressed: () => Process.start(Platform.resolvedExecutable, const []),
            icon: const Icon(Icons.widgets_outlined),
            label: const Text('启动桌面组件'),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await applyDesktopWallpaper(force: true);
              messenger.showSnackBar(const SnackBar(content: Text('已把当前壁纸设为 Windows 静态壁纸')));
            },
            icon: const Icon(Icons.wallpaper_rounded),
            label: const Text('应用为桌面壁纸'),
          ),
        ],
      ),
      const SizedBox(height: 24),
      _desktopSection(context),
      const SizedBox(height: 24),
      SwitchListTile(
        title: const Text('深色主题'),
        value: config['dark'] == true,
        onChanged: (v) {
          config['dark'] = v;
          save();
        },
      ),
      SwitchListTile(
        title: const Text('壁纸自适应主题色'),
        value: config['autoColor'] == true,
        onChanged: (v) {
          config['autoColor'] = v;
          save();
        },
      ),
      SwitchListTile(
        title: const Text('高对比度配色'),
        value: config['highContrast'] == true,
        onChanged: (v) {
          config['highContrast'] = v;
          save();
        },
      ),
      const SizedBox(height: 8),
      Text('固定主题色（关闭「自适应」后生效）', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final item in presetSeeds)
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                config['autoColor'] = false;
                config['seedColor'] = '#${item.$2.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
                save();
              },
              child: Tooltip(
                message: item.$1,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: item.$2,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: parseHexColor('${config['seedColor']}') == item.$2 && config['autoColor'] != true
                          ? cs.onSurface
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 24),
      SwitchListTile(
        title: const Text('定时轮换内置壁纸'),
        value: config['rotate'] == true,
        onChanged: (v) {
          config['rotate'] = v;
          save();
        },
      ),
      if (config['rotate'] == true)
        ListTile(
          title: const Text('轮换间隔'),
          trailing: DropdownButton<int>(
            value: const [5, 15, 30, 60, 120].contains((config['rotateMinutes'] as num?)?.toInt())
                ? (config['rotateMinutes'] as num).toInt()
                : 30,
            items: const [
              DropdownMenuItem(value: 5, child: Text('5 分钟')),
              DropdownMenuItem(value: 15, child: Text('15 分钟')),
              DropdownMenuItem(value: 30, child: Text('30 分钟')),
              DropdownMenuItem(value: 60, child: Text('1 小时')),
              DropdownMenuItem(value: 120, child: Text('2 小时')),
            ],
            onChanged: (v) {
              config['rotateMinutes'] = v ?? 30;
              save();
            },
          ),
        ),


    ];
  }

  // ── 页签 1：桌面组件 ──
  List<Widget> _widgetsTab(BuildContext context) {
    return [
      for (final item in [('clock', '时钟'), ('weather', '天气'), ('music', '媒体播放器')])
        SwitchListTile(
          title: Text(item.$2),
          value: config[item.$1] == true,
          onChanged: (v) {
            config[item.$1] = v;
            save();
          },
        ),
      const Divider(height: 32),
      Text('时钟', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      SwitchListTile(
        title: const Text('24 小时制'),
        value: config['clock24h'] != false,
        onChanged: (v) {
          config['clock24h'] = v;
          save();
        },
      ),
      SwitchListTile(
        title: const Text('显示秒'),
        value: config['clockSeconds'] == true,
        onChanged: (v) {
          config['clockSeconds'] = v;
          save();
        },
      ),
      const Divider(height: 32),
      Text('天气', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      SwitchListTile(
        title: const Text('显示未来 5 天预报'),
        value: config['weatherDays'] == true,
        onChanged: (v) {
          config['weatherDays'] = v;
          save();
        },
      ),
      SwitchListTile(
        title: const Text('显示未来 12 小时温度曲线'),
        value: config['weatherChart'] == true,
        onChanged: (v) {
          config['weatherChart'] = v;
          save();
        },
      ),
      const SizedBox(height: 12),
      TextField(
        controller: cityController,
        decoration: const InputDecoration(labelText: '天气城市', border: OutlineInputBorder()),
        onSubmitted: (_) => changeCity(),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 12,
          children: [
            FilledButton(onPressed: changeCity, child: const Text('查询并保存城市')),
            OutlinedButton.icon(
              onPressed: fetchWeather,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新天气'),
            ),
          ],
        ),
      ),
      if (weatherError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(weatherError!)),
      const SizedBox(height: 24),
      weatherCard(context),
    ];
  }

  // ── 页签 2：播放器连接 ──
  List<Widget> _playerTab(BuildContext context) {
    return [
      DropdownButtonFormField<String>(
        initialValue: (media['sources'] as List?)?.contains(config['source']) == true
            ? config['source'] as String
            : '',
        items: [
          const DropdownMenuItem(value: '', child: Text('跟随系统当前播放器')),
          for (final id in (media['sources'] as List? ?? []))
            DropdownMenuItem(value: '$id', child: Text(id == 'cloudmusic.exe' ? '网易云音乐 · $id' : '$id')),
        ],
        onChanged: (v) {
          config['source'] = v ?? '';
          save();
          poll();
        },
        decoration: const InputDecoration(labelText: '目标媒体会话', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: poll,
          icon: const Icon(Icons.refresh),
          label: const Text('重新枚举媒体会话'),
        ),
      ),
      const SizedBox(height: 24),
      musicCard(context),


    ];
  }
}

/// 桌面组件条的逻辑尺寸（原生会按 DPI 换算成物理像素，并夹到工作区内）。
const double desktopRailWidth = 420;
const double desktopRailHeight = 1020;

/// 配置目录（与原生 `ConfigDir()` 保持一致：%LOCALAPPDATA%\MaterialDesktop）。
/// 测试里会把它指到临时目录，避免测试产物写进真实配置目录。
String? configDirOverride;

String configDirPath() {
  if (configDirOverride != null) {
    return configDirOverride!;
  }
  final base = Platform.environment['LOCALAPPDATA'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return '$base${Platform.pathSeparator}MaterialDesktop';
}

/// 把内置壁纸按**显示器物理分辨率**渲染成 PNG，交给 Windows 当静态壁纸。
///
/// 静态壁纸是「不卡」的关键：桌面由系统绘制，程序只在右侧小窗口里画组件。
Future<Uint8List> renderWallpaperPng(BuiltinWallpaper wallpaper, int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  wallpaper.painter().paint(canvas, Size(width.toDouble(), height.toDouble()));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// 壁纸 PNG 渲染入口。抽成可替换的变量是为了 widget 测试：
/// `Picture.toImage()` 依赖引擎的真实异步任务，在 flutter_test 的 FakeAsync
/// 区域里**永远不会完成**（直接挂住），所以测试里替换成同步桩。
/// 真实渲染由 `renderWallpaperPng` 自己负责（测试用 `tester.runAsync` 覆盖）。
Future<Uint8List> Function(BuiltinWallpaper wallpaper, int width, int height) wallpaperPngRenderer = renderWallpaperPng;

/// 弹系统文件选择框并返回选中的路径（空字符串 = 取消）。
///
/// 原生侧把对话框放在**独立线程**里跑并立即返回，平台线程不再被模态框阻塞
/// （旧实现直接在平台线程里 `GetOpenFileNameW`：对话框一旦开在别的窗口后面，
/// 用户看不到又关不掉，平台线程就永远卡住 → 整个窗口「点击无反应」）。
/// 这里每 200ms 轮询一次结果。
Future<String> pickWallpaperInteractively({Duration timeout = const Duration(minutes: 5)}) async {
  final started = await native.invokeMethod<bool>('pickWallpaper') ?? false;
  if (!started) {
    return ''; // 已经有一个对话框在开着，忽略这次点击
  }
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final r = await native.invokeMapMethod<String, dynamic>('pickWallpaperResult');
    if (r == null) {
      continue;
    }
    if (r['pending'] != true) {
      return '${r['path'] ?? ''}';
    }
  }
  return '';
}

/// 高对比度配色。
///
/// ⚠️ **不能用 `ColorScheme.fromSeed(contrastLevel: …)`**：实测在 Flutter 3.47.5 上
/// 它是**无效参数** —— `contrastLevel: 0.0` 与 `0.5` 生成的 `surface` 逐位相同
/// （回归测试见 `test/widget_test.dart` 的「高对比度」组）。所以这里自己算：
/// 按明暗把「表面色」再压深/提亮，把「文字色」往反方向拉开，边界色也更明显。
ColorScheme applyHighContrast(ColorScheme scheme, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  // 直接按明度**拉到两端**：之前只挪 6%/18%，而深色主题的 surface 本来就在 L≈0.12、
  // 文字已接近纯白，被 clamp 后几乎看不出变化（用户反馈「没生效」就是这个原因）。
  Color push(Color c, double target, [double amount = 1.0]) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness + (target - hsl.lightness) * amount).clamp(0.0, 1.0)).toColor();
  }

  final surfaceTarget = dark ? 0.0 : 1.0; // 卡片底：压到纯黑 / 提到纯白
  final onTarget = dark ? 1.0 : 0.0; // 文字：纯白 / 纯黑
  return scheme.copyWith(
    surface: push(scheme.surface, surfaceTarget, 0.85),
    surfaceContainerLowest: push(scheme.surfaceContainerLowest, surfaceTarget, 0.85),
    surfaceContainerLow: push(scheme.surfaceContainerLow, surfaceTarget, 0.85),
    surfaceContainer: push(scheme.surfaceContainer, surfaceTarget, 0.85),
    surfaceContainerHigh: push(scheme.surfaceContainerHigh, surfaceTarget, 0.85),
    surfaceContainerHighest: push(scheme.surfaceContainerHighest, surfaceTarget, 0.85),
    onSurface: push(scheme.onSurface, onTarget, 1.0),
    onSurfaceVariant: push(scheme.onSurfaceVariant, onTarget, 0.8),
    // 描边拉到明显可见（组件条是浮在壁纸上的，有边框才看得出对比度）
    outline: push(scheme.outline, onTarget, 0.75),
    outlineVariant: push(scheme.outlineVariant, onTarget, 0.7),
    // 强调色更亮/更暗，主按钮更跳
    primary: push(scheme.primary, dark ? 0.85 : 0.25, 0.6),
    onPrimary: push(scheme.onPrimary, dark ? 0.0 : 1.0, 0.6),
    error: push(scheme.error, dark ? 0.8 : 0.3, 0.5),
  );
}

/// 给「跟随壁纸取色」用的图片 provider。
///
/// ⚠️ **必须先缩到很小再取色**：`ColorScheme.fromImageProvider` 内部会把解码后
/// 图片的**每一个像素**都交给 `QuantizerCelebi` 量化。直接丢一张原图（比如
/// 6000x4000 = 2400 万像素，还要先分配 ~96MB 的 RGBA 缓冲）进去，主 isolate
/// 会被算力活卡住几十秒甚至几分钟 —— 用户看到的就是「选完本地壁纸就卡死」。
///
/// `ResizeImage` 会把 targetWidth/targetHeight 交给解码器，**解码阶段就缩到
/// 112x112**（1.2 万像素），量化瞬间完成，颜色结果和原图取色一致。
ImageProvider colorSourceImage(String path, {int size = 112}) => ResizeImage(
  FileImage(File(path)),
  width: size,
  height: size,
  policy: ResizeImagePolicy.fit,
  allowUpscaling: false,
);

/// 展示用的大图：也要限一下解码尺寸，否则一张 2400 万像素的照片会被解码成
/// ~96MB 的位图（全屏壁纸模式下白白吃内存、掉帧）。
ImageProvider displayImage(String path, {int maxWidth = 3840}) =>
    ResizeImage(FileImage(File(path)), width: maxWidth, allowUpscaling: false);

/// 解析 `#RRGGBB` / `#AARRGGBB`；非法输入返回 null。
Color? parseHexColor(String text) {
  var t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  if (t.startsWith('#')) {
    t = t.substring(1);
  }
  if (t.length == 6) {
    t = 'ff$t';
  }
  if (t.length != 8) {
    return null;
  }
  final v = int.tryParse(t, radix: 16);
  return v == null ? null : Color(v);
}

/// 未来 12 小时温度曲线（纯 CustomPaint，不引第三方图表库）。
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.labels,
    required this.color,
    required this.gridColor,
    required this.textColor,
  });

  final List<double> values;
  final List<String> labels;
  final Color color;
  final Color gridColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) {
      return;
    }
    const padY = 6.0;
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final span = (maxV - minV).abs() < .1 ? 1.0 : (maxV - minV);
    final dx = size.width / (values.length - 1);
    final points = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(i * dx, size.height - padY - ((values[i] - minV) / span) * (size.height - padY * 2)),
    ];

    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      line.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      Path.from(line)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close(),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .35), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    canvas.drawCircle(points.last, 3, Paint()..color = color);

    // 每 3 小时标一个刻度
    for (var i = 0; i < labels.length; i += 3) {
      final tp = TextPainter(
        text: TextSpan(text: '${labels[i]}时', style: TextStyle(fontSize: 9, color: textColor)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(points[i].dx - tp.width / 2, size.height - tp.height));
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.color != color || old.values.length != values.length || !_sameValues(old.values, values);

  bool _sameValues(List<double> a, List<double> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
