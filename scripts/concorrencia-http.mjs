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
    // sobra de uma rodada anterior. Desfaz as estreias ANTES de apagar: o FK
    // e `on delete set null` e a copia ficaria descoberta por ninguem.
    await admin.from('card_copies')
      .update({ first_discovered_at: null, first_discovered_by: null })
      .eq('first_discovered_by', velho.id)
    // `.catch()` nao existe no builder do postgrest - ele e thenable, nao
    // Promise. O erro vem no campo .error.
    await admin.rpc('admin_reset_player_collection', { p_nickname: nick })
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

// UM POR UM, nunca 'todos'.
//
// Isto dizia `p_target: 'todos'` e o grant_packs entende 'todos' ao pe da
// letra: `where p_target = 'todos' or nickname = ...`. Cada rodada deste
// teste dava 12 pacotes comuns a TODOS os jogadores do banco - os de
// verdade junto - e a limpeza ainda apagava a linha do admin_log, entao nao
// sobrava nem rastro. Medido: os tres jogadores reais estavam com +12.
//
// Teste que roda em producao nao pode ter alvo coletivo. Nenhum.
for (const { nick } of clientes) {
  await chefe.c.rpc('grant_packs',
    { p_target: nick, p_pack_type: 'comum', p_quantidade: PACOTES })
}
await admin.from('players').update({ is_admin: false }).eq('id', chefe.id)

// Fotografia dos jogadores REAIS, para cobrar no fim que nada os tocou.
const reaisAntes = Object.fromEntries(
  ((await admin.from('players').select('nickname, packs_common, packs_rare, packs_ultra, baba')).data ?? [])
    .filter((p) => !clientes.some((c) => c.nick === p.nickname))
    .map((p) => [p.nickname, JSON.stringify(p)]))

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
//
// Contar pack_opening_cards INTEIRA compara este teste com o banco todo: o
// acervo real do grupo entrava na conta e o numero nunca fechava (352 vs
// 293, sendo 59 aberturas de verdade). A contagem e das aberturas DESTES
// jogadores, so.
const idsAbertura = []
for (const { id } of clientes) {
  const { data } = await admin.from('pack_openings').select('id').eq('player_id', id)
  idsAbertura.push(...(data ?? []).map((a) => a.id))
}
let auditadas = 0
for (let i = 0; i < idsAbertura.length; i += 500) {
  const { count } = await admin.from('pack_opening_cards')
    .select('id', { count: 'exact', head: true })
    .in('opening_id', idsAbertura.slice(i, i + 500))
  auditadas += count ?? 0
}
checar('auditoria registrou toda carta entregue',
  auditadas === todasCopias.length, `${auditadas} vs ${todasCopias.length}`)

// ---------------------------------------------------------------- limpeza
console.log('\nlimpando...')

// ESTREIAS. Isto precisa vir ANTES de apagar os jogadores.
//
// open_pack grava first_discovered_at/by na copia. O FK de
// first_discovered_by e `on delete set null`, entao apagar o jogador de
// teste deixava a copia marcada como DESCOBERTA sem descobridor: uma
// estreia fantasma, que rouba do grupo a chance de fazer a primeira.
// Foi assim que 26 tipos apareceram descobertos por ninguem.
//
// So limpa o que ESTES jogadores descobriram agora.
for (const { id } of clientes) {
  const { data, error } = await admin.from('card_copies')
    .update({ first_discovered_at: null, first_discovered_by: null })
    .eq('first_discovered_by', id)
    .select('id')
  if (error) console.log('  ! falhou limpar estreias:', error.message)
  else if (data?.length) console.log(`  estreias de teste desfeitas: ${data.length}`)
}
await admin.from('players').update({ is_admin: true }).eq('id', chefe.id)
for (const { nick } of clientes) {
  await chefe.c.rpc('admin_reset_player_collection', { p_nickname: nick })
}
await admin.from('players').update({ is_admin: false }).eq('id', chefe.id)

// LIMPEZA: escopo restrito aos usuarios de teste, e nesta ORDEM.
//
// Historico ANTES do jogador. copy_history, pack_openings e admin_log
// referenciam players; apagar o jogador primeiro faz o delete falhar por FK.
// A versao anterior fazia isso e ignorava o erro - a linha do jogador so
// sumia de tabela por causa do cascade de auth.users, e quando o deleteUser
// tambem falhava sobrava um `teste0` orfao no jogo de verdade.
//
// (A versao ANTES dessa fazia delete().neq('id', 0) - global. Isso apagou o
// historico de jogador real uma vez. Escopo por id, sempre.)
const erroLimpeza = []
const anota = (onde, { error }) => { if (error) erroLimpeza.push(`${onde}: ${error.message}`) }

for (const { id } of clientes) {
  const { data: ab } = await admin.from('pack_openings').select('id').eq('player_id', id)
  const ids = (ab ?? []).map((a) => a.id)
  if (ids.length) anota('pack_opening_cards',
    await admin.from('pack_opening_cards').delete().in('opening_id', ids))
  anota('pack_openings', await admin.from('pack_openings').delete().eq('player_id', id))
  anota('copy_history/to', await admin.from('copy_history').delete().eq('to_player', id))
  anota('copy_history/from', await admin.from('copy_history').delete().eq('from_player', id))
  anota('baba_log', await admin.from('baba_log').delete().eq('player_id', id))
  anota('album_colagem', await admin.from('album_colagem').delete().eq('player_id', id))
  anota('admin_log', await admin.from('admin_log').delete().eq('admin_id', id))
}

for (const { id, c } of clientes) {
  await c.auth.signOut()
  anota('players', await admin.from('players').delete().eq('id', id))
  const { error } = await admin.auth.admin.deleteUser(id)
  if (error) erroLimpeza.push(`deleteUser: ${error.message}`)
}
checar('a limpeza nao engoliu nenhum erro', erroLimpeza.length === 0, erroLimpeza.join(' | '))

const sobrou = await admin.from('card_copies').select('id', { count: 'exact', head: true }).not('owner_id', 'is', null)
checar('o acervo dos jogadores REAIS ficou intacto', sobrou.count === antes.count,
  `${antes.count} antes, ${sobrou.count} depois`)

// nenhuma copia pode terminar marcada como descoberta sem descobridor
const fantasmas = await admin.from('card_copies')
  .select('id', { count: 'exact', head: true })
  .not('first_discovered_at', 'is', null).is('first_discovered_by', null)
checar('nenhuma estreia fantasma ficou para tras', fantasmas.count === 0,
  `${fantasmas.count} copias descobertas por ninguem`)
// nenhum jogador de teste pode sobrar no jogo de verdade
const { data: sobrando } = await admin.from('players')
  .select('nickname').in('nickname', clientes.map((c) => c.nick))
checar('nenhum jogador de teste sobrou', (sobrando ?? []).length === 0,
  (sobrando ?? []).map((p) => p.nickname).join(', ') || 'nenhum')
// Nenhum jogador REAL pode ter sido tocado por este teste.
{
  const depois = Object.fromEntries(
    ((await admin.from('players').select('nickname, packs_common, packs_rare, packs_ultra, baba')).data ?? [])
      .map((p) => [p.nickname, JSON.stringify(p)]))
  const mexidos = Object.keys(reaisAntes).filter((n) => reaisAntes[n] !== depois[n])
  checar('nenhum jogador real teve pacote ou baba alterado', mexidos.length === 0,
    mexidos.map((n) => `${n}: ${reaisAntes[n]} -> ${depois[n]}`).join(' | ') || 'nenhum')
}

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
process.exit(falhas === 0 ? 0 : 1)
