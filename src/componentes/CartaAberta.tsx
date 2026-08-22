import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Figurinha, serialDe } from './Figurinha'
import { giroscopioPrecisaDePermissao, pedirGiroscopio } from '../lib/tilt'
import { baixarFigurinha } from '../lib/exportar'
import { useSessao } from '../lib/sessao'
import { COR_TIER, ROTULO_TIER, type Carta } from '../lib/tipos'

type Dono = { kind: string; created_at: string; de: string | null; para: string | null }

/**
 * Figurinha aberta em tela cheia (spec §11).
 *
 * Tilt pelo ponteiro ou giroscópio, shader do tier, selo sobreposto. Ao lado:
 * serial, personagem, skin, tier, tiragem, procedência, data e histórico de
 * donos. Setas ou swipe navegam pela lista. Esc fecha e DEVOLVE O FOCO.
 *
 * Reaproveita o componente único de figurinha — não existe segunda
 * implementação do render.
 */
export function CartaAberta({
  lista, indice, aoFechar, aoNavegar, aoMudar,
}: {
  lista: Carta[]
  indice: number
  aoFechar: () => void
  aoNavegar: (i: number) => void
  /** chamado depois de vender, para a tela de trás se atualizar */
  aoMudar?: () => void
}) {
  const carta = lista[indice]
  const [historico, setHistorico] = useState<Dono[] | null>(null)
  const [giroLiberado, setGiroLiberado] = useState(!giroscopioPrecisaDePermissao())
  const { jogador, recarregar } = useSessao()
  const [quantas, setQuantas] = useState(0)      // quantas você tem deste tipo
  const [confirmando, setConfirmando] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)
  const [vendendo, setVendendo] = useState(false)
  const dialogo = useRef<HTMLDivElement>(null)
  const focoAnterior = useRef<HTMLElement | null>(null)
  const toqueX = useRef<number | null>(null)

  // Esc fecha e devolve o foco a quem o tinha antes de abrir.
  useEffect(() => {
    focoAnterior.current = document.activeElement as HTMLElement
    dialogo.current?.focus()
    const anterior = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.body.style.overflow = anterior
      focoAnterior.current?.focus?.()
    }
  }, [])

  useEffect(() => {
    const tecla = (e: KeyboardEvent) => {
      if (e.key === 'Escape') { e.preventDefault(); aoFechar() }
      if (e.key === 'ArrowRight' && indice < lista.length - 1) aoNavegar(indice + 1)
      if (e.key === 'ArrowLeft' && indice > 0) aoNavegar(indice - 1)
    }
    window.addEventListener('keydown', tecla)
    return () => window.removeEventListener('keydown', tecla)
  }, [indice, lista.length, aoFechar, aoNavegar])

  useEffect(() => {
    setHistorico(null)
    ;(async () => {
      const { data } = await supabase
        .from('copy_history')
        .select('kind, created_at, from_player, to_player')
        .eq('copy_id', carta.copy_id)
        .order('created_at')
      if (!data) return setHistorico([])

      const ids = [...new Set(data.flatMap((h) => [h.from_player, h.to_player]).filter(Boolean))]
      const nomes = new Map<string, string>()
      if (ids.length) {
        const { data: ps } = await supabase.from('players_public').select('id, nickname').in('id', ids)
        for (const p of ps ?? []) nomes.set(p.id, p.nickname)
      }
      setHistorico(data.map((h) => ({
        kind: h.kind, created_at: h.created_at,
        de: h.from_player ? (nomes.get(h.from_player) ?? '—') : null,
        para: h.to_player ? (nomes.get(h.to_player) ?? '—') : null,
      })))
    })()
  }, [carta.copy_id])

  // quantas cópias deste tipo você tem: a última nunca se vende (spec §19.4)
  useEffect(() => {
    setConfirmando(false); setAviso(null)
    if (!jogador) return
    supabase.from('card_copies')
      .select('id, card_types!inner(id)', { count: 'exact', head: true })
      .eq('owner_id', jogador.id).eq('burned', false)
      .eq('card_type_id', (carta as any).card_type_id ?? -1)
      .then(({ count }) => setQuantas(count ?? 0))
  }, [carta.copy_id, jogador])

  const cor = COR_TIER[carta.tier]
  const minha = !!jogador && quantas > 0
  const podeVender = minha && quantas > 1 && carta.seal === 'none' && carta.tier !== 'prisma'

  async function vender() {
    setVendendo(true); setAviso(null)
    const { data, error } = await supabase.rpc('vender', { p_copy_id: carta.copy_id })
    setVendendo(false); setConfirmando(false)
    if (error) return setAviso(error.message)
    await recarregar()
    aoMudar?.()
    setAviso(`Vendida por ${(data as any).valor} baba.`)
    setTimeout(aoFechar, 900)
  }
  const rotuloOrigem: Record<string, string> = {
    pull: 'puxada de pacote', daily: 'pacote diário', trade: 'troca',
    forge: 'forjada', sell: 'vendida ao pool', admin_reset: 'devolvida ao pool',
  }

  return (
    <div
      ref={dialogo}
      role="dialog"
      aria-modal="true"
      aria-label={`${carta.character_name} ${carta.skin}`}
      tabIndex={-1}
      onClick={(e) => { if (e.target === e.currentTarget) aoFechar() }}
      onPointerDown={(e) => { toqueX.current = e.clientX }}
      onPointerUp={(e) => {
        const dx = e.clientX - (toqueX.current ?? e.clientX)
        toqueX.current = null
        if (Math.abs(dx) < 60) return
        if (dx < 0 && indice < lista.length - 1) aoNavegar(indice + 1)
        if (dx > 0 && indice > 0) aoNavegar(indice - 1)
      }}
      className="fixed inset-0 z-50 overflow-y-auto bg-black/90 p-4 outline-none backdrop-blur-sm sm:p-8"
    >
      <div className="mx-auto grid max-w-5xl gap-6 sm:grid-cols-[minmax(0,1fr)_20rem]">
        <div className="mx-auto w-full max-w-md">
          <Figurinha carta={carta} tamanho="grande" interativa />

          <div className="mt-3 flex items-center justify-between text-sm">
            <button
              onClick={() => aoNavegar(indice - 1)}
              disabled={indice === 0}
              className="rounded border border-neutral-700 px-3 py-1 text-neutral-300 disabled:opacity-30"
            >
              ←
            </button>
            <span className="text-neutral-500">{indice + 1} de {lista.length}</span>
            <button
              onClick={() => aoNavegar(indice + 1)}
              disabled={indice === lista.length - 1}
              className="rounded border border-neutral-700 px-3 py-1 text-neutral-300 disabled:opacity-30"
            >
              →
            </button>
          </div>

          {/* Export para WhatsApp (spec §14) */}
          <button
            onClick={() => jogador && baixarFigurinha(carta, jogador.nickname)}
            className="btn btn-fraco mt-2 w-full"
          >
            baixar figurinha
          </button>
          <p className="mt-1 text-[11px] leading-snug text-neutral-600">
            O arquivo é comum e pode ser reenviado por qualquer um. Quem garante a posse é o app.
            O código <span className="font-mono">{carta.verify_code}</span> abre a página do dono atual.
          </p>

          {/* ---------------------------------------------------------- vender */}
          {minha && (
            <div className="mt-3">
              {!confirmando ? (
                <button onClick={() => setConfirmando(true)} disabled={!podeVender}
                  className="btn btn-fraco w-full">
                  vender
                </button>
              ) : (
                <div className="painel border-amber-900 p-3 text-left">
                  <p className="text-xs leading-snug text-amber-300">
                    Ela volta ao pool <strong>marcada com desgaste</strong> e outra pessoa pode
                    puxá-la em pacote. {carta.origin === 'forge'
                      ? 'Forjada vale 40% e é queimada de vez.'
                      : 'Isto não se desfaz.'}
                  </p>
                  <div className="mt-2 flex gap-2">
                    <button onClick={vender} disabled={vendendo} className="btn btn-perigo flex-1">
                      {vendendo ? '...' : 'confirmar venda'}
                    </button>
                    <button onClick={() => setConfirmando(false)} className="btn btn-fraco">
                      voltar
                    </button>
                  </div>
                </div>
              )}

              {!podeVender && (
                <p className="mt-1 text-[11px] text-neutral-600">
                  {carta.seal !== 'none' ? 'Figurinha selada não se vende.'
                    : carta.tier === 'prisma' ? 'Prisma não se vende.'
                    : 'Sua única cópia deste tipo — não dá para vender.'}
                </p>
              )}
              {aviso && <p className="mt-2 rounded-lg p-2 text-xs aviso-ok">{aviso}</p>}
            </div>
          )}

          {!giroLiberado && (
            <button
              onClick={async () => setGiroLiberado(await pedirGiroscopio())}
              className="mt-2 w-full rounded border border-neutral-700 py-1 text-xs text-neutral-400"
            >
              usar giroscópio
            </button>
          )}
        </div>

        <aside className="text-sm">
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold">{carta.character_name}</h2>
              <p className="text-neutral-400">{carta.skin}</p>
            </div>
            <button onClick={aoFechar} aria-label="fechar" className="btn btn-fraco shrink-0 py-1">
              fechar
            </button>
          </div>

          <dl className="mt-4 divide-y divide-neutral-800 border-y border-neutral-800">
            <Linha r="Serial"><span className="font-mono" style={{ color: cor }}>{serialDe(carta)}</span></Linha>
            <Linha r="Tier"><span style={{ color: cor }}>{ROTULO_TIER[carta.tier]}</span></Linha>
            <Linha r="Tiragem">{carta.print_run} no mundo</Linha>
            <Linha r="Procedência">
              {carta.origin === 'forge'
                ? <span className="text-amber-400">forjada — supply paralelo</span>
                : 'puxada de pacote'}
            </Linha>
            {carta.seal !== 'none' && <Linha r="Selo"><span className="capitalize">{carta.seal}</span></Linha>}
            {carta.damage_level > 0 && (
              <Linha r="Desgaste"><span className="text-amber-400">nível {carta.damage_level} de 3</span></Linha>
            )}
            <Linha r="Código"><span className="font-mono text-xs">{carta.verify_code}</span></Linha>
          </dl>

          <h3 className="mt-5 font-medium">Histórico</h3>
          {historico === null ? (
            <p className="text-neutral-600">…</p>
          ) : historico.length === 0 ? (
            <p className="text-neutral-600">sem registro</p>
          ) : (
            <ol className="mt-1 space-y-1">
              {historico.map((h, i) => (
                <li key={i} className="flex justify-between gap-2 border-b border-neutral-900 py-1">
                  <span className="text-neutral-300">
                    {rotuloOrigem[h.kind] ?? h.kind}
                    {h.de && h.para && <span className="text-neutral-500"> · {h.de} → {h.para}</span>}
                    {!h.de && h.para && <span className="text-neutral-500"> · {h.para}</span>}
                  </span>
                  <span className="shrink-0 text-neutral-600">
                    {new Date(h.created_at).toLocaleDateString('pt-BR')}
                  </span>
                </li>
              ))}
            </ol>
          )}
        </aside>
      </div>
    </div>
  )
}

const Linha = ({ r, children }: { r: string; children: React.ReactNode }) => (
  <div className="flex justify-between gap-3 py-2">
    <dt className="text-neutral-500">{r}</dt>
    <dd className="text-right">{children}</dd>
  </div>
)
