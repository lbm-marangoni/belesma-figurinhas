import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import { Figurinha } from '../componentes/Figurinha'
import { CartaAberta } from '../componentes/CartaAberta'
import { baixarFigurinha } from '../lib/exportar'
import { ROTULO_TIER as RT, COR_TIER } from '../lib/tipos'
import '../styles/menu.css'
import { ROTULO_TIER, TIERS, type Carta, type Selo, type Tier } from '../lib/tipos'

type Ordem = 'raridade' | 'raridade-asc' | 'personagem' | 'skin'
           | 'serial' | 'repetidas' | 'recentes'

/** Repetidas do mesmo card_type empilham. A da frente é a de melhor serial:
 *  selada tem prioridade, depois o menor número (spec §11). */
function melhorPrimeiro(a: Carta, b: Carta) {
  const seladaA = a.seal !== 'none' ? 0 : 1
  const seladaB = b.seal !== 'none' ? 0 : 1
  if (seladaA !== seladaB) return seladaA - seladaB
  return a.serial_number - b.serial_number
}

export default function Colecao() {
  const { jogador, recarregar } = useSessao()
  const [msg, setMsg] = useState<{ tipo: 'ok' | 'erro'; texto: string } | null>(null)
  const [ocupado, setOcupado] = useState(false)
  const [cartas, setCartas] = useState<Carta[] | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [personagem, setPersonagem] = useState('todos')
  const [tier, setTier] = useState<'todos' | Tier>('todos')
  const [selo, setSelo] = useState<'todos' | Exclude<Selo, 'none'> | 'nenhum'>('todos')
  const [ordem, setOrdem] = useState<Ordem>('raridade')
  const [aberta, setAberta] = useState<string | null>(null)
  const [posLeque, setPosLeque] = useState({ x: 0, y: 0, seta: 50 })
  const [emFoco, setEmFoco] = useState<number | null>(null)

  const recarregarAcervo = useCallback(async () => {
    if (!jogador) return
    {
      const { data, error } = await supabase
        .from('card_copies')
        .select(`copy_id:id, card_type_id, serial_number, seal, origin, damage_level, forge_index, verify_code,
                 card_types!inner ( print_run, tier, tier_order, skin, art_path,
                                    characters!inner ( slug, name ) )`)
        .eq('owner_id', jogador.id)
        .order('id')
      if (error) return setErro(error.message)

      setCartas((data ?? []).map((r: any) => ({
        copy_id: r.copy_id, card_type_id: r.card_type_id,
        serial_number: r.serial_number, seal: r.seal,
        origin: r.origin, damage_level: r.damage_level, forge_index: r.forge_index,
        verify_code: r.verify_code, print_run: r.card_types.print_run,
        tier: r.card_types.tier, tier_order: r.card_types.tier_order,
        skin: r.card_types.skin, art_path: r.card_types.art_path,
        character_slug: r.card_types.characters.slug,
        character_name: r.card_types.characters.name,
      })))
    }
  }, [jogador])

  useEffect(() => { recarregarAcervo() }, [recarregarAcervo])

  // Esc e clique fora fecham o leque. Sem isso ele ficava aberto para sempre
  // e o jogador tinha que clicar de novo exatamente na carta.
  useEffect(() => {
    if (!aberta) return
    const fora = (e: MouseEvent) => {
      if (!(e.target as Element).closest('[data-leque]')) setAberta(null)
    }
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setAberta(null) }
    const rolou = () => setAberta(null)   // menu fixo nao acompanha a rolagem
    document.addEventListener('mousedown', fora)
    window.addEventListener('keydown', esc)
    window.addEventListener('scroll', rolou, true)
    return () => {
      document.removeEventListener('mousedown', fora)
      window.removeEventListener('keydown', esc)
      window.removeEventListener('scroll', rolou, true)
    }
  }, [aberta])

  /** Abre o leque ancorado na carta, travado dentro da janela. */
  function abrirLeque(chave: string, alvo: HTMLElement) {
    if (aberta === chave) return setAberta(null)
    const r = alvo.getBoundingClientRect()
    const largura = 288                       // igual ao max-width do .leque
    const centro = r.left + r.width / 2
    const x = Math.min(Math.max(centro, largura / 2 + 10), window.innerWidth - largura / 2 - 10)
    setPosLeque({ x, y: r.bottom + 8, seta: 50 + ((centro - x) / largura) * 100 })
    setAberta(chave)
  }

  // Vender e IRREVERSIVEL: a copia volta ao pool marcada com desgaste e outra
  // pessoa pode puxa-la (spec §19.4). Por isso a confirmacao explicita.
  async function vender(c: Carta) {
    if (!confirm(
      `Vender ${c.character_slug} ${c.skin} ${c.serial_number}/${c.print_run}?

` +
      'Ela volta ao pool marcada com desgaste. Outra pessoa pode puxá-la em pacote.')) return
    setOcupado(true); setMsg(null)
    const { data, error } = await supabase.rpc('vender', { p_copy_id: c.copy_id })
    setOcupado(false)
    if (error) return setMsg({ tipo: 'erro', texto: error.message })
    setMsg({ tipo: 'ok', texto: `Vendida por ${(data as any).valor} baba.` })
    await recarregarAcervo(); await recarregar()
  }

  async function restaurar(c: Carta) {
    setOcupado(true); setMsg(null)
    const { data, error } = await supabase.rpc('restaurar', { p_copy_id: c.copy_id })
    setOcupado(false)
    if (error) return setMsg({ tipo: 'erro', texto: error.message })
    setMsg({ tipo: 'ok', texto: `Restaurada por ${(data as any).custo} baba.` })
    await recarregarAcervo(); await recarregar()
  }

  const personagens = useMemo(
    () => [...new Set((cartas ?? []).map((c) => c.character_slug))].sort(), [cartas])

  // agrupa por card_type (personagem + skin) e ordena a pilha
  const pilhas = useMemo(() => {
    const filtradas = (cartas ?? []).filter((c) =>
      (personagem === 'todos' || c.character_slug === personagem) &&
      (tier === 'todos' || c.tier === tier) &&
      (selo === 'todos' || (selo === 'nenhum' ? c.seal === 'none' : c.seal === selo)))

    const mapa = new Map<string, Carta[]>()
    for (const c of filtradas) {
      const k = `${c.character_slug}|${c.skin}`
      ;(mapa.get(k) ?? mapa.set(k, []).get(k)!).push(c)
    }
    return [...mapa.entries()]
      .map(([k, v]) => ({ chave: k, copias: v.sort(melhorPrimeiro) }))
      .sort((A, B) => {
        const a = A.copias[0], b = B.copias[0]
        switch (ordem) {
          case 'raridade':     return b.tier_order - a.tier_order || a.skin.localeCompare(b.skin)
          case 'raridade-asc': return a.tier_order - b.tier_order || a.skin.localeCompare(b.skin)
          case 'personagem':   return a.character_slug.localeCompare(b.character_slug) ||
                                      a.tier_order - b.tier_order
          case 'skin':         return a.skin.localeCompare(b.skin) ||
                                      a.character_slug.localeCompare(b.character_slug)
          case 'serial':       return a.serial_number - b.serial_number
          case 'repetidas':    return B.copias.length - A.copias.length ||
                                      b.tier_order - a.tier_order
          case 'recentes':     return b.copy_id - a.copy_id
          default:             return 0
        }
      })
  }, [cartas, personagem, tier, selo, ordem])

  // O overlay navega pela lista inteira que está na tela, na mesma ordem
  // das pilhas — seta pra direita continua de onde o olho parou.
  const planas = pilhas.flatMap((p) => p.copias)

  if (erro) return <p className="p-6 text-red-400">{erro}</p>
  if (!cartas) return <p className="p-6 text-neutral-500">carregando…</p>

  const selo3 = ['branco', 'preto', 'rosa'] as const

  return (
    <div className="p-4 sm:p-6">
      <div className="mb-4 flex flex-wrap items-center gap-2 text-sm">
        <Selecao valor={personagem} aoMudar={setPersonagem}
          opcoes={[['todos', 'Todos os Belesmas'], ...personagens.map((p) => [p, p] as [string, string])]} />
        <Selecao valor={tier} aoMudar={(v) => setTier(v as any)}
          opcoes={[['todos', 'Todos os tiers'], ...TIERS.map((t) => [t, ROTULO_TIER[t]] as [string, string])]} />
        <Selecao valor={selo} aoMudar={(v) => setSelo(v as any)}
          opcoes={[['todos', 'Com e sem selo'], ['nenhum', 'Sem selo'],
                   ...selo3.map((s) => [s, `Selo ${s}`] as [string, string])]} />
        <Selecao valor={ordem} aoMudar={(v) => setOrdem(v as Ordem)}
          opcoes={[
            ['raridade', 'Mais rara primeiro'],
            ['raridade-asc', 'Mais comum primeiro'],
            ['personagem', 'Por personagem'],
            ['skin', 'Por skin (A–Z)'],
            ['serial', 'Menor serial'],
            ['repetidas', 'Mais repetidas'],
            ['recentes', 'Mais recentes'],
          ]} />
        <span className="ml-auto flex gap-2">
          <span className="chip"><strong>{cartas.length}</strong> cópias</span>
          <span className="chip"><strong>{pilhas.length}</strong> tipos</span>
        </span>
      </div>

      {msg && (
        <p className={`mb-3 rounded-lg p-2 text-sm ${msg.tipo === 'ok' ? 'aviso-ok' : 'aviso-ruim'}`}>
          {msg.texto}
        </p>
      )}

      {pilhas.length === 0 ? (
        <p className="py-16 text-center text-neutral-500">
          Nada aqui ainda. Abra um pacote.
        </p>
      ) : (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6">
          {pilhas.map(({ chave, copias }) => (
            <div key={chave} className="relative">
              <Figurinha
                carta={copias[0]}
                tamanho="miniatura"
                onClick={(e: any) => copias.length === 1
                  ? setEmFoco(planas.indexOf(copias[0]))
                  : abrirLeque(chave, e.currentTarget as HTMLElement)}
              />
              {copias.length > 1 && (
                <span className="selo-novo absolute -right-1.5 -top-1.5">x{copias.length}</span>
              )}

              {/* leque com todos os seriais — flutua, não empurra o grid */}
              {aberta === chave && (
                <div className="leque" data-leque
                  style={{
                    left: posLeque.x, top: posLeque.y,
                    ['--seta' as string]: `${posLeque.seta}%`,
                  }}>
                  <div className="leque-topo">
                    <b style={{ color: COR_TIER[copias[0].tier] }}>{copias[0].skin}</b>
                    <span>{RT[copias[0].tier]} · {copias.length} sua(s)</span>
                  </div>

                  <div className="leque-lista">
                    {copias.map((c, i) => (
                      <div key={c.copy_id} className="leque-linha">
                        <button onClick={() => { setEmFoco(planas.indexOf(c)); setAberta(null) }}
                          className="leque-serial" title="abrir em tela cheia">
                          <span style={{ color: COR_TIER[c.tier] }}>
                            {c.origin === 'forge'
                              ? `FORJADA ${String(c.forge_index).padStart(2, '0')}`
                              : `${String(c.serial_number).padStart(String(c.print_run).length, '0')}/${c.print_run}`}
                          </span>
                          {i === 0 && copias.length > 1 && <span className="tag tag-melhor">melhor</span>}
                          {c.seal !== 'none' && <span className="tag tag-selo">{c.seal}</span>}
                          {c.origin === 'forge' && <span className="tag tag-forjada">forjada</span>}
                          {c.damage_level > 0 && <span className="tag tag-desgaste">nv {c.damage_level}</span>}
                        </button>

                        <button className="leque-acao" title="baixar para o WhatsApp"
                          disabled={ocupado} onClick={() => baixarFigurinha(c, jogador!.nickname)}>
                          <svg width="13" height="13" viewBox="0 0 24 24" fill="none"
                               stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
                            <path d="M12 4v11m0 0 4-4m-4 4-4-4M4 19h16" />
                          </svg>
                        </button>

                        {c.damage_level > 0 && (
                          <button className="leque-acao restaurar" title="restaurar o desgaste"
                            disabled={ocupado} onClick={() => restaurar(c)}>
                            <svg width="13" height="13" viewBox="0 0 24 24" fill="none"
                                 stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
                              <path d="M12 3v3m0 12v3m9-9h-3M6 12H3m13.5-6.5-2 2m-5 5-2 2m0-9 2 2m5 5 2 2" />
                            </svg>
                          </button>
                        )}

                        {copias.length > 1 && c.seal === 'none' && c.tier !== 'prisma' && (
                          <button className="leque-acao vender" title="vender ao pool"
                            disabled={ocupado} onClick={() => vender(c)}>
                            <svg width="13" height="13" viewBox="0 0 24 24" fill="none"
                                 stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
                              <path d="M12 2v20M17 6.5C17 4.6 14.8 3.5 12 3.5S7 4.6 7 6.5s2 2.7 5 3.5 5 1.6 5 3.5-2.2 3-5 3-5-1.1-5-3" />
                            </svg>
                          </button>
                        )}
                      </div>
                    ))}
                  </div>

                  {copias.length === 1 && (
                    <p className="leque-rodape">Sua única cópia deste tipo — não dá para vender.</p>
                  )}
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {emFoco !== null && planas[emFoco] && (
        <CartaAberta
          lista={planas}
          indice={emFoco}
          aoFechar={() => setEmFoco(null)}
          aoNavegar={setEmFoco}
          aoMudar={recarregarAcervo}
        />
      )}
    </div>
  )
}

function Selecao({ valor, aoMudar, opcoes }: {
  valor: string; aoMudar: (v: string) => void; opcoes: [string, string][]
}) {
  return (
    <select value={valor} onChange={(e) => aoMudar(e.target.value)} className="campo">
      {opcoes.map(([v, r]) => <option key={v} value={v}>{r}</option>)}
    </select>
  )
}
