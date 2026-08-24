-- BELESMA figurinhas - todas as migracoes em um arquivo.
-- Gerado por scripts/bundle-sql.mjs. Cole no SQL editor do Supabase.

begin;

-- ===== 20260821120000_schema.sql =====
-- BELESMA figurinhas - Fase 1: schema completo (spec secoes 5, 6, 7, 8, 18, 19)
--
-- Principios que este arquivo obedece:
--   - a escada de raridade e DADO (tabela tiers), nunca enum nem codigo
--   - o cliente nunca escreve em card_copies, players, trades ou baba
--   - nao existe admin_key: a guarda e players.is_admin, checada no banco

-- pgcrypto e citext: no Supabase eles moram no schema "extensions"; num
-- Postgres cru (e no PGlite do harness) cairiam em "public". Fixamos os dois
-- em "extensions" nos dois ambientes para que um unico search_path sirva.
--
-- Isto NAO e detalhe: as funcoes abaixo tem "set search_path" explicito, que
-- e obrigatorio em security definer. Sem "extensions" nessa lista,
-- gen_random_bytes() nao resolve e o sorteio de selo quebra - foi exatamente
-- o que aconteceu na primeira tentativa de deploy.
create schema if not exists extensions;
create extension if not exists citext   with schema extensions;
create extension if not exists pgcrypto with schema extensions;
grant usage on schema extensions to public;

create schema if not exists private;

-- ---------------------------------------------------------------- enums
-- Fixos por design. O que precisa crescer sem migracao mora em tabela.
do $$ begin
  create type public.seal_type   as enum ('none','branco','preto','rosa');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.copy_origin as enum ('pull','forge');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.pack_type   as enum ('comum','raro','ultra');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.pack_slot   as enum ('base','hit');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.trade_status as enum ('pending','accepted','declined','cancelled');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------- tiers
-- Spec secao 4. Adicionar tier no futuro e um INSERT, nao um deploy.
create table if not exists public.tiers (
  slug        text     primary key,
  tier_order  smallint not null unique,
  print_run   int      not null check (print_run > 0),
  forjavel    boolean  not null default false,   -- secao 7: forja so produz ate mitica
  vendavel    boolean  not null default true,    -- secao 19.4: prisma nao vende
  label       text     not null
);

-- ---------------------------------------------------------------- skins
-- Spec secao 4: a escada precisa ser dado. Personagem novo nao traz lista de
-- skin no parametro - seed_edition le daqui.
create table if not exists public.skins (
  slug       text primary key,
  tier       text not null references public.tiers(slug),
  skin_order int  not null unique,
  tema       text not null,
  label      text not null
);

-- ---------------------------------------------------------------- characters
create table if not exists public.characters (
  id              serial primary key,
  slug            extensions.citext not null unique,
  name            text   not null,
  display_order   int    not null,
  palette_primary text   not null,
  palette_accent  text   not null
);

-- ---------------------------------------------------------------- album_pages
-- Spec secao 11: uma pagina por TEMA (= skin), com um slot por personagem.
-- Personagem novo entra nos slots sozinho, sem tocar nesta tabela.
create table if not exists public.album_pages (
  id          serial primary key,
  slug        text    not null unique,
  title       text    not null,
  page_order  int     not null unique,
  tier_filter text    references public.tiers(slug),
  skin_filter text,
  seal_only   boolean not null default false     -- pagina "Selados"
);

-- ---------------------------------------------------------------- card_types
create table if not exists public.card_types (
  id           serial primary key,
  character_id int  not null references public.characters(id),
  tier         text not null references public.tiers(slug),
  tier_order   smallint not null,
  skin         text not null,
  print_run    int  not null check (print_run > 0),
  art_path     text not null,
  album_page   int  references public.album_pages(id),
  unique (character_id, skin)
);
create index if not exists card_types_character_idx on public.card_types(character_id);
create index if not exists card_types_tier_idx      on public.card_types(tier);

-- ---------------------------------------------------------------- players
create table if not exists public.players (
  id                  uuid primary key references auth.users(id) on delete cascade,
  nickname            extensions.citext not null unique,

  -- allotment inicial (secao 8): 12 comuns, 5 raros, 2 ultra
  packs_common        int not null default 0 check (packs_common       >= 0),
  packs_rare          int not null default 0 check (packs_rare         >= 0),
  packs_ultra         int not null default 0 check (packs_ultra        >= 0),

  -- vindos do diario: slots base saem da reserva (secao 8)
  packs_common_daily  int not null default 0 check (packs_common_daily >= 0),
  packs_rare_daily    int not null default 0 check (packs_rare_daily   >= 0),
  packs_ultra_daily   int not null default 0 check (packs_ultra_daily  >= 0),

  last_daily_at       timestamptz,
  dailies_claimed     int not null default 0 check (dailies_claimed >= 0),
  pity_counter        int not null default 0 check (pity_counter    >= 0),

  baba                int not null default 0 check (baba >= 0),     -- secao 19.1
  is_admin            boolean not null default false,               -- secao 18, ligado na mao

  showcase_1          bigint,
  showcase_2          bigint,
  showcase_3          bigint,
  created_at          timestamptz not null default now()
);

-- ---------------------------------------------------------------- card_copies
create table if not exists public.card_copies (
  id                   bigserial primary key,
  card_type_id         int not null references public.card_types(id),
  serial_number        int not null check (serial_number > 0),

  owner_id             uuid references public.players(id) on delete set null,
  claimed_at           timestamptz,

  seal                 public.seal_type   not null default 'none',
  origin               public.copy_origin not null default 'pull',
  forge_index          int,
  burned               boolean not null default false,
  reserved_for_daily   boolean not null default false,
  damage_level         int not null default 0 check (damage_level between 0 and 3),

  verify_code          text not null unique,      -- secao 14, rota /v/<codigo>

  first_discovered_at  timestamptz,
  first_discovered_by  uuid references public.players(id) on delete set null,

  -- uma copia puxada tem serial unico dentro do tipo; a forjada tem forge_index
  constraint card_copies_serial_unico unique (card_type_id, serial_number),
  constraint card_copies_forge_index_coerente check (
    (origin = 'pull'  and forge_index is null) or
    (origin = 'forge' and forge_index is not null)
  ),
  -- secao 6: forjadas nunca recebem selo
  constraint card_copies_forjada_sem_selo check (origin = 'pull' or seal = 'none')
);

create index if not exists card_copies_owner_idx on public.card_copies(owner_id)
  where owner_id is not null;
-- indice do sorteio: o pool disponivel de um tipo, fora da reserva
create index if not exists card_copies_pool_idx
  on public.card_copies(card_type_id, reserved_for_daily)
  where owner_id is null and not burned;
create index if not exists card_copies_seal_idx on public.card_copies(seal)
  where seal <> 'none';

-- players.showcase_* aponta para card_copies, que so existe agora
do $$ begin
  alter table public.players
    add constraint players_showcase_1_fk foreign key (showcase_1) references public.card_copies(id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.players
    add constraint players_showcase_2_fk foreign key (showcase_2) references public.card_copies(id) on delete set null;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.players
    add constraint players_showcase_3_fk foreign key (showcase_3) references public.card_copies(id) on delete set null;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------- seal_audit
-- Secao 6: o selo passa a ser sorteado de verdade (CSPRNG), entao nao da mais
-- para recalcular a distribuicao depois. A auditoria e esta tabela: registra
-- o que saiu, quando, e um checksum das copias marcadas. A linha aqui tambem
-- e o que torna o sorteio IMUTAVEL - existindo, ninguem re-sorteia.
create table if not exists public.seal_audit (
  character_id int primary key references public.characters(id),
  sealed_at    timestamptz not null default now(),
  branco       int not null,
  preto        int not null,
  rosa         int not null,
  checksum     text not null
);

-- ---------------------------------------------------------------- copy_history
create table if not exists public.copy_history (
  id          bigserial primary key,
  copy_id     bigint not null references public.card_copies(id),
  from_player uuid references public.players(id) on delete set null,
  to_player   uuid references public.players(id) on delete set null,
  kind        text   not null,     -- pull | daily | trade | forge | sell | admin_reset
  created_at  timestamptz not null default now()
);
create index if not exists copy_history_copy_idx on public.copy_history(copy_id);

-- ---------------------------------------------------------------- trades
-- Secao 19.6: cada lado oferece uma copia OU baba, nunca os dois, nunca nenhum.
create table if not exists public.trades (
  id                bigserial primary key,
  from_player       uuid not null references public.players(id) on delete cascade,
  to_player         uuid not null references public.players(id) on delete cascade,
  offered_copy_id   bigint references public.card_copies(id),
  offered_baba      int not null default 0 check (offered_baba   >= 0),
  requested_copy_id bigint references public.card_copies(id),
  requested_baba    int not null default 0 check (requested_baba >= 0),
  status            public.trade_status not null default 'pending',
  created_at        timestamptz not null default now(),
  resolved_at       timestamptz,

  constraint trades_sem_auto_troca check (from_player <> to_player),
  constraint trades_lado_oferecido check (
    (offered_copy_id is not null and offered_baba = 0) or
    (offered_copy_id is null     and offered_baba > 0)
  ),
  constraint trades_lado_pedido check (
    (requested_copy_id is not null and requested_baba = 0) or
    (requested_copy_id is null     and requested_baba > 0)
  ),
  -- baba por baba e proibido
  constraint trades_nao_baba_por_baba check (
    offered_copy_id is not null or requested_copy_id is not null
  )
);
create index if not exists trades_pending_idx on public.trades(status)
  where status = 'pending';
create index if not exists trades_from_idx on public.trades(from_player);
create index if not exists trades_to_idx   on public.trades(to_player);

-- ---------------------------------------------------------------- pack_config
-- Secao 8: odds editaveis sem deploy. Cada (pack_type, slot) soma 100.
create table if not exists public.pack_config (
  pack_type public.pack_type not null,
  slot      public.pack_slot not null,
  tier      text    not null references public.tiers(slug),
  weight    numeric not null check (weight >= 0),
  primary key (pack_type, slot, tier)
);

create table if not exists public.pack_params (
  chave     text primary key,
  valor     numeric not null,
  descricao text not null
);

-- ---------------------------------------------------------------- economy_config
create table if not exists public.economy_config (
  chave     text primary key,
  valor     numeric not null,
  descricao text not null
);

-- ---------------------------------------------------------------- baba_log
create table if not exists public.baba_log (
  id         bigserial primary key,
  player_id  uuid not null references public.players(id) on delete cascade,
  delta      int  not null,
  motivo     text not null,
  ref_id     text,
  created_at timestamptz not null default now()
);
create index if not exists baba_log_player_idx on public.baba_log(player_id, created_at desc);

-- ---------------------------------------------------------------- admin_log
create table if not exists public.admin_log (
  id         bigserial primary key,
  admin_id   uuid not null references public.players(id),
  acao       text not null,
  alvo       text,
  payload    jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- auditoria do sorteio
create table if not exists public.pack_openings (
  id             bigserial primary key,
  player_id      uuid not null references public.players(id) on delete cascade,
  pack_type      public.pack_type not null,
  from_daily     boolean not null default false,
  promoted_slots int     not null default 0,
  hot            boolean not null default false,
  pity           boolean not null default false,
  bonus          boolean not null default false,
  created_at     timestamptz not null default now()
);

create table if not exists public.pack_opening_cards (
  id             bigserial primary key,
  opening_id     bigint not null references public.pack_openings(id) on delete cascade,
  copy_id        bigint not null references public.card_copies(id),
  slot_index     int  not null,
  reveal_index   int  not null,
  tier           text not null references public.tiers(slug),
  from_hit_table boolean not null
);

-- ---------------------------------------------------------------- recompensas travadas
-- Secao 19.3: pagam uma vez e nunca mais. Sao a trava anti-impressora.
create table if not exists public.album_page_rewards (
  player_id     uuid not null references public.players(id) on delete cascade,
  album_page_id int  not null references public.album_pages(id),
  granted_at    timestamptz not null default now(),
  primary key (player_id, album_page_id)
);

create table if not exists public.trade_rewards (
  player_a      uuid not null references public.players(id) on delete cascade,
  player_b      uuid not null references public.players(id) on delete cascade,
  card_type_id  int  not null references public.card_types(id),
  granted_at    timestamptz not null default now(),
  primary key (player_a, player_b, card_type_id),
  constraint trade_rewards_par_ordenado check (player_a < player_b)
);

-- ================================================================ helpers
-- Secao 8, "Aleatoriedade": random() do Postgres e um PRNG de sessao e o
-- cliente pode fixa-lo com setseed(). Nenhuma RPC pode usa-lo.
create or replace function private.random_int(n int)
returns int
language plpgsql
volatile
set search_path = public, extensions, pg_temp
as $$
declare
  limite bigint;
  bruto  bigint;
begin
  if n is null or n <= 0 then
    raise exception 'random_int: n precisa ser positivo, veio %', n;
  end if;
  if n = 1 then
    return 0;
  end if;

  -- amostragem por rejeicao: descarta o rabo que nao cabe num multiplo
  -- exato de n, senao o modulo enviesa os indices baixos.
  limite := (4294967296::bigint / n) * n;
  loop
    bruto := ('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    exit when bruto < limite;
  end loop;
  return (bruto % n)::int;
end;
$$;

-- Secao 18: a guarda administrativa. Nao existe admin_key.
create or replace function private.require_admin()
returns void
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if not exists (
    select 1 from public.players
    where id = auth.uid() and is_admin
  ) then
    raise exception 'nao autorizado' using errcode = '42501';
  end if;
end;
$$;

-- Secao 6: sorteio dos selos, 12 branco / 4 preto / 1 rosa por personagem.
--
-- Aleatoriedade de verdade, da mesma fonte do sorteio de pacote:
-- gen_random_bytes, o CSPRNG que private.random_int() embrulha. Nunca
-- random(), e nunca mais um hash do serial.
--
-- A versao anterior ordenava por md5(semente || personagem || skin || serial).
-- Era uniforme, mas a migracao mora no repositorio: qualquer jogador que
-- lesse o arquivo calculava a lista inteira de selados antes do lancamento e
-- sabia exatamente quais seriais cacar. Isso mata a graca do selo.
--
-- Imutabilidade e auditoria continuam de pe, mas por seal_audit em vez de por
-- reprodutibilidade: existindo a linha de auditoria, a funcao sai sem tocar
-- em nada. Rodar o seed de novo nunca re-sorteia.
create or replace function private.distribuir_selos(p_character_id int)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  n_total int;
begin
  if exists (select 1 from public.seal_audit where character_id = p_character_id) then
    return;   -- ja sorteado, e selo nao se re-sorteia
  end if;

  select count(*) into n_total
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = p_character_id and cc.origin = 'pull';

  if n_total < 17 then
    raise exception 'personagem % tem so % copias, nao da para 12/4/1', p_character_id, n_total;
  end if;

  -- Uniforme sobre TODAS as copias do personagem, sem excluir tier nenhum -
  -- inclusive a Prisma 1/1. Tiragem alta domina porque ha mais copias dela;
  -- isso e a logica pedida, nao efeito colateral.
  with sorteadas as (
    select cc.id,
           row_number() over (order by gen_random_bytes(8)) as rn
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    where ct.character_id = p_character_id
      and cc.origin = 'pull'
      and cc.seal = 'none'
  )
  update public.card_copies cc
  set seal = case
               when s.rn <= 12 then 'branco'::public.seal_type
               when s.rn <= 16 then 'preto'::public.seal_type
               else                 'rosa'::public.seal_type
             end
  from sorteadas s
  where cc.id = s.id and s.rn <= 17;

  insert into public.seal_audit (character_id, branco, preto, rosa, checksum)
  select p_character_id,
         count(*) filter (where cc.seal = 'branco'),
         count(*) filter (where cc.seal = 'preto'),
         count(*) filter (where cc.seal = 'rosa'),
         md5(string_agg(cc.verify_code || ':' || cc.seal::text, '|' order by cc.verify_code))
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = p_character_id and cc.seal <> 'none';
end;
$fn$;

-- Secao 8: reserva do diario, tambem por CSPRNG. Completa ate o alvo por
-- personagem, entao rodar de novo nao rouba copia que ja tem dono.
create or replace function private.reservar_diario(p_character_id int, p_alvo int)
returns int
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  ja_tem int;
  faltam int;
begin
  select count(*) into ja_tem
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = p_character_id and cc.reserved_for_daily and not cc.burned;

  faltam := p_alvo - ja_tem;
  if faltam <= 0 then return 0; end if;

  with candidatas as (
    select cc.id
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.tiers t on t.slug = ct.tier
    where ct.character_id = p_character_id
      and t.slug in ('comum','incomum')
      and cc.owner_id is null
      and not cc.burned
      and not cc.reserved_for_daily
    order by gen_random_bytes(8)
    limit faltam
  )
  update public.card_copies cc
  set reserved_for_daily = true
  from candidatas c where cc.id = c.id;

  return faltam;
end;
$fn$;

-- Mesma guarda, em forma de boolean, para usar DENTRO de policy.
--
-- Precisa ser security definer: uma policy e avaliada com os privilegios de
-- quem consulta, e authenticated nao tem SELECT em players. Escrever o
-- "exists (select 1 from players ...)" direto na policy negava ate para admin
-- de verdade - o erro saia como "permission denied for table players".
create or replace function public.sou_admin()
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (select 1 from public.players where id = auth.uid() and is_admin);
$$;

-- Secao 9: o proprio jogador precisa ler baba, pacotes e pity, que nao sao
-- publicos. A leitura da linha inteira passa por aqui, nunca por GRANT.
-- O drop antes do create nao e enfeite: uma migracao posterior troca o tipo
-- de retorno para jsonb (o inventario passou a vir junto), e sem isto
-- reaplicar a cadeia inteira estoura com "cannot change return type".
drop function if exists public.me();
create or replace function public.me()
returns public.players
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select * from public.players where id = auth.uid();
$$;

-- Secao 9: o recorte publico de players. Existir esta view e o que permite
-- REVOGAR o SELECT na tabela inteira - sem ela o cliente teria que nomear
-- coluna por coluna, e um select('*') distraido tomaria permission denied.
-- Sem security_invoker de proposito: a view roda com os direitos do dono, e e
-- ela, nao a RLS, que faz o recorte.
create or replace view public.players_public as
  select id, nickname, showcase_1, showcase_2, showcase_3, is_admin, created_at
  from public.players;

-- Explicito para nao virar acidente: me() e a view so enxergam a tabela
-- porque rodam como o dono. Trocar o dono para um papel comum quebra as duas.
alter function public.me() owner to postgres;
alter function public.sou_admin() owner to postgres;
alter view public.players_public owner to postgres;


-- ===== 20260821120100_seed.sql =====
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


-- ===== 20260821120200_rls.sql =====
-- BELESMA figurinhas - Fase 1: RLS e permissoes (spec secao 9)
--
-- Modelo: nega tudo, libera SELECT ponto a ponto. Nenhuma escrita direta
-- existe para anon nem para authenticated, em nenhuma tabela. Toda mutacao
-- passa por RPC security definer.
--
-- O Supabase concede privilegios por default no schema public a anon e
-- authenticated. Por isso o REVOKE abaixo nao e decorativo: sem ele, a RLS
-- ficaria por cima de GRANTs abertos.

-- service_role e o papel de servidor de confianca: bypassa RLS e precisa de
-- GRANT explicito. O Supabase concede por default, mas essa configuracao vive
-- presa ao schema - se alguem recriar o schema public, ela some junto e o
-- painel e os scripts administrativos param de enxergar as tabelas.
-- Conceder aqui torna a migracao autossuficiente.
-- A chave de service_role NUNCA vai para o navegador.
grant usage on schema public to postgres, anon, authenticated, service_role;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- o schema private nao existe para o cliente
revoke all on schema private from anon, authenticated;

-- ---------------------------------------------------------------- RLS ligada
alter table public.tiers               enable row level security;
alter table public.characters          enable row level security;
alter table public.album_pages         enable row level security;
alter table public.card_types          enable row level security;
alter table public.card_copies         enable row level security;
alter table public.players             enable row level security;
alter table public.copy_history        enable row level security;
alter table public.trades              enable row level security;
alter table public.pack_config         enable row level security;
alter table public.pack_params         enable row level security;
alter table public.economy_config      enable row level security;
alter table public.baba_log            enable row level security;
alter table public.admin_log           enable row level security;
alter table public.pack_openings       enable row level security;
alter table public.pack_opening_cards  enable row level security;
alter table public.album_page_rewards  enable row level security;
alter table public.trade_rewards       enable row level security;
alter table public.seal_audit         enable row level security;

-- force: nem o dono da tabela escapa da politica em consulta normal.
-- As RPCs security definer continuam funcionando porque rodam como owner
-- com bypassrls no papel de servico.
alter table public.card_copies        force row level security;
alter table public.players            force row level security;
alter table public.admin_log          force row level security;

-- ================================================================ catalogo
-- Publico. O indice global e publico e a rota /v/<codigo> nao pede auth.
drop policy if exists tiers_leitura on public.tiers;
create policy tiers_leitura        on public.tiers          for select to anon, authenticated using (true);
drop policy if exists characters_leitura on public.characters;
create policy characters_leitura   on public.characters     for select to anon, authenticated using (true);
drop policy if exists album_pages_leitura on public.album_pages;
create policy album_pages_leitura  on public.album_pages    for select to anon, authenticated using (true);
drop policy if exists card_types_leitura on public.card_types;
create policy card_types_leitura   on public.card_types     for select to anon, authenticated using (true);
drop policy if exists pack_config_leitura on public.pack_config;
create policy pack_config_leitura  on public.pack_config    for select to anon, authenticated using (true);
drop policy if exists pack_params_leitura on public.pack_params;
create policy pack_params_leitura  on public.pack_params    for select to anon, authenticated using (true);
drop policy if exists economy_leitura on public.economy_config;
create policy economy_leitura      on public.economy_config for select to anon, authenticated using (true);

drop policy if exists seal_audit_leitura on public.seal_audit;
create policy seal_audit_leitura on public.seal_audit
  for select to anon, authenticated using (true);

grant select on public.tiers, public.characters, public.album_pages,
               public.card_types, public.pack_config, public.pack_params,
               public.economy_config, public.seal_audit
  to anon, authenticated;

-- ================================================================ card_copies
-- SELECT liberado (secao 9). Nenhuma politica de INSERT, UPDATE ou DELETE
-- existe - e a ausencia dela que nega, nao uma regra explicita.
drop policy if exists card_copies_leitura on public.card_copies;
create policy card_copies_leitura on public.card_copies
  for select to anon, authenticated using (true);

grant select on public.card_copies to anon, authenticated;

-- historico de donos aparece na figurinha aberta (secao 11)
drop policy if exists copy_history_leitura on public.copy_history;
create policy copy_history_leitura on public.copy_history
  for select to anon, authenticated using (true);

grant select on public.copy_history to anon, authenticated;

-- ================================================================ players
-- Secao 9: SELECT so de nickname, id, vitrine e is_admin.
--
-- RLS nao filtra COLUNA, so linha. A primeira versao resolvia com GRANT por
-- coluna, o que funcionava mas deixava uma armadilha: qualquer
-- select('*') em players tomaria permission denied, e o erro nao explica o
-- porque. Agora a tabela nao tem SELECT nenhum para o cliente, e o recorte
-- publico e a view players_public. Um select('*') NA VIEW e seguro.
--
-- O proprio jogador le a linha inteira - baba, pacotes, pity - por me().
grant select on public.players_public to anon, authenticated;
grant execute on function public.me() to authenticated;

-- ================================================================ trades
drop policy if exists trades_leitura on public.trades;
create policy trades_leitura on public.trades
  for select to authenticated
  using (auth.uid() = from_player or auth.uid() = to_player);

grant select on public.trades to authenticated;

-- ================================================================ baba_log
drop policy if exists baba_log_leitura on public.baba_log;
create policy baba_log_leitura on public.baba_log
  for select to authenticated
  using (auth.uid() = player_id);

grant select on public.baba_log to authenticated;

-- ================================================================ admin_log
-- Secao 18.3: somente leitura, e so para admin. Sem UPDATE e sem DELETE
-- para papel nenhum - nem admin apaga o proprio rastro.
drop policy if exists admin_log_leitura on public.admin_log;
create policy admin_log_leitura on public.admin_log
  for select to authenticated
  using (public.sou_admin());

grant select on public.admin_log to authenticated;
grant execute on function public.sou_admin() to authenticated;

-- ================================================================ auditoria de pacote
drop policy if exists pack_openings_leitura on public.pack_openings;
create policy pack_openings_leitura on public.pack_openings
  for select to authenticated
  using (auth.uid() = player_id);

drop policy if exists pack_opening_cards_leitura on public.pack_opening_cards;
create policy pack_opening_cards_leitura on public.pack_opening_cards
  for select to authenticated
  using (exists (
    select 1 from public.pack_openings o
    where o.id = pack_opening_cards.opening_id and o.player_id = auth.uid()
  ));

grant select on public.pack_openings, public.pack_opening_cards to authenticated;

-- ================================================================ recompensas
drop policy if exists album_page_rewards_leitura on public.album_page_rewards;
create policy album_page_rewards_leitura on public.album_page_rewards
  for select to authenticated
  using (auth.uid() = player_id);

grant select on public.album_page_rewards to authenticated;

-- trade_rewards e trava interna: ninguem le, ninguem escreve, so as RPCs.
-- Sem policy e sem grant de proposito.

-- ================================================================ service_role
-- Depois de todos os REVOKE acima, devolve tudo ao papel de servidor.
grant all on all tables     in schema public to service_role;
grant all on all sequences  in schema public to service_role;
grant all on all functions  in schema public to service_role;
grant usage on schema private to service_role;
grant all on all functions in schema private to service_role;

alter default privileges in schema public grant all on tables    to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant all on functions to service_role;


-- ===== 20260822100000_rpc_jogador.sql =====
-- BELESMA figurinhas - Fase 2: RPCs de jogador (spec secoes 8, 9, 10)
--
-- Regra que este arquivo obedece acima de tudo: o cliente nunca sorteia e
-- nunca escreve. Tudo aqui e security definer e atomico.

-- ================================================================ helpers
-- Peso -> escolha, com UM unico sorteio contra a soma cumulativa (secao 8).
-- Nao e uma sequencia de moedas tier a tier: aquilo distorce a tabela.
create or replace function private.escolher_ponderado(pesos numeric[])
returns int
language plpgsql
volatile
set search_path = public, extensions, pg_temp
as $$
declare
  total numeric := 0;
  ponto numeric;
  acumulado numeric := 0;
  i int;
begin
  foreach ponto in array pesos loop total := total + ponto; end loop;
  if total <= 0 then return null; end if;

  -- random_int da inteiro; multiplicamos por 1e6 para ter resolucao decimal
  ponto := (private.random_int(1000000)::numeric / 1000000) * total;

  for i in 1 .. array_length(pesos, 1) loop
    acumulado := acumulado + pesos[i];
    if ponto < acumulado then return i; end if;
  end loop;
  return array_length(pesos, 1);
end;
$$;

-- ================================================================ login
-- Secao 10: apelido + senha, e-mail sintetico interno. O cadastro no Auth
-- acontece no cliente (supabase.auth.signUp); esta RPC cria a linha de
-- players e entrega o allotment inicial.
create or replace function public.nickname_disponivel(p_nickname text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select not exists (
    select 1 from public.players where nickname = p_nickname::extensions.citext
  );
$$;

create or replace function public.claim_nickname(p_nickname text)
returns public.players
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_row   public.players;
begin
  if v_uid is null then
    raise exception 'precisa estar logado' using errcode = '42501';
  end if;

  -- Idempotente: chamar de novo devolve a linha, nao duplica allotment.
  select * into v_row from public.players where id = v_uid;
  if found then return v_row; end if;

  if p_nickname !~ '^[a-z0-9][a-z0-9_-]{2,19}$' then
    raise exception 'apelido invalido: 3 a 20 caracteres, minusculas, numeros, - e _';
  end if;

  -- O apelido tem que bater com o e-mail sintetico do proprio JWT, senao
  -- daria para cadastrar como "fulano" e reivindicar o apelido "beltrano".
  select email into v_email from auth.users where id = v_uid;
  if lower(split_part(v_email, '@', 1)) <> lower(p_nickname) then
    raise exception 'apelido nao confere com a conta';
  end if;

  insert into public.players (id, nickname, packs_common, packs_rare, packs_ultra)
  values (
    v_uid,
    p_nickname::extensions.citext,
    (select valor from public.pack_params where chave = 'allotment_comum')::int,
    (select valor from public.pack_params where chave = 'allotment_raro')::int,
    (select valor from public.pack_params where chave = 'allotment_ultra')::int
  )
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'esse apelido ja existe';
end;
$$;

-- A coluna vive na sua propria migracao (20260822140000), mas open_pack
-- referencia ela. Como as migracoes rodam por ordem de nome e esta e mais
-- antiga, garante aqui tambem. Idempotente nos dois caminhos.
alter table public.pack_opening_cards
  add column if not exists garantido boolean not null default false;

-- ================================================================ open_pack
-- Secao 8 inteira: 3 base + 1 hit, promocao, pacote quente, carta bonus,
-- pity, regras duras, cascata de esgotamento e ordem embaralhada.
--
-- Atomica: se qualquer coisa falhar, nada foi distribuido. As cartas ficam
-- gravadas ANTES de qualquer animacao - fechar a aba no meio nao perde nada.
create or replace function public.open_pack(pack_type text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid        uuid := auth.uid();
  v_jogador    public.players;
  v_tipo       public.pack_type := pack_type::public.pack_type;
  v_do_diario  boolean := false;

  v_quente     boolean := false;
  v_bonus      boolean := false;
  v_pity       boolean := false;
  v_promovidos int := 0;

  v_n_base     int;
  v_pity_lim   int;
  v_slots      int;
  v_i          int;
  v_tent       int;

  v_da_tabela  boolean;
  v_garantido  boolean;
  v_tier       text;
  v_type_id    int;
  v_copy_id    bigint;
  v_reserva    boolean;

  v_tiers      text[];
  v_pesos      numeric[];
  v_idx        int;
  v_piso       smallint;

  v_usados     int[] := '{}';
  v_copias     bigint[] := '{}';
  v_tiers_saiu text[] := '{}';
  v_do_hit     boolean[] := '{}';
  v_garantidos boolean[] := '{}';

  v_abertura   bigint;
  v_ordem      int[];
  v_tmp        int;
  v_j          int;
  v_resultado  jsonb;
begin
  if v_uid is null then
    raise exception 'precisa estar logado' using errcode = '42501';
  end if;

  -- Trava o jogador: duas abas do mesmo dono nao gastam o mesmo pacote.
  select * into v_jogador from public.players where id = v_uid for update;
  if not found then
    raise exception 'jogador nao encontrado' using errcode = '42501';
  end if;

  -- Gasta primeiro os pacotes do diario (secao 8). Sao eles que puxam os
  -- slots base de dentro da reserva.
  if v_tipo = 'comum' then
    if v_jogador.packs_common_daily > 0 then
      v_do_diario := true;
      update public.players set packs_common_daily = packs_common_daily - 1 where id = v_uid;
    elsif v_jogador.packs_common > 0 then
      update public.players set packs_common = packs_common - 1 where id = v_uid;
    else raise exception 'sem pacote comum'; end if;
  elsif v_tipo = 'raro' then
    if v_jogador.packs_rare_daily > 0 then
      v_do_diario := true;
      update public.players set packs_rare_daily = packs_rare_daily - 1 where id = v_uid;
    elsif v_jogador.packs_rare > 0 then
      update public.players set packs_rare = packs_rare - 1 where id = v_uid;
    else raise exception 'sem pacote raro'; end if;
  else
    if v_jogador.packs_ultra_daily > 0 then
      v_do_diario := true;
      update public.players set packs_ultra_daily = packs_ultra_daily - 1 where id = v_uid;
    elsif v_jogador.packs_ultra > 0 then
      update public.players set packs_ultra = packs_ultra - 1 where id = v_uid;
    else raise exception 'sem pacote ultra'; end if;
  end if;

  v_n_base   := (select valor from public.pack_params where chave = 'cartas_base')::int;
  v_pity_lim := (select valor from public.pack_params where chave = 'pity_limite')::int;

  v_quente := private.random_int(100000) <
              (select valor from public.pack_params where chave = 'pacote_quente')::numeric * 100000;
  v_bonus  := private.random_int(100000) <
              (select valor from public.pack_params where chave = 'carta_bonus')::numeric * 100000;
  v_pity   := v_tipo = 'comum' and v_jogador.pity_counter >= v_pity_lim;

  -- slots: base + 1 hit (+1 se veio bonus). O hit e sempre o ultimo.
  v_slots := v_n_base + 1 + (case when v_bonus then 1 else 0 end);

  for v_i in 1 .. v_slots loop
    -- o slot de hit e o de indice v_n_base + 1; bonus entra como base extra
    v_da_tabela := (v_i = v_n_base + 1);
    v_garantido := false;

    if v_quente then
      v_da_tabela := true;
      v_garantido := true;                        -- pacote quente e slot garantido
    elsif not v_da_tabela then
      if private.random_int(100000) <
         (select valor from public.pack_params where chave = 'promocao_base')::numeric * 100000 then
        v_da_tabela := true;
        v_garantido := true;                      -- promocao tambem e garantido
        v_promovidos := v_promovidos + 1;
      end if;
    elsif v_pity then
      v_garantido := true;                        -- pity idem
    end if;

    -- ---------------------------------------------------------- escolhe tier
    v_piso := case
                when v_pity and v_da_tabela then
                  (select tier_order from public.tiers where slug = 'epica')
                else 0 end;

    -- Pesos so dos tiers COM ESTOQUE, renormalizados antes do sorteio
    -- (secao 8). E isso que preserva a garantia do pacote: se mitica zerar,
    -- o Ultra redistribui entre cosmica+ em vez de cair para lendaria.
    select array_agg(x.tier order by x.tier_order), array_agg(x.weight order by x.tier_order)
      into v_tiers, v_pesos
    from (
      select pc.tier, t.tier_order, pc.weight
      from public.pack_config pc
      join public.tiers t on t.slug = pc.tier
      where pc.pack_type = v_tipo
        and pc.slot = (case when v_da_tabela then 'hit' else 'base' end)::public.pack_slot
        and pc.weight > 0
        and t.tier_order >= v_piso
        -- regra dura: diamante e prisma nunca em slot garantido
        and not (v_garantido and t.slug in ('diamante','prisma'))
        and exists (
          select 1 from public.card_copies cc
          join public.card_types ct on ct.id = cc.card_type_id
          where ct.tier = pc.tier and cc.owner_id is null and not cc.burned
            and cc.reserved_for_daily = (v_do_diario and not v_da_tabela)
        )
    ) x;

    -- Cascata: nada no nivel tem estoque. Desce um degrau e tenta de novo.
    if v_tiers is null then
      select array_agg(t.slug order by t.tier_order), array_agg(1::numeric)
        into v_tiers, v_pesos
      from public.tiers t
      where t.slug not in ('diamante','prisma')
        and exists (
          select 1 from public.card_copies cc
          join public.card_types ct on ct.id = cc.card_type_id
          where ct.tier = t.slug and cc.owner_id is null and not cc.burned
            and cc.reserved_for_daily = (v_do_diario and not v_da_tabela)
        );
    end if;

    -- Sem estoque em lugar nenhum: o pacote sai menor, e o front avisa.
    exit when v_tiers is null;

    v_idx  := private.escolher_ponderado(v_pesos);
    v_tier := v_tiers[v_idx];
    v_reserva := (v_do_diario and not v_da_tabela);

    -- -------------------------------------------------- escolhe skin no tier
    -- Peso proporcional ao ESTOQUE RESTANTE: drena os tipos do tier juntos
    -- em vez de esgotar uma skin muito antes das outras (secao 8).
    -- Tipos ja sorteados neste pacote saem do sorteio.
    v_type_id := null;
    select x.id into v_type_id
    from (
      select ct.id,
             sum(count(*)) over () as total,
             count(*) as estoque,
             sum(count(*)) over (order by ct.id rows between unbounded preceding and current row) as ate_aqui
      from public.card_types ct
      join public.card_copies cc on cc.card_type_id = ct.id
      where ct.tier = v_tier and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
        and not (ct.id = any(v_usados))
      group by ct.id
    ) x
    where x.ate_aqui > (private.random_int(1000000)::numeric / 1000000) * x.total
    order by x.ate_aqui
    limit 1;

    -- so sobrou tipo repetido: aceita a repeticao em vez de entregar menos
    if v_type_id is null then
      select ct.id into v_type_id
      from public.card_types ct
      join public.card_copies cc on cc.card_type_id = ct.id
      where ct.tier = v_tier and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
      group by ct.id
      order by extensions.gen_random_bytes(8)
      limit 1;
    end if;
    continue when v_type_id is null;

    -- ------------------------------------------------- escolhe a copia
    -- Serial ALEATORIO, nunca em ordem: em ordem a cacada de serial da
    -- secao 11 vira "quem abriu primeiro" em vez de sorte.
    v_copy_id := null;
    for v_tent in 1 .. 5 loop
      select cc.id into v_copy_id
      from public.card_copies cc
      where cc.card_type_id = v_type_id
        and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
      order by extensions.gen_random_bytes(8)
      limit 1
      for update skip locked;
      exit when v_copy_id is not null;
    end loop;
    continue when v_copy_id is null;

    update public.card_copies
    set owner_id = v_uid,
        claimed_at = now(),
        first_discovered_at = coalesce(first_discovered_at, now()),
        first_discovered_by = coalesce(first_discovered_by, v_uid)
    where id = v_copy_id;

    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (v_copy_id, null, v_uid, case when v_do_diario then 'daily' else 'pull' end);

    v_usados     := v_usados     || v_type_id;
    v_copias     := v_copias     || v_copy_id;
    v_tiers_saiu := v_tiers_saiu || v_tier;
    v_do_hit     := v_do_hit     || v_da_tabela;
    v_garantidos := v_garantidos || v_garantido;
  end loop;

  if array_length(v_copias, 1) is null then
    raise exception 'sem estoque: nao foi possivel montar o pacote';
  end if;

  -- ---------------------------------------------------------------- pity
  if v_tipo = 'comum' then
    if v_pity or exists (
      select 1 from unnest(v_tiers_saiu) s
      join public.tiers t on t.slug = s
      where t.tier_order > (select tier_order from public.tiers where slug = 'rara')
    ) then
      update public.players set pity_counter = 0 where id = v_uid;
    else
      update public.players set pity_counter = pity_counter + 1 where id = v_uid;
    end if;
  end if;

  -- ------------------------------------------------------- ordem de revelacao
  -- Fisher-Yates no servidor. O hit pode ser a 1a, 2a, 3a ou 4a.
  v_ordem := array(select generate_series(1, array_length(v_copias, 1)));
  for v_i in reverse array_length(v_ordem, 1) .. 2 loop
    v_j := private.random_int(v_i) + 1;
    v_tmp := v_ordem[v_i]; v_ordem[v_i] := v_ordem[v_j]; v_ordem[v_j] := v_tmp;
  end loop;

  -- ---------------------------------------------------------------- auditoria
  insert into public.pack_openings (player_id, pack_type, from_daily, promoted_slots, hot, pity, bonus)
  values (v_uid, v_tipo, v_do_diario, v_promovidos, v_quente, v_pity, v_bonus)
  returning id into v_abertura;

  for v_i in 1 .. array_length(v_copias, 1) loop
    insert into public.pack_opening_cards
      (opening_id, copy_id, slot_index, reveal_index, tier, from_hit_table, garantido)
    values
      (v_abertura, v_copias[v_i], v_i, array_position(v_ordem, v_i),
       v_tiers_saiu[v_i], v_do_hit[v_i], v_garantidos[v_i]);
  end loop;

  -- ---------------------------------------------------------------- resposta
  select jsonb_build_object(
    'abertura', v_abertura,
    'pack_type', v_tipo,
    'do_diario', v_do_diario,
    'quente', v_quente,
    'bonus', v_bonus,
    'pity', v_pity,
    'promovidos', v_promovidos,
    'esperado', v_slots,
    'cartas', coalesce(jsonb_agg(c order by c->>'reveal_index'), '[]'::jsonb)
  ) into v_resultado
  from (
    select jsonb_build_object(
      'copy_id', cc.id,
      'card_type_id', cc.card_type_id,
      'reveal_index', poc.reveal_index,
      'from_hit_table', poc.from_hit_table,
      'garantido', poc.garantido,
      'serial_number', cc.serial_number,
      'print_run', ct.print_run,
      'seal', cc.seal,
      'origin', cc.origin,
      'damage_level', cc.damage_level,
      'verify_code', cc.verify_code,
      'tier', ct.tier,
      'tier_order', ct.tier_order,
      'skin', ct.skin,
      'art_path', ct.art_path,
      'character_slug', ch.slug,
      'character_name', ch.name,
      'estreia_mundial', cc.first_discovered_by = v_uid and cc.first_discovered_at >= now() - interval '1 minute',
      'nova', not exists (
        select 1 from public.card_copies o
        where o.card_type_id = cc.card_type_id and o.owner_id = v_uid and o.id <> cc.id
      )
    ) as c
    from public.pack_opening_cards poc
    join public.card_copies cc on cc.id = poc.copy_id
    join public.card_types  ct on ct.id = cc.card_type_id
    join public.characters  ch on ch.id = ct.character_id
    where poc.opening_id = v_abertura
  ) t;

  return v_resultado;
end;
$$;

-- ================================================================ permissoes
revoke all on function public.open_pack(text)          from public, anon;
revoke all on function public.claim_nickname(text)     from public, anon;
revoke all on function public.nickname_disponivel(text) from public;

grant execute on function public.open_pack(text)           to authenticated;
grant execute on function public.claim_nickname(text)      to authenticated;
grant execute on function public.nickname_disponivel(text) to anon, authenticated;

alter function public.open_pack(text)           owner to postgres;
alter function public.claim_nickname(text)      owner to postgres;
alter function public.nickname_disponivel(text) owner to postgres;


-- ===== 20260822100100_rpc_admin.sql =====
-- BELESMA figurinhas - Fase 2: RPCs administrativas (spec secao 18)
--
-- NAO existe admin_key. Toda funcao aqui comeca com private.require_admin(),
-- que checa auth.uid() contra players.is_admin dentro do banco.
--
-- Elas sao CHAMAVEIS por authenticated de proposito: o erro precisa ser
-- "nao autorizado", nao "function does not exist", para o teste de fraude da
-- secao 17 ser conclusivo.

create or replace function private.registrar(p_acao text, p_alvo text, p_payload jsonb)
returns void
language sql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
  insert into public.admin_log (admin_id, acao, alvo, payload)
  values (auth.uid(), p_acao, p_alvo, p_payload);
$$;

-- ================================================================ jogadores
create or replace function public.admin_jogadores()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'nickname', p.nickname, 'created_at', p.created_at,
      'is_admin', p.is_admin, 'baba', p.baba,
      'copias', (select count(*) from public.card_copies cc where cc.owner_id = p.id),
      'pacotes', jsonb_build_object(
        'comum', p.packs_common, 'raro', p.packs_rare, 'ultra', p.packs_ultra,
        'comum_diario', p.packs_common_daily, 'raro_diario', p.packs_rare_daily,
        'ultra_diario', p.packs_ultra_daily),
      'last_daily_at', p.last_daily_at, 'pity_counter', p.pity_counter
    ) order by p.created_at)
    from public.players p), '[]'::jsonb);
end;
$$;

create or replace function public.grant_packs(p_target text, p_pack_type text, p_quantidade int)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_n int; v_tipo public.pack_type := p_pack_type::public.pack_type;
begin
  perform private.require_admin();
  if p_quantidade is null or p_quantidade = 0 then raise exception 'quantidade invalida'; end if;

  update public.players p
  set packs_common = p.packs_common + (case when v_tipo = 'comum' then p_quantidade else 0 end),
      packs_rare   = p.packs_rare   + (case when v_tipo = 'raro'  then p_quantidade else 0 end),
      packs_ultra  = p.packs_ultra  + (case when v_tipo = 'ultra' then p_quantidade else 0 end)
  where p_target = 'todos' or p.nickname = p_target::extensions.citext;
  get diagnostics v_n = row_count;

  perform private.registrar('grant_packs', p_target,
    jsonb_build_object('pack_type', p_pack_type, 'quantidade', p_quantidade, 'jogadores', v_n));
  return v_n;
end;
$$;

create or replace function public.admin_reset_password(p_nickname text, p_nova_senha text)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id uuid;
begin
  perform private.require_admin();
  if length(coalesce(p_nova_senha, '')) < 6 then raise exception 'senha minima de 6 caracteres'; end if;

  select id into v_id from public.players where nickname = p_nickname::extensions.citext;
  if v_id is null then raise exception 'jogador nao encontrado'; end if;

  -- Secao 10: nao existe recuperacao automatica; o reset e manual e passa
  -- por aqui. A senha nunca e gravada no admin_log.
  update auth.users
  set encrypted_password = extensions.crypt(p_nova_senha, extensions.gen_salt('bf')),
      updated_at = now()
  where id = v_id;

  perform private.registrar('admin_reset_password', p_nickname, jsonb_build_object('senha', 'omitida'));
end;
$$;

create or replace function public.admin_reset_daily_cooldown(p_nickname text)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  update public.players set last_daily_at = null where nickname = p_nickname::extensions.citext;
  if not found then raise exception 'jogador nao encontrado'; end if;
  perform private.registrar('admin_reset_daily_cooldown', p_nickname, '{}'::jsonb);
end;
$$;

-- ================================================================ odds e precos
-- Uma migracao posterior troca o retorno para void (a funcao passou a so
-- recusar: pack_config nao alimenta mais o sorteio). Sem o drop, reaplicar a
-- cadeia inteira estoura com "cannot change return type".
drop function if exists public.admin_set_pack_config(jsonb);
create or replace function public.admin_set_pack_config(p_rows jsonb)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_antes jsonb; v_n int; v_erro text;
begin
  perform private.require_admin();

  select jsonb_agg(to_jsonb(pc)) into v_antes from public.pack_config pc;

  update public.pack_config pc
  set weight = (r->>'weight')::numeric
  from jsonb_array_elements(p_rows) r
  where pc.pack_type = (r->>'pack_type')::public.pack_type
    and pc.slot      = (r->>'slot')::public.pack_slot
    and pc.tier      = r->>'tier';
  get diagnostics v_n = row_count;

  -- Secao 18.1: cada tipo de pacote soma 100%. Nao salva torto.
  select string_agg(x.pack_type || '/' || x.slot || ' = ' || x.total, ', ')
    into v_erro
  from (select pack_type::text, slot::text, sum(weight) as total
        from public.pack_config group by pack_type, slot) x
  where x.total <> 100;

  if v_erro is not null then
    raise exception 'as odds precisam somar 100: %', v_erro;
  end if;

  perform private.registrar('admin_set_pack_config', null,
    jsonb_build_object('antes', v_antes, 'depois', p_rows, 'linhas', v_n));
  return v_n;
end;
$$;

create or replace function public.admin_set_economy_config(p_rows jsonb)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_antes jsonb; v_n int;
begin
  perform private.require_admin();
  select jsonb_agg(to_jsonb(ec)) into v_antes from public.economy_config ec;

  update public.economy_config ec
  set valor = (r->>'valor')::numeric
  from jsonb_array_elements(p_rows) r
  where ec.chave = r->>'chave';
  get diagnostics v_n = row_count;

  perform private.registrar('admin_set_economy_config', null,
    jsonb_build_object('antes', v_antes, 'depois', p_rows, 'linhas', v_n));
  return v_n;
end;
$$;

-- ================================================================ estoque
create or replace function public.top_up_daily_reserve(p_n int)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_por_char int; v_total int := 0; v_c record;
begin
  perform private.require_admin();
  if p_n is null or p_n <= 0 then raise exception 'n invalido'; end if;

  v_por_char := ceil(p_n::numeric / greatest((select count(*) from public.characters), 1));
  for v_c in select id from public.characters order by id loop
    v_total := v_total + private.reservar_diario(v_c.id,
      (select count(*) from public.card_copies cc
       join public.card_types ct on ct.id = cc.card_type_id
       where ct.character_id = v_c.id and cc.reserved_for_daily and not cc.burned)::int + v_por_char);
  end loop;

  perform private.registrar('top_up_daily_reserve', null,
    jsonb_build_object('pedido', p_n, 'marcadas', v_total));
  return v_total;
end;
$$;

create or replace function public.admin_stock_report()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  return jsonb_build_object(
    'por_tier', (
      select coalesce(jsonb_agg(x order by x->>'tier_order'), '[]'::jsonb) from (
        select jsonb_build_object(
          'tier', t.slug, 'tier_order', t.tier_order,
          'total', count(cc.id),
          'distribuidas', count(*) filter (where cc.owner_id is not null),
          'queimadas',    count(*) filter (where cc.burned),
          'reservadas',   count(*) filter (where cc.reserved_for_daily and cc.owner_id is null),
          'disponiveis',  count(*) filter (where cc.owner_id is null and not cc.burned)
        ) as x
        from public.tiers t
        join public.card_types ct on ct.tier = t.slug
        join public.card_copies cc on cc.card_type_id = ct.id
        group by t.slug, t.tier_order) y),
    'por_personagem', (
      select coalesce(jsonb_agg(x order by x->>'display_order'), '[]'::jsonb) from (
        select jsonb_build_object(
          'personagem', ch.slug, 'display_order', ch.display_order,
          'total', count(cc.id),
          'distribuidas', count(*) filter (where cc.owner_id is not null),
          'queimadas',    count(*) filter (where cc.burned),
          'disponiveis',  count(*) filter (where cc.owner_id is null and not cc.burned)
        ) as x
        from public.characters ch
        join public.card_types ct on ct.character_id = ch.id
        join public.card_copies cc on cc.card_type_id = ct.id
        group by ch.slug, ch.display_order) y),
    'selos', (
      select jsonb_build_object(
        'emitidos', count(*) filter (where cc.seal <> 'none'),
        'em_posse', count(*) filter (where cc.seal <> 'none' and cc.owner_id is not null),
        'branco', count(*) filter (where cc.seal = 'branco'),
        'preto',  count(*) filter (where cc.seal = 'preto'),
        'rosa',   count(*) filter (where cc.seal = 'rosa'))
      from public.card_copies cc),
    'desgaste', (
      select coalesce(jsonb_object_agg(damage_level::text, n), '{}'::jsonb)
      from (select damage_level, count(*) as n from public.card_copies group by damage_level) d),
    'reserva_diaria', (
      select count(*) from public.card_copies where reserved_for_daily and owner_id is null)
  );
end;
$$;

-- O banco nao enxerga disco. Devolve o catalogo com os caminhos; quem
-- confere a existencia do arquivo e o painel, com um HEAD em cada um.
create or replace function public.admin_missing_art()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'card_type_id', ct.id, 'personagem', ch.slug, 'skin', ct.skin, 'art_path', ct.art_path)
      order by ch.display_order, ct.tier_order)
    from public.card_types ct join public.characters ch on ch.id = ct.character_id), '[]'::jsonb);
