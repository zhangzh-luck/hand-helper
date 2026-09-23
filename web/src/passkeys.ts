type JsonPublicKeyCredential = Record<string, unknown>;

type PasskeyCeremony = 'create' | 'get';

function localizedWebAuthnError(error: unknown, ceremony: PasskeyCeremony) {
  const name = typeof error === 'object' && error !== null && 'name' in error && typeof error.name === 'string'
    ? error.name
    : '';
  const action = ceremony === 'create' ? '创建通行密钥' : '通行密钥验证';

  switch (name) {
    case 'NotAllowedError':
      return ceremony === 'create'
        ? '已取消创建通行密钥；若非主动取消，说明当前应用环境尚未获系统授权。'
        : '已取消通行密钥验证；若非主动取消，请使用 Safari 打开网页版登录。';
    case 'NotSupportedError':
      return '当前设备或应用环境不支持通行密钥。';
    case 'SecurityError':
      return '当前页面的安全配置不支持通行密钥，请使用 HTTPS 网页版。';
    case 'InvalidStateError':
      return ceremony === 'create'
        ? '此设备的通行密钥状态异常，请稍后重试。'
        : '通行密钥状态异常，请重新发起验证。';
    case 'AbortError':
      return `已取消${action}。`;
    default:
      return `${action}失败，请重试。`;
  }
}

function base64urlToBuffer(value: string): ArrayBuffer {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

function bufferToBase64url(value: ArrayBuffer): string {
  const bytes = new Uint8Array(value);
  let binary = '';
  bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function publicKeyFromJson(options: JsonPublicKeyCredential, ceremony: 'create' | 'get'): PublicKeyCredentialCreationOptions | PublicKeyCredentialRequestOptions {
  const publicKey = { ...options } as Record<string, unknown>;
  if (typeof publicKey.challenge !== 'string') throw new Error('服务器返回的通行密钥验证信息无效。');
  publicKey.challenge = base64urlToBuffer(publicKey.challenge);
  const credentialKey = ceremony === 'create' ? 'excludeCredentials' : 'allowCredentials';
  if (Array.isArray(publicKey[credentialKey])) {
    publicKey[credentialKey] = publicKey[credentialKey].map((item) => {
      const descriptor = { ...(item as Record<string, unknown>) };
      if (typeof descriptor.id === 'string') descriptor.id = base64urlToBuffer(descriptor.id);
      return descriptor;
    });
  }
  if (ceremony === 'create' && publicKey.user && typeof publicKey.user === 'object') {
    const user = { ...(publicKey.user as Record<string, unknown>) };
    if (typeof user.id !== 'string') throw new Error('服务器返回的通行密钥用户信息无效。');
    user.id = base64urlToBuffer(user.id);
    publicKey.user = user;
  }
  return publicKey as unknown as PublicKeyCredentialCreationOptions | PublicKeyCredentialRequestOptions;
}

function publicCredentialPayload(credential: PublicKeyCredential, response: Record<string, string | string[] | null>) {
  return {
    id: credential.id,
    rawId: bufferToBase64url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment,
    response,
    clientExtensionResults: credential.getClientExtensionResults(),
  };
}

export function passkeySupported() {
  return window.isSecureContext && typeof window.PublicKeyCredential !== 'undefined' && typeof navigator.credentials?.get === 'function';
}

export async function createPasskeyCredential(options: JsonPublicKeyCredential) {
  if (!passkeySupported()) throw new Error('当前浏览器或安全上下文不支持通行密钥。请使用 HTTPS 或 http://localhost 打开应用。');
  let credential: Credential | null;
  try {
    credential = await navigator.credentials.create({ publicKey: publicKeyFromJson(options, 'create') as PublicKeyCredentialCreationOptions });
  } catch (error) {
    throw new Error(localizedWebAuthnError(error, 'create'));
  }
  if (!(credential instanceof PublicKeyCredential) || !(credential.response instanceof AuthenticatorAttestationResponse)) throw new Error('未创建通行密钥。');
  const response = credential.response;
  return publicCredentialPayload(credential, {
    clientDataJSON: bufferToBase64url(response.clientDataJSON),
    attestationObject: bufferToBase64url(response.attestationObject),
    transports: typeof response.getTransports === 'function' ? response.getTransports() : [],
  });
}

export async function getPasskeyAssertion(options: JsonPublicKeyCredential) {
  if (!passkeySupported()) throw new Error('当前浏览器或安全上下文不支持通行密钥。请使用 HTTPS 或 http://localhost 打开应用。');
  let credential: Credential | null;
  try {
    credential = await navigator.credentials.get({ publicKey: publicKeyFromJson(options, 'get') as PublicKeyCredentialRequestOptions });
  } catch (error) {
    throw new Error(localizedWebAuthnError(error, 'get'));
  }
  if (!(credential instanceof PublicKeyCredential) || !(credential.response instanceof AuthenticatorAssertionResponse)) throw new Error('未使用通行密钥完成验证。');
  const response = credential.response;
  return publicCredentialPayload(credential, {
    clientDataJSON: bufferToBase64url(response.clientDataJSON),
    authenticatorData: bufferToBase64url(response.authenticatorData),
    signature: bufferToBase64url(response.signature),
    userHandle: response.userHandle ? bufferToBase64url(response.userHandle) : null,
  });
}
