// 默认同源访问：本地由 Vite 代理 /api，生产由 Nginx 代理 /api，避免浏览器跨域问题。
import { apiBaseUrl } from './app-config';

const API = apiBaseUrl();
type Envelope<T> = { success: boolean; data: T; error?: { code: string; message: string } };

async function readEnvelope<T>(response: Response, fallbackMessage: string): Promise<Envelope<T>> {
  const body = await response.text();
  if (!body.trim()) throw new Error(`服务器未返回数据（HTTP ${response.status}），请确认后端服务正在运行。`);
  try {
    return JSON.parse(body) as Envelope<T>;
  } catch {
    throw new Error(response.ok ? '服务器返回的数据格式异常，请稍后重试。' : `${fallbackMessage}（HTTP ${response.status}）。`);
  }
}

function notifyUnauthenticated() {
  window.dispatchEvent(new Event('hand-helper:unauthenticated'));
}

export async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  let response: Response;
  try {
    const headers = new Headers(options.headers);
    if (!headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
    response = await fetch(`${API}${path}`, {
      credentials: 'include',
      ...options,
      headers,
    });
  } catch {
    throw new Error('无法连接服务器，请检查网络，随后刷新页面再试。');
  }
  const payload = await readEnvelope<T>(response, '服务器响应异常');
  if (response.status === 401) notifyUnauthenticated();
  if (!response.ok || !payload.success) throw new Error(payload.error?.message ?? '请求失败');
  return payload.data;
}
export async function upload<T>(path: string, file: File, fields: Record<string, string> = {}): Promise<T> {
  const form = new FormData();
  Object.entries(fields).forEach(([key, value]) => form.append(key, value));
  form.append('file', file);
  let response: Response;
  try {
    response = await fetch(`${API}${path}`, {
      method: 'POST', body: form, credentials: 'include',
    });
  } catch {
    throw new Error('无法连接服务器，请检查网络，随后刷新页面再试。');
  }
  const payload = await readEnvelope<T>(response, '上传服务响应异常');
  if (response.status === 401) notifyUnauthenticated();
  if (!response.ok || !payload.success) throw new Error(payload.error?.message ?? '上传失败');
  return payload.data;
}
const termQuery = (termId?: number) => termId ? `?term_id=${termId}` : '';
export const api = {
  login: (username: string, password: string) => request<AuthMe>('/api/v1/auth/login', { method: 'POST', body: JSON.stringify({ username, password }) }),
  logout: () => request<{ logged_out: boolean }>('/api/v1/auth/logout', { method: 'POST' }),
  me: () => request<AuthMe>('/api/v1/auth/me'),
  profile: () => request<Profile>('/api/v1/profile'),
  updateProfile: (profile: ProfileUpdate) => request<Profile>('/api/v1/profile', { method: 'PUT', body: JSON.stringify(profile) }),
  terms: () => request<Term[]>('/api/v1/terms'),
  updateTermStartDate: (termId: number, startDate: string) => request<{ sessions_generated: number }>(`/api/v1/terms/${termId}/start-date`, { method: 'PUT', body: JSON.stringify({ start_date: startDate }) }),
  periodTimes: () => request<PeriodTime[]>('/api/v1/settings/period-times'),
  updatePeriodTime: (periodNumber: number, startTime: string, endTime: string) => request<{ sessions_generated: number }>(`/api/v1/settings/period-times/${periodNumber}`, { method: 'PUT', body: JSON.stringify({ start_time: startTime, end_time: endTime }) }),
  importTimetableFile: (file: File) => upload<{ term_id: string; courses_imported: number; sessions_generated: number; ignored_notes: boolean }>('/api/v1/timetable/import-file', file),
  sessions: (termId?: number) => request<Session[]>(`/api/v1/timetable${termQuery(termId)}`),
  manualCourses: (termId?: number) => request<ManualCourse[]>(`/api/v1/manual-courses${termQuery(termId)}`),
  createManualCourse: (payload: ManualCourseInput) => request<ManualCourse>('/api/v1/manual-courses', { method: 'POST', body: JSON.stringify(payload) }),
  updateManualCourse: (courseId: number, payload: ManualCourseInput) => request<ManualCourse>(`/api/v1/manual-courses/${courseId}`, { method: 'PATCH', body: JSON.stringify(payload) }),
  deleteManualCourse: (courseId: number) => request<{ deleted: boolean }>(`/api/v1/manual-courses/${courseId}`, { method: 'DELETE' }),
  customSchedules: (date?: string) => request<CustomSchedule[]>(`/api/v1/custom-schedules${date ? `?scheduled_date=${encodeURIComponent(date)}` : ''}`),
  createCustomSchedule: (payload: CustomScheduleInput) => request<CustomSchedule>('/api/v1/custom-schedules', { method: 'POST', body: JSON.stringify(payload) }),
  updateCustomSchedule: (scheduleId: number, payload: CustomScheduleInput) => request<CustomSchedule>(`/api/v1/custom-schedules/${scheduleId}`, { method: 'PATCH', body: JSON.stringify(payload) }),
  deleteCustomSchedule: (scheduleId: number) => request<{ deleted: boolean }>(`/api/v1/custom-schedules/${scheduleId}`, { method: 'DELETE' }),
  previewGradesFile: (file: File, termId?: string) => upload<GradeImportPreview>(`/api/v1/grades/import-file${termId ? `?term_id=${encodeURIComponent(termId)}` : ''}`, file),
  confirmGradesImport: (payload: GradeImportConfirmInput) => request<{ term_id: number; source_term_id: string; grades_imported: number }>('/api/v1/grades/import-confirm', { method: 'POST', body: JSON.stringify(payload) }),
  grades: (termId?: number) => request<Grade[]>(`/api/v1/grades${termQuery(termId)}`),
  summary: (termId?: number) => request<Summary>(`/api/v1/grades/summary${termQuery(termId)}`),
  aiSettings: () => request<AiProviderSetting>('/api/v1/ai/settings'),
  updateAiSettings: (payload: AiProviderSettingInput) => request<AiProviderSetting>('/api/v1/ai/settings', { method: 'PUT', body: JSON.stringify(payload) }),
  lookupAiModels: (payload: AiModelLookupInput) => request<AiModelList>('/api/v1/ai/settings/models', { method: 'POST', body: JSON.stringify(payload) }),
  refreshAiModels: () => request<AiProviderSetting>('/api/v1/ai/settings/models/refresh', { method: 'POST' }),
  selectAiModel: (model: string) => request<AiProviderSetting>('/api/v1/ai/settings/model', { method: 'PATCH', body: JSON.stringify({ model }) }),
  testAiSettings: (payload: AiProviderSettingInput) => request<AiConnectionTest>('/api/v1/ai/settings/test', { method: 'POST', body: JSON.stringify(payload) }),
  clearAiSettings: () => request<{ deleted: boolean }>('/api/v1/ai/settings', { method: 'DELETE' }),
  analyzeGrades: (termId: number, forceRefresh = false) => request<GradeAiAnalysis>(`/api/v1/grades/ai-analysis?term_id=${termId}${forceRefresh ? '&force_refresh=true' : ''}`, { method: 'POST' }),
  gradeAiAnalyses: (termId?: number) => request<GradeAiAnalysisHistory[]>(`/api/v1/grades/ai-analyses${termQuery(termId)}`),
  clearGradeAiAnalyses: () => request<{ deleted: number }>('/api/v1/grades/ai-analyses', { method: 'DELETE' }),
};
export type AuthMe = { authenticated: true; username: string };
export type Profile = { display_name: string; avatar_data_url: string | null };
export type ProfileUpdate = { display_name: string; avatar_data_url?: string | null };
export type Term = { id: number; source_term_id: string; display_name: string; start_date: string | null; is_current: boolean };
export type PeriodTime = { period_number: number; start_time: string; end_time: string };
export type Session = { id: number; course_name: string; course_code: string; session_date: string; start_datetime: string; end_datetime: string; classroom: string | null; teacher: string | null; week_expression: string | null; status: string; source?: 'IMPORTED' | 'MANUAL'; manual_course_id?: number | null; term_id?: number | null; weekday?: number | null; start_period?: number | null; end_period?: number | null };
export type ManualCourseInput = { term_id: number; course_name: string; teacher?: string | null; classroom?: string | null; weekday: number; start_period: number; end_period: number; week_expression: string };
export type ManualCourse = ManualCourseInput & { id: number; created_at: string; updated_at: string };
export type CustomScheduleInput = { title: string; scheduled_date: string; scheduled_time: string };
export type CustomSchedule = CustomScheduleInput & { id: number; created_at: string; updated_at: string };
export type Grade = { id: number; term_id: number; course_code: string; course_name: string; course_type: string | null; credits: number | null; score: string | null; final_exam_score: string | null; usual_score: string | null; grade_point: number | null; weighted_grade_point: number | null; exam_type: string | null; makeup_flag: boolean; retake_flag: boolean };
export type GradeImportItem = { source_grade_id: string; course_code: string; course_name: string; course_type: string | null; credits: number | null; score: string | null; final_exam_score: string | null; usual_score: string | null; grade_point: number | null; weighted_grade_point: number | null; exam_type: string | null; makeup_flag: boolean; retake_flag: boolean };
export type GradeImportPreview = { source_term_id: string; grades: GradeImportItem[] };
export type GradeImportConfirmInput = GradeImportPreview;
export type Summary = { total_courses: number; total_credits: number; earned_credits: number; failed_courses: number; average_score: number | null; gpa: number | null; gpa_note?: string };
export type AiProviderSetting = { configured: boolean; provider: string | null; base_url: string | null; model: string | null; api_key_hint: string | null; available_models: string[]; models_synced_at: string | null; is_enabled: boolean };
export type AiProviderSettingInput = { provider: string; base_url: string; model: string; api_key: string };
export type AiModelLookupInput = { provider: string; base_url: string; api_key: string };
export type AiModelList = { models: string[] };
export type AiConnectionTest = { message: string; provider: string; model: string };
export type GradeAiAnalysis = { term_id: number; content: string; provider: string; model: string; created_at: string; cached: boolean };
export type GradeAiAnalysisHistory = { id: number; term_id: number; content: string; provider: string; model: string; created_at: string };
