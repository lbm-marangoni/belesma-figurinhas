import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { emailDe, useSessao } from '../lib/sessao'

export default function Login() {
  const { recarregar } = useSessao()
  const [modo, setModo] = useState<'entrar' | 'criar'>('entrar')
  const [apelido, setApelido] = useState('')
  const [senha, setSenha] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)

  const apelidoValido = /^[a-z0-9][a-z0-9_-]{2,19}$/.test(apelido)

  async function enviar(e: React.FormEvent) {
    e.preventDefault()
    setErro(null)
    if (!apelidoValido) return setErro('Apelido: 3 a 20 caracteres, minúsculas, números, - e _')
    if (senha.length < 6) return setErro('A senha precisa de no mínimo 6 caracteres')

    setOcupado(true)
    try {
      const email = emailDe(apelido)
      if (modo === 'criar') {
        const { data: livre } = await supabase.rpc('nickname_disponivel', { p_nickname: apelido })
        if (livre === false) throw new Error('Esse apelido já existe')

        const { error } = await supabase.auth.signUp({ email, password: senha })
        if (error) throw error
        // Se o projeto exigir confirmação de e-mail não haverá sessão aqui;
        // como o e-mail é sintético, a confirmação fica desligada.
        const { error: e2 } = await supabase.rpc('claim_nickname', { p_nickname: apelido })
        if (e2) throw e2
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password: senha })
        if (error) throw new Error('Apelido ou senha não confere')
        // Reivindicar é idempotente: cobre quem criou a conta e perdeu o passo.
        await supabase.rpc('claim_nickname', { p_nickname: apelido })
      }
      await recarregar()
    } catch (e) {
      setErro(e instanceof Error ? e.message : String(e))
    } finally {
      setOcupado(false)
    }
  }

  return (
    <main className="grid min-h-dvh place-items-center p-6">
      <form onSubmit={enviar} className="w-full max-w-sm">
        <h1 className="marca text-4xl">BELESMA</h1>
        <p className="mt-1 text-sm text-neutral-400">
          {modo === 'entrar' ? 'Entrar na coleção' : 'Criar apelido'}
        </p>

        <label className="mt-6 block text-sm text-neutral-400">
          Apelido
          <input
            value={apelido}
            onChange={(e) => setApelido(e.target.value.toLowerCase().trim())}
            autoComplete="username"
            className="campo mt-1 w-full text-base"
          />
        </label>

        <label className="mt-3 block text-sm text-neutral-400">
          Senha
          <input
            type="password"
            value={senha}
            onChange={(e) => setSenha(e.target.value)}
            autoComplete={modo === 'criar' ? 'new-password' : 'current-password'}
            className="campo mt-1 w-full text-base"
          />
        </label>

        {erro && (
          <p className="aviso-ruim mt-3 rounded-lg p-2 text-sm">{erro}</p>
        )}

        <button
          type="submit"
          disabled={ocupado}
          className="btn btn-forte mt-4 w-full py-2"
        >
          {ocupado ? '...' : modo === 'entrar' ? 'Entrar' : 'Criar'}
        </button>

        <button
          type="button"
          onClick={() => { setModo(modo === 'entrar' ? 'criar' : 'entrar'); setErro(null) }}
          className="mt-3 w-full text-sm text-neutral-400 underline underline-offset-4"
        >
          {modo === 'entrar' ? 'Não tenho apelido ainda' : 'Já tenho apelido'}
        </button>

        {/* Spec §10: avisar, sem enfeitar. */}
        <p className="mt-6 border-t border-neutral-800 pt-4 text-xs leading-relaxed text-neutral-500">
          O apelido é único e travado depois de criado. <strong className="text-neutral-400">Não
          existe recuperação de senha automática</strong> — se esquecer, só um admin reseta na mão.
        </p>
      </form>
    </main>
  )
}
