# README e scripts legados — plano de melhoria

> **For implementers:** Use ring-default:executing-plans. Este documento é a fonte de
> verdade; a elaboração das fases seguintes é escrita de volta aqui durante a execução.

**Goal:** O README diz o que o repositório é hoje — templates Terraform multi-produto
para a plataforma Lerian, dirigidos pelo `lerian-infra` — e nada nele contradiz o
código. O `deploy.sh` sai de cena de forma limpa.

**Architecture:** Documentação segue a mesma regra do código: uma fonte de verdade por
fato. A tabela de dataplane é gerada do filesystem, não escrita à mão. O README fica
com o que um recém-chegado precisa nos primeiros dez minutos; o detalhe vai para os
READMEs que já existem em cada root (todos os 22 produtos têm um) e para `docs/`.

**Tech Stack:** Markdown, `lerian-infra --list`, shell.

## Phase Overview

| Phase | Milestone | Epics | Status |
|-------|-----------|-------|--------|
| 1 | Nada no README contradiz o código; o repo não se apresenta como "do Midaz" | 1.1, 1.2, 1.3 | Detailed |
| 2 | `deploy.sh` aposentado sem deixar referência órfã; raiz do repo enxuta | 2.1, 2.2 | Epic-level |
| 3 | README reorganizado por jornada, com matriz de suporte por cloud gerada | 3.1, 3.2 | Epic-level |

---

## Phase 1 — Corrigir o que está errado

Antes de reorganizar, tirar o que mente. Cada item aqui é uma afirmação do README que o
código desmente.

### Epic 1.1: O repositório não é do Midaz

**Goal:** título, descrição e metadados dizem "plataforma Lerian", não "Midaz"
**Scope:** `README.md` (título e parágrafo de abertura), `package.json` (`description`)
**Dependencies:** none
**Done when:** `grep -i midaz README.md` só retorna ocorrências onde midaz é UM produto
entre outros (nome de target, exemplo de comando), nunca o sujeito do repositório
**Status:** Pending

#### Task 1.1.1: Reescrever título e abertura

- [ ] Done

**Context:** `README.md:1` é `# Midaz Terraform Foundation`. O repositório tem 21
produtos em `examples/aws/products/` mais o tier `shared-resources`; midaz é um deles.
`package.json:5` descreve "Terraform templates for deploying Midaz infrastructure".

**Implementation vision:** Título vira `# Lerian Terraform Foundation` (o nome do
repositório). Abertura em três frases: o que é (templates Terraform para a infra dos
produtos Lerian em AWS, GCP e Azure), como se usa (`lerian-infra` para AWS), para quem
(clientes em BYOC e usuários open source). Midaz aparece pela primeira vez na tabela de
produtos, não antes. `package.json` recebe a mesma descrição.

**Files:**
- Modify: `README.md:1-3`
- Modify: `package.json:5`

**Verification:** `head -5 README.md` não contém "Midaz".

**Done when:** um leitor que nunca ouviu falar do Midaz entende o que o repo é.

### Epic 1.2: Remover a seção "Installing Midaz"

**Goal:** o README não ensina a instalar produto nenhum via Helm
**Scope:** `README.md`, seção `## Installing Midaz` (~70 linhas)
**Dependencies:** none
**Done when:** a seção não existe, e no lugar dela há um parágrafo apontando para onde
isso vive
**Status:** Pending

#### Task 1.2.1: Substituir a seção por um ponteiro

- [ ] Done

**Context:** A seção usa `onboarding:` e `transaction:` como componentes (o chart
`midaz` 8.7.0 tem `ledger` e `crm`), `REDIS_PORT` (removido no chart 3.0 — `REDIS_HOST`
carrega `host:port`), `DB_REPLICA_HOST` (a chave é `DB_ONBOARDING_REPLICA_HOST`), e
coloca senhas literais em `secrets:`. Tudo isso é o oposto do que `--action
helm-values` produz, que é documentado na mesma página. Um leitor que siga a seção
monta um values que não funciona.

**Implementation vision:** Apagar a seção inteira. No lugar, uma seção curta `## Depois
da infra: instalar os produtos` com dois caminhos: (1) `lerian-infra --action
helm-values`, que produz o overlay de values já no formato do chart, sem credencial;
(2) os charts em `github.com/LerianStudio/helm`, para quem instala à mão. Nenhum YAML
de exemplo: o `helm-values` É o exemplo, e é gerado. O wizard NÃO é mencionado por
enquanto — decisão do usuário em 2026-08-29.

**Files:**
- Modify: `README.md` (remover `## Installing Midaz` até antes de `## Security Considerations`)

**Verification:** `grep -n 'helm repo add\|onboarding:\|REDIS_PORT' README.md` retorna
vazio.

**Done when:** não há values de Helm escrito à mão no README.

