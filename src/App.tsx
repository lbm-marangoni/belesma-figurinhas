import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'

// Fase 1 nao tem interface. Esta tela existe so para provar a fiacao:
// se ela mostra os numeros do set lendo pela anon key, entao o schema subiu,
// o seed rodou e as policies de leitura publica estao certas.
// A Fase 2 substitui isto por login e colecao.

type Contagem = { personagens: number; tipos: number; copias: number; selos: number }

export default function App() {
  const [dados, setDados] = useState<Contagem | null>(null)
  const [erro, setErro] = useState<string | null>(null)

  useEffect(() => {
    ;(async () => {
      const conta = async (tabela: string, filtro?: (q: any) => any) => {
        let q = supabase.from(tabela).select('*', { count: 'exact', head: true })
        if (filtro) q = filtro(q)
        const { count, error } = await q
        if (error) throw error
        return count ?? 0
      }
      try {
        setDados({
          personagens: await conta('characters'),
          tipos: await conta('card_types'),
          copias: await conta('card_copies'),
          selos: await conta('card_copies', (q) => q.neq('seal', 'none')),
        })
      } catch (e) {
        setErro(e instanceof Error ? e.message : String(e))
      }
    })()
  }, [])

  return (
    <main className="min-h-dvh grid place-items-center p-8">
      <div className="w-full max-w-md">
        <h1 className="text-2xl font-semibold tracking-tight">BELESMA</h1>
        <p className="mt-1 text-sm text-neutral-400">Fase 1 — fundação</p>

        {erro && (
          <p className="mt-6 rounded border border-red-900 bg-red-950/50 p-3 text-sm text-red-300">
            {erro}
          </p>
        )}

        {dados && (
          <dl className="mt-6 divide-y divide-neutral-800 border-y border-neutral-800 text-sm">
            {[
              ['Personagens', dados.personagens, 3],
              ['Tipos', dados.tipos, 81],
              ['Cópias', dados.copias, 6642],
              ['Selos', dados.selos, 51],
            ].map(([rotulo, valor, esperado]) => (
              <div key={String(rotulo)} className="flex justify-between py-2">
                <dt className="text-neutral-400">{rotulo}</dt>
                <dd className={valor === esperado ? 'text-neutral-100' : 'text-amber-400'}>
                  {valor}
                  {valor !== esperado && (
                    <span className="text-neutral-500"> / esperado {esperado}</span>
                  )}
                </dd>
              </div>
            ))}
          </dl>
        )}

        {!dados && !erro && <p className="mt-6 text-sm text-neutral-500">carregando…</p>}
      </div>
    </main>
  )
}
