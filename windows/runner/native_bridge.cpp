#include "native_bridge.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Storage.Streams.h>
#include <future>
#include <memory>
#include <shellapi.h>
#include <shlobj.h>
#include <commdlg.h>
#include <fstream>
#include <filesystem>
using namespace winrt;
using namespace Windows::Media::Control;
using namespace Windows::Storage::Streams;
using V=flutter::EncodableValue;
using M=flutter::EncodableMap;
static std::unique_ptr<flutter::MethodChannel<V>> channel;
static std::string artworkKey;      // 已成功取到封面的曲目 key
static std::string artworkMissKey;  // 取过图但没拿到的曲目 key
static int artworkMissCount = 0;
static std::vector<uint8_t> artwork;
// 窗口标题按模式区分：控制中心可以据此找到并关掉壁纸/组件进程。
static constexpr const wchar_t* kWallpaperTitle = L"material_desktop wallpaper";
static constexpr const wchar_t* kSettingsTitle  = L"material_desktop settings";
static constexpr const wchar_t* kDesktopTitle   = L"material_desktop desktop";

// ── 桌面组件模式（不依赖 Wallpaper Engine）───────────────────────────────
//
// 背景：Wallpaper Engine 的壁纸**在设计上就不接受鼠标交互**（官方文档里
// 只有 Scene 壁纸有 cursor 事件，Web 壁纸 API 没有鼠标接口），而且 Application
// 类壁纸未在文档中列出、2.8.42 起还下架了创意工坊分发。所以「桌面上可点击的
// 组件」只能由 EXE 自己做：
//   * 壁纸 → 渲染成 PNG，交给 Windows 自己当静态壁纸（零渲染开销，不卡）
//   * 组件 → 一个**很小**的透明无边框窗口，钉在桌面层（Progman 之上、
//            普通窗口之下），可以正常点击
static std::wstring ToWide(const std::string& utf8){
 if(utf8.empty()) return L"";
 int n=MultiByteToWideChar(CP_UTF8,0,utf8.c_str(),(int)utf8.size(),nullptr,0);
 std::wstring out((size_t)n,L'\0');
 MultiByteToWideChar(CP_UTF8,0,utf8.c_str(),(int)utf8.size(),out.data(),n);
 return out;
}

struct AccentPolicy{int state;int flags;int gradientColor;int animationId;};
struct CompositionAttribData{int attrib;void* data;SIZE_T size;};
constexpr int kWcaAccentPolicy=19;
constexpr int kAccentDisabled=0;
constexpr int kAccentTransparentGradient=2;
constexpr int kAccentBlurBehind=3;
constexpr int kAccentAcrylicBlurBehind=4;

// 让窗口背景真正透明（DWM 合成层生效）。Win10/11 都可用；
// 拿不到这个未文档化 API 时静默降级为「不透明组件条」，功能不受影响。
static void ApplyWindowTransparency(HWND hwnd,int accentState,int gradientColor){
 auto user32=GetModuleHandleW(L"user32.dll");
 if(!user32) return;
 using Fn=BOOL(WINAPI*)(HWND,CompositionAttribData*);
 auto fn=reinterpret_cast<Fn>(GetProcAddress(user32,"SetWindowCompositionAttribute"));
 if(!fn) return;
 AccentPolicy policy{accentState,2,gradientColor,0};
 CompositionAttribData data{kWcaAccentPolicy,&policy,sizeof(policy)};
 fn(hwnd,&data);
}

