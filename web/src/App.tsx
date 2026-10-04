import { useEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent, type RefObject } from 'react';
import { createPortal } from 'react-dom';
import ReactMarkdown from 'react-markdown';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Capacitor } from '@capacitor/core';
import Cropper, { type Area } from 'react-easy-crop';
import { Award, BookOpen, CalendarDays, ChevronDown, ChevronLeft, ChevronRight, Clock3, Database, Eye, EyeOff, FileText, GraduationCap, Home, Info, KeyRound, LockKeyhole, MapPin, Monitor, Moon, Palette, Pencil, Plus, RotateCcw, Settings as SettingsIcon, Smartphone, Sparkles, Sun, Trash2, Upload, UserRound, X } from 'lucide-react';
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { api, ConnectionError, UnauthorizedError, AiProviderSettingInput, CustomSchedule, CustomScheduleInput, Grade, GradeAiAnalysis, GradeAiAnalysisHistory, GradeImportPreview, ManualCourseInput, PasskeyCredential, PeriodTime, Profile, ProfileUpdate, Session, Term } from './api';
import { updateNativeStatusBar } from './native-runtime';
import { createPasskeyCredential, getPasskeyAssertion, passkeySupported } from './passkeys';
import { TimetableStage } from './timetable/TimetableStage';

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
const TIMETABLE_BACKGROUND_INPUT_MAX_BYTES = 5_000_000;
const TIMETABLE_BACKGROUND_INPUT_MAX_PIXELS = 25_000_000;
const TIMETABLE_BACKGROUND_OUTPUT_MAX_BYTES = 1_000_000;
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
  return new Promise((resolve, reject) => canvas.toBlob((blob) => blob ? resolve(blob) : reject(new Error('图片处理失败，请换一张图片后重试。')), 'image/jpeg', quality));
}

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(new Error('图片处理失败，请重试。'));
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

