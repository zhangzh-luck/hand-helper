import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { describe, expect, it } from 'vitest';
import App, { moveWeekInTerm } from './App';

describe('未登录路由', () => it('直接展示登录页，不再保留展示页', () => {
  localStorage.clear();
  render(<QueryClientProvider client={new QueryClient()}><MemoryRouter><App /></MemoryRouter></QueryClientProvider>);
  expect(screen.getByRole('heading', { name: '航的助手' })).toBeInTheDocument();
  expect(screen.getByRole('button', { name: '登录' })).toBeInTheDocument();
}));

describe('底部导航', () => it('显示四个主要页面', () => {
  localStorage.setItem('access_token', 'test');
  const { container } = render(<QueryClientProvider client={new QueryClient()}><MemoryRouter initialEntries={['/timetable']}><App /></MemoryRouter></QueryClientProvider>);
  expect(screen.getByRole('link', { name: '今日' })).toBeInTheDocument();
  expect(screen.getByRole('link', { name: '课程表' })).toBeInTheDocument();
  expect(screen.getByRole('link', { name: '分析' })).toBeInTheDocument();
  expect(screen.getByRole('link', { name: '设置' })).toBeInTheDocument();
  expect(container.querySelector('.page-route-stage-forward')).toBeInTheDocument();
}));

describe('学期周次跳转', () => it('开学前点击下一周会直接跳至开学周', () => {
  const result = moveWeekInTerm(new Date('2026-07-14T12:00:00'), 1, { id: 1, source_term_id: '2026-2027-1', display_name: '2026-2027-1', start_date: '2026-09-07', is_current: false });
  expect(result.toISOString().slice(0, 10)).toBe('2026-09-07');
}));
