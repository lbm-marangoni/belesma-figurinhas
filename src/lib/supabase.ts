import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!url || !anon) {
  throw new Error(
    'Faltam VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY. Copie .env.example para .env.local.',
  )
}

// A anon key e publica por design: ela vai no bundle. Quem protege o acervo e
// a RLS (supabase/migrations/*_rls.sql), nao o segredo da chave.
export const supabase = createClient(url, anon, {
  auth: { persistSession: true, autoRefreshToken: true },
})
