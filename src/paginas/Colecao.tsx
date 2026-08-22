import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import { Figurinha } from '../componentes/Figurinha'
import { CartaAberta } from '../componentes/CartaAberta'
import { ROTULO_TIER, TIERS, type Carta, type Selo, type Tier } from '../lib/tipos'

/** Repetidas do mesmo card_type empilham. A da frente é a de melhor serial:
 *  selada tem prioridade, depois o menor número (spec §11). */
function melhorPrimeiro(a: Carta, b: Carta) {
  const seladaA = a.seal !== 'none' ? 0 : 1
  const seladaB = b.seal !== 'none' ? 0 : 1
  if (seladaA !== seladaB) return seladaA - seladaB
  return a.serial_number - b.serial_number
}

export default function Colecao() {
  const { jogador } = useSessao()
  const [cartas, setCartas] = useState<Carta[] | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [personagem, setPersonagem] = useState('todos')
  const [tier, setTier] = useState<'todos' | Tier>('todos')
  const [selo, setSelo] = useState<'todos' | Exclude<Selo, 'none'> | 'nenhum'>('todos')
  const [aberta, setAberta] = useState<string | null>(null)
  const [emFoco, setEmFoco] = useState<number | null>(null)

  useEffect(() => {
    if (!jogador) return
    ;(async () => {
      const { data, error } = await supabase
        .from('card_copies')
        .select(`copy_id:id, serial_number, seal, origin, damage_level, forge_index, verify_code,
                 card_types!inner ( print_run, tier, tier_order, skin, art_path,
                                    characters!inner ( slug, name ) )`)
        .eq('owner_id', jogador.id)
        .order('id')
      if (error) return setErro(error.message)

      setCartas((data ?? []).map((r: any) => ({
        copy_id: r.copy_id, serial_number: r.serial_number, seal: r.seal,
        origin: r.origin, damage_level: r.damage_level, forge_index: r.forge_index,
        verify_code: r.verify_code, print_run: r.card_types.print_run,
        tier: r.card_types.tier, tier_order: r.card_types.tier_order,
        skin: r.card_types.skin, art_path: r.card_types.art_path,
        character_slug: r.card_types.characters.slug,
        character_name: r.card_types.characters.name,
      })))
    })()
  }, [jogador])

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
      .sort((a, b) =>
        a.copias[0].tier_order - b.copias[0].tier_order ||
        a.copias[0].character_slug.localeCompare(b.copias[0].character_slug))
  }, [cartas, personagem, tier, selo])

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
        <span className="ml-auto flex gap-2">
          <span className="chip"><strong>{cartas.length}</strong> cópias</span>
          <span className="chip"><strong>{pilhas.length}</strong> tipos</span>
        </span>
      </div>

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
                onClick={() => copias.length === 1
                  ? setEmFoco(planas.indexOf(copias[0]))
                  : setAberta(aberta === chave ? null : chave)}
              />
              {copias.length > 1 && (
                <span className="selo-novo absolute -right-1.5 -top-1.5">x{copias.length}</span>
              )}

              {/* leque com todos os seriais */}
              {aberta === chave && (
                <ul className="mt-1 rounded border border-neutral-700 bg-neutral-900 p-1.5 text-[11px]">
                  {copias.map((c) => (
                    <li key={c.copy_id}>
                      <button onClick={() => setEmFoco(planas.indexOf(c))}
                        className="flex w-full justify-between gap-2 py-0.5 font-mono tabular-nums
                                   hover:text-white">
                        <span className="text-neutral-300">
                          {c.origin === 'forge'
                            ? `FORJADA ${c.forge_index}`
                            : `${c.serial_number}/${c.print_run}`}
                        </span>
                        {c.seal !== 'none' && <span className="text-neutral-500">selo {c.seal}</span>}
                      </button>
                    </li>
                  ))}
                </ul>
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
