import { act, cleanup, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import App from './App'
import { supabase } from './lib/supabase'

const harness = vi.hoisted(() => ({
  authListener: null as ((event: string, session: unknown) => void) | null,
  session: null as any,
  membershipId: null as string | null,
  businessData: null as any,
}))

vi.mock('./lib/supabase', () => ({
  isSupabaseConfigured: true,
  supabase: {
    auth: {
      getSession: vi.fn(async () => ({ data: { session: harness.session } })),
      onAuthStateChange: vi.fn((callback: (event: string, session: unknown) => void) => {
        harness.authListener = callback
        return { data: { subscription: { unsubscribe: vi.fn() } } }
      }),
      signInWithOtp: vi.fn(async () => ({ error: null })),
      signOut: vi.fn(async () => ({ error: null })),
    },
  },
}))

vi.mock('./lib/data', () => {
  const refreshBalance = (customerId: string) => {
    const customer = harness.businessData.customers.find((item: any) => item.id === customerId)
    if (!customer) return
    const orders = harness.businessData.orders.filter((item: any) => item.customer_id === customerId)
    const entries = harness.businessData.entries.filter((item: any) => item.customer_id === customerId)
    const delivered = orders.filter((item: any) => item.status === 'delivered')
    const charges = delivered.reduce((sum: number, item: any) => sum + item.amount_minor, 0)
    const received = entries.filter((item: any) => item.entry_kind === 'received').reduce((sum: number, item: any) => sum + item.amount_minor, 0)
    const returned = entries.filter((item: any) => item.entry_kind === 'returned').reduce((sum: number, item: any) => sum + item.amount_minor, 0)
    const booked = orders.filter((item: any) => item.status === 'scheduled')
    const balance = {
      business_id: customer.business_id, customer_id: customerId, full_name: customer.full_name,
      phone_e164: customer.phone_e164, flat_number: customer.flat_number, building: customer.building,
      address_text: customer.address_text, status: customer.status, created_at: customer.created_at,
      total_owed_minor: charges - received + returned, delivered_charges_minor: charges,
      net_received_minor: received - returned, oldest_unpaid_on: null,
      booked_order_count: booked.length, booked_minor: booked.reduce((sum: number, item: any) => sum + item.amount_minor, 0),
      next_booked_on: booked[0]?.service_date ?? null, last_reminded_on: null,
    }
    const existing = harness.businessData.balances.findIndex((item: any) => item.customer_id === customerId)
    if (existing < 0) harness.businessData.balances.push(balance)
    else harness.businessData.balances[existing] = balance
  }

  return {
    amountToMinorUnits: (value: string) => Math.round(Number(value) * 100),
    activeBusinessForUser: vi.fn(async () => harness.membershipId),
    addCustomerNote: vi.fn(async () => null),
    createCustomer: vi.fn(async (input: any) => {
      const customer = {
        id: 'customer-1', business_id: input.businessId, full_name: input.fullName,
        phone_e164: input.phone, flat_number: input.flat, building: input.building,
        address_text: input.address, status: 'active', created_at: '2026-11-24T00:00:00.000Z',
      }
      harness.businessData.customers.push(customer)
      refreshBalance(customer.id)
      return customer
    }),
    csvDownload: vi.fn(),
    deleteClosureRule: vi.fn(),
    loadBusinessData: vi.fn(async () => structuredClone(harness.businessData)),
    newIdempotencyKey: vi.fn(() => 'test-idempotency-key'),
    formatMoney: (minor: number, currency = 'INR') => new Intl.NumberFormat('en-IN', { style: 'currency', currency, maximumFractionDigits: 0 }).format(minor / 100),
    normalizePhone: (raw: string, countryCode: string) => raw.trim() ? `+${countryCode}${raw.replace(/\D/g, '').replace(/^0+/, '')}` : null,
    rpc: vi.fn(async (name: string, args: any) => {
      if (name === 'create_business_for_current_user') {
        harness.membershipId = 'business-1'
        harness.businessData.business.name = args.p_name
        return 'business-1'
      }
      if (name === 'create_order') {
        const order = {
          id: 'order-1', business_id: args.p_business_id, customer_id: args.p_customer_id,
          booking_id: null, slot_id: args.p_slot_id, service_date: args.p_service_date,
          description: args.p_description, quantity: args.p_quantity, amount_minor: args.p_amount_minor,
          order_kind: args.p_order_kind, status: 'scheduled', delivered_at: null,
          cancelled_at: null, note: args.p_note, row_version: 1,
        }
        harness.businessData.orders.push(order)
        refreshBalance(order.customer_id)
        return { order_id: order.id }
      }
      if (name === 'mark_order_delivered' || name === 'undo_order_delivery') {
        const order = harness.businessData.orders.find((item: any) => item.id === args.p_order_id)
        order.status = name === 'mark_order_delivered' ? 'delivered' : 'scheduled'
        order.delivered_at = name === 'mark_order_delivered' ? `${order.service_date}T12:00:00.000Z` : null
        refreshBalance(order.customer_id)
        return { order_id: order.id }
      }
      if (name === 'record_payment' || name === 'record_return') {
        const entry = {
          id: 'ledger-1', business_id: args.p_business_id, customer_id: args.p_customer_id,
          entry_kind: name === 'record_payment' ? 'received' : 'returned', amount_minor: args.p_amount_minor,
          occurred_on: args.p_occurred_on, payment_method: args.p_payment_method ?? null,
          reference_note: args.p_reference_note, tagged_order_id: args.p_tagged_order_id,
          reversal_of_id: null, created_at: `${args.p_occurred_on}T12:00:00.000Z`,
        }
        harness.businessData.entries.push(entry)
        refreshBalance(entry.customer_id)
        return { ledger_entry_id: entry.id }
      }
      return null
    }),
    saveClosureRule: vi.fn(),
    saveCustomer: vi.fn(async (input: any) => {
      const customer = harness.businessData.customers.find((item: any) => item.id === input.customerId)
      Object.assign(customer, {
        full_name: input.fullName, phone_e164: input.phone, flat_number: input.flat,
        building: input.building, address_text: input.address, status: input.status,
      })
      refreshBalance(customer.id)
      return customer
    }),
    saveSettings: vi.fn(),
    saveSlot: vi.fn(),
  }
})

function emptyBusinessData() {
  return {
    business: {
      id: 'business-1', name: 'New business', country_code: 'IN', currency_code: 'INR',
      time_zone: 'Asia/Kolkata', terminology: {}, reminder_weekday: null, reminder_day: null,
      reminder_time: null, reminder_template: null,
    },
    customers: [], balances: [], slots: [], closures: [], orders: [], bookings: [],
    entries: [], orderStatuses: [], notes: [], reminders: [],
  }
}

describe('owner setup and daily workflow', () => {
  beforeEach(() => {
    harness.authListener = null
    harness.session = null
    harness.membershipId = null
    harness.businessData = emptyBusinessData()
  })

  afterEach(() => cleanup())

  it('signs up, creates a workspace, adds and updates a customer, records a payment, and tracks today’s order', async () => {
    const user = userEvent.setup()
    render(<App />)

    await user.type(await screen.findByLabelText('Email address'), 'owner@example.com')
    await user.click(screen.getByRole('button', { name: /continue with email/i }))
    expect(supabase?.auth.signInWithOtp).toHaveBeenCalledWith({
      email: 'owner@example.com',
      options: { emailRedirectTo: window.location.origin, shouldCreateUser: true },
    })
    expect(await screen.findByRole('heading', { name: /check your inbox/i })).toBeTruthy()

    const session = { user: { id: 'owner-1', email: 'owner@example.com' } }
    act(() => harness.authListener?.('SIGNED_IN', session))
    await screen.findByRole('heading', { name: /set up your business/i })
    await user.type(screen.getByLabelText('Business name'), 'Sunny Kitchen')
    await user.click(screen.getByRole('button', { name: /^continue$/i }))
    await screen.findByText('Today’s orders')
    expect(harness.businessData.business.name).toBe('Sunny Kitchen')

    await user.click(screen.getAllByRole('button', { name: 'Customers' })[0])
    await user.click(screen.getByRole('button', { name: 'Add a customer' }))
    await user.type(screen.getByLabelText('Full name'), 'Samira Patel')
    await user.type(screen.getByLabelText(/phone number/i), '9876543210')
    await user.click(screen.getByRole('button', { name: 'Save customer' }))
    await screen.findByText('Samira Patel')

    await user.click(screen.getByRole('button', { name: /Samira Patel/i }))
    await user.click(screen.getByRole('button', { name: 'Edit details' }))
    const nameInput = screen.getByLabelText('Full name')
    await user.clear(nameInput)
    await user.type(nameInput, 'Samira Shah')
    await user.click(screen.getByRole('button', { name: 'Save details' }))
    await screen.findByRole('heading', { name: 'Samira Shah' })

    await user.click(screen.getAllByRole('button', { name: 'Today' })[0])
    await user.click(screen.getAllByRole('button', { name: /add an order/i })[0])
    await user.selectOptions(screen.getByLabelText('Customer'), 'customer-1')
    await user.type(screen.getByLabelText('Description'), 'Lunch box')
    await user.type(screen.getByLabelText('Amount (INR)'), '12.50')
    await user.click(screen.getByRole('button', { name: 'Add order' }))
    await screen.findByText('Lunch box')

    await user.click(screen.getAllByRole('button', { name: 'Mark delivered' })[1])
    await screen.findByRole('button', { name: /delivered.*undo/i })
    expect(harness.businessData.orders[0].status).toBe('delivered')

    await user.click(screen.getByRole('button', { name: /Samira Shah/i }))
    await user.click(screen.getByRole('button', { name: /record payment/i }))
    await user.type(screen.getByLabelText('Amount (INR)'), '12.50')
    await user.click(within(screen.getByRole('dialog', { name: 'Record payment' })).getByRole('button', { name: /record payment/i }))
    await screen.findByText('Payment received')

    expect(harness.businessData.entries).toHaveLength(1)
    expect(harness.businessData.entries[0].amount_minor).toBe(1250)
    expect(harness.businessData.balances[0].total_owed_minor).toBe(0)
    expect(screen.getByText(/balance/i)).toBeTruthy()
  })
})
