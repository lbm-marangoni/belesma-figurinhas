-- BELESMA figurinhas - Fase 1: schema completo (spec secoes 5, 6, 7, 8, 18, 19)
--
-- Principios que este arquivo obedece:
--   - a escada de raridade e DADO (tabela tiers), nunca enum nem codigo
--   - o cliente nunca escreve em card_copies, players, trades ou baba
--   - nao existe admin_key: a guarda e players.is_admin, checada no banco

create extension if not exists citext;
create extension if not exists pgcrypto;

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
  slug            citext not null unique,
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
  nickname            citext not null unique,

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
set search_path = public, pg_temp
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
set search_path = public, pg_temp
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
set search_path = public, pg_temp
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

-- Secao 9: o proprio jogador precisa ler baba, pacotes e pity, que nao sao
-- publicos. A leitura da linha inteira passa por aqui, nunca por GRANT.
create or replace function public.me()
returns public.players
language sql
stable
security definer
set search_path = public, pg_temp
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
alter view public.players_public owner to postgres;
