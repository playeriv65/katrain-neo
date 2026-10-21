// The `katrain-neo` command tree: every command with its options and positionals, and the API call it sends.

import 'dart:convert';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../agent_guide.dart';
import 'command_base.dart';
import 'environment.dart';
import 'links.dart';
import 'transport.dart';

const _nodeHelp = 'node: current|root|end|<move N>|main:<N>|n<ID>';

void _node(ArgParser p, [String fallback = 'current node']) =>
    p.addOption('node', abbr: 'n', valueHelp: 'REF', help: '$_nodeHelp (default: $fallback)');

void _visits(ArgParser p, [String? help]) => p.addOption('visits', abbr: 'v', valueHelp: 'N', help: help);

void _board(ArgParser p) => p.addFlag('board', negatable: false, help: 'include the board');

void _onOff(ArgParser p, String name, [String? help]) => p.addOption(name, valueHelp: 'on|off', help: help);

/// --top, --no-pv, --pv-limit, --ownership: what an analysis result includes.
void _analysisView(ArgParser p, {bool policy = true}) {
  p
    ..addOption('top', valueHelp: 'N', help: 'number of candidate moves (default 10)')
    ..addFlag('no-pv', negatable: false, help: 'omit principal variations')
    ..addOption('pv-limit', valueHelp: 'N', help: 'truncate PVs to this many moves')
    ..addFlag('ownership', negatable: false, help: 'include the ownership grid');
  if (policy) p.addFlag('policy', negatable: false, help: 'include the top policy moves');
}

Map<String, Object?> _analysisViewArgs(Args a) => {
  'top': a.integer('top'),
  'pv': !a.flag('no-pv'),
  'pv_limit': a.integer('pv-limit'),
  'ownership': a.flag('ownership'),
  'policy': a.flag('policy'),
};

String _scope(Args a) => a.flag('global') ? 'global' : 'node';

const _markColors = 'red, blue, green, yellow, orange, purple, cyan, white, black, #rrggbb';

/// All top-level commands.
List<Command<int>> buildCommands() => [
  ..._appCommands(),
  ..._readingCommands(),
  ..._analysisCommands(),
  ..._navigationCommands(),
  ..._displayCommands(),
  _tsumegoCommands(),
  _sandboxCommands(),
];

List<Command<int>> _appCommands() => [
  CliCommand(
    'gui',
    'start KaTrain Neo in the background and wait for its API',
    params: const [Param.optional('sgf', help: 'SGF file to open')],
    options: (p) => p
      ..addOption('config', valueHelp: 'FILE', help: 'config.json to use (default: ~/.katrain-neo/config.json)')
      ..addFlag('no-wait', negatable: false, help: 'return as soon as the app is started'),
    action: (a) async {
      final response = await a.env.launch(
        config: a.string('config'),
        sgf: a.string('sgf'),
        wait: !a.flag('no-wait'),
        timeout: a.timeout ?? launchTimeout,
      );
      return a.env.report(response, compact: a.compact);
    },
  ),
  CliCommand(
    'ping',
    'check that the API is reachable',
    action: (a) async => a.env.report(
      await a.env.client.health(port: a.port, timeout: a.timeout ?? 3),
      compact: a.compact,
    ),
  ),
  CliCommand(
    'guide',
    'print the agent usage guide (markdown)',
    action: (a) async {
      a.env.out.writeln(agentGuide);
      return exitOk;
    },
  ),
  CliCommand(
    'commands',
    'list all API commands',
    action: (a) async =>
        a.env.report(await a.env.client.call('commands', null, a.port, a.timeout ?? 60), compact: a.compact),
  ),
  CliCommand(
    'call',
    'call any API command with JSON arguments',
    params: const [
      Param('command', help: 'API command, e.g. nav.goto (see "katrain-neo commands")'),
      Param.optional('json', help: 'arguments as a JSON object, e.g. \'{"node": "45"}\'', defaultsTo: '{}'),
    ],
    action: (a) async {
      final Object? args;
      try {
        args = jsonDecode(a.string('json')!);
      } on FormatException catch (e) {
        a.fail('Invalid JSON arguments: ${e.message}');
      }
      if (args is! Map<String, dynamic>) a.fail('The JSON arguments must be an object.');
      // the server may take args.timeout seconds; wait a minute longer
      final serverTimeout = switch (args['timeout']) {
        null => 0,
        final int i => i,
        final double d when d.isFinite => d.truncate(),
        final String s when int.tryParse(s.trim()) != null => int.parse(s.trim()),
        final other => a.fail('Invalid timeout in the JSON arguments: $other'),
      };
      final response = await a.env.client.call(a.string('command')!, args, a.port, a.timeout ?? serverTimeout + 60);
      return a.env.report(response, compact: a.compact);
    },
  ),
  CliCommand(
    'open',
    'follow a katrain:// link (goto / state / variation / pv / analysis)',
    params: const [Param('url', help: 'e.g. katrain://goto/45, katrain://variation/v1?step=2')],
    action: (a) async {
      Envelope badLink(String message) => {
        'ok': false,
        'error': {'code': 'bad_link', 'message': message},
      };
      Envelope response;
      try {
        final link = linkToCommand(a.string('url')!);
        response = await a.env.client.call(link.command, link.args, a.port, a.timeout ?? 60);
      } on LinkError catch (e) {
        response = badLink(e.message);
      } on NotRunning catch (e) {
        response = badLink(e.message);
      }
      return a.env.report(response, compact: a.compact);
    },
  ),
];

