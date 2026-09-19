import { useEffect, useLayoutEffect, useMemo, useRef, type CSSProperties } from 'react';
import { Plus } from 'lucide-react';
import type { PeriodTime, Session, Term } from '../api';
import { toTimetableDisplaySession } from './timetable-adapter';
import fallbackBackdrop from './backdrop.svg';
import './timetable-v2.css';

export type TimetableSlot = { weekday: number; startPeriod: number; endPeriod: number };

type Props = {
  sessions: Session[];
  term?: Term;
  periods: PeriodTime[];
  anchor: Date;
  todayKey: string;
  courseColors: Record<string, string>;
  pendingSlot: TimetableSlot | null;
  selectedSessionId: number | null;
  timetableBackground: string | null;
  onWeekChange: (anchor: Date) => void;
  onSelect: (session: Session) => void;
  onSelectSlot: (slot: TimetableSlot | null) => void;
  onAddSlot: (slot: TimetableSlot) => void;
};

const WEEKDAY_LABELS = ['一', '二', '三', '四', '五', '六', '日'];
const localDateKey = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
const mondayOf = (date: Date) => { const next = new Date(date); next.setHours(12, 0, 0, 0); next.setDate(next.getDate() - ((next.getDay() + 6) % 7)); return next; };
const addDays = (date: Date, days: number) => { const next = new Date(date); next.setDate(next.getDate() + days); return next; };
const displayTeacherName = (teacher: string | null) => (teacher ?? '教师待定').replace(/\s*[（(][^（）()]*[）)]\s*$/, '').trim() || '教师待定';
function WeekHeader({ dates, todayKey }: { dates: Date[]; todayKey: string }) {
  const monthDate = dates.find((date) => localDateKey(date) === todayKey) ?? dates[0];
  return <header className="timetable-v2-header" aria-label="本周日期"><div className="timetable-v2-rail-spacer" aria-label={`${monthDate.getMonth() + 1}月`}><span>{monthDate.getMonth() + 1}月</span></div>{dates.map((date, index) => {
    const isToday = localDateKey(date) === todayKey;
    return <div className="timetable-v2-date" key={localDateKey(date)} aria-label={`星期${WEEKDAY_LABELS[index]}，${date.getMonth() + 1}月${date.getDate()}日${isToday ? '，今天' : ''}`}><span>周{WEEKDAY_LABELS[index]}</span><strong className={isToday ? 'is-today' : ''}>{date.getDate()}</strong></div>;
  })}</header>;
}

function TimeRail({ periods }: { periods: PeriodTime[] }) {
  return <aside className="timetable-v2-time-rail" aria-label="节次时间">{periods.map((period) => <div className="timetable-v2-time" key={period.period_number}><b>{period.period_number}</b><span>{period.start_time}</span><small>{period.end_time}</small></div>)}</aside>;
}

function CourseGrid({ sessions, periods, courseColors, pendingSlot, selectedSessionId, onSelect, onSelectSlot, onAddSlot, canAdd }: Pick<Props, 'sessions' | 'periods' | 'courseColors' | 'pendingSlot' | 'selectedSessionId' | 'onSelect' | 'onSelectSlot' | 'onAddSlot'> & { canAdd: boolean }) {
  const cells = useMemo(() => Array.from({ length: periods.length * 7 }, (_, index) => ({ weekday: index % 7 + 1, period: Math.floor(index / 7) + 1 })), [periods.length]);
  const offsetPeriod = periods[0]?.period_number ?? 1;
  return <div className="timetable-v2-grid" aria-label="课程网格" style={{ '--timetable-v2-periods': periods.length } as CSSProperties}>
    <div className="timetable-v2-empty-layer">{cells.map(({ weekday, period }) => {
      const actualPeriod = period + offsetPeriod - 1;
      const isArmed = pendingSlot?.weekday === weekday && pendingSlot.startPeriod === actualPeriod;
      return <button type="button" key={`${weekday}-${actualPeriod}`} className="timetable-v2-empty" style={{ gridColumn: weekday, gridRow: period }} disabled={!canAdd} onClick={() => isArmed ? onAddSlot(pendingSlot) : onSelectSlot({ weekday, startPeriod: actualPeriod, endPeriod: actualPeriod })} aria-label={canAdd ? (isArmed ? `星期${weekday}第${actualPeriod}节，确认添加课程` : `星期${weekday}第${actualPeriod}节空时段，点选后显示添加课程按钮`) : `星期${weekday}第${actualPeriod}节空时段，当前周不可添加课程`}>{isArmed && canAdd && <Plus size={19} aria-hidden="true" />}</button>;
    })}</div>
    <div className="timetable-v2-course-layer">{sessions.map((session) => {
      const display = toTimetableDisplaySession(session, periods, courseColors);
      if (!display) return null;
      const start = display.startPeriod - offsetPeriod + 1; const end = display.endPeriod - offsetPeriod + 1;
      if (start < 1 || end < start || end > periods.length) return null;
      const long = end > start;
      return <button type="button" key={session.id} className={`timetable-v2-course tone-${display.tone}${long ? ' is-long' : ''}${display.isManual ? ' is-manual' : ''}${session.id === selectedSessionId ? ' is-detail-open' : ''}`} style={{ gridColumn: display.weekday, gridRow: `${start} / ${end + 1}` }} onClick={() => onSelect(session)} aria-label={`${session.course_name}，第${display.startPeriod}${long ? `至${display.endPeriod}` : ''}节，${session.classroom ?? '教室待定'}`}><strong>{session.course_name}</strong><span className="timetable-v2-classroom">{session.classroom ?? '教室待定'}</span>{long && <small>{displayTeacherName(session.teacher)}</small>}</button>;
    })}</div>
  </div>;
}

