import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { emailDe, useSessao } from '../lib/sessao'

export default function Perfil() {
  const { jogador, recarregar } = useSessao()
  const [novo, setNovo] = useState('')
  const [livre, setLivre] = useState<boolean | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)
  const [historico, setHistorico] = useState<{ nickname: string; usado_ate: string }[]>([])

  const formatoOk = /^[a-z0-9][a-z0-9_-]{2,19}$/.test(novo)

  useEffect(() => {
    if (!jogador) return
    supabase.from('nickname_history').select('nickname, usado_ate')
      .eq('player_id', jogador.id).order('usado_ate', { ascending: false })
      .then(({ data }) => setHistorico(data ?? []))
  }, [jogador, ok])

  // checa disponibilidade enquanto digita, com um respiro
  useEffect(() => {
    if (!formatoOk) { setLivre(null); return }
    const t = setTimeout(async () => {
      const { data } = await supabase.rpc('nickname_disponivel', { p_nickname: novo })
      setLivre(data as boolean)
    }, 350)
    return () => clearTimeout(t)
  }, [novo, formatoOk])

  if (!jogador) return null

  async function trocar(e: React.FormEvent) {
    e.preventDefault()
    setErro(null); setOk(null); setOcupado(true)
    const anterior = jogador!.nickname
    const { error } = await supabase.rpc('mudar_nickname', { p_novo: novo })
    if (error) { setErro(error.message); setOcupado(false); return }

    // O e-mail de login mudou junto. Renova a sessão para o JWT não ficar
    // com o e-mail velho.
    await supabase.auth.refreshSession()
    await recarregar()
    setOk(`Agora você é ${novo}. Da próxima vez, entre com esse apelido — "${anterior}" não serve mais.`)
    setNovo(''); setLivre(null); setOcupado(false)
  }

  return (
    <div className="max-w-lg p-4 sm:p-6">
      <h2 className="text-lg font-medium">Perfil</h2>
      <dl className="mt-3 divide-y divide-neutral-800 border-y border-neutral-800 text-sm">
        <Linha rotulo="Apelido" valor={jogador.nickname} />
        <Linha rotulo="Entra com" valor={emailDe(jogador.nickname)} suave />
        <Linha rotulo="Baba" valor={String(jogador.baba)} />
        {jogador.is_admin && <Linha rotulo="Admin" valor="sim" />}
      </dl>

      <form onSubmit={trocar} className="mt-6">
        <h3 className="text-sm font-medium">Trocar de apelido</h3>
        <label className="mt-2 block text-sm text-neutral-400">
          Novo apelido
          <input
            value={novo}
            onChange={(e) => { setNovo(e.target.value.toLowerCase().trim()); setOk(null); setErro(null) }}
            className="mt-1 w-full rounded border border-neutral-700 bg-neutral-900 px-3 py-2
                       text-base text-neutral-100 outline-none focus:border-neutral-500"
          />
        </label>

        <p className="mt-1 h-5 text-xs">
          {novo && !formatoOk && (
            <span className="text-amber-400">3 a 20 caracteres, minúsculas, números, - e _</span>
          )}
          {formatoOk && livre === true && <span className="text-emerald-400">disponível</span>}
          {formatoOk && livre === false && <span className="text-red-400">já está em uso ou já foi de alguém</span>}
        </p>

        {erro && <p className="mt-2 rounded border border-red-900 bg-red-950/50 p-2 text-sm text-red-300">{erro}</p>}
        {ok && <p className="mt-2 rounded border border-emerald-900 bg-emerald-950/50 p-2 text-sm text-emerald-300">{ok}</p>}

        <button type="submit" disabled={ocupado || !formatoOk || livre !== true}
          className="mt-3 rounded bg-neutral-100 px-3 py-2 text-sm font-medium text-neutral-900 disabled:opacity-40">
          {ocupado ? '...' : 'trocar'}
        </button>
      </form>

      {historico.length > 0 && (
        <section className="mt-6">
          <h3 className="text-sm font-medium">Apelidos anteriores</h3>
          <ul className="mt-1 text-sm text-neutral-400">
            {historico.map((h) => (
              <li key={h.nickname} className="flex justify-between border-b border-neutral-900 py-1">
                <span className="font-mono">{h.nickname}</span>
                <span className="text-neutral-600">até {new Date(h.usado_ate).toLocaleDateString('pt-BR')}</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      <p className="mt-6 border-t border-neutral-800 pt-4 text-xs leading-relaxed text-neutral-500">
        Trocar de apelido troca também o seu login. As figurinhas continuam suas — a posse é do
        jogador, não do nome. <strong className="text-neutral-400">Apelido que já foi de alguém
        nunca vai para outra pessoa</strong>: é o que impede uma figurinha exportada antiga de
        passar a creditar quem não é.
      </p>
    </div>
  )
}

const Linha = ({ rotulo, valor, suave }: { rotulo: string; valor: string; suave?: boolean }) => (
  <div className="flex justify-between py-2">
    <dt className="text-neutral-400">{rotulo}</dt>
    <dd className={suave ? 'font-mono text-xs text-neutral-500' : ''}>{valor}</dd>
  </div>
)
