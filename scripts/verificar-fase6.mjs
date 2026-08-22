// Verificacao da Fase 6: forja, moeda BABA, loja, verificacao publica e a
// auditoria de ciclos que a spec §19.7 exige.

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
console.log('migracoes aplicadas')

const um = async (s, p) => (await db.query(s, p)).rows[0]
const tudo = async (s, p) => (await db.query(s, p)).rows
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
  catch (e) { checar(nome, true, String(e.message).split('\n')[0].slice(0, 66)) }
}

const A = '11111111-1111-1111-1111-111111111111'
const B = '22222222-2222-2222-2222-222222222222'
await db.exec(`insert into auth.users (id,email) values
  ('${A}','ana@belesma.local'),('${B}','bob@belesma.local');`)
await como(A, `select public.claim_nickname('ana')`)
await como(B, `select public.claim_nickname('bob')`)

const dar = async (uid, tier, n, offset = 0) => (await tudo(`
  update card_copies set owner_id = $1, claimed_at = now()
  where id in (select cc.id from card_copies cc join card_types ct on ct.id = cc.card_type_id
               where ct.tier = $2 and cc.owner_id is null order by cc.id offset $4 limit $3)
  returning id`, [uid, tier, n, offset])).map((r) => r.id)

// ================================================================ forja
console.log('\n== forja (spec §7) ==')
const cincoRaras = await dar(A, 'rara', 5)
await deveFalhar('forja recusa numero diferente de 5', A,
  `select public.forge($1)`, [cincoRaras.slice(0, 4)])

const misturado = [...(await dar(A, 'comum', 4, 0)), cincoRaras[0]]
await deveFalhar('forja recusa tiers misturados', A, `select public.forge($1)`, [misturado])

const doBob = await dar(B, 'rara', 5, 50)
await deveFalhar('forja recusa copia alheia', A, `select public.forge($1)`, [doBob])

const f = (await como(A, `select public.forge($1) as r`, [cincoRaras])).r
checar('forja devolve uma do tier acima', f.tier === 'epica', f.tier)
checar('forja marca forge_index', f.forge_index === 1, `${f.forge_index}`)

const nova = await um(`select origin, serial_number, forge_index, seal, burned
                       from card_copies where id = $1`, [f.copy_id])
checar('a forjada tem origin=forge', nova.origin === 'forge')
checar('a forjada NAO consome serial da tiragem', nova.serial_number === null,
  `serial=${nova.serial_number}`)
checar('a forjada nunca recebe selo', nova.seal === 'none')

const queimadas = await um(`select count(*) as n from card_copies
  where id = any($1) and burned and owner_id is null`, [cincoRaras])
checar('as 5 foram queimadas e nao voltaram ao pool', Number(queimadas.n) === 5, `${queimadas.n}`)
const noPool = await um(`select count(*) as n from card_copies
  where id = any($1) and owner_id is null and not burned`, [cincoRaras])
checar('as 5 saíram do pool de sorteio de vez', Number(noPool.n) === 0, `${noPool.n}`)

// teto: nao forja acima de mitica
const cincoMiticas = await dar(A, 'mitica', 5)
await deveFalhar('forja acima de mitica e bloqueada', A,
  `select public.forge($1)`, [cincoMiticas])

// copia em troca aberta nao queima
const cincoEpicas = await dar(A, 'epica', 5)
const alvoBob = (await dar(B, 'comum', 1, 200))[0]
await como(A, `select public.propose_trade($1,0,$2,0)`, [cincoEpicas[0], alvoBob])
await deveFalhar('nao queima copia em proposta de troca aberta', A,
  `select public.forge($1)`, [cincoEpicas])

// ================================================================ vender
console.log('\n== vender (spec §19.4) ==')
const duasComuns = await dar(A, 'comum', 2, 300)
const mesmoTipo = await um(`select card_type_id from card_copies where id = $1`, [duasComuns[0]])
// garante duas do MESMO tipo
await db.exec(`update card_copies set owner_id = '${A}', claimed_at = now()
  where id = (select id from card_copies where card_type_id = ${mesmoTipo.card_type_id}
              and owner_id is null limit 1);`)
const doTipo = (await tudo(`select id from card_copies
  where owner_id = $1 and card_type_id = $2 order by id`, [A, mesmoTipo.card_type_id])).map((r) => r.id)

