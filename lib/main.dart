import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/wallpaper_catalog.dart';
import 'src/weather.dart' as wx;

const native = MethodChannel('material.desktop/native');

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动模式约定：
  //   `--settings`  → 控制中心（普通窗口）
  //   其它/无参数    → 壁纸模式（全屏无边框）
  // 之所以把「无参数」定为壁纸模式：Wallpaper Engine 的「应用程序壁纸」
  // 只会启动 project.json 里写的 exe，**不会附加任何命令行参数**，
  // 双击 exe 的用户想要的也是壁纸本身。控制中心必须显式加 --settings。
  runApp(
    DesktopApp(
      settingsMode: settingsModeFor(args),
      initialTab: initialTabFor(args),
    ),
  );
}

/// 启动模式判定（抽成纯函数，便于单元测试锁死这条 WE 关键约定）：
/// 只有显式传 `--settings` 才是控制中心，其它一律壁纸模式。
bool settingsModeFor(List<String> args) => args.contains('--settings');

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
  final bool settingsMode;
  final int initialTab;
  const DesktopApp({super.key, required this.settingsMode, this.initialTab = 0});
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
  int tab = 0;
  int _rotation = 0;
  final cityController = TextEditingController();

  bool get isWallpaper => !widget.settingsMode;

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
      if (isWallpaper) {
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

  Future<void> save() async {
    await native.invokeMethod('writeConfig', {'json': jsonEncode(config)});
    await extractColor();
    scheduleRotation();
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
        final palette = await ColorScheme.fromImageProvider(
          provider: FileImage(File(path)),
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
    });
  }

  Future<void> poll([String action = 'poll', double seconds = 0]) async {
    if (busy) {
      return;
    }
    if (config['music'] != true && tab != 2 && action == 'poll') {
      return;
    }
    busy = true;
    try {
      final result = await native.invokeMapMethod<String, dynamic>('media', {
        'action': action,
        'source': config['source'] ?? '',
        'seconds': seconds,
      });
      if (isWallpaper) {
        // 壁纸进程跟着控制中心改配置：壁纸/取色/组件开关都会实时生效。
        final text = await native.invokeMethod<String>('readConfig');
        if (text != null && text.isNotEmpty) {
          final next = jsonDecode(text) as Map<String, dynamic>;
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

  ThemeData theme() => ThemeData(
    useMaterial3: true,
    fontFamily: 'Microsoft YaHei UI',
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: config['dark'] == true ? Brightness.dark : Brightness.light,
      // Material 3 的高对比度不是另一个 variant，而是 contrastLevel（0–1）。
      contrastLevel: config['highContrast'] == true ? 0.5 : 0.0,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: widget.settingsMode ? 'Material Desktop · 控制中心' : 'Material Desktop Wallpaper',
      theme: theme(),
      home: Builder(builder: (context) => widget.settingsMode ? controlCenter(context) : wallpaper(context)),
    );
  }

  // ─────────────────────────────── 壁纸层 ───────────────────────────────

  Widget wallpaperLayer() {
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
          ? Image.file(
              File(path),
              key: ValueKey('file:$path'),
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
                  tooltip: '打开控制中心（控制中心里可退出壁纸）',
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
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainer.withValues(alpha: .94),
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
            '${wx.weekdayLabel(now)}  /  ${now.hour < 12
                ? '慢慢开始新的一天'
                : now.hour < 18
                ? '留一点时间给自己'
                : '享受宁静的夜晚'}',
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
                      '${config['city']}  ·  ${r == null ? '实时天气' : wx.weatherLabel(code)}',
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
                      available && '${media['title']}'.isNotEmpty ? '${media['title']}' : '等待播放器',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      available ? '${media['artist'] ?? ''}' : '打开网易云并播放一首歌',
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
            Text(
              '此播放器未提供时间轴 · 不显示虚假进度',
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
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
    final cs = Theme.of(context).colorScheme;
    const titles = ['你的桌面，你的色彩', '让桌面保持简洁', '真实媒体，不是演示'];
    const subtitles = [
      '内置 8 张壁纸可切换，Material You 配色会跟着壁纸变化，也可以自己选图。',
      '时钟、天气、媒体三块组件都能单独开关，设置保存后壁纸自动同步。',
      '通过 Windows GSMTC 对指定播放器读取与控制，不做假进度、假可视化。',
    ];
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
                Text(titles[tab], style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w400)),
                const SizedBox(height: 8),
                Text(subtitles[tab], style: TextStyle(color: cs.onSurfaceVariant)),
                const SizedBox(height: 32),
                ...switch (tab) { 0 => _appearanceTab(context), 1 => _widgetsTab(context), _ => _playerTab(context) },
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 页签 0：壁纸与外观 ──
  List<Widget> _appearanceTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLocal = '${config['wallpaper']}'.isNotEmpty;
    return [
      SizedBox(
        height: 270,
        child: ClipRRect(borderRadius: BorderRadius.circular(24), child: wallpaperLayer()),
      ),
      const SizedBox(height: 12),
      Text(
        isLocal
            ? '当前：本地图片 · ${config['wallpaper']}'
            : '当前：内置「${currentWallpaper.name}」 —— ${currentWallpaper.description}',
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
                    child: CustomPaint(painter: wp.painter()),
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
              final path = await native.invokeMethod<String>('pickWallpaper');
              if (path != null && path.isNotEmpty) {
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
            label: const Text('启动壁纸预览'),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final ok = await native.invokeMethod<bool>('quitWallpaper') ?? false;
              messenger.showSnackBar(
                SnackBar(content: Text(ok ? '已请求关闭壁纸进程' : '没有找到独立运行的壁纸进程（可能由 Wallpaper Engine 托管）')),
              );
            },
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('关闭壁纸进程'),
          ),
        ],
      ),
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
        subtitle: const Text('本地图片用 ColorScheme.fromImageProvider 真取色；内置壁纸用其自带 seed'),
        value: config['autoColor'] == true,
        onChanged: (v) {
          config['autoColor'] = v;
          save();
        },
      ),
      SwitchListTile(
        title: const Text('高对比度配色'),
        subtitle: const Text('ColorScheme.fromSeed(dynamicSchemeVariant: highContrast)'),
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
      const SizedBox(height: 20),
      const Text(
        '独立使用：双击 EXE 即为壁纸模式（全屏无边框），控制中心请用 --settings 启动（或点壁纸右下角的调节按钮）。\n'
        'Wallpaper Engine 接入：创建「应用程序」类型壁纸，选择本包 material_desktop.exe —— WE 不会附加参数，因此无参数启动就是壁纸模式。',
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
      const SizedBox(height: 24),
      const Text(
        '支持：真实歌名、歌手、专辑、封面、播放状态，以及播放器声明支持的播放/暂停、上一首、下一首与跳转。\n\n'
        '网易云当前会话未开放时间轴和跳转，因此不会伪造进度条。控制返回 false 时会显示失败提示。\n\n'
        'GSMTC 的能力边界：不提供音量、循环模式、音频频谱，所以本项目也不显示这三类假控件。',
      ),
    ];
  }
}

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
