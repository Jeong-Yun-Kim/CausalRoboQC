import 'dart:convert';
import 'package:http/http.dart' as http;

import 'data_browser_data.dart';

final class ApiDataBrowserDataSource implements DataBrowserDataSource {
  const ApiDataBrowserDataSource(
      {this.apiBase = const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://127.0.0.1:8000',
      )});

  final String apiBase;

  Uri _uri(String path, Map<String, String> parameters) {
    final base = apiBase.replaceFirst(RegExp(r'/$'), '');
    return (base.isEmpty ? Uri.base.resolve(path) : Uri.parse('$base$path'))
        .replace(queryParameters: parameters);
  }

  @override
  Future<DataBrowserResult> load(DataBrowserFilter filter,
      {required int limit, required int offset}) async {
    final response = await http
        .get(_uri('/api/data/rpf', {
          ...filter.parameters,
          'limit': '$limit',
          'offset': '$offset',
        }))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('데이터 조회 오류: HTTP ${response.statusCode}');
    }
    return DataBrowserResult.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
  }

  @override
  Uri csvUri(DataBrowserFilter filter) =>
      _uri('/api/data/rpf.csv', filter.parameters);
}
