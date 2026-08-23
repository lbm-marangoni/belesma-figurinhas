-- BELESMA figurinhas - o construtor de pacotes do painel admin

-- ================================================================ leitura
create or replace function public.admin_pacotes()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  perform private.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', d.id, 'slug', d.slug::text, 'name', d.name, 'descricao', d.descricao,
      'art_path', d.art_path, 'tamanho', d.tamanho,
      'distribuicao', d.distribuicao::text,
      'elegivel_loja', d.elegivel_loja, 'preco_baba', d.preco_baba,
      'limite_global', d.limite_global, 'aberturas_realizadas', d.aberturas_realizadas,
      'taxa_quente', d.taxa_quente, 'taxa_bonus', d.taxa_bonus,
      'taxa_promocao', d.taxa_promocao,
      'pity_limite', d.pity_limite, 'pity_piso_tier', d.pity_piso_tier,
      'allotment_quantidade', d.allotment_quantidade,
      'diario_quantidade', d.diario_quantidade, 'diario_ciclo', d.diario_ciclo,
      'ativo', d.ativo, 'created_at', d.created_at,
      'em_maos', coalesce((select sum(quantidade) from public.player_packs pp
                           where pp.pack_definition_id = d.id), 0),
      'slots', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', s.id, 'ordem', s.ordem, 'filtro', s.filtro, 'garantido', s.garantido,
          'odds', coalesce((select jsonb_agg(jsonb_build_object('tier', o.tier, 'weight', o.weight)
                                             order by t.tier_order)
                            from public.pack_slot_odds o
                            join public.tiers t on t.slug = o.tier
                            where o.pack_slot_id = s.id), '[]'::jsonb)
        ) order by s.ordem)
        from public.pack_slots s where s.pack_definition_id = d.id), '[]'::jsonb)
    ) order by d.id)
    from public.pack_definitions d), '[]'::jsonb);
end;
$fn$;

-- ================================================================ estoque
-- Quanto ha disponivel de cada tier dentro de um filtro. Base da sugestao de
-- odds, do aviso de esgotamento e da checagem de viabilidade.
create or replace function private.estoque_do_filtro(p_filtro jsonb)
returns table (tier text, tier_order smallint, estoque bigint)
language sql stable
set search_path = public, extensions, pg_temp
as $fn$
  select ct.tier, ct.tier_order, count(*)
  from public.card_copies cc
  join public.card_types ct on ct.id = cc.card_type_id
  where cc.owner_id is null and not cc.burned
    and ct.id in (select private.tipos_do_filtro(p_filtro))
  group by ct.tier, ct.tier_order
  order by ct.tier_order;
$fn$;

-- ================================================================ sugerir odds
-- Proporcional ao ESTOQUE, amaciado por uma curva que preserva a hierarquia.
--
-- Estoque puro nao serve sozinho: no set atual ha 90 cosmicas e 60 miticas,
-- entao proporcionalidade crua faria a cosmica - que e MAIS rara - sair com
-- mais frequencia que a mitica. A curva impede isso: descendo a escada, o
-- peso de um tier nunca passa de 60% do peso do tier imediatamente mais
-- comum que tenha estoque.
create or replace function private.sugerir_odds(p_filtro jsonb)
returns jsonb
language plpgsql stable
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_r      record;
  v_peso   numeric;
  v_ant    numeric := null;
  v_soma   numeric := 0;
  v_linhas jsonb := '[]'::jsonb;
  v_saida  jsonb := '[]'::jsonb;
  v_decaimento constant numeric := 0.6;
