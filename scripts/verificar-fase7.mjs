// Verificacao da Fase 7: diario, streak, bonus de troca com a trava
// anti-impressora, cascata de esgotamento e a auditoria de seguranca final.

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

// ================================================================ diario
console.log('\n== diario (spec §8) ==')
// claim_daily agora devolve uma LISTA de pacotes, porque quais pacotes o
// diario entrega saiu do codigo e virou coluna de pack_definitions.
const doDia = (r, slug) =>
  Number((r.pacotes ?? []).find((x) => x.slug === slug)?.quantidade ?? 0)

const d1 = (await como(A, `select public.claim_daily() as r`)).r
checar('credita 2 comuns e 1 raro', doDia(d1,'comum') === 2 && doDia(d1,'raro') === 1,
  `${doDia(d1,'comum')}/${doDia(d1,'raro')}`)
checar('o primeiro resgate nao traz ultra', doDia(d1,'ultra') === 0)
checar('streak comeca em 1', d1.streak === 1, `${d1.streak}`)

const p1 = await um(`select private.tem_pacotes(id,'comum',true) as packs_common_daily,
       private.tem_pacotes(id,'raro',true)  as packs_rare_daily,
       private.tem_pacotes(id,'ultra',true) as packs_ultra_daily, baba,
                            dailies_claimed from players where id=$1`, [A])
checar('os pacotes caem nos contadores do DIARIO, nao no allotment',
  Number(p1.packs_common_daily) === 2 && Number(p1.packs_rare_daily) === 1
  && Number(p1.packs_ultra_daily) === 0)
checar('login diario paga 30 baba', p1.baba === 30, `${p1.baba}`)

await deveFalhar('nao resgata duas vezes em 24h', A, `select public.claim_daily()`)

// segundo e terceiro resgate: o ultra sai no terceiro
await db.exec(`update players set last_daily_at = now() - interval '25 hours' where id='${A}';`)
const d2 = (await como(A, `select public.claim_daily() as r`)).r
checar('segundo resgate ainda sem ultra', doDia(d2,'ultra') === 0)
checar('streak avanca', d2.streak === 2, `${d2.streak}`)

await db.exec(`update players set last_daily_at = now() - interval '25 hours' where id='${A}';`)
const d3 = (await como(A, `select public.claim_daily() as r`)).r
checar('o TERCEIRO resgate traz o ultra', doDia(d3,'ultra') === 1)
checar('o ultra caiu no contador do diario',
  Number((await um(`select private.tem_pacotes($1,'ultra',true) as n`, [A])).n) === 1)

// streak de 7 paga o extra
for (let i = 4; i <= 7; i++) {
  await db.exec(`update players set last_daily_at = now() - interval '25 hours' where id='${A}';`)
  var d = (await como(A, `select public.claim_daily() as r`)).r
}
checar('setimo dia de streak paga o bonus extra', d.streak === 7 && d.baba === 130,
  `streak ${d.streak}, ${d.baba} baba`)

// passou de 48h: o streak recomeca
await db.exec(`update players set last_daily_at = now() - interval '3 days' where id='${A}';`)
const dq = (await como(A, `select public.claim_daily() as r`)).r
checar('passar de 48h zera o streak', dq.streak === 1, `${dq.streak}`)

// ------------------------------------- o diario puxa da RESERVA (§8)
const antesReserva = Number((await um(
  `select count(*) as n from card_copies where reserved_for_daily and owner_id is null`)).n)
const rd = (await como(A, `select public.open_pack('comum') as r`)).r
checar('pacote do diario e marcado como tal', rd.do_diario === true)
const base = rd.cartas.filter((c) => !c.from_hit_table).map((c) => c.copy_id)
const daReserva = await um(`select count(*) filter (where reserved_for_daily) r, count(*) n
  from card_copies where id = any($1)`, [base])
checar('os slots base sairam da reserva',
  Number(daReserva.r) === Number(daReserva.n), `${daReserva.r}/${daReserva.n}`)
checar('a reserva encolheu', Number((await um(
  `select count(*) as n from card_copies where reserved_for_daily and owner_id is null`)).n)
  < antesReserva)

