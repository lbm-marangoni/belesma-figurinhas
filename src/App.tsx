import { useEffect, useState } from 'react'
import { BrowserRouter, Link, NavLink, Navigate, Route, Routes } from 'react-router-dom'
import { supabase } from './lib/supabase'
import { ProvedorSessao, useSessao } from './lib/sessao'
import Login from './paginas/Login'
import Colecao from './paginas/Colecao'
import Abrir from './paginas/Abrir'
import Admin from './paginas/Admin'
import Perfil from './paginas/Perfil'
import Album from './paginas/Album'
import Trocas from './paginas/Trocas'
import Conquistas from './paginas/Conquistas'

export default function App() {
  return (
    <ProvedorSessao>
      <BrowserRouter basename={import.meta.env.BASE_URL}>
        <Rotas />
      </BrowserRouter>
    </ProvedorSessao>
  )
}

function Rotas() {
  const { sessao, jogador, carregando } = useSessao()

  if (carregando) {
    return <main className="grid min-h-dvh place-items-center text-neutral-600">…</main>
  }
  if (!sessao || !jogador) return <Login />

  return (
    <div className="min-h-dvh">
      <Shell />
      <Routes>
        <Route path="/" element={<Navigate to="/colecao" replace />} />
        <Route path="/colecao" element={<Colecao />} />
        <Route path="/abrir" element={<Abrir />} />
        <Route path="/album" element={<Album />} />
        <Route path="/trocas" element={<Trocas />} />
        <Route path="/conquistas" element={<Conquistas />} />
        <Route path="/perfil" element={<Perfil />} />
        <Route path="/admin" element={<Admin />} />
        <Route path="*" element={<Navigate to="/colecao" replace />} />
      </Routes>
    </div>
  )
}

function Shell() {
  const { jogador, sair } = useSessao()
  const [pendentes, setPendentes] = useState(0)

  // contador de propostas recebidas, atualizado por realtime
  useEffect(() => {
    if (!jogador) return
    const contar = async () => {
      const { count } = await supabase.from('trades')
        .select('id', { count: 'exact', head: true })
        .eq('status', 'pending').eq('to_player', jogador.id)
      setPendentes(count ?? 0)
    }
    contar()
    const canal = supabase.channel('badge-trocas')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'trades' }, contar)
      .subscribe()
    return () => { supabase.removeChannel(canal) }
  }, [jogador])

  if (!jogador) return null

  const pacotes = jogador.packs_common + jogador.packs_rare + jogador.packs_ultra +
    jogador.packs_common_daily + jogador.packs_rare_daily + jogador.packs_ultra_daily

  const aba = ({ isActive }: { isActive: boolean }) =>
    `px-3 py-2 text-sm ${isActive ? 'text-neutral-100' : 'text-neutral-500 hover:text-neutral-300'}`

  return (
    <header className="flex flex-wrap items-center gap-1 border-b border-neutral-800 px-4 py-2">
      <Link to="/colecao" className="mr-3 font-semibold tracking-tight">BELESMA</Link>
      <NavLink to="/colecao" className={aba}>Coleção</NavLink>
      <NavLink to="/abrir" className={aba}>
        Abrir {pacotes > 0 && <span className="text-emerald-400">({pacotes})</span>}
      </NavLink>
      <NavLink to="/album" className={aba}>Álbum</NavLink>
      <NavLink to="/trocas" className={aba}>
        Trocas {pendentes > 0 && <span className="text-emerald-400">({pendentes})</span>}
      </NavLink>
      <NavLink to="/conquistas" className={aba}>Conquistas</NavLink>
      <NavLink to="/perfil" className={aba}>Perfil</NavLink>
      {jogador.is_admin && <NavLink to="/admin" className={aba}>Admin</NavLink>}

      <div className="ml-auto flex items-center gap-3 text-sm">
        {/* Saldo sempre visível (spec §19.8). A moeda entra na Fase 6. */}
        <span className="text-neutral-400">{jogador.baba} baba</span>
        <Link to="/perfil" className="text-neutral-300">{jogador.nickname}</Link>
        <button onClick={sair} className="text-neutral-500 underline underline-offset-4">sair</button>
      </div>
    </header>
  )
}
