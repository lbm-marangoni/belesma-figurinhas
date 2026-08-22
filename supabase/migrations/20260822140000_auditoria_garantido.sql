-- BELESMA figurinhas - torna a regra dura de diamante/prisma AUDITAVEL
--
-- A spec secao 8 diz: "diamante e prisma nunca saem em slot garantido - nem
-- na promocao, nem no pacote quente, nem no pity. So do slot de hit de
-- pacote Comum, sorteado livre pela tabela."
--
-- Ate agora a auditoria guardava se a carta veio da tabela de hit, mas nao
-- se o SLOT era garantido. Sem isso nao da para conferir a regra: um pacote
-- Comum com uma promocao pode legitimamente trazer um diamante no slot de
-- hit NATURAL, e de fora os dois casos pareciam iguais.
--
-- Foi exatamente isso que deu falso positivo no teste da Fase 2.

alter table public.pack_opening_cards
  add column if not exists garantido boolean not null default false;

comment on column public.pack_opening_cards.garantido is
  'Slot garantido (promocao, pacote quente ou pity). Nestes, diamante e '
  'prisma sao proibidos pela regra dura da secao 8.';
