import { defineConfig } from 'vite'; import react from '@vitejs/plugin-react';
export default defineConfig({
  plugins:[react()],
  // 本地开发时将同源 API 请求转发到当前后端实例，避免浏览器跨域。
  // 局域网 iPhone 调试时不缓存开发资源，避免 Safari 继续使用旧 CSS。
  server:{ host:'0.0.0.0', port:5173, headers:{ 'Cache-Control':'no-store, max-age=0' }, proxy:{ '/api':{ target:'http://127.0.0.1:8000', changeOrigin:true } } },
  build:{outDir:'dist'}, test:{environment:'jsdom',globals:true},
});
