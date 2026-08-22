import { useEffect, useRef, type RefObject } from 'react'

/**
 * Tilt por ponteiro ou giroscópio (spec §12).
 *
 * ARMADILHA que este código evita de propósito: nunca ler
 * getBoundingClientRect() do elemento que carrega o transform. Esse rect é a
 * caixa PROJETADA — e como o tilt sai dessa leitura, vira realimentação: a
 * carta treme sozinha e o ângulo foge.
 *
 * A receita correta: rect do PALCO (que não tem transform) + offsetWidth /
 * offsetHeight da figurinha (layout puro), derivando a escala de ancestrais
 * por rect.width / offsetWidth.
 *
 * O hook não mexe em estado do React: escreve direto em CSS custom
 * properties. Um re-render por movimento de mouse seria desperdício.
 */
export function useTilt(
  palco: RefObject<HTMLElement | null>,
  carta: RefObject<HTMLElement | null>,
  ativo: boolean,
  maxGraus = 12,
) {
  const solto = useRef(false)

  useEffect(() => {
    const p = palco.current
    const c = carta.current
    if (!ativo || !p || !c) return

    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return

    const escrever = (rx: number, ry: number, px: number, py: number) => {
      p.style.setProperty('--rx', `${rx.toFixed(2)}deg`)
      p.style.setProperty('--ry', `${ry.toFixed(2)}deg`)
      p.style.setProperty('--px', `${px.toFixed(1)}%`)
      p.style.setProperty('--py', `${py.toFixed(1)}%`)
    }

    const mover = (ev: PointerEvent) => {
      const rect = p.getBoundingClientRect()       // palco: sem transform, seguro
      const lw = c.offsetWidth, lh = c.offsetHeight // layout puro da figurinha
      if (!lw || !lh) return

      // escala acumulada dos ancestrais (zoom, transform de container, etc.)
      const escala = rect.width / lw || 1

      const x = (ev.clientX - rect.left) / escala
      const y = (ev.clientY - rect.top) / escala

      const nx = Math.min(1, Math.max(0, x / lw))
      const ny = Math.min(1, Math.max(0, y / lh))

      if (solto.current) { c.classList.remove('solta'); solto.current = false }
      escrever((0.5 - ny) * 2 * maxGraus, (nx - 0.5) * 2 * maxGraus, nx * 100, ny * 100)
    }

    const sair = () => {
      c.classList.add('solta'); solto.current = true
      escrever(0, 0, 50, 50)
    }

    // giroscópio: beta = frente/trás, gamma = esquerda/direita
    const girar = (ev: DeviceOrientationEvent) => {
      if (ev.beta == null || ev.gamma == null) return
      const rx = Math.max(-maxGraus, Math.min(maxGraus, (ev.beta - 45) / 3))
      const ry = Math.max(-maxGraus, Math.min(maxGraus, ev.gamma / 3))
      escrever(rx, ry, 50 + (ry / maxGraus) * 40, 50 - (rx / maxGraus) * 40)
    }

    p.addEventListener('pointermove', mover)
    p.addEventListener('pointerleave', sair)
    window.addEventListener('deviceorientation', girar)
    return () => {
      p.removeEventListener('pointermove', mover)
      p.removeEventListener('pointerleave', sair)
      window.removeEventListener('deviceorientation', girar)
    }
  }, [palco, carta, ativo, maxGraus])
}

/** iOS 13+ exige gesto do usuário para liberar o giroscópio. */
export const giroscopioPrecisaDePermissao = () =>
  typeof (DeviceOrientationEvent as any)?.requestPermission === 'function'

export async function pedirGiroscopio() {
  try { return (await (DeviceOrientationEvent as any).requestPermission()) === 'granted' }
  catch { return false }
}
