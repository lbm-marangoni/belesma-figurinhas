import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import type { DefinicaoPacote } from '../lib/tipos'

/**
 * Loja (spec §19.5) e extrato da moeda (§19.1).
 *
 * O teto de 3 pacotes por dia é contado NO SERVIDOR, pela janela de 24h do
 * extrato. Aqui só mostramos o contador — a regra não é do cliente.
 *
 * O pacote dirigido sorteia só de um personagem e custa o dobro: serve para
 * fechar página do álbum.
 */

type Preco = { chave: string; valor: number }
type Lancamento = { id: number; delta: number; motivo: string; ref_id: string | null; created_at: string }

export default function Loja() {
  const { jogador, recarregar } = useSessao()
  const [precos, setPrecos] = useState<Map<string, number>>(new Map())
  /** O que esta a venda vem do catalogo, nao de uma lista aqui dentro. */
  const [aVenda, setAVenda] = useState<DefinicaoPacote[]>([])
  const [personagens, setPersonagens] = useState<{ id: number; slug: string; name: string }[]>([])
  const [dirigidoA, setDirigidoA] = useState<string>('')
  const [extrato, setExtrato] = useState<Lancamento[]>([])
  const [compradosHoje, setComprados] = useState(0)
  const [msg, setMsg] = useState<{ tipo: 'ok' | 'erro'; texto: string } | null>(null)
  const [ocupado, setOcupado] = useState(false)

  const carregar = async () => {
    if (!jogador) return
    const [ec, ch, bl, pd] = await Promise.all([
      supabase.from('economy_config').select('chave, valor'),
      supabase.from('characters').select('id, slug, name').order('display_order'),
      supabase.from('baba_log').select('*').order('id', { ascending: false }).limit(60),
      supabase.from('pack_definitions')
        .select('id, slug, name, descricao, art_path, tamanho, distribuicao, elegivel_loja, '
              + 'preco_baba, limite_global, aberturas_realizadas, ativo')
        .eq('elegivel_loja', true).eq('ativo', true).order('preco_baba'),
    ])
    setPrecos(new Map(((ec.data ?? []) as Preco[]).map((p) => [p.chave, Number(p.valor)])))
    setAVenda((pd.data ?? []) as unknown as DefinicaoPacote[])
    setPersonagens(ch.data ?? [])
    const lanc = (bl.data ?? []) as Lancamento[]
    setExtrato(lanc)
    const limite = Date.now() - 24 * 3600 * 1000
    setComprados(lanc.filter((l) => l.motivo === 'compra' && new Date(l.created_at).getTime() > limite).length)
  }
  useEffect(() => { carregar() }, [jogador])

  if (!jogador) return null

  const teto = precos.get('teto_compra_dia') ?? 3
  const mult = precos.get('dirigido_mult') ?? 2

  async function comprar(def: DefinicaoPacote) {
    setOcupado(true); setMsg(null)
    const { data, error } = await supabase.rpc('comprar_pacote', {
      p_pack_type: def.slug,
      p_character_id: dirigidoA ? Number(dirigidoA) : null,
    })
    setOcupado(false)
    if (error) return setMsg({ tipo: 'erro', texto: error.message })
    const d = data as any
    setMsg({ tipo: 'ok', texto:
      `${def.name} comprado por ${d.preco} baba. Restam ${d.restantes_hoje} compras hoje.` })
    await carregar(); await recarregar()
  }

  async function conferirAlbum() {
    const { data, error } = await supabase.rpc('conferir_bonus_album')
    if (error) return setMsg({ tipo: 'erro', texto: error.message })
    const c = (data as any).creditado
    setMsg({
      tipo: 'ok',
      texto: c > 0 ? `+${c} baba por página completa do álbum.` : 'Nenhuma página nova completa.',
    })
    await carregar(); await recarregar()
  }



  return (
    <div className="mx-auto max-w-[80rem] p-3 sm:p-6">
      <div className="mb-4 flex flex-wrap items-center gap-3">
        <h2 className="text-lg font-semibold">Loja</h2>
        <span className="chip"><strong>{jogador.baba}</strong> baba</span>
        <span className="chip">{teto - compradosHoje} de {teto} compras hoje</span>
        <button onClick={conferirAlbum} className="btn btn-fraco ml-auto">
          conferir bônus do álbum
        </button>
      </div>

      {msg && (
        <p className={`mb-4 rounded-lg p-2 text-sm ${msg.tipo === 'ok' ? 'aviso-ok' : 'aviso-ruim'}`}>
          {msg.texto}
        </p>
      )}

      <label className="mb-4 flex flex-wrap items-center gap-2 text-sm text-neutral-400">
        Pacote dirigido
        <select value={dirigidoA} onChange={(e) => setDirigidoA(e.target.value)} className="campo">
          <option value="">qualquer Belesma (preço normal)</option>
          {personagens.map((p) => (
            <option key={p.id} value={p.id}>só {p.name} — custa {mult}×</option>
          ))}
        </select>
        <span className="text-xs text-neutral-600">
          mesmo conteúdo e mesmas odds, só de um personagem. Serve para fechar página do álbum.
        </span>
      </label>

      {/* A vitrine e o catalogo: qualquer definicao marcada como elegivel para
          loja aparece aqui sozinha, com preco, tamanho e o que resta da
          edicao se ela for limitada. */}
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {aVenda.map((d) => {
          const preco = (d.preco_baba ?? 0) * (dirigidoA ? mult : 1)
          const restam = d.limite_global == null
            ? null : d.limite_global - d.aberturas_realizadas
          const esgotou = restam != null && restam <= 0
          const podeComprar = !esgotou && jogador!.baba >= preco && compradosHoje < teto
          return (
            <div key={d.id} className="painel flex flex-col items-center gap-2 p-4">
              <img src={`${import.meta.env.BASE_URL}${d.art_path ?? 'packs/booster-comum.png'}`}
                   alt="" className="h-32 object-contain" />
              <p className="font-medium">{d.name}</p>
              {d.descricao && (
                <p className="text-center text-xs leading-snug text-neutral-500">{d.descricao}</p>
              )}
              <p className="text-xs text-neutral-600">{d.tamanho} cartas</p>
              {restam != null && (
                <p className={`text-xs ${esgotou ? 'text-red-400' : 'text-amber-400'}`}>
                  {esgotou ? 'edição esgotada' : `${restam} de ${d.limite_global} restantes`}
                </p>
              )}
              <p className="text-sm text-neutral-400">
                <strong className="text-[var(--acento)]">{preco}</strong> baba
                {dirigidoA && <span className="text-neutral-600"> (dirigido)</span>}
              </p>
              <button onClick={() => comprar(d)} disabled={ocupado || !podeComprar}
                className="btn btn-forte w-full">
                {esgotou ? 'esgotado'
                  : compradosHoje >= teto ? 'limite de hoje'
                  : jogador!.baba < preco ? 'saldo curto' : 'comprar'}
              </button>
            </div>
          )
        })}
        {aVenda.length === 0 && (
          <p className="text-sm text-neutral-500">Nada à venda no momento.</p>
        )}
      </div>

      {/* ---------------------------------------------------------- extrato */}
      <section className="mt-8">
        <h3 className="mb-2 text-sm font-medium">Extrato</h3>
        {extrato.length === 0 ? (
          <p className="text-sm text-neutral-600">nenhuma movimentação ainda</p>
        ) : (
          <table className="w-full max-w-2xl text-left text-sm">
            <tbody>
              {extrato.map((l) => (
                <tr key={l.id} className="border-b border-neutral-900">
                  <td className="py-1 text-neutral-500">
                    {new Date(l.created_at).toLocaleString('pt-BR', {
                      day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}
                  </td>
                  <td className="text-neutral-300">{l.motivo}</td>
                  <td className="text-neutral-600">{l.ref_id ?? ''}</td>
                  <td className={`text-right tabular-nums ${l.delta > 0 ? 'text-[var(--acento)]' : 'text-red-400'}`}>
                    {l.delta > 0 ? '+' : ''}{l.delta}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p className="mt-2 text-xs text-neutral-600">
          O saldo e o extrato são gravados na mesma transação. Se um dia divergirem,
          o extrato é a verdade e o saldo é o bug.
        </p>
      </section>
    </div>
  )
}
