// katrain:// links (`katrain-neo open`, and the links the API returns, e.g. from `state save`): the host names the
// action, the path or the query names its target.

import 'transport.dart';

/// A link that cannot be followed.
class LinkError implements Exception {
  final String message;
  LinkError(this.message);

  @override
  String toString() => message;
}

/// Maps a link to an API call: `katrain://state/<name>`, `katrain://goto/45`, `katrain://goto?node=n12`,
/// `katrain://variation/v3?step=2&as=branch`, `katrain://pv?from=45&moves=D4,Q16&step=1`,
/// `katrain://analysis?node=45`. Query parameters without a value are ignored; a repeated one keeps its last value.
ApiCall linkToCommand(String url) {
  final Uri uri;
  final String? target;
  final Map<String, String> q;
  try {
    uri = Uri.parse(url.trim());
    final path = uri.path.replaceAll(RegExp(r'^/+|/+$'), '');
    target = path.isEmpty ? null : Uri.decodeComponent(path);
    q = {
      for (final MapEntry(:key, :value) in uri.queryParametersAll.entries)
        key: ?value.where((v) => v.isNotEmpty).lastOrNull,
    };
  } on FormatException catch (e) {
    throw LinkError('invalid link: ${e.message}');
  }
  if (uri.scheme != 'katrain' || !uri.hasAuthority) throw LinkError('links must start with katrain://');
  switch (uri.host) {
    case 'goto':
      return ApiCall('nav.goto', {'node': target ?? q['node']});
    case 'state':
      return ApiCall('state.restore', {'name': target ?? q['name'] ?? ''});
    case 'variation':
      return ApiCall('variation.show', {'id': target ?? q['id'], 'step': q['step'], 'as': q['as']});
    case 'pv':
      return ApiCall('pv.show', {
        'from': q['from'],
        'moves': q['moves'],
        'candidate': q['candidate'],
        'step': q['step'],
      });
    case 'analysis':
      return ApiCall('analysis.get', {'node': target ?? q['node']});
  }
  throw LinkError("unknown link action '${uri.host}'");
}
