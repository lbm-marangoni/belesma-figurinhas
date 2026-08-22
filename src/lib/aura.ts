import type { Carta } from './tipos'
import { ROTULO_TIER } from './tipos'

/**
 * Que espetáculo cada carta merece ao sair do pacote.
 *
 * São DUAS camadas independentes, e elas empilham de propósito:
 *
 *   origem   por que esta carta está aqui — pacote quente, slot de hit,
 *            slot base. É a camada do PACOTE.
 *   identidade  o que a carta é — estreia mundial, selo, 1/N, tier alto.
 *            É a camada da CARTA.
 *
 * Se fossem uma coisa só, uma mítica dentro de um pacote quente teria que
 * escolher entre o fogo e o halo, e a informação mais rara — o selo, a
 * estreia — perderia para a mais comum. Empilhando, o fogo diz "pacote
 * quente" e o halo diz "e ainda por cima é uma rosa".
 */

export type Aura = {
  /** classes CSS a aplicar no invólucro da carta */
  classes: string[]
  /** faixa mostrada enquanto a carta emerge; null = carta sem evento */
  rotulo: string | null
  /** cor das fagulhas da identidade */
  cor: string
  /** quantas fagulhas soltar quando a carta sai de vez */
  faiscas: number
  /** raios girando atrás da carta — só para o que é raro de verdade */
  raios: boolean
}

type Identidade = {
  nome: string; rotulo: string | null; cor: string; faiscas: number
}

/** Do mais raro para o mais comum: a primeira que casar é a que manda. */
function identidade(c: Carta): Identidade {
  if (c.estreia_mundial)
    return { nome: 'estreia', rotulo: 'ESTREIA MUNDIAL', cor: '#ffffff', faiscas: 40 }
  if (c.seal === 'rosa')
    return { nome: 'selo-rosa', rotulo: 'SELO ROSA · 3 no mundo', cor: '#ff4fa3', faiscas: 36 }
  if (c.seal === 'preto')
    return { nome: 'selo-preto', rotulo: 'SELO PRETO · 12 no mundo', cor: '#b98cff', faiscas: 30 }
  if (c.seal === 'branco')
    return { nome: 'selo-branco', rotulo: 'SELO BRANCO · 36 no mundo', cor: '#e9e4ff', faiscas: 24 }
  if (c.tier === 'prisma')
    return { nome: 'prisma', rotulo: 'PRISMA', cor: '#ffffff', faiscas: 40 }
  if (c.tier === 'diamante')
    return { nome: 'diamante', rotulo: 'DIAMANTE', cor: '#67e8f9', faiscas: 34 }
  if (c.serial_number === 1)
    return { nome: 'uno', rotulo: `1 / ${c.print_run}`, cor: '#ffd86b', faiscas: 28 }
  if (c.tier_order >= 6)
    return { nome: 'alto', rotulo: ROTULO_TIER[c.tier].toUpperCase(), cor: '#7dd3fc', faiscas: 20 }
  if (c.from_hit_table)
    return { nome: 'hit', rotulo: ROTULO_TIER[c.tier].toUpperCase(), cor: '#c4b5fd', faiscas: 12 }
  return { nome: 'base', rotulo: null, cor: '#9ca3af', faiscas: 0 }
}

export function auraDaCarta(c: Carta, quente: boolean): Aura {
  const id = identidade(c)
  const classes = [`aura-${id.nome}`]
  if (quente) classes.push('aura-fogo')
  return {
    classes,
    // sem evento próprio dentro de pacote quente, o fogo é a notícia
    rotulo: id.rotulo ?? (quente ? 'PACOTE QUENTE' : null),
    cor: id.cor,
    faiscas: id.faiscas,
    // abaixo de selo/1-N os raios viram poluição: quase toda carta teria
    raios: id.faiscas >= 24,
  }
}
