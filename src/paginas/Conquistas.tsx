import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { Figurinha } from '../componentes/Figurinha'
import { ROTULO_TIER, COR_TIER, type Carta, type Tier } from '../lib/tipos'

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
    <div className="space-y-8 p-4 sm:p-6">
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
                <span className="text-neutral-500">{achados}/{p.tipos.length} skins</span>
              </button>

              {aberto === p.slug && (
                <table className="w-full border-t border-neutral-800 text-left text-xs">
                  <thead className="text-neutral-600">
                    <tr>
                      <th className="py-1 pl-3 font-normal">skin</th>
                      <th className="font-normal">tier</th>
                      <th className="text-right font-normal">saíram</th>
                      <th className="pr-3 text-right font-normal">estreia</th>
                    </tr>
                  </thead>
                  <tbody>
                    {p.tipos.map((t) => (
                      <tr key={t.skin} className="border-t border-neutral-900">
                        <td className="py-1 pl-3">
                          {t.descoberto
                            ? t.skin
                            : <span className="text-neutral-700">? ? ?</span>}
                        </td>
                        <td style={{ color: t.descoberto ? COR_TIER[t.tier] : '#404040' }}>
                          {ROTULO_TIER[t.tier]}
                        </td>
                        <td className="text-right tabular-nums text-neutral-400">
                          {t.distribuidas} de {t.print_run}
                        </td>
                        <td className="pr-3 text-right text-neutral-500">
                          {t.primeiro
                            ? <>{t.primeiro} · {new Date(t.em!).toLocaleDateString('pt-BR')}</>
                            : '—'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
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
              <th className="py-1 font-normal">jogador</th>
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
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
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
