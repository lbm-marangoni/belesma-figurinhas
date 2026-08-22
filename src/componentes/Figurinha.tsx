import { useRef, useState } from 'react'
import { useTilt } from '../lib/tilt'
import { COR_TIER, ROTULO_TIER, type Carta, type Tier } from '../lib/tipos'
import '../styles/figurinha.css'

/**
 * O ÚNICO componente de figurinha do projeto (spec §11). A coleção, a
 * revelação de pacote e o overlay de tela cheia usam este mesmo. Nunca criar
 * um segundo — o efeito por tier, o selo e o desgaste são CAMADAS aqui dentro.
 *
 * `interativa` liga tilt e shader. O grid da coleção passa false de propósito:
 * a spec §11 pede miniatura leve, só arte estática.
 */

/** Camadas por tier (spec §12). Ordem importa: glare por último fica por cima. */
function camadasDoTier(tier: Tier) {
  switch (tier) {
    case 'comum':
    case 'incomum':  return ['glare glare-suave']
    case 'rara':
    case 'epica':    return ['holo-leve', 'glare']
    case 'lendaria':
    case 'mitica':   return ['metalico', 'glare']
    case 'cosmica':
    case 'divina':   return ['holo-fino', 'glare']
    case 'infernal': return ['brasa', 'glare']
    case 'aura':     return ['halo-aura', 'halo-aura-brilho', 'glare']
    case 'diamante': return ['facetas', 'glare']
    case 'prisma':   return ['oil-slick', 'holo-fino', 'glare']
  }
}

export function serialDe(carta: Carta) {
  return carta.origin === 'forge'
    ? `FORJADA ${String(carta.forge_index ?? 0).padStart(2, '0')}`
    : `${String(carta.serial_number).padStart(String(carta.print_run).length, '0')}/${carta.print_run}`
}

export function Figurinha({
  carta, tamanho = 'media', interativa = false, onClick, selecionada,
}: {
  carta: Carta
  tamanho?: 'miniatura' | 'media' | 'grande'
  interativa?: boolean
  onClick?: () => void
  selecionada?: boolean
}) {
  const [semArte, setSemArte] = useState(false)
  const palco = useRef<HTMLDivElement>(null)
  const face = useRef<HTMLDivElement>(null)
  useTilt(palco, face, interativa)

  const cor = COR_TIER[carta.tier]
  const escala = { miniatura: 'text-[10px]', media: 'text-xs', grande: 'text-sm' }[tamanho]

  return (
    <div ref={palco} className={`palco ${onClick ? 'cursor-pointer' : ''}`} onClick={onClick}>
      <div
        ref={face}
        className={`carta3d aspect-square w-full rounded-lg bg-neutral-900 ${escala}
                    ${selecionada ? 'ring-2 ring-white' : ''}`}
        style={{ border: `2px solid ${cor}` }}
        title={`${carta.character_name} · ${carta.skin} · ${ROTULO_TIER[carta.tier]}`}
      >
        {semArte ? (
          // Spec §3: arte faltando nunca quebra a tela.
          <div className="grid h-full place-items-center bg-neutral-800 p-2 text-center text-neutral-400">
            {carta.character_slug}/{carta.skin}
          </div>
        ) : (
          <img
            src={`${import.meta.env.BASE_URL}figurinhas/${carta.character_slug}/${carta.skin}.jpg`}
            alt={`${carta.character_name} ${carta.skin}`}
            loading="lazy"
            draggable={false}
            onError={() => setSemArte(true)}
            className="h-full w-full object-cover"
          />
        )}

        {/* desgaste: cosmético, escala com o nível (spec §19.2) */}
        {carta.damage_level > 0 && (
          <div className={`camada desgaste-${carta.damage_level}`} aria-hidden />
        )}
        {carta.damage_level === 3 && <div className="camada desgaste-3-rasgo" aria-hidden />}

        {/* shader do tier — só quando interativa; a miniatura fica leve */}
        {interativa && camadasDoTier(carta.tier).map((c) => (
          <div key={c} className={`camada ${c}`} aria-hidden />
        ))}

        {/* selo: PNG com alfa, canto superior direito, em diagonal (spec §6) */}
        {carta.seal !== 'none' && (
          <img
            src={`${import.meta.env.BASE_URL}selos/selo-${carta.seal}.png`}
            alt={`selo ${carta.seal}`}
            draggable={false}
            className="pointer-events-none absolute right-[3%] top-[3%] w-[26%] drop-shadow-lg"
            style={{ transform: 'rotate(20deg)' }}
          />
        )}

        {carta.damage_level > 0 && (
          <span className="pointer-events-none absolute left-[3%] top-[3%] rounded bg-black/70 px-1 text-amber-400">
            desgaste {carta.damage_level}
          </span>
        )}

        {/* serial desenhado por cima — nunca gravado na arte (spec §3) */}
        <div className="pointer-events-none absolute inset-x-0 bottom-0 flex items-end justify-between
                        rounded-b-md bg-gradient-to-t from-black/85 to-transparent px-1.5 pb-1 pt-5">
          <span className="truncate font-medium text-neutral-200">{carta.skin}</span>
          <span className="shrink-0 font-mono tabular-nums" style={{ color: cor }}>{serialDe(carta)}</span>
        </div>
      </div>
    </div>
  )
}
