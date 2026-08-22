import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'

/**
 * Painel administrativo (spec §18).
 *
 * Esta rota decide APENAS o que renderiza. A autorização real está dentro de
 * cada RPC, no banco (private.require_admin). Abrir /admin na mão não habilita
 * nada: toda chamada abaixo volta "nao autorizado" para quem não é is_admin.
 */

const ABAS = ['Jogadores', 'Odds', 'Estoque', 'Conteúdo', 'Zona de perigo', 'Log'] as const
type Aba = (typeof ABAS)[number]

export default function Admin() {
  const { jogador, carregando } = useSessao()
  const [aba, setAba] = useState<Aba>('Jogadores')

  if (carregando) return <p className="p-6 text-neutral-500">…</p>
  // Spec §18: para quem não é admin, 404. Não "acesso negado" — nada de
  // anunciar que o painel existe.
  if (!jogador?.is_admin) {
    return (
      <main className="grid min-h-dvh place-items-center p-6">
        <div className="text-center">
          <p className="text-4xl font-semibold">404</p>
          <p className="mt-2 text-sm text-neutral-500">Essa página não existe.</p>
        </div>
      </main>
    )
  }

  return (
    <div className="p-4 sm:p-6">
      <nav className="mb-5 flex flex-wrap gap-1 border-b border-neutral-800">
        {ABAS.map((a) => (
          <button key={a} onClick={() => setAba(a)}
            className={`px-3 py-2 text-sm ${aba === a
              ? 'border-b-2 border-neutral-100 text-neutral-100'
              : 'text-neutral-500 hover:text-neutral-300'}`}>
            {a}
          </button>
        ))}
      </nav>
      {aba === 'Jogadores' && <Jogadores />}
      {aba === 'Odds' && <Odds />}
      {aba === 'Estoque' && <Estoque />}
      {aba === 'Conteúdo' && <Conteudo />}
      {aba === 'Zona de perigo' && <Perigo />}
      {aba === 'Log' && <Log />}
    </div>
  )
}

// ---------------------------------------------------------------- utilidades
function useAviso() {
  const [msg, setMsg] = useState<{ tipo: 'ok' | 'erro'; texto: string } | null>(null)
  // os builders do supabase-js sao PromiseLike, nao Promise
  const rodar = async (
    fn: () => PromiseLike<{ data: any; error: any }>,
    sucesso: (r: any) => string,
  ) => {
    setMsg(null)
    const { data, error } = await fn()
    if (error) setMsg({ tipo: 'erro', texto: error.message })
    else setMsg({ tipo: 'ok', texto: sucesso(data) })
    return !error
  }
  const Aviso = () => msg ? (
    <p className={`my-3 rounded border p-2 text-sm ${msg.tipo === 'ok'
      ? 'border-emerald-900 bg-emerald-950/50 text-emerald-300'
      : 'border-red-900 bg-red-950/50 text-red-300'}`}>{msg.texto}</p>
  ) : null
  return { rodar, Aviso }
}

const campo = 'rounded border border-neutral-700 bg-neutral-900 px-2 py-1 text-sm text-neutral-100 outline-none'
const botao = 'rounded bg-neutral-100 px-3 py-1 text-sm font-medium text-neutral-900 disabled:opacity-40'
const perigoso = 'rounded bg-red-700 px-3 py-1 text-sm font-medium text-white disabled:opacity-40'

