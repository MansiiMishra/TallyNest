import { useCallback, useEffect, useMemo, useState } from 'react'
import type { FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { CalendarDays, CircleHelp, Cookie, CreditCard, Home, LogOut, Settings, Users } from 'lucide-react'
import { activeBusinessForUser, addCustomerNote, createCustomer, csvDownload, deleteClosureRule, loadBusinessData, newIdempotencyKey, rpc, saveClosureRule, saveCustomer, saveSettings, saveSlot } from './lib/data'
import { isSupabaseConfigured, supabase } from './lib/supabase'
import type { Business, ClosureRule, Customer, CustomerBalance, Order, Slot } from './types/database'
import {
  AuthScreen, BookingDialog, CalendarScreen, ClosureDialog, CustomerDialog, CustomerScreen,
  CustomerDetailScreen, OrderDialog, PaymentDialog, RemindersScreen, SettingsScreen,
  TodayScreen, WorkspaceSetupScreen, type AppPage, type BusinessData, type BookingForm, type OrderForm,
} from './screens'

const navItems: { label: AppPage; icon: typeof Home }[] = [
  { label: 'Today', icon: Home }, { label: 'Calendar', icon: CalendarDays },
  { label: 'Customers', icon: Users }, { label: 'Reminders', icon: CreditCard },
  { label: 'Settings', icon: Settings },
]

function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [authReady, setAuthReady] = useState(false)
  const [businessId, setBusinessId] = useState<string | null>(null)
  const [membershipReady, setMembershipReady] = useState(false)
  const [data, setData] = useState<BusinessData | null>(null)
  const [loading, setLoading] = useState(false)
  const [page, setPage] = useState<AppPage>('Today')
  const [selectedDay, setSelectedDay] = useState('')
  const [selectedCustomerId, setSelectedCustomerId] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [notice, setNotice] = useState<{ kind: 'error' | 'success'; text: string } | null>(null)
  const [modal, setModal] = useState<'order' | 'booking' | 'customer' | 'payment' | 'return' | 'closure' | null>(null)
  const [editingCustomer, setEditingCustomer] = useState<Customer | null>(null)
  const [editingOrder, setEditingOrder] = useState<Order | null>(null)
  const [paymentOrderId, setPaymentOrderId] = useState<string | null>(null)
  const [returnToOrderAfterCustomer, setReturnToOrderAfterCustomer] = useState(false)
  const [writing, setWriting] = useState(false)

  useEffect(() => {
    if (!supabase) { setAuthReady(true); return }
    void supabase.auth.getSession().then(({ data: authData }) => {
      setSession(authData.session)
      setAuthReady(true)
    })
    const { data: listener } = supabase.auth.onAuthStateChange((_event, current) => setSession(current))
    return () => listener.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    let cancelled = false
    if (!session) { setBusinessId(null); setData(null); setMembershipReady(false); return }
    setMembershipReady(false)
    void activeBusinessForUser(session.user.id).then(id => {
      if (!cancelled) { setBusinessId(id); setMembershipReady(true) }
    }).catch(error => {
      if (!cancelled) {
        setNotice({ kind: 'error', text: error instanceof Error ? error.message : 'Could not check business access.' })
        setMembershipReady(true)
      }
    })
    return () => { cancelled = true }
  }, [session])

  const refreshData = useCallback(async () => {
    if (!businessId) return
    setLoading(true)
    try {
      setData(await loadBusinessData(businessId))
    } catch (error) {
      setNotice({ kind: 'error', text: error instanceof Error ? error.message : 'Could not load business data.' })
    } finally { setLoading(false) }
  }, [businessId])

  useEffect(() => { void refreshData() }, [refreshData])
  useEffect(() => {
    if (!businessId) return
    const refreshOnFocus = () => { void refreshData() }
    window.addEventListener('focus', refreshOnFocus)
    return () => window.removeEventListener('focus', refreshOnFocus)
  }, [businessId, refreshData])

  const perform = useCallback(async <T,>(action: () => Promise<T>, success?: string): Promise<T> => {
    setWriting(true)
    try {
      const result = await action()
      await refreshData()
      if (success) setNotice({ kind: 'success', text: success })
      return result
    } catch (error) {
      setNotice({ kind: 'error', text: error instanceof Error ? error.message : 'The change could not be saved.' })
      throw error
    } finally { setWriting(false) }
  }, [refreshData])

  const customers = data?.customers ?? []
  const activeCustomers = customers.filter(customer => customer.status === 'active')
  const balances = data?.balances ?? []
  const selectedCustomer = customers.find(customer => customer.id === selectedCustomerId) ?? null
  const selectedBalance = balances.find(balance => balance.customer_id === selectedCustomerId) ?? null

  async function signIn(event: FormEvent<HTMLFormElement>, email: string) {
    event.preventDefault()
    if (!supabase) return false
    setWriting(true)
    const { error } = await supabase.auth.signInWithOtp({ email: email.trim(), options: { emailRedirectTo: window.location.origin, shouldCreateUser: true } })
    setWriting(false)
    if (error) { setNotice({ kind: 'error', text: error.message }); return false }
    setNotice({ kind: 'success', text: 'Secure sign-in link sent. Open it on this device to continue.' })
    return true
  }

  async function createWorkspace(event: FormEvent<HTMLFormElement>, name: string) {
    event.preventDefault()
    if (!supabase) return
    setWriting(true)
    try {
      const id = await rpc<string>('create_business_for_current_user', { p_name: name.trim() })
      setBusinessId(id)
      setPage('Today')
      setNotice({ kind: 'success', text: 'Your workspace is ready.' })
    } catch (error) {
      setNotice({ kind: 'error', text: error instanceof Error ? error.message : 'Could not create your business.' })
    } finally { setWriting(false) }
  }

  async function signOut() {
    if (!supabase) return
    const { error } = await supabase.auth.signOut()
    if (error) setNotice({ kind: 'error', text: error.message })
  }

  const addOrder = () => { setEditingOrder(null); setModal('order') }
  const editOrder = (order: Order) => { setEditingOrder(order); setModal('order') }
  const openPayment = (kind: 'payment' | 'return', orderId: string | null = null) => { setPaymentOrderId(orderId); setModal(kind) }

  async function saveOrder(values: OrderForm) {
    if (!businessId) throw new Error('No active business is selected.')
    await perform(() => editingOrder?.id
      ? rpc('update_scheduled_order', {
          p_business_id: businessId, p_order_id: editingOrder.id, p_service_date: values.serviceDate,
          p_slot_id: values.slotId || null, p_description: values.description || null,
          p_quantity: values.quantity, p_amount_minor: values.amountMinor, p_order_kind: values.orderKind,
          p_note: values.note || null, p_allow_closed: values.allowClosed, p_idempotency_key: newIdempotencyKey(),
        })
      : rpc('create_order', {
          p_business_id: businessId, p_customer_id: values.customerId, p_service_date: values.serviceDate,
          p_slot_id: values.slotId || null, p_description: values.description || null,
          p_quantity: values.quantity, p_amount_minor: values.amountMinor, p_order_kind: values.orderKind,
          p_note: values.note || null, p_allow_closed: values.allowClosed, p_idempotency_key: newIdempotencyKey(),
        }), editingOrder ? 'Order updated.' : 'Order added.')
    setModal(null)
  }

  async function setDelivered(order: Order, delivered: boolean) {
    if (!businessId) return
    await perform(() => rpc(delivered ? 'mark_order_delivered' : 'undo_order_delivery', {
      p_business_id: businessId, p_order_id: order.id, p_idempotency_key: newIdempotencyKey(),
    }), delivered ? 'Marked delivered.' : 'Delivery undone.')
  }

  async function cancelOrder(order: Order) {
    if (!businessId) return
    await perform(() => rpc('cancel_order', { p_business_id: businessId, p_order_id: order.id, p_idempotency_key: newIdempotencyKey() }), 'Order cancelled.')
  }

  async function saveBooking(values: BookingForm) {
    if (!businessId) throw new Error('No active business is selected.')
    await perform(() => rpc('create_week_booking', {
      p_business_id: businessId, p_customer_id: values.customerId, p_starts_on: values.startsOn,
      p_week_count: values.weekCount, p_weekdays: values.weekdays, p_slot_id: values.slotId || null,
      p_description: values.description || null, p_amount_per_order_minor: values.amountMinor,
      p_extend_for_closures: values.extendForClosures, p_advance_minor: values.advanceMinor,
      p_advance_method: values.advanceMethod || null, p_advance_date: values.advanceDate,
      p_idempotency_key: newIdempotencyKey(),
    }), 'Week booking created.')
    setModal(null)
  }

  async function savePayment(values: { customerId: string; amountMinor: number; date: string; method: string | null; note: string; taggedOrderId: string | null; kind: 'received' | 'returned' }) {
    if (!businessId) throw new Error('No active business is selected.')
    const action = values.kind === 'received'
      ? () => rpc('record_payment', { p_business_id: businessId, p_customer_id: values.customerId, p_amount_minor: values.amountMinor, p_occurred_on: values.date, p_payment_method: values.method, p_reference_note: values.note || null, p_tagged_order_id: values.taggedOrderId, p_idempotency_key: newIdempotencyKey() })
      : () => rpc('record_return', { p_business_id: businessId, p_customer_id: values.customerId, p_amount_minor: values.amountMinor, p_occurred_on: values.date, p_reference_note: values.note || null, p_tagged_order_id: values.taggedOrderId, p_idempotency_key: newIdempotencyKey() })
    await perform(action, values.kind === 'received' ? 'Payment recorded.' : 'Return recorded.')
    setModal(null)
  }

  async function reverseEntry(entryId: string) {
    if (!businessId) return
    await perform(() => rpc('reverse_ledger_entry', { p_business_id: businessId, p_ledger_entry_id: entryId, p_idempotency_key: newIdempotencyKey() }), 'Reversal recorded as a new ledger entry.')
  }

  async function saveCustomerForm(values: { id?: string; fullName: string; phone: string | null; flat: string | null; building: string | null; address: string | null; note: string | null; status: 'active' | 'archived' }) {
    if (!businessId) throw new Error('No active business is selected.')
    const action = values.id
      ? () => saveCustomer({ businessId, customerId: values.id!, fullName: values.fullName, phone: values.phone, flat: values.flat, building: values.building, address: values.address, status: values.status })
      : async () => {
          const customer = await createCustomer({ businessId, fullName: values.fullName, phone: values.phone, flat: values.flat, building: values.building, address: values.address, note: values.note })
          return customer
        }
    const customer = await perform(action, values.id ? 'Customer updated.' : 'Customer added to your community.')
    if (!values.id) setSelectedCustomerId(customer.id)
    setEditingCustomer(null)
    setModal(!values.id && returnToOrderAfterCustomer ? 'order' : null)
    setReturnToOrderAfterCustomer(false)
  }

  async function addNote(customerId: string, note: string) {
    if (!businessId) return
    await perform(() => addCustomerNote(businessId, customerId, note), 'Note added.')
  }

  async function saveBusinessSettings(values: Omit<Business, 'id'> & { id?: string }) {
    if (!businessId) return
    await perform(() => saveSettings({
      businessId, name: values.name, countryCode: values.country_code, currencyCode: values.currency_code,
      timeZone: values.time_zone, reminderWeekday: values.reminder_weekday, reminderDay: values.reminder_day,
      reminderTime: values.reminder_time, reminderTemplate: values.reminder_template ?? '', terminology: values.terminology,
    }), 'Business settings saved.')
  }

  async function upsertSlot(slot: Partial<Slot> & { name: string }) {
    if (!businessId) return
    await perform(() => saveSlot({ businessId, id: slot.id, name: slot.name, startsAt: slot.starts_at ?? null,
      endsAt: slot.ends_at ?? null, sortOrder: slot.sort_order ?? 0, isActive: slot.is_active ?? true }), 'Delivery slot saved.')
  }

  async function saveClosure(values: { id?: string; rule: Record<string, string | number | null> }) {
    if (!businessId) return
    await perform(() => saveClosureRule(businessId, values.id ?? null, values.rule), 'Closure saved.')
    setModal(null)
  }

  async function removeClosure(rule: ClosureRule) {
    if (!businessId) return
    await perform(() => deleteClosureRule(businessId, rule.id), 'Closure removed.')
  }

  async function recordReminder(customerId: string, channel: 'whatsapp' | 'clipboard', action: 'opened' | 'copied') {
    if (!businessId) throw new Error('No active business is selected.')
    return perform(() => rpc<{ reminder_event_id: string }>('record_reminder', {
      p_business_id: businessId, p_customer_id: customerId, p_reminder_date: todayFor(data?.business.time_zone),
      p_channel: channel, p_action: action, p_idempotency_key: newIdempotencyKey(),
    }), 'Reminder action recorded.')
  }

  async function undoReminder(eventId: string) {
    if (!businessId) return
    const reminder = data?.reminders.find(item => item.id === eventId)
    await perform(() => rpc('undo_reminder', { p_business_id: businessId, p_event_id: eventId, p_idempotency_key: newIdempotencyKey() }), `Reminder undone for ${reminder?.reminder_date ?? 'today'}.`)
  }

  const filteredCustomers = useMemo(() => activeCustomers.filter(customer => {
    const q = search.trim().toLowerCase()
    return !q || [customer.full_name, customer.phone_e164, customer.flat_number, customer.building, customer.address_text].some(value => value?.toLowerCase().includes(q))
  }), [activeCustomers, search])

  if (!authReady) return <div className="loading-screen"><span className="loading-mark"><Cookie size={24}/></span><p>Opening your kitchen…</p></div>
  if (!session) return <AuthScreen configured={isSupabaseConfigured} notice={notice} busy={writing} onSubmit={signIn}/>
  if (!membershipReady) return <div className="loading-screen"><span className="loading-mark"><Cookie size={24}/></span><p>Opening your workspace…</p></div>
  if (!businessId) return <WorkspaceSetupScreen email={session.user.email ?? ''} notice={notice} busy={writing} onSubmit={createWorkspace} onSignOut={() => void signOut()}/>
  if (!data && loading) return <div className="loading-screen"><span className="loading-mark"><Cookie size={24}/></span><p>Opening your workspace…</p></div>

  const business = data?.business
  const customerMap = new Map(customers.map(customer => [customer.id, customer]))
  const slotMap = new Map((data?.slots ?? []).map(slot => [slot.id, slot]))
  const orderStatusMap = new Map((data?.orderStatuses ?? []).map(status => [status.order_id, status]))
  const selectedOrders = data?.orders.filter(order => order.customer_id === selectedCustomerId) ?? []
  const selectedEntries = data?.entries.filter(entry => entry.customer_id === selectedCustomerId) ?? []
  const selectedNotes = data?.notes.filter(note => note.customer_id === selectedCustomerId) ?? []

  return <div className="app-shell">
    <aside className="sidebar">
      <a className="brand" href="#today" onClick={() => setPage('Today')}><span className="brand-icon"><Cookie size={22}/></span><span><strong>TallyNest</strong></span></a>
      <div className="business-switcher"><span className="business-avatar">{business?.name?.[0]?.toUpperCase() ?? 'H'}</span><span className="business-name"><strong>{business?.name ?? 'Loading…'}</strong><small>Business workspace</small></span></div>
      <span className="nav-caption">WORKSPACE</span>
      <nav className="main-nav" aria-label="Main navigation">{navItems.map(({ label, icon: Icon }) => <button key={label} className={`nav-link ${page === label || (page === 'Customer Detail' && label === 'Customers') ? 'active' : ''}`} aria-current={page === label || (page === 'Customer Detail' && label === 'Customers') ? 'page' : undefined} onClick={() => setPage(label)}><Icon size={18} strokeWidth={1.8}/><span>{label}</span></button>)}</nav>
      <div className="sidebar-spacer"/>
      <div className="help-card"><span className="help-icon"><CircleHelp size={16}/></span><strong>Your order book, made simple.</strong><p>Changes save online and follow you across devices.</p><button onClick={() => setPage('Settings')}>Business settings</button></div>
      <div className="profile-row"><span className="profile-avatar">{session.user.email?.[0]?.toUpperCase() ?? 'Y'}</span><span className="profile-name"><strong>{session.user.email?.split('@')[0] ?? 'Your account'}</strong><small>{session.user.email}</small></span><button className="icon-button" aria-label="Sign out" onClick={() => void signOut()}><LogOut size={17}/></button></div>
    </aside>
    <nav className="mobile-nav" aria-label="Main navigation">{navItems.map(({ label, icon: Icon }) => <button key={label} className={`mobile-nav-link ${page === label || (page === 'Customer Detail' && label === 'Customers') ? 'active' : ''}`} aria-current={page === label || (page === 'Customer Detail' && label === 'Customers') ? 'page' : undefined} onClick={() => setPage(label)}><Icon size={19} strokeWidth={1.9}/><span>{label}</span></button>)}</nav>
    <main className="main-area">
      <header className="topbar"><div className="mobile-brand"><Cookie size={20}/><strong>TallyNest</strong></div><div className="breadcrumb">Workspace <span>›</span> <strong>{page}</strong></div><div className="topbar-actions"><span className="online-badge"><span/> Online workspace</span><button className="icon-button" aria-label="Help" onClick={() => setPage('Settings')}><CircleHelp size={18}/></button></div></header>
      <section className="page-content">
        {notice && <div className={`notice ${notice.kind}`} role="status"><span>{notice.text}</span><button className="icon-button" aria-label="Dismiss" onClick={() => setNotice(null)}>×</button></div>}
        {loading && <div className="loading-banner">Refreshing your business book…</div>}
        {data && page === 'Today' && <TodayScreen business={business!} data={data} day={selectedDay || todayFor(business!.time_zone)} onDayChange={setSelectedDay} onAddOrder={addOrder} onAddBooking={() => setModal('booking')} onMarkDelivered={order => void setDelivered(order, true)} onUndoDelivery={order => void setDelivered(order, false)} onEditOrder={editOrder} onCancelOrder={order => void cancelOrder(order)} onRefresh={() => void refreshData()} onCustomer={id => { setSelectedCustomerId(id); setPage('Customer Detail') }} />}
        {data && page === 'Calendar' && <CalendarScreen business={business!} data={data} onSelectDay={day => { setSelectedDay(day); setPage('Today') }} onAddOrder={addOrder} onAddBooking={() => setModal('booking')}/>}
        {data && page === 'Customers' && <CustomerScreen data={data} filtered={filteredCustomers} query={search} onQuery={setSearch} onAdd={() => { setEditingCustomer(null); setModal('customer') }} onOpen={id => { setSelectedCustomerId(id); setPage('Customer Detail') }} onExport={() => exportCustomers(data)}/>}
        {data && page === 'Customer Detail' && selectedCustomer && selectedBalance && <CustomerDetailScreen business={business!} customer={selectedCustomer} balance={selectedBalance} orders={selectedOrders} entries={selectedEntries} notes={selectedNotes} slots={slotMap} paymentStatuses={orderStatusMap} onBack={() => setPage('Customers')} onEdit={() => { setEditingCustomer(selectedCustomer); setModal('customer') }} onAddOrder={() => { setEditingOrder(null); setModal('order') }} onRepeatOrder={() => { const last = selectedOrders.filter(order => order.status !== 'cancelled').sort((a,b) => b.service_date.localeCompare(a.service_date))[0]; setEditingOrder(last ? { ...last, id: '', service_date: todayFor(business!.time_zone), status: 'scheduled' } : null); setModal('order') }} onPayment={orderId => openPayment('payment', orderId)} onReturn={() => openPayment('return')} onReverseEntry={entryId => void reverseEntry(entryId)} onArchive={() => void saveCustomerForm({ id: selectedCustomer.id, fullName: selectedCustomer.full_name, phone: selectedCustomer.phone_e164, flat: selectedCustomer.flat_number, building: selectedCustomer.building, address: selectedCustomer.address_text, note: null, status: 'archived' })} onAddNote={note => void addNote(selectedCustomer.id, note)}/>}
        {data && page === 'Customer Detail' && !selectedCustomer && <div className="empty-state"><strong>Choose a customer to see their account.</strong><button className="text-button" onClick={() => setPage('Customers')}>Back to customers</button></div>}
        {data && page === 'Reminders' && <RemindersScreen business={business!} balances={balances} events={data.reminders} onWhatsApp={async customer => { const number = (customer.phone_e164 ?? '').replace(/\D/g, ''); if (!number) { setNotice({ kind: 'error', text: 'Add a phone number to this customer before opening WhatsApp.' }); return } await recordReminder(customer.customer_id, 'whatsapp', 'opened'); window.open(`https://wa.me/${number}?text=${encodeURIComponent(reminderMessage(business!, customer))}`, '_blank', 'noopener,noreferrer') }} onCopy={async customer => { const message = reminderMessage(business!, customer); await navigator.clipboard.writeText(message); await recordReminder(customer.customer_id, 'clipboard', 'copied') }} onUndo={id => void undoReminder(id)}/>}
        {data && page === 'Settings' && <SettingsScreen business={business!} slots={data.slots} closures={data.closures} onSaveBusiness={saveBusinessSettings} onSaveSlot={upsertSlot} onAddClosure={() => setModal('closure')} onRemoveClosure={rule => void removeClosure(rule)} onExportCustomers={() => exportCustomers(data)} onExportOrders={() => exportOrders(data, customerMap)} onExportPayments={() => exportPayments(data, customerMap)}/>}
      </section>
      <footer className="footer"><span>Made with care for the people who make it by hand.</span><span>TallyNest <span className="footer-dot">·</span> V1</span></footer>
    </main>
    {data && modal === 'customer' && <CustomerDialog customer={editingCustomer} customers={customers} business={business!} busy={writing} onClose={() => { if(returnToOrderAfterCustomer){setModal('order');setReturnToOrderAfterCustomer(false)}else setModal(null) }} onSave={saveCustomerForm}/>}
    {data && (modal === 'order' || (modal === 'customer' && returnToOrderAfterCustomer)) && <OrderDialog order={editingOrder} customers={activeCustomers} slots={data.slots.filter(slot => slot.is_active)} closures={data.closures} business={business!} selectedCustomerId={selectedCustomerId} selectedDay={selectedDay || todayFor(business!.time_zone)} busy={writing} onClose={() => {setModal(null);setReturnToOrderAfterCustomer(false)}} onSave={saveOrder} onAddCustomer={() => { setEditingCustomer(null); setReturnToOrderAfterCustomer(true); setModal('customer') }}/>}
    {data && modal === 'booking' && <BookingDialog customers={activeCustomers} slots={data.slots.filter(slot => slot.is_active)} business={business!} selectedCustomerId={selectedCustomerId} selectedDay={selectedDay || todayFor(business!.time_zone)} busy={writing} onClose={() => setModal(null)} onSave={saveBooking}/>}
    {data && (modal === 'payment' || modal === 'return') && <PaymentDialog kind={modal === 'payment' ? 'received' : 'returned'} customers={activeCustomers} orders={data.orders} business={business!} initialCustomerId={selectedCustomerId} initialOrderId={paymentOrderId} busy={writing} onClose={() => setModal(null)} onSave={savePayment}/>}
    {data && modal === 'closure' && <ClosureDialog business={business!} slots={data.slots.filter(slot => slot.is_active)} orders={data.orders} customers={customerMap} closures={data.closures} busy={writing} onClose={() => setModal(null)} onSave={saveClosure}/>}
  </div>
}

