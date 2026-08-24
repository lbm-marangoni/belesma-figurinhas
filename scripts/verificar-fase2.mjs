// Verificacao da Fase 2: login, open_pack com toda a variancia, e as RPCs
// administrativas. Roda no mesmo Postgres em WASM da Fase 1.
//
// O que ele NAO cobre: concorrencia real (PGlite tem uma conexao so). Isso
// esta em scripts/concorrencia-http.mjs, que roda contra o Supabase.

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
const checar = (nome, ok, det) => {
  console.log(`  ${ok ? 'PASS' : 'FALHA'}  ${nome}${det ? ' -> ' + det : ''}`)
  if (!ok) falhas++
}

// roda como o jogador dado, no papel authenticated
async function como(uid, sql, params) {
  await db.exec(`set session request.jwt.claim.sub = '${uid}'; set role authenticated;`)
  try { return (await db.query(sql, params)).rows[0] }
  finally { await db.exec('reset role;') }
}
async function deveFalhar(nome, uid, sql, params) {
  try { await como(uid, sql, params); checar(nome, false, 'PASSOU - furo') }
  catch (e) { checar(nome, true, String(e.message).split('\n')[0].slice(0, 70)) }
}

const UID = {
  ana:  '11111111-1111-1111-1111-111111111111',
  bob:  '22222222-2222-2222-2222-222222222222',
  chefe:'33333333-3333-3333-3333-333333333333',
}
await db.exec(`insert into auth.users (id, email) values
  ('${UID.ana}','ana@belesma.local'), ('${UID.bob}','bob@belesma.local'),
  ('${UID.chefe}','chefe@belesma.local');`)

// ================================================================ login
console.log('\n== claim_nickname (secao 10) ==')
const ana = await como(UID.ana, `select * from public.claim_nickname('ana')`)
checar('cria o jogador', ana.claim_nickname !== null)
const perfil = await um(`select * from public.players where id = $1`, [UID.ana])
const alot = await um(`select private.tem_pacotes($1,'comum') as comuns,
                              private.tem_pacotes($1,'raro')  as raros,
                              private.tem_pacotes($1,'ultra') as ultras`, [UID.ana])
checar('allotment inicial 12/5/2',
  Number(alot.comuns) === 12 && Number(alot.raros) === 5 && Number(alot.ultras) === 2,
  `${alot.comuns}/${alot.raros}/${alot.ultras}`)

await como(UID.ana, `select * from public.claim_nickname('ana')`)
const depois = await um(`select private.tem_pacotes($1,'comum') as packs_common`, [UID.ana])
checar('idempotente: nao dobra o allotment', depois.packs_common === 12, `${depois.packs_common}`)

await deveFalhar('recusa apelido que nao bate com a conta', UID.bob,
  `select public.claim_nickname('ana')`)
await deveFalhar('recusa apelido com formato invalido', UID.bob,
  `select public.claim_nickname('Bob!!')`)

await como(UID.bob, `select public.claim_nickname('bob')`)
await como(UID.chefe, `select public.claim_nickname('chefe')`)
await db.exec(`update public.players set is_admin = true where id = '${UID.chefe}';`)

// ================================================================ open_pack
console.log('\n== open_pack: um pacote ==')
const r1 = (await como(UID.ana, `select public.open_pack('comum') as r`)).r
checar('devolve 4 ou 5 cartas', r1.cartas.length === 4 || r1.cartas.length === 5, `${r1.cartas.length}`)
checar('sem card_type repetido no pacote',
  new Set(r1.cartas.map((c) => c.skin + '|' + c.character_slug)).size === r1.cartas.length)
checar('reveal_index e uma permutacao',
  JSON.stringify(r1.cartas.map((c) => c.reveal_index).sort((a, b) => a - b)) ===
  JSON.stringify([...Array(r1.cartas.length)].map((_, i) => i + 1)))
const donas = await um(`select count(*) as n from card_copies where id = any($1) and owner_id = $2`,
  [r1.cartas.map((c) => c.copy_id), UID.ana])
