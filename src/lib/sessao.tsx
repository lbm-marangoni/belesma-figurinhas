import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './supabase'
import type { Jogador } from './tipos'

type Contexto = {
  sessao: Session | null
  jogador: Jogador | null
  carregando: boolean
  recarregar: () => Promise<void>
  sair: () => Promise<void>
}

const Ctx = createContext<Contexto>({
  sessao: null, jogador: null, carregando: true,
  recarregar: async () => {}, sair: async () => {},
})

export const useSessao = () => useContext(Ctx)

/** O e-mail é sintético e interno: o usuário digita só apelido e senha (spec §10). */
export const emailDe = (apelido: string) => `${apelido.toLowerCase()}@belesma.local`

export function ProvedorSessao({ children }: { children: ReactNode }) {
  const [sessao, setSessao] = useState<Session | null>(null)
  const [jogador, setJogador] = useState<Jogador | null>(null)
  const [carregando, setCarregando] = useState(true)

  // A linha do próprio jogador vem por me(): players não tem SELECT para o
  // cliente, só a view players_public, que não expõe baba nem pacotes.
  const buscarJogador = async () => {
    const { data, error } = await supabase.rpc('me')
    if (error) { setJogador(null); return }
    setJogador((data as Jogador) ?? null)
  }

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      setSessao(data.session)
      if (data.session) await buscarJogador()
      setCarregando(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange(async (_e, s) => {
      setSessao(s)
      if (s) await buscarJogador()
      else setJogador(null)
    })
    return () => sub.subscription.unsubscribe()
  }, [])

  return (
    <Ctx.Provider
      value={{
        sessao, jogador, carregando,
        recarregar: buscarJogador,
        sair: async () => { await supabase.auth.signOut() },
      }}
    >
      {children}
    </Ctx.Provider>
  )
}
