import { useEffect, useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { COR_TIER, ROTULO_TIER, type Selo, type Tier } from '../lib/tipos'

/**
 * Rota pública /v/<codigo> (spec §14). Sem auth.
 *
 * Mostra o dono ATUAL da cópia. Se a figurinha for trocada, esta página
 * reflete na hora — é justamente esse o ponto: o que garante a posse é o app,
 * não o arquivo que circula no WhatsApp.
 */

type Copia = {
  verify_code: string
  personagem: string; personagem_slug: string
  skin: string; tier: Tier; print_run: number
  serial_number: number | null; origin: 'pull' | 'forge'; forge_index: number | null
  seal: Selo; damage_level: number
  dono: string | null; desde: string | null
  estreia_por: string | null; estreia_em: string | null
}

export default function Verificar() {
  const { codigo } = useParams()
  const [c, setC] = useState<Copia | null | 'nada'>(null)

  useEffect(() => {
    if (!codigo) return
    supabase.rpc('verify_copy', { p_codigo: codigo })
      .then(({ data }) => setC((data as Copia) ?? 'nada'))
  }, [codigo])

  if (c === null) return <main className="grid min-h-dvh place-items-center text-neutral-600">…</main>

  if (c === 'nada') {
    return (
      <main className="grid min-h-dvh place-items-center p-6 text-center">
        <div>
          <h1 className="marca text-3xl">BELESMA</h1>
          <p className="mt-4 text-neutral-400">
            Não existe figurinha com o código <code className="font-mono">{codigo}</code>.
          </p>
        </div>
      </main>
    )
  }

  const serial = c.origin === 'forge'
    ? `FORJADA ${String(c.forge_index ?? 0).padStart(2, '0')}`
    : `${c.serial_number}/${c.print_run}`

  return (
    <main className="mx-auto max-w-md p-6">
      <Link to="/" className="marca text-2xl">BELESMA</Link>
      <p className="mt-1 text-xs uppercase tracking-widest text-neutral-500">verificação de figurinha</p>

      <div className="mt-5 overflow-hidden rounded-xl"
           style={{ border: `2px solid ${COR_TIER[c.tier]}` }}>
        <img
          src={`${import.meta.env.BASE_URL}figurinhas/${c.personagem_slug}/${c.skin}.jpg`}
          alt={`${c.personagem} ${c.skin}`}
          className="aspect-square w-full object-cover"
        />
      </div>

      <dl className="mt-4 divide-y divide-neutral-800 border-y border-neutral-800 text-sm">
        <L r="Figurinha">{c.personagem} · {c.skin}</L>
        <L r="Tier"><span style={{ color: COR_TIER[c.tier] }}>{ROTULO_TIER[c.tier]}</span></L>
        <L r="Serial"><span className="font-mono">{serial}</span></L>
        <L r="Tiragem">{c.print_run} no mundo</L>
        {c.seal !== 'none' && <L r="Selo"><span className="capitalize">{c.seal}</span></L>}
        {c.damage_level > 0 && <L r="Desgaste">nível {c.damage_level}</L>}
        <L r="Dono agora">
          {c.dono
            ? <strong className="text-[var(--acento)]">{c.dono}</strong>
            : <span className="text-neutral-500">não distribuída</span>}
        </L>
        {c.desde && <L r="Desde">{new Date(c.desde).toLocaleDateString('pt-BR')}</L>}
        {c.estreia_por && (
          <L r="Estreia mundial">{c.estreia_por} · {new Date(c.estreia_em!).toLocaleDateString('pt-BR')}</L>
        )}
        <L r="Código"><span className="font-mono text-xs">{c.verify_code}</span></L>
      </dl>

      {/* Spec §14: dizer isto sem enfeitar. */}
      <p className="mt-5 text-xs leading-relaxed text-neutral-500">
        A figurinha exportada é um <strong className="text-neutral-400">arquivo comum</strong> e pode
        ser reenviada por qualquer pessoa. O que garante a posse é o app, não o arquivo. O apelido e
        o serial gravados existem para dar crédito, não para impedir cópia — esta página mostra
        sempre o dono atual.
      </p>
    </main>
  )
}

const L = ({ r, children }: { r: string; children: React.ReactNode }) => (
  <div className="flex justify-between gap-3 py-2">
    <dt className="text-neutral-500">{r}</dt>
    <dd className="text-right">{children}</dd>
  </div>
)
