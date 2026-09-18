import { useEffect, useRef, useState, type CSSProperties, type RefObject } from 'react';
import { createPortal } from 'react-dom';
import ReactMarkdown from 'react-markdown';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Capacitor } from '@capacitor/core';
import Cropper, { type Area } from 'react-easy-crop';
import { CalendarDays, ChevronLeft, ChevronRight, Clock3, Database, GraduationCap, Home, Info, KeyRound, Monitor, Moon, Palette, Pencil, Plus, Settings as SettingsIcon, Smartphone, Sun, Trash2, Upload, X } from 'lucide-react';
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { api, AiProviderSettingInput, CustomSchedule, CustomScheduleInput, Grade, GradeAiAnalysis, GradeAiAnalysisHistory, GradeImportPreview, ManualCourseInput, PeriodTime, Profile, ProfileUpdate, Session, Term } from './api';
import { updateNativeStatusBar } from './native-runtime';

const formatTime = (value: string) => new Date(value).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
const DEFAULT_PERIOD_VALUES: Array<[number, string, string]> = [[1, '08:30', '09:15'], [2, '09:20', '10:05'], [3, '10:25', '11:10'], [4, '11:15', '12:00'], [5, '13:40', '14:25'], [6, '14:30', '15:15'], [7, '15:30', '16:15'], [8, '16:30', '17:15'], [9, '17:20', '18:05'], [10, '18:20', '19:05'], [11, '19:10', '19:55'], [12, '20:00', '20:45'], [13, '20:50', '21:35']];
const DEFAULT_PERIODS: PeriodTime[] = DEFAULT_PERIOD_VALUES.map(([period_number, start_time, end_time]) => ({ period_number, start_time, end_time }));
const APP_VERSION = import.meta.env.VITE_APP_VERSION ?? '0.2.0';
type AppearanceMode = 'light' | 'dark' | 'system';
type LayoutMode = 'auto' | 'mobile' | 'desktop';
const WEEKDAY_LABELS = ['一', '二', '三', '四', '五', '六', '日'];
const AVATAR_INPUT_MAX_BYTES = 15_000_000;
const AVATAR_INPUT_MAX_PIXELS = 25_000_000;
const AVATAR_OUTPUT_MAX_BYTES = 1_000_000;
const localDateKey = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
const dateFromKey = (value: string) => new Date(`${value}T12:00:00`);
function mondayOf(date: Date) { const result = new Date(date); result.setHours(12, 0, 0, 0); result.setDate(result.getDate() - ((result.getDay() + 6) % 7)); return result; }
function addDays(date: Date, days: number) { const result = new Date(date); result.setDate(result.getDate() + days); return result; }

function loadImage(source: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error('无法读取该图片，请换一张后重试。'));
    image.src = source;
  });
}

function canvasToJpeg(canvas: HTMLCanvasElement, quality: number): Promise<Blob> {
  return new Promise((resolve, reject) => canvas.toBlob((blob) => blob ? resolve(blob) : reject(new Error('头像处理失败，请换一张图片后重试。')), 'image/jpeg', quality));
}

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(new Error('头像处理失败，请重试。'));
    reader.readAsDataURL(blob);
  });
}

async function createCroppedAvatar(source: string, area: Area): Promise<string> {
  const image = await loadImage(source);
  const exportOptions = [[512, .92], [512, .82], [448, .86], [384, .9], [320, .9]] as const;
  for (const [size, quality] of exportOptions) {
    const canvas = document.createElement('canvas');
    canvas.width = size;
    canvas.height = size;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('当前浏览器不支持头像裁剪。');
    context.fillStyle = '#f8fafc';
    context.fillRect(0, 0, size, size);
    context.drawImage(image, area.x, area.y, area.width, area.height, 0, 0, size, size);
    const blob = await canvasToJpeg(canvas, quality);
    if (blob.size <= AVATAR_OUTPUT_MAX_BYTES) return blobToDataUrl(blob);
  }
  throw new Error('裁剪后的头像仍超过 1 MB，请缩小选区或换一张图片。');
}

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
  const headerRef = useRef<HTMLElement>(null);
  useEffect(() => {
    const container = scrollRef.current;
    const header = headerRef.current;
    if (!container || !header) return;
    let frame: number | null = null;
    let previousProgress = -1;
    const update = () => {
      frame = null;
      // 顶部留出一个小的归零区，避免移动端回弹时留下半透明标题残影。
      const progress = container.scrollTop < 8 ? 0 : Math.min(1, Math.max(0, container.scrollTop / 72));
      if (progress === previousProgress) return;
      previousProgress = progress;
      const compactProgress = Math.max(0, (progress - 0.34) / 0.66);
      // 直接更新标题这一小块的 CSS 变量；不能在滚动帧内 setState，
      // 否则会让课程格、卡片等整个页面子树随手势重复渲染。
      header.style.setProperty('--timetable-large-title-opacity', String(Math.max(0, 1 - progress / 0.68)));
      header.style.setProperty('--timetable-large-title-scale', String(1 - progress * 0.07));
      header.style.setProperty('--timetable-large-title-y', `${progress * -6}px`);
      header.style.setProperty('--timetable-compact-title-opacity', String(compactProgress));
      header.style.setProperty('--timetable-compact-title-scale', String(0.86 + compactProgress * 0.14));
      header.style.setProperty('--timetable-compact-title-y', `${(1 - compactProgress) * 5}px`);
      header.style.setProperty('--timetable-action-scale', String(1 - progress * 0.1));
      header.style.setProperty('--timetable-action-y', `${progress * -3}px`);
      header.style.setProperty('--timetable-side-control-opacity', String(Math.max(0, 1 - progress / 0.45)));
      header.style.setProperty('--timetable-side-control-y', `${progress * -18}px`);
      header.dataset.sideControlsHidden = progress >= 0.55 ? 'true' : 'false';
      // 收拢完成后交回常规文字栅格化，避免 iOS 长时间保留动画合成层而发虚。
      header.dataset.titleSettled = progress === 1 ? 'true' : 'false';
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
  return { scrollRef, headerRef };
}

function savedAppearanceMode(): AppearanceMode {
  const stored = window.localStorage.getItem('appearance_mode');
  return stored === 'light' || stored === 'dark' || stored === 'system' ? stored : 'system';
}

function savedLayoutMode(): LayoutMode {
  const stored = window.localStorage.getItem('layout_mode');
  return stored === 'mobile' || stored === 'desktop' ? stored : 'auto';
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
  const sessions = useQuery({ queryKey: ['sessions'], queryFn: () => api.sessions() });
  const profile = useQuery({ queryKey: ['profile'], queryFn: api.profile });
  const now = new Date();
  const today = localDateKey(now);
  const customSchedules = useQuery({ queryKey: ['custom-schedules', today], queryFn: () => api.customSchedules(today) });
  const [editingSchedule, setEditingSchedule] = useState<CustomSchedule | 'new' | null>(null);
  const [avatarPreviewOpen, setAvatarPreviewOpen] = useState(false);
  useEffect(() => {
    if (avatarPreviewOpen) document.documentElement.dataset.avatarPreview = 'open';
    else delete document.documentElement.dataset.avatarPreview;
    return () => { delete document.documentElement.dataset.avatarPreview; };
  }, [avatarPreviewOpen]);
  const saveSchedule = useMutation({
    mutationFn: (payload: CustomScheduleInput) => editingSchedule === 'new' ? api.createCustomSchedule(payload) : api.updateCustomSchedule(editingSchedule!.id, payload),
    onSuccess: () => { setEditingSchedule(null); queryClient.invalidateQueries({ queryKey: ['custom-schedules'] }); },
  });
  const deleteSchedule = useMutation({
    mutationFn: api.deleteCustomSchedule,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['custom-schedules'] }),
  });
  const items = (sessions.data ?? []).filter((item) => item.session_date === today);
  const name = profile.data?.display_name ?? '用户';
  // 只在首次取得首页所需数据前显示整页加载态。后续失效刷新会保留已显示的主页，避免闪屏。
  const loading = sessions.isLoading || profile.isLoading || customSchedules.isLoading;
  const pageError = sessions.error ?? profile.error ?? customSchedules.error;
  const retryPageData = () => { void Promise.all([sessions.refetch(), profile.refetch(), customSchedules.refetch()]); };
  if (loading) return <TodayBackendLoading appearance={appearance} />;
  if (pageError) return <TodayBackendLoadError appearance={appearance} error={pageError} onRetry={retryPageData} />;
  return <main className={`today-page${appearance === 'dark' ? ' today-page-dark' : ''}`}>
    <section className="today-hero">{profile.data?.avatar_data_url && <><div className="hero-avatar-background" aria-hidden="true" style={{ backgroundImage: `url(${profile.data.avatar_data_url})` }} /><div className="hero-avatar-overlay" aria-hidden="true" /></>}<div className="today-hero-content"><p className="today-kicker">今日 · {greetingForHour(now.getHours())}</p><h1>{name}</h1><p className="today-date">{now.toLocaleDateString('zh-CN', { month: 'long', day: 'numeric', weekday: 'long' })}</p></div>{profile.data?.avatar_data_url ? <button type="button" className="avatar-preview-trigger" aria-label={`预览${name}的头像`} onClick={() => setAvatarPreviewOpen(true)}><Avatar profile={profile.data} /></button> : <Avatar profile={profile.data} />}</section>
    <section className="today-content"><div className="today-section-heading"><h2>今日安排</h2><button type="button" className="add-schedule-button" onClick={() => setEditingSchedule('new')}><Plus size={17} />添加安排</button></div>{items.length || customSchedules.data?.length ? <Timeline sessions={items} schedules={customSchedules.data ?? []} onEdit={setEditingSchedule} onDelete={(schedule) => { if (window.confirm(`确认删除“${schedule.title}”吗？`)) deleteSchedule.mutate(schedule.id); }} /> : <Empty text="今天没有课程或自定义安排，享受自由时间。" />}</section>
    {editingSchedule && <CustomScheduleSheetV2 schedule={editingSchedule === 'new' ? undefined : editingSchedule} initialDate={today} pending={saveSchedule.isPending} error={saveSchedule.error} onClose={() => setEditingSchedule(null)} onSave={(payload) => saveSchedule.mutate(payload)} />}
    {avatarPreviewOpen && profile.data?.avatar_data_url && <AvatarPreviewSheet name={name} src={profile.data.avatar_data_url} dark={appearance === 'dark'} onClose={() => setAvatarPreviewOpen(false)} />}
  </main>;
}

function TodayBackendLoading({ appearance }: { appearance: 'light' | 'dark' }) {
  return <main className={`today-loading-page${appearance === 'dark' ? ' today-loading-page-dark' : ''}`} aria-busy="true" aria-live="polite"><div className="today-loading-indicator"><span className="today-loading-spinner" aria-hidden="true" /><p>后台正在加载…</p></div></main>;
}

function TodayBackendLoadError({ appearance, error, onRetry }: { appearance: 'light' | 'dark'; error: Error; onRetry: () => void }) {
  return <main className={`today-loading-page${appearance === 'dark' ? ' today-loading-page-dark' : ''}`}><section className="today-loading-error" role="alert"><b>首页加载失败</b><p>{error.message || '暂时无法读取后台数据。'}</p><button type="button" onClick={onRetry}>重新加载</button></section></main>;
}

