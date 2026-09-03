import { useEffect, useRef, useState, type CSSProperties, type RefObject } from 'react';
import { createPortal } from 'react-dom';
import ReactMarkdown from 'react-markdown';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Capacitor } from '@capacitor/core';
import DatePicker, { registerLocale } from 'react-datepicker';
import { zhCN } from 'date-fns/locale';
import 'react-datepicker/dist/react-datepicker.css';
import { CalendarDays, ChevronLeft, ChevronRight, Clock3, Database, GraduationCap, Home, Info, KeyRound, Monitor, Moon, Palette, Pencil, Plus, Settings as SettingsIcon, Sun, Trash2, Upload, X } from 'lucide-react';
import { Navigate, NavLink, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { api, AiProviderSettingInput, CustomSchedule, CustomScheduleInput, Grade, GradeAiAnalysis, GradeAiAnalysisHistory, GradeImportPreview, ManualCourseInput, PeriodTime, Profile, ProfileUpdate, Session, Term } from './api';
import { updateNativeStatusBar } from './native-runtime';

const formatTime = (value: string) => new Date(value).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
const DEFAULT_PERIOD_VALUES: Array<[number, string, string]> = [[1, '08:30', '09:15'], [2, '09:20', '10:05'], [3, '10:25', '11:10'], [4, '11:15', '12:00'], [5, '13:40', '14:25'], [6, '14:30', '15:15'], [7, '15:30', '16:15'], [8, '16:30', '17:15'], [9, '17:20', '18:05'], [10, '18:20', '19:05'], [11, '19:10', '19:55'], [12, '20:00', '20:45'], [13, '20:50', '21:35']];
const DEFAULT_PERIODS: PeriodTime[] = DEFAULT_PERIOD_VALUES.map(([period_number, start_time, end_time]) => ({ period_number, start_time, end_time }));
const APP_VERSION = import.meta.env.VITE_APP_VERSION ?? '0.1.0';
type AppearanceMode = 'light' | 'dark' | 'system';
const WEEKDAY_LABELS = ['一', '二', '三', '四', '五', '六', '日'];
registerLocale('zh-CN', zhCN);
const localDateKey = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
const dateFromKey = (value: string) => new Date(`${value}T12:00:00`);
function mondayOf(date: Date) { const result = new Date(date); result.setHours(12, 0, 0, 0); result.setDate(result.getDate() - ((result.getDay() + 6) % 7)); return result; }
function addDays(date: Date, days: number) { const result = new Date(date); result.setDate(result.getDate() + days); return result; }
function currentAcademicTermId() { const now = new Date(); return now.getMonth() >= 8 ? `${now.getFullYear()}-${now.getFullYear() + 1}-1` : `${now.getFullYear() - 1}-${now.getFullYear()}-2`; }
export function moveWeekInTerm(anchor: Date, direction: -1 | 1, term: Term | undefined) {
  const termStart = term?.start_date ? mondayOf(dateFromKey(term.start_date)) : null;
  const currentWeekStart = mondayOf(anchor);
  // 例如暑假中的 7 月查看 9 月开学的学期：第一次“下一周”直接落在开学周，之后才逐周移动。
  if (direction === 1 && termStart && currentWeekStart < termStart) return termStart;
  return addDays(anchor, direction * 7);
}

function useCollapsiblePageTitle() {
  const scrollRef = useRef<HTMLElement>(null);
  const [collapseProgress, setCollapseProgress] = useState(0);
  useEffect(() => {
    const container = scrollRef.current;
    if (!container) return;
    let frame: number | null = null;
    const update = () => {
      frame = null;
      // 顶部留出一个小的归零区，避免移动端回弹时留下半透明标题残影。
      const next = container.scrollTop < 8 ? 0 : Math.min(1, Math.max(0, container.scrollTop / 72));
      setCollapseProgress(next);
    };
    const onScroll = () => {
      if (frame === null) frame = requestAnimationFrame(update);
    };
    update();
    container.addEventListener('scroll', onScroll, { passive: true });
    return () => {
      container.removeEventListener('scroll', onScroll);
      if (frame !== null) cancelAnimationFrame(frame);
    };
  }, []);
  const compactTitleProgress = Math.max(0, (collapseProgress - 0.34) / 0.66);
  const headerSurfaceProgress = Math.max(0, (collapseProgress - 0.12) / 0.88);
  const sideControlsHidden = collapseProgress >= 0.55;
  const headerStyle = {
    '--timetable-header-height': `${60 - collapseProgress * 12}px`,
    '--timetable-large-title-opacity': String(Math.max(0, 1 - collapseProgress / 0.68)),
    '--timetable-large-title-scale': String(1 - collapseProgress * 0.07),
    '--timetable-large-title-y': `${collapseProgress * -6}px`,
    '--timetable-compact-title-opacity': String(compactTitleProgress),
    '--timetable-compact-title-scale': String(0.86 + compactTitleProgress * 0.14),
    '--timetable-compact-title-y': `${(1 - compactTitleProgress) * 5}px`,
    '--timetable-action-scale': String(1 - collapseProgress * 0.1),
    '--timetable-action-y': `${collapseProgress * -3}px`,
    // 设置二级页的固定返回按钮与折叠后的标题胶囊共用同一条基线。
    '--timetable-persistent-action-y': '0px',
    '--timetable-side-control-opacity': String(Math.max(0, 1 - collapseProgress / 0.45)),
    '--timetable-side-control-y': `${collapseProgress * -18}px`,
    '--timetable-header-surface-opacity': String(headerSurfaceProgress * 0.92),
    '--timetable-header-shadow-opacity': String(headerSurfaceProgress * 0.07),
    '--timetable-header-blur': `${headerSurfaceProgress * 14}px`,
  } as CSSProperties;
  return { scrollRef, headerStyle, sideControlsHidden };
}

function savedAppearanceMode(): AppearanceMode {
  const stored = window.localStorage.getItem('appearance_mode');
  return stored === 'light' || stored === 'dark' || stored === 'system' ? stored : 'system';
}

function useResolvedAppearanceMode(mode: AppearanceMode): 'light' | 'dark' {
  const [systemDark, setSystemDark] = useState(() => window.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false);
  useEffect(() => {
    const mediaQuery = window.matchMedia?.('(prefers-color-scheme: dark)');
    if (!mediaQuery) return;
    const update = () => setSystemDark(mediaQuery.matches);
    update();
    mediaQuery.addEventListener('change', update);
    return () => mediaQuery.removeEventListener('change', update);
  }, []);
  return mode === 'system' ? (systemDark ? 'dark' : 'light') : mode;
}

function Today({ appearance }: { appearance: 'light' | 'dark' }) {
  const queryClient = useQueryClient();
  const { data = [], isLoading, error } = useQuery({ queryKey: ['sessions'], queryFn: () => api.sessions() });
  const profile = useQuery({ queryKey: ['profile'], queryFn: api.profile });
  const now = new Date();
  const today = localDateKey(now);
  const customSchedules = useQuery({ queryKey: ['custom-schedules', today], queryFn: () => api.customSchedules(today) });
  const [editingSchedule, setEditingSchedule] = useState<CustomSchedule | 'new' | null>(null);
  const [avatarPreviewOpen, setAvatarPreviewOpen] = useState(false);
  const saveSchedule = useMutation({
    mutationFn: (payload: CustomScheduleInput) => editingSchedule === 'new' ? api.createCustomSchedule(payload) : api.updateCustomSchedule(editingSchedule!.id, payload),
    onSuccess: () => { setEditingSchedule(null); queryClient.invalidateQueries({ queryKey: ['custom-schedules'] }); },
  });
  const deleteSchedule = useMutation({
    mutationFn: api.deleteCustomSchedule,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['custom-schedules'] }),
  });
  const items = data.filter((item) => item.session_date === today);
  const name = profile.data?.display_name ?? '张自航';
  const loading = isLoading || customSchedules.isLoading;
  const pageError = error ?? customSchedules.error;
  return <main className={`today-page${appearance === 'dark' ? ' today-page-dark' : ''}`}>
    <section className="today-hero">{profile.data?.avatar_data_url && <><div className="hero-avatar-background" aria-hidden="true" style={{ backgroundImage: `url(${profile.data.avatar_data_url})` }} /><div className="hero-avatar-overlay" aria-hidden="true" /></>}<div className="today-hero-content"><p className="today-kicker">今日 · {greetingForHour(now.getHours())}</p><h1>{name}</h1><p className="today-date">{now.toLocaleDateString('zh-CN', { month: 'long', day: 'numeric', weekday: 'long' })}</p></div>{profile.data?.avatar_data_url ? <button type="button" className="avatar-preview-trigger" aria-label={`预览${name}的头像`} onClick={() => setAvatarPreviewOpen(true)}><Avatar profile={profile.data} /></button> : <Avatar profile={profile.data} />}</section>
    <section className="today-content"><div className="today-section-heading"><h2>今日安排</h2><button type="button" className="add-schedule-button" onClick={() => setEditingSchedule('new')}><Plus size={17} />添加安排</button></div>{loading ? <p className="muted">正在读取本地缓存…</p> : pageError ? <p className="error">{String(pageError)}</p> : items.length || customSchedules.data?.length ? <Timeline sessions={items} schedules={customSchedules.data ?? []} onEdit={setEditingSchedule} onDelete={(schedule) => { if (window.confirm(`确认删除“${schedule.title}”吗？`)) deleteSchedule.mutate(schedule.id); }} /> : <Empty text="今天没有课程或自定义安排，享受自由时间。" />}</section>
    {editingSchedule && <CustomScheduleSheetV2 schedule={editingSchedule === 'new' ? undefined : editingSchedule} initialDate={today} pending={saveSchedule.isPending} error={saveSchedule.error} onClose={() => setEditingSchedule(null)} onSave={(payload) => saveSchedule.mutate(payload)} />}
    {avatarPreviewOpen && profile.data?.avatar_data_url && <AvatarPreviewSheet name={name} src={profile.data.avatar_data_url} dark={appearance === 'dark'} onClose={() => setAvatarPreviewOpen(false)} />}
  </main>;
}

