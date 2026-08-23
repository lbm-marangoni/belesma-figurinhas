// Varredura do banco de PRODUCAO: seguranca e integridade dos dados.
//
//   SUPABASE_ACCESS_TOKEN=sbp_... node scripts/auditoria-producao.mjs
//
// Os harnesses locais rodam num PGlite recem-criado e provam a LOGICA. Este
// aqui olha o banco de verdade, com os dados de verdade, e pergunta outra
// coisa: o mundo esta consistente agora?
//
// So LE. Nenhuma escrita, nenhum DDL - da para rodar a qualquer momento.

const TOKEN = process.env.SUPABASE_ACCESS_TOKEN
const REF = process.env.SUPABASE_PROJECT_REF ?? 'jllecfwnwgabyqhhfanx'
if (!TOKEN) {
  console.error('falta SUPABASE_ACCESS_TOKEN (sbp_...). Gere em')
  console.error('https://supabase.com/dashboard/account/tokens')
  process.exit(2)
}

async function consultar(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  })
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`)
  return r.json()
}

let falhas = 0
const checar = (nome, ok, detalhe) => {
  console.log(`  ${ok ? 'PASS ' : 'FALHA'}  ${nome}${detalhe !== undefined ? ' -> ' + detalhe : ''}`)
  if (!ok) falhas++
}

// ================================================================ seguranca
console.log('== seguranca ==')
const [seg] = await consultar(`
select jsonb_build_object(
  'tabelas_sem_rls', (
    select coalesce(jsonb_agg(c.relname order by c.relname), '[]'::jsonb)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  'secdef_sem_search_path', (
    select coalesce(jsonb_agg(p.proname order by p.proname), '[]'::jsonb)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','private') and p.prosecdef
      and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c
                      where c like 'search_path=%')),
  'secdef_search_path_sem_extensions', (
    select coalesce(jsonb_agg(p.proname order by p.proname), '[]'::jsonb)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','private') and p.prosecdef
      and exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c
                  where c like 'search_path=%' and c not like '%extensions%')),
  'private_chamavel_de_fora', (
    select coalesce(jsonb_agg(p.proname order by p.proname), '[]'::jsonb)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and (has_function_privilege('anon', p.oid, 'execute')
        or has_function_privilege('authenticated', p.oid, 'execute'))),
  'admin_rpc_aberta_a_anon', (
    select coalesce(jsonb_agg(p.proname order by p.proname), '[]'::jsonb)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'admin\\_%'
      and has_function_privilege('anon', p.oid, 'execute')),
  'grant_residual_para_public', (
    select coalesce(jsonb_agg(p.proname order by p.proname), '[]'::jsonb)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','private')
      and array_to_string(coalesce(p.proacl, '{}'), ',') like '=X/%'),
  'escrita_liberada_para_anon', (
    select coalesce(jsonb_agg(distinct table_name order by table_name), '[]'::jsonb)
    from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'anon'
      and privilege_type in ('INSERT','UPDATE','DELETE')),
  'escrita_liberada_para_authenticated', (
    select coalesce(jsonb_agg(distinct table_name order by table_name), '[]'::jsonb)
    from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'authenticated'
      and privilege_type in ('INSERT','UPDATE','DELETE')),
  'sem_policy_de_leitura', (
    select coalesce(jsonb_agg(c.relname order by c.relname), '[]'::jsonb)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
      and not exists (select 1 from pg_policy p where p.polrelid = c.oid))
) as r`)

for (const [chave, valor] of Object.entries(seg.r)) {
  // Estas tres NEGAM tudo de proposito: RLS ligada, zero policy. `players`
  // so sai por me() e players_public; trade_rewards e trava anti-impressora;
  // skins e catalogo interno.
  if (chave === 'sem_policy_de_leitura') {
    const esperado = ['players', 'skins', 'trade_rewards']
    const extra = valor.filter((t) => !esperado.includes(t))
    const sumiu = esperado.filter((t) => !valor.includes(t))
    checar('nega-tudo continua sendo exatamente players/skins/trade_rewards',
      extra.length === 0 && sumiu.length === 0,
      extra.length ? `a mais: ${extra}` : sumiu.length ? `abriu: ${sumiu}` : 'ok')
    continue
  }
  checar(chave.replace(/_/g, ' '), valor.length === 0, valor.length ? String(valor) : 'nenhum')
}

// ================================================================ integridade
console.log('\n== integridade do acervo ==')
const [inv] = await consultar(`
select jsonb_build_object(
  'serial_duplicado', (select count(*) from (
      select card_type_id, serial_number from card_copies
      where origin = 'pull' group by 1,2 having count(*) > 1) x),
  'pull_sem_serial', (select count(*) from card_copies where origin='pull' and serial_number is null),
  'forjada_com_serial', (select count(*) from card_copies where origin='forge' and serial_number is not null),
  'serial_fora_da_tiragem', (select count(*) from card_copies cc join card_types ct on ct.id=cc.card_type_id
      where cc.origin='pull' and (cc.serial_number < 1 or cc.serial_number > ct.print_run)),
  'tipo_com_numero_errado_de_copias', (select count(*) from (
      select cc.card_type_id from card_copies cc join card_types ct on ct.id=cc.card_type_id
      where cc.origin='pull' group by cc.card_type_id, ct.print_run
      having count(*) <> ct.print_run) x),
  'selo_em_forjada', (select count(*) from card_copies where origin='forge' and seal <> 'none'),
  'reserva_fora_de_comum_incomum', (select count(*) from card_copies cc
      join card_types ct on ct.id=cc.card_type_id
      where cc.reserved_for_daily and ct.tier not in ('comum','incomum')),
  'estreia_sem_descobridor', (select count(*) from card_copies
      where first_discovered_at is not null and first_discovered_by is null),
  'descobridor_sem_data', (select count(*) from card_copies
      where first_discovered_by is not null and first_discovered_at is null),
  'vitrine_com_carta_alheia', (select count(*) from players p
      join card_copies cc on cc.id in (p.showcase_1, p.showcase_2, p.showcase_3)
      where cc.owner_id is distinct from p.id),
  'album_com_carta_alheia', (select count(*) from album_colagem a
      join card_copies cc on cc.id = a.copy_id where cc.owner_id is distinct from a.player_id),
  'album_no_slot_errado', (select count(*) from album_colagem a
      join card_copies cc on cc.id = a.copy_id where cc.card_type_id <> a.card_type_id),
  'baba_negativa', (select count(*) from players where baba < 0),
  'saldo_diverge_do_extrato', (select count(*) from players p
      where p.baba <> coalesce((select sum(delta) from baba_log b where b.player_id = p.id), 0)),
  'troca_pendente_com_carta_sem_dono', (select count(*) from trades t
      join card_copies cc on cc.id in (t.offered_copy_id, t.requested_copy_id)
      where t.status='pending' and cc.owner_id is null),
  'copia_orfa_de_tipo', (select count(*) from card_copies cc
      where not exists (select 1 from card_types ct where ct.id = cc.card_type_id))
) as r`)
for (const [chave, valor] of Object.entries(inv.r)) {
  checar(chave.replace(/_/g, ' '), Number(valor) === 0, String(valor))
}

// ================================================================ numeros do mundo
console.log('\n== os numeros do mundo ==')
const [n] = await consultar(`
select jsonb_build_object(
  'puxadas',  (select count(*) from card_copies where origin='pull'),
  'forjadas', (select count(*) from card_copies where origin='forge'),
  'tipos',    (select count(*) from card_types),
  'personagens', (select count(*) from characters),
  'branco', (select count(*) from card_copies where seal='branco'),
  'preto',  (select count(*) from card_copies where seal='preto'),
  'rosa',   (select count(*) from card_copies where seal='rosa'),
  'reserva',(select count(*) from card_copies
             where reserved_for_daily and not burned and owner_id is null),
  'reserva_marcada',(select count(*) from card_copies where reserved_for_daily and not burned),
  'pack_config_fora_de_100', (select coalesce(jsonb_agg(pack_type||'/'||slot||'='||soma), '[]'::jsonb)
      from (select pack_type::text, slot::text, sum(weight) as soma from pack_config
            group by 1,2 having abs(sum(weight) - 100) > 0.001) x),
  'com_dono', (select count(*) from card_copies where owner_id is not null),
  'distribuidas', (select count(*) from card_copies where first_discovered_at is not null),
  'jogadores', (select count(*) from players)
) as r`)
const m = n.r
checar('6642 copias puxadas (3 personagens x 2214)', Number(m.puxadas) === 6642, m.puxadas)
checar('81 tipos', Number(m.tipos) === 81, m.tipos)
checar('3 personagens no lancamento', Number(m.personagens) === 3, m.personagens)
checar('selos 36 / 12 / 3',
  Number(m.branco) === 36 && Number(m.preto) === 12 && Number(m.rosa) === 3,
  `${m.branco}/${m.preto}/${m.rosa}`)
// A flag continua na copia mesmo depois de entregue, para que ela volte a
// reserva se for vendida. Entao o que se cobra e a reserva DISPONIVEL: e ela
// que o diario consome, e e ela que o claim_daily repoe.
checar('reserva diaria disponivel em 1500', Number(m.reserva) === 1500,
  `${m.reserva} disponiveis de ${m.reserva_marcada} marcadas`)
checar('toda tabela de pack_config soma 100',
  m.pack_config_fora_de_100.length === 0, String(m.pack_config_fora_de_100))
console.log(`   ${m.jogadores} jogadores · ${m.com_dono} copias em maos · ` +
            `${m.distribuidas} ja distribuidas · ${m.forjadas} forjadas`)

console.log(`\n${falhas === 0 ? 'TUDO PASSOU' : falhas + ' FALHA(S)'}`)
process.exit(falhas === 0 ? 0 : 1)
