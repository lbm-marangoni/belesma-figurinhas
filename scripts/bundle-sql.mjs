// Junta as migracoes num arquivo unico para colar no SQL editor do Supabase.
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const dir = join(raiz, 'supabase', 'migrations')
const saida = join(raiz, 'supabase', 'apply-all.sql')

const corpo = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => `-- ===== ${f} =====\n` + readFileSync(join(dir, f), 'utf8'))
  .join('\n\n')

writeFileSync(saida,
  '-- BELESMA figurinhas - todas as migracoes em um arquivo.\n' +
  '-- Gerado por scripts/bundle-sql.mjs. Cole no SQL editor do Supabase.\n\n' +
  'begin;\n\n' + corpo + '\n\ncommit;\n')

console.log(`apply-all.sql: ${(statSync(saida).size / 1024) | 0} KB`)