// ================================================================ bonus de troca
console.log('\n== bonus de troca e a trava anti-impressora (spec §19.3) ==')
const dar = async (uid, tier, n, off = 0) => (await tudo(`
  update card_copies set owner_id=$1, claimed_at=now()
  where id in (select cc.id from card_copies cc join card_types ct on ct.id=cc.card_type_id
               where ct.tier=$2 and cc.owner_id is null order by cc.id offset $4 limit $3)
  returning id, card_type_id`, [uid, tier, n, off]))

// precisam ser card_types DIFERENTES: o bonus so paga quando o lado que
// recebe fica com um tipo do qual tinha zero. Com o mesmo tipo dos dois
// lados nao ha colecao nova para ninguem - e o teste testaria a coisa errada.
// ...e nenhum dos dois pode JA TER o tipo do outro. O pacote diario aberto
// acima pode ter dado uma rara para a ana; se calhar de ser o mesmo tipo, ela
// nao recebe bonus e o teste falha por sorte, nao por bug. Foi o que piscou
// no CI.
const doisTipos = await tudo(`
  select min(cc.id) as id, cc.card_type_id from card_copies cc
  join card_types ct on ct.id = cc.card_type_id
  where ct.tier = 'rara' and cc.owner_id is null
    and not exists (select 1 from card_copies o
                    where o.card_type_id = cc.card_type_id
                      and o.owner_id in ($1, $2))
  group by cc.card_type_id order by cc.card_type_id limit 2`, [A, B])
const ca = doisTipos[0], cb = doisTipos[1]
await db.exec(`update card_copies set owner_id='${A}', claimed_at=now() where id=${ca.id};`)
await db.exec(`update card_copies set owner_id='${B}', claimed_at=now() where id=${cb.id};`)
const babaA0 = (await um(`select baba from players where id=$1`, [A])).baba
const babaB0 = (await um(`select baba from players where id=$1`, [B])).baba

const t1 = await como(A, `select * from public.propose_trade($1,0,$2,0)`, [ca.id, cb.id])
await como(B, `select public.accept_trade($1) as r`, [t1.id])
const babaA1 = (await um(`select baba from players where id=$1`, [A])).baba
const babaB1 = (await um(`select baba from players where id=$1`, [B])).baba
checar('troca que move colecao paga os dois lados',
  babaA1 === babaA0 + 25 && babaB1 === babaB0 + 25, `${babaA1 - babaA0}/${babaB1 - babaB0}`)

// devolver as MESMAS cartas nao pode pagar de novo — era o furo da §19.7
const t2 = await como(B, `select * from public.propose_trade($1,0,$2,0)`, [ca.id, cb.id])
await como(A, `select public.accept_trade($1) as r`, [t2.id])
const babaA2 = (await um(`select baba from players where id=$1`, [A])).baba
const babaB2 = (await um(`select baba from players where id=$1`, [B])).baba
checar('DESFAZER a troca nao paga de novo (trava do par + card_type)',
  babaA2 === babaA1 && babaB2 === babaB1, `${babaA2 - babaA1}/${babaB2 - babaB1}`)

let ida = 0
for (let i = 0; i < 4; i++) {
  const t = await como(A, `select * from public.propose_trade($1,0,$2,0)`, [ca.id, cb.id])
  await como(B, `select public.accept_trade($1) as r`, [t.id])
  const v = await como(B, `select * from public.propose_trade($1,0,$2,0)`, [ca.id, cb.id])
  await como(A, `select public.accept_trade($1) as r`, [v.id])
  ida++
}
const babaA3 = (await um(`select baba from players where id=$1`, [A])).baba
checar(`${ida * 2} trocas reversiveis geraram ZERO baba`,
  babaA3 === babaA2, `${babaA3 - babaA2} baba criados do nada`)

// ================================================================ estoque
console.log('\n== cascata de esgotamento (spec §8) ==')
await db.exec(`set role anon;`)
const est = (await db.query(`select public.estoque_publico() as r`)).rows[0].r
await db.exec(`reset role;`)
checar('estoque_publico e publico', !!est)
checar('traz os 12 tiers', est.por_tier.length === 12, `${est.por_tier.length}`)
checar('traz a reserva do diario e o pool base',
  est.reserva_diaria > 0 && est.pool_base > 0,
  `reserva ${est.reserva_diaria}, base ${est.pool_base}`)

