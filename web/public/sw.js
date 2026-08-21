const CACHE = 'hand-helper-static-v5';

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.add('/manifest.webmanifest')).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  // 课程、成绩和认证都是实时/缓存数据库数据，绝不能被 Service Worker 缓存成旧响应。
  if (event.request.method !== 'GET' || url.origin !== location.origin || url.pathname.startsWith('/api/')) return;
  // 页面和静态资源优先从网络获取；离线时才回退到已缓存的内容。
  event.respondWith(fetch(event.request).then((response) => {
    if (response.ok && (event.request.mode === 'navigate' || url.pathname.endsWith('.webmanifest'))) {
      caches.open(CACHE).then((cache) => cache.put(event.request, response.clone()));
    }
    return response;
  }).catch(() => caches.match(event.request).then((cached) => cached || caches.match('/'))));
});
