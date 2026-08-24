-- BELESMA figurinhas - a escassez passa a contar por SKIN, nao por tier

-- ================================================================ por que
-- O censo agrupava por (tier, selo). Isso junta galaxia com nebulosa, e
-- esmeralda com rubi, safira e ametista - cartas diferentes tratadas como a
-- mesma coisa so por dividirem a raridade.
--
-- O caso que denunciou: existiam duas "cosmica + branco" no mundo, e a
-- jogadora que tinha uma via "2 iguais no mundo". Mas as duas eram skins
-- diferentes:
--
--   santao  galaxia  + branco   (essa saiu, esta com o lucas)
--   lucas   nebulosa + branco   (essa nunca saiu de um pacote)
--
-- Por skin, a galaxia+branco volta a ser 1 no mundo - e e verdade, porque
-- nao existe outra galaxia com selo branco em lugar nenhum.
--
-- Por que SKIN e nao card_type (personagem + skin): medido no set atual,
--
--   por (tier, selo)        5 combinacoes com uma copia so
--   por (skin, selo)       17 combinacoes com uma copia so
--   por (card_type, selo)  55 combinacoes com uma copia so
--
-- Por card_type quase toda carta selada vira 1-de-1 e o selo para de
-- diferenciar qualquer coisa. Por skin o criterio continua discriminando.
--
-- A contagem segue sendo de TODAS as copias, inclusive as que nunca sairam
-- de um pacote. Uma carta e rara pela tiragem dela, nao por quantas ja foram
-- abertas - uma Prisma parada no pool continua sendo 1 de 1.
-- `create or replace view` nao troca o NOME de uma coluna existente (a
-- primeira era `tier`), entao a view cai antes. As funcoes que a usam sao
-- recriadas logo abaixo, na mesma migracao.
drop view if exists private.censo_raridade;
create view private.censo_raridade as
select ct.skin, cc.seal, count(*)::int as copias
from public.card_copies cc
join public.card_types ct on ct.id = cc.card_type_id
where not cc.burned
group by 1, 2;

revoke all on private.censo_raridade from public, anon, authenticated;

-- ---------------------------------------------------------------- ranking
create or replace function public.ranking_serial()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  with pontuadas as (
    select cc.id, cc.owner_id, cc.serial_number, cc.seal, cc.origin, cc.forge_index,
           cc.damage_level, cc.verify_code, cc.card_type_id,
           ct.print_run, ct.tier, ct.tier_order, ct.skin, ch.slug, ch.name,
           censo.copias as iguais_no_mundo,
           private.pontos_carta(censo.copias, ct.tier_order, cc.serial_number,
                                cc.origin, cc.damage_level) as pontos
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.characters ch on ch.id = ct.character_id
    join private.censo_raridade censo on censo.skin = ct.skin and censo.seal = cc.seal
    where cc.owner_id is not null and not cc.burned
  ),
  agregado as (
    select owner_id,
           count(*)                                            as copias,
           count(*) filter (where seal <> 'none')               as selos,
           count(*) filter (where serial_number = 1)            as unos,
           min(serial_number) filter (where origin = 'pull')    as melhor_serial,
           min(iguais_no_mundo)                                 as mais_escassa,
           round(sum(pontos) / 1000000.0, 1)                    as pontos_total
    from pontuadas group by owner_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'nickname', p.nickname,
    'copias', a.copias, 'selos', a.selos, 'unos', a.unos,
    'melhor_serial', a.melhor_serial, 'mais_escassa', a.mais_escassa,
    'pontos', a.pontos_total,
    'joia',   (select to_jsonb(x) from (
                select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                       damage_level, verify_code, card_type_id, tier, tier_order, skin,
                       slug as character_slug, name as character_name, iguais_no_mundo
                from pontuadas where owner_id = a.owner_id
                order by pontos desc limit 1) x),
    'menor_serial', (select to_jsonb(x) from (
                select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                       damage_level, verify_code, card_type_id, tier, tier_order, skin,
                       slug as character_slug, name as character_name, iguais_no_mundo
                from pontuadas where owner_id = a.owner_id and origin = 'pull'
                order by serial_number, print_run, tier_order desc limit 1) x),
    'melhor_selo', (select to_jsonb(x) from (
                select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                       damage_level, verify_code, card_type_id, tier, tier_order, skin,
                       slug as character_slug, name as character_name, iguais_no_mundo
                from pontuadas where owner_id = a.owner_id and seal <> 'none'
                order by case seal when 'rosa' then 3 when 'preto' then 2 else 1 end desc,
                         tier_order desc, serial_number limit 1) x),
    'destaques', (select coalesce(jsonb_agg(to_jsonb(x) order by x.pontos desc), '[]'::jsonb)
                  from (
                    select id as copy_id, serial_number, print_run, seal, origin, forge_index,
                           damage_level, verify_code, card_type_id, tier, tier_order, skin,
                           slug as character_slug, name as character_name,
                           iguais_no_mundo, pontos
                    from pontuadas where owner_id = a.owner_id
                    order by pontos desc limit 8) x)
  ) order by a.pontos_total desc), '[]'::jsonb)
  from agregado a join public.players p on p.id = a.owner_id;
