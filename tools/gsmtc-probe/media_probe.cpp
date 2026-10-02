#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Control.h>
#include <iostream>
#include <fstream>
#include <winrt/Windows.Data.Json.h>
using namespace winrt;
using namespace Windows::Media::Control;
int main(){
 try {
  init_apartment(apartment_type::multi_threaded);
  auto manager=GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
  auto sessions=manager.GetSessions();
  std::wcout<<L"sessions="<<sessions.Size()<<L"\n";
  for(auto const& session:sessions){
   auto props=session.TryGetMediaPropertiesAsync().get();
   auto playback=session.GetPlaybackInfo();
   auto controls=playback.Controls();
   auto timeline=session.GetTimelineProperties();
   Windows::Data::Json::JsonObject json;
   json.SetNamedValue(L"source",Windows::Data::Json::JsonValue::CreateStringValue(session.SourceAppUserModelId()));
   json.SetNamedValue(L"title",Windows::Data::Json::JsonValue::CreateStringValue(props.Title()));
   json.SetNamedValue(L"artist",Windows::Data::Json::JsonValue::CreateStringValue(props.Artist()));
   json.SetNamedValue(L"status",Windows::Data::Json::JsonValue::CreateNumberValue((int)playback.PlaybackStatus()));
   json.SetNamedValue(L"play",Windows::Data::Json::JsonValue::CreateBooleanValue(controls.IsPlayEnabled()));
   json.SetNamedValue(L"pause",Windows::Data::Json::JsonValue::CreateBooleanValue(controls.IsPauseEnabled()));
   json.SetNamedValue(L"next",Windows::Data::Json::JsonValue::CreateBooleanValue(controls.IsNextEnabled()));
   json.SetNamedValue(L"previous",Windows::Data::Json::JsonValue::CreateBooleanValue(controls.IsPreviousEnabled()));
   json.SetNamedValue(L"seek",Windows::Data::Json::JsonValue::CreateBooleanValue(controls.IsPlaybackPositionEnabled()));
   json.SetNamedValue(L"positionSeconds",Windows::Data::Json::JsonValue::CreateNumberValue(timeline.Position().count()/10000000.0));
   json.SetNamedValue(L"durationSeconds",Windows::Data::Json::JsonValue::CreateNumberValue(timeline.EndTime().count()/10000000.0));
   std::ofstream(to_string(session.SourceAppUserModelId()).find("cloudmusic")!=std::string::npos ? "netease-session.json" : "media-session.json")<<to_string(json.Stringify());
   std::wcout<<L"source="<<session.SourceAppUserModelId().c_str()<<L"\n"
    <<L"title="<<props.Title().c_str()<<L"\nartist="<<props.Artist().c_str()<<L"\n"
    <<L"status="<<(int)playback.PlaybackStatus()<<L"\n"
    <<L"play="<<controls.IsPlayEnabled()<<L" pause="<<controls.IsPauseEnabled()
    <<L" next="<<controls.IsNextEnabled()<<L" previous="<<controls.IsPreviousEnabled()
    <<L" seek="<<controls.IsPlaybackPositionEnabled()<<L"\n"
    <<L"positionTicks="<<timeline.Position().count()<<L" endTicks="<<timeline.EndTime().count()<<L"\n";
  }
  return 0;
 }catch(hresult_error const& e){std::wcerr<<e.message().c_str()<<L" code="<<std::hex<<e.code().value<<L"\n";return 1;}
}