const saldo0 = (await um(`select baba from players where id = $1`, [A])).baba
const v = (await como(A, `select public.vender($1) as r`, [doTipo[0]])).r
checar('venda paga o valor do tier', Number(v.valor) === 5, `${v.valor}`)
checar('o saldo subiu', v.saldo === saldo0 + 5, `${saldo0} -> ${v.saldo}`)
const vendida = await um(`select owner_id, damage_level, burned from card_copies where id = $1`, [doTipo[0]])
checar('a vendida volta ao pool, nao e queimada',
  vendida.owner_id === null && vendida.burned === false)
checar('a vendida ganha desgaste +1', vendida.damage_level === 1, `${vendida.damage_level}`)
checar('o extrato registrou a venda',
  Number((await um(`select count(*) as n from baba_log where player_id=$1 and motivo='venda'`, [A])).n) === 1)

// vende ate sobrar UMA: o fixture pode ter dado mais de duas do mesmo tipo,
// e a regra so morde na ultima
let restantes = (await tudo(`select id from card_copies
  where owner_id = $1 and card_type_id = $2 and not burned order by id`,
  [A, mesmoTipo.card_type_id])).map((x) => x.id)
while (restantes.length > 1) {
  await como(A, `select public.vender($1)`, [restantes[0]])
  restantes = restantes.slice(1)
}
await deveFalhar('nao vende a ultima copia do tipo', A,
  `select public.vender($1)`, [restantes[0]])

// selada e prisma nao vendem
const selada = await um(`select cc.id from card_copies cc where cc.seal <> 'none' and cc.owner_id is null limit 1`)
await db.exec(`update card_copies set owner_id = '${A}' where id = ${selada.id};`)
await db.exec(`update card_copies set owner_id = '${A}' where id in (
  select id from card_copies where card_type_id =
    (select card_type_id from card_copies where id = ${selada.id}) and owner_id is null limit 1);`)
// A selada passou a ser VENDAVEL com premio: 36 brancos, 12 pretos e 3
// rosas no mundo, entao raridade vira preco. A prisma segue invendavel.
const infoSelo = await um(`select cc.seal::text, ct.tier from card_copies cc
  join card_types ct on ct.id = cc.card_type_id where cc.id = $1`, [selada.id])
const mult = Number((await um(
  `select valor from economy_config where chave = 'multiplicador_selo_' || $1`, [infoSelo.seal])).valor)
const baseSelo = Number((await um(
  `select valor from economy_config where chave = 'venda_' || $1`, [infoSelo.tier])).valor)
const vs = (await como(A, `select public.vender($1) as r`, [selada.id])).r
checar('selada vende com premio do selo',
  Number(vs.valor) === Math.floor(baseSelo * mult),
  `${infoSelo.seal} em ${infoSelo.tier}: ${vs.valor} = ${baseSelo} x ${mult}`)
checar('o selo continua na copia depois da venda',
  (await um(`select seal::text from card_copies where id=$1`, [selada.id])).seal === infoSelo.seal)

const prismas = await tudo(`select cc.id from card_copies cc join card_types ct on ct.id=cc.card_type_id
  where ct.tier='prisma' and cc.owner_id is null limit 2`)
await db.exec(`update card_copies set owner_id = '${A}' where id in (${prismas.map(p=>p.id).join(',')});`)
await deveFalhar('prisma nao se vende (flag vendavel)', A,
  `select public.vender($1)`, [prismas[0].id])

// forjada vendida e QUEIMADA
const outraForja = await dar(A, 'lendaria', 5)
const f2 = (await como(A, `select public.forge($1) as r`, [outraForja])).r
await db.exec(`update card_copies set owner_id = '${A}' where id in (
  select id from card_copies where card_type_id = ${f2.card_type_id} and owner_id is null limit 1);`)
const vf = (await como(A, `select public.vender($1) as r`, [f2.copy_id])).r
checar('forjada vale 40% do tier', Number(vf.valor) === Math.floor(300 * 0.4), `${vf.valor}`)
checar('forjada vendida e QUEIMADA, nao volta ao pool', vf.queimada === true)
checar('...e some do pool de sorteio',
  (await um(`select burned, owner_id from card_copies where id=$1`, [f2.copy_id])).burned === true)

// ================================================================ restaurar
console.log('\n== restaurar (spec §19.2) ==')
await db.exec(`update players set baba = 10000 where id = '${A}';`)
await db.exec(`update card_copies set owner_id='${A}', damage_level=2 where id=${doTipo[0]};`)
const r = (await como(A, `select public.restaurar($1) as r`, [doTipo[0]])).r
checar('restauro nivel 2 custa 3x o valor do tier', Number(r.custo) === 15, `${r.custo}`)
checar('o desgaste foi a zero',
  (await um(`select damage_level from card_copies where id=$1`, [doTipo[0]])).damage_level === 0)
