-- BELESMA figurinhas - criterios do ranking e o selo entrando no preco

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

-- ================================================================ selo no preco
-- A spec §19.4 diz "nunca vende copia selada". A intencao era proteger o
-- trofeu de uma venda por engano - o selo e a coisa mais rara que existe
-- fora das Prismas: 36 brancos, 12 pretos e 3 rosas no mundo inteiro.
--
-- Passa a ser vendavel, com premio e com aviso reforcado na interface. O que
-- NAO muda: a contagem de selos do mundo continua 36/12/3, porque o selo
-- viaja com a copia de volta para o pool. A prisma segue invendavel.
insert into public.economy_config (chave, valor, descricao) values
  ('multiplicador_selo_branco',  2, 'Premio de venda para copia com selo branco'),
  ('multiplicador_selo_preto',   4, 'Premio de venda para copia com selo preto'),
  ('multiplicador_selo_rosa',   10, 'Premio de venda para copia com selo rosa')
on conflict (chave) do nothing;

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
  if not c.vendavel then raise exception 'figurinha % nao pode ser vendida', c.tier; end if;

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

  -- o selo entra ANTES dos redutores: mais raro, mais caro
  if c.seal <> 'none' then
    v_valor := v_valor * coalesce(private.preco('multiplicador_selo_' || c.seal::text), 1);
  end if;
  if c.damage_level > 0 then v_valor := v_valor * private.preco('multiplicador_estragada'); end if;
  if c.origin = 'forge'  then v_valor := v_valor * private.preco('multiplicador_forjada'); end if;
  v_valor := floor(v_valor);

  insert into public.copy_history (copy_id, from_player, to_player, kind)
  values (p_copy_id, v_uid, null, 'sell');

  if c.origin = 'forge' then
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
  return jsonb_build_object('valor', v_valor, 'saldo', v_saldo,
                            'queimada', c.origin = 'forge', 'selo', c.seal);
end;
$$;

alter function public.ranking_serial() owner to postgres;
alter function public.vender(bigint)   owner to postgres;
grant execute on function public.ranking_serial() to anon, authenticated;
grant execute on function public.vender(bigint)   to authenticated;
