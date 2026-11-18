import { createClient } from '@supabase/supabase-js'

const url = process.env.SUPABASE_URL
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY
const businessName = process.env.BUSINESS_NAME?.trim()
const ownerEmail = process.env.OWNER_EMAIL?.trim().toLowerCase()

if (!url || !serviceKey || !businessName || !ownerEmail) {
  console.error('Set SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, BUSINESS_NAME, and OWNER_EMAIL in this PowerShell session.')
  process.exit(1)
}
if (serviceKey.startsWith('sb_publishable_')) {
  console.error('Use the project service_role secret from Supabase server-side settings. Never use a publishable/anon key here.')
  process.exit(1)
}

const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
let businessId
try {
  const { data: business, error: businessError } = await admin.from('businesses').insert({ name: businessName }).select('id').single()
  if (businessError) throw businessError
  businessId = business.id

  const { data: invite, error: inviteError } = await admin.auth.admin.inviteUserByEmail(ownerEmail, {
    redirectTo: process.env.AUTH_REDIRECT_URL || 'http://127.0.0.1:3000',
    data: { business_name: businessName },
  })
  if (inviteError) throw inviteError

  const { error: memberError } = await admin.from('business_memberships').insert({
    business_id: businessId,
    user_id: invite.user.id,
    role: 'owner',
    status: 'active',
    invited_at: new Date().toISOString(),
    activated_at: new Date().toISOString(),
  })
  if (memberError) throw memberError

  console.log(`Created business ${businessName} (${businessId}) and invited ${ownerEmail}.`)
  console.log('Check the owner inbox for the Supabase sign-in email. The membership is active after link authentication.')
} catch (error) {
  if (businessId) {
    const { error: cleanupError } = await admin.from('businesses').delete().eq('id', businessId)
    if (cleanupError) console.error(`Cleanup needed: remove business ${businessId} in Supabase; ${cleanupError.message}`)
  }
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
