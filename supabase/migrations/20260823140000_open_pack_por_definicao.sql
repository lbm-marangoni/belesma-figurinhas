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
