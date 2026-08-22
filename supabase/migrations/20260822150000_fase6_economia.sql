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
