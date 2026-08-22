-- BELESMA figurinhas - Fase 1: seed do lancamento (spec secoes 4, 6, 8, 19)
--
-- 3 personagens x 27 skins = 81 card_types, 6642 card_copies.
-- Selos: 12 branco / 4 preto / 1 rosa por personagem = 36 / 12 / 3 no set.
--
-- Idempotente: pode rodar de novo sem duplicar nem apagar posse.
-- NAO cria o quarto personagem. Ele entra depois por seed_edition (secao 16).

-- ---------------------------------------------------------------- tiers
insert into public.tiers (slug, tier_order, print_run, forjavel, vendavel, label) values
  ('comum',     1, 250, true, true,  'Comum'),
  ('incomum',   2, 150, true, true,  'Incomum'),
  ('rara',      3, 100, true, true,  'Rara'),
  ('epica',     4,  50, true, true,  'Epica'),
  ('lendaria',  5,  30, true, true,  'Lendaria'),
  ('mitica',    6,  20, false, true, 'Mitica'),      -- teto da forja (secao 7)
  ('cosmica',   7,  15, false, true, 'Cosmica'),
  ('divina',    8,  10, false, true, 'Divina'),
  ('infernal',  9,   5, false, true, 'Infernal'),
  ('aura',     10,   3, false, true, 'Aura'),
  ('diamante', 11,   2, false, true, 'Diamante'),
  ('prisma',   12,   1, false, false, 'Prisma')
on conflict (slug) do nothing;

-- ---------------------------------------------------------------- characters
-- Lancamento com TRES. O quarto entra por seed_edition, nao aqui.
insert into public.characters (id, slug, name, display_order, palette_primary, palette_accent) values
  (1, 'pedrao', 'Belesma do Pedrao', 1, '#5b7a4e', '#8fb04a'),
  (2, 'dinho',  'Belesma do Dinho',  2, '#3d4a63', '#7f6bb0'),
  (3, 'santao', 'Belesma do Santao', 3, '#6b4a3d', '#c98a3e')
on conflict (id) do nothing;
select setval(pg_get_serial_sequence('public.characters','id'),
              (select max(id) from public.characters));

-- ---------------------------------------------------------------- catalogo de skins
-- Fonte unica da escada. album_pages e card_types saem dos dois daqui.
insert into public.skins (slug, tier, skin_order, tema, label) values
  ('original',    'comum',     1, 'Origens',    'Original'),
  ('musgo',       'comum',     2, 'Origens',    'Musgo'),
  ('chuva',       'comum',     3, 'Origens',    'Chuva'),
  ('noite',       'comum',     4, 'Origens',    'Noite'),
  ('bronze',      'incomum',   5, 'Metais',     'Bronze'),
  ('cobre',       'incomum',   6, 'Metais',     'Cobre'),
  ('ferro',       'incomum',   7, 'Metais',     'Ferro'),
  ('fogo',        'rara',      8, 'Elementais', 'Fogo'),
  ('gelo',        'rara',      9, 'Elementais', 'Gelo'),
  ('trovao',      'rara',     10, 'Elementais', 'Trovao'),
  ('vento',       'rara',     11, 'Elementais', 'Vento'),
  ('esmeralda',   'epica',    12, 'Gemas',      'Esmeralda'),
  ('rubi',        'epica',    13, 'Gemas',      'Rubi'),
  ('safira',      'epica',    14, 'Gemas',      'Safira'),
  ('ametista',    'epica',    15, 'Gemas',      'Ametista'),
  ('prata',       'lendaria', 16, 'Pedra',      'Prata'),
  ('marmore',     'lendaria', 17, 'Pedra',      'Marmore'),
  ('obsidiana',   'lendaria', 18, 'Pedra',      'Obsidiana'),
  ('ouro',        'mitica',   19, 'Ouro',       'Ouro'),
  ('galaxia',     'cosmica',  20, 'Cosmos',     'Galaxia'),
  ('nebulosa',    'cosmica',  21, 'Cosmos',     'Nebulosa'),
  ('celestial',   'divina',   22, 'Celestial',  'Celestial'),
  ('inferno',     'infernal', 23, 'Inferno',    'Inferno'),
  ('aura-branca', 'aura',     24, 'Auras',      'Aura Branca'),
  ('aura-preta',  'aura',     25, 'Auras',      'Aura Preta'),
  ('diamante',    'diamante', 26, 'Diamante',   'Diamante'),
  ('prisma',      'prisma',   27, 'Prisma',     'Prisma')
