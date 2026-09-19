import type { PeriodTime, Session } from '../api';

export type TimetableDisplaySession = {
  session: Session;
  weekday: number;
  startPeriod: number;
  endPeriod: number;
  tone: string;
  isManual: boolean;
};

function formattedTime(value: string) {
  return new Date(value).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
}

/** Converts API sessions into grid-only data without changing scheduling semantics. */
export function toTimetableDisplaySession(session: Session, periods: PeriodTime[], courseColors: Record<string, string>): TimetableDisplaySession | null {
  const fromFields = session.start_period && session.end_period ? { startPeriod: session.start_period, endPeriod: session.end_period } : null;
  const startTime = formattedTime(session.start_datetime);
  const endTime = formattedTime(session.end_datetime);
  const startIndex = periods.findIndex((period) => period.start_time === startTime);
  const endIndex = periods.findIndex((period) => period.end_time === endTime);
  const period = fromFields ?? (startIndex >= 0 && endIndex >= startIndex ? { startPeriod: periods[startIndex].period_number, endPeriod: periods[endIndex].period_number } : null);
  const weekday = session.weekday ?? (new Date(`${session.session_date}T12:00:00`).getDay() || 7);
  if (!period || weekday < 1 || weekday > 7 || period.endPeriod < period.startPeriod) return null;
  return {
    session,
    weekday,
    startPeriod: period.startPeriod,
    endPeriod: period.endPeriod,
    tone: courseColors[session.course_name]?.replace('course-color-', '') || 'sky',
    isManual: session.source === 'MANUAL',
  };
}
