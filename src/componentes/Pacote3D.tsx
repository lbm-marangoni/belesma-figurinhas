import { useEffect, useMemo, useRef, useState } from 'react'
import { Figurinha } from './Figurinha'
import type { Carta, TipoPacote } from '../lib/tipos'
import '../styles/pacote.css'

/**
 * Pacote como objeto 3D (spec §13) — não é uma imagem balançando.
 *
 * As cartas JÁ FORAM sorteadas e gravadas pelo open_pack antes desta
 * animação começar. Fechar a aba no meio não perde nada: isto aqui é só
 * apresentação.
 *
 * Cada etapa é cancelável com um clique.
 */

type Etapa = 'idle' | 'tremor' | 'rasgando' | 'saindo' | 'final'

/** Linha de rasgo irregular logo abaixo do lacre. Sorteada a cada abertura —
 *  duas aberturas nunca rasgam igual. */
function linhaDeRasgo() {
  const base = 26                                  // % da altura, abaixo do lacre
  const pontos: [number, number][] = []
  for (let x = 0; x <= 100; x += 100 / 14) {
    pontos.push([x, base + (Math.random() - 0.5) * 4.4])
  }
  const linha = pontos.map(([x, y]) => `${x.toFixed(1)}% ${y.toFixed(2)}%`)
  return {
    cima: `polygon(0% 0%, 100% 0%, ${[...linha].reverse().join(', ')}, 0% 0%)`,
    baixo: `polygon(${linha.join(', ')}, 100% 100%, 0% 100%)`,
    y: base,
  }
}

export function Pacote3D({
  tipo, cartas, quente, aoTerminar,
}: {
  tipo: TipoPacote
  cartas: Carta[]
  quente: boolean
  aoTerminar: () => void
}) {
  const [etapa, setEtapa] = useState<Etapa>('idle')
  const [foils, setFoils] = useState<React.CSSProperties[]>([])
  const cena = useRef<HTMLDivElement>(null)
  const rasgo = useMemo(linhaDeRasgo, [])

  const reduzido = typeof window !== 'undefined' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches

  // Tilt do pacote: mesma regra da §12 — rect da CENA, que não tem transform.
  useEffect(() => {
    const c = cena.current
    if (!c || reduzido) return
    const mover = (e: PointerEvent) => {
      const r = c.getBoundingClientRect()
      const nx = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width))
      const ny = Math.min(1, Math.max(0, (e.clientY - r.top) / r.height))
      c.style.setProperty('--rx', `${((0.5 - ny) * 22).toFixed(1)}deg`)
      c.style.setProperty('--ry', `${((nx - 0.5) * 30).toFixed(1)}deg`)
      c.style.setProperty('--px', `${(nx * 100).toFixed(1)}%`)
      c.style.setProperty('--py', `${(ny * 100).toFixed(1)}%`)
    }
    const sair = () => {
      c.style.setProperty('--rx', '0deg'); c.style.setProperty('--ry', '0deg')
      c.style.setProperty('--px', '50%');  c.style.setProperty('--py', '50%')
    }
    c.addEventListener('pointermove', mover)
    c.addEventListener('pointerleave', sair)
    return () => { c.removeEventListener('pointermove', mover); c.removeEventListener('pointerleave', sair) }
  }, [reduzido])

  // sequência
  useEffect(() => {
    if (reduzido) { setEtapa('final'); return }
    if (etapa !== 'tremor') return
    const t1 = setTimeout(() => {
      // sorteados UMA vez: se ficassem inline no style, cada re-render
      // reposicionaria as particulas no meio do voo
      setFoils([...Array(18)].map((_, i) => ({
        left: `${8 + Math.random() * 84}%`,
        top: `${rasgo.y}%`,
        background: ['#e8e2c8', '#c9d6e8', '#f0d9a8', '#ffffff'][i % 4],
        animationDelay: `${Math.random() * 160}ms`,
        ['--dx' as string]: `${(Math.random() - 0.5) * 220}px`,
        ['--dy' as string]: `${-40 - Math.random() * 130}px`,
        ['--giro' as string]: `${(Math.random() - 0.5) * 720}deg`,
      } as React.CSSProperties)))
      setEtapa('rasgando')
    }, 900)
    return () => clearTimeout(t1)
  }, [etapa, reduzido, rasgo.y])

  useEffect(() => {
    if (etapa === 'rasgando') {
      const t = setTimeout(() => setEtapa('saindo'), 700)
      return () => clearTimeout(t)
    }
    if (etapa === 'saindo') {
      const t = setTimeout(() => setEtapa('final'), 300 + cartas.length * 260)
      return () => clearTimeout(t)
    }
  }, [etapa, cartas.length])

  useEffect(() => { if (etapa === 'final') aoTerminar() }, [etapa, aoTerminar])

  // um clique pula a etapa atual (spec §13)
  const pular = () => {
    if (etapa === 'idle') setEtapa('tremor')
    else setEtapa('final')
  }

  if (etapa === 'final') return null

  const arte = `${import.meta.env.BASE_URL}packs/booster-${tipo}.png`
  const rasgado = etapa === 'rasgando' || etapa === 'saindo'

  return (
    <div className="select-none py-4 text-center">
      <div
        ref={cena}
        className="cena cursor-pointer"
        onClick={pular}
        style={{ ['--corte-cima' as string]: rasgo.cima, ['--corte-baixo' as string]: rasgo.baixo }}
      >
        {/* cartas emergindo de dentro: janela termina na linha da boca, então
            a figurinha some atrás da borda frontal sem clip-path móvel */}
        {etapa === 'saindo' && (
          <div className="janela" style={{ height: `${rasgo.y + 2}%` }}>
            {cartas.map((c, i) => (
              <div key={c.copy_id} className="subindo"
                   style={{ animationDelay: `${i * 260}ms`, zIndex: cartas.length - i }}>
                <Figurinha carta={c} tamanho="media" shader />
              </div>
            ))}
          </div>
        )}

        <div
          className={[
            'pacote',
            etapa === 'idle' ? 'idle' : '',
            etapa === 'tremor' ? 'tremendo' : '',
            quente ? 'quente' : '',
          ].join(' ')}
        >
          {!rasgado ? (
            <Corpo arte={arte} />
          ) : (
            <>
              <div className="metade metade-cima"><Corpo arte={arte} /></div>
              <div className="metade metade-baixo"><Corpo arte={arte} /></div>
              <div className="boca" />
            </>
          )}
        </div>

        {/* partículas de foil saindo do ponto do rasgo */}
        {foils.map((estilo, i) => <span key={i} className="foil" style={estilo} />)}
      </div>

      <p className="mt-4 text-xs text-neutral-500">
        {etapa === 'idle' ? 'clique no pacote para abrir' : 'clique para pular'}
      </p>
    </div>
  )
}

/** Volume real: frente, verso espelhado e escurecido, e as quatro laterais. */
const Corpo = ({ arte }: { arte: string }) => (
  <>
    <div className="face face-frente">
      <img src={arte} alt="" draggable={false} />
      <span className="mylar" />
    </div>
    <div className="face face-verso"><img src={arte} alt="" draggable={false} /></div>
    <div className="lado lado-esq" />
    <div className="lado lado-dir" />
    <div className="lado lado-topo" />
    <div className="lado lado-base" />
  </>
)
