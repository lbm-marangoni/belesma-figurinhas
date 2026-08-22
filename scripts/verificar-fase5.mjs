// Verificacao da Fase 5: trocas, vitrine, indice global, par de aura e
// caçada de serial. Mesmo Postgres em WASM das fases anteriores.
//
// A concorrencia de verdade (duas pessoas aceitando a mesma proposta no
// mesmo instante) esta em scripts/trocas-http.mjs.

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
// PGlite devolve tipo COMPOSTO como string crua; o PostgREST devolve objeto.
// Por isso os testes usam "select * from func()", que expande as colunas.
async function como(uid, sql, params) {
  await db.exec(`set session request.jwt.claim.sub = '${uid}'; set role authenticated;`)
  try { return (await db.query(sql, params)).rows[0] }
  finally { await db.exec('reset role;') }
}
async function deveFalhar(nome, uid, sql, params) {
  try { await como(uid, sql, params); checar(nome, false, 'PASSOU - furo') }
  catch (e) { checar(nome, true, String(e.message).split('\n')[0].slice(0, 68)) }
}

const A = '11111111-1111-1111-1111-111111111111'
const B = '22222222-2222-2222-2222-222222222222'
const C = '33333333-3333-3333-3333-333333333333'
await db.exec(`insert into auth.users (id,email) values
  ('${A}','ana@belesma.local'),('${B}','bob@belesma.local'),('${C}','caio@belesma.local');`)
for (const [u, n] of [[A, 'ana'], [B, 'bob'], [C, 'caio']]) {
  await como(u, `select public.claim_nickname($1)`, [n])
}

// da cartas para os tres, direto no banco (o sorteio ja foi testado na Fase 2)
const daCarta = async (uid, tier, i = 0) => {
  const r = await um(`
    update card_copies set owner_id = $1, claimed_at = now(),
      first_discovered_at = coalesce(first_discovered_at, now()),
      first_discovered_by = coalesce(first_discovered_by, $1)
    where id = (select cc.id from card_copies cc join card_types ct on ct.id = cc.card_type_id
                where ct.tier = $2 and cc.owner_id is null order by cc.id offset $3 limit 1)
    returning id, card_type_id, serial_number`, [uid, tier, i])
  return r
}
const a1 = await daCarta(A, 'comum', 0)
const a2 = await daCarta(A, 'rara', 0)
const b1 = await daCarta(B, 'comum', 5)
const b2 = await daCarta(B, 'epica', 0)

// ================================================================ propor
console.log('\n== propor troca ==')
const t1 = await como(A, `select * from public.propose_trade($1,0,$2,0)`, [a1.id, b1.id])
checar('proposta criada', !!t1?.id)
checar('destinatario deduzido do dono da carta pedida', t1.to_player === B)
checar('status inicial pendente', t1.status === 'pending')

await deveFalhar('nao oferece carta que nao e sua', A,
  `select public.propose_trade($1,0,$2,0)`, [b1.id, a1.id])
await deveFalhar('nao troca consigo mesmo', A,
  `select public.propose_trade($1,0,$2,0)`, [a1.id, a2.id])
await db.exec(`update players set baba = 500 where id = '${A}';`)
await deveFalhar('baba por baba e proibido', A,
  `select public.propose_trade(null,10,null,10)`)

// ================================================================ aceitar
console.log('\n== aceitar ==')
await deveFalhar('quem propos nao pode aceitar a propria proposta', A,
  `select public.accept_trade($1)`, [t1.id])
await deveFalhar('terceiro nao aceita proposta alheia', C,
  `select public.accept_trade($1)`, [t1.id])

const aceita = (await como(B, `select public.accept_trade($1) as r`, [t1.id])).r
checar('aceite funciona', aceita.ok === true, JSON.stringify(aceita))
const donos = await um(`select
  (select owner_id from card_copies where id = $1) as dono_a1,
  (select owner_id from card_copies where id = $2) as dono_b1`, [a1.id, b1.id])
checar('as cartas trocaram de dono de verdade',
  donos.dono_a1 === B && donos.dono_b1 === A)
const hist = await um(`select count(*) as n from copy_history
  where copy_id in ($1,$2) and kind = 'trade'`, [a1.id, b1.id])
checar('historico registrou a troca dos dois lados', Number(hist.n) === 2)
await deveFalhar('nao aceita duas vezes', B, `select public.accept_trade($1)`, [t1.id])

