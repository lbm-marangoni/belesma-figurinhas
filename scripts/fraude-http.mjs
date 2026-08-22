// Teste de fraude contra o Supabase DE VERDADE, por HTTP, com a anon key.
//
// O verificar-fase1.mjs cobre a camada do banco (policies e GRANTs) num
// Postgres local. Este aqui cobre o que faltava: PostgREST, o JWT do Auth e o
// auth.uid() real. Roda contra o projeto configurado em .env.local.
//
//   node scripts/fraude-http.mjs
//
// Precisa de SUPABASE_SERVICE_ROLE_KEY no ambiente para CRIAR o jogador
// cobaia. A chave de servico nunca e usada nas tentativas de fraude - so no
// preparo. As tentativas usam exclusivamente a anon key.

import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const env = Object.fromEntries(
  readFileSync(join(raiz, '.env.local'), 'utf8')
    .split('\n').filter((l) => l.includes('=') && !l.trim().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)

const URL = env.VITE_SUPABASE_URL
const ANON = env.VITE_SUPABASE_ANON_KEY
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SERVICE) { console.error('falta SUPABASE_SERVICE_ROLE_KEY no ambiente'); process.exit(2) }

const admin = createClient(URL, SERVICE, { auth: { persistSession: false } })
const anon = createClient(URL, ANON, { auth: { persistSession: false } })

let falhas = 0
const checar = (nome, ok, detalhe) => {
  console.log(`  ${ok ? 'PASS' : 'FALHA'}  ${nome}${detalhe ? ' -> ' + detalhe : ''}`)
  if (!ok) falhas++
}
const deveFalhar = (nome, { error, data }) => {
  const vazio = Array.isArray(data) && data.length === 0
  checar(nome, !!error || vazio, error ? error.message.slice(0, 80) : vazio ? 'nenhuma linha afetada' : 'PASSOU - furo')
}
const devePassar = (nome, { error }) => checar(nome, !error, error?.message?.slice(0, 80))

// ---------------------------------------------------------------- preparo
const EMAIL = 'cobaia@belesma.local'
const SENHA = 'cobaia-teste-123456'
await admin.auth.admin.listUsers().then(({ data }) => {
  const j = data?.users?.find((u) => u.email === EMAIL)
  return j ? admin.auth.admin.deleteUser(j.id) : null
})
const { data: criado, error: erroCriar } = await admin.auth.admin.createUser({
  email: EMAIL, password: SENHA, email_confirm: true,
})
if (erroCriar) { console.error('nao consegui criar a cobaia:', erroCriar.message); process.exit(2) }
await admin.from('players').insert({ id: criado.user.id, nickname: 'cobaia' })

const alvo = (await admin.from('card_copies').select('id, verify_code').limit(1)).data[0]

// ================================================================ anon
console.log('\n== anon (sem login), por HTTP ==')
deveFalhar('update card_copies.owner_id', await anon.from('card_copies').update({ owner_id: criado.user.id }).eq('id', alvo.id).select())
deveFalhar('insert card_copies', await anon.from('card_copies').insert({ card_type_id: 1, serial_number: 99999, verify_code: 'FRAUDE0001' }).select())
deveFalhar('alterar seal', await anon.from('card_copies').update({ seal: 'rosa' }).eq('id', alvo.id).select())
deveFalhar('delete card_copies', await anon.from('card_copies').delete().eq('id', alvo.id).select())
deveFalhar('ler players direto', await anon.from('players').select('baba'))
deveFalhar('mexer nas odds', await anon.from('pack_config').update({ weight: 100 }).eq('tier', 'prisma').select())
deveFalhar('mexer nos precos', await anon.from('economy_config').update({ valor: 0 }).eq('chave', 'compra_ultra').select())
deveFalhar('escrever em seal_audit', await anon.from('seal_audit').update({ branco: 999 }).eq('character_id', 1).select())

// ================================================================ jogador
console.log('\n== jogador comum logado, por HTTP ==')
const { error: erroLogin } = await anon.auth.signInWithPassword({ email: EMAIL, password: SENHA })
if (erroLogin) { console.error('login falhou:', erroLogin.message); process.exit(2) }
console.log('  (logado como cobaia)')

deveFalhar('update card_copies.owner_id', await anon.from('card_copies').update({ owner_id: criado.user.id }).eq('id', alvo.id).select())
deveFalhar('insert card_copies', await anon.from('card_copies').insert({ card_type_id: 1, serial_number: 99998, verify_code: 'FRAUDE0002' }).select())
deveFalhar('alterar seal', await anon.from('card_copies').update({ seal: 'rosa' }).eq('id', alvo.id).select())
deveFalhar('creditar baba para si', await anon.from('players').update({ baba: 999999 }).eq('id', criado.user.id).select())
deveFalhar('virar admin', await anon.from('players').update({ is_admin: true }).eq('id', criado.user.id).select())
deveFalhar('alterar allotment', await anon.from('players').update({ packs_ultra: 999 }).eq('id', criado.user.id).select())
deveFalhar('select * em players', await anon.from('players').select('*'))
deveFalhar('inserir em baba_log', await anon.from('baba_log').insert({ player_id: criado.user.id, delta: 99999, motivo: 'fraude' }).select())
deveFalhar('inserir em admin_log', await anon.from('admin_log').insert({ admin_id: criado.user.id, acao: 'fraude' }).select())
deveFalhar('ler admin_log sem ser admin', await anon.from('admin_log').select('*'))
deveFalhar('escrever em seal_audit', await anon.from('seal_audit').update({ branco: 999 }).eq('character_id', 1).select())
deveFalhar('chamar random_int do schema private', await anon.rpc('random_int', { n: 10 }))

// ================================================================ legitimo
console.log('\n== leituras legitimas ==')
devePassar('ler card_copies (indice global publico)', await anon.from('card_copies').select('id').limit(1))
devePassar('ler o catalogo', await anon.from('card_types').select('id').limit(1))
devePassar('select * em players_public', await anon.from('players_public').select('*').limit(1))
devePassar('ler seal_audit (auditoria publica)', await anon.from('seal_audit').select('*'))
devePassar('ler o proprio saldo por me()', await anon.rpc('me'))

const { data: eu } = await anon.rpc('me')
checar('me() devolve a propria linha', eu?.nickname === 'cobaia', eu?.nickname)
checar('me() nao vaza is_admin ligado', eu?.is_admin === false, String(eu?.is_admin))

// ================================================================ admin
// A policy do admin_log precisa funcionar PARA admin. Sem isso o painel da
// secao 18 abriria vazio e o erro nem apontaria para o lugar certo.
console.log('\n== promovendo a cobaia a admin ==')
await admin.from('players').update({ is_admin: true }).eq('id', criado.user.id)
devePassar('admin: ler admin_log', await anon.from('admin_log').select('*'))
const { data: euAdmin } = await anon.rpc('me')
checar('me() reflete is_admin', euAdmin?.is_admin === true, String(euAdmin?.is_admin))
const { data: ehAdmin } = await anon.rpc('sou_admin')
checar('sou_admin() devolve true', ehAdmin === true, String(ehAdmin))

await admin.from('players').update({ is_admin: false }).eq('id', criado.user.id)
deveFalhar('ex-admin: ler admin_log', await anon.from('admin_log').select('*'))

// ---------------------------------------------------------------- limpeza
await anon.auth.signOut()
await admin.from('players').delete().eq('id', criado.user.id)
await admin.auth.admin.deleteUser(criado.user.id)

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
process.exit(falhas === 0 ? 0 : 1)