end;
$$;

-- ================================================================ conteudo
create or replace function public.seed_edition_dry_run(p_params jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare v_slug text := lower(p_params->>'slug');
begin
  perform private.require_admin();
  if v_slug is null or v_slug !~ '^[a-z0-9][a-z0-9-]{2,19}$' then
    raise exception 'slug invalido';
  end if;

  return jsonb_build_object(
    'slug', v_slug,
    'ja_existe', exists (select 1 from public.characters where slug = v_slug::extensions.citext),
    'card_types', (select count(*) from public.skins),
    'card_copies', (select sum(t.print_run) from public.skins s join public.tiers t on t.slug = s.tier),
    'selos', jsonb_build_object('branco', 12, 'preto', 4, 'rosa', 1),
    'reserva_diaria', 500,
    'art_paths', (select jsonb_agg('/figurinhas/' || v_slug || '/' || s.slug || '.jpg' order by s.skin_order)
                  from public.skins s)
  );
end;
$$;

create or replace function public.seed_edition(p_params jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_slug text := lower(p_params->>'slug');
  v_id   int;
  v_copias int;
begin
  perform private.require_admin();
  if v_slug is null or v_slug !~ '^[a-z0-9][a-z0-9-]{2,19}$' then
    raise exception 'slug invalido';
  end if;

  -- Secao 16: idempotente por slug. Se ja existe, aborta SEM escrever nada.
  -- Nunca faz DELETE nem UPDATE em card_copies existentes.
  if exists (select 1 from public.characters where slug = v_slug::extensions.citext) then
    raise exception 'personagem % ja existe', v_slug;
  end if;

  insert into public.characters (slug, name, display_order, palette_primary, palette_accent)
  values (v_slug::extensions.citext,
          coalesce(p_params->>'name', initcap(v_slug)),
          coalesce((p_params->>'display_order')::int,
                   (select coalesce(max(display_order), 0) + 1 from public.characters)),
          coalesce(p_params->>'palette_primary', '#555555'),
          coalesce(p_params->>'palette_accent',  '#999999'))
  returning id into v_id;

  insert into public.card_types (character_id, tier, tier_order, skin, print_run, art_path, album_page)
  select v_id, s.tier, t.tier_order, s.slug, t.print_run,
         '/figurinhas/' || v_slug || '/' || s.slug || '.jpg', ap.id
  from public.skins s
  join public.tiers t on t.slug = s.tier
  join public.album_pages ap on ap.slug = s.slug;

  insert into public.card_copies (card_type_id, serial_number, verify_code)
  select ct.id, g,
         upper(substr(encode(extensions.digest(
           'belesma-v1|' || v_slug || '|' || ct.skin || '|' || g::text, 'sha256'), 'hex'), 1, 10))
  from public.card_types ct
  cross join lateral generate_series(1, ct.print_run) g
  where ct.character_id = v_id;

  perform private.distribuir_selos(v_id);
  perform private.reservar_diario(v_id, 500);

  select count(*) into v_copias
  from public.card_copies cc join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = v_id;

  perform private.registrar('seed_edition', v_slug,
    jsonb_build_object('character_id', v_id, 'copias', v_copias));

  return jsonb_build_object('character_id', v_id, 'slug', v_slug, 'copias', v_copias,
    'selos', (select to_jsonb(a) from public.seal_audit a where a.character_id = v_id));
end;
$$;

-- ================================================================ zona de perigo
-- Secao 18.2: nenhum reset apaga card_types nem characters. So posse.
create or replace function private.devolver_ao_pool(p_owner uuid)
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $$
declare v_n int;
begin
  insert into public.copy_history (copy_id, from_player, to_player, kind)
  select id, p_owner, null, 'admin_reset' from public.card_copies where owner_id = p_owner;

  -- Forjada e supply paralelo: devolver ao pool colocaria carta forjada
  -- dentro de pacote. Queima em vez de devolver.
  update public.card_copies
  set owner_id = null, claimed_at = null, burned = true
  where owner_id = p_owner and origin = 'forge';

  -- Puxada volta inteira: mantem id, serial, selo e damage_level.
  -- first_discovered_* NAO e tocado - estreia mundial e historia, nao posse.
  update public.card_copies
  set owner_id = null, claimed_at = null
  where owner_id = p_owner and origin = 'pull';
  get diagnostics v_n = row_count;

  update public.players
  set showcase_1 = null, showcase_2 = null, showcase_3 = null
  where id = p_owner;

  return v_n;
end;
$$;

create or replace function public.admin_reset_player_collection(p_nickname text)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id uuid; v_n int;
begin
  perform private.require_admin();
  select id into v_id from public.players where nickname = p_nickname::extensions.citext;
  if v_id is null then raise exception 'jogador nao encontrado'; end if;

  update public.trades set status = 'cancelled', resolved_at = now()
  where status = 'pending' and (from_player = v_id or to_player = v_id);

  v_n := private.devolver_ao_pool(v_id);
  perform private.registrar('admin_reset_player_collection', p_nickname,
    jsonb_build_object('devolvidas', v_n));
  return v_n;
end;
$$;

create or replace function public.admin_reset_all_collections(p_confirmacao text)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_n int := 0; v_p record;
begin
  perform private.require_admin();
  if p_confirmacao <> 'RESETAR' then
    raise exception 'confirmacao invalida: digite RESETAR';
  end if;

  update public.trades set status = 'cancelled', resolved_at = now() where status = 'pending';
  for v_p in select id from public.players loop
    v_n := v_n + private.devolver_ao_pool(v_p.id);
  end loop;

  perform private.registrar('admin_reset_all_collections', 'todos',
    jsonb_build_object('devolvidas', v_n));
  return v_n;
end;
$$;

create or replace function public.admin_delete_player(p_nickname text)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id uuid; v_n int;
begin
  perform private.require_admin();
  select id into v_id from public.players where nickname = p_nickname::extensions.citext;
  if v_id is null then raise exception 'jogador nao encontrado'; end if;
  if v_id = auth.uid() then raise exception 'nao da para apagar a si mesmo'; end if;

  update public.trades set status = 'cancelled', resolved_at = now()
  where status = 'pending' and (from_player = v_id or to_player = v_id);
  v_n := private.devolver_ao_pool(v_id);

  perform private.registrar('admin_delete_player', p_nickname,
    jsonb_build_object('devolvidas', v_n, 'player_id', v_id));

  -- players.id referencia auth.users on delete cascade
  delete from auth.users where id = v_id;
  return v_n;
end;
$$;

-- ================================================================ permissoes
do $$
declare f text;
begin
  foreach f in array array[
    'admin_jogadores()', 'grant_packs(text,text,int)', 'admin_reset_password(text,text)',
    'admin_reset_daily_cooldown(text)', 'admin_set_pack_config(jsonb)',
    'admin_set_economy_config(jsonb)', 'top_up_daily_reserve(int)', 'admin_stock_report()',
    'admin_missing_art()', 'seed_edition_dry_run(jsonb)', 'seed_edition(jsonb)',
    'admin_reset_player_collection(text)', 'admin_reset_all_collections(text)',
    'admin_delete_player(text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
    execute format('alter function public.%s owner to postgres', f);
  end loop;
end $$;


-- ===== 20260822110000_mudar_nickname.sql =====
-- BELESMA figurinhas - troca de apelido
--
-- A spec secao 10 diz "apelido unico e travado". Isto afrouxa o "travado",
-- mas mantem o "unico" no sentido forte: um apelido que ja foi de alguem
-- nunca vai para outra pessoa.
--
-- Por que isso importa: a figurinha exportada grava o apelido para dar
-- credito (secao 14). Se a "ana" virasse "bia" e outra pessoa pudesse
-- assumir "ana", todo arquivo antigo passaria a creditar a pessoa errada.
-- O historico abaixo impede exatamente isso.
--
-- O apelido tambem e a identidade de login: o e-mail interno e
-- <apelido>@belesma.local. Trocar um sem trocar o outro deixaria o jogador
-- sem conseguir entrar. As duas coisas mudam na mesma transacao.

create table if not exists public.nickname_history (
  id          bigserial primary key,
  player_id   uuid not null references public.players(id) on delete cascade,
  nickname    extensions.citext not null,
  usado_ate   timestamptz not null default now()
);
create unique index if not exists nickname_history_unico
  on public.nickname_history (nickname, player_id);
create index if not exists nickname_history_nick on public.nickname_history (nickname);

alter table public.nickname_history enable row level security;
-- o historico e publico: e ele que permite conferir credito de figurinha velha
drop policy if exists nickname_history_leitura on public.nickname_history;
create policy nickname_history_leitura on public.nickname_history
  for select to anon, authenticated using (true);
grant select on public.nickname_history to anon, authenticated;
grant all on public.nickname_history to service_role;
grant usage, select on sequence public.nickname_history_id_seq to service_role;

-- ---------------------------------------------------------------- disponibilidade
-- Agora tambem recusa apelido que ja foi de OUTRA pessoa. Retomar um apelido
-- que ja foi seu continua liberado.
create or replace function public.nickname_disponivel(p_nickname text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  -- Apelido EM USO nunca esta disponivel, nem para o proprio dono: quem
  -- digita o proprio apelido no formulario de troca recebe "ja esta em uso",
  -- que e verdade. A excecao vale so para o HISTORICO - retomar um apelido
  -- que ja foi seu continua liberado.
  select not exists (
    select 1 from public.players
    where nickname = p_nickname::extensions.citext
  ) and not exists (
    select 1 from public.nickname_history
    where nickname = p_nickname::extensions.citext
      and player_id is distinct from auth.uid()
  );
$$;

-- ---------------------------------------------------------------- troca
create or replace function public.mudar_nickname(p_novo text)
returns public.players
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_atual  extensions.citext;
  v_row    public.players;
begin
  if v_uid is null then
    raise exception 'precisa estar logado' using errcode = '42501';
  end if;

  if p_novo !~ '^[a-z0-9][a-z0-9_-]{2,19}$' then
    raise exception 'apelido invalido: 3 a 20 caracteres, minusculas, numeros, - e _';
  end if;

  select nickname into v_atual from public.players where id = v_uid for update;
  if v_atual is null then raise exception 'jogador nao encontrado'; end if;
  if v_atual = p_novo::extensions.citext then
    raise exception 'esse ja e o seu apelido';
  end if;

  if exists (select 1 from public.players
             where nickname = p_novo::extensions.citext and id <> v_uid) then
    raise exception 'esse apelido ja esta em uso';
  end if;

  if exists (select 1 from public.nickname_history
             where nickname = p_novo::extensions.citext and player_id <> v_uid) then
    raise exception 'esse apelido ja foi de outra pessoa e nao pode ser reusado';
  end if;

  -- guarda o que estava em uso antes de sobrescrever
  insert into public.nickname_history (player_id, nickname)
  values (v_uid, v_atual)
  on conflict (nickname, player_id) do update set usado_ate = now();

  update public.players set nickname = p_novo::extensions.citext
  where id = v_uid
  returning * into v_row;

  -- o login e por <apelido>@belesma.local: sem isto o jogador nao entra mais
  update auth.users
  set email = p_novo || '@belesma.local',
      updated_at = now()
  where id = v_uid;

  return v_row;
exception
  when unique_violation then
    raise exception 'esse apelido ja esta em uso';
end;
$$;

revoke all on function public.mudar_nickname(text) from public, anon;
grant execute on function public.mudar_nickname(text) to authenticated;
alter function public.mudar_nickname(text) owner to postgres;
alter function public.nickname_disponivel(text) owner to postgres;


-- ===== 20260822120000_rpc_social.sql =====
-- BELESMA figurinhas - Fase 5: trocas, indice global, vitrine e ranking
-- (spec secoes 9 e 11)

-- ================================================================ trocas
-- Secao 19.6 ja previa cada lado oferecendo copia OU baba. A interface da
-- Fase 5 so troca carta por carta, mas a RPC ja fecha o contrato inteiro -
-- assim a Fase 6 liga a moeda sem reescrever a transacao.
create or replace function public.propose_trade(
  p_offered_copy_id   bigint default null,
  p_offered_baba      int    default 0,
  p_requested_copy_id bigint default null,
  p_requested_baba    int    default 0
)
returns public.trades
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_outro uuid;
  v_row   public.trades;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  -- o que eu ofereco tem que ser meu
  if p_offered_copy_id is not null then
    if not exists (select 1 from public.card_copies
                   where id = p_offered_copy_id and owner_id = v_uid and not burned) then
      raise exception 'essa copia nao e sua';
    end if;
  elsif p_offered_baba <= 0 then
    raise exception 'ofereca uma copia ou um valor em baba';
  else
    if (select baba from public.players where id = v_uid) < p_offered_baba then
      raise exception 'saldo insuficiente';
    end if;
  end if;

  -- o que eu peco define com quem e a troca
  if p_requested_copy_id is not null then
    select owner_id into v_outro from public.card_copies
    where id = p_requested_copy_id and not burned;
    if v_outro is null then raise exception 'essa copia nao tem dono'; end if;
  elsif p_requested_baba <= 0 then
    raise exception 'peca uma copia ou um valor em baba';
  else
    raise exception 'para pedir baba, ofereca uma copia';   -- baba por baba e proibido
  end if;

  if v_outro = v_uid then raise exception 'nao da para trocar consigo mesmo'; end if;

  insert into public.trades (from_player, to_player, offered_copy_id, offered_baba,
                             requested_copy_id, requested_baba)
  values (v_uid, v_outro, p_offered_copy_id, coalesce(p_offered_baba, 0),
          p_requested_copy_id, coalesce(p_requested_baba, 0))
  returning * into v_row;
  return v_row;
end;
$$;

-- Secao 11: revalida a posse das DUAS copias DENTRO da transacao. Uma
-- proposta pode ficar dias parada e a carta ja ter mudado de dono.
--
-- Devolve jsonb, nao a linha, por um motivo concreto: RAISE faz ROLLBACK de
-- tudo, inclusive do "update trades set cancelled" que marca a proposta
-- furada. Entao os dois tipos de falha sao tratados diferente:
--
--   autorizacao / nao existe / ja resolvida  -> RAISE (nao ha o que gravar)
--   revalidacao falhou (dono mudou, saldo)   -> CANCELA a proposta e devolve
--                                               {ok:false, motivo}, para o
--                                               cancelamento sobreviver ao
--                                               commit
create or replace function public.accept_trade(p_trade_id bigint)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  t     public.trades;
  v_de  uuid;
  v_para uuid;

  -- cancela a proposta e devolve o motivo, SEM raise, para o cancelamento
  -- sobreviver ao commit
  function_motivo text;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  -- FOR UPDATE: duas propostas com a mesma copia aceitas quase junto -
  -- so uma passa (teste de aceitacao 7)
  select * into t from public.trades where id = p_trade_id for update;
  if t.id is null then raise exception 'proposta nao existe'; end if;
  if t.to_player <> v_uid then raise exception 'essa proposta nao e sua' using errcode = '42501'; end if;
  if t.status <> 'pending' then raise exception 'essa proposta ja foi resolvida'; end if;

  -- ---------------------------------------------------------- revalidacao
  if t.offered_copy_id is not null then
    select owner_id into v_de from public.card_copies
    where id = t.offered_copy_id and not burned for update;
    if v_de is distinct from t.from_player then
      function_motivo := 'a carta oferecida mudou de dono desde a proposta';
    end if;
  end if;

  if t.requested_copy_id is not null then
    select owner_id into v_para from public.card_copies
    where id = t.requested_copy_id and not burned for update;
    if v_para is distinct from t.to_player then
      function_motivo := 'a carta pedida mudou de dono desde a proposta';
    end if;
  end if;

  if function_motivo is null and t.offered_baba > 0
     and (select baba from public.players where id = t.from_player) < t.offered_baba then
    function_motivo := 'quem propos nao tem mais saldo para cobrir a oferta';
  end if;
  if function_motivo is null and t.requested_baba > 0
     and (select baba from public.players where id = t.to_player) < t.requested_baba then
    function_motivo := 'voce nao tem mais saldo para cobrir o pedido';
  end if;

  if function_motivo is not null then
    update public.trades set status = 'cancelled', resolved_at = now() where id = t.id;
    return jsonb_build_object('ok', false, 'motivo', function_motivo, 'trade_id', t.id);
  end if;

  -- ---------------------------------------------------------- execucao
  if t.offered_copy_id is not null then
    update public.card_copies set owner_id = t.to_player, claimed_at = now()
    where id = t.offered_copy_id;
    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (t.offered_copy_id, t.from_player, t.to_player, 'trade');
  end if;

  if t.requested_copy_id is not null then
    update public.card_copies set owner_id = t.from_player, claimed_at = now()
    where id = t.requested_copy_id;
    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (t.requested_copy_id, t.to_player, t.from_player, 'trade');
  end if;

  if t.offered_baba > 0 then
    update public.players set baba = baba - t.offered_baba where id = t.from_player;
    update public.players set baba = baba + t.offered_baba where id = t.to_player;
    insert into public.baba_log (player_id, delta, motivo, ref_id) values
      (t.from_player, -t.offered_baba, 'troca', t.id::text),
      (t.to_player,    t.offered_baba, 'troca', t.id::text);
  end if;
  if t.requested_baba > 0 then
    update public.players set baba = baba - t.requested_baba where id = t.to_player;
    update public.players set baba = baba + t.requested_baba where id = t.from_player;
    insert into public.baba_log (player_id, delta, motivo, ref_id) values
      (t.to_player,   -t.requested_baba, 'troca', t.id::text),
      (t.from_player,  t.requested_baba, 'troca', t.id::text);
  end if;

  update public.trades set status = 'accepted', resolved_at = now() where id = t.id
  returning * into t;

  -- Secao 11: aceitar invalida as outras propostas que envolvam estas copias.
  update public.trades set status = 'cancelled', resolved_at = now()
  where status = 'pending' and id <> t.id
    and (offered_copy_id   in (t.offered_copy_id, t.requested_copy_id)
      or requested_copy_id in (t.offered_copy_id, t.requested_copy_id));

  -- a vitrine nao pode apontar para carta que nao e mais sua
  update public.players set
    showcase_1 = case when showcase_1 in (t.offered_copy_id, t.requested_copy_id) then null else showcase_1 end,
    showcase_2 = case when showcase_2 in (t.offered_copy_id, t.requested_copy_id) then null else showcase_2 end,
    showcase_3 = case when showcase_3 in (t.offered_copy_id, t.requested_copy_id) then null else showcase_3 end
  where id in (t.from_player, t.to_player);

  return jsonb_build_object('ok', true, 'trade_id', t.id);
end;
$$;

create or replace function public.decline_trade(p_trade_id bigint)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  update public.trades set status = 'declined', resolved_at = now()
  where id = p_trade_id and to_player = v_uid and status = 'pending';
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'nada a recusar aqui'; end if;
end;
$$;

create or replace function public.cancel_trade(p_trade_id bigint)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  update public.trades set status = 'cancelled', resolved_at = now()
  where id = p_trade_id and from_player = v_uid and status = 'pending';
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'nada a cancelar aqui'; end if;
end;
$$;

-- ================================================================ vitrine
create or replace function public.set_showcase(p_copy_ids bigint[])
returns public.players
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_uid uuid := auth.uid(); v_row public.players; v_id bigint;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;
  if array_length(p_copy_ids, 1) > 3 then raise exception 'a vitrine cabe 3'; end if;

  foreach v_id in array coalesce(p_copy_ids, '{}'::bigint[]) loop
    if not exists (select 1 from public.card_copies
                   where id = v_id and owner_id = v_uid and not burned) then
      raise exception 'so da para expor copia sua';
    end if;
  end loop;

  update public.players set
    showcase_1 = p_copy_ids[1], showcase_2 = p_copy_ids[2], showcase_3 = p_copy_ids[3]
  where id = v_uid
  returning * into v_row;
  return v_row;
end;
$$;

-- ================================================================ indice global
-- Secao 11: conta PERSONAGENS descobertos, com as skins dentro. So conta
-- origin='pull' - forjada nao descobre nada (secao 7).
create or replace function public.global_index()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare v jsonb;
begin
  with tipos as (
    select ct.id, ct.character_id, ct.skin, ct.tier, ct.tier_order, ct.print_run,
           count(*) filter (where cc.owner_id is not null and cc.origin = 'pull') as distribuidas,
           bool_or(cc.first_discovered_at is not null and cc.origin = 'pull')     as descoberto,
           min(cc.first_discovered_at) filter (where cc.origin = 'pull')          as em,
           (select p.nickname from public.card_copies c2
            join public.players p on p.id = c2.first_discovered_by
            where c2.card_type_id = ct.id and c2.origin = 'pull'
              and c2.first_discovered_at is not null
            order by c2.first_discovered_at limit 1)                              as primeiro
    from public.card_types ct
    left join public.card_copies cc on cc.card_type_id = ct.id
    group by ct.id
  )
  select jsonb_build_object(
    'personagens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', ch.slug, 'nome', ch.name, 'display_order', ch.display_order,
        'descoberto', (select bool_or(t.descoberto) from tipos t where t.character_id = ch.id),
        'tipos', (select jsonb_agg(jsonb_build_object(
                    'skin', t.skin, 'tier', t.tier, 'tier_order', t.tier_order,
                    'print_run', t.print_run, 'distribuidas', t.distribuidas,
                    'descoberto', t.descoberto, 'primeiro', t.primeiro, 'em', t.em)
                    order by t.tier_order, t.skin)
                  from tipos t where t.character_id = ch.id)
      ) order by ch.display_order)
      from public.characters ch), '[]'::jsonb),
    'descobertos', (select count(distinct t.character_id) from tipos t where t.descoberto),
    'total_personagens', (select count(*) from public.characters)
  ) into v;
  return v;
