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
