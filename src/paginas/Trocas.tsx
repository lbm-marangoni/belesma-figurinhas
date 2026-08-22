import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import { Figurinha, serialDe } from '../componentes/Figurinha'
import { ROTULO_TIER, type Carta } from '../lib/tipos'

/**
 * Trocas (spec §11). Sua figurinha × a do outro.
 *
 * A revalidação de posse mora na RPC, dentro da transação — uma proposta pode
 * ficar dias parada e a carta já ter mudado de dono. Aqui só mostramos o
 * motivo quando isso acontece.
 *
 * Realtime: a RLS de `trades` só deixa o jogador ver proposta em que ele é
 * parte, e o Realtime respeita a RLS. Ninguém recebe evento de troca alheia.
 */

type Proposta = {
  id: number
  from_player: string; to_player: string
  offered_copy_id: number | null; requested_copy_id: number | null
  offered_baba: number; requested_baba: number
  status: string; created_at: string
}

const daLinha = (r: any): Carta => ({
  copy_id: r.id, card_type_id: r.card_type_id, serial_number: r.serial_number, seal: r.seal, origin: r.origin,
  damage_level: r.damage_level, forge_index: r.forge_index, verify_code: r.verify_code,
  print_run: r.card_types.print_run, tier: r.card_types.tier,
  tier_order: r.card_types.tier_order, skin: r.card_types.skin, art_path: '',
  character_slug: r.card_types.characters.slug,
  character_name: r.card_types.characters.name,
})
const SELECT_CARTA =
  `id, card_type_id, serial_number, seal, origin, damage_level, forge_index, verify_code,
   card_types!inner ( print_run, tier, tier_order, skin, characters!inner ( slug, name ) )`

export default function Trocas() {
  const { jogador } = useSessao()
  const [jogadores, setJogadores] = useState<{ id: string; nickname: string }[]>([])
  const [outro, setOutro] = useState('')
  const [minhas, setMinhas] = useState<Carta[]>([])
  const [dele, setDele] = useState<Carta[]>([])
  const [ofereco, setOfereco] = useState<number | null>(null)
  const [peco, setPeco] = useState<number | null>(null)
  const [propostas, setPropostas] = useState<Proposta[]>([])
  const [cartasDaProposta, setCartas] = useState<Map<number, Carta>>(new Map())
  const [nomes, setNomes] = useState<Map<string, string>>(new Map())
  const [msg, setMsg] = useState<{ tipo: 'ok' | 'erro'; texto: string } | null>(null)

  // ---------------------------------------------------------------- dados
  const carregarPropostas = useCallback(async () => {
    if (!jogador) return
    const { data } = await supabase.from('trades').select('*')
      .eq('status', 'pending').order('created_at', { ascending: false })
    const ps = (data ?? []) as Proposta[]
    setPropostas(ps)

    const ids = ps.flatMap((p) => [p.offered_copy_id, p.requested_copy_id]).filter(Boolean)
    if (ids.length) {
      const { data: cs } = await supabase.from('card_copies').select(SELECT_CARTA).in('id', ids)
      setCartas(new Map((cs ?? []).map((c: any) => [c.id, daLinha(c)])))
    }
  }, [jogador])

  useEffect(() => {
    if (!jogador) return
    ;(async () => {
      const { data: ps } = await supabase.from('players_public').select('id, nickname').order('nickname')
      const outros = (ps ?? []).filter((p) => p.id !== jogador.id)
      setJogadores(outros)
      setNomes(new Map((ps ?? []).map((p) => [p.id, p.nickname])))

      const { data: m } = await supabase.from('card_copies').select(SELECT_CARTA)
        .eq('owner_id', jogador.id).order('id')
      setMinhas((m ?? []).map(daLinha))
    })()
    carregarPropostas()
  }, [jogador, carregarPropostas])

  useEffect(() => {
    if (!outro) { setDele([]); setPeco(null); return }
    ;(async () => {
      const { data } = await supabase.from('card_copies').select(SELECT_CARTA)
        .eq('owner_id', outro).order('id')
      setDele((data ?? []).map(daLinha))
      setPeco(null)
    })()
  }, [outro])

  // realtime: proposta nova ou resolvida aparece sem recarregar
  useEffect(() => {
    if (!jogador) return
    const canal = supabase.channel('trocas')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'trades' },
          () => carregarPropostas())
      .subscribe()
    return () => { supabase.removeChannel(canal) }
  }, [jogador, carregarPropostas])

  const recebidas = useMemo(
    () => propostas.filter((p) => p.to_player === jogador?.id), [propostas, jogador])
  const enviadas = useMemo(
    () => propostas.filter((p) => p.from_player === jogador?.id), [propostas, jogador])

  if (!jogador) return null

  // ---------------------------------------------------------------- ações
  async function propor() {
    setMsg(null)
    const { error } = await supabase.rpc('propose_trade', {
      p_offered_copy_id: ofereco, p_offered_baba: 0,
      p_requested_copy_id: peco, p_requested_baba: 0,
    })
    if (error) return setMsg({ tipo: 'erro', texto: error.message })
    setMsg({ tipo: 'ok', texto: 'Proposta enviada.' })
    setOfereco(null); setPeco(null)
    carregarPropostas()
  }

  async function aceitar(id: number) {
    setMsg(null)
    const { data, error } = await supabase.rpc('accept_trade', { p_trade_id: id })
    if (error) return setMsg({ tipo: 'erro', texto: error.message })
    // a RPC devolve {ok:false, motivo} quando a revalidação reprova — e nesse
    // caso ela já cancelou a proposta
    if (data && (data as any).ok === false) {
      setMsg({ tipo: 'erro', texto: (data as any).motivo })
    } else {
      setMsg({ tipo: 'ok', texto: 'Troca feita.' })
    }
    carregarPropostas()
    const { data: m } = await supabase.from('card_copies').select(SELECT_CARTA)
      .eq('owner_id', jogador!.id).order('id')
    setMinhas((m ?? []).map(daLinha))
  }

  async function resolver(id: number, acao: 'decline_trade' | 'cancel_trade') {
    setMsg(null)
    const { error } = await supabase.rpc(acao, { p_trade_id: id })
    if (error) setMsg({ tipo: 'erro', texto: error.message })
    carregarPropostas()
  }

  const Cartinha = ({ id }: { id: number | null }) => {
    const c = id ? cartasDaProposta.get(id) : null
    if (!c) return <div className="w-20 text-xs text-neutral-600">—</div>
    return (
      <div className="w-20">
        <Figurinha carta={c} tamanho="miniatura" />
        <p className="mt-0.5 truncate text-[10px] text-neutral-500">
          {c.character_slug} · {serialDe(c)}
        </p>
      </div>
    )
  }

  return (
    <div className="p-4 sm:p-6">
      {msg && (
        <p className={`mb-4 rounded border p-2 text-sm ${msg.tipo === 'ok'
          ? 'border-emerald-900 bg-emerald-950/50 text-emerald-300'
          : 'border-red-900 bg-red-950/50 text-red-300'}`}>{msg.texto}</p>
      )}

      {/* ------------------------------------------------------ nova proposta */}
      <section className="rounded border border-neutral-800 p-4">
        <h2 className="mb-3 text-sm font-medium">Nova proposta</h2>
        <select value={outro} onChange={(e) => setOutro(e.target.value)}
          className="mb-4 rounded border border-neutral-700 bg-neutral-900 px-2 py-1 text-sm">
          <option value="">com quem…</option>
          {jogadores.map((p) => <option key={p.id} value={p.id}>{p.nickname}</option>)}
        </select>

        <div className="grid gap-4 sm:grid-cols-2">
          <Seletor titulo="Você oferece" cartas={minhas} valor={ofereco} aoEscolher={setOfereco} />
          <Seletor titulo={outro ? 'Você pede' : 'Você pede (escolha o jogador)'}
                   cartas={dele} valor={peco} aoEscolher={setPeco} />
        </div>

        <button onClick={propor} disabled={!ofereco || !peco}
          className="mt-4 rounded bg-neutral-100 px-3 py-1.5 text-sm font-medium text-neutral-900 disabled:opacity-40">
          propor troca
        </button>
      </section>

      {/* ------------------------------------------------------ recebidas */}
      <section className="mt-6">
        <h2 className="mb-2 text-sm font-medium">
          Recebidas {recebidas.length > 0 && <span className="text-emerald-400">({recebidas.length})</span>}
        </h2>
        {recebidas.length === 0 ? <Vazio /> : recebidas.map((p) => (
          <Linha key={p.id} p={p} nomes={nomes} Cartinha={Cartinha} rotulo="de">
            <button onClick={() => aceitar(p.id)}
              className="rounded bg-emerald-700 px-3 py-1 text-xs font-medium text-white">aceitar</button>
            <button onClick={() => resolver(p.id, 'decline_trade')}
              className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300">recusar</button>
          </Linha>
        ))}
      </section>

      {/* ------------------------------------------------------ enviadas */}
      <section className="mt-6">
        <h2 className="mb-2 text-sm font-medium">Enviadas</h2>
        {enviadas.length === 0 ? <Vazio /> : enviadas.map((p) => (
          <Linha key={p.id} p={p} nomes={nomes} Cartinha={Cartinha} rotulo="para">
            <button onClick={() => resolver(p.id, 'cancel_trade')}
              className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300">cancelar</button>
          </Linha>
        ))}
      </section>
    </div>
  )
}

