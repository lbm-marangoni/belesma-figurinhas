-- BELESMA figurinhas - conserta a contagem de "distribuidas" e enriquece o
-- ranking da cacada de serial.

-- ================================================================ distribuidas
-- BUG: a contagem media "quantas estao com dono AGORA", mas a spec §11 pede
-- "quantas ja SAIRAM do total". Uma copia vendida volta ao pool com
-- owner_id null e sumia da conta - dava linha com estreia mundial creditada
-- e "0 de 250" ao lado, que e contraditorio.
--
-- "Ja saiu" agora e: tem dono, OU foi queimada, OU tem desgaste (so quem foi
-- vendida ganha), OU tem registro de pull/daily no historico. A condicao e
-- redundante de proposito: o historico de alguns jogadores foi perdido num
-- bug meu de script, e os outros criterios cobrem esse buraco.
create or replace function public.global_index()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare v jsonb;
begin
  with tipos as (
    select ct.id, ct.character_id, ct.skin, ct.tier, ct.tier_order, ct.print_run,
           count(*) filter (
             where cc.origin = 'pull' and (
               cc.owner_id is not null
               or cc.burned
               or cc.damage_level > 0
               or exists (select 1 from public.copy_history h
                          where h.copy_id = cc.id and h.kind in ('pull','daily'))
             ))                                                               as distribuidas,
           bool_or(cc.first_discovered_at is not null and cc.origin = 'pull') as descoberto,
           min(cc.first_discovered_at) filter (where cc.origin = 'pull')      as em,
           (select p.nickname from public.card_copies c2
            join public.players p on p.id = c2.first_discovered_by
            where c2.card_type_id = ct.id and c2.origin = 'pull'
              and c2.first_discovered_at is not null
            order by c2.first_discovered_at limit 1)                          as primeiro
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

-- ================================================================ ranking
-- Agora devolve as MELHORES cartas de cada um, com copy_id, para a tela
-- poder mostrar a figurinha e abrir em tela cheia.
create or replace function public.ranking_serial()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'nickname', p.nickname,
    'copias', x.copias,
    'selos', x.selos,
    'unos', x.unos,
    'melhor_serial', x.melhor_serial,
    'destaques', (
      -- as 6 melhores: primeiro tier, depois selo, depois menor serial
      select coalesce(jsonb_agg(jsonb_build_object(
        'copy_id', d.id, 'serial_number', d.serial_number, 'print_run', d.print_run,
        'seal', d.seal, 'origin', d.origin, 'forge_index', d.forge_index,
        'damage_level', d.damage_level, 'verify_code', d.verify_code,
        'card_type_id', d.card_type_id,
        'tier', d.tier, 'tier_order', d.tier_order, 'skin', d.skin,
        'character_slug', d.slug, 'character_name', d.name) order by d.rn), '[]'::jsonb)
      from (
        select cc.id, cc.serial_number, ct.print_run, cc.seal, cc.origin, cc.forge_index,
               cc.damage_level, cc.verify_code, cc.card_type_id,
               ct.tier, ct.tier_order, ct.skin, ch.slug, ch.name,
               row_number() over (
                 order by ct.tier_order desc,
                          (cc.seal <> 'none') desc,
                          cc.serial_number) as rn
        from public.card_copies cc
        join public.card_types ct on ct.id = cc.card_type_id
        join public.characters ch on ch.id = ct.character_id
        where cc.owner_id = x.owner_id and not cc.burned
      ) d where d.rn <= 6)
  ) order by x.selos desc, x.melhor_serial), '[]'::jsonb)
  from (
    select cc.owner_id,
           count(*) as copias,
           count(*) filter (where cc.seal <> 'none') as selos,
           count(*) filter (where cc.serial_number = 1) as unos,
           min(cc.serial_number) as melhor_serial
    from public.card_copies cc
    where cc.owner_id is not null and not cc.burned
    group by cc.owner_id
  ) x
  join public.players p on p.id = x.owner_id;
$$;

alter function public.global_index()  owner to postgres;
alter function public.ranking_serial() owner to postgres;
grant execute on function public.global_index()  to anon, authenticated;
grant execute on function public.ranking_serial() to anon, authenticated;
