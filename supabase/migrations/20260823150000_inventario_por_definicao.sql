-- BELESMA figurinhas - o inventario deixa de ser seis colunas fixas
--
-- players.packs_common / _rare / _ultra (x2, com e sem diario) nao cabem um
-- quarto pacote sem ALTER TABLE. Passa tudo para player_packs, e as colunas
-- somem: manter as duas em sincronia e o tipo de coisa que apodrece na
-- primeira funcao que alguem esquece de atualizar.

-- ================================================================ config
-- Quanto cada definicao da no allotment inicial e no diario. Estava em
-- pack_params por NOME de pacote ('allotment_comum', 'diario_raros'); agora
-- e coluna da propria definicao, e um pacote novo so precisa preencher.
alter table public.pack_definitions
  add column if not exists allotment_quantidade int not null default 0
    check (allotment_quantidade >= 0),
  add column if not exists diario_quantidade int not null default 0
    check (diario_quantidade >= 0),
  add column if not exists diario_ciclo int not null default 1
    check (diario_ciclo >= 1);

update public.pack_definitions d set
  allotment_quantidade = coalesce(
    (select valor from public.pack_params where chave = 'allotment_' || d.slug::text)::int, 0),
  diario_quantidade = case d.slug::text
    when 'comum' then (select valor from public.pack_params where chave = 'diario_comuns')::int
    when 'raro'  then (select valor from public.pack_params where chave = 'diario_raros')::int
    when 'ultra' then 1 else 0 end,
  diario_ciclo = case d.slug::text
    when 'ultra' then (select valor from public.pack_params where chave = 'diario_ultra_ciclo')::int
    else 1 end
where d.slug::text in ('comum','raro','ultra');

-- ================================================================ helper
create or replace function private.dar_pacote(
  p_player uuid, p_def int, p_diario boolean, p_n int)
returns void
language sql volatile
set search_path = public, extensions, pg_temp
as $fn$
  insert into public.player_packs (player_id, pack_definition_id, do_diario, quantidade)
  values (p_player, p_def, p_diario, greatest(p_n, 0))
  on conflict (player_id, pack_definition_id, do_diario)
  do update set quantidade = public.player_packs.quantidade + greatest(p_n, 0);
$fn$;

create or replace function private.inventario(p_player uuid)
returns jsonb
language sql stable
set search_path = public, extensions, pg_temp
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'pack_definition_id', d.id, 'slug', d.slug::text, 'nome', d.name,
    'art_path', d.art_path, 'do_diario', pp.do_diario,
    'quantidade', pp.quantidade, 'tamanho', d.tamanho, 'ativo', d.ativo
  ) order by d.id, pp.do_diario desc), '[]'::jsonb)
  from public.player_packs pp
  join public.pack_definitions d on d.id = pp.pack_definition_id
  where pp.player_id = p_player and pp.quantidade > 0;
$fn$;

-- ================================================================ me()
-- Passa a devolver jsonb: a linha de players nao carrega mais o inventario,
-- e o cliente precisa dele junto para nao fazer duas viagens.
drop function if exists public.me();
create or replace function public.me()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  select to_jsonb(p) - 'packs_common' - 'packs_rare' - 'packs_ultra'
                     - 'packs_common_daily' - 'packs_rare_daily' - 'packs_ultra_daily'
         || jsonb_build_object(
              'inventario', private.inventario(p.id),
              'pacotes_total', coalesce((select sum(quantidade) from public.player_packs
                                         where player_id = p.id), 0))
  from public.players p where p.id = auth.uid();
$fn$;

-- ================================================================ escritores
-- claim_nickname continua devolvendo a linha de players e continua
-- IDEMPOTENTE - chamar de novo devolve a linha, nao repete o allotment. Copia
-- fiel do original; a unica mudanca e de onde sai o allotment.
create or replace function public.claim_nickname(p_nickname text)
returns public.players
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_row   public.players;
  v_d     record;