async function createCroppedPortraitBackground(source: string, area: Area): Promise<string> {
  const image = await loadImage(source);
  const exportOptions = [[720, 1280, .86], [720, 1280, .76], [648, 1152, .8]] as const;
  for (const [width, height, quality] of exportOptions) {
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('当前浏览器不支持背景图片裁切。');
    context.fillStyle = '#f4f7fb';
    context.fillRect(0, 0, width, height);
    context.drawImage(image, area.x, area.y, area.width, area.height, 0, 0, width, height);
    const blob = await canvasToJpeg(canvas, quality);
    if (blob.size <= TIMETABLE_BACKGROUND_OUTPUT_MAX_BYTES) return blobToDataUrl(blob);
  }
  throw new Error('裁切后的背景图片仍超过 1 MB，请缩小选区或换一张图片。');
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
  const [deletingSchedule, setDeletingSchedule] = useState<CustomSchedule | null>(null);
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
    onSuccess: () => { setDeletingSchedule(null); queryClient.invalidateQueries({ queryKey: ['custom-schedules'] }); },
  });
  const items = (sessions.data ?? []).filter((item) => item.session_date === today);
  const name = profile.data?.display_name ?? '用户';
  // 只在首次取得首页所需数据前显示整页加载态。后续失效刷新会保留已显示的主页，避免闪屏。
  const loading = sessions.isLoading || profile.isLoading || customSchedules.isLoading;
  const pageError = sessions.error ?? profile.error ?? customSchedules.error;
  const retryPageData = () => { void Promise.all([sessions.refetch(), profile.refetch(), customSchedules.refetch()]); };
  if (loading) return <TodayBackendLoading appearance={appearance} />;
  if (pageError) return <TodayBackendLoadError appearance={appearance} error={pageError} onRetry={retryPageData} />;
  return <main className={`today-page${appearance === 'dark' ? ' today-page-dark' : ''}${profile.data?.home_wallpaper_data_url ? ' today-page-with-wallpaper' : ''}`} style={profile.data?.home_wallpaper_data_url ? { '--home-wallpaper-image': `url("${profile.data.home_wallpaper_data_url}")` } as CSSProperties : undefined}>
    {profile.data?.home_wallpaper_data_url && <div className="today-wallpaper" aria-hidden="true" style={{ backgroundImage: `url("${profile.data.home_wallpaper_data_url}")` }} />}
    <section className="today-hero">{profile.data?.avatar_data_url && <><div className="hero-avatar-background" aria-hidden="true" style={{ backgroundImage: `url(${profile.data.avatar_data_url})` }} /><div className="hero-avatar-overlay" aria-hidden="true" /></>}<div className="today-hero-content"><p className="today-kicker">今日 · {greetingForHour(now.getHours())}</p><h1>{name}</h1><p className="today-date">{now.toLocaleDateString('zh-CN', { month: 'long', day: 'numeric', weekday: 'long' })}</p></div>{profile.data?.avatar_data_url ? <button type="button" className="avatar-preview-trigger" aria-label={`预览${name}的头像`} onClick={() => setAvatarPreviewOpen(true)}><Avatar profile={profile.data} /></button> : <Avatar profile={profile.data} />}</section>
    <section className="today-content"><div className="today-section-heading"><h2>今日安排</h2>{Boolean(customSchedules.data?.length) && <span className="today-schedule-count">今天有 {customSchedules.data?.length} 项自定义安排</span>}<button type="button" className="add-schedule-button" onClick={() => setEditingSchedule('new')}><Plus size={17} />添加安排</button></div>{items.length || customSchedules.data?.length ? <Timeline sessions={items} schedules={customSchedules.data ?? []} onEdit={setEditingSchedule} onDelete={setDeletingSchedule} /> : null}</section>
    {editingSchedule && <ViewportSheetPortal><CustomScheduleSheetV2 schedule={editingSchedule === 'new' ? undefined : editingSchedule} initialDate={today} pending={saveSchedule.isPending} error={saveSchedule.error} onClose={() => setEditingSchedule(null)} onSave={(payload) => saveSchedule.mutate(payload)} /></ViewportSheetPortal>}
    {deletingSchedule && <ViewportSheetPortal><ConfirmDialog title={`删除“${deletingSchedule.title}”？`} description="删除后无法恢复这项自定义安排。" confirmLabel="删除安排" pending={deleteSchedule.isPending} onCancel={() => setDeletingSchedule(null)} onConfirm={() => deleteSchedule.mutate(deletingSchedule.id)} /></ViewportSheetPortal>}
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
  useModalOpenState(onClose);
  return createPortal(<div className={`sheet-mask sheet-mask-viewport avatar-preview-mask${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={onClose}><div className="avatar-preview-dialog" role="dialog" aria-modal="true" aria-label={`${name}的头像预览`} onClick={(event) => event.stopPropagation()}><section className="avatar-preview-sheet"><div className="sheet-handle" /><div className="avatar-preview-image-frame"><img src={src} alt={`${name}的头像大图`} /></div></section><button type="button" className="avatar-preview-dismiss" aria-label="关闭头像预览" title="关闭" onClick={onClose}><X size={20} /></button></div></div>, document.body);
}

function AvatarCropSheet({ source, dark, onClose, onConfirm }: { source: string; dark: boolean; onClose: () => void; onConfirm: (avatar: string) => void }) {
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [area, setArea] = useState<Area | null>(null);
  const [processing, setProcessing] = useState(false);
  useModalOpenState(onClose, processing);
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
  return createPortal(<div className={`sheet-mask sheet-mask-viewport avatar-crop-mask${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={processing ? undefined : onClose}><section className="avatar-crop-sheet" role="dialog" aria-modal="true" aria-label="裁剪头像" onClick={(event) => event.stopPropagation()}><header><div><h2>裁剪头像</h2><p>拖动图片调整位置，使用双指或滑条缩放。保存后将为 1:1 正方形头像。</p></div><button type="button" className="sheet-close-icon" aria-label="关闭裁剪" title="关闭" onClick={onClose} disabled={processing}><X size={20} /></button></header><div className="avatar-crop-stage"><Cropper image={source} crop={crop} zoom={zoom} aspect={1} cropShape="rect" showGrid onCropChange={setCrop} onZoomChange={setZoom} onCropComplete={(_area, pixels) => setArea(pixels)} /></div><label className="avatar-zoom-control">缩放<input aria-label="头像缩放" type="range" min="1" max="3" step="0.01" value={zoom} onChange={(event) => setZoom(Number(event.target.value))} /></label><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={processing}>取消</button><button type="button" disabled={processing || !area} onClick={() => { void confirmCrop(); }}>{processing ? '处理中…' : '确认裁剪'}</button></div>{error && <p className="error">{error}</p>}</section></div>, document.body);
}

function PortraitBackgroundCropSheet({ source, kind, dark, onClose, onConfirm }: { source: string; kind: 'home' | 'timetable'; dark: boolean; onClose: () => void; onConfirm: (background: string) => void }) {
  const label = kind === 'home' ? '首页壁纸' : '课表背景';
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [area, setArea] = useState<Area | null>(null);
  const [processing, setProcessing] = useState(false);
  useModalOpenState(onClose, processing);
  const [error, setError] = useState<string | null>(null);
  const confirmCrop = async () => {
    if (!area) return;
    setProcessing(true);
    setError(null);
    try {
      onConfirm(await createCroppedPortraitBackground(source, area));
    } catch (cropError) {
      setError(cropError instanceof Error ? cropError.message : `${label}处理失败，请重试。`);
      setProcessing(false);
    }
  };
  return createPortal(<div className={`sheet-mask sheet-mask-viewport avatar-crop-mask${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={processing ? undefined : onClose}><section className="avatar-crop-sheet timetable-background-crop-sheet" role="dialog" aria-modal="true" aria-label={`裁切${label}`} onClick={(event) => event.stopPropagation()}><header><div><h2>裁切{label}</h2><p>{kind === 'home' ? '只显示在首页背景，不会修改课表。' : '背景只显示在课程网格区域。'}固定为 9:16，可使用双指或滑条缩放，最大 3 倍。</p></div><button type="button" className="sheet-close-icon" aria-label="关闭裁切" title="关闭" onClick={onClose} disabled={processing}><X size={20} /></button></header><div className="avatar-crop-stage timetable-background-crop-stage"><Cropper image={source} crop={crop} zoom={zoom} aspect={9 / 16} cropShape="rect" showGrid onCropChange={setCrop} onZoomChange={setZoom} onCropComplete={(_area, pixels) => setArea(pixels)} /></div><label className="avatar-zoom-control">缩放<input aria-label={`${label}缩放`} type="range" min="1" max="3" step="0.01" value={zoom} onChange={(event) => setZoom(Number(event.target.value))} /></label><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={processing}>取消</button><button type="button" disabled={processing || !area} onClick={() => { void confirmCrop(); }}>{processing ? '处理中…' : '确认裁切'}</button></div>{error && <p className="error">{error}</p>}</section></div>, document.body);
}

const CUSTOM_SCHEDULE_SWIPE_WIDTH = 168;
const CUSTOM_SCHEDULE_SWIPE_THRESHOLD = 68;

function SwipeableCustomScheduleCard({ schedule, open, onOpenChange, onEdit, onDelete }: { schedule: CustomSchedule; open: boolean; onOpenChange: (open: boolean) => void; onEdit: (schedule: CustomSchedule) => void; onDelete: (schedule: CustomSchedule) => void }) {
  const gesture = useRef<{ pointerId: number; startX: number; startY: number; startOffset: number; lastOffset: number; axis: 'horizontal' | 'vertical' | null } | null>(null);
  const [dragging, setDragging] = useState(false);
  const [dragOffset, setDragOffset] = useState(0);
  const translateX = dragging ? dragOffset : open ? -CUSTOM_SCHEDULE_SWIPE_WIDTH : 0;
  const handlePointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.pointerType === 'mouse') return;
    gesture.current = { pointerId: event.pointerId, startX: event.clientX, startY: event.clientY, startOffset: open ? -CUSTOM_SCHEDULE_SWIPE_WIDTH : 0, lastOffset: open ? -CUSTOM_SCHEDULE_SWIPE_WIDTH : 0, axis: null };
    event.currentTarget.setPointerCapture(event.pointerId);
  };
  const handlePointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    const currentGesture = gesture.current;
    if (!currentGesture || currentGesture.pointerId !== event.pointerId) return;
    const deltaX = event.clientX - currentGesture.startX;
    const deltaY = event.clientY - currentGesture.startY;
    if (!currentGesture.axis) {
      if (Math.max(Math.abs(deltaX), Math.abs(deltaY)) < 7) return;
      currentGesture.axis = Math.abs(deltaX) > Math.abs(deltaY) ? 'horizontal' : 'vertical';
      if (currentGesture.axis === 'horizontal') setDragging(true);
      else if (open) onOpenChange(false);
    }
    if (currentGesture.axis !== 'horizontal') return;
    event.preventDefault();
    const offset = Math.max(-CUSTOM_SCHEDULE_SWIPE_WIDTH, Math.min(0, currentGesture.startOffset + deltaX));
    currentGesture.lastOffset = offset;
    setDragOffset(offset);
  };
  const finishGesture = (event: ReactPointerEvent<HTMLDivElement>) => {
    const currentGesture = gesture.current;
    if (!currentGesture || currentGesture.pointerId !== event.pointerId) return;
    if (currentGesture.axis === 'horizontal') onOpenChange(currentGesture.lastOffset <= -CUSTOM_SCHEDULE_SWIPE_THRESHOLD);
    setDragging(false);
    gesture.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
  };
  return <article className={`custom-schedule-swipe${open ? ' is-open' : ''}${dragging ? ' is-dragging' : ''}`} style={{ '--swipe-reveal': `${Math.max(0, -translateX)}px` } as CSSProperties}>
    <div className="custom-schedule-swipe-actions" aria-hidden={!open}>
      <button type="button" className="custom-schedule-swipe-edit" tabIndex={open ? 0 : -1} onClick={() => { onOpenChange(false); onEdit(schedule); }}>编辑</button>
      <button type="button" className="custom-schedule-swipe-delete" tabIndex={open ? 0 : -1} onClick={() => { onOpenChange(false); onDelete(schedule); }}>删除</button>
    </div>
    <div className={`card today-entry-card custom-schedule-card${dragging ? ' is-dragging' : ''}`} style={{ transform: `translate3d(${translateX}px,0,0)` }} onPointerDown={handlePointerDown} onPointerMove={handlePointerMove} onPointerUp={finishGesture} onPointerCancel={finishGesture}>
      <div className="custom-schedule-card-head"><small className="today-entry-kind">自定义安排</small><span className="custom-schedule-desktop-actions"><button type="button" aria-label={`编辑 ${schedule.title}`} onClick={() => onEdit(schedule)}><Pencil size={15} /></button><button type="button" aria-label={`删除 ${schedule.title}`} onClick={() => onDelete(schedule)}><Trash2 size={15} /></button></span></div><b>{schedule.title}</b><span className="today-entry-time">{schedule.scheduled_time}</span>
    </div>
  </article>;
}

function Timeline({ sessions, schedules, onEdit, onDelete }: { sessions: Session[]; schedules: CustomSchedule[]; onEdit: (schedule: CustomSchedule) => void; onDelete: (schedule: CustomSchedule) => void }) {
  const now = Date.now();
  const [openScheduleId, setOpenScheduleId] = useState<number | null>(null);
  const timelineRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (openScheduleId === null) return;
    const timeline = timelineRef.current;
    const scrollContainer = timeline?.closest('main');
    const closeSwipeActions = () => setOpenScheduleId(null);
    timeline?.addEventListener('scroll', closeSwipeActions, { passive: true });
    scrollContainer?.addEventListener('scroll', closeSwipeActions, { passive: true });
    const closeWhenPressingOutside = (event: PointerEvent) => {
      if (timeline && event.target instanceof Node && !timeline.contains(event.target)) closeSwipeActions();
    };
    document.addEventListener('pointerdown', closeWhenPressingOutside, true);
    return () => {
      timeline?.removeEventListener('scroll', closeSwipeActions);
      scrollContainer?.removeEventListener('scroll', closeSwipeActions);
      document.removeEventListener('pointerdown', closeWhenPressingOutside, true);
    };
  }, [openScheduleId]);
  const active = sessions.find((session) => new Date(session.start_datetime).getTime() <= now && now < new Date(session.end_datetime).getTime());
  const upcoming = sessions.find((session) => new Date(session.start_datetime).getTime() > now);
  const status = active ? `正在上 ${active.course_name}，距下课约 ${Math.ceil((new Date(active.end_datetime).getTime() - now) / 60000)} 分钟` : upcoming ? `下一节 ${upcoming.course_name}，${Math.ceil((new Date(upcoming.start_datetime).getTime() - now) / 60000)} 分钟后上课` : schedules.length ? `今天有 ${schedules.length} 项自定义安排` : '今天的课程已经结束';
  const entries = [
    ...sessions.map((session) => ({ type: 'course' as const, sortTime: formatTime(session.start_datetime), session })),
    ...schedules.map((schedule) => ({ type: 'custom' as const, sortTime: schedule.scheduled_time, schedule })),
  ].sort((left, right) => left.sortTime.localeCompare(right.sortTime));
  return <>{(active || upcoming || !schedules.length) && <section className="today-status"><b>{status}</b></section>}<div ref={timelineRef} className="stack">{entries.map((entry) => entry.type === 'course' ? <article className={`card today-entry-card today-course-card ${entry.session === active ? 'current-course' : ''}`} key={`course-${entry.session.id}`}><small className="today-entry-kind">课程</small><b>{entry.session.course_name}</b><span className="today-entry-time">{formatTime(entry.session.start_datetime)}—{formatTime(entry.session.end_datetime)}</span><small className="today-entry-meta">{entry.session.classroom ?? '教室待定'} · {entry.session.teacher ?? '教师待定'}</small></article> : <SwipeableCustomScheduleCard key={`custom-${entry.schedule.id}`} schedule={entry.schedule} open={openScheduleId === entry.schedule.id} onOpenChange={(open) => setOpenScheduleId(open ? entry.schedule.id : null)} onEdit={onEdit} onDelete={onDelete} />)}</div></>;
}

function formatScheduleDate(value: string) {
  const [year, month, day] = value.split('-');
  return year && month && day ? `${year}年${Number(month)}月${Number(day)}日` : value;
}

function CustomScheduleSheetV2({ schedule, initialDate, pending, error, onClose, onSave }: { schedule?: CustomSchedule; initialDate: string; pending: boolean; error: Error | null; onClose: () => void; onSave: (payload: CustomScheduleInput) => void }) {
  useModalOpenState(onClose, pending);
  const [title, setTitle] = useState(schedule?.title ?? '');
  const [scheduledDate, setScheduledDate] = useState(schedule?.scheduled_date ?? initialDate);
  const [scheduledTime, setScheduledTime] = useState(schedule?.scheduled_time ?? '09:00');
  useEffect(() => { setTitle(schedule?.title ?? ''); setScheduledDate(schedule?.scheduled_date ?? initialDate); setScheduledTime(schedule?.scheduled_time ?? '09:00'); }, [schedule?.id, initialDate]);
  const initialTitle = schedule?.title.trim() ?? '';
  const initialScheduledDate = schedule?.scheduled_date ?? initialDate;
  const initialScheduledTime = schedule?.scheduled_time ?? '09:00';
  const dirty = title.trim() !== initialTitle || scheduledDate !== initialScheduledDate || scheduledTime !== initialScheduledTime;
  const valid = Boolean(title.trim()) && scheduledDate >= initialDate;
  return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet custom-schedule-sheet" role="dialog" aria-modal="true" aria-label={schedule ? '编辑安排' : '添加安排'} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{schedule ? '编辑安排' : '添加安排'}</h2><button type="button" className="sheet-close-icon" aria-label="关闭安排编辑" title="关闭" onClick={onClose} disabled={pending}><X size={20} /></button></header><form onSubmit={(event) => { event.preventDefault(); if (!valid || !dirty) return; onSave({ title: title.trim(), scheduled_date: scheduledDate, scheduled_time: scheduledTime }); }}><div className="custom-schedule-settings-group"><label className="custom-schedule-settings-row custom-schedule-title-row"><span className="custom-schedule-settings-label">安排事项</span><input aria-label="安排事项名称" value={title} onChange={(event) => setTitle(event.target.value)} maxLength={200} required placeholder="例如：提交课程作业" /></label><label className="custom-schedule-settings-row custom-schedule-native-row"><span className="custom-schedule-settings-label">日期</span><span className="custom-schedule-settings-value">{formatScheduleDate(scheduledDate)}<ChevronRight size={18} aria-hidden="true" /></span><input aria-label="安排日期" type="date" min={initialDate} value={scheduledDate} onChange={(event) => setScheduledDate(event.target.value)} required /></label><label className="custom-schedule-settings-row custom-schedule-native-row"><span className="custom-schedule-settings-label">时间</span><span className="custom-schedule-settings-value">{scheduledTime}<ChevronRight size={18} aria-hidden="true" /></span><input aria-label="安排时间" type="time" value={scheduledTime} onChange={(event) => setScheduledTime(event.target.value)} required /></label></div><small className="custom-schedule-footer">只能添加今天及以后的安排；时间仅用于当天排序，不会触发系统通知。</small><button type="submit" className="custom-schedule-save" disabled={pending || !valid || !dirty}>{pending ? '保存中…' : '保存安排'}</button>{error && <p className="error">{error.message}</p>}</form></section></div>;
}

function GradeImportSheet({ preview, pending, error, onClose, onConfirm }: { preview: GradeImportPreview; pending: boolean; error: Error | null; onClose: () => void; onConfirm: (preview: GradeImportPreview) => void }) {
  useModalOpenState(onClose, pending);
  const [items, setItems] = useState(preview.grades);
  useEffect(() => setItems(preview.grades), [preview]);
  const updateItem = (index: number, key: 'course_name' | 'score' | 'credits' | 'grade_point', value: string) => setItems((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, [key]: key === 'credits' || key === 'grade_point' ? (value.trim() ? Number(value) : null) : value } : item));
  return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet grade-import-sheet" role="dialog" aria-modal="true" aria-label="成绩导入预览" onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>成绩导入预览</h2><button type="button" className="sheet-close-icon" aria-label="关闭成绩导入预览" title="关闭" onClick={onClose} disabled={pending}><X size={20} /></button></header><p className="muted">识别到 {items.length} 门成绩，归入 {preview.source_term_id}。确认后将替换该学期现有成绩记录。</p><div className="grade-import-list">{items.map((item, index) => <article key={item.source_grade_id} className="grade-import-item"><label>课程名称<input value={item.course_name} onChange={(event) => updateItem(index, 'course_name', event.target.value)} required /></label><div><label>成绩<input value={item.score ?? ''} onChange={(event) => updateItem(index, 'score', event.target.value)} /></label><label>学分<input type="number" min="0" step="0.1" value={item.credits ?? ''} onChange={(event) => updateItem(index, 'credits', event.target.value)} /></label><label>绩点<input type="number" min="0" step="0.1" value={item.grade_point ?? ''} onChange={(event) => updateItem(index, 'grade_point', event.target.value)} /></label></div></article>)}</div><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={pending}>取消</button><button type="button" disabled={pending || items.some((item) => !item.course_name.trim())} onClick={() => onConfirm({ ...preview, grades: items })}>{pending ? '正在保存…' : '确认导入成绩'}</button></div>{error && <p className="error">导入失败：{error.message}</p>}</section></div>;
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

function Timetable({ appearance }: { appearance: 'light' | 'dark' }) {
  const queryClient = useQueryClient();
  const { terms } = useTerms();
  const profile = useQuery({ queryKey: ['profile'], queryFn: api.profile });
  const [termId, setTermId] = useState('');
  const [weekAnchor, setWeekAnchor] = useState(() => new Date());
  const [selectedSession, setSelectedSession] = useState<Session | null>(null);
  const [pendingSlot, setPendingSlot] = useState<TimetableSlot | null>(null);
  const [manualEditor, setManualEditor] = useState<{ courseId?: number; initial: ManualCourseInput } | null>(null);
  const [deletingManualCourse, setDeletingManualCourse] = useState<Session | null>(null);
  const selected = termId || terms.data?.find((term) => term.is_current)?.source_term_id || terms.data?.find((term) => term.source_term_id === '2026-2027-1')?.source_term_id || '';
  const selectedTerm = terms.data?.find((term) => term.source_term_id === selected);
  const selectedWeekStart = mondayOf(weekAnchor);
  const selectedTermStart = selectedTerm?.start_date ? mondayOf(dateFromKey(selectedTerm.start_date)) : null;
  const selectedWeekNumber = selectedTermStart && selectedWeekStart >= selectedTermStart ? Math.floor((selectedWeekStart.getTime() - selectedTermStart.getTime()) / 604800000) + 1 : null;
  const sessions = useQuery({ queryKey: ['sessions', selectedTerm?.id], queryFn: () => api.sessions(selectedTerm?.id) });
  const periods = useQuery({ queryKey: ['period-times'], queryFn: api.periodTimes });
  const [courseColors, setCourseColors] = useState<Record<string, string>>({});
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
      setDeletingManualCourse(null);
      await queryClient.invalidateQueries({ queryKey: ['sessions'] });
    },
  });
  return <main className={`timetable-page timetable-page-fullscreen${appearance === 'dark' ? ' timetable-page-dark' : ''}`}>
    <header className="timetable-fullscreen-toolbar">
      <label className="timetable-fullscreen-term"><span><b>{selectedWeekNumber ? `第 ${selectedWeekNumber} 周` : '假期中'}</b><small>{selectedTerm?.display_name ?? '选择学期'}</small></span><ChevronDown size={17} aria-hidden="true" /><select aria-label="选择当前学期" value={selected} disabled={!terms.data?.length} onChange={(event) => setTermId(event.target.value)}><option value="">选择学期</option>{terms.data?.map((term) => <option key={term.source_term_id} value={term.source_term_id}>{term.display_name}</option>)}</select></label>
      <nav aria-label="课程表操作"><button type="button" aria-label="上一周" onClick={() => setWeekAnchor((date) => moveWeekInTerm(date, -1, selectedTerm))}><ChevronLeft size={21} /></button><button type="button" className="timetable-fullscreen-today" onClick={() => setWeekAnchor(new Date())}>今天</button><button type="button" aria-label="下一周或开学周" title={selectedTerm?.start_date && mondayOf(weekAnchor) < mondayOf(dateFromKey(selectedTerm.start_date)) ? `跳到 ${selectedTerm.start_date} 开学周` : '下一周'} onClick={() => setWeekAnchor((date) => moveWeekInTerm(date, 1, selectedTerm))}><ChevronRight size={21} /></button></nav>
    </header>
{terms.isLoading ? <p className="muted timetable-fullscreen-notice">正在读取本地学期列表…</p> : terms.data?.length === 0 ? <div className="timetable-fullscreen-notice"><Empty text="请在“设置 → 数据与导入”中导入教务系统打印的课程表文件。" /></div> : <TimetableStage sessions={sessions.data ?? []} term={selectedTerm} periods={periods.data ?? DEFAULT_PERIODS} anchor={weekAnchor} todayKey={localDateKey(new Date())} courseColors={selectedTerm && sessions.data ? resolveCourseColorMap(selectedTerm, sessions.data) : courseColors} selectedSessionId={selectedSession?.id ?? null} pendingSlot={pendingSlot} onWeekChange={setWeekAnchor} onSelect={(session) => { setPendingSlot(null); setSelectedSession(session); }} onSelectSlot={setPendingSlot} onAddSlot={(slot) => { if (!selectedTerm) return; setManualEditor({ initial: { term_id: selectedTerm.id, course_name: '', week_expression: `${Math.max(1, Math.floor((mondayOf(weekAnchor).getTime() - mondayOf(dateFromKey(selectedTerm.start_date ?? localDateKey(weekAnchor))).getTime()) / 604800000) + 1)}周`, weekday: slot.weekday, start_period: slot.startPeriod, end_period: slot.endPeriod, classroom: '', teacher: '' } }); }} timetableBackground={profile.data?.timetable_background_data_url ?? null} />}
    {terms.error && <p className="error">读取本地课表失败：{String(terms.error)}</p>}
    {selectedSession && <DetailSheet title={selectedSession.course_name} eyebrow="课程详情" showTitle={false} className="detail-sheet-with-eyebrow detail-sheet-list-title" dark={appearance === 'dark'} showHandle={false} onClose={() => setSelectedSession(null)}><div className="icon-detail-list"><IconDetailRow icon={<BookOpen size={20} />} label="课程名称" value={selectedSession.course_name} /><IconDetailRow icon={<Clock3 size={20} />} label="上课时间" value={`${selectedSession.session_date} ${formatTime(selectedSession.start_datetime)}—${formatTime(selectedSession.end_datetime)}`} /><IconDetailRow icon={<MapPin size={20} />} label="教室" value={selectedSession.classroom ?? '未提供'} /><IconDetailRow icon={<UserRound size={20} />} label="教师" value={selectedSession.teacher ?? '未提供'} /><IconDetailRow icon={<CalendarDays size={20} />} label="周次" value={selectedSession.week_expression ?? '未提供'} /></div>{selectedSession.source === 'MANUAL' && selectedSession.manual_course_id && <div className="manual-course-detail-actions"><small>手动添加课程</small><span><button type="button" onClick={() => { if (!selectedTerm) return; setSelectedSession(null); setManualEditor({ courseId: selectedSession.manual_course_id!, initial: { term_id: selectedSession.term_id ?? selectedTerm.id, course_name: selectedSession.course_name, teacher: selectedSession.teacher, classroom: selectedSession.classroom, weekday: selectedSession.weekday ?? (new Date(`${selectedSession.session_date}T12:00:00`).getDay() || 7), start_period: selectedSession.start_period ?? 1, end_period: selectedSession.end_period ?? 1, week_expression: selectedSession.week_expression ?? '' } }); }}>编辑</button><button type="button" className="danger-button" onClick={() => setDeletingManualCourse(selectedSession)}>删除</button></span></div>}</DetailSheet>}
    {manualEditor && <ManualCourseSheetV2 initial={manualEditor.initial} periods={periods.data ?? DEFAULT_PERIODS} pending={saveManualCourse.isPending} error={saveManualCourse.error} editing={Boolean(manualEditor.courseId)} dark={appearance === 'dark'} onClose={() => setManualEditor(null)} onSave={(payload) => saveManualCourse.mutate({ courseId: manualEditor.courseId, payload })} />}
    {deletingManualCourse?.manual_course_id && <ViewportSheetPortal><ConfirmDialog title={`删除“${deletingManualCourse.course_name}”？`} description="删除后无法恢复这门手动添加的课程。" confirmLabel="删除课程" pending={deleteManualCourse.isPending} onCancel={() => setDeletingManualCourse(null)} onConfirm={() => deleteManualCourse.mutate(deletingManualCourse.manual_course_id!)} /></ViewportSheetPortal>}
  </main>;
}

function AiAnalysisReport({ content }: { content: string }) {
  return <div className="grade-ai-markdown"><ReactMarkdown components={{ h2: ({ children }) => <h2>{children}</h2>, ul: ({ children }) => <ul>{children}</ul>, li: ({ children }) => <li>{children}</li>, p: ({ children }) => <p>{children}</p>, strong: ({ children }) => <strong>{children}</strong> }}>{content}</ReactMarkdown></div>;
}

function Grades({ appearance }: { appearance: 'light' | 'dark' }) {
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { scrollRef: gradesScrollRef, headerRef: gradesHeaderRef } = useCollapsiblePageTitle();
  const { terms } = useTerms();
  const [termId, setTermId] = useState('');
  const [selectedGrade, setSelectedGrade] = useState<Grade | null>(null);
  const [analysis, setAnalysis] = useState<GradeAiAnalysis | null>(null);
  const [analysisDetailOpen, setAnalysisDetailOpen] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [deleteGradesConfirm, setDeleteGradesConfirm] = useState(false);
  const now = new Date();
  const academicYear = now.getMonth() >= 8 ? `${now.getFullYear()}-${now.getFullYear() + 1}-1` : `${now.getFullYear() - 1}-${now.getFullYear()}-2`;
  const selected = termId || terms.data?.find((term) => term.is_current)?.source_term_id || terms.data?.find((term) => term.source_term_id === academicYear)?.source_term_id || '';
  const selectedTerm = terms.data?.find((term) => term.source_term_id === selected);
  const grades = useQuery({ queryKey: ['grades', selectedTerm?.id], queryFn: () => api.grades(selectedTerm?.id) });
  const showGradeListEmptyState = Boolean(selectedTerm && grades.isSuccess && !grades.data?.length);
  const summary = useQuery({ queryKey: ['summary', selectedTerm?.id], queryFn: () => api.summary(selectedTerm?.id) });
  const analysisHistory = useQuery({ queryKey: ['grade-ai-analyses', selectedTerm?.id], queryFn: () => api.gradeAiAnalyses(selectedTerm?.id), enabled: Boolean(selectedTerm) });
  useEffect(() => { setAnalysis(null); setAnalysisDetailOpen(false); setHistoryOpen(false); setDeleteGradesConfirm(false); }, [selectedTerm?.id]);
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
    <section className="grade-import-actions" aria-label="当前学期">
      <div className="grade-import-group">
        <label className="grade-import-row grade-current-term-trigger">
          <span className="grade-import-row-content"><b>当前学期</b><small>选择要查看成绩与分析的学期</small></span>
          <span className="grade-current-term-value">{selectedTerm?.display_name ?? '选择学期'}<ChevronRight size={18} /></span>
          <select className="grade-current-term-native" aria-label="当前学期" value={selected} onChange={(event) => setTermId(event.target.value)}><option value="">选择学期</option>{terms.data?.map((term) => <option key={term.source_term_id} value={term.source_term_id}>{term.display_name}</option>)}</select>
        </label>
        {Boolean(selectedTerm && grades.data?.length) && <button type="button" className="grade-delete-button" onClick={() => { deleteGrades.reset(); setDeleteGradesConfirm(true); }}><Trash2 size={16} />删除本学期成绩</button>}
      </div>
      {deleteGrades.error && <p className="error">删除失败：{deleteGrades.error.message}</p>}
    </section>
    <section className="grade-overview" aria-label="成绩概览"><h2>成绩概览</h2><div className="grade-overview-grid"><Metric label="已获学分" value={summary.data?.earned_credits ?? '—'} /><Metric label="平均成绩" value={summary.data?.average_score?.toFixed(1) ?? '—'} /><Metric label="绩点" value={summary.data?.gpa?.toFixed(2) ?? '—'} /><Metric label="不及格" value={summary.data?.failed_courses ?? '—'} /></div></section>
    <section className="grade-ai-actions" aria-label="AI 成绩分析"><h2>AI 成绩分析</h2><div className="grade-ai-group"><button type="button" className="grade-ai-primary-row" disabled={!selectedTerm || analyze.isPending || (!analysis && !grades.data?.length)} onClick={() => { if (analysis) { setAnalysisDetailOpen(true); return; } analyze.reset(); analyze.mutate(false); }}><span><b>{analysis ? '查看 AI 成绩分析' : '生成 AI 成绩分析'}</b><small>{analysis ? '查看当前学期已生成的分析结果' : analyze.isPending ? '正在分析当前学期成绩…' : '基于当前学期成绩生成学习建议'}</small></span><span className="grade-ai-row-trailing">{analyze.isPending ? '分析中…' : <ChevronRight size={18} />}</span></button><button type="button" className="grade-ai-history-row" disabled={!selectedTerm} aria-expanded={historyOpen} onClick={() => setHistoryOpen((open) => !open)}><span><b>历史分析</b><small>{analysisHistory.data?.length ? `本学期共 ${analysisHistory.data.length} 条记录` : '查看本学期已生成的分析'}</small></span><ChevronRight size={18} /></button>{historyOpen && <GradeAiAnalysisHistoryPanel history={analysisHistory.data ?? []} loading={analysisHistory.isLoading} error={analysisHistory.error} onSelect={(entry) => { setAnalysis({ ...entry, cached: true }); setAnalysisDetailOpen(true); }} />}</div><small className="grade-ai-footer">仅在你点击生成后，将当前学期的课程名称、成绩、学分和绩点发送给已配置的模型服务。</small></section>
    {analyze.error && <p className="error">分析失败：{analyze.error.message}</p>}
    {showGradeListEmptyState ? <section className="grade-list-empty" aria-label="课程成绩为空"><span><b>暂无课程成绩</b><small>导入成绩文件后，这里会显示每门课程的成绩与详情。</small></span><button type="button" onClick={() => navigate('/settings', { state: { settingsSection: 'data' } })}>前往数据与导入<ChevronRight size={17} aria-hidden="true" /></button></section> : <section className="grade-list-section" aria-label="课程成绩"><h2>课程成绩</h2><div className="grade-list">{grades.data?.map((grade: Grade) => <button type="button" className={`grade-list-item${grade.id === selectedGrade?.id ? ' is-detail-open' : ''}`} key={grade.id} onClick={() => setSelectedGrade(grade)}><span className="grade-list-main"><b>{grade.course_name}</b><small>{grade.course_type ?? '课程性质未提供'} · {grade.credits ?? '—'} 学分 · GPA {grade.grade_point ?? '—'}</small></span><span className="grade-list-score"><small>成绩</small><b>{grade.score ?? '未公布'}</b></span></button>)}</div></section>}
    {summary.data?.gpa_note && <small className="muted">{summary.data.gpa_note}</small>}
    {terms.error && <p className="error">读取成绩分析失败：{String(terms.error)}</p>}
    {analysis && analysisDetailOpen && <DetailSheet title="分析结果" dark={appearance === 'dark'} onClose={() => setAnalysisDetailOpen(false)}><div className="grade-ai-detail-meta"><div className="icon-detail-list grade-ai-detail-info" aria-label="分析元信息"><IconDetailRow icon={<Sparkles size={20} />} label="分析模型" value={analysis.model} /><IconDetailRow icon={<Database size={20} />} label="结果来源" value={analysis.cached ? '已使用当前成绩快照的缓存结果' : '本次实时生成'} /><IconDetailRow icon={<Clock3 size={20} />} label="生成时间" value={new Date(analysis.created_at).toLocaleString('zh-CN', { dateStyle: 'medium', timeStyle: 'short' })} /></div><button type="button" className="secondary-button" disabled={analyze.isPending} onClick={() => { analyze.reset(); analyze.mutate(true); }}>{analyze.isPending ? '生成中…' : '重新生成'}</button></div><AiAnalysisReport content={analysis.content} /></DetailSheet>}
    {selectedGrade && <DetailSheet title={selectedGrade.course_name} eyebrow="成绩详情" showTitle={false} className="detail-sheet-with-eyebrow detail-sheet-list-title" dark={appearance === 'dark'} onClose={() => setSelectedGrade(null)}><div className="icon-detail-list grade-detail-list"><IconDetailRow icon={<BookOpen size={20} />} label="课程名称" value={selectedGrade.course_name} /><div className="grade-score-summary" aria-label="成绩摘要"><div className="grade-score-summary-total"><span><Award size={19} aria-hidden="true" />总评成绩</span><b>{selectedGrade.score ?? '未公布'}</b></div><div><small>期末成绩</small><b>{selectedGrade.final_exam_score ?? '未提供'}</b></div><div><small>平时成绩</small><b>{selectedGrade.usual_score ?? '未提供'}</b></div></div><IconDetailRow icon={<GraduationCap size={20} />} label="学分 / 绩点" value={`${selectedGrade.credits ?? '—'} / ${selectedGrade.grade_point ?? '—'}`} /><IconDetailRow icon={<BookOpen size={20} />} label="课程性质" value={selectedGrade.course_type ?? '未提供'} /><IconDetailRow icon={<FileText size={20} />} label="考试性质" value={selectedGrade.exam_type ?? '未提供'} /><IconDetailRow icon={<RotateCcw size={20} />} label="补考 / 重修" value={`${selectedGrade.makeup_flag ? '补考' : '否'} / ${selectedGrade.retake_flag ? '重修' : '否'}`} /></div></DetailSheet>}
    {deleteGradesConfirm && selectedTerm && <ViewportSheetPortal><ConfirmDialog title={`删除 ${selectedTerm.display_name} 的成绩？`} description={`将删除该学期已导入的全部 ${grades.data?.length ?? 0} 门成绩，以及对应的 AI 分析缓存。此操作无法撤销，其他学期不会受影响。`} confirmLabel="确认删除" pending={deleteGrades.isPending} onCancel={() => setDeleteGradesConfirm(false)} onConfirm={() => deleteGrades.mutate()} /></ViewportSheetPortal>}
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
  const [clearConfirmOpen, setClearConfirmOpen] = useState(false);
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
  const clear = useMutation({ mutationFn: api.clearAiSettings, onSuccess: async () => { setApiKey(''); setConnectionNotice(null); setClearConfirmOpen(false); await queryClient.invalidateQueries({ queryKey: ['ai-settings'] }); } });
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
      <button className="ai-settings-save settings-group-save-row" type="submit" disabled={!dirty || save.isPending || incomplete}>{save.isPending ? '正在保存…' : '保存配置'}</button>
    </div>{(modelLookupNotice || connectionNotice) && <div className="ai-settings-feedback" aria-live="polite">{modelLookupNotice && <p className="ai-settings-notice">{modelLookupNotice}</p>}{connectionNotice && <p className="ai-settings-notice">{connectionNotice}</p>}</div>}<p className="ai-settings-footer">{syncedLabel}</p></section>
    {isSavedConfiguration && <section className="ai-settings-section" aria-labelledby="ai-danger-heading"><h2 id="ai-danger-heading">危险操作</h2><div className="ai-settings-group"><button type="button" className="ai-settings-row ai-settings-destructive-row" disabled={clear.isPending} onClick={() => setClearConfirmOpen(true)}><span><b>清除模型服务配置</b><small>不会清除已导入的成绩或分析历史</small></span><ChevronRight size={18} aria-hidden="true" /></button></div></section>}
    {error && <p className="ai-settings-error" role="alert">{error}</p>}
  </form>{clearConfirmOpen && <ViewportSheetPortal><ConfirmDialog title="清除模型服务配置？" description="已保存的服务地址、模型和 API Key 配置将被移除，无法恢复。成绩与分析历史不会受影响。" confirmLabel="确认清除" pending={clear.isPending} onCancel={() => setClearConfirmOpen(false)} onConfirm={() => clear.mutate()} /></ViewportSheetPortal>}{editor && <AiSettingsTextSheet kind={editor} value={editor === 'provider' ? provider : editor === 'base-url' ? baseUrl : apiKey} configured={isSavedConfiguration} apiKeyHint={settings.data?.api_key_hint ?? null} dark={dark} onClose={() => setEditor(null)} onConfirm={(value) => { if (editor === 'provider') { setProvider(value); resetModelLookup(); } else if (editor === 'base-url') { setBaseUrl(value); resetModelLookup(); } else { setApiKey(value); resetModelLookup(); } setEditor(null); }} />}</>;
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
  return <><section className="ai-settings-section ai-history-settings-section" aria-labelledby="ai-history-heading"><h2 id="ai-history-heading">分析历史缓存</h2><p className="ai-settings-footer">保存生成的文字、时间和模型名称，便于回看。</p><div className="ai-settings-group"><button type="button" className="ai-settings-row ai-settings-destructive-row" disabled={clearHistory.isPending} onClick={() => setConfirmClear(true)}><span><b>{clearHistory.isPending ? '正在清除…' : '清除历史分析'}</b><small>不会影响成绩或模型服务配置</small></span><ChevronRight size={18} aria-hidden="true" /></button></div>{clearHistory.isSuccess && <p className="ai-settings-notice">已清除 {clearHistory.data.deleted} 条历史分析。</p>}{clearHistory.error && <p className="ai-settings-error" role="alert">清除失败：{clearHistory.error.message}</p>}</section><p className="ai-settings-page-footer">上传的原始成绩文件不会保留。</p>{confirmClear && <ViewportSheetPortal><ConfirmDialog title="清除全部 AI 分析历史？" description="这会删除已保存的 AI 分析文字，无法恢复；课程、成绩和模型配置不会受到影响。" confirmLabel="确认清除" pending={clearHistory.isPending} onCancel={() => setConfirmClear(false)} onConfirm={() => clearHistory.mutate()} /></ViewportSheetPortal>}</>;
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

const PASSKEY_SWIPE_WIDTH = 84;
const PASSKEY_SWIPE_THRESHOLD = 36;

function SwipeablePasskeyCredentialRow({ credential, open, onOpenChange, onRemove }: { credential: PasskeyCredential; open: boolean; onOpenChange: (open: boolean) => void; onRemove: (credential: PasskeyCredential) => void }) {
  const gesture = useRef<{ pointerId: number; startX: number; startY: number; startOffset: number; lastOffset: number; axis: 'horizontal' | 'vertical' | null } | null>(null);
  const [dragging, setDragging] = useState(false);
  const [dragOffset, setDragOffset] = useState(0);
  const translateX = dragging ? dragOffset : open ? -PASSKEY_SWIPE_WIDTH : 0;
  const handlePointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.pointerType === 'mouse') return;
    gesture.current = { pointerId: event.pointerId, startX: event.clientX, startY: event.clientY, startOffset: open ? -PASSKEY_SWIPE_WIDTH : 0, lastOffset: open ? -PASSKEY_SWIPE_WIDTH : 0, axis: null };
    event.currentTarget.setPointerCapture(event.pointerId);
  };
  const handlePointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    const currentGesture = gesture.current;
    if (!currentGesture || currentGesture.pointerId !== event.pointerId) return;
    const deltaX = event.clientX - currentGesture.startX;
    const deltaY = event.clientY - currentGesture.startY;
    if (!currentGesture.axis) {
      if (Math.max(Math.abs(deltaX), Math.abs(deltaY)) < 7) return;
      currentGesture.axis = Math.abs(deltaX) > Math.abs(deltaY) ? 'horizontal' : 'vertical';
      if (currentGesture.axis === 'horizontal') {
        if (!open) onOpenChange(false);
        setDragging(true);
      }
    }
    if (currentGesture.axis !== 'horizontal') return;
    event.preventDefault();
    const offset = Math.max(-PASSKEY_SWIPE_WIDTH, Math.min(0, currentGesture.startOffset + deltaX));
    currentGesture.lastOffset = offset;
    setDragOffset(offset);
  };
  const finishGesture = (event: ReactPointerEvent<HTMLDivElement>) => {
    const currentGesture = gesture.current;
    if (!currentGesture || currentGesture.pointerId !== event.pointerId) return;
    if (currentGesture.axis === 'horizontal') onOpenChange(currentGesture.lastOffset <= -PASSKEY_SWIPE_THRESHOLD);
    setDragging(false);
    gesture.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
  };
  return <div className={`passkey-swipe-row${open ? ' is-open' : ''}${open || dragging ? ' is-revealed' : ''}`}>
    <div className="passkey-swipe-actions" aria-hidden={!open && !dragging}><button type="button" tabIndex={open ? 0 : -1} onClick={() => { onOpenChange(false); onRemove(credential); }}>移除</button></div>
    <div className={`passkey-credential-row${dragging ? ' is-dragging' : ''}`} style={{ transform: `translate3d(${translateX}px,0,0)` }} onPointerDown={handlePointerDown} onPointerMove={handlePointerMove} onPointerUp={finishGesture} onPointerCancel={finishGesture}>
      <span><b>{credential.label}</b><small>{credential.device_type === 'multi_device' ? '可同步通行密钥' : '设备通行密钥'} · {credential.last_used_at ? `最近使用 ${new Date(credential.last_used_at).toLocaleDateString('zh-CN')}` : `添加于 ${new Date(credential.created_at).toLocaleDateString('zh-CN')}`}</small></span>
      <button type="button" className="passkey-desktop-remove" onClick={() => onRemove(credential)}>移除</button>
    </div>
  </div>;
}

function PasskeyRegistrationSheet({ pending, error, onClose, onSubmit }: { pending: boolean; error: Error | null; onClose: () => void; onSubmit: (payload: { label: string; password: string }) => void }) {
  useModalOpenState(onClose, pending);
  const [label, setLabel] = useState('此设备');
  const [password, setPassword] = useState('');
  const submit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    onSubmit({ label: label.trim() || '此设备', password });
  };
  return <ViewportSheetPortal><div className="sheet-mask sheet-mask-viewport passkey-registration-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet passkey-registration-sheet" role="dialog" aria-modal="true" aria-labelledby="passkey-registration-title" onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><div><h2 id="passkey-registration-title">添加通行密钥</h2><p>为这台设备创建可用于登录的通行密钥。</p></div><button type="button" className="sheet-close-icon" aria-label="关闭添加通行密钥" title="关闭" disabled={pending} onClick={onClose}><X size={20} /></button></header><form onSubmit={submit}><div className="passkey-registration-group"><label><span>设备名称</span><input value={label} onChange={(event) => setLabel(event.target.value)} maxLength={64} placeholder="例如：我的 iPhone" autoComplete="off" required /></label><label><span>当前密码</span><input value={password} onChange={(event) => setPassword(event.target.value)} type="password" autoComplete="current-password" required /></label></div><p className="passkey-registration-note">为防止已解锁设备被他人绑定凭据，添加时需再次验证当前密码。</p>{error && <p className="passkey-registration-error" role="alert">{error.message}</p>}<div className="passkey-registration-actions"><button type="button" className="secondary-button" disabled={pending} onClick={onClose}>取消</button><button type="submit" disabled={pending}>{pending ? '正在验证…' : '继续并验证'}</button></div></form></section></div></ViewportSheetPortal>;
}

function PasskeyRemovalSheet({ credential, pending, error, onClose, onSubmit }: { credential: PasskeyCredential; pending: boolean; error: Error | null; onClose: () => void; onSubmit: (password: string) => void }) {
  useModalOpenState(onClose, pending);
  const [password, setPassword] = useState('');
  return <ViewportSheetPortal><div className="sheet-mask sheet-mask-viewport passkey-registration-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet passkey-registration-sheet passkey-removal-sheet" role="dialog" aria-modal="true" aria-labelledby="passkey-removal-title" onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><div><h2 id="passkey-removal-title">移除“{credential.label}”</h2><p>移除后，这台设备将不能再使用此通行密钥登录。</p></div><button type="button" className="sheet-close-icon" aria-label="关闭移除通行密钥" title="关闭" disabled={pending} onClick={onClose}><X size={20} /></button></header><form onSubmit={(event) => { event.preventDefault(); onSubmit(password); }}><div className="passkey-registration-group"><label><span>当前密码</span><input value={password} onChange={(event) => setPassword(event.target.value)} type="password" autoComplete="current-password" required /></label></div><p className="passkey-registration-note">为保护账号安全，移除已登记的通行密钥前需要再次验证当前密码。</p>{error && <p className="passkey-registration-error" role="alert">{error.message}</p>}<div className="passkey-registration-actions"><button type="button" className="secondary-button" disabled={pending} onClick={onClose}>取消</button><button type="submit" className="passkey-removal-confirm" disabled={pending}>{pending ? '正在移除…' : '确认移除'}</button></div></form></section></div></ViewportSheetPortal>;
}

function PasskeySettings() {
  const queryClient = useQueryClient();
  const passkeys = useQuery({ queryKey: ['passkeys'], queryFn: api.passkeys });
  const [registrationOpen, setRegistrationOpen] = useState(false);
  const [removing, setRemoving] = useState<PasskeyCredential | null>(null);
  const [openPasskeyId, setOpenPasskeyId] = useState<number | null>(null);
  const passkeyGroupRef = useRef<HTMLDivElement>(null);
  const register = useMutation({
    mutationFn: async ({ label, password }: { label: string; password: string }) => {
      const options = await api.passkeyRegistrationOptions(password, label);
      const credential = await createPasskeyCredential(options.public_key);
      return api.verifyPasskeyRegistration({ challenge_id: options.challenge_id, credential, label });
    },
    onSuccess: async () => {
      setRegistrationOpen(false);
      await queryClient.invalidateQueries({ queryKey: ['passkeys'] });
    },
  });
  const revoke = useMutation({
    mutationFn: ({ id, password }: { id: number; password: string }) => api.deletePasskey(id, password),
    onSuccess: async () => {
      setRemoving(null); setOpenPasskeyId(null);
      await queryClient.invalidateQueries({ queryKey: ['passkeys'] });
    },
  });
  const unsupported = !passkeySupported();
  const error = passkeys.error?.message;
  const beginRemoval = (credential: PasskeyCredential) => {
    setOpenPasskeyId(null);
    setRemoving(credential);
    revoke.reset();
  };
  useEffect(() => {
    if (openPasskeyId === null) return;
    const group = passkeyGroupRef.current;
    const scrollContainer = group?.closest('main');
    const closeSwipeActions = () => setOpenPasskeyId(null);
    scrollContainer?.addEventListener('scroll', closeSwipeActions, { passive: true });
    const closeWhenPressingOutside = (event: PointerEvent) => {
      if (group && event.target instanceof Node && !group.contains(event.target)) closeSwipeActions();
    };
    document.addEventListener('pointerdown', closeWhenPressingOutside, true);
    return () => {
      scrollContainer?.removeEventListener('scroll', closeSwipeActions);
      document.removeEventListener('pointerdown', closeWhenPressingOutside, true);
    };
  }, [openPasskeyId]);
  return <section className="account-settings-section passkey-settings-section" aria-labelledby="passkey-settings-heading">
    <h2 id="passkey-settings-heading">通行密钥</h2>
    <div ref={passkeyGroupRef} className="account-settings-group passkey-settings-group">
      {passkeys.isLoading ? <div className="account-authentication-row"><span><b>正在读取通行密钥…</b></span></div> : passkeys.data?.length ? passkeys.data.map((item) => <SwipeablePasskeyCredentialRow key={item.id} credential={item} open={openPasskeyId === item.id} onOpenChange={(open) => setOpenPasskeyId(open ? item.id : null)} onRemove={beginRemoval} />) : <div className="account-authentication-row"><span><b>尚未添加通行密钥</b><small>添加后可使用设备生物识别或设备 PIN 登录。</small></span></div>}
      <button type="button" className="passkey-add-row" disabled={unsupported} aria-describedby={unsupported ? 'passkey-support-hint' : undefined} onClick={() => { setOpenPasskeyId(null); register.reset(); setRegistrationOpen(true); }}><span><Plus size={18} aria-hidden="true" /><b>添加通行密钥</b></span></button>
    </div>
    {unsupported && <p id="passkey-support-hint" className="account-settings-footer">当前环境不支持通行密钥；本地请使用 <code>http://localhost:5173</code>，正式环境需使用 HTTPS。</p>}
    {error && <p className="account-settings-error" role="alert">{error}</p>}
    {registrationOpen && <PasskeyRegistrationSheet pending={register.isPending} error={register.error} onClose={() => { if (!register.isPending) setRegistrationOpen(false); }} onSubmit={(payload) => register.mutate(payload)} />}
    {removing && <PasskeyRemovalSheet credential={removing} pending={revoke.isPending} error={revoke.error} onClose={() => { if (!revoke.isPending) setRemoving(null); }} onSubmit={(password) => revoke.mutate({ id: removing.id, password })} />}
  </section>;
}

type SettingsSection = 'account' | 'time' | 'personal' | 'data' | 'analysis' | 'about';

function Settings({ appearanceMode, resolvedAppearanceMode, onAppearanceModeChange, layoutMode, onLayoutModeChange, routeEntering }: { appearanceMode: AppearanceMode; resolvedAppearanceMode: 'light' | 'dark'; onAppearanceModeChange: (mode: AppearanceMode) => void; layoutMode: LayoutMode; onLayoutModeChange: (mode: LayoutMode) => void; routeEntering: boolean }) {
  const queryClient = useQueryClient();
  const location = useLocation();
  const { scrollRef: settingsScrollRef, headerRef: settingsHeaderRef } = useCollapsiblePageTitle();
  const profile = useQuery({ queryKey: ['profile'], queryFn: api.profile });
  const terms = useQuery({ queryKey: ['terms'], queryFn: api.terms });
  const periods = useQuery({ queryKey: ['period-times'], queryFn: api.periodTimes });
  const [selectedTermId, setSelectedTermId] = useState<number | null>(null);
  const [selectedPeriodNumber, setSelectedPeriodNumber] = useState<number | null>(null);
  const [logoutConfirm, setLogoutConfirm] = useState(false);
  const [settingsSection, setSettingsSection] = useState<SettingsSection | null>(() => (location.state as { settingsSection?: string } | null)?.settingsSection === 'data' ? 'data' : null);
  const [settingsTransitionDirection, setSettingsTransitionDirection] = useState<'forward' | 'backward'>('forward');
  const [displayName, setDisplayName] = useState('用户');
  const [newAvatar, setNewAvatar] = useState<string | null | undefined>(undefined);
  const [avatarCropSource, setAvatarCropSource] = useState<string | null>(null);
  const [newTimetableBackground, setNewTimetableBackground] = useState<string | null | undefined>(undefined);
  const [timetableBackgroundCropSource, setTimetableBackgroundCropSource] = useState<string | null>(null);
  const [newHomeWallpaper, setNewHomeWallpaper] = useState<string | null | undefined>(undefined);
  const [homeWallpaperCropSource, setHomeWallpaperCropSource] = useState<string | null>(null);
  const [avatarError, setAvatarError] = useState<string | null>(null);
  const [avatarEditorOpen, setAvatarEditorOpen] = useState(false);
  const [nameEditorOpen, setNameEditorOpen] = useState(false);
  const [timetableBackgroundEditorOpen, setTimetableBackgroundEditorOpen] = useState(false);
  const [homeWallpaperEditorOpen, setHomeWallpaperEditorOpen] = useState(false);
  const preferredTerm = terms.data?.find((term) => term.source_term_id === currentAcademicTermId()) ?? terms.data?.find((term) => term.is_current) ?? terms.data?.[0];
  useEffect(() => { if (profile.data) setDisplayName(profile.data.display_name); }, [profile.data]);
  useEffect(() => () => { if (avatarCropSource) URL.revokeObjectURL(avatarCropSource); }, [avatarCropSource]);
  useEffect(() => () => { if (timetableBackgroundCropSource) URL.revokeObjectURL(timetableBackgroundCropSource); }, [timetableBackgroundCropSource]);
  useEffect(() => () => { if (homeWallpaperCropSource) URL.revokeObjectURL(homeWallpaperCropSource); }, [homeWallpaperCropSource]);
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
      if (newTimetableBackground !== undefined) payload.timetable_background_data_url = newTimetableBackground;
      if (newHomeWallpaper !== undefined) payload.home_wallpaper_data_url = newHomeWallpaper;
      return api.updateProfile(payload);
    },
    onSuccess: (updatedProfile) => { setDisplayName(updatedProfile.display_name); setNewAvatar(undefined); setNewTimetableBackground(undefined); setNewHomeWallpaper(undefined); setAvatarError(null); queryClient.setQueryData(['profile'], updatedProfile); queryClient.invalidateQueries({ queryKey: ['profile'] }); },
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
  const choosePortraitBackground = async (file: File | undefined, kind: 'home' | 'timetable') => {
    if (!file) return;
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) { setAvatarError('请选择 PNG、JPEG 或 WebP 格式的图片。'); return; }
    if (file.size > TIMETABLE_BACKGROUND_INPUT_MAX_BYTES) { setAvatarError('原图不能超过 5 MB。'); return; }
    const source = URL.createObjectURL(file);
    try {
      const image = await loadImage(source);
      if (image.naturalWidth * image.naturalHeight > TIMETABLE_BACKGROUND_INPUT_MAX_PIXELS) throw new Error('原图像素不能超过 2500 万，请换一张图片。');
      if (kind === 'home') setHomeWallpaperCropSource(source);
      else setTimetableBackgroundCropSource(source);
      setAvatarError(null);
    } catch (imageError) {
      URL.revokeObjectURL(source);
      setAvatarError(imageError instanceof Error ? imageError.message : '无法读取该图片，请换一张后重试。');
    }
  };
  const chooseTimetableBackground = (file: File | undefined) => choosePortraitBackground(file, 'timetable');
  const chooseHomeWallpaper = (file: File | undefined) => choosePortraitBackground(file, 'home');
  const openSettingsSection = (section: SettingsSection) => { setSettingsTransitionDirection('forward'); setSettingsSection(section); };
  const closeSettingsSection = () => { setSettingsTransitionDirection('backward'); setSettingsSection(null); };
  const sectionTitle = settingsSection === 'account' ? '账号安全' : settingsSection === 'time' ? '时间设置' : settingsSection === 'personal' ? '个性化设置' : settingsSection === 'data' ? '数据与导入' : settingsSection === 'analysis' ? '成绩分析设置' : settingsSection === 'about' ? '关于助手' : '设置';
  const accountTitleCollapsible = settingsSection === 'account';
  const sectionTitleCollapsible = Boolean(settingsSection);
  const rootTitleCollapsible = !settingsSection;
  const settingsPageClassName = `${accountTitleCollapsible ? 'account-settings-page ' : ''}${sectionTitleCollapsible ? 'settings-section-page ' : ''}${resolvedAppearanceMode === 'dark' ? 'settings-page-dark' : ''}`.trim();
  const displayedProfile: Profile = { display_name: displayName.trim() || '用户', avatar_data_url: newAvatar === undefined ? profile.data?.avatar_data_url ?? null : newAvatar, timetable_background_data_url: newTimetableBackground === undefined ? profile.data?.timetable_background_data_url ?? null : newTimetableBackground, home_wallpaper_data_url: newHomeWallpaper === undefined ? profile.data?.home_wallpaper_data_url ?? null : newHomeWallpaper };
  const profileDirty = profile.data ? displayName.trim() !== profile.data.display_name || newAvatar !== undefined || newTimetableBackground !== undefined || newHomeWallpaper !== undefined : false;
  return <Page title={sectionTitle} icon={accountTitleCollapsible ? <KeyRound size={20} /> : !settingsSection ? <SettingsIcon size={20} /> : undefined} action={settingsSection ? <button type="button" className="settings-back settings-back-ios" aria-label="返回设置" onClick={closeSettingsSection}><ChevronLeft size={18} />设置</button> : undefined} mainRef={settingsScrollRef} headerRef={settingsHeaderRef} className={settingsPageClassName} headerClassName={rootTitleCollapsible ? 'collapsible-page-header' : sectionTitleCollapsible ? 'collapsible-page-header settings-section-header settings-detail-header' : undefined} compactTitle={rootTitleCollapsible || sectionTitleCollapsible}>
    {settingsSection === 'personal' && <p className="settings-inline-note">自定义显示模式、页面布局和个人资料。</p>}
    {settingsSection === 'data' && <p className="settings-inline-note">课程表和成绩仅通过你主动选择的导出文件导入，并保存在本地缓存中。</p>}
    {!settingsSection && <div className={settingsTransitionDirection === 'backward' ? 'settings-detail-stage settings-detail-stage-backward' : routeEntering ? 'settings-root-stage' : undefined}><section className="settings-menu" aria-label="设置项目录">
      <section className="settings-menu-group" aria-labelledby="settings-group-account">
        <h2 id="settings-group-account">账户</h2>
        <div className="settings-menu-group-list">
          <button type="button" className="settings-menu-item" onClick={() => openSettingsSection('account')}><span><b><KeyRound size={18} />账号安全</b><small>密码、通行密钥与退出</small></span><span aria-hidden="true">›</span></button>
        </div>
      </section>
      <section className="settings-menu-group" aria-labelledby="settings-group-preferences">
        <h2 id="settings-group-preferences">偏好设置</h2>
        <div className="settings-menu-group-list">
          <button type="button" className="settings-menu-item" onClick={() => openSettingsSection('time')}><span><b><Clock3 size={18} />时间设置</b><small>学期第一周与节次时间</small></span><span aria-hidden="true">›</span></button>
          <button type="button" className="settings-menu-item" onClick={() => openSettingsSection('personal')}><span><b><Palette size={18} />个性化设置</b><small>姓名、头像与独立壁纸</small></span><span aria-hidden="true">›</span></button>
        </div>
      </section>
      <section className="settings-menu-group" aria-labelledby="settings-group-data">
        <h2 id="settings-group-data">数据与助手</h2>
        <div className="settings-menu-group-list">
          <DataSettingsEntry onOpen={() => openSettingsSection('data')} />
          <button type="button" className="settings-menu-item" onClick={() => openSettingsSection('analysis')}><span><b><GraduationCap size={18} />成绩分析设置</b><small>第三方模型服务与 API Key</small></span><span aria-hidden="true">›</span></button>
          <button type="button" className="settings-menu-item" onClick={() => openSettingsSection('about')}><span><b><Info size={18} />关于助手</b><small>版本、数据保护与使用说明</small></span><span aria-hidden="true">›</span></button>
        </div>
      </section>
    </section></div>}
    {settingsSection && <div key={`${settingsSection}-${settingsTransitionDirection}`} className={`settings-detail-stage settings-detail-stage-${settingsTransitionDirection}`}>
    {settingsSection === 'personal' && <><ProfileSettings profile={displayedProfile} dirty={profileDirty} pending={saveProfile.isPending} error={avatarError ?? saveProfile.error?.message ?? null} onOpenAvatar={() => setAvatarEditorOpen(true)} onOpenName={() => setNameEditorOpen(true)} onOpenHomeWallpaper={() => setHomeWallpaperEditorOpen(true)} onOpenTimetableBackground={() => setTimetableBackgroundEditorOpen(true)} onSave={() => saveProfile.mutate()} /><AppearanceModeSelector mode={appearanceMode} onChange={onAppearanceModeChange} /><LayoutModeSelector mode={layoutMode} onChange={onLayoutModeChange} /></>}
    {settingsSection === 'account' && <section className="account-settings-detail" aria-label="账号安全设置">
      <section className="account-settings-section" aria-labelledby="account-authentication-heading">
        <h2 id="account-authentication-heading">单用户认证</h2>
        <div className="account-settings-group">
          <div className="account-authentication-row"><span><b>服务器环境认证</b><small>账号凭据由服务器环境配置管理</small></span></div>
        </div>
        <p className="account-settings-footer">本页不会展示或保存账号密码。</p>
        <details className="account-deployment-note"><summary><span>部署说明</span><ChevronRight size={18} aria-hidden="true" /></summary><div className="account-deployment-copy"><p>管理员用户名通过 <code>ADMIN_USERNAME</code> 配置，密码哈希通过 <code>ADMIN_PASSWORD_HASH</code> 配置。修改密码后，请重新生成 Argon2id 哈希并更新服务器 <code>.env</code>，再重启后端。</p></div></details>
      </section>
      <PasskeySettings />
      <section className="account-settings-section" aria-labelledby="account-action-heading">
        <h2 id="account-action-heading">账户操作</h2>
        <div className="account-settings-group">
          <button type="button" className="account-logout-row" disabled={appLogout.isPending} onClick={() => setLogoutConfirm(true)}><span><b>退出航的助手</b><small>返回登录页，不会删除本地课程表、成绩缓存或自定义安排</small></span><ChevronRight size={18} aria-hidden="true" /></button>
        </div>
      </section>
    </section>}
    {settingsSection === 'time' && <TimeSettings terms={terms.data} periods={periods.data} preferredTerm={preferredTerm} selectedTermId={selectedTermId} selectedPeriodNumber={selectedPeriodNumber} onSelectTerm={setSelectedTermId} onSelectPeriod={setSelectedPeriodNumber} onTermSaved={() => { queryClient.invalidateQueries({ queryKey: ['terms'] }); queryClient.invalidateQueries({ queryKey: ['sessions'] }); }} onPeriodSaved={() => { queryClient.invalidateQueries({ queryKey: ['period-times'] }); queryClient.invalidateQueries({ queryKey: ['sessions'] }); }} />}
    {settingsSection === 'data' && <DataImportSettings />}
    {settingsSection === 'analysis' && <><AiAnalysisSettings dark={resolvedAppearanceMode === 'dark'} /><AiAnalysisHistorySettings /></>}
    {settingsSection === 'about' && <><section className="about-hero"><div className="about-mark"><img src="/pwa-192.png" alt="航的助手应用图标" /></div><div><small>Hand Helper</small><h2>航的助手</h2><span>v{APP_VERSION}</span></div></section><section className="card about-card"><div className="about-card-intro"><b>应用说明</b><small>为个人使用场景设计的课程表与成绩分析助手。课程和成绩由你主动上传导出文件后写入本地缓存。</small></div><div className="icon-detail-list about-detail-list"><IconDetailRow icon={<UserRound size={20} />} label="使用范围" value="仅供本人使用" /><IconDetailRow icon={<Database size={20} />} label="数据方式" value="本地导出文件解析" /></div></section><HelpCenter /><section className="card settings-card"><b>隐私与安全</b><small>登录令牌不会展示在页面或日志中。课程、成绩和头像数据仅保存在你配置的后端与本地缓存中；上传的原始教务文件仅用于当次解析。</small></section><section className="card settings-card about-github-card"><a className="about-github-row" href="https://github.com/zhangzh-luck/hand-helper" target="_blank" rel="noreferrer" aria-label="在 GitHub 打开航的助手项目主页"><img src="/github-icons8.png" alt="" width="26" height="26" aria-hidden="true" /><span><b>GitHub 项目主页</b><small>查看源码、版本更新与问题反馈</small></span><ChevronRight size={18} aria-hidden="true" /></a></section></>}
    </div>}
    {avatarCropSource && <AvatarCropSheet source={avatarCropSource} dark={resolvedAppearanceMode === 'dark'} onClose={() => setAvatarCropSource(null)} onConfirm={(avatar) => { setNewAvatar(avatar); setAvatarCropSource(null); setAvatarError(null); }} />}
    {avatarEditorOpen && <ProfileAvatarSheet profile={displayedProfile} dark={resolvedAppearanceMode === 'dark'} onClose={() => setAvatarEditorOpen(false)} onChoose={(file) => { setAvatarEditorOpen(false); void chooseAvatar(file); }} onRemove={() => { setNewAvatar(null); setAvatarEditorOpen(false); }} />}
    {nameEditorOpen && <ProfileNameSheet initialName={displayName} dark={resolvedAppearanceMode === 'dark'} onClose={() => setNameEditorOpen(false)} onConfirm={(name) => { setDisplayName(name); setNameEditorOpen(false); }} />}
    {timetableBackgroundCropSource && <PortraitBackgroundCropSheet source={timetableBackgroundCropSource} kind="timetable" dark={resolvedAppearanceMode === 'dark'} onClose={() => setTimetableBackgroundCropSource(null)} onConfirm={(background) => { setNewTimetableBackground(background); setTimetableBackgroundCropSource(null); setAvatarError(null); }} />}
    {homeWallpaperCropSource && <PortraitBackgroundCropSheet source={homeWallpaperCropSource} kind="home" dark={resolvedAppearanceMode === 'dark'} onClose={() => setHomeWallpaperCropSource(null)} onConfirm={(background) => { setNewHomeWallpaper(background); setHomeWallpaperCropSource(null); setAvatarError(null); }} />}
    {timetableBackgroundEditorOpen && <TimetableBackgroundSheet background={displayedProfile.timetable_background_data_url} dark={resolvedAppearanceMode === 'dark'} onClose={() => setTimetableBackgroundEditorOpen(false)} onChoose={(file) => { setTimetableBackgroundEditorOpen(false); void chooseTimetableBackground(file); }} onRemove={() => { setNewTimetableBackground(null); setTimetableBackgroundEditorOpen(false); }} />}
    {homeWallpaperEditorOpen && <HomeWallpaperSheet background={displayedProfile.home_wallpaper_data_url} dark={resolvedAppearanceMode === 'dark'} onClose={() => setHomeWallpaperEditorOpen(false)} onChoose={(file) => { setHomeWallpaperEditorOpen(false); void chooseHomeWallpaper(file); }} onRemove={() => { setNewHomeWallpaper(null); setHomeWallpaperEditorOpen(false); }} />}
    {logoutConfirm && <ViewportSheetPortal><ConfirmDialog title="确认退出航的助手？" description="退出后将返回登录页。已导入的课程表、成绩缓存和自定义安排都会保留。" confirmLabel="确认退出" pending={appLogout.isPending} onCancel={() => setLogoutConfirm(false)} onConfirm={() => appLogout.mutate()} /></ViewportSheetPortal>}
  </Page>;
}

function formatSettingsDate(value: string | null) {
  if (!value) return '选择日期';
  const date = dateFromKey(value);
  return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
}

function ProfileSettings({ profile, dirty, pending, error, onOpenAvatar, onOpenName, onOpenHomeWallpaper, onOpenTimetableBackground, onSave }: { profile: Profile; dirty: boolean; pending: boolean; error: string | null; onOpenAvatar: () => void; onOpenName: () => void; onOpenHomeWallpaper: () => void; onOpenTimetableBackground: () => void; onSave: () => void }) {
  return <section className="profile-settings-section" aria-labelledby="profile-settings-heading"><h2 id="profile-settings-heading">个人资料</h2><form onSubmit={(event) => { event.preventDefault(); onSave(); }}><div className="profile-settings-group">
    <button type="button" className="profile-settings-row" onClick={onOpenAvatar}><span className="profile-settings-label">头像</span><span className="profile-settings-trailing"><Avatar profile={profile} className="profile-settings-avatar" /><ChevronRight size={18} aria-hidden="true" /></span></button>
    <button type="button" className="profile-settings-row" onClick={onOpenName}><span className="profile-settings-label">显示姓名</span><span className="profile-settings-trailing profile-settings-name">{profile.display_name}<ChevronRight size={18} aria-hidden="true" /></span></button>
    <button type="button" className="profile-settings-row" onClick={onOpenHomeWallpaper}><span className="profile-settings-label">首页壁纸</span><span className="profile-settings-trailing profile-settings-name">{profile.home_wallpaper_data_url ? '已设置' : '未设置'}<ChevronRight size={18} aria-hidden="true" /></span></button>
    <button type="button" className="profile-settings-row" onClick={onOpenTimetableBackground}><span className="profile-settings-label">课表背景</span><span className="profile-settings-trailing profile-settings-name">{profile.timetable_background_data_url ? '已设置' : '未设置'}<ChevronRight size={18} aria-hidden="true" /></span></button>
    <button className="profile-settings-save" type="submit" disabled={!dirty || pending}>{pending ? '正在保存…' : '保存更改'}</button>
  </div>{error && <p className="profile-settings-error" role="alert">{error}</p>}</form></section>;
}

function ProfileAvatarSheet({ profile, dark, onClose, onChoose, onRemove }: { profile: Profile; dark: boolean; onClose: () => void; onChoose: (file: File | undefined) => void; onRemove: () => void }) {
  return <DetailSheet title="头像" dark={dark} onClose={onClose}><section className="profile-avatar-editor"><Avatar profile={profile} className="profile-avatar-editor-preview" /><label className="profile-avatar-picker">选择并裁剪头像<input aria-label="选择头像" type="file" accept="image/png,image/jpeg,image/webp" onChange={(event) => { onChoose(event.target.files?.[0]); event.currentTarget.value = ''; }} /></label>{profile.avatar_data_url && <button type="button" className="profile-avatar-remove" onClick={onRemove}>移除头像</button>}<small>支持 PNG、JPEG 或 WebP；保存后的头像为 1:1 正方形，最大 1 MB。</small></section></DetailSheet>;
}

function TimetableBackgroundSheet({ background, dark, onClose, onChoose, onRemove }: { background: string | null; dark: boolean; onClose: () => void; onChoose: (file: File | undefined) => void; onRemove: () => void }) {
  return <DetailSheet title="课表背景" dark={dark} onClose={onClose}><section className="timetable-background-editor">{background ? <img src={background} alt="当前课表背景预览" /> : <div className="timetable-background-editor-empty">尚未设置背景</div>}<label className="profile-avatar-picker">选择并裁切背景<input aria-label="选择课表背景" type="file" accept="image/png,image/jpeg,image/webp" onChange={(event) => { onChoose(event.target.files?.[0]); event.currentTarget.value = ''; }} /></label>{background && <button type="button" className="profile-avatar-remove" onClick={onRemove}>移除课表背景</button>}<small>原图最大 5 MB。保存后为 9:16 JPEG，最大 1 MB；仅应用于课程网格区域。</small></section></DetailSheet>;
}

function HomeWallpaperSheet({ background, dark, onClose, onChoose, onRemove }: { background: string | null; dark: boolean; onClose: () => void; onChoose: (file: File | undefined) => void; onRemove: () => void }) {
  return <DetailSheet title="首页壁纸" dark={dark} onClose={onClose}><section className="timetable-background-editor">{background ? <img src={background} alt="当前首页壁纸预览" /> : <div className="timetable-background-editor-empty">尚未设置首页壁纸</div>}<label className="profile-avatar-picker">选择并裁切首页壁纸<input aria-label="选择首页壁纸" type="file" accept="image/png,image/jpeg,image/webp" onChange={(event) => { onChoose(event.target.files?.[0]); event.currentTarget.value = ''; }} /></label>{background && <button type="button" className="profile-avatar-remove" onClick={onRemove}>移除首页壁纸</button>}<small>原图最大 5 MB。保存后为 9:16 JPEG，最大 1 MB；只影响首页，不改变课表背景。</small></section></DetailSheet>;
}

function ProfileNameSheet({ initialName, dark, onClose, onConfirm }: { initialName: string; dark: boolean; onClose: () => void; onConfirm: (name: string) => void }) {
  const [value, setValue] = useState(initialName);
  const normalizedValue = value.trim();
  const changed = normalizedValue !== initialName.trim();
  return <DetailSheet title="显示姓名" dark={dark} onClose={onClose}><form className="profile-name-editor" onSubmit={(event) => { event.preventDefault(); if (normalizedValue) onConfirm(normalizedValue); }}><label>姓名<input aria-label="显示姓名" value={value} onChange={(event) => setValue(event.target.value)} maxLength={64} autoFocus required /></label><small>会显示在首页与头像占位图中。</small><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose}>取消</button><button type="submit" disabled={!normalizedValue || !changed}>完成编辑</button></div></form></DetailSheet>;
}

function DataImportSettings() {
  const queryClient = useQueryClient();
  const [manualGradeTermOpen, setManualGradeTermOpen] = useState(false);
  const [gradeTermId, setGradeTermId] = useState('');
  const [gradePreview, setGradePreview] = useState<GradeImportPreview | null>(null);
  const [timetableNotice, setTimetableNotice] = useState<string | null>(null);
  const [gradeNotice, setGradeNotice] = useState<string | null>(null);
  const timetableImport = useMutation({
    mutationFn: api.importTimetableFile,
    onMutate: () => setTimetableNotice(null),
    onSuccess: async (result) => {
      await queryClient.invalidateQueries({ queryKey: ['terms'] });
      await queryClient.invalidateQueries({ queryKey: ['sessions'] });
      const refreshedTerms = await queryClient.fetchQuery({ queryKey: ['terms'], queryFn: api.terms });
      const importedTerm = refreshedTerms.find((term) => term.source_term_id === result.term_id);
      if (importedTerm) {
        const importedSessions = await queryClient.fetchQuery({ queryKey: ['sessions', importedTerm.id], queryFn: () => api.sessions(importedTerm.id) });
        localStorage.setItem(courseColorStorageKey(importedTerm.id), JSON.stringify(createCourseColorMap(importedSessions)));
      }
      setTimetableNotice(`已导入 ${result.courses_imported} 门课程，并生成 ${result.sessions_generated} 条课程安排。`);
    },
  });
  const previewGradesImport = useMutation({
    mutationFn: (file: File) => api.previewGradesFile(file, gradeTermId.trim() || undefined),
    onMutate: () => setGradeNotice(null),
    onSuccess: setGradePreview,
  });
  const confirmGradesImport = useMutation({
    mutationFn: api.confirmGradesImport,
    onSuccess: async (result) => {
      setGradePreview(null);
      setGradeNotice(`已导入 ${result.grades_imported} 门 ${result.source_term_id} 的成绩。`);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['terms'] }),
        queryClient.invalidateQueries({ queryKey: ['grades'] }),
        queryClient.invalidateQueries({ queryKey: ['summary'] }),
        queryClient.invalidateQueries({ queryKey: ['grade-ai-analyses'] }),
      ]);
    },
  });
  return <><section className="data-import-settings-section" aria-labelledby="data-import-settings-heading"><h2 id="data-import-settings-heading">本地文件导入</h2><div className="data-import-settings-group">
    <label className="data-import-settings-row data-import-settings-file-row"><span><b>课程表</b><small>导入打印的 .xls 课表</small></span><ChevronRight size={18} aria-hidden="true" /><input aria-label="导入打印课表文件" type="file" accept=".xls,application/vnd.ms-excel" disabled={timetableImport.isPending} onChange={(event) => { const file = event.target.files?.[0]; if (file) { timetableImport.reset(); timetableImport.mutate(file); event.currentTarget.value = ''; } }} /></label>
    <button type="button" className="data-import-settings-row" aria-expanded={manualGradeTermOpen} onClick={() => setManualGradeTermOpen((open) => !open)}><span><b>导入文件学期</b><small>{manualGradeTermOpen ? '文件未标明学期时，可手动指定归属学期' : '默认从成绩文件中自动识别'}</small></span><span className="data-import-settings-trailing">{manualGradeTermOpen ? '手动指定' : '自动识别'}<ChevronRight size={18} aria-hidden="true" /></span></button>
    {manualGradeTermOpen && <label className="data-import-settings-term-input"><span>导入学期</span><input aria-label="成绩导入学期" value={gradeTermId} onChange={(event) => setGradeTermId(event.target.value)} placeholder="例如：2025-2026-2" pattern="20\\d{2}-20\\d{2}-[12]" maxLength={11} /></label>}
    <label className="data-import-settings-row data-import-settings-file-row"><span><b>成绩分析</b><small>导入 .xls 或 HTML 成绩文件</small></span><ChevronRight size={18} aria-hidden="true" /><input aria-label="导入成绩文件" type="file" accept=".xls,.html,.htm,application/vnd.ms-excel,text/html" disabled={previewGradesImport.isPending} onChange={(event) => { const file = event.target.files?.[0]; if (file) { previewGradesImport.reset(); previewGradesImport.mutate(file); event.currentTarget.value = ''; } }} /></label>
    <div className="data-import-settings-row data-import-settings-note"><span><b>原始文件</b><small>仅用于本次解析，不会保存</small></span></div>
  </div><p className="data-import-settings-footer">课程表支持教务系统导出的 .xls 打印课表；成绩支持 .xls 或 HTML 文件。</p>{timetableNotice && <p className="data-import-settings-notice" role="status">{timetableNotice}</p>}{timetableImport.error && <p className="error">课程表导入失败：{timetableImport.error.message}</p>}{previewGradesImport.error && <p className="error">成绩识别失败：{previewGradesImport.error.message}</p>}{gradeNotice && <p className="data-import-settings-notice" role="status">{gradeNotice}</p>}</section>
  {gradePreview && <ViewportSheetPortal><GradeImportSheet preview={gradePreview} pending={confirmGradesImport.isPending} error={confirmGradesImport.error} onClose={() => { if (!confirmGradesImport.isPending) setGradePreview(null); }} onConfirm={(preview) => confirmGradesImport.mutate(preview)} /></ViewportSheetPortal>}</>;
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
    <button className="time-settings-save settings-group-save-row" type="submit" disabled={!dirty || !isMonday || save.isPending}>{save.isPending ? '正在保存…' : '保存更改'}</button>
  </div>{value && !isMonday && <p className="time-settings-error" role="alert">请选择星期一作为第一周的开始日期。</p>}{save.error && <p className="time-settings-error" role="alert">{save.error.message}</p>}<p className="time-settings-footer">选择已导入的学期后，设置第一周的星期一。保存会重新生成该学期课程日程。</p></form></section>;
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
    <button className="time-settings-save settings-group-save-row" type="submit" disabled={!dirty || save.isPending || !startTime || !endTime}>{save.isPending ? '正在保存…' : '保存更改'}</button>
  </div>{save.error && <p className="time-settings-error" role="alert">{save.error.message}</p>}<p className="time-settings-footer">选择需要调整的节次。保存后，已有课程日程会按新时间重新生成。</p></form></section>;
}

function Metric({ label, value }: { label: string; value: string | number }) { return <div><small>{label}</small><b>{value}</b></div>; }
function ManualCourseSheet({ initial, periods, pending, error, editing, onClose, onSave }: { initial: ManualCourseInput; periods: PeriodTime[]; pending: boolean; error: Error | null; editing: boolean; onClose: () => void; onSave: (payload: ManualCourseInput) => void }) {
  useModalOpenState(onClose, pending);
  const [courseName, setCourseName] = useState(initial.course_name);
  const [weekExpression, setWeekExpression] = useState(initial.week_expression);
  const [weekday, setWeekday] = useState(initial.weekday);
  const [startPeriod, setStartPeriod] = useState(initial.start_period);
  const [endPeriod, setEndPeriod] = useState(initial.end_period);
  const [classroom, setClassroom] = useState(initial.classroom ?? '');
  const [teacher, setTeacher] = useState(initial.teacher ?? '');
  useEffect(() => { setCourseName(initial.course_name); setWeekExpression(initial.week_expression); setWeekday(initial.weekday); setStartPeriod(initial.start_period); setEndPeriod(initial.end_period); setClassroom(initial.classroom ?? ''); setTeacher(initial.teacher ?? ''); }, [initial]);
  const weekNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return <div className="sheet-mask" role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet manual-course-sheet" role="dialog" aria-modal="true" aria-label={editing ? '编辑手动课程' : '添加手动课程'} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{editing ? '编辑课程' : '添加课程'}</h2><button type="button" className="sheet-close-icon" aria-label="关闭课程编辑" title="关闭" onClick={onClose} disabled={pending}><X size={20} /></button></header><p className="muted">课程会保存到当前学期，不会被教务系统同步或打印课表导入覆盖。</p><form onSubmit={(event) => { event.preventDefault(); onSave({ term_id: initial.term_id, course_name: courseName.trim(), week_expression: weekExpression.trim(), weekday, start_period: startPeriod, end_period: endPeriod, classroom: classroom.trim() || null, teacher: teacher.trim() || null }); }}><label>课程名称<input aria-label="课程名称" value={courseName} onChange={(event) => setCourseName(event.target.value)} maxLength={255} required placeholder="例如：课程作业答疑" /></label><label>上课周次<input aria-label="上课周次" value={weekExpression} onChange={(event) => setWeekExpression(event.target.value)} maxLength={255} required placeholder="例如：1-18周、1,3,5周、1-16周(单)" /></label><div className="manual-course-grid"><label>星期<select aria-label="上课星期" value={weekday} onChange={(event) => setWeekday(Number(event.target.value))}>{weekNames.map((name, index) => <option value={index + 1} key={name}>{name}</option>)}</select></label><label>开始节次<select aria-label="开始节次" value={startPeriod} onChange={(event) => setStartPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.start_time}</option>)}</select></label><label>结束节次<select aria-label="结束节次" value={endPeriod} onChange={(event) => setEndPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.end_time}</option>)}</select></label></div><label>教室地点<input aria-label="教室地点" value={classroom} onChange={(event) => setClassroom(event.target.value)} maxLength={255} placeholder="可留空" /></label><label>任课教师<input aria-label="任课教师" value={teacher} onChange={(event) => setTeacher(event.target.value)} maxLength={255} placeholder="可留空" /></label><small>保存后会按设置中的学期第一周周一和节次时间，自动生成每周课表日期。</small><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose} disabled={pending}>取消</button><button type="submit" disabled={pending || !courseName.trim() || !weekExpression.trim()}>{pending ? '保存中…' : '保存课程'}</button></div>{error && <p className="error">{error.message}</p>}</form></section></div>;
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
  useModalOpenState(onClose);
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
  useModalOpenState(onClose, pending);
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
  return createPortal(<><div className={`sheet-mask sheet-mask-viewport${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={pending ? undefined : onClose}><section className="detail-sheet manual-course-sheet" role="dialog" aria-modal="true" aria-label={editing ? '编辑手动课程' : '添加手动课程'} onClick={(event) => event.stopPropagation()}><div className="sheet-handle" /><header><h2>{editing ? '编辑课程' : '添加课程'}</h2><button type="button" className="sheet-close-icon" aria-label="关闭课程编辑" title="关闭" onClick={onClose} disabled={pending}><X size={20} /></button></header><p className="manual-course-top-note">课程会保存到当前学期，不会被教务系统同步或打印课表导入覆盖。</p><form onSubmit={(event) => { event.preventDefault(); if (!valid || !dirty) return; onSave({ term_id: initial.term_id, course_name: courseName.trim(), week_expression: currentWeekExpression, weekday, start_period: startPeriod, end_period: endPeriod, classroom: classroom.trim() || null, teacher: teacher.trim() || null }); }}><section className="manual-course-settings-section"><h3>课程信息</h3><div className="manual-course-settings-group"><label className="manual-course-settings-row manual-course-title-row"><span className="manual-course-settings-label">课程名称</span><input aria-label="课程名称" value={courseName} onChange={(event) => setCourseName(event.target.value)} maxLength={255} required placeholder="例如：课程作业答疑" /></label><button type="button" className="manual-course-settings-row" onClick={() => setWeekPickerOpen(true)}><span className="manual-course-settings-label">上课周次</span><span className="manual-course-settings-value">{selectedWeekText ? `第 ${selectedWeekText} 周` : '请选择上课周次'}<ChevronRight size={18} aria-hidden="true" /></span></button><label className="manual-course-settings-row manual-course-native-row"><span className="manual-course-settings-label">星期</span><span className="manual-course-settings-value">{weekNames[weekday - 1] ?? '请选择'}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="上课星期" value={weekday} onChange={(event) => setWeekday(Number(event.target.value))}>{weekNames.map((name, index) => <option value={index + 1} key={name}>{name}</option>)}</select></label></div></section><section className="manual-course-settings-section"><h3>上课时间</h3><div className="manual-course-settings-group"><label className="manual-course-settings-row manual-course-native-row"><span className="manual-course-settings-label">开始节次</span><span className="manual-course-settings-value">{periodLabel(startPeriod, 'start')}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="开始节次" value={startPeriod} onChange={(event) => setStartPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.start_time}</option>)}</select></label><label className="manual-course-settings-row manual-course-native-row"><span className="manual-course-settings-label">结束节次</span><span className="manual-course-settings-value">{periodLabel(endPeriod, 'end')}<ChevronRight size={18} aria-hidden="true" /></span><select aria-label="结束节次" value={endPeriod} onChange={(event) => setEndPeriod(Number(event.target.value))}>{periods.map((period) => <option value={period.period_number} key={period.period_number}>第 {period.period_number} 节 · {period.end_time}</option>)}</select></label></div></section><section className="manual-course-settings-section"><h3>其他信息</h3><div className="manual-course-settings-group"><button type="button" className="manual-course-settings-row" onClick={() => setTextEditor('classroom')}><span className="manual-course-settings-label">教室地点</span><span className="manual-course-settings-value">{classroom.trim() || '可留空'}<ChevronRight size={18} aria-hidden="true" /></span></button><button type="button" className="manual-course-settings-row" onClick={() => setTextEditor('teacher')}><span className="manual-course-settings-label">任课教师</span><span className="manual-course-settings-value">{teacher.trim() || '可留空'}<ChevronRight size={18} aria-hidden="true" /></span></button></div></section><p className="manual-course-footer">保存后会按设置中的学期第一周周一和节次时间，自动生成每周课程日期。</p><button type="submit" className="manual-course-save" disabled={pending || !valid || !dirty}>{pending ? '保存中…' : '保存课程'}</button>{error && <p className="error">{error.message}</p>}</form></section></div>{weekPickerOpen && <ManualWeekPicker selected={selectedWeeks} dark={dark} onClose={() => setWeekPickerOpen(false)} onConfirm={(weeks) => { setSelectedWeeks(weeks); setWeekPickerOpen(false); }} />}{textEditor && <ManualCourseTextSheet kind={textEditor} value={textEditor === 'classroom' ? classroom : teacher} dark={dark} onClose={() => setTextEditor(null)} onConfirm={(value) => { if (textEditor === 'classroom') setClassroom(value); else setTeacher(value); setTextEditor(null); }} />}</>, document.body);
}

function ManualCourseTextSheet({ kind, value, dark, onClose, onConfirm }: { kind: 'classroom' | 'teacher'; value: string; dark: boolean; onClose: () => void; onConfirm: (value: string) => void }) {
  const [draft, setDraft] = useState(value);
  const normalizedValue = draft.trim();
  const changed = normalizedValue !== value.trim();
  const title = kind === 'classroom' ? '教室地点' : '任课教师';
  return <DetailSheet title={title} dark={dark} onClose={onClose}><form className="manual-course-text-editor" onSubmit={(event) => { event.preventDefault(); if (changed) onConfirm(normalizedValue); }}><label>{title}<input aria-label={title} value={draft} onChange={(event) => setDraft(event.target.value)} maxLength={255} autoFocus placeholder="可留空" /></label><small>可留空，保存课程时会一并写入。</small><div className="custom-schedule-actions"><button type="button" className="secondary-button" onClick={onClose}>取消</button><button type="submit" disabled={!changed}>完成编辑</button></div></form></DetailSheet>;
}

let nextModalId = 0;
const modalStack: number[] = [];
const modalHistoryKey = '__handHelperModal';
const modalSelector = '[role="dialog"][aria-modal="true"], [role="alertdialog"][aria-modal="true"]';
const focusableSelector = 'button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), a[href], [tabindex]:not([tabindex="-1"])';

function useModalOpenState(onClose: () => void, pending = false) {
  const id = useRef(++nextModalId).current;
  const closeRef = useRef(onClose);
  const pendingRef = useRef(pending);
  closeRef.current = onClose;
  pendingRef.current = pending;
  useEffect(() => {
    const trigger = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    modalStack.push(id);
    document.documentElement.dataset.modalOpen = 'true';
    const top = () => modalStack[modalStack.length - 1] === id;
    const dialog = () => [...document.querySelectorAll<HTMLElement>(modalSelector)].at(-1);
    const focusTimer = window.setTimeout(() => {
      if (!top()) return;
      const current = dialog();
      if (!current || current.contains(document.activeElement)) return;
      current.tabIndex = -1;
      (current.querySelector<HTMLElement>('[autofocus]') ?? current.querySelector<HTMLElement>(focusableSelector) ?? current).focus({ preventScroll: true });
    }, 0);
    // 独立历史项使浏览器或 WebView 的返回手势先收起弹窗，不离开当前页面。
    const historyTimer = window.setTimeout(() => {
      const state = typeof window.history.state === 'object' && window.history.state !== null ? window.history.state : {};
      window.history.pushState({ ...state, [modalHistoryKey]: id }, '');
    }, 0);
    const onKeyDown = (event: KeyboardEvent) => {
      if (!top()) return;
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopPropagation();
        if (!pendingRef.current) closeRef.current();
        return;
      }
      if (event.key !== 'Tab') return;
      const current = dialog();
      if (!current) return;
      const items = [...current.querySelectorAll<HTMLElement>(focusableSelector)].filter((item) => item.getClientRects().length > 0);
      if (!items.length) { event.preventDefault(); current.focus(); return; }
      const first = items[0], last = items[items.length - 1];
      if (event.shiftKey && (document.activeElement === first || !current.contains(document.activeElement))) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && (document.activeElement === last || !current.contains(document.activeElement))) { event.preventDefault(); first.focus(); }
    };
    const onPopState = () => {
      if (!top() || window.history.state?.[modalHistoryKey] === id) return;
      if (pendingRef.current) {
        window.history.pushState({ ...(window.history.state ?? {}), [modalHistoryKey]: id }, '');
      } else closeRef.current();
    };
    document.addEventListener('keydown', onKeyDown, true);
    window.addEventListener('popstate', onPopState);
    return () => {
      window.clearTimeout(focusTimer);
      window.clearTimeout(historyTimer);
      document.removeEventListener('keydown', onKeyDown, true);
      window.removeEventListener('popstate', onPopState);
      const index = modalStack.lastIndexOf(id);
      if (index >= 0) modalStack.splice(index, 1);
      if (!modalStack.length) delete document.documentElement.dataset.modalOpen;
      if (window.history.state?.[modalHistoryKey] === id) window.history.back();
      window.setTimeout(() => { if (trigger?.isConnected) trigger.focus({ preventScroll: true }); }, 0);
    };
  }, [id]);
}