### Epic 1.3: Corrigir referências ao layout v1

**Goal:** nenhum path ou nome de arquivo do layout pré-v2 sobrevive no README
**Scope:** `README.md`, seções `## AWS Requirements` e `## VPN and Private Kubernetes Access`
**Dependencies:** none
**Done when:** todo path citado existe no checkout
**Status:** Pending

#### Task 1.3.1: Atualizar "AWS Requirements"

- [ ] Done

**Context:** A seção cita `midaz.tfvars` (no v2 é `envs/<env>.tfvars`), `eks/iam.tf`
(o root é `infra-base/eks/`, e a IRSA role do LB controller é `module.lb_controller_irsa_role`
em `main.tf`), e "Midaz or plugins" como se fossem os únicos produtos. A afirmação de
que autoscaler, LB controller e ingress "must be installed manually" continua correta e
já está no próprio `infra-base/eks/main.tf:300`; a frase sobre `RABBITMQ_URI: "amqps"`
continua correta e o `helm-values` já a emite.

**Implementation vision:** Reescrever com os paths v2. Trocar "Midaz or plugins" por
"qualquer produto". Onde o README repete algo que o `helm-values` já faz (o `amqps`),
dizer que o CLI emite em vez de mandar o operador setar. Manter a lista de charts
externos (autoscaler, LB controller, ingress) — é informação útil que o CLI não dá.
Acrescentar a StorageClass default, que hoje não é mencionada em lugar nenhum e é o
primeiro problema que aparece na fase de apps: o addon `aws-ebs-csi-driver` não cria
nenhuma, e um PVC sem `storageClassName` fica `Pending`.

**Files:**
- Modify: `README.md`, seção `## AWS Requirements`

**Verification:** cada path citado na seção passa em `test -e`.

**Done when:** a seção descreve o layout que existe.

#### Task 1.3.2: Neutralizar a seção de VPN

- [ ] Done

**Context:** O exemplo HCL tem `description = "Access EKS from Midaz VPN and Network
VPC"` e o texto fala em "Client Responsibilities" sem dizer que o CLI já tem a variável
`allowed_api_access_cidrs` para o caso comum (allow-list por IP, que o `init` detecta
com `--api-cidr auto`).

**Implementation vision:** Abrir a seção dizendo o caminho padrão (allow-list por
CIDR, preenchida pelo `init`), e só depois o caso de cluster privado + VPN como
responsabilidade do cliente. Tirar "Midaz" da description do exemplo.

**Files:**
- Modify: `README.md`, seção `## VPN and Private Kubernetes Access`

**Verification:** `grep -n 'Midaz VPN' README.md` vazio.

**Done when:** o leitor sabe que o caso simples já está coberto antes de ler o caso
difícil.

---

## Phase 2 — Aposentar o deploy.sh e enxugar a raiz

### Epic 2.1: Remover o `deploy.sh`

**Goal:** o script sai do repositório sem deixar referência órfã
**Scope:** `deploy.sh`, 69 arquivos `.tf` que o citam em comentário,
`examples/aws/environments.conf.example:8`, `examples/aws/products/shared-resources/README.md:442`,
`deploy-legacy.sh:176`, seção `### ./deploy.sh — superseded` do README
**Dependencies:** Phase 1 (para o README já estar coerente quando a seção sair)
**Done when:** `grep -rn 'deploy\.sh' --include='*' . | grep -v deploy-legacy` retorna
vazio, e `lerian-infra --env dev --target all --dry-run` continua verde
**Status:** Pending

*(Sem tasks ainda. Decisões que a elaboração deve respeitar: o `deploy.sh` é 100%
redundante com o CLI — mesmas flags, mesmo layout — então não há caso de uso que
justifique mantê-lo; a remoção é `git rm`, recuperável na história. As 69 citações em
`.tf` são comentários que dizem "o placeholder check do deploy.sh greps por `<...>`" ou
"deploy.sh trata os engines identicamente" — substituir por `lerian-infra`, não apagar,
porque a informação continua verdadeira. A linha 176 do `deploy-legacy.sh` passa a
apontar para `lerian-infra --help`. O `deploy-legacy.sh` FICA: é o único caminho para
GCP e Azure.)*

### Epic 2.2: Enxugar a raiz do repositório

**Goal:** a raiz mostra o que o repositório é, sem sobras de trabalho
**Scope:** `plan.md`, `package.json`, `commitlint.config.js`, `Makefile` (target `deps`)
**Dependencies:** none
**Done when:** a raiz não tem arquivo untracked de trabalho, e todo arquivo que sobra
tem uma razão para estar lá
**Status:** Pending

