package infra

// Chart mapping: the translation from a datastore's facts to the environment
// variables one product's Helm chart expects.
//
// This knowledge used to live only in HCL, in each product root's helm_values
// output. That worked, and it had one consequence worth removing: reading it
// required the product root to have been applied, because `terraform output`
// reads state. In shared mode a product root creates nothing at all — every
// resource is count = 0 and the root exists purely to compute this map — so an
// operator was made to run an apply that built no infrastructure, just to
// materialise an expression into a state file.
//
// With the mapping here, values can be built from whichever root OWNS the
// datastore. In shared mode that is products/shared-resources/<engine>, and the
// product root stops being on the critical path.
//
// The port that made this possible already existed: every datastore root, tier or
// product, exposes the same output contract (endpoint, port, secret_arn,
// secret_name, identifier, plus a small per-engine set). Facts below reads that
// contract; the per-product tables translate it.

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Facts are what a datastore root reports about the thing it owns.
//
// Every field is optional: engines differ, and a missing one means the engine has
// no such concept rather than an error. A mapping that needs a field it did not
// get omits its key instead of emitting an empty string, because a chart with
// REDIS_HOST="" fails at runtime with a worse message than one where the key is
// absent.
type Facts struct {
	Engine   string
	Endpoint string
	Port     string
	Username string
	// ReaderEndpoint is the replica or reader address, when the engine has one.
	ReaderEndpoint string
	SecretARN      string
	SecretName     string
	Identifier     string
	// TLS reports whether connections are encrypted in transit. Nil means the
	// engine does not expose the notion.
	TLS *bool
}

// ReadFacts turns one root's outputs into Facts.
//
// The output names are not uniform across engines and this is where that is
// absorbed: postgres calls its user "username", DocumentDB "master_username" and
// AmazonMQ "admin_username". Normalising here keeps the per-product tables free of
// engine trivia.
func ReadFacts(engine string, outputs map[string]json.RawMessage) Facts {
	facts := Facts{Engine: engine}

	str := func(keys ...string) string {
		for _, key := range keys {
			raw, ok := outputs[key]
			if !ok {
				continue
			}
			var text string
			if err := json.Unmarshal(raw, &text); err == nil && text != "" {
				return text
			}
			// A port arrives as a JSON number.
			var number float64
			if err := json.Unmarshal(raw, &number); err == nil {
				return strconv.FormatInt(int64(number), 10)
			}
		}
		return ""
	}

	facts.Endpoint = str("endpoint")
	facts.Port = str("port")
	facts.Username = str("username", "master_username", "admin_username")
	facts.ReaderEndpoint = str("reader_endpoint", "replica_endpoint")
	facts.SecretARN = str("secret_arn")
	facts.SecretName = str("secret_name")
	facts.Identifier = str("identifier")

	if raw, ok := outputs["transit_encryption_enabled"]; ok {
		var enabled bool
		if err := json.Unmarshal(raw, &enabled); err == nil {
			facts.TLS = &enabled
		}
	}
	return facts
}

// ChartMapper builds one product's env vars from one datastore's facts.
type ChartMapper func(Facts) map[string]any

// chartMappers is the registry, keyed by product then engine.
//
// A product absent from here still works: CollectHelmValues falls back to reading
// the helm_values output out of the product root, which is where every product's
// mapping lives today. Entries are added one product at a time, each one verified
// against that product's chart, because the cost of getting a key wrong is a
// service that starts and then cannot reach its database.
// The components of the midaz chart, as the chart itself names them: it declares
// lerian.studio/chart-type: multi-component and has exactly templates/ledger and
// templates/crm.
const (
	midazLedger = "ledger"
	midazCRM    = "crm"
)

var chartMappers = map[string]map[string]ChartMapper{
	"midaz": {
		"postgres":   midazPostgres,
		"documentdb": midazDocumentDB,
		"valkey":     midazValkey,
		"rabbitmq":   midazRabbitMQ,
	},
}

// HasChartMapper reports whether this product's mapping has been ported to Go.
func HasChartMapper(product, engine string) bool {
	engines, ok := chartMappers[product]
	if !ok {
		return false
	}
	_, ok = engines[engine]
	return ok
}

