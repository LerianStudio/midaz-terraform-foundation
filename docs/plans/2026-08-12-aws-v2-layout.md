# Plano — lerian-terraform-foundation v2 (AWS multi-produto, multi-ambiente)

> **Arquivado em 2026-08-29.** Este plano descreve a migração para o layout AWS v2 e
> está concluído. Ele é mantido porque carrega o raciocínio por trás de decisões que o
> código não explica sozinho — por que um state por serviço em vez de um por produto,
> por que os nove diretórios pré-v2 foram removidos, e o trade-off de blast radius que
> justificou os ~60 diretórios. A Fase 4 fala de um `deploy.sh` v2 que existiu e foi
> substituído pelo `lerian-infra`; a Fase 6 fala de uma v2.0.0 que acabou saindo como
> v1.6.0.


Data: 2026-08-12
Fonte de discovery: `infrastructure/IAC/product-infra-dependencies.yaml` (dependências por chart Helm)
Baseline: `main` @ v1.5.0

## Objetivo

Reestruturar os templates AWS para:
1. `infra-base/` com o que todo deploy precisa: VPC e EKS
2. Um diretório por serviço, por produto (21 produtos), mais um tier compartilhado opcional em `products/shared-resources/`
3. Ambientes dev/stg/prd segregados: env no nome de todo recurso E bucket S3 de state segregado por ambiente
4. Deploy "one click" via `deploy.sh` v2 manifest-driven

## Decisões fechadas

| Decisão | Escolha |
|---|---|
| Broker streaming AWS | MSK (Kafka API; charts usam `rpk`/lib-streaming, compatível) |
| DNS privado | **Removido.** Sem Route53 no caminho de conexão — ver "Por que o Route53 saiu" abaixo |
| Datastores | Híbrido por flag: `mode = "dedicated"` ou `"shared"` por produto |
| Escopo v1 | Todos os 21 produtos |
| Layout dos produtos | `examples/aws/products/<produto>/<serviço>/` — **um root Terraform por serviço**, não por produto. 1 state por serviço por ambiente. Vale também para o tier compartilhado, que é `products/shared-resources/<serviço>/` |
| Tier compartilhado | **Opcional e opt-in por diretório**, em `products/shared-resources/`. Não fica em `infra-base`, que é só o que todo deploy precisa (vpc, eks) |
| Naming | `{product}-{env}-{recurso}`. A fundação (`vpc`, `eks`) usa product = `lerian`; o tier compartilhado de datastores usa product = **`shared`** |
| TF state | 1 bucket S3 + 1 tabela DynamoDB **por ambiente** |
| Módulos | Wrappers locais finos (`_modules/`) com módulos oficiais terraform-aws-modules pinados por dentro; docdb e amazonmq não têm módulo oficial e ficam com resources crus dentro do wrapper |
| Versão | v2.0.0 (breaking) via PR → develop → main |

## Convenções globais (valem para todas as fases)

- **Naming**: todo recurso nomeado via módulo `naming`: `${var.product}-${var.environment}-${sufixo}`. Ex: `midaz-dev-postgres`, `lerian-prd-vpc`. Proibido literal de nome fora do módulo.
- **Nomes globalmente únicos**: buckets S3 (e o bucket de state) recebem sufixo de account id — `{product}-{env}-{nome}-{account_id}` — porque o namespace do S3 é global entre contas. Resolvido via `data.aws_caller_identity` dentro do módulo; é a única exceção documentada ao padrão de naming.
- **Envs válidos**: `dev | stg | prd`, com `validation` block em toda variável `environment`.
- **Tags mínimas**: `Product`, `Environment`, `ManagedBy = "terraform"`, `Repository = "lerian-terraform-foundation"`.
- **Backend**: cada stack tem `backend "s3" {}` vazio; config injetada via `terraform init -backend-config=<repo>/examples/aws/backend/<env>.hcl -backend-config="key=aws/<stack>/terraform.tfstate"`. O bucket já é por env, então a key não repete o env.
- **tfvars**: cada stack tem `envs/{dev,stg,prd}.tfvars` (exemplos versionados como `.tfvars-example`; `.tfvars` real segue no `.gitignore`).
- **Cross-stack wiring**: mantém lookup por `tag:Name` (sem remote state), mas o nome procurado é sempre **derivado** (`lerian-${var.environment}-vpc`), nunca literal em tfvars.
- **Ordem de deploy** (corrigida na Fase 1, ver nota abaixo):
  `bootstrap → infra-base/vpc → infra-base/eks → [products/shared-resources/* se optar] → products/<produto>/*`
  O EKS vem **antes** do shared-services: o shared-services libera ingress para o security group dos nodes do EKS, e o EKS não depende de datastore nenhum (seus únicos lookups cross-stack são a VPC e as subnets `Type=private`). Na ordem inversa o SG dos nodes ainda não existe no primeiro apply, o que forçava reaplicar o shared-services depois — dois applies para o mesmo resultado. Destroy é a ordem reversa.
- **Provider AWS**: `>= 6.42.0, < 7.0.0` em todos os stacks e módulos. O piso 6.42 não é escolha estética: os módulos oficiais `msk-kafka-cluster` 3.3.0 e `s3-bucket` 5.15.4 o exigem, então o grafo já resolvia 6.x mesmo com a constraint antiga (`>= 5.83.0`) — que portanto mentia. O teto `< 7.0.0` evita major surpresa.
- **Validação estática padrão** (roda em toda fase, em todo diretório tocado):
  ```bash
  terraform fmt -check -recursive
  terraform init -backend=false && terraform validate
  tflint --config <repo>/.tflint.hcl
  tfsec . --exclude-downloaded-modules
  ```
