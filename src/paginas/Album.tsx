import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import { Figurinha, serialDe } from '../componentes/Figurinha'
import { CartaAberta } from '../componentes/CartaAberta'
import { ROTULO_TIER, TIERS, type Carta, type Tier } from '../lib/tipos'
import '../styles/album.css'

/**
 * Álbum Panini (spec §11), em formato de álbum de verdade.
 *
 * Duas páginas abertas, uma folha que gira sobre a lombada, e um deck embaixo
 * de onde o jogador ARRASTA a figurinha para colar no slot. A colagem
 * persiste no banco (`album_colagem`) — o gesto não pode se perder no reload,
 * e a spec §2 proíbe localStorage como fonte de verdade.
 *
 * As páginas são agrupadas por TIER, não por skin. A spec dava um exemplo por
 * skin ("Elementais · Fogo"), mas isso rendia 27 páginas de 3 slots cada,
 * magras demais para parecer álbum. Agrupando por tema, cada abertura tem de
 * 3 a 12 slots e ganha identidade visual própria.
 *
 * O que continua vindo do banco: os tipos e os personagens. Personagem novo
 * entra nos slots sozinho, sem tocar neste arquivo.
 */

type Tipo = {
  id: number; skin: string; tier: Tier; tier_order: number; print_run: number
  character_slug: string; character_name: string; display_order: number
}
type Colada = { card_type_id: number; copy_id: number }
type Spread = { tier: Tier | 'selados'; titulo: string; skins: string[] }

const TEMAS: Record<Tier, string> = {
  comum: 'Origens', incomum: 'Metais', rara: 'Elementais', epica: 'Gemas',
  lendaria: 'Pedra', mitica: 'Ouro', cosmica: 'Cosmos', divina: 'Celestial',
  infernal: 'Inferno', aura: 'Auras', diamante: 'Diamante', prisma: 'Prismas 1/1',
}