// MapChartValues applies a product's mapping. The second result is false when
// there is no Go mapping for this pair.
//
// The result is keyed by CHART COMPONENT, never by env var: a chart gives each of
// its components its own ConfigMap, so "which component" is part of the answer and
// not something a consumer can recover afterwards. midaz has two — ledger and crm —
// and the unsuffixed MONGO_* keys belong to a different ConfigMap than the
// suffixed ones, which a flat map cannot express at all.
//
// The component name is bare ("ledger", not "ledger.configmap") because the
// ".configmap" half says which OUTPUT the keys came from, not which component:
// helm_values lands in <component>.configmap and helm_secret_values in
// <component>.secrets. Encoding it in the key would make the same component appear
// under two different strings and stop two services of one product from merging
// into it.
func MapChartValues(product, engine string, facts Facts) (map[string]any, bool) {
	engines, ok := chartMappers[product]
	if !ok {
		return nil, false
	}
	mapper, ok := engines[engine]
	if !ok {
		return nil, false
	}
	return mapper(facts), true
}

// component returns the map for one chart component, creating it on first use.
//
// Components are created lazily so a mapper that ends up contributing nothing to a
// component leaves it out entirely, rather than emitting an empty ConfigMap block
// the consumer then has to filter.
//
// The inner map is map[string]any and not map[string]string even though every value
// is a string, because mergeInto only recurses when BOTH sides assert to
// map[string]any. All four midaz roots contribute to "ledger", so with a typed
// inner map the second service to arrive would not merge into the first — it would
// be reported as a conflict between two objects.
func component(values map[string]any, name string) map[string]any {
	if existing, ok := values[name].(map[string]any); ok {
		return existing
	}
	created := map[string]any{}
	values[name] = created
	return created
}

// put writes a key only when the value is present, so an absent fact leaves the
// key out rather than setting it empty.
func put(values map[string]any, key, value string) {
	if value == "" {
		return
	}
	values[key] = value
}

// midazPostgres mirrors products/midaz/postgres/outputs.tf.
//
// Onboarding and transaction are separate databases in the chart but share one
// instance here, so both point at the same endpoint. The replica keys fall back to
// the writer when no replica exists, which is what the HCL did: the chart requires
// the keys, and pointing them at the writer is correct for a single-instance dev
// environment.
//
// DB_ONBOARDING_USER / DB_TRANSACTION_USER AND THEIR REPLICA TWINS ARE NOT EMITTED,
// and that is the correction described in secretRefFor: the master username is the
// admin identity, not the application's. templates/bootstrap-postgres.yaml creates
// a scoped role named midaz, which is also the chart default for these keys, so
// leaving them out is what makes the release use it.
func midazPostgres(f Facts) map[string]any {
	values := map[string]any{}
	ledger := component(values, midazLedger)

	replica := f.ReaderEndpoint
	if replica == "" {
		replica = f.Endpoint
	}
	for _, prefix := range []string{"DB_ONBOARDING", "DB_TRANSACTION"} {
		put(ledger, prefix+"_HOST", f.Endpoint)
		put(ledger, prefix+"_PORT", f.Port)
		put(ledger, prefix+"_REPLICA_HOST", replica)
		put(ledger, prefix+"_REPLICA_PORT", f.Port)
	}
	return values
}

// midazDocumentDB mirrors products/midaz/documentdb/outputs.tf.
//
// retryWrites=false is not a preference: DocumentDB rejects retryable writes, and
// the MongoDB driver sends them by default, so the parameter is mandatory rather
// than tuning.
//
// This is the mapping that made the nesting necessary. The suffixed keys go to the
// ledger ConfigMap (templates/ledger/configmap.yaml) and the unsuffixed ones to the
// crm ConfigMap (templates/crm/configmap.yaml, keys MONGO_URI/HOST/PORT/USER/
// PARAMETERS) — two different ConfigMaps in the same chart, holding keys that
// differ only by prefix. Flattened, the split existed only in prose and every
// consumer had to re-derive it.
//
// crm is emitted even though crm.enabled defaults to false: the keys are inert
// until it is turned on, and emitting them means turning it on needs no second
// lookup.
func midazDocumentDB(f Facts) map[string]any {
	values := map[string]any{}
	ledger := component(values, midazLedger)
	for _, prefix := range []string{"MONGO_ONBOARDING", "MONGO_TRANSACTION"} {
		put(ledger, prefix+"_URI", "mongodb")
		put(ledger, prefix+"_HOST", f.Endpoint)
		put(ledger, prefix+"_PORT", f.Port)
		put(ledger, prefix+"_PARAMETERS", "retryWrites=false")
	}

	crm := component(values, midazCRM)
	put(crm, "MONGO_URI", "mongodb")
	put(crm, "MONGO_HOST", f.Endpoint)
	put(crm, "MONGO_PORT", f.Port)
	put(crm, "MONGO_PARAMETERS", "retryWrites=false")
	return values
}