// ================================================================ revalidação
console.log('\n== revalidacao da posse (spec §11) ==')
// A propoe a2 por b2. Depois a2 muda de dono por fora. O aceite tem que falhar.
const t2 = await como(A, `select * from public.propose_trade($1,0,$2,0)`, [a2.id, b2.id])
await db.exec(`update card_copies set owner_id = '${C}' where id = ${a2.id};`)
const furada = (await como(B, `select public.accept_trade($1) as r`, [t2.id])).r
checar('carta oferecida mudou de dono: aceite recusa com motivo',
  furada.ok === false && /mudou de dono/.test(furada.motivo), JSON.stringify(furada))
checar('a proposta furada foi cancelada, nao deixada pendente',
  (await um(`select status from trades where id = $1`, [t2.id])).status === 'cancelled')
checar('nenhuma carta se moveu na tentativa falha',
  (await um(`select owner_id from card_copies where id = $1`, [b2.id])).owner_id === B)
await db.exec(`update card_copies set owner_id = '${A}' where id = ${a2.id};`)

// ================================================================ exclusividade
console.log('\n== duas propostas com a mesma copia (teste de aceitacao 7) ==')
const c1 = await daCarta(C, 'comum', 9)
const p1 = await como(A, `select * from public.propose_trade($1,0,$2,0)`, [a2.id, b2.id])
const p2 = await como(A, `select * from public.propose_trade($1,0,$2,0)`, [a2.id, c1.id])
checar('duas propostas pendentes com a mesma carta oferecida',
  Number((await um(`select count(*) as n from trades where status='pending' and offered_copy_id=$1`,
    [a2.id])).n) === 2)
await como(B, `select public.accept_trade($1) as r`, [p1.id])
const est = await tudo(`select id, status from trades where id in ($1,$2) order by id`, [p1.id, p2.id])
checar('aceitar uma cancela a outra automaticamente',
  est[0].status === 'accepted' && est[1].status === 'cancelled',
  est.map((e) => e.status).join('/'))
await deveFalhar('a proposta cancelada nao pode mais ser aceita', C,
  `select public.accept_trade($1)`, [p2.id])

// ================================================================ recusar
console.log('\n== recusar e cancelar ==')
const doB = await um(`select id from card_copies where owner_id = $1 limit 1`, [B])
const p3 = await como(B, `select * from public.propose_trade($1,0,$2,0)`, [doB.id, c1.id])
await deveFalhar('so o destinatario recusa', B, `select public.decline_trade($1)`, [p3.id])
await como(C, `select public.decline_trade($1)`, [p3.id])
checar('recusa marca declined',
  (await um(`select status from trades where id=$1`, [p3.id])).status === 'declined')

const p4 = await como(B, `select * from public.propose_trade($1,0,$2,0)`, [doB.id, c1.id])
await deveFalhar('so quem propos cancela', C, `select public.cancel_trade($1)`, [p4.id])
await como(B, `select public.cancel_trade($1)`, [p4.id])
checar('cancelamento marca cancelled',
  (await um(`select status from trades where id=$1`, [p4.id])).status === 'cancelled')

// ================================================================ vitrine
console.log('\n== vitrine ==')
const minhas = await tudo(`select id from card_copies where owner_id = $1 limit 3`, [A])
await como(A, `select public.set_showcase($1)`, [minhas.map((m) => m.id)])
const vit = await um(`select showcase_1, showcase_2, showcase_3 from players where id=$1`, [A])
checar('vitrine gravada', vit.showcase_1 === minhas[0].id)

// tem que ser carta de OUTRO no momento do teste: b2 passou para a ana numa
// das trocas acima, entao usar b2 aqui testaria a coisa errada
const alheia = await um(`select id from card_copies where owner_id = $1 limit 1`, [C])
await deveFalhar('nao expoe carta alheia', A,
  `select public.set_showcase($1)`, [[alheia.id]])
await deveFalhar('vitrine cabe 3', A,
  `select public.set_showcase($1)`, [[...minhas.map((m) => m.id), alheia.id, alheia.id]])
checar('as tentativas recusadas nao mexeram na vitrine',
  (await um(`select showcase_1 from players where id=$1`, [A])).showcase_1 === minhas[0].id)

