-- BELESMA figurinhas - criar e editar pacote pelo painel

-- Recebe a definicao INTEIRA num jsonb - cabecalho e slots juntos - e grava
-- em uma transacao. Editar slot por slot deixaria o pacote num estado
-- intermediario invalido (odds nao somando 100) por alguns milissegundos, e
-- alguem podendo abrir nesse intervalo.
--
--   { id, slug, name, descricao, art_path, tamanho, distribuicao,
--     elegivel_loja, preco_baba, limite_global, ativo,
--     taxa_quente, taxa_bonus, taxa_promocao, pity_limite, pity_piso_tier,
--     allotment_quantidade, diario_quantidade, diario_ciclo,
--     slots: [ { ordem, filtro, garantido, odds: [{tier, weight}] } ] }
create or replace function public.admin_salvar_pacote(p_def jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_id     int := nullif(p_def->>'id', '')::int;
  v_novo   boolean := v_id is null;
  v_slug   extensions.citext := lower(trim(p_def->>'slug'))::extensions.citext;
  v_s      jsonb;
  v_o      jsonb;
  v_slot   int;
  v_soma   numeric;
  v_ordem  int := 0;
  v_ev     jsonb;
  v_piso   numeric;
begin
  perform private.require_admin();

  if v_slug is null or length(v_slug::text) < 2 then
    raise exception 'slug obrigatorio';
  end if;
  if v_slug::text !~ '^[a-z0-9][a-z0-9_-]{1,29}$' then
    raise exception 'slug: minusculas, numeros, - e _, de 2 a 30 caracteres';
  end if;
  if coalesce(jsonb_array_length(p_def->'slots'), 0) = 0 then
    raise exception 'um pacote precisa de pelo menos um slot';
  end if;

  -- odds de cada slot precisam somar 100 ANTES de qualquer escrita
  for v_s in select * from jsonb_array_elements(p_def->'slots') loop
    select coalesce(sum((o->>'weight')::numeric), 0) into v_soma
    from jsonb_array_elements(v_s->'odds') o;
    if abs(v_soma - 100) > 0.01 then
      raise exception 'as odds de um slot somam %, precisam somar 100', v_soma;
    end if;
    if exists (select 1 from jsonb_array_elements(v_s->'odds') o
               where not exists (select 1 from public.tiers where slug = o->>'tier')) then
      raise exception 'ha um tier que nao existe nas odds';
    end if;
  end loop;

  -- ------------------------------------------------------------- cabecalho
  if v_novo then
    insert into public.pack_definitions (
      slug, name, descricao, art_path, tamanho, distribuicao, elegivel_loja,
      preco_baba, limite_global, ativo, taxa_quente, taxa_bonus, taxa_promocao,
      pity_limite, pity_piso_tier, allotment_quantidade, diario_quantidade,
      diario_ciclo, created_by)
    values (
      v_slug, p_def->>'name', p_def->>'descricao', p_def->>'art_path',
      (p_def->>'tamanho')::int, (p_def->>'distribuicao')::public.pack_distribuicao,
      coalesce((p_def->>'elegivel_loja')::boolean, false),
      nullif(p_def->>'preco_baba','')::int, nullif(p_def->>'limite_global','')::int,
      coalesce((p_def->>'ativo')::boolean, true),
      coalesce((p_def->>'taxa_quente')::numeric, 0),
      coalesce((p_def->>'taxa_bonus')::numeric, 0),
      coalesce((p_def->>'taxa_promocao')::numeric, 0),
      nullif(p_def->>'pity_limite','')::int, nullif(p_def->>'pity_piso_tier',''),
      coalesce((p_def->>'allotment_quantidade')::int, 0),
      coalesce((p_def->>'diario_quantidade')::int, 0),
      coalesce((p_def->>'diario_ciclo')::int, 1),
      auth.uid())
    returning id into v_id;
  else
    update public.pack_definitions set
      slug = v_slug, name = p_def->>'name', descricao = p_def->>'descricao',
      art_path = p_def->>'art_path', tamanho = (p_def->>'tamanho')::int,
      distribuicao = (p_def->>'distribuicao')::public.pack_distribuicao,
      elegivel_loja = coalesce((p_def->>'elegivel_loja')::boolean, false),
      preco_baba = nullif(p_def->>'preco_baba','')::int,
      limite_global = nullif(p_def->>'limite_global','')::int,
      ativo = coalesce((p_def->>'ativo')::boolean, true),
      taxa_quente = coalesce((p_def->>'taxa_quente')::numeric, 0),
      taxa_bonus = coalesce((p_def->>'taxa_bonus')::numeric, 0),
      taxa_promocao = coalesce((p_def->>'taxa_promocao')::numeric, 0),
      pity_limite = nullif(p_def->>'pity_limite','')::int,
      pity_piso_tier = nullif(p_def->>'pity_piso_tier',''),
      allotment_quantidade = coalesce((p_def->>'allotment_quantidade')::int, 0),
      diario_quantidade = coalesce((p_def->>'diario_quantidade')::int, 0),
      diario_ciclo = coalesce((p_def->>'diario_ciclo')::int, 1)
    where id = v_id;
    if not found then raise exception 'pacote % nao existe', v_id; end if;
  end if;

  -- ------------------------------------------------------------- slots
  delete from public.pack_slots where pack_definition_id = v_id;
  for v_s in select * from jsonb_array_elements(p_def->'slots') loop
    v_ordem := v_ordem + 1;
    insert into public.pack_slots (pack_definition_id, ordem, filtro, garantido)
    values (v_id, v_ordem, coalesce(v_s->'filtro', '{}'::jsonb),
            coalesce((v_s->>'garantido')::boolean, false))
    returning id into v_slot;

    for v_o in select * from jsonb_array_elements(v_s->'odds') loop
      if (v_o->>'weight')::numeric > 0 then
        insert into public.pack_slot_odds (pack_slot_id, tier, weight)
        values (v_slot, v_o->>'tier', (v_o->>'weight')::numeric);
      end if;
    end loop;
  end loop;

  -- ------------------------------------------------------------- piso
  -- Depois dos slots, porque o EV depende deles. Este e o unico bloqueio
  -- duro do construtor: abaixo do piso o pacote se paga vendendo o proprio
  -- conteudo, e isso e uma impressora de baba.
  if coalesce((p_def->>'elegivel_loja')::boolean, false) then
    v_ev := public.admin_ev_pacote(v_id);
    v_piso := (v_ev->>'piso')::numeric;
    if nullif(p_def->>'preco_baba','')::numeric is null then
      raise exception 'pacote de loja precisa de preco';
    end if;
    if (p_def->>'preco_baba')::numeric < v_piso then
      -- literal inteiro numa linha so: RAISE quer um literal, nao expressao,
      -- entao `'a' || 'b'` como formato e erro de sintaxe
      raise exception 'Preco abaixo do piso - este pacote permite lucro vendendo o conteudo, criando geracao infinita de baba. (EV %, piso %)',
        v_ev->>'ev', v_piso;
    end if;
  end if;

  perform private.registrar(
    case when v_novo then 'pacote_criado' else 'pacote_editado' end,
    v_slug::text, p_def);

  return jsonb_build_object('id', v_id, 'slug', v_slug::text, 'novo', v_novo,
                            'ev', public.admin_ev_pacote(v_id),
                            'viabilidade', public.admin_viabilidade_pacote(v_id));
end;
$fn$;

-- ---------------------------------------------------------------- ativar
create or replace function public.admin_pacote_ativo(p_id int, p_ativo boolean)
returns boolean
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_slug text;
begin
  perform private.require_admin();
  update public.pack_definitions set ativo = p_ativo where id = p_id
  returning slug::text into v_slug;
  if v_slug is null then raise exception 'pacote nao existe'; end if;
  perform private.registrar('pacote_ativo', v_slug, jsonb_build_object('ativo', p_ativo));
  return p_ativo;
end;
$fn$;

-- ---------------------------------------------------------------- apagar
create or replace function public.admin_apagar_pacote(p_id int, p_confirmacao text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare d public.pack_definitions; v_maos bigint;
begin
  perform private.require_admin();
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;
  if p_confirmacao <> d.slug::text then
    raise exception 'confirmacao invalida: digite %', d.slug;
  end if;

  -- Pacote ja aberto tem historico apontando para ele; apagar reescreveria o
  -- passado. Desativar e o caminho.
  if d.aberturas_realizadas > 0 then
    raise exception '"%" ja foi aberto % vezes: desative em vez de apagar',
      d.name, d.aberturas_realizadas;
  end if;
  select coalesce(sum(quantidade), 0) into v_maos
  from public.player_packs where pack_definition_id = d.id;
  if v_maos > 0 then
    raise exception 'ha % copias de "%" na mao de jogadores', v_maos, d.name;
  end if;

  delete from public.pack_definitions where id = p_id;
  perform private.registrar('pacote_apagado', d.slug::text, to_jsonb(d));
  return jsonb_build_object('apagado', d.slug::text);
end;
$fn$;

-- ---------------------------------------------------------------- entregar
create or replace function public.admin_entregar_pacote(
  p_id int, p_target text, p_quantidade int, p_diario boolean default false)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare d public.pack_definitions; v_n int := 0; v_p record;
begin
  perform private.require_admin();
  if p_quantidade is null or p_quantidade = 0 then raise exception 'quantidade invalida'; end if;
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;

  for v_p in
    select id from public.players
    where p_target = 'todos' or nickname = p_target::extensions.citext
  loop
    if p_quantidade > 0 then
      perform private.dar_pacote(v_p.id, d.id, p_diario, p_quantidade);
    else
      update public.player_packs set quantidade = greatest(0, quantidade + p_quantidade)
      where player_id = v_p.id and pack_definition_id = d.id and do_diario = p_diario;
    end if;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then raise exception 'nenhum jogador casou com "%"', p_target; end if;

  perform private.registrar('pacote_entregue', p_target,
    jsonb_build_object('pacote', d.slug::text, 'quantidade', p_quantidade,
                       'diario', p_diario, 'jogadores', v_n));
  return v_n;
end;
$fn$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_salvar_pacote(jsonb)', 'admin_pacote_ativo(int, boolean)',
    'admin_apagar_pacote(int, text)', 'admin_entregar_pacote(int, text, int, boolean)']
  loop
    execute format('alter function public.%s owner to postgres', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

select private.fechar_grants();