// ================================================================ seguranca final
console.log('\n== auditoria final de seguranca (teste 14/15 da §17) ==')
const rpcsAdmin = [
  `select public.admin_jogadores()`,
  `select public.grant_packs('todos','ultra',999)`,
  `select public.admin_reset_password('bob','xxxxxx')`,
  `select public.admin_reset_daily_cooldown('bob')`,
  `select public.admin_set_pack_config('[]'::jsonb)`,
  `select public.admin_set_economy_config('[]'::jsonb)`,
  `select public.top_up_daily_reserve(10)`,
  `select public.admin_stock_report()`,
  `select public.admin_missing_art()`,
  `select public.seed_edition_dry_run('{"slug":"x"}'::jsonb)`,
  `select public.seed_edition('{"slug":"x"}'::jsonb)`,
  `select public.admin_reset_player_collection('bob')`,
  `select public.admin_reset_all_collections('RESETAR')`,
  `select public.admin_delete_player('bob')`,
]
for (const sql of rpcsAdmin) {
  await deveFalhar(`negado: ${sql.slice(14, 46)}`, A, sql)
}

const escritas = [
  [`update public.card_copies set owner_id = '${A}'`, 'update card_copies'],
  [`update public.players set baba = 999999 where id = '${A}'`, 'creditar baba'],
  [`update public.players set is_admin = true where id = '${A}'`, 'virar admin'],
  [`update public.card_copies set seal = 'rosa'`, 'alterar selo'],
  [`update public.card_copies set damage_level = 0`, 'zerar desgaste'],
  [`update public.economy_config set valor = 1`, 'mexer nos precos'],
  [`update public.pack_config set weight = 1`, 'mexer nas odds'],
  [`insert into public.baba_log (player_id, delta, motivo) values ('${A}', 9, 'x')`, 'forjar extrato'],
  [`update public.seal_audit set branco = 0`, 'mexer na auditoria de selo'],
  [`insert into public.album_colagem (player_id, card_type_id, copy_id) values ('${A}',1,1)`, 'colar na marra'],
  [`update public.trade_rewards set card_type_id = 1`, 'burlar a trava de troca'],
  [`delete from public.copy_history`, 'apagar historico'],
]
for (const [sql, nome] of escritas) await deveFalhar(`negado: ${nome}`, A, sql)

// as invariantes do acervo continuam de pe
console.log('\n== invariantes do acervo ==')
const inv = await um(`
  select
    (select count(*) from card_copies where origin='pull'
       and (serial_number is null or forge_index is not null))            as pull_torta,
    (select count(*) from card_copies where origin='forge'
       and (serial_number is not null or forge_index is null))            as forge_torta,
    (select count(*) from card_copies where origin='forge' and seal<>'none') as forjada_selada,
    (select count(*) from card_copies cc join card_types ct on ct.id=cc.card_type_id
       where cc.serial_number > ct.print_run)                             as serial_estourado,
    (select count(*) from (select card_type_id, serial_number from card_copies
       where origin='pull' group by 1,2 having count(*)>1) x)             as serial_duplicado,
    (select count(*) filter (where seal='branco') from card_copies)       as branco,
    (select count(*) filter (where seal='preto')  from card_copies)       as preto,
    (select count(*) filter (where seal='rosa')   from card_copies)       as rosa`)
checar('nenhuma puxada sem serial ou com forge_index', Number(inv.pull_torta) === 0)
checar('nenhuma forjada com serial da tiragem', Number(inv.forge_torta) === 0)
checar('nenhuma forjada com selo', Number(inv.forjada_selada) === 0)
checar('nenhum serial acima da tiragem', Number(inv.serial_estourado) === 0)
checar('nenhum (tipo, serial) duplicado', Number(inv.serial_duplicado) === 0)
const NCH7 = Number((await um(`select count(*) as n from characters`)).n)
checar('a contagem de selos NAO mudou depois de tudo isso (teste 5)',
  Number(inv.branco) === NCH7 * 12 && Number(inv.preto) === NCH7 * 4
  && Number(inv.rosa) === NCH7,
  `${inv.branco}/${inv.preto}/${inv.rosa}`)

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
await db.close()
process.exit(falhas === 0 ? 0 : 1)
