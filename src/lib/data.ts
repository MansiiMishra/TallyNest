import { supabase } from './supabase'
import type {
  Business, ClosureRule, Customer, CustomerBalance, CustomerNote, LedgerEntry, Order,
  OrderPaymentStatus, ReminderEvent, Slot,
} from '../types/database'

// The schema is maintained in SQL migrations; keep this boundary small until
// Supabase CLI generated Database types are checked into the project.
type QueryResult<T> = { data: T | null; error: { message: string } | null }
type QueryFactory = () => any

function db(): any {
  if (!supabase) throw new Error('Supabase is not configured. Add the project URL and publishable key to .env.local.')
  return supabase
}

function unwrap<T>(result: QueryResult<T>): T {
  if (result.error) throw new Error(result.error.message)
  if (result.data === null) throw new Error('The request returned no data.')
  return result.data
}

async function allRows<T>(query: QueryFactory): Promise<T[]> {
  const rows: T[] = []
  for (let offset = 0; ; offset += 1000) {
    const result = await query().range(offset, offset + 999)
    if (result.error) throw new Error(result.error.message)
    const batch = (result.data ?? []) as T[]
    rows.push(...batch)
    if (batch.length < 1000) return rows
  }
}

export async function loadBusinessData(businessId: string) {
  const client = db()
  const [businessResult, customers, balances, slots, closures, orders, bookings, entries, orderStatuses, notes, reminders] = await Promise.all([
    client.from('businesses').select('*').eq('id', businessId).single(),
    allRows<Customer>(() => client.from('customers').select('*').eq('business_id', businessId).order('full_name')),
    allRows<CustomerBalance>(() => client.from('customer_balances').select('*').eq('business_id', businessId).order('full_name')),
    allRows<Slot>(() => client.from('slots').select('*').eq('business_id', businessId).order('sort_order').order('name')),
    allRows<ClosureRule>(() => client.from('closure_rules').select('*').eq('business_id', businessId).order('created_at', { ascending: false })),
    allRows<Order>(() => client.from('orders').select('*').eq('business_id', businessId).order('service_date')),
    allRows<Record<string, any>>(() => client.from('bookings').select('*').eq('business_id', businessId).order('starts_on', { ascending: false })),
    allRows<LedgerEntry>(() => client.from('ledger_entries').select('*').eq('business_id', businessId).order('occurred_on', { ascending: false })),
    allRows<OrderPaymentStatus>(() => client.from('order_payment_status').select('*').eq('business_id', businessId)),
    allRows<CustomerNote>(() => client.from('customer_notes').select('*').eq('business_id', businessId).order('created_at', { ascending: false })),
    allRows<ReminderEvent>(() => client.from('reminder_events').select('*').eq('business_id', businessId).order('created_at', { ascending: false })),
  ])
  if (businessResult.error) throw new Error(businessResult.error.message)
  return {
    business: businessResult.data as Business,
    customers, balances, slots, closures, orders, bookings, entries, orderStatuses, notes, reminders,
  }
}

export async function activeBusinessForUser(userId: string): Promise<string | null> {
  const result = await db().from('business_memberships').select('business_id').eq('user_id', userId).eq('status', 'active').order('created_at').limit(1).maybeSingle()
  if (result.error) throw new Error(result.error.message)
  return result.data?.business_id ?? null
}

export async function createCustomer(input: {
  businessId: string; fullName: string; phone: string | null; flat: string | null; building: string | null; address: string | null; note: string | null
}) {
  const result = await db().from('customers').insert({
    business_id: input.businessId, full_name: input.fullName, phone_e164: input.phone,
    flat_number: input.flat, building: input.building, address_text: input.address,
  }).select('*').single()
  const customer = unwrap<Customer>(result)
  if (input.note) {
    const noteResult = await db().from('customer_notes').insert({ business_id: input.businessId, customer_id: customer.id, note: input.note })
    if (noteResult.error) throw new Error(`Customer was added, but the note could not be saved: ${noteResult.error.message}`)
  }
  return customer
}

