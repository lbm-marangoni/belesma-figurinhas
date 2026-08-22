// DELETE e UPDATE sem WHERE: passa no PGlite, falha no Supabase.
//
//   node scripts/verificar-safeupdate.mjs
//
// O Supabase liga o safeupdate (supautils), que recusa DELETE e UPDATE sem
// clausula WHERE com "DELETE requires a WHERE clause". A trava e da SESSAO,
// entao vale inclusive dentro de funcao `security definer` chamada pelo
// papel `authenticated`.
//
// O PGlite nao tem essa extensao. Sem esta verificacao, uma funcao com
// `delete from tabela;` passa em toda a bateria local e so quebra na cara do
// jogador - foi o que aconteceu com admin_recomecar_do_zero.
//
// Se apagar tudo E a intencao, escreva `where true`. Nao e enfeite: e a
// declaracao de que e proposital.

import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const dir = join(raiz, 'supabase', 'migrations')

/**
 * Quebra o SQL em comandos, contando parenteses e pulando literais.
 *
 * Contar parenteses e o ponto: `update t set x = (select 1 from y where z)`
 * TEM um where, mas dentro de subconsulta - no nivel do comando ele nao
 * existe, e o safeupdate recusa. Um regex ingenuo da esse falso negativo.
 */
function comandos(sql) {
  const fora = []
  let atual = '', prof = 0, i = 0
  while (i < sql.length) {
    const c = sql[i]

    // comentario de linha
    if (c === '-' && sql[i + 1] === '-') {
      const fim = sql.indexOf('\n', i)
      i = fim === -1 ? sql.length : fim
      continue
    }
    // comentario de bloco
    if (c === '/' && sql[i + 1] === '*') {
      const fim = sql.indexOf('*/', i)
      i = fim === -1 ? sql.length : fim + 2
      continue
    }
    // literal entre aspas simples
    if (c === "'") {
      const j = sql.indexOf("'", i + 1)
      i = j === -1 ? sql.length : j + 1
      atual += ' '
      continue
    }
    // identificador entre aspas duplas
    if (c === '"') {
      const j = sql.indexOf('"', i + 1)
      i = j === -1 ? sql.length : j + 1
      atual += ' x '
      continue
    }
    // $$ ... $$ / $fn$ ... $fn$: o corpo da funcao. Entramos nele de
    // proposito - e la dentro que moram os deletes.
    const cifrao = /^\$[a-z_]*\$/i.exec(sql.slice(i))
    if (cifrao) {
      atual += ' '
      i += cifrao[0].length
      continue
    }

    if (c === '(') prof++
    else if (c === ')') prof--
    else if (c === ';' && prof === 0) {
      fora.push(atual)
      atual = ''
      i++
      continue
    }
    atual += c
    i++
  }
  if (atual.trim()) fora.push(atual)
  return fora
}

/** O comando tem um WHERE no nivel dele, fora de qualquer parentese? */
function temWhereNoTopo(cmd) {
  let prof = 0
  const re = /\(|\)|\bwhere\b/gi
  let m
  while ((m = re.exec(cmd))) {
    if (m[0] === '(') prof++
    else if (m[0] === ')') prof--
    else if (prof === 0) return true
  }
  return false
}

let achados = 0
for (const arquivo of readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()) {
  const sql = readFileSync(join(dir, arquivo), 'utf8')
  for (const cmd of comandos(sql)) {
    const limpo = cmd.trim().replace(/\s+/g, ' ')
    const abre = /^(delete\s+from|update)\s+([a-z_]+(?:\.[a-z_]+)?)/i.exec(limpo)
    if (!abre) continue
    // `update` sem SET e `update` de outra coisa (ex.: "for update")
    if (/^update/i.test(limpo) && !/\bset\b/i.test(limpo)) continue
    if (temWhereNoTopo(limpo)) continue
    const linha = sql.slice(0, sql.indexOf(cmd.trim().slice(0, 40))).split('\n').length
    console.log(`  FALHA  ${arquivo}:~${linha}  ${abre[1].toLowerCase()} ${abre[2]} sem WHERE`)
    achados++
  }
}

if (achados === 0) {
  console.log('  PASS  nenhum DELETE/UPDATE sem WHERE nas migracoes')
  console.log('\nTUDO PASSOU')
} else {
  console.log(`\n${achados} comando(s) que o Supabase vai recusar. Use \`where true\` se for proposital.`)
}
process.exit(achados === 0 ? 0 : 1)