List<Command<int>> _readingCommands() => [
  apiCommand('status', 'game info, current node, mode, engine state', (_) => const ApiCall('status', {})),
  apiCommand(
    'board',
    'stones on the board',
    (a) => ApiCall('board', {'node': a.string('node')}),
    options: _node,
    ascii: true,
  ),
  apiCommand(
    'node',
    'details of a node',
    (a) => ApiCall('node', {'node': a.string('ref')}),
    params: const [Param.optional('ref', help: 'node reference (default: current node)')],
  ),
  apiCommand(
    'history',
    'moves from the root to a node',
    (a) => ApiCall('history', {'node': a.string('node'), 'future': a.flag('future'), 'eval': !a.flag('no-eval')}),
    options: (p) {
      _node(p);
      p
        ..addFlag('future', negatable: false, help: 'continue to the end of the line')
        ..addFlag('no-eval', negatable: false, help: 'omit per-move evaluations');
    },
  ),
  apiCommand(
    'tree',
    'game tree with all variations',
    (a) => ApiCall('tree', {'node': a.string('node'), 'max_depth': a.integer('max-depth')}),
    options: (p) {
      _node(p, 'root');
      p.addOption('max-depth', valueHelp: 'N', help: 'collapse the tree below this depth');
    },
  ),
  apiCommand(
    'variations',
    'alternatives at a node and branch points on its line',
    (a) => ApiCall('variations', {'node': a.string('node')}),
    options: _node,
  ),
  CommandGroup('sgf', 'import or export SGF', [
    apiCommand(
      'export',
      'print SGF or write it to a file',
      (a) {
        final out = a.string('out');
        return ApiCall('sgf.export', {
          'path': out == null || out.isEmpty ? out : a.env.absolute(out),
          'overwrite': a.flag('overwrite'),
          'analysis': a.flag('analysis'),
          'comments': a.flag('comments'),
          'marks': a.flag('marks'),
        });
      },
      options: (p) => p
        ..addOption(
          'out',
          abbr: 'o',
          valueHelp: 'FILE',
          help: 'file to write (refuses to overwrite without --overwrite)',
        )
        ..addFlag('overwrite', negatable: false, help: 'replace an existing file')
        ..addFlag('analysis', negatable: false, help: 'embed the analysis')
        ..addFlag('comments', negatable: false, help: 'add generated move comments')
        ..addFlag('marks', negatable: false, help: 'add best-move marks'),
    ),
    apiCommand(
      'import',
      'load an SGF file into the app (current game is backed up)',
      (a) {
        final path = a.string('path')!;
        return ApiCall('sgf.import', {
          if (path == '-') 'content': a.env.readStdin() else 'path': a.env.absolute(path),
          'fast': a.flag('fast'),
          'at_end': a.flag('end'),
        });
      },
      params: const [Param('path', help: 'SGF path, or - for standard input')],
      options: (p) => p
        ..addFlag('fast', negatable: false, help: 'quick initial analysis')
        ..addFlag('end', negatable: false, help: 'go to the last move'),
    ),
  ]),
  CommandGroup('game', 'game-level actions', [
    apiCommand(
      'new',
      'start a new game (current game is backed up)',
      (a) => ApiCall('game.new', {
        'size': a.string('size'),
        'komi': a.number('komi'),
        'rules': a.string('rules'),
        'handicap': a.integer('handicap'),
      }),
      options: (p) => p
        ..addOption('size', valueHelp: 'SIZE', help: '19, 13, 9 or WxH')
        ..addOption('komi', valueHelp: 'KOMI')
        ..addOption('rules', valueHelp: 'RULES', help: 'japanese, chinese, korean, aga, tromp-taylor, new zealand')
        ..addOption('handicap', valueHelp: 'N'),
    ),
  ]),
];

