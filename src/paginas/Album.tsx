import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import { Figurinha, serialDe } from '../componentes/Figurinha'
import { CartaAberta } from '../componentes/CartaAberta'
import { ROTULO_TIER, COR_TIER, TIERS, type Carta, type Tier } from '../lib/tipos'
import '../styles/menu.css'
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

/**
 * Estreito o bastante para uma página só?
 *
 * Precisa ser ESTADO, não uma leitura solta no corpo do render: o álbum
 * decide quantas skins vão em cada página com este valor, e um matchMedia
 * lido uma vez não muda quando o telefone gira nem quando a janela é
 * redimensionada — metade das figurinhas sumiria até recarregar.
 */
function useEstreito() {
  const consulta = '(max-width: 768px)'
  const [estreito, setEstreito] = useState(
    () => typeof window !== 'undefined' && window.matchMedia(consulta).matches)
  useEffect(() => {
    const mq = window.matchMedia(consulta)
    const ouvir = () => setEstreito(mq.matches)
    ouvir()
    mq.addEventListener('change', ouvir)
    return () => mq.removeEventListener('change', ouvir)
  }, [])
  return estreito
}

export default function Album() {
  const estreito = useEstreito()
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
  // qual repetida vai ser colada, por card_type. Elas NAO sao iguais: serial,
  // selo e desgaste mudam, entao a escolha e do jogador.
  const [escolhida, setEscolhida] = useState<Map<number, number>>(new Map())
  const [escolhendo, setEscolhendo] = useState<{ tipo: number; x: number; y: number } | null>(null)


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

  /**
   * Toque seco abre o seletor de repetida; arrastar começa depois de 5px.
   *
   * Os listeners são presos AQUI, no próprio pointerdown, e não num efeito.
   * A versão anterior lia `gesto.current` dentro de um `useEffect` — só que
   * mexer num ref não re-renderiza, então o efeito nunca rodava depois do
   * pointerdown e nada arrastava.
   */
  function iniciarGesto(e: React.PointerEvent, carta: Carta, tipo: number) {
    const x0 = e.clientX, y0 = e.clientY
    let virouArraste = false
    let virouRolagem = false

    const mover = (ev: PointerEvent) => {
      const dx = Math.abs(ev.clientX - x0), dy = Math.abs(ev.clientY - y0)
      if (!virouArraste) {
        // deslize horizontal é rolagem do trilho, não arraste: só vira
        // arraste quando o movimento é mais vertical que horizontal
        if (Math.hypot(dx, dy) < 6) return
        if (dx > dy) {
          // ROLOU: marca, senão o pointerup abria o seletor de repetida a
          // cada deslize lateral. No celular era impossível ver o deck
          // inteiro — o menu pulava na cara em toda passada de dedo.
          virouRolagem = true
          window.removeEventListener('pointermove', mover)
          return
        }
        virouArraste = true
        setArrastando(carta)
      }
      ev.preventDefault()
      setPonteiro({ x: ev.clientX, y: ev.clientY })
    }
    const soltar = (ev: PointerEvent) => {
      window.removeEventListener('pointermove', mover)
      window.removeEventListener('pointerup', soltar)
      window.removeEventListener('pointercancel', soltar)
      if (virouArraste || virouRolagem) return
      // toque seco de verdade, e só quando há o que escolher
      if ((porTipoNoDeck.get(tipo) ?? []).length > 1) {
        setEscolhendo({ tipo, x: ev.clientX, y: ev.clientY })
      } else {
        setEmFoco(carta)
      }
    }
    window.addEventListener('pointermove', mover)
    window.addEventListener('pointerup', soltar)
    window.addEventListener('pointercancel', soltar)
  }

  // ------------------------------------------------------------- arraste
  //
  // A tela ACOMPANHA o dedo. No celular o deck fica no rodape e os slots de
  // cima do album ficam fora da tela: sem isto era impossivel colar neles,
  // porque para rolar a pagina era preciso soltar a figurinha.
  //
  // O alvo e recalculado a cada quadro, nao a cada pointermove: durante a
  // rolagem automatica o dedo fica parado e o slot embaixo dele muda mesmo
  // assim.
  useEffect(() => {
    if (!arrastando) return

    const BORDA = 110      // faixa sensivel no topo e no rodape, em px
    const MAX = 22         // px por quadro no limite da faixa
    let vel = 0
    let quadro = 0
    const pos = { x: -1, y: -1 }

    const mirar = () => {
      if (pos.x < 0) return
      const el = document.elementFromPoint(pos.x, pos.y)
      const slot = el?.closest('[data-slot]')
      const id = slot ? Number((slot as HTMLElement).dataset.slot) : null
      setSlotAlvo(id === (arrastando as any).card_type_id ? id : null)
    }

    const passo = () => {
      if (vel !== 0) {
        const antes = window.scrollY
        window.scrollBy(0, vel)
        // so vale reMirar se a tela realmente andou; no fim do documento
        // scrollBy nao faz nada e o alvo continua o mesmo
        if (window.scrollY !== antes) mirar()
      }
      quadro = requestAnimationFrame(passo)
    }
    quadro = requestAnimationFrame(passo)

    const mover = (e: PointerEvent) => {
      pos.x = e.clientX; pos.y = e.clientY
      setPonteiro({ x: e.clientX, y: e.clientY })

      const alturaTela = window.innerHeight
      if (e.clientY < BORDA) {
        // quanto mais perto da borda, mais rapido. Linear e previsivel:
        // com curva, o dedo passa de "parado" a "disparado" sem meio-termo.
        vel = -Math.ceil(((BORDA - e.clientY) / BORDA) * MAX)
      } else if (e.clientY > alturaTela - BORDA) {
        vel = Math.ceil(((e.clientY - (alturaTela - BORDA)) / BORDA) * MAX)
      } else {
        vel = 0
      }

      mirar()
    }

    const soltar = async () => {
      cancelAnimationFrame(quadro)
      const alvo = slotAlvo
      const carta = arrastando
      setArrastando(null); setSlotAlvo(null)
      if (alvo == null || !carta) return
      setColandoAgora(alvo)
      // `colar` faz upsert por (jogador, card_type): soltar sobre um slot ja
      // colado TROCA a figurinha que estava la.
      const { error } = await supabase.rpc('colar', { p_copy_id: carta.copy_id })
      if (!error) setColadas((m) => new Map(m).set(alvo, carta.copy_id))
      setTimeout(() => setColandoAgora(null), 700)
    }

    window.addEventListener('pointermove', mover)
    window.addEventListener('pointerup', soltar)
    window.addEventListener('pointercancel', soltar)
    return () => {
      cancelAnimationFrame(quadro)
      window.removeEventListener('pointermove', mover)
      window.removeEventListener('pointerup', soltar)
      window.removeEventListener('pointercancel', soltar)
    }
  }, [arrastando, slotAlvo])

  // Rede de segurança do virar-página. Precisa ficar aqui em cima, com os
  // outros hooks: embaixo dos early returns ele só rodaria em parte das
  // renderizações e quebraria a ordem dos hooks.
  useEffect(() => {
    if (!virando) return
    const t = setTimeout(() => { setIndice(alvoPag.current); setVirando('') }, 1200)
    return () => clearTimeout(t)
  }, [virando])

  if (erro) return <p className="p-6 text-red-400">{erro}</p>
  if (!spreads.length) return <p className="p-6 text-neutral-500">carregando…</p>

  // No celular a folha não é renderizada (uma página por vez), então
  // onAnimationEnd nunca dispararia e `virando` ficaria preso — o álbum
  // avançava uma vez e travava. Sem folha, a troca é direta.
  const semAnimacao = estreito ||
    (typeof window !== 'undefined' &&
     window.matchMedia('(prefers-reduced-motion: reduce)').matches)

  const virar = (d: number) => {
    if (virando) return
    const destino = indice + d
    if (destino < 0 || destino >= spreads.length) return
    alvoPag.current = destino
    if (semAnimacao) { setIndice(destino); return }
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
  // O deck mostra o que da para colar E o que da para TROCAR: se o slot ja
  // esta colado mas você tem outra cópia daquele tipo, ela continua na mão.
  // Colei uma comum e depois saiu uma selada? a selada aparece para trocar.
  const deck = minhas.filter((c) => {
    const tid = (c as any).card_type_id
    if (!doSpread.has(tid)) return false
    const colada = coladasValidas.get(tid)
    return !colada || colada.copy_id !== c.copy_id
  })
  const porTipoNoDeck = new Map<number, Carta[]>()
  for (const c of deck) {
    const tid = (c as any).card_type_id
    porTipoNoDeck.set(tid, [...(porTipoNoDeck.get(tid) ?? []), c])
  }

  const props = {
    tipos, coladas: coladasValidas, minhas,
    slotAlvo, colandoAgora, aoAbrir: setEmFoco,
    // enquanto se arrasta, o destino é marcado ANTES de o dedo chegar lá.
    // A crítica mais comum ao TCG Pocket é justamente o gesto sem alvo.
    tipoArrastado: arrastando ? ((arrastando as any).card_type_id as number) : null,
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
          <Pagina spread={virando === 'frente' ? destino : atual} lado="esq"
                  umaPagina={estreito} {...props} />
          {virando === 'frente' && <span className="sombra-varrida" />}

          {/* direita, por baixo: a próxima. No celular ela não existe — e é
              melhor não renderizar do que esconder com display:none, senão o
              conteúdo dela some sem ninguém perceber. */}
          {!estreito && <Pagina spread={virando ? destino : atual} lado="dir" {...props} />}

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
              ? <>puxe <b className="text-neutral-400">para cima</b> e solte no slot ·
                  deslize <b className="text-neutral-400">para o lado</b> para ver o resto ·
                  toque na que tem <span className="deck-badge deck-badge-exemplo">n</span> para
                  escolher qual repetida
                  <span className="ml-2 text-neutral-600">({porTipoNoDeck.size} tipos)</span></>
              : 'nada para colar nesta página'}
          </p>
          <div className="deck-trilho">
            {[...porTipoNoDeck.entries()].map(([tid, cs]) => {
              const alvo = cs.find((c) => c.copy_id === escolhida.get(tid)) ?? cs[0]
              return (
                <div
                  key={tid}
                  className={`deck-carta ${arrastando?.copy_id === alvo.copy_id ? 'arrastando' : ''}`}
                  onPointerDown={(e) => iniciarGesto(e, alvo, tid)}
                >
                  {cs.length > 1 && <span className="deck-badge">{cs.length}</span>}
                  <Figurinha carta={alvo} tamanho="miniatura" />
                  <p className="mt-0.5 truncate text-center text-[9px] text-neutral-500">
                    {serialDe(alvo)}
                  </p>
                </div>
              )
            })}
          </div>
        </div>
      )}

      {/* seletor de repetida: qual das suas vai para o álbum */}
      {escolhendo && (() => {
        const cs = porTipoNoDeck.get(escolhendo.tipo) ?? []
        if (cs.length === 0) return null
        const largura = 288
        const x = Math.min(Math.max(escolhendo.x, largura / 2 + 10), window.innerWidth - largura / 2 - 10)
        return (
          <>
            <div className="fixed inset-0 z-50" onClick={() => setEscolhendo(null)} />
            <div className="leque" style={{ left: x, top: Math.max(escolhendo.y - 240, 60) }}>
              <div className="leque-topo">
                <b style={{ color: COR_TIER[cs[0].tier] }}>{cs[0].skin}</b>
                <span>qual colar?</span>
              </div>
              <div className="leque-lista">
                {cs.map((c) => {
                  const marcada = (escolhida.get(escolhendo.tipo) ?? cs[0].copy_id) === c.copy_id
                  return (
                    <button key={c.copy_id} className="leque-linha w-full"
                      onClick={() => {
                        setEscolhida((m) => new Map(m).set(escolhendo.tipo, c.copy_id))
                        setEscolhendo(null)
                      }}>
                      <span className="leque-serial">
                        <span style={{ color: COR_TIER[c.tier] }}>{serialDe(c)}</span>
                        {marcada && <span className="tag tag-melhor">escolhida</span>}
                        {c.seal !== 'none' && <span className="tag tag-selo">{c.seal}</span>}
                        {c.origin === 'forge' && <span className="tag tag-forjada">forjada</span>}
                        {c.damage_level > 0 && <span className="tag tag-desgaste">nv {c.damage_level}</span>}
                      </span>
                    </button>
                  )
                })}
              </div>
              <p className="leque-rodape">
                As repetidas não são iguais: serial, selo e desgaste mudam. A que ficar no álbum
                é a que você colar.
              </p>
            </div>
          </>
        )
      })()}

      {/* Faixas de rolagem. Sem elas ninguem descobre que arrastar ate a
          borda faz a tela andar — e no celular essa e a unica forma de
          alcancar os slots de cima. */}
      {arrastando && (
        <>
          <div className="faixa-rolagem faixa-rolagem-topo"><span>▲</span></div>
          <div className="faixa-rolagem faixa-rolagem-base"><span>▼</span></div>
        </>
      )}

      {/* fantasma seguindo o dedo */}
      {arrastando && (
        <div className="fantasma" style={{ left: ponteiro.x, top: ponteiro.y }}>
          <Figurinha carta={arrastando} tamanho="miniatura" shader />
        </div>
      )}

      {emFoco && (
        <CartaAberta lista={[emFoco]} indice={0}
          aoFechar={() => setEmFoco(null)} aoNavegar={() => {}} aoMudar={carregar} />
      )}
    </div>
  )
}

