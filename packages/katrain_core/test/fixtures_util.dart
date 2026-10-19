import 'dart:convert';
import 'dart:io';

/// Loads a differential fixture written by tools/fixtures/generate.py.
Map<String, dynamic> loadFixture(String name) {
  final file = File('test/fixtures/$name');
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return json['data'] as Map<String, dynamic>;
}

File fixtureInput(String name) => File('test/fixtures/inputs/$name');
