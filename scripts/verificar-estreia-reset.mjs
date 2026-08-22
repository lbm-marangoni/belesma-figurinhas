// Estreia mundial e do TIPO, trofeus do mundo, e o reset que reseta mesmo.
//
//   node scripts/verificar-estreia-reset.mjs

import { PGlite } from '@electric-sql/pglite'
import { citext } from '@electric-sql/pglite/contrib/citext'
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const migracoes = join(raiz, 'supabase', 'migrations')
const db = await PGlite.create({ extensions: { citext, pgcrypto } })

await db.exec(`
  create role anon nologin; create role authenticated nologin;
  create role service_role nologin bypassrls;
  grant usage on schema public to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables    to anon, authenticated;
  alter default privileges in schema public grant all on sequences to anon, authenticated;
  create schema auth;
  create table auth.users (id uuid primary key, email text, encrypted_password text, updated_at timestamptz);
  create or replace function auth.uid() returns uuid language sql stable as $fn$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
  $fn$;
  grant usage on schema auth to anon, authenticated;
`)
for (const f of readdirSync(migracoes).filter((x) => x.endsWith('.sql')).sort()) {
  await db.exec(readFileSync(join(migracoes, f), 'utf8'))
}

const um = async (s, p) => (await db.query(s, p)).rows[0]
let falhas = 0
const checar = (n, ok, d) => {
  console.log(`  ${ok ? 'PASS' : 'FALHA'}  ${n}${d ? ' -> ' + d : ''}`); if (!ok) falhas++
}
async function como(uid, sql, params) {
  await db.exec(`set session request.jwt.claim.sub = '${uid}'; set role authenticated;`)
  try { return (await db.query(sql, params)).rows[0] }
  finally { await db.exec('reset role;') }
}
async function deveFalhar(nome, uid, sql, params) {
  try { await como(uid, sql, params); checar(nome, false, 'PASSOU - furo') }
  catch (e) { checar(nome, true, String(e.message).split('\n')[0].slice(0, 62)) }
}

const A = '11111111-1111-1111-1111-111111111111'
const B = '22222222-2222-2222-2222-222222222222'
await db.exec(`insert into auth.users (id,email) values
  ('${A}','ana@belesma.local'), ('${B}','bia@belesma.local');`)
await como(A, `select public.claim_nickname('ana')`)
await como(B, `select public.claim_nickname('bia')`)

// ================================================================ estreia
console.log('\n== estreia mundial e do TIPO, nao da COPIA ==')

// um tipo comum qualquer, com muitas copias no pool
const tipo = await um(`
  select ct.id, count(*) as copias
  from card_types ct join card_copies cc on cc.card_type_id = ct.id
  where ct.tier = 'comum' and cc.owner_id is null and not cc.reserved_for_daily
  group by ct.id order by ct.id limit 1`)

// primeira copia: estreia de verdade
const c1 = await um(`select id from card_copies
  where card_type_id = $1 and owner_id is null and not reserved_for_daily limit 1`, [tipo.id])
await db.exec(`update card_copies set owner_id = '${A}', claimed_at = now(),
  first_discovered_at = now() - interval '3 days', first_discovered_by = '${A}'
  where id = ${c1.id};`)

// agora a MESMA pessoa puxa a segunda copia do MESMO tipo. Antes isso vinha
// marcado como estreia mundial, porque a copia era nova mesmo o tipo nao sendo.
const c2 = await um(`select id from card_copies
  where card_type_id = $1 and owner_id is null and not reserved_for_daily limit 1`, [tipo.id])
await db.exec(`update card_copies set owner_id = '${A}', claimed_at = now(),
  first_discovered_at = now(), first_discovered_by = '${A}' where id = ${c2.id};`)

const eEstreia = async (id) => (await um(`
  select cc.first_discovered_by = '${A}'
     and cc.first_discovered_at >= now() - interval '1 minute'
     and not exists (
       select 1 from card_copies anterior
       where anterior.card_type_id = cc.card_type_id and anterior.id <> cc.id
         and anterior.first_discovered_at is not null
         and anterior.first_discovered_at < cc.first_discovered_at) as e
  from card_copies cc where cc.id = $1`, [id])).e