checar('todas as copias ficaram com o dono', Number(donas.n) === r1.cartas.length)
const aud = await um(`select count(*) as n from pack_opening_cards where opening_id = $1`, [r1.abertura])
checar('auditoria gravada', Number(aud.n) === r1.cartas.length)
checar('consumiu um pacote comum',
  Number((await um(`select private.tem_pacotes($1,'comum') as n`, [UID.ana])).n) === 11)

// ================================================================ em volume
console.log('\n== open_pack: 450 pacotes ==')
await como(UID.chefe, `select public.grant_packs('ana','comum',300)`)
await como(UID.chefe, `select public.grant_packs('ana','raro',100)`)
await como(UID.chefe, `select public.grant_packs('ana','ultra',50)`)

const est = { comum: 0, raro: 0, ultra: 0 }
const tiersHit = {}
let quentes = 0, bonus = 0, promovidos = 0, cartas = 0
// A spec §8 permite repetir card_type SO quando o tier nao tem tipos
// distintos suficientes para os slots sorteados dele. Ex.: pacote quente
// sorteia 4 slots de mitica, e mitica tem 3 tipos (um por personagem).
let repetidoIlegal = 0, repetidoLegitimo = 0
const repeticoes = []
let raroAbaixo = 0, ultraAbaixo = 0, duroEmGarantido = 0

const ordem = Object.fromEntries((await tudo(`select slug, tier_order from tiers`))
  .map((t) => [t.slug, Number(t.tier_order)]))

for (const [tipo, n] of [['comum', 300], ['raro', 100], ['ultra', 50]]) {
  for (let i = 0; i < n; i++) {
    const r = (await como(UID.ana, `select public.open_pack($1) as r`, [tipo])).r
    est[tipo]++
    cartas += r.cartas.length
    if (r.quente) quentes++
    if (r.bonus) bonus++
    promovidos += r.promovidos
    const chaves = r.cartas.map((c) => c.skin + '|' + c.character_slug)
    if (new Set(chaves).size !== chaves.length) {
      const porTier = {}
      for (const c of r.cartas) porTier[c.tier] = (porTier[c.tier] ?? 0) + 1
      repeticoes.push(porTier)
    }

    const hit = r.cartas.filter((c) => c.from_hit_table)
    const melhor = Math.max(...r.cartas.map((c) => ordem[c.tier]))
    if (tipo === 'raro' && melhor < ordem.epica) raroAbaixo++
    if (tipo === 'ultra' && melhor < ordem.mitica) ultraAbaixo++

    // Regra dura, conferida por CARTA e nao por pacote: um Comum com
    // promocao pode legitimamente trazer um diamante no slot de hit
    // NATURAL. O que a spec proibe e diamante/prisma em slot GARANTIDO.
    for (const c of r.cartas) {
      if (c.garantido && (c.tier === 'diamante' || c.tier === 'prisma')) duroEmGarantido++
    }
    // distribuicao so do pacote comum sem promocao/quente, para nao poluir
    if (tipo === 'comum' && !r.quente && r.promovidos === 0 && !r.pity && hit.length === 1) {
      tiersHit[hit[0].tier] = (tiersHit[hit[0].tier] ?? 0) + 1
    }
  }
}

// A spec §8 permite repetir card_type SO quando o tier nao tem tipos
// distintos suficientes para os slots sorteados dele.
//
// "Suficientes" e por tipos COM ESTOQUE, nao por tipos que existem: se uma
// skin de mitica esgotou, sobram 2 tipos para 3 slots e a repeticao vira
// forcada. Comparar com o total de tipos dava falso positivo raro - foi o que
// fez este teste piscar em 1 de cada 20 execucoes.
const comEstoque = Object.fromEntries((await tudo(`
  select ct.tier, count(distinct ct.id) as n
  from card_types ct join card_copies cc on cc.card_type_id = ct.id
  where cc.owner_id is null and not cc.burned
  group by ct.tier`)).map((r) => [r.tier, Number(r.n)]))

for (const porTier of repeticoes) {
  const forcado = Object.entries(porTier).some(([t, n]) => n > (comEstoque[t] ?? 0))
  if (forcado) repetidoLegitimo++; else repetidoIlegal++
}
checar('repeticao de card_type so quando o tier esgota os tipos',
  repetidoIlegal === 0,
  `${repetidoIlegal} ilegais, ${repetidoLegitimo} forcados por falta de tipo com estoque`)