// midazValkey mirrors products/midaz/valkey/outputs.tf.
//
// Two shapes for one address, both required by the same chart: REDIS_HOST carries
// "host:port" because chart 3.0 removed REDIS_PORT, while the multi-tenant block
// kept them separate. REDIS_DB is 0, the variable's default in every root; it is a
// chart-side database index with no counterpart in AWS, so there is nothing in
// state to read it from.
func midazValkey(f Facts) map[string]any {
	values := map[string]any{}
	ledger := component(values, midazLedger)

	tls := "false"
	if f.TLS != nil && *f.TLS {
		tls = "true"
	}
	if f.Endpoint != "" && f.Port != "" {
		ledger["REDIS_HOST"] = f.Endpoint + ":" + f.Port
	}
	ledger["REDIS_TLS"] = tls
	ledger["REDIS_DB"] = "0"

	put(ledger, "MULTI_TENANT_REDIS_HOST", f.Endpoint)
	put(ledger, "MULTI_TENANT_REDIS_PORT", f.Port)
	ledger["MULTI_TENANT_REDIS_TLS"] = tls
	return values
}

// midazRabbitMQ mirrors products/midaz/rabbitmq/outputs.tf.
//
// The two port keys are named backwards and that is deliberate, inherited from the
// chart: RABBITMQ_PORT_HOST is the AMQP port and RABBITMQ_PORT_AMQP is the
// management console. Renaming them here would fix the name and break the chart.
// The console port is 443 for every AmazonMQ broker — the service terminates TLS
// and exposes no other management port — so it is a constant rather than a fact.
// RABBITMQ_DEFAULT_USER IS NOT EMITTED. It does belong in the ConfigMap rather than
// the Secret — templates/ledger/configmap.yaml reads it and only
// RABBITMQ_DEFAULT_PASS comes from templates/ledger/secrets.yaml — but the value is
// not the broker's admin user. templates/bootstrap-rabbitmq.yaml creates two scoped
// users, "transaction" and "consumer", and "transaction" is the chart default for
// this key. See secretRefFor: the admin identity travels as a SecretRef.
func midazRabbitMQ(f Facts) map[string]any {
	values := map[string]any{}
	ledger := component(values, midazLedger)

	ledger["RABBITMQ_URI"] = "amqps"
	ledger["RABBITMQ_PROTOCOL"] = "https"
	put(ledger, "RABBITMQ_HOST", f.Endpoint)
	put(ledger, "RABBITMQ_PORT_HOST", f.Port)
	ledger["RABBITMQ_PORT_AMQP"] = "443"
	return values
}