checar('segunda copia do mesmo tipo NAO e estreia mundial', (await eEstreia(c2.id)) === false)

// e a formula ainda reconhece uma estreia de verdade
const outro = await um(`
  select ct.id from card_types ct
  where not exists (select 1 from card_copies cc
                    where cc.card_type_id = ct.id and cc.first_discovered_at is not null)
  limit 1`)
const c3 = await um(`select id from card_copies
  where card_type_id = $1 and owner_id is null limit 1`, [outro.id])
await db.exec(`update card_copies set owner_id = '${A}', claimed_at = now(),
  first_discovered_at = now(), first_discovered_by = '${A}' where id = ${c3.id};`)
checar('primeira copia de um tipo virgem AINDA e estreia mundial', (await eEstreia(c3.id)) === true)

// o caminho real: abrir pacotes ate repetir e conferir o que open_pack devolve
await db.exec(`update players set packs_common = 40 where id = '${A}';`)
const vistos = new Set()
let repetidasComEstreia = 0, repetidas = 0
for (let i = 0; i < 40; i++) {
  const r = (await como(A, `select public.open_pack('comum') as r`)).r
  for (const c of r.cartas) {
    if (vistos.has(c.card_type_id)) {
      repetidas++
      if (c.estreia_mundial) repetidasComEstreia++
    }
    vistos.add(c.card_type_id)
  }
}
checar('em 40 pacotes, nenhuma repetida veio marcada como estreia',
  repetidasComEstreia === 0, `${repetidas} repetidas, ${repetidasComEstreia} marcadas`)

// ================================================================ trofeus
console.log('\n== trofeus do mundo ==')
const t = (await um(`select public.trofeus_do_mundo() as t`)).t
checar('trofeus_do_mundo devolve os tres campos',
  'joia' in t && 'menor_serial' in t && 'melhor_selo' in t)
checar('a joia do mundo tem dono', t.joia?.dono != null, t.joia?.dono)
checar('a joia do mundo bate com a melhor de algum jogador', await (async () => {
  const r = (await um(`select public.ranking_serial() as r`)).r
  return r.some((p) => p.joia?.copy_id === t.joia?.copy_id)
})())
checar('em_jogo bate com as copias com dono', Number(t.em_jogo) ===
  Number((await um(`select count(*) as n from card_copies where owner_id is not null and not burned`)).n),
  `${t.em_jogo}`)

// ================================================================ reset
console.log('\n== recomecar do zero ==')
// deixa o mundo bem sujo antes
await db.exec(`update players set baba = 900, packs_common = 3, pity_counter = 7,
  dailies_claimed = 4, last_daily_at = now() where id = '${A}';`)
await db.exec(`update card_copies set damage_level = 2 where owner_id = '${A}';`)
const sujo = await um(`select
  (select count(*) from card_copies where owner_id is not null) as com_dono,
  (select count(*) from card_copies where first_discovered_at is not null) as estreadas,
  (select count(*) from pack_openings) as aberturas,
  (select count(*) from copy_history) as historico`)
console.log(`   antes: ${sujo.com_dono} com dono, ${sujo.estreadas} estreadas, ` +
            `${sujo.aberturas} aberturas, ${sujo.historico} no historico`)

await deveFalhar('reset exige ser admin', B,
  `select public.admin_recomecar_do_zero('RECOMECAR DO ZERO')`)
await db.exec(`update players set is_admin = true where id = '${A}';`)
await deveFalhar('reset exige a frase exata', A,
  `select public.admin_recomecar_do_zero('resetar')`)

const res = (await como(A, `select public.admin_recomecar_do_zero('RECOMECAR DO ZERO') as r`)).r
console.log(`   devolveu: ${JSON.stringify(res)}`)

