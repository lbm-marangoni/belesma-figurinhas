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
