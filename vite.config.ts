import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// GitHub Pages serve o site de projeto em /<repo>/, entao o base precisa
// bater com o nome do repositorio. Em dev fica na raiz.
export default defineConfig(({ command }) => ({
  base: command === 'build' ? '/belesma-figurinhas/' : '/',
  plugins: [react()],
}))
