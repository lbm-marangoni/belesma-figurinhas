-- BELESMA figurinhas - um dos 17 selos cai obrigatoriamente em mitica ou +

-- ================================================================ por que
-- O sorteio era uniforme sobre as 2214 copias do personagem. Uniforme cai
-- onde esta a massa, e a massa e comum: dos 100 selos que ainda nao sairam,
-- 42 sao brancos em comuns.
--
-- Medido no mundo de seis personagens, 102 selos em 13284 copias:
--
--   tier       copias   esperado   P(pelo menos um selado)
--   prisma          6      0.046        4.5%
--   diamante       12      0.092        8.8%
--   aura           36      0.276       24.3%
--   infernal       30      0.230       20.7%
--
--   os quatro juntos: P(NENHUM selado) = 52.2%
--
-- Ou seja: era mais provavel que nenhum tier de topo tivesse selo do que o
-- contrario. E aconteceu. A combinacao que faria alguem gritar - uma aura
-- com selo rosa - tinha 1,62% de existir no mundo inteiro.
--
-- A trava: das 17 copias sorteadas por personagem, UMA vem obrigatoriamente
-- do pool mitica-ou-melhor e as outras 16 vem de abaixo dele. Exatamente
-- uma, nem mais nem menos.
--
-- O que NAO muda: continua sorteio, nao carta marcada. Qual copia mitica+ e
-- escolhida sai do CSPRNG entre as 74 elegiveis, e a COR dela tambem - as
-- tres cores sao embaralhadas sobre as 17 depois. Entao a alta pode receber
-- branco, preto ou rosa, e a rosa cai nela em 1/17 das vezes.
--
-- Efeito: 6 cartas de tier alto seladas garantidas no mundo (uma por
-- personagem) em vez de "provavelmente zero", e a chance de existir alguma
-- rosa em mitica+ sobe de ~2% para 1 - (16/17)^6 = 30.7%.
create or replace function private.distribuir_selos(p_character_id int)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  n_total int;
  n_alto  int;
  v_piso  smallint;
begin
  if exists (select 1 from public.seal_audit where character_id = p_character_id) then
    return;   -- ja sorteado, e selo nao se re-sorteia
  end if;

  select count(*) into n_total
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = p_character_id and cc.origin = 'pull';

  if n_total < 17 then
    raise exception 'personagem % tem so % copias, nao da para 12/4/1', p_character_id, n_total;
  end if;

  v_piso := (select tier_order from public.tiers where slug = 'mitica');

  select count(*) into n_alto
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = p_character_id and cc.origin = 'pull'
    and cc.seal = 'none' and ct.tier_order >= v_piso;

  if n_alto = 0 then
    raise exception 'personagem % nao tem copia mitica ou melhor', p_character_id;
  end if;

  with alta as (
    -- a garantida: uma copia mitica-ou-melhor, escolhida por CSPRNG
    select cc.id
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    where ct.character_id = p_character_id and cc.origin = 'pull'
      and cc.seal = 'none' and ct.tier_order >= v_piso
    order by gen_random_bytes(8)
    limit 1
  ),
  baixas as (
    -- as outras 16, de ABAIXO do piso. Exatamente uma alta, como pedido:
    -- deixar as 16 sortearem do pool inteiro permitiria duas por acaso.
    select cc.id
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    where ct.character_id = p_character_id and cc.origin = 'pull'
      and cc.seal = 'none' and ct.tier_order < v_piso
    order by gen_random_bytes(8)
    limit 16
  ),
  sorteadas as (
    -- as 17 juntas, re-embaralhadas: a COR nao sabe qual delas e a alta
    select id, row_number() over (order by gen_random_bytes(8)) as rn
    from (select id from alta union all select id from baixas) x
  )
  update public.card_copies cc
  set seal = case
               when s.rn <= 12 then 'branco'::public.seal_type
               when s.rn <= 16 then 'preto'::public.seal_type
               else                 'rosa'::public.seal_type
             end
  from sorteadas s
  where cc.id = s.id;

  insert into public.seal_audit (character_id, branco, preto, rosa, checksum)
  select p_character_id,
         count(*) filter (where cc.seal = 'branco'),
         count(*) filter (where cc.seal = 'preto'),
         count(*) filter (where cc.seal = 'rosa'),
         md5(string_agg(cc.id::text, ',' order by cc.id))
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = p_character_id and cc.seal <> 'none';
end;
$fn$;

revoke all on function private.distribuir_selos(int) from public, anon, authenticated;

-- ================================================================ reset
-- "Recomecar do zero" passa a RE-SORTEAR os selos.
--
-- Antes eu tinha deixado os selos de fora de proposito, com o argumento de
-- que sao a contagem do mundo e nao estado de jogo. Isso deixou de valer
-- quando a regra do sorteio mudou: um mundo novo com o sorteio velho gravado
-- nas cartas nao e um mundo novo.
--
-- Continua sendo sorteio unico e imutavel DENTRO de um mundo - o seal_audit
-- e apagado junto e refeito, com checksum novo. O que nao se pode e
-- re-sortear sem reset; isso segue impossivel.
create or replace function public.admin_recomecar_do_zero(p_confirmacao text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_forjadas int; v_devolvidas int; v_jogadores int; v_estreias int;
  v_p record; v_d record; v_c record;
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
      first_discovered_at = null, first_discovered_by = null,
      reserved_for_daily = false,
      seal = 'none'                     -- <- o selo volta a mesa junto
  where true;
  get diagnostics v_devolvidas = row_count;

  delete from public.seal_audit where true;
  for v_c in select id from public.characters order by id loop
    perform private.distribuir_selos(v_c.id);
  end loop;

  update public.players set
    baba = 0, pity_counter = 0, dailies_claimed = 0, last_daily_at = null,
    showcase_1 = null, showcase_2 = null, showcase_3 = null
  where true;
  get diagnostics v_jogadores = row_count;

  for v_p in select id from public.players loop
    for v_d in select id, allotment_quantidade from public.pack_definitions
               where ativo and allotment_quantidade > 0
    loop
      perform private.dar_pacote(v_p.id, v_d.id, false, v_d.allotment_quantidade);
    end loop;
  end loop;

  update public.pack_definitions set aberturas_realizadas = 0 where true;
  perform private.repor_reserva();

  perform private.registrar('admin_recomecar_do_zero', 'mundo',
    jsonb_build_object('forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
                       'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores,
                       'selos_re_sorteados', true));

  return jsonb_build_object(
    'forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
    'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores,
    'selos_re_sorteados', (select count(*) from public.card_copies where seal <> 'none'),
    'selos_em_mitica_ou_melhor', (
      select count(*) from public.card_copies cc
      join public.card_types ct on ct.id = cc.card_type_id
      where cc.seal <> 'none'
        and ct.tier_order >= (select tier_order from public.tiers where slug = 'mitica')),
    'reservadas_para_diario',
      (select count(*) from public.card_copies where reserved_for_daily));
end;
$fn$;

alter function public.admin_recomecar_do_zero(text) owner to postgres;
grant execute on function public.admin_recomecar_do_zero(text) to authenticated;

select private.fechar_grants();