*(Sem tasks ainda. O que já se sabe: `go.mod` e `go.sum` NÃO podem sair da raiz — o
module path é `github.com/LerianStudio/lerian-terraform-foundation` e o wizard importa
`.../pkg/infra` a partir dele; mover para um subdiretório quebra o import. `plan.md`
(40 KB, untracked, de 2026-08-12) é histórico do layout v2: arquivar em
`docs/plans/2026-08-12-aws-v2-layout.md` para não perder o raciocínio, ou apagar.
`package.json` + `commitlint.config.js` existem só para o commitlint via npm; avaliar
se `.github/workflows/ci.yml` já roda commitlint por action (roda:
`wagoid/commitlint-github-action`), o que tornaria o npm local opcional. `bin/` é
gitignored e é output do `make build`, fica.)*

---

## Phase 3 — Reorganizar por jornada

### Epic 3.1: Matriz de suporte por cloud

**Goal:** uma tabela diz, para cada coisa que se pode subir, em quais clouds existe
template e o que ela cria — e a tabela não pode divergir do filesystem
**Scope:** `README.md`, possivelmente `cmd/lerian-infra` (saída da matriz)
**Dependencies:** none
**Done when:** a tabela tem as cinco colunas abaixo, cada célula de suporte é
verificável contra `examples/`, e o README diz como regenerá-la
**Status:** Pending

Forma decidida pelo usuário em 2026-08-29:

| Coluna | Conteúdo |
| --- | --- |
| 1 | o que se sobe: `bootstrap`, `infra-base`, e cada produto |
| 2 | AWS TF template support? `true`/`false` |
| 3 | GCP TF template support? `true`/`false` |
| 4 | Azure TF template support? `true`/`false` |
| 5 | recursos criados |

*(Sem tasks ainda. Fatos levantados em 2026-08-29 que as células devem refletir:*

*AWS: `bootstrap` true (bucket S3 versionado + tabela DynamoDB de lock + backend/<env>.hcl);
`infra-base` true (VPC multi-AZ, EKS 1.36 com 5 addons e IRSA); 21 produtos true, cada
um com seu conjunto de {postgres, documentdb, valkey, rabbitmq, msk, s3}; mais o tier
`shared-resources` (postgres, documentdb, valkey, rabbitmq, msk — sem s3, que nunca é
compartilhado).*

*GCP: `bootstrap` FALSE — o README manda criar o bucket GCS à mão; `infra-base` true
(vpc, gke, cloud-dns); TODOS os produtos false. O que existe é `cloud-sql` e `valkey`
genéricos, no layout v1, hardcoded para o Midaz (`random_password.midaz_user_password`),
sem root por produto e sem modo shared/dedicated. Dizer "true" para midaz aqui seria
mentir: não há paridade de contrato com o AWS.*

*Azure: `bootstrap` true-com-ressalva — `base-resources` cria a storage account do
state (Azure faz lock por blob lease, não há tabela); `infra-base` true (network, aks,
dns); TODOS os produtos false, pelo mesmo motivo do GCP — `database`, `redis` e
`cosmosdb` são genéricos e hardcoded (`kv-db-midaz`).*

*A matriz precisa de UMA nota de rodapé para GCP/Azure explicando que os datastores
existem mas são genéricos e dirigidos pelo `deploy-legacy.sh`, para o `false` não ler
como "não tem banco nenhum".*

*Geração: a coluna AWS sai do mesmo `Discover` que o CLI usa para rodar — isso é o que
impede a tabela de divergir. GCP e Azure são 5+7 diretórios fixos, sem descoberta. Duas
opções para a elaboração: (a) `lerian-infra --list --format markdown` emitindo a matriz
inteira, com GCP/Azure lidos de `examples/{gcp,azure}/*/` por existência de diretório;
(b) a matriz escrita à mão com um teste em `cmd/lerian-infra` que falha se a lista de
produtos AWS no README divergir do `Discover`. A (a) é mais honesta; a (b) é menos
código. Recomendação: (a).)*

### Epic 3.2: Ordem e tamanho

**Goal:** o README lê como uma jornada — o que é, instalar, obter templates, subir um
ambiente, instalar produtos, operar — e cabe em uma leitura
**Scope:** `README.md` inteiro; `docs/` para o que sair
**Dependencies:** Epics 1.x, 2.1, 3.1
**Done when:** as seções estão em ordem de jornada; "Important Note" e "Instance Types
Disclaimer" não interrompem o quickstart; o README tem menos de 450 linhas
**Status:** Pending

*(Sem tasks ainda. Hoje são 641 linhas e "Important Note" + "Instance Types
Disclaimer" ficam ENTRE "Getting the templates" e "Project Structure", cortando o
fluxo. Candidatos a sair para `docs/`: o exemplo HCL de VPN, a seção de credenciais em
produção (multi-cloud, genérica), e "Manual Installation Resources". Candidato a
encolher: "Project Structure", que hoje reproduz a árvore inteira — a tabela de produtos
do Epic 3.1 substitui metade dela.)*