checar('Raro sempre epica ou melhor', raroAbaixo === 0, `${raroAbaixo} abaixo`)
checar('Ultra sempre mitica ou melhor', ultraAbaixo === 0, `${ultraAbaixo} abaixo`)
checar('diamante/prisma nunca em slot garantido', duroEmGarantido === 0, `${duroEmGarantido}`)

const totalPacotes = 451
const pct = (x) => (100 * x / totalPacotes).toFixed(1) + '%'
console.log(`    quente ${quentes} (${pct(quentes)}, esperado 1,5%)`)
console.log(`    bonus  ${bonus} (${pct(bonus)}, esperado 8%)`)
console.log(`    promocoes ${promovidos} em ${totalPacotes * 3} slots base ` +
            `(${(100 * promovidos / (totalPacotes * 3)).toFixed(1)}%, esperado 4%)`)
// Tolerancias em ~4 sigma da binomial, nao chutadas: com 451 pacotes o
// bonus tem media 36 e desvio 5,8, entao +-5 pontos percentuais era 4 sigma
// justo e o teste piscava em CI. Porta de CI nao pode falhar por sorte.
const sigma = (n, p) => Math.sqrt(n * p * (1 - p)) / n
const dentro = (obs, n, p, k = 4) => Math.abs(obs / n - p) <= k * sigma(n, p)

checar('taxa de pacote quente plausivel',
  dentro(quentes, totalPacotes, 0.015), pct(quentes))
checar('taxa de bonus plausivel',
  dentro(bonus, totalPacotes, 0.08), pct(bonus))
checar('taxa de promocao plausivel',
  dentro(promovidos, totalPacotes * 3, 0.04),
  (100 * promovidos / (totalPacotes * 3)).toFixed(1) + '%')

console.log('\n    slot de hit do pacote Comum (limpo):')
const somaHit = Object.values(tiersHit).reduce((a, b) => a + b, 0)
for (const [t, esperado] of [['rara', 78], ['epica', 12], ['lendaria', 6], ['mitica', 2]]) {
  const real = 100 * (tiersHit[t] ?? 0) / somaHit
  console.log(`      ${t.padEnd(9)} ${real.toFixed(1)}%  (tabela: ${esperado}%)`)
}
checar('rara domina o hit do Comum como na tabela',
  Math.abs(100 * (tiersHit.rara ?? 0) / somaHit - 78) < 10,
  (100 * (tiersHit.rara ?? 0) / somaHit).toFixed(1) + '%')

// ---------------------------------------------------- invariante do acervo
const inv = await um(`
  select (select count(*) from card_copies where owner_id is not null) as com_dono,
         (select count(*) from copy_history where kind in ('pull','daily')) as entregas,
         (select count(*) from pack_opening_cards) as auditadas,
         (select count(distinct copy_id) from pack_opening_cards) as copias_distintas`)
checar('nenhuma copia entregue duas vezes',
  Number(inv.auditadas) === Number(inv.copias_distintas),
  `${inv.auditadas} entregas / ${inv.copias_distintas} copias distintas`)
checar('copias com dono batem com as entregas',
  Number(inv.com_dono) === Number(inv.copias_distintas),
  `${inv.com_dono} vs ${inv.copias_distintas}`)
console.log(`    ${cartas} cartas entregues em ${totalPacotes} pacotes`)

// ================================================================ pity
console.log('\n== pity ==')
await db.exec(`update players set pity_counter = 12 where id = '${UID.ana}';`)
await como(UID.chefe, `select public.grant_packs('ana','comum',1)`)
const rp = (await como(UID.ana, `select public.open_pack('comum') as r`)).r
checar('pity disparou', rp.pity === true)
checar('pity garantiu epica ou melhor',
  Math.max(...rp.cartas.map((c) => ordem[c.tier])) >= ordem.epica,
  rp.cartas.map((c) => c.tier).join(','))