List<Command<int>> _analysisCommands() => [
  CommandGroup('analysis', 'KataGo analysis', [
    apiCommand(
      'get',
      'analysis the app already has (no new search)',
      (a) => ApiCall('analysis.get', {'node': a.string('node'), 'moves': a.list('moves'), ..._analysisViewArgs(a)}),
      options: (p) {
        _node(p);
        _analysisView(p);
        p.addMultiOption('moves', valueHelp: 'D4,Q16', help: 'only these candidate moves');
      },
    ),
    apiCommand(
      'run',
      'search a position to N visits and return the analysis',
      (a) {
        final t = a.timeout ?? analysisTimeout;
        return ApiCall('analysis.run', {
          'node': a.string('node'),
          'visits': a.integer('visits'),
          'region': a.string('region'),
          'max_time': a.number('max-time'),
          'force': a.flag('force'),
          'wait': !a.flag('no-wait'),
          'timeout': t,
          ..._analysisViewArgs(a),
        }, t);
      },
      options: (p) {
        _node(p);
        _analysisView(p);
        _visits(p, 'visits (default: engine max_visits)');
        p
          ..addOption(
            'region',
            valueHelp: 'C3:G7',
            help: "restrict candidates to a region like C3:G7, or 'gui' for the app's region",
          )
          ..addOption('max-time', valueHelp: 'SECONDS', help: 'time cap')
          ..addFlag('force', negatable: false, help: 'search even if existing analysis is deep enough')
          ..addFlag('no-wait', negatable: false, help: 'queue the search and return immediately');
      },
    ),
    apiCommand(
      'moves',
      'search specific moves and compare them',
      (a) {
        final t = a.timeout ?? analysisTimeout;
        return ApiCall('analysis.moves', {
          'node': a.string('node'),
          'moves': a.list('moves'),
          'visits': a.integer('visits'),
          'timeout': t,
          ..._analysisViewArgs(a),
        }, t);
      },
      params: const [Param.repeated('moves', help: 'moves for the player to move, e.g. D4 Q16')],
      options: (p) {
        _node(p);
        _analysisView(p);
        _visits(p);
      },
    ),
    apiCommand(
      'game',
      'queue whole-game analysis in the background',
      (a) => ApiCall('analysis.game', {
        'visits': a.integer('visits'),
        'mistakes_only': a.flag('mistakes-only'),
        'move_range': a.string('range'),
      }),
      options: (p) {
        _visits(p);
        p
          ..addFlag('mistakes-only', negatable: false, help: 'only re-analyse the mistakes')
          ..addOption('range', valueHelp: 'FROM-TO', help: 'move range like 20-60');
      },
    ),
    apiCommand('wait', 'wait until the engine is idle', (a) {
      final t = a.timeout ?? analysisTimeout;
      return ApiCall('analysis.wait', {'timeout': t}, t);
    }),
    apiCommand(
      'ponder',
      'continuous analysis on/off',
      (a) => ApiCall('analysis.ponder', {'on': a.onOff('state')}),
      params: const [Param('state', help: 'on | off')],
    ),
    apiCommand('stop', 'stop pondering and pending queries', (_) => const ApiCall('analysis.stop', {})),
  ]),
  CommandGroup('engine', 'search settings', [
    apiCommand('get', 'show settings', (_) => const ApiCall('engine.get', {})),
    apiCommand(
      'set',
      'change settings',
      (a) => ApiCall('engine.set', {
        'max_visits': a.integer('max-visits'),
        'fast_visits': a.integer('fast-visits'),
        'max_time': a.number('max-time'),
        'wide_root_noise': a.number('wide-root-noise'),
        'save': a.flag('save'),
      }),
      options: (p) => p
        ..addOption('max-visits', valueHelp: 'N')
        ..addOption('fast-visits', valueHelp: 'N')
        ..addOption('max-time', valueHelp: 'SECONDS')
        ..addOption('wide-root-noise', valueHelp: 'X')
        ..addFlag('save', negatable: false, help: 'persist to the config file'),
    ),
  ]),
];

