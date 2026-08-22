-- BELESMA figurinhas - fecha o GRANT automatico para PUBLIC

-- O Postgres da EXECUTE a PUBLIC em toda funcao criada, sem pedir. A
-- migracao de RLS revoga isso em massa, mas ela roda ANTES das migracoes que
-- criam funcoes novas - entao cada funcao adicionada depois nasce aberta de
-- novo. Auditoria no banco de producao achou 13 assim.
--
-- Nao era explorable hoje: o PostgREST so expoe o schema `public`, e as do
-- schema `private` nao tem rota. Mas `private.mover_baba` e literalmente
-- "credite baba nesta conta", e isso depender de uma opcao de configuracao
-- do PostgREST nao e defesa - e sorte.
--
-- Aqui a revogacao e por LOOP em vez de lista fixa, de proposito: lista fixa
-- envelhece na proxima funcao que alguem criar.
do $$
declare f record;
begin
  -- ------------------------------------------------------------- private
  -- Ninguem de fora chama nada do private. Os wrappers em public sao
  -- security definer e rodam como o dono, entao continuam enxergando tudo.
  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.assinatura);
  end loop;

  -- ------------------------------------------------------------- public
  -- Em public a regra e outra: revoga o implicito de PUBLIC e mantem so o
  -- que foi concedido de proposito a anon/authenticated.
  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and array_to_string(coalesce(p.proacl, '{}'), ',') like '=X/%'
  loop
    execute format('revoke all on function %s from public', f.assinatura);
  end loop;
end $$;

-- as que precisam continuar chamaveis
grant execute on function public.me()                                to authenticated;
grant execute on function public.sou_admin()                         to authenticated;
grant execute on function public.admin_recomecar_do_zero(text)       to authenticated;

-- ---------------------------------------------------------------- skins
-- Unica tabela de public sem RLS. Hoje nao vaza porque anon e authenticated
-- nao tem grant nenhum nela, mas "sem RLS + sem grant" e uma trava so; o
-- resto do schema tem duas. Ligar a RLS sem policy mantem o padrao do
-- projeto: nega tudo, e o acesso se abre ponto a ponto.
alter table public.skins enable row level security;
