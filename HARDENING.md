# HARDENING.md — Hardening de Containers

## 1. Problemas encontrados (antes do hardening)

| # | Problema | Onde | Risco |
|---|----------|------|-------|
| 1 | Imagem base `ubuntu:latest` | `Dockerfile` | Tag `latest` não é reproduzível (muda sem aviso) e a imagem é grande, com muitos pacotes desnecessários, ampliando a superfície de ataque e a quantidade de CVEs. |
| 2 | `apt-get install nodejs npm` sem versão, sem limpeza de cache, em `RUN` separados | `Dockerfile` | Versão do Node imprevisível/desatualizada, camadas maiores e cache do apt dentro da imagem. |
| 3 | `COPY . .` | `Dockerfile` | Copia tudo (docs, compose, `.git`, futuros `.env`) para a imagem, inclusive arquivos sensíveis. |
| 4 | `ENV DB_PASSWORD=123456` | `Dockerfile` | Senha fraca gravada na camada da imagem; qualquer um com acesso à imagem a recupera com `docker history`/`docker inspect`. |
| 5 | Container executa como `root` | `Dockerfile` (sem `USER`) | Comprometer a aplicação dá privilégios administrativos dentro do container, facilitando escape e movimentação lateral. |
| 6 | `MYSQL_ROOT_PASSWORD: root` | `docker-compose.yml` | Senha trivial, em texto puro, em arquivo versionado. |
| 7 | `mysql:latest` | `docker-compose.yml` | Versão não fixa: upgrades de major inesperados e builds não reproduzíveis. |
| 8 | Porta `3306:3306` publicada | `docker-compose.yml` | Banco exposto a toda a máquina/rede do host, permitindo ataques de força bruta e exploração direta. |
| 9 | Sem limites de CPU/memória | `docker-compose.yml` | Um container comprometido ou com bug pode esgotar recursos do host (DoS). |
| 10 | Sem redes segmentadas | `docker-compose.yml` | Tudo na rede padrão, sem separar o que é público do que é interno. |
| 11 | Sem restrições de isolamento (filesystem gravável, capabilities padrão, sem `no-new-privileges`) | `docker-compose.yml` | Maior impacto se o container for comprometido. |
| 12 | Banco usando apenas o usuário `root` | `docker-compose.yml` | Violação do menor privilégio: a aplicação não deveria usar o superusuário. |
| 13 | `app/package.json` vazio (0 bytes) | `app/package.json` | A aplicação **não inicia** no estado original: `node app/server.js` falha com `ERR_INVALID_PACKAGE_CONFIG`. |
| 14 | Sem `.gitignore`, `.dockerignore` e `.env.example` | raiz do projeto | Nada impede o versionamento de segredos nem o envio de arquivos sensíveis ao contexto de build. |

## 2. Medidas aplicadas