begin
  if v_uid is null then
    raise exception 'precisa estar logado' using errcode = '42501';
  end if;

  -- Idempotente: chamar de novo devolve a linha, nao duplica allotment.
  select * into v_row from public.players where id = v_uid;
  if found then return v_row; end if;

  if p_nickname !~ '^[a-z0-9][a-z0-9_-]{2,19}$' then
    raise exception 'apelido invalido: 3 a 20 caracteres, minusculas, numeros, - e _';
  end if;

  -- O apelido tem que bater com o e-mail sintetico do proprio JWT, senao
  -- daria para cadastrar como "fulano" e reivindicar o apelido "beltrano".
  select email into v_email from auth.users where id = v_uid;
  if lower(split_part(v_email, '@', 1)) <> lower(p_nickname) then
    raise exception 'apelido nao confere com a conta';
  end if;

  insert into public.players (id, nickname)
  values (v_uid, p_nickname::extensions.citext)
  returning * into v_row;

  -- allotment inicial: vem da coluna da definicao, nao de uma chave em
  -- pack_params nomeada pelo slug do pacote. Pacote novo so preenche o campo.
  for v_d in select id, allotment_quantidade from public.pack_definitions
             where ativo and allotment_quantidade > 0
  loop
    perform private.dar_pacote(v_uid, v_d.id, false, v_d.allotment_quantidade);
  end loop;

  return v_row;
exception
  when unique_violation then
    raise exception 'esse apelido ja existe';
end;
$fn$;

-- ---------------------------------------------------------------- grant
create or replace function public.grant_packs(p_target text, p_pack_type text, p_quantidade int)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_def int; v_n int := 0; v_p record;
begin
  perform private.require_admin();
  if p_quantidade is null or p_quantidade = 0 then raise exception 'quantidade invalida'; end if;

  select id into v_def from public.pack_definitions
  where slug = p_pack_type::extensions.citext;
  if v_def is null then raise exception 'pacote "%" nao existe', p_pack_type; end if;

  for v_p in
    select id from public.players
    where p_target = 'todos' or nickname = p_target::extensions.citext
  loop
    if p_quantidade > 0 then
      perform private.dar_pacote(v_p.id, v_def, false, p_quantidade);
    else
      update public.player_packs set quantidade = greatest(0, quantidade + p_quantidade)
      where player_id = v_p.id and pack_definition_id = v_def and not do_diario;
    end if;
    v_n := v_n + 1;
  end loop;

  perform private.registrar('grant_packs', p_target,
    jsonb_build_object('pacote', p_pack_type, 'quantidade', p_quantidade, 'jogadores', v_n));
  return v_n;
end;
$fn$;

-- ---------------------------------------------------------------- loja
create or replace function public.comprar_pacote(p_pack_type text, p_character_id int default null)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_def   public.pack_definitions;
  v_preco numeric;
  v_teto  int;
  v_hoje  int;
  v_saldo int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select * into v_def from public.pack_definitions
  where slug = p_pack_type::extensions.citext;
  if v_def.id is null then raise exception 'pacote "%" nao existe', p_pack_type; end if;
  if not v_def.ativo then raise exception 'pacote "%" esta desativado', v_def.name; end if;
  if not v_def.elegivel_loja then raise exception '"%" nao esta a venda', v_def.name; end if;

  if v_def.limite_global is not null
     and v_def.aberturas_realizadas >= v_def.limite_global then
    raise exception 'edicao esgotada'; end if;

  v_teto := private.preco('teto_compra_dia')::int;
  select count(*) into v_hoje from public.baba_log
  where player_id = v_uid and motivo = 'compra' and created_at > now() - interval '24 hours';
  if v_hoje >= v_teto then
    raise exception 'limite de % compras por dia atingido', v_teto;
  end if;

  v_preco := v_def.preco_baba;
  if p_character_id is not null then
    v_preco := v_preco * private.preco('dirigido_mult');
  end if;

  v_saldo := private.mover_baba(v_uid, -floor(v_preco)::int, 'compra', v_def.slug::text);
  perform private.dar_pacote(v_uid, v_def.id, false, 1);

  return jsonb_build_object('preco', floor(v_preco), 'saldo', v_saldo,
    'restantes_hoje', v_teto - v_hoje - 1, 'pack_definition_id', v_def.id);