// a troca aceita nao pode deixar vitrine apontando para carta que saiu
const naVitrine = minhas[0].id
const alvoC = await daCarta(C, 'incomum', 0)
const p5 = await como(A, `select * from public.propose_trade($1,0,$2,0)`, [naVitrine, alvoC.id])
await como(C, `select public.accept_trade($1) as r`, [p5.id])
const vit2 = await um(`select showcase_1 from players where id=$1`, [A])
checar('trocar carta da vitrine limpa o slot', vit2.showcase_1 === null, `${vit2.showcase_1}`)

// ================================================================ indice global
console.log('\n== indice global ==')
const gi = (await um(`select public.global_index() as g`)).g
checar('lista os 3 personagens', gi.personagens.length === 3, `${gi.personagens.length}`)
checar('total_personagens bate', gi.total_personagens === 3)
checar('cada personagem traz 27 tipos',
  gi.personagens.every((p) => p.tipos.length === 27),
  gi.personagens.map((p) => p.tipos.length).join('/'))
const algum = gi.personagens.flatMap((p) => p.tipos).find((t) => t.descoberto)
checar('tipo descoberto tem credito e data', !!algum?.primeiro && !!algum?.em,
  `${algum?.skin} por ${algum?.primeiro}`)
checar('descobertos <= total', gi.descobertos <= gi.total_personagens, `${gi.descobertos}`)

// forjada nao descobre nada (secao 7)
await db.exec(`
  insert into card_copies (card_type_id, serial_number, origin, forge_index, owner_id, verify_code,
                           first_discovered_at, first_discovered_by)
  select ct.id, null, 'forge', 1, '${A}', 'FORJTESTE1', now(), '${A}'
  from card_types ct join characters ch on ch.id = ct.character_id
  where ch.slug = 'santao' and ct.skin = 'prisma';`)
const gi2 = (await um(`select public.global_index() as g`)).g
const prismaSantao = gi2.personagens.find((p) => p.slug === 'santao').tipos.find((t) => t.skin === 'prisma')
checar('forjada NAO conta como descoberta', prismaSantao.descoberto === false,
  `descoberto=${prismaSantao.descoberto}`)
checar('forjada NAO conta como distribuida', Number(prismaSantao.distribuidas) === 0,
  `${prismaSantao.distribuidas}`)

// ================================================================ par de aura
console.log('\n== par de aura ==')
checar('sem par ainda', (await um(`select public.pares_de_aura() as p`)).p.length === 0)
await db.exec(`
  update card_copies set owner_id = '${B}', claimed_at = now()
  where id in (
    select min(cc.id) from card_copies cc
    join card_types ct on ct.id = cc.card_type_id
    join characters ch on ch.id = ct.character_id
    where ch.slug = 'pedrao' and ct.skin in ('aura-branca','aura-preta') and cc.owner_id is null
    group by ct.skin);`)
const pares = (await um(`select public.pares_de_aura() as p`)).p
checar('par de aura detectado', pares.length === 1, JSON.stringify(pares))
checar('par nomeia o dono e o personagem',
  pares[0]?.nickname === 'bob' && pares[0]?.personagem === 'pedrao')

// uma aura de personagem DIFERENTE nao forma par
await db.exec(`
  update card_copies set owner_id = '${C}', claimed_at = now()
  where id = (select min(cc.id) from card_copies cc
    join card_types ct on ct.id = cc.card_type_id
    join characters ch on ch.id = ct.character_id
    where ch.slug = 'dinho' and ct.skin = 'aura-branca' and cc.owner_id is null);`)
checar('aura solta nao vira par',
  (await um(`select public.pares_de_aura() as p`)).p.length === 1)

// ================================================================ ranking
console.log('\n== caçada de serial ==')
const rank = (await um(`select public.ranking_serial() as r`)).r
checar('ranking lista quem tem carta', rank.length >= 3, `${rank.length} jogadores`)
checar('traz menor serial e contagem de selos',
  rank.every((r) => r.melhor_serial > 0 && r.selos >= 0))
checar('ranking e publico (anon le)',
  !!(await (async () => {
    await db.exec(`set role anon;`)
    try { return (await db.query(`select public.ranking_serial() as r`)).rows[0].r } finally { await db.exec('reset role;') }
  })()))
checar('indice global e publico (anon le)',
  !!(await (async () => {
    await db.exec(`set role anon;`)
    try { return (await db.query(`select public.global_index() as g`)).rows[0].g } finally { await db.exec('reset role;') }
  })()))

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
await db.close()
process.exit(falhas === 0 ? 0 : 1)