end;
$$;

-- ================================================================ par de aura
-- Secao 11: aura-branca E aura-preta do MESMO personagem. O evento mais raro
-- do jogo — e publico, o grupo inteiro vê.
create or replace function public.pares_de_aura()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'nickname', p.nickname, 'personagem', ch.slug, 'nome', ch.name,
    'em', x.em) order by x.em), '[]'::jsonb)
  from (
    select cc.owner_id, ct.character_id, max(cc.claimed_at) as em
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    where cc.owner_id is not null and ct.skin in ('aura-branca','aura-preta')
    group by cc.owner_id, ct.character_id
    having count(distinct ct.skin) = 2
  ) x
  join public.players p on p.id = x.owner_id
  join public.characters ch on ch.id = x.character_id;
$$;

-- ================================================================ caçada de serial
-- Secao 11: ranking publico de menores seriais e contagem de selos.
create or replace function public.ranking_serial()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'nickname', p.nickname,
    'copias', x.copias,
    'selos', x.selos,
    'melhor_serial', x.melhor_serial,
    'melhor_skin', x.melhor_skin,
    'melhor_personagem', x.melhor_personagem,
    'melhor_print_run', x.melhor_print_run,
    'unos', x.unos
  ) order by x.selos desc, x.melhor_serial), '[]'::jsonb)
  from (
    select cc.owner_id,
           count(*) as copias,
           count(*) filter (where cc.seal <> 'none') as selos,
           count(*) filter (where cc.serial_number = 1) as unos,
           min(cc.serial_number) as melhor_serial,
           (array_agg(ct.skin order by cc.serial_number))[1]  as melhor_skin,
           (array_agg(ch.slug order by cc.serial_number))[1]  as melhor_personagem,
           (array_agg(ct.print_run order by cc.serial_number))[1] as melhor_print_run
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.characters ch on ch.id = ct.character_id
    where cc.owner_id is not null and cc.origin = 'pull'
    group by cc.owner_id
  ) x
  join public.players p on p.id = x.owner_id;
$$;

-- ================================================================ realtime
-- Secao 11: as propostas chegam sem recarregar. O Realtime respeita a RLS,
-- entao cada jogador so recebe evento de troca em que ele e parte.
do $$ begin
  alter publication supabase_realtime add table public.trades;
exception when duplicate_object then null; when undefined_object then null; end $$;

alter table public.trades replica identity full;

-- ================================================================ permissoes
do $$
declare f text;
begin
  foreach f in array array[
    'propose_trade(bigint,int,bigint,int)', 'accept_trade(bigint)',
    'decline_trade(bigint)', 'cancel_trade(bigint)', 'set_showcase(bigint[])'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
    execute format('alter function public.%s owner to postgres', f);
  end loop;

  -- indice, pares de aura e ranking sao PUBLICOS (secao 11)
  foreach f in array array['global_index()', 'pares_de_aura()', 'ranking_serial()'] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
    execute format('alter function public.%s owner to postgres', f);
  end loop;
end $$;


-- ===== 20260822130000_album_colagem.sql =====
-- BELESMA figurinhas - colar figurinha no album
--
-- Ate aqui o album se preenchia sozinho: teve a copia, apareceu no slot.
-- Agora o gesto existe - o jogador arrasta a figurinha do deck e COLA.
--
-- Isso precisa persistir no banco. A spec secao 2 e explicita: nunca usar
-- localStorage como fonte de verdade.

create table if not exists public.album_colagem (
  player_id    uuid not null references public.players(id) on delete cascade,
  card_type_id int  not null references public.card_types(id),
  copy_id      bigint not null references public.card_copies(id),
  colada_em    timestamptz not null default now(),
  primary key (player_id, card_type_id)
);
create index if not exists album_colagem_copy on public.album_colagem(copy_id);

alter table public.album_colagem enable row level security;
drop policy if exists album_colagem_leitura on public.album_colagem;
-- publica: o album de cada um pode ser visto pelo grupo
create policy album_colagem_leitura on public.album_colagem
  for select to anon, authenticated using (true);
grant select on public.album_colagem to anon, authenticated;
grant all on public.album_colagem to service_role;

-- ---------------------------------------------------------------- colar
create or replace function public.colar(p_copy_id bigint)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_tipo int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select card_type_id into v_tipo
  from public.card_copies
  where id = p_copy_id and owner_id = v_uid and not burned;
  if v_tipo is null then raise exception 'essa copia nao e sua'; end if;

  insert into public.album_colagem (player_id, card_type_id, copy_id)
  values (v_uid, v_tipo, p_copy_id)
  on conflict (player_id, card_type_id) do update set copy_id = excluded.copy_id,
                                                      colada_em = now();

  return jsonb_build_object('card_type_id', v_tipo, 'copy_id', p_copy_id);
end;
$$;

-- ---------------------------------------------------------------- descolar
create or replace function public.descolar(p_card_type_id int)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
begin
  delete from public.album_colagem
  where player_id = auth.uid() and card_type_id = p_card_type_id;
end;
$$;

-- ---------------------------------------------------------------- colar tudo
-- Quem ja tem acervo grande nao vai arrastar 80 figurinhas na mao.
create or replace function public.colar_tudo()
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  insert into public.album_colagem (player_id, card_type_id, copy_id)
  select v_uid, cc.card_type_id, min(cc.id)
  from public.card_copies cc
  where cc.owner_id = v_uid and not cc.burned
  group by cc.card_type_id
  on conflict (player_id, card_type_id) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- A colagem NAO e limpa quando a copia sai numa troca: a consulta do album
-- confere a posse na hora, entao o slot volta a ficar vazio sozinho. Limpar
-- aqui tambem evita a linha orfa ficar para sempre.
create or replace function public.accept_trade(p_trade_id bigint)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  t     public.trades;
  v_de  uuid;
  v_para uuid;
  function_motivo text;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select * into t from public.trades where id = p_trade_id for update;
  if t.id is null then raise exception 'proposta nao existe'; end if;
  if t.to_player <> v_uid then raise exception 'essa proposta nao e sua' using errcode = '42501'; end if;
  if t.status <> 'pending' then raise exception 'essa proposta ja foi resolvida'; end if;

  if t.offered_copy_id is not null then
    select owner_id into v_de from public.card_copies
    where id = t.offered_copy_id and not burned for update;
    if v_de is distinct from t.from_player then
      function_motivo := 'a carta oferecida mudou de dono desde a proposta';
    end if;
  end if;

  if t.requested_copy_id is not null then
    select owner_id into v_para from public.card_copies
    where id = t.requested_copy_id and not burned for update;
    if v_para is distinct from t.to_player then
      function_motivo := 'a carta pedida mudou de dono desde a proposta';
    end if;
  end if;

  if function_motivo is null and t.offered_baba > 0
     and (select baba from public.players where id = t.from_player) < t.offered_baba then
    function_motivo := 'quem propos nao tem mais saldo para cobrir a oferta';
  end if;
  if function_motivo is null and t.requested_baba > 0
     and (select baba from public.players where id = t.to_player) < t.requested_baba then
    function_motivo := 'voce nao tem mais saldo para cobrir o pedido';
  end if;

  if function_motivo is not null then
    update public.trades set status = 'cancelled', resolved_at = now() where id = t.id;
    return jsonb_build_object('ok', false, 'motivo', function_motivo, 'trade_id', t.id);
  end if;

  if t.offered_copy_id is not null then
    update public.card_copies set owner_id = t.to_player, claimed_at = now()
    where id = t.offered_copy_id;
    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (t.offered_copy_id, t.from_player, t.to_player, 'trade');
  end if;

  if t.requested_copy_id is not null then
    update public.card_copies set owner_id = t.from_player, claimed_at = now()
    where id = t.requested_copy_id;
    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (t.requested_copy_id, t.to_player, t.from_player, 'trade');
  end if;

  if t.offered_baba > 0 then
    update public.players set baba = baba - t.offered_baba where id = t.from_player;
    update public.players set baba = baba + t.offered_baba where id = t.to_player;
    insert into public.baba_log (player_id, delta, motivo, ref_id) values
      (t.from_player, -t.offered_baba, 'troca', t.id::text),
      (t.to_player,    t.offered_baba, 'troca', t.id::text);
  end if;
  if t.requested_baba > 0 then
    update public.players set baba = baba - t.requested_baba where id = t.to_player;
    update public.players set baba = baba + t.requested_baba where id = t.from_player;
    insert into public.baba_log (player_id, delta, motivo, ref_id) values
      (t.to_player,   -t.requested_baba, 'troca', t.id::text),
      (t.from_player,  t.requested_baba, 'troca', t.id::text);
  end if;

  update public.trades set status = 'accepted', resolved_at = now() where id = t.id
  returning * into t;

  update public.trades set status = 'cancelled', resolved_at = now()
  where status = 'pending' and id <> t.id
    and (offered_copy_id   in (t.offered_copy_id, t.requested_copy_id)
      or requested_copy_id in (t.offered_copy_id, t.requested_copy_id));

  update public.players set
    showcase_1 = case when showcase_1 in (t.offered_copy_id, t.requested_copy_id) then null else showcase_1 end,
    showcase_2 = case when showcase_2 in (t.offered_copy_id, t.requested_copy_id) then null else showcase_2 end,
    showcase_3 = case when showcase_3 in (t.offered_copy_id, t.requested_copy_id) then null else showcase_3 end
  where id in (t.from_player, t.to_player);

  -- a carta descolou do album de quem a entregou
  delete from public.album_colagem
  where copy_id in (t.offered_copy_id, t.requested_copy_id);

  return jsonb_build_object('ok', true, 'trade_id', t.id);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['colar(bigint)', 'descolar(int)', 'colar_tudo()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
    execute format('alter function public.%s owner to postgres', f);
  end loop;
  execute 'alter function public.accept_trade(bigint) owner to postgres';
  execute 'grant execute on function public.accept_trade(bigint) to authenticated';
end $$;


-- ===== 20260822140000_auditoria_garantido.sql =====
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


-- ===== 20260822150000_fase6_economia.sql =====
-- BELESMA figurinhas - Fase 6: forja, moeda BABA, loja e verificacao publica
-- (spec secoes 7, 14 e 19)

-- ================================================================ serial da forjada
-- A forjada e SUPPLY PARALELO: nao consome serial da tiragem original
-- (spec §7). Ate agora serial_number era NOT NULL, o que obrigaria a forjada
-- a ocupar um numero da tiragem - exatamente o que a spec proibe.
--
-- Agora: pull tem serial e nao tem forge_index; forge tem forge_index e nao
-- tem serial. O unique (card_type_id, serial_number) continua valendo para
-- as puxadas, porque NULL nao conflita com NULL no Postgres.
alter table public.card_copies alter column serial_number drop not null;

do $$ begin
  alter table public.card_copies drop constraint card_copies_forge_index_coerente;
exception when undefined_object then null; end $$;

-- idempotente: o harness da Fase 1 roda as migracoes duas vezes de proposito
do $$ begin
  alter table public.card_copies
    add constraint card_copies_procedencia_coerente check (
      (origin = 'pull'  and serial_number is not null and forge_index is null) or
      (origin = 'forge' and serial_number is null     and forge_index is not null)
    );
exception when duplicate_object then null; end $$;

create unique index if not exists card_copies_forge_index_unico
  on public.card_copies (card_type_id, forge_index) where origin = 'forge';

-- ================================================================ helpers
create or replace function private.preco(p_chave text)
returns numeric
language sql stable
set search_path = public, extensions, pg_temp
as $$ select valor from public.economy_config where chave = p_chave $$;

-- Todo credito e debito passa por aqui, e o extrato e gravado na MESMA
-- transacao que altera o saldo (spec §19.1).
create or replace function private.mover_baba(
  p_player uuid, p_delta int, p_motivo text, p_ref text default null)
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $$
declare v_novo int;
begin
  update public.players set baba = baba + p_delta
  where id = p_player
  returning baba into v_novo;

  if v_novo is null then raise exception 'jogador nao encontrado'; end if;

  insert into public.baba_log (player_id, delta, motivo, ref_id)
  values (p_player, p_delta, p_motivo, p_ref);
  return v_novo;
end;
$$;

-- ================================================================ forja
-- Spec §7. Consome 5 copias do MESMO tier, de personagens e skins quaisquer,
-- e devolve 1 do tier imediatamente acima.
create or replace function public.forge(p_copy_ids bigint[])
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_tier   text;
  v_ordem  smallint;
  v_acima  text;
  v_n      int;
  v_tipo   int;
  v_idx    int;
  v_nova   bigint;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;
  if array_length(p_copy_ids, 1) <> 5 then raise exception 'a forja consome exatamente 5'; end if;
  if (select count(distinct x) from unnest(p_copy_ids) x) <> 5 then
    raise exception 'as 5 precisam ser copias diferentes';
  end if;

  -- trava as 5 e confere posse, tier unico e que nenhuma esta em troca aberta
  select count(*), min(ct.tier), min(t.tier_order)
    into v_n, v_tier, v_ordem
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  join public.tiers t on t.slug = ct.tier
  where cc.id = any(p_copy_ids) and cc.owner_id = v_uid and not cc.burned;

  if v_n <> 5 then raise exception 'alguma dessas copias nao e sua'; end if;

  if (select count(distinct ct.tier) from public.card_copies cc
      join public.card_types ct on ct.id = cc.card_type_id
      where cc.id = any(p_copy_ids)) <> 1 then
    raise exception 'as 5 precisam ser do mesmo tier';
  end if;

  if exists (select 1 from public.trades
             where status = 'pending'
               and (offered_copy_id = any(p_copy_ids) or requested_copy_id = any(p_copy_ids))) then
    raise exception 'uma dessas copias esta em proposta de troca aberta';
  end if;

  -- teto: a forja so produz ate mitica (spec §7)
  select slug into v_acima from public.tiers where tier_order = v_ordem + 1;
  if v_acima is null then raise exception 'nao existe tier acima de %', v_tier; end if;
  if not (select forjavel from public.tiers where slug = v_tier) then
    raise exception 'tier % nao e forjavel', v_tier;
  end if;

  -- sorteia o card_type de destino dentro do tier acima
  select ct.id into v_tipo
  from public.card_types ct where ct.tier = v_acima
  order by extensions.gen_random_bytes(8) limit 1;
  if v_tipo is null then raise exception 'sem tipo no tier %', v_acima; end if;

  -- as 5 saem de circulacao PARA SEMPRE: nao voltam ao pool de sorteio
  insert into public.copy_history (copy_id, from_player, to_player, kind)
  select id, v_uid, null, 'forge' from public.card_copies where id = any(p_copy_ids);

  update public.card_copies
  set owner_id = null, claimed_at = null, burned = true
  where id = any(p_copy_ids);

  delete from public.album_colagem where copy_id = any(p_copy_ids);
  update public.players set
    showcase_1 = case when showcase_1 = any(p_copy_ids) then null else showcase_1 end,
    showcase_2 = case when showcase_2 = any(p_copy_ids) then null else showcase_2 end,
    showcase_3 = case when showcase_3 = any(p_copy_ids) then null else showcase_3 end
  where id = v_uid;

  -- forge_index sequencial por card_type; serial fica NULL (supply paralelo)
  select coalesce(max(forge_index), 0) + 1 into v_idx
  from public.card_copies where card_type_id = v_tipo and origin = 'forge';

  insert into public.card_copies (card_type_id, serial_number, origin, forge_index,
                                  owner_id, claimed_at, seal, verify_code)
  values (v_tipo, null, 'forge', v_idx, v_uid, now(), 'none',
          upper(substr(encode(extensions.digest(
            'forja|' || v_tipo::text || '|' || v_idx::text, 'sha256'), 'hex'), 1, 10)))
  returning id into v_nova;

  insert into public.copy_history (copy_id, from_player, to_player, kind)
  values (v_nova, null, v_uid, 'forge');

  return jsonb_build_object(
    'copy_id', v_nova, 'card_type_id', v_tipo, 'forge_index', v_idx,
    'tier', v_acima, 'queimadas', 5);
end;
$$;

-- ================================================================ vender
-- Spec §19.4.
create or replace function public.vender(p_copy_id bigint)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  c       record;
  v_valor numeric;
  v_saldo int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select cc.id, cc.card_type_id, cc.seal, cc.origin, cc.damage_level, cc.owner_id,
         ct.tier, t.vendavel
    into c
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  join public.tiers t on t.slug = ct.tier
  where cc.id = p_copy_id and not cc.burned
  for update of cc;

  if c.id is null or c.owner_id <> v_uid then raise exception 'essa copia nao e sua'; end if;

  -- "prisma nao vende" e uma FLAG, nao uma chave ausente na tabela de precos
  if not c.vendavel then raise exception 'figurinha % nao pode ser vendida', c.tier; end if;
  if c.seal <> 'none' then raise exception 'figurinha selada nao se vende'; end if;

  if (select count(*) from public.card_copies
      where owner_id = v_uid and card_type_id = c.card_type_id and not burned) < 2 then
    raise exception 'essa e a sua ultima copia desse tipo';
  end if;

  if exists (select 1 from public.trades where status = 'pending'
             and (offered_copy_id = p_copy_id or requested_copy_id = p_copy_id)) then
    raise exception 'essa copia esta em proposta de troca aberta';
  end if;

  v_valor := private.preco('venda_' || c.tier);
  if v_valor is null then raise exception 'sem preco para o tier %', c.tier; end if;
  if c.damage_level > 0 then v_valor := v_valor * private.preco('multiplicador_estragada'); end if;
  if c.origin = 'forge'  then v_valor := v_valor * private.preco('multiplicador_forjada'); end if;
  v_valor := floor(v_valor);

  insert into public.copy_history (copy_id, from_player, to_player, kind)
  values (p_copy_id, v_uid, null, 'sell');

  if c.origin = 'forge' then
    -- Forjada vendida e QUEIMADA, nao volta ao pool: supply paralelo nao pode
    -- virar supply de pacote e contaminar o indice global (spec §19.4).
    update public.card_copies
    set owner_id = null, claimed_at = null, burned = true
    where id = p_copy_id;
  else
    update public.card_copies
    set owner_id = null, claimed_at = null,
        damage_level = least(damage_level + 1, 3)
    where id = p_copy_id;
  end if;

  delete from public.album_colagem where copy_id = p_copy_id;
  update public.players set
    showcase_1 = case when showcase_1 = p_copy_id then null else showcase_1 end,
    showcase_2 = case when showcase_2 = p_copy_id then null else showcase_2 end,
    showcase_3 = case when showcase_3 = p_copy_id then null else showcase_3 end
  where id = v_uid;

  v_saldo := private.mover_baba(v_uid, v_valor::int, 'venda', p_copy_id::text);
  return jsonb_build_object('valor', v_valor, 'saldo', v_saldo, 'queimada', c.origin = 'forge');
end;
$$;

-- ================================================================ restaurar
-- Spec §19.2. Sempre deficitario de proposito: estragada vale 40% em
-- QUALQUER nivel, entao o ganho e fixo e o custo cresce.
create or replace function public.restaurar(p_copy_id bigint)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  c       record;
  v_custo numeric;
  v_saldo int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select cc.id, cc.damage_level, cc.owner_id, ct.tier into c
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where cc.id = p_copy_id and not cc.burned
  for update of cc;

  if c.id is null or c.owner_id <> v_uid then raise exception 'essa copia nao e sua'; end if;
  if c.damage_level = 0 then raise exception 'essa figurinha nao esta estragada'; end if;

  v_custo := floor(coalesce(private.preco('venda_' || c.tier), 0)
                   * private.preco('restauro_mult_' || c.damage_level::text));
  if v_custo <= 0 then raise exception 'sem preco de restauro para o tier %', c.tier; end if;

  if (select baba from public.players where id = v_uid) < v_custo then
    raise exception 'saldo insuficiente: precisa de % baba', v_custo;
  end if;

  update public.card_copies set damage_level = 0 where id = p_copy_id;
  v_saldo := private.mover_baba(v_uid, -v_custo::int, 'restauro', p_copy_id::text);
  return jsonb_build_object('custo', v_custo, 'saldo', v_saldo);
end;
$$;

-- ================================================================ loja
-- Spec §19.5. Pacote comprado e pacote de ALLOTMENT: tira os slots base de
-- fora da reserva do diario.
create or replace function public.comprar_pacote(p_pack_type text, p_character_id int default null)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_preco numeric;
  v_teto  int;
  v_hoje  int;
  v_saldo int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;
  if p_pack_type not in ('comum','raro','ultra') then raise exception 'tipo de pacote invalido'; end if;

  perform 1 from public.players where id = v_uid for update;

  v_preco := private.preco('compra_' || p_pack_type);
  if v_preco is null then raise exception 'sem preco para o pacote %', p_pack_type; end if;
  if p_character_id is not null then
    if not exists (select 1 from public.characters where id = p_character_id) then
      raise exception 'personagem nao existe';
    end if;
    v_preco := v_preco * private.preco('dirigido_mult');
  end if;

  -- teto diario contado NO SERVIDOR, pela janela de 24h do extrato
  v_teto := private.preco('teto_compra_dia')::int;
  select count(*) into v_hoje from public.baba_log
  where player_id = v_uid and motivo = 'compra' and created_at > now() - interval '24 hours';
  if v_hoje >= v_teto then
    raise exception 'voce ja comprou % pacotes nas ultimas 24h', v_teto;
  end if;

  if (select baba from public.players where id = v_uid) < v_preco then
    raise exception 'saldo insuficiente: o pacote custa % baba', v_preco;
  end if;

  v_saldo := private.mover_baba(v_uid, -v_preco::int, 'compra', p_pack_type);

  update public.players set
    packs_common = packs_common + (case when p_pack_type = 'comum' then 1 else 0 end),
    packs_rare   = packs_rare   + (case when p_pack_type = 'raro'  then 1 else 0 end),
    packs_ultra  = packs_ultra  + (case when p_pack_type = 'ultra' then 1 else 0 end)
  where id = v_uid;

  return jsonb_build_object('pack_type', p_pack_type, 'preco', v_preco, 'saldo', v_saldo,
                            'restantes_hoje', v_teto - v_hoje - 1);
end;
$$;

-- ================================================================ bonus de album
-- Spec §19.3: +150 por pagina completa, UMA VEZ por pagina, para sempre.
create or replace function public.conferir_bonus_album()
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_val  int;
  v_pago int := 0;
  p      record;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;
  v_val := private.preco('bonus_pagina')::int;

  for p in
    select ap.id, ap.title
    from public.album_pages ap
    where ap.skin_filter is not null
      and not exists (select 1 from public.album_page_rewards r
                      where r.player_id = v_uid and r.album_page_id = ap.id)
      -- pagina completa = todo card_type daquela skin esta colado
      and not exists (
        select 1 from public.card_types ct
        where ct.skin = ap.skin_filter
          and not exists (select 1 from public.album_colagem ac
                          where ac.player_id = v_uid and ac.card_type_id = ct.id))
  loop
    insert into public.album_page_rewards (player_id, album_page_id) values (v_uid, p.id);
    perform private.mover_baba(v_uid, v_val, 'pagina do album', p.title);
    v_pago := v_pago + v_val;
  end loop;

  return jsonb_build_object('creditado', v_pago,
    'saldo', (select baba from public.players where id = v_uid));
end;
$$;

-- ================================================================ verify_copy
-- Spec §14: rota publica /v/<codigo>, sem auth. Mostra o dono ATUAL.
create or replace function public.verify_copy(p_codigo text)
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select jsonb_build_object(
    'verify_code', cc.verify_code,
    'personagem', ch.name,
    'personagem_slug', ch.slug,
    'skin', ct.skin,
    'tier', ct.tier,
    'print_run', ct.print_run,
    'serial_number', cc.serial_number,
    'origin', cc.origin,
    'forge_index', cc.forge_index,
    'seal', cc.seal,
    'damage_level', cc.damage_level,
    'dono', p.nickname,
    'desde', cc.claimed_at,
    'estreia_por', (select p2.nickname from public.players p2 where p2.id = cc.first_discovered_by),
    'estreia_em', cc.first_discovered_at
  )
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  join public.characters ch on ch.id = ct.character_id
  left join public.players p on p.id = cc.owner_id
  where upper(cc.verify_code) = upper(p_codigo);
$$;

-- ================================================================ permissoes
do $$
declare f text;
begin
  foreach f in array array[
    'forge(bigint[])', 'vender(bigint)', 'restaurar(bigint)',
    'comprar_pacote(text,int)', 'conferir_bonus_album()'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
    execute format('alter function public.%s owner to postgres', f);
  end loop;

  -- verify_copy e PUBLICA e sem auth (spec §9)
  execute 'revoke all on function public.verify_copy(text) from public';
  execute 'grant execute on function public.verify_copy(text) to anon, authenticated';
  execute 'alter function public.verify_copy(text) owner to postgres';
end $$;


-- ===== 20260822160000_fase7_diario.sql =====
-- BELESMA figurinhas - Fase 7: diario, streak de login e bonus de troca
-- (spec secoes 8 e 19.3)

-- ================================================================ claim_daily
-- Spec §8: a cada 24h credita 2 Comuns + 1 Raro. A cada TERCEIRO resgate,
-- credita tambem 1 Ultra.
--
-- O ciclo do Ultra conta RESGATES, nao calendario: quem pula um dia atrasa o
-- ciclo, nao o perde.
--
-- Junto vem o login diario da §19.3: +30 baba, +100 extra no setimo dia de
-- streak. O streak quebra se passar de 48h desde o ultimo resgate.
create or replace function public.claim_daily()
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  p            public.players;
  v_comuns     int;
  v_raros      int;
  v_ciclo      int;
  v_ultra      boolean;
  v_streak     int;
  v_bonus      int;
  v_extra      int := 0;
  v_espera     interval;
begin
  if auth.uid() is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select * into p from public.players where id = auth.uid() for update;
  if p.id is null then raise exception 'jogador nao encontrado'; end if;

  if p.last_daily_at is not null and p.last_daily_at > now() - interval '24 hours' then
    v_espera := (p.last_daily_at + interval '24 hours') - now();
    raise exception 'o diario volta em %', to_char(v_espera, 'HH24"h"MI"min"');
  end if;

  v_comuns := (select valor from public.pack_params where chave = 'diario_comuns')::int;
  v_raros  := (select valor from public.pack_params where chave = 'diario_raros')::int;
  v_ciclo  := (select valor from public.pack_params where chave = 'diario_ultra_ciclo')::int;

  -- streak: mantem se resgatou nas ultimas 48h, senao recomeca
  v_streak := case
    when p.last_daily_at is not null and p.last_daily_at > now() - interval '48 hours'
      then (p.dailies_claimed % 7) + 1
    else 1 end;

  v_ultra := (p.dailies_claimed + 1) % v_ciclo = 0;

  update public.players set
    packs_common_daily = packs_common_daily + v_comuns,
    packs_rare_daily   = packs_rare_daily   + v_raros,
    packs_ultra_daily  = packs_ultra_daily  + (case when v_ultra then 1 else 0 end),
    last_daily_at      = now(),
    dailies_claimed    = case
      when p.last_daily_at is not null and p.last_daily_at > now() - interval '48 hours'
        then dailies_claimed + 1
      else 1 end
  where id = p.id;

  v_bonus := (select valor from public.economy_config where chave = 'bonus_login')::int;
  if v_streak = 7 then
    v_extra := (select valor from public.economy_config where chave = 'bonus_login_streak7')::int;
  end if;
  perform private.mover_baba(p.id, v_bonus + v_extra, 'login diario',
                             'streak ' || v_streak::text);

  return jsonb_build_object(
    'comuns', v_comuns, 'raros', v_raros, 'ultra', v_ultra,
    'streak', v_streak, 'baba', v_bonus + v_extra,
    'proximo_ultra_em', case when v_ultra then v_ciclo else v_ciclo - ((p.dailies_claimed + 1) % v_ciclo) end);
end;
$$;

-- ================================================================ bonus de troca
-- Spec §19.3: +25 para os dois lados, 5 por dia, e SO quando a troca move
-- colecao de verdade.
--
-- Sem a trava a moeda vira impressora: dois amigos trocam as mesmas duas
-- cartas de ida e volta cinco vezes por dia e sacam 125 baba cada, do nada.
-- Por isso o par (jogadores, card_type) so paga uma vez na vida.
create or replace function private.pagar_troca(
  p_a uuid, p_b uuid, p_tipo_para_a int, p_tipo_para_b int)
returns void
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $$
declare
  v_val   int := (select valor from public.economy_config where chave = 'bonus_troca')::int;
  v_teto  int := (select valor from public.economy_config where chave = 'bonus_troca_max_dia')::int;
  v_menor uuid := least(p_a, p_b);
  v_maior uuid := greatest(p_a, p_b);
  v_hoje  int;
  v_tipo  int;
  v_quem  uuid;
begin
  foreach v_tipo in array array[p_tipo_para_a, p_tipo_para_b] loop
    v_quem := case when v_tipo = p_tipo_para_a then p_a else p_b end;
    continue when v_tipo is null;

    -- so paga se o par de jogadores nunca recebeu por este card_type
    if exists (select 1 from public.trade_rewards
               where player_a = v_menor and player_b = v_maior and card_type_id = v_tipo) then
      continue;
    end if;

    select count(*) into v_hoje from public.baba_log
    where player_id = v_quem and motivo = 'troca concluida'
      and created_at > now() - interval '24 hours';
    continue when v_hoje >= v_teto;

    insert into public.trade_rewards (player_a, player_b, card_type_id)
    values (v_menor, v_maior, v_tipo)
    on conflict do nothing;

    perform private.mover_baba(v_quem, v_val, 'troca concluida', v_tipo::text);
  end loop;
end;
$$;

-- accept_trade passa a pagar o bonus. Recria inteira porque plpgsql nao
-- tem patch parcial.
create or replace function public.accept_trade(p_trade_id bigint)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  t     public.trades;
  v_de  uuid;
  v_para uuid;
  function_motivo text;
  v_tipo_ofer int;
  v_tipo_ped  int;
  v_novo_para_recebedor int;
  v_novo_para_propositor int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select * into t from public.trades where id = p_trade_id for update;
  if t.id is null then raise exception 'proposta nao existe'; end if;
  if t.to_player <> v_uid then raise exception 'essa proposta nao e sua' using errcode = '42501'; end if;
  if t.status <> 'pending' then raise exception 'essa proposta ja foi resolvida'; end if;

  if t.offered_copy_id is not null then
    select owner_id into v_de from public.card_copies
    where id = t.offered_copy_id and not burned for update;
    if v_de is distinct from t.from_player then
      function_motivo := 'a carta oferecida mudou de dono desde a proposta';
    end if;
  end if;

  if t.requested_copy_id is not null then
    select owner_id into v_para from public.card_copies
    where id = t.requested_copy_id and not burned for update;
    if v_para is distinct from t.to_player then
      function_motivo := 'a carta pedida mudou de dono desde a proposta';
    end if;
  end if;

  if function_motivo is null and t.offered_baba > 0
     and (select baba from public.players where id = t.from_player) < t.offered_baba then
    function_motivo := 'quem propos nao tem mais saldo para cobrir a oferta';
  end if;
  if function_motivo is null and t.requested_baba > 0
     and (select baba from public.players where id = t.to_player) < t.requested_baba then
    function_motivo := 'voce nao tem mais saldo para cobrir o pedido';
  end if;

  if function_motivo is not null then
    update public.trades set status = 'cancelled', resolved_at = now() where id = t.id;
    return jsonb_build_object('ok', false, 'motivo', function_motivo, 'trade_id', t.id);
  end if;

  -- Guarda ANTES de mover: o bonus so vale se o lado que recebe ficar com um
  -- card_type do qual tinha ZERO. Depois da troca ja tem 1 e a conta muda.
  select card_type_id into v_tipo_ofer from public.card_copies where id = t.offered_copy_id;
  select card_type_id into v_tipo_ped  from public.card_copies where id = t.requested_copy_id;

  v_novo_para_recebedor := case when v_tipo_ofer is not null and not exists (
    select 1 from public.card_copies where owner_id = t.to_player
      and card_type_id = v_tipo_ofer and not burned) then v_tipo_ofer end;
  v_novo_para_propositor := case when v_tipo_ped is not null and not exists (
    select 1 from public.card_copies where owner_id = t.from_player
      and card_type_id = v_tipo_ped and not burned) then v_tipo_ped end;

  if t.offered_copy_id is not null then
    update public.card_copies set owner_id = t.to_player, claimed_at = now()
    where id = t.offered_copy_id;
    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (t.offered_copy_id, t.from_player, t.to_player, 'trade');
  end if;

  if t.requested_copy_id is not null then
    update public.card_copies set owner_id = t.from_player, claimed_at = now()
    where id = t.requested_copy_id;
    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (t.requested_copy_id, t.to_player, t.from_player, 'trade');
  end if;

  if t.offered_baba > 0 then
    perform private.mover_baba(t.from_player, -t.offered_baba, 'troca', t.id::text);
    perform private.mover_baba(t.to_player,    t.offered_baba, 'troca', t.id::text);
  end if;
  if t.requested_baba > 0 then
    perform private.mover_baba(t.to_player,   -t.requested_baba, 'troca', t.id::text);
    perform private.mover_baba(t.from_player,  t.requested_baba, 'troca', t.id::text);
  end if;

  update public.trades set status = 'accepted', resolved_at = now() where id = t.id
  returning * into t;

  update public.trades set status = 'cancelled', resolved_at = now()
  where status = 'pending' and id <> t.id
    and (offered_copy_id   in (t.offered_copy_id, t.requested_copy_id)
      or requested_copy_id in (t.offered_copy_id, t.requested_copy_id));

  update public.players set
    showcase_1 = case when showcase_1 in (t.offered_copy_id, t.requested_copy_id) then null else showcase_1 end,
    showcase_2 = case when showcase_2 in (t.offered_copy_id, t.requested_copy_id) then null else showcase_2 end,
    showcase_3 = case when showcase_3 in (t.offered_copy_id, t.requested_copy_id) then null else showcase_3 end
  where id in (t.from_player, t.to_player);

  delete from public.album_colagem
  where copy_id in (t.offered_copy_id, t.requested_copy_id);

  -- bonus so quando a troca moveu colecao de verdade
  perform private.pagar_troca(t.to_player, t.from_player,
                              v_novo_para_recebedor, v_novo_para_propositor);

  return jsonb_build_object('ok', true, 'trade_id', t.id);
end;
$$;

-- ================================================================ estoque
-- Spec §8, cascata de esgotamento: o front precisa saber quando o pool esta
-- no fim para avisar com honestidade em vez de so entregar menos.
create or replace function public.estoque_publico()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select jsonb_build_object(
    'por_tier', coalesce(jsonb_agg(jsonb_build_object(
      'tier', x.tier, 'tier_order', x.tier_order,
      'disponiveis', x.disponiveis, 'total', x.total
    ) order by x.tier_order), '[]'::jsonb),
    'reserva_diaria', (select count(*) from public.card_copies
                       where reserved_for_daily and owner_id is null and not burned),
    'pool_base', (select count(*) from public.card_copies cc
                  join public.card_types ct on ct.id = cc.card_type_id
                  where ct.tier in ('comum','incomum')
                    and cc.owner_id is null and not cc.burned)
  )
  from (
    select t.slug as tier, t.tier_order,
           count(*) filter (where cc.owner_id is null and not cc.burned) as disponiveis,
           count(*) as total
    from public.tiers t
    join public.card_types ct on ct.tier = t.slug
    join public.card_copies cc on cc.card_type_id = ct.id
    group by t.slug, t.tier_order
  ) x;
$$;

do $$
declare f text;
begin
  foreach f in array array['claim_daily()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
    execute format('alter function public.%s owner to postgres', f);
  end loop;
  execute 'revoke all on function public.estoque_publico() from public';
  execute 'grant execute on function public.estoque_publico() to anon, authenticated';
  execute 'alter function public.estoque_publico() owner to postgres';
  execute 'alter function public.accept_trade(bigint) owner to postgres';
  execute 'grant execute on function public.accept_trade(bigint) to authenticated';
end $$;


-- ===== 20260822170000_indice_e_ranking.sql =====
-- BELESMA figurinhas - conserta a contagem de "distribuidas" e enriquece o
-- ranking da cacada de serial.

-- ================================================================ distribuidas
-- BUG: a contagem media "quantas estao com dono AGORA", mas a spec §11 pede
-- "quantas ja SAIRAM do total". Uma copia vendida volta ao pool com
-- owner_id null e sumia da conta - dava linha com estreia mundial creditada
-- e "0 de 250" ao lado, que e contraditorio.
--
-- "Ja saiu" agora e: tem dono, OU foi queimada, OU tem desgaste (so quem foi
-- vendida ganha), OU tem registro de pull/daily no historico. A condicao e
-- redundante de proposito: o historico de alguns jogadores foi perdido num
-- bug meu de script, e os outros criterios cobrem esse buraco.
create or replace function public.global_index()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare v jsonb;
begin
  with tipos as (
    select ct.id, ct.character_id, ct.skin, ct.tier, ct.tier_order, ct.print_run,
           count(*) filter (
             where cc.origin = 'pull' and (
               cc.owner_id is not null
               or cc.burned
               or cc.damage_level > 0
               or exists (select 1 from public.copy_history h
                          where h.copy_id = cc.id and h.kind in ('pull','daily'))
             ))                                                               as distribuidas,
           bool_or(cc.first_discovered_at is not null and cc.origin = 'pull') as descoberto,
           min(cc.first_discovered_at) filter (where cc.origin = 'pull')      as em,
           (select p.nickname from public.card_copies c2
            join public.players p on p.id = c2.first_discovered_by
            where c2.card_type_id = ct.id and c2.origin = 'pull'
              and c2.first_discovered_at is not null
            order by c2.first_discovered_at limit 1)                          as primeiro
    from public.card_types ct
    left join public.card_copies cc on cc.card_type_id = ct.id
    group by ct.id
  )
  select jsonb_build_object(
    'personagens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', ch.slug, 'nome', ch.name, 'display_order', ch.display_order,
        'descoberto', (select bool_or(t.descoberto) from tipos t where t.character_id = ch.id),
        'tipos', (select jsonb_agg(jsonb_build_object(
                    'skin', t.skin, 'tier', t.tier, 'tier_order', t.tier_order,
                    'print_run', t.print_run, 'distribuidas', t.distribuidas,
                    'descoberto', t.descoberto, 'primeiro', t.primeiro, 'em', t.em)
                    order by t.tier_order, t.skin)
                  from tipos t where t.character_id = ch.id)
      ) order by ch.display_order)
      from public.characters ch), '[]'::jsonb),
    'descobertos', (select count(distinct t.character_id) from tipos t where t.descoberto),
    'total_personagens', (select count(*) from public.characters)
  ) into v;
  return v;
