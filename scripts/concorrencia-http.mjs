// Teste de aceitacao da Fase 2 (spec secao 15):
// "dois navegadores abrindo ao mesmo tempo nao repetem serial".
//
// PGlite tem uma conexao so, entao concorrencia de verdade so da para testar
// aqui, contra o Supabase, com varios clientes HTTP disparando em paralelo.
//
//   SUPABASE_SERVICE_ROLE_KEY=... node scripts/concorrencia-http.mjs

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
const URL = env.VITE_SUPABASE_URL
const ANON = env.VITE_SUPABASE_ANON_KEY
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SERVICE) { console.error('falta SUPABASE_SERVICE_ROLE_KEY'); process.exit(2) }

const admin = createClient(URL, SERVICE, { auth: { persistSession: false } })
let falhas = 0
const checar = (nome, ok, det) => {
  console.log(`  ${ok ? 'PASS' : 'FALHA'}  ${nome}${det ? ' -> ' + det : ''}`)
  if (!ok) falhas++
}

const N_JOGADORES = 6
const PACOTES = 12          // por jogador, todos disparados em paralelo
const SENHA = 'concorrencia-123456'

// ---------------------------------------------------------------- preparo
console.log(`preparando ${N_JOGADORES} jogadores...`)
const clientes = []
for (let i = 0; i < N_JOGADORES; i++) {
  const nick = `teste${i}`
  const email = `${nick}@belesma.local`

  const { data: lista } = await admin.auth.admin.listUsers({ perPage: 200 })
  const velho = lista?.users?.find((u) => u.email === email)
  if (velho) {
    await admin.rpc('admin_reset_player_collection', { p_nickname: nick }).catch(() => {})
    await admin.from('players').delete().eq('id', velho.id)
    await admin.auth.admin.deleteUser(velho.id)
  }

  const { data: u, error } = await admin.auth.admin.createUser({
    email, password: SENHA, email_confirm: true,
  })
  if (error) { console.error(error.message); process.exit(2) }

  const c = createClient(URL, ANON, { auth: { persistSession: false } })
  await c.auth.signInWithPassword({ email, password: SENHA })
  await c.rpc('claim_nickname', { p_nickname: nick })
  clientes.push({ nick, id: u.user.id, c })
}

// allotment inicial e 12/5/2; garante pacote suficiente
const chefe = clientes[0]
await admin.from('players').update({ is_admin: true }).eq('id', chefe.id)
await chefe.c.rpc('grant_packs', { p_target: 'todos', p_pack_type: 'comum', p_quantidade: PACOTES })
await admin.from('players').update({ is_admin: false }).eq('id', chefe.id)

const antes = await admin.from('card_copies').select('id', { count: 'exact', head: true }).not('owner_id', 'is', null)

// ---------------------------------------------------------------- disparo
console.log(`abrindo ${N_JOGADORES * PACOTES} pacotes, todos em paralelo...`)
const t0 = Date.now()
const chamadas = []
for (const { nick, c } of clientes) {
  for (let i = 0; i < PACOTES; i++) {
    chamadas.push(c.rpc('open_pack', { pack_type: 'comum' }).then((r) => ({ nick, ...r })))
  }
}
const respostas = await Promise.all(chamadas)
console.log(`  ${((Date.now() - t0) / 1000).toFixed(1)}s`)

const ok = respostas.filter((r) => !r.error)
const erro = respostas.filter((r) => r.error)
console.log(`  ${ok.length} pacotes abertos, ${erro.length} com erro`)
if (erro.length) console.log('   ', [...new Set(erro.map((e) => e.error.message))].join(' | '))
checar('nenhuma abertura falhou', erro.length === 0, `${erro.length} erros`)

// ---------------------------------------------------------------- invariantes
const todasCopias = ok.flatMap((r) => r.data.cartas.map((c) => c.copy_id))
const unicas = new Set(todasCopias)
checar('nenhuma copia entregue duas vezes',
  unicas.size === todasCopias.length,
  `${todasCopias.length} entregues / ${unicas.size} distintas`)

// confere no banco: cada copia tem UM dono, e o dono e quem abriu
const donoEsperado = new Map()
for (const r of ok) for (const c of r.data.cartas) donoEsperado.set(c.copy_id, r.nick)

const ids = [...unicas]
const donos = []
for (let i = 0; i < ids.length; i += 500) {
  const { data } = await admin.from('card_copies')
    .select('id, owner_id, card_type_id, serial_number').in('id', ids.slice(i, i + 500))
  donos.push(...data)
}
const nickPorId = Object.fromEntries(clientes.map((c) => [c.id, c.nick]))
checar('toda copia entregue tem dono no banco', donos.every((d) => d.owner_id !== null))
checar('o dono no banco e quem abriu o pacote',
  donos.every((d) => nickPorId[d.owner_id] === donoEsperado.get(d.id)))

const chaveSerial = new Set(donos.map((d) => `${d.card_type_id}:${d.serial_number}`))
checar('nenhum (tipo, serial) repetido entre os entregues',
  chaveSerial.size === donos.length, `${chaveSerial.size}/${donos.length}`)

const depois = await admin.from('card_copies').select('id', { count: 'exact', head: true }).not('owner_id', 'is', null)
checar('o acervo cresceu exatamente o que foi entregue',
  depois.count - antes.count === unicas.size,
  `${depois.count - antes.count} vs ${unicas.size}`)

// a auditoria tem que bater com o que foi devolvido
const { count: auditadas } = await admin.from('pack_opening_cards')
  .select('id', { count: 'exact', head: true })
checar('auditoria registrou toda carta entregue',
  auditadas === todasCopias.length, `${auditadas} vs ${todasCopias.length}`)

// ---------------------------------------------------------------- limpeza
console.log('\nlimpando...')
await admin.from('players').update({ is_admin: true }).eq('id', chefe.id)
for (const { nick } of clientes) {
  await chefe.c.rpc('admin_reset_player_collection', { p_nickname: nick })
}
await admin.from('players').update({ is_admin: false }).eq('id', chefe.id)
for (const { id, c } of clientes) {
  await c.auth.signOut()
  await admin.from('players').delete().eq('id', id)
  await admin.auth.admin.deleteUser(id)
}
// LIMPEZA: escopo restrito aos usuarios de teste.
//
// A versao anterior fazia delete().neq('id', 0) em copy_history,
// pack_openings e admin_log - ou seja, GLOBAL. Isso apaga o historico de
// jogadores de verdade. Script de teste nao pode encostar em dado real.
for (const { id } of clientes) {
  const { data: ab } = await admin.from('pack_openings').select('id').eq('player_id', id)
  const ids = (ab ?? []).map((a) => a.id)
  if (ids.length) await admin.from('pack_opening_cards').delete().in('opening_id', ids)
  await admin.from('pack_openings').delete().eq('player_id', id)
  await admin.from('copy_history').delete().eq('to_player', id)
  await admin.from('copy_history').delete().eq('from_player', id)
  await admin.from('admin_log').delete().eq('admin_id', id)
}

const sobrou = await admin.from('card_copies').select('id', { count: 'exact', head: true }).not('owner_id', 'is', null)
checar('o acervo dos jogadores REAIS ficou intacto', sobrou.count === antes.count,
  `${antes.count} antes, ${sobrou.count} depois`)

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
process.exit(falhas === 0 ? 0 : 1)
