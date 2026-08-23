export type Tier =
  | 'comum' | 'incomum' | 'rara' | 'epica' | 'lendaria' | 'mitica'
  | 'cosmica' | 'divina' | 'infernal' | 'aura' | 'diamante' | 'prisma'

export type Selo = 'none' | 'branco' | 'preto' | 'rosa'
export type Origem = 'pull' | 'forge'
export type TipoPacote = 'comum' | 'raro' | 'ultra'

/** Uma pilha de pacotes na mao do jogador. `do_diario` separa o que veio do
 *  diario (sorteia da prateleira reservada) do que foi comprado ou ganho. */
export type ItemInventario = {
  pack_definition_id: number
  slug: string
  nome: string
  art_path: string | null
  do_diario: boolean
  quantidade: number
  tamanho: number
  ativo: boolean
}

/** Uma definicao de pacote, do catalogo publico. */
export type DefinicaoPacote = {
  id: number
  slug: string
  name: string
  descricao: string | null
  art_path: string | null
  tamanho: number
  distribuicao: 'loja' | 'admin' | 'missao' | 'diario' | 'allotment'
  elegivel_loja: boolean
  preco_baba: number | null
  limite_global: number | null
  aberturas_realizadas: number
  ativo: boolean
}

export type Jogador = {
  id: string
  nickname: string
  /** o que o jogador tem para abrir, uma linha por definicao de pacote */
  inventario: ItemInventario[]
  pacotes_total: number
  baba: number
  is_admin: boolean
  pity_counter: number
  last_daily_at: string | null
  dailies_claimed: number
}

/** O formato que open_pack devolve e o que a coleção monta. Um só, de propósito:
 *  o componente de figurinha é único no projeto (spec §11). */
export type Carta = {
  copy_id: number
  /** necessário para contar suas cópias do mesmo tipo (vender, colar, trocar) */
  card_type_id?: number
  serial_number: number
  print_run: number
  seal: Selo
  origin: Origem
  damage_level: number
  verify_code: string
  tier: Tier
  tier_order: number
  skin: string
  art_path: string
  character_slug: string
  character_name: string
  forge_index?: number | null
  /** só vem de open_pack */
  reveal_index?: number
  from_hit_table?: boolean
  nova?: boolean
  estreia_mundial?: boolean
}

export type ResultadoPacote = {
  abertura: number
  pack_type: TipoPacote
  do_diario: boolean
  quente: boolean
  bonus: boolean
  pity: boolean
  promovidos: number
  esperado: number
  cartas: Carta[]
}

export const TIERS: Tier[] = [
  'comum', 'incomum', 'rara', 'epica', 'lendaria', 'mitica',
  'cosmica', 'divina', 'infernal', 'aura', 'diamante', 'prisma',
]

export const ROTULO_TIER: Record<Tier, string> = {
  comum: 'Comum', incomum: 'Incomum', rara: 'Rara', epica: 'Épica',
  lendaria: 'Lendária', mitica: 'Mítica', cosmica: 'Cósmica', divina: 'Divina',
  infernal: 'Infernal', aura: 'Aura', diamante: 'Diamante', prisma: 'Prisma',
}

/** Cor de borda por tier. Sem holo nem glare — isso é Fase 3. */
export const COR_TIER: Record<Tier, string> = {
  comum: '#6b7280', incomum: '#84cc16', rara: '#3b82f6', epica: '#a855f7',
  lendaria: '#f59e0b', mitica: '#eab308', cosmica: '#06b6d4', divina: '#f0f9ff',
  infernal: '#ef4444', aura: '#ec4899', diamante: '#67e8f9', prisma: '#fff',
}
