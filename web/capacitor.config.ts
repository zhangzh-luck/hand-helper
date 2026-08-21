import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.zhangzh.hangassistant',
  appName: '航的助手',
  webDir: 'dist',
  bundledWebRuntime: false,
  server: {
    // 资源仅从 APK 的 dist 目录加载；绝不使用 server.url 远程套壳。
    androidScheme: 'https',
    cleartext: false,
  },
  plugins: {
    SplashScreen: {
      launchAutoHide: false,
      backgroundColor: '#F4F7FB',
      showSpinner: false,
    },
    StatusBar: {
      overlaysWebView: false,
    },
  },
};

export default config;