begin
  for v_r in select * from private.estoque_do_filtro(p_filtro) loop
    v_peso := v_r.estoque::numeric;
    if v_ant is not null then v_peso := least(v_peso, v_ant * v_decaimento); end if;
    if v_peso <= 0 then continue; end if;
    v_ant  := v_peso;
    v_soma := v_soma + v_peso;
    v_linhas := v_linhas || jsonb_build_object(
      'tier', v_r.tier, 'tier_order', v_r.tier_order,
      'estoque', v_r.estoque, 'bruto', v_peso);
  end loop;

  if v_soma = 0 then
    return jsonb_build_object('odds', '[]'::jsonb, 'aviso',
      'nenhuma copia disponivel casa com este filtro');
  end if;

  select jsonb_agg(jsonb_build_object(
    'tier', x->>'tier',
    'weight', round((x->>'bruto')::numeric * 100 / v_soma, 2),
    'estoque', (x->>'estoque')::bigint,
    -- quantas aberturas ate este tier acabar, na frequencia sugerida
    'aberturas_ate_esgotar',
      case when (x->>'bruto')::numeric > 0
           then floor((x->>'estoque')::numeric
                      / ((x->>'bruto')::numeric / v_soma))::bigint end
  ) order by (x->>'tier_order')::int) into v_saida
  from jsonb_array_elements(v_linhas) x;

  -- arredondamento: sobra ou falta vai para o tier mais comum, que e o de
  -- maior peso e onde a diferenca menos se nota
  return jsonb_build_object(
    'odds', v_saida,
    'soma', (select round(sum((o->>'weight')::numeric), 2)
             from jsonb_array_elements(v_saida) o),
    'decaimento', v_decaimento);
end;
$fn$;