// ================================================================ página
function Pagina({
  spread, lado, tipos, coladas, minhas, slotAlvo, colandoAgora, aoAbrir, nua, tipoArrastado,
  umaPagina,
}: {
  spread: Spread; lado: 'esq' | 'dir'
  /** celular: existe só a página esquerda, e ela carrega o spread inteiro */
  umaPagina?: boolean
  tipos: Tipo[]; coladas: Map<number, Carta>; minhas: Carta[]
  slotAlvo: number | null; colandoAgora: number | null
  aoAbrir: (c: Carta) => void
  nua?: boolean
  tipoArrastado?: number | null
}) {
  const classe = `pagina pagina-${lado}${nua ? '' : ''}`

  // ---------------------------------------------------------- selados
  if (spread.tier === 'selados') {
    const seladas = minhas.filter((c) => c.seal !== 'none').sort((a, b) => a.tier_order - b.tier_order)
    const metade = Math.ceil(seladas.length / 2)
    const fatia = umaPagina
      ? seladas
      : lado === 'esq' ? seladas.slice(0, metade) : seladas.slice(metade)
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
  // O spread divide as skins entre as duas páginas. No celular só a esquerda
  // existe, então dividir ali APAGA metade do tier — era por isso que
  // Origens mostrava só chuva e musgo, sem noite nem original.
  const skinsAqui = umaPagina
    ? (lado === 'esq' ? spread.skins : [])
    : spread.skins.length === 1
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
          <span>
            {ROTULO_TIER[spread.tier as Tier]} · {feitas}/{totalTier}
            {/* sem página direita não há a placa da tiragem: ela vem para cá */}
            {umaPagina && doTier[0] && <> · tiragem {doTier[0].print_run}</>}
          </span>
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
                      alvo={slotAlvo === t.id} marcado={tipoArrastado === t.id}
                      colando={colandoAgora === t.id} aoAbrir={aoAbrir} />
              ))}
            </div>
          )
        })}
      </div>
      <span className="numero-pagina">{spread.titulo.toUpperCase()}</span>
    </div>
  )
}