checar('pity zerou o contador',
  (await um(`select pity_counter from players where id = $1`, [UID.ana])).pity_counter === 0)

// ================================================================ reserva
console.log('\n== reserva do diario ==')
await db.query(`select private.definir_pacotes($1,'comum',true,1)`, [UID.bob])
const rd = (await como(UID.bob, `select public.open_pack('comum') as r`)).r
checar('pacote do diario marcado como tal', rd.do_diario === true)
const base = rd.cartas.filter((c) => !c.from_hit_table)
const daReserva = await um(`
  select count(*) filter (where reserved_for_daily) as r, count(*) as n
  from card_copies where id = any($1)`, [base.map((c) => c.copy_id)])
checar('slots base do diario sairam da reserva',
  Number(daReserva.r) === Number(daReserva.n), `${daReserva.r}/${daReserva.n}`)
const rn = (await como(UID.ana, `select public.open_pack('comum') as r`)).r
const baseN = rn.cartas.filter((c) => !c.from_hit_table)
const foraReserva = await um(`
  select count(*) filter (where not reserved_for_daily) as f, count(*) as n
  from card_copies where id = any($1)`, [baseN.map((c) => c.copy_id)])
checar('slots base do allotment ficaram FORA da reserva',
  Number(foraReserva.f) === Number(foraReserva.n), `${foraReserva.f}/${foraReserva.n}`)

// ================================================================ admin
console.log('\n== RPCs administrativas: jogador comum deve ser negado ==')
const adminRpcs = [
  [`select public.admin_jogadores()`, 'admin_jogadores'],
  [`select public.grant_packs('ana','ultra',999)`, 'grant_packs'],
  [`select public.admin_reset_password('ana','novasenha')`, 'admin_reset_password'],
  [`select public.admin_reset_daily_cooldown('ana')`, 'admin_reset_daily_cooldown'],
  [`select public.admin_set_pack_config('[]'::jsonb)`, 'admin_set_pack_config'],
  [`select public.admin_set_economy_config('[]'::jsonb)`, 'admin_set_economy_config'],
  [`select public.top_up_daily_reserve(10)`, 'top_up_daily_reserve'],
  [`select public.admin_stock_report()`, 'admin_stock_report'],
  [`select public.admin_missing_art()`, 'admin_missing_art'],
  [`select public.seed_edition_dry_run('{"slug":"novo"}'::jsonb)`, 'seed_edition_dry_run'],
  [`select public.seed_edition('{"slug":"novo"}'::jsonb)`, 'seed_edition'],
  [`select public.admin_reset_player_collection('bob')`, 'admin_reset_player_collection'],
  [`select public.admin_reset_all_collections('RESETAR')`, 'admin_reset_all_collections'],
  [`select public.admin_delete_player('bob')`, 'admin_delete_player'],
]
for (const [sql, nome] of adminRpcs) await deveFalhar(nome, UID.bob, sql)

console.log('\n== RPCs administrativas: admin deve funcionar ==')
checar('admin_jogadores lista', (await como(UID.chefe, `select public.admin_jogadores() as r`)).r.length === 3)
checar('admin_stock_report responde',
  !!(await como(UID.chefe, `select public.admin_stock_report() as r`)).r.por_tier)
await deveFalhar('odds que nao somam 100 sao recusadas', UID.chefe,
  `select public.admin_set_pack_config('[{"pack_type":"comum","slot":"hit","tier":"rara","weight":50}]'::jsonb)`)
checar('odds recusadas nao ficaram gravadas',
  Number((await um(`select sum(weight) as s from pack_config where pack_type='comum' and slot='hit'`)).s) === 100)

await como(UID.chefe, `select public.admin_reset_password('bob','senha-nova-123')`)
checar('reset de senha gravou hash no auth.users',
  (await um(`select encrypted_password from auth.users where id = $1`, [UID.bob])).encrypted_password?.startsWith('$2'))
checar('a senha nova confere',
  (await um(`select encrypted_password = extensions.crypt('senha-nova-123', encrypted_password) as ok
             from auth.users where id = $1`, [UID.bob])).ok === true)
checar('admin_log nao guardou a senha',
  !JSON.stringify(await tudo(`select payload from admin_log`)).includes('senha-nova-123'))

