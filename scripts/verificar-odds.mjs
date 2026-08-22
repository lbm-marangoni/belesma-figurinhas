// As odds fazem efeito REAL? Amostra grande e qui-quadrado.
//
// Os testes das fases olham centenas de pacotes com tolerância folgada. Este
// abre milhares e cobra a tabela de verdade: se a distribuição observada não
// puder ter saído de pack_config, ele reprova.
//
//   node scripts/verificar-odds.mjs [nPacotes]

import { PGlite } from '@electric-sql/pglite'
import { citext } from '@electric-sql/pglite/contrib/citext'
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const N = Number(process.argv[2] ?? 4000)
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
const tudo = async (s, p) => (await db.query(s, p)).rows
let falhas = 0
const checar = (n, ok, d) => {
  console.log(`  ${ok ? 'PASS' : 'FALHA'}  ${n}${d ? ' -> ' + d : ''}`); if (!ok) falhas++
}

const U = '11111111-1111-1111-1111-111111111111'
await db.exec(`insert into auth.users (id,email) values ('${U}','ana@belesma.local');`)
await db.exec(`set session request.jwt.claim.sub = '${U}'; set role authenticated;`)
await db.query(`select public.claim_nickname('ana')`)
await db.exec(`reset role;`)
await db.exec(`update players set is_admin = true where id = '${U}';`)

// O pool do set inteiro é 6642. Abrir milhares de pacotes esgota tiers e a
// cascata distorce a amostra de propósito. Para medir as ODDS e não a
// cascata, o estoque é reposto a cada lote.
const repor = () => db.exec(`
  update card_copies set owner_id = null, claimed_at = null where owner_id is not null;
  delete from pack_opening_cards; delete from pack_openings; delete from copy_history;`)

const chi2 = (obs, esp) => obs.reduce((a, o, i) => a + (esp[i] > 0 ? (o - esp[i]) ** 2 / esp[i] : 0), 0)
// valor crítico de 99,9% por graus de liberdade (tabela)
const CRITICO = { 1: 10.83, 2: 13.82, 3: 16.27, 4: 18.47, 5: 20.52, 6: 22.46,
                  7: 24.32, 8: 26.12, 9: 27.88, 10: 29.59 }

console.log(`abrindo ${N} pacotes de cada tipo...\n`)

const params = Object.fromEntries((await tudo(`select chave, valor from pack_params`))
  .map((r) => [r.chave, Number(r.valor)]))
const ordem = Object.fromEntries((await tudo(`select slug, tier_order from tiers`))
  .map((r) => [r.slug, Number(r.tier_order)]))

// Quantos pacotes cabem antes de repor. O pool do slot de hit do Ultra é
// mitica+cosmica+divina+infernal+aura = 213 cópias no mundo INTEIRO; repor a
// cada 600 pacotes mede a cascata, não a tabela. O lote sai do estoque real.
const lote = async (tipo) => {
  const r = await um(
    `select count(*) as n from card_copies cc
     join card_types ct on ct.id = cc.card_type_id
     where ct.tier in (select tier from pack_config
                       where pack_type = $1 and slot = 'hit' and weight > 0)`, [tipo])
  return Math.max(20, Math.floor(Number(r.n) / 4))   // folga p/ quente e promoção
}