on conflict (slug) do nothing;

-- ---------------------------------------------------------------- album_pages
-- Secao 11: uma pagina por tema (= skin), com um slot por personagem.
-- Personagem novo preenche os slots sozinho; esta tabela nao muda.
insert into public.album_pages (slug, title, page_order, tier_filter, skin_filter)
select s.slug,
       case when s.tema = s.label then s.label
            else s.tema || ' - ' || s.label end,
       s.skin_order,
       s.tier,
       s.slug
from public.skins s
on conflict (slug) do nothing;

-- Pagina extra, so aparece para quem tem selo (secao 11).
insert into public.album_pages (slug, title, page_order, tier_filter, skin_filter, seal_only)
values ('selados', 'Selados', 28, null, null, true)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------- card_types
-- 3 personagens x 27 skins = 81.
insert into public.card_types (character_id, tier, tier_order, skin, print_run, art_path, album_page)
select c.id,
       s.tier,
       t.tier_order,
       s.slug,
       t.print_run,
       '/figurinhas/' || c.slug || '/' || s.slug || '.jpg',
       ap.id
from public.characters c
cross join public.skins s
join public.tiers t       on t.slug = s.tier
join public.album_pages ap on ap.slug = s.slug
on conflict (character_id, skin) do nothing;

-- ---------------------------------------------------------------- card_copies
-- 6642 copias. Cada serial existe uma unica vez no mundo.
-- verify_code e deterministico: mesma copia, mesmo codigo, sempre (secao 14).
insert into public.card_copies (card_type_id, serial_number, verify_code)
select ct.id,
       s,
       upper(substr(
         encode(extensions.digest('belesma-v1|' || ch.slug || '|' || ct.skin || '|' || s::text, 'sha256'), 'hex'),
         1, 10))
from public.card_types ct
join public.characters ch on ch.id = ct.character_id
cross join lateral generate_series(1, ct.print_run) as s
on conflict (card_type_id, serial_number) do nothing;

-- ---------------------------------------------------------------- selos
-- Secao 6: 12 branco / 4 preto / 1 rosa por personagem, sorteio uniforme
-- sobre TODAS as copias daquele personagem, sem excluir nenhum tier -
-- inclusive a Prisma 1/1.
--
-- O sorteio real vive em private.distribuir_selos(), por CSPRNG, e grava em
-- seal_audit. Rodar este seed de novo NAO re-sorteia: a funcao sai na hora se
-- ja existir auditoria para o personagem.
select private.distribuir_selos(c.id) from public.characters c order by c.id;

-- ---------------------------------------------------------------- reserva do diario
-- Secao 8: 1500 copias do pool base, 500 por personagem. Tambem por CSPRNG.
-- Completa ate o alvo, entao re-executar nunca marca copia que ja tem dono.
select private.reservar_diario(c.id, 500) from public.characters c order by c.id;

-- ---------------------------------------------------------------- pack_config
-- Secao 8. Cada (pack_type, slot) soma exatamente 100.
insert into public.pack_config (pack_type, slot, tier, weight) values
  -- slot base, igual para os tres tipos
  ('comum','base','comum',   62.5), ('comum','base','incomum', 37.5),
  ('raro', 'base','comum',   62.5), ('raro', 'base','incomum', 37.5),
  ('ultra','base','comum',   62.5), ('ultra','base','incomum', 37.5),

  -- slot de hit
  ('comum','hit','rara',     78),
  ('comum','hit','epica',    12),
  ('comum','hit','lendaria',  6),
  ('comum','hit','mitica',    2),
  ('comum','hit','cosmica',   1.2),
  ('comum','hit','divina',    0.5),
  ('comum','hit','infernal',  0.15),
  ('comum','hit','aura',      0.05),
  ('comum','hit','diamante',  0.08),
  ('comum','hit','prisma',    0.02),

  ('raro','hit','epica',     60),
  ('raro','hit','lendaria',  25),
  ('raro','hit','mitica',     8),
  ('raro','hit','cosmica',    5),
  ('raro','hit','divina',     1.5),
  ('raro','hit','infernal',   0.4),
  ('raro','hit','aura',       0.1),

  ('ultra','hit','mitica',   55),
  ('ultra','hit','cosmica',  31),
  ('ultra','hit','divina',    9),
  ('ultra','hit','infernal',  3),
  ('ultra','hit','aura',      2)
