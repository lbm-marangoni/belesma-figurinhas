// Teste de aceitacao 7 (spec §17): "duas propostas com a mesma copia:
// aceitar as duas quase junto, so uma passa".
//
// PGlite tem uma conexao so, entao a corrida de verdade so acontece aqui,
// contra o Supabase, com dois clientes HTTP disparando em paralelo.
// Tambem confere o Realtime das propostas.
//
//   SUPABASE_SERVICE_ROLE_KEY=... node scripts/trocas-http.mjs

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const env = Object.fromEntries(
  readFileSync(join(raiz, '.env.local'), 'utf8')
    .split('\n').filter((l) => l.includes('=') && !l.trim().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)
const URL = env.VITE_SUPABASE_URL, ANON = env.VITE_SUPABASE_ANON_KEY
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SERVICE) { console.error('falta SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const admin = createClient(URL, SERVICE, { auth: { persistSession: false } })

// linha de base: o banco tem jogadores de verdade, entao a afericao final e
// por delta. Nenhum script de teste pode encostar em dado real.
const { count: comDonoAntes } = await admin.from('card_copies')
  .select('id', { count: 'exact', head: true }).not('owner_id', 'is', null)
let falhas = 0
const checar = (n, ok, d) => {
  console.log(`  ${ok ? 'PASS' : 'FALHA'}  ${n}${d ? ' -> ' + d : ''}`); if (!ok) falhas++
}

const SENHA = 'trocas-123456'
const NICKS = ['troca1', 'troca2', 'troca3']

// ---------------------------------------------------------------- preparo
console.log('preparando...')
const cli = {}
for (const nick of NICKS) {
  const email = `${nick}@belesma.local`
  const { data: lista } = await admin.auth.admin.listUsers({ perPage: 200 })
  const velho = lista?.users?.find((u) => u.email === email)
  if (velho) { await admin.from('players').delete().eq('id', velho.id); await admin.auth.admin.deleteUser(velho.id) }
  const { data: u, error } = await admin.auth.admin.createUser({ email, password: SENHA, email_confirm: true })
  if (error) { console.error(error.message); process.exit(2) }
  const c = createClient(URL, ANON, { auth: { persistSession: false } })
  await c.auth.signInWithPassword({ email, password: SENHA })
  await c.rpc('claim_nickname', { p_nickname: nick })
  cli[nick] = { c, id: u.user.id }
}

// entrega cartas direto (o sorteio ja foi testado na Fase 2)
const daCarta = async (uid, offset) => {
  const { data } = await admin.from('card_copies')
    .select('id').is('owner_id', null).eq('burned', false).order('id').range(offset, offset)
  const id = data[0].id
  await admin.from('card_copies').update({ owner_id: uid, claimed_at: new Date().toISOString() }).eq('id', id)
  return id
}
const clientesIds = NICKS.map((n) => cli[n].id)
const alvo   = await daCarta(cli.troca1.id, 0)   // a carta disputada
const doDois = await daCarta(cli.troca2.id, 1)
const doTres = await daCarta(cli.troca3.id, 2)

// ================================================================ realtime
console.log('\n== realtime ==')
let recebeu = null
const canal = cli.troca2.c.channel('teste-trocas')
  .on('postgres_changes', { event: '*', schema: 'public', table: 'trades' },
      (p) => { recebeu = p.new ?? p.old })
const estadoCanal = await new Promise((r) => {
  canal.subscribe((estado) => { if (estado !== 'SUBSCRIBING') r(estado) })
  setTimeout(() => r('TIMEOUT'), 12000)
})
checar('canal de realtime conectou', estadoCanal === 'SUBSCRIBED', estadoCanal)

const { data: pAviso, error: eAviso } = await cli.troca1.c.rpc('propose_trade', {
  p_offered_copy_id: alvo, p_offered_baba: 0, p_requested_copy_id: doDois, p_requested_baba: 0,
})
checar('proposta criada por HTTP', !eAviso && !!pAviso?.id, eAviso?.message)
// o Realtime respeita a RLS: so chega para quem e parte da troca
for (let i = 0; i < 24 && recebeu === null; i++) await new Promise((r) => setTimeout(r, 500))
checar('o destinatario recebeu o evento de realtime', recebeu !== null,
  recebeu ? `trade ${recebeu.id}` : 'nenhum evento em 12s')
await cli.troca2.c.removeChannel(canal)

// limpa para a corrida
await cli.troca1.c.rpc('cancel_trade', { p_trade_id: pAviso.id })

// ================================================================ corrida
console.log('\n== corrida: duas propostas com a MESMA copia (teste 7) ==')
const { data: p1 } = await cli.troca1.c.rpc('propose_trade', {
  p_offered_copy_id: alvo, p_offered_baba: 0, p_requested_copy_id: doDois, p_requested_baba: 0 })
const { data: p2 } = await cli.troca1.c.rpc('propose_trade', {
  p_offered_copy_id: alvo, p_offered_baba: 0, p_requested_copy_id: doTres, p_requested_baba: 0 })
checar('duas propostas pendentes com a mesma carta', !!p1?.id && !!p2?.id)

// os dois aceitam no mesmo instante
const [r2, r3] = await Promise.all([
  cli.troca2.c.rpc('accept_trade', { p_trade_id: p1.id }),
  cli.troca3.c.rpc('accept_trade', { p_trade_id: p2.id }),
])
const resultado = (r) => r.error ? { ok: false, motivo: r.error.message } : r.data
const a2 = resultado(r2), a3 = resultado(r3)
console.log('   troca2:', JSON.stringify(a2))
console.log('   troca3:', JSON.stringify(a3))

const passou = [a2, a3].filter((x) => x?.ok === true).length
checar('exatamente UMA das duas passou', passou === 1, `${passou} passaram`)

const { data: dono } = await admin.from('card_copies').select('owner_id').eq('id', alvo).single()
const nomeDono = Object.entries(cli).find(([, v]) => v.id === dono.owner_id)?.[0]
checar('a carta disputada tem exatamente um dono', !!nomeDono, nomeDono)
checar('o dono e quem teve o aceite aprovado',
  (a2.ok === true && nomeDono === 'troca2') || (a3.ok === true && nomeDono === 'troca3'),
  nomeDono)

const { data: sobrando } = await admin.from('trades').select('id, status').in('id', [p1.id, p2.id])
checar('nenhuma proposta ficou pendente',
  sobrando.every((t) => t.status !== 'pending'),
  sobrando.map((t) => t.status).join('/'))

// nada pode ter sumido nem duplicado. Afericao por DELTA: o banco tem
// jogadores de verdade jogando ao mesmo tempo, entao numero absoluto nao
// serve. As 3 cartas do teste continuam sendo 3, e so.
const { data: dosTestes } = await admin.from('card_copies')
  .select('id, owner_id').in('id', [alvo, doDois, doTres])
const idsTeste = new Set(clientesIds)
checar('as 3 cartas do teste seguem com donos do teste',
  dosTestes.length === 3 && dosTestes.every((c) => idsTeste.has(c.owner_id)),
  dosTestes.map((c) => c.owner_id?.slice(0, 4)).join('/'))

// ---------------------------------------------------------------- limpeza
console.log('\nlimpando...')
// LIMPEZA: escopo restrito aos usuarios de teste.
//
// A versao anterior fazia delete().neq('id', 0) em copy_history,
// pack_openings e admin_log - ou seja, GLOBAL. Isso apaga o historico de
// jogadores de verdade. Script de teste nao pode encostar em dado real.
for (const nick of NICKS) {
  const { id } = cli[nick]
  await admin.from('trades').delete().eq('from_player', id)
  await admin.from('trades').delete().eq('to_player', id)
  await admin.from('copy_history').delete().eq('to_player', id)
  await admin.from('copy_history').delete().eq('from_player', id)
}
for (const nick of NICKS) {
  const { id, c } = cli[nick]
  await admin.from('card_copies').update({ owner_id: null, claimed_at: null }).eq('owner_id', id)
  await c.auth.signOut()
  await admin.from('players').delete().eq('id', id)
  await admin.auth.admin.deleteUser(id)
}
const { count: sobrou } = await admin.from('card_copies')
  .select('id', { count: 'exact', head: true }).not('owner_id', 'is', null)
checar('o acervo dos jogadores REAIS ficou intacto', sobrou === comDonoAntes,
  `${comDonoAntes} antes, ${sobrou} depois`)

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
process.exit(falhas === 0 ? 0 : 1)
