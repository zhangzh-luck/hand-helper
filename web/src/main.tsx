import React from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import App from './App';
import { initializeNativeRuntime } from './native-runtime';
import './styles.css';
import './layout-fix.css';

createRoot(document.getElementById('root')!).render(
  <React.StrictMode><QueryClientProvider client={new QueryClient()}><BrowserRouter><App /></BrowserRouter></QueryClientProvider></React.StrictMode>,
);

if ('serviceWorker' in navigator) window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js'));

void initializeNativeRuntime();
