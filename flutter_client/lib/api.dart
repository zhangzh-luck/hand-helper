import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://hand.zhangzh.cc',
);
const pendingLocalPhotoKey = 'pending_local_photo_key_v1';

typedef PasskeyAssertionProvider = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> publicKey,
);
typedef PasskeyRegistrationProvider = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> publicKey,
);

class PasskeyCredentialInfo {
  const PasskeyCredentialInfo({
    required this.id,
    required this.label,
    required this.deviceType,
    required this.backedUp,
    required this.createdAt,
    this.lastUsedAt,
  });

  factory PasskeyCredentialInfo.fromJson(Map<String, dynamic> json) {
    final createdAt = DateTime.tryParse(json['created_at'] as String? ?? '');
    final lastUsed = json['last_used_at'];
    if (json['id'] is! int ||
        json['label'] is! String ||
        json['device_type'] is! String ||
        json['backed_up'] is! bool ||
        createdAt == null ||
        (lastUsed != null &&
            (lastUsed is! String || DateTime.tryParse(lastUsed) == null))) {
      throw const FormatException('Invalid passkey credential');
    }
    return PasskeyCredentialInfo(
      id: json['id'] as int,
      label: json['label'] as String,
      deviceType: json['device_type'] as String,
      backedUp: json['backed_up'] as bool,
      createdAt: createdAt,
      lastUsedAt: lastUsed == null ? null : DateTime.parse(lastUsed as String),
    );
  }

  final int id;
  final String label;
  final String deviceType;
  final bool backedUp;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
}

class ApiFailure implements Exception {
  const ApiFailure(
    this.message, {
    this.unauthorized = false,
    this.connection = false,
  });
  final String message;
  final bool unauthorized;
  final bool connection;
  @override
  String toString() => message;
}

class Profile {
  const Profile(
    this.name,
    this.avatar,
    this.wallpaper, {
    this.timetableBackground,
    this.analysisWallpaper,
    this.settingsWallpaper,
  });
  final String name;
  final String? avatar;
  final String? wallpaper;
  final String? timetableBackground;
  final String? analysisWallpaper;
  final String? settingsWallpaper;
  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    json['display_name'] as String? ?? '用户',
    json['avatar_data_url'] as String?,
    json['home_wallpaper_data_url'] as String?,
    timetableBackground: json['timetable_background_data_url'] as String?,
    analysisWallpaper: json['analysis_wallpaper_data_url'] as String?,
    settingsWallpaper: json['settings_wallpaper_data_url'] as String?,
  );
  Map<String, dynamic> toJson() => {
    'display_name': name,
    'avatar_data_url': avatar,
    'home_wallpaper_data_url': wallpaper,
    'timetable_background_data_url': timetableBackground,
    'analysis_wallpaper_data_url': analysisWallpaper,
    'settings_wallpaper_data_url': settingsWallpaper,
  };
}

/// Device-only presentation data, isolated by API and account owner.
class LocalProfileStore {
  LocalProfileStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directoryProvider;
  Future<File> _legacyFile() async => File(
    '${(await _directoryProvider()).path}${Platform.pathSeparator}local_profile_v1.json',
  );
  Future<File> _file(String baseUrl, String scope) async {
    final key = base64UrlEncode(utf8.encode('$baseUrl|$scope'))
        .replaceAll('=', '');
    return File(
      '${(await _directoryProvider()).path}${Platform.pathSeparator}local_profile_v2_$key.json',
    );
  }

  Future<Profile?> read({
    required String baseUrl,
    required String scope,
  }) async {
    try {
      final raw = jsonDecode(
        await (await _file(baseUrl, scope)).readAsString(),
      ) as Map<String, dynamic>;
      if (raw['version'] != 2 ||
          raw['base_url'] != baseUrl ||
          raw['scope'] != scope)
        return null;
      return Profile.fromJson(Map<String, dynamic>.from(raw['profile'] as Map));
    } catch (_) {
      // A previous version used one session-scoped file. Read it only for its
      // matching scope; ApiClient migrates it to the stable account owner.
      try {
        final raw = jsonDecode(
          await (await _legacyFile()).readAsString(),
        ) as Map<String, dynamic>;
        if (raw['version'] != 1 ||
            raw['base_url'] != baseUrl ||
            raw['scope'] != scope)
          return null;
        return Profile.fromJson(
          Map<String, dynamic>.from(raw['profile'] as Map),
        );
      } catch (_) {
        return null;
      }
    }
  }

  Future<Profile> resolve({
    required String baseUrl,
    required String scope,
    required Profile fallback,
  }) async {
    final saved = await read(baseUrl: baseUrl, scope: scope);
    if (saved != null) return saved;
    await write(baseUrl: baseUrl, scope: scope, profile: fallback);
    return fallback;
  }

  Future<void> write({
    required String baseUrl,
    required String scope,
    required Profile profile,
  }) async {
    final file = await _file(baseUrl, scope);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 2,
        'base_url': baseUrl,
        'scope': scope,
        'profile': profile.toJson(),
      }),
      flush: true,
    );
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }

  Future<void> clear() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) return;
    await for (final candidate in directory.list()) {
      if (candidate is! File) continue;
      final name = candidate.uri.pathSegments.last;
      if (name == 'local_profile_v1.json' ||
          name == 'local_profile_v1.json.tmp' ||
          name.startsWith('local_profile_v2_') && name.endsWith('.json') ||
          name.startsWith('local_profile_v2_') && name.endsWith('.json.tmp')) {
        await candidate.delete();
      }
    }
  }
}

class SettingsData {
  const SettingsData(this.profile, this.terms, this.periods, this.savedAt);
  final Profile profile;
  final List<TermInfo> terms;
  final List<PeriodInfo> periods;
  final DateTime savedAt;
}

class AiProviderSettings {
  const AiProviderSettings(
    this.configured,
    this.provider,
    this.baseUrl,
    this.model,
    this.keyHint,
    this.models,
    this.syncedAt,
    this.migrationRequired,
  );
  final bool configured;
  final String? provider;
  final String? baseUrl;
  final String? model;
  final String? keyHint;
  final List<String> models;
  final DateTime? syncedAt;
  final bool migrationRequired;
  factory AiProviderSettings.fromJson(Map<String, dynamic> json) =>
      AiProviderSettings(
        json['configured'] == true,
        json['provider'] as String?,
        json['base_url'] as String?,
        json['model'] as String?,
        json['api_key_hint'] as String?,
        (json['available_models'] as List? ?? [])
            .map((value) => value.toString())
            .toList(),
        DateTime.tryParse(json['models_synced_at']?.toString() ?? ''),
        json['requires_apikey_fan_migration'] == true,
      );
}

