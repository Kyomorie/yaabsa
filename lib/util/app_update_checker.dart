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
    final parsedCurrent = _ParsedVersion.tryParse(currentVersion);
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

      final parsedLatest = _ParsedVersion.tryParse(tagName);
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
        isUpdateAvailable: parsedLatest.compareTo(parsedCurrent) > 0,
      );
    } on DioException catch (e, s) {
      final isRateLimited = e.response?.statusCode == 403 || e.response?.statusCode == 429;
      int? rateLimitResetMs;
      if (isRateLimited) {
        final resetHeader = e.response?.headers.value('x-ratelimit-reset');
        final resetEpochSeconds = resetHeader == null ? null : int.tryParse(resetHeader);
        if (resetEpochSeconds != null) {
          rateLimitResetMs = resetEpochSeconds * 1000;
        }
      }

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
        rateLimitResetMs: rateLimitResetMs,
      );
    } catch (e, s) {
      logger(
        'Failed to check latest Yaabsa version from GitHub: $e\n$s',
        tag: 'AppUpdateChecker',
        level: InfoLevel.warning,
      );
      return AppUpdateCheckResult.failed(currentVersion: currentVersion);
    } finally {
      if (shouldCloseDio) {
        dio.close();
      }
    }
  }

  static bool isUpdateAvailable(String currentVersion, String latestVersion) {
    final current = _ParsedVersion.tryParse(currentVersion);
    final latest = _ParsedVersion.tryParse(latestVersion);
    if (current == null || latest == null) {
      return false;
    }
    return latest.compareTo(current) > 0;
  }

  static String _displayVersion(String version) {
    final trimmed = version.trim();
    if (trimmed.startsWith('v') || trimmed.startsWith('V')) {
      return trimmed.substring(1);
    }
    return trimmed;
  }
}

class _ParsedVersion implements Comparable<_ParsedVersion> {
  static final RegExp _pattern = RegExp(
    r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  final int major;
  final int minor;
  final int patch;
  final List<String>? preRelease;

  const _ParsedVersion({required this.major, required this.minor, required this.patch, this.preRelease});

  static _ParsedVersion? tryParse(String input) {
    final match = _pattern.firstMatch(input.trim());
    if (match == null) {
      return null;
    }

    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = int.tryParse(match.group(3)!);
    if (major == null || minor == null || patch == null) {
      return null;
    }

    final preReleaseValue = match.group(4);
    final preRelease = preReleaseValue == null ? null : preReleaseValue.split('.');

    return _ParsedVersion(major: major, minor: minor, patch: patch, preRelease: preRelease);
  }

  @override
  int compareTo(_ParsedVersion other) {
    final majorComparison = major.compareTo(other.major);
    if (majorComparison != 0) return majorComparison;

    final minorComparison = minor.compareTo(other.minor);
    if (minorComparison != 0) return minorComparison;

    final patchComparison = patch.compareTo(other.patch);
    if (patchComparison != 0) return patchComparison;

    if (preRelease == null && other.preRelease == null) return 0;
    if (preRelease == null) return 1;
    if (other.preRelease == null) return -1;

    final maxLength = preRelease!.length > other.preRelease!.length ? preRelease!.length : other.preRelease!.length;
    for (var index = 0; index < maxLength; index++) {
      if (index >= preRelease!.length) return -1;
      if (index >= other.preRelease!.length) return 1;

      final currentPart = preRelease![index];
      final otherPart = other.preRelease![index];
      final currentNumber = int.tryParse(currentPart);
      final otherNumber = int.tryParse(otherPart);

      if (currentNumber != null && otherNumber != null) {
        final comparison = currentNumber.compareTo(otherNumber);
        if (comparison != 0) return comparison;
        continue;
      }
      if (currentNumber != null) return -1;
      if (otherNumber != null) return 1;

      final comparison = currentPart.compareTo(otherPart);
      if (comparison != 0) return comparison;
    }

    return 0;
  }
}