function ViewportSheetPortal({ children }: { children: React.ReactNode }) {
  return createPortal(<div className="viewport-sheet-portal">{children}</div>, document.body);
}

function Detail({ label, value }: { label: string; value: string }) { return <p><small>{label}</small><span>{value}</span></p>; }
function IconDetailRow({ icon, label, value }: { icon: React.ReactNode; label: string; value: string }) {
  return <div className="icon-detail-row"><span className="icon-detail-icon" aria-hidden="true">{icon}</span><span className="icon-detail-copy"><small>{label}</small><span>{value}</span></span></div>;
}
function DetailSheet({ title, children, onClose, dark = false, showHandle = true, eyebrow, showTitle = true, className = '' }: { title: string; children: React.ReactNode; onClose: () => void; dark?: boolean; showHandle?: boolean; eyebrow?: string; showTitle?: boolean; className?: string }) {
  useModalOpenState(onClose);
  return createPortal(<div className={`sheet-mask sheet-mask-viewport${dark ? ' sheet-mask-dark' : ''}`} role="presentation" onClick={onClose}><section className={`detail-sheet${className ? ` ${className}` : ''}`} role="dialog" aria-modal="true" aria-label={title} onClick={(event) => event.stopPropagation()}>{showHandle && <div className="sheet-handle" />}<header>{eyebrow ? <div className="detail-sheet-heading"><small>{eyebrow}</small>{showTitle ? <h2>{title}</h2> : <h2 className="detail-sheet-visually-hidden">{title}</h2>}</div> : <h2>{title}</h2>}<button type="button" className="sheet-close-icon" aria-label="关闭详情" title="关闭" onClick={onClose}><X size={20} /></button></header>{children}</section></div>, document.body);
}
function ConfirmDialog({ title, description, confirmLabel, pending, onCancel, onConfirm }: { title: string; description: string; confirmLabel: string; pending: boolean; onCancel: () => void; onConfirm: () => void }) {
  useModalOpenState(onCancel, pending);
  return <div className="sheet-mask confirm-mask" role="presentation" onClick={pending ? undefined : onCancel}><section className="confirm-dialog" role="alertdialog" aria-modal="true" aria-labelledby="confirm-dialog-title" aria-describedby="confirm-dialog-description" onClick={(event) => event.stopPropagation()}><div className="confirm-dialog-copy"><h2 id="confirm-dialog-title">{title}</h2><p id="confirm-dialog-description">{description}</p></div><div className="confirm-dialog-actions"><button type="button" className="confirm-dialog-destructive" disabled={pending} onClick={onConfirm}>{pending ? '正在处理…' : confirmLabel}</button><button type="button" className="confirm-dialog-cancel" disabled={pending} onClick={onCancel}>取消</button></div></section></div>;
}
function Empty({ text }: { text: string }) { return <div className="empty">{text}</div>; }
function Page({ title, children, action, icon, className, headerClassName, compactTitle, mainRef, headerRef }: { title: string; children: React.ReactNode; action?: React.ReactNode; icon?: React.ReactNode; className?: string; headerClassName?: string; compactTitle?: boolean; mainRef?: RefObject<HTMLElement>; headerRef?: RefObject<HTMLElement> }) { return <main ref={mainRef} className={className}><header ref={headerRef} className={headerClassName}>{compactTitle && icon && <span className="page-fixed-title-icon" aria-hidden="true">{icon}</span>}<h1 className="page-title">{!compactTitle && icon && <span className="page-title-icon" aria-hidden="true">{icon}</span>}{title}</h1>{compactTitle && <span className="page-title-compact" aria-hidden="true">{title}</span>}{action}</header>{children}</main>; }

