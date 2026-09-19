import { App } from '@capacitor/app';
import { Capacitor } from '@capacitor/core';
import { Keyboard, KeyboardResize } from '@capacitor/keyboard';
import { SplashScreen } from '@capacitor/splash-screen';
import { StatusBar, Style } from '@capacitor/status-bar';

/** Optional Capacitor calls must not create unhandled WebView errors. */
async function runOptionalNativeAction(action: () => Promise<unknown>) {
  try {
    await action();
  } catch {
    // Use the WebView default when a platform-specific method is unavailable.
  }
}

function dismissOpenDialog() {
  const masks = [...document.querySelectorAll<HTMLElement>('.sheet-mask')];
  const mask = masks.at(-1);
  if (!mask) return false;
  mask.click();
  return true;
}

export async function updateNativeStatusBar(appearance: 'light' | 'dark') {
  if (!Capacitor.isNativePlatform()) return;
  const isDark = appearance === 'dark';
  await runOptionalNativeAction(() => StatusBar.setStyle({ style: isDark ? Style.Light : Style.Dark }));
  await runOptionalNativeAction(() => StatusBar.setBackgroundColor({ color: isDark ? '#000000' : '#f4f7fb' }));
}

/** Initializes Android-only behavior without changing browser/PWA behavior. */
export async function initializeNativeRuntime() {
  if (!Capacitor.isNativePlatform()) return;

  document.documentElement.classList.add('capacitor-native');
  await runOptionalNativeAction(() => StatusBar.setOverlaysWebView({ overlay: false }));
  const keyboardResizeMode = Capacitor.getPlatform() === 'ios' ? KeyboardResize.None : KeyboardResize.Body;
  await runOptionalNativeAction(() => Keyboard.setResizeMode({ mode: keyboardResizeMode }));
  await updateNativeStatusBar(document.documentElement.dataset.appearance === 'dark' ? 'dark' : 'light');

  await runOptionalNativeAction(() => App.addListener('backButton', ({ canGoBack }) => {
    if (dismissOpenDialog()) return;
    if (window.location.pathname !== '/' && canGoBack) {
      window.history.back();
      return;
    }
    if (window.confirm('要退出航的助手吗？')) void App.exitApp();
  }));

  await runOptionalNativeAction(() => SplashScreen.hide());
}
