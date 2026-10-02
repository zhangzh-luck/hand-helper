import '@testing-library/jest-dom/vitest';
import { fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import App, { moveWeekInTerm } from './App';

beforeEach(() => {
  vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ success: false, error: { message: '未登录' } }), { status: 401 })));
});

describe('未登录路由', () => it('验证会话后展示登录页，不再保留展示页', async () => {
  render(<QueryClientProvider client={new QueryClient()}><MemoryRouter><App /></MemoryRouter></QueryClientProvider>);
  expect(await screen.findByRole('button', { name: '登录' })).toBeInTheDocument();
  expect(screen.getByRole('heading', { name: '航的助手' })).toBeInTheDocument();
}));

describe('底部导航', () => it('会话有效时显示四个主要页面', async () => {
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input);
    const data = url.endsWith('/api/v1/auth/me') ? { authenticated: true, username: 'admin' } : [];
    return new Response(JSON.stringify({ success: true, data }), { status: 200 });
  }));
  const { container } = render(<QueryClientProvider client={new QueryClient()}><MemoryRouter initialEntries={['/timetable']}><App /></MemoryRouter></QueryClientProvider>);
  const today = await screen.findByRole('button', { name: '今日' });
  expect(today).toBeInTheDocument();
  expect(today).not.toHaveAttribute('href');
  expect(screen.getByRole('button', { name: '课程表' })).toBeInTheDocument();
  expect(screen.getByRole('button', { name: '分析' })).toBeInTheDocument();
  expect(screen.getByRole('button', { name: '设置' })).toBeInTheDocument();
  expect(container.querySelector('.page-route-stage')).toBeInTheDocument();
}));

describe('连接恢复', () => it('验证会话断线时保留重试入口，不误跳到登录页', async () => {
  const fetchMock = vi.fn()
    .mockRejectedValueOnce(new TypeError('Failed to fetch'))
    .mockImplementation(async () => new Response(JSON.stringify({ success: true, data: { authenticated: true, username: 'admin' } }), { status: 200 }));
  vi.stubGlobal('fetch', fetchMock);
  render(<QueryClientProvider client={new QueryClient()}><MemoryRouter><App /></MemoryRouter></QueryClientProvider>);
  const retry = await screen.findByRole('button', { name: '重试连接' });
  expect(screen.queryByRole('button', { name: '登录' })).not.toBeInTheDocument();
  fireEvent.click(retry);
  expect(await screen.findByRole('button', { name: '今日' })).toBeInTheDocument();
}));

describe('首页安排摘要', () => it('自定义安排数量显示在标题和添加按钮之间', async () => {
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input);
    const data = url.endsWith('/api/v1/auth/me') ? { authenticated: true, username: 'admin' }
      : url.endsWith('/api/v1/profile') ? { display_name: '测试用户', avatar_data_url: null, timetable_background_data_url: null }
      : url.includes('/api/v1/custom-schedules') ? [{ id: 1, title: '测试安排', scheduled_date: '2026-10-02', scheduled_time: '09:00' }]
      : [];
    return new Response(JSON.stringify({ success: true, data }), { status: 200 });
  }));
  const { container } = render(<QueryClientProvider client={new QueryClient()}><MemoryRouter><App /></MemoryRouter></QueryClientProvider>);
  const summary = await screen.findByText('今天有 1 项自定义安排');
  const heading = summary.closest('.today-section-heading');
  expect(heading).toContainElement(screen.getByRole('heading', { name: '今日安排' }));
  expect(heading).toContainElement(screen.getByRole('button', { name: '添加安排' }));
  expect(container.querySelector('.today-status')).toBeNull();
}));

describe('学期周次跳转', () => it('开学前点击下一周会直接跳至开学周', () => {
  const result = moveWeekInTerm(new Date('2026-07-14T12:00:00'), 1, { id: 1, source_term_id: '2026-2027-1', display_name: '2026-2027-1', start_date: '2026-09-07', is_current: false });
  expect(result.toISOString().slice(0, 10)).toBe('2026-09-07');
}));
