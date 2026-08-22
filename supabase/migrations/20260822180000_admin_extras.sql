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