$fn$;

create or replace function public.trofeus_do_mundo()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  with pontuadas as (
    select cc.id as copy_id, cc.serial_number, cc.seal, cc.origin, cc.forge_index,
           cc.damage_level, cc.verify_code, cc.card_type_id,
           ct.print_run, ct.tier, ct.tier_order, ct.skin,
           ch.slug as character_slug, ch.name as character_name,
           p.nickname as dono,
           censo.copias as iguais_no_mundo,
           private.pontos_carta(censo.copias, ct.tier_order, cc.serial_number,
                                cc.origin, cc.damage_level) as pontos
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    join public.characters ch on ch.id = ct.character_id
    join public.players p on p.id = cc.owner_id
    join private.censo_raridade censo on censo.skin = ct.skin and censo.seal = cc.seal
    where cc.owner_id is not null and not cc.burned
  )
  select jsonb_build_object(
    'joia', (select to_jsonb(x) from (
              select * from pontuadas order by pontos desc, copy_id limit 1) x),
    'menor_serial', (select to_jsonb(x) from (
              select * from pontuadas where origin = 'pull'
              order by serial_number, print_run, tier_order desc, copy_id limit 1) x),
    'melhor_selo', (select to_jsonb(x) from (
              select * from pontuadas where seal <> 'none'
              order by case seal when 'rosa' then 3 when 'preto' then 2 else 1 end desc,
                       tier_order desc, serial_number, copy_id limit 1) x),
    'em_jogo', (select count(*) from pontuadas),
    'donos',   (select count(distinct dono) from pontuadas)
  );
$fn$;

-- o filtro da Colecao usa o mesmo censo
create or replace function public.escassez_por_classe()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'skin', skin, 'seal', seal, 'copias', copias) order by copias, skin), '[]'::jsonb)
  from private.censo_raridade;
$fn$;

-- ================================================================ saude
-- O alerta de selos comparava com 36/12/3 escrito na mao - os numeros de
-- QUANDO havia tres personagens. Com seis o painel passou a acusar bug onde
-- nao ha nenhum. E 12 brancos, 4 pretos e 1 rosa POR personagem.
create or replace function public.admin_saude()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_ch int;
begin
  perform private.require_admin();
  select count(*) into v_ch from public.characters;
  return jsonb_build_object(
    'jogadores', (select count(*) from public.players),
    'copias_com_dono', (select count(*) from public.card_copies where owner_id is not null),
    'queimadas', (select count(*) from public.card_copies where burned),
    'forjadas', (select count(*) from public.card_copies where origin = 'forge'),
    'reserva_do_diario', (select count(*) from public.card_copies
                          where reserved_for_daily and owner_id is null and not burned),
    'pool_base_livre', (select count(*) from public.card_copies cc
                        join public.card_types ct on ct.id = cc.card_type_id
                        where ct.tier in ('comum','incomum')
                          and cc.owner_id is null and not cc.burned
                          and not cc.reserved_for_daily),
    'baba_em_circulacao', (select coalesce(sum(baba), 0) from public.players),
    'trocas_pendentes', (select count(*) from public.trades where status = 'pending'),
    'alertas', jsonb_build_object(
      'selos_fora_de_12_4_1_por_personagem', (
        select case when count(*) filter (where seal='branco') = v_ch * 12
                     and count(*) filter (where seal='preto')  = v_ch * 4
                     and count(*) filter (where seal='rosa')   = v_ch
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
$fn$;

alter function public.ranking_serial()       owner to postgres;
alter function public.trofeus_do_mundo()     owner to postgres;
alter function public.escassez_por_classe()  owner to postgres;
alter function public.admin_saude()          owner to postgres;
grant execute on function public.ranking_serial()      to anon, authenticated;
grant execute on function public.trofeus_do_mundo()    to anon, authenticated;
grant execute on function public.escassez_por_classe() to anon, authenticated;
grant execute on function public.admin_saude()         to authenticated;

select private.fechar_grants();
