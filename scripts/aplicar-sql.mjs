// Aplica um arquivo SQL no Supabase pela Management API.
//
//   SUPABASE_ACCESS_TOKEN=sbp_... node scripts/aplicar-sql.mjs arquivo.sql
//
// A service_role key NAO serve aqui: ela e um JWT do PostgREST e so enxerga
// tabelas e funcoes que ja existem. Criar funcao e DDL, e DDL so passa por
// esta API (ou por conexao direta com a senha do banco).
import { readFileSync } from 'node:fs'

const TOKEN = process.env.SUPABASE_ACCESS_TOKEN
const REF = process.env.SUPABASE_PROJECT_REF ?? 'jllecfwnwgabyqhhfanx'
const arquivo = process.argv[2]
if (!TOKEN || !arquivo) {
  console.error('uso: SUPABASE_ACCESS_TOKEN=sbp_... node scripts/aplicar-sql.mjs <arquivo.sql>')
  process.exit(2)
}

const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: readFileSync(arquivo, 'utf8') }),
})
const corpo = await r.text()
if (!r.ok) { console.error(`HTTP ${r.status}\n${corpo}`); process.exit(1) }
console.log(`ok (${r.status})`, corpo.slice(0, 300))
