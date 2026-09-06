import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'quality_dashboard_page.dart';
import 'dashboard_theme.dart';

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
  static const _normalSequenceFallback = [
    'HOME',
    'PICK_ABOVE',
    'PICK',
    'GRAB',
    'LIFT',
    'PLACE',
    'RELEASE',
    'HOME',
  ];
  static const _errorSequenceFallback = [
    'HOME',
    'PICK_ABOVE',
    'ERROR_PICK',
    'PICK_ABOVE',
    'PICK',
    'GRAB',
    'LIFT',
    'ERROR_PLACE',
    'LIFT',
    'PLACE',
    'RELEASE',
    'HOME',
  ];
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
      if (full || includeRuns) await _loadRuns();
      if (full) await _loadPoses();
      if (_selectedRunId != null && (full || includeEvents)) {
        await _loadEvents(_selectedRunId!);
      }
      if (!mounted) return;
      setState(() {
        _backendOnline = true;
        _lastError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _backendOnline = false;
        _lastError = error.toString().replaceFirst('Exception: ', '');
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

  int get _savedErrorPoseCount {
    return _errorPoses.where((name) => _poses[name]?.length == 6).length;
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
              title: Text('Run #$runId 결과 기록'),
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
      await _perform('Run #$runId 결과 저장 완료', () async {
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
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        error.toString().replaceFirst('Exception: ', ''),
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
    } catch (error) {
      if (mounted) {
        _showMessage(
          'Joint ${index + 1}: ${error.toString().replaceFirst('Exception: ', '')}',
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
    } catch (error) {
      if (mounted) {
        _showMessage(
          error.toString().replaceFirst('Exception: ', ''),
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
        title: const Text('Servo Detach'),
        content: const Text('모든 서보의 토크가 즉시 해제됩니다. 로봇팔을 손으로 지지하고 계속하세요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Detach'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _safetyControl('detach', 'Servo Detach 완료');
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
    final title = switch (_pageIndex) {
      0 => '대시보드',
      1 => '로봇 제어',
      _ => '품질관리 대시보드',
    };

    return Scaffold(
      body: SafeArea(
          child: Row(
        children: [
          if (desktopNavigation) _buildSidebar(),
          Expanded(
            child: Column(children: [
              _buildTopBar(title, desktopNavigation),
              Expanded(
                  child: switch (_pageIndex) {
                0 => _buildDashboardPage(),
                1 => _buildRobotControlPage(),
                _ => const QualityDashboardPage(),
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
              ],
            ),
    );
  }

  Widget _buildSidebar() {
    const destinations = [
      (Icons.space_dashboard_outlined, '대시보드', 'Overview'),
      (Icons.tune_rounded, '로봇 제어', 'Robot control'),
      (Icons.fact_check_outlined, '품질관리', 'Quality insights'),
    ];
    return Container(
      width: 224,
      color: DashboardTheme.navy,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 30, 18, 36),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                  color: const Color(0xff2dd4bf).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11)),
              child: const Icon(Icons.precision_manufacturing_outlined,
                  color: Color(0xff68ddd0), size: 23),
            ),
            const SizedBox(width: 10),
            const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CausalRoboQC',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5)),
                  SizedBox(height: 3),
                  Text('ROBOT OPERATIONS',
                      style: TextStyle(
                          color: Color(0xff91a9b8),
                          fontSize: 8,
                          letterSpacing: 1.6)),
                ]),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(26, 0, 20, 14),
          child: Text('WORKSPACE',
              style: TextStyle(
                  color: Color(0xff829aa9),
                  fontSize: 10,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w600)),
        ),
        Expanded(
            child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: List.generate(destinations.length, (index) {
            final item = destinations[index];
            final selected = index == _pageIndex;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: selected ? const Color(0xff244554) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: ListTile(
                  selected: selected,
                  selectedTileColor: Colors.transparent,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                  leading: Icon(item.$1,
                      size: 21,
                      color: selected
                          ? const Color(0xff75e3d6)
                          : const Color(0xff91a9b8)),
                  title: Text(item.$2,
                      style: TextStyle(
                          color:
                              selected ? Colors.white : const Color(0xffc0cfd8),
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  subtitle: Text(item.$3,
                      style: const TextStyle(
                          color: Color(0xff91a9b8), fontSize: 10)),
                  trailing: selected
                      ? Container(
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(
                              color: Color(0xff75e3d6), shape: BoxShape.circle))
                      : null,
                  onTap: () => setState(() => _pageIndex = index),
                ),
              ),
            );
          }),
        )),
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              border: Border.all(color: const Color(0xff34505f)),
              borderRadius: BorderRadius.circular(12)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                  _backendOnline
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                  size: 17,
                  color: const Color(0xffa9c2ce)),
              const SizedBox(width: 8),
              Text(_backendOnline ? '서버 연결됨' : '서버 연결 대기',
                  style:
                      const TextStyle(color: Color(0xffd3e1e8), fontSize: 12)),
            ]),
            const SizedBox(height: 7),
            const Text('6-AXIS ROBOT ARM',
                style: TextStyle(
                    color: Color(0xff829aa9), fontSize: 9, letterSpacing: 1.1)),
          ]),
        ),
      ]),
    );
  }

  Widget _buildTopBar(String title, bool desktop) {
    return Container(
      height: 72,
      padding: EdgeInsets.symmetric(horizontal: desktop ? 28 : 16),
      decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: DashboardTheme.border))),
      child: Row(children: [
        if (desktop) ...[
          const Text('워크스페이스',
              style: TextStyle(color: DashboardTheme.muted, fontSize: 12)),
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.chevron_right,
                  size: 16, color: DashboardTheme.muted)),
        ],
        Expanded(
            child: Text(desktop ? title : 'CausalRoboQC',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700))),
        if (MediaQuery.sizeOf(context).width >= 600) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
                color: DashboardTheme.background,
                borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                      color: _socketOnline
                          ? DashboardTheme.success
                          : DashboardTheme.warning,
                      shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text(_socketOnline ? '실시간 연결' : '연결 대기',
                  style: const TextStyle(
                      fontSize: 11, color: DashboardTheme.muted)),
            ]),
          ),
          const SizedBox(width: 12),
        ],
        IconButton(
          tooltip: '새로고침',
          onPressed: _polling ? null : () => _refresh(full: true),
          icon: const Icon(Icons.refresh_rounded, size: 20),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Emergency Stop',
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: DashboardTheme.danger,
              side: BorderSide(
                  color: DashboardTheme.danger
                      .withValues(alpha: _serialReady ? 0.4 : 0.15)),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: !_serialReady || _safetyBusy
                ? null
                : () => _safetyControl('estop', 'Emergency Stop 작동'),
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('E-STOP',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  Widget _buildRobotControlPage() {
    return RefreshIndicator(
      onRefresh: () => _refresh(full: true),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1050;
          final left = <Widget>[
            _buildReadiness(),
            const SizedBox(height: 20),
            _buildControls(),
            const SizedBox(height: 20),
            _buildCalibrationReadiness(),
            const SizedBox(height: 20),
            _buildJoints(),
          ];
          final right = <Widget>[
            _buildPoses(),
            const SizedBox(height: 20),
            _buildHistory(),
          ];
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: DashboardTheme.pagePadding(constraints.maxWidth),
            children: [
              const DashboardHeading(
                eyebrow: 'ROBOT CONTROL',
                title: '로봇 제어',
                description: '실행 준비부터 자세 조정까지, 로봇팔의 모든 동작을 관리하세요.',
              ),
              _buildConnectionBanner(),
              const SizedBox(height: 20),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: Column(children: left)),
                    const SizedBox(width: 20),
                    Expanded(flex: 5, child: Column(children: right)),
                  ],
                )
              else ...[
                ...left,
                const SizedBox(height: 20),
                ...right,
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildDashboardPage() {
    return RefreshIndicator(
      onRefresh: () => _refresh(full: true),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1050;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: DashboardTheme.pagePadding(constraints.maxWidth),
            children: [
              DashboardHeading(
                eyebrow: 'OPERATIONS OVERVIEW',
                title: '대시보드',
                description: '로봇의 현재 상태와 작업 흐름을 한눈에 확인하세요.',
                trailing: OutlinedButton.icon(
                  onPressed: () => setState(() => _pageIndex = 1),
                  icon: const Icon(Icons.tune_rounded, size: 17),
                  label: const Text('로봇 제어'),
                ),
              ),
              _buildDashboardBanner(),
              const SizedBox(height: 20),
              _buildStatusRibbon(),
              const SizedBox(height: 20),
              _buildRunKpis(),
              const SizedBox(height: 20),
              _buildSequenceProgress(),
              const SizedBox(height: 20),
              _buildJointSummary(),
              const SizedBox(height: 20),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: _buildRecentRuns()),
                    const SizedBox(width: 20),
                    Expanded(flex: 6, child: _buildDashboardEvents()),
                  ],
                )
              else ...[
                _buildRecentRuns(),
                const SizedBox(height: 20),
                _buildDashboardEvents(),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildDashboardBanner() {
    final run = _map(_status['active_run']);
    final robot = _map(_status['robot']);
    final serial = _map(_status['serial']);
    final active = run.isNotEmpty;
    late final String heading;
    late final String description;
    if (!_backendOnline) {
      heading = 'FastAPI 연결 대기';
      description = '노트북에서 FastAPI 서버가 실행 중인지 확인하세요.';
    } else if (!_serialReady) {
      heading = 'Arduino 연결 대기';
      description =
          serial['last_error']?.toString() ?? 'USB Serial 연결과 펌웨어 응답을 확인하세요.';
    } else if (_estopActive) {
      heading = 'Emergency Stop 작동 중';
      description = '안전을 확인한 뒤 로봇 제어 화면에서 E-STOP을 해제하세요.';
    } else if (active) {
      heading =
          'Run #${run['id']} · ${run['run_mode'] == 'error' ? '오류 로직' : run['repeat'] == true ? '반복 실행' : '1회 실행'}';
      description = '${run['current_pose'] ?? '시작 대기'} 자세를 수행하고 있습니다.';
    } else if (_readyToRun) {
      heading = '로봇팔 실행 준비 완료';
      description = '저장된 8단계 Pick & Place 시퀀스를 실행할 수 있습니다.';
    } else if (_savedPoseCount < 7) {
      heading = 'Pose 설정이 필요합니다';
      description = 'robot_arm에서 필수 Pose를 설정한 뒤 상태를 확인하세요.';
    } else {
      heading = '로봇팔 명령 처리 중';
      description = '현재 명령이 끝나면 저장된 Pose로 바로 실행할 수 있습니다.';
    }

    return Container(
      padding: const EdgeInsets.all(26),
      decoration: DashboardTheme.bannerDecoration,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final summary = Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _darkMetric(
                '상태',
                !_backendOnline
                    ? 'OFFLINE'
                    : _estopActive
                        ? 'E-STOP'
                        : active
                            ? '${run['status'] ?? '-'}'
                            : 'IDLE',
              ),
              _darkMetric(
                '현재 Pose',
                active ? '${run['current_pose'] ?? '-'}' : '-',
              ),
              _darkMetric('Cycle', active ? '${run['cycle_count'] ?? 0}' : '-'),
              _darkMetric(
                'Servo',
                !_serialReady
                    ? 'UNKNOWN'
                    : robot['moving'] == true
                        ? 'MOVING'
                        : 'STILL',
              ),
            ],
          );
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                active ? 'ACTIVE RUN' : 'ROBOT ARM STATUS',
                style: const TextStyle(
                  color: Color(0xff92a6bd),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                heading,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                description,
                style: const TextStyle(color: Color(0xffb9c5d2)),
              ),
            ],
          );
          if (constraints.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, const SizedBox(height: 18), summary],
            );
          }
          return Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: 24),
              summary,
            ],
          );
        },
      ),
    );
  }

  Widget _darkMetric(String label, String value) {
    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xff8296ac), fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  int get _attachedCount {
    final mask = _integer(_map(_status['robot'])['attached_mask']) ?? 0;
    return mask.toRadixString(2).split('').where((bit) => bit == '1').length;
  }

  Widget _buildStatusRibbon() {
    final serial = _map(_status['serial']);
    final port = serial['port']?.toString() ?? '/dev/ttyACM0';
    final cells = <Widget>[
      _ribbonCell('API', _backendOnline ? 'ONLINE' : 'OFFLINE', _backendOnline),
      _ribbonCell(
        'WebSocket',
        _socketOnline ? 'LIVE' : 'POLLING',
        _socketOnline,
      ),
      _ribbonCell(
        'Serial',
        _serialReady ? '$port · READY' : '$port · 대기',
        _serialReady,
      ),
      _ribbonCell('Servo Attach', '$_attachedCount/6', _attachedCount == 6),
      _ribbonCell('Poses', '$_savedPoseCount/7', _savedPoseCount == 7),
      _ribbonCell(
        'E-STOP',
        !_serialReady ? '확인 불가' : (_estopActive ? '작동' : '해제'),
        _serialReady && !_estopActive,
        danger: _serialReady && _estopActive,
      ),
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 960
                ? 6
                : constraints.maxWidth >= 600
                    ? 3
                    : 2;
            final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: cells
                  .map((cell) => SizedBox(width: width, child: cell))
                  .toList(),
            );
          },
        ),
      ),
    );
  }

  Widget _ribbonCell(
    String label,
    String value,
    bool good, {
    bool danger = false,
  }) {
    final color = danger
        ? Theme.of(context).colorScheme.error
        : good
            ? DashboardTheme.success
            : DashboardTheme.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildRunKpis() {
    final recent = _runs.take(30).toList();
    final completed =
        recent.where((run) => run['status'] == 'completed').length;
    final interrupted = recent.where((run) {
      return const {
        'failed',
        'interrupted',
        'stopped',
        'emergency_stopped',
        'detached',
      }.contains(run['status']);
    }).length;
    final repeatRuns = recent.where((run) => run['repeat'] == true).length;
    final completionRate =
        recent.isEmpty ? '0%' : '${(completed * 100 / recent.length).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('최근 30 Run 요약', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth >= 700
                ? (constraints.maxWidth - 36) / 4
                : (constraints.maxWidth - 12) / 2;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _kpiTile('전체 Run', '${recent.length}', Icons.history, width),
                _kpiTile('완료', '$completed', Icons.task_alt, width),
                _kpiTile('중단 / 오류', '$interrupted', Icons.error_outline, width),
                _kpiTile(
                  '완료율',
                  completionRate,
                  Icons.donut_small,
                  width,
                  note: '반복 $repeatRuns',
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _kpiTile(
    String label,
    String value,
    IconData icon,
    double width, {
    String? note,
  }) {
    final color = switch (label) {
      '완료' => DashboardTheme.success,
      '중단 / 오류' => DashboardTheme.danger,
      '완료율' => const Color(0xff6c6ba9),
      _ => DashboardTheme.primary,
    };
    return SizedBox(
      width: width,
      child: DashboardMetric(
          label: label, value: value, icon: icon, color: color, note: note),
    );
  }

  Widget _buildSequenceProgress() {
    final run = _map(_status['active_run']);
    final active = run.isNotEmpty;
    final errorMode = run['run_mode']?.toString() == 'error';
    final stepIndex = _integer(run['step_index']) ?? -1;
    final rawSequence =
        errorMode ? _status['error_sequence'] : _status['sequence'];
    final fallback =
        errorMode ? _errorSequenceFallback : _normalSequenceFallback;
    final sequence = rawSequence is List && rawSequence.isNotEmpty
        ? rawSequence.map((item) => item.toString()).toList()
        : fallback;

    return _section(
      '${sequence.length}단계 ${errorMode ? '오류 ' : ''}Pick & Place 진행',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            active
                ? 'Run #${run['id']} · Step ${stepIndex + 1}/${sequence.length}'
                : '활성 Run이 없을 때는 진행 상태가 표시되지 않습니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(sequence.length, (index) {
                final complete = active && index < stepIndex;
                final current = active && index == stepIndex;
                final color = current
                    ? Theme.of(context).colorScheme.primary
                    : complete
                        ? DashboardTheme.success
                        : Theme.of(context).colorScheme.outlineVariant;
                return Row(
                  children: [
                    Container(
                      width: 126,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: current
                            ? color.withValues(alpha: 0.1)
                            : Theme.of(
                                context,
                              ).colorScheme.surfaceContainerLowest,
                        border: Border.all(color: color),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 13,
                            backgroundColor: complete || current
                                ? color
                                : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHigh,
                            foregroundColor: complete || current
                                ? Colors.white
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            child: complete
                                ? const Icon(Icons.check, size: 15)
                                : Text('${index + 1}'),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              sequence[index],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (index < sequence.length - 1)
                      SizedBox(
                        width: 18,
                        child: Divider(
                          thickness: 2,
                          color: complete
                              ? DashboardTheme.success
                              : Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJointSummary() {
    final robot = _map(_status['robot']);
    final current = robot['current_angles'] is List
        ? robot['current_angles'] as List
        : const <dynamic>[];
    final target = robot['target_angles'] is List
        ? robot['target_angles'] as List
        : const <dynamic>[];
    final attachedMask = _integer(robot['attached_mask']) ?? 0;

    return _section(
      'Joint 현재 / 목표 각도',
      LayoutBuilder(
        builder: (context, constraints) {
          return GridView.builder(
            itemCount: 6,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: constraints.maxWidth >= 1050
                  ? 6
                  : constraints.maxWidth >= 580
                      ? 3
                      : constraints.maxWidth >= 280
                          ? 2
                          : 1,
              mainAxisExtent: 118,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemBuilder: (context, index) {
              final currentAngle = index < current.length
                  ? _integer(current[index])
                  : _angles[index];
              final targetAngle =
                  index < target.length ? _integer(target[index]) : null;
              final attached = (attachedMask & (1 << index)) != 0;
              final moving = currentAngle != null &&
                  targetAngle != null &&
                  currentAngle != targetAngle;
              final limits = _limitsFor(index);
              final color = moving
                  ? DashboardTheme.warning
                  : attached
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline;
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.06),
                  border: Border.all(color: color.withValues(alpha: 0.24)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Joint ${index + 1}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          attached
                              ? (moving ? 'MOVING' : 'ATTACHED')
                              : 'DETACHED',
                          style: TextStyle(
                            color: color,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      '${currentAngle == null ? '-' : '$currentAngle°'}  →  '
                      '${targetAngle == null ? '-' : '$targetAngle°'}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '범위 ${limits[0]}°–${limits[1]}°',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildRecentRuns() {
    final recent = _runs.take(5).toList();
    return _section(
      '최근 Run 5개',
      SizedBox(
        height: 330,
        child: recent.isEmpty
            ? const DashboardEmptyState(
                icon: Icons.history_rounded,
                title: '아직 저장된 Run이 없습니다',
                description: '작업을 실행하면 이곳에 이력이 쌓입니다.')
            : ListView.separated(
                itemCount: recent.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final run = recent[index];
                  final id = run['id'];
                  final selected = id.toString() == _selectedRunId.toString();
                  final status = run['status']?.toString() ?? '-';
                  final complete = status == 'completed';
                  return ListTile(
                    selected: selected,
                    leading: CircleAvatar(
                      backgroundColor: (complete
                              ? DashboardTheme.success
                              : Theme.of(context).colorScheme.primary)
                          .withValues(alpha: 0.12),
                      foregroundColor: complete
                          ? DashboardTheme.success
                          : Theme.of(context).colorScheme.primary,
                      child: Text('#$id', style: const TextStyle(fontSize: 11)),
                    ),
                    title: Text(
                      '${run['run_mode'] == 'error' ? '오류' : run['repeat'] == true ? '반복' : '1회'} · $status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${run['current_pose'] ?? '-'} · cycle ${run['cycle_count'] ?? 0}\n'
                      '${_formatTime(run['started_at'])}',
                      maxLines: 2,
                    ),
                    onTap: () {
                      setState(() {
                        _selectedRunId = id;
                        _events = <Map<String, dynamic>>[];
                      });
                      if (id != null) unawaited(_loadEvents(id));
                    },
                  );
                },
              ),
      ),
    );
  }

  Widget _buildDashboardEvents() {
    return _section(
      _selectedRunId == null
          ? '선택 Run RPF 이벤트'
          : 'Run #$_selectedRunId · RPF 이벤트',
      SizedBox(
        height: 330,
        child: _events.isEmpty
            ? const DashboardEmptyState(
                icon: Icons.timeline_rounded,
                title: '표시할 R/P/F 이벤트가 없습니다',
                description: 'Run을 선택하면 단계별 이벤트를 확인할 수 있습니다.')
            : ListView.separated(
                itemCount: _events.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final event = _events[index];
                  final type = event['event_type']?.toString() ?? '?';
                  final color = switch (type) {
                    'R' => DashboardTheme.primary,
                    'P' => DashboardTheme.warning,
                    'F' => DashboardTheme.success,
                    _ => Colors.grey,
                  };
                  final payload = event['payload'];
                  final details = payload == null ||
                          (payload is Map && payload.isEmpty)
                      ? _formatTime(event['created_at'])
                      : '${_formatTime(event['created_at'])} · ${jsonEncode(payload)}';
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 15,
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                      child: Text(type),
                    ),
                    title: Text(event['name']?.toString() ?? '-'),
                    subtitle: Text(
                      details,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildConnectionBanner() {
    final serial = _map(_status['serial']);
    final robot = _map(_status['robot']);
    final run = _map(_status['active_run']);
    final port = serial['port']?.toString() ?? '/dev/ttyACM0';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _statusChip('API', _backendOnline, Icons.dns_outlined),
            _statusChip('WebSocket', _socketOnline, Icons.sync_alt),
            _statusChip(
              serial['connected'] == true ? '$port 연결' : '$port 미연결',
              serial['connected'] == true,
              Icons.usb,
            ),
            _statusChip(
              robot['estop'] == true ? 'E-STOP 작동' : 'E-STOP 해제',
              robot['estop'] != true,
              Icons.warning_amber,
            ),
            Text(
              run.isEmpty
                  ? '활성 Run 없음'
                  : 'Run #${run['id']} · ${run['status'] ?? '-'} · ${run['current_pose'] ?? '-'}',
            ),
            if (_lastError != null)
              Text(
                _lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String label, bool good, IconData icon) {
    final color = good ? DashboardTheme.success : DashboardTheme.danger;
    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
      side: BorderSide(color: color.withValues(alpha: 0.35)),
      backgroundColor: color.withValues(alpha: 0.08),
    );
  }

  Widget _section(String title, Widget child) {
    final icon = switch (title) {
      'Joint 현재 / 목표 각도' || 'Joint 수동 제어' => Icons.tune_rounded,
      '실행 준비 상태' => Icons.checklist_rounded,
      '반복 실행 준비 데이터' => Icons.rule_folder_outlined,
      '작업 제어' => Icons.play_circle_outline,
      'Pose Playback' => Icons.precision_manufacturing_outlined,
      '최근 Run 5개' || 'Run / RPF 이벤트 이력' => Icons.history_rounded,
      _ => Icons.analytics_outlined,
    };
    return DashboardSection(title: title, icon: icon, child: child);
  }

  Widget _buildReadiness() {
    final serial = _map(_status['serial']);
    final robot = _map(_status['robot']);
    final attachedMask = _integer(robot['attached_mask']) ?? 0;
    final attachedCount = attachedMask
        .toRadixString(2)
        .split('')
        .where((bit) => bit == '1')
        .length;
    return _section(
      '실행 준비 상태',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _progressRow('Arduino Serial', _serialReady ? 1 : 0, 1),
          _progressRow('필수 Pose 준비', _savedPoseCount, 7),
          const SizedBox(height: 8),
          Text(
            !_serialReady
                ? 'Arduino Serial 연결 후 실행할 수 있습니다.'
                : _savedPoseCount < 7
                    ? 'robot_arm에서 필수 Pose 7개를 설정해야 실행할 수 있습니다.'
                    : _estopActive
                        ? 'E-STOP을 해제하면 실행할 수 있습니다.'
                        : _runActive
                            ? '현재 작업을 실행하고 있습니다.'
                            : _busy || _safetyBusy
                                ? '로봇팔 명령을 처리하고 있습니다.'
                                : '저장된 Pose로 바로 실행할 수 있습니다.',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color:
                  _readyToRun ? DashboardTheme.success : DashboardTheme.warning,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Serial: ${serial['ready'] == true ? 'READY' : '대기'}  ·  '
            'Servo attach: $attachedCount/6  ·  '
            'Moving: ${robot['moving'] == true ? 'YES' : 'NO'}',
          ),
        ],
      ),
    );
  }

  Widget _progressRow(String label, int value, int total) {
    final complete = value >= total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            complete ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: complete ? DashboardTheme.success : DashboardTheme.warning,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text('$value/$total'),
        ],
      ),
    );
  }

  Widget _buildCalibrationReadiness() {
    final calibration = _calibration;
    final required = _integer(calibration['required_samples']) ?? 0;
    final labeled = _integer(calibration['labeled_samples']) ?? 0;
    final normal = _integer(calibration['normal_samples']) ?? 0;
    final abnormal = _integer(calibration['abnormal_samples']) ?? 0;
    final remaining = _integer(calibration['remaining_samples']) ?? 0;
    final progress =
        required <= 0 ? 0.0 : (labeled / required).clamp(0.0, 1.0).toDouble();
    final latestRaw = calibration['latest_unreviewed_run'];
    final latest = _map(latestRaw);
    final latestId = _latestUnreviewedRunId;
    final lockColor =
        _repeatUnlocked ? DashboardTheme.success : DashboardTheme.warning;

    return _section(
      '반복 실행 준비 데이터',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '결과 확정 $labeled / $required',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Text('남은 결과 $remaining건'),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress, minHeight: 8),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                avatar: Icon(
                  Icons.check_circle,
                  color: DashboardTheme.success,
                  size: 18,
                ),
                label: Text('정상 $normal건'),
              ),
              Chip(
                avatar: Icon(
                  Icons.warning_amber,
                  color: Theme.of(context).colorScheme.error,
                  size: 18,
                ),
                label: Text('이상 $abnormal건'),
              ),
              Chip(
                avatar: Icon(
                  _repeatUnlocked ? Icons.lock_open : Icons.lock_outline,
                  color: lockColor,
                  size: 18,
                ),
                label: Text(
                  _repeatUnlocked ? '반복 실행 잠금 해제' : '반복 실행 잠김',
                ),
                side: BorderSide(color: lockColor.withValues(alpha: 0.35)),
                backgroundColor: lockColor.withValues(alpha: 0.08),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(12),
            ),
            child: latestId == null
                ? const Text('결과를 기록할 미판정 Run이 없습니다.')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '최신 미판정 ${latest['run_mode'] == 'error' ? '오류' : '1회'} Run #$latestId',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        latest.isEmpty
                            ? '완료 결과 판정 대기'
                            : '${latest['status'] ?? 'completed'} · '
                                'cycle ${latest['cycle_count'] ?? 0} · '
                                '${_formatTime(latest['finished_at'])}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: _busy || _reviewDialogOpen
                              ? null
                              : () => _showRunReview(latestId),
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('결과 기록'),
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _busy || _runActive || _reviewDialogOpen
                  ? null
                  : _confirmCalibrationReset,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('판정 데이터 초기화'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final robot = _map(_status['robot']);
    final estop = robot['estop'] == true;
    return _section(
      '작업 제어',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _readyToRun ? () => _startRun(false) : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('1회 실행'),
              ),
              FilledButton.tonalIcon(
                onPressed: _readyToRun && _savedErrorPoseCount == 2
                    ? () => _startRun(false, mode: 'error')
                    : null,
                icon: const Icon(Icons.warning_amber),
                label: const Text('오류 로직 실행'),
              ),
              FilledButton.icon(
                onPressed: _readyToRun && _repeatUnlocked
                    ? () => _startRun(true)
                    : null,
                icon: Icon(
                  _repeatUnlocked ? Icons.repeat : Icons.lock_outline,
                ),
                label: const Text('반복 실행'),
              ),
              OutlinedButton.icon(
                onPressed: !_serialReady || _safetyBusy
                    ? null
                    : () => _safetyControl('stop', '작업 정지 요청 완료'),
                icon: const Icon(Icons.stop),
                label: const Text('정지'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: !_serialReady || _safetyBusy
                    ? null
                    : () => _safetyControl('estop', 'Emergency Stop 작동'),
                icon: const Icon(Icons.report),
                label: const Text('E-STOP'),
              ),
              OutlinedButton.icon(
                onPressed: !_serialReady || _safetyBusy || !estop
                    ? null
                    : () => _safetyControl('reset', 'Emergency Stop 해제'),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset'),
              ),
              OutlinedButton.icon(
                onPressed: !_serialReady || _safetyBusy ? null : _confirmDetach,
                icon: const Icon(Icons.link_off),
                label: const Text('Servo Detach'),
              ),
            ],
          ),
          if (_savedErrorPoseCount < 2) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: DashboardTheme.warning,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'robot_arm에서 ERROR_PICK, ERROR_PLACE를 저장해야 합니다.',
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildJoints() {
    final controlsEnabled =
        _serialReady && !_runActive && !_estopActive && !_safetyBusy && !_busy;
    return _section(
      'Joint 수동 제어',
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
                    'Joint ${index + 1}',
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
                      color: known == null ? DashboardTheme.warning : null,
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
    final normalSequence = (_status['sequence'] is List
            ? _status['sequence'] as List
            : _normalSequenceFallback)
        .join(' → ');
    final errorSequence = (_status['error_sequence'] is List
            ? _status['error_sequence'] as List
            : _errorSequenceFallback)
        .join(' → ');
    return _section(
      'Pose Playback',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _selectedPose,
            decoration: const InputDecoration(
              labelText: 'Pose',
              border: OutlineInputBorder(),
            ),
            items: _poseNames
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
          Text(saved == null ? '설정 각도: -' : '설정 각도: ${saved.join(', ')}'),
          const SizedBox(height: 10),
          OutlinedButton.icon(
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
            icon: const Icon(Icons.directions_run),
            label: const Text('선택 Pose 이동'),
          ),
          const SizedBox(height: 12),
          Text('정상 실행 순서', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(normalSequence),
          const SizedBox(height: 10),
          Text('오류 실행 순서', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(errorSequence),
        ],
      ),
    );
  }

  Widget _buildHistory() {
    return _section(
      'Run / RPF 이벤트 이력',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_runs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('저장된 Run이 없습니다.'),
            )
          else
            SizedBox(
              height: 190,
              child: ListView.separated(
                itemCount: _runs.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final run = _runs[index];
                  final id = run['id'];
                  final selected = id.toString() == _selectedRunId.toString();
                  return ListTile(
                    dense: true,
                    selected: selected,
                    title: Text(
                      'Run #$id · ${run['run_mode'] == 'error' ? '오류' : run['repeat'] == true ? '반복' : '1회'} · ${run['status'] ?? '-'}',
                    ),
                    subtitle: Text(
                      '${run['current_pose'] ?? '-'} · cycle ${run['cycle_count'] ?? 0} · ${_formatTime(run['started_at'])}',
                    ),
                    onTap: () {
                      setState(() {
                        _selectedRunId = id;
                        _events = <Map<String, dynamic>>[];
                      });
                      if (id != null) unawaited(_loadEvents(id));
                    },
                  );
                },
              ),
            ),
          const Divider(),
          Text(
            _selectedRunId == null
                ? '이벤트'
                : 'Run #$_selectedRunId 이벤트 (${_events.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          if (_events.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('R/P/F 이벤트가 없습니다.'),
            )
          else
            SizedBox(
              height: 310,
              child: ListView.separated(
                itemCount: _events.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final event = _events[index];
                  final type = event['event_type']?.toString() ?? '?';
                  final color = switch (type) {
                    'R' => DashboardTheme.primary,
                    'P' => DashboardTheme.warning,
                    'F' => DashboardTheme.success,
                    _ => Colors.grey,
                  };
                  final payload = event['payload'];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 15,
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                      child: Text(type),
                    ),
                    title: Text(event['name']?.toString() ?? '-'),
                    subtitle: Text(
                      '${_formatTime(event['created_at'])}'
                      '${payload == null || (payload is Map && payload.isEmpty) ? '' : ' · ${jsonEncode(payload)}'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  String _formatTime(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (parsed == null) return '-';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}:${two(parsed.second)}';
  }
}
