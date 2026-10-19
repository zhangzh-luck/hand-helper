import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

class PasskeyLoginCancelled implements Exception {
  const PasskeyLoginCancelled();
}

class PasskeyLoginFailure implements Exception {
  const PasskeyLoginFailure(this.message);
  final String message;
}

class PasskeyRegistrationCancelled implements Exception {
  const PasskeyRegistrationCancelled();
}

class PasskeyRegistrationFailure implements Exception {
  const PasskeyRegistrationFailure(this.message);
  final String message;
}

/// The server may omit optional descriptor transports, while the passkeys
/// plugin requires a list. Do not alter any other WebAuthn registration data.
Map<String, dynamic> normalizePasskeyRegistrationOptions(
  Map<String, dynamic> publicKey,
) {
  final descriptors = publicKey['excludeCredentials'];
  if (descriptors == null) return publicKey;
  if (descriptors is! List) {
    throw const FormatException('Invalid excludeCredentials');
  }

  var changed = false;
  final normalized = <dynamic>[];
  for (final descriptor in descriptors) {
    if (descriptor is! Map<String, dynamic>) {
      throw const FormatException('Invalid excludeCredentials entry');
    }
    final transports = descriptor['transports'];
    if (transports == null) {
      normalized.add({...descriptor, 'transports': <String>[]});
      changed = true;
    } else if (transports is List &&
        transports.every((value) => value is String)) {
      normalized.add(descriptor);
    } else {
      throw const FormatException('Invalid excludeCredentials transports');
    }
  }
  return changed ? {...publicKey, 'excludeCredentials': normalized} : publicKey;
}

/// The authenticator handles the native Credential Manager ceremony. Keep the
/// server's challenge and the returned WebAuthn fields unchanged.
Future<Map<String, dynamic>> requestPasskeyAssertion(
  Map<String, dynamic> publicKey,
) async {
  try {
    final request = AuthenticateRequestType.fromJson(
      publicKey,
      preferImmediatelyAvailableCredentials: false,
    );
    final assertion = await PasskeyAuthenticator().authenticate(request);
    return assertion.toJson();
  } on PasskeyAuthCancelledException {
    throw const PasskeyLoginCancelled();
  } on NoCredentialsAvailableException {
    throw const PasskeyLoginFailure('这台设备没有可用的通行密钥，请使用账号密码登录。');
  } on DomainNotAssociatedException {
    throw const PasskeyLoginFailure('应用尚未与登录网站完成安全关联，请使用账号密码登录。');
  } on DeviceNotSupportedException {
    throw const PasskeyLoginFailure('当前设备不支持通行密钥，请使用账号密码登录。');
  } on PasskeyUnsupportedException {
    throw const PasskeyLoginFailure('当前 Android 版本不支持通行密钥，请使用账号密码登录。');
  } on AuthenticatorException {
    throw const PasskeyLoginFailure('通行密钥验证未完成，请重试或使用账号密码登录。');
  }
}

/// Uses the same server-provided creation options and WebAuthn response fields
/// as the web client. Android Credential Manager owns biometric/PIN approval.
Future<Map<String, dynamic>> requestPasskeyRegistration(
  Map<String, dynamic> publicKey,
) async {
  try {
    final request = RegisterRequestType.fromJson(
      normalizePasskeyRegistrationOptions(publicKey),
    );
    final credential = await PasskeyAuthenticator().register(request);
    return credential.toJson();
  } on PasskeyAuthCancelledException {
    throw const PasskeyRegistrationCancelled();
  } on ExcludeCredentialsCanNotBeRegisteredException {
    throw const PasskeyRegistrationFailure('此设备已注册该通行密钥，请勿重复添加。');
  } on DomainNotAssociatedException {
    throw const PasskeyRegistrationFailure('应用尚未与登录网站完成安全关联，暂时无法添加通行密钥。');
  } on DeviceNotSupportedException {
    throw const PasskeyRegistrationFailure('当前设备不支持通行密钥。');
  } on PasskeyUnsupportedException {
    throw const PasskeyRegistrationFailure('当前 Android 版本不支持通行密钥。');
  } on MissingGoogleSignInException {
    throw const PasskeyRegistrationFailure('请先在设备上登录支持通行密钥的账号。');
  } on SyncAccountNotAvailableException {
    throw const PasskeyRegistrationFailure('当前设备的通行密钥账号不可用，请检查系统账号设置。');
  } on NoCreateOptionException {
    throw const PasskeyRegistrationFailure('没有可用的通行密钥提供程序，请检查设备设置。');
  } on TimeoutException {
    throw const PasskeyRegistrationFailure('设备验证超时，请重试。');
  } on AuthenticatorException {
    throw const PasskeyRegistrationFailure('通行密钥创建未完成，请重试。');
  } on FormatException {
    throw const PasskeyRegistrationFailure('服务器返回的通行密钥参数无效。');
  }
}
