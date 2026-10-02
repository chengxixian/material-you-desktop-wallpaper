# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.1.0] - 2026-10-02

首个公开版本。Flutter (Windows) 桌面壁纸程序：无参数启动 = 壁纸模式，
`--settings` = 控制中心。

### 新增

- **壁纸模式**：全屏无边框窗口，按 `MonitorFromWindow` 的物理像素铺满当前显示器，
  右上角排布时钟 / 天气 / 媒体三块 Material 3 组件。
- **8 张程序化绘制的内置壁纸**（流体渐变 / 极光 / 森林 / 海洋 / 日落 / 霓虹 / 几何 / 山峦）：
  零图片资源、离线可用、任意分辨率不糊；画廊缩略图、480ms 交叉淡入、5–120 分钟定时轮换。
- **本地图片壁纸**：文件选择器 + `BoxFit.cover`。
- **Material You 动态取色**（三级优先级）：固定色 → 本地图片 `ColorScheme.fromImageProvider`
  真取色 → 内置壁纸自带 seed；支持深色/浅色、Material 3 `contrastLevel` 高对比度、8 个预设固定色。
- **天气**：Open-Meteo 当前温度 / 体感 / 湿度 / 风速 + **未来 5 天预报** + **未来 12 小时温度曲线**
  （自绘 `CustomPaint`），城市走 Open-Meteo Geocoding。
- **媒体控制**：Windows GSMTC 真实元数据（歌名 / 歌手 / 专辑 / 封面 / 播放状态），
  播放暂停、上一首、下一首、跳转按播放器声明的能力启停。
- **控制中心**：三个页签（壁纸与外观 / 桌面组件 / 播放器连接）、DPI 自适应窗口尺寸并居中、
  `--tab=N` 可直达页签、可关闭独立运行的壁纸进程。
- **Wallpaper Engine 接入**：`tools/we-mount.ps1` 一键「打包进 WE 工程 + 挂载 + 验证 + 还原」。
- 配置落盘 `%LOCALAPPDATA%\MaterialDesktop\settings.json`，壁纸进程每秒重读，改设置立即生效。

### 修复

- **音乐封面一直在闪**：原生桥原先每秒都把封面字节回传一次，Dart 侧每收到一次就
  `new` 一个 `Uint8List`，而 `MemoryImage` 的相等性看的是 bytes 的 identity ——
  于是 `Image` 每秒都被判定成新 provider、**每秒重新解码一次封面**。
  现在原生只在「换歌」那一次回传字节（其余轮询只回 `artworkKey`，取图失败最多重试 3 次），
  Dart 侧用 `ArtworkCache` 缓存同一个实例，并补了回归测试与
  `tools/check-artwork-flicker.ps1` 真实抓帧验证；顺带省掉每秒 100KB 的无效传输与解码。
- 启动模式：原先「无参数 = 控制中心」会让 Wallpaper Engine 挂载时弹出设置窗口。
  现在**无参数 = 壁纸模式**，只有显式 `--settings` 才是控制中心，并用单元测试锁死这条约定。
- `AnimatedSwitcher` 的子节点约束是 loose 的，未显式撑满的 `CustomPaint`
  会按 `Size.zero` 布局，导致换壁纸后**整张壁纸不再绘制**（壁纸层改用 `size: Size.infinite`）。
- 壁纸窗口尺寸原先取 `GetSystemMetrics(SM_CXSCREEN)`，在混合 DPI / 多屏下会拿到被虚拟化的
  尺寸，右上角组件可能被挤到窗口外；改用 `MonitorFromWindow` + `GetMonitorInfo(...).rcMonitor`。
- 控制中心窗口原先固定 1280x720 **物理像素**，在 175% 缩放的屏幕上又小又挤；
  改为按 DPI 取 1360x880 逻辑像素并居中。
- 原生侧 `.cpp` 含中文注释时 MSVC 按 CP936 解码会报 C4819（在 warnings-as-errors 下直接失败），
  已加 `/utf-8`。

### 说明

- 媒体控件的能力边界来自 GSMTC：**不提供音量、循环模式、音频频谱**，
  因此界面不显示这三类控件，也不做假进度条。
- 天气需要联网；取不到数据时显示可点击的重试提示，不生成演示数据。
