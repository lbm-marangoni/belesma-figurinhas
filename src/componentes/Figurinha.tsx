import { useState } from 'react'
import { COR_TIER, ROTULO_TIER, type Carta } from '../lib/tipos'

/**
 * O ÚNICO componente de figurinha do projeto (spec §11). A coleção e a
 * revelação de pacote usam este mesmo. Nunca criar um segundo.
 *
 * Fase 2 é o esqueleto: arte estática, selo sobreposto e serial desenhado por
 * cima. Tilt, glare, holo por tier e overlay de desgaste entram na Fase 3,
 * como camadas AQUI DENTRO — não como outro componente.
 */
export function Figurinha({
  carta, tamanho = 'media', onClick, selecionada,
}: {
  carta: Carta
  tamanho?: 'miniatura' | 'media' | 'grande'
  onClick?: () => void
  selecionada?: boolean
}) {
  const [semArte, setSemArte] = useState(false)
  const cor = COR_TIER[carta.tier]

  const serial = carta.origin === 'forge'
    ? `FORJADA ${String(carta.forge_index ?? 0).padStart(2, '0')}`
    : `${String(carta.serial_number).padStart(String(carta.print_run).length, '0')}/${carta.print_run}`

  const escala = { miniatura: 'text-[10px]', media: 'text-xs', grande: 'text-sm' }[tamanho]

  return (
    <div
      onClick={onClick}
      className={`relative aspect-square w-full overflow-hidden rounded-lg bg-neutral-900 ${escala}
                  ${onClick ? 'cursor-pointer' : ''}
                  ${selecionada ? 'ring-2 ring-white' : ''}`}
      style={{ border: `2px solid ${cor}`, isolation: 'isolate' }}
      title={`${carta.character_name} · ${carta.skin} · ${ROTULO_TIER[carta.tier]}`}
    >
      {semArte ? (
        // A spec §3 é explícita: arte faltando nunca quebra a tela.
        <div className="grid h-full place-items-center bg-neutral-800 p-2 text-center text-neutral-400">
          {carta.character_slug}/{carta.skin}
        </div>
      ) : (
        <img
          src={`${import.meta.env.BASE_URL}figurinhas/${carta.character_slug}/${carta.skin}.jpg`}
          alt={`${carta.character_name} ${carta.skin}`}
          loading="lazy"
          onError={() => setSemArte(true)}
          className="h-full w-full object-cover"
        />
      )}

      {/* selo: PNG com alfa, canto superior direito, em diagonal (spec §6) */}
      {carta.seal !== 'none' && (
        <img
          src={`${import.meta.env.BASE_URL}selos/selo-${carta.seal}.png`}
          alt={`selo ${carta.seal}`}
          className="pointer-events-none absolute right-[3%] top-[3%] w-[26%] drop-shadow-lg"
          style={{ transform: 'rotate(20deg)' }}
        />
      )}

      {carta.damage_level > 0 && (
        <span className="absolute left-[3%] top-[3%] rounded bg-black/70 px-1 text-amber-400">
          desgaste {carta.damage_level}
        </span>
      )}

      {/* serial desenhado por cima — nunca gravado na arte (spec §3) */}
      <div className="pointer-events-none absolute inset-x-0 bottom-0 flex items-end justify-between
                      bg-gradient-to-t from-black/85 to-transparent px-1.5 pb-1 pt-5">
        <span className="truncate font-medium text-neutral-200">{carta.skin}</span>
        <span className="shrink-0 font-mono tabular-nums" style={{ color: cor }}>{serial}</span>
      </div>
    </div>
  )
}
