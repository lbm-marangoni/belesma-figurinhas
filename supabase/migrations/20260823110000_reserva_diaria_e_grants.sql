-- BELESMA figurinhas - a reserva do diario vazava, e o grant residual voltou

-- ================================================================ 1. reserva
-- BUG: `private.reservar_diario` contava como reserva TODA copia com a flag
-- `reserved_for_daily`, inclusive as que ja tinham dono. Como o open_pack
-- nunca limpa a flag ao entregar a carta, cada carta de diario reclamada
-- continuava sendo contada como se ainda estivesse na prateleira.
--
-- Efeito: a reposicao achava a reserva cheia e nao repunha nada. Medido na
-- producao com 3 jogadores e poucos dias de jogo:
--
--   com a flag, nao queimadas .... 1488   <- o que a funcao contava
--   de fato disponiveis .......... 1472   <- o que existia para sortear
--   ja com dono .................. 16
--
-- 16 em poucos dias. A reserva e de 1500 e o consumo e de ~3 cartas por
-- jogador por dia; a conta errada vai drenando ate o diario nao ter mais de
-- onde sortear, e nada avisa.
--
-- A reserva e o conjunto de copias DISPONIVEIS e marcadas. Copia com dono
-- saiu da prateleira, mesmo que a flag continue nela - e a flag continua de
-- proposito, para que a copia volte para a reserva se for vendida.
create or replace function private.reservar_diario(p_character_id int, p_alvo int)
returns int
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  ja_tem int;
  faltam int;
begin
  select count(*) into ja_tem
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = p_character_id
    and cc.reserved_for_daily
    and not cc.burned
    and cc.owner_id is null;          -- <- o conserto

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
    order by extensions.gen_random_bytes(8)
    limit faltam
  )
  update public.card_copies set reserved_for_daily = true
  where id in (select id from candidatas);

  return faltam;
end;
$fn$;

-- O top_up tinha a mesma conta errada no alvo que passa para a funcao.
create or replace function public.top_up_daily_reserve(p_n int)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_por_char int; v_total int := 0; v_c record;
begin
  perform private.require_admin();
  if p_n is null or p_n <= 0 then raise exception 'n invalido'; end if;

  v_por_char := ceil(p_n::numeric / greatest((select count(*) from public.characters), 1));
  for v_c in select id from public.characters order by id loop
    v_total := v_total + private.reservar_diario(v_c.id,
      (select count(*) from public.card_copies cc
       join public.card_types ct on ct.id = cc.card_type_id
       where ct.character_id = v_c.id and cc.reserved_for_daily
         and not cc.burned and cc.owner_id is null)::int + v_por_char);
  end loop;

  perform private.registrar('top_up_daily_reserve', null,
    jsonb_build_object('pedido', p_n, 'reservadas', v_total));
  return v_total;
end;
$fn$;

-- ---------------------------------------------------------------- auto
-- Repor a reserva era so manual, por RPC de admin. Isso e um alarme que
-- depende de alguem lembrar: o diario simplesmente para de ter estoque num
-- dia qualquer, sem aviso. Agora o proprio claim_daily devolve a reserva ao
-- alvo depois de servir - custa uma contagem por personagem, com 8 amigos
-- reclamando uma vez por dia.
create or replace function private.repor_reserva()
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare v_alvo int; v_total int := 0; v_c record;
begin
  -- o alvo por personagem vem do seed: 1500 divididos entre os personagens
  v_alvo := (1500 / greatest((select count(*) from public.characters), 1))::int;
  for v_c in select id from public.characters order by id loop
    v_total := v_total + private.reservar_diario(v_c.id, v_alvo);
  end loop;
  return v_total;
end;
$fn$;

revoke all on function private.repor_reserva() from public, anon, authenticated;

-- ================================================================ 2. grants
-- O grant automatico para PUBLIC voltou, exatamente como o comentario da
-- migracao de ontem previu: `private.pontos_carta` mudou de assinatura, e
-- funcao nova nasce aberta. A auditoria de producao pegou na primeira
-- rodada seguinte.
--
-- Vira funcao, para as proximas migracoes so precisarem chamar no fim.
create or replace function private.fechar_grants()
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare f record; n int := 0;
begin
  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
    where n2.nspname = 'private'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.assinatura);
    n := n + 1;
  end loop;

  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
    where n2.nspname = 'public'
      and array_to_string(coalesce(p.proacl, '{}'), ',') like '=X/%'
  loop
    execute format('revoke all on function %s from public', f.assinatura);
    n := n + 1;
  end loop;
  return n;
end;
$fn$;

select private.fechar_grants();
revoke all on function private.fechar_grants() from public, anon, authenticated;

-- ---------------------------------------------------------------- claim_daily
-- Passa a repor a reserva depois de servir. Ver o comentario dentro.
create or replace function public.claim_daily()
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
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

  -- Repor a prateleira do diario aqui, e nao so por RPC de admin. A reserva
  -- e consumida justamente por esta funcao; deixar a reposicao dependendo de
  -- alguem lembrar significa que um dia o diario para sem aviso.
  perform private.repor_reserva();

  return jsonb_build_object(
    'comuns', v_comuns, 'raros', v_raros, 'ultra', v_ultra,
    'streak', v_streak, 'baba', v_bonus + v_extra,
    'proximo_ultra_em', case when v_ultra then v_ciclo else v_ciclo - ((p.dailies_claimed + 1) % v_ciclo) end);
end;
$fn$;

alter function public.claim_daily() owner to postgres;
grant execute on function public.claim_daily() to authenticated;
select private.fechar_grants();
