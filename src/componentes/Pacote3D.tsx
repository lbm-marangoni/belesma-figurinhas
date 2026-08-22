import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Figurinha } from './Figurinha'
import { auraDaCarta } from '../lib/aura'
import type { Carta, TipoPacote } from '../lib/tipos'
import '../styles/pacote.css'

/**
 * Pacote como objeto 3D (spec §13) — não é uma imagem balançando.
 *
 * As cartas JÁ FORAM sorteadas e gravadas pelo open_pack antes desta
 * animação começar. Fechar a aba no meio não perde nada: isto é só
 * apresentação.
 *
 * A revelação é UMA CARTA POR VEZ, puxada pelo jogador. Ela vai aparecendo
 * conforme sai da boca do pacote — quem controla o ritmo é a mão, não um
 * timer.
 */

type Etapa = 'idle' | 'tremor' | 'rasgando' | 'puxando' | 'final'

/** Quanto da carta fica espiando para fora enquanto ninguém puxa. É o que
 *  faz o jogador enxergar que tem algo ali e saber onde pegar. */
const REPOUSO = 0.17

/** Linha de rasgo irregular logo abaixo do lacre, sorteada a cada abertura. */
function linhaDeRasgo() {
  const base = 24
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
  const [indice, setIndice] = useState(0)
  const [puxada, setPuxada] = useState(REPOUSO)         // 0..1 da carta atual
  const [transicao, setTransicao] = useState<'' | 'assentando' | 'saindo'>('')
  const [reveladas, setReveladas] = useState<Carta[]>([])
  const [faiscas, setFaiscas] = useState<React.CSSProperties[]>([])

  const cena = useRef<HTMLDivElement>(null)
  const arrasto = useRef<{ y0: number; alcance: number; moveu: boolean } | null>(null)
  const rasgo = useMemo(linhaDeRasgo, [])

  const reduzido = typeof window !== 'undefined' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches

  const arte = `${import.meta.env.BASE_URL}packs/booster-${tipo}.png`

  // Pré-carrega as artes do pacote inteiro assim que ele abre.
  //
  // Sem isto, trocar de carta mostrava a ANTERIOR por um instante: o <img>
  // novo só troca de pixel quando o arquivo termina de baixar, e as artes
  // têm ~300 KB. A key acima força o remount; o preload garante que o
  // arquivo já esteja em cache quando o remount acontece.
  useEffect(() => {
    for (const c of cartas) {
      const img = new Image()
      img.src = `${import.meta.env.BASE_URL}figurinhas/${c.character_slug}/${c.skin}.jpg`
    }
  }, [cartas])

  // Tilt do pacote: rect da CENA, que não carrega transform (spec §12).
  useEffect(() => {
    const c = cena.current
    if (!c || reduzido || etapa === 'puxando') return
    const mover = (e: PointerEvent) => {
      const r = c.getBoundingClientRect()
      const nx = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width))
      const ny = Math.min(1, Math.max(0, (e.clientY - r.top) / r.height))
      c.style.setProperty('--rx', `${((0.5 - ny) * 20).toFixed(1)}deg`)
      c.style.setProperty('--ry', `${((nx - 0.5) * 28).toFixed(1)}deg`)
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
  }, [reduzido, etapa])

  // enquanto puxa, o pacote fica parado de frente: girar atrapalha a mira
  useEffect(() => {
    if (etapa !== 'puxando') return
    const c = cena.current
    c?.style.setProperty('--rx', '0deg')
    c?.style.setProperty('--ry', '0deg')
  }, [etapa])

  // ------------------------------------------------------------- sequência
  useEffect(() => {
    if (reduzido) { setReveladas(cartas); setEtapa('final') }
  }, [reduzido, cartas])

  useEffect(() => {
    if (etapa !== 'tremor') return
    const t = setTimeout(() => {
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
    return () => clearTimeout(t)
  }, [etapa, rasgo.y])

  useEffect(() => {
    if (etapa !== 'rasgando') return
    const t = setTimeout(() => setEtapa('puxando'), 850)
    return () => clearTimeout(t)
  }, [etapa])

  useEffect(() => { if (etapa === 'final') aoTerminar() }, [etapa, aoTerminar])

  // as fagulhas duram ~1s; some com elas antes da próxima carta emergir
  useEffect(() => {
    if (faiscas.length === 0) return
    const t = setTimeout(() => setFaiscas([]), 1200)
    return () => clearTimeout(t)
  }, [faiscas])

  // ------------------------------------------------------------- puxar
  const concluir = useCallback(() => {
    setTransicao('saindo')
    setPuxada(1)
    // fagulhas na cor da aura, sopradas da boca do pacote para fora
    const a = auraDaCarta(cartas[indice], quente)
    setFaiscas([...Array(a.faiscas)].map(() => ({
      left: `${18 + Math.random() * 64}%`,
      top: `${18 + Math.random() * 26}%`,
      background: a.cor,
      boxShadow: `0 0 8px 1px ${a.cor}`,
      animationDelay: `${Math.random() * 220}ms`,
      ['--dx' as string]: `${(Math.random() - 0.5) * 300}px`,
      ['--dy' as string]: `${-60 - Math.random() * 190}px`,
      ['--giro' as string]: `${(Math.random() - 0.5) * 540}deg`,
    } as React.CSSProperties)))
    setTimeout(() => {
      setReveladas((r) => [...r, cartas[indice]])
      const proximo = indice + 1
      setTransicao('')
      setPuxada(REPOUSO)
      if (proximo >= cartas.length) setEtapa('final')
      else setIndice(proximo)
    }, 280)
  }, [indice, cartas, quente])

  const aoDescer = (e: React.PointerEvent) => {
    if (transicao) return
    ;(e.currentTarget as Element).setPointerCapture?.(e.pointerId)
    // alcance = altura da própria figurinha, derivada da largura da cena.
    // A cena não carrega transform, então o rect dela é estável (spec §12).
    const r = cena.current!.getBoundingClientRect()
    arrasto.current = { y0: e.clientY, alcance: r.width * 0.62, moveu: false }
  }

  const aoMover = (e: React.PointerEvent) => {
    if (!arrasto.current || transicao) return
    const { y0, alcance } = arrasto.current
    if (Math.abs(y0 - e.clientY) > 3) arrasto.current.moveu = true
    setPuxada(Math.min(1, Math.max(REPOUSO, REPOUSO + (y0 - e.clientY) / alcance)))
  }

  const aoSoltar = () => {
    if (!arrasto.current) return
    const { moveu } = arrasto.current
    const p = puxada
    arrasto.current = null
    // passou da metade, ou foi clique seco sem arrastar: sai de vez
    if (p > 0.5 || !moveu) return concluir()
    setTransicao('assentando')
    setPuxada(REPOUSO)
    setTimeout(() => setTransicao(''), 320)
  }

  if (etapa === 'final') return null

  const rasgado = etapa === 'rasgando' || etapa === 'puxando'
  const atual = cartas[indice]
  const aura = atual ? auraDaCarta(atual, quente) : null

  return (
    <div className="abertura select-none py-4">
      <div className="palco-abertura">
      <div
        ref={cena}
        className="cena"
        style={{
          ['--corte-cima' as string]: rasgo.cima,
          ['--corte-baixo' as string]: rasgo.baixo,
          ['--arte' as string]: `url("${arte}")`,
          ['--puxada' as string]: puxada,
        }}
      >
        {quente && <span className="brilho-quente" />}

        {/* carta atual emergindo: a janela termina na linha da boca, então a
            figurinha só aparece na medida em que é puxada */}
        {etapa === 'puxando' && atual && aura && (
          <div className="janela" style={{ bottom: `${100 - rasgo.y}%` }}>
            <div
              key={atual.copy_id}
              className={`carta-puxada ${transicao} ${aura.classes.join(' ')}`}
              style={{ ['--aura' as string]: aura.cor }}
            >
              <span className="halo" />
              {aura.raios && <span className="raios" />}
              {quente && <span className="chamas"><i /><i /><i /><i /><i /></span>}
              {/* o pulo fica aqui dentro para não brigar com o transform do arraste */}
              <div className="conteudo">
                <div className={puxada <= REPOUSO + 0.01 && !transicao ? 'espiando' : ''}>
                  <Figurinha carta={atual} tamanho="media" shader />
                </div>
              </div>
            </div>
          </div>
        )}

        {/* a faixa só aparece quando a carta já saiu o bastante para o nome
            fazer sentido — antes disso ela entregaria a surpresa */}
        {etapa === 'puxando' && aura?.rotulo && puxada > 0.42 && (
          <span className="faixa-aura" style={{ ['--aura' as string]: aura.cor }}>
            {aura.rotulo}
          </span>
        )}

        {faiscas.map((estilo, i) => <span key={i} className="faisca" style={estilo} />)}

        <div
          className={[
            'pacote',
            etapa === 'idle' ? 'idle' : '',
            etapa === 'tremor' ? 'tremendo' : '',
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

        {foils.map((estilo, i) => <span key={i} className="foil" style={estilo} />)}

        {/* área de arraste, logo sobre a boca do pacote */}
        {etapa === 'puxando' && atual && (
          <div
            className="pega"
            style={{ top: `${rasgo.y - 20}%` }}
            onPointerDown={aoDescer}
            onPointerMove={aoMover}
            onPointerUp={aoSoltar}
            onPointerCancel={aoSoltar}
          />
        )}

        {etapa === 'idle' && (
          <div className="absolute inset-0 cursor-pointer" onClick={() => setEtapa('tremor')} />
        )}
      </div>
      </div>

      <p className="mt-4 text-center text-xs text-neutral-500">
        {etapa === 'idle' && 'clique no pacote para abrir'}
        {(etapa === 'tremor' || etapa === 'rasgando') && '…'}
        {etapa === 'puxando' && (
          <span className="dica-puxar relative block">
            puxe a carta para cima · {indice + 1} de {cartas.length}
          </span>
        )}
      </p>

      {/* as que já saíram ficam à mostra, na ordem em que foram puxadas */}
      {reveladas.length > 0 && (
        <div className="mx-auto mt-5 grid max-w-2xl grid-cols-3 gap-2 sm:grid-cols-5">
          {reveladas.map((c) => {
            const a = auraDaCarta(c, quente)
            return (
              <div key={c.copy_id} className={`mini-aura ${a.classes.join(' ')}`}
                   style={{ ['--aura' as string]: a.cor }}>
                <Figurinha carta={c} tamanho="miniatura" shader />
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

/** Volume real: verso espelhado e escurecido, quatro laterais, e a frente. */
const Corpo = ({ arte }: { arte: string }) => (
  <>
    <div className="face face-verso"><img src={arte} alt="" draggable={false} /></div>
    <div className="lado lado-esq" />
    <div className="lado lado-dir" />
    <div className="lado lado-topo" />
    <div className="lado lado-base" />
    <div className="face face-frente">
      <img src={arte} alt="" draggable={false} />
      <span className="mylar" />
    </div>
  </>
)