List<Command<int>> _navigationCommands() => [
  apiCommand(
    'goto',
    'jump to a node',
    (a) => ApiCall('nav.goto', {'node': a.string('ref'), 'board': a.flag('board')}),
    params: const [Param('ref', help: '<move N> | main:<N> | n<ID> | root | end')],
    options: _board,
  ),
  for (final (name, help) in const [('next', 'step forward'), ('prev', 'step back')])
    apiCommand(
      name,
      help,
      (a) => ApiCall('nav.$name', {'n': a.integer('n'), 'board': a.flag('board')}),
      params: const [Param.optional('n', help: 'number of moves', defaultsTo: '1')],
      options: _board,
    ),
  apiCommand(
    'branch',
    'switch between sibling variations',
    (a) => switch (a.string('which')) {
      'next' => ApiCall('nav.branch', {'direction': 1, 'board': a.flag('board')}),
      'prev' => ApiCall('nav.branch', {'direction': -1, 'board': a.flag('board')}),
      final index => ApiCall('nav.branch', {'index': index, 'board': a.flag('board')}),
    },
    params: const [Param('which', help: 'next | prev | <index>')],
    options: _board,
  ),
  apiCommand(
    'play',
    'play moves from the current position (adds them to the game)',
    (a) => ApiCall('play', {
      'moves': a.list('moves'),
      'color': a.string('color'),
      'analyze': !a.flag('no-analyze'),
      'board': a.flag('board'),
    }),
    params: const [Param.repeated('moves', help: 'D4 Q16 ..., colors alternate; prefix B:/W: to force')],
    options: (p) {
      p
        ..addOption('color', valueHelp: 'B|W', help: 'color of the first move')
        ..addFlag('no-analyze', negatable: false, help: 'do not analyse the new moves');
      _board(p);
    },
  ),
  CommandGroup('variation', 'create, delete, promote, register and show variations', [
    apiCommand(
      'add',
      'add a variation below a node',
      (a) => ApiCall('variation.add', {
        'moves': a.list('moves'),
        'from': a.string('from'),
        'color': a.string('color'),
        'goto': a.flag('goto'),
        'analyze': a.string('analyze'),
      }),
      params: const [Param.repeated('moves', help: 'D4 Q16 ..., colors alternate; prefix B:/W: to force')],
      options: (p) => p
        ..addOption('from', valueHelp: 'REF', help: 'start node (default: current node)')
        ..addOption('color', valueHelp: 'B|W', help: 'color of the first move')
        ..addFlag('goto', negatable: false, help: 'jump to the end of the new variation')
        ..addOption('analyze', allowed: const ['fast', 'full', 'none'], defaultsTo: 'fast'),
    ),
    apiCommand(
      'delete',
      'delete a node and its subtree',
      (a) => ApiCall('variation.delete', {'node': a.string('ref'), 'force': a.flag('force')}),
      params: const [Param('ref', help: 'node reference')],
      options: (p) => p.addFlag('force', negatable: false, help: 'allow deleting original game nodes'),
    ),
    apiCommand(
      'promote',
      'make the line through a node the main line',
      (a) => ApiCall('variation.promote', {'node': a.string('ref')}),
      params: const [Param('ref', help: 'node reference')],
    ),
    apiCommand(
      'register',
      'register a variation and get an id (v1, v2, ...)',
      (a) => ApiCall('variation.register', {
        'moves': a.list('moves'),
        'from': a.string('from'),
        'color': a.string('color'),
        'label': a.string('label'),
      }),
      params: const [Param.repeated('moves', help: 'D4 Q16 ..., colors alternate; prefix B:/W: to force')],
      options: (p) => p
        ..addOption('from', valueHelp: 'REF', help: 'start node (default: current node)')
        ..addOption('color', valueHelp: 'B|W', help: 'color of the first move')
        ..addOption('label', valueHelp: 'TEXT'),
    ),
    apiCommand('list', 'registered variations', (_) => const ApiCall('variation.list', {})),
    apiCommand(
      'show',
      'show a registered variation',
      (a) => ApiCall('variation.show', {'id': a.string('id'), 'as': a.string('as'), 'step': a.integer('step')}),
      params: const [Param('id', help: 'v1, v2, ...')],
      options: (p) => p
        ..addOption('as', allowed: const ['pv', 'branch'], defaultsTo: 'pv')
        ..addOption('step', valueHelp: 'N', help: 'show only the first N moves'),
    ),
  ]),
];

