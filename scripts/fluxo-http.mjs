// Fluxo completo da Fase 2 pelo caminho do usuario: cadastro com apelido e
// senha, abertura de pacote, leitura da colecao. Tudo pela anon key, por HTTP,
// contra o Supabase de verdade - do jeito que o navegador faz.
//
//   SUPABASE_SERVICE_ROLE_KEY=... node scripts/fluxo-http.mjs
//
// A service key so e usada na limpeza no fim.

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
let falhas = 0
const checar = (n, ok, d) => {
  console.log(`  ${ok ? 'PASS' : 'FALHA'}  ${n}${d ? ' -> ' + d : ''}`); if (!ok) falhas++
}

const NICK = 'fluxo1', SENHA = 'fluxo-123456'
const EMAIL = `${NICK}@belesma.local`

// limpa resto de execucao anterior
{
  const { data } = await admin.auth.admin.listUsers({ perPage: 200 })
  const v = data?.users?.find((u) => u.email === EMAIL)
  if (v) { await admin.from('players').delete().eq('id', v.id); await admin.auth.admin.deleteUser(v.id) }
}

// linha de base: quantas copias JA tinham dono antes do teste. O banco tem
// jogadores de verdade, entao a afericao e por delta, nunca por zero absoluto.
const { count: comDonoAntes } = await admin.from('card_copies')
  .select('id', { count: 'exact', head: true }).not('owner_id', 'is', null)

const c = createClient(URL, ANON, { auth: { persistSession: false } })

// ================================================================ cadastro
console.log('\n== cadastro com apelido + senha (secao 10) ==')
const { data: livre } = await c.rpc('nickname_disponivel', { p_nickname: NICK })
checar('nickname_disponivel responde para anon', livre === true, String(livre))

const { error: eUp } = await c.auth.signUp({ email: EMAIL, password: SENHA })
checar('signUp com e-mail sintetico .local aceito', !eUp, eUp?.message)
if (eUp) { console.log('\nFALHA CRITICA: o Auth rejeita o dominio sintetico.'); process.exit(1) }

const { data: pl, error: eNick } = await c.rpc('claim_nickname', { p_nickname: NICK })
checar('claim_nickname cria o jogador', !eNick, eNick?.message)
checar('allotment inicial 12/5/2',
  pl?.packs_common === 12 && pl?.packs_rare === 5 && pl?.packs_ultra === 2,
  `${pl?.packs_common}/${pl?.packs_rare}/${pl?.packs_ultra}`)
checar('nao nasce admin', pl?.is_admin === false)

const { data: dep } = await c.rpc('nickname_disponivel', { p_nickname: NICK })
checar('apelido fica travado depois', dep === false)

// login de novo, como quem volta ao site
await c.auth.signOut()
const { error: eIn } = await c.auth.signInWithPassword({ email: EMAIL, password: SENHA })
checar('login volta a funcionar', !eIn, eIn?.message)

// ================================================================ abrir
console.log('\n== abrir pacote ==')
const { data: r, error: eOpen } = await c.rpc('open_pack', { pack_type: 'comum' })
checar('open_pack responde', !eOpen, eOpen?.message)
checar('4 ou 5 cartas', r?.cartas?.length === 4 || r?.cartas?.length === 5, `${r?.cartas?.length}`)
checar('toda carta traz art_path e serial',
  r.cartas.every((x) => x.art_path && x.serial_number > 0 && x.print_run > 0))
checar('reveal_index veio embaralhado do servidor',
  new Set(r.cartas.map((x) => x.reveal_index)).size === r.cartas.length)
// ESTREIA MUNDIAL e do TIPO, nao da copia nem do jogador.
//
// A versao anterior exigia que a PRIMEIRA abertura de um jogador novo
// estreasse algo. Isso so valia enquanto o bug existia: cada copia contava
// como estreia, entao todo pacote acendia. Num mundo com tipos ja
// descobertos, um jogador novo pode abrir varios pacotes sem estrear nada -
// e isso e o certo.
//
// O que da para cobrar sempre: nada marcado como estreia pode ser de um tipo
// que ja tinha saido antes.
{
  const marcadas = r.cartas.filter((x) => x.estreia_mundial === true)
  let mentiu = 0
  for (const x of marcadas) {
    const { count } = await admin.from('card_copies')
      .select('id', { count: 'exact', head: true })
      .eq('card_type_id', x.card_type_id)
      .not('first_discovered_at', 'is', null)
      .neq('id', x.copy_id)
    if ((count ?? 0) > 0) mentiu++
  }
  checar('nenhuma estreia mundial falsa (tipo que ja tinha saido)', mentiu === 0,
    `${marcadas.length} marcadas, ${mentiu} falsas`)
}

const { data: me1 } = await c.rpc('me')
checar('consumiu um pacote comum', me1.packs_common === 11, `${me1.packs_common}`)

// sem pacote suficiente, falha limpo
for (let i = 0; i < 11; i++) await c.rpc('open_pack', { pack_type: 'comum' })
const { error: eSem } = await c.rpc('open_pack', { pack_type: 'comum' })
checar('sem pacote, erro claro', !!eSem && /sem pacote/.test(eSem.message), eSem?.message)

// ================================================================ colecao
console.log('\n== colecao ==')
const { data: acervo, error: eCol } = await c
  .from('card_copies')
  .select(`copy_id:id, serial_number, seal, origin,
           card_types!inner ( print_run, tier, skin, characters!inner ( slug, name ) )`)
  .eq('owner_id', pl.id)
checar('le o proprio acervo pela anon key', !eCol, eCol?.message)
checar('acervo tem as cartas abertas', (acervo?.length ?? 0) >= 40, `${acervo?.length} copias`)