// 钉在桌面层：插到 Progman 之上（= 桌面图标之上、普通窗口之下）。
static void PinToDesktop(HWND hwnd){
 HWND progman=FindWindowW(L"Progman",nullptr);
 if(progman){
  SetWindowPos(hwnd,progman,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
 }else{
  SetWindowPos(hwnd,HWND_BOTTOM,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
 }
}
static std::filesystem::path ConfigDir(){
 PWSTR p=nullptr; SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&p);
 auto dir=std::filesystem::path(p?p:L".")/L"MaterialDesktop"; CoTaskMemFree(p);
 std::filesystem::create_directories(dir); return dir;
}
// 显示器物理像素矩形（进程是 DPI-aware，rcMonitor 就是真实物理像素）。
static RECT MonitorRect(HWND hwnd){
 auto mon=MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST);
 MONITORINFO mi{sizeof(mi)};
 if(mon && GetMonitorInfoW(mon,&mi)) return mi.rcMonitor;
 RECT r{0,0,GetSystemMetrics(SM_CXSCREEN),GetSystemMetrics(SM_CYSCREEN)};
 return r;
}
static RECT WorkRect(HWND hwnd){
 auto mon=MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST);
 MONITORINFO mi{sizeof(mi)};
 if(mon && GetMonitorInfoW(mon,&mi)) return mi.rcWork;
 return MonitorRect(hwnd);
}
// 文件选择对话框的状态。
//
// 为什么要放到独立线程：`GetOpenFileNameW` 是**模态**的，它会霸占调用线程的消息循环
// 直到用户关掉对话框。如果直接在平台线程里调，那么
//   ① 期间窗口的所有点击都进不来（表现就是「点了没反应」）；
//   ② 一旦对话框因为焦点/前台的原因开在别的窗口后面，用户看不到也关不掉，
//      平台线程就永远卡在里面 —— 程序彻底假死。
// 所以这里改成：起一个线程弹框、立刻返回；Dart 侧轮询 `pickWallpaperResult` 拿结果。
static std::atomic<bool> pickRunning{false};
static std::mutex pickMutex;
static std::string pickResult;
static bool pickDone = false;

static void StartPickDialog(HWND owner) {
 std::thread([owner] {
  // 对话框内部要用 COM，必须在它自己的线程里初始化（STA）
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  wchar_t buffer[32768] = {0};
  OPENFILENAMEW ofn = {sizeof(ofn)};
  ofn.hwndOwner = owner;
  ofn.lpstrFile = buffer;
  ofn.nMaxFile = 32768;
  ofn.lpstrFilter = L"Images\0*.jpg;*.jpeg;*.png;*.bmp;*.webp\0All files\0*.*\0";
  ofn.Flags = OFN_FILEMUSTEXIST | OFN_EXPLORER | OFN_NOCHANGEDIR;
  std::string picked;
  if (GetOpenFileNameW(&ofn)) picked = to_string(buffer);
  CoUninitialize();
  {
   std::lock_guard<std::mutex> lock(pickMutex);
   pickResult = picked;
   pickDone = true;
  }
  pickRunning = false;
 }).detach();
}