for (const tipo of ['comum', 'raro', 'ultra']) {
  await repor()
  const LOTE = await lote(tipo)
  console.log(`   (repondo estoque a cada ${LOTE} pacotes de ${tipo})`)
  await db.exec(`update players set packs_common = ${N}, packs_rare = ${N}, packs_ultra = ${N},
                                    pity_counter = 0 where id = '${U}';`)

  const hitNatural = {}, base = {}
  let quentes = 0, bonus = 0, promovidos = 0, slotsBase = 0, cartas = 0, pity = 0
  let tamanho4 = 0, tamanho5 = 0, outros = 0
  let quebrouGarantia = 0, menores = 0
  const piso = tipo === 'raro' ? 4 : tipo === 'ultra' ? 6 : 1

  for (let i = 0; i < N; i++) {
    if (i % LOTE === LOTE - 1) await repor()   // repõe antes de a cascata pesar
    await db.exec(`set session request.jwt.claim.sub = '${U}'; set role authenticated;`)
    const r = (await db.query(`select public.open_pack($1) as r`, [tipo])).rows[0].r
    await db.exec(`reset role;`)

    cartas += r.cartas.length
    if (r.quente) quentes++
    if (r.bonus) bonus++
    if (r.pity) pity++
    promovidos += r.promovidos
    if (r.cartas.length === 4) tamanho4++
    else if (r.cartas.length === 5) tamanho5++
    else outros++
    // menor que o esperado = a cascata bateu no piso e o pacote saiu curto,
    // que e o comportamento honesto. Nao e o mesmo que quebrar a garantia.
    if (r.cartas.length < r.esperado) menores++
    if (!r.cartas.some((c) => ordem[c.tier] >= piso)) quebrouGarantia++

    if (r.quente || r.pity) continue          // amostra suja para as odds
    for (const c of r.cartas) {
      if (c.from_hit_table && !c.garantido) hitNatural[c.tier] = (hitNatural[c.tier] ?? 0) + 1
      if (!c.from_hit_table) { base[c.tier] = (base[c.tier] ?? 0) + 1; slotsBase++ }
    }
  }

  console.log(`== ${tipo.toUpperCase()} · ${N} pacotes ==`)
  console.log(`   tamanho: ${tamanho4} com 4 cartas, ${tamanho5} com 5, ${outros} outros`)
  console.log(`   quente ${(100*quentes/N).toFixed(2)}% (tabela ${(params.pacote_quente*100).toFixed(2)}%)` +
              ` · bonus ${(100*bonus/N).toFixed(2)}% (tabela ${(params.carta_bonus*100).toFixed(2)}%)` +
              ` · promocao ${(100*promovidos/(N*3)).toFixed(2)}% (tabela ${(params.promocao_base*100).toFixed(2)}%)`)

  // ---------------------------------------------------------- slot de hit
  const tabela = await tudo(
    `select tier, weight from pack_config where pack_type = $1 and slot = 'hit' and weight > 0
     order by weight desc`, [tipo])
  const totalHit = Object.values(hitNatural).reduce((a, b) => a + b, 0)
  const obs = [], esp = [], linhas = []
  for (const t of tabela) {
    const o = hitNatural[t.tier] ?? 0
    const e = totalHit * Number(t.weight) / 100
    obs.push(o); esp.push(e)
    linhas.push(`     ${t.tier.padEnd(9)} obs ${(100*o/totalHit).toFixed(2).padStart(6)}%` +
                `  tabela ${Number(t.weight).toFixed(2).padStart(6)}%  (n=${o})`)
  }
  console.log(`   slot de hit, ${totalHit} amostras:`)
  linhas.forEach((l) => console.log(l))

  // agrupa as caudas raras: qui-quadrado exige esperado >= 5 por celula
  const grossas = esp.map((e, i) => [e, obs[i]]).filter(([e]) => e >= 5)
  const restoEsp = esp.filter((e) => e < 5).reduce((a, b) => a + b, 0)
  const restoObs = esp.map((e, i) => (e < 5 ? obs[i] : 0)).reduce((a, b) => a + b, 0)
  const eFinal = grossas.map(([e]) => e), oFinal = grossas.map(([, o]) => o)
  if (restoEsp > 0) { eFinal.push(restoEsp); oFinal.push(restoObs) }

  const gl = eFinal.length - 1
  const x2 = chi2(oFinal, eFinal)
  const limite = CRITICO[gl] ?? 30
  console.log(`   qui-quadrado ${x2.toFixed(2)} com ${gl} gl (limite 99,9% = ${limite})`)
  checar(`${tipo}: o slot de hit segue pack_config`, x2 < limite, `X²=${x2.toFixed(2)}`)

  // ---------------------------------------------------------- slot base
  const pctComum = 100 * (base.comum ?? 0) / slotsBase
  console.log(`   slot base: comum ${pctComum.toFixed(2)}% / incomum ` +
              `${(100*(base.incomum ?? 0)/slotsBase).toFixed(2)}%  (tabela 62,50 / 37,50)`)
  checar(`${tipo}: o slot base segue 62,5/37,5`, Math.abs(pctComum - 62.5) < 3,
    `${pctComum.toFixed(2)}%`)

  // ---------------------------------------------------------- garantias
  checar(`${tipo}: garantia do pacote cumprida em TODOS`, quebrouGarantia === 0,
    `${quebrouGarantia} de ${N} falharam`)
  console.log(`   ${menores} pacotes sairam curtos (estoque no piso da garantia)`)

  // ---------------------------------------------------------- regra dura
  const duro = await um(`select count(*) as n from pack_opening_cards
                         where garantido and tier in ('diamante','prisma')`)
  checar(`${tipo}: diamante/prisma nunca em slot garantido`, Number(duro.n) === 0, `${duro.n}`)

  // taxas de variancia, a 4 sigma
  const sig = (n, p) => Math.sqrt(n * p * (1 - p)) / n
  checar(`${tipo}: taxa de pacote quente bate`,
    Math.abs(quentes / N - params.pacote_quente) <= 4 * sig(N, params.pacote_quente),
    `${(100*quentes/N).toFixed(2)}%`)
  checar(`${tipo}: taxa de carta bonus bate`,
    Math.abs(bonus / N - params.carta_bonus) <= 4 * sig(N, params.carta_bonus),
    `${(100*bonus/N).toFixed(2)}%`)
  checar(`${tipo}: taxa de promocao bate`,
    Math.abs(promovidos / (N * 3) - params.promocao_base) <= 4 * sig(N * 3, params.promocao_base),
    `${(100*promovidos/(N*3)).toFixed(2)}%`)
  checar(`${tipo}: 5 cartas acontece e bate com a taxa de bonus`,
    Math.abs(tamanho5 / N - params.carta_bonus) <= 4 * sig(N, params.carta_bonus) && outros === 0,
    `${tamanho5} pacotes de 5, ${outros} fora de 4/5`)
  console.log('')
}

