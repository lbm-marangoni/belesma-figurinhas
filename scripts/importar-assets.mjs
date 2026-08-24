// Importa os assets de "../belesma new" para public/, no padrao da spec secao 3.
//
//   figurinhas  <qualquer nome>_2K_<data>.jpeg  ->  public/figurinhas/<char>/<skin>.jpg
//   selos       selo-<cor>_2K_<data>.jpeg       ->  public/selos/selo-<cor>.png  COM ALFA
//   boosters    ../belesma-packs-png/packs/*.png -> public/packs/
//
// Os selos chegaram como JPEG com o xadrez de transparencia ACHATADO EM PIXEL.
// JPEG nao tem canal alfa, entao o alfa e reconstruido por flood fill a partir
// da borda. Ver reconstruirAlfa() para o porque de cada decisao.

import sharp from 'sharp'
import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const colecao = join(raiz, '..')
const origem = join(colecao, 'belesma new')
const publico = join(raiz, 'public')

const QUALIDADE = 85   // os originais vem em ~3 MB (q95+); 85 corta ~5x sem doer

// ---------------------------------------------------------------- catalogo
const seed = readFileSync(join(raiz, 'supabase/migrations/20260821120100_seed.sql'), 'utf8')
const bloco = (m) => seed.slice(seed.indexOf(m), seed.indexOf(';', seed.indexOf(m)))
const skins = [...bloco('insert into public.skins').matchAll(/\(\s*'([a-z0-9-]+)'\s*,\s*'[a-z]+'\s*,/g)].map((m) => m[1])
// Os personagens saem das PASTAS, nao do seed.
//
// Sair do seed obrigava a editar SQL antes de importar arte, e a ordem certa
// e a inversa: a arte chega primeiro, o seed vem depois. Agora basta existir
// uma pasta "belesma <slug>" com as 27 skins.
const personagens = readdirSync(origem, { withFileTypes: true })
  .filter((e) => e.isDirectory() && /^belesma /.test(e.name))
  .map((e) => e.name.replace(/^belesma /, '').trim().toLowerCase())
  .sort()

// Os arquivos vieram com nome livre e alguns com erro de digitacao:
//   belesma_pedrao_base -> original     pedra-noite  -> pedrao/noite
//   pedro-ruby -> pedrao/rubi           santa-vento  -> santao/vento
//   sapphire -> safira                  ruby         -> rubi
//   infernal -> inferno                obisidana / obisidiana -> obsidiana
const APELIDOS = {
  base: 'original', ruby: 'rubi', sapphire: 'safira',
  infernal: 'inferno', obisidana: 'obsidiana', obisidiana: 'obsidiana',
}
const alvos = [...skins, ...Object.keys(APELIDOS)]

// Casa pelo SUFIXO mais longo: assim "aura-branca" ganha de "branca" e
// "pedra-noite" cai certo em "noite".
function skinDoArquivo(nome) {
  const limpo = nome.replace(/_2K_\d+\.(jpe?g|png)$/i, '').toLowerCase()
  let melhor = null
  for (const a of alvos) {
    if (limpo.endsWith(a) && (!melhor || a.length > melhor.length)) melhor = a
  }
  return melhor ? (APELIDOS[melhor] ?? melhor) : null
}

// ---------------------------------------------------------------- alfa do selo
// O fundo e um xadrez de transparencia de duas tonalidades neutras, com sombra
// projetada do selo por cima. Estrategia:
//
//   1. amostra a borda para descobrir as duas tonalidades do xadrez
//   2. flood fill a partir das quatro bordas, aceitando so pixel NEUTRO
//      (saturacao baixa) e de luminancia proxima de uma das tonalidades
//   3. o flood fill e o que salva o selo: cinza igual ao xadrez que esteja
//      DENTRO do selo nao encosta na borda, entao nunca vira transparencia
//   4. feather de 1px na fronteira para nao serrilhar
function reconstruirAlfa(data, w, h, canais) {
  const lum = (i) => (data[i] * 299 + data[i + 1] * 587 + data[i + 2] * 114) / 1000
  const neutro = (i) => {
    const r = data[i], g = data[i + 1], b = data[i + 2]
    return Math.max(r, g, b) - Math.min(r, g, b) < 30
  }

  // 1. tonalidades do xadrez, pela borda
  const amostras = []
  for (let x = 0; x < w; x += 4) {
    amostras.push(lum((0 * w + x) * canais), lum(((h - 1) * w + x) * canais))
  }
  for (let y = 0; y < h; y += 4) {
    amostras.push(lum((y * w + 0) * canais), lum((y * w + (w - 1)) * canais))
  }
  amostras.sort((a, b) => a - b)
  const tomA = amostras[Math.floor(amostras.length * 0.15)]
  const tomB = amostras[Math.floor(amostras.length * 0.85)]

  // Tolerancia generosa para engolir a sombra projetada e o ruido do JPEG,
  // mas ainda dentro da faixa entre as duas tonalidades.
  const folga = Math.max(34, Math.abs(tomB - tomA) * 0.7)
  const ehFundo = (i) => {
    if (!neutro(i)) return false
    const l = lum(i)
    return Math.abs(l - tomA) <= folga || Math.abs(l - tomB) <= folga
  }

  // 2. flood fill a partir da borda
  const fundo = new Uint8Array(w * h)
  const fila = new Int32Array(w * h)
  let cabeca = 0, cauda = 0
  const empilhar = (p) => {
    if (fundo[p]) return
    if (!ehFundo(p * canais)) return
    fundo[p] = 1
    fila[cauda++] = p
  }
  for (let x = 0; x < w; x++) { empilhar(x); empilhar((h - 1) * w + x) }
  for (let y = 0; y < h; y++) { empilhar(y * w); empilhar(y * w + w - 1) }
  while (cabeca < cauda) {
    const p = fila[cabeca++]
    const x = p % w, y = (p / w) | 0
    if (x > 0)     empilhar(p - 1)
    if (x < w - 1) empilhar(p + 1)
    if (y > 0)     empilhar(p - w)
    if (y < h - 1) empilhar(p + w)
  }

  // 3/4. alfa + feather de 1px
  const alfa = Buffer.alloc(w * h)
  for (let p = 0; p < w * h; p++) alfa[p] = fundo[p] ? 0 : 255
  const suave = Buffer.from(alfa)
  for (let y = 1; y < h - 1; y++) {
    for (let x = 1; x < w - 1; x++) {
      const p = y * w + x
      if (alfa[p] !== 255) continue
      const viz = (alfa[p - 1] === 0) + (alfa[p + 1] === 0) + (alfa[p - w] === 0) + (alfa[p + w] === 0)
      if (viz > 0) suave[p] = 255 - viz * 48
    }
  }
  return { alfa: suave, cobertura: 1 - fundo.reduce((a, b) => a + b, 0) / (w * h) }
}

// ================================================================ execucao
let erros = 0
console.log(`catalogo: ${personagens.length} personagens x ${skins.length} skins\n`)

// ---------------------------------------------------------------- figurinhas
for (const p of personagens) {
  const dir = join(origem, `belesma ${p}`)
  if (!existsSync(dir)) { console.log(`${p}: pasta "${dir}" nao existe`); erros++; continue }

  const destino = join(publico, 'figurinhas', p)
  mkdirSync(destino, { recursive: true })

  const vistos = new Map()
  for (const f of readdirSync(dir)) {
    const skin = skinDoArquivo(f)
    if (!skin) { console.log(`  ${p}: NAO MAPEADO -> ${f}`); erros++; continue }
    if (vistos.has(skin)) { console.log(`  ${p}: ${skin} duplicado (${f} e ${vistos.get(skin)})`); erros++; continue }
    vistos.set(skin, f)
  }

  let bytesAntes = 0, bytesDepois = 0
  for (const [skin, f] of vistos) {
    const de = join(dir, f), para = join(destino, `${skin}.jpg`)
    const img = sharp(de)
    const m = await img.metadata()
    if (m.width !== 2048 || m.height !== 2048) {
      console.log(`  ${p}/${skin}: ${m.width}x${m.height}, reenquadrando para 2048x2048`)
    }
    await img
      .resize(2048, 2048, { fit: 'cover', position: 'centre' })
      .jpeg({ quality: QUALIDADE, mozjpeg: true, chromaSubsampling: '4:4:4' })
      .toFile(para)

    // ------------------------------------------------------------ pequena
    // A miniatura do album e da colecao renderiza com ~86px de largura, e
    // baixar 910 KB de 2048x2048 para isso e absurdo: uma pagina do album
    // mostra dezenas delas de uma vez. Com seis personagens sao 162 artes e
    // 144 MB no bundle.
    //
    // 512 e folgado ate em tela retina, e custa ~15x menos.
    const dirP = join(destino, 'p')
    mkdirSync(dirP, { recursive: true })
    await sharp(de)
      .resize(512, 512, { fit: 'cover', position: 'centre' })
      .jpeg({ quality: 78, mozjpeg: true })
      .toFile(join(dirP, `${skin}.jpg`))
    bytesAntes += statSync(de).size
    bytesDepois += statSync(para).size
  }

  const faltando = skins.filter((s) => !vistos.has(s))
  const mb = (b) => (b / 1048576).toFixed(1)
  console.log(`${p}: ${vistos.size}/${skins.length} importadas  ${mb(bytesAntes)} MB -> ${mb(bytesDepois)} MB`)
  if (faltando.length) { console.log(`  faltam: ${faltando.join(' ')}`); erros += faltando.length }
}

// ---------------------------------------------------------------- selos
console.log('')
mkdirSync(join(publico, 'selos'), { recursive: true })
for (const cor of ['branco', 'preto', 'rosa']) {
  const achado = readdirSync(origem).find((f) => f.startsWith(`selo-${cor}`))
  if (!achado) { console.log(`selo-${cor}: nao achei o arquivo de origem`); erros++; continue }

  const de = join(origem, achado)
  const { data, info } = await sharp(de).raw().toBuffer({ resolveWithObject: true })
  const { alfa, cobertura } = reconstruirAlfa(data, info.width, info.height, info.channels)

  const rgba = Buffer.alloc(info.width * info.height * 4)
  for (let p = 0; p < info.width * info.height; p++) {
    const o = p * info.channels
    rgba[p * 4] = data[o]; rgba[p * 4 + 1] = data[o + 1]; rgba[p * 4 + 2] = data[o + 2]
    rgba[p * 4 + 3] = alfa[p]
  }

  const para = join(publico, 'selos', `selo-${cor}.png`)
  await sharp(rgba, { raw: { width: info.width, height: info.height, channels: 4 } })
    .trim({ threshold: 1 })                     // corta a moldura vazia que sobrou
    .resize(1024, 1024, { fit: 'inside', withoutEnlargement: true })
    .png({ compressionLevel: 9 })
    .toFile(para)

  const m = await sharp(para).metadata()
  console.log(`selo-${cor}.png: ${m.width}x${m.height} alfa=${m.hasAlpha} ` +
              `cobertura ${(cobertura * 100).toFixed(1)}% ${(statSync(para).size / 1024 | 0)} KB`)
  if (cobertura > 0.7) { console.log(`  ATENCAO: quase nada virou transparente - o key falhou`); erros++ }
}

// ---------------------------------------------------------------- boosters
console.log('')
mkdirSync(join(publico, 'packs'), { recursive: true })
const dirPacks = join(colecao, 'belesma-packs-png', 'packs')
for (const tipo of ['comum', 'raro', 'ultra']) {
  const de = join(dirPacks, `booster-${tipo}.png`)
  if (!existsSync(de)) { console.log(`booster-${tipo}: nao achei em ${dirPacks}`); erros++; continue }
  const para = join(publico, 'packs', `booster-${tipo}.png`)
  await sharp(de).png({ compressionLevel: 9, quality: 90 }).toFile(para)
  const m = await sharp(para).metadata()
  console.log(`booster-${tipo}.png: ${m.width}x${m.height} alfa=${m.hasAlpha} ${(statSync(para).size / 1024 | 0)} KB`)
  if (!m.hasAlpha) erros++
}

console.log(erros === 0 ? '\nimportado sem erro' : `\n${erros} problema(s)`)
process.exit(erros === 0 ? 0 : 1)