export default function Album() {
  const { jogador } = useSessao()
  const [tipos, setTipos] = useState<Tipo[]>([])
  const [minhas, setMinhas] = useState<Carta[]>([])
  const [coladas, setColadas] = useState<Map<number, number>>(new Map())
  const [erro, setErro] = useState<string | null>(null)

  const [indice, setIndice] = useState(0)
  const [virando, setVirando] = useState<'' | 'frente' | 'tras'>('')
  const alvoPag = useRef(0)
  const [emFoco, setEmFoco] = useState<Carta | null>(null)

  // arraste do deck para o slot
  const [arrastando, setArrastando] = useState<Carta | null>(null)
  const [ponteiro, setPonteiro] = useState({ x: 0, y: 0 })
  const [slotAlvo, setSlotAlvo] = useState<number | null>(null)
  const [colandoAgora, setColandoAgora] = useState<number | null>(null)

  const carregar = useCallback(async () => {
    if (!jogador) return
    const [ct, cc, ac] = await Promise.all([
      supabase.from('card_types').select(
        `id, skin, tier, tier_order, print_run, characters!inner ( slug, name, display_order )`),
      supabase.from('card_copies').select(
        `copy_id:id, card_type_id, serial_number, seal, origin, damage_level, forge_index, verify_code,
         card_types!inner ( print_run, tier, tier_order, skin, characters!inner ( slug, name ) )`)
        .eq('owner_id', jogador.id),
      supabase.from('album_colagem').select('card_type_id, copy_id').eq('player_id', jogador.id),
    ])
    if (ct.error || cc.error || ac.error) {
      return setErro((ct.error ?? cc.error ?? ac.error)!.message)
    }
    setTipos((ct.data ?? []).map((r: any) => ({
      id: r.id, skin: r.skin, tier: r.tier, tier_order: r.tier_order,
      print_run: r.print_run, character_slug: r.characters.slug,
      character_name: r.characters.name, display_order: r.characters.display_order,
    })))
    setMinhas((cc.data ?? []).map((r: any) => ({
      copy_id: r.copy_id, serial_number: r.serial_number, seal: r.seal,
      origin: r.origin, damage_level: r.damage_level, forge_index: r.forge_index,
      verify_code: r.verify_code, print_run: r.card_types.print_run,
      tier: r.card_types.tier, tier_order: r.card_types.tier_order,
      skin: r.card_types.skin, art_path: '',
      character_slug: r.card_types.characters.slug,
      character_name: r.card_types.characters.name,
      card_type_id: r.card_type_id,
    } as Carta & { card_type_id: number })))
    setColadas(new Map(((ac.data ?? []) as Colada[]).map((c) => [c.card_type_id, c.copy_id])))
  }, [jogador])

  useEffect(() => { carregar() }, [carregar])

  const donoDe = useMemo(() => new Set(minhas.map((c) => c.copy_id)), [minhas])
  // a colagem só vale se a cópia ainda for sua — troca desfaz sozinha
  const coladasValidas = useMemo(() => {
    const m = new Map<number, Carta>()
    for (const [tipoId, copyId] of coladas) {
      if (!donoDe.has(copyId)) continue
      const c = minhas.find((x) => x.copy_id === copyId)
      if (c) m.set(tipoId, c)
    }
    return m
  }, [coladas, minhas, donoDe])

  const spreads = useMemo<Spread[]>(() => {
    const s: Spread[] = TIERS.map((t) => ({
      tier: t,
      titulo: TEMAS[t],
      skins: [...new Set(tipos.filter((x) => x.tier === t).map((x) => x.skin))].sort(),
    })).filter((x) => x.skins.length > 0)
    if (minhas.some((c) => c.seal !== 'none')) {
      s.push({ tier: 'selados', titulo: 'Selados', skins: [] })
    }
    return s
  }, [tipos, minhas])

  const total = useMemo(() => ({
    coladas: coladasValidas.size,
    tenho: new Set(minhas.map((c) => (c as any).card_type_id)).size,
    de: tipos.length,
  }), [coladasValidas, minhas, tipos])

  // ------------------------------------------------------------- arraste
  useEffect(() => {
    if (!arrastando) return
    const mover = (e: PointerEvent) => {
      setPonteiro({ x: e.clientX, y: e.clientY })
      const el = document.elementFromPoint(e.clientX, e.clientY)
      const slot = el?.closest('[data-slot]')
      const id = slot ? Number((slot as HTMLElement).dataset.slot) : null
      setSlotAlvo(id === (arrastando as any).card_type_id ? id : null)
    }
    const soltar = async () => {
      const alvo = slotAlvo
      const carta = arrastando
      setArrastando(null); setSlotAlvo(null)
      if (alvo == null || !carta) return
      setColandoAgora(alvo)
      const { error } = await supabase.rpc('colar', { p_copy_id: carta.copy_id })
      if (!error) setColadas((m) => new Map(m).set(alvo, carta.copy_id))
      setTimeout(() => setColandoAgora(null), 700)
    }
    window.addEventListener('pointermove', mover)
    window.addEventListener('pointerup', soltar)
    window.addEventListener('pointercancel', soltar)
    return () => {
      window.removeEventListener('pointermove', mover)
      window.removeEventListener('pointerup', soltar)
      window.removeEventListener('pointercancel', soltar)
    }
  }, [arrastando, slotAlvo])

  if (erro) return <p className="p-6 text-red-400">{erro}</p>
  if (!spreads.length) return <p className="p-6 text-neutral-500">carregando…</p>

  const virar = (d: number) => {
    if (virando) return
    const destino = indice + d
    if (destino < 0 || destino >= spreads.length) return
    alvoPag.current = destino
    setVirando(d > 0 ? 'frente' : 'tras')
  }
  const aoFim = () => { setIndice(alvoPag.current); setVirando('') }

  const atual = spreads[indice]
  const destino = spreads[alvoPag.current] ?? atual

  // deck: o que tenho desta abertura e ainda não colei
  const doSpread = new Set(
    atual.tier === 'selados'
      ? []
      : tipos.filter((t) => t.tier === atual.tier).map((t) => t.id))
  const deck = minhas.filter((c) => {
    const tid = (c as any).card_type_id
    return doSpread.has(tid) && !coladasValidas.has(tid)
  })
  const porTipoNoDeck = new Map<number, Carta[]>()
  for (const c of deck) {
    const tid = (c as any).card_type_id
    porTipoNoDeck.set(tid, [...(porTipoNoDeck.get(tid) ?? []), c])
  }

  const props = {
    tipos, coladas: coladasValidas, minhas,
    slotAlvo, colandoAgora, aoAbrir: setEmFoco,
  }

  return (
    <div className="p-3 sm:p-5">
      <div className="mx-auto mb-3 flex max-w-[60rem] items-center justify-between text-sm">
        <span className="text-neutral-400">
          <strong className="text-neutral-100">{total.coladas}</strong> coladas ·{' '}
          {total.tenho} no acervo · {total.de} no álbum
        </span>
        <button
          onClick={async () => { await supabase.rpc('colar_tudo'); carregar() }}
          className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-400"
        >
          colar tudo
        </button>
      </div>

      <div className="mesa">
        <div className={`livro tema-${atual.tier}`}>
          {/* esquerda: no avanço já mostra a de destino sendo revelada */}
          <Pagina spread={virando === 'frente' ? destino : atual} lado="esq" {...props} />
          {virando === 'frente' && <span className="sombra-varrida" />}

          {/* direita, por baixo: a próxima */}
          <Pagina spread={virando ? destino : atual} lado="dir" {...props} />

          {/* a folha que gira sobre a lombada */}
          {virando && (
            <div className={`folha virando-${virando}`} onAnimationEnd={aoFim}>
              <div className={`folha-face tema-${(virando === 'frente' ? atual : destino).tier}`}>
                <Pagina spread={virando === 'frente' ? atual : destino} lado="dir" nua {...props} />
              </div>
              <div className={`folha-face folha-verso tema-${(virando === 'frente' ? destino : atual).tier}`}>
                <Pagina spread={virando === 'frente' ? destino : atual} lado="esq" nua {...props} />
              </div>
              <span className="sombra-dobra" />
            </div>
          )}
        </div>
      </div>

      <div className="mx-auto mt-4 flex max-w-[60rem] items-center justify-center gap-4 text-sm">
        <button onClick={() => virar(-1)} disabled={indice === 0 || !!virando}
          className="rounded border border-neutral-700 px-4 py-1 text-neutral-300 disabled:opacity-30">
          ←
        </button>
        <span className="text-neutral-500">{atual.titulo} · {indice + 1}/{spreads.length}</span>
        <button onClick={() => virar(1)} disabled={indice === spreads.length - 1 || !!virando}
          className="rounded border border-neutral-700 px-4 py-1 text-neutral-300 disabled:opacity-30">
          →
        </button>
      </div>

      {/* ------------------------------------------------------------ deck */}
      {atual.tier !== 'selados' && (
        <div className="deck">
          <p className="mb-1.5 text-[11px] uppercase tracking-widest text-neutral-500">
            {deck.length > 0
              ? 'arraste para o slot vazio'
              : 'nada para colar nesta página'}
          </p>
          <div className="deck-trilho">
            {[...porTipoNoDeck.entries()].map(([tid, cs]) => (
              <div
                key={tid}
                className={`deck-carta ${arrastando?.copy_id === cs[0].copy_id ? 'arrastando' : ''}`}
                onPointerDown={(e) => {
                  e.preventDefault()
                  setPonteiro({ x: e.clientX, y: e.clientY })
                  setArrastando(cs[0])
                }}
              >
                {cs.length > 1 && <span className="deck-badge">+{cs.length - 1}</span>}
                <Figurinha carta={cs[0]} tamanho="miniatura" />
              </div>
            ))}
          </div>
        </div>
      )}

      {/* fantasma seguindo o dedo */}
      {arrastando && (
        <div className="fantasma" style={{ left: ponteiro.x, top: ponteiro.y }}>
          <Figurinha carta={arrastando} tamanho="miniatura" shader />
        </div>
      )}

      {emFoco && (
        <CartaAberta lista={[emFoco]} indice={0}
          aoFechar={() => setEmFoco(null)} aoNavegar={() => {}} />
      )}
    </div>
  )
}