function useAuthenticationViewportLock() {
  useEffect(() => {
    document.documentElement.dataset.authScreen = 'active';
    return () => { delete document.documentElement.dataset.authScreen; };
  }, []);
}

function Login({ onSuccess, appearance, onToggleAppearance }: { onSuccess: () => void; appearance: 'light' | 'dark'; onToggleAppearance: () => void }) {
  useAuthenticationViewportLock();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const login = useMutation({ mutationFn: () => api.login(username, password), onSuccess });
  const passkeyLogin = useMutation({ mutationFn: async () => {
    const options = await api.passkeyAuthenticationOptions();
    const credential = await getPasskeyAssertion(options.public_key);
    return api.verifyPasskeyAuthentication({ challenge_id: options.challenge_id, credential });
  }, onSuccess });
  const unsupportedPasskey = !passkeySupported();
  const AppearanceIcon = appearance === 'dark' ? Sun : Moon;
  const appearanceLabel = appearance === 'dark' ? '切换为浅色模式' : '切换为深色模式';
  return <main className="login login-native-page">
    <div className="login-native-glow login-native-glow-top" aria-hidden="true" />
    <div className="login-native-glow login-native-glow-bottom" aria-hidden="true" />
    <section className="login-native-shell" aria-labelledby="login-title">
      <div className="login-native-topbar"><button type="button" className="login-appearance-toggle" aria-label={appearanceLabel} title={appearanceLabel} onClick={onToggleAppearance}><AppearanceIcon size={19} aria-hidden="true" /></button></div>
      <header className="login-native-brand"><div className="login-logo"><img src="/pwa-192.png" alt="航的助手" width="76" height="76" /></div><div><p>欢迎回来</p><h1 id="login-title">航的助手</h1></div></header>
      <form className="login-form login-native-form" onSubmit={(event) => { event.preventDefault(); login.mutate(); }}>
        <div className="login-native-fields">
          <label className="login-native-field"><span className="login-native-field-icon" aria-hidden="true"><UserRound size={21} /></span><input aria-label="用户名" value={username} onChange={(event) => setUsername(event.target.value)} autoComplete="username" autoFocus required placeholder="账号" /></label>
          <div className="login-native-divider" aria-hidden="true" />
          <label className="login-native-field"><span className="login-native-field-icon" aria-hidden="true"><LockKeyhole size={21} /></span><input aria-label="密码" value={password} onChange={(event) => setPassword(event.target.value)} autoComplete="current-password" required type={showPassword ? 'text' : 'password'} placeholder="密码" /><button type="button" className="login-password-toggle" aria-label={showPassword ? '隐藏密码' : '显示密码'} title={showPassword ? '隐藏密码' : '显示密码'} onClick={() => setShowPassword((shown) => !shown)}>{showPassword ? <EyeOff size={20} aria-hidden="true" /> : <Eye size={20} aria-hidden="true" />}</button></label>
        </div>
        <button className="login-btn login-native-submit" type="submit" disabled={login.isPending || passkeyLogin.isPending}>{login.isPending ? <span className="login-native-spinner" aria-label="正在登录" /> : '登录'}</button>
        <div className="login-auth-divider" aria-hidden="true"><span>或</span></div>
        <button className="login-passkey-button" type="button" disabled={unsupportedPasskey || login.isPending || passkeyLogin.isPending} onClick={() => passkeyLogin.mutate()} aria-describedby="login-passkey-hint"><KeyRound size={19} aria-hidden="true" /><span>{passkeyLogin.isPending ? '正在验证…' : '通过通行密钥登录'}</span></button>
        <span id="login-passkey-hint" className="sr-only">{unsupportedPasskey ? '当前浏览器或安全上下文不支持通行密钥' : '使用已添加的通行密钥登录'}</span>
        {unsupportedPasskey && <p className="login-passkey-unavailable" role="status">当前应用环境暂不支持通行密钥，请使用 HTTPS 网页版登录。</p>}
        {(login.error || passkeyLogin.error) && <div className="login-error" role="alert">{login.error?.message ?? passkeyLogin.error?.message}</div>}
      </form>
      <footer className="login-native-footer"><span>© 2026 航的助手</span><span aria-hidden="true">·</span><a href="https://github.com/zhangzh-luck" target="_blank" rel="noreferrer" aria-label="GitHub 用户名 zhangzh-luck"><img src="/github-icons8.png" alt="" width="16" height="16" aria-hidden="true" /><span>GitHub @zhangzh-luck</span></a></footer>
    </section>
  </main>;
}