export async function saveCustomer(input: { businessId: string; customerId: string; fullName: string; phone: string | null; flat: string | null; building: string | null; address: string | null; status: 'active' | 'archived' }) {
  const result = await db().from('customers').update({
    full_name: input.fullName, phone_e164: input.phone, flat_number: input.flat,
    building: input.building, address_text: input.address, status: input.status,
    archived_at: input.status === 'archived' ? new Date().toISOString() : null,
  }).eq('business_id', input.businessId).eq('id', input.customerId).select('*').single()
  return unwrap<Customer>(result)
}

export async function addCustomerNote(businessId: string, customerId: string, note: string) {
  const result = await db().from('customer_notes').insert({ business_id: businessId, customer_id: customerId, note }).select('*').single()
  return unwrap<CustomerNote>(result)
}

export async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const result = await db().rpc(name, args)
  if (result.error) throw new Error(result.error.message)
  return result.data as T
}

export async function saveSlot(input: { businessId: string; id?: string; name: string; startsAt: string | null; endsAt: string | null; sortOrder: number; isActive: boolean }) {
  const payload = { name: input.name, starts_at: input.startsAt, ends_at: input.endsAt, sort_order: input.sortOrder, is_active: input.isActive }
  const result = input.id
    ? await db().from('slots').update(payload).eq('business_id', input.businessId).eq('id', input.id).select('*').single()
    : await db().from('slots').insert({ ...payload, business_id: input.businessId }).select('*').single()
  return unwrap<Slot>(result)
}

export async function saveSettings(input: {
  businessId: string; name: string; countryCode: string; currencyCode: string; timeZone: string;
  reminderWeekday: number | null; reminderDay: number | null; reminderTime: string | null;
  reminderTemplate: string; terminology: Record<string, string>
}) {
  return rpc<Business>('update_business_settings', {
    p_business_id: input.businessId, p_name: input.name, p_country_code: input.countryCode,
    p_currency_code: input.currencyCode, p_time_zone: input.timeZone,
    p_reminder_weekday: input.reminderWeekday, p_reminder_day: input.reminderDay,
    p_reminder_time: input.reminderTime, p_reminder_template: input.reminderTemplate,
    p_terminology: input.terminology,
  })
}

export async function saveClosureRule(businessId: string, ruleId: string | null, rule: Record<string, string | number | null>) {
  return rpc<ClosureRule>('save_closure_rule', { p_business_id: businessId, p_rule_id: ruleId, p_rule: rule })
}

export async function deleteClosureRule(businessId: string, ruleId: string) {
  return rpc<null>('delete_closure_rule', { p_business_id: businessId, p_rule_id: ruleId })
}

export function newIdempotencyKey() {
  return crypto.randomUUID()
}

export function amountToMinorUnits(value: string) {
  const amount = Number(value)
  if (!Number.isFinite(amount) || amount <= 0) throw new Error('Enter an amount greater than zero.')
  const minor = Math.round(amount * 100)
  if (!Number.isSafeInteger(minor)) throw new Error('That amount is too large.')
  return minor
}

export function formatMoney(minor: number, currency = 'INR') {
  return new Intl.NumberFormat('en-IN', { style: 'currency', currency, maximumFractionDigits: currency === 'INR' ? 0 : 2 }).format(minor / 100)
}

export function localDate(value = new Date(), timeZone = 'Asia/Kolkata') {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(value)
  const part = (type: string) => parts.find(item => item.type === type)?.value ?? ''
  return `${part('year')}-${part('month')}-${part('day')}`
}

export function normalizePhone(raw: string, countryCode: string) {
  const trimmed = raw.trim()
  if (!trimmed) return null
  const digits = trimmed.replace(/\D/g, '')
  if (trimmed.startsWith('+')) return `+${digits}`
  return `+${countryCode.replace(/\D/g, '')}${digits.replace(/^0+/, '')}`
}

export function csvDownload(filename: string, rows: Array<Record<string, string | number | null>>) {
  if (!rows.length) return
  const headers = Object.keys(rows[0])
  const quote = (value: unknown) => `"${String(value ?? '').replaceAll('"', '""')}"`
  const content = [headers.map(quote).join(','), ...rows.map(row => headers.map(header => quote(row[header])).join(','))].join('\r\n')
  const blob = new Blob([`\uFEFF${content}`], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  URL.revokeObjectURL(url)
}