function todayFor(timeZone = 'Asia/Kolkata') {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date())
  return `${parts.find(part => part.type === 'year')?.value}-${parts.find(part => part.type === 'month')?.value}-${parts.find(part => part.type === 'day')?.value}`
}

function reminderMessage(business: Business, customer: CustomerBalance) {
  const amount = new Intl.NumberFormat('en-IN', { style: 'currency', currency: business.currency_code, maximumFractionDigits: 0 }).format(customer.total_owed_minor / 100)
  const date = customer.oldest_unpaid_on ? new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short', timeZone: 'UTC' }).format(new Date(`${customer.oldest_unpaid_on}T00:00:00Z`)) : '—'
  const template = business.reminder_template || 'Hi {customer_name}, your pending amount at {business_name} is {total_owed}. Please pay when convenient. Thank you!'
  return template.replaceAll('{customer_name}', customer.full_name).replaceAll('{business_name}', business.name).replaceAll('{total_owed}', amount).replaceAll('{date_owed_since}', date)
}

function exportCustomers(data: BusinessData) {
  const rows = data.customers.map(customer => ({ name: customer.full_name, phone: customer.phone_e164, flat: customer.flat_number, building: customer.building, address: customer.address_text, status: customer.status }))
  csvDownload('tallynest-customers.csv', rows)
}
function exportOrders(data: BusinessData, customerMap: Map<string, Customer>) {
  const rows = data.orders.map(order => ({ date: order.service_date, customer: customerMap.get(order.customer_id)?.full_name ?? '', description: order.description, quantity: order.quantity, amount_minor: order.amount_minor, kind: order.order_kind, status: order.status, note: order.note }))
  csvDownload('tallynest-orders.csv', rows)
}
function exportPayments(data: BusinessData, customerMap: Map<string, Customer>) {
  const rows = data.entries.map(entry => ({ date: entry.occurred_on, customer: customerMap.get(entry.customer_id)?.full_name ?? '', kind: entry.entry_kind, amount_minor: entry.amount_minor, method: entry.payment_method, note: entry.reference_note, tagged_order_id: entry.tagged_order_id, reversal_of_id: entry.reversal_of_id }))
  csvDownload('tallynest-payments.csv', rows)
}

export default App
