import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Open-Meteo 天气数据（免 API Key）。
///
/// 项目原则：**只显示真实数据，绝不伪造**。取不到就报错让用户重试，
/// 不生成「演示数据」冒充实时天气。

class WeatherNow {
  const WeatherNow({
    required this.temperature,
    required this.feelsLike,
    required this.humidity,
    required this.wind,
    required this.code,
  });

  final double temperature;
  final double feelsLike;
  final double humidity;
  final double wind;
  final int code;
}

class WeatherHour {
  const WeatherHour({required this.time, required this.temperature, required this.code});

  final DateTime time;
  final double temperature;
  final int code;
}

class WeatherDay {
  const WeatherDay({required this.date, required this.code, required this.min, required this.max});

  final DateTime date;
  final int code;
  final double min;
  final double max;
}

class WeatherReport {
  const WeatherReport({required this.now, required this.hours, required this.days});

  final WeatherNow now;
  final List<WeatherHour> hours;
  final List<WeatherDay> days;
}

/// 中国大陆时区固定 +8（Open-Meteo 用 `timezone=Asia/Shanghai` 时返回的是**不带偏移的
/// 当地时刻字符串**，如 `2026-10-02T14:00`，按本地时刻字面解析即可，不要再做偏移换算）。

Future<WeatherReport> fetchWeather({
  required double latitude,
  required double longitude,
  int hourCount = 12,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '$latitude',
      'longitude': '$longitude',
      'current': 'temperature_2m,apparent_temperature,weather_code,relative_humidity_2m,wind_speed_10m',
      'hourly': 'temperature_2m,weather_code',
      'daily': 'weather_code,temperature_2m_max,temperature_2m_min',
      'timezone': 'Asia/Shanghai',
      'forecast_days': '7',
    });
    final req = await client.getUrl(uri);
    final response = await req.close().timeout(timeout);
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final data = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
    return parseWeather(data, hourCount: hourCount);
  } finally {
    client.close();
  }
}

/// 把 Open-Meteo 的 JSON 解析成模型（独立出来便于单元测试，不依赖网络）。
WeatherReport parseWeather(Map<String, dynamic> data, {int hourCount = 12}) {
  final current = (data['current'] as Map).cast<String, dynamic>();
  final now = WeatherNow(
    temperature: (current['temperature_2m'] as num).toDouble(),
    feelsLike: (current['apparent_temperature'] as num?)?.toDouble() ?? (current['temperature_2m'] as num).toDouble(),
    humidity: (current['relative_humidity_2m'] as num?)?.toDouble() ?? 0,
    wind: (current['wind_speed_10m'] as num?)?.toDouble() ?? 0,
    code: (current['weather_code'] as num?)?.toInt() ?? 0,
  );

  final hourly = (data['hourly'] as Map).cast<String, dynamic>();
  final times = (hourly['time'] as List).cast<String>();
  final temps = (hourly['temperature_2m'] as List).cast<num>();
  final codes = (hourly['weather_code'] as List).cast<num>();
  final all = <WeatherHour>[];
  for (var i = 0; i < times.length; i++) {
    if (i >= temps.length || i >= codes.length) {
      break;
    }
    all.add(
      WeatherHour(
        time: DateTime.parse(times[i]),
        temperature: temps[i].toDouble(),
        code: codes[i].toInt(),
      ),
    );
  }
  var start = all.indexWhere((h) => !h.time.isBefore(_parseApiTime(current['time'] as String?)));
  if (start < 0) {
    start = 0;
  }
  final hours = all.skip(start).take(hourCount).toList();

  final daily = (data['daily'] as Map).cast<String, dynamic>();
  final days = <WeatherDay>[];
  final dayTimes = (daily['time'] as List).cast<String>();
  final dayCodes = (daily['weather_code'] as List).cast<num>();
  final maxes = (daily['temperature_2m_max'] as List).cast<num>();
  final mins = (daily['temperature_2m_min'] as List).cast<num>();
  for (var i = 0; i < dayTimes.length; i++) {
    if (i >= dayCodes.length || i >= maxes.length || i >= mins.length) {
      break;
    }
    days.add(
      WeatherDay(
        date: DateTime.parse(dayTimes[i]),
        code: dayCodes[i].toInt(),
        min: mins[i].toDouble(),
        max: maxes[i].toDouble(),
      ),
    );
  }
  return WeatherReport(now: now, hours: hours, days: days);
}

DateTime _parseApiTime(String? text) {
  if (text == null || text.isEmpty) {
    return DateTime.now();
  }
  return DateTime.parse(text);
}

class GeoPlace {
  const GeoPlace({required this.name, required this.latitude, required this.longitude, this.detail = ''});

  final String name;
  final double latitude;
  final double longitude;
  final String detail;
}

Future<GeoPlace> geocodeCity(String name, {Duration timeout = const Duration(seconds: 8)}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(
      Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
        'name': name,
        'count': '1',
        'language': 'zh',
      }),
    );
    final res = await req.close().timeout(timeout);
    final data = jsonDecode(await utf8.decoder.bind(res).join()) as Map;
    final places = data['results'] as List?;
    if (places == null || places.isEmpty) {
      throw const FormatException('未找到该城市');
    }
    final place = places.first as Map;
    final detail = [place['admin1'], place['country']].where((v) => v != null && '$v'.isNotEmpty).join(' · ');
    return GeoPlace(
      name: '${place['name']}',
      latitude: (place['latitude'] as num).toDouble(),
      longitude: (place['longitude'] as num).toDouble(),
      detail: detail,
    );
  } finally {
    client.close();
  }
}

// ───────────────────────── WMO 天气代码 → 中文 / 图标 ─────────────────────────

String weatherLabel(int code) {
  if (code == 0) {
    return '晴';
  }
  if (code == 1) {
    return '大致晴朗';
  }
  if (code == 2) {
    return '多云';
  }
  if (code == 3) {
    return '阴';
  }
  if (code == 45 || code == 48) {
    return '有雾';
  }
  if (code >= 51 && code <= 57) {
    return '毛毛雨';
  }
  if (code >= 61 && code <= 65) {
    return '降雨';
  }
  if (code == 66 || code == 67) {
    return '冻雨';
  }
  if (code >= 71 && code <= 77) {
    return '降雪';
  }
  if (code >= 80 && code <= 82) {
    return '阵雨';
  }
  if (code == 85 || code == 86) {
    return '阵雪';
  }
  if (code >= 95) {
    return '雷暴';
  }
  return '未知';
}

IconData weatherIcon(int code) {
  if (code == 0 || code == 1) {
    return Icons.wb_sunny_outlined;
  }
  if (code == 2) {
    return Icons.wb_cloudy_outlined;
  }
  if (code == 3) {
    return Icons.cloud_outlined;
  }
  if (code == 45 || code == 48) {
    return Icons.foggy;
  }
  if (code >= 51 && code <= 57) {
    return Icons.grain;
  }
  if (code == 66 || code == 67) {
    return Icons.ac_unit;
  }
  if (code >= 71 && code <= 77) {
    return Icons.ac_unit;
  }
  if (code == 85 || code == 86) {
    return Icons.ac_unit;
  }
  if (code >= 95) {
    return Icons.thunderstorm_outlined;
  }
  return Icons.water_drop_outlined;
}

/// 星期几（`10月2日 星期五` 这种紧凑写法用得上）。
String weekdayLabel(DateTime d) => '星期${const ['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1]}';