- **Validação em conta real**: usar a conta AWS de validação. Perfis/region via env:
  ```bash
  export AWS_PROFILE=<perfil-validacao>   # preencher antes de rodar
  export AWS_REGION=us-east-1             # region de validação (barata); ajustar se necessário
  ```
  Todo apply de validação usa os menores tamanhos possíveis (ver tabela de custo por fase) e termina com `terraform destroy` do que foi criado, exceto o bootstrap de state de `dev` que pode permanecer.

---

## Fase 1 — Branch, módulos de contrato e infra-base

### Objetivo
Branch de trabalho criada; `_modules/` completos e testados; `infra-base/` funcional multi-env com state segregado por ambiente.

### Tarefas

1.1 **Branch**
- `git checkout main && git pull && git checkout -b feat/aws-v2-foundation`

1.2 **Bootstrap de state por ambiente** — `examples/aws/bootstrap/`
- Stack com **state local** (gitignored) que cria, por env:
  - S3 `lerian-tfstate-{env}-{account_id}` (versioning, SSE-S3, public access block, lifecycle noncurrent 90d)
  - DynamoDB `lerian-tfstate-lock-{env}` (PAY_PER_REQUEST, hash key `LockID`)
- Gera/atualiza `examples/aws/backend/{env}.hcl`:
  ```hcl
  bucket         = "lerian-tfstate-dev-<account_id>"
  region         = "us-east-1"
  dynamodb_table = "lerian-tfstate-lock-dev"
  encrypt        = true
  ```
- Variável única: `environment` (+ region). Rodar 1x por env.

1.3 **Módulo `naming`** — `examples/aws/_modules/naming/`
- Inputs: `product`, `environment` (com validation), `extra_tags`.
- Outputs: `prefix` (`{product}-{env}`), `tags` (map padrão mergeado).

1.4 **Módulos de datastore** — `examples/aws/_modules/`
Cada um recebe `product`, `environment`, `mode` (`dedicated|shared`, onde aplicável), `vpc_lookup` (nome derivado), `dns_zone_name`, e sizing. Todos criam: SG próprio, secret no Secrets Manager (`{prefix}/{recurso}`), CNAME na zona privada (`{recurso}.{product}.{zona}`), e usam `naming`.

| Módulo | Motor interno | Observações |
|---|---|---|
| `postgres-rds/` | `terraform-aws-modules/rds/aws ~> 6.0` | Migrar lógica de `examples/aws/rds/`; réplica opcional; `mode=shared` → não cria instância, só faz data lookup do endpoint `lerian-{env}-postgres` e outputs (criação de database/role fica com os bootstrap jobs dos charts — decisão registrada) |
| `mongodb-documentdb/` | resources crus + `terraform-aws-modules/kms/aws 1.5.0` | Migrar de `examples/aws/documentdb/`; **corrigir** param group `name = "example"` → `{prefix}-param-group`; **adicionar** CNAME (hoje não tem) |
| `valkey-elasticache/` | `terraform-aws-modules/elasticache/aws ~> 1.6` | Migrar de `examples/aws/valkey/`; **remover** sufixo hardcoded `/test` do secret |
| `rabbitmq-amazonmq/` | `aws_mq_broker` cru | Migrar de `examples/aws/amazonmq/`; **adicionar** CNAME; manter lógica SINGLE/CLUSTER |
| `streaming-msk/` | `terraform-aws-modules/msk-kafka-cluster` (verificar última versão no registry antes de pinar) | Novo; `mode=shared` só data lookup; tópicos ficam com os charts (`rpk` PreSync jobs) |
| `s3-bucket/` | `terraform-aws-modules/s3-bucket/aws` | Novo; bucket `{prefix}-{nome}` + IAM policy IRSA-ready como output |

- Correções herdadas obrigatórias em todos: nenhum `use_name_prefix = false` com nome sem env; secrets/IAM roles/subnet groups/param groups todos via `prefix`.

1.5 **infra-base** — `examples/aws/infra-base/`
- `vpc/`: migrar de `examples/aws/vpc/` com `product = "lerian"`; nome final `lerian-{env}-vpc`; tags k8s apontando para `lerian-{env}-eks`.
- `route53/`: zona privada `{env}.lerian.internal` (default; sobrescrevível).
- `eks/`: migrar de `examples/aws/eks/`; cluster `lerian-{env}-eks`; IAM roles `lerian-{env}-eks-admin-role` etc.
- `shared-services/`: um stack que instancia os módulos postgres/documentdb/valkey/amazonmq/msk com `enabled` individual (default `false`) — é o lado "shared" do modo híbrido. Nomes `lerian-{env}-postgres` etc.
- Cada stack: `backend.tf` vazio + `envs/*.tfvars-example` + `variables.tf` com validation.

### Validação E2E (executável por agente)

```bash
# 1. Estática em todos os novos dirs
for d in examples/aws/_modules/* examples/aws/infra-base/* examples/aws/bootstrap; do
  (cd "$d" && terraform fmt -check && terraform init -backend=false -input=false && terraform validate)
done
tflint --recursive && ./scripts/run-tfsec.sh

# 2. Bootstrap state dev + stg (prova segregação de bucket)
cd examples/aws/bootstrap
terraform apply -var environment=dev -auto-approve
terraform apply -var environment=stg -auto-approve   # state local separado por env (usar -state=dev.tfstate / stg.tfstate)
aws s3api get-bucket-versioning --bucket lerian-tfstate-dev-<acct>   # Enabled
aws s3api get-bucket-versioning --bucket lerian-tfstate-stg-<acct>   # Enabled

# 3. infra-base dev: vpc + route53 (baratos) — apply real
cd ../infra-base/vpc
terraform init -backend-config=../../backend/dev.hcl -backend-config="key=aws/infra-base/vpc/terraform.tfstate"
terraform apply -var-file=envs/dev.tfvars -auto-approve
cd ../route53 && terraform init -backend-config=../../backend/dev.hcl -backend-config="key=aws/infra-base/route53/terraform.tfstate"
terraform apply -var-file=envs/dev.tfvars -auto-approve

# 4. Prova anti-colisão: aplicar vpc também em stg na MESMA conta
cd ../vpc
terraform init -reconfigure -backend-config=../../backend/stg.hcl -backend-config="key=aws/infra-base/vpc/terraform.tfstate"
terraform apply -var-file=envs/stg.tfvars -auto-approve
aws ec2 describe-vpcs --filters Name=tag:Name,Values=lerian-dev-vpc,lerian-stg-vpc --query 'length(Vpcs)'  # == 2

# 5. shared-services dev com postgres+valkey enabled, tamanhos mínimos — apply, checar CNAMEs, destroy
# 6. eks dev: plan completo obrigatório; apply opcional (ver custo)
# 7. destroy de tudo em ordem reversa (stg vpc → dev route53 → dev vpc; manter bootstrap dev)
```

