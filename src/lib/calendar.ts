import type { ClosureRule } from '../types/database'

export function closureReasonForDay(rules: ClosureRule[], date: string, slotId: string | null = null) {
  const exceptions = rules.filter(rule => rule.action === 'open_exception' && rule.rule_type === 'exception' && rule.starts_on === date && (!rule.slot_id || rule.slot_id === slotId))
  if (exceptions.length) return null
  const day = new Date(`${date}T00:00:00Z`)
  const dow = day.getUTCDay()
  const dayNumber = day.getUTCDate()
  const weekNumber = Math.ceil(dayNumber / 7)
  const monthLastDay = new Date(Date.UTC(day.getUTCFullYear(), day.getUTCMonth() + 1, 0)).getUTCDate()
  const matches = rules.filter(rule => {
    if (rule.action !== 'closed' || (rule.slot_id && rule.slot_id !== slotId)) return false
    if (rule.starts_on && date < rule.starts_on) return false
    if (rule.ends_on && date > rule.ends_on) return false
    switch (rule.rule_type) {
      case 'date_range': case 'daily': return true
      case 'weekday': return rule.weekday === dow
      case 'monthly_date': return rule.month_day === dayNumber
      case 'monthly_weekday': return rule.weekday === dow && (rule.week_of_month === -1 ? dayNumber + 7 > monthLastDay : rule.week_of_month === weekNumber)
      default: return false
    }
  }).sort((a, b) => Number(Boolean(b.slot_id)) - Number(Boolean(a.slot_id)))
  return matches[0]?.reason || (matches.length ? 'Closed for this date or slot' : null)
}

export function plainDateLabel(value: string, options: Intl.DateTimeFormatOptions = { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }, locale = 'en-IN') {
  return new Intl.DateTimeFormat(locale, { ...options, timeZone: 'UTC' }).format(new Date(`${value}T00:00:00Z`))
}

export function monthStart(value: string) {
  const date = new Date(`${value}T00:00:00Z`)
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1))
}

export function shiftMonth(value: string, amount: number) {
  const date = new Date(`${value}T00:00:00Z`)
  const moved = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + amount, 1))
  return `${moved.getUTCFullYear()}-${String(moved.getUTCMonth() + 1).padStart(2, '0')}-01`
}

export function shiftDate(value: string, amount: number) {
  const date = new Date(`${value}T00:00:00Z`)
  date.setUTCDate(date.getUTCDate() + amount)
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, '0')}-${String(date.getUTCDate()).padStart(2, '0')}`
}

export function dateWeekday(value: string) {
  return new Date(`${value}T00:00:00Z`).getUTCDay()
}