// So as PUXADAS sao 6642. A forja cria supply PARALELO (spec §7), entao a
// contagem total de card_copies cresce alem disso de proposito.
const { count: puxadas } = await c.from('card_copies')
  .select('id', { count: 'exact', head: true }).eq('origin', 'pull')
checar('a tiragem puxavel segue em 6642', puxadas === 6642, `${puxadas}`)
const { count: total } = await c.from('card_copies').select('id', { count: 'exact', head: true })
checar('indice global continua publico', (total ?? 0) >= 6642, `${total} linhas`)

// ================================================================ admin
console.log('\n== /admin so para admin ==')
for (const [nome, chamada] of [
  ['admin_jogadores', c.rpc('admin_jogadores')],
  ['admin_stock_report', c.rpc('admin_stock_report')],
  ['grant_packs', c.rpc('grant_packs', { p_target: 'todos', p_pack_type: 'ultra', p_quantidade: 99 })],
  ['seed_edition', c.rpc('seed_edition', { p_params: { slug: 'invasor' } })],
  ['admin_reset_all_collections', c.rpc('admin_reset_all_collections', { p_confirmacao: 'RESETAR' })],
]) {
  const { error } = await chamada
  checar(`jogador comum: ${nome} negado`, !!error, error?.message?.slice(0, 40))
}

await admin.from('players').update({ is_admin: true }).eq('id', pl.id)
const { data: meAdmin } = await c.rpc('me')
checar('me() ja reflete is_admin', meAdmin.is_admin === true)
const { data: js, error: eJs } = await c.rpc('admin_jogadores')
checar('admin: admin_jogadores funciona', !eJs && Array.isArray(js), eJs?.message)
const { data: est } = await c.rpc('admin_stock_report')
checar('admin: estoque bate com o seed',
  est.selos.emitidos === 51 && est.selos.branco === 36, `${est.selos.emitidos} selos`)
const { error: eOdds } = await c.rpc('admin_set_pack_config', {
  p_rows: [{ pack_type: 'comum', slot: 'hit', tier: 'rara', weight: 50 }],
})
checar('admin: odds que nao somam 100 sao recusadas', !!eOdds, eOdds?.message?.slice(0, 45))
const { data: somaOdds } = await c.from('pack_config').select('weight')
  .eq('pack_type', 'comum').eq('slot', 'hit')
checar('as odds recusadas nao ficaram gravadas',
  somaOdds.reduce((a, x) => a + Number(x.weight), 0) === 100)

const { data: seco } = await c.rpc('seed_edition_dry_run', { p_params: { slug: 'zezao' } })
checar('dry-run preve 27 tipos e 2214 copias',
  Number(seco.card_types) === 27 && Number(seco.card_copies) === 2214)
const { count: chars } = await c.from('characters').select('id', { count: 'exact', head: true })
checar('dry-run nao escreveu nada', chars === 3, `${chars} personagens`)

const { data: logs } = await c.from('admin_log').select('*')
checar('admin le o admin_log', Array.isArray(logs), `${logs?.length} linhas`)

// ================================================================ limpeza
console.log('\nlimpando...')
// LIMPEZA: escopo restrito aos usuarios de teste.
//
// A versao anterior fazia delete().neq('id', 0) em copy_history,
// pack_openings e admin_log - ou seja, GLOBAL. Isso apaga o historico de
// jogadores de verdade. Script de teste nao pode encostar em dado real.
await c.rpc('admin_reset_player_collection', { p_nickname: NICK })
const { data: aberturas } = await admin.from('pack_openings').select('id').eq('player_id', pl.id)
const idsAbertura = (aberturas ?? []).map((a) => a.id)
if (idsAbertura.length) await admin.from('pack_opening_cards').delete().in('opening_id', idsAbertura)
await admin.from('pack_openings').delete().eq('player_id', pl.id)
await admin.from('copy_history').delete().eq('to_player', pl.id)
await admin.from('copy_history').delete().eq('from_player', pl.id)
await admin.from('admin_log').delete().eq('admin_id', pl.id)
await admin.from('album_colagem').delete().eq('player_id', pl.id)

// ESTREIAS. Antes de apagar a cobaia.
//
// open_pack grava first_discovered_at/by na copia e o FK de
// first_discovered_by e `on delete set null`: apagar a cobaia deixaria a
// copia marcada como DESCOBERTA sem descobridor - estreia fantasma, que
// rouba do grupo a chance de fazer a primeira.
{
  const { data, error } = await admin.from('card_copies')
    .update({ first_discovered_at: null, first_discovered_by: null })
    .eq('first_discovered_by', pl.id)
    .select('id')
  if (error) console.log('  ! falhou limpar estreias:', error.message)
  else if (data?.length) console.log(`  estreias de teste desfeitas: ${data.length}`)
}

await c.auth.signOut()
await admin.from('players').delete().eq('id', pl.id)
await admin.auth.admin.deleteUser(pl.id)

const { count: sobrou } = await admin.from('card_copies')
  .select('id', { count: 'exact', head: true }).eq('owner_id', pl.id)
checar('a cobaia nao deixou nenhuma copia para tras', sobrou === 0, `${sobrou}`)
const { count: agora } = await admin.from('card_copies')
  .select('id', { count: 'exact', head: true }).not('owner_id', 'is', null)
checar('o acervo dos jogadores REAIS ficou intacto', agora === comDonoAntes,
  `${comDonoAntes} antes, ${agora} depois`)
const { count: fantasmas } = await admin.from('card_copies')
  .select('id', { count: 'exact', head: true })
  .not('first_discovered_at', 'is', null).is('first_discovered_by', null)
checar('nenhuma estreia fantasma ficou para tras', fantasmas === 0,
  `${fantasmas} copias descobertas por ninguem`)

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
process.exit(falhas === 0 ? 0 : 1)
