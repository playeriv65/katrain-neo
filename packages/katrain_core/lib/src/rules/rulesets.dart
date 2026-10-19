// Ruleset names and the rules KataGo is given for an SGF `RU` value.

import 'dart:convert';

/// Short and long ruleset names.
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
/// Unknown names fall back to japanese.
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