function Slot({ tipo, carta, alvo, marcado, colando, aoAbrir }: {
  tipo: Tipo; carta?: Carta; alvo: boolean; marcado: boolean; colando: boolean
  aoAbrir: (c: Carta) => void
}) {
  const nome = tipo.character_name.replace('Belesma do ', '')
  if (!carta) {
    return (
      <div>
        <div data-slot={tipo.id}
          className={`slot slot-vazio ${marcado ? 'slot-marcado' : ''} ${alvo ? 'slot-alvo' : ''}`}>
          {/* enquanto a figurinha está na mão, o destino vira um "+" */}
          {marcado ? <span className="mais-colar">+</span> : '?'}
        </div>
        <p className={`mt-1 truncate text-center text-[10px] ${marcado ? 'text-[var(--luz)]' : 'text-neutral-600'}`}>
          {marcado ? 'cole aqui' : nome}
        </p>
      </div>
    )
  }
  return (
    <div>
      <button data-slot={tipo.id} onClick={() => aoAbrir(carta)}
        className={`slot slot-colada block w-full ${colando ? 'colando' : ''}
                    ${marcado ? 'slot-trocavel' : ''} ${alvo ? 'slot-alvo' : ''}`}>
        <Figurinha carta={carta} tamanho="miniatura" />
        {carta.origin === 'forge' && <span className="marca-forjada">FORJADA</span>}
        {/* já tem uma colada e você trouxe outra: soltar aqui TROCA */}
        {marcado && <span className="troca-colar">⇄</span>}
      </button>
      <p className={`mt-1 truncate text-center text-[10px] ${marcado ? 'text-[var(--luz)]' : 'text-neutral-500'}`}>
        {marcado ? 'trocar por esta' : <>{nome} <span className="text-neutral-700">{serialDe(carta)}</span></>}
      </p>
    </div>
  )
}
