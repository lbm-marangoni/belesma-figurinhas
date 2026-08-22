import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Figurinha } from '../componentes/Figurinha'
import { ROTULO_TIER, COR_TIER, type Carta, type Tier } from '../lib/tipos'
import '../styles/menu.css'

/**
 * Conquistas (spec §11): índice global, par de Aura, caçada de serial e as
 * vitrines do grupo.
 *
 * Tudo aqui é PÚBLICO de propósito — o índice global é do grupo, não de cada
 * um. Forjada não conta: descoberta e estreia só valem para origin='pull'
 * (spec §7).
 */

type Tipo = {
  skin: string; tier: Tier; tier_order: number; print_run: number
  distribuidas: number; descoberto: boolean; primeiro: string | null; em: string | null
}
type Personagem = { slug: string; nome: string; descoberto: boolean; tipos: Tipo[] }
type Indice = { personagens: Personagem[]; descobertos: number; total_personagens: number }
type Par = { nickname: string; personagem: string; nome: string; em: string }
type Rank = {
  nickname: string; copias: number; selos: number
  melhor_serial: number; melhor_skin: string; melhor_personagem: string
  melhor_print_run: number; unos: number
}

/**
 * Miniatura do TIPO, não de uma cópia. O índice global fala de tipos — não
 * há serial para desenhar, e a arte pode nem ser sua. Não descoberto fica
 * preto com "?" (spec §11).
 */
function Selo({ personagem, skin, tier, descoberto, titulo }: {
  personagem: string; skin: string; tier: Tier; descoberto: boolean; titulo: string
}) {
  if (!descoberto) {
    return (
      <div title="ainda não descoberta"
        className="grid aspect-square place-items-center rounded border border-neutral-800
                   bg-black text-sm font-bold text-neutral-700">
        ?
      </div>
    )
  }
  return (
    <div title={titulo} className="relative aspect-square overflow-hidden rounded"
         style={{ border: `1.5px solid ${COR_TIER[tier]}` }}>
      <img
        src={`${import.meta.env.BASE_URL}figurinhas/${personagem}/${skin}.jpg`}
        alt={skin} loading="lazy"
        className="h-full w-full object-cover"
      />
    </div>
  )
}

