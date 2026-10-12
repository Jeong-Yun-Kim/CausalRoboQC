import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'quality_dashboard_page.dart';
import 'dashboard_theme.dart';
import 'data_browser_page.dart';
import 'quality_dashboard_api.dart';
import 'quality_dashboard_data.dart';
import 'metric_help.dart';
import 'copilot_overlay.dart';
import 'rpf_analysis_overview.dart';
import 'camera_preview.dart';
import 'server_camera_preview.dart';

const _configuredApiBase = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

void main() {
  runApp(const RobotArmApp());
}

class RobotArmApp extends StatelessWidget {
  const RobotArmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CausalRoboQC',
      locale: const Locale('ko'),
      supportedLocales: const [Locale('ko'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: DashboardTheme.light,
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static const _requiredPoses = [
    'HOME',
    'PICK_ABOVE',
    'PICK',
    'GRAB',
    'LIFT',
    'PLACE',
    'RELEASE',
  ];
  static const _errorPoses = ['ERROR_PICK', 'ERROR_PLACE'];
  static const _poseNames = [..._requiredPoses, ..._errorPoses];
  static const _defaultCauseOptions = [
    '집기 재시도',
    '작업시간 초과',
    '배치 실패',
    '제품 ID 불일치',
    '작업자 수동 보정',
    '기타',
  ];

  final String _apiBase = _configuredApiBase.replaceFirst(RegExp(r'/$'), '');
  final List<int?> _angles = List<int?>.filled(6, null);
  final List<int> _draftAngles = List<int>.filled(6, 90);
  final Set<int> _jointBusy = <int>{};
  final Set<String> _reviewPromptedRunIds = <String>{};

  Timer? _pollTimer;
  Timer? _reconnectTimer;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _socketSubscription;

  Map<String, dynamic> _status = <String, dynamic>{};
  Map<String, List<int>?> _poses = <String, List<int>?>{};
  List<Map<String, dynamic>> _runs = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];
  DashboardData? _qualitySummary;
  bool _qualityError = false;
  Object? _selectedRunId;
  String _selectedPose = 'HOME';
  String? _lastError;
  bool _backendOnline = false;
  bool _socketOnline = false;
  bool _busy = false;
  bool _safetyBusy = false;
  bool _polling = false;
  bool _reviewDialogOpen = false;
  int _pollCount = 0;
  int _pageIndex = 0;

  @override
  void initState() {
    super.initState();
    _connectSocket();
    unawaited(_refresh(full: true));
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_poll());
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    _socketSubscription?.cancel();
    _socket?.sink.close();
    super.dispose();
  }

  Uri _uri(String path) {
    if (_apiBase.isEmpty) return Uri.base.resolve(path);
    return Uri.parse('$_apiBase$path');
  }

  Uri get _webSocketUri {
    final sameOrigin = _apiBase.isEmpty;
    final base = sameOrigin ? Uri.base : Uri.parse(_apiBase);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: sameOrigin ? '/ws' : '$basePath/ws',
      query: null,
      fragment: null,
    );
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    final encodedBody = body == null ? null : jsonEncode(body);
    late http.Response response;

    switch (method) {
      case 'GET':
        response = await http
            .get(_uri(path), headers: headers)
            .timeout(const Duration(seconds: 25));
      case 'POST':
        response = await http
            .post(_uri(path), headers: headers, body: encodedBody)
            .timeout(const Duration(seconds: 25));
      default:
        throw ArgumentError('Unsupported method: $method');
    }

