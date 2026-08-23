import { useEffect, useState } from 'react'
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
  const [diario, setDiario] = useState<{ pronto: boolean; falta: string } | null>(null)
  const [avisoDiario, setAvisoDiario] = useState<string | null>(null)
  const [estoque, setEstoque] = useState<{ tier: string; disponiveis: number; total: number }[]>([])

  // quando volta o diário, e se algum tier está no fim (spec §8)
  useEffect(() => {
    if (!jogador) return
    const t = jogador.last_daily_at ? new Date(jogador.last_daily_at).getTime() : 0
    const volta = t + 24 * 3600 * 1000
    const falta = volta - Date.now()
    setDiario({
      pronto: falta <= 0,
      falta: falta <= 0 ? '' :
        `${Math.floor(falta / 3600000)}h${String(Math.floor((falta % 3600000) / 60000)).padStart(2, '0')}`,
    })
    supabase.rpc('estoque_publico').then(({ data }) => setEstoque((data as any)?.por_tier ?? []))
  }, [jogador])

  if (!jogador) return null

  async function resgatar() {
    setAvisoDiario(null)
    const { data, error } = await supabase.rpc('claim_daily')
    if (error) return setAvisoDiario(error.message)
    const d = data as any
    // quais pacotes o diario da saiu do codigo e virou coluna da definicao,
    // entao a mensagem se monta do que o servidor respondeu
    const lista = (d.pacotes ?? [])
      .map((p: any) => `+${p.quantidade} ${p.nome}`).join(', ')
    setAvisoDiario(
      `${lista || 'nada hoje'} · +${d.baba} baba (streak ${d.streak})`)
    await recarregar()
  }

  /**
   * O que da para abrir agora, uma pilha por definicao.
   *
   * A lista nao esta mais escrita aqui: ela vem do inventario, que vem das
   * definicoes. Criar um pacote novo no painel faz ele aparecer nesta tela
   * sem tocar em uma linha de codigo - que era o ponto de tirar comum, raro
   * e ultra de dentro do programa.
   */
  const pilhas = (() => {
    const m = new Map<number, { def: number; nome: string; arte: string | null;
                                comprados: number; diarios: number }>()
    for (const it of jogador.inventario ?? []) {
      if (!it.ativo) continue
      const e = m.get(it.pack_definition_id)
        ?? { def: it.pack_definition_id, nome: it.nome, arte: it.art_path,
             comprados: 0, diarios: 0 }
      if (it.do_diario) e.diarios += it.quantidade
      else e.comprados += it.quantidade
      m.set(it.pack_definition_id, e)
    }
    return [...m.values()].filter((p) => p.comprados + p.diarios > 0)
  })()

  async function abrir(def: number) {
    setErro(null); setOcupado(true); setRes(null); setEmFoco(null)
    const { data, error } = await supabase.rpc('open_pack', { p_pack_definition_id: def })
    setOcupado(false)
    if (error) return setErro(error.message)
    setRes(data as ResultadoPacote)
    setAnimando(true)
    await recarregar()
  }

  return (
    <div className="mx-auto max-w-[100rem] p-3 sm:p-6">
      {/* ------------------------------------------------------------ diário */}
      {!animando && (
        <div className="painel mb-4 flex flex-wrap items-center gap-3 p-3">
          <div className="text-sm">
            <p className="font-medium">Diário</p>
            <p className="text-xs text-neutral-500">
              2 comuns + 1 raro a cada 24h · 1 ultra a cada 3 resgates
            </p>
          </div>
          <button onClick={resgatar} disabled={!diario?.pronto}
            className="btn btn-forte ml-auto">
            {diario?.pronto ? 'resgatar' : `volta em ${diario?.falta ?? '…'}`}
          </button>
          {avisoDiario && (
            <p className="w-full rounded-lg p-2 text-sm aviso-ok">{avisoDiario}</p>
          )}
        </div>
      )}

      {/* cascata de esgotamento: avisar com honestidade (spec §8) */}
      {!animando && estoque.filter((e) => e.disponiveis === 0).length > 0 && (
        <p className="mb-4 rounded-lg p-2 text-sm aviso-ruim">
          Esgotou no mundo:{' '}
          <strong>{estoque.filter((e) => e.disponiveis === 0).map((e) => e.tier).join(', ')}</strong>.
          Os pacotes redistribuem dentro da própria tabela de odds, então a garantia do Raro e do
          Ultra continua valendo — mas esses tiers não saem mais.
        </p>
      )}

      {!animando && (
        <div className="flex flex-wrap gap-3">
          {pilhas.map((p) => (
            <button
              key={p.def}
              disabled={ocupado}
              onClick={() => abrir(p.def)}
              className="flex w-36 flex-col items-center gap-2 rounded-lg border border-neutral-700
                         bg-neutral-900 p-3 transition-colors hover:border-neutral-500
                         disabled:opacity-40 disabled:hover:border-neutral-700"
            >
              <img src={`${import.meta.env.BASE_URL}${p.arte ?? 'packs/booster-comum.png'}`}
                   alt="" className="h-28 object-contain" />
              <span className="text-sm font-medium">{p.nome}</span>
              <span className="text-xs text-neutral-400">
                {p.comprados + p.diarios}
                {p.diarios > 0 && <span className="text-emerald-400"> ({p.diarios} do diário)</span>}
              </span>
            </button>
          ))}
          {pilhas.length === 0 && (
            <p className="text-sm text-neutral-500">
              Nenhum pacote para abrir. Resgate o diário ou compre na Loja.
            </p>
          )}
        </div>
      )}

      {erro && <p className="mt-4 rounded border border-red-900 bg-red-950/50 p-3 text-sm text-red-300">{erro}</p>}

      {/* o pacote 3D some sozinho ao terminar; as cartas já estão gravadas */}
      {res && animando && (
        <Pacote3D
          tipo={(res.pack_type ?? 'comum') as TipoPacote}
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