static M Media(std::string action,std::string source,double seconds){
 init_apartment(apartment_type::multi_threaded);
 auto manager=GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
 auto sessions=manager.GetSessions();
 GlobalSystemMediaTransportControlsSession selected{nullptr};
 flutter::EncodableList list;
 for(auto const& s:sessions){
  auto id=to_string(s.SourceAppUserModelId());
  list.emplace_back(id);
  if(!source.empty() && id==source) selected=s;
  if(source.empty() && id.find("cloudmusic")!=std::string::npos) selected=s;
 }
 if(!selected && source.empty()) selected=manager.GetCurrentSession();
 M out{{V("sources"),V(list)},{V("available"),V(bool(selected))}};
 if(!selected) return out;
 auto info=selected.GetPlaybackInfo(); auto c=info.Controls();
 if(action!="poll"){
  bool ok=false;
  if(action=="play" && c.IsPlayEnabled()) ok=selected.TryPlayAsync().get();
  else if(action=="pause" && c.IsPauseEnabled()) ok=selected.TryPauseAsync().get();
  else if(action=="next" && c.IsNextEnabled()) ok=selected.TrySkipNextAsync().get();
  else if(action=="previous" && c.IsPreviousEnabled()) ok=selected.TrySkipPreviousAsync().get();
  else if(action=="seek" && c.IsPlaybackPositionEnabled()) ok=selected.TryChangePlaybackPositionAsync((int64_t)(seconds*10000000)).get();
  out[V("commandAccepted")]=V(ok);
 }
 auto p=selected.TryGetMediaPropertiesAsync().get();
 auto t=selected.GetTimelineProperties();
 out[V("source")]=V(to_string(selected.SourceAppUserModelId()));
 out[V("title")]=V(to_string(p.Title())); out[V("artist")]=V(to_string(p.Artist()));
 out[V("album")]=V(to_string(p.AlbumTitle()));
 out[V("playing")]=V(info.PlaybackStatus()==GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing);
 out[V("canPlay")]=V(c.IsPlayEnabled()); out[V("canPause")]=V(c.IsPauseEnabled());
 out[V("canNext")]=V(c.IsNextEnabled()); out[V("canPrevious")]=V(c.IsPreviousEnabled());
 out[V("canSeek")]=V(c.IsPlaybackPositionEnabled());
 out[V("position")]=V(t.Position().count()/10000000.0);
 out[V("duration")]=V((t.EndTime()-t.StartTime()).count()/10000000.0);
 // 封面协议：**只在真的去读缩略图的那一次**把 `artwork` 放进返回结果，
 // 其余轮询只回 `artworkKey`。原因：Dart 侧每收到一次字节就会 new 一个 Uint8List，
 // 而 MemoryImage 的相等性看的是 bytes 的 identity —— 每秒回传一次封面，
 // Flutter 就会每秒重新解码一次图片，视觉上就是「封面一直在闪」（还白烧 CPU）。
 std::string key=to_string(selected.SourceAppUserModelId())+"|"+to_string(p.Title())+"|"+to_string(p.Artist());
 out[V("artworkKey")]=V(key);
 bool needArtwork=false;
 if(key!=artworkKey){
  // 换歌一定重取；同一首取图失败过则最多再试 3 次（缩略图有时慢一拍才就绪）
  if(key!=artworkMissKey || artworkMissCount<3) needArtwork=true;
 }
 if(needArtwork){
  std::vector<uint8_t> fresh;
  try{
   if(p.Thumbnail()){
    auto stream=p.Thumbnail().OpenReadAsync().get();
    if(stream.Size()>0 && stream.Size()<8*1024*1024){
     DataReader reader(stream); reader.LoadAsync((uint32_t)stream.Size()).get();
     fresh.resize((size_t)stream.Size());reader.ReadBytes(fresh);
    }
   }
  }catch(hresult_error const&){ fresh.clear(); }
  if(!fresh.empty()){
   artwork=std::move(fresh); artworkKey=key; artworkMissKey.clear(); artworkMissCount=0;
  }else{
   artwork.clear(); artworkKey.clear(); artworkMissKey=key; artworkMissCount++;
  }
  out[V("artwork")]=V(artwork);
 }
 return out;
}
void InstallNativeBridge(flutter::FlutterEngine* engine,HWND hwnd){
 channel=std::make_unique<flutter::MethodChannel<V>>(engine->messenger(),"material.desktop/native",&flutter::StandardMethodCodec::GetInstance());
 channel->SetMethodCallHandler([hwnd](auto const& call,auto result){
  try{
   auto name=call.method_name();
   M args; if(call.arguments() && std::holds_alternative<M>(*call.arguments())) args=std::get<M>(*call.arguments());
   auto str=[&](const char* k){auto it=args.find(V(k));return it!=args.end()&&std::holds_alternative<std::string>(it->second)?std::get<std::string>(it->second):std::string();};
   auto num=[&](const char* k,double def){auto it=args.find(V(k));return it!=args.end()&&std::holds_alternative<double>(it->second)?std::get<double>(it->second):def;};
   auto flag=[&](const char* k,bool def){auto it=args.find(V(k));return it!=args.end()&&std::holds_alternative<bool>(it->second)?std::get<bool>(it->second):def;};
   if(name=="media"){
    auto action=str("action");if(action.empty()) action="poll";
    double pos=0;auto it=args.find(V("seconds"));if(it!=args.end()&&std::holds_alternative<double>(it->second)) pos=std::get<double>(it->second);
    auto source=str("source");
    // WinRT get() must not run on the Flutter STA. Dedicated MTA does all media I/O.
    auto data=std::async(std::launch::async,[action,source,pos]{return Media(action,source,pos);}).get();
    result->Success(V(data));
   }else if(name=="readConfig"){
    std::ifstream file(ConfigDir()/L"settings.json");std::string s((std::istreambuf_iterator<char>(file)),{});result->Success(V(s));
   }else if(name=="writeConfig"){
    std::ofstream file(ConfigDir()/L"settings.json",std::ios::binary);file<<str("json");result->Success();
   }else if(name=="pickWallpaper"){
    // 立刻返回；对话框在独立线程里跑（见 StartPickDialog 注释）。
    // 已经有一个对话框开着时返回 false，避免叠出第二个。
    if(pickRunning.exchange(true)){ result->Success(V(false)); return; }
    {
     std::lock_guard<std::mutex> lock(pickMutex);
     pickResult.clear();
     pickDone=false;
    }
    StartPickDialog(hwnd);
    result->Success(V(true));
   }else if(name=="pickWallpaperResult"){
    // Dart 侧每 200ms 问一次：pending=false 表示这次选择已经结束（path 为空 = 取消）
    std::lock_guard<std::mutex> lock(pickMutex);
    M m{{V("pending"),V(!pickDone)},{V("path"),V(pickResult)}};
    if(pickDone){ pickDone=false; pickResult.clear(); pickRunning=false; }
    result->Success(V(m));
   }else if(name=="settings"){
    wchar_t exe[MAX_PATH];GetModuleFileNameW(nullptr,exe,MAX_PATH);
    ShellExecuteW(nullptr,L"open",exe,L"--settings",nullptr,SW_SHOWNORMAL);result->Success();
   }else if(name=="wallpaper"){
    // 壁纸模式：铺满**当前显示器**（用 rcMonitor 的物理像素，而不是
    // GetSystemMetrics —— 后者在混合 DPI / 多屏下会给出被虚拟化的尺寸，
    // 结果是 Flutter 视图比窗口大，右上角组件被挤到窗口外面）。
    // 注意：不做 SetParent(WorkerW)。此举是为了兼容 Wallpaper Engine 的
    // 应用程序壁纸（由 WE 负责桌面层级），独立运行时窗口就是一块全屏无边框窗口。
    RECT mon=MonitorRect(hwnd);
    LONG_PTR style=GetWindowLongPtrW(hwnd,GWL_STYLE);
    SetWindowLongPtrW(hwnd,GWL_STYLE,(style & ~WS_OVERLAPPEDWINDOW)|WS_POPUP|WS_VISIBLE);
    SetWindowPos(hwnd,HWND_TOP,mon.left,mon.top,mon.right-mon.left,mon.bottom-mon.top,
                 SWP_FRAMECHANGED|SWP_NOACTIVATE);
    SetWindowTextW(hwnd,kWallpaperTitle);
    result->Success();
   }else if(name=="settingsWindow"){
    // 控制中心：按 DPI 取一个舒服的逻辑尺寸并居中（默认 1280x720 物理像素
    // 在 175% 缩放的屏幕上是又小又挤的）。
    auto dpi=GetDpiForWindow(hwnd); double scale=dpi>0?dpi/96.0:1.0;
    RECT work=WorkRect(hwnd);
    int w=(int)(1360*scale), h=(int)(880*scale);
    int maxW=(int)((work.right-work.left)*0.94), maxH=(int)((work.bottom-work.top)*0.94);
    if(w>maxW) w=maxW;
    if(h>maxH) h=maxH;
    int x=work.left+((work.right-work.left)-w)/2;
    int y=work.top+((work.bottom-work.top)-h)/2;
    SetWindowPos(hwnd,HWND_TOP,x,y,w,h,SWP_FRAMECHANGED|SWP_NOACTIVATE);
    SetWindowTextW(hwnd,kSettingsTitle);
    result->Success();
   }else if(name=="windowInfo"){
    // 诊断用：窗口矩形 / 显示器矩形 / DPI 都按物理像素返回。
    RECT r{};GetWindowRect(hwnd,&r);RECT mon=MonitorRect(hwnd);
    M info{{V("left"),V((int)r.left)},{V("top"),V((int)r.top)},
           {V("right"),V((int)r.right)},{V("bottom"),V((int)r.bottom)},
           {V("width"),V((int)(r.right-r.left))},{V("height"),V((int)(r.bottom-r.top))},
           {V("monitorWidth"),V((int)(mon.right-mon.left))},{V("monitorHeight"),V((int)(mon.bottom-mon.top))},
           {V("dpi"),V((int)GetDpiForWindow(hwnd))}};
    result->Success(V(info));
   }else if(name=="desktopOverlay"){
    // 桌面组件的**透明可交互小窗口**：只有右侧组件条那么大，钉在桌面层。
    // 这样桌面上其它地方的图标/右键照常可用，组件自己可以点。
    double lw=num("width",420), lh=num("height",900);
    bool acrylic=flag("acrylic",false);
    auto dpi=GetDpiForWindow(hwnd); double scale=dpi>0?dpi/96.0:1.0;
    RECT work=WorkRect(hwnd);
    int pw=(int)(lw*scale), ph=(int)(lh*scale);
    int workH=work.bottom-work.top, workW=work.right-work.left;
    if(ph>workH-(int)(32*scale)) ph=workH-(int)(32*scale);
    if(pw>workW) pw=workW;
    int x=work.right-pw-(int)(24*scale);
    int y=work.top+(int)(24*scale);
    LONG_PTR style=GetWindowLongPtrW(hwnd,GWL_STYLE);
    SetWindowLongPtrW(hwnd,GWL_STYLE,(style & ~WS_OVERLAPPEDWINDOW)|WS_POPUP|WS_VISIBLE);
    // WS_EX_NOACTIVATE：点组件不抢焦点、不改变 z 序（否则一点就被顶到最前面）。
    // 鼠标消息照样送到窗口，所以按钮仍然可点。
    LONG_PTR ex=GetWindowLongPtrW(hwnd,GWL_EXSTYLE)|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE;
    SetWindowLongPtrW(hwnd,GWL_EXSTYLE,ex);
    SetWindowPos(hwnd,HWND_TOP,x,y,pw,ph,SWP_FRAMECHANGED|SWP_NOACTIVATE);
    SetWindowTextW(hwnd,kDesktopTitle);
    // 背景全透明；acrylic=true 时用亚克力（带模糊，看个人喜好）
    ApplyWindowTransparency(hwnd,acrylic?kAccentAcrylicBlurBehind:kAccentTransparentGradient,0x00000000);
    PinToDesktop(hwnd);
    result->Success();
   }else if(name=="reapplyTransparency"){
    // Explorer 重启 / 主题切换后重新贴一次
    ApplyWindowTransparency(hwnd,flag("acrylic",false)?kAccentAcrylicBlurBehind:kAccentTransparentGradient,0x00000000);
    PinToDesktop(hwnd);
    result->Success();
   }else if(name=="setWallpaperImage"){
    // 把渲染好的 PNG（或用户选的图片）交给 Windows 当静态壁纸：
    // 桌面不再需要任何实时渲染 → 这是解决「卡」的关键。
    // 不加 SPIF_SENDCHANGE：那会向所有窗口广播 WM_SETTINGCHANGE，实测要等 ~250ms
    // 才超时返回，而且这一步跑在平台线程上（期间点击事件进不来）。
    std::wstring path=ToWide(str("path"));
    if(path.empty()){ result->Success(V(false)); return; }
    BOOL ok=SystemParametersInfoW(SPI_SETDESKWALLPAPER,0,(PVOID)path.c_str(),SPIF_UPDATEINIFILE);
    result->Success(V(ok!=FALSE));
   }else if(name=="getWallpaperImage"){
    wchar_t buf[2048]={0};
    SystemParametersInfoW(SPI_GETDESKWALLPAPER,(UINT)(sizeof(buf)/sizeof(wchar_t)),buf,0);
    result->Success(V(to_string(buf)));
   }else if(name=="setAutostart"){
    bool enable=flag("enable",false);
    HKEY key=nullptr;
    if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,KEY_SET_VALUE,&key)!=ERROR_SUCCESS){
     result->Success(V(false)); return;
    }
    if(enable){
     wchar_t exe[MAX_PATH]={0}; GetModuleFileNameW(nullptr,exe,MAX_PATH);
     std::wstring cmd=L"\""+std::wstring(exe)+L"\"";
     RegSetValueExW(key,L"MaterialDesktop",0,REG_SZ,(const BYTE*)cmd.c_str(),(DWORD)((cmd.size()+1)*sizeof(wchar_t)));
    }else{
     RegDeleteValueW(key,L"MaterialDesktop");
    }
    RegCloseKey(key);
    result->Success(V(true));
   }else if(name=="quitWallpaper"){
    // 控制中心关掉独立运行的壁纸/组件进程（WE 托管时找不到窗口，返回 false）。
    HWND target=FindWindowW(nullptr,kWallpaperTitle);
    if(!target) target=FindWindowW(nullptr,kDesktopTitle);
    result->Success(V(target && PostMessageW(target,WM_CLOSE,0,0)));
   }else result->NotImplemented();
  }catch(hresult_error const& e){result->Error("WINDOWS_MEDIA",to_string(e.message()));}
   catch(std::exception const& e){result->Error("NATIVE_ERROR",e.what());}
 });
}