function AuthGateLoading() {
  useAuthenticationViewportLock();
  return <main className="login login-native-page" aria-busy="true" aria-live="polite">
    <div className="login-native-glow login-native-glow-top" aria-hidden="true" />
    <div className="login-native-glow login-native-glow-bottom" aria-hidden="true" />
    <section className="login-native-shell login-native-checking-shell" aria-label="正在验证登录状态">
      <div className="login-native-checking-status">
        <div className="login-logo"><img src="/pwa-192.png" alt="航的助手" width="76" height="76" /></div>
        <p>正在验证登录状态</p>
        <span className="login-native-checking-spinner" aria-hidden="true" />
      </div>
    </section>
  </main>;
}

function AuthGateConnectionError({ onRetry }: { onRetry: () => void }) {
  useAuthenticationViewportLock();
  return <main className="login login-native-page" role="alert">
    <section className="login-native-shell login-native-checking-shell">
      <div className="login-native-checking-status">
        <div className="login-logo"><img src="/pwa-192.png" alt="航的助手" width="76" height="76" /></div>
        <p>暂时无法连接服务器，请检查网络后重试。</p>
        <button type="button" className="login-btn auth-retry-button" onClick={onRetry}>重试连接</button>
      </div>
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
  const initialPathname = useRef(pathname);
  const previousPathname = useRef(pathname);
  const currentIndex = primaryRouteIndex(pathname);
  const previousIndex = primaryRouteIndex(previousPathname.current);
  const direction = currentIndex < previousIndex ? 'backward' : 'forward';
  const routeEntering = pathname !== initialPathname.current;

  useEffect(() => {
    previousPathname.current = pathname;
  }, [pathname]);

  // 认证完成后首次挂载主页面时不做淡入，避免与启动校验态在 WebView 中形成残影。
  const transitionClassName = pathname === initialPathname.current ? 'page-route-stage' : `page-route-stage page-route-stage-${direction}`;
  return <div key={pathname} className={transitionClassName}>
    <Routes>
      <Route path="/" element={<Today appearance={resolvedAppearanceMode} />} />
      <Route path="/timetable" element={<Timetable appearance={resolvedAppearanceMode} />} />
      <Route path="/grades" element={<Grades appearance={resolvedAppearanceMode} />} />
      <Route path="/settings" element={<Settings appearanceMode={appearanceMode} resolvedAppearanceMode={resolvedAppearanceMode} onAppearanceModeChange={onAppearanceModeChange} layoutMode={layoutMode} onLayoutModeChange={onLayoutModeChange} routeEntering={routeEntering} />} />
    </Routes>
  </div>;
}

