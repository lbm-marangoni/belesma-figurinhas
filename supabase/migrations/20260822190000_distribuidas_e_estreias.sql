-- BELESMA figurinhas - conserta de vez a contagem de "distribuidas" e limpa
-- as estreias fantasma.

-- ================================================================ distribuidas
-- A tentativa anterior somava varios sinais indiretos e ainda errava. O sinal
-- CERTO estava na frente o tempo todo: open_pack faz
--
--   first_discovered_at = coalesce(first_discovered_at, now())
--
-- por COPIA, nao por tipo. Entao toda copia que ja saiu de um pacote tem
-- first_discovered_at preenchido, e isso nunca e apagado - nem por venda, nem
-- por troca, nem por reset administrativo (a §18.2 e explicita: estreia
-- mundial e historia, nao posse).
--
-- E, portanto, a marca permanente de "esta copia ja saiu".
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
             where cc.origin = 'pull' and cc.first_discovered_at is not null)   as distribuidas,
           count(*) filter (
             where cc.origin = 'pull' and cc.owner_id is not null)              as em_maos,
           bool_or(cc.first_discovered_at is not null and cc.origin = 'pull')   as descoberto,
           min(cc.first_discovered_at) filter (where cc.origin = 'pull')        as em,
           (select p.nickname from public.card_copies c2
            join public.players p on p.id = c2.first_discovered_by
            where c2.card_type_id = ct.id and c2.origin = 'pull'
              and c2.first_discovered_at is not null
            order by c2.first_discovered_at limit 1)                            as primeiro
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
                    'em_maos', t.em_maos,
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

alter function public.global_index() owner to postgres;
grant execute on function public.global_index() to anon, authenticated;

-- ================================================================ estreias fantasma
-- Os scripts de teste de concorrencia abriram pacotes em producao com
-- jogadores descartaveis. Ao apagar esses jogadores, o FK
-- first_discovered_by virou NULL (on delete set null), mas
-- first_discovered_at ficou - resultando em tipos marcados como DESCOBERTOS
-- sem ninguem creditado, roubando do grupo a chance de fazer a estreia.
--
-- Limpa so o caso inequivoco: descoberta sem descobridor E sem dono atual.
-- Copia descoberta por jogador que existe nao e tocada.
do $$
declare v_n int;
begin
  update public.card_copies
  set first_discovered_at = null
  where first_discovered_at is not null
    and first_discovered_by is null
    and owner_id is null
    and not burned;
  get diagnostics v_n = row_count;
  raise notice 'estreias fantasma limpas: %', v_n;
end $$;