function greetingForHour(hour: number) { if (hour < 10) return '早上好'; if (hour < 14) return '中午好'; if (hour < 18) return '下午好'; return '晚上好'; }
function Avatar({ profile, className = '' }: { profile: Profile | undefined; className?: string }) { const name = profile?.display_name ?? '用户'; return <div className={`user-avatar ${className}`}>{profile?.avatar_data_url ? <img src={profile.avatar_data_url} alt={`${name}的头像`} /> : <span>{name.slice(-1)}</span>}</div>; }
function AvatarPreviewSheet({ name, src, dark, onClose }: { name: string; src: string; dark: boolean; onClose: () => void }) {
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose(); };
    window.addEventListener('keydown', closeOnEscape);
    return () => window.removeEventListener('keydown', closeOnEscape);
  }, [onClose]);
  return createPortal(<div className={`sheet-mask sheet-mask-viewport avatar-preview-mask${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={onClose}><section className="avatar-preview-sheet" role="dialog" aria-modal="true" aria-label={`${name}的头像预览`} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><button type="button" aria-label="关闭头像预览" title="关闭" onClick={onClose}><X size={18} /></button></header><div className="avatar-preview-image-frame"><img src={src} alt={`${name}的头像大图`} /></div></section></div>, document.body);
}

function AvatarCropSheet({ source, dark, onClose, onConfirm }: { source: string; dark: boolean; onClose: () => void; onConfirm: (avatar: string) => void }) {
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [area, setArea] = useState<Area | null>(null);
  const [processing, setProcessing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const confirmCrop = async () => {
    if (!area) return;
    setProcessing(true);
    setError(null);
    try {
      onConfirm(await createCroppedAvatar(source, area));
    } catch (cropError) {
      setError(cropError instanceof Error ? cropError.message : '头像处理失败，请重试。');
      setProcessing(false);
    }
  };
  return createPortal(<div className={`sheet-mask sheet-mask-viewport avatar-crop-mask${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={processing ? undefined : onClose}><section className="avatar-crop-sheet" role="dialog" aria-modal="true" aria-label="裁剪头像" onClick={(event) => event.stopPropagation()}><header><div><h2>裁剪头像</h2><p>拖动图片调整位置，使用双指或滑条缩放。保存后将为 1:1 正方形头像。</p></div><button type="button" aria-label="关闭裁剪" onClick={onClose} disabled={processing}><X size={18} /></button></header><div className="avatar-crop-stage"><Cropper image={source} crop={crop} zoom={zoom} aspect={1} cropShape="rect" showGrid onCropChange={setCrop} onZoomChange={setZoom} onCropComplete={(_area, pixels) => setArea(pixels)} /></div><label className="avatar-zoom-control">缩放<input aria-label="头像缩放" type="range" min="1" max="3" step="0.01" value={zoom} onChange={(event) => setZoom(Number(event.target.value))} /></label><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={processing}>取消</button><button type="button" disabled={processing || !area} onClick={() => { void confirmCrop(); }}>{processing ? '处理中…' : '确认裁剪'}</button></div>{error && <p className="error">{error}</p>}</section></div>, document.body);
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
  const initialTitle = schedule?.title.trim() ?? '';
  const initialScheduledDate = schedule?.scheduled_date ?? initialDate;
  const initialScheduledTime = schedule?.scheduled_time ?? '09:00';
  const dirty = title.trim() !== initialTitle || scheduledDate !== initialScheduledDate || scheduledTime !== initialScheduledTime;
  const valid = Boolean(title.trim()) && scheduledDate >= initialDate;
  return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet custom-schedule-sheet" role="dialog" aria-modal="true" aria-label={schedule ? '编辑安排' : '添加安排'} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{schedule ? '编辑安排' : '添加安排'}</h2><button type="button" onClick={onClose} disabled={pending}>关闭</button></header><form onSubmit={(event) => { event.preventDefault(); if (!valid || !dirty) return; onSave({ title: title.trim(), scheduled_date: scheduledDate, scheduled_time: scheduledTime }); }}><div className="custom-schedule-settings-group"><label className="custom-schedule-settings-row custom-schedule-title-row"><span className="custom-schedule-settings-label">安排事项</span><input aria-label="安排事项名称" value={title} onChange={(event) => setTitle(event.target.value)} maxLength={200} required placeholder="例如：提交课程作业" /></label><label className="custom-schedule-settings-row custom-schedule-native-row"><span className="custom-schedule-settings-label">日期</span><span className="custom-schedule-settings-value">{formatScheduleDate(scheduledDate)}<ChevronRight size={18} aria-hidden="true" /></span><input aria-label="安排日期" type="date" min={initialDate} value={scheduledDate} onChange={(event) => setScheduledDate(event.target.value)} required /></label><label className="custom-schedule-settings-row custom-schedule-native-row"><span className="custom-schedule-settings-label">时间</span><span className="custom-schedule-settings-value">{scheduledTime}<ChevronRight size={18} aria-hidden="true" /></span><input aria-label="安排时间" type="time" value={scheduledTime} onChange={(event) => setScheduledTime(event.target.value)} required /></label></div><small className="custom-schedule-footer">只能添加今天及以后的安排；时间仅用于当天排序，不会触发系统通知。</small><button type="submit" className="custom-schedule-save" disabled={pending || !valid || !dirty}>{pending ? '保存中…' : '保存安排'}</button>{error && <p className="error">{error.message}</p>}</form></section></div>;
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
  return Object.fromEntries(courseNames.map((name) => {
    // 首帧和后续渲染使用同一套颜色，避免随机洗牌导致课程卡片闪色。
    let hash = 0;
    for (let index = 0; index < name.length; index += 1) hash = ((hash * 31) + name.charCodeAt(index)) >>> 0;
    return [name, COURSE_COLOR_CLASSES[hash % COURSE_COLOR_CLASSES.length]];
  }));
}
function readCourseColorMap(termId: number): Record<string, string> | null {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(courseColorStorageKey(termId)) ?? 'null');
    return parsed && typeof parsed === 'object' ? parsed as Record<string, string> : null;
  } catch { return null; }
}
function resolveCourseColorMap(term: Term, sessions: Session[]): Record<string, string> {
  const courseNames = new Set(sessions.map((session) => session.course_name));
  const saved = readCourseColorMap(term.id);
  return saved && [...courseNames].every((name) => saved[name]) ? saved : createCourseColorMap(sessions);
}

type TimetableSlot = { weekday: number; startPeriod: number; endPeriod: number };

function WeekCalendar({ sessions, term, periods, anchor, courseColors, selectedSessionId, onSelect, pendingSlot, onSelectSlot, onAddSlot }: { sessions: Session[]; term: Term | undefined; periods: PeriodTime[]; anchor: Date; courseColors: Record<string, string>; selectedSessionId: number | null; onSelect: (session: Session) => void; pendingSlot: TimetableSlot | null; onSelectSlot: (slot: TimetableSlot | null) => void; onAddSlot: (slot: TimetableSlot) => void }) {
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
          return <button type="button" className={`week-course ${session.source === 'MANUAL' ? 'manual-course-card' : ''} ${courseColors[session.course_name] ?? 'course-color-sky'} ${session.id === selectedSessionId ? 'is-detail-open' : ''}`} key={session.id} title={`${session.course_name} · ${session.classroom ?? '教室待定'} · ${session.teacher ?? '教师待定'}`} onClick={() => onSelect(session)} style={{ gridColumn: day + 2, gridRow: `${startPeriod + 1} / ${endPeriod + 2}` }}><b>{session.course_name}</b><small>{session.classroom ?? '教室待定'}</small><small>{session.teacher ?? '教师待定'}</small></button>;
        })}
      </div>
    </div>
  </section>;
}

function Timetable({ appearance }: { appearance: 'light' | 'dark' }) {
  const queryClient = useQueryClient();
  const { scrollRef: timetableScrollRef, headerRef: timetableHeaderRef } = useCollapsiblePageTitle();
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
    const next = resolveCourseColorMap(selectedTerm, sessions.data);
    const saved = readCourseColorMap(selectedTerm.id);
    const courseNames = new Set(sessions.data.map((session) => session.course_name));
    if (!saved || ![...courseNames].every((name) => saved[name])) localStorage.setItem(courseColorStorageKey(selectedTerm.id), JSON.stringify(next));
    setCourseColors(next);
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
  return <Page title="课程表" icon={<CalendarDays size={20} />} mainRef={timetableScrollRef} headerRef={timetableHeaderRef} className={`timetable-page${appearance === 'dark' ? ' timetable-page-dark' : ''}`} headerClassName="collapsible-page-header" compactTitle>
    <div className="week-tools"><button aria-label="上一周" onClick={() => setWeekAnchor((date) => moveWeekInTerm(date, -1, selectedTerm))}><ChevronLeft size={18} /></button><button type="button" onClick={() => setWeekAnchor(new Date())}>回到今天</button><button aria-label="下一周或开学周" title={selectedTerm?.start_date && mondayOf(weekAnchor) < mondayOf(dateFromKey(selectedTerm.start_date)) ? `跳到 ${selectedTerm.start_date} 开学周` : '下一周'} onClick={() => setWeekAnchor((date) => moveWeekInTerm(date, 1, selectedTerm))}><ChevronRight size={18} /></button></div>
{terms.isLoading ? <p className="muted">正在读取本地学期列表…</p> : terms.data?.length === 0 ? <Empty text="请导入教务系统打印的课程表文件，然后选择对应学期。" /> : <WeekCalendar sessions={sessions.data ?? []} term={selectedTerm} periods={periods.data ?? DEFAULT_PERIODS} anchor={weekAnchor} courseColors={selectedTerm && sessions.data ? resolveCourseColorMap(selectedTerm, sessions.data) : courseColors} selectedSessionId={selectedSession?.id ?? null} onSelect={(session) => { setPendingSlot(null); setSelectedSession(session); }} pendingSlot={pendingSlot} onSelectSlot={setPendingSlot} onAddSlot={(slot) => { if (!selectedTerm) return; setManualEditor({ initial: { term_id: selectedTerm.id, course_name: '', week_expression: `${Math.max(1, Math.floor((mondayOf(weekAnchor).getTime() - mondayOf(dateFromKey(selectedTerm.start_date ?? localDateKey(weekAnchor))).getTime()) / 604800000) + 1)}周`, weekday: slot.weekday, start_period: slot.startPeriod, end_period: slot.endPeriod, classroom: '', teacher: '' } }); }} />}
    {terms.error && <p className="error">读取本地课表失败：{String(terms.error)}</p>}
    <section className="timetable-management" aria-labelledby="timetable-management-heading"><h2 id="timetable-management-heading">课表管理</h2><div className="timetable-management-group"><label className="timetable-management-row timetable-management-native-row"><span className="timetable-management-label">当前学期</span><span className="timetable-management-value">{selectedTerm?.display_name ?? '选择学期'}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="选择当前学期" value={selected} disabled={!terms.data?.length} onChange={(event) => setTermId(event.target.value)}><option value="">选择学期</option>{terms.data?.map((term) => <option key={term.source_term_id} value={term.source_term_id}>{term.display_name}</option>)}</select></label><label className="timetable-management-row timetable-management-import-row"><span className="timetable-management-label">{fileImport.isPending ? '正在解析课表…' : '导入打印课表文件'}</span><span className="timetable-management-value"><ChevronRight size={18} aria-hidden="true" /></span><input aria-label="导入打印课表文件" type="file" accept=".xls,application/vnd.ms-excel" disabled={fileImport.isPending} onChange={(event) => { const file = event.target.files?.[0]; if (file) { fileImport.reset(); fileImport.mutate(file); } event.currentTarget.value = ''; }} /></label></div><p className="timetable-management-footer">支持教务系统导出的 .xls 打印课表文件。</p>{fileImportNotice && <p className="timetable-management-notice">{fileImportNotice}</p>}{fileImport.error && <p className="timetable-management-error" role="alert">导入失败：{fileImport.error.message}</p>}</section>
    {selectedSession && <DetailSheet title={selectedSession.course_name} dark={appearance === 'dark'} onClose={() => setSelectedSession(null)}><Detail label="上课时间" value={`${selectedSession.session_date} ${formatTime(selectedSession.start_datetime)}—${formatTime(selectedSession.end_datetime)}`} /><Detail label="教室" value={selectedSession.classroom ?? '未提供'} /><Detail label="教师" value={selectedSession.teacher ?? '未提供'} /><Detail label="周次" value={selectedSession.week_expression ?? '未提供'} />{selectedSession.source === 'MANUAL' && selectedSession.manual_course_id && <div className="manual-course-detail-actions"><small>手动添加课程</small><span><button type="button" onClick={() => { if (!selectedTerm) return; setSelectedSession(null); setManualEditor({ courseId: selectedSession.manual_course_id!, initial: { term_id: selectedSession.term_id ?? selectedTerm.id, course_name: selectedSession.course_name, teacher: selectedSession.teacher, classroom: selectedSession.classroom, weekday: selectedSession.weekday ?? (new Date(`${selectedSession.session_date}T12:00:00`).getDay() || 7), start_period: selectedSession.start_period ?? 1, end_period: selectedSession.end_period ?? 1, week_expression: selectedSession.week_expression ?? '' } }); }}>编辑</button><button type="button" className="danger-button" onClick={() => { if (window.confirm(`确认删除手动课程“${selectedSession.course_name}”吗？`)) deleteManualCourse.mutate(selectedSession.manual_course_id!); }}>删除</button></span></div>}</DetailSheet>}
    {manualEditor && <ManualCourseSheetV2 initial={manualEditor.initial} periods={periods.data ?? DEFAULT_PERIODS} pending={saveManualCourse.isPending} error={saveManualCourse.error} editing={Boolean(manualEditor.courseId)} dark={appearance === 'dark'} onClose={() => setManualEditor(null)} onSave={(payload) => saveManualCourse.mutate({ courseId: manualEditor.courseId, payload })} />}
  </Page>;
}