create or replace function public.admin_sugerir_odds(p_filtro jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  perform private.require_admin();
  return private.sugerir_odds(p_filtro);
end;
$fn$;

-- ================================================================ valor esperado
-- EV em baba: soma, sobre todos os slots e tiers, de probabilidade x preco
-- de venda do tier. Leva a variancia em conta - quente, promocao e bonus
-- mudam o valor medio de um pacote e ignora-los subestima o EV.
create or replace function public.admin_ev_pacote(p_id int)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  d          public.pack_definitions;
  v_s        record;
  v_ev_ref   numeric := 0;
  v_ev       numeric := 0;
  v_ev_gar   numeric := 0;
  v_ev_nao   numeric := 0;
  v_n_nao    int := 0;
  v_min      numeric := 0;
  v_max      numeric := 0;
  v_var      numeric := 0;
  v_ev1      numeric := 0;
  v_primeiro boolean := true;
begin
  perform private.require_admin();
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;

  -- EV do slot de referencia (o garantido de maior ordem), usado por quente
  -- e promocao
  select coalesce(sum(o.weight * coalesce(private.preco('venda_' || o.tier), 0))
                  / nullif(sum(o.weight), 0), 0)
    into v_ev_ref
  from public.pack_slot_odds o
  where o.pack_slot_id = (select id from public.pack_slots
                          where pack_definition_id = d.id and garantido
                          order by ordem desc limit 1);

  for v_s in
    select s.id, s.ordem, s.garantido,
           coalesce(sum(o.weight), 0)                                   as peso,
           -- Prisma nao tem `venda_prisma` porque prisma nao se vende, e um
           -- null aqui envenenava a soma inteira. Vale 0 no EV, e esta certo:
           -- o EV responde "da para lucrar vendendo o conteudo?", e conteudo
           -- invendavel nao financia nada.
           coalesce(sum(o.weight * coalesce(private.preco('venda_' || o.tier), 0)), 0) as soma_val,
           coalesce(sum(o.weight * power(coalesce(private.preco('venda_' || o.tier), 0), 2)), 0) as soma_q,
           min(coalesce(private.preco('venda_' || o.tier), 0))          as menor,
           max(coalesce(private.preco('venda_' || o.tier), 0))          as maior
    from public.pack_slots s
    left join public.pack_slot_odds o on o.pack_slot_id = s.id and o.weight > 0
    where s.pack_definition_id = d.id
    group by s.id, s.ordem, s.garantido
    order by s.ordem
  loop
    continue when v_s.peso = 0;
    declare
      v_mu numeric := v_s.soma_val / v_s.peso;
      v_e2 numeric := v_s.soma_q  / v_s.peso;
    begin
      if v_s.garantido then
        v_ev_gar := v_ev_gar + v_mu;
      else
        v_ev_nao := v_ev_nao + v_mu;
        v_n_nao  := v_n_nao + 1;
      end if;
      v_var := v_var + (v_e2 - v_mu * v_mu);
      v_min := v_min + v_s.menor;
      v_max := v_max + v_s.maior;
      if v_primeiro then v_ev1 := v_mu; v_primeiro := false; end if;
    end;
  end loop;

  -- quente troca TODOS os nao garantidos pelo de referencia; fora dele, cada
  -- nao garantido tem taxa_promocao de virar o de referencia
  v_ev :=
      d.taxa_quente * (v_ev_ref * v_n_nao + v_ev_gar)
    + (1 - d.taxa_quente) * (
        v_ev_gar
        + d.taxa_promocao * v_ev_ref * v_n_nao
        + (1 - d.taxa_promocao) * v_ev_nao)
    -- carta bonus repete o primeiro slot
    + d.taxa_bonus * v_ev1;

  return jsonb_build_object(
    'ev', round(v_ev, 2),
    'ev_minimo', round(v_min, 2),
    'ev_maximo', round(v_max + (case when d.taxa_bonus > 0 then v_ev1 else 0 end), 2),
    'desvio', round(sqrt(greatest(v_var, 0)), 2),
    'ev_do_slot_garantido', round(v_ev_ref, 2),
    'preco', d.preco_baba,
    'piso',      round(v_ev * private.preco('preco_multiplicador_piso'), 0),
    'sugerido',  round(v_ev * private.preco('preco_multiplicador_sugerido'), 0),
    'teto_aviso',round(v_ev * private.preco('preco_multiplicador_alerta'), 0),
    'margem_pct', case when v_ev > 0 and d.preco_baba is not null
                       then round((d.preco_baba / v_ev - 1) * 100, 1) end,
    'ev_da_edicao', case when d.limite_global is not null
                         then round(v_ev * d.limite_global, 0) end);
end;
$fn$;

-- ================================================================ viabilidade
create or replace function public.admin_viabilidade_pacote(p_id int)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  d       public.pack_definitions;
  v_s     record;
  v_o     record;
  v_ev    jsonb;
  v_av    jsonb := '[]'::jsonb;
  v_soma  numeric;
  v_est   bigint;
  v_gasta numeric;
begin
  perform private.require_admin();
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;

  if not exists (select 1 from public.pack_slots where pack_definition_id = d.id) then
    v_av := v_av || jsonb_build_object('nivel','erro',
      'texto','o pacote nao tem slot nenhum: abrir vai falhar');
  end if;

  if d.tamanho <> (select count(*) from public.pack_slots where pack_definition_id = d.id) then
    v_av := v_av || jsonb_build_object('nivel','aviso', 'texto',
      format('tamanho diz %s cartas mas ha %s slots; quem manda e o numero de slots',
             d.tamanho, (select count(*) from public.pack_slots where pack_definition_id = d.id)));
  end if;

  for v_s in select * from public.pack_slots where pack_definition_id = d.id order by ordem loop
    select coalesce(sum(weight), 0) into v_soma
    from public.pack_slot_odds where pack_slot_id = v_s.id;

    if abs(v_soma - 100) > 0.01 then
      v_av := v_av || jsonb_build_object('nivel','erro', 'slot', v_s.ordem,
        'texto', format('as odds do slot %s somam %s%%, nao 100%%', v_s.ordem, v_soma));
    end if;

    if not exists (select 1 from private.estoque_do_filtro(v_s.filtro)) then
      v_av := v_av || jsonb_build_object('nivel','erro', 'slot', v_s.ordem,
        'texto', format('o filtro do slot %s nao casa com nenhuma copia disponivel', v_s.ordem));
    end if;

    -- tier das odds sem estoque dentro do filtro
    for v_o in
      select o.tier, o.weight from public.pack_slot_odds o
      where o.pack_slot_id = v_s.id and o.weight > 0
        and not exists (select 1 from private.estoque_do_filtro(v_s.filtro) e
                        where e.tier = o.tier)
    loop
      v_av := v_av || jsonb_build_object('nivel','aviso', 'slot', v_s.ordem,
        'texto', format('slot %s pede %s (%s%%) mas nao ha %s disponivel dentro do filtro',
                        v_s.ordem, v_o.tier, v_o.weight, v_o.tier));
    end loop;

    -- quantas aberturas ate o tier mais raro do slot esgotar
    select e.estoque, o.weight / nullif(v_soma, 0) into v_est, v_gasta
    from public.pack_slot_odds o
    join public.tiers t on t.slug = o.tier
    join lateral private.estoque_do_filtro(v_s.filtro) e on e.tier = o.tier
    where o.pack_slot_id = v_s.id and o.weight > 0
    order by t.tier_order desc limit 1;

    if v_est is not null and v_gasta > 0 and floor(v_est / v_gasta) < 20 then
      v_av := v_av || jsonb_build_object('nivel','aviso', 'slot', v_s.ordem,
        'texto', format('o tier mais raro do slot %s esgota em ~%s aberturas',
                        v_s.ordem, floor(v_est / v_gasta)));
    end if;

    if d.elegivel_loja and exists (
      select 1 from public.pack_slot_odds o
      where o.pack_slot_id = v_s.id and o.weight > 0
        and o.tier in ('prisma','aura','diamante'))
    then
      v_av := v_av || jsonb_build_object('nivel','aviso', 'slot', v_s.ordem,
        'texto', format('slot %s tem tier de topo num pacote comprável: prisma, aura e '
                     || 'diamante somam poucas dezenas de copias no mundo e drenam '
                     || 'mais rapido do que se pretende', v_s.ordem));
    end if;
  end loop;

  if d.elegivel_loja then
    v_ev := public.admin_ev_pacote(d.id);
    if d.preco_baba is not null and (v_ev->>'piso') is not null
       and d.preco_baba < (v_ev->>'piso')::numeric then
      v_av := v_av || jsonb_build_object('nivel','erro', 'texto',
        'Preco abaixo do piso - este pacote permite lucro vendendo o conteudo, '
        || 'criando geracao infinita de baba.');
    end if;
    if d.preco_baba is not null and (v_ev->>'teto_aviso') is not null
       and d.preco_baba > (v_ev->>'teto_aviso')::numeric then
      v_av := v_av || jsonb_build_object('nivel','aviso', 'texto',
        format('preco %s esta acima de EV x 5 (%s): provavelmente ninguem compra',
               d.preco_baba, v_ev->>'teto_aviso'));
    end if;
  end if;

  return jsonb_build_object('avisos', v_av,
    'erros', (select count(*) from jsonb_array_elements(v_av) a where a->>'nivel' = 'erro'));
end;
$fn$;

-- ================================================================ preview
-- Simula N aberturas SEM GRAVAR NADA. Nao chama open_pack de proposito: o
-- open_pack entrega cartas de verdade, e um preview que mexe no acervo nao e
-- preview. Aqui e amostragem sobre a mesma configuracao e o mesmo estoque.
create or replace function public.admin_preview_pacote(p_id int, p_n int default 1000)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  d          public.pack_definitions;
  v_ids      int[];
  v_id_slot  int;
  v_slot     public.pack_slots;
  v_uso      public.pack_slots;
  v_ref      public.pack_slots;
  v_i        int;
  v_bonus    boolean;
  v_quente   boolean;
  v_tier     text;
  v_tipo     record;
  v_por_tier jsonb := '{}'::jsonb;
  v_por_char jsonb := '{}'::jsonb;
  v_cartas   int := 0;
  v_valor    numeric := 0;
begin
  perform private.require_admin();
  if p_n is null or p_n < 1 or p_n > 20000 then raise exception 'n entre 1 e 20000'; end if;
  select * into d from public.pack_definitions where id = p_id;
  if d.id is null then raise exception 'pacote nao existe'; end if;

  select array_agg(id order by ordem) into v_ids
  from public.pack_slots where pack_definition_id = d.id;
  if v_ids is null then raise exception 'o pacote nao tem slot nenhum'; end if;

  select * into v_ref from public.pack_slots
  where pack_definition_id = d.id and garantido order by ordem desc limit 1;

  for v_i in 1 .. p_n loop
    v_quente := private.random_int(100000) < d.taxa_quente * 100000;
    v_bonus  := private.random_int(100000) < d.taxa_bonus  * 100000;

    foreach v_id_slot in array (case when v_bonus then v_ids || v_ids[1] else v_ids end) loop
      select * into v_slot from public.pack_slots where id = v_id_slot;
      v_uso := v_slot;
      if v_ref.id is not null and not v_slot.garantido
         and (v_quente or private.random_int(100000) < d.taxa_promocao * 100000) then
        v_uso := v_ref;
      end if;

      -- sorteia o tier entre os que TEM estoque dentro do filtro
      select o.tier into v_tier
      from public.pack_slot_odds o
      join lateral private.estoque_do_filtro(v_uso.filtro) e on e.tier = o.tier
      where o.pack_slot_id = v_uso.id and o.weight > 0
      order by -ln(1 - (private.random_int(1000000)::numeric / 1000000)) / o.weight
      limit 1;
      continue when v_tier is null;

      -- e um tipo dentro do tier, proporcional ao estoque
      select ct.tier, ch.slug as personagem into v_tipo
      from public.card_types ct
      join public.characters ch on ch.id = ct.character_id
      join public.card_copies cc on cc.card_type_id = ct.id
      where ct.tier = v_tier and cc.owner_id is null and not cc.burned
        and ct.id in (select private.tipos_do_filtro(v_uso.filtro))
      order by extensions.gen_random_bytes(8) limit 1;
      continue when v_tipo is null;

      v_cartas   := v_cartas + 1;
      v_valor    := v_valor + coalesce(private.preco('venda_' || v_tier), 0);
      v_por_tier := jsonb_set(v_por_tier, array[v_tier],
                      to_jsonb(coalesce((v_por_tier->>v_tier)::int, 0) + 1));
      v_por_char := jsonb_set(v_por_char, array[v_tipo.personagem],
                      to_jsonb(coalesce((v_por_char->>v_tipo.personagem)::int, 0) + 1));
    end loop;
  end loop;

  return jsonb_build_object(
    'aberturas', p_n,
    'cartas', v_cartas,
    'cartas_por_abertura', round(v_cartas::numeric / p_n, 2),
    'valor_medio', round(v_valor / p_n, 2),
    -- o fecho do coalesce vem ANTES do from: `coalesce(agg(...) from ...)`
    -- deixa o coalesce aberto quando o from aparece, e o parser reclama
    'por_tier', (select coalesce(jsonb_agg(jsonb_build_object(
                     'tier', e.k, 'n', e.v::int,
                     'pct', round(e.v::numeric * 100 / nullif(v_cartas, 0), 2))
                     order by t.tier_order desc), '[]'::jsonb)
                 from jsonb_each_text(v_por_tier) as e(k, v)
                 join public.tiers t on t.slug = e.k),
    'por_personagem', (select coalesce(jsonb_agg(jsonb_build_object(
                     'personagem', e.k, 'n', e.v::int,
                     'pct', round(e.v::numeric * 100 / nullif(v_cartas, 0), 2))
                     order by e.k), '[]'::jsonb)
                 from jsonb_each_text(v_por_char) as e(k, v)));
end;
$fn$;

-- ================================================================ relatorio
create or replace function public.admin_relatorio_loja()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_d record; v_ev jsonb; v_out jsonb := '[]'::jsonb;
begin
  perform private.require_admin();
  for v_d in select * from public.pack_definitions where elegivel_loja order by id loop
    v_ev := public.admin_ev_pacote(v_d.id);
    v_out := v_out || jsonb_build_object(
      'id', v_d.id, 'slug', v_d.slug::text, 'name', v_d.name, 'ativo', v_d.ativo,
      'preco', v_d.preco_baba,
      'ev', v_ev->'ev', 'piso', v_ev->'piso', 'sugerido', v_ev->'sugerido',
      'margem_pct', v_ev->'margem_pct',
      'abaixo_do_piso', (v_d.preco_baba < (v_ev->>'piso')::numeric),
      'compras', (select count(*) from public.baba_log
                  where motivo = 'compra' and ref_id = v_d.slug::text),
      'aberturas', v_d.aberturas_realizadas, 'limite', v_d.limite_global);
  end loop;
  return v_out;
end;
$fn$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_pacotes()', 'admin_sugerir_odds(jsonb)', 'admin_ev_pacote(int)',
    'admin_viabilidade_pacote(int)', 'admin_preview_pacote(int, int)',
    'admin_relatorio_loja()']
  loop
    execute format('alter function public.%s owner to postgres', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

select private.fechar_grants();