await deveFalhar('nao restaura o que nao esta estragado', A,
  `select public.restaurar($1)`, [doTipo[0]])

// ================================================================ loja
console.log('\n== loja (spec §19.5) ==')
const antesPac = await um(`select packs_common, baba from players where id=$1`, [A])
const compra = (await como(A, `select public.comprar_pacote('comum', null) as r`)).r
checar('compra debita o preco', Number(compra.preco) === 120, `${compra.preco}`)
checar('compra credita o pacote',
  (await um(`select packs_common from players where id=$1`, [A])).packs_common === antesPac.packs_common + 1)
checar('o saldo caiu certinho', compra.saldo === antesPac.baba - 120, `${compra.saldo}`)

const dirigido = (await como(A, `select public.comprar_pacote('comum', 1) as r`)).r
checar('pacote dirigido custa o dobro', Number(dirigido.preco) === 240, `${dirigido.preco}`)

await como(A, `select public.comprar_pacote('comum', null)`)
await deveFalhar('teto de 3 compras por dia', A, `select public.comprar_pacote('comum', null)`)

await db.exec(`update players set baba = 10 where id = '${B}';`)
await deveFalhar('sem saldo nao compra', B, `select public.comprar_pacote('ultra', null)`)

// ================================================================ verify_copy
console.log('\n== /v/<codigo> (spec §14) ==')
const cod = await um(`select verify_code from card_copies where owner_id = $1 limit 1`, [A])
await db.exec(`set role anon;`)
const pub = (await db.query(`select public.verify_copy($1) as r`, [cod.verify_code])).rows[0].r
await db.exec(`reset role;`)
checar('verify_copy e publica (anon le)', !!pub)
checar('mostra o dono atual', pub.dono === 'ana', pub.dono)
checar('traz serial e tiragem', pub.print_run > 0)
const vazio = (await um(`select public.verify_copy('NAOEXISTE1') as r`)).r
checar('codigo inexistente devolve nada', vazio === null || vazio === undefined, JSON.stringify(vazio))

// ================================================================ §19.7
console.log('\n== auditoria de ciclos (spec §19.7) ==')
const p = Object.fromEntries((await tudo(`select chave, valor from economy_config`))
  .map((x) => [x.chave, Number(x.valor)]))
const tiersHit = await tudo(`select pack_type::text tipo, tier, weight from pack_config where slot='hit'`)
const base = 0.625 * p.venda_comum + 0.375 * p.venda_incomum

const evPacote = (tipo) => {
  const hit = tiersHit.filter((t) => t.tipo === tipo)
    .reduce((a, t) => a + (Number(t.weight) / 100) * (p['venda_' + t.tier] ?? 0), 0)
  const promo = 3 * 0.04 * (hit - base)
  const quente = 0.015 * 3 * (hit - base)
  return 3 * base + hit + promo + quente + 0.08 * base
}
for (const [tipo, preco] of [['comum', p.compra_comum], ['raro', p.compra_raro], ['ultra', p.compra_ultra]]) {
  const ev = evPacote(tipo)
  console.log(`    ${tipo.padEnd(6)} valor esperado ${ev.toFixed(1)} vs preco ${preco}`)
  checar(`comprar ${tipo} e vender tudo da prejuizo`, ev < preco, `${ev.toFixed(1)} < ${preco}`)
}
for (const n of [1, 2, 3]) {
  const ganho = 1 - p.multiplicador_estragada          // 0,6 x V
  const custo = p['restauro_mult_' + n]
  checar(`restaurar nivel ${n} e vender da prejuizo`, ganho < custo,
    `ganha ${ganho}·V, custa ${custo}·V`)
}
const ordem = Object.fromEntries((await tudo(`select slug, tier_order from tiers`)).map((t) => [t.slug, t.tier_order]))
for (const t of ['comum', 'incomum', 'rara', 'epica', 'lendaria']) {
  const acima = Object.keys(ordem).find((k) => ordem[k] === ordem[t] + 1)
  const gasta = 5 * p['venda_' + t]
  const ganha = (p['venda_' + acima] ?? 0) * p.multiplicador_forjada
  checar(`forjar 5 ${t} e vender da prejuizo`, ganha < gasta, `${ganha} < ${gasta}`)
}

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
await db.close()
process.exit(falhas === 0 ? 0 : 1)
