import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { copyFileSync } from 'node:fs'
import { resolve } from 'node:path'

// GitHub Pages serve o site de projeto em /<repo>/, entao o base precisa
// bater com o nome do repositorio. Em dev fica na raiz.
//
// O 404.html e o truque de SPA no Pages: link direto para /admin nao existe
// como arquivo, o Pages devolve 404.html, e como ele e o proprio app o
// React Router resolve a rota normalmente.
export default defineConfig(({ command }) => ({
  base: command === 'build' ? '/belesma-figurinhas/' : '/',
  plugins: [
    react(),
    {
      name: 'spa-404',
      closeBundle() {
        if (command !== 'build') return
        const dist = resolve(__dirname, 'dist')
        copyFileSync(resolve(dist, 'index.html'), resolve(dist, '404.html'))
      },
    },
  ],
}))
