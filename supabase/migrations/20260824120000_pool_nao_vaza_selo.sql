-- BELESMA figurinhas - o pool para de entregar o mapa dos selos

-- ================================================================ o furo
-- A policy de card_copies era `using (true)`: qualquer um, com a chave
-- publica que vai no bundle do navegador, listava TODAS as copias - inclusive
-- as que nunca sairam de um pacote, com o selo delas.
--
--   GET /card_copies?select=serial_number,seal&seal=neq.none&owner_id=is.null
--   -> 100 linhas: onde esta cada selo que ainda nao apareceu no jogo
--
-- O selo e sorteado UMA VEZ, no seed, e gravado na copia (spec §6). Isso e
-- proposital e auditavel - o seal_audit tem o checksum que prova que ninguem
-- re-sorteou. Mas significa que o mapa existe desde o dia zero, e deixa-lo
-- legivel transforma a surpresa em consulta.
--
-- Pior que estragar surpresa: da vantagem de compra. Sabendo que ainda ha
-- um selo rosa nao reclamado nas cartas do Dinho, compra-se Booster Dinho.
-- Pequena, mas real, e assimetrica - so quem pensa em consultar a API ganha.
--
-- A correcao e a menor possivel: a copia so e visivel se ja EXISTE no jogo -
-- tem dono, ou ja saiu de um pacote alguma vez. O que esta parado no pool,
-- ninguem viu, e ninguem le.
--
-- Nada disso afeta o indice global nem o estoque publico: os dois vem de
-- funcoes security definer, que rodam como dono e nao passam pela policy.
drop policy if exists card_copies_leitura on public.card_copies;
create policy card_copies_leitura on public.card_copies
  for select to anon, authenticated
  using (owner_id is not null or first_discovered_at is not null);

-- ---------------------------------------------------------------- estoque
-- O que o pool tem de fato continua publico, so que agregado: contagem por
-- tier, sem dizer QUAL copia. E o suficiente para as telas de estoque e para
-- a §8 ("odds e escassez a vista"), sem entregar o mapa.
create or replace function public.estoque_publico()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  select jsonb_build_object(
    'por_tier', coalesce(jsonb_agg(jsonb_build_object(
      'tier', x.tier, 'tier_order', x.tier_order,
      'disponiveis', x.disponiveis, 'total', x.total,
      -- Quantas copias seladas ainda nao apareceram, por tier. O NUMERO e
      -- publico de proposito: sem ele a cacada perde a graca, e a §8 manda
      -- deixar escassez a vista. QUAIS copias sao, nao se diz.
      'selados_no_pool', x.selados_no_pool
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
           count(*) as total,
           count(*) filter (where cc.seal <> 'none' and cc.owner_id is null
                              and cc.first_discovered_at is null) as selados_no_pool
    from public.tiers t
    join public.card_types ct on ct.tier = t.slug
    join public.card_copies cc on cc.card_type_id = ct.id
    group by t.slug, t.tier_order
  ) x;
$fn$;

alter function public.estoque_publico() owner to postgres;
grant execute on function public.estoque_publico() to anon, authenticated;

select private.fechar_grants();