List<Command<int>> _displayCommands() => [
  CommandGroup('pv', 'overlay a variation with numbered stones (does not change the game)', [
    apiCommand(
      'show',
      "show moves, or KataGo's PV for --candidate",
      (a) => ApiCall('pv.show', {
        'moves': a.list('moves'),
        'from': a.string('from'),
        'candidate': a.string('candidate'),
        'step': a.integer('step'),
      }),
      params: const [Param.repeated('moves', optional: true, help: 'moves to show from --from, e.g. C3 D2 C2')],
      options: (p) => p
        ..addOption('from', valueHelp: 'REF', help: 'start node (default: current node)')
        ..addOption('candidate', valueHelp: 'MOVE', help: 'use the analysed PV of this candidate move')
        ..addOption('step', valueHelp: 'N', help: 'show only the first N moves (omit to animate)'),
    ),
    apiCommand(
      'step',
      'show one more / fewer move',
      (a) => ApiCall('pv.step', {'delta': a.integer('delta'), 'index': a.integer('index')}),
      params: const [Param.optional('delta', help: 'moves to add; negative after --, e.g. -- -1', defaultsTo: '1')],
      options: (p) => p.addOption('index', valueHelp: 'N', help: 'show exactly N moves'),
    ),
    apiCommand('hide', 'remove the overlay', (_) => const ApiCall('pv.hide', {})),
  ]),
  CommandGroup('mark', 'marks and highlights on the board', [
    apiCommand(
      'add',
      'mark points',
      (a) => ApiCall('mark.add', {
        'points': a.list('points'),
        'type': a.string('type'),
        'text': a.list('text'),
        'color': a.string('color'),
        'scope': _scope(a),
      }),
      params: const [Param.repeated('points', help: 'D4 E5 ...')],
      options: (p) => p
        ..addOption(
          'type',
          abbr: 't',
          allowed: const ['circle', 'square', 'triangle', 'cross', 'label', 'dot'],
          defaultsTo: 'circle',
        )
        ..addMultiOption('text', valueHelp: 'A,B', help: 'label texts (default A, B, C...)')
        ..addOption('color', abbr: 'c', valueHelp: 'COLOR', help: _markColors)
        ..addFlag('global', negatable: false, help: 'keep showing on every move (default: this node only)'),
    ),
    apiCommand(
      'area',
      'highlight a rectangle',
      (a) => ApiCall('mark.area', {
        'region': a.string('region'),
        'text': a.string('text'),
        'color': a.string('color'),
        'scope': _scope(a),
      }),
      params: const [Param('region', help: 'e.g. C3:G7')],
      options: (p) => p
        ..addOption('text', valueHelp: 'TEXT')
        ..addOption('color', abbr: 'c', valueHelp: 'COLOR', help: _markColors)
        ..addFlag('global', negatable: false, help: 'keep showing on every move (default: this node only)'),
    ),
    apiCommand('list', 'list marks', (_) => const ApiCall('mark.list', {})),
    apiCommand(
      'clear',
      'remove marks (all, or given points / ids)',
      (a) => ApiCall('mark.clear', {'points': a.list('points'), 'ids': a.list('ids')}),
      params: const [Param.repeated('points', optional: true, help: 'only marks on these points')],
      options: (p) => p.addMultiOption('ids', valueHelp: 'ID,ID', help: 'mark ids from "mark list"'),
    ),
  ]),
  CommandGroup('region', 'KataGo region of interest', [
    apiCommand(
      'set',
      'restrict the analysis to a region',
      (a) => ApiCall('region.set', {'region': a.string('region')}),
      params: const [Param('region', help: 'e.g. C3:G7')],
    ),
    apiCommand('clear', 'analyse the whole board again', (_) => const ApiCall('region.clear', {})),
  ]),
  apiCommand(
    'view',
    'toggle display layers',
    (a) => ApiCall('view.set', {
      'hints': a.onOff('hints'),
      'ownership': a.onOff('ownership'),
      'policy': a.onOff('policy'),
      'eval': a.onOff('eval'),
      'children': a.onOff('children'),
      'move_numbers': a.onOff('move-numbers'),
      'zoom': a.string('zoom'),
      'hide_frame': a.onOff('hide-frame'),
    }),
    options: (p) {
      for (final name in const ['hints', 'ownership', 'policy', 'eval', 'children', 'move-numbers']) {
        _onOff(p, name);
      }
      p.addOption('zoom', valueHelp: 'C3:G7|auto|off', help: 'show only part of the board (auto: the tsumego problem)');
      _onOff(p, 'hide-frame', 'hide the tsumego frame stones');
    },
  ),
  apiCommand(
    'mode',
    'switch play / analyze mode',
    (a) => ApiCall('mode.set', {'mode': a.string('mode')}),
    params: const [
      Param('mode', allowed: ['play', 'analyze']),
    ],
  ),
  apiCommand(
    'message',
    'show a line in the status bar',
    (a) => ApiCall('message', {'text': a.string('text')}),
    params: const [Param('text', help: 'the line to show')],
  ),
  CommandGroup('state', 'save / restore board states', [
    for (final (name, help) in const [
      ('save', 'remember the position, mode, region, marks and overlay'),
      ('restore', 'return to a saved state'),
    ])
      apiCommand(
        name,
        help,
        (a) => ApiCall('state.$name', {'name': a.string('name')}),
        params: const [Param.optional('name', help: 'state name', defaultsTo: 'default')],
      ),
    apiCommand('list', 'saved states', (_) => const ApiCall('state.list', {})),
  ]),
  CommandGroup('demo', 'temporary demonstrations that leave the game record untouched', [
    apiCommand(
      'start',
      'snapshot the position; later additions are temporary',
      (a) => ApiCall('demo.start', {'label': a.string('label')}),
      options: (p) => p.addOption('label', valueHelp: 'TEXT'),
    ),
    apiCommand(
      'end',
      'remove demo moves and restore the snapshot',
      (a) => ApiCall('demo.end', {'keep': a.flag('keep')}),
      options: (p) => p.addFlag('keep', negatable: false, help: 'keep the moves added during the demo'),
    ),
    apiCommand('status', 'whether a demo is running', (_) => const ApiCall('demo.status', {})),
  ]),
];