// ================================================================ Jogadores
function Jogadores() {
  const [lista, setLista] = useState<any[]>([])
  const { rodar, Aviso } = useAviso()
  const [alvo, setAlvo] = useState('todos')
  const [tipo, setTipo] = useState('comum')
  const [qtd, setQtd] = useState(10)
  const [senhaAlvo, setSenhaAlvo] = useState('')
  const [senhaNova, setSenhaNova] = useState('')

  const carregar = async () => {
    const { data } = await supabase.rpc('admin_jogadores')
    setLista(data ?? [])
  }
  useEffect(() => { carregar() }, [])

  return (
    <div className="space-y-6">
      <Aviso />
      <table className="w-full text-left text-sm">
        <thead className="text-neutral-500">
          <tr className="border-b border-neutral-800">
            <th className="py-1 font-normal">apelido</th>
            <th className="font-normal">entrou</th>
            <th className="text-right font-normal">cópias</th>
            <th className="text-right font-normal">pacotes</th>
            <th className="text-right font-normal">baba</th>
            <th className="text-right font-normal">pity</th>
          </tr>
        </thead>
        <tbody>
          {lista.map((p) => (
            <tr key={p.id} className="border-b border-neutral-900">
              <td className="py-1">{p.nickname} {p.is_admin && <span className="text-amber-400">admin</span>}</td>
              <td className="text-neutral-500">{new Date(p.created_at).toLocaleDateString('pt-BR')}</td>
              <td className="text-right tabular-nums">{p.copias}</td>
              <td className="text-right tabular-nums text-neutral-400">
                {p.pacotes.comum}/{p.pacotes.raro}/{p.pacotes.ultra}
                <span className="text-emerald-600"> +{p.pacotes.comum_diario}/{p.pacotes.raro_diario}/{p.pacotes.ultra_diario}</span>
              </td>
              <td className="text-right tabular-nums">{p.baba}</td>
              <td className="text-right tabular-nums text-neutral-500">{p.pity_counter}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <section>
        <h3 className="mb-2 text-sm font-medium">Dar pacotes</h3>
        <div className="flex flex-wrap items-center gap-2">
          <select value={alvo} onChange={(e) => setAlvo(e.target.value)} className={campo}>
            <option value="todos">todos</option>
            {lista.map((p) => <option key={p.id} value={p.nickname}>{p.nickname}</option>)}
          </select>
          <select value={tipo} onChange={(e) => setTipo(e.target.value)} className={campo}>
            <option value="comum">comum</option><option value="raro">raro</option><option value="ultra">ultra</option>
          </select>
          <input type="number" value={qtd} onChange={(e) => setQtd(+e.target.value)} className={`${campo} w-20`} />
          <button className={botao} onClick={async () => {
            if (await rodar(() => supabase.rpc('grant_packs',
              { p_target: alvo, p_pack_type: tipo, p_quantidade: qtd }),
              (n) => `${qtd} pacote(s) ${tipo} para ${n} jogador(es)`)) carregar()
          }}>dar</button>
        </div>
      </section>

      <section>
        <h3 className="mb-2 text-sm font-medium">Resetar senha</h3>
        <div className="flex flex-wrap items-center gap-2">
          <select value={senhaAlvo} onChange={(e) => setSenhaAlvo(e.target.value)} className={campo}>
            <option value="">jogador…</option>
            {lista.map((p) => <option key={p.id} value={p.nickname}>{p.nickname}</option>)}
          </select>
          <input type="text" placeholder="nova senha (mín. 6)" value={senhaNova}
            onChange={(e) => setSenhaNova(e.target.value)} className={`${campo} w-56`} />
          <button className={botao} disabled={!senhaAlvo || senhaNova.length < 6}
            onClick={() => rodar(() => supabase.rpc('admin_reset_password',
              { p_nickname: senhaAlvo, p_nova_senha: senhaNova }),
              () => `senha de ${senhaAlvo} trocada`)}>resetar</button>
          <button className={botao} disabled={!senhaAlvo}
            onClick={() => rodar(() => supabase.rpc('admin_reset_daily_cooldown', { p_nickname: senhaAlvo }),
              () => `cooldown do diário de ${senhaAlvo} zerado`)}>zerar cooldown do diário</button>
        </div>
      </section>
    </div>
  )
}

// ================================================================ Odds
function Odds() {
  const [linhas, setLinhas] = useState<any[]>([])
  const { rodar, Aviso } = useAviso()

  const carregar = async () => {
    const { data } = await supabase.from('pack_config').select('*')
      .order('pack_type').order('slot').order('tier')
    setLinhas(data ?? [])
  }
  useEffect(() => { carregar() }, [])

  const somas = new Map<string, number>()
  for (const l of linhas) {
    const k = `${l.pack_type}/${l.slot}`
    somas.set(k, (somas.get(k) ?? 0) + Number(l.weight))
  }
  const tudoCem = [...somas.values()].every((v) => Math.abs(v - 100) < 1e-9)

  return (
    <div>
      <Aviso />
      <p className="mb-3 text-sm text-neutral-500">
        Cada tipo de pacote precisa somar 100%. O banco recusa se não fechar — o botão
        só evita a viagem.
      </p>
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {[...somas.keys()].map((grupo) => {
          const [pt, slot] = grupo.split('/')
          const soma = somas.get(grupo)!
          return (
            <div key={grupo} className="rounded border border-neutral-800 p-3">
              <div className="mb-2 flex justify-between text-sm">
                <span className="font-medium">{pt} · {slot}</span>
                <span className={Math.abs(soma - 100) < 1e-9 ? 'text-neutral-500' : 'text-red-400'}>
                  {soma}%{Math.abs(soma - 100) < 1e-9 ? '' : ` (falta ${(100 - soma).toFixed(2)})`}
                </span>
              </div>
              {linhas.filter((l) => l.pack_type === pt && l.slot === slot).map((l) => (
                <label key={l.tier} className="flex items-center justify-between gap-2 py-0.5 text-sm">
                  <span className="text-neutral-400">{l.tier}</span>
                  <input type="number" step="0.01" value={l.weight}
                    onChange={(e) => setLinhas(linhas.map((x) =>
                      x === l ? { ...x, weight: e.target.value } : x))}
                    className={`${campo} w-24 text-right`} />
                </label>
              ))}
            </div>
          )
        })}
      </div>
      <div className="mt-4 flex gap-2">
        <button className={botao} disabled={!tudoCem} onClick={async () => {
          if (await rodar(() => supabase.rpc('admin_set_pack_config', {
            p_rows: linhas.map((l) => ({
              pack_type: l.pack_type, slot: l.slot, tier: l.tier, weight: Number(l.weight),
            })),
          }), (n) => `${n} linha(s) salvas e registradas no log`)) carregar()
        }}>salvar</button>
        <button className="text-sm text-neutral-500 underline" onClick={carregar}>descartar</button>
      </div>
    </div>
  )
}

// ================================================================ Estoque
function Estoque() {
  const [r, setR] = useState<any>(null)
  const { rodar, Aviso } = useAviso()
  const carregar = async () => setR((await supabase.rpc('admin_stock_report')).data)
  useEffect(() => { carregar() }, [])
  if (!r) return <p className="text-neutral-500">…</p>

  return (
    <div className="space-y-6 text-sm">
      <Aviso />
      <div className="flex flex-wrap items-center gap-3">
        <span className="text-neutral-400">Reserva do diário: <strong>{r.reserva_diaria}</strong> disponíveis</span>
        <button className={botao} onClick={async () => {
          if (await rodar(() => supabase.rpc('top_up_daily_reserve', { p_n: 500 }),
            (n) => `${n} cópias marcadas`)) carregar()
        }}>recarregar +500</button>
      </div>

      <Tabela titulo="Por tier" cols={['tier', 'total', 'distribuídas', 'queimadas', 'reservadas', 'disponíveis']}
        linhas={r.por_tier.map((x: any) => [x.tier, x.total, x.distribuidas, x.queimadas, x.reservadas, x.disponiveis])} />
      <Tabela titulo="Por personagem" cols={['personagem', 'total', 'distribuídas', 'queimadas', 'disponíveis']}
        linhas={r.por_personagem.map((x: any) => [x.personagem, x.total, x.distribuidas, x.queimadas, x.disponiveis])} />

      <section>
        <h3 className="mb-1 font-medium">Selos</h3>
        <p className="text-neutral-400">
          emitidos <strong>{r.selos.emitidos}</strong> · em posse <strong>{r.selos.em_posse}</strong>
          {' · '}{r.selos.branco} branco / {r.selos.preto} preto / {r.selos.rosa} rosa
        </p>
        <p className="mt-1 text-xs text-neutral-500">
          Emitidos nunca muda depois do seed. Se esse número mexer, é bug.
        </p>
      </section>

      <section>
        <h3 className="mb-1 font-medium">Desgaste</h3>
        <p className="text-neutral-400">
          {Object.entries(r.desgaste).map(([n, q]) => `nível ${n}: ${q}`).join(' · ')}
        </p>
      </section>
    </div>
  )
}

const Tabela = ({ titulo, cols, linhas }: { titulo: string; cols: string[]; linhas: any[][] }) => (
  <section>
    <h3 className="mb-1 font-medium">{titulo}</h3>
    <table className="w-full text-left">
      <thead className="text-neutral-500">
        <tr className="border-b border-neutral-800">
          {cols.map((c, i) => <th key={c} className={`py-1 font-normal ${i ? 'text-right' : ''}`}>{c}</th>)}
        </tr>
      </thead>
      <tbody>
        {linhas.map((l, i) => (
          <tr key={i} className="border-b border-neutral-900">
            {l.map((v, j) => <td key={j} className={`py-0.5 tabular-nums ${j ? 'text-right' : ''}`}>{v}</td>)}
          </tr>
        ))}
      </tbody>
    </table>
  </section>
)

// ================================================================ Conteúdo
function Conteudo() {
  const { rodar, Aviso } = useAviso()
  const [slug, setSlug] = useState('')
  const [nome, setNome] = useState('')
  const [seco, setSeco] = useState<any>(null)
  const [faltando, setFaltando] = useState<string[] | null>(null)
  const [conferindo, setConferindo] = useState(false)

  // O banco não enxerga disco: ele devolve os caminhos e o navegador confere.
  async function conferirArte() {
    setConferindo(true); setFaltando(null)
    const { data } = await supabase.rpc('admin_missing_art')
    const faltas: string[] = []
    for (const a of data ?? []) {
      const url = import.meta.env.BASE_URL.replace(/\/$/, '') + a.art_path
      try {
        const r = await fetch(url, { method: 'HEAD' })
        if (!r.ok) faltas.push(a.art_path)
      } catch { faltas.push(a.art_path) }
    }
    setFaltando(faltas); setConferindo(false)
  }

  return (
    <div className="space-y-6 text-sm">
      <Aviso />
      <section>
        <h3 className="mb-2 font-medium">Personagem novo</h3>
        <div className="flex flex-wrap items-center gap-2">
          <input placeholder="slug (ex: zezao)" value={slug}
            onChange={(e) => { setSlug(e.target.value.toLowerCase().trim()); setSeco(null) }}
            className={`${campo} w-40`} />
          <input placeholder="nome" value={nome} onChange={(e) => setNome(e.target.value)}
            className={`${campo} w-56`} />
          <button className={botao} disabled={!slug} onClick={() => rodar(
            () => supabase.rpc('seed_edition_dry_run', { p_params: { slug } }).then((r) => {
              setSeco(r.data); return r
            }), () => 'dry-run pronto — confira antes de confirmar')}>dry-run</button>
        </div>

        {seco && (
          <div className="mt-3 rounded border border-neutral-800 p-3">
            <p className="text-neutral-300">
              Criaria <strong>{seco.card_types}</strong> tipos e <strong>{seco.card_copies}</strong> cópias
              para <strong>{seco.slug}</strong>, com {seco.selos.branco}/{seco.selos.preto}/{seco.selos.rosa} selos
              e {seco.reserva_diaria} na reserva do diário.
            </p>
            {seco.ja_existe && <p className="mt-1 text-red-400">Esse personagem já existe. Vai abortar.</p>}
            <p className="mt-2 text-xs text-neutral-500">
              As artes precisam estar em <code>public/figurinhas/{seco.slug}/</code> antes.
            </p>
            <button className={`${botao} mt-3`} disabled={seco.ja_existe} onClick={() => rodar(
              () => supabase.rpc('seed_edition', { p_params: { slug, name: nome || undefined } }),
              (d) => `criado: ${d.copias} cópias`)}>confirmar e criar</button>
          </div>
        )}
      </section>

      <section>
        <h3 className="mb-2 font-medium">Artes em disco</h3>
        <button className={botao} disabled={conferindo} onClick={conferirArte}>
          {conferindo ? 'conferindo…' : 'conferir art_path'}
        </button>
        {faltando && (
          <p className={`mt-2 ${faltando.length ? 'text-amber-400' : 'text-emerald-400'}`}>
            {faltando.length === 0 ? 'todas as artes estão no ar' : `${faltando.length} faltando:`}
            {faltando.length > 0 && <span className="block text-xs text-neutral-400">{faltando.join(' ')}</span>}
          </p>
        )}
      </section>
    </div>
  )
}

// ================================================================ Zona de perigo
function Perigo() {
  const { rodar, Aviso } = useAviso()
  const [lista, setLista] = useState<any[]>([])
  const [alvo, setAlvo] = useState('')
  const [conf, setConf] = useState('')
  const [confTudo, setConfTudo] = useState('')
  const [confApagar, setConfApagar] = useState('')
  const [alvoApagar, setAlvoApagar] = useState('')
  const [totalComDono, setTotalComDono] = useState(0)

  const carregar = async () => {
    const { data } = await supabase.rpc('admin_jogadores')
    setLista(data ?? [])
    const { count } = await supabase.from('card_copies')
      .select('id', { count: 'exact', head: true }).not('owner_id', 'is', null)
    setTotalComDono(count ?? 0)
  }
  useEffect(() => { carregar() }, [])

  const copiasDe = (n: string) => lista.find((p) => p.nickname === n)?.copias ?? 0

  return (
    <div className="space-y-6 text-sm">
      <Aviso />
      <p className="rounded border border-red-900 bg-red-950/30 p-3 text-red-300">
        Nada aqui apaga <code>card_types</code> nem <code>characters</code> — só posse. Cópias puxadas
        voltam ao pool com serial e selo intactos; forjadas são queimadas. A estreia mundial é
        história e não se apaga.
      </p>

      <Bloco titulo="Resetar a coleção de um jogador"
        afetadas={`${copiasDe(alvo)} cópias voltam ao pool`}>
        <select value={alvo} onChange={(e) => { setAlvo(e.target.value); setConf('') }} className={campo}>
          <option value="">jogador…</option>
          {lista.map((p) => <option key={p.id} value={p.nickname}>{p.nickname} ({p.copias})</option>)}
        </select>
        <input placeholder={`digite ${alvo || 'o apelido'}`} value={conf}
          onChange={(e) => setConf(e.target.value)} className={`${campo} w-44`} />
        <button className={perigoso} disabled={!alvo || conf !== alvo} onClick={async () => {
          if (await rodar(() => supabase.rpc('admin_reset_player_collection', { p_nickname: alvo }),
            (n) => `${n} cópias devolvidas ao pool`)) { setConf(''); carregar() }
        }}>resetar</button>
      </Bloco>

      <Bloco titulo="Resetar TODAS as coleções"
        afetadas={`${totalComDono} cópias voltam ao pool, de todos os jogadores`}>
        <input placeholder="digite RESETAR" value={confTudo}
          onChange={(e) => setConfTudo(e.target.value)} className={`${campo} w-44`} />
        <button className={perigoso} disabled={confTudo !== 'RESETAR'} onClick={async () => {
          if (await rodar(() => supabase.rpc('admin_reset_all_collections', { p_confirmacao: 'RESETAR' }),
            (n) => `${n} cópias devolvidas ao pool`)) { setConfTudo(''); carregar() }
        }}>resetar tudo</button>
      </Bloco>

      <Bloco titulo="Apagar um jogador"
        afetadas={`${copiasDe(alvoApagar)} cópias voltam ao pool e a conta some de vez`}>
        <select value={alvoApagar} onChange={(e) => { setAlvoApagar(e.target.value); setConfApagar('') }} className={campo}>
          <option value="">jogador…</option>
          {lista.map((p) => <option key={p.id} value={p.nickname}>{p.nickname} ({p.copias})</option>)}
        </select>
        <input placeholder={`digite ${alvoApagar || 'o apelido'}`} value={confApagar}
          onChange={(e) => setConfApagar(e.target.value)} className={`${campo} w-44`} />
        <button className={perigoso} disabled={!alvoApagar || confApagar !== alvoApagar} onClick={async () => {
          if (await rodar(() => supabase.rpc('admin_delete_player', { p_nickname: alvoApagar }),
            (n) => `jogador apagado, ${n} cópias devolvidas`)) { setConfApagar(''); setAlvoApagar(''); carregar() }
        }}>apagar</button>
      </Bloco>
    </div>
  )
}

const Bloco = ({ titulo, afetadas, children }: {
  titulo: string; afetadas: string; children: React.ReactNode
}) => (
  <section className="rounded border border-neutral-800 p-3">
    <h3 className="font-medium">{titulo}</h3>
    <p className="mb-2 text-xs text-neutral-500">{afetadas}</p>
    <div className="flex flex-wrap items-center gap-2">{children}</div>
  </section>
)

// ================================================================ Log
function Log() {
  const [linhas, setLinhas] = useState<any[]>([])
  useEffect(() => {
    supabase.from('admin_log').select('*').order('id', { ascending: false }).limit(200)
      .then(({ data }) => setLinhas(data ?? []))
  }, [])
  return (
    <div className="text-sm">
      <p className="mb-3 text-neutral-500">
        Somente leitura. Nem admin edita nem apaga — a RLS bloqueia UPDATE e DELETE para todos.
      </p>
      <table className="w-full text-left">
        <thead className="text-neutral-500">
          <tr className="border-b border-neutral-800">
            <th className="py-1 font-normal">quando</th>
            <th className="font-normal">ação</th>
            <th className="font-normal">alvo</th>
            <th className="font-normal">payload</th>
          </tr>
        </thead>
        <tbody>
          {linhas.map((l) => (
            <tr key={l.id} className="border-b border-neutral-900 align-top">
              <td className="whitespace-nowrap py-1 text-neutral-500">
                {new Date(l.created_at).toLocaleString('pt-BR')}
              </td>
              <td className="whitespace-nowrap">{l.acao}</td>
              <td className="text-neutral-400">{l.alvo ?? '—'}</td>
              <td className="max-w-md truncate font-mono text-xs text-neutral-600">
                {JSON.stringify(l.payload)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {linhas.length === 0 && <p className="py-6 text-neutral-500">nada registrado ainda</p>}
    </div>
  )
}