end;
$$;

-- ================================================================ ranking
-- Agora devolve as MELHORES cartas de cada um, com copy_id, para a tela
-- poder mostrar a figurinha e abrir em tela cheia.
create or replace function public.ranking_serial()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'nickname', p.nickname,
    'copias', x.copias,
    'selos', x.selos,
    'unos', x.unos,
    'melhor_serial', x.melhor_serial,
    'destaques', (
      -- as 6 melhores: primeiro tier, depois selo, depois menor serial
      select coalesce(jsonb_agg(jsonb_build_object(
        'copy_id', d.id, 'serial_number', d.serial_number, 'print_run', d.print_run,
        'seal', d.seal, 'origin', d.origin, 'forge_index', d.forge_index,
        'damage_level', d.damage_level, 'verify_code', d.verify_code,
        'card_type_id', d.card_type_id,
        'tier', d.tier, 'tier_order', d.tier_order, 'skin', d.skin,
        'character_slug', d.slug, 'character_name', d.name) order by d.rn), '[]'::jsonb)
      from (
        select cc.id, cc.serial_number, ct.print_run, cc.seal, cc.origin, cc.forge_index,
               cc.damage_level, cc.verify_code, cc.card_type_id,
               ct.tier, ct.tier_order, ct.skin, ch.slug, ch.name,
               row_number() over (
                 order by ct.tier_order desc,
                          (cc.seal <> 'none') desc,
                          cc.serial_number) as rn
        from public.card_copies cc
        join public.card_types ct on ct.id = cc.card_type_id
        join public.characters ch on ch.id = ct.character_id
        where cc.owner_id = x.owner_id and not cc.burned
      ) d where d.rn <= 6)
  ) order by x.selos desc, x.melhor_serial), '[]'::jsonb)
  from (
    select cc.owner_id,
           count(*) as copias,
           count(*) filter (where cc.seal <> 'none') as selos,
           count(*) filter (where cc.serial_number = 1) as unos,
           min(cc.serial_number) as melhor_serial
    from public.card_copies cc
    where cc.owner_id is not null and not cc.burned
    group by cc.owner_id
  ) x
  join public.players p on p.id = x.owner_id;
$$;

alter function public.global_index()  owner to postgres;
alter function public.ranking_serial() owner to postgres;
grant execute on function public.global_index()  to anon, authenticated;
grant execute on function public.ranking_serial() to anon, authenticated;


-- ===== 20260822180000_admin_extras.sql =====
-- BELESMA figurinhas - ferramentas administrativas adicionais (spec §18)
--
-- Tudo aqui e security definer com private.require_admin() por dentro, e
-- grava em admin_log. Nenhuma delas apaga card_types nem characters.

-- ---------------------------------------------------------------- dar baba
-- A moeda so nasce por regra do jogo (venda, album, estreia, troca, login).
-- Isto e a valvula do operador: creditar ou debitar na mao, com motivo, e
-- SEMPRE aparecendo no extrato do jogador.
create or replace function public.admin_dar_baba(p_target text, p_delta int, p_motivo text)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_n int := 0; p record;
begin
  perform private.require_admin();
  if p_delta = 0 then raise exception 'delta zero nao faz nada'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'diga o motivo'; end if;

  for p in select id, baba from public.players
           where p_target = 'todos' or nickname = p_target::extensions.citext loop
    -- o CHECK (baba >= 0) recusaria o debito; corta no zero em vez de estourar
    perform private.mover_baba(p.id, greatest(p_delta, -p.baba), 'admin: ' || p_motivo, null);
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then raise exception 'ninguem encontrado para %', p_target; end if;
  perform private.registrar('admin_dar_baba', p_target,
    jsonb_build_object('delta', p_delta, 'motivo', p_motivo, 'jogadores', v_n));
  return v_n;
end;
$$;

-- ---------------------------------------------------------------- extrato
create or replace function public.admin_extrato(p_nickname text)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id uuid;
begin
  perform private.require_admin();
  select id into v_id from public.players where nickname = p_nickname::extensions.citext;
  if v_id is null then raise exception 'jogador nao encontrado'; end if;

  return jsonb_build_object(
    'saldo', (select baba from public.players where id = v_id),
    'lancamentos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'delta', b.delta, 'motivo', b.motivo, 'ref', b.ref_id, 'em', b.created_at)
        order by b.id desc)
      from (select * from public.baba_log where player_id = v_id
            order by id desc limit 100) b), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------- acervo
create or replace function public.admin_acervo(p_nickname text)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id uuid;
begin
  perform private.require_admin();
  select id into v_id from public.players where nickname = p_nickname::extensions.citext;
  if v_id is null then raise exception 'jogador nao encontrado'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'tier', ct.tier, 'tier_order', ct.tier_order, 'skin', ct.skin,
      'personagem', ch.slug, 'serial', cc.serial_number, 'print_run', ct.print_run,
      'seal', cc.seal, 'origin', cc.origin, 'forge_index', cc.forge_index,
      'damage_level', cc.damage_level, 'verify_code', cc.verify_code)
      order by ct.tier_order desc, ch.slug, ct.skin)
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.characters ch on ch.id = ct.character_id
    where cc.owner_id = v_id and not cc.burned), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------- auditoria do sorteio
-- Compara a distribuicao REAL do slot de hit com a tabela de pack_config.
-- E o unico jeito de descobrir que as odds sairam do lugar sem ninguem ver.
create or replace function public.admin_auditoria_sorteio()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  return jsonb_build_object(
    'aberturas', (select count(*) from public.pack_openings),
    'cartas', (select count(*) from public.pack_opening_cards),
    'variancia', jsonb_build_object(
      'quente',   (select count(*) filter (where hot)   from public.pack_openings),
      'bonus',    (select count(*) filter (where bonus) from public.pack_openings),
      'pity',     (select count(*) filter (where pity)  from public.pack_openings),
      'promovidos', (select coalesce(sum(promoted_slots), 0) from public.pack_openings)),
    'hit_por_tier', coalesce((
      select jsonb_agg(jsonb_build_object(
        'pack_type', x.pack_type, 'tier', x.tier, 'saiu', x.n,
        'observado_pct', round(100.0 * x.n / nullif(x.total, 0), 2),
        'esperado_pct', x.peso)
        order by x.pack_type, x.esperado_desc)
      from (
        select o.pack_type::text as pack_type, poc.tier, count(*) as n,
               sum(count(*)) over (partition by o.pack_type) as total,
               max(pc.weight) as peso,
               max(t.tier_order) as esperado_desc
        from public.pack_opening_cards poc
        join public.pack_openings o on o.id = poc.opening_id
        join public.tiers t on t.slug = poc.tier
        left join public.pack_config pc
          on pc.pack_type = o.pack_type and pc.slot = 'hit' and pc.tier = poc.tier
        where poc.from_hit_table and not poc.garantido
        group by o.pack_type, poc.tier
      ) x), '[]'::jsonb),
    -- a regra dura da §8, conferivel: zero e o unico valor aceitavel
    'diamante_prisma_em_slot_garantido', (
      select count(*) from public.pack_opening_cards
      where garantido and tier in ('diamante','prisma')));
end;
$$;

-- ---------------------------------------------------------------- album
create or replace function public.admin_descolar_album(p_nickname text)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id uuid; v_n int;
begin
  perform private.require_admin();
  select id into v_id from public.players where nickname = p_nickname::extensions.citext;
  if v_id is null then raise exception 'jogador nao encontrado'; end if;
  delete from public.album_colagem where player_id = v_id;
  get diagnostics v_n = row_count;
  perform private.registrar('admin_descolar_album', p_nickname, jsonb_build_object('descoladas', v_n));
  return v_n;
end;
$$;

-- ---------------------------------------------------------------- reserva
-- top_up_daily_reserve ja existe, mas so aceita um numero. Esta devolve o
-- quadro completo para o painel decidir quanto repor.
create or replace function public.admin_saude()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  return jsonb_build_object(
    'jogadores', (select count(*) from public.players),
    'copias_com_dono', (select count(*) from public.card_copies where owner_id is not null),
    'queimadas', (select count(*) from public.card_copies where burned),
    'forjadas', (select count(*) from public.card_copies where origin = 'forge'),
    'reserva_diaria', (select count(*) from public.card_copies
                       where reserved_for_daily and owner_id is null and not burned),
    'pool_base_livre', (select count(*) from public.card_copies cc
                        join public.card_types ct on ct.id = cc.card_type_id
                        where ct.tier in ('comum','incomum')
                          and cc.owner_id is null and not cc.burned
                          and not cc.reserved_for_daily),
    'baba_em_circulacao', (select coalesce(sum(baba), 0) from public.players),
    'trocas_pendentes', (select count(*) from public.trades where status = 'pending'),
    -- invariantes: qualquer numero diferente de zero aqui e bug
    'alertas', jsonb_build_object(
      'selos_fora_de_36_12_3', (
        select case when count(*) filter (where seal='branco') = 36
                     and count(*) filter (where seal='preto')  = 12
                     and count(*) filter (where seal='rosa')   = 3
               then 0 else 1 end from public.card_copies),
      'forjada_com_selo', (select count(*) from public.card_copies
                           where origin = 'forge' and seal <> 'none'),
      'forjada_com_serial', (select count(*) from public.card_copies
                             where origin = 'forge' and serial_number is not null),
      'serial_acima_da_tiragem', (select count(*) from public.card_copies cc
                                  join public.card_types ct on ct.id = cc.card_type_id
                                  where cc.serial_number > ct.print_run),
      'saldo_diferente_do_extrato', (
        select count(*) from public.players p
        where p.baba <> coalesce((select sum(delta) from public.baba_log b
                                  where b.player_id = p.id), 0))));
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_dar_baba(text,int,text)', 'admin_extrato(text)', 'admin_acervo(text)',
    'admin_auditoria_sorteio()', 'admin_descolar_album(text)', 'admin_saude()'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
    execute format('alter function public.%s owner to postgres', f);
  end loop;
end $$;


-- ===== 20260822190000_distribuidas_e_estreias.sql =====
-- BELESMA figurinhas - conserta de vez a contagem de "distribuidas" e limpa
-- as estreias fantasma.

-- ================================================================ distribuidas
-- A tentativa anterior somava varios sinais indiretos e ainda errava. O sinal
-- CERTO estava na frente o tempo todo: open_pack faz
--
--   first_discovered_at = coalesce(first_discovered_at, now())
--
-- por COPIA, nao por tipo. Entao toda copia que ja saiu de um pacote tem
-- first_discovered_at preenchido, e isso nunca e apagado - nem por venda, nem
-- por troca, nem por reset administrativo (a §18.2 e explicita: estreia
-- mundial e historia, nao posse).
--
-- E, portanto, a marca permanente de "esta copia ja saiu".
create or replace function public.global_index()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare v jsonb;
begin
  with tipos as (
    select ct.id, ct.character_id, ct.skin, ct.tier, ct.tier_order, ct.print_run,
           count(*) filter (
             where cc.origin = 'pull' and cc.first_discovered_at is not null)   as distribuidas,
           count(*) filter (
             where cc.origin = 'pull' and cc.owner_id is not null)              as em_maos,
           bool_or(cc.first_discovered_at is not null and cc.origin = 'pull')   as descoberto,
           min(cc.first_discovered_at) filter (where cc.origin = 'pull')        as em,
           (select p.nickname from public.card_copies c2
            join public.players p on p.id = c2.first_discovered_by
            where c2.card_type_id = ct.id and c2.origin = 'pull'
              and c2.first_discovered_at is not null
            order by c2.first_discovered_at limit 1)                            as primeiro
    from public.card_types ct
    left join public.card_copies cc on cc.card_type_id = ct.id
    group by ct.id
  )
  select jsonb_build_object(
    'personagens', coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', ch.slug, 'nome', ch.name, 'display_order', ch.display_order,
        'descoberto', (select bool_or(t.descoberto) from tipos t where t.character_id = ch.id),
        'tipos', (select jsonb_agg(jsonb_build_object(
                    'skin', t.skin, 'tier', t.tier, 'tier_order', t.tier_order,
                    'print_run', t.print_run, 'distribuidas', t.distribuidas,
                    'em_maos', t.em_maos,
                    'descoberto', t.descoberto, 'primeiro', t.primeiro, 'em', t.em)
                    order by t.tier_order, t.skin)
                  from tipos t where t.character_id = ch.id)
      ) order by ch.display_order)
      from public.characters ch), '[]'::jsonb),
    'descobertos', (select count(distinct t.character_id) from tipos t where t.descoberto),
    'total_personagens', (select count(*) from public.characters)
  ) into v;
  return v;
end;
$$;

alter function public.global_index() owner to postgres;
grant execute on function public.global_index() to anon, authenticated;

-- ================================================================ estreias fantasma
-- Os scripts de teste de concorrencia abriram pacotes em producao com
-- jogadores descartaveis. Ao apagar esses jogadores, o FK
-- first_discovered_by virou NULL (on delete set null), mas
-- first_discovered_at ficou - resultando em tipos marcados como DESCOBERTOS
-- sem ninguem creditado, roubando do grupo a chance de fazer a estreia.
--
-- Limpa so o caso inequivoco: descoberta sem descobridor E sem dono atual.
-- Copia descoberta por jogador que existe nao e tocada.
do $$
declare v_n int;
begin
  update public.card_copies
  set first_discovered_at = null
  where first_discovered_at is not null
    and first_discovered_by is null
    and owner_id is null
    and not burned;
  get diagnostics v_n = row_count;
  raise notice 'estreias fantasma limpas: %', v_n;
end $$;


-- ===== 20260822200000_ranking_criterios.sql =====
-- BELESMA figurinhas - criterios do ranking da cacada de serial
--
-- Chegou a existir aqui um multiplicador de venda por selo. Foi retirado: a
-- §19.4 diz "nunca vende copia selada" e continua valendo. O selo pontua no
-- ranking, que e onde ele deve valer - nao no caixa.

-- ================================================================ pontuacao
-- "A carta mais rara possivel" precisa de um criterio unico, senao cada
-- pessoa discute a sua. Este e o criterio, e ele esta a vista na tela:
--
--   raridade      tier_order (1 a 12), peso maior de todos
--   selo          rosa > preto > branco > nenhum
--   tiragem       quanto MENOR a tiragem, mais raro
--   serial        quanto MENOR o serial, mais cobicado; o 1/N vale extra
--   procedencia   puxada vale mais que forjada (supply paralelo)
--   conservacao   desgaste tira ponto
--
-- Os pesos sao ordens de grandeza separadas de proposito: raridade nunca
-- perde para selo, selo nunca perde para serial. Assim o ranking nao inverte
-- por acaso quando alguem junta muitas cartas medianas.
create or replace function private.pontos_carta(
  p_tier_order smallint, p_seal public.seal_type, p_print_run int,
  p_serial int, p_origin public.copy_origin, p_damage int)
returns numeric
language sql immutable
as $$
  select
      p_tier_order * 1000000
    + (case p_seal when 'rosa' then 3 when 'preto' then 2 when 'branco' then 1 else 0 end) * 100000
    + (case when p_print_run > 0 then least(50000, 50000.0 / p_print_run) else 0 end)
    + (case when p_serial = 1 then 8000
            when p_serial is null then 0
            else greatest(0, 5000 - p_serial * 10) end)
    + (case when p_origin = 'pull' then 2000 else 0 end)
    - p_damage * 1500
$$;

create or replace function public.ranking_serial()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  with pontuadas as (
    select cc.id, cc.owner_id, cc.serial_number, cc.seal, cc.origin, cc.forge_index,
           cc.damage_level, cc.verify_code, cc.card_type_id,
           ct.print_run, ct.tier, ct.tier_order, ct.skin, ch.slug, ch.name,
           private.pontos_carta(ct.tier_order, cc.seal, ct.print_run,
                                cc.serial_number, cc.origin, cc.damage_level) as pontos
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.characters ch on ch.id = ct.character_id
    where cc.owner_id is not null and not cc.burned
  ),
  agregado as (
    select owner_id,
           count(*)                                            as copias,
           count(*) filter (where seal <> 'none')               as selos,
           count(*) filter (where serial_number = 1)            as unos,
           min(serial_number) filter (where origin = 'pull')    as melhor_serial,
           max(tier_order)                                      as melhor_tier,
           round(sum(pontos) / 1000000.0, 1)                    as pontos_total
    from pontuadas group by owner_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'nickname', p.nickname,
    'copias', a.copias, 'selos', a.selos, 'unos', a.unos,
    'melhor_serial', a.melhor_serial,
    'pontos', a.pontos_total,

    -- os tres troféus, cada um com critério próprio e explícito
    'joia',   (select to_jsonb(x) from (
                select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                       damage_level, verify_code, card_type_id, tier, tier_order, skin,
                       slug as character_slug, name as character_name
                from pontuadas where owner_id = a.owner_id
                order by pontos desc limit 1) x),
    'menor_serial', (select to_jsonb(x) from (
                select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                       damage_level, verify_code, card_type_id, tier, tier_order, skin,
                       slug as character_slug, name as character_name
                from pontuadas where owner_id = a.owner_id and origin = 'pull'
                -- desempate: mesmo serial, ganha a de tiragem menor, depois a mais rara
                order by serial_number, print_run, tier_order desc limit 1) x),
    'melhor_selo', (select to_jsonb(x) from (
                select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                       damage_level, verify_code, card_type_id, tier, tier_order, skin,
                       slug as character_slug, name as character_name
                from pontuadas where owner_id = a.owner_id and seal <> 'none'
                order by case seal when 'rosa' then 3 when 'preto' then 2 else 1 end desc,
                         tier_order desc, serial_number limit 1) x),

    'destaques', (select coalesce(jsonb_agg(to_jsonb(x) order by x.pontos desc), '[]'::jsonb)
                  from (
                    select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                           damage_level, verify_code, card_type_id, tier, tier_order, skin,
                           slug as character_slug, name as character_name, pontos
                    from pontuadas where owner_id = a.owner_id
                    order by pontos desc limit 8) x)
  ) order by a.pontos_total desc), '[]'::jsonb)
  from agregado a join public.players p on p.id = a.owner_id;
$$;

alter function public.ranking_serial() owner to postgres;
grant execute on function public.ranking_serial() to anon, authenticated;