end;
$fn$;

-- ---------------------------------------------------------------- diario
create or replace function public.claim_daily()
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  p        public.players;
  v_streak int;
  v_bonus  int;
  v_extra  int := 0;
  v_espera interval;
  v_d      record;
  v_dados  jsonb := '[]'::jsonb;
  v_n      int;
begin
  if auth.uid() is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;

  select * into p from public.players where id = auth.uid() for update;
  if p.id is null then raise exception 'jogador nao encontrado'; end if;

  if p.last_daily_at is not null and p.last_daily_at > now() - interval '24 hours' then
    v_espera := (p.last_daily_at + interval '24 hours') - now();
    raise exception 'o diario volta em %', to_char(v_espera, 'HH24"h"MI"min"');
  end if;

  v_streak := case
    when p.last_daily_at is not null and p.last_daily_at > now() - interval '48 hours'
      then (p.dailies_claimed % 7) + 1
    else 1 end;

  -- cada definicao diz o que da e de quantos em quantos resgates
  for v_d in select id, name, slug, diario_quantidade, diario_ciclo
             from public.pack_definitions
             where ativo and diario_quantidade > 0 order by id
  loop
    v_n := case when (p.dailies_claimed + 1) % v_d.diario_ciclo = 0
                then v_d.diario_quantidade else 0 end;
    if v_n > 0 then
      perform private.dar_pacote(p.id, v_d.id, true, v_n);
      v_dados := v_dados || jsonb_build_object(
        'pack_definition_id', v_d.id, 'slug', v_d.slug::text,
        'nome', v_d.name, 'quantidade', v_n);
    end if;
  end loop;

  update public.players set
    last_daily_at   = now(),
    dailies_claimed = case
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

  perform private.repor_reserva();

  return jsonb_build_object('pacotes', v_dados, 'streak', v_streak,
                            'baba', v_bonus + v_extra);
end;
$fn$;

-- ---------------------------------------------------------------- admin
create or replace function public.admin_jogadores()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  perform private.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'nickname', p.nickname, 'created_at', p.created_at,
      'is_admin', p.is_admin, 'baba', p.baba,
      'copias', (select count(*) from public.card_copies cc where cc.owner_id = p.id),
      'pacotes', private.inventario(p.id),
      'pacotes_total', coalesce((select sum(quantidade) from public.player_packs
                                 where player_id = p.id), 0),
      'last_daily_at', p.last_daily_at, 'pity_counter', p.pity_counter
    ) order by p.created_at)
    from public.players p), '[]'::jsonb);
end;
$fn$;

