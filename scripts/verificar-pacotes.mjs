// Pacote como DADO: definicao, slots, filtros, limite de edicao, construtor.
//
//   node scripts/verificar-pacotes.mjs
//
// Cobre o que o modelo novo promete e o antigo nao conseguia: criar pacote
// sem deploy, filtrar o pool antes do sorteio, respeitar o filtro tambem na
// cascata, e recusar preco que se paga sozinho.

import { PGlite } from '@electric-sql/pglite'
import { citext } from '@electric-sql/pglite/contrib/citext'
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
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
  grant usage on schema auth to anon, authenticated;`)
for (const f of readdirSync(join(raiz, 'supabase', 'migrations'))
  .filter((x) => x.endsWith('.sql')).sort()) {
  await db.exec(readFileSync(join(raiz, 'supabase', 'migrations', f), 'utf8'))
}

const um = async (s, p) => (await db.query(s, p)).rows[0]
const tudo = async (s, p) => (await db.query(s, p)).rows
let falhas = 0
const checar = (n, ok, d) => {
  console.log(`  ${ok ? 'PASS' : 'FALHA'}  ${n}${d !== undefined ? ' -> ' + d : ''}`)
  if (!ok) falhas++
}
async function como(uid, sql, params) {
  await db.exec(`set session request.jwt.claim.sub = '${uid}'; set role authenticated;`)
  try { return (await db.query(sql, params)).rows[0] }
  finally { await db.exec('reset role;') }
}
async function deveFalhar(nome, uid, sql, params) {
  try { await como(uid, sql, params); checar(nome, false, 'PASSOU - furo') }
  catch (e) { checar(nome, true, String(e.message).split('\n')[0].slice(0, 70)) }
}

const A = '11111111-1111-1111-1111-111111111111'
const B = '22222222-2222-2222-2222-222222222222'
await db.exec(`insert into auth.users (id,email) values
  ('${A}','ana@belesma.local'),('${B}','bob@belesma.local');`)
await como(A, `select public.claim_nickname('ana')`)
await como(B, `select public.claim_nickname('bob')`)
await db.exec(`update players set is_admin = true where id = '${A}';`)

const defs = async () => (await como(A, `select public.admin_pacotes() as r`)).r
const idDe = async (slug) => (await defs()).find((d) => d.slug === slug)?.id

// ================================================================ migracao
console.log('== os tres antigos viraram linha ==')
{
  const ds = await defs()
  for (const slug of ['comum', 'raro', 'ultra']) {
    const d = ds.find((x) => x.slug === slug)
    checar(`${slug}: existe como definicao`, !!d)
    checar(`${slug}: 4 slots, o ultimo garantido`,
      d.slots.length === 4 && d.slots[3].garantido && !d.slots[0].garantido,
      `${d.slots.length} slots`)
    const somas = d.slots.map((s) => s.odds.reduce((a, o) => a + Number(o.weight), 0))
    checar(`${slug}: toda tabela de odds soma 100`,
      somas.every((x) => Math.abs(x - 100) < 0.01), somas.join(' / '))
  }
  // as odds do hit tem que bater com a pack_config original, ao centesimo
  for (const slug of ['comum', 'raro', 'ultra']) {
    const d = ds.find((x) => x.slug === slug)
    const nova = Object.fromEntries(d.slots[3].odds.map((o) => [o.tier, Number(o.weight)]))
    const velha = Object.fromEntries((await tudo(
      `select tier, weight from pack_config where pack_type=$1 and slot='hit' and weight>0`,
      [slug])).map((r) => [r.tier, Number(r.weight)]))
    // comparar por chave ordenada: JSON.stringify de objeto e sensivel a
    // ordem de insercao, e as duas consultas ordenam diferente
    const norm = (o) => Object.keys(o).sort().map((k) => `${k}=${o[k]}`).join(' ')
    checar(`${slug}: odds do hit preservadas ao centesimo`,
      norm(nova) === norm(velha),
      norm(nova) === norm(velha) ? Object.keys(velha).length + ' tiers'
        : `${norm(nova)} vs ${norm(velha)}`)
  }
  const c = ds.find((x) => x.slug === 'comum')
  checar('comum manteve quente/bonus/promocao/pity',
    Number(c.taxa_quente) === 0.015 && Number(c.taxa_bonus) === 0.08
    && Number(c.taxa_promocao) === 0.04 && c.pity_limite === 12
    && c.pity_piso_tier === 'epica',
    `${c.taxa_quente}/${c.taxa_bonus}/${c.taxa_promocao}/pity ${c.pity_limite}`)
}

// ================================================================ exemplos
console.log('\n== os tres de exemplo ==')
for (const [slug, esperado] of [['elementais', ['rara']], ['joias', ['epica']]]) {
  const d = (await defs()).find((x) => x.slug === slug)
  checar(`${slug}: criado`, !!d)
  const tiers = [...new Set(d.slots.flatMap((s) => s.odds.map((o) => o.tier)))]
  checar(`${slug}: so sai ${esperado.join('/')}`,
    JSON.stringify(tiers.sort()) === JSON.stringify(esperado.sort()), tiers.join(','))
}
{
  const d = (await defs()).find((x) => x.slug === 'pedrao-comum-mais')
  checar('pedrao-comum-mais: criado', !!d)
  const tiers = d.slots[0].odds.map((o) => o.tier)
  checar('pedrao-comum-mais: cobre a escada inteira', tiers.length === 12, `${tiers.length} tiers`)
  const pesos = d.slots[0].odds.map((o) => Number(o.weight))
  const decrescente = pesos.every((w, i) => i === 0 || w <= pesos[i - 1] + 0.01)
  checar('pedrao-comum-mais: tier mais raro nunca mais provavel que o mais comum',
    decrescente, pesos.map((x) => x.toFixed(2)).join(' > '))
}


// ================================================================ personagem
console.log('\n== um booster por personagem ==')
{
  const ds = await defs()
  const chars = await tudo(`select slug, name from characters order by display_order, id`)
  for (const c of chars) {
    const d = ds.find((x) => x.slug === `booster-${c.slug}`)
    checar(`booster-${c.slug}: existe e esta na loja`, !!d && d.elegivel_loja)
    if (!d) continue
    const filtros = d.slots.map((s) => JSON.stringify(s.filtro?.characters ?? []))
    checar(`booster-${c.slug}: TODO slot filtra o personagem`,
      filtros.every((f) => f === JSON.stringify([c.slug])), filtros.join(' '))
  }

  // as odds tem que ser as mesmas do Comum: o booster de personagem restringe
  // QUEM sai, nao a raridade
  const comum = ds.find((x) => x.slug === 'comum')
  const ped = ds.find((x) => x.slug === 'booster-pedrao')
  const chave = (d) => d.slots.map((s) => s.odds
    .map((o) => `${o.tier}:${o.weight}`).sort().join(',')).join(' | ')
  checar('booster de personagem tem as odds do Comum', chave(comum) === chave(ped))

  // e na pratica so vem aquele personagem
  const id = ped.id
  await como(A, `select public.admin_entregar_pacote($1::int, 'ana', 15, false)`, [id])
  const fora = []
  for (let i = 0; i < 15; i++) {
    const r = (await como(A, `select public.open_pack($1::int) as r`, [id])).r
    for (const x of r.cartas) if (x.character_slug !== 'pedrao') fora.push(x.character_slug)
  }
  checar('15 aberturas do Booster Pedrao e so vem Pedrao', fora.length === 0,
    fora.join(',') || 'so pedrao')
}

// o quarto Belesma chega e o booster dele nasce junto
{
  await db.exec(`insert into characters (slug, name, display_order,
                                        palette_primary, palette_accent)
                 values ('invasor', 'Belesma Invasor', 99, '#000', '#fff')
                 on conflict do nothing;`)
  const criados = (await como(A, `select public.admin_criar_booster_faltando() as r`)).r
  checar('personagem novo ganha booster sozinho',
    criados.some((c) => /Invasor/.test(c.personagem)), JSON.stringify(criados))
  checar('e rodar de novo nao duplica',
    (await como(A, `select public.admin_criar_booster_faltando() as r`)).r.length === 0)
  await db.exec(`delete from pack_definitions where slug = 'booster-invasor';
                 delete from characters where slug = 'invasor';`)
}

// pack_config nao engana mais
await deveFalhar('editar pack_config e recusado com explicacao', A,
  `select public.admin_set_pack_config('[]'::jsonb)`)

// ================================================================ filtro
console.log('\n== o filtro restringe o pool de verdade ==')
{
  const id = await idDe('elementais')
  await como(A, `select public.admin_entregar_pacote($1::int, 'ana', 30, false)`, [id])
  const saiu = new Set()
  for (let i = 0; i < 30; i++) {
    const r = (await como(A, `select public.open_pack($1::int) as r`, [id])).r
    for (const c of r.cartas) saiu.add(`${c.tier}|${c.skin}`)
  }
  const fora = [...saiu].filter((k) => !['fogo', 'gelo', 'trovao', 'vento'].includes(k.split('|')[1]))
  checar('30 aberturas de Elementais e nada fora das quatro skins',
    fora.length === 0, fora.join(', ') || `${saiu.size} combinacoes, todas dentro`)
}
{
  const id = await idDe('pedrao-comum-mais')
  await como(A, `select public.admin_entregar_pacote($1::int, 'ana', 20, false)`, [id])
  const fora = []
  for (let i = 0; i < 20; i++) {
    const r = (await como(A, `select public.open_pack($1::int) as r`, [id])).r
    for (const c of r.cartas) if (c.character_slug !== 'pedrao') fora.push(c.character_slug)
  }
  checar('20 aberturas de Pedrao Comum+ e so vem Pedrao', fora.length === 0,
    fora.join(',') || 'so pedrao')
}

// a cascata tambem nao pode sair do filtro
console.log('\n== a cascata respeita o filtro ==')
{
  const id = await idDe('joias')
  // seca TODAS as epicas: o slot fica sem o unico tier que ele lista
  await db.exec(`update card_copies set owner_id = '${B}'
    where card_type_id in (select id from card_types where tier = 'epica');`)
  await como(A, `select public.admin_entregar_pacote($1::int, 'ana', 5, false)`, [id])
  let fora = 0, curtos = 0, estouros = 0
  for (let i = 0; i < 5; i++) {
    try {
      const r = (await como(A, `select public.open_pack($1::int) as r`, [id])).r
      if (r.cartas.length < r.esperado) curtos++
      for (const c of r.cartas) if (c.tier !== 'epica') fora++
    } catch { estouros++ }
  }
  checar('sem epica no mundo, Joias nao entrega outra coisa', fora === 0, `${fora} fora do filtro`)
  checar('em vez disso o pacote sai curto ou recusa', curtos + estouros === 5,
    `${curtos} curtos, ${estouros} recusados`)
  await db.exec(`update card_copies set owner_id = null where owner_id = '${B}';`)
}

// ================================================================ limite
console.log('\n== edicao limitada ==')
{
  const r = await como(A, `select public.admin_salvar_pacote($1::jsonb) as r`, [JSON.stringify({
    slug: 'edicao-teste', name: 'Edicao Teste', tamanho: 1, distribuicao: 'admin',
    limite_global: 3,
    slots: [{ ordem: 1, filtro: { tiers: ['comum'] }, garantido: false,
              odds: [{ tier: 'comum', weight: 100 }] }],
  })])
  const id = r.r.id
  await como(A, `select public.admin_entregar_pacote($1::int, 'ana', 10, false)`, [id])
  let ok = 0, negados = 0
  for (let i = 0; i < 6; i++) {
    try { await como(A, `select public.open_pack($1::int)`, [id]); ok++ }
    catch { negados++ }
  }
  checar('para exatamente no limite_global', ok === 3 && negados === 3, `${ok} abertas, ${negados} negadas`)
  checar('o contador bate', Number((await um(
    `select aberturas_realizadas from pack_definitions where id=$1::int`, [id])).aberturas_realizadas) === 3)
}

// ================================================================ construtor
console.log('\n== o construtor valida ==')
await deveFalhar('recusa odds que nao somam 100', A,
  `select public.admin_salvar_pacote($1::jsonb)`, [JSON.stringify({
    slug: 'ruim1', name: 'Ruim', tamanho: 1, distribuicao: 'admin',
    slots: [{ odds: [{ tier: 'comum', weight: 90 }] }] })])
await deveFalhar('recusa pacote sem slot', A,
  `select public.admin_salvar_pacote($1::jsonb)`, [JSON.stringify({
    slug: 'ruim2', name: 'Ruim', tamanho: 1, distribuicao: 'admin', slots: [] })])
await deveFalhar('recusa tier inexistente', A,
  `select public.admin_salvar_pacote($1::jsonb)`, [JSON.stringify({
    slug: 'ruim3', name: 'Ruim', tamanho: 1, distribuicao: 'admin',
    slots: [{ odds: [{ tier: 'ouro-falso', weight: 100 }] }] })])
await deveFalhar('nao e admin, nao salva', B,
  `select public.admin_salvar_pacote($1::jsonb)`, [JSON.stringify({
    slug: 'ruim4', name: 'Ruim', tamanho: 1, distribuicao: 'admin',
    slots: [{ odds: [{ tier: 'comum', weight: 100 }] }] })])

// o piso de preco: um pacote de comuns a 1 baba se paga vendendo o conteudo
await deveFalhar('BLOQUEIA preco abaixo do piso', A,
  `select public.admin_salvar_pacote($1::jsonb)`, [JSON.stringify({
    slug: 'impressora', name: 'Impressora', tamanho: 4, distribuicao: 'loja',
    elegivel_loja: true, preco_baba: 1,
    slots: [1, 2, 3, 4].map((o) => ({ ordem: o, filtro: { tiers: ['epica'] },
      odds: [{ tier: 'epica', weight: 100 }] })) })])
await deveFalhar('pacote de loja sem preco tambem nao passa', A,
  `select public.admin_salvar_pacote($1::jsonb)`, [JSON.stringify({
    slug: 'sem-preco', name: 'Sem preco', tamanho: 1, distribuicao: 'loja',
    elegivel_loja: true,
    slots: [{ odds: [{ tier: 'comum', weight: 100 }] }] })])

// ================================================================ EV
console.log('\n== valor esperado dos tres da loja ==')
for (const slug of ['comum', 'raro', 'ultra']) {
  const id = await idDe(slug)
  const ev = (await como(A, `select public.admin_ev_pacote($1::int) as r`, [id])).r
  const acima = Number(ev.preco) >= Number(ev.piso)
  console.log(`   ${slug.padEnd(6)} EV ${String(ev.ev).padStart(8)}  piso ${String(ev.piso).padStart(6)}` +
              `  sugerido ${String(ev.sugerido).padStart(6)}  preco ${String(ev.preco).padStart(5)}` +
              `  margem ${ev.margem_pct}%  min ${ev.ev_minimo} max ${ev.ev_maximo} sd ${ev.desvio}`)
  // O que NAO pode acontecer e o preco ficar abaixo do EV: ai comprar e
  // vender o conteudo da lucro, e isso e uma impressora de baba. O piso
  // (EV x 1,5) e margem de seguranca em cima disso, nao o ponto de
  // equilibrio - um pacote entre EV e piso e caro o bastante para nao
  // imprimir, so nao tem folga.
  checar(`${slug}: preco acima do EV (nao imprime baba)`,
    Number(ev.preco) > Number(ev.ev), `${ev.preco} > ${ev.ev}`)
  if (!acima) console.log(`          (abaixo do piso de ${ev.piso}, mas sem lucro)`)
}

// ================================================================ preview
console.log('\n== preview nao grava nada ==')
{
  const id = await idDe('elementais')
  const antes = await um(`select
    (select count(*) from card_copies where owner_id is not null) as donos,
    (select count(*) from pack_openings) as aberturas,
    (select aberturas_realizadas from pack_definitions where id = $1) as conta`, [id])
  const p = (await como(A, `select public.admin_preview_pacote($1::int, 300) as r`, [id])).r
  const depois = await um(`select
    (select count(*) from card_copies where owner_id is not null) as donos,
    (select count(*) from pack_openings) as aberturas,
    (select aberturas_realizadas from pack_definitions where id = $1) as conta`, [id])
  checar('o preview simulou 300 aberturas', Number(p.aberturas) === 300)
  checar('e nao encostou no acervo',
    antes.donos === depois.donos && antes.aberturas === depois.aberturas
    && antes.conta === depois.conta,
    `${antes.donos}/${antes.aberturas}/${antes.conta} -> ${depois.donos}/${depois.aberturas}/${depois.conta}`)
  checar('preview de Elementais so mostra rara',
    p.por_tier.every((t) => t.tier === 'rara'), p.por_tier.map((t) => t.tier).join(','))
}

// ================================================================ viabilidade
console.log('\n== avisos do construtor ==')
{
  const r = (await como(A, `select public.admin_salvar_pacote($1::jsonb) as r`, [JSON.stringify({
    slug: 'impossivel', name: 'Impossivel', tamanho: 1, distribuicao: 'admin',
    slots: [{ ordem: 1, filtro: { characters: ['nao-existe'] },
              odds: [{ tier: 'comum', weight: 100 }] }] })])).r
  const av = r.viabilidade.avisos.map((a) => a.texto).join(' | ')
  checar('avisa filtro que nao casa com nada', /nao casa com nenhuma copia/.test(av), av.slice(0, 70))
}
{
  // Um slot 100% diamante: existem 6 no mundo inteiro, entao ele aguenta 6
  // aberturas. (O pedrao-comum-mais NAO dispara este aviso, e esta certo: o
  // amaciamento poe o prisma em 0,05%, o que da ~2000 aberturas.)
  const r = (await como(A, `select public.admin_salvar_pacote($1::jsonb) as r`, [JSON.stringify({
    slug: 'so-diamante', name: 'So Diamante', tamanho: 1, distribuicao: 'admin',
    slots: [{ ordem: 1, filtro: { tiers: ['diamante'] },
              odds: [{ tier: 'diamante', weight: 100 }] }] })])).r
  const av = r.viabilidade.avisos.map((a) => a.texto)
  checar('avisa tier que esgota em menos de 20 aberturas',
    av.some((t) => /esgota em/.test(t)), av.find((t) => /esgota em/.test(t))?.slice(0, 62) ?? 'nenhum')

  // e o pedrao-comum-mais nao dispara, porque de fato nao esgota rapido
  const v = (await como(A, `select public.admin_viabilidade_pacote($1::int) as r`,
    [await idDe('pedrao-comum-mais')])).r
  checar('Pedrao Comum+ nao dispara alarme falso de esgotamento',
    !v.avisos.some((a) => /esgota em/.test(a.texto)),
    `${v.avisos.length} avisos`)
}

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
await db.close()
process.exit(falhas === 0 ? 0 : 1)
