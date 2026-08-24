import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { TIERS, ROTULO_TIER, type Tier } from '../lib/tipos'

/**
 * Construtor de pacotes (§18 + adendo).
 *
 * A tela inteira e um editor de LINHAS: pack_definitions, pack_slots e
 * pack_slot_odds. Nao existe pacote "comum" escrito em lugar nenhum aqui.
 *
 * O salvamento manda a definicao inteira de uma vez, cabecalho e slots
 * juntos, porque gravar em partes deixaria o pacote com odds fora de 100 por
 * alguns milissegundos - e alguem podendo abrir nesse intervalo.
 */

type Odd = { tier: string; weight: number }
type Filtro = {
  tiers?: string[]; characters?: string[]; skins?: string[]
  tiers_min?: string; tiers_max?: string
}
type Slot = { ordem: number; filtro: Filtro; garantido: boolean; odds: Odd[] }
type Def = {
  id?: number; slug: string; name: string; descricao: string | null
  art_path: string | null; tamanho: number; distribuicao: string
  elegivel_loja: boolean; preco_baba: number | null
  limite_global: number | null; aberturas_realizadas?: number
  taxa_quente: number; taxa_bonus: number; taxa_promocao: number
  pity_limite: number | null; pity_piso_tier: string | null
  allotment_quantidade: number; diario_quantidade: number; diario_ciclo: number
  ativo: boolean; em_maos?: number; slots: Slot[]
}

const VAZIO = (): Def => ({
  slug: '', name: '', descricao: '', art_path: 'packs/booster-comum.png',
  tamanho: 4, distribuicao: 'admin', elegivel_loja: false, preco_baba: null,
  limite_global: null, taxa_quente: 0, taxa_bonus: 0, taxa_promocao: 0,
  pity_limite: null, pity_piso_tier: null, allotment_quantidade: 0,
  diario_quantidade: 0, diario_ciclo: 1, ativo: true,
  slots: [{ ordem: 1, filtro: {}, garantido: false, odds: [] }],
})

const campo = 'rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm'
const soma = (o: Odd[]) => o.reduce((a, x) => a + (Number(x.weight) || 0), 0)