create or replace function public.admin_recomecar_do_zero(p_confirmacao text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_forjadas int; v_devolvidas int; v_jogadores int; v_estreias int;
  v_ch record; v_p record; v_d record;
begin
  perform private.require_admin();
  if p_confirmacao <> 'RECOMECAR DO ZERO' then
    raise exception 'confirmacao invalida: digite RECOMECAR DO ZERO';
  end if;

  delete from public.trades             where true;
  delete from public.trade_rewards      where true;
  delete from public.album_colagem      where true;
  delete from public.pack_opening_cards where true;
  delete from public.pack_openings      where true;
  delete from public.copy_history       where true;
  delete from public.baba_log           where true;
  delete from public.player_packs       where true;

  delete from public.card_copies where origin = 'forge';
  get diagnostics v_forjadas = row_count;

  select count(*) into v_estreias
  from public.card_copies where first_discovered_at is not null;

  update public.card_copies
  set owner_id = null, claimed_at = null, burned = false, damage_level = 0,
      first_discovered_at = null, first_discovered_by = null, reserved_for_daily = false
  where true;
  get diagnostics v_devolvidas = row_count;

  update public.players set
    baba = 0, pity_counter = 0, dailies_claimed = 0, last_daily_at = null,
    showcase_1 = null, showcase_2 = null, showcase_3 = null
  where true;
  get diagnostics v_jogadores = row_count;

  -- allotment de volta, da definicao
  for v_p in select id from public.players loop
    for v_d in select id, allotment_quantidade from public.pack_definitions
               where ativo and allotment_quantidade > 0
    loop
      perform private.dar_pacote(v_p.id, v_d.id, false, v_d.allotment_quantidade);
    end loop;
  end loop;

  -- as edicoes limitadas voltam a zero: e um mundo novo
  update public.pack_definitions set aberturas_realizadas = 0 where true;

  for v_ch in select id from public.characters order by id loop
    perform private.reservar_diario(v_ch.id, 500);
  end loop;

  perform private.registrar('admin_recomecar_do_zero', 'mundo',
    jsonb_build_object('forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
                       'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores));

  return jsonb_build_object(
    'forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
    'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores,
    'reservadas_para_diario',
      (select count(*) from public.card_copies where reserved_for_daily));
end;
$fn$;

-- ================================================================ colunas
-- Agora que ninguem mais le nem escreve, elas saem. Deixar uma coluna morta
-- e um convite para alguem voltar a usar por engano.
alter table public.players
  drop column if exists packs_common,       drop column if exists packs_rare,
  drop column if exists packs_ultra,        drop column if exists packs_common_daily,
  drop column if exists packs_rare_daily,   drop column if exists packs_ultra_daily;

alter function public.me()                             owner to postgres;
alter function public.claim_nickname(text)             owner to postgres;
alter function public.grant_packs(text, text, int)     owner to postgres;
alter function public.comprar_pacote(text, int)        owner to postgres;
alter function public.claim_daily()                    owner to postgres;
alter function public.admin_jogadores()                owner to postgres;
alter function public.admin_recomecar_do_zero(text)    owner to postgres;

grant execute on function public.me()                          to authenticated;
grant execute on function public.claim_nickname(text)          to authenticated;
grant execute on function public.grant_packs(text, text, int)  to authenticated;
grant execute on function public.comprar_pacote(text, int)     to authenticated;
grant execute on function public.claim_daily()                 to authenticated;
grant execute on function public.admin_jogadores()             to authenticated;
grant execute on function public.admin_recomecar_do_zero(text) to authenticated;

select private.fechar_grants();

-- ---------------------------------------------------------------- definir
-- `dar_pacote` SOMA. Para fixar um saldo (admin corrigindo, teste montando
-- cenario) o que se quer e substituir.
create or replace function private.definir_pacotes(
  p_player uuid, p_slug text, p_diario boolean, p_n int)
returns void
language sql volatile
set search_path = public, extensions, pg_temp
as $fn$
  insert into public.player_packs (player_id, pack_definition_id, do_diario, quantidade)
  select p_player, d.id, p_diario, greatest(p_n, 0)
  from public.pack_definitions d where d.slug = p_slug::extensions.citext
  on conflict (player_id, pack_definition_id, do_diario)
  do update set quantidade = greatest(p_n, 0);
$fn$;

create or replace function private.tem_pacotes(
  p_player uuid, p_slug text, p_diario boolean default false)
returns int
language sql stable
set search_path = public, extensions, pg_temp
as $fn$
  select coalesce((select pp.quantidade from public.player_packs pp
                   join public.pack_definitions d on d.id = pp.pack_definition_id
                   where pp.player_id = p_player and d.slug = p_slug::extensions.citext
                     and pp.do_diario = p_diario), 0);
$fn$;

select private.fechar_grants();