-- ===== 20260822210000_cascata_respeita_garantia.sql =====
-- BELESMA figurinhas - a cascata precisa respeitar a garantia do pacote
--
-- BUG: quando a tabela de hit inteira ficava sem estoque, o fallback
-- sorteava de QUALQUER tier com estoque - inclusive comum. Um pacote Ultra
-- podia entregar uma comum no slot de hit, quebrando "mitica ou melhor".
--
-- Medido com 1500 pacotes Ultra e o estoque alto esgotado: 120 pacotes
-- sairam abaixo da garantia e o qui-quadrado do slot de hit foi a 704.
--
-- A §8 diz "tier sem estoque desce um nivel e re-sorteia" e tambem que o
-- Raro garante epica+ e o Ultra garante mitica+. As duas frases so convivem
-- se a descida parar no piso da garantia. Abaixo dele o pacote sai MENOR e o
-- front avisa - que e a outra coisa que a §8 manda fazer.
create or replace function public.open_pack(pack_type text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid        uuid := auth.uid();
  v_jogador    public.players;
  v_tipo       public.pack_type := pack_type::public.pack_type;
  v_do_diario  boolean := false;

  v_quente     boolean := false;
  v_bonus      boolean := false;
  v_pity       boolean := false;
  v_promovidos int := 0;

  v_n_base     int;
  v_pity_lim   int;
  v_slots      int;
  v_i          int;
  v_tent       int;

  v_da_tabela  boolean;
  v_garantido  boolean;
  v_natural    boolean;
  v_tier       text;
  v_type_id    int;
  v_copy_id    bigint;
  v_reserva    boolean;

  v_tiers      text[];
  v_pesos      numeric[];
  v_idx        int;
  v_piso       smallint;
  v_piso_gar   smallint;      -- piso da GARANTIA do pacote

  v_usados     int[] := '{}';
  v_copias     bigint[] := '{}';
  v_tiers_saiu text[] := '{}';
  v_do_hit     boolean[] := '{}';
  v_garantidos boolean[] := '{}';

  v_abertura   bigint;
  v_ordem      int[];
  v_tmp        int;
  v_j          int;
  v_resultado  jsonb;
begin
  if v_uid is null then
    raise exception 'precisa estar logado' using errcode = '42501';
  end if;

  select * into v_jogador from public.players where id = v_uid for update;
  if not found then
    raise exception 'jogador nao encontrado' using errcode = '42501';
  end if;

  if v_tipo = 'comum' then
    if v_jogador.packs_common_daily > 0 then
      v_do_diario := true;
      update public.players set packs_common_daily = packs_common_daily - 1 where id = v_uid;
    elsif v_jogador.packs_common > 0 then
      update public.players set packs_common = packs_common - 1 where id = v_uid;
    else raise exception 'sem pacote comum'; end if;
  elsif v_tipo = 'raro' then
    if v_jogador.packs_rare_daily > 0 then
      v_do_diario := true;
      update public.players set packs_rare_daily = packs_rare_daily - 1 where id = v_uid;
    elsif v_jogador.packs_rare > 0 then
      update public.players set packs_rare = packs_rare - 1 where id = v_uid;
    else raise exception 'sem pacote raro'; end if;
  else
    if v_jogador.packs_ultra_daily > 0 then
      v_do_diario := true;
      update public.players set packs_ultra_daily = packs_ultra_daily - 1 where id = v_uid;
    elsif v_jogador.packs_ultra > 0 then
      update public.players set packs_ultra = packs_ultra - 1 where id = v_uid;
    else raise exception 'sem pacote ultra'; end if;
  end if;

  v_n_base   := (select valor from public.pack_params where chave = 'cartas_base')::int;
  v_pity_lim := (select valor from public.pack_params where chave = 'pity_limite')::int;

  -- O piso da garantia sai da PROPRIA tabela de odds: o menor tier que o
  -- pacote lista no slot de hit e a promessa que ele faz. Comum lista rara,
  -- Raro lista epica, Ultra lista mitica. Nada de constante no codigo.
  select min(t.tier_order) into v_piso_gar
  from public.pack_config pc join public.tiers t on t.slug = pc.tier
  where pc.pack_type = v_tipo and pc.slot = 'hit' and pc.weight > 0;

  v_quente := private.random_int(100000) <
              (select valor from public.pack_params where chave = 'pacote_quente')::numeric * 100000;
  v_bonus  := private.random_int(100000) <
              (select valor from public.pack_params where chave = 'carta_bonus')::numeric * 100000;
  v_pity   := v_tipo = 'comum' and v_jogador.pity_counter >= v_pity_lim;

  v_slots := v_n_base + 1 + (case when v_bonus then 1 else 0 end);

  for v_i in 1 .. v_slots loop
    -- o slot de hit "de fabrica" e o unico que carrega a garantia; os outros
    -- so viram hit por bonus (quente ou promocao) e podem ser rebaixados
    v_natural   := (v_i = v_n_base + 1);
    v_da_tabela := v_natural;
    v_garantido := false;

    if v_quente then
      v_da_tabela := true;
      v_garantido := true;
    elsif not v_da_tabela then
      if private.random_int(100000) <
         (select valor from public.pack_params where chave = 'promocao_base')::numeric * 100000 then
        v_da_tabela := true;
        v_garantido := true;
        v_promovidos := v_promovidos + 1;
      end if;
    elsif v_pity then
      v_garantido := true;
    end if;

    loop
      v_piso := case
                  when v_pity and v_da_tabela then
                    (select tier_order from public.tiers where slug = 'epica')
                  else 0 end;

      select array_agg(x.tier order by x.tier_order), array_agg(x.weight order by x.tier_order)
        into v_tiers, v_pesos
      from (
        select pc.tier, t.tier_order, pc.weight
        from public.pack_config pc
        join public.tiers t on t.slug = pc.tier
        where pc.pack_type = v_tipo
          and pc.slot = (case when v_da_tabela then 'hit' else 'base' end)::public.pack_slot
          and pc.weight > 0
          and t.tier_order >= v_piso
          and not (v_garantido and t.slug in ('diamante','prisma'))
          and exists (
            select 1 from public.card_copies cc
            join public.card_types ct on ct.id = cc.card_type_id
            where ct.tier = pc.tier and cc.owner_id is null and not cc.burned
              and cc.reserved_for_daily = (v_do_diario and not v_da_tabela)
          )
      ) x;

      -- Cascata. Para o slot de HIT ela nao pode descer abaixo do piso da
      -- garantia: e melhor o pacote sair menor do que sair mentindo.
      if v_tiers is null then
        select array_agg(t.slug order by t.tier_order), array_agg(1::numeric)
          into v_tiers, v_pesos
        from public.tiers t
        where t.slug not in ('diamante','prisma')
          and (case when v_da_tabela then t.tier_order >= v_piso_gar else true end)
          and t.tier_order >= v_piso
          and exists (
            select 1 from public.card_copies cc
            join public.card_types ct on ct.id = cc.card_type_id
            where ct.tier = t.slug and cc.owner_id is null and not cc.burned
              and cc.reserved_for_daily = (v_do_diario and not v_da_tabela)
          );
      end if;

      exit when v_tiers is not null;

      -- Nada honra a promessa. Se o slot so era hit por BONUS (pacote quente
      -- ou promocao), o bonus e o que se perde: rebaixa para base e tenta de
      -- novo. Um pacote quente com o pool alto seco vira um pacote normal, e
      -- nao um pacote vazio - que era o que acontecia antes.
      exit when v_natural or not v_da_tabela;
      if not v_quente then v_promovidos := v_promovidos - 1; end if;
      v_da_tabela := false;
      v_garantido := false;
    end loop;

    -- so o slot de hit natural chega aqui vazio: o pacote sai curto
    continue when v_tiers is null;

    v_idx  := private.escolher_ponderado(v_pesos);
    v_tier := v_tiers[v_idx];
    v_reserva := (v_do_diario and not v_da_tabela);

    v_type_id := null;
    select x.id into v_type_id
    from (
      select ct.id,
             sum(count(*)) over () as total,
             count(*) as estoque,
             sum(count(*)) over (order by ct.id rows between unbounded preceding and current row) as ate_aqui
      from public.card_types ct
      join public.card_copies cc on cc.card_type_id = ct.id
      where ct.tier = v_tier and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
        and not (ct.id = any(v_usados))
      group by ct.id
    ) x
    where x.ate_aqui > (private.random_int(1000000)::numeric / 1000000) * x.total
    order by x.ate_aqui
    limit 1;

    if v_type_id is null then
      select ct.id into v_type_id
      from public.card_types ct
      join public.card_copies cc on cc.card_type_id = ct.id
      where ct.tier = v_tier and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
      group by ct.id
      order by extensions.gen_random_bytes(8)
      limit 1;
    end if;
    continue when v_type_id is null;

    v_copy_id := null;
    for v_tent in 1 .. 5 loop
      select cc.id into v_copy_id
      from public.card_copies cc
      where cc.card_type_id = v_type_id
        and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
      order by extensions.gen_random_bytes(8)
      limit 1
      for update skip locked;
      exit when v_copy_id is not null;
    end loop;
    continue when v_copy_id is null;

    update public.card_copies
    set owner_id = v_uid,
        claimed_at = now(),
        first_discovered_at = coalesce(first_discovered_at, now()),
        first_discovered_by = coalesce(first_discovered_by, v_uid)
    where id = v_copy_id;

    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (v_copy_id, null, v_uid, case when v_do_diario then 'daily' else 'pull' end);

    v_usados     := v_usados     || v_type_id;
    v_copias     := v_copias     || v_copy_id;
    v_tiers_saiu := v_tiers_saiu || v_tier;
    v_do_hit     := v_do_hit     || v_da_tabela;
    v_garantidos := v_garantidos || v_garantido;
  end loop;

  if array_length(v_copias, 1) is null then
    raise exception 'sem estoque: nao foi possivel montar o pacote';
  end if;

  if v_tipo = 'comum' then
    if v_pity or exists (
      select 1 from unnest(v_tiers_saiu) s
      join public.tiers t on t.slug = s
      where t.tier_order > (select tier_order from public.tiers where slug = 'rara')
    ) then
      update public.players set pity_counter = 0 where id = v_uid;
    else
      update public.players set pity_counter = pity_counter + 1 where id = v_uid;
    end if;
  end if;

  v_ordem := array(select generate_series(1, array_length(v_copias, 1)));
  for v_i in reverse array_length(v_ordem, 1) .. 2 loop
    v_j := private.random_int(v_i) + 1;
    v_tmp := v_ordem[v_i]; v_ordem[v_i] := v_ordem[v_j]; v_ordem[v_j] := v_tmp;
  end loop;

  insert into public.pack_openings (player_id, pack_type, from_daily, promoted_slots, hot, pity, bonus)
  values (v_uid, v_tipo, v_do_diario, v_promovidos, v_quente, v_pity, v_bonus)
  returning id into v_abertura;

  for v_i in 1 .. array_length(v_copias, 1) loop
    insert into public.pack_opening_cards
      (opening_id, copy_id, slot_index, reveal_index, tier, from_hit_table, garantido)
    values
      (v_abertura, v_copias[v_i], v_i, array_position(v_ordem, v_i),
       v_tiers_saiu[v_i], v_do_hit[v_i], v_garantidos[v_i]);
  end loop;

  select jsonb_build_object(
    'abertura', v_abertura,
    'pack_type', v_tipo,
    'do_diario', v_do_diario,
    'quente', v_quente,
    'bonus', v_bonus,
    'pity', v_pity,
    'promovidos', v_promovidos,
    'esperado', v_slots,
    'cartas', coalesce(jsonb_agg(c order by c->>'reveal_index'), '[]'::jsonb)
  ) into v_resultado
  from (
    select jsonb_build_object(
      'copy_id', cc.id,
      'card_type_id', cc.card_type_id,
      'reveal_index', poc.reveal_index,
      'from_hit_table', poc.from_hit_table,
      'garantido', poc.garantido,
      'serial_number', cc.serial_number,
      'print_run', ct.print_run,
      'seal', cc.seal,
      'origin', cc.origin,
      'damage_level', cc.damage_level,
      'verify_code', cc.verify_code,
      'tier', ct.tier,
      'tier_order', ct.tier_order,
      'skin', ct.skin,
      'art_path', ct.art_path,
      'character_slug', ch.slug,
      'character_name', ch.name,
      'estreia_mundial', cc.first_discovered_by = v_uid and cc.first_discovered_at >= now() - interval '1 minute',
      'nova', not exists (
        select 1 from public.card_copies o
        where o.card_type_id = cc.card_type_id and o.owner_id = v_uid and o.id <> cc.id
      )
    ) as c
    from public.pack_opening_cards poc
    join public.card_copies cc on cc.id = poc.copy_id
    join public.card_types  ct on ct.id = cc.card_type_id
    join public.characters  ch on ch.id = ct.character_id
    where poc.opening_id = v_abertura
  ) t;

  return v_resultado;
end;
$$;

alter function public.open_pack(text) owner to postgres;
grant execute on function public.open_pack(text) to authenticated;


-- ===== 20260822220000_estreia_trofeus_reset.sql =====
-- BELESMA figurinhas - estreia por TIPO, trofeus do mundo, e reset de verdade

-- ================================================================ 1. estreia
-- BUG reportado: toda carta saia marcada como ESTREIA MUNDIAL, mesmo quando
-- o jogador ja tinha tres repetidas dela. Ver o comentario no jsonb abaixo.
create or replace function public.open_pack(pack_type text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid        uuid := auth.uid();
  v_jogador    public.players;
  v_tipo       public.pack_type := pack_type::public.pack_type;
  v_do_diario  boolean := false;

  v_quente     boolean := false;
  v_bonus      boolean := false;
  v_pity       boolean := false;
  v_promovidos int := 0;

  v_n_base     int;
  v_pity_lim   int;
  v_slots      int;
  v_i          int;
  v_tent       int;

  v_da_tabela  boolean;
  v_garantido  boolean;
  v_natural    boolean;
  v_tier       text;
  v_type_id    int;
  v_copy_id    bigint;
  v_reserva    boolean;

  v_tiers      text[];
  v_pesos      numeric[];
  v_idx        int;
  v_piso       smallint;
  v_piso_gar   smallint;      -- piso da GARANTIA do pacote

  v_usados     int[] := '{}';
  v_copias     bigint[] := '{}';
  v_tiers_saiu text[] := '{}';
  v_do_hit     boolean[] := '{}';
  v_garantidos boolean[] := '{}';

  v_abertura   bigint;
  v_ordem      int[];
  v_tmp        int;
  v_j          int;
  v_resultado  jsonb;
begin
  if v_uid is null then
    raise exception 'precisa estar logado' using errcode = '42501';
  end if;

  select * into v_jogador from public.players where id = v_uid for update;
  if not found then
    raise exception 'jogador nao encontrado' using errcode = '42501';
  end if;

  if v_tipo = 'comum' then
    if v_jogador.packs_common_daily > 0 then
      v_do_diario := true;
      update public.players set packs_common_daily = packs_common_daily - 1 where id = v_uid;
    elsif v_jogador.packs_common > 0 then
      update public.players set packs_common = packs_common - 1 where id = v_uid;
    else raise exception 'sem pacote comum'; end if;
  elsif v_tipo = 'raro' then
    if v_jogador.packs_rare_daily > 0 then
      v_do_diario := true;
      update public.players set packs_rare_daily = packs_rare_daily - 1 where id = v_uid;
    elsif v_jogador.packs_rare > 0 then
      update public.players set packs_rare = packs_rare - 1 where id = v_uid;
    else raise exception 'sem pacote raro'; end if;
  else
    if v_jogador.packs_ultra_daily > 0 then
      v_do_diario := true;
      update public.players set packs_ultra_daily = packs_ultra_daily - 1 where id = v_uid;
    elsif v_jogador.packs_ultra > 0 then
      update public.players set packs_ultra = packs_ultra - 1 where id = v_uid;
    else raise exception 'sem pacote ultra'; end if;
  end if;

  v_n_base   := (select valor from public.pack_params where chave = 'cartas_base')::int;
  v_pity_lim := (select valor from public.pack_params where chave = 'pity_limite')::int;

  -- O piso da garantia sai da PROPRIA tabela de odds: o menor tier que o
  -- pacote lista no slot de hit e a promessa que ele faz. Comum lista rara,
  -- Raro lista epica, Ultra lista mitica. Nada de constante no codigo.
  select min(t.tier_order) into v_piso_gar
  from public.pack_config pc join public.tiers t on t.slug = pc.tier
  where pc.pack_type = v_tipo and pc.slot = 'hit' and pc.weight > 0;

  v_quente := private.random_int(100000) <
              (select valor from public.pack_params where chave = 'pacote_quente')::numeric * 100000;
  v_bonus  := private.random_int(100000) <
              (select valor from public.pack_params where chave = 'carta_bonus')::numeric * 100000;
  v_pity   := v_tipo = 'comum' and v_jogador.pity_counter >= v_pity_lim;

  v_slots := v_n_base + 1 + (case when v_bonus then 1 else 0 end);

  for v_i in 1 .. v_slots loop
    -- o slot de hit "de fabrica" e o unico que carrega a garantia; os outros
    -- so viram hit por bonus (quente ou promocao) e podem ser rebaixados
    v_natural   := (v_i = v_n_base + 1);
    v_da_tabela := v_natural;
    v_garantido := false;

    if v_quente then
      v_da_tabela := true;
      v_garantido := true;
    elsif not v_da_tabela then
      if private.random_int(100000) <
         (select valor from public.pack_params where chave = 'promocao_base')::numeric * 100000 then
        v_da_tabela := true;
        v_garantido := true;
        v_promovidos := v_promovidos + 1;
      end if;
    elsif v_pity then
      v_garantido := true;
    end if;

    loop
      v_piso := case
                  when v_pity and v_da_tabela then
                    (select tier_order from public.tiers where slug = 'epica')
                  else 0 end;

      select array_agg(x.tier order by x.tier_order), array_agg(x.weight order by x.tier_order)
        into v_tiers, v_pesos
      from (
        select pc.tier, t.tier_order, pc.weight
        from public.pack_config pc
        join public.tiers t on t.slug = pc.tier
        where pc.pack_type = v_tipo
          and pc.slot = (case when v_da_tabela then 'hit' else 'base' end)::public.pack_slot
          and pc.weight > 0
          and t.tier_order >= v_piso
          and not (v_garantido and t.slug in ('diamante','prisma'))
          and exists (
            select 1 from public.card_copies cc
            join public.card_types ct on ct.id = cc.card_type_id
            where ct.tier = pc.tier and cc.owner_id is null and not cc.burned
              and cc.reserved_for_daily = (v_do_diario and not v_da_tabela)
          )
      ) x;

      -- Cascata. Para o slot de HIT ela nao pode descer abaixo do piso da
      -- garantia: e melhor o pacote sair menor do que sair mentindo.
      if v_tiers is null then
        select array_agg(t.slug order by t.tier_order), array_agg(1::numeric)
          into v_tiers, v_pesos
        from public.tiers t
        where t.slug not in ('diamante','prisma')
          and (case when v_da_tabela then t.tier_order >= v_piso_gar else true end)
          and t.tier_order >= v_piso
          and exists (
            select 1 from public.card_copies cc
            join public.card_types ct on ct.id = cc.card_type_id
            where ct.tier = t.slug and cc.owner_id is null and not cc.burned
              and cc.reserved_for_daily = (v_do_diario and not v_da_tabela)
          );
      end if;

      exit when v_tiers is not null;

      -- Nada honra a promessa. Se o slot so era hit por BONUS (pacote quente
      -- ou promocao), o bonus e o que se perde: rebaixa para base e tenta de
      -- novo. Um pacote quente com o pool alto seco vira um pacote normal, e
      -- nao um pacote vazio - que era o que acontecia antes.
      exit when v_natural or not v_da_tabela;
      if not v_quente then v_promovidos := v_promovidos - 1; end if;
      v_da_tabela := false;
      v_garantido := false;
    end loop;

    -- so o slot de hit natural chega aqui vazio: o pacote sai curto
    continue when v_tiers is null;

    v_idx  := private.escolher_ponderado(v_pesos);
    v_tier := v_tiers[v_idx];
    v_reserva := (v_do_diario and not v_da_tabela);

    v_type_id := null;
    select x.id into v_type_id
    from (
      select ct.id,
             sum(count(*)) over () as total,
             count(*) as estoque,
             sum(count(*)) over (order by ct.id rows between unbounded preceding and current row) as ate_aqui
      from public.card_types ct
      join public.card_copies cc on cc.card_type_id = ct.id
      where ct.tier = v_tier and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
        and not (ct.id = any(v_usados))
      group by ct.id
    ) x
    where x.ate_aqui > (private.random_int(1000000)::numeric / 1000000) * x.total
    order by x.ate_aqui
    limit 1;

    if v_type_id is null then
      select ct.id into v_type_id
      from public.card_types ct
      join public.card_copies cc on cc.card_type_id = ct.id
      where ct.tier = v_tier and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
      group by ct.id
      order by extensions.gen_random_bytes(8)
      limit 1;
    end if;
    continue when v_type_id is null;

    v_copy_id := null;
    for v_tent in 1 .. 5 loop
      select cc.id into v_copy_id
      from public.card_copies cc
      where cc.card_type_id = v_type_id
        and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
      order by extensions.gen_random_bytes(8)
      limit 1
      for update skip locked;
      exit when v_copy_id is not null;
    end loop;
    continue when v_copy_id is null;

    update public.card_copies
    set owner_id = v_uid,
        claimed_at = now(),
        first_discovered_at = coalesce(first_discovered_at, now()),
        first_discovered_by = coalesce(first_discovered_by, v_uid)
    where id = v_copy_id;

    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (v_copy_id, null, v_uid, case when v_do_diario then 'daily' else 'pull' end);

    v_usados     := v_usados     || v_type_id;
    v_copias     := v_copias     || v_copy_id;
    v_tiers_saiu := v_tiers_saiu || v_tier;
    v_do_hit     := v_do_hit     || v_da_tabela;
    v_garantidos := v_garantidos || v_garantido;
  end loop;

  if array_length(v_copias, 1) is null then
    raise exception 'sem estoque: nao foi possivel montar o pacote';
  end if;

  if v_tipo = 'comum' then
    if v_pity or exists (
      select 1 from unnest(v_tiers_saiu) s
      join public.tiers t on t.slug = s
      where t.tier_order > (select tier_order from public.tiers where slug = 'rara')
    ) then
      update public.players set pity_counter = 0 where id = v_uid;
    else
      update public.players set pity_counter = pity_counter + 1 where id = v_uid;
    end if;
  end if;

  v_ordem := array(select generate_series(1, array_length(v_copias, 1)));
  for v_i in reverse array_length(v_ordem, 1) .. 2 loop
    v_j := private.random_int(v_i) + 1;
    v_tmp := v_ordem[v_i]; v_ordem[v_i] := v_ordem[v_j]; v_ordem[v_j] := v_tmp;
  end loop;

  insert into public.pack_openings (player_id, pack_type, from_daily, promoted_slots, hot, pity, bonus)
  values (v_uid, v_tipo, v_do_diario, v_promovidos, v_quente, v_pity, v_bonus)
  returning id into v_abertura;

  for v_i in 1 .. array_length(v_copias, 1) loop
    insert into public.pack_opening_cards
      (opening_id, copy_id, slot_index, reveal_index, tier, from_hit_table, garantido)
    values
      (v_abertura, v_copias[v_i], v_i, array_position(v_ordem, v_i),
       v_tiers_saiu[v_i], v_do_hit[v_i], v_garantidos[v_i]);
  end loop;

  select jsonb_build_object(
    'abertura', v_abertura,
    'pack_type', v_tipo,
    'do_diario', v_do_diario,
    'quente', v_quente,
    'bonus', v_bonus,
    'pity', v_pity,
    'promovidos', v_promovidos,
    'esperado', v_slots,
    'cartas', coalesce(jsonb_agg(c order by c->>'reveal_index'), '[]'::jsonb)
  ) into v_resultado
  from (
    select jsonb_build_object(
      'copy_id', cc.id,
      'card_type_id', cc.card_type_id,
      'reveal_index', poc.reveal_index,
      'from_hit_table', poc.from_hit_table,
      'garantido', poc.garantido,
      'serial_number', cc.serial_number,
      'print_run', ct.print_run,
      'seal', cc.seal,
      'origin', cc.origin,
      'damage_level', cc.damage_level,
      'verify_code', cc.verify_code,
      'tier', ct.tier,
      'tier_order', ct.tier_order,
      'skin', ct.skin,
      'art_path', ct.art_path,
      'character_slug', ch.slug,
      'character_name', ch.name,
      -- Estreia mundial e do TIPO, nao da COPIA.
      --
      -- first_discovered_at existe por copia: puxar a copia 47/250 de um
      -- tipo que ja circula ha semanas gravava a data NELA pela primeira
      -- vez, e a versao anterior lia isso como estreia. Resultado: toda
      -- carta do pacote saia com a faixa, ate as que o jogador ja tinha
      -- repetida. Agora so e estreia se nenhuma outra copia do mesmo tipo
      -- saiu antes.
      'estreia_mundial',
          cc.first_discovered_by = v_uid
          and cc.first_discovered_at >= now() - interval '1 minute'
          and not exists (
            select 1 from public.card_copies anterior
            where anterior.card_type_id = cc.card_type_id
              and anterior.id <> cc.id
              and anterior.first_discovered_at is not null
              and anterior.first_discovered_at < cc.first_discovered_at
          ),
      'nova', not exists (
        select 1 from public.card_copies o
        where o.card_type_id = cc.card_type_id and o.owner_id = v_uid and o.id <> cc.id
      )
    ) as c
    from public.pack_opening_cards poc
    join public.card_copies cc on cc.id = poc.copy_id
    join public.card_types  ct on ct.id = cc.card_type_id
    join public.characters  ch on ch.id = ct.character_id
    where poc.opening_id = v_abertura
  ) t;

  return v_resultado;
end;
$$;

alter function public.open_pack(text) owner to postgres;
grant execute on function public.open_pack(text) to authenticated;

-- ================================================================ 2. trofeus do mundo
-- Os tres trofeus do SERVIDOR, com o dono de cada um.
--
-- Mesmos criterios da versao por jogador (private.pontos_carta): se o
-- criterio fosse outro aqui, o campeao do servidor poderia nao ser campeao
-- de ninguem, e o ranking viraria discussao.
create or replace function public.trofeus_do_mundo()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  with pontuadas as (
    select cc.id as copy_id, cc.serial_number, cc.seal, cc.origin, cc.forge_index,
           cc.damage_level, cc.verify_code, cc.card_type_id,
           ct.print_run, ct.tier, ct.tier_order, ct.skin,
           ch.slug as character_slug, ch.name as character_name,
           p.nickname as dono,
           private.pontos_carta(ct.tier_order, cc.seal, ct.print_run,
                                cc.serial_number, cc.origin, cc.damage_level) as pontos
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.characters ch on ch.id = ct.character_id
    join public.players p on p.id = cc.owner_id
    where cc.owner_id is not null and not cc.burned
  )
  select jsonb_build_object(
    'joia', (select to_jsonb(x) from (
              select * from pontuadas order by pontos desc, copy_id limit 1) x),
    'menor_serial', (select to_jsonb(x) from (
              select * from pontuadas where origin = 'pull'
              -- desempate: mesmo serial, ganha a de tiragem menor, depois a mais rara
              order by serial_number, print_run, tier_order desc, copy_id limit 1) x),
    'melhor_selo', (select to_jsonb(x) from (
              select * from pontuadas where seal <> 'none'
              order by case seal when 'rosa' then 3 when 'preto' then 2 else 1 end desc,
                       tier_order desc, serial_number, copy_id limit 1) x),
    'em_jogo', (select count(*) from pontuadas),
    'donos',   (select count(distinct dono) from pontuadas)
  );
$$;

alter function public.trofeus_do_mundo() owner to postgres;
grant execute on function public.trofeus_do_mundo() to anon, authenticated;

-- ================================================================ 3. recomecar do zero
-- O admin_reset_all_collections devolve as cartas ao pool e para por ai:
-- booster, baba, desgaste, estreia mundial, album e historico ficam todos de
-- pe. Serve para redistribuir o acervo, nao para recomecar.
--
-- Este aqui recomeca de verdade: depois dele o mundo esta como no dia da
-- estreia, com uma excecao deliberada - o admin_log NAO e apagado. Ele e o
-- registro de quem mexeu no que (§18), e um reset que apaga o proprio
-- rastro nao e auditavel. O reset fica gravado la.
--
-- O que NAO muda porque nao e estado de jogo: os selos continuam nas mesmas
-- copias (36 brancos, 12 pretos, 3 rosas), o seal_audit continua provando
-- como foram sorteados, e o nickname_history continua.
create or replace function public.admin_recomecar_do_zero(p_confirmacao text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_forjadas   int;
  v_devolvidas int;
  v_jogadores  int;
  v_estreias   int;
  v_ch         record;
begin
  perform private.require_admin();
  if p_confirmacao <> 'RECOMECAR DO ZERO' then
    raise exception 'confirmacao invalida: digite RECOMECAR DO ZERO';
  end if;

  -- ------------------------------------------------------------ historico
  --
  -- `where true` em tudo aqui NAO e enfeite: o Supabase liga o safeupdate
  -- (supautils), que recusa DELETE e UPDATE sem clausula WHERE com
  -- "DELETE requires a WHERE clause". Vale para security definer tambem,
  -- porque a trava e da sessao, nao do dono da funcao. Sem isto a funcao
  -- roda no PGlite e falha no Supabase - foi exatamente o que aconteceu.
  --
  -- Nao remover "porque nao filtra nada". Ele filtra: declara que apagar
  -- tudo e intencional.
  delete from public.trades           where true;
  delete from public.trade_rewards    where true;
  delete from public.album_colagem    where true;
  delete from public.pack_opening_cards where true;
  delete from public.pack_openings    where true;
  delete from public.copy_history     where true;
  delete from public.baba_log         where true;

  -- ------------------------------------------------------------ acervo
  -- Forjada nao existe no mundo do dia zero: ela e supply criado por
  -- jogador. Some de vez, nao volta ao pool.
  delete from public.card_copies where origin = 'forge';
  get diagnostics v_forjadas = row_count;

  select count(*) into v_estreias
  from public.card_copies where first_discovered_at is not null;

  update public.card_copies
  set owner_id = null,
      claimed_at = null,
      burned = false,
      damage_level = 0,
      first_discovered_at = null,
      first_discovered_by = null,
      reserved_for_daily = false
  where true;                                   -- safeupdate, ver acima
  get diagnostics v_devolvidas = row_count;

  -- ------------------------------------------------------------ jogadores
  update public.players set
    packs_common       = (select valor from public.pack_params where chave = 'allotment_comum')::int,
    packs_rare         = (select valor from public.pack_params where chave = 'allotment_raro')::int,
    packs_ultra        = (select valor from public.pack_params where chave = 'allotment_ultra')::int,
    packs_common_daily = 0,
    packs_rare_daily   = 0,
    packs_ultra_daily  = 0,
    baba               = 0,
    pity_counter       = 0,
    dailies_claimed    = 0,
    last_daily_at      = null,
    showcase_1 = null, showcase_2 = null, showcase_3 = null
  where true;                                   -- safeupdate, ver acima
  get diagnostics v_jogadores = row_count;

  -- ------------------------------------------------------------ reserva diaria
  -- Zerada junto com o resto acima; refeita aqui com o mesmo alvo do seed.
  for v_ch in select id from public.characters order by id loop
    perform private.reservar_diario(v_ch.id, 500);
  end loop;

  perform private.registrar('admin_recomecar_do_zero', 'mundo',
    jsonb_build_object('forjadas_apagadas', v_forjadas,
                       'copias_devolvidas', v_devolvidas,
                       'estreias_apagadas', v_estreias,
                       'jogadores_zerados', v_jogadores));

  return jsonb_build_object(
    'forjadas_apagadas', v_forjadas,
    'copias_devolvidas', v_devolvidas,
    'estreias_apagadas', v_estreias,
    'jogadores_zerados', v_jogadores,
    'reservadas_para_diario',
      (select count(*) from public.card_copies where reserved_for_daily));
end;
$$;

alter function public.admin_recomecar_do_zero(text) owner to postgres;
grant execute on function public.admin_recomecar_do_zero(text) to authenticated;


-- ===== 20260822230000_fechar_grant_residual.sql =====
-- BELESMA figurinhas - fecha o GRANT automatico para PUBLIC

-- O Postgres da EXECUTE a PUBLIC em toda funcao criada, sem pedir. A
-- migracao de RLS revoga isso em massa, mas ela roda ANTES das migracoes que
-- criam funcoes novas - entao cada funcao adicionada depois nasce aberta de
-- novo. Auditoria no banco de producao achou 13 assim.
--
-- Nao era explorable hoje: o PostgREST so expoe o schema `public`, e as do
-- schema `private` nao tem rota. Mas `private.mover_baba` e literalmente
-- "credite baba nesta conta", e isso depender de uma opcao de configuracao
-- do PostgREST nao e defesa - e sorte.
--
-- Aqui a revogacao e por LOOP em vez de lista fixa, de proposito: lista fixa
-- envelhece na proxima funcao que alguem criar.
do $$
declare f record;
begin
  -- ------------------------------------------------------------- private
  -- Ninguem de fora chama nada do private. Os wrappers em public sao
  -- security definer e rodam como o dono, entao continuam enxergando tudo.
  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.assinatura);
  end loop;

  -- ------------------------------------------------------------- public
  -- Em public a regra e outra: revoga o implicito de PUBLIC e mantem so o
  -- que foi concedido de proposito a anon/authenticated.
  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and array_to_string(coalesce(p.proacl, '{}'), ',') like '=X/%'
  loop
    execute format('revoke all on function %s from public', f.assinatura);
  end loop;
end $$;

-- as que precisam continuar chamaveis
grant execute on function public.me()                                to authenticated;
grant execute on function public.sou_admin()                         to authenticated;
grant execute on function public.admin_recomecar_do_zero(text)       to authenticated;

-- ---------------------------------------------------------------- skins
-- Unica tabela de public sem RLS. Hoje nao vaza porque anon e authenticated
-- nao tem grant nenhum nela, mas "sem RLS + sem grant" e uma trava so; o
-- resto do schema tem duas. Ligar a RLS sem policy mantem o padrao do
-- projeto: nega tudo, e o acesso se abre ponto a ponto.
alter table public.skins enable row level security;


-- ===== 20260823100000_joia_por_escassez.sql =====
-- BELESMA figurinhas - "a joia" passa a medir escassez de verdade

-- ================================================================ por que
-- A versao anterior somava pesos que EU escolhi: raridade x 1.000.000, selo
-- x 100.000. Isso poe o selo a um decimo de um degrau de raridade, e a
-- consequencia foi medida no servidor: uma cosmica + selo branco, da qual
-- existe UMA no mundo inteiro, ficava atras de tres divinas, das quais
-- existem 29.
--
-- O erro de fundo foi tratar a escada de tiers como se ela ja medisse
-- escassez. Ela nao mede: o selo e um SEGUNDO eixo, e um selo cair numa
-- cosmica e muito mais improvavel do que cair numa comum, porque so existem
-- 90 cosmicas para ele cair e quase tres mil comuns. Censo do set:
--
--   divina + selo preto      1 copia      (esperava-se 0,054)
--   cosmica + selo branco    1            (esperava-se 0,49)
--   prisma                   3
--   diamante                 6
--   infernal                15
--   divina                  29
--
-- Agora o criterio nao tem peso nenhum inventado por mim: e a contagem.
-- "A joia e a carta com menos copias iguais no mundo." Uma frase, conferivel
-- por qualquer um, e que se ajusta sozinha quando o quarto personagem
-- entrar por seed_edition.
create or replace view private.censo_raridade as
select ct.tier, cc.seal, count(*)::int as copias
from public.card_copies cc
join public.card_types ct on ct.id = cc.card_type_id
where not cc.burned
group by 1, 2;

-- ================================================================ pontuacao
-- O primeiro termo domina por construcao: mesmo entre as classes mais
-- povoadas (rara com 1200 copias contra incomum com ~1300) a diferenca passa
-- de 60.000 pontos, e a soma de TODOS os desempates nao chega a 7.000. Logo
-- nenhum desempate inverte uma diferenca de escassez - eles so decidem
-- dentro da mesma classe.
drop function if exists private.pontos_carta(smallint, public.seal_type, int, int, public.copy_origin, int);

create or replace function private.pontos_carta(
  p_copias_iguais int,          -- do censo: quantas ha no mundo com este tier E este selo
  p_tier_order    smallint,
  p_serial        int,
  p_origin        public.copy_origin,
  p_damage        int)
returns numeric
language sql immutable
as $fn$
  select
      -- escassez: o eixo. Menos copias iguais, mais pontos.
      1000000000.0 / greatest(p_copias_iguais, 1)
      -- entre duas classes igualmente escassas, a mais alta na escada
    + p_tier_order * 500
      -- serial baixo, e o 1/N valendo extra
    + (case when p_serial = 1 then 400
            when p_serial is null then 0
            else greatest(0, 300 - p_serial) end)
      -- puxada vale mais que forjada: forja e supply paralelo
    + (case when p_origin = 'pull' then 200 else 0 end)
      -- conservacao
    - p_damage * 150
$fn$;

-- ================================================================ por jogador
create or replace function public.ranking_serial()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  with pontuadas as (
    select cc.id, cc.owner_id, cc.serial_number, cc.seal, cc.origin, cc.forge_index,
           cc.damage_level, cc.verify_code, cc.card_type_id,
           ct.print_run, ct.tier, ct.tier_order, ct.skin, ch.slug, ch.name,
           censo.copias as iguais_no_mundo,
           private.pontos_carta(censo.copias, ct.tier_order, cc.serial_number,
                                cc.origin, cc.damage_level) as pontos
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.characters ch on ch.id = ct.character_id
    join private.censo_raridade censo on censo.tier = ct.tier and censo.seal = cc.seal
    where cc.owner_id is not null and not cc.burned
  ),
  agregado as (
    select owner_id,
           count(*)                                            as copias,
           count(*) filter (where seal <> 'none')               as selos,
           count(*) filter (where serial_number = 1)            as unos,
           min(serial_number) filter (where origin = 'pull')    as melhor_serial,
           min(iguais_no_mundo)                                 as mais_escassa,
           round(sum(pontos) / 1000000.0, 1)                    as pontos_total
    from pontuadas group by owner_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'nickname', p.nickname,
    'copias', a.copias, 'selos', a.selos, 'unos', a.unos,
    'melhor_serial', a.melhor_serial,
    'mais_escassa', a.mais_escassa,
    'pontos', a.pontos_total,

    'joia',   (select to_jsonb(x) from (
                select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                       damage_level, verify_code, card_type_id, tier, tier_order, skin,
                       slug as character_slug, name as character_name, iguais_no_mundo
                from pontuadas where owner_id = a.owner_id
                order by pontos desc limit 1) x),
    'menor_serial', (select to_jsonb(x) from (
                select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                       damage_level, verify_code, card_type_id, tier, tier_order, skin,
                       slug as character_slug, name as character_name, iguais_no_mundo
                from pontuadas where owner_id = a.owner_id and origin = 'pull'
                order by serial_number, print_run, tier_order desc limit 1) x),
    'melhor_selo', (select to_jsonb(x) from (
                select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                       damage_level, verify_code, card_type_id, tier, tier_order, skin,
                       slug as character_slug, name as character_name, iguais_no_mundo
                from pontuadas where owner_id = a.owner_id and seal <> 'none'
                order by case seal when 'rosa' then 3 when 'preto' then 2 else 1 end desc,
                         tier_order desc, serial_number limit 1) x),

    'destaques', (select coalesce(jsonb_agg(to_jsonb(x) order by x.pontos desc), '[]'::jsonb)
                  from (
                    select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                           damage_level, verify_code, card_type_id, tier, tier_order, skin,
                           slug as character_slug, name as character_name,
                           iguais_no_mundo, pontos
                    from pontuadas where owner_id = a.owner_id
                    order by pontos desc limit 8) x)
  ) order by a.pontos_total desc), '[]'::jsonb)
  from agregado a join public.players p on p.id = a.owner_id;
$fn$;