export default function AdminPacotes() {
  const [lista, setLista] = useState<Def[]>([])
  const [edit, setEdit] = useState<Def | null>(null)
  const [msg, setMsg] = useState<{ t: 'ok' | 'erro'; x: string } | null>(null)
  const [ocupado, setOcupado] = useState(false)
  const [personagens, setPersonagens] = useState<string[]>([])
  const [skins, setSkins] = useState<{ skin: string; tier: string }[]>([])
  const [ev, setEv] = useState<any>(null)
  const [viab, setViab] = useState<any>(null)
  const [preview, setPreview] = useState<any>(null)
  const [relatorio, setRelatorio] = useState<any[]>([])
  const [entrega, setEntrega] = useState({ alvo: 'todos', n: 1, diario: false })

  const carregar = useCallback(async () => {
    const [p, ch, ct, rel] = await Promise.all([
      supabase.rpc('admin_pacotes'),
      supabase.from('characters').select('slug').order('display_order'),
      supabase.from('card_types').select('skin, tier'),
      supabase.rpc('admin_relatorio_loja'),
    ])
    setLista((p.data ?? []) as Def[])
    setPersonagens(((ch.data ?? []) as any[]).map((x) => x.slug))
    const vistas = new Map<string, string>()
    for (const r of (ct.data ?? []) as any[]) vistas.set(r.skin, r.tier)
    setSkins([...vistas].map(([skin, tier]) => ({ skin, tier })))
    setRelatorio((rel.data ?? []) as any[])
  }, [])
  useEffect(() => { carregar() }, [carregar])

  // EV e avisos acompanham o que esta salvo, nao o rascunho: os dois se
  // calculam no banco a partir dos slots gravados.
  useEffect(() => {
    if (!edit?.id) { setEv(null); setViab(null); setPreview(null); return }
    supabase.rpc('admin_ev_pacote', { p_id: edit.id }).then(({ data }) => setEv(data))
    supabase.rpc('admin_viabilidade_pacote', { p_id: edit.id }).then(({ data }) => setViab(data))
  }, [edit?.id])

  async function salvar() {
    if (!edit) return
    setOcupado(true); setMsg(null)
    const { data, error } = await supabase.rpc('admin_salvar_pacote', { p_def: edit as any })
    setOcupado(false)
    if (error) return setMsg({ t: 'erro', x: error.message })
    const r = data as any
    setMsg({ t: 'ok', x: `"${r.slug}" ${r.novo ? 'criado' : 'salvo'} · EV ${r.ev.ev} baba` })
    setEv(r.ev); setViab(r.viabilidade)
    await carregar()
    setEdit((e) => (e ? { ...e, id: r.id } : e))
  }

  async function sugerir(i: number) {
    if (!edit) return
    const { data, error } = await supabase.rpc('admin_sugerir_odds',
      { p_filtro: edit.slots[i].filtro as any })
    if (error) return setMsg({ t: 'erro', x: error.message })
    const d = data as any
    if (!d.odds?.length) return setMsg({ t: 'erro', x: d.aviso ?? 'sem estoque nesse filtro' })
    // a sugestao arredonda a 2 casas; a sobra vai para o maior peso
    const odds: Odd[] = d.odds.map((o: any) => ({ tier: o.tier, weight: Number(o.weight) }))
    const falta = 100 - soma(odds)
    const maior = odds.reduce((a, b) => (a.weight >= b.weight ? a : b))
    maior.weight = Number((maior.weight + falta).toFixed(2))
    const slots = [...edit.slots]
    slots[i] = { ...slots[i], odds }
    setEdit({ ...edit, slots })
    setMsg({ t: 'ok', x: `sugestão aplicada no slot ${i + 1} · ` +
      d.odds.map((o: any) => `${o.tier} ${o.weight}% (${o.estoque} em estoque, ` +
        `~${o.aberturas_ate_esgotar} aberturas)`).join(' · ') })
  }

  async function simular() {
    if (!edit?.id) return
    setOcupado(true)
    const { data, error } = await supabase.rpc('admin_preview_pacote',
      { p_id: edit.id, p_n: 1000 })
    setOcupado(false)
    if (error) return setMsg({ t: 'erro', x: error.message })
    setPreview(data)
  }

  const mudarSlot = (i: number, m: Partial<Slot>) => {
    if (!edit) return
    const slots = [...edit.slots]; slots[i] = { ...slots[i], ...m }
    setEdit({ ...edit, slots })
  }
  const lista4 = (v?: string[]) => (v ?? []).join(', ')
  const parse = (s: string) => s.split(',').map((x) => x.trim()).filter(Boolean)

  return (
    <div className="space-y-6 text-sm">
      {/* as skins do set inteiro, para o campo de filtro sugerir enquanto se
          digita em vez de exigir que o admin lembre de cor */}
      <datalist id="skins-do-set">
        {skins.map((s) => <option key={s.skin} value={s.skin}>{s.tier}</option>)}
      </datalist>

      {msg && (
        <p className={`rounded border p-2 ${msg.t === 'ok'
          ? 'border-emerald-900 bg-emerald-950/50 text-emerald-300'
          : 'border-red-900 bg-red-950/50 text-red-300'}`}>{msg.x}</p>
      )}

      {/* ------------------------------------------------------------ lista */}
      <section>
        <div className="mb-2 flex items-center gap-3">
          <h3 className="font-medium">Definições</h3>
          <button onClick={() => { setEdit(VAZIO()); setPreview(null) }}
            className="btn btn-forte px-3 py-1">novo pacote</button>
        </div>
        <div className="overflow-x-auto"><table className="w-full text-left">
          <thead className="text-[11px] uppercase tracking-widest text-neutral-500">
            <tr><th className="py-1">pacote</th><th>distribuição</th><th>slots</th>
              <th>preço</th><th>aberturas</th><th>em mãos</th><th></th></tr>
          </thead>
          <tbody>
            {lista.map((d) => (
              <tr key={d.id} className="border-t border-neutral-900">
                <td className="py-1.5">
                  <span className={d.ativo ? '' : 'text-neutral-600 line-through'}>{d.name}</span>
                  <span className="ml-2 text-xs text-neutral-600">{d.slug}</span>
                </td>
                <td className="text-neutral-400">
                  {d.distribuicao}{d.elegivel_loja && <span className="text-[var(--acento)]"> · loja</span>}
                </td>
                <td className="text-neutral-400">{d.slots.length}</td>
                <td className="tabular-nums text-neutral-400">{d.preco_baba ?? '—'}</td>
                <td className="tabular-nums text-neutral-400">
                  {d.aberturas_realizadas}{d.limite_global != null && ` / ${d.limite_global}`}
                  {d.limite_global != null && d.aberturas_realizadas! >= d.limite_global && (
                    <span className="ml-1 text-red-400">esgotada</span>
                  )}
                </td>
                <td className="tabular-nums text-neutral-400">{d.em_maos}</td>
                <td className="text-right">
                  <button onClick={() => { setEdit(structuredClone(d)); setPreview(null) }}
                    className="mr-2 text-xs text-neutral-400 underline">editar</button>
                  <button
                    onClick={async () => {
                      await supabase.rpc('admin_pacote_ativo', { p_id: d.id, p_ativo: !d.ativo })
                      carregar()
                    }}
                    className="text-xs text-neutral-500 underline">
                    {d.ativo ? 'desativar' : 'ativar'}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table></div>
      </section>

      {/* ------------------------------------------------------------ editor */}
      {edit && (
        <section className="rounded border border-neutral-800 p-3">
          <div className="mb-3 flex items-center gap-3">
            <h3 className="font-medium">{edit.id ? `Editando ${edit.slug}` : 'Novo pacote'}</h3>
            <button onClick={salvar} disabled={ocupado} className="btn btn-forte px-3 py-1">salvar</button>
            <button onClick={() => setEdit(null)} className="btn btn-fraco px-3 py-1">fechar</button>
          </div>

          <div className="grid gap-2 sm:grid-cols-3 lg:grid-cols-4">
            <L r="slug"><input className={campo} value={edit.slug}
              onChange={(e) => setEdit({ ...edit, slug: e.target.value })} /></L>
            <L r="nome"><input className={campo} value={edit.name}
              onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></L>
            <L r="arte"><input className={campo} value={edit.art_path ?? ''}
              onChange={(e) => setEdit({ ...edit, art_path: e.target.value })} /></L>
            <L r="tamanho"><input type="number" className={campo} value={edit.tamanho}
              onChange={(e) => setEdit({ ...edit, tamanho: Number(e.target.value) })} /></L>
            <L r="distribuição">
              <select className={campo} value={edit.distribuicao}
                onChange={(e) => setEdit({ ...edit, distribuicao: e.target.value })}>
                {['loja', 'admin', 'missao', 'diario', 'allotment'].map((x) =>
                  <option key={x} value={x}>{x}</option>)}
              </select>
            </L>
            <L r="limite da edição"><input type="number" className={campo}
              value={edit.limite_global ?? ''} placeholder="ilimitado"
              onChange={(e) => setEdit({ ...edit,
                limite_global: e.target.value === '' ? null : Number(e.target.value) })} /></L>
            <L r="allotment inicial"><input type="number" className={campo}
              value={edit.allotment_quantidade}
              onChange={(e) => setEdit({ ...edit, allotment_quantidade: Number(e.target.value) })} /></L>
            <L r="diário (qtd / ciclo)">
              <div className="flex gap-1">
                <input type="number" className={`${campo} w-16`} value={edit.diario_quantidade}
                  onChange={(e) => setEdit({ ...edit, diario_quantidade: Number(e.target.value) })} />
                <input type="number" className={`${campo} w-16`} value={edit.diario_ciclo}
                  onChange={(e) => setEdit({ ...edit, diario_ciclo: Number(e.target.value) })} />
              </div>
            </L>
            <L r="quente / bônus / promoção">
              <div className="flex gap-1">
                {(['taxa_quente', 'taxa_bonus', 'taxa_promocao'] as const).map((k) => (
                  <input key={k} type="number" step="0.001" className={`${campo} w-16`}
                    value={edit[k]} onChange={(e) => setEdit({ ...edit, [k]: Number(e.target.value) })} />
                ))}
              </div>
            </L>
            <L r="pity (nº / piso)">
              <div className="flex gap-1">
                <input type="number" className={`${campo} w-16`} value={edit.pity_limite ?? ''}
                  onChange={(e) => setEdit({ ...edit,
                    pity_limite: e.target.value === '' ? null : Number(e.target.value) })} />
                <select className={campo} value={edit.pity_piso_tier ?? ''}
                  onChange={(e) => setEdit({ ...edit, pity_piso_tier: e.target.value || null })}>
                  <option value="">—</option>
                  {TIERS.map((t) => <option key={t} value={t}>{t}</option>)}
                </select>
              </div>
            </L>
          </div>

          <label className="mt-3 flex items-center gap-2">
            <input type="checkbox" checked={edit.elegivel_loja}
              onChange={(e) => setEdit({ ...edit, elegivel_loja: e.target.checked })} />
            <span>à venda na loja</span>
          </label>

          {/* preço só existe para pacote de loja (adendo, item 1) */}
          {edit.elegivel_loja && (
            <div className="mt-2 flex flex-wrap items-center gap-3">
              <L r="preço em baba"><input type="number" className={campo}
                value={edit.preco_baba ?? ''}
                onChange={(e) => setEdit({ ...edit,
                  preco_baba: e.target.value === '' ? null : Number(e.target.value) })} /></L>
              {ev && (
                <span className="text-xs text-neutral-400">
                  EV <strong className="text-neutral-200">{ev.ev}</strong> ·
                  piso <strong className={Number(edit.preco_baba) < Number(ev.piso)
                    ? 'text-red-400' : 'text-neutral-200'}>{ev.piso}</strong> ·
                  sugerido <strong className="text-[var(--acento)]">{ev.sugerido}</strong>
                  {ev.margem_pct != null && <> · margem <strong>{ev.margem_pct}%</strong></>}
                  <button className="ml-2 underline"
                    onClick={() => setEdit({ ...edit, preco_baba: Number(ev.sugerido) })}>
                    usar o sugerido
                  </button>
                </span>
              )}
            </div>
          )}

          {/* --------------------------------------------------------- slots */}
          <div className="mt-4 space-y-3">
            {edit.slots.map((s, i) => {
              const t = soma(s.odds)
              return (
                <div key={i} className="rounded border border-neutral-800 p-2">
                  <div className="mb-2 flex flex-wrap items-center gap-3">
                    <strong className="text-xs uppercase tracking-widest text-neutral-400">
                      slot {i + 1}
                    </strong>
                    <label className="flex items-center gap-1 text-xs">
                      <input type="checkbox" checked={s.garantido}
                        onChange={(e) => mudarSlot(i, { garantido: e.target.checked })} />
                      garantido
                    </label>
                    <button onClick={() => sugerir(i)} className="btn btn-fraco px-2 py-0.5 text-xs">
                      sugerir odds
                    </button>
                    <span className={`text-xs ${Math.abs(t - 100) < 0.01
                      ? 'text-emerald-400' : 'text-red-400'}`}>
                      soma {t.toFixed(2)}%
                    </span>
                    <button
                      onClick={() => setEdit({ ...edit,
                        slots: edit.slots.filter((_, k) => k !== i) })}
                      className="ml-auto text-xs text-red-400 underline">remover slot</button>
                  </div>

                  <div className="mb-2 grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
                    <L r="tiers (vazio = todos)"><input className={campo}
                      value={lista4(s.filtro.tiers)} placeholder="rara, epica"
                      onChange={(e) => mudarSlot(i, {
                        filtro: { ...s.filtro, tiers: parse(e.target.value) } })} /></L>
                    <L r="personagens"><input className={campo}
                      value={lista4(s.filtro.characters)} placeholder={personagens.join(', ')}
                      onChange={(e) => mudarSlot(i, {
                        filtro: { ...s.filtro, characters: parse(e.target.value) } })} /></L>
                    <L r="skins"><input className={campo} list="skins-do-set"
                      value={lista4(s.filtro.skins)} placeholder="fogo, gelo"
                      onChange={(e) => mudarSlot(i, {
                        filtro: { ...s.filtro, skins: parse(e.target.value) } })} /></L>
                    <L r="tier mínimo / máximo">
                      <div className="flex gap-1">
                        {(['tiers_min', 'tiers_max'] as const).map((k) => (
                          <select key={k} className={campo} value={s.filtro[k] ?? ''}
                            onChange={(e) => mudarSlot(i, {
                              filtro: { ...s.filtro, [k]: e.target.value || undefined } })}>
                            <option value="">—</option>
                            {TIERS.map((x) => <option key={x} value={x}>{x}</option>)}
                          </select>
                        ))}
                      </div>
                    </L>
                  </div>

                  <div className="flex flex-wrap gap-1.5">
                    {TIERS.map((tier) => {
                      const o = s.odds.find((x) => x.tier === tier)
                      return (
                        <label key={tier} className="flex items-center gap-1 rounded
                                                     border border-neutral-800 px-1.5 py-0.5 text-xs">
                          <span className="text-neutral-400">{ROTULO_TIER[tier as Tier]}</span>
                          <input type="number" step="0.01" className="w-16 bg-transparent text-right"
                            value={o?.weight ?? ''}
                            onChange={(e) => {
                              const v = e.target.value === '' ? 0 : Number(e.target.value)
                              const odds = s.odds.filter((x) => x.tier !== tier)
                              if (v > 0) odds.push({ tier, weight: v })
                              mudarSlot(i, { odds })
                            }} />
                        </label>
                      )
                    })}
                  </div>
                </div>
              )
            })}
            <button
              onClick={() => setEdit({ ...edit, slots: [...edit.slots,
                { ordem: edit.slots.length + 1, filtro: {}, garantido: false, odds: [] }] })}
              className="btn btn-fraco px-3 py-1">adicionar slot</button>
          </div>

          {/* ------------------------------------------------------ avisos */}
          {viab?.avisos?.length > 0 && (
            <ul className="mt-4 space-y-1">
              {viab.avisos.map((a: any, i: number) => (
                <li key={i} className={`rounded border p-2 text-xs ${a.nivel === 'erro'
                  ? 'border-red-900 bg-red-950/40 text-red-300'
                  : 'border-amber-900 bg-amber-950/30 text-amber-300'}`}>
                  {a.nivel === 'erro' ? '⛔ ' : '⚠ '}{a.texto}
                </li>
              ))}
            </ul>
          )}

          {/* ------------------------------------------------------ EV */}
          {ev && (
            <div className="mt-4 rounded border border-neutral-800 p-2 text-xs">
              <strong className="text-neutral-300">Valor esperado</strong>
              <div className="mt-1 grid gap-x-6 gap-y-0.5 sm:grid-cols-2 lg:grid-cols-4">
                <span>médio: <strong className="text-neutral-200">{ev.ev}</strong> baba</span>
                <span>mínimo possível: {ev.ev_minimo}</span>
                <span>máximo possível: {ev.ev_maximo}</span>
                <span>desvio: ±{ev.desvio}</span>
                {ev.ev_da_edicao != null && (
                  <span className="text-amber-300">
                    a edição inteira vale {ev.ev_da_edicao} baba
                  </span>
                )}
              </div>
            </div>
          )}

          {/* ------------------------------------------------------ preview */}
          <div className="mt-4">
            <button onClick={simular} disabled={ocupado || !edit.id}
              className="btn btn-fraco px-3 py-1">
              {ocupado ? 'simulando…' : 'simular 1000 aberturas'}
            </button>
            {!edit.id && <span className="ml-2 text-xs text-neutral-600">salve antes de simular</span>}
            {preview && (
              <div className="mt-2 grid gap-4 sm:grid-cols-2">
                <div>
                  <p className="text-xs text-neutral-500">
                    {preview.cartas} cartas em {preview.aberturas} aberturas
                    ({preview.cartas_por_abertura} por pacote) · valor médio {preview.valor_medio} baba
                  </p>
                  <div className="overflow-x-auto"><table className="mt-1 w-full text-xs">
                    <tbody>
                      {preview.por_tier.map((t: any) => (
                        <tr key={t.tier}>
                          <td className="text-neutral-400">{t.tier}</td>
                          <td className="tabular-nums">{t.n}</td>
                          <td className="tabular-nums text-neutral-500">{t.pct}%</td>
                          <td className="w-1/2">
                            <span className="block h-1.5 rounded bg-[var(--acento)]"
                                  style={{ width: `${Math.min(100, t.pct)}%` }} />
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table></div>
                </div>
                <div>
                  <p className="text-xs text-neutral-500">por personagem</p>
                  <div className="overflow-x-auto"><table className="mt-1 w-full text-xs">
                    <tbody>
                      {preview.por_personagem.map((c: any) => (
                        <tr key={c.personagem}>
                          <td className="text-neutral-400">{c.personagem}</td>
                          <td className="tabular-nums">{c.n}</td>
                          <td className="tabular-nums text-neutral-500">{c.pct}%</td>
                        </tr>
                      ))}
                    </tbody>
                  </table></div>
                </div>
              </div>
            )}
          </div>

          {/* ------------------------------------------------------ entregar */}
          {edit.id && (
            <div className="mt-4 flex flex-wrap items-end gap-2 border-t border-neutral-900 pt-3">
              <L r="entregar para"><input className={campo} value={entrega.alvo}
                onChange={(e) => setEntrega({ ...entrega, alvo: e.target.value })} /></L>
              <L r="quantidade"><input type="number" className={`${campo} w-20`} value={entrega.n}
                onChange={(e) => setEntrega({ ...entrega, n: Number(e.target.value) })} /></L>
              <label className="flex items-center gap-1 pb-1 text-xs">
                <input type="checkbox" checked={entrega.diario}
                  onChange={(e) => setEntrega({ ...entrega, diario: e.target.checked })} />
                como pacote do diário
              </label>
              <button className="btn btn-forte px-3 py-1"
                onClick={async () => {
                  const { data, error } = await supabase.rpc('admin_entregar_pacote', {
                    p_id: edit.id, p_target: entrega.alvo,
                    p_quantidade: entrega.n, p_diario: entrega.diario })
                  setMsg(error ? { t: 'erro', x: error.message }
                               : { t: 'ok', x: `entregue a ${data} jogador(es)` })
                  carregar()
                }}>entregar</button>
              <span className="pb-1 text-xs text-neutral-600">
                "todos" atinge o servidor inteiro
              </span>
            </div>
          )}
        </section>
      )}

      {/* --------------------------------------------------------- relatorio */}
      <section>
        <h3 className="mb-1 font-medium">Relatório da loja</h3>
        <p className="mb-2 text-xs text-neutral-500">
          Serve para ver se algum pacote ficou desbalanceado depois que a galera começou a usar.
        </p>
        <div className="overflow-x-auto"><table className="w-full text-left">
          <thead className="text-[11px] uppercase tracking-widest text-neutral-500">
            <tr><th className="py-1">pacote</th><th>EV</th><th>piso</th><th>sugerido</th>
              <th>preço</th><th>margem</th><th>compras</th><th>aberturas</th></tr>
          </thead>
          <tbody>
            {relatorio.map((r) => (
              <tr key={r.id} className="border-t border-neutral-900">
                <td className="py-1.5">{r.name}</td>
                <td className="tabular-nums text-neutral-400">{r.ev}</td>
                <td className="tabular-nums text-neutral-400">{r.piso}</td>
                <td className="tabular-nums text-neutral-400">{r.sugerido}</td>
                <td className={`tabular-nums ${r.abaixo_do_piso ? 'text-amber-400' : ''}`}>
                  {r.preco}
                </td>
                <td className="tabular-nums text-neutral-400">{r.margem_pct}%</td>
                <td className="tabular-nums text-neutral-400">{r.compras}</td>
                <td className="tabular-nums text-neutral-400">
                  {r.aberturas}{r.limite != null && ` / ${r.limite}`}
                </td>
              </tr>
            ))}
          </tbody>
        </table></div>
        <p className="mt-2 text-xs text-neutral-600">
          Abaixo do piso não significa prejuízo: o piso é EV × 1,5, uma folga em cima do
          ponto de equilíbrio. O que não pode é preço abaixo do EV — aí comprar e vender
          o conteúdo dá lucro, e isso imprime baba.
        </p>
      </section>
    </div>
  )
}

const L = ({ r, children }: { r: string; children: React.ReactNode }) => (
  <label className="flex flex-col gap-0.5">
    <span className="text-[10px] uppercase tracking-widest text-neutral-500">{r}</span>
    {children}
  </label>
)
