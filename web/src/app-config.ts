import { Capacitor } from '@capacitor/core';

// 所有 API 基地址只在这里决策：Web 保持同源 /api，原生包使用 HTTPS API。
const DEFAULT_ANDROID_API_URL = 'https://hand.zhangzh.cc';

function normalizedBaseUrl(value: string | undefined) {
  return value?.trim().replace(/\/$/, '') ?? '';
}

export function apiBaseUrl() {
  const explicitUrl = normalizedBaseUrl(import.meta.env.VITE_API_URL);
  if (explicitUrl) return explicitUrl;
  if (!Capacitor.isNativePlatform()) return '';
  return normalizedBaseUrl(import.meta.env.VITE_ANDROID_API_URL) || DEFAULT_ANDROID_API_URL;
}
