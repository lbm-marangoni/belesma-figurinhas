// Aplica um arquivo SQL no Supabase pela Management API.
//
//   SUPABASE_ACCESS_TOKEN=sbp_... node scripts/aplicar-sql.mjs arquivo.sql
//
// A service_role key NAO serve aqui: ela e um JWT do PostgREST e so enxerga
// tabelas e funcoes que ja existem. Criar funcao e DDL, e DDL so passa por
// esta API (ou por conexao direta com a senha do banco).
import { readFileSync, readdirSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'

const TOKEN = process.env.SUPABASE_ACCESS_TOKEN
const REF = process.env.SUPABASE_PROJECT_REF ?? 'jllecfwnwgabyqhhfanx'
const arquivo = process.argv[2]
if (!TOKEN || !arquivo) {
  console.error('uso: SUPABASE_ACCESS_TOKEN=sbp_... node scripts/aplicar-sql.mjs <arquivo.sql>')
  process.exit(2)
}

// AVISO: aplicar UMA migracao antiga isolada reverte tudo que veio depois
// dela. As migracoes usam `create or replace`, entao rodar um arquivo velho
// recria as versoes velhas das funcoes que arquivos posteriores ja
// substituiram. Aconteceu: reaplicar rpc_admin.sql para um ajuste pequeno
// devolveu o admin_jogadores que lia colunas ja derrubadas, e a producao
// quebrou ate a cadeia ser reaplicada por inteiro.
const dir = dirname(arquivo)
if (basename(dir) === 'migrations') {
  const todas = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()
  const eu = todas.indexOf(basename(arquivo))
  if (eu !== -1 && eu < todas.length - 1) {
    console.warn(`AVISO: ${basename(arquivo)} nao e a ultima migracao.`)
    console.warn(`       Ha ${todas.length - 1 - eu} depois dela que podem recriar o que`)
    console.warn('       este arquivo desfaz. Rode tambem as posteriores, em ordem.')
  }
}

const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: readFileSync(arquivo, 'utf8') }),
})
const corpo = await r.text()
if (!r.ok) { console.error(`HTTP ${r.status}\n${corpo}`); process.exit(1) }
// truncar a resposta escondia auditorias inteiras; o limite agora e opcional
const limite = Number(process.env.SQL_MAX ?? 0)
console.log(`ok (${r.status})`, limite > 0 ? corpo.slice(0, limite) : corpo)