    dynamic decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        decoded = response.body;
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = decoded?.toString() ?? 'HTTP ${response.statusCode}';
      if (decoded is Map && decoded['detail'] != null) {
        detail = decoded['detail'].toString();
      }
      throw Exception(detail);
    }
    return decoded;
  }

  void _connectSocket() {
    _reconnectTimer?.cancel();
    final socket = WebSocketChannel.connect(_webSocketUri);
    _socket = socket;
    _socketSubscription?.cancel();
    _socketSubscription = socket.stream.listen(
      _onSocketMessage,
      onError: (_) => _socketDisconnected(socket),
      onDone: () => _socketDisconnected(socket),
      cancelOnError: true,
    );
    socket.ready.timeout(const Duration(seconds: 5)).then((_) {
      if (!mounted || !identical(_socket, socket)) return;
      setState(() => _socketOnline = true);
    }).catchError((Object _) {
      _socketDisconnected(socket);
    });
  }

  void _socketDisconnected(WebSocketChannel socket) {
    if (!mounted || !identical(_socket, socket)) return;
    if (_socketOnline) setState(() => _socketOnline = false);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), _connectSocket);
  }

  void _onSocketMessage(dynamic message) {
    if (!mounted) return;
    try {
      final decoded = jsonDecode(message.toString());
      if (decoded is! Map) return;
      final envelope = Map<String, dynamic>.from(decoded);
      final type = envelope['type']?.toString();
      final data = envelope['data'];
      Object? finishedRunId;

      setState(() {
        _socketOnline = true;
        if (type == 'snapshot' && data is Map) {
          final snapshot = Map<String, dynamic>.from(data);
          if (snapshot['status'] is Map) {
            _applyStatus(Map<String, dynamic>.from(snapshot['status'] as Map));
          }
          if (snapshot['poses'] != null) {
            _poses = _parsePoses(snapshot['poses']);
          }
        } else if (type == 'status' && data is Map) {
          _applyStatus(Map<String, dynamic>.from(data));
        } else if (type == 'event' && data is Map) {
          final event = Map<String, dynamic>.from(data);
          _addLiveEvent(event);
          if (event['name']?.toString() == 'RUN_FINISHED') {
            finishedRunId = event['run_id'];
          }
        } else if (type == 'poses') {
          _poses = _parsePoses(data);
        }
      });
      if (finishedRunId != null) {
        unawaited(_handleRunFinished(finishedRunId!));
      }
    } on FormatException {
      // Ignore non-JSON serial/debug frames.
    }
  }

  Future<void> _poll() async {
    _pollCount++;
    await _refresh(
      includeRuns: _pollCount % 3 == 0,
      includeEvents: !_socketOnline || _pollCount % 5 == 0,
    );
  }

  Future<void> _refresh({
    bool full = false,
    bool includeRuns = false,
    bool includeEvents = false,
  }) async {
    if (_polling) return;
    _polling = true;
    try {
      await _loadStatus();
      if (full || includeRuns) {
        await _loadRuns();
        unawaited(_loadQualitySummary());
      }
      if (full) await _loadPoses();
      if (_selectedRunId != null && (full || includeEvents)) {
        await _loadEvents(_selectedRunId!);
      }
      if (!mounted) return;
      setState(() {
        _backendOnline = true;
        _lastError = null;
      });
    } catch (error, stack) {
      debugPrint('Request failed: $error\n$stack');
      if (!mounted) return;
      setState(() {
        _backendOnline = false;
        _lastError = '서버에 연결할 수 없습니다.';
      });
    } finally {
      _polling = false;
    }
  }

  Future<void> _loadStatus() async {
    final data = await _request('GET', '/api/status');
    if (data is! Map || !mounted) return;
    setState(() => _applyStatus(Map<String, dynamic>.from(data)));
  }

  void _applyStatus(Map<String, dynamic> data) {
    _status = data;
    final robot = _map(data['robot']);
    final current = robot['current_angles'];
    if (current is List) {
      for (var i = 0; i < 6 && i < current.length; i++) {
        final value = _integer(current[i]);
        _angles[i] = value;
        if (value != null) {
          _draftAngles[i] = value;
        }
      }
    }
    final activeRun = _map(data['active_run']);
    final activeId = activeRun['id'];
    _selectedRunId ??= activeId;
  }

  Future<void> _loadPoses() async {
    final data = await _request('GET', '/api/poses');
    if (!mounted) return;
    setState(() => _poses = _parsePoses(data));
  }

  Future<void> _loadRuns() async {
    final data = await _request('GET', '/api/runs?limit=30&offset=0');
    final items = _items(data);
    if (!mounted) return;
    setState(() {
      _runs = items;
      if (_selectedRunId == null && items.isNotEmpty) {
        _selectedRunId = items.first['id'];
      }
    });
  }

  Future<void> _loadQualitySummary() async {
    try {
      final data = await const ApiQualityDashboardDataSource().load();
      if (!mounted) return;
      setState(() {
        _qualitySummary = data;
        _qualityError = false;
      });
    } catch (error, stack) {
      debugPrint('Product summary load failed: $error\n$stack');
      if (mounted) {
        setState(() {
          _qualitySummary = null;
          _qualityError = true;
        });
      }
    }
  }

  Future<void> _loadEvents(Object runId) async {
    final data = await _request(
      'GET',
      '/api/runs/${Uri.encodeComponent(runId.toString())}/events?limit=200',
    );
    if (!mounted || _selectedRunId.toString() != runId.toString()) return;
    setState(() => _events = _items(data));
  }

  void _addLiveEvent(Map<String, dynamic> event) {
    final runId = event['run_id'];
    _selectedRunId ??= runId;
    if (_selectedRunId.toString() != runId.toString()) return;
    final eventId = event['id']?.toString();
    _events.removeWhere((item) => item['id']?.toString() == eventId);
    _events.insert(0, event);
    if (_events.length > 200) _events.removeLast();
  }

  Map<String, List<int>?> _parsePoses(dynamic data) {
    dynamic raw = data;
    if (raw is Map && raw['poses'] != null) raw = raw['poses'];
    final result = <String, List<int>?>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is List && value.length == 6) {
          final angles = value.map(_integer).toList();
          result[entry.key.toString()] = angles.every((angle) => angle != null)
              ? angles.cast<int>()
              : null;
        } else {
          result[entry.key.toString()] = null;
        }
      }
    }
    for (final name in _poseNames) {
      result.putIfAbsent(name, () => null);
    }
    return result;
  }

  List<Map<String, dynamic>> _items(dynamic data) {
    dynamic raw = data;
    if (raw is Map) raw = raw['items'] ?? raw['runs'] ?? raw['events'] ?? [];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Map<String, dynamic> _map(dynamic value) {
    return value is Map
        ? Map<String, dynamic>.from(value)
        : <String, dynamic>{};
  }

  int? _integer(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  List<int> _limitsFor(int index) {
    final robot = _map(_status['robot']);
    final limits = robot['limits'];
    if (limits is List && index < limits.length && limits[index] is List) {
      final pair = limits[index] as List;
      if (pair.length >= 2) {
        final minimum = _integer(pair[0]);
        final maximum = _integer(pair[1]);
        if (minimum != null && maximum != null && minimum < maximum) {
          return [minimum, maximum];
        }
      }
    }
    return [0, 180];
  }

  bool get _serialReady {
    final serial = _map(_status['serial']);
    return serial['connected'] == true && serial['ready'] == true;
  }

  bool get _runActive => _map(_status['active_run']).isNotEmpty;

  bool get _estopActive => _map(_status['robot'])['estop'] == true;

  int get _savedPoseCount {
    return _requiredPoses.where((name) => _poses[name]?.length == 6).length;
  }

  bool get _readyToRun {
    return _serialReady &&
        _savedPoseCount == 7 &&
        !_runActive &&
        !_estopActive &&
        !_safetyBusy &&
        !_busy;
  }

  Map<String, dynamic> get _calibration => _map(_status['calibration']);

  bool get _repeatUnlocked => _calibration['repeat_unlocked'] == true;

  String? get _latestUnreviewedRunId {
    final latest = _calibration['latest_unreviewed_run'];
    final value = latest is Map ? latest['id'] ?? latest['run_id'] : latest;
    return value?.toString();
  }

  List<String> get _calibrationCauseOptions {
    final raw = _calibration['cause_options'];
    if (raw is List) {
      final options = raw
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      if (options.isNotEmpty) return options;
    }
    return _defaultCauseOptions;
  }

  Future<void> _startRun(bool repeat, {String mode = 'normal'}) async {
    if (repeat && !_repeatUnlocked) {
      _showMessage('준비 데이터를 모두 확정한 뒤 반복 실행할 수 있습니다.', error: true);
      return;
    }
    final errorMode = mode == 'error';
    final successMessage = errorMode
        ? '오류 로직 실행 시작'
        : repeat
            ? '반복 실행 시작'
            : '1회 실행 시작';
    await _perform(successMessage, () async {
      final data = await _request(
        'POST',
        '/api/runs/start',
        body: {'repeat': repeat, 'mode': mode},
      );
      if (data is Map) {
        final run = _map(data['run']);
        if (run['id'] != null) _selectedRunId = run['id'];
      }
    });
  }

  Future<void> _handleRunFinished(Object runId) async {
    final id = runId.toString();
    if (_reviewPromptedRunIds.contains(id)) return;
    _reviewPromptedRunIds.add(id);
    try {
      await _loadStatus();
    } catch (_) {
      // The event itself is sufficient to offer a review if status refresh lags.
    }
    if (!mounted || _pageIndex != 1) return;
    await _showRunReview(id);
  }

  Future<void> _showRunReview(String runId) async {
    if (_reviewDialogOpen || !mounted) return;
    _reviewDialogOpen = true;
    final causeOptions = _calibrationCauseOptions;
    try {
      var run = _map(_calibration['latest_unreviewed_run']);
      if (run['id']?.toString() != runId) {
        run = <String, dynamic>{};
      }
      try {
        final data = await _request(
          'GET',
          '/api/runs/${Uri.encodeComponent(runId)}',
        );
        run = _map(data);
      } catch (_) {
        // Keep the status snapshot as a fallback if the detail request is late.
      }
      if (!mounted) return;

      final errorMode = run['run_mode']?.toString() == 'error';
      final suggestedVerdict = run['suggested_verdict']?.toString();
      final recommendedVerdict =
          suggestedVerdict == 'normal' || suggestedVerdict == 'abnormal'
              ? suggestedVerdict!
              : errorMode
                  ? 'abnormal'
                  : 'normal';
      var verdict = recommendedVerdict;
      final selectedCauses = <String>{};
      final suggestedCauses = run['suggested_causes'];
      if (suggestedCauses is List) {
        selectedCauses.addAll(
          suggestedCauses
              .map((cause) => cause.toString())
              .where(causeOptions.contains),
        );
      }

      final result = await showDialog<({String verdict, List<String> causes})>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final abnormal = verdict == 'abnormal';
            return AlertDialog(
              title: Text('작업 결과 기록'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        errorMode
                            ? '오류 로직 실행 결과입니다. 실제 결과에 맞게 판정을 확정하세요.'
                            : '완료된 1회 작업의 실제 결과를 선택하세요.',
                      ),
                      const SizedBox(height: 14),
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'normal',
                            icon: const Icon(Icons.check_circle_outline),
                            label: Text(
                              recommendedVerdict == 'normal' ? '정상 (추천)' : '정상',
                            ),
                          ),
                          ButtonSegment(
                            value: 'abnormal',
                            icon: const Icon(Icons.warning_amber),
                            label: Text(
                              recommendedVerdict == 'abnormal'
                                  ? '이상 (추천)'
                                  : '이상',
                            ),
                          ),
                        ],
                        selected: {verdict},
                        onSelectionChanged: (selection) {
                          setDialogState(() => verdict = selection.first);
                        },
                      ),
                      if (abnormal) ...[
                        const SizedBox(height: 18),
                        Text(
                          '이상 원인 (복수 선택)',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: causeOptions.map((cause) {
                            return FilterChip(
                              label: Text(cause),
                              selected: selectedCauses.contains(cause),
                              onSelected: (selected) {
                                setDialogState(() {
                                  if (selected) {
                                    selectedCauses.add(cause);
                                  } else {
                                    selectedCauses.remove(cause);
                                  }
                                });
                              },
                            );
                          }).toList(growable: false),
                        ),
                        if (selectedCauses.isEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            '이상 공정은 원인을 하나 이상 선택해야 합니다.',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: abnormal && selectedCauses.isEmpty
                      ? null
                      : () {
                          Navigator.pop(dialogContext, (
                            verdict: verdict,
                            causes: abnormal
                                ? causeOptions
                                    .where(selectedCauses.contains)
                                    .toList(growable: false)
                                : <String>[],
                          ));
                        },
                  child: const Text('결과 저장'),
                ),
              ],
            );
          },
        ),
      );
      if (result == null || !mounted) return;
      await _perform('작업 결과를 저장했습니다.', () async {
        await _request(
          'POST',
          '/api/runs/${Uri.encodeComponent(runId)}/review',
          body: {'verdict': result.verdict, 'causes': result.causes},
        );
      });
    } finally {
      _reviewDialogOpen = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _confirmCalibrationReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('판정 데이터 초기화'),
        content: const Text(
          '확정한 정상/이상 판정 데이터만 초기화합니다.\n\n'
          '원본 Run과 RPF 이벤트 이력은 그대로 유지됩니다. 초기화하면 반복 실행이 다시 잠기며, 필요한 수만큼 1회 실행 결과를 다시 확정해야 합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform('판정 데이터 초기화 완료', () async {
      await _request('POST', '/api/calibration/reset');
      _reviewPromptedRunIds.clear();
    });
  }

  Future<void> _perform(
    String successMessage,
    Future<void> Function() work,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
      if (!mounted) return;
      _showMessage(successMessage);
      await _refresh(full: true);
    } catch (error, stack) {
      debugPrint('Request failed: $error\n$stack');
      if (!mounted) return;
      _showMessage(
        '요청을 처리하지 못했습니다. 연결 상태를 확인해 주세요.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendJoint(int index, int angle) async {
    if (_jointBusy.contains(index)) return;
    setState(() => _jointBusy.add(index));
    try {
      final data = await _request(
        'POST',
        '/api/servos/${index + 1}',
        body: {'angle': angle},
      );
      if (!mounted) return;
      setState(() {
        _angles[index] = angle;
        _draftAngles[index] = angle;
        if (data is Map && data['status'] is Map) {
          _applyStatus(Map<String, dynamic>.from(data['status'] as Map));
        }
      });
    } catch (error, stack) {
      debugPrint('Robot command failed: $error\n$stack');
      if (mounted) {
        _showMessage(
          'J${index + 1} 각도를 변경하지 못했습니다.',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _jointBusy.remove(index));
    }
  }

  Future<void> _safetyControl(String command, String successMessage) async {
    if (_safetyBusy || !_serialReady) return;
    setState(() => _safetyBusy = true);
    try {
      await _request('POST', '/api/control/$command');
      if (!mounted) return;
      _showMessage(successMessage);
      await _refresh(full: true);
    } catch (error, stack) {
      debugPrint('Robot command failed: $error\n$stack');
      if (mounted) {
        _showMessage(
          '요청을 처리하지 못했습니다. 연결 상태를 확인해 주세요.',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _safetyBusy = false);
    }
  }

  Future<void> _confirmDetach() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('서보 해제'),
        content: const Text('모든 서보의 토크가 즉시 해제됩니다. 로봇팔을 손으로 지지하고 계속하세요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DETACH'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _safetyControl('detach', '서보 해제 완료');
    }
  }

  void _showMessage(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final desktopNavigation = width >= 900;

    return CopilotOverlay(
        child: Scaffold(
      body: SafeArea(
          child: Row(
        children: [
          if (desktopNavigation) _buildSidebar(),
          Expanded(
            child: Column(children: [
              if (!desktopNavigation) _buildTopBar(),
              Expanded(
                  child: switch (_pageIndex) {
                0 => _buildDashboardPage(),
                1 => _buildRobotControlPage(),
                2 => const QualityDashboardPage(),
                _ => const DataBrowserPage(),
              }),
            ]),
          ),
        ],
      )),
      bottomNavigationBar: desktopNavigation
          ? null
          : NavigationBar(
              selectedIndex: _pageIndex,
              onDestinationSelected: (index) {
                setState(() => _pageIndex = index);
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: '대시보드',
                ),
                NavigationDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: Icon(Icons.tune),
                  label: '로봇 제어',
                ),
                NavigationDestination(
                  icon: Icon(Icons.fact_check_outlined),
                  selectedIcon: Icon(Icons.fact_check),
                  label: '품질관리',
                ),
                NavigationDestination(
                  icon: Icon(Icons.table_chart_outlined),
                  selectedIcon: Icon(Icons.table_chart),
                  label: '데이터 조회',
                ),
              ],
            ),
    ));
  }

  Widget _buildSidebar() {
    const destinations = [
      (Icons.space_dashboard_outlined, '대시보드'),
      (Icons.tune_rounded, '로봇 제어'),
      (Icons.fact_check_outlined, '품질관리'),
      (Icons.table_chart_outlined, '데이터 조회'),
    ];
    return Container(
      width: 200,
      color: DashboardTheme.navy,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 24, 12, 24),
          child: Row(children: [
            Text('CausalRoboQC',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
        Expanded(
            child: ListView(
          padding: EdgeInsets.zero,
          children: List.generate(destinations.length, (index) {
            final item = destinations[index];
            final selected = index == _pageIndex;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: selected
                    ? DashboardTheme.sidebarSelected
                    : Colors.transparent,
                child: ListTile(
                  shape: const RoundedRectangleBorder(),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  selected: selected,
                  selectedTileColor: DashboardTheme.sidebarSelected,
                  leading: Icon(item.$1,
                      size: 20,
                      color: selected
                          ? Colors.white
                          : DashboardTheme.sidebarMuted),
                  title: Text(item.$2,
                      style: TextStyle(
                          fontSize: 13,
                          color: selected
                              ? Colors.white
                              : DashboardTheme.sidebarMuted)),
                  onTap: () => setState(() => _pageIndex = index),
                ),
              ),
            );
          }),
        )),
        Material(
          color: Colors.white,
          child: Padding(
              padding: const EdgeInsets.all(12), child: _buildEmergencyStop()),
        ),
      ]),
    );
  }

  Widget _buildEmergencyStop() => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
            foregroundColor: DashboardTheme.danger,
            side: const BorderSide(color: DashboardTheme.danger)),
        onPressed: !_serialReady || _safetyBusy
            ? null
            : () => _safetyControl('estop', '비상 정지 요청 완료'),
        icon: const Icon(Icons.stop_circle_outlined, size: 18),
        label: const Text('E-STOP'),
      );

  Widget _buildTopBar() => Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: DashboardTheme.border))),
        child: Row(children: [
          const Expanded(
              child: Text('CausalRoboQC',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
          _buildEmergencyStop(),
        ]),
      );

  Widget _pageHeading(String title) => DashboardHeading(
        title: title,
        trailing: TextButton(
            onPressed: _polling ? null : () => _refresh(full: true),
            child: const Text('새로고침')),
      );

  Widget _buildRobotControlPage() => RefreshIndicator(
        onRefresh: () => _refresh(full: true),
        child: LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= 960;
          final left =
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _buildControls(),
            const SizedBox(height: DashboardTheme.sectionSpacing),
            _buildJoints(),
          ]);
          final right =
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _buildPoses(),
            const SizedBox(height: DashboardTheme.sectionSpacing),
            _buildCalibrationReadiness(),
          ]);
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: DashboardTheme.pagePadding(constraints.maxWidth),
            children: [
              _pageHeading('로봇 제어'),
              _buildConnectionBanner(),
              const SizedBox(height: DashboardTheme.sectionSpacing),
              _buildSafety(),
              const SizedBox(height: DashboardTheme.sectionSpacing),
              if (_status['camera_preview_mode'] == 'server')
                ServerCameraPreview(apiBase: _apiBase)
              else if (_status['camera_preview_mode'] == 'browser')
                const CameraPreview(),
              const SizedBox(height: DashboardTheme.sectionSpacing),
              if (wide)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 6, child: left),
                  const SizedBox(width: DashboardTheme.sectionSpacing),
                  Expanded(flex: 5, child: right),
                ])
              else ...[
                left,
                const SizedBox(height: DashboardTheme.sectionSpacing),
                right
              ],
              const SizedBox(height: DashboardTheme.sectionSpacing),
              _buildHistory(),
            ],
          );
        }),
      );

  Widget _buildDashboardPage() => RefreshIndicator(
        onRefresh: () => _refresh(full: true),
        child: LayoutBuilder(
            builder: (context, constraints) => ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: DashboardTheme.pagePadding(constraints.maxWidth),
                  children: [
                    _pageHeading('대시보드'),
                    _buildConnectionBanner(),
                    const SizedBox(height: DashboardTheme.sectionSpacing),
                    Builder(
                      builder: (context) {
                        final data = _qualitySummary;
                        return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('최근 제품 · 최대 50건',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              Wrap(
                                  spacing: 28,
                                  runSpacing: 4,
                                  children: [
                                    (
                                      '처리 제품',
                                      data == null
                                          ? '-'
                                          : '${data.processedProducts}건',
                                      DashboardTheme.ink
                                    ),
                                    (
                                      '공정 이탈률',
                                      data == null
                                          ? '-'
                                          : '${data.processDeviationRate.toStringAsFixed(1)}%',
                                      DashboardTheme.ink
                                    ),
                                    (
                                      '확인 필요',
                                      data == null
                                          ? '-'
                                          : '${data.reviewProducts}건',
                                      DashboardTheme.warning
                                    ),
                                    (
                                      '우선검사',
                                      data == null
                                          ? '-'
                                          : '${data.priorityProducts}건',
                                      DashboardTheme.danger
                                    ),
                                  ]
                                      .map((item) => DashboardMetric(
                                            label: item.$1,
                                            value: item.$2,
                                            color: item.$3,
                                            helpTerm: metricDescriptions
                                                    .containsKey(item.$1)
                                                ? item.$1
                                                : null,
                                            onTap: () =>
                                                setState(() => _pageIndex = 2),
                                          ))
                                      .toList()),
                              if (_qualityError)
                                const Padding(
                                    padding: EdgeInsets.only(top: 8),
                                    child: Text('제품 데이터를 불러오지 못했습니다.')),
                            ]);
                      },
                    ),
                    const SizedBox(height: DashboardTheme.sectionSpacing),
                    _buildRecentRuns(),
                    if (_qualitySummary != null) ...[
                      const SizedBox(height: DashboardTheme.sectionSpacing),
                      RpfAnalysisOverview(products: _qualitySummary!.products),
                    ],
                    const SizedBox(height: DashboardTheme.sectionSpacing),
                    _buildDashboardEvents(),
                  ],
                )),
      );

  String _runStatus(dynamic status) => switch (status?.toString()) {
        'completed' => '완료',
        'running' => '실행 중',
        'stopping' => '정지 중',
        'failed' => '실패',
        'interrupted' => '중단',
        'stopped' => '정지',
        'emergency_stopped' => '비상 정지',
        'detached' => '서보 해제',
        'pending' => '대기',
        _ => '상태 확인 중',
      };

  String? _eventLabel(dynamic name) => switch (name?.toString()) {
        'RUN_STARTED' => '작업 시작',
        'RUN_FINISHED' => '작업 종료',
        'RPF_STARTED' || 'CYCLE_STARTED' => '사이클 시작',
        'RPF_FINISHED' || 'CYCLE_FINISHED' || 'CYCLE_COMPLETED' => '사이클 완료',
        'PICK_RETRY_INJECTED' || 'PICK_RETRY' => '집기 재시도',
        'PICK_FAILED' => '집기 실패',
        'PLACE_FAILURE_INJECTED' || 'PLACE_FAILED' => '배치 실패',
        'WORK_TIME_OVERRUN_INJECTED' || 'WORK_TIME_EXCEEDED' => '작업시간 초과',
        'OPERATOR_INTERVENTION' => '작업자 개입',
        'RUN_EMERGENCY_STOPPED' || 'ESTOP' || 'EMERGENCY_STOP' => '비상 정지',
        'STOP' || 'RUN_STOPPED' => '작업 정지',
        'RESET' => '비상 정지 해제',
        'RUN_DETACHED' || 'DETACH' => '서보 해제',
        'RPF_FAILED' || 'ERROR' || 'RUN_FAILED' => '작업 오류',
        'RUN_INTERRUPTED' => '작업 중단',
        'RUN_STOP_FAILED' => '정지 요청 실패',
        'RUN_REVIEW_SAVED' => '작업 결과 저장',
        _ => null,
      };

  Widget _buildRecentRuns({bool all = false}) {
    final recent = all ? _runs : _runs.take(5).toList();
    return _section(
      all ? '작업 이력' : '최근 작업',
      recent.isEmpty
          ? const DashboardEmptyState(
              icon: Icons.history, title: '저장된 작업이 없습니다.')
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: recent.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final run = recent[index];
                  final id = run['id'];
                  return ListTile(
                    selected: id.toString() == _selectedRunId.toString(),
                    title: Text(run['run_mode'] == 'error'
                        ? '오류 로직 작업'
                        : run['repeat'] == true
                            ? '반복 작업'
                            : '1회 작업'),
                    subtitle: Text(
                        '${_formatTime(run['started_at'])} · ${run['cycle_count'] ?? 0}회',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    trailing: Text(_runStatus(run['status'])),
                    onTap: () {
                      setState(() {
                        _selectedRunId = id;
                        _events = [];
                      });
                      if (id != null) unawaited(_loadEvents(id));
                    },
                  );
                },
              ),
            ),
    );
  }

  Widget _buildDashboardEvents({bool all = false}) {
    final visibleEvents = _events.where((e) => _eventLabel(e['name']) != null);
    final events = (all ? visibleEvents : visibleEvents.take(5)).toList();
    return _section(
      '선택 작업의 주요 이벤트',
      events.isEmpty
          ? const DashboardEmptyState(
              icon: Icons.history, title: '표시할 주요 이벤트가 없습니다.')
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: events.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final event = events[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Wrap(spacing: 20, runSpacing: 4, children: [
                      Text(_formatTime(event['created_at']),
                          style: Theme.of(context).textTheme.bodySmall),
                      Text(_eventLabel(event['name'])!),
                    ]),
                  );
                },
              ),
            ),
    );
  }

  Widget _buildConnectionBanner() {
    final run = _map(_status['active_run']);
    final latest = run.isNotEmpty ? run : _runs.firstOrNull;
    final message = !_backendOnline
        ? (_lastError ?? '서버 연결을 확인하고 있습니다.')
        : !_serialReady
            ? '로봇 연결을 확인해 주세요.'
            : _estopActive
                ? '비상 정지 상태입니다. 안전 확인 후 RESET을 누르세요.'
                : _savedPoseCount < 7
                    ? '필수 포즈 설정이 필요합니다 ($_savedPoseCount/7).'
                    : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 24, runSpacing: 12, children: [
        _connectionStatus('서버', _backendOnline),
        _connectionStatus('로봇', _backendOnline && _serialReady),
        Text(
            '최근 작업 · ${latest == null ? '기록 없음' : _runStatus(latest['status'])}'),
        if (run.isNotEmpty && run['current_pose'] != null)
          Text('현재 포즈 · ${run['current_pose']}'),
      ]),
      if (message != null) ...[
        const SizedBox(height: 8),
        Text(message, style: Theme.of(context).textTheme.bodySmall),
      ],
      const Divider(height: 24),
    ]);
  }

  Widget _connectionStatus(String label, bool connected) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label),
        const SizedBox(width: 8),
        Text(connected ? '연결됨' : '연결 대기'),
      ]);

  Widget _section(String title, Widget child) =>
      DashboardSection(title: title, child: child);

  Widget _buildCalibrationReadiness() {
    final calibration = _calibration;
    final required = _integer(calibration['required_samples']) ?? 0;
    final labeled = _integer(calibration['labeled_samples']) ?? 0;
    final latestId = _latestUnreviewedRunId;
    return _section(
        '작업 결과 기록',
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_repeatUnlocked
              ? '반복 실행 가능'
              : '반복 실행 준비 · 결과 확정 $labeled / $required'),
          if (!_repeatUnlocked) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
                value:
                    required <= 0 ? 0 : (labeled / required).clamp(0.0, 1.0)),
          ],
          const SizedBox(height: 12),
          Text(latestId == null ? '기록할 작업 결과가 없습니다.' : '완료된 작업의 결과를 기록해 주세요.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: latestId == null || _busy || _reviewDialogOpen
                    ? null
                    : () => _showRunReview(latestId),
                child: const Text('결과 기록')),
            TextButton(
                onPressed: _busy || _runActive || _reviewDialogOpen
                    ? null
                    : _confirmCalibrationReset,
                child: const Text('판정 데이터 초기화')),
          ]),
        ]));
  }

  Widget _buildControls() {
    final run = _map(_status['active_run']);
    return _section(
        '작업 실행',
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(
                onPressed: _readyToRun ? () => _startRun(false) : null,
                child: const Text('1회 실행')),
            OutlinedButton(
                onPressed: _readyToRun && _repeatUnlocked
                    ? () => _startRun(true)
                    : null,
                child: const Text('반복 실행')),
          ]),
          const SizedBox(height: 12),
          Text(run.isEmpty
              ? '실행 대기'
              : '${_runStatus(run['status'])} · ${run['current_pose'] ?? '준비 중'} · ${run['cycle_count'] ?? 0}회'),
        ]));
  }

  Widget _buildSafety() => Container(
      padding: const EdgeInsets.all(DashboardTheme.cardPadding),
      decoration: BoxDecoration(
          color: DashboardTheme.background,
          border: Border.all(color: DashboardTheme.border),
          borderRadius: BorderRadius.circular(DashboardTheme.radius)),
      child: _section(
          '안전 제어',
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: !_serialReady || _safetyBusy
                    ? null
                    : () => _safetyControl('stop', '작업 정지 요청 완료'),
                child: const Text('STOP')),
            FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: DashboardTheme.danger,
                    foregroundColor: Colors.white),
                onPressed: !_serialReady || _safetyBusy
                    ? null
                    : () => _safetyControl('estop', '비상 정지 요청 완료'),
                child: const Text('E-STOP')),
            OutlinedButton(
                onPressed: !_serialReady || _safetyBusy || !_estopActive
                    ? null
                    : () => _safetyControl('reset', '비상 정지 해제'),
                child: const Text('RESET')),
            OutlinedButton(
                onPressed: !_serialReady || _safetyBusy ? null : _confirmDetach,
                child: const Text('DETACH')),
          ])));

  Widget _buildJoints() {
    final controlsEnabled =
        _serialReady && !_runActive && !_estopActive && !_safetyBusy && !_busy;
    return _section(
      '관절 제어',
      Column(
        children: List.generate(6, (index) {
          final limits = _limitsFor(index);
          final minimum = limits[0];
          final maximum = limits[1];
          final known = _angles[index];
          final draft = _draftAngles[index].clamp(minimum, maximum);
          final sending = _jointBusy.contains(index);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: MediaQuery.sizeOf(context).width < 600 ? 52 : 72,
                  child: Text(
                    'J${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton.outlined(
                  tooltip: '-1°',
                  onPressed: !controlsEnabled ||
                          sending ||
                          known == null ||
                          known <= minimum
                      ? null
                      : () => _sendJoint(index, known - 1),
                  icon: const Icon(Icons.remove, size: 18),
                ),
                Expanded(
                  child: Slider(
                    min: minimum.toDouble(),
                    max: maximum.toDouble(),
                    divisions: maximum - minimum,
                    value: draft.toDouble(),
                    label: '$draft°',
                    onChanged: !controlsEnabled || sending
                        ? null
                        : (value) {
                            setState(() => _draftAngles[index] = value.round());
                          },
                    onChangeEnd: !controlsEnabled || sending
                        ? null
                        : (value) => _sendJoint(index, value.round()),
                  ),
                ),
                IconButton.outlined(
                  tooltip: '+1°',
                  onPressed: !controlsEnabled ||
                          sending ||
                          known == null ||
                          known >= maximum
                      ? null
                      : () => _sendJoint(index, known + 1),
                  icon: const Icon(Icons.add, size: 18),
                ),
                SizedBox(
                  width: MediaQuery.sizeOf(context).width < 600 ? 48 : 70,
                  child: Text(
                    known == null ? '미설정' : '$known°',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: known == null ? DashboardTheme.muted : null,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildPoses() {
    final saved = _poses[_selectedPose];
    return _section(
      '포즈',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _selectedPose,
            decoration: const InputDecoration(
              labelText: '포즈',
            ),
            items: _requiredPoses
                .map(
                  (name) => DropdownMenuItem(
                    value: name,
                    child: Text(
                      _poses[name] == null ? '$name · 미저장' : '$name · 저장됨',
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) setState(() => _selectedPose = value);
            },
          ),
          const SizedBox(height: 10),
          Text(saved == null
              ? '설정 각도: -'
              : List.generate(
                      saved.length, (index) => 'J${index + 1} ${saved[index]}°')
                  .join(' · ')),
          const SizedBox(height: 10),
          Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: _busy ||
                        _safetyBusy ||
                        _runActive ||
                        !_serialReady ||
                        _estopActive ||
                        saved == null
                    ? null
                    : () => _perform('$_selectedPose 이동 요청 완료', () async {
                          await _request(
                            'POST',
                            '/api/poses/${Uri.encodeComponent(_selectedPose)}/move',
                          );
                        }),
                child: const Text('선택 포즈 이동'),
              )),
        ],
      ),
    );
  }

  Widget _buildHistory() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _buildRecentRuns(all: true),
        const SizedBox(height: DashboardTheme.sectionSpacing),
        _buildDashboardEvents(all: true),
      ]);

  String _formatTime(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (parsed == null) return '-';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}:${two(parsed.second)}';
  }
}