Command<int> _tsumegoCommands() {
  void filters(ArgParser p) => p
    ..addOption('set', valueHelp: 'TEXT', help: 'only problems whose collection/folder contains this text')
    ..addOption('difficulty', valueHelp: 'LABEL', help: 'only problems with this difficulty label')
    ..addOption(
      'level',
      valueHelp: 'N|LO-HI',
      help: "only problems of this level in the set's index.json, e.g. 3 or 2-4",
    )
    ..addFlag('unanswered', negatable: false, help: 'also problems without an answer (they cannot be judged)');
  int engineTimeout(Args a) => a.timeout ?? analysisTimeout;

  return CommandGroup('tsumego', 'life-and-death problems', [
    apiCommand(
      'list',
      'list problems in an SGF file or folder',
      (a) => ApiCall('tsumego.list', {
        'source': a.env.absolute(a.string('source')!),
        'set': a.string('set'),
        'difficulty': a.string('difficulty'),
        'level': a.string('level'),
        if (a.flag('unanswered')) 'answered': false,
        'limit': a.integer('limit'),
      }),
      params: const [Param('source', help: 'SGF file or folder (searched recursively)')],
      options: (p) {
        filters(p);
        p.addOption('limit', valueHelp: 'N', defaultsTo: '200');
      },
    ),
    apiCommand(
      'load',
      'load a problem: frame + local search, zoomed view with the frame hidden',
      (a) => ApiCall('tsumego.load', {
        'source': a.env.absolute(a.string('source')!),
        'index': a.integer('index'),
        'set': a.string('set'),
        'difficulty': a.string('difficulty'),
        'level': a.string('level'),
        if (a.flag('unanswered')) 'answered': false,
        'frame': a.onOff('frame'),
        'margin': a.integer('margin'),
        'ko': a.flag('ko'),
        'zoom': !a.flag('no-zoom'),
      }),
      params: const [Param('source', help: 'SGF file or folder')],
      options: (p) {
        p
          ..addFlag('no-zoom', negatable: false, help: 'keep the full-board view')
          ..addOption('index', abbr: 'i', valueHelp: 'N', defaultsTo: '0', help: 'problem index from "tsumego list"');
        filters(p);
        _onOff(p, 'frame', 'a tsumego frame (default: on, off for center problems)');
        p
          ..addOption('margin', valueHelp: 'N', defaultsTo: '4')
          ..addFlag('ko', negatable: false, help: 'frame with ko threats');
      },
    ),
    apiCommand(
      'target',
      'set goal and target group',
      (a) => ApiCall('tsumego.target', {
        'goal': a.string('goal'),
        'group': a.string('group'),
        'region': a.string('region'),
      }),
      options: (p) => p
        ..addOption('goal', allowed: const ['kill', 'live'], help: 'from the perspective of the player to move')
        ..addOption('group', valueHelp: 'MOVE', help: 'a stone of the target group, e.g. C3')
        ..addOption('region', valueHelp: 'C3:G7', help: 'local search area, e.g. A1:F6'),
    ),
    apiCommand(
      'try',
      'play a move; KataGo answers locally',
      (a) => ApiCall('tsumego.try', {
        'move': a.string('move'),
        'visits': a.integer('visits'),
        'reply': !a.flag('no-reply'),
        'timeout': engineTimeout(a),
      }, engineTimeout(a)),
      params: const [Param('move', help: 'e.g. B2')],
      options: (p) {
        _visits(p);
        p.addFlag('no-reply', negatable: false, help: 'do not let KataGo answer');
      },
    ),
    apiCommand(
      'eval',
      'evaluate the current problem position',
      (a) => ApiCall('tsumego.eval', {'visits': a.integer('visits'), 'timeout': engineTimeout(a)}, engineTimeout(a)),
      options: _visits,
    ),
    apiCommand('reset', 'back to the starting position', (_) => const ApiCall('tsumego.reset', {})),
    apiCommand(
      'hint',
      "mark where the solver's move is (--level 1, an area) or the move (2): the answer's, else KataGo's",
      (a) => ApiCall('tsumego.hint', {
        'level': a.integer('level'),
        'visits': a.integer('visits'),
        'timeout': engineTimeout(a),
      }, engineTimeout(a)),
      options: (p) {
        p.addOption('level', valueHelp: '1|2', defaultsTo: '2', help: '1: a 4x4 area holding the move; 2: the move');
        _visits(p);
      },
    ),
    apiCommand(
      'solution',
      "reference solution from the SGF, or KataGo's line",
      (a) => ApiCall('tsumego.solution', {
        'show': a.flag('show'),
        'visits': a.integer('visits'),
        'timeout': engineTimeout(a),
      }, engineTimeout(a)),
      options: (p) {
        p.addFlag('show', negatable: false, help: 'overlay it on the board');
        _visits(p);
      },
    ),
    apiCommand('status', 'the current problem and attempt', (_) => const ApiCall('tsumego.status', {})),
  ]);
}

