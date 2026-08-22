import { useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import { Figurinha } from '../componentes/Figurinha'
import { CartaAberta } from '../componentes/CartaAberta'
import { ROTULO_TIER, type Carta, type Tier } from '../lib/tipos'
import '../styles/album.css'

/**
 * Álbum Panini (spec §11).
 *
 * Uma página por TEMA (= skin), com um slot por personagem. As páginas vêm de
 * `album_pages`, nunca de lista no código: personagem novo entra nos slots
 * sozinho, sem tocar aqui.
 *
 * A página "Selados" só aparece para quem tem alguma cópia com selo.
 */

type Pagina = {
  id: number; slug: string; title: string; page_order: number
  tier_filter: Tier | null; skin_filter: string | null; seal_only: boolean
}
type Tipo = {
  id: number; skin: string; tier: Tier; tier_order: number; print_run: number
  character_slug: string; character_name: string; display_order: number
}

export default function Album() {
  const { jogador } = useSessao()
  const [paginas, setPaginas] = useState<Pagina[]>([])
  const [tipos, setTipos] = useState<Tipo[]>([])
  const [minhas, setMinhas] = useState<Carta[]>([])
  const [erro, setErro] = useState<string | null>(null)

  const [indice, setIndice] = useState(0)
  const [virando, setVirando] = useState<'' | 'frente' | 'tras'>('')
  const alvo = useRef(0)
  const [emFoco, setEmFoco] = useState<Carta | null>(null)

  useEffect(() => {
    if (!jogador) return
    ;(async () => {
      const [pg, ct, cc] = await Promise.all([
        supabase.from('album_pages').select('*').order('page_order'),
        supabase.from('card_types').select(
          `id, skin, tier, tier_order, print_run, characters!inner ( slug, name, display_order )`),
        supabase.from('card_copies').select(
          `copy_id:id, serial_number, seal, origin, damage_level, forge_index, verify_code,
           card_types!inner ( id, print_run, tier, tier_order, skin,
                              characters!inner ( slug, name ) )`)
          .eq('owner_id', jogador.id),
      ])
      if (pg.error || ct.error || cc.error) {
        return setErro((pg.error ?? ct.error ?? cc.error)!.message)
      }
      setPaginas(pg.data as Pagina[])
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
      })))
    })()
  }, [jogador])

  // melhor cópia por (personagem, skin): selada na frente, depois menor serial
  const porTipo = useMemo(() => {
    const m = new Map<string, Carta>()
    for (const c of minhas) {
      const k = `${c.character_slug}|${c.skin}`
      const atual = m.get(k)
      if (!atual) { m.set(k, c); continue }
      const melhorNovo = (c.seal !== 'none' ? 0 : 1) * 1e6 + c.serial_number
      const melhorAtual = (atual.seal !== 'none' ? 0 : 1) * 1e6 + atual.serial_number
      if (melhorNovo < melhorAtual) m.set(k, c)
    }
    return m
  }, [minhas])

  const temSelo = minhas.some((c) => c.seal !== 'none')
  const visiveis = useMemo(() => paginas.filter((p) =>
    // a página "Selados" só existe para quem tem selo (spec §11)
    (!p.seal_only || temSelo) &&
    // As páginas são por skin, mas o §11 pede as duas Auras LADO A LADO numa
    // moldura conjunta. Duas páginas separadas tornariam isso impossível,
    // então a de aura-preta some e a de aura-branca vira a página "Auras",
    // com as duas skins de cada Belesma juntas.
    p.skin_filter !== 'aura-preta'
  ), [paginas, temSelo])

  const total = useMemo(() => {
    const preenchidos = tipos.filter((t) => porTipo.has(`${t.character_slug}|${t.skin}`)).length
    return { preenchidos, de: tipos.length }
  }, [tipos, porTipo])

  if (erro) return <p className="p-6 text-red-400">{erro}</p>
  if (!visiveis.length) return <p className="p-6 text-neutral-500">carregando…</p>

  const virar = (delta: number) => {
    if (virando) return
    const destino = indice + delta
    if (destino < 0 || destino >= visiveis.length) return
    alvo.current = destino
    setVirando(delta > 0 ? 'frente' : 'tras')
  }

  const aoFim = () => {
    setIndice(alvo.current)
    setVirando('')
  }

  const pagAtual = visiveis[indice]
  const pagAlvo = visiveis[alvo.current] ?? pagAtual
  // quem vai por baixo é a página de destino; a de cima é a que gira
  const embaixo = virando === 'frente' ? pagAlvo : pagAtual
  const emCima = virando === 'frente' ? pagAtual : pagAlvo

  return (
    <div className="p-4 sm:p-6">
      <div className="mb-3 flex items-center justify-between text-sm">
        <span className="text-neutral-400">
          Álbum · <strong className="text-neutral-100">{total.preenchidos}</strong> de {total.de}
        </span>
        <span className="text-neutral-500">
          página {indice + 1} de {visiveis.length}
        </span>
      </div>

      <div className="livro">
        <Folha pagina={embaixo} tipos={tipos} porTipo={porTipo} minhas={minhas}
               classe="folha folha-proxima" aoAbrir={setEmFoco} />
        <Folha
          pagina={virando ? emCima : pagAtual}
          tipos={tipos} porTipo={porTipo} minhas={minhas}
          classe={`folha folha-atual ${virando ? `virando-${virando}` : ''}`}
          aoAnimacaoFim={aoFim}
          aoAbrir={setEmFoco}
        />
      </div>

      <div className="mt-4 flex items-center justify-center gap-3 text-sm">
        <button onClick={() => virar(-1)} disabled={indice === 0 || !!virando}
          className="rounded border border-neutral-700 px-4 py-1 text-neutral-300 disabled:opacity-30">
          ← anterior
        </button>
        <button onClick={() => virar(1)} disabled={indice === visiveis.length - 1 || !!virando}
          className="rounded border border-neutral-700 px-4 py-1 text-neutral-300 disabled:opacity-30">
          próxima →
        </button>
      </div>

      {emFoco && (
        <CartaAberta lista={[emFoco]} indice={0}
          aoFechar={() => setEmFoco(null)} aoNavegar={() => {}} />
      )}
    </div>
  )
}