function WeekPage({ weekStart, ...props }: Props & { weekStart: Date }) {
  const dates = useMemo(() => Array.from({ length: 7 }, (_, index) => addDays(weekStart, index)), [weekStart]);
  const sessions = useMemo(() => props.sessions.filter((session) => dates.some((date) => localDateKey(date) === session.session_date)), [dates, props.sessions]);
  const termStart = props.term?.start_date ? mondayOf(new Date(`${props.term.start_date}T12:00:00`)) : null;
  const weekNumber = termStart && weekStart >= termStart ? Math.floor((weekStart.getTime() - termStart.getTime()) / 604800000) + 1 : null;
  const canAdd = Boolean(weekNumber && weekNumber <= 25);
  return <section className="timetable-v2-week" aria-label={weekNumber ? `第 ${weekNumber} 周课程表` : '假期课程表'}><div className="timetable-v2-scroll"><WeekHeader dates={dates} todayKey={props.todayKey} /><div className="timetable-v2-body"><TimeRail periods={props.periods} /><CourseGrid sessions={sessions} periods={props.periods} courseColors={props.courseColors} pendingSlot={props.pendingSlot} selectedSessionId={props.selectedSessionId} onSelect={props.onSelect} onSelectSlot={props.onSelectSlot} onAddSlot={props.onAddSlot} canAdd={canAdd} /></div></div></section>;
}

export function TimetableStage(props: Props) {
  const pagerRef = useRef<HTMLDivElement>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const weekStart = mondayOf(props.anchor);
  const offsets = [-3, -2, -1, 0, 1, 2, 3];
  useLayoutEffect(() => {
    const pager = pagerRef.current;
    if (!pager || !pager.clientWidth) return;
    pager.scrollLeft = pager.clientWidth * 3;
  }, [weekStart]);
  useEffect(() => () => { if (timerRef.current) clearTimeout(timerRef.current); }, []);
  const onScroll = () => {
    const pager = pagerRef.current; if (!pager || !pager.clientWidth) return;
    if (timerRef.current) { clearTimeout(timerRef.current); timerRef.current = null; }
    const nearest = Math.max(0, Math.min(6, Math.round(pager.scrollLeft / pager.clientWidth)));
    const offset = offsets[nearest];
    if (offset === 0) return;
    timerRef.current = setTimeout(() => {
      const currentPager = pagerRef.current;
      if (!currentPager || !currentPager.clientWidth) return;
      const settledIndex = Math.max(0, Math.min(6, Math.round(currentPager.scrollLeft / currentPager.clientWidth)));
      const settledOffset = offsets[settledIndex];
      if (settledOffset !== 0) props.onWeekChange(addDays(weekStart, settledOffset * 7));
    }, 180);
  };
  const background = props.timetableBackground || fallbackBackdrop;
  return <section className="timetable-v2-stage" aria-label="周课程表"><div className="timetable-v2-backdrop" style={{ backgroundImage: `url("${background}")` }} aria-hidden="true" /><div className="timetable-v2-backdrop-tint" aria-hidden="true" /><div ref={pagerRef} className="timetable-v2-pager" onScroll={onScroll} aria-label="可左右滑动切换周次">{offsets.map((offset) => <WeekPage {...props} key={offset} weekStart={addDays(weekStart, offset * 7)} />)}</div></section>;
}