### Custo/tempo estimado da validação
- VPC ×2 + Route53: ~US$0,10/h (NAT GW) — minutos.
- shared-services mínimo (db.t4g.micro, cache.t4g.micro): ~US$0,05/h — apply RDS ~10 min.
- EKS (se aplicado): US$0,10/h cluster + nodes; ~20 min de apply. Recomendado 1 apply completo antes de fechar a fase.

### Critérios de saída
- [x] Estática 100% verde em módulos, infra-base e bootstrap — 12/12 diretórios com `fmt -check`, `validate` e `tflint` limpos; `trivy config` com 0 achados HIGH/CRITICAL no código próprio (achados dentro de `.terraform/modules/` são upstream)
- [x] Buckets/tabelas de state dev e stg criados e segregados — `lerian-tfstate-{dev,stg}-{account_id}` + `lerian-tfstate-lock-{dev,stg}`, ambos com versioning, SSE e public access block
- [x] dev e stg coexistindo na mesma conta sem colisão de nome — provado em nome **global de conta**: `lerian-dev-vpc-flow-logs` e `lerian-stg-vpc-flow-logs` coexistiram (o legado usava `${var.name}-flow-logs`, sem env, e falharia com `EntityAlreadyExists`). Ver nota de quota abaixo
- [x] shared-services aplicado e destruído sem erro; CNAMEs resolvem na zona privada — `postgres.lerian.dev.lerian.internal` e `valkey.lerian.dev.lerian.internal` criados apontando para os endpoints reais, no formato exato que o modo `shared` dos módulos procura
- [x] EKS: plan limpo — 56 recursos, IAM roles já com `lerian-dev-eks-*`; acordo cross-stack verificado (a VPC taggeou as subnets com `kubernetes.io/cluster/lerian-dev-eks`, que é o nome que o stack eks deriva). Apply completo pendente para a Fase 2

### Validação em conta real — como foi feita

Conta de sandbox, region `us-east-2`. Aplicado e destruído: vpc dev (42 recursos), route53 dev, shared-services dev (postgres `db.t4g.micro` + valkey `cache.t4g.micro`). Mantidos: os buckets/tabelas de state (custo desprezível, e a Fase 2 usa).

**Limitação de quota encontrada**: a conta está no teto de 5 VPCs por region, com 3 VPCs de outros trabalhos (`sst-teste`, `vpc-sandbox`, `vpc-test-capacity`) que não foram tocadas. Por isso o apply da VPC de stg falhou com `VpcLimitExceeded` — quota da conta, não defeito do código. A prova de anti-colisão acabou saindo mais forte por outro caminho: o apply parcial do stg chegou a criar o IAM role, e IAM role é nome **global de conta**, superfície de colisão mais dura que a de uma VPC (que a AWS deixa duplicar o tag Name sem erro). Para repetir o teste no nível de VPC, é preciso subir a quota ou liberar uma das VPCs existentes.

**Comportamento observado que confirma a ordem de deploy**: com o EKS ainda não aplicado, o `check "eks_node_security_group_resolved"` do shared-services avisou sem falhar, e o ingress ficou só com os CIDRs das subnets privadas — exatamente a degradação graciosa desenhada, e a razão de o EKS passar a vir antes do shared-services.

### Estado — código da Fase 1 concluído

12 diretórios entregues, todos validados:

```
examples/aws/
├── bootstrap/                    state por ambiente: S3 + DynamoDB lock, workspace local por env
├── backend/                      {env}.hcl gerados pelo bootstrap (gitignored, contêm account id)
├── _modules/
│   ├── naming/                   contrato de nome e tag; tudo deriva daqui
│   ├── postgres-rds/             migrado de examples/aws/rds/
│   ├── mongodb-documentdb/       migrado de documentdb/ + os 2 clones; substitui os 3
│   ├── valkey-elasticache/       migrado de valkey/
│   ├── rabbitmq-amazonmq/        migrado de amazonmq/
│   ├── streaming-msk/            novo (msk-kafka-cluster 3.3.0)
│   └── s3-bucket/                novo (s3-bucket 5.15.4) + policy IRSA
└── infra-base/
    ├── vpc/                      lerian-{env}-vpc
    ├── route53/                  zona privada {env}.lerian.internal
    ├── eks/                      lerian-{env}-eks
    └── shared-services/          lado "shared" do modelo híbrido, todo datastore default off
```

Os 9 stacks legado seguem intactos — remoção é Fase 5.

#### Bugs pré-existentes corrigidos na migração

Encontrados ao migrar, não introduzidos por nós:

- **docdb**: parameter group com `name = "example"` literal (só na base; os clones já tinham corrigido — divergência viva). Secret com `1` colado no nome (`documentdb-password1`). Nenhum registro DNS.
- **valkey**: secret com sufixo `/test` hardcoded. Security group criado e nunca anexado.
- **rds**: réplica sem `manage_master_user_password = false` (RDS rejeita master password gerenciada em réplica).
- **rds — `engine_version = "16.3"` não existe mais**: pego no apply em conta real, `InvalidParameterCombination: Cannot find version 16.3 for postgres`. A AWS retira versões minor; hoje só há 16.9+. O default passou a ser o **major** `"16"`, que faz o RDS escolher o minor mais recente e não gera diff perpétuo (o provider trata a config como prefixo). Pinar minor completo é armadilha de manutenção: quebra sozinho com o tempo. O stack legado `examples/aws/rds/` tinha o mesmo `16.3` — ou seja, **estava quebrado para qualquer cliente que rodasse do zero**; removido na limpeza antecipada.
- **amazonmq — `mq.t3.micro` não existe para RabbitMQ**: pego no apply do piloto midaz, `BadRequestException: Broker engine type [RabbitMQ] does not support host instance type [mq.t3.micro]`. Esse tipo é exclusivo do ActiveMQ; o menor que o RabbitMQ aceita é `mq.m7g.medium`. A premissa veio do stack legado e tinha se espalhado para os defaults novos e para os tfvars de dev — qualquer cliente quebraria no apply. Corrigido, e o erro foi promovido a `precondition` de plan-time validando por família (`mq.m5.` / `mq.m7g.`) em vez de lista fechada, para não rejeitar tamanhos novos que a AWS lance.
  **Impacto de custo real** (Price List oficial da AWS, us-east-1/2): a premissa era ~US$20/mês; o real é **~US$100/mês** single-AZ (~US$299 em cluster 3 nós). Isso muda a economia do modelo dedicado: 21 produtos com broker próprio ficam caros, o que fortalece o `mode = "shared"` como default prático para RabbitMQ.
  Um segundo erro apareceu junto: 6 pontos da doc afirmavam que a restrição valia só em `CLUSTER_MULTI_AZ` e que cluster exigiria `mq.m5.large`. Falso — `mq.m7g.medium` clusteriza normalmente; o salto de custo dev→prd é a contagem de nós (1→3), não um piso de tipo.
- **eks**: módulo v21 criando uma segunda CMK além da que o stack já passava — colisão de alias no apply e chave órfã paga.
- **vpc**: NACL das subnets de database só permitia os CIDRs privados, o que **quebraria a replicação cross-AZ** de RDS Multi-AZ, DocumentDB e ElastiCache. SG dos VPC endpoints liberava 5432/6379 em vez de 443 (endpoint de interface termina HTTPS).
- **route53**: associação cross-account revertida a cada apply (faltava `ignore_changes = [vpc]`).
- **amazonmq/docdb**: ingress liberando todos os protocolos e portas em vez de escopar na porta do serviço.
- Todos: `environment` com `default = "<environment>"` — o placeholder aplicava literalmente quando esquecido.

#### Divergências de contrato corrigidas

O `shared-services`, sendo o primeiro consumidor conjunto dos 5 módulos, expôs divergências que teriam sido copiadas para os 21 roots de produto na Fase 3. Corrigidas na raiz:

- **Regra única de ingress** nos 5 módulos: qualquer entrada em `allowed_cidr_blocks`/`allowed_security_group_ids` vale sozinha e nada é somado por cima; as duas vazias caem no CIDR da VPC só se `allow_vpc_cidr_ingress = true`. Antes havia três comportamentos: docdb/rabbitmq abriam a VPC inteira **mesmo com allow list restrita** (quem restringia não restringia), e o MSK não tinha fallback nenhum (listas vazias = cluster inalcançável em silêncio). Cada módulo ganhou `check "ingress_is_reachable"`.
- **Outputs em `one(x[*].attr)`** nos 5, nunca `x[0].attr`: um ternário avalia os dois lados, então `[0]` num recurso com `count = 0` estoura até no branch não escolhido.
- **Footguns de apply promovidos a plan-time**: Performance Insights não existe em `db.t4g.micro/small` (exatamente o tamanho dos tfvars de dev) e DocumentDB não tem as classes micro/small — os dois agora falham no plan com mensagem explícita em vez de quebrar minutos adentro do apply.

---

## Fase 2 — Piloto midaz

### Objetivo
Primeiro produto no novo padrão, validando a estrutura por-serviço e o contrato dos módulos nos dois modos (dedicated e shared) antes do rollout.

### Layout — um root por serviço

Decisão do usuário: cada serviço de um produto é um root Terraform independente, com seu próprio state.

```
examples/aws/products/midaz/
├── README.md      composição, ordem, mapeamento output -> values do Helm
├── postgres/      -> _modules/postgres-rds
├── documentdb/    -> _modules/mongodb-documentdb
├── valkey/        -> _modules/valkey-elasticache
└── rabbitmq/      -> _modules/rabbitmq-amazonmq
```

Sem diretório `msk/`: o chart midaz tem `STREAMING_ENABLED` default `false`. Se for ligado, o caminho é `mode = "shared"` contra o MSK do `infra-base/shared-services`.

**Trade-off aceito**: blast radius menor (mexer no valkey não toca o RDS) em troca de ~60 diretórios no total e de o deploy de um produto ser N applies. Consequência prática: os outputs de um produto ficam em N states, então montar os values do Helm exige N `terraform output` — o `deploy.sh` v2 deve agregar isso.

### Tarefas

2.1 Os 4 roots de serviço, cada um com `main.tf` fino (module call), `variables.tf`, `outputs.tf`, `providers.tf`, `backend.tf` vazio, `versions.tf`, `envs/{dev,stg,prd}.tfvars-example`, `README.md`. State key `aws/products/midaz/<serviço>/terraform.tfstate`.

2.2 Cada serviço expõe um output `helm_values` (map) com as chaves de env que aquele datastore alimenta no chart — é o que torna o handoff pro Helm mecânico em vez de manual.