// ---------------------------------------------------------------- folha
function Folha({
  pagina, tipos, porTipo, minhas, classe, aoAnimacaoFim, aoAbrir,
}: {
  pagina: Pagina
  tipos: Tipo[]
  porTipo: Map<string, Carta>
  minhas: Carta[]
  classe: string
  aoAnimacaoFim?: () => void
  aoAbrir: (c: Carta) => void
}) {
  // página de selos: mostra as cópias seladas em vez dos slots por personagem
  if (pagina.seal_only) {
    const seladas = minhas.filter((c) => c.seal !== 'none')
      .sort((a, b) => a.tier_order - b.tier_order)
    return (
      <section className={classe} onAnimationEnd={aoAnimacaoFim}>
        <Cabecalho titulo="Selados" sub={`${seladas.length} no seu acervo`} />
        <div className="grid grid-cols-3 gap-3 sm:grid-cols-5">
          {seladas.map((c) => (
            <button key={c.copy_id} onClick={() => aoAbrir(c)} className="slot-puxada">
              <Figurinha carta={c} tamanho="miniatura" />
            </button>
          ))}
        </div>
      </section>
    )
  }

  // ---------------------------------------------------- página das Auras
  if (pagina.tier_filter === 'aura') {
    const personagens = [...new Map(tipos.filter((t) => t.tier === 'aura')
      .map((t) => [t.character_slug, t])).values()]
      .sort((a, b) => a.display_order - b.display_order)
    const tenho = personagens.flatMap((p) => ['aura-branca', 'aura-preta']
      .filter((sk) => porTipo.has(`${p.character_slug}|${sk}`))).length

    return (
      <section className={classe} onAnimationEnd={aoAnimacaoFim}>
        <Cabecalho titulo="Auras" sub={`Aura · ${tenho} de ${personagens.length * 2}`} />
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {personagens.map((p) => {
            const branca = porTipo.get(`${p.character_slug}|aura-branca`)
            const preta = porTipo.get(`${p.character_slug}|aura-preta`)
            const par = !!branca && !!preta
            const dupla = (
              <div className="grid grid-cols-2 gap-2">
                {[branca, preta].map((c, i) => c ? (
                  <button key={i} onClick={() => aoAbrir(c)}
                    className={`block w-full ${c.origin === 'forge' ? 'slot-forjada' : 'slot-puxada'}`}>
                    <Figurinha carta={c} tamanho="miniatura" />
                  </button>
                ) : <div key={i} className="slot-vazio">?</div>)}
              </div>
            )
            return (
              <div key={p.character_slug}>
                {/* moldura CONJUNTA, uma para as duas (spec §11) */}
                {par ? <div className="moldura-aura"><div>{dupla}</div></div> : dupla}
                <p className="mt-1 text-center text-[11px] text-neutral-500">
                  {p.character_name.replace('Belesma do ', '')}
                  {par && <span className="text-pink-400"> · par completo</span>}
                </p>
              </div>
            )
          })}
        </div>
      </section>
    )
  }

  const doTema = tipos
    .filter((t) => t.skin === pagina.skin_filter)
    .sort((a, b) => a.display_order - b.display_order)

  const preenchidos = doTema.filter((t) => porTipo.has(`${t.character_slug}|${t.skin}`)).length

  return (
    <section className={classe} onAnimationEnd={aoAnimacaoFim}>
      <Cabecalho
        titulo={pagina.title}
        sub={`${pagina.tier_filter ? ROTULO_TIER[pagina.tier_filter] : ''} · ${preenchidos} de ${doTema.length}`}
      />
      <div className="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-5">
        {doTema.map((t) => {
          const c = porTipo.get(`${t.character_slug}|${t.skin}`)
          const slot = c ? (
            <button onClick={() => aoAbrir(c)}
              className={`block w-full ${c.origin === 'forge' ? 'slot-forjada' : 'slot-puxada'}`}>
              <Figurinha carta={c} tamanho="miniatura" />
            </button>
          ) : (
            <div className="slot-vazio">?</div>
          )
          return (
            <div key={t.id}>
              {slot}
              <p className="mt-1 truncate text-center text-[11px] text-neutral-500">
                {t.character_name.replace('Belesma do ', '')}
              </p>
            </div>
          )
        })}
      </div>
    </section>
  )
}

const Cabecalho = ({ titulo, sub }: { titulo: string; sub: string }) => (
  <header className="mb-4 border-b border-neutral-800 pb-2 pl-3">
    <h2 className="text-lg font-semibold tracking-tight">{titulo}</h2>
    <p className="text-xs text-neutral-500">{sub}</p>
  </header>
)
