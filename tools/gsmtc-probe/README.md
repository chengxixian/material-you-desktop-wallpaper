# GSMTC 探针（排查 Windows 媒体会话用）

`media_probe.cpp` 是一个**不依赖 Flutter** 的最小控制台程序：直接调
`GlobalSystemMediaTransportControlsSessionManager`，把系统里每一个媒体会话的
来源 / 歌名 / 歌手 / 播放状态 / **各控制项是否可用**（play / pause / next /
previous / seek）打印出来，并把结果写成 JSON。

排查「为什么界面上的跳转按钮是灰的」「时间轴为什么是 0」这类问题时，
先用它确认**播放器到底开放了哪些能力**，比在 Flutter 里猜快得多。

## 编译

需要 MSVC（VS2022 Build Tools 即可）+ Windows SDK：

```powershell
# 在 "x64 Native Tools Command Prompt for VS" 里执行
cl /std:c++17 /EHsc /utf-8 media_probe.cpp /link windowsapp.lib /out:media_probe.exe
```

> `/utf-8` 不能省：文件里有中文注释，不指定时代码页 936 会把 UTF-8 字节解坏。

## 运行

```powershell
.\media_probe.exe
```

输出示例（本机实测，网易云正在播放）：

```
sessions=2
source=cloudmusic.exe
title=100种生活
artist=卢广仲
status=5
play=true pause=true next=true previous=true seek=false
positionTicks=0 endTicks=0
```

同时会在**当前工作目录**生成：

* `netease-session.json` —— 来源名含 `cloudmusic` 的会话
* `media-session.json` —— 其它会话

`seek=false / endTicks=0` 就是界面不画进度条的原因：网易云当前会话没开放
时间轴与跳转，程序不会伪造一个。
