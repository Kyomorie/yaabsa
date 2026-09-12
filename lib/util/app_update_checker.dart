import 'package:dio/dio.dart';
import 'package:yaabsa/util/logger.dart';

enum AppUpdateCheckStatus { success, rateLimited, failed }

class AppUpdateCheckResult {
  final AppUpdateCheckStatus status;
  final String currentVersion;
  final String? latestVersion;
  final bool isUpdateAvailable;
  final int? rateLimitResetMs;

  const AppUpdateCheckResult({
    required this.status,
    required this.currentVersion,
    required this.latestVersion,
    required this.isUpdateAvailable,
    this.rateLimitResetMs,
  });

  const AppUpdateCheckResult.failed({required String currentVersion})
    : this(
        status: AppUpdateCheckStatus.failed,
        currentVersion: currentVersion,
        latestVersion: null,
        isUpdateAvailable: false,
      );
}

class AppUpdateChecker {
  static const String latestReleaseUrl = 'https://api.github.com/repos/Vito0912/yaabsa/releases/latest';

  final Dio? _injectedDio;

  const AppUpdateChecker({Dio? dio}) : _injectedDio = dio;

  Future<AppUpdateCheckResult> check(String currentVersion) async {
    final parsedCurrent = _parseVersion(currentVersion);
    if (parsedCurrent == null) {
      logger(
        'Skipping app update check because the installed version is invalid: $currentVersion',
        tag: 'AppUpdateChecker',
        level: InfoLevel.warning,
      );
      return AppUpdateCheckResult.failed(currentVersion: currentVersion);
    }

    final dio = _injectedDio ?? Dio();
    final shouldCloseDio = _injectedDio == null;

    try {
      logger('Fetching latest Yaabsa release from GitHub API...', tag: 'AppUpdateChecker', level: InfoLevel.info);
      final response = await dio.get<Map<String, dynamic>>(
        latestReleaseUrl,
        options: Options(
          headers: const {'Accept': 'application/vnd.github.v3+json', 'User-Agent': 'Yaabsa-App'},
          responseType: ResponseType.json,
        ),
      );

      final data = response.data;
      final tagName = data?['tag_name']?.toString().trim();
      if (data == null || tagName == null || tagName.isEmpty || data['draft'] == true || data['prerelease'] == true) {
        logger(
          'GitHub latest-release response did not contain a usable stable release.',
          tag: 'AppUpdateChecker',
          level: InfoLevel.warning,
        );
        return AppUpdateCheckResult.failed(currentVersion: currentVersion);
      }

      final parsedLatest = _parseVersion(tagName);
      if (parsedLatest == null) {
        logger(
          'Skipping app update notification because the latest release tag is invalid: $tagName',
          tag: 'AppUpdateChecker',
          level: InfoLevel.warning,
        );
        return AppUpdateCheckResult.failed(currentVersion: currentVersion);
      }

      return AppUpdateCheckResult(
        status: AppUpdateCheckStatus.success,
        currentVersion: currentVersion,
        latestVersion: _displayVersion(tagName),
        isUpdateAvailable: _compareVersions(parsedLatest, parsedCurrent) > 0,
      );
    } on DioException catch (e, s) {
      final isRateLimited = e.response?.statusCode == 403 || e.response?.statusCode == 429;
      final resetHeader = isRateLimited ? e.response?.headers.value('x-ratelimit-reset') : null;
      final resetEpochSeconds = resetHeader == null ? null : int.tryParse(resetHeader);

      logger(
        'Failed to fetch latest Yaabsa version from GitHub (Rate Limited: $isRateLimited): $e\n$s',
        tag: 'AppUpdateChecker',
        level: InfoLevel.warning,
      );

      return AppUpdateCheckResult(
        status: isRateLimited ? AppUpdateCheckStatus.rateLimited : AppUpdateCheckStatus.failed,
        currentVersion: currentVersion,
        latestVersion: null,
        isUpdateAvailable: false,
        rateLimitResetMs: resetEpochSeconds == null ? null : resetEpochSeconds * 1000,
      );
    } catch (e, s) {
      logger(
        'Failed to check latest Yaabsa version from GitHub: $e\n$s',
        tag: 'AppUpdateChecker',
        level: InfoLevel.warning,
      );
      return AppUpdateCheckResult.failed(currentVersion: currentVersion);
    } finally {
      if (shouldCloseDio) dio.close();
    }
  }

  static bool isUpdateAvailable(String currentVersion, String latestVersion) {
    final current = _parseVersion(currentVersion);
    final latest = _parseVersion(latestVersion);
    return current != null && latest != null && _compareVersions(latest, current) > 0;
  }

  static _ParsedVersion? _parseVersion(String value) {
    var version = value.trim();
    if (version.startsWith('v') || version.startsWith('V')) version = version.substring(1);

    version = version.split('+').first;
    final isPrerelease = version.contains('-');
    final parts = version.split('-').first.split('.');
    if (parts.length != 3) return null;

    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = int.tryParse(parts[2]);
    if (major == null || minor == null || patch == null) return null;

    return _ParsedVersion(major, minor, patch, isPrerelease);
  }

  static int _compareVersions(_ParsedVersion first, _ParsedVersion second) {
    final firstParts = [first.major, first.minor, first.patch];
    final secondParts = [second.major, second.minor, second.patch];
    for (var index = 0; index < firstParts.length; index++) {
      final comparison = firstParts[index].compareTo(secondParts[index]);
      if (comparison != 0) return comparison;
    }

    if (first.isPrerelease == second.isPrerelease) return 0;
    return first.isPrerelease ? -1 : 1;
  }

  static String _displayVersion(String version) {
    final trimmed = version.trim();
    return trimmed.startsWith('v') || trimmed.startsWith('V') ? trimmed.substring(1) : trimmed;
  }
}

class _ParsedVersion {
  final int major;
  final int minor;
  final int patch;
  final bool isPrerelease;

  const _ParsedVersion(this.major, this.minor, this.patch, this.isPrerelease);
}
