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
