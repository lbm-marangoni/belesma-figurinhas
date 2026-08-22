import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import { Figurinha } from '../componentes/Figurinha'
import { CartaAberta } from '../componentes/CartaAberta'
import { Pacote3D } from '../componentes/Pacote3D'
import type { ResultadoPacote, TipoPacote } from '../lib/tipos'

/**
 * Abertura de pacote (spec §13).
 *
 * A ordem importa e é inegociável: `open_pack` sorteia e GRAVA as cartas
 * primeiro; só depois a animação começa. Se o jogador fechar a aba no meio do
 * rasgo, as figurinhas continuam dele.
 *
 * A revelação usa o mesmo componente de figurinha do resto do projeto.
 */
export default function Abrir() {
  const { jogador, recarregar } = useSessao()
  const [res, setRes] = useState<ResultadoPacote | null>(null)
  const [animando, setAnimando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)
  const [emFoco, setEmFoco] = useState<number | null>(null)

  if (!jogador) return null

  const pilhas: [TipoPacote, string, number, number][] = [
    ['comum', 'Comum', jogador.packs_common, jogador.packs_common_daily],
    ['raro', 'Raro', jogador.packs_rare, jogador.packs_rare_daily],
    ['ultra', 'Ultra', jogador.packs_ultra, jogador.packs_ultra_daily],
  ]

  async function abrir(tipo: TipoPacote) {
    setErro(null); setOcupado(true); setRes(null); setEmFoco(null)
    const { data, error } = await supabase.rpc('open_pack', { pack_type: tipo })
    setOcupado(false)
    if (error) return setErro(error.message)
    setRes(data as ResultadoPacote)
    setAnimando(true)
    await recarregar()
  }

  return (
    <div className="p-4 sm:p-6">
      {!animando && (
        <div className="flex flex-wrap gap-3">
          {pilhas.map(([tipo, rotulo, n, nd]) => (
            <button
              key={tipo}
              disabled={ocupado || n + nd === 0}
              onClick={() => abrir(tipo)}
              className="flex w-36 flex-col items-center gap-2 rounded-lg border border-neutral-700
                         bg-neutral-900 p-3 transition-colors hover:border-neutral-500
                         disabled:opacity-40 disabled:hover:border-neutral-700"
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
      )}

      {erro && <p className="mt-4 rounded border border-red-900 bg-red-950/50 p-3 text-sm text-red-300">{erro}</p>}

      {/* o pacote 3D some sozinho ao terminar; as cartas já estão gravadas */}
      {res && animando && (
        <Pacote3D
          tipo={res.pack_type}
          cartas={res.cartas}
          quente={res.quente}
          aoTerminar={() => setAnimando(false)}
        />
      )}

      {res && !animando && (
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

          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-5">
            {res.cartas.map((c, i) => (
              <div key={c.copy_id}>
                <Figurinha carta={c} interativa onClick={() => setEmFoco(i)} />
                <div className="mt-1 flex flex-wrap gap-1 text-[10px]">
                  {c.estreia_mundial && <Etiqueta cor="bg-yellow-600">ESTREIA MUNDIAL</Etiqueta>}
                  {c.nova && !c.estreia_mundial && <Etiqueta cor="bg-emerald-700">NOVA</Etiqueta>}
                </div>
              </div>
            ))}
          </div>

          <button
            onClick={() => { setRes(null); setEmFoco(null) }}
            className="mt-5 rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300"
          >
            abrir outro
          </button>
        </section>
      )}

      {res && !animando && emFoco !== null && (
        <CartaAberta
          lista={res.cartas}
          indice={emFoco}
          aoFechar={() => setEmFoco(null)}
          aoNavegar={setEmFoco}
        />
      )}
    </div>
  )
}

const Etiqueta = ({ cor, children }: { cor: string; children: React.ReactNode }) => (
  <span className={`rounded px-1.5 py-0.5 font-bold text-white ${cor}`}>{children}</span>
)