2.3 Ingress via o mesmo padrão que o então `shared-services` já usava: `data "aws_security_groups"` plural em `tag:Name = lerian-{env}-eks-node`, que retorna lista vazia em vez de falhar quando o EKS ainda não existe. (Hoje esse lookup vive no módulo `product-network`, escrito uma vez.)

2.4 **`_modules/product-network`** — extraído durante o piloto, antes de replicar. O lookup de VPC/subnets/SG-do-EKS era ~70 linhas idênticas em cada root; com 21 produtos isso seria ~4.400 linhas duplicadas e 70+ pontos de edição para qualquer correção. Agora é um módulo puro de lookup (zero recursos AWS), com o `check` dentro dele, e cada root perdeu ~100 linhas. Refactor provado sem regressão: a lista de outputs dos 4 roots ficou idêntica antes/depois.

**Armadilha registrada para a Fase 3**: existem dois `subnet_tag_type` com semânticas diferentes — no `product-network` o default é `private` (CIDRs que viram ingress) e nos módulos de datastore é `database` (onde a instância é colocada). Ligar um no outro autoriza os CIDRs errados. Está avisado na descrição da variável, no README do módulo e no contrato.

### Achados sobre o chart midaz (confirmados no chart, não presumidos)

Três coisas que teriam quebrado o deploy em silêncio:

- **`REDIS_PORT` não existe** (removido no chart 3.0). `REDIS_HOST` carrega `host:porta` — emitir só o hostname deixa o ledger discando porta 0.
- **`RABBITMQ_PORT_HOST` é a porta AMQP (5672) e `RABBITMQ_PORT_AMQP` é a de management (15672)** — os nomes estão invertidos no chart. O piloto seguiu o comportamento, não o nome.
- **`STREAMING_BROKERS` não existe**: o chart só tem `STREAMING_ENABLED`, `STREAMING_SASL_PASSWORD` e `STREAMING_TLS_CA_CERT`. Ligar streaming hoje exige injetar a lista de brokers por `ledger.extraEnvVars`. Vale abrir issue no repo de charts.

### Por que o Route53 saiu

Cada serviço AWS apresenta certificado do próprio domínio, então um CNAME em zona privada **quebra a verificação de hostname TLS**:

| Serviço | Certificado cobre |
|---|---|
| RDS | `*.{region}.rds.amazonaws.com` |
| DocumentDB | `*.docdb.amazonaws.com` |
| AmazonMQ | `*.mq.{region}.on.aws` |
| ElastiCache | `*.{cluster}.{region}.cache.amazonaws.com` |

O repo já fugia disso pela metade — rabbitmq usava endpoint bruto e docdb trocava quando TLS estava ligado — mas postgres e valkey ainda emitiam CNAME no `helm_values`, e o valkey de dev estava com `transit_encryption_enabled = true` apontando para CNAME, exatamente a combinação que falha.

O argumento a favor do CNAME seria nome estável quando o recurso é substituído. Ele não se sustenta aqui: os values do Helm saem de `terraform output helm_values`, regenerados a cada deploy, então não há valor hardcoded a proteger. Sobrava só a conveniência de digitar o host à mão.

Consequência: o `mode = "shared"` resolvia o tier compartilhado pelo CNAME, sem chamada de API. Passa a resolver por **data source, pelo nome derivado** `lerian-{env}-{component}`:

| Módulo | Data source |
|---|---|
| postgres-rds | `aws_db_instance` |
| valkey-elasticache | `aws_elasticache_replication_group` |
| rabbitmq-amazonmq | `aws_mq_broker` |
| streaming-msk | `aws_msk_cluster` (já era assim) |
| mongodb-documentdb | `aws_rds_cluster` — ver abaixo |

**DocumentDB não tem data source próprio** (só `docdb_engine_version` e `docdb_orderable_db_instance`). Validado em conta real que `aws_rds_cluster` enxerga clusters DocumentDB e devolve `engine=docdb`, endpoint writer, `reader_endpoint`, porta e `master_username` — tudo que o modo shared precisa.

### O tier compartilhado é um produto, não fundação

`shared-services` era um root único com os 5 datastores num state só — exatamente o modelo root-por-produto rejeitado para os produtos. E, sendo opcional, não pertencia a `infra-base`, que é o que todo deploy precisa.

Passou a ser `products/shared-resources/{postgres,documentdb,valkey,rabbitmq,msk}/`: **um root por serviço, um state cada**, no mesmo formato de `products/midaz/*`. Ganhos:

- regra única de granularidade no repo inteiro — a Fase 3 gera produto e tier compartilhado com o mesmo molde;
- **os toggles `*_enabled` somem**: habilitar um datastore compartilhado é aplicar o diretório, e só;
- blast radius por datastore, igual aos produtos;
- `infra-base` fica com o que é de fato obrigatório: `vpc` e `eks`.

Sutileza que confunde e precisa continuar documentada: os roots de `shared-resources` rodam com `mode = "dedicated"`, porque **eles são os donos reais** dos recursos. O rótulo "shared" descreve como os *produtos* os consomem, não como este stack os cria.

### Dois prefixos, de propósito

| Prefixo | Onde | Por quê |
|---|---|---|
| `lerian-{env}-*` | `infra-base/vpc`, `infra-base/eks` | Fundação. Sempre compartilhada, sem alternativa "dedicada" — o rótulo `shared` não carregaria informação nenhuma. |
| `shared-{env}-{engine}` | `products/shared-resources/*` | Aqui existe a escolha `dedicated`/`shared`, então o nome precisa distinguir o compartilhado de um datastore de produto. `shared-dev-postgres` diz o que é; `lerian-dev-postgres` não. |

