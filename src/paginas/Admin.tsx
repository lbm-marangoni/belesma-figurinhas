import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSessao } from '../lib/sessao'
import AdminPacotes from './AdminPacotes'

/**
 * Painel administrativo (spec §18).
 *
 * Esta rota decide APENAS o que renderiza. A autorização real está dentro de
 * cada RPC, no banco (private.require_admin). Abrir /admin na mão não habilita
 * nada: toda chamada abaixo volta "nao autorizado" para quem não é is_admin.
 */

// A aba "Odds" saiu. Ela editava pack_config, e desde que o sorteio passou a
// ler pack_slot_odds (por definicao de pacote) aquilo nao alimentava mais
// nada: dizia "salvo" e o jogo continuava igual. Um botao que mente e pior
// que um botao que nao existe. As odds vivem em Pacotes.
const ABAS = ['Saúde', 'Jogadores', 'Pacotes', 'Estoque', 'Sorteio',
              'Conteúdo', 'Zona de perigo', 'Log'] as const
type Aba = (typeof ABAS)[number]

export default function Admin() {
  const { jogador, carregando } = useSessao()
  const [aba, setAba] = useState<Aba>('Saúde')

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
    <div className="mx-auto max-w-[112rem] p-3 sm:p-6">
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
      {aba === 'Saúde' && <Saude />}
      {aba === 'Jogadores' && <Jogadores />}
      {aba === 'Pacotes' && <AdminPacotes />}
      {aba === 'Sorteio' && <Sorteio />}
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

// ================================================================ Saúde
function Saude() {
  const [s, setS] = useState<any>(null)
  useEffect(() => { supabase.rpc('admin_saude').then(({ data }) => setS(data)) }, [])
  if (!s) return <p className="text-neutral-500">…</p>

  const alertas = Object.entries(s.alertas as Record<string, number>)
  const ruins = alertas.filter(([, v]) => Number(v) > 0)

  return (
    <div className="space-y-6 text-sm">
      {/* Invariantes primeiro: se alguma quebrou, é a única coisa que importa
          nesta tela. Configuração pode estar errada; invariante quebrada é bug. */}
      <section className={`rounded-lg p-3 ${ruins.length ? 'aviso-ruim' : 'aviso-ok'}`}>
        <p className="font-medium">
          {ruins.length === 0
            ? 'Todas as invariantes de pé.'
            : `${ruins.length} invariante(s) quebrada(s) — isto é bug, não configuração.`}
        </p>
        <ul className="mt-1 text-xs">
          {alertas.map(([k, v]) => (
            <li key={k} className={Number(v) > 0 ? 'font-semibold' : 'opacity-60'}>
              {Number(v) > 0 ? '✗' : '✓'} {k.replace(/_/g, ' ')}{Number(v) > 0 ? ` (${v})` : ''}
            </li>
          ))}
        </ul>
      </section>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {[
          ['jogadores', s.jogadores], ['cópias com dono', s.copias_com_dono],
          ['queimadas', s.queimadas], ['forjadas', s.forjadas],
          ['reserva do diário', s.reserva_diaria], ['pool base livre', s.pool_base_livre],
          ['baba em circulação', s.baba_em_circulacao], ['trocas pendentes', s.trocas_pendentes],
        ].map(([k, v]) => (
          <div key={String(k)} className="painel p-3">
            <p className="text-xs uppercase tracking-wider text-neutral-500">{k}</p>
            <p className="mt-1 text-2xl font-semibold tabular-nums">{String(v)}</p>
          </div>
        ))}
      </div>
    </div>
  )
}

// ================================================================ Sorteio
function Sorteio() {
  const [a, setA] = useState<any>(null)
  useEffect(() => { supabase.rpc('admin_auditoria_sorteio').then(({ data }) => setA(data)) }, [])
  if (!a) return <p className="text-neutral-500">…</p>

  return (
    <div className="space-y-5 text-sm">
      <p className="text-neutral-400">
        {a.aberturas} aberturas · {a.cartas} cartas · quente {a.variancia.quente} ·
        bônus {a.variancia.bonus} · pity {a.variancia.pity} ·
        promovidos {a.variancia.promovidos}
      </p>

      <p className={`rounded-lg p-2 text-sm ${
        a.diamante_prisma_em_slot_garantido === 0 ? 'aviso-ok' : 'aviso-ruim'}`}>
        Regra dura da §8: diamante e prisma em slot garantido ={' '}
        <strong>{a.diamante_prisma_em_slot_garantido}</strong>
        {a.diamante_prisma_em_slot_garantido === 0 ? ' — como tem que ser.' : ' — isto é bug.'}
      </p>

      <div>
        <h3 className="mb-1 font-medium">Slot de hit: observado vs tabela</h3>
        <p className="mb-2 text-xs text-neutral-500">
          Só slots de hit naturais — promoção, pacote quente e pity ficam de fora, senão
          poluiriam a amostra. Com poucas aberturas a variância é grande; olhe a tendência.
        </p>
        <div className="overflow-x-auto"><table className="w-full max-w-2xl text-left">
          <thead className="text-xs text-neutral-500">
            <tr className="border-b border-neutral-800">
              <th className="py-1 font-normal">pacote</th><th className="font-normal">tier</th>
              <th className="text-right font-normal">saiu</th>
              <th className="text-right font-normal">observado</th>
              <th className="text-right font-normal">tabela</th>
            </tr>
          </thead>
          <tbody>
            {(a.hit_por_tier ?? []).map((r: any, i: number) => {
              const desvio = r.esperado_pct ? Math.abs(r.observado_pct - r.esperado_pct) : 0
              return (
                <tr key={i} className="border-b border-neutral-900">
                  <td className="py-1">{r.pack_type}</td>
                  <td>{r.tier}</td>
                  <td className="text-right tabular-nums">{r.saiu}</td>
                  <td className={`text-right tabular-nums ${desvio > 15 ? 'text-amber-400' : ''}`}>
                    {r.observado_pct}%
                  </td>
                  <td className="text-right tabular-nums text-neutral-500">{r.esperado_pct ?? '—'}%</td>
                </tr>
              )
            })}
          </tbody>
        </table></div>
      </div>
    </div>
  )
}

// ================================================================ Jogadores
function Jogadores() {
  const [lista, setLista] = useState<any[]>([])
  const { rodar, Aviso } = useAviso()
  const [senhaAlvo, setSenhaAlvo] = useState('')
  const [senhaNova, setSenhaNova] = useState('')
  const [babaAlvo, setBabaAlvo] = useState('todos')
  const [babaDelta, setBabaDelta] = useState(100)
  const [babaMotivo, setBabaMotivo] = useState('')
  const [detalhe, setDetalhe] = useState<{ nick: string; extrato: any; acervo: any } | null>(null)

  const carregar = async () => {
    const { data } = await supabase.rpc('admin_jogadores')
    setLista(data ?? [])
  }
  useEffect(() => { carregar() }, [])

  return (
    <div className="space-y-6">
      <Aviso />
      <div className="overflow-x-auto"><table className="w-full text-left text-sm">
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
              <td className="py-1">
                <button className="underline underline-offset-2 hover:text-white"
                  onClick={async () => {
                    const [e, ac] = await Promise.all([
                      supabase.rpc('admin_extrato', { p_nickname: p.nickname }),
                      supabase.rpc('admin_acervo', { p_nickname: p.nickname }),
                    ])
                    setDetalhe({ nick: p.nickname, extrato: e.data, acervo: ac.data })
                  }}>
                  {p.nickname}
                </button>
                {p.is_admin && <span className="ml-1 text-amber-400">admin</span>}
              </td>
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
      </table></div>

      {/* "Dar pacotes" saiu daqui. Ele tinha um select fixo com comum, raro e
          ultra, e desde que pacote virou dado essa lista nasce desatualizada
          a cada definicao nova - ja estava sem os seis boosters de
          personagem. Entregar pacote agora e na aba Pacotes, onde a lista
          vem do catalogo e da para escolher se cai como pacote do diario. */}
      <p className="rounded border border-neutral-800 p-2 text-xs text-neutral-500">
        Para entregar pacote, use a aba <strong className="text-neutral-300">Pacotes</strong>:
        a lista sai do catálogo e inclui os boosters de personagem.
      </p>

      <section>
        <h3 className="mb-2 text-sm font-medium">Dar ou tirar baba</h3>
        <div className="flex flex-wrap items-center gap-2">
          <select value={babaAlvo} onChange={(e) => setBabaAlvo(e.target.value)} className={campo}>
            <option value="todos">todos</option>
            {lista.map((p) => <option key={p.id} value={p.nickname}>{p.nickname}</option>)}
          </select>
          <input type="number" value={babaDelta} onChange={(e) => setBabaDelta(+e.target.value)}
            className={`${campo} w-24`} />
          <input placeholder="motivo (vai para o extrato)" value={babaMotivo}
            onChange={(e) => setBabaMotivo(e.target.value)} className={`${campo} w-64`} />
          <button className={botao} disabled={!babaMotivo.trim() || babaDelta === 0}
            onClick={async () => {
              if (await rodar(() => supabase.rpc('admin_dar_baba', {
                p_target: babaAlvo, p_delta: babaDelta, p_motivo: babaMotivo,
              }), (n) => `${babaDelta > 0 ? '+' : ''}${babaDelta} baba para ${n} jogador(es)`)) {
                setBabaMotivo(''); carregar()
              }
            }}>aplicar</button>
        </div>
        <p className="mt-1 text-xs text-neutral-600">
          Sempre aparece no extrato do jogador, com o motivo. Débito maior que o saldo corta no zero.
        </p>
      </section>

      {detalhe && (
        <section className="painel p-3">
          <div className="mb-2 flex items-center justify-between">
            <h3 className="text-sm font-medium">
              {detalhe.nick} · saldo {detalhe.extrato?.saldo} baba · {detalhe.acervo?.length ?? 0} cópias
            </h3>
            <button className="btn btn-fraco" onClick={() => setDetalhe(null)}>fechar</button>
          </div>
          <div className="grid gap-4 lg:grid-cols-2">
            <div>
              <p className="mb-1 text-xs uppercase tracking-wider text-neutral-500">extrato</p>
              <div className="max-h-64 overflow-y-auto text-xs">
                {(detalhe.extrato?.lancamentos ?? []).map((l: any, i: number) => (
                  <div key={i} className="flex justify-between border-b border-neutral-900 py-0.5">
                    <span className="text-neutral-400">{l.motivo}</span>
                    <span className={l.delta > 0 ? 'text-[var(--acento)]' : 'text-red-400'}>
                      {l.delta > 0 ? '+' : ''}{l.delta}
                    </span>
                  </div>
                ))}
                {(detalhe.extrato?.lancamentos ?? []).length === 0 && (
                  <p className="text-neutral-600">sem movimentação</p>)}
              </div>
            </div>
            <div>
              <p className="mb-1 text-xs uppercase tracking-wider text-neutral-500">acervo</p>
              <div className="max-h-64 overflow-y-auto text-xs">
                {(detalhe.acervo ?? []).map((c: any, i: number) => (
                  <div key={i} className="flex justify-between border-b border-neutral-900 py-0.5">
                    <span>{c.personagem} {c.skin}</span>
                    <span className="font-mono text-neutral-500">
                      {c.origin === 'forge' ? `FORJADA ${c.forge_index}` : `${c.serial}/${c.print_run}`}
                      {c.seal !== 'none' && ` · ${c.seal}`}
                      {c.damage_level > 0 && ` · nv${c.damage_level}`}
                    </span>
                  </div>
                ))}
                {(detalhe.acervo ?? []).length === 0 && (
                  <p className="text-neutral-600">sem figurinhas</p>)}
              </div>
            </div>
          </div>
          <button className="btn btn-fraco mt-3"
            onClick={() => rodar(() => supabase.rpc('admin_descolar_album', { p_nickname: detalhe.nick }),
              (n) => `${n} figurinhas descoladas do álbum de ${detalhe.nick}`)}>
            descolar o álbum inteiro
          </button>
        </section>
      )}

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
    <div className="overflow-x-auto"><table className="w-full text-left">
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
    </table></div>
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
  const [confZero, setConfZero] = useState('')
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
        Os dois resets de cima mexem só em <strong>posse</strong>: cópias puxadas voltam ao pool
        com serial, selo e desgaste intactos, forjadas são queimadas, e booster, baba e estreia
        mundial ficam de pé. <strong>Recomeçar do zero</strong> é outra coisa — leia o bloco.
        Nada aqui apaga <code>card_types</code> nem <code>characters</code>.
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

      {/* O "resetar tudo" acima nunca resetou tudo: booster, baba, desgaste,
          estreia mundial, album e historico continuavam de pe. Este aqui
          recomeca de verdade. */}
      <Bloco titulo="Recomeçar do zero"
        afetadas="o mundo volta ao dia da estreia — este é o botão que apaga tudo">
        <div className="w-full">
          <ul className="mb-2 grid gap-x-6 gap-y-0.5 text-xs text-neutral-400 sm:grid-cols-2">
            <li>· todas as cópias voltam ao pool, <strong>sem desgaste</strong></li>
            <li>· <strong>booster de volta ao inicial</strong>: 12 comuns, 5 raros, 2 ultra</li>
            <li>· baba, pity, streak e cooldown do diário zerados</li>
            <li>· forjadas apagadas de vez (não são do mundo do dia zero)</li>
            <li>· <strong>toda estreia mundial apagada</strong> — dá para descobrir de novo</li>
            <li>· álbum, vitrines, trocas, extrato e histórico apagados</li>
            <li>· reserva do diário refeita (1500)</li>
            <li>· selos ficam onde estão: 36 brancos, 12 pretos, 3 rosas</li>
          </ul>
          <p className="mb-2 text-xs text-neutral-500">
            O <code>admin_log</code> <strong>não</strong> é apagado: um reset que some com o próprio
            rastro não é auditável. Esta ação fica gravada lá.
          </p>
          <div className="flex flex-wrap items-center gap-2">
            <input placeholder="digite RECOMECAR DO ZERO" value={confZero}
              onChange={(e) => setConfZero(e.target.value)} className={`${campo} w-64`} />
            <button className={perigoso} disabled={confZero !== 'RECOMECAR DO ZERO'}
              onClick={async () => {
                if (await rodar(
                  () => supabase.rpc('admin_recomecar_do_zero', { p_confirmacao: 'RECOMECAR DO ZERO' }),
                  (r: any) => `mundo reiniciado: ${r.copias_devolvidas} cópias ao pool, ` +
                              `${r.estreias_apagadas} estreias apagadas, ` +
                              `${r.forjadas_apagadas} forjadas removidas, ` +
                              `${r.jogadores_zerados} jogadores zerados`,
                )) { setConfZero(''); carregar() }
              }}>recomeçar do zero</button>
          </div>
        </div>
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
      <div className="overflow-x-auto"><table className="w-full text-left">
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
      </table></div>
      {linhas.length === 0 && <p className="py-6 text-neutral-500">nada registrado ainda</p>}
    </div>
  )
}
