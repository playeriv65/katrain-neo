// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/cli.py: to_api.

import 'argparse.dart';

/// cli.py's ANALYSIS_TIMEOUT: default seconds the app may search before answering.
const analysisTimeout = 300;

/// One API call: the command, its arguments (null values are dropped when sending) and, for commands that wait
/// for the engine, the seconds the server may take (the client then waits 30 s longer).
class ApiCall {
  final String command;
  final Map<String, Object?> args;
  final int? timeout;
  const ApiCall(this.command, this.args, [this.timeout]);

  @override
  String toString() => 'ApiCall($command, $args, $timeout)';
}

/// Python's `x or default` for an optional int.
int orDefault(int? value, int fallback) => value == null || value == 0 ? fallback : value;

/// Maps a parsed command line to an API call. [absolute] makes a path absolute (Python's os.path.abspath) and
/// [readStdin] returns all of standard input.
ApiCall toApi(Invocation a, {required String Function(String) absolute, required String Function() readStdin}) {
  final c = a.cmd;
  final sub = a.sub;
  Map<String, Object?> viewArgs() => {
    'top': a['top'],
    'pv': a['no_pv'] != true,
    'pv_limit': a['pv_limit'],
    'ownership': a['ownership'],
    'policy': a['policy'],
  };
  String scope() => a['global_'] == true ? 'global' : 'node';
  Object? orNull(Object? list) => list is List && list.isEmpty ? null : list;

  switch (c) {
    case 'status':
      return const ApiCall('status', {});
    case 'board':
      return ApiCall('board', {'node': a['node']});
    case 'node':
      return ApiCall('node', {'node': a['ref']});
    case 'history':
      return ApiCall('history', {'node': a['node'], 'future': a['future'], 'eval': a['no_eval'] != true});
    case 'tree':
      return ApiCall('tree', {'node': a['node'], 'max_depth': a['max_depth']});
    case 'variations':
      return ApiCall('variations', {'node': a['node']});
    case 'sgf' when sub == 'export':
      final out = a['out'] as String?;
      return ApiCall('sgf.export', {
        'path': out == null || out.isEmpty ? out : absolute(out),
        'overwrite': a['overwrite'],
        'analysis': a['analysis'],
        'comments': a['comments'],
        'marks': a['marks'],
      });
    case 'sgf' when sub == 'import':
      if (a['path'] == '-') {
        return ApiCall('sgf.import', {'content': readStdin(), 'fast': a['fast'], 'at_end': a['end']});
      }
      return ApiCall('sgf.import', {'path': absolute(a['path'] as String), 'fast': a['fast'], 'at_end': a['end']});
    case 'game' when sub == 'new':
      return ApiCall('game.new', {
        'size': a['size'],
        'komi': a['komi'],
        'rules': a['rules'],
        'handicap': a['handicap'],
      });
    case 'analysis':
      switch (sub) {
        case 'get':
          return ApiCall('analysis.get', {'node': a['node'], 'moves': a['moves'], ...viewArgs()});
        case 'run':
          final t = orDefault(a.timeout, analysisTimeout);
          return ApiCall('analysis.run', {
            'node': a['node'],
            'visits': a['visits'],
            'region': a['region'],
            'max_time': a['max_time'],
            'force': a['force'],
            'wait': a['no_wait'] != true,
            'timeout': t,
            ...viewArgs(),
          }, t);
        case 'moves':
          final t = orDefault(a.timeout, analysisTimeout);
          return ApiCall('analysis.moves', {
            'node': a['node'],
            'moves': a['moves'],
            'visits': a['visits'],
            'timeout': t,
            ...viewArgs(),
          }, t);
        case 'game':
          return ApiCall('analysis.game', {
            'visits': a['visits'],
            'mistakes_only': a['mistakes_only'],
            'move_range': a['range'],
          });
        case 'wait':
          final t = orDefault(a.timeout, analysisTimeout);
          return ApiCall('analysis.wait', {'timeout': t}, t);
        case 'ponder':
          return ApiCall('analysis.ponder', {'on': a['state']});
        case 'stop':
          return const ApiCall('analysis.stop', {});
      }
    case 'engine':
      if (sub == 'get') return const ApiCall('engine.get', {});
      return ApiCall('engine.set', {
        'max_visits': a['max_visits'],
        'fast_visits': a['fast_visits'],
        'max_time': a['max_time'],
        'wide_root_noise': a['wide_root_noise'],
        'save': a['save'],
      });
    case 'goto':
      return ApiCall('nav.goto', {'node': a['ref'], 'board': a['board']});
    case 'next':
      return ApiCall('nav.next', {'n': a['n'], 'board': a['board']});
    case 'prev':
      return ApiCall('nav.prev', {'n': a['n'], 'board': a['board']});
    case 'branch':
      final which = a['which'];
      if (which == 'next' || which == 'prev') {
        return ApiCall('nav.branch', {'direction': which == 'next' ? 1 : -1, 'board': a['board']});
      }
      return ApiCall('nav.branch', {'index': which, 'board': a['board']});
    case 'play':
      return ApiCall('play', {
        'moves': a['moves'],
        'color': a['color'],
        'analyze': a['no_analyze'] != true,
        'board': a['board'],
      });
    case 'variation':
      switch (sub) {
        case 'add':
          return ApiCall('variation.add', {
            'moves': a['moves'],
            'from': a['from_'],
            'color': a['color'],
            'goto': a['goto'],
            'analyze': a['analyze'],
          });
        case 'delete':
          return ApiCall('variation.delete', {'node': a['ref'], 'force': a['force']});
        case 'promote':
          return ApiCall('variation.promote', {'node': a['ref']});
        case 'register':
          return ApiCall('variation.register', {
            'moves': a['moves'],
            'from': a['from_'],
            'color': a['color'],
            'label': a['label'],
          });
        case 'list':
          return const ApiCall('variation.list', {});
        case 'show':
          return ApiCall('variation.show', {'id': a['id'], 'as': a['as_'], 'step': a['step']});
      }
    case 'pv':
      if (sub == 'show') {
        return ApiCall('pv.show', {
          'moves': orNull(a['moves']),
          'from': a['from_'],
          'candidate': a['candidate'],
          'step': a['step'],
        });
      }
      if (sub == 'step') return ApiCall('pv.step', {'delta': a['delta'], 'index': a['index']});
      return const ApiCall('pv.hide', {});
    case 'mark':
      switch (sub) {
        case 'add':
          return ApiCall('mark.add', {
            'points': a['points'],
            'type': a['type'],
            'text': a['text'],
            'color': a['color'],
            'scope': scope(),
          });
        case 'area':
          return ApiCall('mark.area', {
            'region': a['region'],
            'text': a['text'],
            'color': a['color'],
            'scope': scope(),
          });
        case 'list':
          return const ApiCall('mark.list', {});
      }
      return ApiCall('mark.clear', {'points': orNull(a['points']), 'ids': a['ids']});
    case 'region':
      return sub == 'set' ? ApiCall('region.set', {'region': a['region']}) : const ApiCall('region.clear', {});
    case 'view':
      return ApiCall('view.set', {
        'hints': a['hints'],
        'ownership': a['ownership'],
        'policy': a['policy'],
        'eval': a['eval'],
        'children': a['children'],
        'move_numbers': a['move_numbers'],
        'zoom': a['zoom'],
        'hide_frame': a['hide_frame'],
      });
    case 'mode':
      return ApiCall('mode.set', {'mode': a['mode']});
    case 'message':
      return ApiCall('message', {'text': a['text']});
    case 'state':
      return ApiCall('state.$sub', {'name': a['name']});
    case 'demo':
      if (sub == 'start') return ApiCall('demo.start', {'label': a['label']});
      if (sub == 'end') return ApiCall('demo.end', {'keep': a['keep']});
      return const ApiCall('demo.status', {});
    case 'tsumego':
      final t = orDefault(a.timeout, analysisTimeout);
      switch (sub) {
        case 'list':
          return ApiCall('tsumego.list', {
            'source': absolute(a['source'] as String),
            'set': a['set_'],
            'difficulty': a['difficulty'],
            'limit': a['limit'],
          });
        case 'load':
          return ApiCall('tsumego.load', {
            'source': absolute(a['source'] as String),
            'index': a['index'],
            'set': a['set_'],
            'difficulty': a['difficulty'],
            'frame': a['frame'],
            'margin': a['margin'],
            'ko': a['ko'],
            'zoom': a['no_zoom'] != true,
          });
        case 'target':
          return ApiCall('tsumego.target', {'goal': a['goal'], 'group': a['group'], 'region': a['region']});
        case 'try':
          return ApiCall('tsumego.try', {
            'move': a['move'],
            'visits': a['visits'],
            'reply': a['no_reply'] != true,
            'timeout': t,
          }, t);
        case 'eval':
          return ApiCall('tsumego.eval', {'visits': a['visits'], 'timeout': t}, t);
        case 'solution':
          return ApiCall('tsumego.solution', {'show': a['show'], 'visits': a['visits'], 'timeout': t}, t);
      }
      return ApiCall('tsumego.$sub', {});
    case 'sandbox':
      switch (sub) {
        case 'new':
          return ApiCall('sandbox.new', {'from': a['from_'], 'name': a['name']});
        case 'play':
          return ApiCall('sandbox.play', {'id': a['id'], 'moves': a['moves'], 'color': a['color']});
        case 'back':
          return ApiCall('sandbox.back', {'id': a['id'], 'n': a['n']});
        case 'board':
          return ApiCall('sandbox.board', {'id': a['id']});
        case 'analyze':
          final t = orDefault(a.timeout, analysisTimeout);
          return ApiCall('sandbox.analyze', {
            'id': a['id'],
            'visits': a['visits'],
            'moves': a['moves'],
            'top': a['top'],
            'pv': a['no_pv'] != true,
            'pv_limit': a['pv_limit'],
            'ownership': a['ownership'],
            'force': a['force'],
            'timeout': t,
          }, t);
        case 'show':
          return ApiCall('sandbox.show', {'id': a['id'], 'as': a['as_'], 'step': a['step']});
        case 'drop':
          return ApiCall('sandbox.drop', {'id': a['id'], 'prune': a['prune']});
      }
      return const ApiCall('sandbox.list', {});
  }
  throw ArgumentError('unhandled command $c $sub');
}
