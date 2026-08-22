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
import Forja from './paginas/Forja'
import Loja from './paginas/Loja'
import Verificar from './paginas/Verificar'

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

  // /v/<codigo> e PUBLICA: nao exige login (spec §14)
  const publica = (
    <Routes>
      <Route path="/v/:codigo" element={<Verificar />} />
    </Routes>
  )
  if (window.location.pathname.includes('/v/')) return publica

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
        <Route path="/forja" element={<Forja />} />
        <Route path="/loja" element={<Loja />} />
        <Route path="/v/:codigo" element={<Verificar />} />
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

  const aba = ({ isActive }: { isActive: boolean }) => `aba ${isActive ? 'aba-ativa' : ''}`

  return (
    <header className="topo">
      <Link to="/colecao" className="marca mr-2 text-lg">
        BELESMA
      </Link>

      <nav className="flex min-w-0 flex-1 items-center gap-0.5 overflow-x-auto">
        <NavLink to="/colecao" className={aba}>Coleção</NavLink>
        <NavLink to="/album" className={aba}>Álbum</NavLink>
        <NavLink to="/abrir" className={aba}>
          Abrir {pacotes > 0 && <span className="selo-novo">{pacotes}</span>}
        </NavLink>
        <NavLink to="/trocas" className={aba}>
          Trocas {pendentes > 0 && <span className="selo-novo">{pendentes}</span>}
        </NavLink>
        <NavLink to="/forja" className={aba}>Forja</NavLink>
        <NavLink to="/loja" className={aba}>Loja</NavLink>
        <NavLink to="/conquistas" className={aba}>Conquistas</NavLink>
        {jogador.is_admin && <NavLink to="/admin" className={aba}>Admin</NavLink>}
      </nav>

      <div className="ml-auto flex shrink-0 items-center gap-2">
        {/* Saldo sempre visível (spec §19.8). A moeda entra na Fase 6. */}
        <Link to="/loja" className="chip"><strong>{jogador.baba}</strong> baba</Link>
        <Link to="/perfil" className="aba">{jogador.nickname}</Link>
        <button onClick={sair} className="aba" title="sair">sair</button>
      </div>
    </header>
  )
}
