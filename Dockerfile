# Imagem base com versão fixa e variante alpine (poucos pacotes = menor superfície de ataque)
FROM node:20.18.1-alpine3.20

ENV NODE_ENV=production

WORKDIR /app

# Copia somente o que a aplicação precisa (docs, compose, .env etc. ficam fora da imagem)
COPY app/ ./app/

# A aplicação não possui dependências externas hoje.
# Quando houver, adicionar: RUN cd app && npm ci --omit=dev

# Usuário sem privilégios (já existe na imagem oficial do Node, uid 1000).
# Os arquivos pertencem ao root e ficam somente leitura para o usuário da aplicação.
USER node

EXPOSE 3000

CMD ["node", "app/server.js"]
