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
