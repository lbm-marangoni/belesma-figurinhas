import { useEffect, useState } from 'react'
import { BrowserRouter, Link, NavLink, Navigate, Route, Routes, useLocation } from 'react-router-dom'
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
import './styles/navegacao.css'

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

/* ---------------------------------------------------------------- ícones
 * SVG inline de 24px, traço único. Sem biblioteca: são cinco desenhos e
 * qualquer pacote de ícones custaria mais que o arquivo inteiro. */
const Icone = ({ d }: { d: string }) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"
       strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d={d} />
  </svg>
)
const ICONES = {
  colecao: 'M4 5h6v6H4zM14 5h6v6h-6zM4 13h6v6H4zM14 13h6v6h-6z',
  album:   'M4 5a2 2 0 0 1 2-2h13v18H6a2 2 0 0 1-2-2zM9 3v18',
  abrir:   'M3 8h18v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1zM3 8l2-4h14l2 4M12 4v17',
  trocas:  'M4 8h13l-3-3M20 16H7l3 3',
  mais:    'M5 12h.01M12 12h.01M19 12h.01',
}

function Shell() {
  const { jogador, sair } = useSessao()
  const [pendentes, setPendentes] = useState(0)
  const [mais, setMais] = useState(false)
  const local = useLocation()

  // trocar de página fecha a folha; sem isto ela ficava aberta por cima do
  // destino recém-aberto
  useEffect(() => { setMais(false) }, [local.pathname])

  useEffect(() => {
    if (!mais) return
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setMais(false) }
    window.addEventListener('keydown', esc)
    return () => window.removeEventListener('keydown', esc)
  }, [mais])

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

  const baixo = ({ isActive }: { isActive: boolean }) =>
    `item-baixo ${isActive ? 'item-baixo-ativo' : ''}`

  // as secundárias vivem na folha "mais"; no desktop elas continuam no topo
  const secundarias: [string, string][] = [
    ['/forja', 'Forja'], ['/loja', 'Loja'], ['/conquistas', 'Conquistas'],
    ['/perfil', jogador.nickname],
    ...(jogador.is_admin ? ([['/admin', 'Admin']] as [string, string][]) : []),
  ]

  return (
    <>
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
        {/* Saldo sempre visível (spec §19.8) — inclusive no celular, onde as
            abas somem mas o chip continua no topo. */}
        <Link to="/loja" className="chip"><strong>{jogador.baba}</strong> baba</Link>
        <Link to="/perfil" className="aba so-desktop">{jogador.nickname}</Link>
        <button onClick={sair} className="aba so-desktop" title="sair">sair</button>
      </div>
    </header>

    {/* =========================================================== celular
     * Oito abas numa fileira que rola de lado é um menu que ninguém lê: o
     * que está fora da tela não existe, e no topo nada disso alcança o
     * polegar. No celular as quatro rotas de uso diário viram barra
     * inferior, e o resto mora numa folha. */}
    <nav className="barra-baixo" aria-label="navegação principal">
      <NavLink to="/colecao" className={baixo}>
        <Icone d={ICONES.colecao} /><span>Coleção</span>
      </NavLink>
      <NavLink to="/album" className={baixo}>
        <Icone d={ICONES.album} /><span>Álbum</span>
      </NavLink>
      <NavLink to="/abrir" className={baixo}>
        <Icone d={ICONES.abrir} /><span>Abrir</span>
        {pacotes > 0 && <i className="ponto-baixo">{pacotes}</i>}
      </NavLink>
      <NavLink to="/trocas" className={baixo}>
        <Icone d={ICONES.trocas} /><span>Trocas</span>
        {pendentes > 0 && <i className="ponto-baixo">{pendentes}</i>}
      </NavLink>
      <button type="button" onClick={() => setMais(true)}
        className={`item-baixo ${mais ? 'item-baixo-ativo' : ''}`}
        aria-haspopup="dialog" aria-expanded={mais}>
        <Icone d={ICONES.mais} /><span>Mais</span>
      </button>
    </nav>

    {mais && (
      <div className="gaveta-fundo" onClick={() => setMais(false)}>
        <div className="gaveta" role="dialog" aria-label="mais opções"
             onClick={(e) => e.stopPropagation()}>
          <span className="gaveta-pega" />
          <div className="gaveta-topo">
            <strong>{jogador.nickname}</strong>
            <span className="chip"><strong>{jogador.baba}</strong> baba</span>
          </div>
          <div className="gaveta-grade">
            {secundarias.map(([para, rotulo]) => (
              <NavLink key={para} to={para}
                className={({ isActive }) => `gaveta-item ${isActive ? 'gaveta-item-ativo' : ''}`}>
                {rotulo}
              </NavLink>
            ))}
          </div>
          <button onClick={sair} className="gaveta-sair">sair da conta</button>
        </div>
      </div>
    )}
    </>
  )
}
