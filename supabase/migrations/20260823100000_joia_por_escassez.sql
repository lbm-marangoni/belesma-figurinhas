-- BELESMA figurinhas - "a joia" passa a medir escassez de verdade

-- ================================================================ por que
-- A versao anterior somava pesos que EU escolhi: raridade x 1.000.000, selo
-- x 100.000. Isso poe o selo a um decimo de um degrau de raridade, e a
-- consequencia foi medida no servidor: uma cosmica + selo branco, da qual
-- existe UMA no mundo inteiro, ficava atras de tres divinas, das quais
-- existem 29.
--
-- O erro de fundo foi tratar a escada de tiers como se ela ja medisse
-- escassez. Ela nao mede: o selo e um SEGUNDO eixo, e um selo cair numa
-- cosmica e muito mais improvavel do que cair numa comum, porque so existem
-- 90 cosmicas para ele cair e quase tres mil comuns. Censo do set:
--
--   divina + selo preto      1 copia      (esperava-se 0,054)
--   cosmica + selo branco    1            (esperava-se 0,49)
--   prisma                   3
--   diamante                 6
--   infernal                15
--   divina                  29
--
-- Agora o criterio nao tem peso nenhum inventado por mim: e a contagem.
-- "A joia e a carta com menos copias iguais no mundo." Uma frase, conferivel
-- por qualquer um, e que se ajusta sozinha quando o quarto personagem
-- entrar por seed_edition.
create or replace view private.censo_raridade as
select ct.tier, cc.seal, count(*)::int as copias
from public.card_copies cc
join public.card_types ct on ct.id = cc.card_type_id
where not cc.burned
group by 1, 2;

-- ================================================================ pontuacao
-- O primeiro termo domina por construcao: mesmo entre as classes mais
-- povoadas (rara com 1200 copias contra incomum com ~1300) a diferenca passa
-- de 60.000 pontos, e a soma de TODOS os desempates nao chega a 7.000. Logo
-- nenhum desempate inverte uma diferenca de escassez - eles so decidem
-- dentro da mesma classe.
drop function if exists private.pontos_carta(smallint, public.seal_type, int, int, public.copy_origin, int);

create or replace function private.pontos_carta(
  p_copias_iguais int,          -- do censo: quantas ha no mundo com este tier E este selo
  p_tier_order    smallint,
  p_serial        int,
  p_origin        public.copy_origin,
  p_damage        int)
returns numeric
language sql immutable
as $fn$
  select
      -- escassez: o eixo. Menos copias iguais, mais pontos.
      1000000000.0 / greatest(p_copias_iguais, 1)
      -- entre duas classes igualmente escassas, a mais alta na escada
    + p_tier_order * 500
      -- serial baixo, e o 1/N valendo extra
    + (case when p_serial = 1 then 400
            when p_serial is null then 0
            else greatest(0, 300 - p_serial) end)
      -- puxada vale mais que forjada: forja e supply paralelo
    + (case when p_origin = 'pull' then 200 else 0 end)
      -- conservacao
    - p_damage * 150
$fn$;

-- ================================================================ por jogador
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
    join private.censo_raridade censo on censo.tier = ct.tier and censo.seal = cc.seal
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
    'melhor_serial', a.melhor_serial,
    'mais_escassa', a.mais_escassa,
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

-- ================================================================ do servidor
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
    join private.censo_raridade censo on censo.tier = ct.tier and censo.seal = cc.seal
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

alter function public.ranking_serial()    owner to postgres;
alter function public.trofeus_do_mundo()  owner to postgres;
grant execute on function public.ranking_serial()   to anon, authenticated;
grant execute on function public.trofeus_do_mundo() to anon, authenticated;

-- o censo vive em private: ninguem de fora precisa da view crua
revoke all on private.censo_raridade from public, anon, authenticated;