-- ================================================================ do servidor
create or replace function public.trofeus_do_mundo()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  with pontuadas as (
    select cc.id as copy_id, cc.serial_number, cc.seal, cc.origin, cc.forge_index,
           cc.damage_level, cc.verify_code, cc.card_type_id,
           ct.print_run, ct.tier, ct.tier_order, ct.skin,
           ch.slug as character_slug, ch.name as character_name,
           p.nickname as dono,
           censo.copias as iguais_no_mundo,
           private.pontos_carta(censo.copias, ct.tier_order, cc.serial_number,
                                cc.origin, cc.damage_level) as pontos
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.characters ch on ch.id = ct.character_id
    join public.players p on p.id = cc.owner_id
    join private.censo_raridade censo on censo.tier = ct.tier and censo.seal = cc.seal
    where cc.owner_id is not null and not cc.burned
  )
  select jsonb_build_object(
    'joia', (select to_jsonb(x) from (
              select * from pontuadas order by pontos desc, copy_id limit 1) x),
    'menor_serial', (select to_jsonb(x) from (
              select * from pontuadas where origin = 'pull'
              order by serial_number, print_run, tier_order desc, copy_id limit 1) x),
    'melhor_selo', (select to_jsonb(x) from (
              select * from pontuadas where seal <> 'none'
              order by case seal when 'rosa' then 3 when 'preto' then 2 else 1 end desc,
                       tier_order desc, serial_number, copy_id limit 1) x),
    'em_jogo', (select count(*) from pontuadas),
    'donos',   (select count(distinct dono) from pontuadas)
  );
$fn$;

alter function public.ranking_serial()    owner to postgres;
alter function public.trofeus_do_mundo()  owner to postgres;
grant execute on function public.ranking_serial()   to anon, authenticated;
grant execute on function public.trofeus_do_mundo() to anon, authenticated;

-- o censo vive em private: ninguem de fora precisa da view crua
revoke all on private.censo_raridade from public, anon, authenticated;


-- ===== 20260823110000_reserva_diaria_e_grants.sql =====
-- BELESMA figurinhas - a reserva do diario vazava, e o grant residual voltou

-- ================================================================ 1. reserva
-- BUG: `private.reservar_diario` contava como reserva TODA copia com a flag
-- `reserved_for_daily`, inclusive as que ja tinham dono. Como o open_pack
-- nunca limpa a flag ao entregar a carta, cada carta de diario reclamada
-- continuava sendo contada como se ainda estivesse na prateleira.
--
-- Efeito: a reposicao achava a reserva cheia e nao repunha nada. Medido na
-- producao com 3 jogadores e poucos dias de jogo:
--
--   com a flag, nao queimadas .... 1488   <- o que a funcao contava
--   de fato disponiveis .......... 1472   <- o que existia para sortear
--   ja com dono .................. 16
--
-- 16 em poucos dias. A reserva e de 1500 e o consumo e de ~3 cartas por
-- jogador por dia; a conta errada vai drenando ate o diario nao ter mais de
-- onde sortear, e nada avisa.
--
-- A reserva e o conjunto de copias DISPONIVEIS e marcadas. Copia com dono
-- saiu da prateleira, mesmo que a flag continue nela - e a flag continua de
-- proposito, para que a copia volte para a reserva se for vendida.
create or replace function private.reservar_diario(p_character_id int, p_alvo int)
returns int
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  ja_tem int;
  faltam int;
begin
  select count(*) into ja_tem
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = p_character_id
    and cc.reserved_for_daily
    and not cc.burned
    and cc.owner_id is null;          -- <- o conserto

  faltam := p_alvo - ja_tem;
  if faltam <= 0 then return 0; end if;

  with candidatas as (
    select cc.id
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.tiers t on t.slug = ct.tier
    where ct.character_id = p_character_id
      and t.slug in ('comum','incomum')
      and cc.owner_id is null
      and not cc.burned
      and not cc.reserved_for_daily
    order by extensions.gen_random_bytes(8)
    limit faltam
  )
  update public.card_copies set reserved_for_daily = true
  where id in (select id from candidatas);

  return faltam;
end;
$fn$;

-- O top_up tinha a mesma conta errada no alvo que passa para a funcao.
create or replace function public.top_up_daily_reserve(p_n int)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_por_char int; v_total int := 0; v_c record;
begin
  perform private.require_admin();
  if p_n is null or p_n <= 0 then raise exception 'n invalido'; end if;

  v_por_char := ceil(p_n::numeric / greatest((select count(*) from public.characters), 1));
  for v_c in select id from public.characters order by id loop
    v_total := v_total + private.reservar_diario(v_c.id,
      (select count(*) from public.card_copies cc
       join public.card_types ct on ct.id = cc.card_type_id
       where ct.character_id = v_c.id and cc.reserved_for_daily
         and not cc.burned and cc.owner_id is null)::int + v_por_char);
  end loop;

  perform private.registrar('top_up_daily_reserve', null,
    jsonb_build_object('pedido', p_n, 'reservadas', v_total));
  return v_total;
end;
$fn$;

-- ---------------------------------------------------------------- auto
-- Repor a reserva era so manual, por RPC de admin. Isso e um alarme que
-- depende de alguem lembrar: o diario simplesmente para de ter estoque num
-- dia qualquer, sem aviso. Agora o proprio claim_daily devolve a reserva ao
-- alvo depois de servir - custa uma contagem por personagem, com 8 amigos
-- reclamando uma vez por dia.
create or replace function private.repor_reserva()
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare v_alvo int; v_total int := 0; v_c record;
begin
  -- o alvo por personagem vem do seed: 1500 divididos entre os personagens
  v_alvo := (1500 / greatest((select count(*) from public.characters), 1))::int;
  for v_c in select id from public.characters order by id loop
    v_total := v_total + private.reservar_diario(v_c.id, v_alvo);
  end loop;
  return v_total;
end;
$fn$;

revoke all on function private.repor_reserva() from public, anon, authenticated;

-- ================================================================ 2. grants
-- O grant automatico para PUBLIC voltou, exatamente como o comentario da
-- migracao de ontem previu: `private.pontos_carta` mudou de assinatura, e
-- funcao nova nasce aberta. A auditoria de producao pegou na primeira
-- rodada seguinte.
--
-- Vira funcao, para as proximas migracoes so precisarem chamar no fim.
create or replace function private.fechar_grants()
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare f record; n int := 0;
begin
  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
    where n2.nspname = 'private'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.assinatura);
    n := n + 1;
  end loop;

  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
    where n2.nspname = 'public'
      and array_to_string(coalesce(p.proacl, '{}'), ',') like '=X/%'
  loop
    execute format('revoke all on function %s from public', f.assinatura);
    n := n + 1;
  end loop;
  return n;
end;
$fn$;

select private.fechar_grants();
revoke all on function private.fechar_grants() from public, anon, authenticated;

-- ---------------------------------------------------------------- claim_daily
-- Passa a repor a reserva depois de servir. Ver o comentario dentro.
create or replace function public.claim_daily()
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  p            public.players;
  v_comuns     int;
  v_raros      int;
  v_ciclo      int;
  v_ultra      boolean;
  v_streak     int;
  v_bonus      int;
  v_extra      int := 0;
  v_espera     interval;
begin
  if auth.uid() is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select * into p from public.players where id = auth.uid() for update;
  if p.id is null then raise exception 'jogador nao encontrado'; end if;

  if p.last_daily_at is not null and p.last_daily_at > now() - interval '24 hours' then
    v_espera := (p.last_daily_at + interval '24 hours') - now();
    raise exception 'o diario volta em %', to_char(v_espera, 'HH24"h"MI"min"');
  end if;

  v_comuns := (select valor from public.pack_params where chave = 'diario_comuns')::int;
  v_raros  := (select valor from public.pack_params where chave = 'diario_raros')::int;
  v_ciclo  := (select valor from public.pack_params where chave = 'diario_ultra_ciclo')::int;

  -- streak: mantem se resgatou nas ultimas 48h, senao recomeca
  v_streak := case
    when p.last_daily_at is not null and p.last_daily_at > now() - interval '48 hours'
      then (p.dailies_claimed % 7) + 1
    else 1 end;

  v_ultra := (p.dailies_claimed + 1) % v_ciclo = 0;

  update public.players set
    packs_common_daily = packs_common_daily + v_comuns,
    packs_rare_daily   = packs_rare_daily   + v_raros,
    packs_ultra_daily  = packs_ultra_daily  + (case when v_ultra then 1 else 0 end),
    last_daily_at      = now(),
    dailies_claimed    = case
      when p.last_daily_at is not null and p.last_daily_at > now() - interval '48 hours'
        then dailies_claimed + 1
      else 1 end
  where id = p.id;

  v_bonus := (select valor from public.economy_config where chave = 'bonus_login')::int;
  if v_streak = 7 then
    v_extra := (select valor from public.economy_config where chave = 'bonus_login_streak7')::int;
  end if;
  perform private.mover_baba(p.id, v_bonus + v_extra, 'login diario',
                             'streak ' || v_streak::text);

  -- Repor a prateleira do diario aqui, e nao so por RPC de admin. A reserva
  -- e consumida justamente por esta funcao; deixar a reposicao dependendo de
  -- alguem lembrar significa que um dia o diario para sem aviso.
  perform private.repor_reserva();

  return jsonb_build_object(
    'comuns', v_comuns, 'raros', v_raros, 'ultra', v_ultra,
    'streak', v_streak, 'baba', v_bonus + v_extra,
    'proximo_ultra_em', case when v_ultra then v_ciclo else v_ciclo - ((p.dailies_claimed + 1) % v_ciclo) end);
end;
$fn$;

alter function public.claim_daily() owner to postgres;
grant execute on function public.claim_daily() to authenticated;
select private.fechar_grants();


-- ===== 20260823120000_censo_publico.sql =====
-- BELESMA figurinhas - o censo de escassez fica visivel para o cliente

-- O filtro "mais rara primeiro" da Colecao ordenava so por tier_order, o
-- mesmo defeito que a joia tinha: uma cosmica com selo, unica no mundo,
-- aparecia embaixo de qualquer divina. Para a tela usar o criterio de
-- verdade ela precisa do censo, e o censo e informacao publica - o indice
-- global ja diz quantas copias de cada tipo existem.
--
-- Devolve a tabela inteira de uma vez: sao ~30 linhas, e o cliente resolve
-- as ordenacoes localmente sem uma consulta por carta.
create or replace function public.escassez_por_classe()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'tier', tier, 'seal', seal, 'copias', copias) order by copias, tier), '[]'::jsonb)
  from private.censo_raridade;
$fn$;

alter function public.escassez_por_classe() owner to postgres;
grant execute on function public.escassez_por_classe() to anon, authenticated;

select private.fechar_grants();


-- ===== 20260823130000_pacotes_como_dados.sql =====
-- BELESMA figurinhas - pacote deixa de ser codigo e vira dado
--
-- Ate aqui `comum`, `raro` e `ultra` eram um ENUM, e o open_pack decidia por
-- NOME: qual tabela de odds ler, quantas cartas dar, que garantia honrar.
-- Criar um pacote novo exigia migracao, deploy e um `case` a mais.
--
-- Agora a definicao inteira e linha de tabela: tamanho, slots, filtros,
-- odds, variancia, limite de edicao e preco. O open_pack passa a receber um
-- id e nao sabe mais o nome de pacote nenhum.

-- ================================================================ enums
do $$ begin
  create type public.pack_distribuicao as enum
    ('loja', 'admin', 'missao', 'diario', 'allotment');
exception when duplicate_object then null; end $$;

-- ================================================================ definicao
create table if not exists public.pack_definitions (
  id            serial primary key,
  slug          extensions.citext not null unique,
  name          text not null,
  descricao     text,
  art_path      text,
  tamanho       int not null check (tamanho between 1 and 20),
  distribuicao  public.pack_distribuicao not null,

  -- Loja. `elegivel_loja` e a chave: sem ele o pacote nao aparece na loja e
  -- o preco nem e cobrado. Evita que pacote de missao precise inventar um
  -- valor so para satisfazer um not null.
  elegivel_loja boolean not null default false,
  preco_baba    int check (preco_baba is null or preco_baba >= 0),

  -- Edicao limitada: quantas aberturas no mundo inteiro. null = sem teto.
  limite_global        int check (limite_global is null or limite_global > 0),
  aberturas_realizadas int not null default 0 check (aberturas_realizadas >= 0),

  -- Variancia, por definicao e nao mais por nome de pacote (spec §8).
  -- Pacote novo nasce deterministico: N slots, N cartas, sem surpresa. Os
  -- tres antigos herdam exatamente as taxas que ja tinham.
  taxa_quente    numeric(6,5) not null default 0 check (taxa_quente   between 0 and 1),
  taxa_bonus     numeric(6,5) not null default 0 check (taxa_bonus    between 0 and 1),
  taxa_promocao  numeric(6,5) not null default 0 check (taxa_promocao between 0 and 1),
  pity_limite    int          check (pity_limite is null or pity_limite > 0),
  pity_piso_tier text         references public.tiers(slug),

  ativo      boolean not null default true,
  created_by uuid references public.players(id) on delete set null,
  created_at timestamptz not null default now(),

  constraint preco_so_com_elegivel
    check (not elegivel_loja or preco_baba is not null),
  constraint pity_completo
    check ((pity_limite is null) = (pity_piso_tier is null))
);

-- ================================================================ slots
create table if not exists public.pack_slots (
  id                 serial primary key,
  pack_definition_id int not null references public.pack_definitions(id) on delete cascade,
  ordem              int not null,

  -- { tiers:[], characters:[], skins:[], tiers_min:'', tiers_max:'' }
  -- Vazio = pool inteiro. O filtro restringe o pool ANTES do sorteio, e a
  -- cascata de esgotamento nunca sai dele.
  filtro    jsonb not null default '{}'::jsonb,

  -- Quando true, a cascata nao desce abaixo do menor tier das odds deste
  -- slot. Sem estoque que honre isso, o pacote sai CURTO - e o que a §8
  -- manda, e melhor entregar menos do que entregar mentindo.
  garantido boolean not null default false,

  unique (pack_definition_id, ordem)
);

create table if not exists public.pack_slot_odds (
  id           serial primary key,
  pack_slot_id int not null references public.pack_slots(id) on delete cascade,
  tier         text not null references public.tiers(slug),
  weight       numeric(7,4) not null check (weight >= 0),
  unique (pack_slot_id, tier)
);

create index if not exists idx_pack_slots_def on public.pack_slots(pack_definition_id, ordem);
create index if not exists idx_pack_slot_odds_slot on public.pack_slot_odds(pack_slot_id);

-- ================================================================ inventario
-- players.packs_* eram seis colunas fixas: tres tipos vezes comprado/diario.
-- Nao cabe um quarto pacote sem alterar tabela.
--
-- `do_diario` continua no identificador porque a diferenca e real: pacote de
-- diario sorteia da prateleira reservada (reserved_for_daily), o comprado
-- sorteia do pool geral. Nao sao a mesma moeda.
create table if not exists public.player_packs (
  player_id          uuid not null references public.players(id) on delete cascade,
  pack_definition_id int  not null references public.pack_definitions(id) on delete cascade,
  do_diario          boolean not null default false,
  quantidade         int not null default 0 check (quantidade >= 0),
  primary key (player_id, pack_definition_id, do_diario)
);
create index if not exists idx_player_packs_jogador on public.player_packs(player_id);

-- ================================================================ balanceamento
-- O multiplicador do preco sugerido vive aqui, editavel, e nao numa
-- constante no meio de uma funcao.
insert into public.economy_config (chave, valor, descricao) values
  ('preco_multiplicador_sugerido', 2.2,
   'Preco sugerido de um pacote de loja = valor esperado x isto'),
  ('preco_multiplicador_piso',     1.5,
   'Piso do preco. Abaixo disso o pacote se paga vendendo o conteudo'),
  ('preco_multiplicador_alerta',   5.0,
   'Acima disso o construtor avisa que provavelmente ninguem compra')
on conflict (chave) do nothing;

-- ================================================================ migracao
-- Converte comum, raro e ultra em linhas, preservando as odds ao centesimo.
do $$
declare
  v_def   int;
  v_slot  int;
  v_tipo  record;
  v_base  int;
  v_i     int;
begin
  if exists (select 1 from public.pack_definitions) then
    raise notice 'pack_definitions ja populada, nada a migrar';
    return;
  end if;

  v_base := (select valor from public.pack_params where chave = 'cartas_base')::int;

  for v_tipo in
    select * from (values
      ('comum', 'Booster Comum', 'O pacote de todo dia. Quatro cartas e uma chance de hit.'),
      ('raro',  'Booster Raro',  'Garante epica ou melhor no slot de hit.'),
      ('ultra', 'Booster Ultra', 'Garante mitica ou melhor no slot de hit.')
    ) as t(slug, nome, descricao)
  loop
    insert into public.pack_definitions
      (slug, name, descricao, art_path, tamanho, distribuicao, elegivel_loja, preco_baba,
       taxa_quente, taxa_bonus, taxa_promocao, pity_limite, pity_piso_tier)
    values (
      v_tipo.slug, v_tipo.nome, v_tipo.descricao,
      'packs/booster-' || v_tipo.slug || '.png',
      v_base + 1,                         -- 3 base + 1 hit; o bonus e variancia
      'loja',
      true,
      (select valor from public.economy_config where chave = 'compra_' || v_tipo.slug)::int,
      (select valor from public.pack_params where chave = 'pacote_quente')::numeric,
      (select valor from public.pack_params where chave = 'carta_bonus')::numeric,
      (select valor from public.pack_params where chave = 'promocao_base')::numeric,
      case when v_tipo.slug = 'comum'
           then (select valor from public.pack_params where chave = 'pity_limite')::int end,
      case when v_tipo.slug = 'comum' then 'epica' end
    )
    returning id into v_def;

    -- slots base: os primeiros, sem filtro e sem garantia
    for v_i in 1 .. v_base loop
      insert into public.pack_slots (pack_definition_id, ordem, filtro, garantido)
      values (v_def, v_i, '{}'::jsonb, false)
      returning id into v_slot;

      insert into public.pack_slot_odds (pack_slot_id, tier, weight)
      select v_slot, pc.tier, pc.weight
      from public.pack_config pc
      where pc.pack_type = v_tipo.slug::public.pack_type and pc.slot = 'base' and pc.weight > 0;
    end loop;

    -- slot de hit: o ultimo, e o unico que carrega garantia
    insert into public.pack_slots (pack_definition_id, ordem, filtro, garantido)
    values (v_def, v_base + 1, '{}'::jsonb, true)
    returning id into v_slot;

    insert into public.pack_slot_odds (pack_slot_id, tier, weight)
    select v_slot, pc.tier, pc.weight
    from public.pack_config pc
    where pc.pack_type = v_tipo.slug::public.pack_type and pc.slot = 'hit' and pc.weight > 0;
  end loop;

  raise notice 'migradas % definicoes', (select count(*) from public.pack_definitions);
end $$;

-- ---------------------------------------------------------------- saldos
do $$
declare v_n int;
begin
  if exists (select 1 from public.player_packs) then
    raise notice 'player_packs ja populada';
    return;
  end if;
  -- Uma migracao posterior derruba players.packs_*. Reaplicar a cadeia
  -- inteira (o teste de idempotencia faz isso) chegaria aqui com as colunas
  -- ja mortas e estouraria. O PL/pgSQL so analisa o comando quando o
  -- alcanca, entao sair antes basta.
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'players'
                   and column_name = 'packs_common') then
    raise notice 'colunas antigas ja removidas, nada a migrar';
    return;
  end if;

  insert into public.player_packs (player_id, pack_definition_id, do_diario, quantidade)
  select p.id, d.id, x.diario, x.qtd
  from public.players p
  cross join lateral (values
    ('comum', false, p.packs_common),        ('comum', true, p.packs_common_daily),
    ('raro',  false, p.packs_rare),          ('raro',  true, p.packs_rare_daily),
    ('ultra', false, p.packs_ultra),         ('ultra', true, p.packs_ultra_daily)
  ) as x(slug, diario, qtd)
  join public.pack_definitions d on d.slug = x.slug::extensions.citext
  where x.qtd > 0;
  get diagnostics v_n = row_count;
  raise notice 'saldos migrados: % linhas', v_n;
end $$;

-- ================================================================ rls
alter table public.pack_definitions enable row level security;
alter table public.pack_slots       enable row level security;
alter table public.pack_slot_odds   enable row level security;
alter table public.player_packs     enable row level security;

revoke all on public.pack_definitions, public.pack_slots,
              public.pack_slot_odds, public.player_packs from anon, authenticated;

-- O catalogo de pacotes e publico: a loja mostra, e as odds sao abertas
-- (spec §8 - odds a vista, sempre).
grant select on public.pack_definitions, public.pack_slots, public.pack_slot_odds
  to anon, authenticated;
grant select on public.player_packs to authenticated;
grant all on public.pack_definitions, public.pack_slots,
             public.pack_slot_odds, public.player_packs to service_role;
grant usage, select on all sequences in schema public to service_role;

drop policy if exists pack_definitions_leitura on public.pack_definitions;
create policy pack_definitions_leitura on public.pack_definitions
  for select to anon, authenticated using (true);

drop policy if exists pack_slots_leitura on public.pack_slots;
create policy pack_slots_leitura on public.pack_slots
  for select to anon, authenticated using (true);

drop policy if exists pack_slot_odds_leitura on public.pack_slot_odds;
create policy pack_slot_odds_leitura on public.pack_slot_odds
  for select to anon, authenticated using (true);

-- inventario e so do dono
drop policy if exists player_packs_meu on public.player_packs;
create policy player_packs_meu on public.player_packs
  for select to authenticated using (player_id = auth.uid());

select private.fechar_grants();


-- ===== 20260823140000_open_pack_por_definicao.sql =====
-- BELESMA figurinhas - open_pack passa a ler a definicao, nao o nome

alter table public.pack_openings
  add column if not exists pack_definition_id int references public.pack_definitions(id);

alter table public.pack_openings alter column pack_type drop not null;

update public.pack_openings o
set pack_definition_id = d.id
from public.pack_definitions d
where o.pack_definition_id is null and d.slug = o.pack_type::text::extensions.citext;

-- ================================================================ filtro
-- Traduz o filtro de um slot no conjunto de card_types elegiveis.
--
--   { "tiers": ["rara","epica"] }
--   { "skins": ["fogo","gelo","trovao","vento"] }
--   { "characters": ["pedrao"], "tiers_min": "comum" }
--
-- Chave ausente ou lista vazia nao restringe. Filtro {} = pool inteiro.
create or replace function private.tipos_do_filtro(p_filtro jsonb)
returns setof int
language sql
stable
set search_path = public, extensions, pg_temp
as $fn$
  select ct.id
  from public.card_types ct
  join public.characters ch on ch.id = ct.character_id
  join public.tiers t on t.slug = ct.tier
  where (coalesce(jsonb_array_length(p_filtro->'tiers'), 0) = 0
         or ct.tier in (select jsonb_array_elements_text(p_filtro->'tiers')))
    and (coalesce(jsonb_array_length(p_filtro->'characters'), 0) = 0
         or ch.slug in (select jsonb_array_elements_text(p_filtro->'characters')))
    and (coalesce(jsonb_array_length(p_filtro->'skins'), 0) = 0
         or ct.skin in (select jsonb_array_elements_text(p_filtro->'skins')))
    and (p_filtro->>'tiers_min' is null
         or t.tier_order >= (select tier_order from public.tiers
                             where slug = p_filtro->>'tiers_min'))
    and (p_filtro->>'tiers_max' is null
         or t.tier_order <= (select tier_order from public.tiers
                             where slug = p_filtro->>'tiers_max'))
$fn$;

-- ================================================================ open_pack
create or replace function public.open_pack(p_pack_definition_id int)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid       uuid := auth.uid();
  v_jogador   public.players;
  v_def       public.pack_definitions;
  v_do_diario boolean := false;

  v_ref       public.pack_slots;      -- slot de referencia do quente/promocao
  v_slot      public.pack_slots;
  v_slot_uso  public.pack_slots;

  v_quente    boolean := false;
  v_bonus     boolean := false;
  v_pity      boolean := false;
  v_promov    int := 0;

  v_garantido boolean;
  v_piso      smallint;
  v_piso_slot smallint;
  v_reserva   boolean;

  v_tiers     text[];
  v_pesos     numeric[];
  v_idx       int;
  v_tier      text;
  v_type_id   int;
  v_copy_id   bigint;
  v_tent      int;

  v_usados     int[]    := '{}';
  v_copias     bigint[] := '{}';
  v_tiers_saiu text[]   := '{}';
  v_do_hit     boolean[]:= '{}';
  v_garantidos boolean[]:= '{}';

  v_ids_slots int[];
  v_id_slot   int;
  v_i         int;
  v_j         int;
  v_tmp       int;
  v_ordem     int[];
  v_abertura  bigint;
  v_resultado jsonb;
begin
  if v_uid is null then
    raise exception 'precisa estar logado' using errcode = '42501';
  end if;

  -- A definicao e travada aqui e nao no fim: o contador de edicao limitada
  -- precisa ser lido e escrito sob a mesma trava, senao duas aberturas
  -- simultaneas passam do limite.
  select * into v_def from public.pack_definitions
  where id = p_pack_definition_id for update;
  if not found then raise exception 'pacote nao existe'; end if;
  if not v_def.ativo then raise exception 'pacote "%" esta desativado', v_def.name; end if;

  if v_def.limite_global is not null
     and v_def.aberturas_realizadas >= v_def.limite_global then
    raise exception 'edicao esgotada: % de % aberturas ja aconteceram',
      v_def.aberturas_realizadas, v_def.limite_global;
  end if;

  select * into v_jogador from public.players where id = v_uid for update;
  if not found then raise exception 'jogador nao encontrado'; end if;

  -- Gasta primeiro o do diario: ele sorteia da prateleira reservada e nao
  -- acumula valor, entao segurar nao traz vantagem nenhuma.
  update public.player_packs
  set quantidade = quantidade - 1
  where player_id = v_uid and pack_definition_id = v_def.id and do_diario
    and quantidade > 0;
  if found then
    v_do_diario := true;
  else
    update public.player_packs
    set quantidade = quantidade - 1
    where player_id = v_uid and pack_definition_id = v_def.id and not do_diario
      and quantidade > 0;
    if not found then
      raise exception 'voce nao tem nenhum "%"', v_def.name;
    end if;
  end if;

  -- Slot de referencia do pacote quente e da promocao: o de maior ordem
  -- entre os garantidos. Sem slot garantido, quente e promocao nao tem para
  -- onde promover e simplesmente nao acontecem.
  select * into v_ref from public.pack_slots
  where pack_definition_id = v_def.id and garantido
  order by ordem desc limit 1;

  if v_ref.id is not null then
    v_quente := private.random_int(100000) < v_def.taxa_quente * 100000;
    v_promov := 0;
    if v_def.pity_limite is not null then
      v_pity := v_jogador.pity_counter >= v_def.pity_limite;
    end if;
  end if;
  v_bonus := private.random_int(100000) < v_def.taxa_bonus * 100000;

  -- ------------------------------------------------------------- slots
  select array_agg(id order by ordem) into v_ids_slots
  from public.pack_slots where pack_definition_id = v_def.id;
  if v_ids_slots is null then
    raise exception 'o pacote "%" nao tem slot nenhum configurado', v_def.name;
  end if;
  -- carta bonus: uma repeticao do primeiro slot, no fim
  if v_bonus then v_ids_slots := v_ids_slots || v_ids_slots[1]; end if;

  foreach v_id_slot in array v_ids_slots loop
    select * into v_slot from public.pack_slots where id = v_id_slot;
    v_slot_uso  := v_slot;
    v_garantido := false;

    if v_quente and not v_slot.garantido and v_ref.id is not null then
      v_slot_uso  := v_ref;
      v_garantido := true;
    elsif not v_slot.garantido and v_ref.id is not null
          and private.random_int(100000) < v_def.taxa_promocao * 100000 then
      v_slot_uso  := v_ref;
      v_garantido := true;
      v_promov    := v_promov + 1;
    elsif v_slot.garantido and v_pity then
      v_garantido := true;
    end if;

    -- piso do proprio slot: o menor tier que as odds dele listam. Slot
    -- garantido nunca entrega abaixo disso - o pacote sai curto em vez de
    -- mentir (§8).
    select min(t.tier_order) into v_piso_slot
    from public.pack_slot_odds o join public.tiers t on t.slug = o.tier
    where o.pack_slot_id = v_slot_uso.id and o.weight > 0;

    v_piso := case
      when v_pity and v_slot_uso.garantido and v_def.pity_piso_tier is not null
        then (select tier_order from public.tiers where slug = v_def.pity_piso_tier)
      else 0 end;

    -- pacote de diario sorteia da prateleira reservada, menos nos slots
    -- garantidos: hit nunca sai da reserva de comuns
    v_reserva := v_do_diario and not v_slot_uso.garantido;

    -- ----------------------------------------------------------- sorteio
    select array_agg(x.tier order by x.tier_order), array_agg(x.weight order by x.tier_order)
      into v_tiers, v_pesos
    from (
      select o.tier, t.tier_order, o.weight
      from public.pack_slot_odds o
      join public.tiers t on t.slug = o.tier
      where o.pack_slot_id = v_slot_uso.id
        and o.weight > 0
        and t.tier_order >= v_piso
        and not (v_garantido and t.slug in ('diamante','prisma'))
        and exists (
          select 1 from public.card_copies cc
          join public.card_types ct on ct.id = cc.card_type_id
          where ct.tier = o.tier and cc.owner_id is null and not cc.burned
            and cc.reserved_for_daily = v_reserva
            and ct.id in (select private.tipos_do_filtro(v_slot_uso.filtro))
        )
    ) x;

    -- Cascata. Ela NUNCA sai do filtro do slot, e num slot garantido nao
    -- desce abaixo do piso das odds dele.
    if v_tiers is null then
      select array_agg(t.slug order by t.tier_order), array_agg(1::numeric)
        into v_tiers, v_pesos
      from public.tiers t
      where t.slug not in ('diamante','prisma')
        and t.tier_order >= v_piso
        and (not v_slot_uso.garantido or t.tier_order >= v_piso_slot)
        and exists (
          select 1 from public.card_copies cc
          join public.card_types ct on ct.id = cc.card_type_id
          where ct.tier = t.slug and cc.owner_id is null and not cc.burned
            and cc.reserved_for_daily = v_reserva
            and ct.id in (select private.tipos_do_filtro(v_slot_uso.filtro))
        );
    end if;

    -- Slot promovido que ficou sem nada: o bonus e o que se perde, nao a
    -- carta. Volta a ser o slot original e tenta de novo.
    if v_tiers is null and v_slot_uso.id <> v_slot.id then
      if not v_quente then v_promov := v_promov - 1; end if;
      v_slot_uso  := v_slot;
      v_garantido := false;
      v_reserva   := v_do_diario;
      select array_agg(t.slug order by t.tier_order), array_agg(1::numeric)
        into v_tiers, v_pesos
      from public.tiers t
      where t.slug not in ('diamante','prisma')
        and exists (
          select 1 from public.card_copies cc
          join public.card_types ct on ct.id = cc.card_type_id
          where ct.tier = t.slug and cc.owner_id is null and not cc.burned
            and cc.reserved_for_daily = v_reserva
            and ct.id in (select private.tipos_do_filtro(v_slot.filtro))
        );
    end if;

    continue when v_tiers is null;

    v_idx  := private.escolher_ponderado(v_pesos);
    v_tier := v_tiers[v_idx];

    -- tipo dentro do tier, respeitando o filtro e evitando repetir no pacote
    v_type_id := null;
    select ct.id into v_type_id
    from public.card_types ct
    join public.card_copies cc on cc.card_type_id = ct.id
    where ct.tier = v_tier and cc.owner_id is null and not cc.burned
      and cc.reserved_for_daily = v_reserva
      and ct.id in (select private.tipos_do_filtro(v_slot_uso.filtro))
      and not (ct.id = any(v_usados))
    group by ct.id
    order by extensions.gen_random_bytes(8)
    limit 1;

    if v_type_id is null then
      select ct.id into v_type_id
      from public.card_types ct
      join public.card_copies cc on cc.card_type_id = ct.id
      where ct.tier = v_tier and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
        and ct.id in (select private.tipos_do_filtro(v_slot_uso.filtro))
      group by ct.id
      order by extensions.gen_random_bytes(8)
      limit 1;
    end if;
    continue when v_type_id is null;

    v_copy_id := null;
    for v_tent in 1 .. 5 loop
      select cc.id into v_copy_id
      from public.card_copies cc
      where cc.card_type_id = v_type_id and cc.owner_id is null and not cc.burned
        and cc.reserved_for_daily = v_reserva
      order by extensions.gen_random_bytes(8)
      limit 1
      for update skip locked;
      exit when v_copy_id is not null;
    end loop;
    continue when v_copy_id is null;

    update public.card_copies
    set owner_id = v_uid,
        claimed_at = now(),
        first_discovered_at = coalesce(first_discovered_at, now()),
        first_discovered_by = coalesce(first_discovered_by, v_uid)
    where id = v_copy_id;

    insert into public.copy_history (copy_id, from_player, to_player, kind)
    values (v_copy_id, null, v_uid, case when v_do_diario then 'daily' else 'pull' end);

    v_usados     := v_usados     || v_type_id;
    v_copias     := v_copias     || v_copy_id;
    v_tiers_saiu := v_tiers_saiu || v_tier;
    v_do_hit     := v_do_hit     || v_slot_uso.garantido;
    v_garantidos := v_garantidos || v_garantido;
  end loop;

  if array_length(v_copias, 1) is null then
    raise exception 'sem estoque: nao foi possivel montar o pacote';
  end if;

  -- ------------------------------------------------------------- pity
  if v_def.pity_limite is not null then
    if v_pity or exists (
      select 1 from unnest(v_tiers_saiu) s join public.tiers t on t.slug = s
      where t.tier_order >= (select tier_order from public.tiers
                             where slug = v_def.pity_piso_tier))
    then
      update public.players set pity_counter = 0 where id = v_uid;
    else
      update public.players set pity_counter = pity_counter + 1 where id = v_uid;
    end if;
  end if;

  -- ------------------------------------------------------------- edicao
  update public.pack_definitions
  set aberturas_realizadas = aberturas_realizadas + 1
  where id = v_def.id;

  -- ------------------------------------------------------------- registro
  v_ordem := array(select generate_series(1, array_length(v_copias, 1)));
  for v_i in reverse array_length(v_ordem, 1) .. 2 loop
    v_j := private.random_int(v_i) + 1;
    v_tmp := v_ordem[v_i]; v_ordem[v_i] := v_ordem[v_j]; v_ordem[v_j] := v_tmp;
  end loop;

  insert into public.pack_openings
    (player_id, pack_type, pack_definition_id, from_daily, promoted_slots, hot, pity, bonus)
  values (v_uid,
          (case when v_def.slug::text in ('comum','raro','ultra')
                then v_def.slug::text::public.pack_type end),
          v_def.id, v_do_diario, v_promov, v_quente, v_pity, v_bonus)
  returning id into v_abertura;

  for v_i in 1 .. array_length(v_copias, 1) loop
    insert into public.pack_opening_cards
      (opening_id, copy_id, slot_index, reveal_index, tier, from_hit_table, garantido)
    values (v_abertura, v_copias[v_i], v_i, array_position(v_ordem, v_i),
            v_tiers_saiu[v_i], v_do_hit[v_i], v_garantidos[v_i]);
  end loop;

  select jsonb_build_object(
    'abertura', v_abertura,
    'pack_definition_id', v_def.id,
    'pack_slug', v_def.slug::text,
    'pack_nome', v_def.name,
    'pack_type', v_def.slug::text,
    'do_diario', v_do_diario,
    'quente', v_quente, 'bonus', v_bonus, 'pity', v_pity, 'promovidos', v_promov,
    'esperado', v_def.tamanho + (case when v_bonus then 1 else 0 end),
    'restantes_da_edicao', case when v_def.limite_global is null then null
                                else v_def.limite_global - v_def.aberturas_realizadas - 1 end,
    'cartas', coalesce(jsonb_agg(c order by c->>'reveal_index'), '[]'::jsonb)
  ) into v_resultado
  from (
    select jsonb_build_object(
      'copy_id', cc.id, 'card_type_id', cc.card_type_id,
      'reveal_index', poc.reveal_index, 'from_hit_table', poc.from_hit_table,
      'garantido', poc.garantido, 'serial_number', cc.serial_number,
      'print_run', ct.print_run, 'seal', cc.seal, 'origin', cc.origin,
      'damage_level', cc.damage_level, 'verify_code', cc.verify_code,
      'tier', ct.tier, 'tier_order', ct.tier_order, 'skin', ct.skin,
      'art_path', ct.art_path,
      'character_slug', ch.slug, 'character_name', ch.name,
      'estreia_mundial',
          cc.first_discovered_by = v_uid
          and cc.first_discovered_at >= now() - interval '1 minute'
          and not exists (
            select 1 from public.card_copies anterior
            where anterior.card_type_id = cc.card_type_id and anterior.id <> cc.id
              and anterior.first_discovered_at is not null
              and anterior.first_discovered_at < cc.first_discovered_at),
      'nova', not exists (
        select 1 from public.card_copies o
        where o.card_type_id = cc.card_type_id and o.owner_id = v_uid and o.id <> cc.id)
    ) as c
    from public.pack_opening_cards poc
    join public.card_copies cc on cc.id = poc.copy_id
    join public.card_types  ct on ct.id = cc.card_type_id
    join public.characters  ch on ch.id = ct.character_id
    where poc.opening_id = v_abertura
  ) t;

  return v_resultado;