| Alteração | Objetivo de segurança | Risco reduzido |
|-----------|----------------------|----------------|
| Base `node:20.18.1-alpine3.20` (versão fixa, Alpine) | Imagem mínima, reproduzível e adequada à aplicação | Superfície de ataque, CVEs de pacotes não usados (#1, #2) |
| `COPY app/ ./app/` apenas | Imagem contém só o necessário | Vazamento de arquivos sensíveis na imagem (#3) |
| Remoção do `ENV DB_PASSWORD` | Nenhum segredo nas camadas da imagem | Exposição de senha via `docker history` (#4) |
| `USER node` (uid 1000), código pertencente ao root e somente leitura para a app | Menor privilégio | Impacto de comprometimento da aplicação (#5) |
| Segredos movidos para `.env` e referenciados com `${VAR}` | Segredos fora de arquivos versionados | Vazamento via Git (#4, #6) |
| `.gitignore` ignora `.env`; `.env.example` só com nomes das variáveis | Impedir versionamento de segredos e documentar variáveis | Vazamento de credenciais (#14) |
| `.dockerignore` | Impedir que `.env`, `.git`, docs entrem no contexto de build | Vazamento no build (#3, #14) |
| `mysql:8.4` | Versão fixa (LTS) | Atualizações inesperadas (#7) |
| Banco com usuário próprio (`MYSQL_USER`/`MYSQL_PASSWORD`), root separado | Aplicação não usa o root do banco | Privilégio excessivo (#12) |
| Remoção de `ports` do `banco`; rede `backend` com `internal: true` | Expor só o necessário; banco acessível apenas pela app | Acesso externo ao banco (#8, #10) |
| Redes `frontend` (app) e `backend` (app + banco) | Segmentação | Movimentação lateral (#10) |
| `mem_limit`, `cpus`, `pids_limit` | Controle de recursos | Esgotamento de recursos do host (#9) |
| `read_only: true` + `tmpfs: /tmp` na app | Filesystem imutável | Persistência de malware/alterações no container (#11) |
| `cap_drop: ALL` e `no-new-privileges` | Remover capabilities e impedir escalonamento | Escalonamento de privilégios (#11) |
| `app/package.json` válido (`private: true`) | Aplicação volta a funcionar; evita publicação acidental | Falha de execução (#13) |

Observação: o código da aplicação (`server.js`) foi mantido como estava; ele ainda não consome as credenciais do banco, mas elas já são entregues ao container por variáveis de ambiente (`DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`).

## 3. Respostas às perguntas das etapas

**Etapa 2 — Por que uma imagem menor reduz a superfície de ataque?**
Cada pacote presente é código que pode conter vulnerabilidades e ferramentas que um atacante pode usar (shell, curl, compiladores). Menos componentes significa menos CVEs, menos binários úteis ao atacante, scans mais rápidos e pull/deploy mais leves.

**Etapa 3 — Impacto de um atacante controlar uma aplicação rodando como root?**
Ele teria controle total do container: instalar ferramentas, ler segredos e arquivos, alterar o sistema de arquivos e, combinado a outras falhas (capabilities, mounts do host, vulnerabilidades do kernel/runtime), tentar escapar para o host e atacar outros serviços.

**Etapa 4**
1. Mesmo que a app funcione, a senha fica gravada nas camadas da imagem e no repositório; quem acessar a imagem ou o código a obtém (`docker history`), e ela não pode ser rotacionada sem rebuild.
2. Porque contém segredos reais; versionar expõe credenciais a todos com acesso ao repositório e permanece no histórico do Git mesmo se o arquivo for removido depois.
3. Documentar quais variáveis são necessárias para executar o projeto (`cp .env.example .env`), sem expor valores.
4. Escrever a senha no compose a deixa em arquivo versionado. Com `.env`, o compose contém só a referência `${DB_PASSWORD}` e o valor fica fora do Git, podendo variar por ambiente.

**Etapa 5 — O banco precisa expor a porta ao host?**
Não. Se só a aplicação o utiliza, ela acessa por `banco:3306` na rede interna do Docker. Publicar a porta no host expõe o banco a toda a máquina/rede, aumentando a superfície de ataque sem benefício.

**Etapa 6 — E se um container consumir toda a CPU/memória do host?**
Os outros serviços ficam lentos ou param (starvation), o kernel pode acionar o OOM killer e encerrar processos aleatórios, e o host pode travar, caracterizando um DoS. Limites isolam o dano ao próprio container.

## 4. Análise final

1. **Principal risco:** segredos expostos (senha fixa no Dockerfile e no compose) somados ao banco publicado no host e à execução como root.
2. **Alteração mais importante:** a remoção de segredos do código/imagem para o `.env`, porque o vazamento de credenciais compromete tudo e é permanente nas camadas e no histórico Git. Muito próxima em importância: não publicar o banco e rodar sem root.
3. **Se o container da app fosse comprometido:** com as medidas atuais o atacante teria um usuário sem privilégios, filesystem somente leitura, sem capabilities, sem escalonamento, com CPU/memória limitadas e sem acesso à rede externa do banco além do necessário. Antes teria root e a senha embutida.
4. **Menor privilégio:** `USER node`, `cap_drop: ALL`, `no-new-privileges`, filesystem somente leitura, código do app não gravável, usuário de banco dedicado em vez do root, banco acessível apenas pela rede interna.
5. **`.env` fora do repositório:** contém credenciais reais; o Git guarda histórico e é compartilhado, então o vazamento seria permanente e acessível a todos com acesso ao repositório.
6. **`.env.example`:** modelo com os nomes das variáveis, sem valores, para que qualquer desenvolvedor saiba o que configurar.
7. **CI/CD:** adicionar etapas automáticas, como lint do Dockerfile (Hadolint), scan de vulnerabilidades da imagem (Trivy/Grype), scan de segredos (Gitleaks/TruffleHog), SAST/dependências (CodeQL, `npm audit`), validação do compose e política que falha o build em severidade alta/crítica; assinar imagens (cosign) e gerar SBOM.
8. **Kubernetes:** `securityContext` (`runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop de capabilities, seccomp), Pod Security Standards, `NetworkPolicy` para restringir tráfego, `requests/limits` e `ResourceQuota`, Secrets (idealmente com Vault/External Secrets e criptografia em repouso), RBAC mínimo, imagens por digest em registry privado, admission controllers (Kyverno/OPA Gatekeeper) e scan contínuo.

## 5. Evidências da validação

Execute os comandos abaixo na sua máquina e cole as saídas reais em cada item antes de entregar.

**Antes do hardening** (projeto original): `node app/server.js` falha com `ERR_INVALID_PACKAGE_CONFIG`, pois `app/package.json` está vazio (verificado).

**Depois do hardening**

```bash
cp .env.example .env     # preencher os valores (já existe localmente)
docker compose up -d --build
docker compose ps
docker compose logs app
```
Esperado: log `Olá mundo!` (a aplicação imprime a mensagem e encerra, pois não há servidor HTTP no código).

Usuário do container (esperado: `uid=1000(node)`):
```bash
docker compose run --rm app id
```

Banco não publicado no host (esperado: nenhuma porta 3306 listada para `banco`):
```bash
docker compose ps banco
```

Limites de recursos (esperado: valores de memória/CPU configurados):
```bash
docker stats --no-stream
```

Segredo fora da imagem (esperado: nenhuma ocorrência de `DB_PASSWORD`/senha):
```bash
docker history hardening-app:1.0.0
docker inspect hardening-app:1.0.0 | grep -i password
```

`.env` ignorado pelo Git (esperado: linha com `.gitignore:1:.env`):
```bash
git check-ignore -v .env
```

Verificações já realizadas neste trabalho: `node app/server.js` imprime `Olá mundo!` com o `package.json` corrigido; `docker compose config` resolve todas as variáveis a partir do `.env` sem erros e mostra o banco sem `ports`, `internal: true` na rede de backend e os limites configurados.
