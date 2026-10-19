// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/cli.py: build_parser
// (every subcommand, option, default and help text) and _accept_global_options_everywhere.

import 'argparse.dart';

const _nodeHelp = 'node: current|root|end|<move N>|main:<N>|n<ID>';

void _addNode(CommandSpec p, [String defaultHelp = 'current node']) =>
    p.option('node', abbr: 'n', help: '$_nodeHelp (default: $defaultHelp)');

void _addAnalysisView(CommandSpec p) {
  p.option('top', type: ArgType.integer, help: 'number of candidate moves (default 10)');
  p.flag('no-pv', help: 'omit principal variations');
  p.option('pv-limit', type: ArgType.integer, help: 'truncate PVs to this many moves');
  p.flag('ownership', help: 'include the ownership grid');
  p.flag('policy', help: 'include the top policy moves');
}

/// The `katrain-neo` command tree.
CommandSpec buildCommands() {
  final root = CommandSpec(
    'katrain-neo',
    description:
        'Control a running KaTrain Neo. Run without arguments to start the app. '
        'Read commands print JSON. Exit codes: 0 ok, 1 command error, 2 usage error, 3 app not running.',
  );
  root.option('port', type: ArgType.integer, help: 'API port (default: from ~/.katrain-neo/api.json)', global: true);
  root.option('timeout', type: ArgType.integer, help: 'seconds to wait for the app / engine', global: true);
  root.flag('compact', help: 'single-line JSON output', global: true);
  root.subMetavar = 'COMMAND';
  root.subRequired = false;

  var p = root.sub('gui', 'start KaTrain Neo in the background and wait for its API');
  p.arg('sgf', nargs: '?', help: 'SGF file to open');
  p.option('config', help: 'config.json to use (default: ~/.katrain-neo/config.json)');
  p.flag('no-wait');

  root.sub('ping', 'check that the API is reachable');
  root.sub('guide', 'print the agent usage guide (markdown)');
  root.sub('commands', 'list all API commands');
  p = root.sub('call', 'call any API command with JSON arguments');
  p.arg('command');
  p.arg('json_args', nargs: '?', defaultValue: '{}', help: 'e.g. \'{"node": "45"}\'');
  p = root.sub('open', 'follow a katrain:// link (goto / variation / pv / analysis)');
  p.arg('url');

  // reading
  root.sub('status', 'game info, current node, mode, engine state');
  p = root.sub('board', 'stones on the board');
  _addNode(p);
  p.flag('ascii', help: 'print only the text diagram');
  p = root.sub('node', 'details of a node');
  p.arg('ref', nargs: '?', help: 'node reference (default current)');
  p = root.sub('history', 'moves from the root to a node');
  _addNode(p);
  p.flag('future', help: 'continue to the end of the line');
  p.flag('no-eval', help: 'omit per-move evaluations');
  p = root.sub('tree', 'game tree with all variations');
  _addNode(p, 'root');
  p.option('max-depth', type: ArgType.integer);
  p = root.sub('variations', 'alternatives at a node and branch points on its line');
  _addNode(p);

  // sgf / game
  p = root.sub('sgf', 'import or export SGF');
  var q = p.sub('export', 'print SGF or write it to a file');
  q.option('out', abbr: 'o', help: 'file to write (refuses to overwrite without --overwrite)');
  q.flag('overwrite');
  q.flag('analysis', help: 'embed KaTrain analysis');
  q.flag('comments', help: 'add KaTrain move comments');
  q.flag('marks', help: 'add best-move marks');
  q = p.sub('import', 'load an SGF file into the app (current game is backed up)');
  q.arg('path', help: 'SGF path, or - for stdin');
  q.flag('fast', help: 'quick initial analysis');
  q.flag('end', help: 'go to the last move');
  p = root.sub('game', 'game-level actions');
  q = p.sub('new', 'start a new game (current game is backed up)');
  q.option('size', help: '19, 13, 9 or WxH');
  q.option('komi', type: ArgType.float);
  q.option('rules', help: 'japanese, chinese, korean, aga, tromp-taylor, new zealand');
  q.option('handicap', type: ArgType.integer);

  // analysis
  p = root.sub('analysis', 'KataGo analysis');
  q = p.sub('get', 'analysis KaTrain already has (no new search)');
  _addNode(q);
  _addAnalysisView(q);
  q.multi('moves', help: 'only these candidate moves');
  q = p.sub('run', 'search a position to N visits and return the analysis');
  _addNode(q);
  _addAnalysisView(q);
  q.option('visits', abbr: 'v', type: ArgType.integer, help: 'visits (default: engine max_visits)');
  q.option('region', help: "restrict candidates to a region like C3:G7, or 'gui' for KaTrain's region");
  q.option('max-time', type: ArgType.float, help: 'time cap in seconds');
  q.flag('force', help: 'search even if existing analysis is deep enough');
  q.flag('no-wait', help: 'queue the search and return immediately');
  q = p.sub('moves', 'search specific moves and compare them');
  q.arg('moves', nargs: '+', help: 'moves for the player to move, e.g. D4 Q16');
  _addNode(q);
  _addAnalysisView(q);
  q.option('visits', abbr: 'v', type: ArgType.integer);
  q = p.sub('game', 'queue whole-game analysis in the background');
  q.option('visits', abbr: 'v', type: ArgType.integer);
  q.flag('mistakes-only');
  q.option('range', help: 'move range like 20-60');
  p.sub('wait', 'wait until the engine is idle');
  q = p.sub('ponder', 'continuous analysis on/off');
  q.arg('state', type: ArgType.onOff);
  p.sub('stop', 'stop pondering and pending queries');

  p = root.sub('engine', 'search settings');
  p.sub('get', 'show settings');
  q = p.sub('set', 'change settings');
  q.option('max-visits', type: ArgType.integer);
  q.option('fast-visits', type: ArgType.integer);
  q.option('max-time', type: ArgType.float);
  q.option('wide-root-noise', type: ArgType.float);
  q.flag('save', help: 'persist to the config file');

  // navigation
  p = root.sub('goto', 'jump to a node');
  p.arg('ref', help: '<move N> | main:<N> | n<ID> | root | end');
  p.flag('board', help: 'include the board');
  for (final (name, help) in const [('next', 'step forward'), ('prev', 'step back')]) {
    p = root.sub(name, help);
    p.arg('n', nargs: '?', type: ArgType.integer, defaultValue: 1);
    p.flag('board');
  }
  p = root.sub('branch', 'switch between sibling variations');
  p.arg('which', help: 'next | prev | <index>');
  p.flag('board');
  p = root.sub('play', 'play moves from the current position (adds them to the game)');
  p.arg('moves', nargs: '+', help: 'D4 Q16 ..., colors alternate; prefix B:/W: to force');
  p.option('color', help: 'color of the first move');
  p.flag('no-analyze');
  p.flag('board');

  p = root.sub('variation', 'create, delete, promote, register and show variations');
  q = p.sub('add', 'add a variation below a node');
  q.arg('moves', nargs: '+');
  q.option('from', dest: 'from_', help: 'start node (default current)');
  q.option('color');
  q.flag('goto', help: 'jump to the end of the new variation');
  q.option('analyze', choices: const ['fast', 'full', 'none'], defaultValue: 'fast');
  q = p.sub('delete', 'delete a node and its subtree');
  q.arg('ref');
  q.flag('force', help: 'allow deleting original game nodes');
  q = p.sub('promote', 'make the line through a node the main line');
  q.arg('ref');
  q = p.sub('register', 'register a variation and get an id (v1, v2, ...)');
  q.arg('moves', nargs: '+');
  q.option('from', dest: 'from_');
  q.option('color');
  q.option('label');
  p.sub('list', 'registered variations');
  q = p.sub('show', 'show a registered variation');
  q.arg('id');
  q.option('as', dest: 'as_', choices: const ['pv', 'branch'], defaultValue: 'pv');
  q.option('step', type: ArgType.integer, help: 'show only the first N moves');

  // display
  p = root.sub('pv', 'overlay a variation with numbered stones (does not change the game)');
  q = p.sub('show', "show moves, or KataGo's PV for --candidate");
  q.arg('moves', nargs: '*');
  q.option('from', dest: 'from_', help: 'start node (default current)');
  q.option('candidate', help: 'use the analysed PV of this candidate move');
  q.option('step', type: ArgType.integer, help: 'show only the first N moves (omit to animate)');
  q = p.sub('step', 'show one more / fewer move');
  q.arg('delta', nargs: '?', type: ArgType.integer, defaultValue: 1);
  q.option('index', type: ArgType.integer, help: 'show exactly N moves');
  p.sub('hide', 'remove the overlay');

  p = root.sub('mark', 'marks and highlights on the board');
  q = p.sub('add', 'mark points');
  q.arg('points', nargs: '+');
  q.option(
    'type',
    abbr: 't',
    defaultValue: 'circle',
    choices: const ['circle', 'square', 'triangle', 'cross', 'label', 'dot'],
  );
  q.multi('text', help: 'label texts (default A, B, C...)');
  q.option('color', abbr: 'c', help: 'red, blue, green, yellow, orange, purple, cyan, white, black, #rrggbb');
  q.flag('global', dest: 'global_', help: 'keep showing on every move (default: this node only)');
  q = p.sub('area', 'highlight a rectangle');
  q.arg('region', help: 'C3:G7');
  q.option('text');
  q.option('color', abbr: 'c');
  q.flag('global', dest: 'global_');
  p.sub('list', 'list marks');
  q = p.sub('clear', 'remove marks (all, or given points / ids)');
  q.arg('points', nargs: '*');
  q.multi('ids');

  p = root.sub('region', 'KataGo region of interest');
  q = p.sub('set');
  q.arg('region', help: 'C3:G7');
  p.sub('clear');

  p = root.sub('view', 'toggle display layers');
  for (final name in const ['hints', 'ownership', 'policy', 'eval', 'children', 'move-numbers']) {
    p.option(name, type: ArgType.onOff, metavar: 'on|off');
  }
  p.option('zoom', metavar: 'C3:G7|auto|off', help: 'show only part of the board (auto: the tsumego problem)');
  p.option('hide-frame', type: ArgType.onOff, metavar: 'on|off', help: 'hide the tsumego frame stones');
  p = root.sub('mode', 'switch play / analyze mode');
  p.arg('mode', choices: const ['play', 'analyze']);
  p = root.sub('message', 'show a line in the status bar');
  p.arg('text');

  p = root.sub('state', 'save / restore board states');
  for (final name in const ['save', 'restore']) {
    q = p.sub(name);
    q.arg('name', nargs: '?', defaultValue: 'default');
  }
  p.sub('list');

  p = root.sub('demo', 'temporary demonstrations that leave the game record untouched');
  q = p.sub('start', 'snapshot the position; later additions are temporary');
  q.option('label');
  q = p.sub('end', 'remove demo moves and restore the snapshot');
  q.flag('keep', help: 'keep the moves added during the demo');
  p.sub('status');

  p = root.sub('tsumego', 'life-and-death problems');
  q = p.sub('list', 'list problems in an SGF file or folder');
  q.arg('source', help: 'SGF file or folder (searched recursively)');
  q.option('set', dest: 'set_', help: 'only problems whose collection/folder contains this text');
  q.option('difficulty', help: 'only problems with this difficulty label');
  q.option('limit', type: ArgType.integer, defaultValue: 200);
  q = p.sub('load', 'load a problem: frame + local search, zoomed view with the frame hidden');
  q.arg('source', help: 'SGF file or folder');
  q.flag('no-zoom', help: 'keep the full-board view');
  q.option('index', abbr: 'i', type: ArgType.integer, defaultValue: 0, help: "problem index from 'tsumego list'");
  q.option('set', dest: 'set_');
  q.option('difficulty');
  q.option(
    'frame',
    type: ArgType.onOff,
    metavar: 'on|off',
    help: "KaTrain's tsumego frame (default: on, off for center problems)",
  );
  q.option('margin', type: ArgType.integer, defaultValue: 4);
  q.flag('ko', help: 'frame with ko threats');
  q = p.sub('target', 'set goal and target group');
  q.option('goal', choices: const ['kill', 'live'], help: 'from the perspective of the player to move');
  q.option('group', help: 'a stone of the target group, e.g. C3');
  q.option('region', help: 'local search area, e.g. A1:F6');
  q = p.sub('try', 'play a move; KataGo answers locally');
  q.arg('move');
  q.option('visits', abbr: 'v', type: ArgType.integer);
  q.flag('no-reply', help: 'do not let KataGo answer');
  q = p.sub('eval', 'evaluate the current problem position');
  q.option('visits', abbr: 'v', type: ArgType.integer);
  p.sub('reset', 'back to the starting position');
  q = p.sub('solution', "reference solution from the SGF, or KataGo's line");
  q.flag('show', help: 'overlay it on the board');
  q.option('visits', abbr: 'v', type: ArgType.integer);
  p.sub('status');

  p = root.sub(
    'sandbox',
    "background exploration: lines and analysis are kept in the user's game, the board does not move",
  );
  q = p.sub('new', "start a background cursor at a position of the user's game");
  q.option('from', dest: 'from_', help: "node to copy (default: the user's current position)");
  q.option('name', help: 'sandbox id (default s1, s2, ...)');
  q = p.sub('play', 'play moves at the cursor (kept as a variation, board does not move)');
  q.arg('id');
  q.arg('moves', nargs: '+');
  q.option('color', help: 'color of the first move');
  q = p.sub('back', 'take back moves in a sandbox');
  q.arg('id');
  q.arg('n', nargs: '?', type: ArgType.integer, defaultValue: 1);
  q = p.sub('board', 'show a sandbox board');
  q.arg('id');
  q.flag('ascii', help: 'print only the text diagram');
  q = p.sub('analyze', 'analyze a sandbox position at low priority');
  q.arg('id');
  q.option('visits', abbr: 'v', type: ArgType.integer);
  q.multi('moves', help: 'compare these candidate moves');
  q.option('top', type: ArgType.integer);
  q.flag('no-pv');
  q.option('pv-limit', type: ArgType.integer);
  q.flag('ownership');
  q.flag('force');
  q = p.sub('show', "bring a sandbox line to the user's board");
  q.arg('id');
  q.option(
    'as',
    dest: 'as_',
    choices: const ['pv', 'goto'],
    defaultValue: 'pv',
    help: "pv overlay, or move the user's board there",
  );
  q.option('step', type: ArgType.integer, help: 'show only the first N moves');
  p.sub('list', 'list sandboxes');
  q = p.sub('drop', "forget a sandbox (or 'all'); --prune also deletes the variations it added");
  q.arg('id');
  q.flag('prune', help: "delete the sandbox's API-created variations");

  _acceptGlobalOptionsEverywhere(root);
  return root;
}

/// Lets --port/--timeout/--compact also appear after the subcommand (agents put them anywhere).
void _acceptGlobalOptionsEverywhere(CommandSpec parser) {
  for (final child in parser.subcommands.values) {
    child.option('port', type: ArgType.integer, hidden: true, global: true);
    child.option('timeout', type: ArgType.integer, hidden: true, global: true);
    child.flag('compact', hidden: true, global: true);
    _acceptGlobalOptionsEverywhere(child);
  }
}