end;
$fn$;

-- A assinatura antiga aceitava texto. Fica como ponte para o front antigo e
-- para os testes, resolvendo o slug para o id.
create or replace function public.open_pack(pack_type text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_id int;
begin
  select id into v_id from public.pack_definitions
  where slug = pack_type::extensions.citext;
  if v_id is null then raise exception 'pacote "%" nao existe', pack_type; end if;
  return public.open_pack(v_id);
end;
$fn$;

alter function public.open_pack(int)  owner to postgres;
alter function public.open_pack(text) owner to postgres;
grant execute on function public.open_pack(int)  to authenticated;
grant execute on function public.open_pack(text) to authenticated;

select private.fechar_grants();


-- ===== 20260823150000_inventario_por_definicao.sql =====
-- BELESMA figurinhas - o inventario deixa de ser seis colunas fixas
--
-- players.packs_common / _rare / _ultra (x2, com e sem diario) nao cabem um
-- quarto pacote sem ALTER TABLE. Passa tudo para player_packs, e as colunas
-- somem: manter as duas em sincronia e o tipo de coisa que apodrece na
-- primeira funcao que alguem esquece de atualizar.

-- ================================================================ config
-- Quanto cada definicao da no allotment inicial e no diario. Estava em
-- pack_params por NOME de pacote ('allotment_comum', 'diario_raros'); agora
-- e coluna da propria definicao, e um pacote novo so precisa preencher.
alter table public.pack_definitions
  add column if not exists allotment_quantidade int not null default 0
    check (allotment_quantidade >= 0),
  add column if not exists diario_quantidade int not null default 0
    check (diario_quantidade >= 0),
  add column if not exists diario_ciclo int not null default 1
    check (diario_ciclo >= 1);

update public.pack_definitions d set
  allotment_quantidade = coalesce(
    (select valor from public.pack_params where chave = 'allotment_' || d.slug::text)::int, 0),
  diario_quantidade = case d.slug::text
    when 'comum' then (select valor from public.pack_params where chave = 'diario_comuns')::int
    when 'raro'  then (select valor from public.pack_params where chave = 'diario_raros')::int
    when 'ultra' then 1 else 0 end,
  diario_ciclo = case d.slug::text
    when 'ultra' then (select valor from public.pack_params where chave = 'diario_ultra_ciclo')::int
    else 1 end
where d.slug::text in ('comum','raro','ultra');

-- ================================================================ helper
create or replace function private.dar_pacote(
  p_player uuid, p_def int, p_diario boolean, p_n int)
returns void
language sql volatile
set search_path = public, extensions, pg_temp
as $fn$
  insert into public.player_packs (player_id, pack_definition_id, do_diario, quantidade)
  values (p_player, p_def, p_diario, greatest(p_n, 0))
  on conflict (player_id, pack_definition_id, do_diario)
  do update set quantidade = public.player_packs.quantidade + greatest(p_n, 0);
$fn$;

create or replace function private.inventario(p_player uuid)
returns jsonb
language sql stable
set search_path = public, extensions, pg_temp
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'pack_definition_id', d.id, 'slug', d.slug::text, 'nome', d.name,
    'art_path', d.art_path, 'do_diario', pp.do_diario,
    'quantidade', pp.quantidade, 'tamanho', d.tamanho, 'ativo', d.ativo
  ) order by d.id, pp.do_diario desc), '[]'::jsonb)
  from public.player_packs pp
  join public.pack_definitions d on d.id = pp.pack_definition_id
  where pp.player_id = p_player and pp.quantidade > 0;
$fn$;

-- ================================================================ me()
-- Passa a devolver jsonb: a linha de players nao carrega mais o inventario,
-- e o cliente precisa dele junto para nao fazer duas viagens.
drop function if exists public.me();
create or replace function public.me()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  select to_jsonb(p) - 'packs_common' - 'packs_rare' - 'packs_ultra'
                     - 'packs_common_daily' - 'packs_rare_daily' - 'packs_ultra_daily'
         || jsonb_build_object(
              'inventario', private.inventario(p.id),
              'pacotes_total', coalesce((select sum(quantidade) from public.player_packs
                                         where player_id = p.id), 0))
  from public.players p where p.id = auth.uid();
$fn$;

-- ================================================================ escritores
-- claim_nickname continua devolvendo a linha de players e continua
-- IDEMPOTENTE - chamar de novo devolve a linha, nao repete o allotment. Copia
-- fiel do original; a unica mudanca e de onde sai o allotment.
create or replace function public.claim_nickname(p_nickname text)
returns public.players
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_row   public.players;
  v_d     record;
begin
  if v_uid is null then
    raise exception 'precisa estar logado' using errcode = '42501';
  end if;

  -- Idempotente: chamar de novo devolve a linha, nao duplica allotment.
  select * into v_row from public.players where id = v_uid;
  if found then return v_row; end if;

  if p_nickname !~ '^[a-z0-9][a-z0-9_-]{2,19}$' then
    raise exception 'apelido invalido: 3 a 20 caracteres, minusculas, numeros, - e _';
  end if;

  -- O apelido tem que bater com o e-mail sintetico do proprio JWT, senao
  -- daria para cadastrar como "fulano" e reivindicar o apelido "beltrano".
  select email into v_email from auth.users where id = v_uid;
  if lower(split_part(v_email, '@', 1)) <> lower(p_nickname) then
    raise exception 'apelido nao confere com a conta';
  end if;

  insert into public.players (id, nickname)
  values (v_uid, p_nickname::extensions.citext)
  returning * into v_row;

  -- allotment inicial: vem da coluna da definicao, nao de uma chave em
  -- pack_params nomeada pelo slug do pacote. Pacote novo so preenche o campo.
  for v_d in select id, allotment_quantidade from public.pack_definitions
             where ativo and allotment_quantidade > 0
  loop
    perform private.dar_pacote(v_uid, v_d.id, false, v_d.allotment_quantidade);
  end loop;

  return v_row;
exception
  when unique_violation then
    raise exception 'esse apelido ja existe';
end;
$fn$;

-- ---------------------------------------------------------------- grant
create or replace function public.grant_packs(p_target text, p_pack_type text, p_quantidade int)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_def int; v_n int := 0; v_p record;
begin
  perform private.require_admin();
  if p_quantidade is null or p_quantidade = 0 then raise exception 'quantidade invalida'; end if;

  select id into v_def from public.pack_definitions
  where slug = p_pack_type::extensions.citext;
  if v_def is null then raise exception 'pacote "%" nao existe', p_pack_type; end if;

  for v_p in
    select id from public.players
    where p_target = 'todos' or nickname = p_target::extensions.citext
  loop
    if p_quantidade > 0 then
      perform private.dar_pacote(v_p.id, v_def, false, p_quantidade);
    else
      update public.player_packs set quantidade = greatest(0, quantidade + p_quantidade)
      where player_id = v_p.id and pack_definition_id = v_def and not do_diario;
    end if;
    v_n := v_n + 1;
  end loop;

  perform private.registrar('grant_packs', p_target,
    jsonb_build_object('pacote', p_pack_type, 'quantidade', p_quantidade, 'jogadores', v_n));
  return v_n;
end;
$fn$;

-- ---------------------------------------------------------------- loja
create or replace function public.comprar_pacote(p_pack_type text, p_character_id int default null)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_def   public.pack_definitions;
  v_preco numeric;
  v_teto  int;
  v_hoje  int;
  v_saldo int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select * into v_def from public.pack_definitions
  where slug = p_pack_type::extensions.citext;
  if v_def.id is null then raise exception 'pacote "%" nao existe', p_pack_type; end if;
  if not v_def.ativo then raise exception 'pacote "%" esta desativado', v_def.name; end if;
  if not v_def.elegivel_loja then raise exception '"%" nao esta a venda', v_def.name; end if;

  if v_def.limite_global is not null
     and v_def.aberturas_realizadas >= v_def.limite_global then
    raise exception 'edicao esgotada'; end if;

  v_teto := private.preco('teto_compra_dia')::int;
  select count(*) into v_hoje from public.baba_log
  where player_id = v_uid and motivo = 'compra' and created_at > now() - interval '24 hours';
  if v_hoje >= v_teto then
    raise exception 'limite de % compras por dia atingido', v_teto;
  end if;

  v_preco := v_def.preco_baba;
  if p_character_id is not null then
    v_preco := v_preco * private.preco('dirigido_mult');
  end if;

  v_saldo := private.mover_baba(v_uid, -floor(v_preco)::int, 'compra', v_def.slug::text);
  perform private.dar_pacote(v_uid, v_def.id, false, 1);

  return jsonb_build_object('preco', floor(v_preco), 'saldo', v_saldo,
    'restantes_hoje', v_teto - v_hoje - 1, 'pack_definition_id', v_def.id);
end;
$fn$;

-- ---------------------------------------------------------------- diario
create or replace function public.claim_daily()
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  p        public.players;
  v_streak int;
  v_bonus  int;
  v_extra  int := 0;
  v_espera interval;
  v_d      record;
  v_dados  jsonb := '[]'::jsonb;
  v_n      int;
begin
  if auth.uid() is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select * into p from public.players where id = auth.uid() for update;
  if p.id is null then raise exception 'jogador nao encontrado'; end if;

  if p.last_daily_at is not null and p.last_daily_at > now() - interval '24 hours' then
    v_espera := (p.last_daily_at + interval '24 hours') - now();
    raise exception 'o diario volta em %', to_char(v_espera, 'HH24"h"MI"min"');
  end if;

  v_streak := case
    when p.last_daily_at is not null and p.last_daily_at > now() - interval '48 hours'
      then (p.dailies_claimed % 7) + 1
    else 1 end;

  -- cada definicao diz o que da e de quantos em quantos resgates
  for v_d in select id, name, slug, diario_quantidade, diario_ciclo
             from public.pack_definitions
             where ativo and diario_quantidade > 0 order by id
  loop
    v_n := case when (p.dailies_claimed + 1) % v_d.diario_ciclo = 0
                then v_d.diario_quantidade else 0 end;
    if v_n > 0 then
      perform private.dar_pacote(p.id, v_d.id, true, v_n);
      v_dados := v_dados || jsonb_build_object(
        'pack_definition_id', v_d.id, 'slug', v_d.slug::text,
        'nome', v_d.name, 'quantidade', v_n);
    end if;
  end loop;

  update public.players set
    last_daily_at   = now(),
    dailies_claimed = case
      when p.last_daily_at is not null and p.last_daily_at > now() - interval '48 hours'
        then dailies_claimed + 1
      else 1 end
  where id = p.id;

  v_bonus := (select valor from public.economy_config where chave = 'bonus_login')::int;
  if v_streak = 7 then
    v_extra := (select valor from public.economy_config where chave = 'bonus_login_streak7')::int;
  end if;
  perform private.mover_baba(p.id, v_bonus + v_extra, 'login diario',
                             'streak ' || v_streak::text);

  perform private.repor_reserva();

  return jsonb_build_object('pacotes', v_dados, 'streak', v_streak,
                            'baba', v_bonus + v_extra);
end;
$fn$;

-- ---------------------------------------------------------------- admin
create or replace function public.admin_jogadores()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  perform private.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'nickname', p.nickname, 'created_at', p.created_at,
      'is_admin', p.is_admin, 'baba', p.baba,
      'copias', (select count(*) from public.card_copies cc where cc.owner_id = p.id),
      'pacotes', private.inventario(p.id),
      'pacotes_total', coalesce((select sum(quantidade) from public.player_packs
                                 where player_id = p.id), 0),
      'last_daily_at', p.last_daily_at, 'pity_counter', p.pity_counter
    ) order by p.created_at)
    from public.players p), '[]'::jsonb);
end;
$fn$;

create or replace function public.admin_recomecar_do_zero(p_confirmacao text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_forjadas int; v_devolvidas int; v_jogadores int; v_estreias int;
  v_ch record; v_p record; v_d record;
begin
  perform private.require_admin();
  if p_confirmacao <> 'RECOMECAR DO ZERO' then
    raise exception 'confirmacao invalida: digite RECOMECAR DO ZERO';
  end if;

  delete from public.trades             where true;
  delete from public.trade_rewards      where true;
  delete from public.album_colagem      where true;
  delete from public.pack_opening_cards where true;
  delete from public.pack_openings      where true;
  delete from public.copy_history       where true;
  delete from public.baba_log           where true;
  delete from public.player_packs       where true;

  delete from public.card_copies where origin = 'forge';
  get diagnostics v_forjadas = row_count;

  select count(*) into v_estreias
  from public.card_copies where first_discovered_at is not null;

  update public.card_copies
  set owner_id = null, claimed_at = null, burned = false, damage_level = 0,
      first_discovered_at = null, first_discovered_by = null, reserved_for_daily = false
  where true;
  get diagnostics v_devolvidas = row_count;

  update public.players set
    baba = 0, pity_counter = 0, dailies_claimed = 0, last_daily_at = null,
    showcase_1 = null, showcase_2 = null, showcase_3 = null
  where true;
  get diagnostics v_jogadores = row_count;

  -- allotment de volta, da definicao
  for v_p in select id from public.players loop
    for v_d in select id, allotment_quantidade from public.pack_definitions
               where ativo and allotment_quantidade > 0
    loop
      perform private.dar_pacote(v_p.id, v_d.id, false, v_d.allotment_quantidade);
    end loop;
  end loop;

  -- as edicoes limitadas voltam a zero: e um mundo novo
  update public.pack_definitions set aberturas_realizadas = 0 where true;

  for v_ch in select id from public.characters order by id loop
    perform private.reservar_diario(v_ch.id, 500);
  end loop;

  perform private.registrar('admin_recomecar_do_zero', 'mundo',
    jsonb_build_object('forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
                       'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores));

  return jsonb_build_object(
    'forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
    'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores,
    'reservadas_para_diario',
      (select count(*) from public.card_copies where reserved_for_daily));
end;
$fn$;

-- ================================================================ colunas
-- Agora que ninguem mais le nem escreve, elas saem. Deixar uma coluna morta
-- e um convite para alguem voltar a usar por engano.
alter table public.players
  drop column if exists packs_common,       drop column if exists packs_rare,
  drop column if exists packs_ultra,        drop column if exists packs_common_daily,
  drop column if exists packs_rare_daily,   drop column if exists packs_ultra_daily;

alter function public.me()                             owner to postgres;
alter function public.claim_nickname(text)             owner to postgres;
alter function public.grant_packs(text, text, int)     owner to postgres;
alter function public.comprar_pacote(text, int)        owner to postgres;
alter function public.claim_daily()                    owner to postgres;
alter function public.admin_jogadores()                owner to postgres;
alter function public.admin_recomecar_do_zero(text)    owner to postgres;

grant execute on function public.me()                          to authenticated;
grant execute on function public.claim_nickname(text)          to authenticated;
grant execute on function public.grant_packs(text, text, int)  to authenticated;
grant execute on function public.comprar_pacote(text, int)     to authenticated;
grant execute on function public.claim_daily()                 to authenticated;
grant execute on function public.admin_jogadores()             to authenticated;
grant execute on function public.admin_recomecar_do_zero(text) to authenticated;

select private.fechar_grants();

-- ---------------------------------------------------------------- definir
-- `dar_pacote` SOMA. Para fixar um saldo (admin corrigindo, teste montando
-- cenario) o que se quer e substituir.
create or replace function private.definir_pacotes(
  p_player uuid, p_slug text, p_diario boolean, p_n int)
returns void
language sql volatile
set search_path = public, extensions, pg_temp
as $fn$
  insert into public.player_packs (player_id, pack_definition_id, do_diario, quantidade)
  select p_player, d.id, p_diario, greatest(p_n, 0)
  from public.pack_definitions d where d.slug = p_slug::extensions.citext
  on conflict (player_id, pack_definition_id, do_diario)
  do update set quantidade = greatest(p_n, 0);
$fn$;

create or replace function private.tem_pacotes(
  p_player uuid, p_slug text, p_diario boolean default false)
returns int
language sql stable
set search_path = public, extensions, pg_temp
as $fn$
  select coalesce((select pp.quantidade from public.player_packs pp
                   join public.pack_definitions d on d.id = pp.pack_definition_id
                   where pp.player_id = p_player and d.slug = p_slug::extensions.citext
                     and pp.do_diario = p_diario), 0);
$fn$;

select private.fechar_grants();


-- ===== 20260823160000_construtor_de_pacotes.sql =====
-- BELESMA figurinhas - o construtor de pacotes do painel admin

-- ================================================================ leitura
create or replace function public.admin_pacotes()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  perform private.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', d.id, 'slug', d.slug::text, 'name', d.name, 'descricao', d.descricao,
      'art_path', d.art_path, 'tamanho', d.tamanho,
      'distribuicao', d.distribuicao::text,
      'elegivel_loja', d.elegivel_loja, 'preco_baba', d.preco_baba,
      'limite_global', d.limite_global, 'aberturas_realizadas', d.aberturas_realizadas,
      'taxa_quente', d.taxa_quente, 'taxa_bonus', d.taxa_bonus,
      'taxa_promocao', d.taxa_promocao,
      'pity_limite', d.pity_limite, 'pity_piso_tier', d.pity_piso_tier,
      'allotment_quantidade', d.allotment_quantidade,
      'diario_quantidade', d.diario_quantidade, 'diario_ciclo', d.diario_ciclo,
      'ativo', d.ativo, 'created_at', d.created_at,
      'em_maos', coalesce((select sum(quantidade) from public.player_packs pp
                           where pp.pack_definition_id = d.id), 0),
      'slots', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', s.id, 'ordem', s.ordem, 'filtro', s.filtro, 'garantido', s.garantido,
          'odds', coalesce((select jsonb_agg(jsonb_build_object('tier', o.tier, 'weight', o.weight)
                                             order by t.tier_order)
                            from public.pack_slot_odds o
                            join public.tiers t on t.slug = o.tier
                            where o.pack_slot_id = s.id), '[]'::jsonb)
        ) order by s.ordem)
        from public.pack_slots s where s.pack_definition_id = d.id), '[]'::jsonb)
    ) order by d.id)
    from public.pack_definitions d), '[]'::jsonb);
end;
$fn$;

-- ================================================================ estoque
-- Quanto ha disponivel de cada tier dentro de um filtro. Base da sugestao de
-- odds, do aviso de esgotamento e da checagem de viabilidade.
create or replace function private.estoque_do_filtro(p_filtro jsonb)
returns table (tier text, tier_order smallint, estoque bigint)
language sql stable
set search_path = public, extensions, pg_temp
as $fn$
  select ct.tier, ct.tier_order, count(*)
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where cc.owner_id is null and not cc.burned
    and ct.id in (select private.tipos_do_filtro(p_filtro))
  group by ct.tier, ct.tier_order
  order by ct.tier_order;
$fn$;

-- ================================================================ sugerir odds
-- Proporcional ao ESTOQUE, amaciado por uma curva que preserva a hierarquia.
--
-- Estoque puro nao serve sozinho: no set atual ha 90 cosmicas e 60 miticas,
-- entao proporcionalidade crua faria a cosmica - que e MAIS rara - sair com
-- mais frequencia que a mitica. A curva impede isso: descendo a escada, o
-- peso de um tier nunca passa de 60% do peso do tier imediatamente mais
-- comum que tenha estoque.
create or replace function private.sugerir_odds(p_filtro jsonb)
returns jsonb
language plpgsql stable
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_r      record;
  v_peso   numeric;
  v_ant    numeric := null;
  v_soma   numeric := 0;
  v_linhas jsonb := '[]'::jsonb;
  v_saida  jsonb := '[]'::jsonb;
  v_decaimento constant numeric := 0.6;
begin
  for v_r in select * from private.estoque_do_filtro(p_filtro) loop
    v_peso := v_r.estoque::numeric;
    if v_ant is not null then v_peso := least(v_peso, v_ant * v_decaimento); end if;
    if v_peso <= 0 then continue; end if;
    v_ant  := v_peso;
    v_soma := v_soma + v_peso;
    v_linhas := v_linhas || jsonb_build_object(
      'tier', v_r.tier, 'tier_order', v_r.tier_order,
      'estoque', v_r.estoque, 'bruto', v_peso);
  end loop;

  if v_soma = 0 then
    return jsonb_build_object('odds', '[]'::jsonb, 'aviso',
      'nenhuma copia disponivel casa com este filtro');
  end if;

  select jsonb_agg(jsonb_build_object(
    'tier', x->>'tier',
    'weight', round((x->>'bruto')::numeric * 100 / v_soma, 2),
    'estoque', (x->>'estoque')::bigint,
    -- quantas aberturas ate este tier acabar, na frequencia sugerida
    'aberturas_ate_esgotar',
      case when (x->>'bruto')::numeric > 0
           then floor((x->>'estoque')::numeric
                      / ((x->>'bruto')::numeric / v_soma))::bigint end
  ) order by (x->>'tier_order')::int) into v_saida
  from jsonb_array_elements(v_linhas) x;

  -- arredondamento: sobra ou falta vai para o tier mais comum, que e o de
  -- maior peso e onde a diferenca menos se nota
  return jsonb_build_object(
    'odds', v_saida,
    'soma', (select round(sum((o->>'weight')::numeric), 2)
             from jsonb_array_elements(v_saida) o),
    'decaimento', v_decaimento);
end;
$fn$;