const dep = await um(`select
  (select count(*) from card_copies where owner_id is not null)             as com_dono,
  (select count(*) from card_copies where first_discovered_at is not null)  as estreadas,
  (select count(*) from card_copies where damage_level > 0)                 as estragadas,
  (select count(*) from card_copies where burned)                           as queimadas,
  (select count(*) from card_copies where origin = 'forge')                 as forjadas,
  (select count(*) from card_copies where reserved_for_daily)               as reservadas,
  (select count(*) from pack_openings)                                      as aberturas,
  (select count(*) from pack_opening_cards)                                 as auditoria,
  (select count(*) from copy_history)                                       as historico,
  (select count(*) from baba_log)                                           as extrato,
  (select count(*) from album_colagem)                                      as coladas,
  (select count(*) from trades)                                             as trocas,
  (select sum(baba) from players)                                           as baba,
  (select sum(pity_counter + dailies_claimed) from players)                 as contadores,
  (select count(*) from players where last_daily_at is not null)            as com_daily,
  (select sum(packs_common) from players)                                   as comuns,
  (select sum(packs_rare) from players)                                     as raros,
  (select sum(packs_ultra) from players)                                    as ultras,
  (select sum(packs_common_daily + packs_rare_daily + packs_ultra_daily) from players) as diarios,
  (select count(*) from players)                                            as jogadores,
  (select count(*) from card_copies)                                        as total_copias,
  (select count(*) from card_copies where seal <> 'none')                   as selos`)

checar('nenhuma copia com dono',          Number(dep.com_dono) === 0, `${dep.com_dono}`)
checar('nenhuma estreia mundial de pe',   Number(dep.estreadas) === 0, `${dep.estreadas}`)
checar('nenhum desgaste sobrou',          Number(dep.estragadas) === 0, `${dep.estragadas}`)
checar('nenhuma copia queimada',          Number(dep.queimadas) === 0, `${dep.queimadas}`)
checar('nenhuma forjada sobrou',          Number(dep.forjadas) === 0, `${dep.forjadas}`)
checar('aberturas apagadas',              Number(dep.aberturas) === 0, `${dep.aberturas}`)
checar('auditoria de pacote apagada',     Number(dep.auditoria) === 0, `${dep.auditoria}`)
checar('historico apagado',               Number(dep.historico) === 0, `${dep.historico}`)
checar('extrato de baba apagado',         Number(dep.extrato) === 0, `${dep.extrato}`)
checar('album descolado',                 Number(dep.coladas) === 0, `${dep.coladas}`)
checar('trocas apagadas',                 Number(dep.trocas) === 0, `${dep.trocas}`)
checar('baba zerada',                     Number(dep.baba) === 0, `${dep.baba}`)
checar('pity e streak zerados',           Number(dep.contadores) === 0, `${dep.contadores}`)
checar('cooldown do diario liberado',     Number(dep.com_daily) === 0, `${dep.com_daily}`)

const j = Number(dep.jogadores)
checar('BOOSTER de volta ao allotment inicial',
  Number(dep.comuns) === 12 * j && Number(dep.raros) === 5 * j && Number(dep.ultras) === 2 * j,
  `${dep.comuns}/${dep.raros}/${dep.ultras} para ${j} jogadores (esperado ${12*j}/${5*j}/${2*j})`)
checar('nenhum pacote diario pendente',   Number(dep.diarios) === 0, `${dep.diarios}`)
checar('reserva diaria refeita',          Number(dep.reservadas) === 1500, `${dep.reservadas}`)

// o mundo nao encolheu nem perdeu os selos
checar('o acervo do mundo continua 6642', Number(dep.total_copias) === 6642, `${dep.total_copias}`)
checar('os selos continuam 36/12/3 (51 no total)', Number(dep.selos) === 51, `${dep.selos}`)

// e o reset fica registrado
const log = await um(`select count(*) as n from admin_log where acao = 'admin_recomecar_do_zero'`)
checar('o reset ficou gravado no admin_log', Number(log.n) === 1, `${log.n}`)

// depois do reset da para jogar de novo
await db.exec(`update players set is_admin = false where id = '${A}';`)
const novo = (await como(A, `select public.open_pack('comum') as r`)).r
checar('da para abrir pacote logo depois do reset', novo.cartas.length >= 4,
  `${novo.cartas.length} cartas`)
checar('e a primeira carta depois do reset volta a ser estreia',
  novo.cartas.some((c) => c.estreia_mundial))

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
await db.close()
process.exit(falhas === 0 ? 0 : 1)
