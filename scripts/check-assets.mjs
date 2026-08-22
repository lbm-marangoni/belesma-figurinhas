// Confere os assets contra o catalogo (spec secao 3).
//
// A lista de personagens e skins sai do proprio seed SQL - a mesma fonte de
// onde card_types e gerado - entao rodar isto nao exige banco no ar.
//
// Verifica:
//   - todo <personagem>/<skin>.jpg existe, com a extensao certa
//   - arquivos na pasta que nao batem com nenhum slug (acento, underscore,
//     extensao trocada, nome livre)
//   - selos e boosters tem canal alfa de verdade

import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { join, dirname, extname, basename } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const publico = join(raiz, 'public')
const seed = readFileSync(
  join(raiz, 'supabase', 'migrations', '20260821120100_seed.sql'),
  'utf8',
)

const bloco = (marcador) => {
  const i = seed.indexOf(marcador)
  if (i < 0) throw new Error(`nao achei o bloco ${marcador} no seed`)
  return seed.slice(i, seed.indexOf(';', i))
}

const personagens = [...bloco('insert into public.characters').matchAll(/\(\s*\d+,\s*'([a-z0-9-]+)'/g)]
  .map((m) => m[1])
const skins = [...bloco('insert into public.skins').matchAll(/\(\s*'([a-z0-9-]+)'\s*,\s*'[a-z]+'\s*,/g)]
  .map((m) => m[1])

console.log(`catalogo: ${personagens.length} personagens x ${skins.length} skins = ${personagens.length * skins.length} figurinhas\n`)

let problemas = 0
const aviso = (msg) => { console.log('  ' + msg); problemas++ }

// ---------------------------------------------------------------- figurinhas
const esperadas = new Set()
for (const p of personagens) for (const s of skins) esperadas.add(`${p}/${s}.jpg`)

for (const p of personagens) {
  const dir = join(publico, 'figurinhas', p)
  const faltando = []
  if (!existsSync(dir)) {
    console.log(`${p}: pasta public/figurinhas/${p}/ nao existe - faltam as ${skins.length}`)
    problemas += skins.length
    continue
  }
  const presentes = readdirSync(dir)
  for (const s of skins) if (!presentes.includes(`${s}.jpg`)) faltando.push(s)

  console.log(`${p}: ${skins.length - faltando.length}/${skins.length} presentes`)
  if (faltando.length) {
    console.log(`  faltam: ${faltando.join(' ')}`)
    problemas += faltando.length
  }

  for (const f of presentes) {
    if (esperadas.has(`${p}/${f}`)) continue
    const nome = basename(f, extname(f))
    const dica = skins.includes(nome)
      ? `extensao errada, tem que ser .jpg`
      : skins.includes(nome.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/_/g, '-'))
        ? `nome fora do padrao (acento ou underscore)`
        : `nao bate com nenhum slug conhecido`
    aviso(`sobrando: ${f} - ${dica}`)
  }
}

// ---------------------------------------------------------------- alfa
// Le o IHDR do PNG: byte 25 e o color type. 6 = RGBA, 4 = cinza+alfa,
// 3 = paleta (so tem alfa se existir um chunk tRNS).
function temAlfa(caminho) {
  const buf = readFileSync(caminho)
  if (buf.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') return { png: false }
  const tipo = buf[25]
  if (tipo === 6 || tipo === 4) return { png: true, alfa: true }
  if (tipo === 3) return { png: true, alfa: buf.includes(Buffer.from('tRNS')) }
  return { png: true, alfa: false }
}

console.log('')
for (const [pasta, arquivos] of [
  ['selos', ['selo-branco.png', 'selo-preto.png', 'selo-rosa.png']],
  ['packs', ['booster-comum.png', 'booster-raro.png', 'booster-ultra.png']],
]) {
  for (const nome of arquivos) {
    const caminho = join(publico, pasta, nome)
    if (!existsSync(caminho)) { aviso(`${pasta}/${nome}: nao existe`); continue }
    const r = temAlfa(caminho)
    if (!r.png) aviso(`${pasta}/${nome}: nao e PNG de verdade`)
    else if (!r.alfa) aviso(`${pasta}/${nome}: PNG SEM canal alfa - vai virar retangulo branco por cima da arte`)
    else console.log(`${pasta}/${nome}: ok, com alfa`)
  }
}

console.log(problemas === 0 ? '\nlimpo' : `\n${problemas} problema(s)`)
process.exit(problemas === 0 ? 0 : 1)