// ============================================================ estoque seco
// Guarda-regressao do bug da cascata: quando a tabela de hit inteira fica sem
// estoque, o fallback antigo sorteava de QUALQUER tier - inclusive comum - e
// um pacote Ultra entregava comum no slot de hit. Medido: 120 de 1500.
//
// O certo e o pacote sair CURTO. Aqui o estoque alto e secado de proposito e
// nenhuma das duas coisas pode acontecer: nem mentir, nem estourar.
console.log('== estoque seco: a cascata respeita o piso da garantia ==')
await repor()
await db.exec(`
  update card_copies set owner_id = '${U}', claimed_at = now()
  where card_type_id in (select id from card_types where tier_order >= 6);
  update players set packs_ultra = 400, pity_counter = 0 where id = '${U}';`)

let secoQuebrou = 0, secoCurto = 0, secoOk = 0, secoEstourou = 0, secoVazio = 0
for (let i = 0; i < 400; i++) {
  await db.exec(`set session request.jwt.claim.sub = '${U}'; set role authenticated;`)
  let r
  try { r = (await db.query(`select public.open_pack('ultra') as r`)).rows[0].r }
  catch { secoEstourou++; await db.exec(`reset role;`); continue }
  await db.exec(`reset role;`)
  if (r.cartas.length === 0) secoVazio++
  if (r.cartas.some((c) => ordem[c.tier] >= 6)) secoOk++
  else if (r.cartas.length < r.esperado) secoCurto++
  else secoQuebrou++
}
console.log(`   ${secoOk} honraram mesmo assim · ${secoCurto} sairam curtos · ` +
            `${secoQuebrou} mentiram · ${secoEstourou} estouraram`)
// Pacote quente transforma TODO slot em hit. Com o pool alto seco isso dava
// pacote de zero cartas e excecao. Quente e bonus: rebaixa para normal.
checar('estoque seco: nenhum pacote estoura nem sai vazio',
  secoEstourou === 0 && secoVazio === 0, `${secoEstourou} estouros, ${secoVazio} vazios`)
checar('estoque seco: nenhum pacote entrega abaixo do piso da garantia', secoQuebrou === 0,
  `${secoQuebrou} de 400`)
checar('estoque seco: o pacote sai curto em vez de mentir', secoCurto > 0, `${secoCurto} curtos`)
console.log('')

console.log(falhas === 0 ? 'TUDO PASSOU' : `${falhas} FALHA(S)`)
await db.close()
process.exit(falhas === 0 ? 0 : 1)