Command<int> _sandboxCommands() {
  const id = Param('id', help: 'sandbox id');
  return CommandGroup(
    'sandbox',
    "background exploration: lines and analysis are kept in the user's game, the board does not move",
    [
      apiCommand(
        'new',
        "start a background cursor at a position of the user's game",
        (a) => ApiCall('sandbox.new', {'from': a.string('from'), 'name': a.string('name')}),
        options: (p) => p
          ..addOption('from', valueHelp: 'REF', help: "node to copy (default: the user's current position)")
          ..addOption('name', valueHelp: 'ID', help: 'sandbox id (default s1, s2, ...)'),
      ),
      apiCommand(
        'play',
        'play moves at the cursor (kept as a variation, board does not move)',
        (a) => ApiCall('sandbox.play', {'id': a.string('id'), 'moves': a.list('moves'), 'color': a.string('color')}),
        params: const [
          id,
          Param.repeated('moves', help: 'D4 Q16 ..., colors alternate; prefix B:/W: to force'),
        ],
        options: (p) => p.addOption('color', valueHelp: 'B|W', help: 'color of the first move'),
      ),
      apiCommand(
        'back',
        'take back moves in a sandbox',
        (a) => ApiCall('sandbox.back', {'id': a.string('id'), 'n': a.integer('n')}),
        params: const [
          id,
          Param.optional('n', help: 'number of moves', defaultsTo: '1'),
        ],
      ),
      apiCommand(
        'board',
        'show a sandbox board',
        (a) => ApiCall('sandbox.board', {'id': a.string('id')}),
        params: const [id],
        ascii: true,
      ),
      apiCommand(
        'analyze',
        'analyze a sandbox position at low priority',
        (a) {
          final t = a.timeout ?? analysisTimeout;
          return ApiCall('sandbox.analyze', {
            'id': a.string('id'),
            'visits': a.integer('visits'),
            'moves': a.list('moves'),
            'top': a.integer('top'),
            'pv': !a.flag('no-pv'),
            'pv_limit': a.integer('pv-limit'),
            'ownership': a.flag('ownership'),
            'force': a.flag('force'),
            'timeout': t,
          }, t);
        },
        params: const [id],
        options: (p) {
          _visits(p);
          p.addMultiOption('moves', valueHelp: 'H6,H4', help: 'compare these candidate moves');
          _analysisView(p, policy: false);
          p.addFlag('force', negatable: false, help: 'search even if existing analysis is deep enough');
        },
      ),
      apiCommand(
        'show',
        "bring a sandbox line to the user's board",
        (a) => ApiCall('sandbox.show', {'id': a.string('id'), 'as': a.string('as'), 'step': a.integer('step')}),
        params: const [id],
        options: (p) => p
          ..addOption(
            'as',
            allowed: const ['pv', 'goto'],
            defaultsTo: 'pv',
            help: "pv overlay, or move the user's board there",
          )
          ..addOption('step', valueHelp: 'N', help: 'show only the first N moves'),
      ),
      apiCommand('list', 'list sandboxes', (_) => const ApiCall('sandbox.list', {})),
      apiCommand(
        'drop',
        "forget a sandbox (or 'all'); --prune also deletes the variations it added",
        (a) => ApiCall('sandbox.drop', {'id': a.string('id'), 'prune': a.flag('prune')}),
        params: const [Param('id', help: "sandbox id, or 'all'")],
        options: (p) => p.addFlag('prune', negatable: false, help: "delete the sandbox's API-created variations"),
      ),
    ],
  );
}
