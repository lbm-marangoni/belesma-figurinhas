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
