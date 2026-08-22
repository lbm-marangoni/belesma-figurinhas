export type Tier =
  | 'comum' | 'incomum' | 'rara' | 'epica' | 'lendaria' | 'mitica'
  | 'cosmica' | 'divina' | 'infernal' | 'aura' | 'diamante' | 'prisma'

export type Selo = 'none' | 'branco' | 'preto' | 'rosa'
export type Origem = 'pull' | 'forge'
export type TipoPacote = 'comum' | 'raro' | 'ultra'

export type Jogador = {
  id: string
  nickname: string
  packs_common: number; packs_rare: number; packs_ultra: number
  packs_common_daily: number; packs_rare_daily: number; packs_ultra_daily: number
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