function AiAnalysisReport({ content }: { content: string }) {
  return <div className="grade-ai-markdown"><ReactMarkdown components={{ h2: ({ children }) => <h2>{children}</h2>, ul: ({ children }) => <ul>{children}</ul>, li: ({ children }) => <li>{children}</li>, p: ({ children }) => <p>{children}</p>, strong: ({ children }) => <strong>{children}</strong> }}>{content}</ReactMarkdown></div>;
}

function Grades({ appearance }: { appearance: 'light' | 'dark' }) {
  const queryClient = useQueryClient();
  const { scrollRef: gradesScrollRef, headerRef: gradesHeaderRef } = useCollapsiblePageTitle();
  const { terms } = useTerms();
  const [termId, setTermId] = useState('');
  const [importTermId, setImportTermId] = useState('');
  const [manualImportTermOpen, setManualImportTermOpen] = useState(false);
  const [selectedGrade, setSelectedGrade] = useState<Grade | null>(null);
  const [gradePreview, setGradePreview] = useState<GradeImportPreview | null>(null);
  const [analysis, setAnalysis] = useState<GradeAiAnalysis | null>(null);
  const [analysisDetailOpen, setAnalysisDetailOpen] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [deleteGradesConfirm, setDeleteGradesConfirm] = useState(false);
  const now = new Date();
  const academicYear = now.getMonth() >= 8 ? `${now.getFullYear()}-${now.getFullYear() + 1}-1` : `${now.getFullYear() - 1}-${now.getFullYear()}-2`;
  const selected = termId || terms.data?.find((term) => term.is_current)?.source_term_id || terms.data?.find((term) => term.source_term_id === academicYear)?.source_term_id || '';
  const selectedTerm = terms.data?.find((term) => term.source_term_id === selected);
  const grades = useQuery({ queryKey: ['grades', selectedTerm?.id], queryFn: () => api.grades(selectedTerm?.id) });
  const summary = useQuery({ queryKey: ['summary', selectedTerm?.id], queryFn: () => api.summary(selectedTerm?.id) });
  const analysisHistory = useQuery({ queryKey: ['grade-ai-analyses', selectedTerm?.id], queryFn: () => api.gradeAiAnalyses(selectedTerm?.id), enabled: Boolean(selectedTerm) });
  useEffect(() => { setAnalysis(null); setAnalysisDetailOpen(false); setHistoryOpen(false); setDeleteGradesConfirm(false); }, [selectedTerm?.id]);
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
      setAnalysisDetailOpen(true);
      await queryClient.invalidateQueries({ queryKey: ['grade-ai-analyses'] });
    },
  });
  const deleteGrades = useMutation({
    mutationFn: () => {
      if (!selectedTerm) throw new Error('请先选择一个学期');
      return api.deleteGrades(selectedTerm.id);
    },
    onSuccess: async () => {
      setDeleteGradesConfirm(false);
      setSelectedGrade(null);
      setAnalysis(null);
      setAnalysisDetailOpen(false);
      setHistoryOpen(false);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['grades'] }),
        queryClient.invalidateQueries({ queryKey: ['summary'] }),
        queryClient.invalidateQueries({ queryKey: ['grade-ai-analyses'] }),
      ]);
    },
  });
  return <Page title="成绩分析" icon={<GraduationCap size={20} />} mainRef={gradesScrollRef} headerRef={gradesHeaderRef} className={`grades-page${appearance === 'dark' ? ' grades-page-dark' : ''}`} headerClassName="collapsible-page-header" compactTitle>
    <section className="grade-import-actions" aria-label="成绩导入">
      <h2>成绩导入</h2>
      <div className="grade-import-group">
        <label className="grade-import-row grade-current-term-trigger">
          <span className="grade-import-row-content"><b>当前学期</b><small>选择要查看和导入成绩的学期</small></span>
          <span className="grade-current-term-value">{selectedTerm?.display_name ?? '选择学期'}<ChevronRight size={18} /></span>
          <select className="grade-current-term-native" aria-label="当前学期" value={selected} onChange={(event) => setTermId(event.target.value)}><option value="">选择学期</option>{terms.data?.map((term) => <option key={term.source_term_id} value={term.source_term_id}>{term.display_name}</option>)}</select>
        </label>
        <div className="grade-import-row grade-import-term-row">
          <span><b>导入文件学期</b><small>{manualImportTermOpen ? '文件未标明学期时，手动指定归属学期' : '默认从成绩文件中自动识别'}</small></span>
          <button type="button" className="grade-import-disclosure" aria-expanded={manualImportTermOpen} onClick={() => setManualImportTermOpen((open) => !open)}>{manualImportTermOpen ? '收起' : '手动指定'}<ChevronRight size={16} /></button>
        </div>
        {manualImportTermOpen && <label className="grade-import-term-input"><span>导入学期</span><input aria-label="成绩导入学期" value={importTermId} onChange={(event) => setImportTermId(event.target.value)} placeholder={selected || '例如：2025-2026-2'} pattern="20\\d{2}-20\\d{2}-[12]" maxLength={11} /></label>}
        {Boolean(selectedTerm && grades.data?.length) && <button type="button" className="grade-delete-button" onClick={() => { deleteGrades.reset(); setDeleteGradesConfirm(true); }}><Trash2 size={16} />删除本学期成绩</button>}
      </div>
      <label className="file-import-button grade-import-primary"><Upload size={18} />{previewImport.isPending ? '正在识别成绩…' : '从文件导入成绩'}<input type="file" accept=".xls,.html,.htm,application/vnd.ms-excel,text/html" disabled={previewImport.isPending} onChange={(event) => { const file = event.target.files?.[0]; if (file) { previewImport.reset(); previewImport.mutate(file); event.currentTarget.value = ''; } }} /></label>
      <small className="grade-import-footer">支持教务系统导出的 .xls 或 HTML 成绩文件；文件仅用于本次识别，不会保留原件。</small>
      {previewImport.error && <p className="error">识别失败：{previewImport.error.message}</p>}{deleteGrades.error && <p className="error">删除失败：{deleteGrades.error.message}</p>}
    </section>
    <section className="grade-overview" aria-label="成绩概览"><h2>成绩概览</h2><div className="grade-overview-grid"><Metric label="已获学分" value={summary.data?.earned_credits ?? '—'} /><Metric label="平均成绩" value={summary.data?.average_score?.toFixed(1) ?? '—'} /><Metric label="绩点" value={summary.data?.gpa?.toFixed(2) ?? '—'} /><Metric label="不及格" value={summary.data?.failed_courses ?? '—'} /></div></section>
    <section className="grade-ai-actions" aria-label="AI 成绩分析"><h2>AI 成绩分析</h2><div className="grade-ai-group"><button type="button" className="grade-ai-primary-row" disabled={!selectedTerm || analyze.isPending || (!analysis && !grades.data?.length)} onClick={() => { if (analysis) { setAnalysisDetailOpen(true); return; } analyze.reset(); analyze.mutate(false); }}><span><b>{analysis ? '查看 AI 成绩分析' : '生成 AI 成绩分析'}</b><small>{analysis ? '查看当前学期已生成的分析结果' : analyze.isPending ? '正在分析当前学期成绩…' : '基于当前学期成绩生成学习建议'}</small></span><span className="grade-ai-row-trailing">{analyze.isPending ? '分析中…' : <ChevronRight size={18} />}</span></button><button type="button" className="grade-ai-history-row" disabled={!selectedTerm} aria-expanded={historyOpen} onClick={() => setHistoryOpen((open) => !open)}><span><b>历史分析</b><small>{analysisHistory.data?.length ? `本学期共 ${analysisHistory.data.length} 条记录` : '查看本学期已生成的分析'}</small></span><ChevronRight size={18} /></button>{historyOpen && <GradeAiAnalysisHistoryPanel history={analysisHistory.data ?? []} loading={analysisHistory.isLoading} error={analysisHistory.error} onSelect={(entry) => { setAnalysis({ ...entry, cached: true }); setAnalysisDetailOpen(true); }} />}</div><small className="grade-ai-footer">仅在你点击生成后，将当前学期的课程名称、成绩、学分和绩点发送给已配置的模型服务。</small></section>
    {analyze.error && <p className="error">分析失败：{analyze.error.message}</p>}
    <section className="grade-list-section" aria-label="课程成绩"><h2>课程成绩</h2><div className="grade-list">{grades.data?.map((grade: Grade) => <button type="button" className={`grade-list-item${grade.id === selectedGrade?.id ? ' is-detail-open' : ''}`} key={grade.id} onClick={() => setSelectedGrade(grade)}><span className="grade-list-main"><b>{grade.course_name}</b><small>{grade.course_type ?? '课程性质未提供'} · {grade.credits ?? '—'} 学分 · GPA {grade.grade_point ?? '—'}</small></span><span className="grade-list-score"><small>成绩</small><b>{grade.score ?? '未公布'}</b></span></button>)}</div></section>
    {summary.data?.gpa_note && <small className="muted">{summary.data.gpa_note}</small>}
    {terms.error && <p className="error">读取成绩分析失败：{String(terms.error)}</p>}
    {analysis && analysisDetailOpen && <DetailSheet title="分析结果" dark={appearance === 'dark'} onClose={() => setAnalysisDetailOpen(false)}><div className="grade-ai-detail-meta"><small>{analysis.cached ? '已使用当前成绩快照的缓存结果' : `由 ${analysis.model} 生成`}</small><button type="button" className="secondary-button" disabled={analyze.isPending} onClick={() => { analyze.reset(); analyze.mutate(true); }}>{analyze.isPending ? '生成中…' : '重新生成'}</button></div><AiAnalysisReport content={analysis.content} /></DetailSheet>}
    {selectedGrade && <DetailSheet title={selectedGrade.course_name} dark={appearance === 'dark'} onClose={() => setSelectedGrade(null)}><Detail label="总评成绩" value={selectedGrade.score ?? '未公布'} /><Detail label="期末成绩" value={selectedGrade.final_exam_score ?? '未提供'} /><Detail label="平时成绩" value={selectedGrade.usual_score ?? '未提供'} /><Detail label="学分 / 绩点" value={`${selectedGrade.credits ?? '—'} / ${selectedGrade.grade_point ?? '—'}`} /><Detail label="课程性质" value={selectedGrade.course_type ?? '未提供'} /><Detail label="考试性质" value={selectedGrade.exam_type ?? '未提供'} /><Detail label="补考 / 重修" value={`${selectedGrade.makeup_flag ? '补考' : '否'} / ${selectedGrade.retake_flag ? '重修' : '否'}`} /></DetailSheet>}
    {gradePreview && <GradeImportSheet preview={gradePreview} pending={confirmImport.isPending} error={confirmImport.error} onClose={() => { if (!confirmImport.isPending) setGradePreview(null); }} onConfirm={(preview) => confirmImport.mutate(preview)} />}
    {deleteGradesConfirm && selectedTerm && <ConfirmDialog title={`删除 ${selectedTerm.display_name} 的成绩？`} description={`将删除该学期已导入的全部 ${grades.data?.length ?? 0} 门成绩，以及对应的 AI 分析缓存。此操作无法撤销，其他学期不会受影响。`} confirmLabel="确认删除" pending={deleteGrades.isPending} onCancel={() => setDeleteGradesConfirm(false)} onConfirm={() => deleteGrades.mutate()} />}
  </Page>;
}

