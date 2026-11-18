export type OrderStatus = 'scheduled' | 'delivered' | 'cancelled'
export type CustomerStatus = 'active' | 'archived'
export type OrderKind = 'regular' | 'bulk'
export type PaymentMethod = 'cash' | 'upi' | 'bank_transfer' | 'other'
export type ClosureAction = 'closed' | 'open_exception'
export type ClosureType = 'date_range' | 'daily' | 'weekday' | 'monthly_date' | 'monthly_weekday' | 'exception'

export interface Business {
  id: string
  name: string
  country_code: string
  currency_code: string
  time_zone: string
  terminology: Record<string, string>
  reminder_weekday: number | null
  reminder_day: number | null
  reminder_time: string | null
  reminder_template: string | null
}

export interface Customer {
  id: string
  business_id: string
  full_name: string
  phone_e164: string | null
  flat_number: string | null
  building: string | null
  address_text: string | null
  status: CustomerStatus
  created_at: string
}

export interface CustomerBalance {
  business_id: string
  customer_id: string
  full_name: string
  phone_e164: string | null
  flat_number: string | null
  building: string | null
  address_text: string | null
  status: CustomerStatus
  created_at: string
  total_owed_minor: number
  delivered_charges_minor: number
  net_received_minor: number
  oldest_unpaid_on: string | null
  booked_order_count: number
  booked_minor: number
  next_booked_on: string | null
  last_reminded_on: string | null
}

export interface Slot {
  id: string
  business_id: string
  name: string
  starts_at: string | null
  ends_at: string | null
  sort_order: number
  is_active: boolean
}

export interface ClosureRule {
  id: string
  business_id: string
  slot_id: string | null
  rule_type: ClosureType
  starts_on: string | null
  ends_on: string | null
  weekday: number | null
  month_day: number | null
  week_of_month: number | null
  action: ClosureAction
  reason: string | null
}

export interface Booking {
  id: string
  business_id: string
  customer_id: string
  slot_id: string | null
  starts_on: string
  week_count: number
  weekdays: number[]
  description: string | null
  amount_per_order_minor: number
  status: 'draft' | 'confirmed' | 'cancelled'
}

export interface Order {
  id: string
  business_id: string
  customer_id: string
  booking_id: string | null
  slot_id: string | null
  service_date: string
  description: string | null
  quantity: number
  amount_minor: number
  order_kind: OrderKind
  status: OrderStatus
  delivered_at: string | null
  cancelled_at: string | null
  note: string | null
  row_version: number
}

export interface OrderPaymentStatus {
  order_id: string
  business_id: string
  customer_id: string
  service_date: string
  delivered_at: string
  charge_minor: number
  tagged_applied_minor: number
  general_applied_minor: number
  unpaid_minor: number
  payment_status: 'unpaid' | 'partly_paid' | 'paid'
}

export interface LedgerEntry {
  id: string
  business_id: string
  customer_id: string
  tagged_order_id: string | null
  entry_kind: 'received' | 'returned'
  amount_minor: number
  occurred_on: string
  payment_method: PaymentMethod | null
  reference_note: string | null
  reversal_of_id: string | null
  created_at: string
}

export interface CustomerNote {
  id: string
  business_id: string
  customer_id: string
  note: string
  created_at: string
}

export interface ReminderEvent {
  id: string
  business_id: string
  customer_id: string
  reminder_date: string
  channel: 'whatsapp' | 'clipboard'
  action: 'opened' | 'copied' | 'undone' | 'prepared' | 'cancelled'
  undo_of_id: string | null
  created_at: string
}
