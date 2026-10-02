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
// 窗口标题按模式区分：控制中心可以据此找到并关掉壁纸进程。
static constexpr const wchar_t* kWallpaperTitle = L"material_desktop wallpaper";
static constexpr const wchar_t* kSettingsTitle  = L"material_desktop settings";
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
    wchar_t buffer[32768]={0};OPENFILENAMEW ofn={sizeof(ofn)};ofn.hwndOwner=hwnd;ofn.lpstrFile=buffer;ofn.nMaxFile=32768;
    ofn.lpstrFilter=L"Images\0*.jpg;*.jpeg;*.png;*.bmp;*.webp\0All files\0*.*\0";ofn.Flags=OFN_FILEMUSTEXIST|OFN_EXPLORER;
    result->Success(V(GetOpenFileNameW(&ofn)?to_string(buffer):""));
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
   }else if(name=="quitWallpaper"){
    // 控制中心关掉独立运行的壁纸进程（WE 托管时找不到窗口，返回 false）。
    HWND target=FindWindowW(nullptr,kWallpaperTitle);
    result->Success(V(target && PostMessageW(target,WM_CLOSE,0,0)));
   }else result->NotImplemented();
  }catch(hresult_error const& e){result->Error("WINDOWS_MEDIA",to_string(e.message()));}
   catch(std::exception const& e){result->Error("NATIVE_ERROR",e.what());}
 });
}