// MappedProducts lists the products whose mapping lives in Go, for a status line.
func MappedProducts() []string {
	names := make([]string, 0, len(chartMappers))
	for name := range chartMappers {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// EngineOf returns the datastore engine a unit configures, which is the last
// segment of its path: products/midaz/valkey -> valkey.
func EngineOf(unit Unit) string {
	name := unit.Name
	if index := strings.LastIndex(name, "/"); index >= 0 {
		return name[index+1:]
	}
	return name
}

// ProductOf returns the product a unit belongs to, or "" for a non-product root.
func ProductOf(unit Unit) string {
	rest, ok := strings.CutPrefix(unit.Name, "products/")
	if !ok {
		return ""
	}
	product, _, ok := strings.Cut(rest, "/")
	if !ok {
		return ""
	}
	return product
}

// SharedUnitFor returns the tier root that owns this product datastore.
func SharedUnitFor(layout Layout, unit Unit) Unit {
	engine := EngineOf(unit)
	dir := layout.ProductsDir() + "/" + sharedResources + "/" + engine
	return Unit{Dir: dir, Name: fmt.Sprintf("products/%s/%s", sharedResources, engine)}
}

// readDatastoreMode reads the dedicated/shared switch out of a root's own tfvars.
//
// The mode is not in state — a root in shared mode has almost no state at all —
// and it is not in the Terraform outputs of the owner either. The tfvars is the
// one place that carries the operator's choice, and it is the same file the apply
// reads, so a decision made here cannot disagree with the one Terraform made.
//
// An absent file or an absent key both mean dedicated, matching the templates'
// default: values are only redirected on an explicit opt-in.
func readDatastoreMode(unit Unit, env string) (string, error) {
	content, err := os.ReadFile(VarFile(unit, env))
	if err != nil {
		if os.IsNotExist(err) {
			return DedicatedMode, nil
		}
		return "", fmt.Errorf("infra: cannot read %s: %w", VarFile(unit, env), err)
	}

	for _, line := range splitLines(content) {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		match := modeAssignment.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		// The captured group is the prefix up to the opening quote; take the value
		// between the quotes instead.
		if start := strings.Index(line, "\""); start >= 0 {
			if end := strings.Index(line[start+1:], "\""); end >= 0 {
				return line[start+1 : start+1+end], nil
			}
		}
	}
	return DedicatedMode, nil
}

// SecretRef is where the ADMIN credential of one datastore lives in AWS.
//
// It is not the application's credential and must not be handed to the workload as
// one. The midaz chart ships bootstrap Jobs — templates/bootstrap-postgres.yaml,
// bootstrap-mongodb.yaml, bootstrap-rabbitmq.yaml — that connect as the master,
// create a scoped user (a role named midaz, a Mongo user, the RabbitMQ users
// transaction and consumer) with a password the operator supplies, and exit. The
// workload then authenticates as that scoped user. So the master's only consumer is
// the Job, and rotating it in AWS no longer takes the application down.
//
// This is also why the mappers above stopped emitting *_USER: the chart's own
// defaults for those keys are the users the Jobs create, and overwriting them with
// the master username produced a release that starts and then fails to
// authenticate — the credential is scoped to the wrong identity.
type SecretRef struct {
	// Engine is the datastore this credential belongs to: postgres, documentdb,
	// valkey or rabbitmq.
	Engine string
	// SecretName and SecretARN identify the AWS Secrets Manager secret. Which one it
	// is already follows the mode: a product in shared mode resolves the tier's
	// secret, so no caller has to know that shared-{env}-postgres exists.
	SecretName string
	SecretARN  string
	// Property is the field to read out of the secret's payload, or "" when the
	// payload IS the credential.
	//
	// THE PAYLOADS ARE NOT UNIFORM AND THIS CANNOT BE GUESSED. postgres-rds stores a
	// JSON document ({username, password, engine, host, port, dbname}) because that
	// is the shape RDS itself publishes; mongodb-documentdb, valkey-elasticache and
	// rabbitmq-amazonmq each store the password as a bare string. Reading a bare
	// string as JSON, or a JSON document as a password, both fail at connect time
	// with a message that names neither.
	Property string
	// AdminUsername is the identity the password belongs to: DB_USER_ADMIN for the
	// postgres Job, MONGO_ROOT_USER for the mongo one, RABBITMQ_ADMIN_USER for the
	// rabbitmq one. Empty for valkey, which authenticates with a token and no user.
	AdminUsername string
	// Host and Port repeat what the config map already carries, because the Jobs read
	// them from global.external*Definitions.connection rather than from the
	// component ConfigMaps, and those defaults are in-cluster names
	// ("midaz-postgresql-primary") that resolve to nothing against AWS.
	Host string
	Port string
}

// secretPayloadProperty records, per engine, how _modules/<engine> stores the
// credential. It is keyed by engine and not by product because it describes this
// repository's own modules: every product and the shared tier use the same ones.
var secretPayloadProperty = map[string]string{
	"postgres": "password",
}

// SecretRefFor builds the admin credential reference for one datastore's facts. The
// second result is false when the root reported no secret, which is what a stack
// that provisions no credential looks like.
//
// It is deliberately independent of the chart mapping: secret_name and secret_arn
// are part of the uniform contract every datastore root exposes, so this works for
// the twenty products that have no Go mapping yet.
func SecretRefFor(engine string, facts Facts) (SecretRef, bool) {
	if facts.SecretName == "" && facts.SecretARN == "" {
		return SecretRef{}, false
	}
	return SecretRef{
		Engine:        engine,
		SecretName:    facts.SecretName,
		SecretARN:     facts.SecretARN,
		Property:      secretPayloadProperty[engine],
		AdminUsername: facts.Username,
		Host:          facts.Endpoint,
		Port:          facts.Port,
	}, true
}
