import { BrowserRouter, Link, NavLink, Navigate, Route, Routes } from 'react-router-dom'
import { ProvedorSessao, useSessao } from './lib/sessao'
import Login from './paginas/Login'
import Colecao from './paginas/Colecao'
import Abrir from './paginas/Abrir'
import Admin from './paginas/Admin'

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
        <Route path="/admin" element={<Admin />} />
        <Route path="*" element={<Navigate to="/colecao" replace />} />
      </Routes>
    </div>
  )
}

function Shell() {
  const { jogador, sair } = useSessao()
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
      {jogador.is_admin && <NavLink to="/admin" className={aba}>Admin</NavLink>}

      <div className="ml-auto flex items-center gap-3 text-sm">
        {/* Saldo sempre visível (spec §19.8). A moeda entra na Fase 6. */}
        <span className="text-neutral-400">{jogador.baba} baba</span>
        <span className="text-neutral-300">{jogador.nickname}</span>
        <button onClick={sair} className="text-neutral-500 underline underline-offset-4">sair</button>
      </div>
    </header>
  )
}
