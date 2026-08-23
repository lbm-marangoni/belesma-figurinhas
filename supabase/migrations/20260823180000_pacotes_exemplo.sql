-- BELESMA figurinhas - tres pacotes de exemplo, feitos so com dados
--
-- Nenhuma linha de codigo novo: sao linhas de pack_definitions, pack_slots e
-- pack_slot_odds. E a prova de que o construtor faz o que promete.
--
-- Os tres nascem com distribuicao 'admin' e elegivel_loja = false. Ligar a
-- loja e um toggle no painel, e o piso de preco entra em vigor no mesmo ato.

create or replace function private.criar_pacote_exemplo(
  p_slug text, p_nome text, p_desc text, p_tamanho int, p_filtro jsonb)
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_def   int;
  v_slot  int;
  v_odds  jsonb;
  v_o     jsonb;
  v_i     int;
begin
  if exists (select 1 from public.pack_definitions where slug = p_slug::extensions.citext) then
    return (select id from public.pack_definitions where slug = p_slug::extensions.citext);
  end if;

  v_odds := private.sugerir_odds(p_filtro)->'odds';
  if v_odds is null or jsonb_array_length(v_odds) = 0 then
    raise notice 'filtro de "%" nao casa com nada, pacote nao criado', p_slug;
    return null;
  end if;

  insert into public.pack_definitions
    (slug, name, descricao, art_path, tamanho, distribuicao, elegivel_loja, ativo)
  values (p_slug::extensions.citext, p_nome, p_desc,
          'packs/booster-comum.png', p_tamanho, 'admin', false, true)
  returning id into v_def;

  for v_i in 1 .. p_tamanho loop
    insert into public.pack_slots (pack_definition_id, ordem, filtro, garantido)
    values (v_def, v_i, p_filtro, false)
    returning id into v_slot;

    for v_o in select * from jsonb_array_elements(v_odds) loop
      insert into public.pack_slot_odds (pack_slot_id, tier, weight)
      values (v_slot, v_o->>'tier', (v_o->>'weight')::numeric);
    end loop;

    -- a sugestao arredonda a 2 casas; a sobra vai para o tier de maior peso,
    -- que e onde a diferenca menos aparece
    update public.pack_slot_odds set weight = weight + (
      100 - (select sum(weight) from public.pack_slot_odds where pack_slot_id = v_slot))
    where id = (select id from public.pack_slot_odds
                where pack_slot_id = v_slot order by weight desc limit 1);
  end loop;

  return v_def;
end;
$fn$;

do $$
begin
  -- fogo, gelo, trovao e vento sao as quatro skins RARAS: o pacote inteiro
  -- sai de um tier so, e a sugestao de odds devolve rara 100%
  perform private.criar_pacote_exemplo(
    'elementais', 'Elementais',
    'Quatro cartas, todas dos quatro elementos: fogo, gelo, trovao e vento.',
    4, '{"skins": ["fogo","gelo","trovao","vento"]}'::jsonb);

  -- esmeralda, rubi, safira e ametista sao as quatro EPICAS
  perform private.criar_pacote_exemplo(
    'joias', 'Joias',
    'Quatro cartas de pedra preciosa: esmeralda, rubi, safira e ametista.',
    4, '{"skins": ["esmeralda","rubi","safira","ametista"]}'::jsonb);

  -- so o Pedrao, escada inteira a partir de comum. Aqui a sugestao mostra o
  -- que sabe fazer: distribui pelos doze tiers na proporcao do estoque, sem
  -- deixar um tier raro ficar mais provavel que um comum.
  perform private.criar_pacote_exemplo(
    'pedrao-comum-mais', 'Pedrao Comum+',
    'So o Belesma do Pedrao, de comum para cima.',
    4, '{"characters": ["pedrao"], "tiers_min": "comum"}'::jsonb);
end $$;

select private.fechar_grants();