export default function App() {
  const [authState, setAuthState] = useState<'checking' | 'authenticated' | 'unauthenticated' | 'connection-error'>('checking');
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
      resolvedAppearanceMode === 'dark' ? '#000000' : '#f4f7fb',
    );
    void updateNativeStatusBar(resolvedAppearanceMode);
  }, [resolvedAppearanceMode]);
  const checkAuthentication = () => {
    setAuthState('checking');
    void api.me().then(() => setAuthState('authenticated')).catch((error: unknown) => {
      setAuthState(error instanceof UnauthorizedError ? 'unauthenticated' : 'connection-error');
    });
  };
  useEffect(() => {
    let active = true;
    const markUnauthenticated = () => { if (active) setAuthState('unauthenticated'); };
    window.addEventListener('hand-helper:unauthenticated', markUnauthenticated);
    void api.me().then(() => { if (active) setAuthState('authenticated'); }).catch((error: unknown) => {
      if (active) setAuthState(error instanceof UnauthorizedError ? 'unauthenticated' : 'connection-error');
    });
    return () => { active = false; window.removeEventListener('hand-helper:unauthenticated', markUnauthenticated); };
  }, []);
  useEffect(() => {
    // 普通应用内容按原生界面处理，避免移动端长按选择文字或呼出图片菜单；可编辑区域与报告正文例外。
    const isEditableContent = (target: EventTarget | null) => target instanceof Element && Boolean(target.closest('input, textarea, select, [contenteditable="true"], .grade-ai-markdown'));
    const isAppSurface = (target: EventTarget | null) => target instanceof Element && Boolean(target.closest('.shell, .login-native-page'));
    const suppressAppSurfaceMenu = (event: MouseEvent) => {
      const target = event.target;
      const imageMenuTarget = target instanceof HTMLImageElement && target.matches('.shell img, .login-native-page img, .avatar-preview-image-frame img');
      if (imageMenuTarget || (isAppSurface(target) && !isEditableContent(target))) event.preventDefault();
    };
    const suppressAppSurfaceSelection = (event: Event) => {
      if (isAppSurface(event.target) && !isEditableContent(event.target)) event.preventDefault();
    };
    document.addEventListener('contextmenu', suppressAppSurfaceMenu);
    document.addEventListener('selectstart', suppressAppSurfaceSelection);
    return () => {
      document.removeEventListener('contextmenu', suppressAppSurfaceMenu);
      document.removeEventListener('selectstart', suppressAppSurfaceSelection);
    };
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
  if (authState === 'connection-error') return <AuthGateConnectionError onRetry={checkAuthentication} />;
  if (authState === 'unauthenticated') return <><NativeStartupNotice /><Routes><Route path="/login" element={<Login appearance={resolvedAppearanceMode} onToggleAppearance={() => setAppearanceMode(resolvedAppearanceMode === 'dark' ? 'light' : 'dark')} onSuccess={() => { setAuthState('authenticated'); navigate('/', { replace: true }); }} />} /><Route path="*" element={<Navigate to="/login" replace />} /></Routes></>;
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
  const [connectionFailed, setConnectionFailed] = useState(false);
  const [retrying, setRetrying] = useState(false);
  const queryClient = useQueryClient();
  useEffect(() => {
    const markOnline = () => setOnline(true);
    const markOffline = () => setOnline(false);
    const markFailed = () => setConnectionFailed(true);
    const markRestored = () => setConnectionFailed(false);
    window.addEventListener('online', markOnline);
    window.addEventListener('offline', markOffline);
    window.addEventListener('hand-helper:connection-failed', markFailed);
    window.addEventListener('hand-helper:connection-restored', markRestored);
    return () => {
      window.removeEventListener('online', markOnline);
      window.removeEventListener('offline', markOffline);
      window.removeEventListener('hand-helper:connection-failed', markFailed);
      window.removeEventListener('hand-helper:connection-restored', markRestored);
    };
  }, []);
  if (online && !connectionFailed) return null;
  const retry = async () => {
    setRetrying(true);
    try { await api.me(); await queryClient.invalidateQueries(); }
    catch (error) { if (!(error instanceof ConnectionError)) setConnectionFailed(false); }
    finally { setRetrying(false); }
  };
  return <div className="native-offline-banner" role="status"><span>{online ? '暂时无法连接服务器。' : '当前离线，操作暂不可用。'}</span><button type="button" disabled={!online || retrying} onClick={() => void retry()}>{retrying ? '连接中…' : '重试'}</button></div>;
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