const Vazio = () => <p className="text-sm text-neutral-600">nada por aqui</p>

function Linha({ p, nomes, Cartinha, rotulo, children }: {
  p: Proposta
  nomes: Map<string, string>
  Cartinha: (props: { id: number | null }) => React.ReactElement
  rotulo: string
  children: React.ReactNode
}) {
  const quem = rotulo === 'de' ? p.from_player : p.to_player
  return (
    <div className="mb-2 flex flex-wrap items-center gap-4 rounded border border-neutral-800 p-3">
      <span className="text-xs text-neutral-400">{rotulo} <strong className="text-neutral-200">{nomes.get(quem) ?? '—'}</strong></span>
      <Cartinha id={p.offered_copy_id} />
      <span className="text-neutral-500">↔</span>
      <Cartinha id={p.requested_copy_id} />
      <div className="ml-auto flex gap-2">{children}</div>
    </div>
  )
}

function Seletor({ titulo, cartas, valor, aoEscolher }: {
  titulo: string; cartas: Carta[]; valor: number | null; aoEscolher: (id: number) => void
}) {
  return (
    <div>
      <p className="mb-1 text-xs text-neutral-400">{titulo}</p>
      <div className="grid max-h-64 grid-cols-3 gap-2 overflow-y-auto rounded border border-neutral-800 p-2 sm:grid-cols-4">
        {cartas.length === 0 && <p className="col-span-full py-6 text-center text-xs text-neutral-600">nenhuma carta</p>}
        {cartas.map((c) => (
          <button key={c.copy_id} onClick={() => aoEscolher(c.copy_id)} className="text-left">
            <Figurinha carta={c} tamanho="miniatura" selecionada={valor === c.copy_id} />
            <p className="mt-0.5 truncate text-[10px] text-neutral-500">
              {ROTULO_TIER[c.tier]} · {serialDe(c)}
            </p>
          </button>
        ))}
      </div>
    </div>
  )
}