// ================================================================ página
function Pagina({
  spread, lado, tipos, coladas, minhas, slotAlvo, colandoAgora, aoAbrir, nua,
}: {
  spread: Spread; lado: 'esq' | 'dir'
  tipos: Tipo[]; coladas: Map<number, Carta>; minhas: Carta[]
  slotAlvo: number | null; colandoAgora: number | null
  aoAbrir: (c: Carta) => void
  nua?: boolean
}) {
  const classe = `pagina pagina-${lado}${nua ? '' : ''}`

  // ---------------------------------------------------------- selados
  if (spread.tier === 'selados') {
    const seladas = minhas.filter((c) => c.seal !== 'none').sort((a, b) => a.tier_order - b.tier_order)
    const metade = Math.ceil(seladas.length / 2)
    const fatia = lado === 'esq' ? seladas.slice(0, metade) : seladas.slice(metade)
    return (
      <div className={classe}>
        {lado === 'esq' && (
          <div className="tema-titulo">
            <h2>Selados</h2><span>{seladas.length} no seu acervo</span>
          </div>
        )}
        <div className="grade-slots">
          {fatia.map((c) => (
            <button key={c.copy_id} className="slot slot-colada" onClick={() => aoAbrir(c)}>
              <Figurinha carta={c} tamanho="miniatura" />
            </button>
          ))}
        </div>
        <span className="numero-pagina">SELADOS</span>
      </div>
    )
  }

  const doTier = tipos.filter((t) => t.tier === spread.tier)
  const meio = Math.ceil(spread.skins.length / 2)
  const skinsAqui = spread.skins.length === 1
    ? (lado === 'esq' ? spread.skins : [])
    : (lado === 'esq' ? spread.skins.slice(0, meio) : spread.skins.slice(meio))

  const totalTier = doTier.length
  const feitas = doTier.filter((t) => coladas.has(t.id)).length

  // página direita sem slots vira a placa do tema
  if (skinsAqui.length === 0) {
    const t0 = doTier[0]
    return (
      <div className={classe}>
        <div className="grid h-full place-items-center text-center">
          <div>
            <p className="text-[.6rem] uppercase tracking-[.3em] text-[color-mix(in_srgb,var(--tinta)_70%,transparent)]">
              tiragem
            </p>
            <p className="my-1 text-5xl font-bold text-[var(--luz)]">{t0?.print_run}</p>
            <p className="text-xs text-neutral-400">
              cópias de cada, no mundo inteiro
            </p>
            <p className="mt-6 text-sm text-neutral-300">{feitas} de {totalTier} coladas</p>
          </div>
        </div>
        <span className="numero-pagina">{spread.titulo.toUpperCase()}</span>
      </div>
    )
  }

  return (
    <div className={classe}>
      {lado === 'esq' && (
        <div className="tema-titulo">
          <h2>{spread.titulo}</h2>
          <span>{ROTULO_TIER[spread.tier as Tier]} · {feitas}/{totalTier}</span>
        </div>
      )}

      <div className="grade-slots">
        {skinsAqui.map((skin) => {
          const daSkin = doTier.filter((t) => t.skin === skin)
            .sort((a, b) => a.display_order - b.display_order)
          return (
            <div key={skin} className="contents">
              <p className="linha-skin">{skin.replace('-', ' ')}</p>
              {daSkin.map((t) => (
                <Slot key={t.id} tipo={t} carta={coladas.get(t.id)}
                      alvo={slotAlvo === t.id} colando={colandoAgora === t.id}
                      aoAbrir={aoAbrir} />
              ))}
            </div>
          )
        })}
      </div>
      <span className="numero-pagina">{spread.titulo.toUpperCase()}</span>
    </div>
  )
}

function Slot({ tipo, carta, alvo, colando, aoAbrir }: {
  tipo: Tipo; carta?: Carta; alvo: boolean; colando: boolean
  aoAbrir: (c: Carta) => void
}) {
  const nome = tipo.character_name.replace('Belesma do ', '')
  if (!carta) {
    return (
      <div>
        <div data-slot={tipo.id} className={`slot slot-vazio ${alvo ? 'slot-alvo' : ''}`}>?</div>
        <p className="mt-1 truncate text-center text-[10px] text-neutral-600">{nome}</p>
      </div>
    )
  }
  return (
    <div>
      <button data-slot={tipo.id} onClick={() => aoAbrir(carta)}
        className={`slot slot-colada block w-full ${colando ? 'colando' : ''}`}>
        <Figurinha carta={carta} tamanho="miniatura" />
        {carta.origin === 'forge' && <span className="marca-forjada">FORJADA</span>}
      </button>
      <p className="mt-1 truncate text-center text-[10px] text-neutral-500">
        {nome} <span className="text-neutral-700">{serialDe(carta)}</span>
      </p>
    </div>
  )
}
