import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import { Figurinha } from '../componentes/Figurinha'
import type { ResultadoPacote, TipoPacote } from '../lib/tipos'

/**
 * Fase 2: abertura sem enfeite. As cartas já foram sorteadas e GRAVADAS pelo
 * open_pack antes de qualquer coisa aparecer na tela — fechar a aba no meio
 * não perde nada (spec §13). O pacote 3D com rasgo é Fase 4.
 *
 * A revelação segue reveal_index, que veio embaralhado do servidor. O tier de
 * carta ainda não revelada não vai para o DOM.
 */
export default function Abrir() {
  const { jogador, recarregar } = useSessao()
  const [res, setRes] = useState<ResultadoPacote | null>(null)
  const [reveladas, setReveladas] = useState(0)
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)

  if (!jogador) return null

  const pilhas: [TipoPacote, string, number, number][] = [
    ['comum', 'Comum', jogador.packs_common, jogador.packs_common_daily],
    ['raro', 'Raro', jogador.packs_rare, jogador.packs_rare_daily],
    ['ultra', 'Ultra', jogador.packs_ultra, jogador.packs_ultra_daily],
  ]

  async function abrir(tipo: TipoPacote) {
    setErro(null); setOcupado(true); setRes(null); setReveladas(0)
    const { data, error } = await supabase.rpc('open_pack', { pack_type: tipo })
    setOcupado(false)
    if (error) return setErro(error.message)
    setRes(data as ResultadoPacote)
    await recarregar()
  }

  const tudoRevelado = res && reveladas >= res.cartas.length

  return (
    <div className="p-4 sm:p-6">
      <div className="flex flex-wrap gap-3">
        {pilhas.map(([tipo, rotulo, n, nd]) => (
          <button
            key={tipo}
            disabled={ocupado || n + nd === 0}
            onClick={() => abrir(tipo)}
            className="flex w-36 flex-col items-center gap-2 rounded-lg border border-neutral-700
                       bg-neutral-900 p-3 disabled:opacity-40"
          >
            <img src={`${import.meta.env.BASE_URL}packs/booster-${tipo}.png`} alt=""
                 className="h-28 object-contain" />
            <span className="text-sm font-medium">{rotulo}</span>
            <span className="text-xs text-neutral-400">
              {n + nd} {nd > 0 && <span className="text-emerald-400">({nd} do diário)</span>}
            </span>
          </button>
        ))}
      </div>

      {erro && <p className="mt-4 rounded border border-red-900 bg-red-950/50 p-3 text-sm text-red-300">{erro}</p>}

      {res && (
        <section className="mt-6">
          <div className="mb-3 flex flex-wrap items-center gap-2 text-xs">
            {res.quente && <Etiqueta cor="bg-orange-600">PACOTE QUENTE</Etiqueta>}
            {res.bonus && <Etiqueta cor="bg-sky-700">+1 BÔNUS</Etiqueta>}
            {res.pity && <Etiqueta cor="bg-purple-700">GARANTIDO</Etiqueta>}
            {res.promovidos > 0 && <Etiqueta cor="bg-neutral-700">{res.promovidos} promovida(s)</Etiqueta>}
            {res.do_diario && <Etiqueta cor="bg-emerald-800">DO DIÁRIO</Etiqueta>}
            {res.cartas.length < res.esperado && (
              <span className="text-amber-400">
                O pacote saiu com {res.cartas.length} de {res.esperado}: acabou o estoque de algum tier.
              </span>
            )}
          </div>

          {!tudoRevelado ? (
            <button
              onClick={() => setReveladas(res.cartas.length)}
              className="mb-3 rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300"
            >
              revelar tudo
            </button>
          ) : null}

          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-5">
            {res.cartas.map((c, i) => (
              <div key={c.copy_id} className="relative">
                {i < reveladas ? (
                  <>
                    <Figurinha carta={c} />
                    <div className="mt-1 flex flex-wrap gap-1 text-[10px]">
                      {c.estreia_mundial && <Etiqueta cor="bg-yellow-600">ESTREIA MUNDIAL</Etiqueta>}
                      {c.nova && !c.estreia_mundial && <Etiqueta cor="bg-emerald-700">NOVA</Etiqueta>}
                    </div>
                  </>
                ) : (
                  // verso fechado: nada do conteúdo vai para o DOM antes da virada
                  <button
                    onClick={() => setReveladas(i + 1)}
                    disabled={i !== reveladas}
                    className="aspect-square w-full rounded-lg border-2 border-neutral-700
                               bg-neutral-800 text-3xl text-neutral-600 disabled:opacity-50"
                  >
                    ?
                  </button>
                )}
              </div>
            ))}
          </div>
        </section>
      )}
    </div>
  )
}

const Etiqueta = ({ cor, children }: { cor: string; children: React.ReactNode }) => (
  <span className={`rounded px-1.5 py-0.5 font-bold text-white ${cor}`}>{children}</span>
)