create or replace function public.admin_sugerir_odds(p_filtro jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  perform private.require_admin();
  return private.sugerir_odds(p_filtro);
end;
$fn$;

-- ================================================================ valor esperado
-- EV em baba: soma, sobre todos os slots e tiers, de probabilidade x preco
-- de venda do tier. Leva a variancia em conta - quente, promocao e bonus
-- mudam o valor medio de um pacote e ignora-los subestima o EV.
create or replace function public.admin_ev_pacote(p_id int)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  d          public.pack_definitions;
  v_s        record;
  v_ev_ref   numeric := 0;
  v_ev       numeric := 0;
  v_ev_gar   numeric := 0;
  v_ev_nao   numeric := 0;
  v_n_nao    int := 0;
  v_min      numeric := 0;
  v_max      numeric := 0;
  v_var      numeric := 0;
  v_ev1      numeric := 0;
  v_primeiro boolean := true;
begin
  perform private.require_admin();
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;

  -- EV do slot de referencia (o garantido de maior ordem), usado por quente
  -- e promocao
  select coalesce(sum(o.weight * coalesce(private.preco('venda_' || o.tier), 0))
                  / nullif(sum(o.weight), 0), 0)
    into v_ev_ref
  from public.pack_slot_odds o
  where o.pack_slot_id = (select id from public.pack_slots
                          where pack_definition_id = d.id and garantido
                          order by ordem desc limit 1);

  for v_s in
    select s.id, s.ordem, s.garantido,
           coalesce(sum(o.weight), 0)                                   as peso,
           -- Prisma nao tem `venda_prisma` porque prisma nao se vende, e um
           -- null aqui envenenava a soma inteira. Vale 0 no EV, e esta certo:
           -- o EV responde "da para lucrar vendendo o conteudo?", e conteudo
           -- invendavel nao financia nada.
           coalesce(sum(o.weight * coalesce(private.preco('venda_' || o.tier), 0)), 0) as soma_val,
           coalesce(sum(o.weight * power(coalesce(private.preco('venda_' || o.tier), 0), 2)), 0) as soma_q,
           min(coalesce(private.preco('venda_' || o.tier), 0))          as menor,
           max(coalesce(private.preco('venda_' || o.tier), 0))          as maior
    from public.pack_slots s
    left join public.pack_slot_odds o on o.pack_slot_id = s.id and o.weight > 0
    where s.pack_definition_id = d.id
    group by s.id, s.ordem, s.garantido
    order by s.ordem
  loop
    continue when v_s.peso = 0;
    declare
      v_mu numeric := v_s.soma_val / v_s.peso;
      v_e2 numeric := v_s.soma_q  / v_s.peso;
    begin
      if v_s.garantido then
        v_ev_gar := v_ev_gar + v_mu;
      else
        v_ev_nao := v_ev_nao + v_mu;
        v_n_nao  := v_n_nao + 1;
      end if;
      v_var := v_var + (v_e2 - v_mu * v_mu);
      v_min := v_min + v_s.menor;
      v_max := v_max + v_s.maior;
      if v_primeiro then v_ev1 := v_mu; v_primeiro := false; end if;
    end;
  end loop;

  -- quente troca TODOS os nao garantidos pelo de referencia; fora dele, cada
  -- nao garantido tem taxa_promocao de virar o de referencia
  v_ev :=
      d.taxa_quente * (v_ev_ref * v_n_nao + v_ev_gar)
    + (1 - d.taxa_quente) * (
        v_ev_gar
        + d.taxa_promocao * v_ev_ref * v_n_nao
        + (1 - d.taxa_promocao) * v_ev_nao)
    -- carta bonus repete o primeiro slot
    + d.taxa_bonus * v_ev1;

  return jsonb_build_object(
    'ev', round(v_ev, 2),
    'ev_minimo', round(v_min, 2),
    'ev_maximo', round(v_max + (case when d.taxa_bonus > 0 then v_ev1 else 0 end), 2),
    'desvio', round(sqrt(greatest(v_var, 0)), 2),
    'ev_do_slot_garantido', round(v_ev_ref, 2),
    'preco', d.preco_baba,
    'piso',      round(v_ev * private.preco('preco_multiplicador_piso'), 0),
    'sugerido',  round(v_ev * private.preco('preco_multiplicador_sugerido'), 0),
    'teto_aviso',round(v_ev * private.preco('preco_multiplicador_alerta'), 0),
    'margem_pct', case when v_ev > 0 and d.preco_baba is not null
                       then round((d.preco_baba / v_ev - 1) * 100, 1) end,
    'ev_da_edicao', case when d.limite_global is not null
                         then round(v_ev * d.limite_global, 0) end);
end;
$fn$;

-- ================================================================ viabilidade
create or replace function public.admin_viabilidade_pacote(p_id int)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  d       public.pack_definitions;
  v_s     record;
  v_o     record;
  v_ev    jsonb;
  v_av    jsonb := '[]'::jsonb;
  v_soma  numeric;
  v_est   bigint;
  v_gasta numeric;
begin
  perform private.require_admin();
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;

  if not exists (select 1 from public.pack_slots where pack_definition_id = d.id) then
    v_av := v_av || jsonb_build_object('nivel','erro',
      'texto','o pacote nao tem slot nenhum: abrir vai falhar');
  end if;

  if d.tamanho <> (select count(*) from public.pack_slots where pack_definition_id = d.id) then
    v_av := v_av || jsonb_build_object('nivel','aviso', 'texto',
      format('tamanho diz %s cartas mas ha %s slots; quem manda e o numero de slots',
             d.tamanho, (select count(*) from public.pack_slots where pack_definition_id = d.id)));
  end if;

  for v_s in select * from public.pack_slots where pack_definition_id = d.id order by ordem loop
    select coalesce(sum(weight), 0) into v_soma
    from public.pack_slot_odds where pack_slot_id = v_s.id;

    if abs(v_soma - 100) > 0.01 then
      v_av := v_av || jsonb_build_object('nivel','erro', 'slot', v_s.ordem,
        'texto', format('as odds do slot %s somam %s%%, nao 100%%', v_s.ordem, v_soma));
    end if;

    if not exists (select 1 from private.estoque_do_filtro(v_s.filtro)) then
      v_av := v_av || jsonb_build_object('nivel','erro', 'slot', v_s.ordem,
        'texto', format('o filtro do slot %s nao casa com nenhuma copia disponivel', v_s.ordem));
    end if;

    -- tier das odds sem estoque dentro do filtro
    for v_o in
      select o.tier, o.weight from public.pack_slot_odds o
      where o.pack_slot_id = v_s.id and o.weight > 0
        and not exists (select 1 from private.estoque_do_filtro(v_s.filtro) e
                        where e.tier = o.tier)
    loop
      v_av := v_av || jsonb_build_object('nivel','aviso', 'slot', v_s.ordem,
        'texto', format('slot %s pede %s (%s%%) mas nao ha %s disponivel dentro do filtro',
                        v_s.ordem, v_o.tier, v_o.weight, v_o.tier));
    end loop;

    -- quantas aberturas ate o tier mais raro do slot esgotar
    select e.estoque, o.weight / nullif(v_soma, 0) into v_est, v_gasta
    from public.pack_slot_odds o
    join public.tiers t on t.slug = o.tier
    join lateral private.estoque_do_filtro(v_s.filtro) e on e.tier = o.tier
    where o.pack_slot_id = v_s.id and o.weight > 0
    order by t.tier_order desc limit 1;

    if v_est is not null and v_gasta > 0 and floor(v_est / v_gasta) < 20 then
      v_av := v_av || jsonb_build_object('nivel','aviso', 'slot', v_s.ordem,
        'texto', format('o tier mais raro do slot %s esgota em ~%s aberturas',
                        v_s.ordem, floor(v_est / v_gasta)));
    end if;

    if d.elegivel_loja and exists (
      select 1 from public.pack_slot_odds o
      where o.pack_slot_id = v_s.id and o.weight > 0
        and o.tier in ('prisma','aura','diamante'))
    then
      v_av := v_av || jsonb_build_object('nivel','aviso', 'slot', v_s.ordem,
        'texto', format('slot %s tem tier de topo num pacote comprável: prisma, aura e '
                     || 'diamante somam poucas dezenas de copias no mundo e drenam '
                     || 'mais rapido do que se pretende', v_s.ordem));
    end if;
  end loop;

  if d.elegivel_loja then
    v_ev := public.admin_ev_pacote(d.id);
    if d.preco_baba is not null and (v_ev->>'piso') is not null
       and d.preco_baba < (v_ev->>'piso')::numeric then
      v_av := v_av || jsonb_build_object('nivel','erro', 'texto',
        'Preco abaixo do piso - este pacote permite lucro vendendo o conteudo, '
        || 'criando geracao infinita de baba.');
    end if;
    if d.preco_baba is not null and (v_ev->>'teto_aviso') is not null
       and d.preco_baba > (v_ev->>'teto_aviso')::numeric then
      v_av := v_av || jsonb_build_object('nivel','aviso', 'texto',
        format('preco %s esta acima de EV x 5 (%s): provavelmente ninguem compra',
               d.preco_baba, v_ev->>'teto_aviso'));
    end if;
  end if;

  return jsonb_build_object('avisos', v_av,
    'erros', (select count(*) from jsonb_array_elements(v_av) a where a->>'nivel' = 'erro'));
end;
$fn$;

-- ================================================================ preview
-- Simula N aberturas SEM GRAVAR NADA. Nao chama open_pack de proposito: o
-- open_pack entrega cartas de verdade, e um preview que mexe no acervo nao e
-- preview. Aqui e amostragem sobre a mesma configuracao e o mesmo estoque.
create or replace function public.admin_preview_pacote(p_id int, p_n int default 1000)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  d          public.pack_definitions;
  v_ids      int[];
  v_id_slot  int;
  v_slot     public.pack_slots;
  v_uso      public.pack_slots;
  v_ref      public.pack_slots;
  v_i        int;
  v_bonus    boolean;
  v_quente   boolean;
  v_tier     text;
  v_tipo     record;
  v_por_tier jsonb := '{}'::jsonb;
  v_por_char jsonb := '{}'::jsonb;
  v_cartas   int := 0;
  v_valor    numeric := 0;
begin
  perform private.require_admin();
  if p_n is null or p_n < 1 or p_n > 20000 then raise exception 'n entre 1 e 20000'; end if;
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;

  select array_agg(id order by ordem) into v_ids
  from public.pack_slots where pack_definition_id = d.id;
  if v_ids is null then raise exception 'o pacote nao tem slot nenhum'; end if;

  select * into v_ref from public.pack_slots
  where pack_definition_id = d.id and garantido order by ordem desc limit 1;

  for v_i in 1 .. p_n loop
    v_quente := private.random_int(100000) < d.taxa_quente * 100000;
    v_bonus  := private.random_int(100000) < d.taxa_bonus  * 100000;

    foreach v_id_slot in array (case when v_bonus then v_ids || v_ids[1] else v_ids end) loop
      select * into v_slot from public.pack_slots where id = v_id_slot;
      v_uso := v_slot;
      if v_ref.id is not null and not v_slot.garantido
         and (v_quente or private.random_int(100000) < d.taxa_promocao * 100000) then
        v_uso := v_ref;
      end if;

      -- sorteia o tier entre os que TEM estoque dentro do filtro
      select o.tier into v_tier
      from public.pack_slot_odds o
      join lateral private.estoque_do_filtro(v_uso.filtro) e on e.tier = o.tier
      where o.pack_slot_id = v_uso.id and o.weight > 0
      order by -ln(1 - (private.random_int(1000000)::numeric / 1000000)) / o.weight
      limit 1;
      continue when v_tier is null;

      -- e um tipo dentro do tier, proporcional ao estoque
      select ct.tier, ch.slug as personagem into v_tipo
      from public.card_types ct
      join public.characters ch on ch.id = ct.character_id
      join public.card_copies cc on cc.card_type_id = ct.id
      where ct.tier = v_tier and cc.owner_id is null and not cc.burned
        and ct.id in (select private.tipos_do_filtro(v_uso.filtro))
      order by extensions.gen_random_bytes(8) limit 1;
      continue when v_tipo is null;

      v_cartas   := v_cartas + 1;
      v_valor    := v_valor + coalesce(private.preco('venda_' || v_tier), 0);
      v_por_tier := jsonb_set(v_por_tier, array[v_tier],
                      to_jsonb(coalesce((v_por_tier->>v_tier)::int, 0) + 1));
      v_por_char := jsonb_set(v_por_char, array[v_tipo.personagem],
                      to_jsonb(coalesce((v_por_char->>v_tipo.personagem)::int, 0) + 1));
    end loop;
  end loop;

  return jsonb_build_object(
    'aberturas', p_n,
    'cartas', v_cartas,
    'cartas_por_abertura', round(v_cartas::numeric / p_n, 2),
    'valor_medio', round(v_valor / p_n, 2),
    -- o fecho do coalesce vem ANTES do from: `coalesce(agg(...) from ...)`
    -- deixa o coalesce aberto quando o from aparece, e o parser reclama
    'por_tier', (select coalesce(jsonb_agg(jsonb_build_object(
                     'tier', e.k, 'n', e.v::int,
                     'pct', round(e.v::numeric * 100 / nullif(v_cartas, 0), 2))
                     order by t.tier_order desc), '[]'::jsonb)
                 from jsonb_each_text(v_por_tier) as e(k, v)
                 join public.tiers t on t.slug = e.k),
    'por_personagem', (select coalesce(jsonb_agg(jsonb_build_object(
                     'personagem', e.k, 'n', e.v::int,
                     'pct', round(e.v::numeric * 100 / nullif(v_cartas, 0), 2))
                     order by e.k), '[]'::jsonb)
                 from jsonb_each_text(v_por_char) as e(k, v)));
end;
$fn$;

-- ================================================================ relatorio
create or replace function public.admin_relatorio_loja()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_d record; v_ev jsonb; v_out jsonb := '[]'::jsonb;
begin
  perform private.require_admin();
  for v_d in select * from public.pack_definitions where elegivel_loja order by id loop
    v_ev := public.admin_ev_pacote(v_d.id);
    v_out := v_out || jsonb_build_object(
      'id', v_d.id, 'slug', v_d.slug::text, 'name', v_d.name, 'ativo', v_d.ativo,
      'preco', v_d.preco_baba,
      'ev', v_ev->'ev', 'piso', v_ev->'piso', 'sugerido', v_ev->'sugerido',
      'margem_pct', v_ev->'margem_pct',
      'abaixo_do_piso', (v_d.preco_baba < (v_ev->>'piso')::numeric),
      'compras', (select count(*) from public.baba_log
                  where motivo = 'compra' and ref_id = v_d.slug::text),
      'aberturas', v_d.aberturas_realizadas, 'limite', v_d.limite_global);
  end loop;
  return v_out;
end;
$fn$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_pacotes()', 'admin_sugerir_odds(jsonb)', 'admin_ev_pacote(int)',
    'admin_viabilidade_pacote(int)', 'admin_preview_pacote(int, int)',
    'admin_relatorio_loja()']
  loop
    execute format('alter function public.%s owner to postgres', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

select private.fechar_grants();


-- ===== 20260823170000_construtor_escrita.sql =====
-- BELESMA figurinhas - criar e editar pacote pelo painel

-- Recebe a definicao INTEIRA num jsonb - cabecalho e slots juntos - e grava
-- em uma transacao. Editar slot por slot deixaria o pacote num estado
-- intermediario invalido (odds nao somando 100) por alguns milissegundos, e
-- alguem podendo abrir nesse intervalo.
--
--   { id, slug, name, descricao, art_path, tamanho, distribuicao,
--     elegivel_loja, preco_baba, limite_global, ativo,
--     taxa_quente, taxa_bonus, taxa_promocao, pity_limite, pity_piso_tier,
--     allotment_quantidade, diario_quantidade, diario_ciclo,
--     slots: [ { ordem, filtro, garantido, odds: [{tier, weight}] } ] }
create or replace function public.admin_salvar_pacote(p_def jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_id     int := nullif(p_def->>'id', '')::int;
  v_novo   boolean := v_id is null;
  v_slug   extensions.citext := lower(trim(p_def->>'slug'))::extensions.citext;
  v_s      jsonb;
  v_o      jsonb;
  v_slot   int;
  v_soma   numeric;
  v_ordem  int := 0;
  v_ev     jsonb;
  v_piso   numeric;
begin
  perform private.require_admin();

  if v_slug is null or length(v_slug::text) < 2 then
    raise exception 'slug obrigatorio';
  end if;
  if v_slug::text !~ '^[a-z0-9][a-z0-9_-]{1,29}$' then
    raise exception 'slug: minusculas, numeros, - e _, de 2 a 30 caracteres';
  end if;
  if coalesce(jsonb_array_length(p_def->'slots'), 0) = 0 then
    raise exception 'um pacote precisa de pelo menos um slot';
  end if;

  -- odds de cada slot precisam somar 100 ANTES de qualquer escrita
  for v_s in select * from jsonb_array_elements(p_def->'slots') loop
    select coalesce(sum((o->>'weight')::numeric), 0) into v_soma
    from jsonb_array_elements(v_s->'odds') o;
    if abs(v_soma - 100) > 0.01 then
      raise exception 'as odds de um slot somam %, precisam somar 100', v_soma;
    end if;
    if exists (select 1 from jsonb_array_elements(v_s->'odds') o
               where not exists (select 1 from public.tiers where slug = o->>'tier')) then
      raise exception 'ha um tier que nao existe nas odds';
    end if;
  end loop;

  -- ------------------------------------------------------------- cabecalho
  if v_novo then
    insert into public.pack_definitions (
      slug, name, descricao, art_path, tamanho, distribuicao, elegivel_loja,
      preco_baba, limite_global, ativo, taxa_quente, taxa_bonus, taxa_promocao,
      pity_limite, pity_piso_tier, allotment_quantidade, diario_quantidade,
      diario_ciclo, created_by)
    values (
      v_slug, p_def->>'name', p_def->>'descricao', p_def->>'art_path',
      (p_def->>'tamanho')::int, (p_def->>'distribuicao')::public.pack_distribuicao,
      coalesce((p_def->>'elegivel_loja')::boolean, false),
      nullif(p_def->>'preco_baba','')::int, nullif(p_def->>'limite_global','')::int,
      coalesce((p_def->>'ativo')::boolean, true),
      coalesce((p_def->>'taxa_quente')::numeric, 0),
      coalesce((p_def->>'taxa_bonus')::numeric, 0),
      coalesce((p_def->>'taxa_promocao')::numeric, 0),
      nullif(p_def->>'pity_limite','')::int, nullif(p_def->>'pity_piso_tier',''),
      coalesce((p_def->>'allotment_quantidade')::int, 0),
      coalesce((p_def->>'diario_quantidade')::int, 0),
      coalesce((p_def->>'diario_ciclo')::int, 1),
      auth.uid())
    returning id into v_id;
  else
    update public.pack_definitions set
      slug = v_slug, name = p_def->>'name', descricao = p_def->>'descricao',
      art_path = p_def->>'art_path', tamanho = (p_def->>'tamanho')::int,
      distribuicao = (p_def->>'distribuicao')::public.pack_distribuicao,
      elegivel_loja = coalesce((p_def->>'elegivel_loja')::boolean, false),
      preco_baba = nullif(p_def->>'preco_baba','')::int,
      limite_global = nullif(p_def->>'limite_global','')::int,
      ativo = coalesce((p_def->>'ativo')::boolean, true),
      taxa_quente = coalesce((p_def->>'taxa_quente')::numeric, 0),
      taxa_bonus = coalesce((p_def->>'taxa_bonus')::numeric, 0),
      taxa_promocao = coalesce((p_def->>'taxa_promocao')::numeric, 0),
      pity_limite = nullif(p_def->>'pity_limite','')::int,
      pity_piso_tier = nullif(p_def->>'pity_piso_tier',''),
      allotment_quantidade = coalesce((p_def->>'allotment_quantidade')::int, 0),
      diario_quantidade = coalesce((p_def->>'diario_quantidade')::int, 0),
      diario_ciclo = coalesce((p_def->>'diario_ciclo')::int, 1)
    where id = v_id;
    if not found then raise exception 'pacote % nao existe', v_id; end if;
  end if;

  -- ------------------------------------------------------------- slots
  delete from public.pack_slots where pack_definition_id = v_id;
  for v_s in select * from jsonb_array_elements(p_def->'slots') loop
    v_ordem := v_ordem + 1;
    insert into public.pack_slots (pack_definition_id, ordem, filtro, garantido)
    values (v_id, v_ordem, coalesce(v_s->'filtro', '{}'::jsonb),
            coalesce((v_s->>'garantido')::boolean, false))
    returning id into v_slot;

    for v_o in select * from jsonb_array_elements(v_s->'odds') loop
      if (v_o->>'weight')::numeric > 0 then
        insert into public.pack_slot_odds (pack_slot_id, tier, weight)
        values (v_slot, v_o->>'tier', (v_o->>'weight')::numeric);
      end if;
    end loop;
  end loop;

  -- ------------------------------------------------------------- piso
  -- Depois dos slots, porque o EV depende deles. Este e o unico bloqueio
  -- duro do construtor: abaixo do piso o pacote se paga vendendo o proprio
  -- conteudo, e isso e uma impressora de baba.
  if coalesce((p_def->>'elegivel_loja')::boolean, false) then
    v_ev := public.admin_ev_pacote(v_id);
    v_piso := (v_ev->>'piso')::numeric;
    if nullif(p_def->>'preco_baba','')::numeric is null then
      raise exception 'pacote de loja precisa de preco';
    end if;
    if (p_def->>'preco_baba')::numeric < v_piso then
      -- literal inteiro numa linha so: RAISE quer um literal, nao expressao,
      -- entao `'a' || 'b'` como formato e erro de sintaxe
      raise exception 'Preco abaixo do piso - este pacote permite lucro vendendo o conteudo, criando geracao infinita de baba. (EV %, piso %)',
        v_ev->>'ev', v_piso;
    end if;
  end if;

  perform private.registrar(
    case when v_novo then 'pacote_criado' else 'pacote_editado' end,
    v_slug::text, p_def);

  return jsonb_build_object('id', v_id, 'slug', v_slug::text, 'novo', v_novo,
                            'ev', public.admin_ev_pacote(v_id),
                            'viabilidade', public.admin_viabilidade_pacote(v_id));
end;
$fn$;

-- ---------------------------------------------------------------- ativar
create or replace function public.admin_pacote_ativo(p_id int, p_ativo boolean)
returns boolean
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_slug text;
begin
  perform private.require_admin();
  update public.pack_definitions set ativo = p_ativo where id = p_id
  returning slug::text into v_slug;
  if v_slug is null then raise exception 'pacote nao existe'; end if;
  perform private.registrar('pacote_ativo', v_slug, jsonb_build_object('ativo', p_ativo));
  return p_ativo;
end;
$fn$;

-- ---------------------------------------------------------------- apagar
create or replace function public.admin_apagar_pacote(p_id int, p_confirmacao text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare d public.pack_definitions; v_maos bigint;
begin
  perform private.require_admin();
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;
  if p_confirmacao <> d.slug::text then
    raise exception 'confirmacao invalida: digite %', d.slug;
  end if;

  -- Pacote ja aberto tem historico apontando para ele; apagar reescreveria o
  -- passado. Desativar e o caminho.
  if d.aberturas_realizadas > 0 then
    raise exception '"%" ja foi aberto % vezes: desative em vez de apagar',
      d.name, d.aberturas_realizadas;
  end if;
  select coalesce(sum(quantidade), 0) into v_maos
  from public.player_packs where pack_definition_id = d.id;
  if v_maos > 0 then
    raise exception 'ha % copias de "%" na mao de jogadores', v_maos, d.name;
  end if;

  delete from public.pack_definitions where id = p_id;
  perform private.registrar('pacote_apagado', d.slug::text, to_jsonb(d));
  return jsonb_build_object('apagado', d.slug::text);
end;
$fn$;

-- ---------------------------------------------------------------- entregar
create or replace function public.admin_entregar_pacote(
  p_id int, p_target text, p_quantidade int, p_diario boolean default false)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare d public.pack_definitions; v_n int := 0; v_p record;
begin
  perform private.require_admin();
  if p_quantidade is null or p_quantidade = 0 then raise exception 'quantidade invalida'; end if;
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;

  for v_p in
    select id from public.players
    where p_target = 'todos' or nickname = p_target::extensions.citext
  loop
    if p_quantidade > 0 then
      perform private.dar_pacote(v_p.id, d.id, p_diario, p_quantidade);
    else
      update public.player_packs set quantidade = greatest(0, quantidade + p_quantidade)
      where player_id = v_p.id and pack_definition_id = d.id and do_diario = p_diario;
    end if;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then raise exception 'nenhum jogador casou com "%"', p_target; end if;

  perform private.registrar('pacote_entregue', p_target,
    jsonb_build_object('pacote', d.slug::text, 'quantidade', p_quantidade,
                       'diario', p_diario, 'jogadores', v_n));
  return v_n;
end;
$fn$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_salvar_pacote(jsonb)', 'admin_pacote_ativo(int, boolean)',
    'admin_apagar_pacote(int, text)', 'admin_entregar_pacote(int, text, int, boolean)']
  loop
    execute format('alter function public.%s owner to postgres', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

select private.fechar_grants();


-- ===== 20260823180000_pacotes_exemplo.sql =====
-- BELESMA figurinhas - tres pacotes de exemplo, feitos so com dados
--
-- Nenhuma linha de codigo novo: sao linhas de pack_definitions, pack_slots e
-- pack_slot_odds. E a prova de que o construtor faz o que promete.
--
-- Os tres nascem com distribuicao 'admin' e elegivel_loja = false. Ligar a
-- loja e um toggle no painel, e o piso de preco entra em vigor no mesmo ato.

create or replace function private.criar_pacote_exemplo(
  p_slug text, p_nome text, p_desc text, p_tamanho int, p_filtro jsonb)
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_def   int;
  v_slot  int;
  v_odds  jsonb;
  v_o     jsonb;
  v_i     int;
begin
  if exists (select 1 from public.pack_definitions where slug = p_slug::extensions.citext) then
    return (select id from public.pack_definitions where slug = p_slug::extensions.citext);
  end if;

  v_odds := private.sugerir_odds(p_filtro)->'odds';
  if v_odds is null or jsonb_array_length(v_odds) = 0 then
    raise notice 'filtro de "%" nao casa com nada, pacote nao criado', p_slug;
    return null;
  end if;

  insert into public.pack_definitions
    (slug, name, descricao, art_path, tamanho, distribuicao, elegivel_loja, ativo)
  values (p_slug::extensions.citext, p_nome, p_desc,
          'packs/booster-comum.png', p_tamanho, 'admin', false, true)
  returning id into v_def;

  for v_i in 1 .. p_tamanho loop
    insert into public.pack_slots (pack_definition_id, ordem, filtro, garantido)
    values (v_def, v_i, p_filtro, false)
    returning id into v_slot;

    for v_o in select * from jsonb_array_elements(v_odds) loop
      insert into public.pack_slot_odds (pack_slot_id, tier, weight)
      values (v_slot, v_o->>'tier', (v_o->>'weight')::numeric);
    end loop;

    -- a sugestao arredonda a 2 casas; a sobra vai para o tier de maior peso,
    -- que e onde a diferenca menos aparece
    update public.pack_slot_odds set weight = weight + (
      100 - (select sum(weight) from public.pack_slot_odds where pack_slot_id = v_slot))
    where id = (select id from public.pack_slot_odds
                where pack_slot_id = v_slot order by weight desc limit 1);
  end loop;

  return v_def;
end;
$fn$;

do $$
begin
  -- fogo, gelo, trovao e vento sao as quatro skins RARAS: o pacote inteiro
  -- sai de um tier so, e a sugestao de odds devolve rara 100%
  perform private.criar_pacote_exemplo(
    'elementais', 'Elementais',
    'Quatro cartas, todas dos quatro elementos: fogo, gelo, trovao e vento.',
    4, '{"skins": ["fogo","gelo","trovao","vento"]}'::jsonb);

  -- esmeralda, rubi, safira e ametista sao as quatro EPICAS
  perform private.criar_pacote_exemplo(
    'joias', 'Joias',
    'Quatro cartas de pedra preciosa: esmeralda, rubi, safira e ametista.',
    4, '{"skins": ["esmeralda","rubi","safira","ametista"]}'::jsonb);

  -- so o Pedrao, escada inteira a partir de comum. Aqui a sugestao mostra o
  -- que sabe fazer: distribui pelos doze tiers na proporcao do estoque, sem
  -- deixar um tier raro ficar mais provavel que um comum.
  perform private.criar_pacote_exemplo(
    'pedrao-comum-mais', 'Pedrao Comum+',
    'So o Belesma do Pedrao, de comum para cima.',
    4, '{"characters": ["pedrao"], "tiers_min": "comum"}'::jsonb);
end $$;

select private.fechar_grants();


-- ===== 20260823190000_boosters_por_personagem.sql =====
-- BELESMA figurinhas - o pacote dirigido vira um booster por personagem

-- O "pacote dirigido" era um parametro escondido em comprar_pacote: um
-- select na loja mandava p_character_id e o preco dobrava. Ninguem via um
-- produto - via um modificador. E ele nao existia no catalogo, entao nao
-- tinha arte, nem descricao, nem EV proprio, nem aparecia no relatorio.
--
-- Vira definicao de verdade: um booster por personagem, com o filtro no
-- proprio slot. Mesma estrutura do Booster Comum, so que restrito.
create or replace function private.criar_booster_de_personagem(p_character_id int)
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_ch    public.characters;
  v_base  public.pack_definitions;
  v_slug  text;
  v_def   int;
  v_slot  int;
  v_s     record;
  v_mult  numeric;
  v_curto text;
begin
  select * into v_ch from public.characters where id = p_character_id;
  if v_ch.id is null then raise exception 'personagem % nao existe', p_character_id; end if;

  v_slug := 'booster-' || v_ch.slug;
  if exists (select 1 from public.pack_definitions where slug = v_slug::extensions.citext) then
    return (select id from public.pack_definitions where slug = v_slug::extensions.citext);
  end if;

  -- o molde e o Booster Comum: mesmas odds, mesma variancia, mesmo tamanho
  select * into v_base from public.pack_definitions where slug = 'comum';
  if v_base.id is null then
    raise notice 'sem Booster Comum de molde, nada a criar';
    return null;
  end if;
  v_mult := coalesce(private.preco('dirigido_mult'), 2);
  -- characters.name ja e "Belesma do Pedrao"; sem tirar o prefixo o produto
  -- vira "Booster Belesma do Pedrao", que ninguem chama assim
  v_curto := regexp_replace(v_ch.name, '^\s*Belesma\s+(do|da|de|dos|das)?\s*', '', 'i');
  if v_curto = '' then v_curto := v_ch.name; end if;

  insert into public.pack_definitions (
    slug, name, descricao, art_path, tamanho, distribuicao, elegivel_loja,
    preco_baba, taxa_quente, taxa_bonus, taxa_promocao, pity_limite, pity_piso_tier,
    ativo)
  values (
    v_slug::extensions.citext,
    'Booster ' || v_curto,
    'Só ' || v_ch.name || '. Mesmas odds do Comum, restrito a um Belesma — '
      || 'serve para fechar página do álbum.',
    v_base.art_path,
    v_base.tamanho, 'loja', true,
    ceil(v_base.preco_baba * v_mult)::int,
    v_base.taxa_quente, v_base.taxa_bonus, v_base.taxa_promocao,
    v_base.pity_limite, v_base.pity_piso_tier,
    true)
  returning id into v_def;

  -- copia os slots do molde, acrescentando o filtro do personagem
  for v_s in select * from public.pack_slots
             where pack_definition_id = v_base.id order by ordem
  loop
    insert into public.pack_slots (pack_definition_id, ordem, filtro, garantido)
    values (v_def, v_s.ordem,
            coalesce(v_s.filtro, '{}'::jsonb)
              || jsonb_build_object('characters', jsonb_build_array(v_ch.slug)),
            v_s.garantido)
    returning id into v_slot;

    insert into public.pack_slot_odds (pack_slot_id, tier, weight)
    select v_slot, o.tier, o.weight
    from public.pack_slot_odds o where o.pack_slot_id = v_s.id;
  end loop;

  return v_def;
end;
$fn$;

-- um para cada personagem que ja existe
do $$
declare v_c record;
begin
  for v_c in select id, slug from public.characters order by display_order, id loop
    perform private.criar_booster_de_personagem(v_c.id);
  end loop;
end $$;

-- ---------------------------------------------------------------- futuro
-- O quarto personagem entra por seed_edition. O booster dele nasce junto:
-- sem isto, alguem teria que lembrar de criar na mao, e a loja ficaria com
-- tres boosters e quatro Belesmas.
create or replace function public.admin_criar_booster_faltando()
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_c record; v_criados jsonb := '[]'::jsonb; v_id int;
begin
  perform private.require_admin();
  for v_c in select id, slug, name from public.characters order by display_order, id loop
    if not exists (select 1 from public.pack_definitions
                   where slug = ('booster-' || v_c.slug)::extensions.citext) then
      v_id := private.criar_booster_de_personagem(v_c.id);
      v_criados := v_criados || jsonb_build_object('id', v_id, 'personagem', v_c.name);
    end if;
  end loop;
  if jsonb_array_length(v_criados) > 0 then
    perform private.registrar('boosters_de_personagem_criados', null, v_criados);
  end if;
  return v_criados;
end;
$fn$;

-- ---------------------------------------------------------------- dirigido
-- O parametro some. Deixar aceitar em silencio faria a loja cobrar o dobro e
-- entregar um pacote sem filtro nenhum - pior que recusar.
create or replace function public.comprar_pacote(p_pack_type text, p_character_id int default null)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_def   public.pack_definitions;
  v_teto  int;
  v_hoje  int;
  v_saldo int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;
  if p_character_id is not null then
    raise exception 'o pacote dirigido virou produto: compre o Booster do personagem na loja';
  end if;

  select * into v_def from public.pack_definitions
  where slug = p_pack_type::extensions.citext;
  if v_def.id is null then raise exception 'pacote "%" nao existe', p_pack_type; end if;
  if not v_def.ativo then raise exception 'pacote "%" esta desativado', v_def.name; end if;
  if not v_def.elegivel_loja then raise exception '"%" nao esta a venda', v_def.name; end if;

  if v_def.limite_global is not null
     and v_def.aberturas_realizadas >= v_def.limite_global then
    raise exception 'edicao esgotada'; end if;

  v_teto := private.preco('teto_compra_dia')::int;
  select count(*) into v_hoje from public.baba_log
  where player_id = v_uid and motivo = 'compra' and created_at > now() - interval '24 hours';
  if v_hoje >= v_teto then
    raise exception 'limite de % compras por dia atingido', v_teto;
  end if;

  v_saldo := private.mover_baba(v_uid, -v_def.preco_baba, 'compra', v_def.slug::text);
  perform private.dar_pacote(v_uid, v_def.id, false, 1);

  return jsonb_build_object('preco', v_def.preco_baba, 'saldo', v_saldo,
    'restantes_hoje', v_teto - v_hoje - 1, 'pack_definition_id', v_def.id,
    'nome', v_def.name);
end;
$fn$;

-- ---------------------------------------------------------------- pack_config
-- A tabela vira registro historico: foi o molde de onde os slots nasceram, e
-- fica como procedencia. Mas EDITAR nao muda nada no jogo desde que o
-- open_pack passou a ler pack_slot_odds - e uma RPC que diz "salvo" sem
-- efeito e pior que uma que nao existe.
-- o original devolvia a diferenca aplicada; agora so recusa, entao muda o
-- tipo de retorno e precisa cair antes
drop function if exists public.admin_set_pack_config(jsonb);
create or replace function public.admin_set_pack_config(p_linhas jsonb)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  perform private.require_admin();
  raise exception 'pack_config nao alimenta mais o sorteio: as odds vivem em pack_slot_odds, por definicao de pacote. Edite em /admin > Pacotes.';
end;
$fn$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_criar_booster_faltando()', 'comprar_pacote(text, int)',
    'admin_set_pack_config(jsonb)']
  loop
    execute format('alter function public.%s owner to postgres', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

select private.fechar_grants();

-- os primeiros nasceram com o nome comprido; renomeia sem recriar
update public.pack_definitions d set name = 'Booster ' ||
  regexp_replace(c.name, '^\s*Belesma\s+(do|da|de|dos|das)?\s*', '', 'i')
from public.characters c
where d.slug = ('booster-' || c.slug)::extensions.citext
  and d.name <> 'Booster ' ||
      regexp_replace(c.name, '^\s*Belesma\s+(do|da|de|dos|das)?\s*', '', 'i');


-- ===== 20260824100000_biscoito_lucas_luiz.sql =====
-- BELESMA figurinhas - entram Biscoito, Lucas e Luiz
--
-- Tres personagens novos, 27 skins cada, pelo mesmo caminho que o
-- seed_edition usa. Fica como migracao e nao como chamada de RPC para o
-- mundo ser reproduzivel: qualquer banco novo (o PGlite dos testes, por
-- exemplo) nasce com os seis.
--
-- O que cada um traz:
--   27 card_types (uma por skin)
--   2214 card_copies, com a tiragem de cada tier
--   selos por CSPRNG: 12 brancos, 4 pretos, 1 rosa
--   500 copias reservadas para o diario
--
-- O acervo do mundo passa de 6642 para 13284, e os selos de 36/12/3 para
-- 72/24/6. Isso muda a escassez de tudo - inclusive quem tem a joia do
-- servidor - e e assim que tem que ser: o censo se recalcula sozinho.

do $$
declare
  v_c    record;
  v_id   int;
  v_n    int;
begin
  for v_c in
    select * from (values
      ('biscoito', 'Belesma do Biscoito', 4, '#c98b3a', '#f2d08a'),
      ('lucas',    'Belesma do Lucas',    5, '#3a6fc9', '#8ab6f2'),
      ('luiz',     'Belesma do Luiz',     6, '#3ac98b', '#8af2c4')
    ) as t(slug, nome, ordem, primaria, acento)
  loop
    -- Idempotente por slug, igual ao seed_edition: se ja existe, nao encosta
    -- em card_copies. Reaplicar a cadeia inteira nao pode duplicar acervo.
    if exists (select 1 from public.characters
               where slug = v_c.slug::extensions.citext) then
      raise notice '% ja existe, pulando', v_c.slug;
      continue;
    end if;

    insert into public.characters (slug, name, display_order, palette_primary, palette_accent)
    values (v_c.slug::extensions.citext, v_c.nome, v_c.ordem, v_c.primaria, v_c.acento)
    returning id into v_id;

    insert into public.card_types (character_id, tier, tier_order, skin, print_run, art_path, album_page)
    select v_id, s.tier, t.tier_order, s.slug, t.print_run,
           '/figurinhas/' || v_c.slug || '/' || s.slug || '.jpg', ap.id
    from public.skins s
    join public.tiers t on t.slug = s.tier
    join public.album_pages ap on ap.slug = s.slug;

    -- o verify_code e deterministico por (personagem, skin, serial): a mesma
    -- carta gera o mesmo codigo em qualquer banco, e /v/<codigo> funciona
    insert into public.card_copies (card_type_id, serial_number, verify_code)
    select ct.id, g,
           upper(substr(encode(extensions.digest(
             'belesma-v1|' || v_c.slug || '|' || ct.skin || '|' || g::text, 'sha256'),
             'hex'), 1, 10))
    from public.card_types ct
    cross join lateral generate_series(1, ct.print_run) g
    where ct.character_id = v_id;

    perform private.distribuir_selos(v_id);
    perform private.reservar_diario(v_id, 500);

    select count(*) into v_n
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    where ct.character_id = v_id;
    raise notice '% : % copias', v_c.slug, v_n;
  end loop;
end $$;

-- ---------------------------------------------------------------- boosters
-- Um Booster por personagem, como os tres primeiros. Sem isto a loja ficaria
-- com tres boosters e seis Belesmas.
do $$
declare v_c record;
begin
  for v_c in select id from public.characters order by display_order, id loop
    perform private.criar_booster_de_personagem(v_c.id);
  end loop;
end $$;

-- ---------------------------------------------------------------- reserva
-- A reserva do diario era 1500 divididos entre os personagens - com tres,
-- 500 cada. Com seis isso viraria 250 cada, e como reservar_diario so
-- ACRESCENTA, os tres antigos ficariam em 500 e os novos em 250: metade da
-- prateleira para quem chegou depois, sem motivo nenhum.
--
-- O alvo passa a ser POR PERSONAGEM. Cada Belesma traz 2214 copias proprias,
-- entao a prateleira dele acompanha - e o total cresce junto com o mundo em
-- vez de encolher por cabeca.
create or replace function private.repor_reserva()
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare v_alvo int; v_total int := 0; v_c record;
begin
  v_alvo := coalesce(private.preco('reserva_por_personagem')::int, 500);
  for v_c in select id from public.characters order by id loop
    v_total := v_total + private.reservar_diario(v_c.id, v_alvo);
  end loop;
  return v_total;
end;
$fn$;

insert into public.economy_config (chave, valor, descricao) values
  ('reserva_por_personagem', 500,
   'Copias de comum/incomum reservadas para o diario, por personagem')
on conflict (chave) do nothing;

revoke all on function private.repor_reserva() from public, anon, authenticated;

-- o reset total tambem passa a usar o alvo por personagem, em vez do 500
-- escrito na mao
create or replace function public.admin_recomecar_do_zero(p_confirmacao text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_forjadas int; v_devolvidas int; v_jogadores int; v_estreias int;
  v_p record; v_d record;
begin
  perform private.require_admin();
  if p_confirmacao <> 'RECOMECAR DO ZERO' then
    raise exception 'confirmacao invalida: digite RECOMECAR DO ZERO';
  end if;

  delete from public.trades             where true;
  delete from public.trade_rewards      where true;
  delete from public.album_colagem      where true;
  delete from public.pack_opening_cards where true;
  delete from public.pack_openings      where true;
  delete from public.copy_history       where true;
  delete from public.baba_log           where true;
  delete from public.player_packs       where true;

  delete from public.card_copies where origin = 'forge';
  get diagnostics v_forjadas = row_count;

  select count(*) into v_estreias
  from public.card_copies where first_discovered_at is not null;

  update public.card_copies
  set owner_id = null, claimed_at = null, burned = false, damage_level = 0,
      first_discovered_at = null, first_discovered_by = null, reserved_for_daily = false
  where true;
  get diagnostics v_devolvidas = row_count;

  update public.players set
    baba = 0, pity_counter = 0, dailies_claimed = 0, last_daily_at = null,
    showcase_1 = null, showcase_2 = null, showcase_3 = null
  where true;
  get diagnostics v_jogadores = row_count;

  for v_p in select id from public.players loop
    for v_d in select id, allotment_quantidade from public.pack_definitions
               where ativo and allotment_quantidade > 0
    loop
      perform private.dar_pacote(v_p.id, v_d.id, false, v_d.allotment_quantidade);
    end loop;
  end loop;

  update public.pack_definitions set aberturas_realizadas = 0 where true;

  perform private.repor_reserva();

  perform private.registrar('admin_recomecar_do_zero', 'mundo',
    jsonb_build_object('forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
                       'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores));

  return jsonb_build_object(
    'forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
    'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores,
    'reservadas_para_diario',
      (select count(*) from public.card_copies where reserved_for_daily));
end;
$fn$;

alter function public.admin_recomecar_do_zero(text) owner to postgres;
grant execute on function public.admin_recomecar_do_zero(text) to authenticated;

select private.fechar_grants();


commit;
