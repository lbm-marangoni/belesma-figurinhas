// Verificacao da Fase 1 num Postgres de verdade, sem Docker.
//
// PGlite e o Postgres compilado para WASM. Roda as MESMAS migracoes que vao
// para o Supabase, entao as contagens e o teste de RLS abaixo sao execucao
// real, nao conferencia de planilha.
//
// O que ele NAO cobre: a camada HTTP do PostgREST e o JWT do Supabase Auth.
// auth.uid() aqui e um stub que le a mesma GUC que o Supabase usa.

import { PGlite } from '@electric-sql/pglite'
import { citext } from '@electric-sql/pglite/contrib/citext'
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const migracoes = join(raiz, 'supabase', 'migrations')

const db = await PGlite.create({ extensions: { citext, pgcrypto } })

// ------------------------------------------------------- ambiente Supabase
// Reproduz o que o Supabase ja tem antes da primeira migracao, incluindo o
// GRANT default aberto no schema public - que e justamente o que o REVOKE
// da migracao de RLS precisa desfazer.
await db.exec(`
  create role anon nologin;
  create role authenticated nologin;
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

const arquivos = readdirSync(migracoes).filter((f) => f.endsWith('.sql')).sort()
for (const f of arquivos) {
  process.stdout.write(`  migracao ${f} ... `)
  await db.exec(readFileSync(join(migracoes, f), 'utf8'))
  console.log('ok')
}

const um = async (sql, params) => (await db.query(sql, params)).rows[0]
const tudo = async (sql, params) => (await db.query(sql, params)).rows

let falhas = 0
const checar = (nome, ok, detalhe) => {
  console.log(`  ${ok ? 'PASS' : 'FALHA'}  ${nome}${detalhe ? ' -> ' + detalhe : ''}`)
  if (!ok) falhas++
}

// ================================================================ contagens
console.log('\n== Seed ==')

const c = await um(`
  select
    (select count(*) from characters)                             as personagens,
    (select count(*) from skins)                                  as skins,
    (select count(*) from card_types)                             as tipos,
    (select count(*) from card_copies)                            as copias,
    (select count(distinct verify_code) from card_copies)         as codigos,
    (select count(*) from card_copies where reserved_for_daily)   as reserva,
    (select count(*) from album_pages)                            as paginas
`)
console.log('  characters ..........', c.personagens)
console.log('  skins ...............', c.skins)
console.log('  card_types ..........', c.tipos)
console.log('  card_copies .........', c.copias)
console.log('  album_pages .........', c.paginas)
console.log('  reserved_for_daily ..', c.reserva)

checar('3 personagens', Number(c.personagens) === 3, `${c.personagens}`)
checar('81 card_types', Number(c.tipos) === 81, `${c.tipos}`)
checar('6642 card_copies', Number(c.copias) === 6642, `${c.copias}`)
checar('verify_code unico em todas', Number(c.codigos) === Number(c.copias), `${c.codigos}/${c.copias}`)
checar('reserva do diario = 1500', Number(c.reserva) === 1500, `${c.reserva}`)

// cada personagem tem exatamente 2214
console.log('\n== Copias por personagem ==')
for (const r of await tudo(`
  select ch.slug, count(*) as n
  from card_copies cc join card_types ct on ct.id = cc.card_type_id
  join characters ch on ch.id = ct.character_id
  group by ch.slug order by ch.slug`)) {
  console.log(`  ${r.slug.padEnd(8)} ${r.n}`)
  checar(`${r.slug}: 2214 copias`, Number(r.n) === 2214, `${r.n}`)
}

// tiragem por tier bate com a escada
const tiragem = await tudo(`
  select t.slug, t.print_run, count(distinct ct.id) as tipos, count(cc.id) as copias
  from tiers t
  join card_types ct on ct.tier = t.slug
  join card_copies cc on cc.card_type_id = ct.id
  group by t.slug, t.print_run, t.tier_order order by t.tier_order`)
console.log('\n== Tiragem por tier ==')
for (const r of tiragem) {
  const esperado = Number(r.print_run) * Number(r.tipos)
  console.log(`  ${r.slug.padEnd(9)} ${String(r.tipos).padStart(2)} tipos x ${String(r.print_run).padStart(3)} = ${r.copias}`)
  checar(`tier ${r.slug}`, Number(r.copias) === esperado, `${r.copias} != ${esperado}`)
}

// ================================================================ selos
console.log('\n== Selos ==')
const porCor = await tudo(`
  select seal::text as cor, count(*) as n from card_copies
  where seal <> 'none' group by seal order by seal`)
const mapa = Object.fromEntries(porCor.map((r) => [r.cor, Number(r.n)]))
console.log('  branco ...', mapa.branco ?? 0)
console.log('  preto ....', mapa.preto ?? 0)
console.log('  rosa .....', mapa.rosa ?? 0)
checar('36 branco', (mapa.branco ?? 0) === 36, `${mapa.branco ?? 0}`)
checar('12 preto', (mapa.preto ?? 0) === 12, `${mapa.preto ?? 0}`)
checar('3 rosa', (mapa.rosa ?? 0) === 3, `${mapa.rosa ?? 0}`)

console.log('\n  por personagem:')
for (const r of await tudo(`
  select ch.slug,
    count(*) filter (where cc.seal = 'branco') as branco,
    count(*) filter (where cc.seal = 'preto')  as preto,
    count(*) filter (where cc.seal = 'rosa')   as rosa
  from card_copies cc join card_types ct on ct.id = cc.card_type_id
  join characters ch on ch.id = ct.character_id
  group by ch.slug order by ch.slug`)) {
  console.log(`    ${r.slug.padEnd(8)} ${r.branco} branco / ${r.preto} preto / ${r.rosa} rosa`)
  checar(`${r.slug}: 12/4/1`,
    Number(r.branco) === 12 && Number(r.preto) === 4 && Number(r.rosa) === 1,
    `${r.branco}/${r.preto}/${r.rosa}`)
}

// spec secao 6: o sorteio nao exclui tier nenhum, inclusive prisma 1/1
const tiersComSelo = await um(`
  select count(distinct ct.tier) as n from card_copies cc
  join card_types ct on ct.id = cc.card_type_id where cc.seal <> 'none'`)
console.log(`\n  tiers atingidos pelo sorteio de selo: ${tiersComSelo.n} de 12`)
console.log('  (uniforme por COPIA, entao tier de tiragem alta domina - esperado)')
for (const r of await tudo(`
  select t.slug, t.tier_order,
         count(*) filter (where cc.seal <> 'none') as selados,
         count(*) as total
  from tiers t
  join card_types ct on ct.tier = t.slug
  join card_copies cc on cc.card_type_id = ct.id
  group by t.slug, t.tier_order order by t.tier_order`)) {
  const esperado = (Number(r.total) * 51 / 6642).toFixed(2)
  console.log(`    ${r.slug.padEnd(9)} ${String(r.selados).padStart(2)} selados de ${String(r.total).padStart(4)}  (esperanca ${esperado})`)
}

// O sorteio agora e CSPRNG, entao nao e reproduzivel de fora - a auditoria
// e a tabela seal_audit, gravada no momento do sorteio.
console.log('\n  seal_audit (o comprovante do sorteio):')
const auditoria = await tudo(`
  select ch.slug, a.branco, a.preto, a.rosa, a.checksum
  from seal_audit a join characters ch on ch.id = a.character_id order by ch.slug`)
for (const a of auditoria) {
  console.log(`    ${a.slug.padEnd(8)} ${a.branco}/${a.preto}/${a.rosa}  ${a.checksum}`)
}
checar('seal_audit tem uma linha por personagem', auditoria.length === 3, `${auditoria.length}`)
checar('auditoria bate com 12/4/1 em todos',
  auditoria.every((a) => a.branco === 12 && a.preto === 4 && a.rosa === 1))

// o sorteio precisa ser DIFERENTE a cada banco novo - senao nao e sorteio
const outroBanco = await PGlite.create({ extensions: { citext, pgcrypto } })
await outroBanco.exec(`
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
  grant usage on schema auth to anon, authenticated;`)
for (const a of arquivos) await outroBanco.exec(readFileSync(join(migracoes, a), 'utf8'))
const outraAssinatura = (await outroBanco.query(
  `select string_agg(checksum, '|' order by character_id) as h from seal_audit`)).rows[0].h
const estaAssinatura = auditoria.map((a) => a.checksum).join('|')
checar('um seed novo sorteia selos DIFERENTES (e sorteio, nao hash)',
  outraAssinatura !== estaAssinatura)
const contagemOutro = (await outroBanco.query(
  `select count(*) filter (where seal='branco') b, count(*) filter (where seal='preto') p,
          count(*) filter (where seal='rosa') r from card_copies`)).rows[0]
checar('...mas continua saindo 36/12/3',
  Number(contagemOutro.b) === 36 && Number(contagemOutro.p) === 12 && Number(contagemOutro.r) === 3,
  `${contagemOutro.b}/${contagemOutro.p}/${contagemOutro.r}`)
await outroBanco.close()

// ================================================================ fraude
console.log('\n== Teste de fraude ==')

const alvo = await um(`select id, verify_code from card_copies order by id limit 1`)
const jogador = '11111111-1111-1111-1111-111111111111'
const outro = '22222222-2222-2222-2222-222222222222'
await db.exec(`
  insert into auth.users (id, email) values
    ('${jogador}','comum@belesma.local'),
    ('${outro}','outro@belesma.local');
  insert into public.players (id, nickname) values
    ('${jogador}','comum'), ('${outro}','outro');
`)

async function deveFalhar(nome, sql, papel = 'authenticated', uid = jogador) {
  try {
    await db.exec(`set local role none`)
  } catch { /* fora de transacao, ignora */ }
  try {
    await db.exec(`
      set session request.jwt.claim.sub = '${uid}';
      set role ${papel};
    `)
    await db.exec(sql)
    await db.exec(`reset role;`)
    checar(nome, false, 'PASSOU - isto e um furo')
    return
  } catch (e) {
    const msg = String(e.message || e).split('\n')[0]
    try { await db.exec(`reset role;`) } catch {}
    checar(nome, true, msg.slice(0, 88))
  }
}

console.log('\n  como anon:')
await deveFalhar('anon: update card_copies.owner_id',
  `update public.card_copies set owner_id = '${jogador}' where id = ${alvo.id};`, 'anon')
await deveFalhar('anon: insert card_copies',
  `insert into public.card_copies (card_type_id, serial_number, verify_code)
   values (1, 99999, 'FRAUDE0001');`, 'anon')
await deveFalhar('anon: alterar seal',
  `update public.card_copies set seal = 'rosa' where id = ${alvo.id};`, 'anon')
await deveFalhar('anon: delete card_copies',
  `delete from public.card_copies where id = ${alvo.id};`, 'anon')

console.log('\n  como jogador comum (authenticated):')
await deveFalhar('player: update card_copies.owner_id',
  `update public.card_copies set owner_id = '${jogador}' where id = ${alvo.id};`)
await deveFalhar('player: insert card_copies',
  `insert into public.card_copies (card_type_id, serial_number, verify_code)
   values (1, 99998, 'FRAUDE0002');`)
await deveFalhar('player: alterar seal',
  `update public.card_copies set seal = 'rosa' where id = ${alvo.id};`)
await deveFalhar('player: creditar baba para si',
  `update public.players set baba = 999999 where id = '${jogador}';`)
await deveFalhar('player: virar admin',
  `update public.players set is_admin = true where id = '${jogador}';`)
await deveFalhar('player: alterar allotment',
  `update public.players set baba = 999999 where id = '${jogador}';`)
await deveFalhar('player: mexer nas odds',
  `update public.pack_config set weight = 100 where pack_type = 'comum' and tier = 'prisma';`)
await deveFalhar('player: mexer nos precos',
  `update public.economy_config set valor = 0 where chave = 'compra_ultra';`)
await deveFalhar('player: inserir em baba_log',
  `insert into public.baba_log (player_id, delta, motivo) values ('${jogador}', 99999, 'fraude');`)
await deveFalhar('player: inserir em admin_log',
  `insert into public.admin_log (admin_id, acao) values ('${jogador}', 'fraude');`)
await deveFalhar('player: apagar admin_log',
  `delete from public.admin_log;`)
await deveFalhar('player: chamar a guarda administrativa',
  `select private.require_admin();`)
await deveFalhar('player: usar o schema private',
  `select private.random_int(10);`)
await deveFalhar('player: ler baba alheio',
  `select baba from public.players where id = '${outro}';`)
await deveFalhar('player: select * em players (a armadilha antiga)',
  `select * from public.players;`)
await deveFalhar('player: escrever em seal_audit',
  `update public.seal_audit set branco = 999;`)

// leituras que DEVEM funcionar
console.log('\n  leituras legitimas (devem passar):')
async function devePassar(nome, sql, papel = 'authenticated', uid = jogador) {
  try {
    await db.exec(`set session request.jwt.claim.sub = '${uid}'; set role ${papel};`)
    await db.exec(sql)
    await db.exec(`reset role;`)
    checar(nome, true)
  } catch (e) {
    try { await db.exec(`reset role;`) } catch {}
    checar(nome, false, String(e.message || e).split('\n')[0].slice(0, 88))
  }
}
await devePassar('anon: ler card_copies (indice global publico)',
  `select count(*) from public.card_copies;`, 'anon')
await devePassar('anon: ler o catalogo',
  `select count(*) from public.card_types, public.characters, public.tiers;`, 'anon')
await devePassar('player: ler o proprio saldo por me()',
  `select (public.me())->>'baba' as baba;`)
await devePassar('anon: select * em players_public (sem armadilha)',
  `select * from public.players_public;`, 'anon')
await devePassar('anon: ler seal_audit (auditoria publica)',
  `select * from public.seal_audit;`, 'anon')

// ---------------------------------------------------- a guarda em si funciona?
// Os testes acima provam que o schema private esta trancado, o que esconde se
// require_admin() decide certo. As RPCs da Fase 2 vao viver em public e ser
// security definer, entao serao CHAMAVEIS - quem nega e a guarda por dentro.
// Este bloco simula exatamente esse formato.
console.log('\n  a guarda administrativa (formato das RPCs da Fase 2):')
await db.exec(`
  create or replace function public.rpc_admin_de_mentira()
  returns text language plpgsql security definer
  set search_path = public, pg_temp as $fn$
  begin
    perform private.require_admin();
    return 'executou';
  end; $fn$;
  grant execute on function public.rpc_admin_de_mentira() to authenticated;
`)
await deveFalhar('RPC admin chamavel, jogador comum -> nao autorizado',
  `select public.rpc_admin_de_mentira();`)

await db.exec(`update public.players set is_admin = true where id = '${outro}';`)
await devePassar('RPC admin com is_admin = true -> executa',
  `select public.rpc_admin_de_mentira();`, 'authenticated', outro)
await db.exec(`update public.players set is_admin = false where id = '${outro}';`)
await deveFalhar('RPC admin depois de tirar is_admin -> nega de novo',
  `select public.rpc_admin_de_mentira();`, 'authenticated', outro)
await db.exec(`drop function public.rpc_admin_de_mentira();`)

// ================================================================ integridade
console.log('\n== Integridade ==')
const i = await um(`
  select
    (select count(*) from card_copies where owner_id is not null)   as com_dono,
    (select count(*) from card_copies where burned)                 as queimadas,
    (select count(*) from card_copies where origin <> 'pull')       as forjadas,
    (select count(*) from card_copies where damage_level <> 0)      as estragadas,
    (select count(*) from card_types where art_path not like '/figurinhas/%') as art_ruim,
    (select count(*) from card_copies cc join card_types ct on ct.id = cc.card_type_id
       where cc.serial_number > ct.print_run)                       as serial_estourado`)
checar('nenhuma copia com dono no seed', Number(i.com_dono) === 0, `${i.com_dono}`)
checar('nenhuma queimada no seed', Number(i.queimadas) === 0, `${i.queimadas}`)
checar('nenhuma forjada no seed', Number(i.forjadas) === 0, `${i.forjadas}`)
checar('nenhum desgaste no seed', Number(i.estragadas) === 0, `${i.estragadas}`)
checar('todo art_path no padrao', Number(i.art_ruim) === 0, `${i.art_ruim}`)
checar('nenhum serial acima da tiragem', Number(i.serial_estourado) === 0, `${i.serial_estourado}`)

const vend = await tudo(`select slug, vendavel from tiers where not vendavel`)
checar('so prisma tem vendavel = false',
  vend.length === 1 && vend[0].slug === 'prisma',
  vend.map((v) => v.slug).join(',') || 'nenhum')

// odds fecham em 100 por (pack_type, slot) - secao 18.1
console.log('\n== Odds ==')
for (const r of await tudo(`
  select pack_type::text as tipo, slot::text as slot, sum(weight) as total
  from pack_config group by pack_type, slot order by pack_type, slot`)) {
  console.log(`  ${r.tipo.padEnd(6)} ${r.slot.padEnd(5)} soma ${r.total}`)
  checar(`odds ${r.tipo}/${r.slot} somam 100`, Number(r.total) === 100, `${r.total}`)
}

// ================================================================ idempotencia
console.log('\n== Idempotencia do seed ==')
const antes = await um(`
  select count(*) as n, count(*) filter (where seal <> 'none') as s,
         (select string_agg(checksum, '|' order by character_id) from seal_audit) as h
  from card_copies`)
for (const f of arquivos) await db.exec(readFileSync(join(migracoes, f), 'utf8'))
const depois = await um(`
  select count(*) as n, count(*) filter (where seal <> 'none') as s,
         (select string_agg(checksum, '|' order by character_id) from seal_audit) as h
  from card_copies`)
checar('rodar tudo de novo nao duplica copia',
  Number(antes.n) === Number(depois.n), `${antes.n} -> ${depois.n}`)
checar('rodar tudo de novo nao muda selo',
  Number(antes.s) === Number(depois.s), `${antes.s} -> ${depois.s}`)
checar('rodar tudo de novo NAO re-sorteia (checksum intacto)',
  antes.h === depois.h)
const reserva2 = await um(`select count(*) as n from card_copies where reserved_for_daily`)
checar('rodar tudo de novo nao infla a reserva', Number(reserva2.n) === 1500, `${reserva2.n}`)

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
await db.close()
process.exit(falhas === 0 ? 0 : 1)