Cada root de `shared-resources` roda com `product = "shared"` e tem `validation` que rejeita outro valor, porque o modo `shared` dos módulos deriva esse rótulo para achar o tier — divergir cria recursos que nenhum consumidor encontra, e o apply passa.

Não "unifique" os dois prefixos: eles codificam uma distinção real.

### `check` blocks avisam, não bloqueiam

Descoberto ao corrigir os CIDRs do EKS, e vale para todo o repo: um `check` block **nunca falha um plan ou apply** — ele só emite warning. Portanto `check` serve para sinalizar estado transitório legítimo (ex: o SG dos nodes do EKS ainda não existe no primeiro apply), e **nunca** para impedir uma configuração inválida. O que bloqueia é `validation` (na variável) ou `precondition` (no recurso). Confundir os dois troca uma falha barulhenta por um apply silencioso e errado — foi exatamente o risco no caso do `allowed_api_access_cidrs` vazio, que teria aberto o endpoint da API para `0.0.0.0/0` sem erro nenhum.

### Armadilha de troca de conta: `.terraform` guarda o backend antigo

Ao mover a validação de uma conta para outra, o `terraform init -reconfigure` precisa ser refeito em **todo** stack. O `.terraform/` local guarda o bucket anterior, e um stack esquecido falha com `403 Forbidden` tentando ler o state na conta errada — aconteceu com o `infra-base/eks` aqui. O erro é claro, mas o modo de falha é silencioso até o momento do apply. O `deploy.sh` v2 deve sempre passar `-reconfigure` no init, em vez de assumir que o `.terraform` está coerente com o ambiente pedido.

### Limitação conhecida do bootstrap: um estado local por ambiente, não por conta

O `bootstrap` usa state local com um workspace por ambiente, e uma `precondition` exige `workspace == environment`. Isso assume **uma conta AWS**. Rodar o mesmo diretório contra duas contas colide no mesmo workspace `dev`. Clientes com dev/stg/prd em contas separadas (padrão em Control Tower) vão bater nisso. Correção candidata para a Fase 4: incluir o account id no nome do workspace, ou usar `-state=` por conta.

### Validação E2E

```bash
cd examples/aws/midaz
terraform init -backend-config=../backend/dev.hcl -backend-config="key=aws/midaz/terraform.tfstate"

# 1. Modo dedicated, tamanhos mínimos — apply real em dev
terraform apply -var-file=envs/dev.tfvars -auto-approve
# Checagens:
aws rds describe-db-instances --query "DBInstances[?DBInstanceIdentifier=='midaz-dev-postgres']"
aws docdb describe-db-clusters --query "DBClusters[?DBClusterIdentifier=='midaz-dev-docdb']"
aws secretsmanager list-secrets --filter Key=name,Values=midaz-dev | jq '.SecretList|length'  # >= 4
# CNAMEs na zona dev.lerian.internal: postgres.midaz., mongodb.midaz., valkey.midaz., rabbitmq.midaz.

# 2. Modo shared: shared-services dev com postgres enabled + midaz com postgres_mode=shared
terraform plan -var-file=envs/dev.tfvars -var postgres_mode=shared   # não cria instância; output = endpoint lerian-dev-postgres

# 3. Prova multi-env do produto: plan de stg com backend stg — zero conflito de nome com dev
terraform init -reconfigure -backend-config=../backend/stg.hcl -backend-config="key=aws/midaz/terraform.tfstate"
terraform plan -var-file=envs/stg.tfvars

# 4. (Opcional, se EKS dev estiver de pé) helm install midaz com subcharts off apontando pros outputs — smoke real do contrato
# 5. destroy do midaz dev
```

### Critérios de saída
- [x] midaz dev aplicado/destruído nos tamanhos mínimos sem intervenção manual — 4/4 datastores aplicados na conta de development (us-east-2) e destruídos; `midaz-dev-postgres` (16.13), `midaz-dev-docdb`, `midaz-dev-valkey`, `midaz-dev-rabbitmq-single`
- [x] 5 CNAMEs por produto criados e resolvendo: `postgres|mongodb|mongodb-ro|valkey|rabbitmq.midaz.dev.lerian.internal`
- [x] `helm_values` conferido nos 4 roots — inclusive `REDIS_HOST` com `host:porta`, `retryWrites=false` do DocumentDB e `RABBITMQ_HOST` no endpoint bruto (o CNAME quebraria a verificação de hostname do AMQPS)
- [x] Contrato retro-aplicado antes da Fase 3 — `product-network` extraído, defaults de RabbitMQ e Postgres corrigidos nos módulos
- [x] Modo shared valida contra o tier compartilhado real — `midaz/valkey` com `mode = "shared"` aplicou **0 recursos** e resolveu `valkey.lerian.dev.lerian.internal` mais o ARN real de `lerian-dev-valkey/auth-token`. O modelo híbrido está provado: mesmo root, uma variável decide dedicado vs compartilhado

### Infra-base: validação completa (a lacuna que faltava)

Rodada dedicada na `lerian-development`, com **todos** os stacks aplicados de verdade:

| Stack | Recursos | Resultado |
|---|---|---|
| `vpc` | 42 | ok |
| `route53` | 1 | ok |
| `eks` | 25 (+31 de tentativas anteriores no state) | cluster `lerian-dev-eks` ACTIVE, v1.32, node group ativo, 5 addons, IRSA |
| `shared-services` | 75 | os **5** datastores: postgres, docdb, valkey, rabbitmq e MSK (ACTIVE) |
| `products/midaz/postgres` | 13 | com o cluster de pé |

**O contrato de ingress foi provado end-to-end pela primeira vez.** Antes disso, todo apply tinha rodado sem cluster, então o `check` sempre avisava e o ingress vinha só dos CIDRs privados — só a degradação estava testada, nunca o caminho feliz. Com o cluster real:

- zero warnings de check, tanto no produto quanto no shared-services;
- `ingress_security_group_ids = ["sg-0abc…(SG dos nodes)"]`, o SG dos nodes;
- regra real no SG do Postgres: `porta 5432 origem=sg-0abc…(SG dos nodes)`, além dos 3 CIDRs privados.

Detalhe que confirma o desenho: o nome real do SG é `lerian-dev-eks-node-b47379f4b4e354eff9ef9795a1` — o módulo oficial usa `name_prefix` com sufixo aleatório. É por isso que o lookup **precisa** ser por `tag:Name` e não por nome do grupo.

### Ganho medido da estrutura por-serviço

Os 4 datastores foram aplicados **em paralelo em 9 minutos**. Sequencial (o que um root único por produto forçaria) seria ~30 min, limitado pelo AmazonMQ. O destroy paralelo levou 12 min. Esse é o ganho concreto que compensa os ~60 diretórios.

### Nota de custo que muda a recomendação de default

Com o preço real do AmazonMQ (~US$100/mês por broker single-AZ), 21 produtos com RabbitMQ dedicado ficam caros. Para os 9 produtos do discovery que usam RabbitMQ, `mode = "shared"` contra o broker do `infra-base/shared-services` deve ser o default sugerido na Fase 3, com dedicado como exceção justificada.

---

## Fase 3 — Rollout dos 20 produtos restantes

### Objetivo
Todos os produtos do discovery com diretório próprio, gerados do manifest.

### Tarefas

3.1 Criar `examples/aws/products.yaml` (manifest, derivado do `product-infra-dependencies.yaml`):
```yaml
midaz:      {postgres: true, documentdb: true, valkey: true, amazonmq: true, msk: false}
tracer:     {postgres: true, valkey: optional}          # valkey só multi-tenant
reporter:   {documentdb: true, valkey: true, amazonmq: true, s3: [reporter-storage]}
fetcher:    {documentdb: true, valkey: true, amazonmq: true, s3: [external-data]}
bc-correios: {postgres: true, valkey: true, amazonmq: true, s3: [bc-correios-attachments]}
br-sisbajud: {postgres: true, valkey: true, msk: required}
br-sfn:      {postgres: true, valkey: true, amazonmq: true, msk: required}
# ... demais conforme discovery
```
3.2 Gerar os 20 diretórios no mesmo template do midaz (estrutura idêntica, composição do manifest).
3.3 **Checkpoint humano**: validar composição de `flowker`, `matcher`, `underwriter` (lender) e `plugin-br-pix-jd` com os times donos — charts sem `Chart.yaml` no repo, dependências inferidas. Bloqueia o merge, não bloqueia a geração.
3.4 Produtos com `msk: required` (`br-sisbajud`, `br-sfn`): variável `streaming_brokers` obrigatória OU `msk_mode=shared` lendo o MSK do shared-services.

### Validação E2E

```bash
# 1. Estática nos 21 dirs (loop padrão)
# 2. init + plan de TODOS os 21 em dev (backend dev real; plan-only, sem custo de apply)
for p in $(ls -d examples/aws/*/ | grep -vE '_modules|infra-base|backend|bootstrap'); do
  (cd "$p" && terraform init -backend-config=../backend/dev.hcl -backend-config="key=aws/$(basename $p)/terraform.tfstate" \
    && terraform plan -var-file=envs/dev.tfvars -detailed-exitcode); echo "$p => $?"
done   # exitcode 2 (mudanças) esperado em todos; 1 = erro, falha a fase

# 3. Apply real de amostra cobrindo cada combinação de datastore não exercitada pelo midaz:
#    reporter (documentdb+valkey+amazonmq+s3), br-payments (só postgres), br-sisbajud (msk shared)
#    → apply mínimo em dev, checar recursos {produto}-dev-*, destroy
# 4. Conferir que nenhum plan contém nome sem env: grep -L 'environment' nos plans salvos + regra tflint custom
```

### Critérios de saída
- [ ] 21/21 com plan limpo em dev
- [ ] Amostra (reporter, br-payments, br-sisbajud) aplicada e destruída
- [ ] 4 produtos inferidos validados pelos times (ou marcados `# UNVALIDATED` no manifest com issue aberta)

---

## Fase 4 — deploy.sh v2 + CI

### Objetivo
Orquestração one-click por env/produto, sem case tables duplicadas; CI que descobre diretórios sozinho.

### Tarefas

4.1 `deploy.sh` v2 — **decisão do usuário: só depois de a estrutura nova estar validada**, e o script novo deve englobar também o `bootstrap` (que hoje fica fora dele). Até então o caminho AWS do script fica quebrado de propósito, porque aponta para os 9 stacks legado removidos; GCP e Azure seguem funcionando.
- Flags: `--env dev|stg|prd` (obrigatória), `--product <nome>|infra-base|all`, `--action plan|apply|destroy` (default `plan`), `--auto-approve`.
- Precisa agregar os outputs dos N states de um produto num único bloco de values do Helm — consequência direta do layout por-serviço.

**Requisito explícito do usuário: os 3 ambientes têm que rodar tanto em conta única quanto em contas separadas.**

O que já está pronto para isso:
- `backend/{env}.hcl` carrega o account id no nome do bucket, então contas separadas já funcionam no state;
- conta única está **provado** — dev e stg coexistiram sem colisão de nome (o teste do IAM role).