// ---------------------------------------------------- zona de perigo
console.log('\n== zona de perigo ==')
const antesTipos = await um(`select (select count(*) from card_types) t, (select count(*) from characters) c`)
const tinhaAna = Number((await um(`select count(*) as n from card_copies where owner_id = $1`, [UID.ana])).n)

// uma forjada para conferir que ela e queimada, nao devolvida
await db.exec(`
  insert into card_copies (card_type_id, serial_number, origin, forge_index, owner_id, verify_code)
  values ((select id from card_types limit 1), null, 'forge', 1, '${UID.ana}', 'FORJADA001');`)

const devolvidas = (await como(UID.chefe, `select public.admin_reset_player_collection('ana') as n`)).n
checar('reset devolveu as puxadas', Number(devolvidas) === tinhaAna, `${devolvidas} de ${tinhaAna}`)
checar('ana ficou sem nada',
  Number((await um(`select count(*) as n from card_copies where owner_id = $1`, [UID.ana])).n) === 0)
checar('forjada foi queimada, nao devolvida ao pool',
  (await um(`select burned, owner_id from card_copies where verify_code = 'FORJADA001'`)).burned === true)
checar('a forjada nao voltou para o pool de sorteio',
  Number((await um(`select count(*) as n from card_copies
     where verify_code = 'FORJADA001' and owner_id is null and not burned`)).n) === 0)
const depoisTipos = await um(`select (select count(*) from card_types) t, (select count(*) from characters) c`)
checar('reset nao apagou card_types nem characters',
  antesTipos.t === depoisTipos.t && antesTipos.c === depoisTipos.c)
checar('estreia mundial sobreviveu ao reset',
  Number((await um(`select count(*) as n from card_copies where first_discovered_by is not null`)).n) > 0)
await deveFalhar('reset global sem digitar RESETAR', UID.chefe,
  `select public.admin_reset_all_collections('sim')`)
await deveFalhar('admin nao apaga a si mesmo', UID.chefe,
  `select public.admin_delete_player('chefe')`)

// ---------------------------------------------------- personagem novo
console.log('\n== seed_edition (personagem 4) ==')
// quantos personagens ANTES do dry-run: o numero cresce a cada Belesma que
// entra, entao comparar com 3 fixo quebrava sozinho
const chAntes = Number((await um(`select count(*) as n from characters`)).n)
const seco = (await como(UID.chefe, `select public.seed_edition_dry_run('{"slug":"zezao"}'::jsonb) as r`)).r
checar('dry-run nao escreve nada',
  Number((await um(`select count(*) as n from characters`)).n) === chAntes,
  `${seco.card_copies} previstas`)
checar('dry-run preve 27 tipos e 2214 copias',
  Number(seco.card_types) === 27 && Number(seco.card_copies) === 2214,
  `${seco.card_types}/${seco.card_copies}`)
const novo = (await como(UID.chefe, `select public.seed_edition('{"slug":"zezao","name":"Belesma do Zezao"}'::jsonb) as r`)).r
checar('criou 2214 copias', Number(novo.copias) === 2214, `${novo.copias}`)
checar('selos do novo saem 12/4/1',
  novo.selos.branco === 12 && novo.selos.preto === 4 && novo.selos.rosa === 1)
checar(`set agora tem ${(chAntes + 1) * 2214} copias`,
  Number((await um(`select count(*) as n from card_copies where origin = 'pull'`)).n)
    === (chAntes + 1) * 2214)
checar('album absorveu os slots sem pagina nova',
  Number((await um(`select count(*) as n from album_pages`)).n) === 28)
await deveFalhar('seed_edition duas vezes aborta', UID.chefe,
  `select public.seed_edition('{"slug":"zezao"}'::jsonb)`)

console.log('\n== admin_log ==')
const log = await tudo(`select acao, alvo from admin_log order by id`)
console.log('   ', log.map((l) => l.acao).join(', '))
checar('admin_log registrou as acoes', log.length >= 6, `${log.length} linhas`)

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
await db.close()
process.exit(falhas === 0 ? 0 : 1)
