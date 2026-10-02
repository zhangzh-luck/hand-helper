const CACHE = 'hand-helper-static-v6';

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // Vite 资源名带 hash，更新时要把入口及其脚本、样式作为一组缓存。
    const page = await fetch('/', { cache: 'no-store' });
    if (!page.ok) throw new Error('App shell unavailable');
    const html = await page.clone().text();
    const assets = [...html.matchAll(/(?:src|href)=["'](\/assets\/[^"']+)["']/g)].map((match) => match[1]);
    await cache.put('/', page);
    await cache.addAll(['/manifest.webmanifest', '/pwa-192.png', '/github-icons8.png', ...new Set(assets)]);
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((key) => key.startsWith('hand-helper-static-') && key !== CACHE).map((key) => caches.delete(key)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  // 课程、成绩和认证都是实时/缓存数据库数据，绝不能被 Service Worker 缓存成旧响应。
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.pathname.startsWith('/api/')) return;
  // 页面和静态资源优先从网络获取；离线时才回退到已缓存的内容。
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    try {
      const response = await fetch(event.request);
      if (response.ok && (event.request.mode === 'navigate' || url.pathname.startsWith('/assets/') || url.pathname.endsWith('.webmanifest'))) {
        await cache.put(event.request, response.clone());
      }
      return response;
    } catch {
      const cached = await cache.match(event.request);
      if (cached) return cached;
      if (event.request.mode === 'navigate') return (await cache.match('/')) || Response.error();
      // 不能把 HTML 作为离线 JS/CSS 返回，否则浏览器会报 MIME 错误。
      return Response.error();
    }
  })());
});
