// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/engine.py: KataGoEngine.RULESETS
// and KataGoEngine.get_rules.

import 'dart:convert';

/// Short and long ruleset names as KaTrain knows them.
const List<(String, String)> rulesetsAbbr = [
  ('jp', 'japanese'),
  ('cn', 'chinese'),
  ('ko', 'korean'),
  ('aga', 'aga'),
  ('tt', 'tromp-taylor'),
  ('nz', 'new zealand'),
  ('stone_scoring', 'stone_scoring'),
];

final Map<String, String> rulesets = {
  for (final (abbr, name) in rulesetsAbbr) ...{abbr: name, name: name},
};

/// The rules to use for an SGF `RU` value: a ruleset name, or a KataGo rules dictionary given as JSON.
/// Unknown names fall back to japanese, as in KaTrain.
Object getRules(String ruleset) {
  if (ruleset.trim().startsWith('{')) {
    try {
      final decoded = jsonDecode(ruleset);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // not JSON after all: treat it as a name
    }
  }
  return rulesets[ruleset.toLowerCase()] ?? 'japanese';
}
