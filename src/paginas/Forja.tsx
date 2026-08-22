import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import { Figurinha, serialDe } from '../componentes/Figurinha'
import { ROTULO_TIER, COR_TIER, type Carta, type Tier } from '../lib/tipos'

/**
 * Forja (spec §7).
 *
 * Consome 5 cópias do mesmo tier — de personagens e skins quaisquer — e
 * devolve 1 do tier imediatamente acima, marcada FORJADA.
 *
 * As 5 saem de circulação PARA SEMPRE. Não voltam ao pool de sorteio. Por
 * isso a confirmação é explícita e diz isso com todas as letras.
 */

type Tiers = { slug: Tier; tier_order: number; forjavel: boolean }[]

export default function Forja() {
  const { jogador, recarregar } = useSessao()
  const [acervo, setAcervo] = useState<Carta[]>([])
  const [tiers, setTiers] = useState<Tiers>([])
  const [tier, setTier] = useState<Tier | ''>('')
  const [escolhidas, setEscolhidas] = useState<number[]>([])
  const [confirmando, setConfirmando] = useState(false)
  const [msg, setMsg] = useState<{ tipo: 'ok' | 'erro'; texto: string } | null>(null)
  const [resultado, setResultado] = useState<Carta | null>(null)
  const [ocupado, setOcupado] = useState(false)

  const carregar = async () => {
    if (!jogador) return
    const [cc, ts] = await Promise.all([
      supabase.from('card_copies').select(
        `copy_id:id, card_type_id, serial_number, seal, origin, damage_level, forge_index, verify_code,
         card_types!inner ( print_run, tier, tier_order, skin, characters!inner ( slug, name ) )`)
        .eq('owner_id', jogador.id).eq('burned', false).order('id'),
      supabase.from('tiers').select('slug, tier_order, forjavel').order('tier_order'),
    ])
    setAcervo((cc.data ?? []).map((r: any) => ({
      copy_id: r.copy_id, card_type_id: r.card_type_id,
      serial_number: r.serial_number, seal: r.seal, origin: r.origin,
      damage_level: r.damage_level, forge_index: r.forge_index, verify_code: r.verify_code,
      print_run: r.card_types.print_run, tier: r.card_types.tier,
      tier_order: r.card_types.tier_order, skin: r.card_types.skin, art_path: '',
      character_slug: r.card_types.characters.slug,
      character_name: r.card_types.characters.name,
    })))
    setTiers((ts.data ?? []) as Tiers)
  }
  useEffect(() => { carregar() }, [jogador])

  const forjaveis = useMemo(() => tiers.filter((t) => t.forjavel), [tiers])
  const doTier = useMemo(
    () => acervo.filter((c) => c.tier === tier), [acervo, tier])
  const acima = useMemo(() => {
    const at = tiers.find((t) => t.slug === tier)
    return at ? tiers.find((t) => t.tier_order === at.tier_order + 1)?.slug : undefined
  }, [tier, tiers])

  if (!jogador) return null

  const alternar = (id: number) => {
    setMsg(null)
    setEscolhidas((v) => v.includes(id) ? v.filter((x) => x !== id)
      : v.length >= 5 ? v : [...v, id])
  }

  async function forjar() {
    setOcupado(true); setMsg(null)
    const { data, error } = await supabase.rpc('forge', { p_copy_ids: escolhidas })
    setOcupado(false); setConfirmando(false)
    if (error) return setMsg({ tipo: 'erro', texto: error.message })

    setEscolhidas([])
    await carregar(); await recarregar()
    const { data: nova } = await supabase.from('card_copies').select(
      `copy_id:id, serial_number, seal, origin, damage_level, forge_index, verify_code,
       card_types!inner ( print_run, tier, tier_order, skin, characters!inner ( slug, name ) )`)
      .eq('id', (data as any).copy_id).single()
    if (nova) {
      const r: any = nova
      setResultado({
        copy_id: r.copy_id, card_type_id: r.card_type_id,
      serial_number: r.serial_number, seal: r.seal, origin: r.origin,
        damage_level: r.damage_level, forge_index: r.forge_index, verify_code: r.verify_code,
        print_run: r.card_types.print_run, tier: r.card_types.tier,
        tier_order: r.card_types.tier_order, skin: r.card_types.skin, art_path: '',
        character_slug: r.card_types.characters.slug,
        character_name: r.card_types.characters.name,
      })
    }
    setMsg({ tipo: 'ok', texto: 'Forjada. As 5 saíram de circulação para sempre.' })
  }

  return (
    <div className="p-4 sm:p-6">
      <h2 className="text-lg font-semibold">Forja</h2>
      <p className="mb-4 max-w-2xl text-sm text-neutral-400">
        Cinco figurinhas do <strong className="text-neutral-200">mesmo tier</strong> — personagens e
        skins quaisquer — viram uma do tier de cima, marcada <strong>FORJADA</strong>. As cinco
        saem de circulação para sempre: não voltam ao pool de sorteio de ninguém.
        A forja só produz até <strong className="text-neutral-200">Mítica</strong>.
      </p>

      {msg && (
        <p className={`mb-4 rounded-lg p-2 text-sm ${msg.tipo === 'ok' ? 'aviso-ok' : 'aviso-ruim'}`}>
          {msg.texto}
        </p>
      )}

      {resultado && (
        <div className="painel mb-5 flex items-center gap-4 p-4">
          <div className="w-28"><Figurinha carta={resultado} interativa /></div>
          <div className="text-sm">
            <p className="text-xs uppercase tracking-widest text-amber-400">saiu da forja</p>
            <p className="mt-1 text-base font-medium">
              {resultado.character_name} · {resultado.skin}
            </p>
            <p style={{ color: COR_TIER[resultado.tier] }}>
              {ROTULO_TIER[resultado.tier]} · {serialDe(resultado)}
            </p>
          </div>
        </div>
      )}

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <select value={tier} onChange={(e) => { setTier(e.target.value as Tier); setEscolhidas([]) }}
          className="campo">
          <option value="">escolha o tier…</option>
          {forjaveis.map((t) => {
            const n = acervo.filter((c) => c.tier === t.slug).length
            return (
              <option key={t.slug} value={t.slug} disabled={n < 5}>
                {ROTULO_TIER[t.slug]} — {n} no acervo{n < 5 ? ' (precisa de 5)' : ''}
              </option>
            )
          })}
        </select>

        {tier && acima && (
          <span className="chip">
            5 × {ROTULO_TIER[tier as Tier]} → 1 × <strong>{ROTULO_TIER[acima]}</strong>
          </span>
        )}
        <span className="ml-auto chip"><strong>{escolhidas.length}</strong>/5 escolhidas</span>
      </div>

      {tier && (
        <div className="grid grid-cols-3 gap-3 sm:grid-cols-5 md:grid-cols-8">
          {doTier.map((c) => (
            <button key={c.copy_id} onClick={() => alternar(c.copy_id)} className="text-left">
              <Figurinha carta={c} tamanho="miniatura" selecionada={escolhidas.includes(c.copy_id)} />
              <p className="mt-0.5 truncate text-[10px] text-neutral-500">
                {c.character_slug} · {serialDe(c)}
              </p>
            </button>
          ))}
          {doTier.length === 0 && (
            <p className="col-span-full py-8 text-center text-sm text-neutral-600">
              você não tem figurinhas desse tier
            </p>
          )}
        </div>
      )}

      {escolhidas.length === 5 && !confirmando && (
        <button onClick={() => setConfirmando(true)} className="btn btn-forte mt-5">
          forjar
        </button>
      )}

      {confirmando && (
        <div className="painel mt-5 max-w-lg border-amber-900 p-4">
          <p className="text-sm text-amber-300">
            Isto é <strong>irreversível</strong>. As 5 figurinhas escolhidas são queimadas e somem
            do jogo — ninguém mais vai puxá-las em pacote. Em troca você recebe 1 de{' '}
            <strong>{acima ? ROTULO_TIER[acima] : '?'}</strong>, sorteada, marcada FORJADA e sem selo.
          </p>
          <div className="mt-3 flex gap-2">
            <button onClick={forjar} disabled={ocupado} className="btn btn-perigo">
              {ocupado ? '...' : 'queimar as 5 e forjar'}
            </button>
            <button onClick={() => setConfirmando(false)} className="btn btn-fraco">voltar</button>
          </div>
        </div>
      )}
    </div>
  )
}