function greetingForHour(hour: number) { if (hour < 10) return '早上好'; if (hour < 14) return '中午好'; if (hour < 18) return '下午好'; return '晚上好'; }
function Avatar({ profile, className = '' }: { profile: Profile | undefined; className?: string }) { const name = profile?.display_name ?? '张自航'; return <div className={`user-avatar ${className}`}>{profile?.avatar_data_url ? <img src={profile.avatar_data_url} alt={`${name}的头像`} /> : <span>{name.slice(-1)}</span>}</div>; }
function AvatarPreviewSheet({ name, src, dark, onClose }: { name: string; src: string; dark: boolean; onClose: () => void }) {
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose(); };
    window.addEventListener('keydown', closeOnEscape);
    return () => window.removeEventListener('keydown', closeOnEscape);
  }, [onClose]);
  return createPortal(<div className={`sheet-mask sheet-mask-viewport avatar-preview-mask${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={onClose}><section className="avatar-preview-sheet" role="dialog" aria-modal="true" aria-label={`${name}的头像预览`} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><button type="button" aria-label="关闭头像预览" title="关闭" onClick={onClose}><X size={18} /></button></header><div className="avatar-preview-image-frame"><img src={src} alt={`${name}的头像大图`} /></div></section></div>, document.body);
}

function Timeline({ sessions, schedules, onEdit, onDelete }: { sessions: Session[]; schedules: CustomSchedule[]; onEdit: (schedule: CustomSchedule) => void; onDelete: (schedule: CustomSchedule) => void }) {
  const now = Date.now();
  const active = sessions.find((session) => new Date(session.start_datetime).getTime() <= now && now < new Date(session.end_datetime).getTime());
  const upcoming = sessions.find((session) => new Date(session.start_datetime).getTime() > now);
  const status = active ? `正在上 ${active.course_name}，距下课约 ${Math.ceil((new Date(active.end_datetime).getTime() - now) / 60000)} 分钟` : upcoming ? `下一节 ${upcoming.course_name}，${Math.ceil((new Date(upcoming.start_datetime).getTime() - now) / 60000)} 分钟后上课` : schedules.length ? `今天有 ${schedules.length} 项自定义安排` : '今天的课程已经结束';
  const entries = [
    ...sessions.map((session) => ({ type: 'course' as const, sortTime: formatTime(session.start_datetime), session })),
    ...schedules.map((schedule) => ({ type: 'custom' as const, sortTime: schedule.scheduled_time, schedule })),
  ].sort((left, right) => left.sortTime.localeCompare(right.sortTime));
  return <><section className="today-status"><b>{status}</b></section><div className="stack">{entries.map((entry) => entry.type === 'course' ? <article className={`card ${entry.session === active ? 'current-course' : ''}`} key={`course-${entry.session.id}`}><b>{entry.session.course_name}</b><span>{formatTime(entry.session.start_datetime)}—{formatTime(entry.session.end_datetime)}</span><small>{entry.session.classroom ?? '教室待定'} · {entry.session.teacher ?? '教师待定'}</small></article> : <article className="card custom-schedule-card" key={`custom-${entry.schedule.id}`}><div className="custom-schedule-card-head"><small>自定义安排</small><span><button type="button" aria-label={`编辑 ${entry.schedule.title}`} onClick={() => onEdit(entry.schedule)}><Pencil size={15} /></button><button type="button" aria-label={`删除 ${entry.schedule.title}`} onClick={() => onDelete(entry.schedule)}><Trash2 size={15} /></button></span></div><b>{entry.schedule.title}</b><span>{entry.schedule.scheduled_time}</span></article>)}</div></>;
}

function CustomScheduleSheet({ schedule, initialDate, pending, error, onClose, onSave }: { schedule?: CustomSchedule; initialDate: string; pending: boolean; error: Error | null; onClose: () => void; onSave: (payload: CustomScheduleInput) => void }) {
  const [title, setTitle] = useState(schedule?.title ?? '');
  const [scheduledDate, setScheduledDate] = useState(schedule?.scheduled_date ?? initialDate);
  const [scheduledTime, setScheduledTime] = useState(schedule?.scheduled_time ?? '09:00');
  useEffect(() => { setTitle(schedule?.title ?? ''); setScheduledDate(schedule?.scheduled_date ?? initialDate); setScheduledTime(schedule?.scheduled_time ?? '09:00'); }, [schedule?.id, initialDate]);
  return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet custom-schedule-sheet" role="dialog" aria-modal="true" aria-label={schedule ? '编辑安排' : '添加安排'} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{schedule ? '编辑安排' : '添加安排'}</h2><button type="button" onClick={onClose} disabled={pending}>关闭</button></header><form onSubmit={(event) => { event.preventDefault(); onSave({ title: title.trim(), scheduled_date: scheduledDate, scheduled_time: scheduledTime }); }}><label>安排事项<input aria-label="安排事项名称" value={title} onChange={(event) => setTitle(event.target.value)} maxLength={200} required placeholder="例如：提交课程作业" /></label><div className="custom-schedule-time-fields"><label>日期<input aria-label="安排日期" type="date" value={scheduledDate} onChange={(event) => setScheduledDate(event.target.value)} required /></label><label>时间<input aria-label="安排时间" type="time" value={scheduledTime} onChange={(event) => setScheduledTime(event.target.value)} required /></label></div><small>安排会在所选日期的“今日安排”中显示；时间仅用于当天排序，不会触发系统通知。</small><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={pending}>取消</button><button type="submit" disabled={pending || !title.trim()}>{pending ? '保存中…' : '保存安排'}</button></div>{error && <p className="error">{error.message}</p>}</form></section></div>;
}

function formatScheduleDate(value: string) {
  const [year, month, day] = value.split('-');
  return year && month && day ? `${year}年${Number(month)}月${Number(day)}日` : value;
}

function CustomScheduleSheetV2({ schedule, initialDate, pending, error, onClose, onSave }: { schedule?: CustomSchedule; initialDate: string; pending: boolean; error: Error | null; onClose: () => void; onSave: (payload: CustomScheduleInput) => void }) {
  const [title, setTitle] = useState(schedule?.title ?? '');
  const [scheduledDate, setScheduledDate] = useState(schedule?.scheduled_date ?? initialDate);
  const [scheduledTime, setScheduledTime] = useState(schedule?.scheduled_time ?? '09:00');
  useEffect(() => { setTitle(schedule?.title ?? ''); setScheduledDate(schedule?.scheduled_date ?? initialDate); setScheduledTime(schedule?.scheduled_time ?? '09:00'); }, [schedule?.id, initialDate]);
  return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet custom-schedule-sheet" role="dialog" aria-modal="true" aria-label={schedule ? '编辑安排' : '添加安排'} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{schedule ? '编辑安排' : '添加安排'}</h2><button type="button" onClick={onClose} disabled={pending}>关闭</button></header><form onSubmit={(event) => { event.preventDefault(); if (scheduledDate < initialDate) return; onSave({ title: title.trim(), scheduled_date: scheduledDate, scheduled_time: scheduledTime }); }}><label>安排事项<input aria-label="安排事项名称" value={title} onChange={(event) => setTitle(event.target.value)} maxLength={200} required placeholder="例如：提交课程作业" /></label><label>日期<span className="custom-schedule-picker"><span className="custom-schedule-picker-value">{formatScheduleDate(scheduledDate)}</span><input aria-label="安排日期" type="date" min={initialDate} value={scheduledDate} onChange={(event) => setScheduledDate(event.target.value)} required /></span></label><label>时间<span className="custom-schedule-picker"><span className="custom-schedule-picker-value">{scheduledTime}</span><input aria-label="安排时间" type="time" value={scheduledTime} onChange={(event) => setScheduledTime(event.target.value)} required /></span></label><small>只能添加今天及以后的安排；时间仅用于当天排序，不会触发系统通知。</small><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={pending}>取消</button><button type="submit" disabled={pending || !title.trim() || scheduledDate < initialDate}>{pending ? '保存中…' : '保存安排'}</button></div>{error && <p className="error">{error.message}</p>}</form></section></div>;
}

function TermPicker({ terms, selected, onChange, disabled = false }: {
  terms: Term[] | undefined; selected: string; onChange: (value: string) => void; disabled?: boolean;
}) {
  return <div className="term-picker">
    <select aria-label="选择学期" value={selected} onChange={(event) => onChange(event.target.value)} disabled={disabled}>
      <option value="">选择学期</option>
      {terms?.map((term) => <option key={term.source_term_id} value={term.source_term_id}>{term.display_name}</option>)}
    </select>
  </div>;
}

function FileImportPanel({ pending, notice, error, onUpload }: { pending: boolean; notice: string | null; error: Error | null; onUpload: (file: File) => void }) {
  return <section className="file-import" aria-live="polite">
    <label className="file-import-button">{pending ? '正在解析课表…' : '导入打印课表文件'}<input type="file" accept=".xls,application/vnd.ms-excel" disabled={pending} onChange={(event) => { const file = event.target.files?.[0]; if (file) { onUpload(file); event.currentTarget.value = ''; } }} /></label>
    {notice && <p className="import-success">{notice}</p>}
    {error && <p className="error">导入失败：{error.message}</p>}
  </section>;
}

function GradeImportSheet({ preview, pending, error, onClose, onConfirm }: { preview: GradeImportPreview; pending: boolean; error: Error | null; onClose: () => void; onConfirm: (preview: GradeImportPreview) => void }) {
  const [items, setItems] = useState(preview.grades);
  useEffect(() => setItems(preview.grades), [preview]);
  const updateItem = (index: number, key: 'course_name' | 'score' | 'credits' | 'grade_point', value: string) => setItems((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, [key]: key === 'credits' || key === 'grade_point' ? (value.trim() ? Number(value) : null) : value } : item));
  return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet grade-import-sheet" role="dialog" aria-modal="true" aria-label="成绩导入预览" onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>成绩导入预览</h2><button type="button" onClick={onClose} disabled={pending}>关闭</button></header><p className="muted">识别到 {items.length} 门成绩，归入 {preview.source_term_id}。确认后将替换该学期现有成绩记录。</p><div className="grade-import-list">{items.map((item, index) => <article key={item.source_grade_id} className="grade-import-item"><label>课程名称<input value={item.course_name} onChange={(event) => updateItem(index, 'course_name', event.target.value)} required /></label><div><label>成绩<input value={item.score ?? ''} onChange={(event) => updateItem(index, 'score', event.target.value)} /></label><label>学分<input type="number" min="0" step="0.1" value={item.credits ?? ''} onChange={(event) => updateItem(index, 'credits', event.target.value)} /></label><label>绩点<input type="number" min="0" step="0.1" value={item.grade_point ?? ''} onChange={(event) => updateItem(index, 'grade_point', event.target.value)} /></label></div></article>)}</div><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={pending}>取消</button><button type="button" disabled={pending || items.some((item) => !item.course_name.trim())} onClick={() => onConfirm({ ...preview, grades: items })}>{pending ? '正在保存…' : '确认导入成绩'}</button></div>{error && <p className="error">导入失败：{error.message}</p>}</section></div>;
}

function useTerms() {
  const terms = useQuery({ queryKey: ['terms'], queryFn: api.terms });
  return { terms };
}

const COURSE_COLOR_CLASSES = ['course-color-violet', 'course-color-sky', 'course-color-emerald', 'course-color-amber', 'course-color-rose', 'course-color-cyan', 'course-color-lime', 'course-color-coral'];
const courseColorStorageKey = (termId: number) => `ynnu-jw-course-colors:${termId}`;
function createCourseColorMap(sessions: Session[]): Record<string, string> {
  const courseNames = [...new Set(sessions.map((session) => session.course_name))].sort();
  const palette = [...COURSE_COLOR_CLASSES];
  for (let index = palette.length - 1; index > 0; index -= 1) {
    const target = Math.floor(Math.random() * (index + 1));
    [palette[index], palette[target]] = [palette[target], palette[index]];
  }
  return Object.fromEntries(courseNames.map((name, index) => [name, palette[index % palette.length]]));
}
function readCourseColorMap(termId: number): Record<string, string> | null {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(courseColorStorageKey(termId)) ?? 'null');
    return parsed && typeof parsed === 'object' ? parsed as Record<string, string> : null;
  } catch { return null; }
}

type TimetableSlot = { weekday: number; startPeriod: number; endPeriod: number };

function WeekCalendar({ sessions, term, periods, anchor, courseColors, onSelect, pendingSlot, onSelectSlot, onAddSlot }: { sessions: Session[]; term: Term | undefined; periods: PeriodTime[]; anchor: Date; courseColors: Record<string, string>; onSelect: (session: Session) => void; pendingSlot: TimetableSlot | null; onSelectSlot: (slot: TimetableSlot | null) => void; onAddSlot: (slot: TimetableSlot) => void }) {
  const start = mondayOf(anchor); const days = Array.from({ length: 7 }, (_, index) => addDays(start, index)); const today = localDateKey(new Date());
  const startDate = term?.start_date ? dateFromKey(term.start_date) : null;
  const currentWeek = startDate && start >= mondayOf(startDate) ? Math.floor((start.getTime() - mondayOf(startDate).getTime()) / 604800000) + 1 : null;
  const canAddManualCourse = Boolean(currentWeek && currentWeek <= 25);
  const title = currentWeek && currentWeek <= 25 ? `第 ${currentWeek} 周` : '假期中';
  const now = dateFromKey(localDateKey(new Date()));
  const daysUntilStart = startDate && now < startDate ? Math.ceil((startDate.getTime() - now.getTime()) / 86400000) : null;
  const holidayHint = title === '假期中' && startDate && daysUntilStart !== null ? `距开学 ${daysUntilStart} 天 · ${startDate.getMonth() + 1} 月 ${startDate.getDate()} 日开学` : null;
  const visible = sessions.filter((session) => days.some((day) => session.session_date === localDateKey(day)));
  return <section className="week-calendar">
    <div className="week-caption"><div className="week-caption-title"><b>{title}</b>{holidayHint && <small>{holidayHint}</small>}</div><div className="week-caption-meta"><small>{term?.display_name ?? '请选择学期'}</small><span>{`${start.getMonth() + 1}月`}</span></div></div>
    <div className="week-scroll"><div className="week-head"><span />{days.map((day, index) => <div className="week-day" key={localDateKey(day)}><b>{WEEKDAY_LABELS[index]}</b><span className={localDateKey(day) === today ? 'today-date' : ''}>{day.getDate()}</span></div>)}</div>
      <div className="week-body">
        {periods.map((period, index) => <div className="period-label" key={period.period_number} style={{ gridRow: index + 1 }}><b>{period.period_number}</b><small>{period.start_time}<br />{period.end_time}</small></div>)}
        {canAddManualCourse && days.flatMap((day, dayIndex) => periods.map((period, periodIndex) => {
          const occupied = visible.some((session) => {
            if (session.session_date !== localDateKey(day)) return false;
            const startPeriod = periods.findIndex((item) => item.start_time === formatTime(session.start_datetime));
            const endPeriod = periods.findIndex((item) => item.end_time === formatTime(session.end_datetime));
            return startPeriod >= 0 && endPeriod >= startPeriod && periodIndex >= startPeriod && periodIndex <= endPeriod;
          });
          if (occupied) return null;
          const slot = { weekday: dayIndex + 1, startPeriod: period.period_number, endPeriod: period.period_number };
          const active = pendingSlot?.weekday === slot.weekday && pendingSlot.startPeriod === slot.startPeriod;
          return <button type="button" aria-label={active ? `在周${WEEKDAY_LABELS[dayIndex]}第${period.period_number}节添加课程` : `选择周${WEEKDAY_LABELS[dayIndex]}第${period.period_number}节`} className={active ? 'week-empty-slot week-empty-slot-active' : 'week-empty-slot'} key={`slot-${localDateKey(day)}-${period.period_number}`} style={{ gridColumn: dayIndex + 2, gridRow: periodIndex + 1 }} onClick={() => active ? onAddSlot(slot) : onSelectSlot(slot)}>{active && <Plus size={28} aria-hidden="true" />}</button>;
        }))}
        {visible.map((session) => {
          const day = days.findIndex((value) => session.session_date === localDateKey(value));
          const startPeriod = periods.findIndex((period) => period.start_time === formatTime(session.start_datetime));
          const endPeriod = periods.findIndex((period) => period.end_time === formatTime(session.end_datetime));
          if (day < 0 || startPeriod < 0 || endPeriod < startPeriod) return null;
          return <button type="button" className={`week-course ${session.source === 'MANUAL' ? 'manual-course-card' : ''} ${courseColors[session.course_name] ?? 'course-color-sky'}`} key={session.id} title={`${session.course_name} · ${session.classroom ?? '教室待定'} · ${session.teacher ?? '教师待定'}`} onClick={() => onSelect(session)} style={{ gridColumn: day + 2, gridRow: `${startPeriod + 1} / ${endPeriod + 2}` }}><b>{session.course_name}</b><small>{session.classroom ?? '教室待定'}</small><small>{session.teacher ?? '教师待定'}</small></button>;
        })}
      </div>
    </div>
  </section>;
}

function Timetable({ appearance }: { appearance: 'light' | 'dark' }) {
  const queryClient = useQueryClient();
  const { scrollRef: timetableScrollRef, headerStyle: timetableHeaderStyle, sideControlsHidden: timetableSideControlsHidden } = useCollapsiblePageTitle();
  const { terms } = useTerms();
  const [termId, setTermId] = useState('');
  const [weekAnchor, setWeekAnchor] = useState(() => new Date());
  const [selectedSession, setSelectedSession] = useState<Session | null>(null);
  const [pendingSlot, setPendingSlot] = useState<TimetableSlot | null>(null);
  const [manualEditor, setManualEditor] = useState<{ courseId?: number; initial: ManualCourseInput } | null>(null);
  const selected = termId || terms.data?.find((term) => term.is_current)?.source_term_id || terms.data?.find((term) => term.source_term_id === '2026-2027-1')?.source_term_id || '';
  const selectedTerm = terms.data?.find((term) => term.source_term_id === selected);
  const sessions = useQuery({ queryKey: ['sessions', selectedTerm?.id], queryFn: () => api.sessions(selectedTerm?.id) });
  const periods = useQuery({ queryKey: ['period-times'], queryFn: api.periodTimes });
  const [courseColors, setCourseColors] = useState<Record<string, string>>({});
  const resetCourseColors = (term: Term, items: Session[]) => {
    const next = createCourseColorMap(items);
    localStorage.setItem(courseColorStorageKey(term.id), JSON.stringify(next));
    setCourseColors(next);
  };
  useEffect(() => {
    if (!selectedTerm || !sessions.data) return;
    const courseNames = new Set(sessions.data.map((session) => session.course_name));
    const saved = readCourseColorMap(selectedTerm.id);
    if (saved && [...courseNames].every((name) => saved[name])) {
      setCourseColors(saved);
      return;
    }
    resetCourseColors(selectedTerm, sessions.data);
  }, [selectedTerm?.id, sessions.data]);
  const saveManualCourse = useMutation({
    mutationFn: ({ courseId, payload }: { courseId?: number; payload: ManualCourseInput }) => courseId ? api.updateManualCourse(courseId, payload) : api.createManualCourse(payload),
    onSuccess: async () => {
      setManualEditor(null);
      setPendingSlot(null);
      setSelectedSession(null);
      await queryClient.invalidateQueries({ queryKey: ['sessions'] });
    },
  });
  const deleteManualCourse = useMutation({
    mutationFn: api.deleteManualCourse,
    onSuccess: async () => {
      setSelectedSession(null);
      await queryClient.invalidateQueries({ queryKey: ['sessions'] });
    },
  });
  const [fileImportNotice, setFileImportNotice] = useState<string | null>(null);
  const fileImport = useMutation({ mutationFn: api.importTimetableFile, onMutate: () => setFileImportNotice(null), onSuccess: async (result) => { setTermId(result.term_id); setFileImportNotice(`已导入 ${result.term_id} 的 ${result.courses_imported} 条课程规则，并生成 ${result.sessions_generated} 条课程日程。`); await queryClient.invalidateQueries({ queryKey: ['terms'] }); await queryClient.invalidateQueries({ queryKey: ['sessions'] }); const importedTerm = queryClient.getQueryData<Term[]>(['terms'])?.find((term) => term.source_term_id === result.term_id); const freshSessions = importedTerm ? queryClient.getQueryData<Session[]>(['sessions', importedTerm.id]) : undefined; if (importedTerm && freshSessions) resetCourseColors(importedTerm, freshSessions); } });
  return <Page title="课程表" icon={<CalendarDays size={20} />} mainRef={timetableScrollRef} className={`timetable-page${appearance === 'dark' ? ' timetable-page-dark' : ''}`} headerClassName={`collapsible-page-header${timetableSideControlsHidden ? ' collapsible-side-controls-hidden' : ''}`} headerStyle={timetableHeaderStyle} compactTitle>
    <div className="week-tools"><button aria-label="上一周" onClick={() => setWeekAnchor((date) => moveWeekInTerm(date, -1, selectedTerm))}><ChevronLeft size={18} /></button><button type="button" onClick={() => setWeekAnchor(new Date())}>回到今天</button><button aria-label="下一周或开学周" title={selectedTerm?.start_date && mondayOf(weekAnchor) < mondayOf(dateFromKey(selectedTerm.start_date)) ? `跳到 ${selectedTerm.start_date} 开学周` : '下一周'} onClick={() => setWeekAnchor((date) => moveWeekInTerm(date, 1, selectedTerm))}><ChevronRight size={18} /></button></div>
{terms.isLoading ? <p className="muted">正在读取本地学期列表…</p> : terms.data?.length === 0 ? <Empty text="请导入教务系统打印的课程表文件，然后选择对应学期。" /> : <WeekCalendar sessions={sessions.data ?? []} term={selectedTerm} periods={periods.data ?? DEFAULT_PERIODS} anchor={weekAnchor} courseColors={courseColors} onSelect={(session) => { setPendingSlot(null); setSelectedSession(session); }} pendingSlot={pendingSlot} onSelectSlot={setPendingSlot} onAddSlot={(slot) => { if (!selectedTerm) return; setManualEditor({ initial: { term_id: selectedTerm.id, course_name: '', week_expression: `${Math.max(1, Math.floor((mondayOf(weekAnchor).getTime() - mondayOf(dateFromKey(selectedTerm.start_date ?? localDateKey(weekAnchor))).getTime()) / 604800000) + 1)}周`, weekday: slot.weekday, start_period: slot.startPeriod, end_period: slot.endPeriod, classroom: '', teacher: '' } }); }} />}
    {terms.error && <p className="error">读取本地课表失败：{String(terms.error)}</p>}
    <section className="timetable-management"><b>课表管理</b><TermPicker terms={terms.data} selected={selected} onChange={setTermId} /><FileImportPanel pending={fileImport.isPending} notice={fileImportNotice} error={fileImport.error} onUpload={(file) => { fileImport.reset(); fileImport.mutate(file); }} /></section>
    {selectedSession && <DetailSheet title={selectedSession.course_name} dark={appearance === 'dark'} onClose={() => setSelectedSession(null)}><Detail label="上课时间" value={`${selectedSession.session_date} ${formatTime(selectedSession.start_datetime)}—${formatTime(selectedSession.end_datetime)}`} /><Detail label="教室" value={selectedSession.classroom ?? '未提供'} /><Detail label="教师" value={selectedSession.teacher ?? '未提供'} /><Detail label="周次" value={selectedSession.week_expression ?? '未提供'} />{selectedSession.source === 'MANUAL' && selectedSession.manual_course_id && <div className="manual-course-detail-actions"><small>手动添加课程</small><span><button type="button" onClick={() => { if (!selectedTerm) return; setSelectedSession(null); setManualEditor({ courseId: selectedSession.manual_course_id!, initial: { term_id: selectedSession.term_id ?? selectedTerm.id, course_name: selectedSession.course_name, teacher: selectedSession.teacher, classroom: selectedSession.classroom, weekday: selectedSession.weekday ?? (new Date(`${selectedSession.session_date}T12:00:00`).getDay() || 7), start_period: selectedSession.start_period ?? 1, end_period: selectedSession.end_period ?? 1, week_expression: selectedSession.week_expression ?? '' } }); }}>编辑</button><button type="button" className="danger-button" onClick={() => { if (window.confirm(`确认删除手动课程“${selectedSession.course_name}”吗？`)) deleteManualCourse.mutate(selectedSession.manual_course_id!); }}>删除</button></span></div>}</DetailSheet>}
    {manualEditor && <ManualCourseSheetV2 initial={manualEditor.initial} periods={periods.data ?? DEFAULT_PERIODS} pending={saveManualCourse.isPending} error={saveManualCourse.error} editing={Boolean(manualEditor.courseId)} dark={appearance === 'dark'} onClose={() => setManualEditor(null)} onSave={(payload) => saveManualCourse.mutate({ courseId: manualEditor.courseId, payload })} />}
  </Page>;
}

function AiAnalysisReport({ content }: { content: string }) {
  return <div className="grade-ai-markdown"><ReactMarkdown components={{ h2: ({ children }) => <h2>{children}</h2>, ul: ({ children }) => <ul>{children}</ul>, li: ({ children }) => <li>{children}</li>, p: ({ children }) => <p>{children}</p>, strong: ({ children }) => <strong>{children}</strong> }}>{content}</ReactMarkdown></div>;
}

function Grades({ appearance }: { appearance: 'light' | 'dark' }) {
  const queryClient = useQueryClient();
  const { scrollRef: gradesScrollRef, headerStyle: gradesHeaderStyle, sideControlsHidden: gradesSideControlsHidden } = useCollapsiblePageTitle();
  const { terms } = useTerms();
  const [termId, setTermId] = useState('');
  const [importTermId, setImportTermId] = useState('');
  const [selectedGrade, setSelectedGrade] = useState<Grade | null>(null);
  const [gradePreview, setGradePreview] = useState<GradeImportPreview | null>(null);
  const [analysis, setAnalysis] = useState<GradeAiAnalysis | null>(null);
  const [historyOpen, setHistoryOpen] = useState(false);
  const now = new Date();
  const academicYear = now.getMonth() >= 8 ? `${now.getFullYear()}-${now.getFullYear() + 1}-1` : `${now.getFullYear() - 1}-${now.getFullYear()}-2`;
  const selected = termId || terms.data?.find((term) => term.is_current)?.source_term_id || terms.data?.find((term) => term.source_term_id === academicYear)?.source_term_id || '';
  const selectedTerm = terms.data?.find((term) => term.source_term_id === selected);
  const grades = useQuery({ queryKey: ['grades', selectedTerm?.id], queryFn: () => api.grades(selectedTerm?.id) });
  const summary = useQuery({ queryKey: ['summary', selectedTerm?.id], queryFn: () => api.summary(selectedTerm?.id) });
  const analysisHistory = useQuery({ queryKey: ['grade-ai-analyses', selectedTerm?.id], queryFn: () => api.gradeAiAnalyses(selectedTerm?.id), enabled: Boolean(selectedTerm) });
  useEffect(() => { setAnalysis(null); setHistoryOpen(false); }, [selectedTerm?.id]);
  const previewImport = useMutation({
    mutationFn: (file: File) => api.previewGradesFile(file, importTermId.trim() || selected || undefined),
    onSuccess: setGradePreview,
  });
  const confirmImport = useMutation({
    mutationFn: api.confirmGradesImport,
    onSuccess: async (result) => {
      setTermId(result.source_term_id);
      setGradePreview(null);
      await queryClient.invalidateQueries({ queryKey: ['terms'] });
      await queryClient.invalidateQueries({ queryKey: ['grades'] });
      await queryClient.invalidateQueries({ queryKey: ['summary'] });
    },
  });
  const analyze = useMutation({
    mutationFn: (forceRefresh: boolean) => {
      if (!selectedTerm) throw new Error('请先选择一个已导入成绩的学期');
      return api.analyzeGrades(selectedTerm.id, forceRefresh);
    },
    onSuccess: async (result) => {
      setAnalysis(result);
      await queryClient.invalidateQueries({ queryKey: ['grade-ai-analyses'] });
    },
  });
  return <Page title="成绩分析" icon={<GraduationCap size={20} />} mainRef={gradesScrollRef} className={`grades-page${appearance === 'dark' ? ' grades-page-dark' : ''}`} headerClassName={`collapsible-page-header${gradesSideControlsHidden ? ' collapsible-side-controls-hidden' : ''}`} headerStyle={gradesHeaderStyle} compactTitle>
    <TermPicker terms={terms.data} selected={selected} onChange={setTermId} />
    <section className="grade-import-actions"><label className="grade-import-term">导入学期（文件未标明时填写）<input aria-label="成绩导入学期" value={importTermId} onChange={(event) => setImportTermId(event.target.value)} placeholder={selected || '例如：2025-2026-2'} pattern="20\\d{2}-20\\d{2}-[12]" maxLength={11} /></label><label className="file-import-button"><Upload size={16} />{previewImport.isPending ? '正在识别成绩…' : '导入成绩文件'}<input type="file" accept=".xls,.html,.htm,application/vnd.ms-excel,text/html" disabled={previewImport.isPending} onChange={(event) => { const file = event.target.files?.[0]; if (file) { previewImport.reset(); previewImport.mutate(file); event.currentTarget.value = ''; } }} /></label><small>支持教务系统导出的 .xls 或 HTML 成绩文件；文件仅用于本次识别，不会保留原件。</small>{previewImport.error && <p className="error">识别失败：{previewImport.error.message}</p>}</section>
    <div className="metrics"><Metric label="已获学分" value={summary.data?.earned_credits ?? '—'} /><Metric label="平均成绩" value={summary.data?.average_score?.toFixed(1) ?? '—'} /><Metric label="绩点" value={summary.data?.gpa?.toFixed(2) ?? '—'} /><Metric label="不及格" value={summary.data?.failed_courses ?? '—'} /></div>
    <section className="grade-ai-actions"><div><b>AI 成绩分析</b><small>仅在你点击后，将当前学期的课程名称、成绩、学分和绩点发送给已配置的模型服务。</small></div><div className="grade-ai-buttons"><button type="button" className="secondary-button" disabled={!selectedTerm} onClick={() => setHistoryOpen((open) => !open)}>{historyOpen ? '收起历史' : `历史分析${analysisHistory.data?.length ? ` ${analysisHistory.data.length}` : ''}`}</button><button type="button" disabled={!selectedTerm || analyze.isPending || !grades.data?.length} onClick={() => { analyze.reset(); analyze.mutate(false); }}>{analyze.isPending ? '分析中…' : '生成分析'}</button></div></section>
    {analyze.error && <p className="error">分析失败：{analyze.error.message}</p>}
    {analysis && <section className="card grade-ai-result"><header><b>分析结果</b><span><small>{analysis.cached ? '已使用当前成绩快照的缓存结果' : `由 ${analysis.model} 生成`}</small><button type="button" className="secondary-button" disabled={analyze.isPending} onClick={() => { analyze.reset(); analyze.mutate(true); }}>{analyze.isPending ? '生成中…' : '重新生成'}</button></span></header><AiAnalysisReport content={analysis.content} /><button type="button" className="secondary-button grade-ai-collapse" onClick={() => setAnalysis(null)}>收起</button></section>}
    {historyOpen && <GradeAiAnalysisHistoryPanel history={analysisHistory.data ?? []} loading={analysisHistory.isLoading} error={analysisHistory.error} onSelect={(entry) => setAnalysis({ ...entry, cached: true })} />}
    <div className="stack">{grades.data?.map((grade: Grade) => <button type="button" className="card grade-card" key={grade.id} onClick={() => setSelectedGrade(grade)}><b>{grade.course_name}</b><span>成绩：{grade.score ?? '未公布'}　学分：{grade.credits ?? '—'}</span><small>{grade.course_type ?? '课程性质未提供'} · 绩点：{grade.grade_point ?? '—'}</small></button>)}</div>
    {summary.data?.gpa_note && <small className="muted">{summary.data.gpa_note}</small>}
    {terms.error && <p className="error">读取成绩分析失败：{String(terms.error)}</p>}
    {selectedGrade && <DetailSheet title={selectedGrade.course_name} dark={appearance === 'dark'} onClose={() => setSelectedGrade(null)}><Detail label="总评成绩" value={selectedGrade.score ?? '未公布'} /><Detail label="期末成绩" value={selectedGrade.final_exam_score ?? '未提供'} /><Detail label="平时成绩" value={selectedGrade.usual_score ?? '未提供'} /><Detail label="学分 / 绩点" value={`${selectedGrade.credits ?? '—'} / ${selectedGrade.grade_point ?? '—'}`} /><Detail label="课程性质" value={selectedGrade.course_type ?? '未提供'} /><Detail label="考试性质" value={selectedGrade.exam_type ?? '未提供'} /><Detail label="补考 / 重修" value={`${selectedGrade.makeup_flag ? '补考' : '否'} / ${selectedGrade.retake_flag ? '重修' : '否'}`} /></DetailSheet>}
    {gradePreview && <GradeImportSheet preview={gradePreview} pending={confirmImport.isPending} error={confirmImport.error} onClose={() => { if (!confirmImport.isPending) setGradePreview(null); }} onConfirm={(preview) => confirmImport.mutate(preview)} />}
  </Page>;
}

function GradeAiAnalysisHistoryPanel({ history, loading, error, onSelect }: { history: GradeAiAnalysisHistory[]; loading: boolean; error: Error | null; onSelect: (entry: GradeAiAnalysisHistory) => void }) {
  return <section className="card grade-ai-history"><header><span><b>历史分析</b><small>仅显示本学期；打开历史不会调用模型服务。</small></span></header>{loading ? <p className="muted">正在读取分析历史…</p> : error ? <p className="error">读取历史失败：{error.message}</p> : history.length ? <div className="grade-ai-history-list">{history.map((entry) => <button type="button" className="grade-ai-history-item" key={entry.id} onClick={() => onSelect(entry)}><span><b>{entry.model}</b><small>{new Date(entry.created_at).toLocaleString('zh-CN', { dateStyle: 'medium', timeStyle: 'short' })} · {entry.provider}</small></span><span>查看</span></button>)}</div> : <p className="muted">当前学期还没有可查看的历史分析。</p>}</section>;
}

function DataSettingsEntry({ onOpen }: { onOpen: () => void }) {
  return <button type="button" className="settings-menu-item" onClick={onOpen}><span><b><Database size={18} />数据与导入</b><small>本地课程表与成绩文件导入</small></span><span aria-hidden="true">›</span></button>;
}

function AiAnalysisSettings() {
  const queryClient = useQueryClient();
  const settings = useQuery({ queryKey: ['ai-settings'], queryFn: api.aiSettings });
  const [provider, setProvider] = useState('APIKEY.FUN');
  const [baseUrl, setBaseUrl] = useState('https://api.apikey.fun/v1');
  const [model, setModel] = useState('');
  const [apiKey, setApiKey] = useState('');
  const [availableModels, setAvailableModels] = useState<string[]>([]);
  const [modelLookupNotice, setModelLookupNotice] = useState<string | null>(null);
  const [connectionNotice, setConnectionNotice] = useState<string | null>(null);
  useEffect(() => {
    if (!settings.data?.configured) return;
    setProvider(settings.data.provider ?? 'APIKEY.FUN');
    setBaseUrl(settings.data.base_url ?? '');
    setModel(settings.data.model ?? '');
    setAvailableModels(settings.data.available_models ?? []);
  }, [settings.data]);
  const save = useMutation({
    mutationFn: () => api.updateAiSettings({ provider, base_url: baseUrl, model, api_key: apiKey } satisfies AiProviderSettingInput),
    onSuccess: async (result) => {
      setApiKey('');
      setAvailableModels(result.available_models);
      setModel(result.model ?? '');
      setModelLookupNotice(`已安全保存 ${result.available_models.length} 个可用模型。`);
      await queryClient.invalidateQueries({ queryKey: ['ai-settings'] });
    },
  });
  const lookupModels = useMutation({
    mutationFn: () => api.lookupAiModels({ provider, base_url: baseUrl, api_key: apiKey }),
    onSuccess: (result) => {
      setAvailableModels(result.models);
      setModel((current) => result.models.includes(current) ? current : result.models[0]);
      setModelLookupNotice(`已读取 ${result.models.length} 个可用模型，并自动选中第一个模型。`);
    },
    onError: () => { setAvailableModels([]); setModelLookupNotice(null); },
  });
  const refreshModels = useMutation({
    mutationFn: api.refreshAiModels,
    onSuccess: async (result) => {
      setAvailableModels(result.available_models);
      setModel(result.model ?? '');
      setModelLookupNotice(`已刷新 ${result.available_models.length} 个可用模型。`);
      await queryClient.invalidateQueries({ queryKey: ['ai-settings'] });
    },
    onError: () => setModelLookupNotice(null),
  });
  const selectModel = useMutation({
    mutationFn: api.selectAiModel,
    onSuccess: async (result) => {
      setModel(result.model ?? '');
      setConnectionNotice(null);
      await queryClient.invalidateQueries({ queryKey: ['ai-settings'] });
    },
    onError: () => setModel(settings.data?.model ?? ''),
  });
  const testConnection = useMutation({
    mutationFn: () => api.testAiSettings({ provider, base_url: baseUrl, model, api_key: apiKey } satisfies AiProviderSettingInput),
    onSuccess: (result) => setConnectionNotice(`${result.message}（${result.model}）`),
    onError: () => setConnectionNotice(null),
  });
  const clear = useMutation({ mutationFn: api.clearAiSettings, onSuccess: async () => { setApiKey(''); setConnectionNotice(null); await queryClient.invalidateQueries({ queryKey: ['ai-settings'] }); } });
  const lookupIncomplete = !provider.trim() || !baseUrl.trim() || apiKey.length < 8;
  const incomplete = lookupIncomplete || !model.trim();
  const savedModels = settings.data?.available_models ?? [];
  const modelOptions = availableModels.length ? availableModels : savedModels;
  const isSavedConfiguration = Boolean(settings.data?.configured);
  const isEditingSavedConfiguration = isSavedConfiguration && (apiKey.trim().length > 0 || provider !== settings.data?.provider || baseUrl !== settings.data?.base_url);
  const resetModelLookup = () => {
    setAvailableModels([]);
    setModelLookupNotice(null);
    setConnectionNotice(null);
  };
  const chooseApikeyFun = () => {
    setProvider('APIKEY.FUN');
    setBaseUrl('https://api.apikey.fun/v1');
    resetModelLookup();
  };
  const chooseModel = (nextModel: string) => {
    setModel(nextModel);
    setConnectionNotice(null);
    if (isSavedConfiguration && !isEditingSavedConfiguration) selectModel.mutate(nextModel);
  };
  const syncedLabel = settings.data?.models_synced_at ? `上次刷新：${new Date(settings.data.models_synced_at).toLocaleString('zh-CN', { dateStyle: 'medium', timeStyle: 'short' })}` : '模型列表尚未刷新';
  return <section className="card settings-card ai-settings-card"><header className="ai-settings-heading"><span><b>第三方模型服务</b><small>模型列表与 API Key 对应；Key 仅以加密形式保存在后端。</small></span>{isSavedConfiguration && <span className="ai-settings-status">已保存</span>}</header><form className="credential-form" onSubmit={(event) => { event.preventDefault(); save.mutate(); }}><label>服务预设<select aria-label="模型服务预设" value={provider === 'APIKEY.FUN' && baseUrl === 'https://api.apikey.fun/v1' ? 'apikey-fun' : 'custom'} onChange={(event) => { if (event.target.value === 'apikey-fun') chooseApikeyFun(); }}><option value="apikey-fun">APIKEY.FUN</option><option value="custom">其他 OpenAI 兼容服务</option></select></label><label>服务名称<input value={provider} onChange={(event) => { setProvider(event.target.value); resetModelLookup(); }} maxLength={64} required /></label><label>服务地址<input type="url" value={baseUrl} onChange={(event) => { setBaseUrl(event.target.value); resetModelLookup(); }} placeholder="https://api.example.com/v1" required /></label><label>API Key<input type="password" value={apiKey} onChange={(event) => { setApiKey(event.target.value); resetModelLookup(); }} placeholder={isSavedConfiguration ? `已配置 ${settings.data?.api_key_hint ?? ''}；更换服务时重新填写` : '输入 API Key'} minLength={8} autoComplete="off" required={!isSavedConfiguration} /></label><label>模型选择<select aria-label="模型选择" value={model} disabled={!modelOptions.length || selectModel.isPending} onChange={(event) => chooseModel(event.target.value)} required><option value="" disabled>{modelOptions.length ? '选择模型' : '请先读取可用模型'}</option>{modelOptions.map((modelId) => <option key={modelId} value={modelId}>{modelId}</option>)}</select><small className="ai-model-sync-note">{syncedLabel}</small></label>{isSavedConfiguration && <button className="secondary-button ai-refresh-models-button" type="button" disabled={refreshModels.isPending || isEditingSavedConfiguration} onClick={() => refreshModels.mutate()}>{refreshModels.isPending ? '刷新中…' : '刷新已保存模型'}</button>}<div className="ai-settings-actions"><button className="secondary-button" type="button" disabled={lookupModels.isPending || lookupIncomplete} onClick={() => lookupModels.mutate()}>{lookupModels.isPending ? '读取中…' : '读取新配置模型'}</button><button className="secondary-button" type="button" disabled={testConnection.isPending || incomplete} onClick={() => testConnection.mutate()}>{testConnection.isPending ? '测试中…' : '测试新配置'}</button><button type="submit" disabled={save.isPending || incomplete}>{save.isPending ? '保存中…' : '加密保存配置'}</button></div>{isSavedConfiguration && <button className="secondary-button ai-settings-clear-button" type="button" disabled={clear.isPending} onClick={() => { if (window.confirm('确认清除已保存的模型服务配置吗？')) clear.mutate(); }}>{clear.isPending ? '清除中…' : '清除模型配置'}</button>}</form>{modelLookupNotice && <p className="success-message">{modelLookupNotice}</p>}{connectionNotice && <p className="success-message">{connectionNotice}</p>}{(settings.error || save.error || lookupModels.error || refreshModels.error || selectModel.error || testConnection.error || clear.error) && <p className="error">{settings.error?.message ?? save.error?.message ?? lookupModels.error?.message ?? refreshModels.error?.message ?? selectModel.error?.message ?? clear.error?.message}</p>}</section>;
}

function AiAnalysisHistorySettings() {
  const queryClient = useQueryClient();
  const [confirmClear, setConfirmClear] = useState(false);
  const clearHistory = useMutation({
    mutationFn: api.clearGradeAiAnalyses,
    onSuccess: async () => {
      setConfirmClear(false);
      await queryClient.invalidateQueries({ queryKey: ['grade-ai-analyses'] });
    },
  });
  return <><section className="card settings-card ai-analysis-history-settings"><b>分析历史缓存</b><small>保存的是 AI 生成的文字、生成时间和模型名称，便于回看；不会保留上传的原始成绩文件。清除后不影响已导入成绩，也不会清除模型服务配置。</small><button type="button" className="logout-button" disabled={clearHistory.isPending} onClick={() => setConfirmClear(true)}>清除历史分析</button>{clearHistory.isSuccess && <p className="success-message">已清除 {clearHistory.data.deleted} 条历史分析。</p>}{clearHistory.error && <p className="error">清除失败：{clearHistory.error.message}</p>}</section>{confirmClear && <ConfirmDialog title="清除全部 AI 分析历史？" description="这会删除已保存的 AI 分析文字，无法恢复；课程、成绩和模型配置不会受到影响。" confirmLabel="确认清除" pending={clearHistory.isPending} onCancel={() => setConfirmClear(false)} onConfirm={() => clearHistory.mutate()} />}</>;
}

function AppearanceModeSelector({ mode, onChange }: { mode: AppearanceMode; onChange: (mode: AppearanceMode) => void }) {
  const options = [
    { value: 'light' as const, label: '浅色', icon: Sun },
    { value: 'dark' as const, label: '深色', icon: Moon },
    { value: 'system' as const, label: '系统', icon: Monitor },
  ];
  const activeIndex = options.findIndex((option) => option.value === mode);
  return <section className="card settings-card appearance-mode-card"><b>外观模式</b><div className="appearance-mode-switch" role="radiogroup" aria-label="外观模式"><span className="appearance-mode-indicator" style={{ transform: `translateX(${activeIndex * 100}%)` }} aria-hidden="true" />{options.map((option) => { const Icon = option.icon; const active = option.value === mode; return <button key={option.value} type="button" role="radio" aria-checked={active} className={active ? 'active' : ''} onClick={() => onChange(option.value)}><Icon size={17} />{option.label}</button>; })}</div></section>;
}

function Settings({ appearanceMode, resolvedAppearanceMode, onAppearanceModeChange }: { appearanceMode: AppearanceMode; resolvedAppearanceMode: 'light' | 'dark'; onAppearanceModeChange: (mode: AppearanceMode) => void }) {
  const queryClient = useQueryClient();
  const { scrollRef: settingsScrollRef, headerStyle: settingsHeaderStyle } = useCollapsiblePageTitle();
  const profile = useQuery({ queryKey: ['profile'], queryFn: api.profile });
  const terms = useQuery({ queryKey: ['terms'], queryFn: api.terms });
  const periods = useQuery({ queryKey: ['period-times'], queryFn: api.periodTimes });
  const [selectedTermId, setSelectedTermId] = useState<number | null>(null);
  const [selectedPeriodNumber, setSelectedPeriodNumber] = useState<number | null>(null);
  const [logoutConfirm, setLogoutConfirm] = useState(false);
  const [settingsSection, setSettingsSection] = useState<'account' | 'time' | 'personal' | 'data' | 'analysis' | 'about' | null>(null);
  const [displayName, setDisplayName] = useState('张自航');
  const [newAvatar, setNewAvatar] = useState<string | null | undefined>(undefined);
  const [avatarError, setAvatarError] = useState<string | null>(null);
  const preferredTerm = terms.data?.find((term) => term.source_term_id === currentAcademicTermId()) ?? terms.data?.find((term) => term.is_current) ?? terms.data?.[0];
  useEffect(() => { if (profile.data) setDisplayName(profile.data.display_name); }, [profile.data]);
  const appLogout = useMutation({
    mutationFn: api.logout,
    onSettled: () => {
      // 退出后替换当前功能页地址，避免刷新时仍停留在 /settings 等受保护路径。
      window.location.replace('/login');
    },
  });
  const saveProfile = useMutation({
    mutationFn: () => {
      const payload: ProfileUpdate = { display_name: displayName.trim() };
      if (newAvatar !== undefined) payload.avatar_data_url = newAvatar;
      return api.updateProfile(payload);
    },
    onSuccess: () => { setNewAvatar(undefined); setAvatarError(null); queryClient.invalidateQueries({ queryKey: ['profile'] }); },
  });
  const chooseAvatar = (file: File | undefined) => {
    if (!file) return;
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) { setAvatarError('请选择 PNG、JPEG 或 WebP 格式的图片。'); return; }
    if (file.size > 1_000_000) { setAvatarError('头像图片不能超过 1 MB。'); return; }
    const reader = new FileReader();
    reader.onload = () => { setNewAvatar(String(reader.result)); setAvatarError(null); };
    reader.readAsDataURL(file);
  };
  const sectionTitle = settingsSection === 'account' ? '账号安全' : settingsSection === 'time' ? '时间设置' : settingsSection === 'personal' ? '个性化设置' : settingsSection === 'data' ? '数据与导入' : settingsSection === 'analysis' ? '成绩分析设置' : settingsSection === 'about' ? '关于助手' : '设置';
  const accountTitleCollapsible = settingsSection === 'account';
  const sectionTitleCollapsible = Boolean(settingsSection);
  const settingsPageClassName = `${accountTitleCollapsible ? 'account-settings-page ' : ''}${sectionTitleCollapsible ? 'settings-section-page ' : ''}${resolvedAppearanceMode === 'dark' ? 'settings-page-dark' : ''}`.trim();
  return <Page title={sectionTitle} icon={accountTitleCollapsible ? <KeyRound size={20} /> : !settingsSection ? <SettingsIcon size={20} /> : undefined} action={settingsSection ? <button type="button" className="settings-back" onClick={() => setSettingsSection(null)}><ChevronLeft size={18} />返回</button> : undefined} mainRef={settingsScrollRef} className={settingsPageClassName} headerClassName={sectionTitleCollapsible ? 'collapsible-page-header settings-section-header' : undefined} headerStyle={sectionTitleCollapsible ? settingsHeaderStyle : undefined} compactTitle={sectionTitleCollapsible}>
    {settingsSection === 'personal' && <p className="settings-inline-note">外观偏好与个人资料会直接显示在本页；目前已适配今日页、底侧栏和设置页面。</p>}
    {settingsSection === 'account' && <p className="settings-inline-note">管理员用户名和密码仅由服务器环境变量配置；本页不会保存或展示密码。</p>}
    {settingsSection === 'data' && <p className="settings-inline-note">课程表与成绩只通过你主动选择的导出文件写入本地缓存，不再由服务器登录或抓取教务系统。</p>}
    {!settingsSection && <section className="settings-menu"><button type="button" className="settings-menu-item" onClick={() => setSettingsSection('account')}><span><b><KeyRound size={18} />账号安全</b><small>单用户登录与退出</small></span><span aria-hidden="true">›</span></button><button type="button" className="settings-menu-item" onClick={() => setSettingsSection('time')}><span><b><Clock3 size={18} />时间设置</b><small>学期第一周与节次时间</small></span><span aria-hidden="true">›</span></button><button type="button" className="settings-menu-item" onClick={() => setSettingsSection('personal')}><span><b><Palette size={18} />个性化设置</b><small>显示姓名与首页头像</small></span><span aria-hidden="true">›</span></button><DataSettingsEntry onOpen={() => setSettingsSection('data')} /><button type="button" className="settings-menu-item" onClick={() => setSettingsSection('analysis')}><span><b><GraduationCap size={18} />成绩分析设置</b><small>第三方模型服务与 API Key</small></span><span aria-hidden="true">›</span></button><button type="button" className="settings-menu-item" onClick={() => setSettingsSection('about')}><span><b><Info size={18} />关于助手</b><small>版本、数据保护与使用说明</small></span><span aria-hidden="true">›</span></button></section>}
    {settingsSection === 'personal' && <AppearanceModeSelector mode={appearanceMode} onChange={onAppearanceModeChange} />}
    {settingsSection === 'account' && <>
      <section className="card settings-card account-settings-card">
        <b>单用户认证</b>
        <small>登录凭据由部署环境中的 <code>ADMIN_USERNAME</code> 和 <code>ADMIN_PASSWORD_HASH</code> 管理。修改密码后，请重新生成 Argon2id 哈希并更新服务器 `.env`，再重启后端。</small>
      </section>
      <section className="card settings-card"><b>退出航的助手</b><small>退出本应用并返回登录页；不会删除已导入的课程表、成绩缓存或自定义安排。</small><button type="button" className="logout-button" disabled={appLogout.isPending} onClick={() => setLogoutConfirm(true)}>退出到登录页</button></section>
    </>}
    {settingsSection === 'personal' && <section className="card settings-card"><b>个人资料</b><small>首页会使用这里的姓名和头像。头像仅保存在你的后端，支持 PNG、JPEG、WebP，最大 1 MB。</small><form className="profile-form" onSubmit={(event) => { event.preventDefault(); saveProfile.mutate(); }}><Avatar profile={newAvatar === undefined ? profile.data : { display_name: displayName || '张自航', avatar_data_url: newAvatar }} className="profile-avatar" /><label>显示姓名<input aria-label="显示姓名" value={displayName} onChange={(event) => setDisplayName(event.target.value)} maxLength={64} required /></label><div className="profile-actions"><label className="profile-upload-button">选择头像<input aria-label="选择头像" type="file" accept="image/png,image/jpeg,image/webp" onChange={(event) => chooseAvatar(event.target.files?.[0])} /></label>{(newAvatar !== undefined ? newAvatar : profile.data?.avatar_data_url) && <button className="secondary-button" type="button" onClick={() => setNewAvatar(null)}>移除头像</button>}<button type="submit" disabled={saveProfile.isPending || !displayName.trim()}>{saveProfile.isPending ? '保存中…' : '保存个人资料'}</button></div>{(avatarError || saveProfile.error) && <p className="error">{avatarError ?? saveProfile.error?.message}</p>}</form></section>}
    {settingsSection === 'time' && <><section className="card"><b>学期第一周</b><small>选择一个已导入的学期后，在日历中选择第一周的星期一。保存会重新生成该学期日程。</small>{terms.data?.length && preferredTerm ? <><label className="settings-select">学期<select aria-label="选择要配置的学期" value={selectedTermId ?? preferredTerm.id} onChange={(event) => setSelectedTermId(Number(event.target.value))}>{terms.data.map((term) => <option key={term.id} value={term.id}>{term.display_name}</option>)}</select></label><TermStartDateEditor term={terms.data.find((term) => term.id === selectedTermId) ?? preferredTerm} onSaved={() => { queryClient.invalidateQueries({ queryKey: ['terms'] }); queryClient.invalidateQueries({ queryKey: ['sessions'] }); }} /></> : <small>尚无学期数据；请先在课程表页导入打印课表文件。</small>}</section><section className="card settings-card"><b>节次时间</b><small>选择需要调整的节次。保存后，已有课程日程会按新时间重新生成。</small>{periods.data?.length ? <><label className="settings-select">节次<select aria-label="选择要配置的节次" value={selectedPeriodNumber ?? periods.data[0].period_number} onChange={(event) => setSelectedPeriodNumber(Number(event.target.value))}>{periods.data.map((period) => <option key={period.period_number} value={period.period_number}>第 {period.period_number} 节</option>)}</select></label><PeriodTimeEditor period={periods.data.find((period) => period.period_number === selectedPeriodNumber) ?? periods.data[0]} onSaved={() => { queryClient.invalidateQueries({ queryKey: ['period-times'] }); queryClient.invalidateQueries({ queryKey: ['sessions'] }); }} /></> : <small>正在读取节次时间…</small>}</section></>}
    {settingsSection === 'data' && <section className="card settings-card"><b>本地文件导入</b><small>课程表与成绩不会由服务器登录教务系统获取。请在教务系统中自行导出文件，再回到本应用导入。已确认入库的数据会保存在个人后端缓存中。</small><div className="about-list"><p><span>课程表</span><strong>导入打印的 .xls 课表</strong></p><p><span>成绩分析</span><strong>导入 .xls 或 HTML 成绩文件</strong></p><p><span>原始文件</span><strong>仅用于本次解析，不会保存</strong></p></div></section>}
    {settingsSection === 'analysis' && <><AiAnalysisSettings /><AiAnalysisHistorySettings /></>}
    {settingsSection === 'about' && <><section className="about-hero"><div className="about-mark"><img src="/pwa-192.png" alt="航的助手应用图标" /></div><div><small>Hand Helper</small><h2>航的助手</h2><span>v{APP_VERSION}</span></div></section><section className="card about-card"><b>应用说明</b><small>为个人使用场景设计的课程表与成绩分析助手。课程和成绩由你主动上传导出文件后写入本地缓存。</small><div className="about-list"><p><span>使用范围</span><strong>仅供本人使用</strong></p><p><span>数据方式</span><strong>本地导出文件解析</strong></p></div></section><section className="card help-center"><b>帮助中心</b><small>常用功能的操作说明集中在这里；需要时展开查看。</small><details><summary>导入打印课表</summary><ol><li>在教务系统切换到目标学期，进入“学期理论课表”。</li><li>点击“打印”，将生成的课表保存为 <code>.xls</code> 文件。</li><li>回到课程表页，点击“导入打印课表文件”并选择该文件。文件中的学期会作为导入目标。</li><li>首次导入某学期后，请在“时间设置”中配置该学期第一周的星期一，系统才会生成准确日期。</li></ol></details><details><summary>导入成绩分析</summary><ol><li>在教务系统中打开目标学期的成绩页面，并使用页面提供的导出或打印功能保存 <code>.xls</code> 或 HTML 文件。</li><li>在“成绩分析”页面选择目标学期（如文件内没有学期信息），点击“导入成绩文件”。</li><li>系统先展示题目、成绩、学分和绩点预览。请检查并修正后，再点击“确认导入成绩”。</li><li>确认后会替换该学期的旧成绩缓存；上传原文件不会长期保存。</li></ol></details><details><summary>使用 AI 成绩分析</summary><ol><li>先在“设置 → 成绩分析设置”填写 HTTPS OpenAI 兼容服务、模型名与 API Key。</li><li>首次使用前，服务端管理员还需在环境变量中设置 <code>AI_CREDENTIAL_MASTER_KEY</code>。</li><li>回到“成绩分析”页，选定已导入成绩的学期后点击“生成分析”。</li><li>只有课程名称、成绩、学分、绩点和考试字段会被发送给你配置的模型服务；同一份成绩默认复用缓存。</li></ol></details><details><summary>时间与个性化设置</summary><ol><li>“时间设置”可配置每个学期第一周的周一，以及各节课的上、下课时间。</li><li>“个性化设置”可修改首页显示姓名并上传头像；头像仅保存到自己的后端。</li></ol></details></section><section className="card settings-card"><b>隐私与安全</b><small>登录令牌不会展示在页面或日志中。课程、成绩和头像数据仅保存在你配置的后端与本地缓存中；上传的原始教务文件仅用于当次解析。</small></section></>}
    {logoutConfirm && <ConfirmDialog title="确认退出航的助手？" description="退出后将返回登录页。已导入的课程表、成绩缓存和自定义安排都会保留。" confirmLabel="确认退出" pending={appLogout.isPending} onCancel={() => setLogoutConfirm(false)} onConfirm={() => appLogout.mutate()} />}
  </Page>;
}

function TermStartDateEditor({ term, onSaved }: { term: Term; onSaved: () => void }) {
  const [value, setValue] = useState<Date | null>(term.start_date ? dateFromKey(term.start_date) : null);
  useEffect(() => setValue(term.start_date ? dateFromKey(term.start_date) : null), [term.id, term.start_date]);
  const save = useMutation({ mutationFn: () => api.updateTermStartDate(term.id, value ? localDateKey(value) : ''), onSuccess: onSaved });
  return <form className="settings-row" onSubmit={(event) => { event.preventDefault(); save.mutate(); }}><label>第一周周一<DatePicker selected={value} onChange={setValue} locale="zh-CN" dateFormat="yyyy 年 MM 月 dd 日" placeholderText="选择星期一" filterDate={(date) => date.getDay() === 1} showPopperArrow={false} required /></label><button type="submit" disabled={!value || save.isPending}>{save.isPending ? '保存中…' : '保存'}</button>{save.error && <span className="error">{save.error.message}</span>}</form>;
}

function PeriodTimeEditor({ period, onSaved }: { period: PeriodTime; onSaved: () => void }) {
  const [startTime, setStartTime] = useState(period.start_time);
  const [endTime, setEndTime] = useState(period.end_time);
  useEffect(() => { setStartTime(period.start_time); setEndTime(period.end_time); }, [period]);
  const save = useMutation({ mutationFn: () => api.updatePeriodTime(period.period_number, startTime, endTime), onSuccess: onSaved });
  return <form className="period-row" onSubmit={(event) => { event.preventDefault(); save.mutate(); }}><b>第 {period.period_number} 节</b><input aria-label={`第 ${period.period_number} 节上课时间`} type="time" value={startTime} onChange={(event) => setStartTime(event.target.value)} required /><span>至</span><input aria-label={`第 ${period.period_number} 节下课时间`} type="time" value={endTime} onChange={(event) => setEndTime(event.target.value)} required /><button type="submit" disabled={save.isPending}>{save.isPending ? '…' : '保存'}</button>{save.error && <span className="error">{save.error.message}</span>}</form>;
}

function Metric({ label, value }: { label: string; value: string | number }) { return <div><small>{label}</small><b>{value}</b></div>; }
function ManualCourseSheet({ initial, periods, pending, error, editing, onClose, onSave }: { initial: ManualCourseInput; periods: PeriodTime[]; pending: boolean; error: Error | null; editing: boolean; onClose: () => void; onSave: (payload: ManualCourseInput) => void }) {
  const [courseName, setCourseName] = useState(initial.course_name);
  const [weekExpression, setWeekExpression] = useState(initial.week_expression);
  const [weekday, setWeekday] = useState(initial.weekday);
  const [startPeriod, setStartPeriod] = useState(initial.start_period);
  const [endPeriod, setEndPeriod] = useState(initial.end_period);
  const [classroom, setClassroom] = useState(initial.classroom ?? '');
  const [teacher, setTeacher] = useState(initial.teacher ?? '');
  useEffect(() => { setCourseName(initial.course_name); setWeekExpression(initial.week_expression); setWeekday(initial.weekday); setStartPeriod(initial.start_period); setEndPeriod(initial.end_period); setClassroom(initial.classroom ?? ''); setTeacher(initial.teacher ?? ''); }, [initial]);
  const weekNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet manual-course-sheet" role="dialog" aria-modal="true" aria-label={editing ? '编辑手动课程' : '添加手动课程'} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{editing ? '编辑课程' : '添加课程'}</h2><button type="button" onClick={onClose} disabled={pending}>关闭</button></header><p className="muted">课程会保存到当前学期，不会被教务系统同步或打印课表导入覆盖。</p><form onSubmit={(event) => { event.preventDefault(); onSave({ term_id: initial.term_id, course_name: courseName.trim(), week_expression: weekExpression.trim(), weekday, start_period: startPeriod, end_period: endPeriod, classroom: classroom.trim() || null, teacher: teacher.trim() || null }); }}><label>课程名称<input aria-label="课程名称" value={courseName} onChange={(event) => setCourseName(event.target.value)} maxLength={255} required placeholder="例如：课程作业答疑" /></label><label>上课周次<input aria-label="上课周次" value={weekExpression} onChange={(event) => setWeekExpression(event.target.value)} maxLength={255} required placeholder="例如：1-18周、1,3,5周、1-16周(单)" /></label><div className="manual-course-grid"><label>星期<select aria-label="上课星期" value={weekday} onChange={(event) => setWeekday(Number(event.target.value))}>{weekNames.map((name, index) => <option value={index + 1} key={name}>{name}</option>)}</select></label><label>开始节次<select aria-label="开始节次" value={startPeriod} onChange={(event) => setStartPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.start_time}</option>)}</select></label><label>结束节次<select aria-label="结束节次" value={endPeriod} onChange={(event) => setEndPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.end_time}</option>)}</select></label></div><label>教室地点<input aria-label="教室地点" value={classroom} onChange={(event) => setClassroom(event.target.value)} maxLength={255} placeholder="可留空" /></label><label>任课教师<input aria-label="任课教师" value={teacher} onChange={(event) => setTeacher(event.target.value)} maxLength={255} placeholder="可留空" /></label><small>保存后会按设置中的学期第一周周一和节次时间，自动生成每周课表日期。</small><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={pending}>取消</button><button type="submit" disabled={pending || !courseName.trim() || !weekExpression.trim()}>{pending ? '保存中…' : '保存课程'}</button></div>{error && <p className="error">{error.message}</p>}</form></section></div>;
}

const MANUAL_COURSE_MAX_WEEKS = 20;

function parseManualCourseWeeks(expression: string): number[] {
  const weeks = new Set<number>();
  const parts = expression.replace(/[，、]/g, ',').match(/\d+(?:\s*-\s*\d+)?/g) ?? [];
  parts.forEach((part) => {
    const [fromText, toText] = part.split('-').map((value) => value.trim());
    const from = Number(fromText);
    const to = Number(toText ?? fromText);
    if (!Number.isInteger(from) || !Number.isInteger(to)) return;
    for (let week = Math.max(1, Math.min(from, to)); week <= Math.min(MANUAL_COURSE_MAX_WEEKS, Math.max(from, to)); week += 1) weeks.add(week);
  });
  return [...weeks].sort((left, right) => left - right);
}

function manualCourseWeekExpression(weeks: Iterable<number>) {
  return `${[...new Set(weeks)].filter((week) => Number.isInteger(week) && week >= 1 && week <= MANUAL_COURSE_MAX_WEEKS).sort((left, right) => left - right).join(',')}周`;
}

function ManualWeekPicker({ selected, onClose, onConfirm, dark = false }: { selected: Set<number>; onClose: () => void; onConfirm: (weeks: Set<number>) => void; dark?: boolean }) {
  const [draft, setDraft] = useState(() => new Set(selected));
  const [notice, setNotice] = useState<string | null>(null);
  const setPattern = (weeks: number[]) => { setDraft(new Set(weeks)); setNotice(null); };
  const toggleWeek = (week: number) => {
    if (!draft.has(week) && draft.size >= MANUAL_COURSE_MAX_WEEKS) { setNotice('最多只能选择 20 周'); return; }
    setDraft((current) => {
      const next = new Set(current);
      if (next.has(week)) next.delete(week); else next.add(week);
      return next;
    });
    setNotice(null);
  };
  const confirm = () => {
    if (!draft.size) { setNotice('请至少选择一个上课周次'); return; }
    onConfirm(new Set(draft));
  };
  const allWeeks = Array.from({ length: MANUAL_COURSE_MAX_WEEKS }, (_, index) => index + 1);
  return <div className={`sheet-mask sheet-mask-viewport manual-week-picker-mask${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={onClose}><section className="detail-sheet manual-week-picker" role="dialog" aria-modal="true" aria-label="选择上课周次" onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><button type="button" onClick={onClose}>取消</button><h2>上课周次</h2><button type="button" onClick={confirm}>完成</button></header><div className="manual-week-tools"><button type="button" onClick={() => setPattern(allWeeks)}>全选</button><button type="button" onClick={() => setPattern(allWeeks.filter((week) => week % 2 === 1))}>单周</button><button type="button" onClick={() => setPattern(allWeeks.filter((week) => week % 2 === 0))}>双周</button><button type="button" onClick={() => setPattern([])}>清空</button></div><p className="manual-week-summary">{notice ?? `已选择 ${draft.size} / ${MANUAL_COURSE_MAX_WEEKS} 周`}</p><div className="manual-week-grid">{allWeeks.map((week) => <button type="button" key={week} aria-label={`第 ${week} 周`} aria-pressed={draft.has(week)} className={draft.has(week) ? 'selected' : ''} onClick={() => toggleWeek(week)}>{week}</button>)}</div></section></div>;
}

function ManualCourseSheetV2({ initial, periods, pending, error, editing, dark = false, onClose, onSave }: { initial: ManualCourseInput; periods: PeriodTime[]; pending: boolean; error: Error | null; editing: boolean; dark?: boolean; onClose: () => void; onSave: (payload: ManualCourseInput) => void }) {
  const [courseName, setCourseName] = useState(initial.course_name);
  const [selectedWeeks, setSelectedWeeks] = useState(() => new Set(parseManualCourseWeeks(initial.week_expression)));
  const [weekPickerOpen, setWeekPickerOpen] = useState(false);
  const [weekday, setWeekday] = useState(initial.weekday);
  const [startPeriod, setStartPeriod] = useState(initial.start_period);
  const [endPeriod, setEndPeriod] = useState(initial.end_period);
  const [classroom, setClassroom] = useState(initial.classroom ?? '');
  const [teacher, setTeacher] = useState(initial.teacher ?? '');
  useEffect(() => {
    setCourseName(initial.course_name);
    setSelectedWeeks(new Set(parseManualCourseWeeks(initial.week_expression)));
    setWeekPickerOpen(false);
    setWeekday(initial.weekday);
    setStartPeriod(initial.start_period);
    setEndPeriod(initial.end_period);
    setClassroom(initial.classroom ?? '');
    setTeacher(initial.teacher ?? '');
  }, [initial]);
  const weekNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  const selectedWeekText = [...selectedWeeks].sort((left, right) => left - right).join('、');
  return createPortal(<><div className={`sheet-mask sheet-mask-viewport${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet manual-course-sheet" role="dialog" aria-modal="true" aria-label={editing ? '编辑手动课程' : '添加手动课程'} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{editing ? '编辑课程' : '添加课程'}</h2><button type="button" onClick={onClose} disabled={pending}>关闭</button></header><p className="muted">课程会保存到当前学期，不会被教务系统同步或打印课表导入覆盖。</p><form onSubmit={(event) => { event.preventDefault(); if (!selectedWeeks.size) return; onSave({ term_id: initial.term_id, course_name: courseName.trim(), week_expression: manualCourseWeekExpression(selectedWeeks), weekday, start_period: startPeriod, end_period: endPeriod, classroom: classroom.trim() || null, teacher: teacher.trim() || null }); }}><label>课程名称<input aria-label="课程名称" value={courseName} onChange={(event) => setCourseName(event.target.value)} maxLength={255} required placeholder="例如：课程作业答疑" /></label><label>上课周次<button type="button" className="manual-week-trigger" aria-label="选择上课周次" onClick={() => setWeekPickerOpen(true)}><span>{selectedWeekText ? `第 ${selectedWeekText} 周` : '请选择上课周次'}</span><ChevronRight size={18} /></button></label><div className="manual-course-grid"><label>星期<select aria-label="上课星期" value={weekday} onChange={(event) => setWeekday(Number(event.target.value))}>{weekNames.map((name, index) => <option value={index + 1} key={name}>{name}</option>)}</select></label><label>开始节次<select aria-label="开始节次" value={startPeriod} onChange={(event) => setStartPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.start_time}</option>)}</select></label><label>结束节次<select aria-label="结束节次" value={endPeriod} onChange={(event) => setEndPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.end_time}</option>)}</select></label></div><label>教室地点<input aria-label="教室地点" value={classroom} onChange={(event) => setClassroom(event.target.value)} maxLength={255} placeholder="可留空" /></label><label>任课教师<input aria-label="任课教师" value={teacher} onChange={(event) => setTeacher(event.target.value)} maxLength={255} placeholder="可留空" /></label><small>保存后会按设置中的学期第一周周一和节次时间，自动生成每周课表日期。</small><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={pending}>取消</button><button type="submit" disabled={pending || !courseName.trim() || !selectedWeeks.size}>{pending ? '保存中…' : '保存课程'}</button></div>{error && <p className="error">{error.message}</p>}</form></section></div>{weekPickerOpen && <ManualWeekPicker selected={selectedWeeks} dark={dark} onClose={() => setWeekPickerOpen(false)} onConfirm={(weeks) => { setSelectedWeeks(weeks); setWeekPickerOpen(false); }} />}</>, document.body);
}

function Detail({ label, value }: { label: string; value: string }) { return <p><small>{label}</small><span>{value}</span></p>; }
function DetailSheet({ title, children, onClose, dark = false }: { title: string; children: React.ReactNode; onClose: () => void; dark?: boolean }) {
  return createPortal(<div className={`sheet-mask sheet-mask-viewport${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={onClose}><section className="detail-sheet" role="dialog" aria-modal="true" aria-label={title} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{title}</h2><button type="button" aria-label="关闭详情" onClick={onClose}>关闭</button></header>{children}</section></div>, document.body);
}
function ConfirmDialog({ title, description, confirmLabel, pending, onCancel, onConfirm }: { title: string; description: string; confirmLabel: string; pending: boolean; onCancel: () => void; onConfirm: () => void }) { return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onCancel}><section className="confirm-dialog" role="dialog" aria-modal="true" aria-label={title} onClick={(event) => event.stopPropagation()}><h2>{title}</h2><p>{description}</p><div><button type="button" className="secondary-button" disabled={pending} onClick={onCancel}>取消</button><button type="button" className="logout-button" disabled={pending} onClick={onConfirm}>{pending ? '正在退出…' : confirmLabel}</button></div></section></div>; }
function Empty({ text }: { text: string }) { return <div className="empty">{text}</div>; }
function Page({ title, children, action, icon, className, headerClassName, headerStyle, compactTitle, mainRef }: { title: string; children: React.ReactNode; action?: React.ReactNode; icon?: React.ReactNode; className?: string; headerClassName?: string; headerStyle?: CSSProperties; compactTitle?: boolean; mainRef?: RefObject<HTMLElement> }) { return <main ref={mainRef} className={className}><header className={headerClassName} style={headerStyle}>{compactTitle && icon && <span className="page-fixed-title-icon" aria-hidden="true">{icon}</span>}<h1 className="page-title">{!compactTitle && icon && <span className="page-title-icon" aria-hidden="true">{icon}</span>}{title}</h1>{compactTitle && <span className="page-title-compact" aria-hidden="true">{title}</span>}{action}</header>{children}</main>; }

function Login({ onSuccess }: { onSuccess: () => void }) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const login = useMutation({ mutationFn: () => api.login(username, password), onSuccess });
  return <main className="login">
    <section className="login-card" aria-labelledby="login-title">
      <div className="login-logo"><img src="/pwa-192.png" alt="航的助手" width="80" height="80" /></div>
      <h1 className="login-title" id="login-title">航的助手</h1>
      <p className="login-desc">输入管理员账号和密码以继续。</p>
      <form className="login-form" onSubmit={(event) => { event.preventDefault(); login.mutate(); }}>
        <input className="login-input" aria-label="用户名" value={username} onChange={(event) => setUsername(event.target.value)} autoComplete="username" autoFocus required placeholder="用户名" />
        <input className="login-input" aria-label="密码" value={password} onChange={(event) => setPassword(event.target.value)} autoComplete="current-password" required type="password" placeholder="密码" />
        {login.error && <div className="login-error" role="alert">{login.error.message}</div>}
        <button className="login-btn" type="submit" disabled={login.isPending}>{login.isPending ? '...' : '登录'}</button>
      </form>
    </section>
  </main>;
}

function AuthGateLoading() {
  return <main className="login" aria-busy="true" aria-live="polite">
    <section className="login-card login-loading-card" aria-label="正在验证登录状态">
      <div className="login-logo"><img src="/pwa-192.png" alt="航的助手" width="80" height="80" /></div>
      <h1 className="login-title">航的助手</h1>
      <p className="login-desc">正在安全验证登录状态…</p>
      <span className="auth-loading-spinner" aria-hidden="true" />
    </section>
  </main>;
}

const PRIMARY_ROUTE_ORDER = ['/', '/timetable', '/grades', '/settings'];

function primaryRouteIndex(pathname: string) {
  const index = PRIMARY_ROUTE_ORDER.indexOf(pathname);
  return index < 0 ? 0 : index;
}

/**
 * 只让新页面入场，避免同时保留两份课程表 DOM 导致横向滚动、弹窗或中端设备性能受影响。
 * Dock 的五个目的地是平级的，故可根据它们的固定顺序决定翻页方向。
 */
function PrimaryRouteTransition({ appearanceMode, resolvedAppearanceMode, onAppearanceModeChange }: {
  appearanceMode: AppearanceMode;
  resolvedAppearanceMode: 'light' | 'dark';
  onAppearanceModeChange: (mode: AppearanceMode) => void;
}) {
  const { pathname } = useLocation();
  const previousPathname = useRef(pathname);
  const currentIndex = primaryRouteIndex(pathname);
  const previousIndex = primaryRouteIndex(previousPathname.current);
  const direction = currentIndex < previousIndex ? 'backward' : 'forward';

  useEffect(() => {
    previousPathname.current = pathname;
  }, [pathname]);

  return <div key={pathname} className={`page-route-stage page-route-stage-${direction}`}>
    <Routes>
      <Route path="/" element={<Today appearance={resolvedAppearanceMode} />} />
      <Route path="/timetable" element={<Timetable appearance={resolvedAppearanceMode} />} />
      <Route path="/grades" element={<Grades appearance={resolvedAppearanceMode} />} />
      <Route path="/settings" element={<Settings appearanceMode={appearanceMode} resolvedAppearanceMode={resolvedAppearanceMode} onAppearanceModeChange={onAppearanceModeChange} />} />
    </Routes>
  </div>;
}

export default function App() {
  const [authState, setAuthState] = useState<'checking' | 'authenticated' | 'unauthenticated'>('checking');
  const navigate = useNavigate();
  const location = useLocation();
  const [appearanceMode, setAppearanceMode] = useState<AppearanceMode>(savedAppearanceMode);
  const resolvedAppearanceMode = useResolvedAppearanceMode(appearanceMode);
  useEffect(() => { window.localStorage.setItem('appearance_mode', appearanceMode); }, [appearanceMode]);
  useEffect(() => {
    document.documentElement.dataset.appearance = resolvedAppearanceMode;
    document.querySelector('meta[name="theme-color"]')?.setAttribute(
      'content',
      resolvedAppearanceMode === 'dark' ? '#09111f' : '#f4f7fb',
    );
    void updateNativeStatusBar(resolvedAppearanceMode);
  }, [resolvedAppearanceMode]);
  useEffect(() => {
    let active = true;
    const markUnauthenticated = () => { if (active) setAuthState('unauthenticated'); };
    window.addEventListener('hand-helper:unauthenticated', markUnauthenticated);
    void api.me().then(() => { if (active) setAuthState('authenticated'); }).catch(markUnauthenticated);
    return () => { active = false; window.removeEventListener('hand-helper:unauthenticated', markUnauthenticated); };
  }, []);
  if (authState === 'checking') return <AuthGateLoading />;
  if (authState === 'unauthenticated') return <><NativeStartupNotice /><Routes><Route path="/login" element={<Login onSuccess={() => { setAuthState('authenticated'); navigate('/', { replace: true }); }} />} /><Route path="*" element={<Navigate to="/login" replace />} /></Routes></>;
  if (location.pathname === '/login') return <Navigate to="/" replace />;
  return <div className="shell"><NativeStartupNotice /><NetworkNotice /><PrimaryRouteTransition appearanceMode={appearanceMode} resolvedAppearanceMode={resolvedAppearanceMode} onAppearanceModeChange={setAppearanceMode} /><BottomNav appearance={resolvedAppearanceMode} /></div>;
}

/** Android 启动时以轻量提示替代系统默认的应用图标动画。 */
function NativeStartupNotice() {
  const [phase, setPhase] = useState<'visible' | 'leaving' | 'hidden'>(() => Capacitor.isNativePlatform() ? 'visible' : 'hidden');
  useEffect(() => {
    if (!Capacitor.isNativePlatform()) return;
    const leaveTimer = window.setTimeout(() => setPhase('leaving'), 650);
    const hideTimer = window.setTimeout(() => setPhase('hidden'), 900);
    return () => { window.clearTimeout(leaveTimer); window.clearTimeout(hideTimer); };
  }, []);
  if (phase === 'hidden') return null;
  return <div className={`native-startup${phase === 'leaving' ? ' is-leaving' : ''}`} role="status" aria-live="polite"><span className="native-startup-spinner" aria-hidden="true" /><p>正在连接服务器</p></div>;
}

function NetworkNotice() {
  const [online, setOnline] = useState(() => navigator.onLine);
  useEffect(() => {
    const markOnline = () => setOnline(true);
    const markOffline = () => setOnline(false);
    window.addEventListener('online', markOnline);
    window.addEventListener('offline', markOffline);
    return () => {
      window.removeEventListener('online', markOnline);
      window.removeEventListener('offline', markOffline);
    };
  }, []);
  return online ? null : <div className="native-offline-banner" role="status">当前离线，已缓存的数据仍可查看。</div>;
}

function BottomNav({ appearance }: { appearance: 'light' | 'dark' }) {
  const { pathname } = useLocation();
  const profile = useQuery({ queryKey: ['profile'], queryFn: api.profile, staleTime: 5 * 60 * 1000 });
  const activeIndex = pathname === '/timetable' ? 1 : pathname === '/grades' ? 2 : pathname === '/settings' ? 3 : 0;
  // 底部四个栏目是平级目的地：切换时替换当前历史项，Android 返回键不会在栏目之间倒退。
  const avatar = profile.data?.avatar_data_url;
  return <nav className={`glass-nav four-nav${appearance === 'dark' ? ' nav-dark' : ''}`} style={{ '--nav-active-offset': `${activeIndex * 100}%` } as CSSProperties}><span className="nav-glass" /><span className="nav-active-pill" /><NavLink replace to="/">{avatar ? <img className="nav-home-avatar" src={avatar} alt="" aria-hidden="true" /> : <Home />}今日</NavLink><NavLink replace to="/timetable"><CalendarDays />课程表</NavLink><NavLink replace to="/grades"><GraduationCap />分析</NavLink><NavLink replace to="/settings"><SettingsIcon />设置</NavLink></nav>;
}

