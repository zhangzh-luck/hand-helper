import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hand_helper_flutter/passkey_login.dart';
import 'package:passkeys/types.dart';

Map<String, dynamic> _options(List<Map<String, dynamic>> descriptors) => {
  'challenge': 'challenge-id',
  'rp': {'id': 'hand.zhangzh.cc', 'name': '航的助手'},
  'user': {'id': 'user-id', 'name': 'owner', 'displayName': 'owner'},
  'pubKeyCredParams': [
    {'type': 'public-key', 'alg': -7},
  ],
  'excludeCredentials': descriptors,
  'attestation': 'none',
};

Map<String, dynamic> _descriptor(String id, [Object? transports = _absent]) => {
  'id': id,
  'type': 'public-key',
  if (transports != _absent) 'transports': transports,
};

const _absent = Object();

void main() {
  test('empty excludeCredentials remains empty', () {
    final source = _options([]);
    final result = normalizePasskeyRegistrationOptions(source);
    expect(identical(result, source), isTrue);
    expect(RegisterRequestType.fromJson(result).excludeCredentials, isEmpty);
  });

  test('missing and null transports become empty lists for the plugin', () {
    for (final descriptor in [
      {'id': 'missing', 'type': 'public-key'},
      _descriptor('null', null),
    ]) {
      final source = _options([descriptor]);
      final snapshot = jsonDecode(jsonEncode(source));
      final result = normalizePasskeyRegistrationOptions(source);
      expect((result['excludeCredentials'] as List).single['transports'], []);
      expect(
        RegisterRequestType.fromJson(result)
            .excludeCredentials
            .single
            .transports,
        isEmpty,
      );
      expect(source, snapshot);
    }
  });

  test('existing empty and populated transport lists are preserved', () {
    final empty = _descriptor('empty', <String>[]);
    final populated = _descriptor('populated', ['internal', 'hybrid']);
    final source = _options([empty, populated]);
    final result = normalizePasskeyRegistrationOptions(source);
    expect(identical(result, source), isTrue);
    expect(identical((result['excludeCredentials'] as List)[0], empty), isTrue);
    expect(
      RegisterRequestType.fromJson(result).excludeCredentials.last.transports,
      ['internal', 'hybrid'],
    );
  });

  test('mixed descriptors retain IDs, fields, and original options', () {
    final source = _options([
      {'id': 'a', 'type': 'public-key'},
      _descriptor('b', null),
      _descriptor('c', <String>[]),
      _descriptor('d', ['internal']),
    ]);
    source['extensions'] = {'example': true};
    final snapshot = jsonDecode(jsonEncode(source));
    final result = normalizePasskeyRegistrationOptions(source);
    final descriptors = result['excludeCredentials'] as List;
    expect(descriptors.map((item) => item['id']), ['a', 'b', 'c', 'd']);
    expect(descriptors.map((item) => item['transports']), [
      <String>[],
      <String>[],
      <String>[],
      ['internal'],
    ]);
    expect(result['challenge'], source['challenge']);
    expect(result['rp'], source['rp']);
    expect(result['user'], source['user']);
    expect(result['extensions'], source['extensions']);
    expect(source, snapshot);
    expect(
      RegisterRequestType.fromJson(result).excludeCredentials
          .map((item) => item.id),
      ['a', 'b', 'c', 'd'],
    );
  });

  test('invalid non-null transports fail without mutating input', () {
    for (final invalid in [
      'internal',
      123,
      <Object>['internal', 123],
      <String, Object>{'value': 'internal'},
    ]) {
      final source = _options([
        _descriptor('valid', null),
        _descriptor('bad', invalid),
      ]);
      final snapshot = jsonDecode(jsonEncode(source));
      expect(
        () => normalizePasskeyRegistrationOptions(source),
        throwsA(isA<FormatException>()),
      );
      expect(source, snapshot);
    }
  });
}
