-- BELESMA figurinhas - o censo de escassez fica visivel para o cliente

-- O filtro "mais rara primeiro" da Colecao ordenava so por tier_order, o
-- mesmo defeito que a joia tinha: uma cosmica com selo, unica no mundo,
-- aparecia embaixo de qualquer divina. Para a tela usar o criterio de
-- verdade ela precisa do censo, e o censo e informacao publica - o indice
-- global ja diz quantas copias de cada tipo existem.
--
-- Devolve a tabela inteira de uma vez: sao ~30 linhas, e o cliente resolve
-- as ordenacoes localmente sem uma consulta por carta.
create or replace function public.escassez_por_classe()
returns jsonb
language sql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'tier', tier, 'seal', seal, 'copias', copias) order by copias, tier), '[]'::jsonb)
  from private.censo_raridade;
$fn$;

alter function public.escassez_por_classe() owner to postgres;
grant execute on function public.escassez_por_classe() to anon, authenticated;

select private.fechar_grants();