function GradeAiAnalysisHistoryPanel({ history, loading, error, onSelect }: { history: GradeAiAnalysisHistory[]; loading: boolean; error: Error | null; onSelect: (entry: GradeAiAnalysisHistory) => void }) {
  return <div className="grade-ai-history" aria-live="polite">{loading ? <p className="muted">正在读取分析历史…</p> : error ? <p className="error">读取历史失败：{error.message}</p> : history.length ? <div className="grade-ai-history-list">{history.map((entry) => <button type="button" className="grade-ai-history-item" key={entry.id} onClick={() => onSelect(entry)}><span><b>{entry.model}</b><small>{new Date(entry.created_at).toLocaleString('zh-CN', { dateStyle: 'medium', timeStyle: 'short' })} · {entry.provider}</small></span><span>查看<ChevronRight size={16} /></span></button>)}</div> : <p className="muted">当前学期还没有可查看的历史分析。</p>}</div>;
}

function DataSettingsEntry({ onOpen }: { onOpen: () => void }) {
  return <button type="button" className="settings-menu-item" onClick={onOpen}><span><b><Database size={18} />数据与导入</b><small>本地课程表与成绩文件导入</small></span><span aria-hidden="true">›</span></button>;
}

function AiAnalysisSettings({ dark = false }: { dark?: boolean }) {
  const queryClient = useQueryClient();
  const settings = useQuery({ queryKey: ['ai-settings'], queryFn: api.aiSettings });
  const [provider, setProvider] = useState('APIKEY.FAN');
  const [baseUrl, setBaseUrl] = useState('https://api.apikey.fan/v1');
  const [model, setModel] = useState('');
  const [apiKey, setApiKey] = useState('');
  const [availableModels, setAvailableModels] = useState<string[]>([]);
  const [modelLookupNotice, setModelLookupNotice] = useState<string | null>(null);
  const [connectionNotice, setConnectionNotice] = useState<string | null>(null);
  useEffect(() => {
    if (!settings.data?.configured) return;
    setProvider(settings.data.provider ?? 'APIKEY.FAN');
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
  const migrateApikeyFan = useMutation({
    mutationFn: api.migrateApikeyFan,
    onSuccess: async (result) => {
      setProvider(result.provider ?? 'APIKEY.FAN');
      setBaseUrl(result.base_url ?? 'https://api.apikey.fan/v1');
      setModel(result.model ?? '');
      setAvailableModels(result.available_models);
      setModelLookupNotice(`已迁移到 APIKEY.FAN，并同步 ${result.available_models.length} 个可用模型。`);
      await queryClient.invalidateQueries({ queryKey: ['ai-settings'] });
    },
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
  const chooseApikeyFan = () => {
    setProvider('APIKEY.FAN');
    setBaseUrl('https://api.apikey.fan/v1');
    resetModelLookup();
  };
  const chooseModel = (nextModel: string) => {
    setModel(nextModel);
    setConnectionNotice(null);
    if (isSavedConfiguration && !isEditingSavedConfiguration) selectModel.mutate(nextModel);
  };
  const syncedLabel = settings.data?.models_synced_at ? `上次刷新：${new Date(settings.data.models_synced_at).toLocaleString('zh-CN', { dateStyle: 'medium', timeStyle: 'short' })}` : '模型列表尚未刷新';
  const legacyApikeyFun = Boolean(settings.data?.requires_apikey_fan_migration);
  const preset = legacyApikeyFun ? 'legacy-apikey-fun' : provider === 'APIKEY.FAN' && baseUrl === 'https://api.apikey.fan/v1' ? 'apikey-fan' : 'custom';
  const [editor, setEditor] = useState<'provider' | 'base-url' | 'api-key' | null>(null);
  const dirty = !isSavedConfiguration ? Boolean(apiKey.trim() || model.trim()) : Boolean(apiKey.trim()) || provider !== settings.data?.provider || baseUrl !== settings.data?.base_url || model !== settings.data?.model;
  const providerLabel = preset === 'apikey-fan' ? 'APIKEY.FAN' : preset === 'legacy-apikey-fun' ? '旧 APIKEY.FUN' : '自定义服务';
  const baseUrlLabel = baseUrl.replace(/^https?:\/\//, '').replace(/\/$/, '') || '未设置';
  const getModels = () => {
    if (isSavedConfiguration && !isEditingSavedConfiguration) refreshModels.mutate();
    else lookupModels.mutate();
  };
  const error = settings.error?.message ?? save.error?.message ?? lookupModels.error?.message ?? refreshModels.error?.message ?? migrateApikeyFan.error?.message ?? selectModel.error?.message ?? testConnection.error?.message ?? clear.error?.message;
  return <><form className="ai-settings-detail" onSubmit={(event) => { event.preventDefault(); save.mutate(); }}>
    <section className="ai-settings-section" aria-labelledby="ai-service-heading"><h2 id="ai-service-heading">模型服务</h2><div className="ai-settings-group">
      <label className="ai-settings-row ai-settings-native-row"><span className="ai-settings-label">服务预设</span><span className="ai-settings-value">{providerLabel}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="模型服务预设" value={preset} disabled={save.isPending} onChange={(event) => { if (event.target.value === 'apikey-fan') chooseApikeyFan(); }}><option value="apikey-fan">APIKEY.FAN</option>{legacyApikeyFun && <option value="legacy-apikey-fun" disabled>旧 APIKEY.FUN（待迁移）</option>}<option value="custom">其他 OpenAI 兼容服务</option></select></label>
      <button type="button" className="ai-settings-row" onClick={() => setEditor('provider')}><span className="ai-settings-label">服务名称</span><span className="ai-settings-value">{provider || '未设置'}<ChevronRight size={18} aria-hidden="true" /></span></button>
      <button type="button" className="ai-settings-row" onClick={() => setEditor('base-url')}><span className="ai-settings-label">服务地址</span><span className="ai-settings-value">{baseUrlLabel}<ChevronRight size={18} aria-hidden="true" /></span></button>
      <button type="button" className="ai-settings-row" onClick={() => setEditor('api-key')}><span className="ai-settings-label">API Key</span><span className="ai-settings-value">{apiKey ? '待保存' : isSavedConfiguration ? '已配置' : '未配置'}<ChevronRight size={18} aria-hidden="true" /></span></button>
    </div>{legacyApikeyFun && <section className="ai-provider-migration-note"><b>检测到旧 APIKEY.FUN 配置</b><small>迁移会使用已加密保存的 Key 验证 APIKEY.FAN 并同步模型。</small><button type="button" disabled={migrateApikeyFan.isPending || isEditingSavedConfiguration} onClick={() => migrateApikeyFan.mutate()}>{migrateApikeyFan.isPending ? '迁移中…' : '迁移到 APIKEY.FAN'}</button></section>}<p className="ai-settings-footer">API Key 仅以加密形式保存在后端。</p></section>
    <section className="ai-settings-section" aria-labelledby="ai-model-heading"><h2 id="ai-model-heading">模型</h2><div className="ai-settings-group">
      <label className="ai-settings-row ai-settings-native-row"><span className="ai-settings-label">当前模型</span><span className="ai-settings-value">{model || '请选择'}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="当前模型" value={model} disabled={!modelOptions.length || selectModel.isPending || save.isPending} onChange={(event) => chooseModel(event.target.value)}><option value="" disabled>{modelOptions.length ? '选择模型' : '请先获取模型列表'}</option>{modelOptions.map((modelId) => <option key={modelId} value={modelId}>{modelId}</option>)}</select></label>
      <button type="button" className="ai-settings-row" disabled={lookupModels.isPending || refreshModels.isPending || (isSavedConfiguration && !isEditingSavedConfiguration ? false : lookupIncomplete)} onClick={getModels}><span className="ai-settings-label">获取模型列表</span><span className="ai-settings-value">{lookupModels.isPending || refreshModels.isPending ? '获取中…' : ''}<ChevronRight size={18} aria-hidden="true" /></span></button>
      <button type="button" className="ai-settings-row" disabled={testConnection.isPending || incomplete} onClick={() => testConnection.mutate()}><span className="ai-settings-label">测试当前配置</span><span className="ai-settings-value">{testConnection.isPending ? '测试中…' : ''}<ChevronRight size={18} aria-hidden="true" /></span></button>
    </div>{(modelLookupNotice || connectionNotice) && <div className="ai-settings-feedback" aria-live="polite">{modelLookupNotice && <p className="ai-settings-notice">{modelLookupNotice}</p>}{connectionNotice && <p className="ai-settings-notice">{connectionNotice}</p>}</div>}<p className="ai-settings-footer">{syncedLabel}</p><button className="ai-settings-save" type="submit" disabled={!dirty || save.isPending || incomplete}>{save.isPending ? '正在保存…' : '保存配置'}</button></section>
    {isSavedConfiguration && <section className="ai-settings-section" aria-labelledby="ai-danger-heading"><h2 id="ai-danger-heading">危险操作</h2><div className="ai-settings-group"><button type="button" className="ai-settings-row ai-settings-destructive-row" disabled={clear.isPending} onClick={() => { if (window.confirm('确认清除已保存的模型服务配置吗？')) clear.mutate(); }}><span><b>清除模型服务配置</b><small>不会清除已导入的成绩或分析历史</small></span><ChevronRight size={18} aria-hidden="true" /></button></div></section>}
    {error && <p className="ai-settings-error" role="alert">{error}</p>}
  </form>{editor && <AiSettingsTextSheet kind={editor} value={editor === 'provider' ? provider : editor === 'base-url' ? baseUrl : apiKey} configured={isSavedConfiguration} apiKeyHint={settings.data?.api_key_hint ?? null} dark={dark} onClose={() => setEditor(null)} onConfirm={(value) => { if (editor === 'provider') { setProvider(value); resetModelLookup(); } else if (editor === 'base-url') { setBaseUrl(value); resetModelLookup(); } else { setApiKey(value); resetModelLookup(); } setEditor(null); }} />}</>;
}

function AiSettingsTextSheet({ kind, value, configured, apiKeyHint, dark, onClose, onConfirm }: { kind: 'provider' | 'base-url' | 'api-key'; value: string; configured: boolean; apiKeyHint: string | null; dark: boolean; onClose: () => void; onConfirm: (value: string) => void }) {
  const [draft, setDraft] = useState(value);
  const trimmed = draft.trim();
  const title = kind === 'provider' ? '服务名称' : kind === 'base-url' ? '服务地址' : 'API Key';
  const label = kind === 'provider' ? '服务名称' : kind === 'base-url' ? '服务地址' : 'API Key';
  const placeholder = kind === 'provider' ? '例如：APIKEY.FAN' : kind === 'base-url' ? 'https://api.example.com/v1' : configured ? `已配置 ${apiKeyHint ?? ''}；更换服务时重新填写` : '输入 API Key';
  const valid = kind === 'api-key' ? trimmed.length >= 8 : Boolean(trimmed);
  return <DetailSheet title={title} dark={dark} onClose={onClose}><form className="ai-text-editor" onSubmit={(event) => { event.preventDefault(); if (valid) onConfirm(trimmed); }}><label>{label}<input aria-label={label} type={kind === 'api-key' ? 'password' : kind === 'base-url' ? 'url' : 'text'} value={draft} onChange={(event) => setDraft(event.target.value)} maxLength={kind === 'provider' ? 64 : undefined} minLength={kind === 'api-key' ? 8 : undefined} autoComplete={kind === 'api-key' ? 'off' : undefined} autoFocus required placeholder={placeholder} /></label>{kind === 'api-key' && <small>密钥仅会在你保存配置时提交，并以加密形式保存在后端。</small>}<div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose}>取消</button><button type="submit" disabled={!valid}>完成编辑</button></div></form></DetailSheet>;
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
  return <><section className="ai-settings-section ai-history-settings-section" aria-labelledby="ai-history-heading"><h2 id="ai-history-heading">分析历史缓存</h2><p className="ai-settings-footer">保存生成的文字、时间和模型名称，便于回看。</p><div className="ai-settings-group"><button type="button" className="ai-settings-row ai-settings-destructive-row" disabled={clearHistory.isPending} onClick={() => setConfirmClear(true)}><span><b>{clearHistory.isPending ? '正在清除…' : '清除历史分析'}</b><small>不会影响成绩或模型服务配置</small></span><ChevronRight size={18} aria-hidden="true" /></button></div>{clearHistory.isSuccess && <p className="ai-settings-notice">已清除 {clearHistory.data.deleted} 条历史分析。</p>}{clearHistory.error && <p className="ai-settings-error" role="alert">清除失败：{clearHistory.error.message}</p>}</section><p className="ai-settings-page-footer">上传的原始成绩文件不会保留。</p>{confirmClear && <ConfirmDialog title="清除全部 AI 分析历史？" description="这会删除已保存的 AI 分析文字，无法恢复；课程、成绩和模型配置不会受到影响。" confirmLabel="确认清除" pending={clearHistory.isPending} onCancel={() => setConfirmClear(false)} onConfirm={() => clearHistory.mutate()} />}</>;
}

function HelpCenter() {
  return <section className="help-center" aria-labelledby="help-center-heading"><h2 id="help-center-heading">帮助中心</h2><div className="help-center-list">
    <details><summary>导入打印课表</summary><ol><li>在教务系统切换到目标学期，进入“学期理论课表”。</li><li>点击“打印”，将生成的课表保存为 <code>.xls</code> 文件。</li><li>回到课程表页，点击“导入打印课表文件”并选择该文件。文件中的学期会作为导入目标。</li><li>首次导入某学期后，请在“时间设置”中配置该学期第一周的星期一，系统才会生成准确日期。</li></ol></details>
    <details><summary>导入成绩分析</summary><ol><li>在教务系统中打开目标学期的成绩页面，并使用页面提供的导出或打印功能保存 <code>.xls</code> 或 HTML 文件。</li><li>在“成绩分析”页面选择目标学期（如文件内没有学期信息），点击“导入成绩文件”。</li><li>系统先展示题目、成绩、学分和绩点预览。请检查并修正后，再点击“确认导入成绩”。</li><li>确认后会替换该学期的旧成绩缓存；上传原文件不会长期保存。</li></ol></details>
    <details><summary>使用 AI 成绩分析</summary><ol><li>先在“设置 → 成绩分析设置”填写 HTTPS OpenAI 兼容服务、模型名与 API Key。</li><li>首次使用前，服务端管理员还需在环境变量中设置 <code>AI_CREDENTIAL_MASTER_KEY</code>。</li><li>回到“成绩分析”页，选定已导入成绩的学期后点击“生成分析”。</li><li>只有课程名称、成绩、学分、绩点和考试字段会被发送给你配置的模型服务；同一份成绩默认复用缓存。</li></ol></details>
    <details><summary>时间与个性化设置</summary><ol><li>“时间设置”可配置每个学期第一周的周一，以及各节课的上、下课时间。</li><li>“个性化设置”可修改首页显示姓名并上传头像；头像仅保存到自己的后端。</li></ol></details>
  </div><p className="help-center-footer">常用功能的操作说明集中在这里；需要时展开查看。</p></section>;
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

function LayoutModeSelector({ mode, onChange }: { mode: LayoutMode; onChange: (mode: LayoutMode) => void }) {
  const options = [
    { value: 'auto' as const, label: '跟随屏幕', icon: Monitor },
    { value: 'mobile' as const, label: '手机页面', icon: Smartphone },
    { value: 'desktop' as const, label: 'PC 页面', icon: Monitor },
  ];
  const activeIndex = options.findIndex((option) => option.value === mode);
  return <section className="card settings-card appearance-mode-card layout-mode-card"><b>页面布局</b><small>{mode === 'desktop' ? 'PC 页面仅在可用宽度足够时启用；窄屏会自动保持手机页面。' : '该偏好只保存在当前设备，不会影响其他设备。'}</small><div className="appearance-mode-switch" role="radiogroup" aria-label="页面布局"><span className="appearance-mode-indicator" style={{ transform: `translateX(${activeIndex * 100}%)` }} aria-hidden="true" />{options.map((option) => { const Icon = option.icon; const active = option.value === mode; return <button key={option.value} type="button" role="radio" aria-checked={active} className={active ? 'active' : ''} onClick={() => onChange(option.value)}><Icon size={17} />{option.label}</button>; })}</div></section>;
}

function Settings({ appearanceMode, resolvedAppearanceMode, onAppearanceModeChange, layoutMode, onLayoutModeChange }: { appearanceMode: AppearanceMode; resolvedAppearanceMode: 'light' | 'dark'; onAppearanceModeChange: (mode: AppearanceMode) => void; layoutMode: LayoutMode; onLayoutModeChange: (mode: LayoutMode) => void }) {
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { scrollRef: settingsScrollRef, headerRef: settingsHeaderRef } = useCollapsiblePageTitle();
  const profile = useQuery({ queryKey: ['profile'], queryFn: api.profile });
  const terms = useQuery({ queryKey: ['terms'], queryFn: api.terms });
  const periods = useQuery({ queryKey: ['period-times'], queryFn: api.periodTimes });
  const [selectedTermId, setSelectedTermId] = useState<number | null>(null);
  const [selectedPeriodNumber, setSelectedPeriodNumber] = useState<number | null>(null);
  const [logoutConfirm, setLogoutConfirm] = useState(false);
  const [settingsSection, setSettingsSection] = useState<'account' | 'time' | 'personal' | 'data' | 'analysis' | 'about' | null>(null);
  const [displayName, setDisplayName] = useState('用户');
  const [newAvatar, setNewAvatar] = useState<string | null | undefined>(undefined);
  const [avatarCropSource, setAvatarCropSource] = useState<string | null>(null);
  const [avatarError, setAvatarError] = useState<string | null>(null);
  const [avatarEditorOpen, setAvatarEditorOpen] = useState(false);
  const [nameEditorOpen, setNameEditorOpen] = useState(false);
  const preferredTerm = terms.data?.find((term) => term.source_term_id === currentAcademicTermId()) ?? terms.data?.find((term) => term.is_current) ?? terms.data?.[0];
  useEffect(() => { if (profile.data) setDisplayName(profile.data.display_name); }, [profile.data]);
  useEffect(() => () => { if (avatarCropSource) URL.revokeObjectURL(avatarCropSource); }, [avatarCropSource]);
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
    onSuccess: (updatedProfile) => { setDisplayName(updatedProfile.display_name); setNewAvatar(undefined); setAvatarError(null); queryClient.setQueryData(['profile'], updatedProfile); queryClient.invalidateQueries({ queryKey: ['profile'] }); },
  });
  const chooseAvatar = async (file: File | undefined) => {
    if (!file) return;
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) { setAvatarError('请选择 PNG、JPEG 或 WebP 格式的图片。'); return; }
    if (file.size > AVATAR_INPUT_MAX_BYTES) { setAvatarError('原图不能超过 15 MB。'); return; }
    const source = URL.createObjectURL(file);
    try {
      const image = await loadImage(source);
      if (image.naturalWidth * image.naturalHeight > AVATAR_INPUT_MAX_PIXELS) throw new Error('原图像素不能超过 2500 万，请换一张图片。');
      setAvatarCropSource(source);
      setAvatarError(null);
    } catch (imageError) {
      URL.revokeObjectURL(source);
      setAvatarError(imageError instanceof Error ? imageError.message : '无法读取该图片，请换一张后重试。');
    }
  };
  const sectionTitle = settingsSection === 'account' ? '账号安全' : settingsSection === 'time' ? '时间设置' : settingsSection === 'personal' ? '个性化设置' : settingsSection === 'data' ? '数据与导入' : settingsSection === 'analysis' ? '成绩分析设置' : settingsSection === 'about' ? '关于助手' : '设置';
  const accountTitleCollapsible = settingsSection === 'account';
  const sectionTitleCollapsible = Boolean(settingsSection);
  const settingsPageClassName = `${accountTitleCollapsible ? 'account-settings-page ' : ''}${sectionTitleCollapsible ? 'settings-section-page ' : ''}${resolvedAppearanceMode === 'dark' ? 'settings-page-dark' : ''}`.trim();
  const displayedProfile: Profile = { display_name: displayName.trim() || '用户', avatar_data_url: newAvatar === undefined ? profile.data?.avatar_data_url ?? null : newAvatar };
  const profileDirty = profile.data ? displayName.trim() !== profile.data.display_name || newAvatar !== undefined : false;
  return <Page title={sectionTitle} icon={accountTitleCollapsible ? <KeyRound size={20} /> : !settingsSection ? <SettingsIcon size={20} /> : undefined} action={settingsSection ? <button type="button" className="settings-back settings-back-ios" aria-label="返回设置" onClick={() => setSettingsSection(null)}><ChevronLeft size={18} />设置</button> : undefined} mainRef={settingsScrollRef} headerRef={settingsHeaderRef} className={settingsPageClassName} headerClassName={sectionTitleCollapsible ? 'collapsible-page-header settings-section-header settings-detail-header' : undefined} compactTitle={sectionTitleCollapsible}>
    {settingsSection === 'personal' && <p className="settings-inline-note">自定义显示模式、页面布局和个人资料。</p>}
    {settingsSection === 'data' && <p className="settings-inline-note">课程表和成绩仅通过你主动选择的导出文件导入，并保存在本地缓存中。</p>}
    {!settingsSection && <section className="settings-menu" aria-label="设置项目录">
      <section className="settings-menu-group" aria-labelledby="settings-group-account">
        <h2 id="settings-group-account">账户</h2>
        <div className="settings-menu-group-list">
          <button type="button" className="settings-menu-item" onClick={() => setSettingsSection('account')}><span><b><KeyRound size={18} />账号安全</b><small>单用户登录与退出</small></span><span aria-hidden="true">›</span></button>
        </div>
      </section>
      <section className="settings-menu-group" aria-labelledby="settings-group-preferences">
        <h2 id="settings-group-preferences">偏好设置</h2>
        <div className="settings-menu-group-list">
          <button type="button" className="settings-menu-item" onClick={() => setSettingsSection('time')}><span><b><Clock3 size={18} />时间设置</b><small>学期第一周与节次时间</small></span><span aria-hidden="true">›</span></button>
          <button type="button" className="settings-menu-item" onClick={() => setSettingsSection('personal')}><span><b><Palette size={18} />个性化设置</b><small>显示姓名与首页头像</small></span><span aria-hidden="true">›</span></button>
        </div>
      </section>
      <section className="settings-menu-group" aria-labelledby="settings-group-data">
        <h2 id="settings-group-data">数据与助手</h2>
        <div className="settings-menu-group-list">
          <DataSettingsEntry onOpen={() => setSettingsSection('data')} />
          <button type="button" className="settings-menu-item" onClick={() => setSettingsSection('analysis')}><span><b><GraduationCap size={18} />成绩分析设置</b><small>第三方模型服务与 API Key</small></span><span aria-hidden="true">›</span></button>
          <button type="button" className="settings-menu-item" onClick={() => setSettingsSection('about')}><span><b><Info size={18} />关于助手</b><small>版本、数据保护与使用说明</small></span><span aria-hidden="true">›</span></button>
        </div>
      </section>
    </section>}
    {settingsSection === 'personal' && <><ProfileSettings profile={displayedProfile} dirty={profileDirty} pending={saveProfile.isPending} error={avatarError ?? saveProfile.error?.message ?? null} onOpenAvatar={() => setAvatarEditorOpen(true)} onOpenName={() => setNameEditorOpen(true)} onSave={() => saveProfile.mutate()} /><AppearanceModeSelector mode={appearanceMode} onChange={onAppearanceModeChange} /><LayoutModeSelector mode={layoutMode} onChange={onLayoutModeChange} /></>}
    {settingsSection === 'account' && <section className="account-settings-detail" aria-label="账号安全设置">
      <section className="account-settings-section" aria-labelledby="account-authentication-heading">
        <h2 id="account-authentication-heading">单用户认证</h2>
        <div className="account-settings-group">
          <div className="account-authentication-row"><span><b>当前使用单用户认证</b><small>账号凭据由服务器环境配置管理</small></span></div>
        </div>
        <p className="account-settings-footer">本页不会展示或保存账号密码。</p>
        <details className="account-deployment-note"><summary>部署说明</summary><p>管理员用户名通过 <code>ADMIN_USERNAME</code> 配置，密码哈希通过 <code>ADMIN_PASSWORD_HASH</code> 配置。修改密码后，请重新生成 Argon2id 哈希并更新服务器 <code>.env</code>，再重启后端。</p></details>
      </section>
      <section className="account-settings-section" aria-labelledby="account-action-heading">
        <h2 id="account-action-heading">账户操作</h2>
        <div className="account-settings-group">
          <button type="button" className="account-logout-row" disabled={appLogout.isPending} onClick={() => setLogoutConfirm(true)}><span><b>退出航的助手</b><small>返回登录页，不会删除本地课程表、成绩缓存或自定义安排</small></span><ChevronRight size={18} aria-hidden="true" /></button>
        </div>
      </section>
    </section>}
    {settingsSection === 'time' && <TimeSettings terms={terms.data} periods={periods.data} preferredTerm={preferredTerm} selectedTermId={selectedTermId} selectedPeriodNumber={selectedPeriodNumber} onSelectTerm={setSelectedTermId} onSelectPeriod={setSelectedPeriodNumber} onTermSaved={() => { queryClient.invalidateQueries({ queryKey: ['terms'] }); queryClient.invalidateQueries({ queryKey: ['sessions'] }); }} onPeriodSaved={() => { queryClient.invalidateQueries({ queryKey: ['period-times'] }); queryClient.invalidateQueries({ queryKey: ['sessions'] }); }} />}
    {settingsSection === 'data' && <DataImportSettings onOpenTimetable={() => navigate('/timetable')} onOpenGrades={() => navigate('/grades')} />}
    {settingsSection === 'analysis' && <><AiAnalysisSettings dark={resolvedAppearanceMode === 'dark'} /><AiAnalysisHistorySettings /></>}
    {settingsSection === 'about' && <><section className="about-hero"><div className="about-mark"><img src="/pwa-192.png" alt="航的助手应用图标" /></div><div><small>Hand Helper</small><h2>航的助手</h2><span>v{APP_VERSION}</span></div></section><section className="card about-card"><b>应用说明</b><small>为个人使用场景设计的课程表与成绩分析助手。课程和成绩由你主动上传导出文件后写入本地缓存。</small><div className="about-list"><p><span>使用范围</span><strong>仅供本人使用</strong></p><p><span>数据方式</span><strong>本地导出文件解析</strong></p></div></section><HelpCenter /><section className="card settings-card"><b>隐私与安全</b><small>登录令牌不会展示在页面或日志中。课程、成绩和头像数据仅保存在你配置的后端与本地缓存中；上传的原始教务文件仅用于当次解析。</small></section></>}
    {avatarCropSource && <AvatarCropSheet source={avatarCropSource} dark={resolvedAppearanceMode === 'dark'} onClose={() => setAvatarCropSource(null)} onConfirm={(avatar) => { setNewAvatar(avatar); setAvatarCropSource(null); setAvatarError(null); }} />}
    {avatarEditorOpen && <ProfileAvatarSheet profile={displayedProfile} dark={resolvedAppearanceMode === 'dark'} onClose={() => setAvatarEditorOpen(false)} onChoose={(file) => { setAvatarEditorOpen(false); void chooseAvatar(file); }} onRemove={() => { setNewAvatar(null); setAvatarEditorOpen(false); }} />}
    {nameEditorOpen && <ProfileNameSheet initialName={displayName} dark={resolvedAppearanceMode === 'dark'} onClose={() => setNameEditorOpen(false)} onConfirm={(name) => { setDisplayName(name); setNameEditorOpen(false); }} />}
    {logoutConfirm && <ConfirmDialog title="确认退出航的助手？" description="退出后将返回登录页。已导入的课程表、成绩缓存和自定义安排都会保留。" confirmLabel="确认退出" pending={appLogout.isPending} onCancel={() => setLogoutConfirm(false)} onConfirm={() => appLogout.mutate()} />}
  </Page>;
}

function formatSettingsDate(value: string | null) {
  if (!value) return '选择日期';
  const date = dateFromKey(value);
  return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
}

function ProfileSettings({ profile, dirty, pending, error, onOpenAvatar, onOpenName, onSave }: { profile: Profile; dirty: boolean; pending: boolean; error: string | null; onOpenAvatar: () => void; onOpenName: () => void; onSave: () => void }) {
  return <section className="profile-settings-section" aria-labelledby="profile-settings-heading"><h2 id="profile-settings-heading">个人资料</h2><form onSubmit={(event) => { event.preventDefault(); onSave(); }}><div className="profile-settings-group">
    <button type="button" className="profile-settings-row" onClick={onOpenAvatar}><span className="profile-settings-label">头像</span><span className="profile-settings-trailing"><Avatar profile={profile} className="profile-settings-avatar" /><ChevronRight size={18} aria-hidden="true" /></span></button>
    <button type="button" className="profile-settings-row" onClick={onOpenName}><span className="profile-settings-label">显示姓名</span><span className="profile-settings-trailing profile-settings-name">{profile.display_name}<ChevronRight size={18} aria-hidden="true" /></span></button>
  </div><button className="profile-settings-save" type="submit" disabled={!dirty || pending}>{pending ? '正在保存…' : '保存资料'}</button>{error && <p className="profile-settings-error" role="alert">{error}</p>}<p className="profile-settings-footer">首页会使用这里的姓名和头像。头像保存前会裁剪为 1:1 正方形。</p></form></section>;
}

function ProfileAvatarSheet({ profile, dark, onClose, onChoose, onRemove }: { profile: Profile; dark: boolean; onClose: () => void; onChoose: (file: File | undefined) => void; onRemove: () => void }) {
  return <DetailSheet title="头像" dark={dark} onClose={onClose}><section className="profile-avatar-editor"><Avatar profile={profile} className="profile-avatar-editor-preview" /><label className="profile-avatar-picker">选择并裁剪头像<input aria-label="选择头像" type="file" accept="image/png,image/jpeg,image/webp" onChange={(event) => { onChoose(event.target.files?.[0]); event.currentTarget.value = ''; }} /></label>{profile.avatar_data_url && <button type="button" className="profile-avatar-remove" onClick={onRemove}>移除头像</button>}<small>支持 PNG、JPEG 或 WebP；保存后的头像为 1:1 正方形，最大 1 MB。</small></section></DetailSheet>;
}

function ProfileNameSheet({ initialName, dark, onClose, onConfirm }: { initialName: string; dark: boolean; onClose: () => void; onConfirm: (name: string) => void }) {
  const [value, setValue] = useState(initialName);
  const normalizedValue = value.trim();
  const changed = normalizedValue !== initialName.trim();
  return <DetailSheet title="显示姓名" dark={dark} onClose={onClose}><form className="profile-name-editor" onSubmit={(event) => { event.preventDefault(); if (normalizedValue) onConfirm(normalizedValue); }}><label>姓名<input aria-label="显示姓名" value={value} onChange={(event) => setValue(event.target.value)} maxLength={64} autoFocus required /></label><small>会显示在首页与头像占位图中。</small><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose}>取消</button><button type="submit" disabled={!normalizedValue || !changed}>完成编辑</button></div></form></DetailSheet>;
}

function DataImportSettings({ onOpenTimetable, onOpenGrades }: { onOpenTimetable: () => void; onOpenGrades: () => void }) {
  return <section className="data-import-settings-section" aria-labelledby="data-import-settings-heading"><h2 id="data-import-settings-heading">本地文件导入</h2><div className="data-import-settings-group">
    <button type="button" className="data-import-settings-row" onClick={onOpenTimetable}><span><b>课程表</b><small>导入打印的 .xls 课表</small></span><ChevronRight size={18} aria-hidden="true" /></button>
    <button type="button" className="data-import-settings-row" onClick={onOpenGrades}><span><b>成绩分析</b><small>导入 .xls 或 HTML 成绩文件</small></span><ChevronRight size={18} aria-hidden="true" /></button>
    <div className="data-import-settings-row data-import-settings-note"><span><b>原始文件</b><small>仅用于本次解析，不会保存</small></span></div>
  </div></section>;
}

function TimeSettings({ terms, periods, preferredTerm, selectedTermId, selectedPeriodNumber, onSelectTerm, onSelectPeriod, onTermSaved, onPeriodSaved }: {
  terms: Term[] | undefined; periods: PeriodTime[] | undefined; preferredTerm: Term | undefined; selectedTermId: number | null; selectedPeriodNumber: number | null; onSelectTerm: (id: number) => void; onSelectPeriod: (period: number) => void; onTermSaved: () => void; onPeriodSaved: () => void;
}) {
  const selectedTerm = terms?.find((term) => term.id === selectedTermId) ?? preferredTerm;
  const selectedPeriod = periods?.find((period) => period.period_number === selectedPeriodNumber) ?? periods?.[0];
  return <div className="time-settings-detail">
    {terms?.length && selectedTerm ? <SemesterStartSettings terms={terms} term={selectedTerm} onSelectTerm={onSelectTerm} onSaved={onTermSaved} /> : <section className="time-settings-section"><h2>学期第一周</h2><p className="time-settings-footer">尚无学期数据；请先在课程表页导入打印课表文件。</p></section>}
    {selectedPeriod && periods ? <PeriodTimeSettings periods={periods} period={selectedPeriod} onSelectPeriod={onSelectPeriod} onSaved={onPeriodSaved} /> : <section className="time-settings-section"><h2>节次时间</h2><p className="time-settings-footer">正在读取节次时间…</p></section>}
  </div>;
}

function SemesterStartSettings({ terms, term, onSelectTerm, onSaved }: { terms: Term[]; term: Term; onSelectTerm: (id: number) => void; onSaved: () => void }) {
  const [value, setValue] = useState(term.start_date ?? '');
  const [savedValue, setSavedValue] = useState(term.start_date ?? '');
  useEffect(() => { const nextValue = term.start_date ?? ''; setValue(nextValue); setSavedValue(nextValue); }, [term.id, term.start_date]);
  const isMonday = Boolean(value) && dateFromKey(value).getDay() === 1;
  const dirty = value !== savedValue;
  const save = useMutation({ mutationFn: () => api.updateTermStartDate(term.id, value), onSuccess: () => { setSavedValue(value); onSaved(); } });
  return <section className="time-settings-section" aria-labelledby="term-start-settings-heading"><h2 id="term-start-settings-heading">学期第一周</h2><form onSubmit={(event) => { event.preventDefault(); if (isMonday) save.mutate(); }}><div className="time-settings-group">
    <label className="time-settings-row time-settings-native-row"><span className="time-settings-label">学期</span><span className="time-settings-value">{term.display_name}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="选择要配置的学期" value={term.id} disabled={save.isPending} onChange={(event) => onSelectTerm(Number(event.target.value))}>{terms.map((item) => <option key={item.id} value={item.id}>{item.display_name}</option>)}</select></label>
    <label className="time-settings-row time-settings-native-row"><span className="time-settings-label">第一周周一</span><span className="time-settings-value">{formatSettingsDate(value || null)}<ChevronRight size={18} aria-hidden="true" /></span><input aria-label="选择第一周周一" type="date" value={value} disabled={save.isPending} onChange={(event) => setValue(event.target.value)} required /></label>
  </div><button className="time-settings-save" type="submit" disabled={!dirty || !isMonday || save.isPending}>{save.isPending ? '正在保存…' : '保存更改'}</button>{value && !isMonday && <p className="time-settings-error" role="alert">请选择星期一作为第一周的开始日期。</p>}{save.error && <p className="time-settings-error" role="alert">{save.error.message}</p>}<p className="time-settings-footer">选择已导入的学期后，设置第一周的星期一。保存会重新生成该学期课程日程。</p></form></section>;
}

function PeriodTimeSettings({ periods, period, onSelectPeriod, onSaved }: { periods: PeriodTime[]; period: PeriodTime; onSelectPeriod: (period: number) => void; onSaved: () => void }) {
  const [startTime, setStartTime] = useState(period.start_time);
  const [endTime, setEndTime] = useState(period.end_time);
  const [savedStartTime, setSavedStartTime] = useState(period.start_time);
  const [savedEndTime, setSavedEndTime] = useState(period.end_time);
  useEffect(() => { setStartTime(period.start_time); setEndTime(period.end_time); setSavedStartTime(period.start_time); setSavedEndTime(period.end_time); }, [period]);
  const dirty = startTime !== savedStartTime || endTime !== savedEndTime;
  const save = useMutation({ mutationFn: () => api.updatePeriodTime(period.period_number, startTime, endTime), onSuccess: () => { setSavedStartTime(startTime); setSavedEndTime(endTime); onSaved(); } });
  return <section className="time-settings-section" aria-labelledby="period-time-settings-heading"><h2 id="period-time-settings-heading">节次时间</h2><form onSubmit={(event) => { event.preventDefault(); save.mutate(); }}><div className="time-settings-group">
    <label className="time-settings-row time-settings-native-row"><span className="time-settings-label">节次</span><span className="time-settings-value">第 {period.period_number} 节<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="选择要配置的节次" value={period.period_number} disabled={save.isPending} onChange={(event) => onSelectPeriod(Number(event.target.value))}>{periods.map((item) => <option key={item.period_number} value={item.period_number}>第 {item.period_number} 节</option>)}</select></label>
    <label className="time-settings-row time-settings-native-row"><span className="time-settings-label">开始时间</span><span className="time-settings-value">{startTime}<ChevronRight size={18} aria-hidden="true" /></span><input aria-label={`第 ${period.period_number} 节开始时间`} type="time" value={startTime} disabled={save.isPending} onChange={(event) => setStartTime(event.target.value)} required /></label>
    <label className="time-settings-row time-settings-native-row"><span className="time-settings-label">结束时间</span><span className="time-settings-value">{endTime}<ChevronRight size={18} aria-hidden="true" /></span><input aria-label={`第 ${period.period_number} 节结束时间`} type="time" value={endTime} disabled={save.isPending} onChange={(event) => setEndTime(event.target.value)} required /></label>
  </div><button className="time-settings-save" type="submit" disabled={!dirty || save.isPending || !startTime || !endTime}>{save.isPending ? '正在保存…' : '保存更改'}</button>{save.error && <p className="time-settings-error" role="alert">{save.error.message}</p>}<p className="time-settings-footer">选择需要调整的节次。保存后，已有课程日程会按新时间重新生成。</p></form></section>;
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
  const [textEditor, setTextEditor] = useState<'classroom' | 'teacher' | null>(null);
  const [weekday, setWeekday] = useState(initial.weekday);
  const [startPeriod, setStartPeriod] = useState(initial.start_period);
  const [endPeriod, setEndPeriod] = useState(initial.end_period);
  const [classroom, setClassroom] = useState(initial.classroom ?? '');
  const [teacher, setTeacher] = useState(initial.teacher ?? '');
  useEffect(() => {
    setCourseName(initial.course_name);
    setSelectedWeeks(new Set(parseManualCourseWeeks(initial.week_expression)));
    setWeekPickerOpen(false);
    setTextEditor(null);
    setWeekday(initial.weekday);
    setStartPeriod(initial.start_period);
    setEndPeriod(initial.end_period);
    setClassroom(initial.classroom ?? '');
    setTeacher(initial.teacher ?? '');
  }, [initial]);
  const weekNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  const selectedWeekText = [...selectedWeeks].sort((left, right) => left - right).join('、');
  const initialWeekExpression = manualCourseWeekExpression(parseManualCourseWeeks(initial.week_expression));
  const currentWeekExpression = manualCourseWeekExpression(selectedWeeks);
  const dirty = courseName.trim() !== initial.course_name.trim() || currentWeekExpression !== initialWeekExpression || weekday !== initial.weekday || startPeriod !== initial.start_period || endPeriod !== initial.end_period || classroom.trim() !== (initial.classroom ?? '').trim() || teacher.trim() !== (initial.teacher ?? '').trim();
  const valid = Boolean(courseName.trim()) && Boolean(selectedWeeks.size);
  const periodLabel = (periodNumber: number, edge: 'start' | 'end') => { const period = periods.find((item) => item.period_number === periodNumber); return `第 ${periodNumber} 节 · ${period ? (edge === 'start' ? period.start_time : period.end_time) : '—'}`; };
  return createPortal(<><div className={`sheet-mask sheet-mask-viewport${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet manual-course-sheet" role="dialog" aria-modal="true" aria-label={editing ? '编辑手动课程' : '添加手动课程'} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{editing ? '编辑课程' : '添加课程'}</h2><button type="button" onClick={onClose} disabled={pending}>关闭</button></header><p className="manual-course-top-note">课程会保存到当前学期，不会被教务系统同步或打印课表导入覆盖。</p><form onSubmit={(event) => { event.preventDefault(); if (!valid || !dirty) return; onSave({ term_id: initial.term_id, course_name: courseName.trim(), week_expression: currentWeekExpression, weekday, start_period: startPeriod, end_period: endPeriod, classroom: classroom.trim() || null, teacher: teacher.trim() || null }); }}><section className="manual-course-settings-section"><h3>课程信息</h3><div className="manual-course-settings-group"><label className="manual-course-settings-row manual-course-title-row"><span className="manual-course-settings-label">课程名称</span><input aria-label="课程名称" value={courseName} onChange={(event) => setCourseName(event.target.value)} maxLength={255} required placeholder="例如：课程作业答疑" /></label><button type="button" className="manual-course-settings-row" onClick={() => setWeekPickerOpen(true)}><span className="manual-course-settings-label">上课周次</span><span className="manual-course-settings-value">{selectedWeekText ? `第 ${selectedWeekText} 周` : '请选择上课周次'}<ChevronRight size={18} aria-hidden="true" /></span></button><label className="manual-course-settings-row manual-course-native-row"><span className="manual-course-settings-label">星期</span><span className="manual-course-settings-value">{weekNames[weekday - 1] ?? '请选择'}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="上课星期" value={weekday} onChange={(event) => setWeekday(Number(event.target.value))}>{weekNames.map((name, index) => <option value={index + 1} key={name}>{name}</option>)}</select></label></div></section><section className="manual-course-settings-section"><h3>上课时间</h3><div className="manual-course-settings-group"><label className="manual-course-settings-row manual-course-native-row"><span className="manual-course-settings-label">开始节次</span><span className="manual-course-settings-value">{periodLabel(startPeriod, 'start')}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="开始节次" value={startPeriod} onChange={(event) => setStartPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.start_time}</option>)}</select></label><label className="manual-course-settings-row manual-course-native-row"><span className="manual-course-settings-label">结束节次</span><span className="manual-course-settings-value">{periodLabel(endPeriod, 'end')}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="结束节次" value={endPeriod} onChange={(event) => setEndPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.end_time}</option>)}</select></label></div></section><section className="manual-course-settings-section"><h3>其他信息</h3><div className="manual-course-settings-group"><button type="button" className="manual-course-settings-row" onClick={() => setTextEditor('classroom')}><span className="manual-course-settings-label">教室地点</span><span className="manual-course-settings-value">{classroom.trim() || '可留空'}<ChevronRight size={18} aria-hidden="true" /></span></button><button type="button" className="manual-course-settings-row" onClick={() => setTextEditor('teacher')}><span className="manual-course-settings-label">任课教师</span><span className="manual-course-settings-value">{teacher.trim() || '可留空'}<ChevronRight size={18} aria-hidden="true" /></span></button></div></section><p className="manual-course-footer">保存后会按设置中的学期第一周周一和节次时间，自动生成每周课程日期。</p><button type="submit" className="manual-course-save" disabled={pending || !valid || !dirty}>{pending ? '保存中…' : '保存课程'}</button>{error && <p className="error">{error.message}</p>}</form></section></div>{weekPickerOpen && <ManualWeekPicker selected={selectedWeeks} dark={dark} onClose={() => setWeekPickerOpen(false)} onConfirm={(weeks) => { setSelectedWeeks(weeks); setWeekPickerOpen(false); }} />}{textEditor && <ManualCourseTextSheet kind={textEditor} value={textEditor === 'classroom' ? classroom : teacher} dark={dark} onClose={() => setTextEditor(null)} onConfirm={(value) => { if (textEditor === 'classroom') setClassroom(value); else setTeacher(value); setTextEditor(null); }} />}</>, document.body);
}

function ManualCourseTextSheet({ kind, value, dark, onClose, onConfirm }: { kind: 'classroom' | 'teacher'; value: string; dark: boolean; onClose: () => void; onConfirm: (value: string) => void }) {
  const [draft, setDraft] = useState(value);
  const normalizedValue = draft.trim();
  const changed = normalizedValue !== value.trim();
  const title = kind === 'classroom' ? '教室地点' : '任课教师';
  return <DetailSheet title={title} dark={dark} onClose={onClose}><form className="manual-course-text-editor" onSubmit={(event) => { event.preventDefault(); if (changed) onConfirm(normalizedValue); }}><label>{title}<input aria-label={title} value={draft} onChange={(event) => setDraft(event.target.value)} maxLength={255} autoFocus placeholder="可留空" /></label><small>可留空，保存课程时会一并写入。</small><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose}>取消</button><button type="submit" disabled={!changed}>完成编辑</button></div></form></DetailSheet>;
}

let detailSheetScrollLockCount = 0;

function useDetailSheetScrollLock() {
  useEffect(() => {
    detailSheetScrollLockCount += 1;
    document.documentElement.dataset.detailSheetOpen = 'true';
    return () => {
      detailSheetScrollLockCount = Math.max(0, detailSheetScrollLockCount - 1);
      if (!detailSheetScrollLockCount) delete document.documentElement.dataset.detailSheetOpen;
    };
  }, []);
}

function Detail({ label, value }: { label: string; value: string }) { return <p><small>{label}</small><span>{value}</span></p>; }
function DetailSheet({ title, children, onClose, dark = false }: { title: string; children: React.ReactNode; onClose: () => void; dark?: boolean }) {
  useDetailSheetScrollLock();
  return createPortal(<div className={`sheet-mask sheet-mask-viewport${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={onClose}><section className="detail-sheet" role="dialog" aria-modal="true" aria-label={title} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{title}</h2><button type="button" aria-label="关闭详情" onClick={onClose}>关闭</button></header>{children}</section></div>, document.body);
}
function ConfirmDialog({ title, description, confirmLabel, pending, onCancel, onConfirm }: { title: string; description: string; confirmLabel: string; pending: boolean; onCancel: () => void; onConfirm: () => void }) { return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onCancel}><section className="confirm-dialog" role="dialog" aria-modal="true" aria-label={title} onClick={(event) => event.stopPropagation()}><h2>{title}</h2><p>{description}</p><div><button type="button" className="secondary-button" disabled={pending} onClick={onCancel}>取消</button><button type="button" className="logout-button" disabled={pending} onClick={onConfirm}>{pending ? '正在退出…' : confirmLabel}</button></div></section></div>; }
function Empty({ text }: { text: string }) { return <div className="empty">{text}</div>; }
function Page({ title, children, action, icon, className, headerClassName, compactTitle, mainRef, headerRef }: { title: string; children: React.ReactNode; action?: React.ReactNode; icon?: React.ReactNode; className?: string; headerClassName?: string; compactTitle?: boolean; mainRef?: RefObject<HTMLElement>; headerRef?: RefObject<HTMLElement> }) { return <main ref={mainRef} className={className}><header ref={headerRef} className={headerClassName}>{compactTitle && icon && <span className="page-fixed-title-icon" aria-hidden="true">{icon}</span>}<h1 className="page-title">{!compactTitle && icon && <span className="page-title-icon" aria-hidden="true">{icon}</span>}{title}</h1>{compactTitle && <span className="page-title-compact" aria-hidden="true">{title}</span>}{action}</header>{children}</main>; }

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
function PrimaryRouteTransition({ appearanceMode, resolvedAppearanceMode, onAppearanceModeChange, layoutMode, onLayoutModeChange }: {
  appearanceMode: AppearanceMode;
  resolvedAppearanceMode: 'light' | 'dark';
  onAppearanceModeChange: (mode: AppearanceMode) => void;
  layoutMode: LayoutMode;
  onLayoutModeChange: (mode: LayoutMode) => void;
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
      <Route path="/settings" element={<Settings appearanceMode={appearanceMode} resolvedAppearanceMode={resolvedAppearanceMode} onAppearanceModeChange={onAppearanceModeChange} layoutMode={layoutMode} onLayoutModeChange={onLayoutModeChange} />} />
    </Routes>
  </div>;
}

export default function App() {
  const [authState, setAuthState] = useState<'checking' | 'authenticated' | 'unauthenticated'>('checking');
  const navigate = useNavigate();
  const location = useLocation();
  const [appearanceMode, setAppearanceMode] = useState<AppearanceMode>(savedAppearanceMode);
  const [layoutMode, setLayoutMode] = useState<LayoutMode>(savedLayoutMode);
  const resolvedAppearanceMode = useResolvedAppearanceMode(appearanceMode);
  useEffect(() => { window.localStorage.setItem('appearance_mode', appearanceMode); }, [appearanceMode]);
  useEffect(() => { window.localStorage.setItem('layout_mode', layoutMode); document.documentElement.dataset.layout = layoutMode; }, [layoutMode]);
  useEffect(() => {
    document.documentElement.dataset.appearance = resolvedAppearanceMode;
    document.querySelector('meta[name="theme-color"]')?.setAttribute(
      'content',
      resolvedAppearanceMode === 'dark' ? '#101827' : '#f4f7fb',
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
  useEffect(() => {
    // 头像仅用于应用内展示；不要让 Safari/桌面浏览器把它作为可保存图片弹出菜单。
    const suppressAvatarImageMenu = (event: MouseEvent) => {
      const target = event.target;
      if (target instanceof HTMLImageElement && target.matches('.user-avatar img, .avatar-preview-image-frame img, .nav-home-avatar')) event.preventDefault();
    };
    document.addEventListener('contextmenu', suppressAvatarImageMenu);
    return () => document.removeEventListener('contextmenu', suppressAvatarImageMenu);
  }, []);
  useEffect(() => {
    // viewport 已锁定常规缩放；补上 Safari 手势事件，防止双指 / 双击仍把整个页面放大。
    // 头像裁剪器自己的双指缩放是编辑图片，而不是页面缩放，须保留。
    const isAvatarCropGesture = (target: EventTarget | null) => target instanceof Element && Boolean(target.closest('.avatar-crop-stage'));
    const preventPageZoom = (event: Event) => {
      if (!isAvatarCropGesture(event.target) && event.cancelable) event.preventDefault();
    };
    const preventMultiTouchZoom = (event: TouchEvent) => {
      if (event.touches.length > 1) preventPageZoom(event);
    };
    document.addEventListener('gesturestart', preventPageZoom, { passive: false });
    document.addEventListener('gesturechange', preventPageZoom, { passive: false });
    document.addEventListener('gestureend', preventPageZoom, { passive: false });
    document.addEventListener('touchmove', preventMultiTouchZoom, { passive: false });
    document.addEventListener('dblclick', preventPageZoom, { passive: false });
    return () => {
      document.removeEventListener('gesturestart', preventPageZoom);
      document.removeEventListener('gesturechange', preventPageZoom);
      document.removeEventListener('gestureend', preventPageZoom);
      document.removeEventListener('touchmove', preventMultiTouchZoom);
      document.removeEventListener('dblclick', preventPageZoom);
    };
  }, []);
  if (authState === 'checking') return <AuthGateLoading />;
  if (authState === 'unauthenticated') return <><NativeStartupNotice /><Routes><Route path="/login" element={<Login onSuccess={() => { setAuthState('authenticated'); navigate('/', { replace: true }); }} />} /><Route path="*" element={<Navigate to="/login" replace />} /></Routes></>;
  if (location.pathname === '/login') return <Navigate to="/" replace />;
  return <div className="shell"><NativeStartupNotice /><NetworkNotice /><PrimaryRouteTransition appearanceMode={appearanceMode} resolvedAppearanceMode={resolvedAppearanceMode} onAppearanceModeChange={setAppearanceMode} layoutMode={layoutMode} onLayoutModeChange={setLayoutMode} /><BottomNav appearance={resolvedAppearanceMode} /></div>;
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
  const navigate = useNavigate();
  const profile = useQuery({ queryKey: ['profile'], queryFn: api.profile, staleTime: 5 * 60 * 1000 });
  const activeIndex = pathname === '/timetable' ? 1 : pathname === '/grades' ? 2 : pathname === '/settings' ? 3 : 0;
  // 底部四个栏目是平级目的地：切换时替换当前历史项，Android 返回键不会在栏目之间倒退。
  const avatar = profile.data?.avatar_data_url;
  const go = (to: string) => () => navigate(to, { replace: true });
  return <nav className={`glass-nav four-nav${appearance === 'dark' ? ' nav-dark' : ''}`} aria-label="主导航" style={{ '--nav-active-offset': `${activeIndex * 100}%` } as CSSProperties}><span className="nav-glass" /><span className="nav-active-pill" /><button type="button" className={`nav-button${activeIndex === 0 ? ' is-active' : ''}`} aria-current={activeIndex === 0 ? 'page' : undefined} onClick={go('/')}>{avatar ? <img className="nav-home-avatar" src={avatar} alt="" aria-hidden="true" /> : <Home />}今日</button><button type="button" className={`nav-button${activeIndex === 1 ? ' is-active' : ''}`} aria-current={activeIndex === 1 ? 'page' : undefined} onClick={go('/timetable')}><CalendarDays />课程表</button><button type="button" className={`nav-button${activeIndex === 2 ? ' is-active' : ''}`} aria-current={activeIndex === 2 ? 'page' : undefined} onClick={go('/grades')}><GraduationCap />分析</button><button type="button" className={`nav-button${activeIndex === 3 ? ' is-active' : ''}`} aria-current={activeIndex === 3 ? 'page' : undefined} onClick={go('/settings')}><SettingsIcon />设置</button></nav>;
}

