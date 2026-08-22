import { createClient } from '@supabase/supabase-js'
import { readFileSync } from 'node:fs'
const env = Object.fromEntries(readFileSync('.env.local','utf8').split('\n')
  .filter(l=>l.includes('=')&&!l.trim().startsWith('#'))
  .map(l=>[l.slice(0,l.indexOf('=')).trim(), l.slice(l.indexOf('=')+1).trim()]))
const admin = createClient(env.VITE_SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {auth:{persistSession:false}})
let f=0; const ck=(n,ok,d)=>{console.log(`  ${ok?'PASS':'FALHA'}  ${n}${d?' -> '+d:''}`); if(!ok)f++}
const novo = () => createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY, {auth:{persistSession:false}})
const SENHA='nick-123456'
for (const n of ['nick1','nick2','nick3']) {
  const {data} = await admin.auth.admin.listUsers({perPage:200})
  const v = data?.users?.find(u=>u.email===`${n}@belesma.local`)
  if (v) { await admin.from('players').delete().eq('id',v.id); await admin.auth.admin.deleteUser(v.id) }
}
const a = novo()
await a.auth.signUp({email:'nick1@belesma.local', password:SENHA})
await a.rpc('claim_nickname',{p_nickname:'nick1'})
const b = novo()
await b.auth.signUp({email:'nick3@belesma.local', password:SENHA})
await b.rpc('claim_nickname',{p_nickname:'nick3'})

console.log('\n== trocar de apelido ==')
const {error:e1} = await a.rpc('mudar_nickname',{p_novo:'nick3'})
ck('nao pega apelido em uso', !!e1, e1?.message)
const {data:d2,error:e2} = await a.rpc('mudar_nickname',{p_novo:'nick2'})
ck('troca funciona', !e2 && d2?.nickname==='nick2', e2?.message ?? d2?.nickname)
const {data:me} = await a.rpc('me'); ck('me() reflete o novo', me.nickname==='nick2')
const {data:hist} = await a.from('nickname_history').select('nickname')
ck('historico guardou o antigo', hist?.some(h=>h.nickname==='nick1'), JSON.stringify(hist))
const {data:livre} = await b.rpc('nickname_disponivel',{p_nickname:'nick1'})
ck('apelido abandonado NAO fica livre para outro', livre===false, String(livre))
const {error:e3} = await b.rpc('mudar_nickname',{p_novo:'nick1'})
ck('outro jogador nao consegue assumir o abandonado', !!e3, e3?.message?.slice(0,60))

await a.auth.signOut()
const {error:eVelho} = await a.auth.signInWithPassword({email:'nick1@belesma.local',password:SENHA})
ck('login com o apelido VELHO nao funciona mais', !!eVelho, eVelho?.message)
const {error:eNovo} = await a.auth.signInWithPassword({email:'nick2@belesma.local',password:SENHA})
ck('login com o apelido NOVO funciona', !eNovo, eNovo?.message)
const {data:volta} = await a.rpc('mudar_nickname',{p_novo:'nick1'})
ck('da para retomar o proprio apelido antigo', volta?.nickname==='nick1', volta?.nickname)

for (const n of ['nick1','nick2','nick3']) {
  const {data} = await admin.auth.admin.listUsers({perPage:200})
  const v = data?.users?.find(u=>u.email===`${n}@belesma.local`)
  if (v) { await admin.from('players').delete().eq('id',v.id); await admin.auth.admin.deleteUser(v.id) }
}
console.log(`\n${f===0?'TUDO PASSOU':f+' FALHA(S)'}`); process.exit(f===0?0:1)