class SettingsCache {
  SettingsCache({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directoryProvider;
  Future<File> _file() async => File(
    '${(await _directoryProvider()).path}${Platform.pathSeparator}settings_snapshot_v1.json',
  );
  Future<SettingsData?> read({
    required String baseUrl,
    required String scope,
  }) async {
    try {
      final raw = jsonDecode(
        await (await _file()).readAsString(),
      ) as Map<String, dynamic>;
      if (raw['version'] != 1 ||
          raw['base_url'] != baseUrl ||
          raw['scope'] != scope)
        return null;
      return SettingsData(
        Profile.fromJson(Map<String, dynamic>.from(raw['profile'] as Map)),
        (raw['terms'] as List)
            .map(
              (row) => TermInfo.fromJson(Map<String, dynamic>.from(row as Map)),
            )
            .toList(),
        (raw['periods'] as List)
            .map(
              (row) =>
                  PeriodInfo.fromJson(Map<String, dynamic>.from(row as Map)),
            )
            .toList(),
        DateTime.parse(raw['saved_at'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write({
    required String baseUrl,
    required String scope,
    required Map<String, dynamic> profile,
    required List<dynamic> terms,
    required List<dynamic> periods,
  }) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'base_url': baseUrl,
        'scope': scope,
        'saved_at': DateTime.now().toIso8601String(),
        'profile': profile,
        'terms': terms,
        'periods': periods,
      }),
      flush: true,
    );
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }

  Future<void> clear() async {
    final file = await _file();
    for (final candidate in [file, File('${file.path}.tmp')]) {
      if (await candidate.exists()) await candidate.delete();
    }
  }
}

class TermInfo {
  const TermInfo(
    this.id,
    this.sourceId,
    this.name,
    this.startDate,
    this.isCurrent,
  );
  final int id;
  final String sourceId;
  final String name;
  final String? startDate;
  final bool isCurrent;
  factory TermInfo.fromJson(Map<String, dynamic> json) => TermInfo(
    json['id'] as int,
    json['source_term_id'] as String,
    json['display_name'] as String,
    json['start_date'] as String?,
    json['is_current'] == true,
  );
}

class PeriodInfo {
  const PeriodInfo(this.number, this.start, this.end);
  final int number;
  final String start;
  final String end;
  factory PeriodInfo.fromJson(Map<String, dynamic> json) => PeriodInfo(
    json['period_number'] as int,
    json['start_time'] as String,
    json['end_time'] as String,
  );
}

class TimetableCourse {
  const TimetableCourse(
    this.id,
    this.name,
    this.date,
    this.start,
    this.end,
    this.room,
    this.teacher,
    this.weeks,
    this.source,
    this.manualId,
    this.termId,
    this.weekday,
    this.startPeriod,
    this.endPeriod,
  );
  final int id;
  final String name;
  final String date;
  final DateTime start;
  final DateTime end;
  final String? room;
  final String? teacher;
  final String? weeks;
  final String? source;
  final int? manualId;
  final int? termId;
  final int? weekday;
  final int? startPeriod;
  final int? endPeriod;
  factory TimetableCourse.fromJson(Map<String, dynamic> json) =>
      TimetableCourse(
        json['id'] as int,
        json['course_name'] as String,
        json['session_date'] as String,
        DateTime.parse(json['start_datetime'] as String),
        DateTime.parse(json['end_datetime'] as String),
        json['classroom'] as String?,
        json['teacher'] as String?,
        json['week_expression'] as String?,
        json['source'] as String?,
        json['manual_course_id'] as int?,
        json['term_id'] as int?,
        json['weekday'] as int?,
        json['start_period'] as int?,
        json['end_period'] as int?,
      );
}

class TimetableData {
  const TimetableData(
    this.terms,
    this.periods,
    this.background,
    this.coursesByTerm,
    this.savedAt,
  );
  final List<TermInfo> terms;
  final List<PeriodInfo> periods;
  final String? background;
  final Map<int, List<TimetableCourse>> coursesByTerm;
  final DateTime savedAt;
}

class GradeRecord {
  const GradeRecord(
    this.id,
    this.name,
    this.type,
    this.credits,
    this.score,
    this.finalScore,
    this.usualScore,
    this.gradePoint,
    this.examType,
    this.makeup,
    this.retake,
  );
  final int id;
  final String name;
  final String? type;
  final num? credits;
  final String? score;
  final String? finalScore;
  final String? usualScore;
  final num? gradePoint;
  final String? examType;
  final bool makeup;
  final bool retake;
  factory GradeRecord.fromJson(Map<String, dynamic> json) => GradeRecord(
    json['id'] as int,
    json['course_name'] as String,
    json['course_type'] as String?,
    json['credits'] as num?,
    json['score']?.toString(),
    json['final_exam_score']?.toString(),
    json['usual_score']?.toString(),
    json['grade_point'] as num?,
    json['exam_type'] as String?,
    json['makeup_flag'] == true,
    json['retake_flag'] == true,
  );
}

class GradeSummary {
  const GradeSummary(
    this.earnedCredits,
    this.averageScore,
    this.gpa,
    this.failedCourses,
    this.note,
  );
  final num? earnedCredits;
  final num? averageScore;
  final num? gpa;
  final int? failedCourses;
  final String? note;
  factory GradeSummary.fromJson(Map<String, dynamic> json) => GradeSummary(
    json['earned_credits'] as num?,
    json['average_score'] as num?,
    json['gpa'] as num?,
    json['failed_courses'] as int?,
    json['gpa_note'] as String?,
  );
}

class GradeAnalysis {
  const GradeAnalysis(
    this.id,
    this.termId,
    this.content,
    this.provider,
    this.model,
    this.createdAt,
    this.cached,
  );
  final int? id;
  final int termId;
  final String content;
  final String provider;
  final String model;
  final DateTime createdAt;
  final bool cached;
  factory GradeAnalysis.fromJson(Map<String, dynamic> json) => GradeAnalysis(
    json['id'] as int?,
    json['term_id'] as int,
    json['content'] as String,
    json['provider'] as String,
    json['model'] as String,
    DateTime.parse(json['created_at'] as String),
    json['cached'] == true,
  );
}

class AnalysisData {
  const AnalysisData(
    this.terms,
    this.gradesByTerm,
    this.summariesByTerm,
    this.historyByTerm,
    this.background,
    this.savedAt,
  );
  final List<TermInfo> terms;
  final Map<int, List<GradeRecord>> gradesByTerm;
  final Map<int, GradeSummary> summariesByTerm;
  final Map<int, List<GradeAnalysis>> historyByTerm;
  final String? background;
  final DateTime savedAt;
}

class AnalysisCache {
  AnalysisCache({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directoryProvider;
  Future<File> _file() async {
    final directory = await _directoryProvider();
    return File(
      '${directory.path}${Platform.pathSeparator}analysis_snapshot_v1.json',
    );
  }

  Future<AnalysisData?> read({
    required String baseUrl,
    required String scope,
  }) async {
    try {
      final document = jsonDecode(
        await (await _file()).readAsString(),
      ) as Map<String, dynamic>;
      if (document['version'] != 1 ||
          document['base_url'] != baseUrl ||
          document['scope'] != scope)
        return null;
      final grades = Map<String, dynamic>.from(
        document['grades_by_term'] as Map,
      );
      final summaries = Map<String, dynamic>.from(
        document['summaries_by_term'] as Map,
      );
      final history = Map<String, dynamic>.from(
        document['history_by_term'] as Map,
      );
      return AnalysisData(
        (document['terms'] as List)
            .map(
              (row) => TermInfo.fromJson(Map<String, dynamic>.from(row as Map)),
            )
            .toList(),
        grades.map(
          (id, rows) => MapEntry(
            int.parse(id),
            (rows as List)
                .map(
                  (row) => GradeRecord.fromJson(
                    Map<String, dynamic>.from(row as Map),
                  ),
                )
                .toList(),
          ),
        ),
        summaries.map(
          (id, row) => MapEntry(
            int.parse(id),
            GradeSummary.fromJson(Map<String, dynamic>.from(row as Map)),
          ),
        ),
        history.map(
          (id, rows) => MapEntry(
            int.parse(id),
            (rows as List)
                .map(
                  (row) => GradeAnalysis.fromJson(
                    Map<String, dynamic>.from(row as Map),
                  ),
                )
                .toList(),
          ),
        ),
        document['background'] as String?,
        DateTime.parse(document['saved_at'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write({
    required String baseUrl,
    required String scope,
    required List<dynamic> terms,
    required Map<String, dynamic> gradesByTerm,
    required Map<String, dynamic> summariesByTerm,
    required Map<String, dynamic> historyByTerm,
    required String? background,
  }) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'base_url': baseUrl,
        'scope': scope,
        'saved_at': DateTime.now().toIso8601String(),
        'terms': terms,
        'grades_by_term': gradesByTerm,
        'summaries_by_term': summariesByTerm,
        'history_by_term': historyByTerm,
        'background': background,
      }),
      flush: true,
    );
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }

  Future<void> clear() async {
    final file = await _file();
    for (final candidate in [file, File('${file.path}.tmp')]) {
      if (await candidate.exists()) await candidate.delete();
    }
  }

  Future<void> removeTerm({
    required String baseUrl,
    required String scope,
    required int termId,
  }) async {
    final file = await _file();
    if (!await file.exists()) return;
    final document =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (document['version'] != 1 ||
        document['base_url'] != baseUrl ||
        document['scope'] != scope) {
      return;
    }
    for (final key in [
      'grades_by_term',
      'summaries_by_term',
      'history_by_term',
    ]) {
      (document[key] as Map).remove('$termId');
    }
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(document), flush: true);
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }

  Future<void> clearHistory({
    required String baseUrl,
    required String scope,
  }) async {
    final file = await _file();
    if (!await file.exists()) return;
    final document =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (document['version'] != 1 ||
        document['base_url'] != baseUrl ||
        document['scope'] != scope) {
      return;
    }
    document['history_by_term'] = <String, dynamic>{};
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(document), flush: true);
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }
}

class TimetableCache {
  TimetableCache({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directoryProvider;
  Future<File> _file() async {
    final directory = await _directoryProvider();
    return File(
      '${directory.path}${Platform.pathSeparator}timetable_snapshot_v1.json',
    );
  }

  Future<TimetableData?> read({
    required String baseUrl,
    required String scope,
  }) async {
    try {
      final document = jsonDecode(
        await (await _file()).readAsString(),
      ) as Map<String, dynamic>;
      if (document['version'] != 1 ||
          document['base_url'] != baseUrl ||
          document['scope'] != scope)
        return null;
      final rawCourses = Map<String, dynamic>.from(
        document['courses_by_term'] as Map,
      );
      return TimetableData(
        (document['terms'] as List)
            .map(
              (item) =>
                  TermInfo.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList(),
        (document['periods'] as List)
            .map(
              (item) =>
                  PeriodInfo.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList(),
        document['background'] as String?,
        rawCourses.map(
          (id, rows) => MapEntry(
            int.parse(id),
            (rows as List)
                .map(
                  (item) => TimetableCourse.fromJson(
                    Map<String, dynamic>.from(item as Map),
                  ),
                )
                .toList(),
          ),
        ),
        DateTime.parse(document['saved_at'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write({
    required String baseUrl,
    required String scope,
    required List<dynamic> terms,
    required List<dynamic> periods,
    required String? background,
    required Map<String, dynamic> coursesByTerm,
  }) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'base_url': baseUrl,
        'scope': scope,
        'saved_at': DateTime.now().toIso8601String(),
        'terms': terms,
        'periods': periods,
        'background': background,
        'courses_by_term': coursesByTerm,
      }),
      flush: true,
    );
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }

  Future<void> clear() async {
    final file = await _file();
    for (final candidate in [file, File('${file.path}.tmp')]) {
      if (await candidate.exists()) await candidate.delete();
    }
  }
}

class CourseSession {
  const CourseSession(
    this.id,
    this.name,
    this.date,
    this.start,
    this.end,
    this.room,
    this.teacher, {
    this.source,
  });
  final int id;
  final String name;
  final String date;
  final DateTime start;
  final DateTime end;
  final String? room;
  final String? teacher;
  final String? source;
  factory CourseSession.fromJson(Map<String, dynamic> json) => CourseSession(
    json['id'] as int,
    json['course_name'] as String,
    json['session_date'] as String,
    DateTime.parse(json['start_datetime'] as String),
    DateTime.parse(json['end_datetime'] as String),
    json['classroom'] as String?,
    json['teacher'] as String?,
    source: json['source'] as String?,
  );
}

class CustomSchedule {
  const CustomSchedule(this.id, this.title, this.date, this.time);
  final int id;
  final String title;
  final String date;
  final String time;
  factory CustomSchedule.fromJson(Map<String, dynamic> json) => CustomSchedule(
    json['id'] as int,
    json['title'] as String,
    json['scheduled_date'] as String,
    json['scheduled_time'] as String,
  );
}

class TodayData {
  const TodayData(this.profile, this.sessions, this.schedules);
  final Profile profile;
  final List<CourseSession> sessions;
  final List<CustomSchedule> schedules;
}

class TodaySnapshot {
  const TodaySnapshot(
    this.data,
    this.date,
    this.savedAt, {
    this.calendarSessions,
  });
  final TodayData data;
  final String date;
  final DateTime savedAt;

  /// Full timetable response captured with Today, when available. Null means
  /// an older snapshot that only stored a single day's sessions.
  final List<CourseSession>? calendarSessions;
  bool isFor(DateTime day) => date == dateKey(day);
}

/// A single last-known-good snapshot, kept in private app storage so large
/// avatar and wallpaper data URLs do not inflate SharedPreferences.
class TodayCache {
  TodayCache({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<File> _file() async {
    final directory = await _directoryProvider();
    return File(
      '${directory.path}${Platform.pathSeparator}today_snapshot_v1.json',
    );
  }

  Future<TodaySnapshot?> read({
    required String baseUrl,
    required String scope,
  }) async {
    try {
      final document = jsonDecode(
        await (await _file()).readAsString(),
      ) as Map<String, dynamic>;
      if (document['version'] != 1 ||
          document['base_url'] != baseUrl ||
          document['scope'] != scope)
        return null;
      final profile = Profile.fromJson(
        Map<String, dynamic>.from(document['profile'] as Map),
      );
      final sessions = (document['sessions'] as List)
          .map(
            (item) =>
                CourseSession.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
      final calendar = (document['timetable_sessions'] as List?)
          ?.map(
            (item) =>
                CourseSession.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
      final schedules = (document['schedules'] as List)
          .map(
            (item) =>
                CustomSchedule.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
      final date = document['date'] as String;
      final savedAt = DateTime.parse(document['saved_at'] as String);
      return TodaySnapshot(
        TodayData(profile, sessions, schedules),
        date,
        savedAt,
        calendarSessions: calendar,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write({
    required String baseUrl,
    required String scope,
    required String date,
    required Map<String, dynamic> profile,
    required List<dynamic> sessions,
    required List<dynamic> schedules,
    List<dynamic>? timetableSessions,
  }) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'base_url': baseUrl,
        'scope': scope,
        'date': date,
        'saved_at': DateTime.now().toIso8601String(),
        'profile': profile,
        'sessions': sessions,
        'timetable_sessions': timetableSessions,
        'schedules': schedules,
      }),
      flush: true,
    );
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      // Windows cannot always rename over an existing file; preserve updates
      // there while keeping the atomic rename path on Android and iOS.
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }

  Future<void> clear() async {
    final snapshot = await _file();
    for (final file in [snapshot, File('${snapshot.path}.tmp')]) {
      if (await file.exists()) await file.delete();
    }
  }
}

/// Private, account-scoped schedule database. Unlike TodayCache this keeps all
/// dates and is never cleared by a network refresh or logout.
class LocalScheduleStore {
  LocalScheduleStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directoryProvider;
  Future<void> _queue = Future.value();

  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<File> _file() async => File(
    '${(await _directoryProvider()).path}${Platform.pathSeparator}local_schedules_v1.json',
  );

  Future<Map<String, dynamic>> _read() async {
    final file = await _file();
    if (!await file.exists())
      return {'version': 1, 'accounts': <String, dynamic>{}};
    try {
      final document = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
      if (document['version'] != 1 || document['accounts'] is! Map)
        throw const FormatException();
      return document;
    } catch (_) {
      throw const ApiFailure('本机安排数据无法读取；为避免覆盖原数据，请先检查设备存储。');
    }
  }

  Future<void> _write(Map<String, dynamic> document) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(document), flush: true);
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }

  String _key(String baseUrl, String owner) => '$baseUrl|$owner';
  Map<String, dynamic> _account(Map<String, dynamic> document, String key) {
    final aliases = Map<String, dynamic>.from(
      document['aliases'] as Map? ?? const {},
    );
    final resolvedKey = aliases[key] as String? ?? key;
    final accounts = Map<String, dynamic>.from(document['accounts'] as Map);
    final account = accounts[resolvedKey] is Map
        ? Map<String, dynamic>.from(accounts[resolvedKey] as Map)
        : <String, dynamic>{
            'records': <dynamic>[],
            'deleted_remote_ids': <dynamic>[],
            'snapshot_imported': false,
            'server_imported': false,
            'next_id': -1,
          };
    accounts[resolvedKey] = account;
    document['accounts'] = accounts;
    return account;
  }

  List<CustomSchedule> _records(Map<String, dynamic> account) =>
      (account['records'] as List)
          .map(
            (item) =>
                CustomSchedule.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();

  Map<String, dynamic> _json(CustomSchedule item) => {
    'id': item.id,
    'title': item.title,
    'scheduled_date': item.date,
    'scheduled_time': item.time,
  };

  Future<List<CustomSchedule>> forDate(
    String baseUrl,
    String owner,
    DateTime day,
  ) => _locked(() async {
    final document = await _read();
    final account = _account(document, _key(baseUrl, owner));
    return _records(account).where((item) => item.date == dateKey(day)).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
  });

  Future<void> save(
    String baseUrl,
    String owner, {
    int? id,
    required String title,
    required DateTime date,
    required String time,
  }) => _locked(() async {
    final document = await _read();
    final account = _account(document, _key(baseUrl, owner));
    final records = _records(account);
    if (id != null && !records.any((item) => item.id == id)) {
      throw const ApiFailure('这项安排已不存在，请返回今日页面重试。');
    }
    final nextId = account['next_id'] as int? ?? -1;
    final actualId = id ?? nextId;
    if (id == null) account['next_id'] = nextId - 1;
    records.removeWhere((item) => item.id == actualId);
    records.add(CustomSchedule(actualId, title, dateKey(date), time));
    account['records'] = records.map(_json).toList();
    try {
      await _write(document);
    } catch (_) {
      throw const ApiFailure('本机安排保存失败，请检查设备存储空间。');
    }
  });

  Future<void> delete(String baseUrl, String owner, int id) =>
      _locked(() async {
        final document = await _read();
        final account = _account(document, _key(baseUrl, owner));
        final records = _records(account)..removeWhere((item) => item.id == id);
        account['records'] = records.map(_json).toList();
        if (id > 0) {
          final deleted =
              (account['deleted_remote_ids'] as List).cast<int>().toSet()
                ..add(id);
          account['deleted_remote_ids'] = deleted.toList();
        }
        try {
          await _write(document);
        } catch (_) {
          throw const ApiFailure('本机安排删除失败，请检查设备存储空间。');
        }
      });

  Future<bool> needsServerImport(String baseUrl, String owner) =>
      _locked(() async {
        final document = await _read();
        return _account(document, _key(baseUrl, owner))['server_imported'] !=
            true;
      });

  Future<void> import(
    String baseUrl,
    String owner,
    List<CustomSchedule> incoming, {
    required bool fromServer,
  }) => _locked(() async {
    final document = await _read();
    final account = _account(document, _key(baseUrl, owner));
    final marker = fromServer ? 'server_imported' : 'snapshot_imported';
    if (account[marker] == true) return;
    final records = _records(account);
    final known = records.map((item) => item.id).toSet();
    final deleted = (account['deleted_remote_ids'] as List).cast<int>().toSet();
    for (final item in incoming) {
      if (!known.contains(item.id) && !deleted.contains(item.id)) {
        records.add(item);
        known.add(item.id);
      }
    }
    account['records'] = records.map(_json).toList();
    account[marker] = true;
    try {
      await _write(document);
    } catch (_) {
      throw const ApiFailure('本机安排导入失败，请检查设备存储空间。');
    }
  });

  Future<void> moveOwner(String baseUrl, String oldOwner, String newOwner) =>
      _locked(() async {
        if (oldOwner == newOwner) return;
        final document = await _read();
        final accounts = Map<String, dynamic>.from(document['accounts'] as Map);
        final oldKey = _key(baseUrl, oldOwner);
        final newKey = _key(baseUrl, newOwner);
        if (accounts[oldKey] is! Map) {
          final aliases = Map<String, dynamic>.from(
            document['aliases'] as Map? ?? const {},
          );
          aliases[oldKey] = newKey;
          document['aliases'] = aliases;
          await _write(document);
          return;
        }
        final source = _account(document, oldKey);
        final target = _account(document, newKey);
        final records = _records(target);
        final ids = records.map((item) => item.id).toSet();
        var nextId = target['next_id'] as int? ?? -1;
        for (final item in _records(source)) {
          if (item.id > 0 && ids.contains(item.id)) continue;
          var id = item.id;
          if (id < 0 && ids.contains(id)) id = nextId--;
          records.add(CustomSchedule(id, item.title, item.date, item.time));
          ids.add(id);
          if (id < 0 && id <= nextId) nextId = id - 1;
        }
        target['records'] = records.map(_json).toList();
        target['next_id'] = nextId;
        target['deleted_remote_ids'] = {
          ...(target['deleted_remote_ids'] as List).cast<int>(),
          ...(source['deleted_remote_ids'] as List).cast<int>(),
        }.toList();
        target['snapshot_imported'] =
            target['snapshot_imported'] == true ||
            source['snapshot_imported'] == true;
        target['server_imported'] =
            target['server_imported'] == true ||
            source['server_imported'] == true;
        (document['accounts'] as Map).remove(oldKey);
        final aliases = Map<String, dynamic>.from(
          document['aliases'] as Map? ?? const {},
        );
        aliases[oldKey] = newKey;
        document['aliases'] = aliases;
        await _write(document);
      });
}

class LocalManualCourse {
  const LocalManualCourse(
    this.id,
    this.termSourceId,
    this.name,
    this.weeks,
    this.weekday,
    this.startPeriod,
    this.endPeriod,
    this.room,
    this.teacher, {
    this.remoteId,
  });
  final int id;
  final String termSourceId;
  final String name;
  final List<int> weeks;
  final int weekday;
  final int startPeriod;
  final int endPeriod;
  final String? room;
  final String? teacher;
  final int? remoteId;

  String get weekExpression => '${weeks.join(',')}周';
  Map<String, dynamic> toJson() => {
    'id': id,
    'term_source_id': termSourceId,
    'name': name,
    'weeks': weeks,
    'weekday': weekday,
    'start_period': startPeriod,
    'end_period': endPeriod,
    'room': room,
    'teacher': teacher,
    'remote_id': remoteId,
  };
  factory LocalManualCourse.fromJson(Map<String, dynamic> json) =>
      LocalManualCourse(
        json['id'] as int,
        json['term_source_id'] as String,
        json['name'] as String,
        (json['weeks'] as List).cast<int>(),
        json['weekday'] as int,
        json['start_period'] as int,
        json['end_period'] as int,
        json['room'] as String?,
        json['teacher'] as String?,
        remoteId: json['remote_id'] as int?,
      );
}

/// Flutter-only manual courses. The server and PWA keep their existing rules.
class LocalManualCourseStore {
  LocalManualCourseStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directoryProvider;
  Future<void> _queue = Future.value();

  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<File> _file() async => File(
    '${(await _directoryProvider()).path}${Platform.pathSeparator}local_manual_courses_v1.json',
  );

  Future<Map<String, dynamic>> _read() async {
    final file = await _file();
    if (!await file.exists())
      return {'version': 1, 'accounts': <String, dynamic>{}};
    try {
      final document = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
      if (document['version'] != 1 || document['accounts'] is! Map)
        throw const FormatException();
      return document;
    } catch (_) {
      throw const ApiFailure('本机课程数据无法读取；为避免覆盖原数据，请先检查设备存储。');
    }
  }

  Future<void> _write(Map<String, dynamic> document) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(document), flush: true);
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }

  Map<String, dynamic> _account(Map<String, dynamic> document, String key) {
    final accounts = Map<String, dynamic>.from(document['accounts'] as Map);
    final account = accounts[key] is Map
        ? Map<String, dynamic>.from(accounts[key] as Map)
        : <String, dynamic>{
            'records': <dynamic>[],
            'next_id': -1,
            'seen_remote_ids': <dynamic>[],
            'server_imported': false,
          };
    accounts[key] = account;
    document['accounts'] = accounts;
    return account;
  }

  List<LocalManualCourse> _records(Map<String, dynamic> account) =>
      (account['records'] as List)
          .map(
            (item) => LocalManualCourse.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();

  Future<List<LocalManualCourse>> all(String key) => _locked(() async {
    final document = await _read();
    return _records(_account(document, key));
  });

  Future<void> save(String key, LocalManualCourse course) => _locked(() async {
    final document = await _read();
    final account = _account(document, key);
    final records = _records(account);
    if (course.id != 0 && !records.any((item) => item.id == course.id)) {
      throw const ApiFailure('这门课程已不存在，请返回课表重试。');
    }
    final id = course.id == 0 ? account['next_id'] as int : course.id;
    if (course.id == 0) account['next_id'] = id - 1;
    records.removeWhere((item) => item.id == id);
    records.add(
      LocalManualCourse(
        id,
        course.termSourceId,
        course.name,
        course.weeks,
        course.weekday,
        course.startPeriod,
        course.endPeriod,
        course.room,
        course.teacher,
        remoteId: course.remoteId,
      ),
    );
    account['records'] = records.map((item) => item.toJson()).toList();
    try {
      await _write(document);
    } catch (_) {
      throw const ApiFailure('本机课程保存失败，请检查设备存储空间。');
    }
  });

  Future<void> delete(String key, int id) => _locked(() async {
    final document = await _read();
    final account = _account(document, key);
    account['records'] = _records(account)
        .where((item) => item.id != id)
        .map((item) => item.toJson())
        .toList();
    try {
      await _write(document);
    } catch (_) {
      throw const ApiFailure('本机课程删除失败，请检查设备存储空间。');
    }
  });

  Future<void> moveOwner(String baseUrl, String oldOwner, String newOwner) =>
      _locked(() async {
        final document = await _read();
        final accounts = Map<String, dynamic>.from(document['accounts'] as Map);
        final oldKey = '$baseUrl|$oldOwner';
        final newKey = '$baseUrl|$newOwner';
        if (oldKey == newKey || accounts[oldKey] is! Map) return;
        final old = Map<String, dynamic>.from(accounts[oldKey] as Map);
        final target = _account(document, newKey);
        final records = _records(target);
        final seen = <int>{
          ...(target['seen_remote_ids'] as List).cast<int>(),
          ...(old['seen_remote_ids'] as List).cast<int>(),
        };
        var nextId = target['next_id'] as int? ?? -1;
        for (final rule in _records(old)) {
          if (rule.remoteId != null &&
              records.any((item) => item.remoteId == rule.remoteId))
            continue;
          records.add(
            LocalManualCourse(
              nextId--,
              rule.termSourceId,
              rule.name,
              rule.weeks,
              rule.weekday,
              rule.startPeriod,
              rule.endPeriod,
              rule.room,
              rule.teacher,
              remoteId: rule.remoteId,
            ),
          );
        }
        target['records'] = records.map((item) => item.toJson()).toList();
        target['next_id'] = nextId;
        target['seen_remote_ids'] = seen.toList();
        target['server_imported'] =
            target['server_imported'] == true || old['server_imported'] == true;
        accounts.remove(oldKey);
        document['accounts'] = accounts;
        await _write(document);
      });

  Future<void> importLegacy(
    String key,
    List<TermInfo> terms,
    Map<int, List<TimetableCourse>> coursesByTerm, {
    required bool online,
  }) => _locked(() async {
    final document = await _read();
    final account = _account(document, key);
    if (online && account['server_imported'] == true) return;
    final records = _records(account);
    final seen = (account['seen_remote_ids'] as List).cast<int>().toSet();
    final grouped = <int, List<TimetableCourse>>{};
    for (final sessions in coursesByTerm.values) {
      for (final session in sessions) {
        if (session.source == 'MANUAL' &&
            session.manualId != null &&
            !seen.contains(session.manualId)) {
          grouped.putIfAbsent(session.manualId!, () => []).add(session);
        }
      }
    }
    final byId = {for (final term in terms) term.id: term};
    var nextId = account['next_id'] as int? ?? -1;
    for (final entry in grouped.entries) {
      final first = entry.value.first;
      final term = byId[first.termId];
      if (term?.startDate == null ||
          first.startPeriod == null ||
          first.endPeriod == null)
        continue;
      final start = DateTime.parse(term!.startDate!);
      final weeks = <int>{};
      for (final session in entry.value) {
        final day = DateTime.parse(session.date);
        final offset = DateTime.utc(
          day.year,
          day.month,
          day.day,
        ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
        final week = offset ~/ 7 + 1;
        if (week >= 1 && week <= 20) weeks.add(week);
      }
      if (weeks.isEmpty) continue;
      records.add(
        LocalManualCourse(
          nextId--,
          term.sourceId,
          first.name,
          weeks.toList()..sort(),
          first.weekday ?? first.start.weekday,
          first.startPeriod!,
          first.endPeriod!,
          first.room,
          first.teacher,
          remoteId: entry.key,
        ),
      );
      seen.add(entry.key);
    }
    account['records'] = records.map((item) => item.toJson()).toList();
    account['next_id'] = nextId;
    account['seen_remote_ids'] = seen.toList();
    if (online) account['server_imported'] = true;
    if (grouped.isNotEmpty || online) await _write(document);
  });
}

class ApiClient {
  ApiClient({
    http.Client? client,
    TodayCache? cache,
    TimetableCache? timetableCache,
    AnalysisCache? analysisCache,
    SettingsCache? settingsCache,
    LocalProfileStore? localProfileStore,
    LocalScheduleStore? localScheduleStore,
    LocalManualCourseStore? localManualCourseStore,
  }) : _client = client ?? http.Client(),
       _cache = cache ?? TodayCache(),
       _timetableCache = timetableCache ?? TimetableCache(),
       _analysisCache = analysisCache ?? AnalysisCache(),
       _settingsCache = settingsCache ?? SettingsCache(),
       _localProfileStore = localProfileStore ?? LocalProfileStore(),
       _localScheduleStore = localScheduleStore ?? LocalScheduleStore(),
       _localManualCourseStore =
           localManualCourseStore ?? LocalManualCourseStore();
  static const _cookieKey = 'session_cookie';
  static const _cacheScopeKey = 'today_cache_scope';
  static const _selectedTimetableTermKey = 'selected_timetable_term_v1';
  static const _localScheduleOwnerKey = 'local_schedule_owner_v1';
  final http.Client _client;
  final TodayCache _cache;
  final TimetableCache _timetableCache;
  final AnalysisCache _analysisCache;
  final SettingsCache _settingsCache;
  final LocalProfileStore _localProfileStore;
  final LocalScheduleStore _localScheduleStore;
  final LocalManualCourseStore _localManualCourseStore;
  final ValueNotifier<int> manualCoursesRevision = ValueNotifier<int>(0);
  final Uri _base = Uri.parse(apiBaseUrl);

  Future<bool> hasStoredSession() async =>
      (await SharedPreferences.getInstance())
          .getString(_cookieKey)
          ?.isNotEmpty ??
      false;

  Future<String?> _cacheScope() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_cookieKey)?.isNotEmpty != true) return null;
    final existing = prefs.getString(_cacheScopeKey);
    if (existing != null) return existing;
    final random = Random.secure();
    final scope = base64UrlEncode(
      List<int>.generate(18, (_) => random.nextInt(256)),
    );
    await prefs.setString(_cacheScopeKey, scope);
    return scope;
  }

  Future<String> _scheduleOwner() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_cookieKey)?.isNotEmpty != true) {
      throw const ApiFailure('请先登录后查看本机安排。', unauthorized: true);
    }
    return prefs.getString(_localScheduleOwnerKey) ??
        'session:${await _cacheScope()}';
  }

  Future<String?> _profileScope() async {
    final session = await _cacheScope();
    if (session == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final owner = prefs.getString(_localScheduleOwnerKey);
    return owner != null && owner.startsWith('user:') ? owner : session;
  }

  Future<List<CustomSchedule>> localSchedules(DateTime day) async =>
      _localScheduleStore.forDate(
        _base.toString(),
        await _scheduleOwner(),
        day,
      );

  Future<void> importSnapshotSchedules(TodaySnapshot? snapshot) async {
    await _localScheduleStore.import(
      _base.toString(),
      await _scheduleOwner(),
      snapshot?.data.schedules ?? const [],
      fromServer: false,
    );
  }

  Future<void> importServerSchedulesOnce() async {
    final owner = await _scheduleOwner();
    if (!await _localScheduleStore.needsServerImport(_base.toString(), owner))
      return;
    final raw = await _request('GET', '/api/v1/custom-schedules') as List;
    final schedules = raw
        .map(
          (item) =>
              CustomSchedule.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
    await _localScheduleStore.import(
      _base.toString(),
      owner,
      schedules,
      fromServer: true,
    );
  }

  Future<String?> selectedTimetableTerm() async {
    final scope = await _cacheScope();
    if (scope == null) return null;
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved =
          jsonDecode(prefs.getString(_selectedTimetableTermKey) ?? '') as Map;
      if (saved['base_url'] != _base.toString() || saved['scope'] != scope)
        return null;
      return saved['source_term_id'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSelectedTimetableTerm(String? sourceId) async {
    final scope = await _cacheScope();
    if (scope == null) throw const ApiFailure('请先登录后保存所选学期。');
    final prefs = await SharedPreferences.getInstance();
    if (sourceId == null) {
      await prefs.remove(_selectedTimetableTermKey);
    } else {
      await prefs.setString(
        _selectedTimetableTermKey,
        jsonEncode({
          'base_url': _base.toString(),
          'scope': scope,
          'source_term_id': sourceId,
        }),
      );
    }
  }

  Future<Profile?> localProfile() async {
    final scope = await _profileScope();
    if (scope == null) return null;
    final saved = await _localProfileStore.read(
      baseUrl: _base.toString(),
      scope: scope,
    );
    if (saved != null) return saved;
    final legacyScope = await _cacheScope();
    if (legacyScope == null || legacyScope == scope) return null;
    final legacy = await _localProfileStore.read(
      baseUrl: _base.toString(),
      scope: legacyScope,
    );
    if (legacy != null) {
      await _localProfileStore.write(
        baseUrl: _base.toString(),
        scope: scope,
        profile: legacy,
      );
    }
    return legacy;
  }

  Future<Profile> _resolveProfile(Profile fallback) async {
    final scope = await _profileScope();
    if (scope == null) return fallback;
    try {
      final saved = await localProfile();
      if (saved != null) return saved;
      await _localProfileStore.write(
        baseUrl: _base.toString(),
        scope: scope,
        profile: fallback,
      );
      return fallback;
    } catch (_) {
      return fallback;
    }
  }

  Future<Profile> saveLocalProfile(
    Map<String, dynamic> changes, {
    required Profile fallback,
  }) async {
    final scope = await _profileScope();
    if (scope == null) throw const ApiFailure('请先登录后保存本机资料。');
    final current = await localProfile() ?? fallback;
    final updated = Profile.fromJson({...current.toJson(), ...changes});
    if (updated.name.trim().isEmpty || updated.name.length > 64) {
      throw const ApiFailure('显示姓名需为 1 至 64 个字符。');
    }
    try {
      await _localProfileStore.write(
        baseUrl: _base.toString(),
        scope: scope,
        profile: updated,
      );
    } catch (_) {
      throw const ApiFailure('本机资料保存失败，请检查设备存储空间。');
    }
    return updated;
  }

  Future<TodaySnapshot?> loadTodaySnapshot() async {
    final scope = await _cacheScope();
    if (scope == null) return null;
    final snapshot = await _cache.read(baseUrl: _base.toString(), scope: scope);
    if (snapshot == null) return null;
    final profile = await _resolveProfile(snapshot.data.profile);
    return TodaySnapshot(
      TodayData(profile, snapshot.data.sessions, snapshot.data.schedules),
      snapshot.date,
      snapshot.savedAt,
      calendarSessions: snapshot.calendarSessions,
    );
  }

  Future<TimetableData?> loadTimetableSnapshot() async {
    final scope = await _cacheScope();
    if (scope == null) return null;
    final snapshot = await _timetableCache.read(
      baseUrl: _base.toString(),
      scope: scope,
    );
    final profile = await localProfile();
    if (snapshot == null) {
      return profile == null
          ? null
          : TimetableData(
              const [],
              const [],
              profile.timetableBackground,
              const {},
              DateTime.now(),
            );
    }
    final merged = await _withLocalManualCourses(snapshot, online: false);
    if (profile == null) return merged;
    return TimetableData(
      merged.terms,
      merged.periods,
      profile.timetableBackground,
      merged.coursesByTerm,
      merged.savedAt,
    );
  }

  Future<TimetableData> _withLocalManualCourses(
    TimetableData source, {
    required bool online,
  }) async {
    final key = '${_base.toString()}|${await _scheduleOwner()}';
    await _localManualCourseStore.importLegacy(
      key,
      source.terms,
      source.coursesByTerm,
      online: online,
    );
    final rules = await _localManualCourseStore.all(key);
    final periods = {
      for (final period in source.periods) period.number: period,
    };
    final courses = <int, List<TimetableCourse>>{};
    for (final term in source.terms) {
      final rows = source.coursesByTerm[term.id] ?? const <TimetableCourse>[];
      courses[term.id] = rows.where((item) => item.source != 'MANUAL').toList();
      if (term.startDate == null) continue;
      final firstDay = DateTime.parse(term.startDate!);
      for (final rule in rules.where(
        (item) => item.termSourceId == term.sourceId,
      )) {
        final first = periods[rule.startPeriod];
        final last = periods[rule.endPeriod];
        if (first == null || last == null) continue;
        final startParts = first.start.split(':').map(int.parse).toList();
        final endParts = last.end.split(':').map(int.parse).toList();
        for (final week in rule.weeks) {
          final day = DateTime(
            firstDay.year,
            firstDay.month,
            firstDay.day + (week - 1) * 7 + rule.weekday - 1,
          );
          final start = DateTime(
            day.year,
            day.month,
            day.day,
            startParts[0],
            startParts[1],
          );
          final end = DateTime(
            day.year,
            day.month,
            day.day,
            endParts[0],
            endParts[1],
          );
          courses[term.id]!.add(
            TimetableCourse(
              -2000000000 + (-rule.id) * 100 + week,
              rule.name,
              dateKey(day),
              start,
              end,
              rule.room,
              rule.teacher,
              rule.weekExpression,
              'LOCAL',
              rule.id,
              term.id,
              rule.weekday,
              rule.startPeriod,
              rule.endPeriod,
            ),
          );
        }
      }
      courses[term.id]!.sort((a, b) => a.start.compareTo(b.start));
    }
    return TimetableData(
      source.terms,
      source.periods,
      source.background,
      courses,
      source.savedAt,
    );
  }

  Future<AnalysisData?> loadAnalysisSnapshot() async {
    final scope = await _cacheScope();
    if (scope == null) return null;
    final snapshot = await _analysisCache.read(
      baseUrl: _base.toString(),
      scope: scope,
    );
    final profile = await localProfile();
    if (snapshot == null) {
      return profile == null
          ? null
          : AnalysisData(
              const [],
              const {},
              const {},
              const {},
              profile.analysisWallpaper,
              DateTime.now(),
            );
    }
    if (profile == null) return snapshot;
    return AnalysisData(
      snapshot.terms,
      snapshot.gradesByTerm,
      snapshot.summariesByTerm,
      snapshot.historyByTerm,
      profile.analysisWallpaper,
      snapshot.savedAt,
    );
  }

  Future<SettingsData?> loadSettingsSnapshot() async {
    final scope = await _cacheScope();
    if (scope == null) return null;
    final saved = await _settingsCache.read(
      baseUrl: _base.toString(),
      scope: scope,
    );
    if (saved != null) {
      return SettingsData(
        await _resolveProfile(saved.profile),
        saved.terms,
        saved.periods,
        saved.savedAt,
      );
    }
    // An older install may already have Today/Timetable snapshots but has not
    // visited Settings yet. Reuse those scoped snapshots for read-only fields.
    final today = await _cache.read(baseUrl: _base.toString(), scope: scope);
    final timetable = await _timetableCache.read(
      baseUrl: _base.toString(),
      scope: scope,
    );
    final analysis = await _analysisCache.read(
      baseUrl: _base.toString(),
      scope: scope,
    );
    if (today == null && timetable == null && analysis == null) {
      final local = await localProfile();
      return local == null
          ? null
          : SettingsData(local, const [], const [], DateTime.now());
    }
    final previous = today?.data.profile;
    final fallback = Profile(
      previous?.name ?? '航的助手',
      previous?.avatar,
      previous?.wallpaper,
      timetableBackground:
          timetable?.background ?? previous?.timetableBackground,
      analysisWallpaper: analysis?.background,
    );
    final profile = await _resolveProfile(fallback);
    return SettingsData(
      profile,
      timetable?.terms ?? analysis?.terms ?? <TermInfo>[],
      timetable?.periods ?? <PeriodInfo>[],
      today?.savedAt ?? timetable?.savedAt ?? analysis!.savedAt,
    );
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool preserveSessionOnPasswordError = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final request = http.Request(method, _base.resolve(path));
    request.headers['Accept'] = 'application/json';
    // The HTTPS backend requires an Origin for state-changing requests. Browsers
    // supply it automatically; native HTTP clients must provide the API origin.
    if (const {'POST', 'PUT', 'PATCH', 'DELETE'}.contains(method)) {
      request.headers['Origin'] = _base.origin;
    }
    final cookie = prefs.getString(_cookieKey);
    if (cookie != null) request.headers['Cookie'] = cookie;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    late final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request))
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const ApiFailure('请求超时，请检查网络后重试。', connection: true);
    } catch (_) {
      throw const ApiFailure('无法连接服务器，请检查网络后重试。', connection: true);
    }
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null) {
      final sessionCookie = setCookie.split(';').first;
      if (sessionCookie.contains('='))
        await prefs.setString(_cookieKey, sessionCookie);
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw ApiFailure('服务器返回的数据格式异常（HTTP ${response.statusCode}）。');
    }
    final error = decoded is Map && decoded['error'] is Map
        ? (decoded['error'] as Map)['message']?.toString()
        : null;
    if (response.statusCode == 401) {
      // Registration/removal re-checks the current password. A wrong password
      // is not an expired session and must not erase the user's local data.
      if (preserveSessionOnPasswordError && error == '当前密码错误') {
        throw ApiFailure(error!);
      }
      await prefs.remove(_cookieKey);
      await prefs.remove(_cacheScopeKey);
      await prefs.remove(pendingLocalPhotoKey);
      await prefs.remove(_selectedTimetableTermKey);
      await prefs.remove(_localScheduleOwnerKey);
      try {
        await _cache.clear();
        await _timetableCache.clear();
        await _analysisCache.clear();
        await _settingsCache.clear();
      } catch (_) {
        /* Auth state still wins. */
      }
      throw ApiFailure(error ?? '登录状态已失效', unauthorized: true);
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded is! Map ||
        decoded['success'] != true) {
      throw ApiFailure(error ?? '请求失败（HTTP ${response.statusCode}）。');
    }
    return decoded['data'];
  }

  Future<bool> hasSession() async {
    try {
      final identity = await _request('GET', '/api/v1/auth/me');
      if (identity is Map && identity['username'] is String) {
        final prefs = await SharedPreferences.getInstance();
        final username = (identity['username'] as String).trim().toLowerCase();
        final previous = await _scheduleOwner();
        final owner = 'user:$username';
        if (previous.startsWith('session:')) {
          await _localScheduleStore.moveOwner(
            _base.toString(),
            previous,
            owner,
          );
          await _localManualCourseStore.moveOwner(
            _base.toString(),
            previous,
            owner,
          );
          final legacy = await localProfile();
          if (legacy != null) {
            await _localProfileStore.write(
              baseUrl: _base.toString(),
              scope: owner,
              profile: legacy,
            );
          }
        }
        await prefs.setString(_localScheduleOwnerKey, owner);
      }
      return true;
    } on ApiFailure catch (error) {
      if (error.unauthorized) return false;
      rethrow;
    }
  }

  Future<void> login(String username, String password) async {
    await _request(
      'POST',
      '/api/v1/auth/login',
      body: {'username': username, 'password': password},
    );
    await _completeLogin(username);
  }

  Future<void> loginWithPasskey(PasskeyAssertionProvider getAssertion) async {
    final options = await _request('POST', '/api/v1/auth/passkey/options');
    if (options is! Map ||
        options['challenge_id'] is! String ||
        options['public_key'] is! Map) {
      throw const ApiFailure('服务器返回的通行密钥验证信息无效。');
    }
    final credential = await getAssertion(
      Map<String, dynamic>.from(options['public_key'] as Map),
    );
    final result = await _request(
      'POST',
      '/api/v1/auth/passkey/verify',
      body: {'challenge_id': options['challenge_id'], 'credential': credential},
    );
    if (result is! Map || result['username'] is! String) {
      throw const ApiFailure('服务器返回的登录信息无效。');
    }
    await _completeLogin(result['username'] as String);
  }

  Future<List<PasskeyCredentialInfo>> listPasskeys() async {
    final result = await _request('GET', '/api/v1/auth/passkeys');
    if (result is! List) throw const ApiFailure('服务器返回的通行密钥列表无效。');
    try {
      return result
          .map(
            (item) => PasskeyCredentialInfo.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
    } catch (_) {
      throw const ApiFailure('服务器返回的通行密钥列表无效。');
    }
  }

  Future<void> registerPasskey({
    required String label,
    required String password,
    required PasskeyRegistrationProvider createCredential,
  }) async {
    final name = label.trim().isEmpty ? '此设备' : label.trim();
    final options = await _request(
      'POST',
      '/api/v1/auth/passkey/registration/options',
      body: {'password': password, 'label': name},
      preserveSessionOnPasswordError: true,
    );
    if (options is! Map ||
        options['challenge_id'] is! String ||
        options['public_key'] is! Map) {
      throw const ApiFailure('服务器返回的通行密钥注册信息无效。');
    }
    final credential = await createCredential(
      Map<String, dynamic>.from(options['public_key'] as Map),
    );
    await _request(
      'POST',
      '/api/v1/auth/passkey/registration/verify',
      body: {
        'challenge_id': options['challenge_id'],
        'credential': credential,
        'label': name,
      },
    );
  }

  Future<void> deletePasskey(int id, String password) async {
    final result = await _request(
      'DELETE',
      '/api/v1/auth/passkeys/$id',
      body: {'password': password},
      preserveSessionOnPasswordError: true,
    );
    if (result is! Map || result['deleted'] != true) {
      throw const ApiFailure('服务器未确认移除通行密钥，请刷新后重试。');
    }
  }

  Future<void> _completeLogin(String username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheScopeKey);
    await prefs.remove(pendingLocalPhotoKey);
    await prefs.remove(_selectedTimetableTermKey);
    await prefs.setString(
      _localScheduleOwnerKey,
      'user:${username.trim().toLowerCase()}',
    );
    try {
      await _cache.clear();
      await _timetableCache.clear();
      await _analysisCache.clear();
      await _settingsCache.clear();
    } catch (_) {
      /* Do not fail login on cache cleanup. */
    }
    await _cacheScope();
  }

  Future<TodayData> today(DateTime now) async {
    final timetableRaw = await _request('GET', '/api/v1/timetable') as List;
    final sessionsRaw = timetableRaw
        .where((entry) => (entry as Map)['session_date'] == dateKey(now))
        .toList();
    final sessions = sessionsRaw
        .map(
          (entry) =>
              CourseSession.fromJson(Map<String, dynamic>.from(entry as Map)),
        )
        .toList();
    List<CustomSchedule> schedules;
    try {
      schedules = await localSchedules(now);
    } catch (_) {
      schedules = const [];
    }
    final profile = await _resolveProfile(const Profile('航的助手', null, null));
    final data = TodayData(profile, sessions, schedules);
    try {
      final scope = await _cacheScope();
      if (scope != null)
        await _cache.write(
          baseUrl: _base.toString(),
          scope: scope,
          date: dateKey(now),
          profile: profile.toJson(),
          sessions: sessionsRaw,
          schedules: schedules
              .map(
                (item) => <String, dynamic>{
                  'id': item.id,
                  'title': item.title,
                  'scheduled_date': item.date,
                  'scheduled_time': item.time,
                },
              )
              .toList(),
          timetableSessions: timetableRaw,
        );
    } catch (_) {
      /* Online data must still render if storage is unavailable. */
    }
    return data;
  }

  Future<TimetableData> timetable() async {
    final results = await Future.wait<dynamic>([
      _request('GET', '/api/v1/terms'),
      _request('GET', '/api/v1/settings/period-times'),
    ]);
    final termsRaw = results[0] as List;
    final periodsRaw = results[1] as List;
    final terms = termsRaw
        .map((row) => TermInfo.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
    final coursesRaw = <String, dynamic>{};
    await Future.wait(
      terms.map((term) async {
        coursesRaw['${term.id}'] = await _request(
          'GET',
          '/api/v1/timetable?term_id=${term.id}',
        ) as List;
      }),
    );
    final localProfile = await _resolveProfile(
      const Profile('航的助手', null, null),
    );
    final data = TimetableData(
      terms,
      periodsRaw
          .map(
            (row) => PeriodInfo.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList(),
      localProfile.timetableBackground,
      coursesRaw.map(
        (id, rows) => MapEntry(
          int.parse(id),
          (rows as List)
              .map(
                (row) => TimetableCourse.fromJson(
                  Map<String, dynamic>.from(row as Map),
                ),
              )
              .toList(),
        ),
      ),
      DateTime.now(),
    );
    try {
      final scope = await _cacheScope();
      if (scope != null) {
        await _timetableCache.write(
          baseUrl: _base.toString(),
          scope: scope,
          terms: termsRaw,
          periods: periodsRaw,
          background: data.background,
          coursesByTerm: coursesRaw,
        );
      }
    } catch (_) {
      /* Online data must still render if storage is unavailable. */
    }
    return _withLocalManualCourses(data, online: true);
  }

  Future<AnalysisData> analysisData() async {
    final termsRaw = await _request('GET', '/api/v1/terms') as List;
    final terms = termsRaw
        .map((row) => TermInfo.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
    final gradesRaw = <String, dynamic>{};
    final summariesRaw = <String, dynamic>{};
    final historyRaw = <String, dynamic>{};
    await Future.wait(
      terms.map((term) async {
        final values = await Future.wait<dynamic>([
          _request('GET', '/api/v1/grades?term_id=${term.id}'),
          _request('GET', '/api/v1/grades/summary?term_id=${term.id}'),
          _request('GET', '/api/v1/grades/ai-analyses?term_id=${term.id}'),
        ]);
        gradesRaw['${term.id}'] = values[0];
        summariesRaw['${term.id}'] = values[1];
        historyRaw['${term.id}'] = values[2];
      }),
    );
    final localProfile = await _resolveProfile(
      const Profile('航的助手', null, null),
    );
    final data = AnalysisData(
      terms,
      gradesRaw.map(
        (id, rows) => MapEntry(
          int.parse(id),
          (rows as List)
              .map(
                (row) =>
                    GradeRecord.fromJson(Map<String, dynamic>.from(row as Map)),
              )
              .toList(),
        ),
      ),
      summariesRaw.map(
        (id, row) => MapEntry(
          int.parse(id),
          GradeSummary.fromJson(Map<String, dynamic>.from(row as Map)),
        ),
      ),
      historyRaw.map(
        (id, rows) => MapEntry(
          int.parse(id),
          (rows as List)
              .map(
                (row) => GradeAnalysis.fromJson(
                  Map<String, dynamic>.from(row as Map),
                ),
              )
              .toList(),
        ),
      ),
      localProfile.analysisWallpaper,
      DateTime.now(),
    );
    try {
      final scope = await _cacheScope();
      if (scope != null) {
        await _analysisCache.write(
          baseUrl: _base.toString(),
          scope: scope,
          terms: termsRaw,
          gradesByTerm: gradesRaw,
          summariesByTerm: summariesRaw,
          historyByTerm: historyRaw,
          background: data.background,
        );
      }
    } catch (_) {
      /* Online data must still render if storage is unavailable. */
    }
    return data;
  }

  Future<GradeAnalysis> analyzeGrades(
    int termId, {
    bool forceRefresh = false,
  }) async {
    final path =
        '/api/v1/grades/ai-analysis?term_id=$termId${forceRefresh ? '&force_refresh=true' : ''}';
    return GradeAnalysis.fromJson(
      Map<String, dynamic>.from(await _request('POST', path) as Map),
    );
  }

  Future<void> deleteGrades(int termId) async {
    await _request('DELETE', '/api/v1/grades?term_id=$termId');
    try {
      final scope = await _cacheScope();
      if (scope != null) {
        await _analysisCache.removeTerm(
          baseUrl: _base.toString(),
          scope: scope,
          termId: termId,
        );
      }
    } catch (_) {
      /* A successful server deletion must not appear to fail. */
    }
  }

  Future<SettingsData> settingsData() async {
    final result = await Future.wait<dynamic>([
      _request('GET', '/api/v1/terms'),
      _request('GET', '/api/v1/settings/period-times'),
    ]);
    final terms = result[0] as List;
    final periods = result[1] as List;
    final profile = await _resolveProfile(const Profile('航的助手', null, null));
    final data = SettingsData(
      profile,
      terms
          .map(
            (row) => TermInfo.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList(),
      periods
          .map(
            (row) => PeriodInfo.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList(),
      DateTime.now(),
    );
    try {
      final scope = await _cacheScope();
      if (scope != null) {
        await _settingsCache.write(
          baseUrl: _base.toString(),
          scope: scope,
          profile: profile.toJson(),
          terms: terms,
          periods: periods,
        );
      }
    } catch (_) {
      /* Settings still render if private storage is unavailable. */
    }
    return data;
  }

  Future<void> updateTermStart(int termId, String date) async => _request(
    'PUT',
    '/api/v1/terms/$termId/start-date',
    body: {'start_date': date},
  );

  Future<void> updatePeriod(int number, String start, String end) async =>
      _request(
        'PUT',
        '/api/v1/settings/period-times/$number',
        body: {'start_time': start, 'end_time': end},
      );

  Future<AiProviderSettings> aiSettings() async => AiProviderSettings.fromJson(
    Map<String, dynamic>.from(
      await _request('GET', '/api/v1/ai/settings') as Map,
    ),
  );

  Future<AiProviderSettings> saveAiSettings(
    String provider,
    String baseUrl,
    String model,
    String apiKey,
  ) async => AiProviderSettings.fromJson(
    Map<String, dynamic>.from(
      await _request(
        'PUT',
        '/api/v1/ai/settings',
        body: {
          'provider': provider,
          'base_url': baseUrl,
          'model': model,
          'api_key': apiKey,
        },
      ) as Map,
    ),
  );

  Future<List<String>> lookupAiModels(
    String provider,
    String baseUrl,
    String apiKey,
  ) async {
    final result = Map<String, dynamic>.from(
      await _request(
        'POST',
        '/api/v1/ai/settings/models',
        body: {'provider': provider, 'base_url': baseUrl, 'api_key': apiKey},
      ) as Map,
    );
    return (result['models'] as List).map((value) => value.toString()).toList();
  }

  Future<AiProviderSettings> refreshAiModels() async =>
      AiProviderSettings.fromJson(
        Map<String, dynamic>.from(
          await _request('POST', '/api/v1/ai/settings/models/refresh') as Map,
        ),
      );

  Future<AiProviderSettings> selectAiModel(String model) async =>
      AiProviderSettings.fromJson(
        Map<String, dynamic>.from(
          await _request(
            'PATCH',
            '/api/v1/ai/settings/model',
            body: {'model': model},
          ) as Map,
        ),
      );

  Future<String> testAiSettings(
    String provider,
    String baseUrl,
    String model,
    String apiKey,
  ) async {
    final result = Map<String, dynamic>.from(
      await _request(
        'POST',
        '/api/v1/ai/settings/test',
        body: {
          'provider': provider,
          'base_url': baseUrl,
          'model': model,
          'api_key': apiKey,
        },
      ) as Map,
    );
    return result['message']?.toString() ?? '连接成功';
  }

  Future<void> clearAiSettings() async =>
      _request('DELETE', '/api/v1/ai/settings');
  Future<void> clearAiHistory() async {
    await _request('DELETE', '/api/v1/grades/ai-analyses');
    try {
      final scope = await _cacheScope();
      if (scope != null) {
        await _analysisCache.clearHistory(
          baseUrl: _base.toString(),
          scope: scope,
        );
      }
    } catch (_) {
      /* Successful server deletion must not appear to fail. */
    }
  }

  Future<dynamic> _uploadFile(
    String path,
    String filename,
    Uint8List bytes,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final request = http.MultipartRequest('POST', _base.resolve(path));
    request.headers['Accept'] = 'application/json';
    request.headers['Origin'] = _base.origin;
    final cookie = prefs.getString(_cookieKey);
    if (cookie != null) request.headers['Cookie'] = cookie;
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: filename),
    );
    late final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request))
          .timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw const ApiFailure('上传超时，请检查网络后重试。', connection: true);
    } catch (_) {
      throw const ApiFailure('无法连接服务器，请检查网络后重试。', connection: true);
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw ApiFailure('上传服务返回的数据格式异常（HTTP ${response.statusCode}）。');
    }
    final message = decoded is Map && decoded['error'] is Map
        ? (decoded['error'] as Map)['message']?.toString()
        : null;
    if (response.statusCode == 401) {
      await prefs.remove(_cookieKey);
      await prefs.remove(_cacheScopeKey);
      await prefs.remove(pendingLocalPhotoKey);
      await prefs.remove(_selectedTimetableTermKey);
      await prefs.remove(_localScheduleOwnerKey);
      try {
        await _cache.clear();
        await _timetableCache.clear();
        await _analysisCache.clear();
        await _settingsCache.clear();
      } catch (_) {
        /* Auth state still wins. */
      }
      throw ApiFailure(message ?? '登录状态已失效', unauthorized: true);
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded is! Map ||
        decoded['success'] != true) {
      throw ApiFailure(message ?? '上传失败（HTTP ${response.statusCode}）。');
    }
    return decoded['data'];
  }

  Future<Map<String, dynamic>> importTimetable(
    String filename,
    Uint8List bytes,
  ) async {
    final result = Map<String, dynamic>.from(
      await _uploadFile('/api/v1/timetable/import-file', filename, bytes)
          as Map,
    );
    try {
      await _timetableCache.clear();
    } catch (_) {
      /* Refresh still works. */
    }
    return result;
  }

  Future<Map<String, dynamic>> previewGrades(
    String filename,
    Uint8List bytes, {
    String? termId,
  }) async => Map<String, dynamic>.from(
    await _uploadFile(
      '/api/v1/grades/import-file${termId == null || termId.isEmpty ? '' : '?term_id=${Uri.encodeQueryComponent(termId)}'}',
      filename,
      bytes,
    ) as Map,
  );

  Future<Map<String, dynamic>> confirmGrades(
    Map<String, dynamic> preview,
  ) async {
    final result = Map<String, dynamic>.from(
      await _request('POST', '/api/v1/grades/import-confirm', body: preview)
          as Map,
    );
    try {
      await _analysisCache.clear();
    } catch (_) {
      /* Refresh still works. */
    }
    return result;
  }

  Future<void> logout() async {
    try {
      await _request('POST', '/api/v1/auth/logout');
    } finally {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cookieKey);
      await prefs.remove(_cacheScopeKey);
      await prefs.remove(pendingLocalPhotoKey);
      await prefs.remove(_selectedTimetableTermKey);
      await prefs.remove(_localScheduleOwnerKey);
      try {
        await _cache.clear();
        await _timetableCache.clear();
        await _analysisCache.clear();
        await _settingsCache.clear();
      } catch (_) {
        /* Session state wins. */
      }
    }
  }

  Future<void> saveManualCourse({
    int? id,
    required TermInfo term,
    required String name,
    required String weeks,
    required int weekday,
    required int startPeriod,
    required int endPeriod,
    String? room,
    String? teacher,
  }) async {
    if (term.startDate == null) {
      throw const ApiFailure('请先设置该学期第一周的周一日期。');
    }
    final snapshot = await loadTimetableSnapshot();
    final available =
        snapshot?.periods.map((item) => item.number).toList() ?? const <int>[];
    final selectedWeeks =
        RegExp(r'\d+')
            .allMatches(weeks)
            .map((item) => int.parse(item.group(0)!))
            .toSet()
            .toList()
          ..sort();
    if (name.trim().isEmpty ||
        selectedWeeks.isEmpty ||
        selectedWeeks.any((week) => week < 1 || week > 20) ||
        weekday < 1 ||
        weekday > 7 ||
        startPeriod > endPeriod ||
        !available.contains(startPeriod) ||
        !available.contains(endPeriod)) {
      throw const ApiFailure('请检查课程名称、周次和节次（仅支持第 1 至 20 周）。');
    }
    final key = '${_base.toString()}|${await _scheduleOwner()}';
    final existing = id == null
        ? null
        : (await _localManualCourseStore.all(key))
              .where((item) => item.id == id)
              .firstOrNull;
    await _localManualCourseStore.save(
      key,
      LocalManualCourse(
        id ?? 0,
        term.sourceId,
        name.trim(),
        selectedWeeks,
        weekday,
        startPeriod,
        endPeriod,
        room?.trim().isEmpty == true ? null : room?.trim(),
        teacher?.trim().isEmpty == true ? null : teacher?.trim(),
        remoteId: existing?.remoteId,
      ),
    );
    manualCoursesRevision.value++;
  }

  Future<void> deleteManualCourse(int id) async {
    await _localManualCourseStore.delete(
      '${_base.toString()}|${await _scheduleOwner()}',
      id,
    );
    manualCoursesRevision.value++;
  }

  Future<void> saveSchedule({
    int? id,
    required String title,
    required DateTime date,
    required String time,
  }) async {
    if (title.trim().isEmpty || title.length > 200) {
      throw const ApiFailure('安排事项需为 1 至 200 个字符。');
    }
    if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(time)) {
      throw const ApiFailure('时间格式无效。');
    }
    await _localScheduleStore.save(
      _base.toString(),
      await _scheduleOwner(),
      id: id,
      title: title.trim(),
      date: date,
      time: time,
    );
  }

  Future<void> deleteSchedule(int id) async =>
      _localScheduleStore.delete(_base.toString(), await _scheduleOwner(), id);
}

String dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