O que falta no script:
- mapear profile AWS por ambiente (`--env prd` → `AWS_PROFILE=lerian-production`), com o mapeamento em arquivo de config e não hardcoded, já que cada cliente nomeia suas contas como quiser;
- `bootstrap` com state local por **conta**, não só por ambiente. Hoje o workspace é preso a `dev|stg|prd` e colide quando o mesmo diretório roda contra duas contas — foi assim que perdi o state da sandbox nesta sessão;
- sempre passar `-reconfigure` no `init`, porque o `.terraform` guarda o bucket da conta anterior e falha com `403 Forbidden` de forma silenciosa até o apply;
- validar antes de agir que o profile resolvido aponta para a conta esperada (`sts get-caller-identity`), para não aplicar prd numa conta de dev por profile errado.
- Lê `products.yaml` para composição/ordem; ordem topológica: `bootstrap(check) → infra-base/vpc → eks → shared-services → produtos` (ver nota de ordem nas convenções globais).
- Injeta `-backend-config=backend/${ENV}.hcl` e `-var-file=envs/${ENV}.tfvars` em tudo; placeholder-check em TODOS os componentes (corrige o gap atual de amazonmq/documentdb).
- Destroy em ordem reversa; `--action plan` nunca toca estado.
4.2 `.github/workflows/ci.yml`: matrix gerada por `find examples -name versions.tf` (fmt/validate/tflint/tfsec em tudo, sem lista manual).
4.3 Remover os 3 case tables e arrays antigos.

### Validação E2E

```bash
# 1. Dry-run integral: ./deploy.sh --env dev --product all --action plan  → 25 plans, zero erro
# 2. Ciclo real mínimo: ./deploy.sh --env dev --product midaz --action apply --auto-approve
#    e depois --action destroy; conferir ordem e exit codes
# 3. Guard rails: --env qa deve falhar com mensagem clara; backend/prd.hcl ausente deve falhar ANTES de qualquer terraform
# 4. shellcheck deploy.sh
# 5. CI: act -j validate (ou push da branch e observar o run) — todos os dirs descobertos
```

### Critérios de saída
- [ ] `plan all` verde nos 3 envs (prd/stg só plan, sem apply)
- [ ] Ciclo apply→destroy do midaz via script sem intervenção
- [ ] shellcheck limpo; CI verde descobrindo 100% dos dirs

---

## Fase 5 — Migração, limpeza e docs

### Objetivo
Repo só com o layout novo; cliente da v1 tem caminho documentado.

### Tarefas

5.1 ~~Remover stacks antigos~~ — **feito antecipadamente, junto da Fase 2**, a pedido do usuário. Os 9 diretórios (`examples/aws/{vpc,route53,rds,valkey,amazonmq,documentdb,documentdb-plugin-fee,documentdb-plugin-crm,eks}`) foram removidos via `git rm`; seguem recuperáveis em `main`. Colateral tratado na hora: o `ci.yml` passou a **descobrir** os diretórios via `find examples -name versions.tf` em vez de enumerá-los (a lista antiga já estava desatualizada — `amazonmq`, os três `documentdb*`, `azure/cosmosdb` e `azure/base-resources` eram deployáveis e nunca eram checados), e as referências nos READMEs dos módulos foram reescritas no passado. `deploy.sh` ficou pendente por decisão explícita (ver 4.1).
5.2 `MIGRATION.md`: v1 → v2 — mapa de recursos antigos→novos, estratégia `terraform state mv`/import por stack, aviso de rename (recriação) para recursos que ganharam env no nome.
5.3 `README.md` reescrito: bootstrap por env → infra-base → produto → helm (subcharts `enabled: false`, endpoints da zona privada). Atualizar seção GCP/Azure com nota "layout v2 é AWS-only por enquanto".
5.4 Atualizar `.tflint.hcl` / tfsec excludes para o novo layout.

### Validação E2E

```bash
# 1. Estática repo inteiro; grep proibitivo: nenhuma referência a examples/aws/rds etc. em docs/scripts
grep -rn 'examples/aws/\(rds\|documentdb-plugin\|amazonmq\)' --include='*.md' --include='*.sh' . && exit 1
# 2. Walkthrough fresh-clone: git clone da branch em /tmp, seguir o README literalmente até 'plan' do midaz dev — sem passos faltando
# 3. deploy.sh --env dev --product all --action plan ainda verde após as remoções
```

### Critérios de saída
- [ ] Zero referência ao layout antigo
- [ ] Fresh-clone walkthrough completo só com o README
- [ ] MIGRATION.md revisado por humano

---

## Fase 6 — Release v2.0.0

### Tarefas
6.1 Squash/organizar commits (conventional commits; sem "BREAKING CHANGES" no corpo sem aprovação explícita — usar `feat!:` só com aval do usuário).
6.2 PR `feat/aws-v2-foundation` → `develop` (template + checklist das fases); depois `develop` → `main`.
6.3 Conferir `.releaserc`/semantic-release para major bump.
6.4 Pós-merge: smoke `deploy.sh --env dev --product midaz --action plan` a partir da tag.

### Critérios de saída
- [ ] CI verde no PR; aprovação humana; tag v2.0.0 publicada

---

## Riscos e mitigação

- **Custo de validação**: applies sempre em tamanho mínimo + destroy imediato; EKS/MSK aplicados 1x cada, não por fase. MSK é o mais caro (~US$0,75/h mínimo provisioned) — validar 1x na Fase 3 via br-sisbajud shared.
- **Recriação para clientes v1**: env no nome força replace; MIGRATION.md + state mv cobrem; comunicar como major.
- **Produtos inferidos**: gate humano na Fase 3; não travar o restante.
- **Provider `postgresql` (criação de DB no modo shared)**: fora do escopo v2 — delegado aos bootstrap jobs dos charts; registrado como possível v2.1.
- **Ordem de destroy**: shared-services só destrói depois de todos os produtos em modo shared do env — deploy.sh v2 valida isso pelo manifest.

## Checklist de aprovações humanas (bloqueiam merge, não a execução)

1. Fim da Fase 2: contrato dos módulos congelado
2. Fase 3: composição dos 4 produtos inferidos
3. Fase 5: MIGRATION.md
4. Fase 6: PR review + autorização de push/merge (nunca sem aprovação explícita)
