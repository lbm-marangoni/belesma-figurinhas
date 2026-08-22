import type { Carta } from './tipos'

/**
 * Export para WhatsApp (spec §14): WebP 512x512 composto no cliente.
 *
 * O ponto crítico é o SELO. Ele é um PNG com canal alfa; se o canvas for
 * composto sem respeitar o alfa, a figurinha exportada sai com um retângulo
 * branco no canto — é o item 20 do teste de aceitação. `drawImage` respeita o
 * alfa desde que o PNG tenha canal alfa de verdade e o contexto não tenha
 * sido preenchido por baixo do selo.
 */

const LADO = 512

function carregar(src: string): Promise<HTMLImageElement> {
  return new Promise((ok, erro) => {
    const img = new Image()
    img.crossOrigin = 'anonymous'
    img.onload = () => ok(img)
    img.onerror = () => erro(new Error(`não consegui carregar ${src}`))
    img.src = src
  })
}

export function rodapeDe(carta: Carta, apelido: string) {
  const serial = carta.origin === 'forge'
    ? `FORJADA ${String(carta.forge_index ?? 0).padStart(2, '0')}`
    : `${String(carta.serial_number).padStart(String(carta.print_run).length, '0')}/${carta.print_run}`
  return `${apelido.toUpperCase()} · ${serial}`
}

export async function exportarFigurinha(carta: Carta, apelido: string): Promise<Blob> {
  const base = import.meta.env.BASE_URL
  const cv = document.createElement('canvas')
  cv.width = LADO; cv.height = LADO
  const ctx = cv.getContext('2d')!
  ctx.imageSmoothingQuality = 'high'

  // 1. a arte
  try {
    const arte = await carregar(`${base}figurinhas/${carta.character_slug}/${carta.skin}.jpg`)
    ctx.drawImage(arte, 0, 0, LADO, LADO)
  } catch {
    ctx.fillStyle = '#1c1c1e'; ctx.fillRect(0, 0, LADO, LADO)
    ctx.fillStyle = '#8a8a92'; ctx.font = '600 26px sans-serif'
    ctx.textAlign = 'center'
    ctx.fillText(`${carta.character_slug}/${carta.skin}`, LADO / 2, LADO / 2)
  }

  // 2. o selo, em diagonal no canto superior direito, COM alfa
  if (carta.seal !== 'none') {
    const selo = await carregar(`${base}selos/selo-${carta.seal}.png`)
    const w = LADO * 0.26
    const h = w * (selo.height / selo.width)
    ctx.save()
    ctx.translate(LADO - w * 0.62, h * 0.62)
    ctx.rotate((20 * Math.PI) / 180)
    // nada de fillRect por baixo: seria exatamente o retangulo branco que a
    // spec manda evitar
    ctx.drawImage(selo, -w / 2, -h / 2, w, h)
    ctx.restore()
  }

  // 3. rodapé discreto com apelido e serial
  const alturaRodape = 62
  const g = ctx.createLinearGradient(0, LADO - alturaRodape, 0, LADO)
  g.addColorStop(0, 'rgba(0,0,0,0)')
  g.addColorStop(1, 'rgba(0,0,0,0.82)')
  ctx.fillStyle = g
  ctx.fillRect(0, LADO - alturaRodape, LADO, alturaRodape)

  ctx.fillStyle = '#f2f2f2'
  ctx.font = '700 22px ui-sans-serif, system-ui, sans-serif'
  ctx.textAlign = 'left'
  ctx.textBaseline = 'alphabetic'
  ctx.fillText(rodapeDe(carta, apelido), 16, LADO - 20)

  // 4. código curto de verificação no canto
  ctx.fillStyle = 'rgba(255,255,255,.62)'
  ctx.font = '600 15px ui-monospace, monospace'
  ctx.textAlign = 'right'
  ctx.fillText(carta.verify_code, LADO - 16, LADO - 20)

  return new Promise((ok, erro) =>
    cv.toBlob((b) => (b ? ok(b) : erro(new Error('canvas não gerou o arquivo'))), 'image/webp', 0.92))
}

export async function baixarFigurinha(carta: Carta, apelido: string) {
  const blob = await exportarFigurinha(carta, apelido)
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `belesma-${carta.character_slug}-${carta.skin}-${carta.verify_code}.webp`
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
