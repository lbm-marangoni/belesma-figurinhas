// Varredura estatica do repositorio: as classes de erro que ja nos morderam.
//
//   node scripts/verificar-estatico.mjs
//
// Nao roda nada, nao conecta em nada. So le os arquivos e procura padroes
// que ja causaram bug de verdade neste projeto. Cada verificacao existe
// porque algo quebrou, e o comentario diz o que foi.

import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const rel = (p) => relative(raiz, p).split('\\').join('/')

function arquivos(dir, filtro, acc = []) {
  if (!existsSync(dir)) return acc
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) arquivos(p, filtro, acc)
    else if (filtro(e.name)) acc.push(p)
  }
  return acc
}

let falhas = 0
const checar = (nome, ok, detalhe) => {
  console.log(`  ${ok ? 'PASS ' : 'FALHA'}  ${nome}${detalhe ? ' -> ' + detalhe : ''}`)
  if (!ok) falhas++
}

const css = arquivos(join(raiz, 'src'), (n) => n.endsWith('.css'))
const codigo = arquivos(join(raiz, 'src'), (n) => /\.(ts|tsx)$/.test(n))
const sqls = arquivos(join(raiz, 'supabase', 'migrations'), (n) => n.endsWith('.sql'))
const semComentario = (s) => s.replace(/\/\*[\s\S]*?\*\//g, ' ')

// ============================================================ 1. classe em 2 arquivos
//
// O `.folha` da gaveta do celular colidiu com o `.folha` que gira na lombada
// do album: a folha do album virou uma laje cinza no desktop e o botao "Mais"
// nasceu invisivel no celular. CSS de componente e global; arquivo separado
// nao isola nada.
//
// So conta a regra BASE (fora de @media). Base num arquivo + override
// responsivo em outro e padrao legitimo e nao deve reprovar.
{
  const donos = new Map()
  for (const f of css) {
    let s = semComentario(readFileSync(f, 'utf8'))
    // remove o corpo de cada @media para sobrarem so as regras base
    let fora = '', prof = 0, i = 0
    while (i < s.length) {
      if (s.startsWith('@media', i)) {
        const abre = s.indexOf('{', i)
        if (abre === -1) break
        prof = 1; i = abre + 1
        while (i < s.length && prof > 0) {
          if (s[i] === '{') prof++
          else if (s[i] === '}') prof--
          i++
        }
        continue
      }
      fora += s[i]; i++
    }
    // o seletor e o que vem antes de cada `{`
    for (const m of fora.matchAll(/([^{}]+)\{[^{}]*\}/g)) {
      for (const c of m[1].matchAll(/(?<![\w-])\.([a-zA-Z][\w-]*)/g)) {
        if (!donos.has(c[1])) donos.set(c[1], new Set())
        donos.get(c[1]).add(rel(f))
      }
    }
  }
  const ruins = [...donos].filter(([, v]) => v.size > 1)
  checar('nenhuma classe CSS com regra base em dois arquivos', ruins.length === 0,
    ruins.map(([k, v]) => `.${k} (${[...v].join(' + ')})`).join('; '))
}

// ============================================================ 2. keyframes
// Mesma historia do `.folha`, so que pior: um @keyframes duplicado troca a
// animacao inteira sem nenhum aviso.
{
  const kf = new Map()
  for (const f of css) {
    for (const m of semComentario(readFileSync(f, 'utf8')).matchAll(/@keyframes\s+([\w-]+)/g)) {
      if (!kf.has(m[1])) kf.set(m[1], new Set())
      kf.get(m[1]).add(rel(f))
    }
  }
  const ruins = [...kf].filter(([, v]) => v.size > 1)
  checar('nenhum @keyframes com o mesmo nome em dois arquivos', ruins.length === 0,
    ruins.map(([k, v]) => `${k} (${[...v].join(' + ')})`).join('; '))
}

// ============================================================ 3. RPC fantasma
// Chamar uma RPC que nao existe da 404 em runtime e passa por todo o
// typecheck: o nome e uma string.
{
  const definidas = new Set()
  for (const f of sqls) {
    for (const m of readFileSync(f, 'utf8')
      .matchAll(/create\s+(?:or\s+replace\s+)?function\s+public\.([a-z_0-9]+)/gi)) {
      definidas.add(m[1])
    }
  }
  const faltando = []
  for (const f of codigo) {
    for (const m of readFileSync(f, 'utf8').matchAll(/\.rpc\(\s*['"]([a-z_0-9]+)['"]/g)) {
      if (!definidas.has(m[1])) faltando.push(`${m[1]} (${rel(f)})`)
    }
  }
  checar('toda RPC chamada pelo front existe no SQL', faltando.length === 0,
    [...new Set(faltando)].join(', '))
}

// ============================================================ 4. search_path
// pgcrypto e citext vivem no schema `extensions` no Supabase, nao em public.
// Um security definer sem `extensions` no search_path acha gen_random_bytes
// no PGlite e quebra na producao.
{
  const ruins = []
  for (const f of sqls) {
    const s = readFileSync(f, 'utf8')
    for (const m of s.matchAll(
      /create\s+(?:or\s+replace\s+)?function\s+([a-z_]+\.[a-z_0-9]+)([\s\S]*?)\bas\s*\$/gi)) {
      const cab = m[2]
      if (!/security\s+definer/i.test(cab)) continue
      const sp = /set\s+search_path\s*=\s*([^\n]+)/i.exec(cab)
      if (!sp) ruins.push(`${m[1]}: sem search_path (${rel(f)})`)
      else if (!sp[1].includes('extensions')) ruins.push(`${m[1]}: search_path sem extensions (${rel(f)})`)
    }
  }
  checar('todo security definer fixa search_path com extensions', ruins.length === 0,
    ruins.join('; '))
}

// ============================================================ 5. random()
// random() do Postgres e previsivel depois de setseed(), que o cliente pode
// disparar. Sorteio so com gen_random_bytes (spec §6).
{
  const ruins = []
  for (const f of sqls) {
    readFileSync(f, 'utf8').split('\n').forEach((linha, i) => {
      if (/(?<![\w.])random\s*\(\s*\)/.test(linha.replace(/--.*/, ''))) {
        ruins.push(`${rel(f)}:${i + 1}`)
      }
    })
  }
  checar('nenhum random() do Postgres no SQL (so CSPRNG)', ruins.length === 0, ruins.join(', '))
}

// ============================================================ 6. marcadores
// TODO/FIXME de verdade tem dois-pontos. Sem isso, "entregava TODO gesto de
// toque" em portugues virava achado.
{
  const ruins = []
  for (const f of [...codigo, ...css, ...arquivos(join(raiz, 'scripts'), (n) => n.endsWith('.mjs'))]) {
    readFileSync(f, 'utf8').split('\n').forEach((linha, i) => {
      if (/\b(TODO|FIXME|XXX|HACK)\s*[:(]/.test(linha)) ruins.push(`${rel(f)}:${i + 1}`)
    })
  }
  checar('nenhum TODO/FIXME pendente', ruins.length === 0, ruins.join(', '))
}

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
process.exit(falhas === 0 ? 0 : 1)