export default function Conquistas() {
  const [indice, setIndice] = useState<Indice | null>(null)
  const [pares, setPares] = useState<Par[]>([])
  const [rank, setRank] = useState<Rank[]>([])
  const [vitrines, setVitrines] = useState<{ nickname: string; cartas: Carta[] }[]>([])
  const [aberto, setAberto] = useState<string | null>(null)

  useEffect(() => {
    ;(async () => {
      const [gi, pa, rk, ps] = await Promise.all([
        supabase.rpc('global_index'),
        supabase.rpc('pares_de_aura'),
        supabase.rpc('ranking_serial'),
        supabase.from('players_public').select('nickname, showcase_1, showcase_2, showcase_3'),
      ])
      setIndice(gi.data as Indice)
      setPares((pa.data ?? []) as Par[])
      setRank((rk.data ?? []) as Rank[])

      const ids = (ps.data ?? []).flatMap((p) => [p.showcase_1, p.showcase_2, p.showcase_3]).filter(Boolean)
      const mapa = new Map<number, Carta>()
      if (ids.length) {
        const { data: cs } = await supabase.from('card_copies').select(
          `id, serial_number, seal, origin, damage_level, forge_index, verify_code,
           card_types!inner ( print_run, tier, tier_order, skin, characters!inner ( slug, name ) )`)
          .in('id', ids)
        for (const r of (cs ?? []) as any[]) {
          mapa.set(r.id, {
            copy_id: r.id, serial_number: r.serial_number, seal: r.seal, origin: r.origin,
            damage_level: r.damage_level, forge_index: r.forge_index, verify_code: r.verify_code,
            print_run: r.card_types.print_run, tier: r.card_types.tier,
            tier_order: r.card_types.tier_order, skin: r.card_types.skin, art_path: '',
            character_slug: r.card_types.characters.slug,
            character_name: r.card_types.characters.name,
          })
        }
      }
      setVitrines((ps.data ?? [])
        .map((p) => ({
          nickname: p.nickname,
          cartas: [p.showcase_1, p.showcase_2, p.showcase_3]
            .map((i) => (i ? mapa.get(i) : null)).filter(Boolean) as Carta[],
        }))
        .filter((v) => v.cartas.length > 0))
    })()
  }, [])

  if (!indice) return <p className="p-6 text-neutral-500">carregando…</p>

  return (
    <div className="mx-auto max-w-[112rem] space-y-10 p-4 sm:px-8 sm:py-6">
      {/* ------------------------------------------------------ índice global */}
      <section>
        <h2 className="text-lg font-semibold tracking-tight">
          {indice.descobertos}/{indice.total_personagens} Belesmas
        </h2>
        <p className="mb-3 text-xs text-neutral-500">
          Descoberta é do grupo inteiro. Forjada não descobre nada.
        </p>

        {indice.personagens.map((p) => {
          const achados = p.tipos.filter((t) => t.descoberto).length
          return (
            <div key={p.slug} className="mb-2 rounded border border-neutral-800">
              <button
                onClick={() => setAberto(aberto === p.slug ? null : p.slug)}
                className="flex w-full items-center justify-between px-3 py-2 text-left text-sm"
              >
                <span className={p.descoberto ? 'font-medium' : 'text-neutral-600'}>
                  {p.descoberto ? p.nome : '???'}
                </span>
                <span className="flex items-center gap-2 text-neutral-500">
                  {achados}/{p.tipos.length} skins
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                    strokeWidth="2.5" strokeLinecap="round"
                    style={{ transform: aberto === p.slug ? 'rotate(180deg)' : 'none',
                             transition: 'transform 200ms ease' }}>
                    <path d="m6 9 6 6 6-6" />
                  </svg>
                </span>
              </button>

              {/* a fileira de figurinhas do personagem, sempre visível */}
              <div className="grid grid-cols-7 gap-1.5 border-t border-neutral-900 px-3 py-3
                              sm:grid-cols-14 sm:gap-2 lg:grid-cols-[repeat(27,minmax(0,1fr))]">
                {p.tipos.map((t) => (
                  <Selo key={t.skin} personagem={p.slug} skin={t.skin} tier={t.tier}
                        descoberto={t.descoberto}
                        titulo={`${t.skin} · ${ROTULO_TIER[t.tier]} · ${t.distribuidas}/${t.print_run} distribuídas`} />
                ))}
              </div>

              {/* abre com transicao de altura, nao com corte seco */}
              <div className={`indice-corpo ${aberto === p.slug ? 'aberto' : ''}`}>
                <div>
                  <div className="indice-linha indice-cabec">
                    <span>skin</span><span>tier</span><span>distribuídas</span>
                    <span className="text-right">estreia mundial</span>
                  </div>
                  {p.tipos.map((t) => {
                    const pct = t.print_run > 0 ? (t.distribuidas / t.print_run) * 100 : 0
                    return (
                      <div key={t.skin}
                        className={`indice-linha ${t.descoberto ? '' : 'indice-oculta'}`}>
                        <span className="truncate">{t.descoberto ? t.skin : '???'}</span>
                        <span className="pilula"
                          style={{ color: t.descoberto ? COR_TIER[t.tier] : '#4a4a50' }}>
                          {ROTULO_TIER[t.tier]}
                        </span>
                        <span className="flex items-center gap-2">
                          <span className="tabular-nums text-neutral-400">
                            {t.distribuidas}/{t.print_run}
                          </span>
                          <span className="barra flex-1">
                            <i style={{
                              width: `${Math.max(pct, t.distribuidas > 0 ? 4 : 0)}%`,
                              background: t.descoberto ? COR_TIER[t.tier] : '#3a3a41',
                            }} />
                          </span>
                        </span>
                        <span className="truncate text-right text-neutral-500">
                          {t.primeiro
                            ? <>{t.primeiro} · {new Date(t.em!).toLocaleDateString('pt-BR')}</>
                            : '—'}
                        </span>
                      </div>
                    )
                  })}
                </div>
              </div>
            </div>
          )
        })}
      </section>

      {/* ------------------------------------------------------ par de aura */}
      <section>
        <h2 className="text-lg font-semibold tracking-tight">Par de Aura</h2>
        <p className="mb-2 text-xs text-neutral-500">
          Aura Branca <strong className="text-neutral-400">e</strong> Aura Preta do mesmo
          Belesma. São 3 cópias de cada no mundo — é o evento mais raro do jogo.
        </p>
        {pares.length === 0 ? (
          <p className="text-sm text-neutral-600">ninguém conseguiu ainda</p>
        ) : (
          <ul className="text-sm">
            {pares.map((p, i) => (
              <li key={i} className="rounded border border-pink-900 bg-pink-950/30 px-3 py-2 text-pink-200">
                <strong>{p.nickname}</strong> fechou o par de {p.nome}
                <span className="text-pink-400/70"> · {new Date(p.em).toLocaleDateString('pt-BR')}</span>
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* ------------------------------------------------------ caçada */}
      <section>
        <h2 className="text-lg font-semibold tracking-tight">Caçada de serial</h2>
        <p className="mb-2 text-xs text-neutral-500">Menores seriais e selos, por jogador.</p>
        <table className="w-full text-left text-sm">
          <thead className="text-neutral-500">
            <tr className="border-b border-neutral-800">
              <th className="w-1/4 py-1 font-normal">jogador</th>
              <th className="text-right font-normal">selos</th>
              <th className="text-right font-normal">nº 1</th>
              <th className="text-right font-normal">melhor serial</th>
              <th className="text-right font-normal">cópias</th>
            </tr>
          </thead>
          <tbody>
            {rank.map((r) => (
              <tr key={r.nickname} className="border-b border-neutral-900">
                <td className="py-1">{r.nickname}</td>
                <td className="text-right tabular-nums">{r.selos}</td>
                <td className="text-right tabular-nums text-neutral-400">{r.unos}</td>
                <td className="text-right tabular-nums">
                  {r.melhor_serial}/{r.melhor_print_run}
                  <span className="text-neutral-600"> · {r.melhor_personagem} {r.melhor_skin}</span>
                </td>
                <td className="text-right tabular-nums text-neutral-400">{r.copias}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {/* ------------------------------------------------------ vitrines */}
      <section>
        <h2 className="text-lg font-semibold tracking-tight">Vitrines</h2>
        <p className="mb-2 text-xs text-neutral-500">Três figurinhas que cada um escolheu mostrar.</p>
        {vitrines.length === 0 ? (
          <p className="text-sm text-neutral-600">ninguém montou vitrine ainda</p>
        ) : (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-5">
            {vitrines.map((v) => (
              <div key={v.nickname} className="rounded border border-neutral-800 p-3">
                <p className="mb-2 text-sm font-medium">{v.nickname}</p>
                <div className="grid grid-cols-3 gap-2">
                  {v.cartas.map((c) => <Figurinha key={c.copy_id} carta={c} tamanho="miniatura" />)}
                </div>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  )
}