on conflict (pack_type, slot, tier) do nothing;

-- ---------------------------------------------------------------- pack_params
insert into public.pack_params (chave, valor, descricao) values
  ('cartas_base',            3,    'Cartas do slot base por pacote'),
  ('promocao_base',          0.04, 'Chance de cada slot base sortear da tabela de hit'),
  ('pacote_quente',          0.015,'Chance de todos os 4 slots virem da tabela de hit'),
  ('carta_bonus',            0.08, 'Chance de uma 5a carta do pool base'),
  ('pity_limite',            12,   'Comuns seguidos sem nada acima de rara ate garantir epica+'),
  ('allotment_comum',        12,   'Allotment inicial, pacotes comuns'),
  ('allotment_raro',         5,    'Allotment inicial, pacotes raros'),
  ('allotment_ultra',        2,    'Allotment inicial, pacotes ultra'),
  ('diario_comuns',          2,    'Pacotes comuns por resgate diario'),
  ('diario_raros',           1,    'Pacotes raros por resgate diario'),
  ('diario_ultra_ciclo',     3,    'A cada N resgates, tambem credita 1 ultra'),
  ('reserva_diaria_inicial', 1500, 'Copias base marcadas reserved_for_daily no seed')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------- economy_config
-- Secao 19.7: nada de preco hardcoded. O painel admin edita isto.
insert into public.economy_config (chave, valor, descricao) values
  ('venda_comum',              5, 'Valor de venda, tier comum'),
  ('venda_incomum',           12, 'Valor de venda, tier incomum'),
  ('venda_rara',              30, 'Valor de venda, tier rara'),
  ('venda_epica',             80, 'Valor de venda, tier epica'),
  ('venda_lendaria',         150, 'Valor de venda, tier lendaria'),
  ('venda_mitica',           300, 'Valor de venda, tier mitica'),
  ('venda_cosmica',          500, 'Valor de venda, tier cosmica'),
  ('venda_divina',           900, 'Valor de venda, tier divina'),
  ('venda_infernal',        1800, 'Valor de venda, tier infernal'),
  ('venda_aura',            5000, 'Valor de venda, tier aura'),
  ('venda_diamante',        8000, 'Valor de venda, tier diamante'),
  -- prisma nao vende: ausencia de chave = venda proibida

  ('compra_comum',           120, 'Preco do pacote comum na loja'),
  ('compra_raro',            400, 'Preco do pacote raro na loja'),
  ('compra_ultra',          1000, 'Preco do pacote ultra na loja'),
  ('dirigido_mult',            2, 'Multiplicador do pacote dirigido a um personagem'),
  ('teto_compra_dia',          3, 'Maximo de pacotes comprados por jogador por dia'),

  ('restauro_mult_1',        1.5, 'Custo de restaurar nivel 1, sobre o valor do tier'),
  ('restauro_mult_2',          3, 'Custo de restaurar nivel 2, sobre o valor do tier'),
  ('restauro_mult_3',          6, 'Custo de restaurar nivel 3, sobre o valor do tier'),
  ('multiplicador_estragada',0.4, 'Fracao do valor pago por copia com damage_level > 0'),
  ('multiplicador_forjada',  0.4, 'Fracao do valor pago por copia origin=forge'),

  ('bonus_pagina',           150, 'Completar pagina do album, uma vez por pagina'),
  ('bonus_estreia',          200, 'Primeira descoberta mundial de um card_type'),
  ('bonus_troca',             25, 'Troca concluida, para cada lado'),
  ('bonus_troca_max_dia',      5, 'Maximo de trocas pagas por jogador por dia'),
  ('bonus_login',             30, 'Login diario'),
  ('bonus_login_streak7',    100, 'Bonus extra no setimo dia de streak')
on conflict (chave) do nothing;
