package infra

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func raw(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

// The user is spelled differently by every engine: postgres says "username",
// DocumentDB "master_username", AmazonMQ "admin_username". Normalising here is what
// keeps that trivia out of the per-product tables.
func TestReadFactsNormalisesTheUserSpellings(t *testing.T) {
	for _, test := range []struct{ key, want string }{
		{"username", "postgres"},
		{"master_username", "docdbadmin"},
		{"admin_username", "rabbitmqadmin"},
	} {
		facts := ReadFacts("x", map[string]json.RawMessage{test.key: raw(test.want)})
		if facts.Username != test.want {
			t.Errorf("%s: Username = %q, want %q", test.key, facts.Username, test.want)
		}
	}
}

// A port arrives from terraform-json as a number, and every chart wants a string.
func TestReadFactsAcceptsANumericPort(t *testing.T) {
	facts := ReadFacts("postgres", map[string]json.RawMessage{"port": raw(5432)})
	if facts.Port != "5432" {
		t.Errorf("Port = %q, want 5432", facts.Port)
	}
}

func TestReadFactsLeavesUnknownFieldsEmpty(t *testing.T) {
	facts := ReadFacts("valkey", map[string]json.RawMessage{})
	if facts.Endpoint != "" || facts.Username != "" || facts.TLS != nil {
		t.Errorf("nothing was reported, so nothing should be filled: %+v", facts)
	}
}

// chartComponent pulls one component's keys out of a mapping result, failing the
// test if the component is missing. Every assertion below goes through it, so a
// mapping that regresses to a flat map fails on the component rather than on each
// key: "no ledger component" is the diagnosis, and twelve absent keys are not.
func chartComponent(t *testing.T, values map[string]any, name string) map[string]any {
	t.Helper()
	keys, ok := values[name].(map[string]any)
	if !ok {
		t.Fatalf("no %q component in %v", name, values)
	}
	return keys
}

// These four assertions are the port of products/midaz/*/outputs.tf. They exist to
// catch a mapping that drifts from the chart the HCL was written against: a wrong
// key here produces a service that starts and then cannot reach its database.
func TestMidazPostgresMapping(t *testing.T) {
	values, ok := MapChartValues("midaz", "postgres", Facts{
		Endpoint: "db.rds.amazonaws.com", Port: "5432", Username: "postgres",
	})
	if !ok {
		t.Fatal("midaz/postgres should have a Go mapping")
	}
	// Every postgres key lands on the ledger ConfigMap. crm has no DB_* variable.
	ledger := chartComponent(t, values, "ledger")
	if _, present := values["crm"]; present {
		t.Error("crm reads no postgres keys, so the component must be absent")
	}
	for key, want := range map[string]string{
		"DB_ONBOARDING_HOST":  "db.rds.amazonaws.com",
		"DB_ONBOARDING_PORT":  "5432",
		"DB_TRANSACTION_HOST": "db.rds.amazonaws.com",
	} {
		if ledger[key] != want {
			t.Errorf("%s = %q, want %q", key, ledger[key], want)
		}
	}
	// With no replica, the replica keys point at the writer: the chart requires
	// them, and a single instance is the dev shape.
	if ledger["DB_ONBOARDING_REPLICA_HOST"] != "db.rds.amazonaws.com" {
		t.Errorf("replica should fall back to the writer, got %q", ledger["DB_ONBOARDING_REPLICA_HOST"])
	}

	// THE USERNAME MUST NOT BE HERE. It is the RDS master, and the workload does not
	// authenticate as the master: templates/bootstrap-postgres.yaml creates a scoped
	// role named midaz, which is also the chart default for these keys. Emitting the
	// master overrides that default with an identity whose password the release does
	// not have, and the failure surfaces as a connection error at runtime.
	for _, key := range []string{
		"DB_ONBOARDING_USER", "DB_TRANSACTION_USER",
		"DB_ONBOARDING_REPLICA_USER", "DB_TRANSACTION_REPLICA_USER",
	} {
		if _, present := ledger[key]; present {
			t.Errorf("%s must not be emitted: the master is not the app identity", key)
		}
	}
}

func TestMidazPostgresUsesTheReplicaWhenThereIsOne(t *testing.T) {
	values, _ := MapChartValues("midaz", "postgres", Facts{
		Endpoint: "writer", Port: "5432", Username: "u", ReaderEndpoint: "reader",
	})
	ledger := chartComponent(t, values, "ledger")
	if ledger["DB_TRANSACTION_REPLICA_HOST"] != "reader" {
		t.Errorf("got %q, want reader", ledger["DB_TRANSACTION_REPLICA_HOST"])
	}
	if ledger["DB_TRANSACTION_HOST"] != "writer" {
		t.Errorf("the writer key must not move: %q", ledger["DB_TRANSACTION_HOST"])
	}
}

func TestMidazDocumentDBMapping(t *testing.T) {
	values, _ := MapChartValues("midaz", "documentdb", Facts{
		Endpoint: "docdb.cluster.amazonaws.com", Port: "27017", Username: "docdbadmin",
	})
	// THE SPLIT IS THE POINT. The suffixed keys are read by
	// templates/ledger/configmap.yaml and the unsuffixed ones by
	// templates/crm/configmap.yaml: two ConfigMaps in one chart, holding keys that
	// differ only by prefix. Flattened, this routing existed only in prose.
	ledger := chartComponent(t, values, "ledger")
	crm := chartComponent(t, values, "crm")

	// retryWrites=false is mandatory, not a preference: DocumentDB rejects
	// retryable writes and the driver sends them by default.
	for _, prefix := range []string{"MONGO_ONBOARDING", "MONGO_TRANSACTION"} {
		if ledger[prefix+"_PARAMETERS"] != "retryWrites=false" {
			t.Errorf("%s_PARAMETERS = %q", prefix, ledger[prefix+"_PARAMETERS"])
		}
		if ledger[prefix+"_URI"] != "mongodb" {
			t.Errorf("%s_URI = %q", prefix, ledger[prefix+"_URI"])
		}
		if ledger[prefix+"_HOST"] != "docdb.cluster.amazonaws.com" {
			t.Errorf("%s_HOST = %q", prefix, ledger[prefix+"_HOST"])
		}
	}
	for key, want := range map[string]string{
		"MONGO_URI":        "mongodb",
		"MONGO_HOST":       "docdb.cluster.amazonaws.com",
		"MONGO_PORT":       "27017",
		"MONGO_PARAMETERS": "retryWrites=false",
	} {
		if crm[key] != want {
			t.Errorf("crm.%s = %q, want %q", key, crm[key], want)
		}
	}

	// The unsuffixed keys must not also appear on the ledger, and the suffixed ones
	// must not appear on crm: neither ConfigMap reads the other's variables, and a
	// key in the wrong one is silently ignored until something fails to connect.
	if _, present := ledger["MONGO_HOST"]; present {
		t.Error("MONGO_HOST is a crm key; the ledger reads MONGO_ONBOARDING_HOST")
	}
	if _, present := crm["MONGO_ONBOARDING_HOST"]; present {
		t.Error("crm has no suffixed Mongo variables")
	}

	// The master username is the Job's identity, not the application's:
	// templates/bootstrap-mongodb.yaml creates a scoped user with the chart's own
	// default name.
	for _, key := range []string{"MONGO_ONBOARDING_USER", "MONGO_TRANSACTION_USER"} {
		if _, present := ledger[key]; present {
			t.Errorf("%s must not be emitted: the master is not the app identity", key)
		}
	}
	if _, present := crm["MONGO_USER"]; present {
		t.Error("crm MONGO_USER must not be emitted either")
	}
}

func TestMidazValkeyMapping(t *testing.T) {
	values, _ := MapChartValues("midaz", "valkey", Facts{
		Endpoint: "master.valkey.cache.amazonaws.com", Port: "6379",
	})
	// The crm deployment has no Redis variable at all.
	ledger := chartComponent(t, values, "ledger")
	if _, present := values["crm"]; present {
		t.Error("crm reads no Redis keys, so the component must be absent")
	}

	// Chart 3.0 removed REDIS_PORT, so REDIS_HOST carries host:port — while the
	// multi-tenant block still wants them apart. Both shapes, one address.
	if ledger["REDIS_HOST"] != "master.valkey.cache.amazonaws.com:6379" {
		t.Errorf("REDIS_HOST = %q, want host:port", ledger["REDIS_HOST"])
	}
	if ledger["MULTI_TENANT_REDIS_HOST"] != "master.valkey.cache.amazonaws.com" {
		t.Errorf("MULTI_TENANT_REDIS_HOST must be the bare host, got %q", ledger["MULTI_TENANT_REDIS_HOST"])
	}
	if ledger["MULTI_TENANT_REDIS_PORT"] != "6379" {
		t.Errorf("MULTI_TENANT_REDIS_PORT = %q", ledger["MULTI_TENANT_REDIS_PORT"])
	}
	if ledger["REDIS_DB"] != "0" {
		t.Errorf("REDIS_DB = %q, want 0", ledger["REDIS_DB"])
	}
	if ledger["REDIS_TLS"] != "false" {
		t.Errorf("no TLS fact reported means false, got %q", ledger["REDIS_TLS"])
	}
}

func TestMidazValkeyReportsTLSWhenEnabled(t *testing.T) {
	enabled := true
	values, _ := MapChartValues("midaz", "valkey", Facts{
		Endpoint: "h", Port: "6379", TLS: &enabled,
	})
	ledger := chartComponent(t, values, "ledger")
	if ledger["REDIS_TLS"] != "true" || ledger["MULTI_TENANT_REDIS_TLS"] != "true" {
		t.Errorf("both TLS keys should be true: %v", ledger)
	}
}

func TestMidazRabbitMQKeepsTheInvertedPortNames(t *testing.T) {
	values, _ := MapChartValues("midaz", "rabbitmq", Facts{
		Endpoint: "b-123.mq.us-east-2.on.aws", Port: "5671", Username: "rabbitmqadmin",
	})
	ledger := chartComponent(t, values, "ledger")

	// Named backwards in the chart: PORT_HOST is AMQP, PORT_AMQP is the console.
	// Fixing the names here would fix nothing and break the chart.
	if ledger["RABBITMQ_PORT_HOST"] != "5671" {
		t.Errorf("RABBITMQ_PORT_HOST must be the AMQP port, got %q", ledger["RABBITMQ_PORT_HOST"])
	}
	if ledger["RABBITMQ_PORT_AMQP"] != "443" {
		t.Errorf("RABBITMQ_PORT_AMQP must be the console port, got %q", ledger["RABBITMQ_PORT_AMQP"])
	}

	// RABBITMQ_DEFAULT_USER does belong in the ConfigMap rather than the Secret, but
	// its value is not the broker admin: templates/bootstrap-rabbitmq.yaml creates
	// the users "transaction" and "consumer", and "transaction" is the chart default
	// for this key. Emitting the admin here is what produces
	// "403 username or password not allowed" against a broker that is up.
	if _, present := ledger["RABBITMQ_DEFAULT_USER"]; present {
		t.Error("RABBITMQ_DEFAULT_USER must not be emitted: the admin is not the app identity")
	}
}

// A missing fact leaves the key out. A chart with REDIS_HOST="" fails at runtime
// with a worse message than one where the key is simply absent.
func TestMappingOmitsKeysItCannotFill(t *testing.T) {
	values, _ := MapChartValues("midaz", "postgres", Facts{Endpoint: "h", Port: "5432"})
	ledger := chartComponent(t, values, "ledger")
	if _, present := ledger["DB_ONBOARDING_USER"]; present {
		t.Error("no username was reported, so the key must be absent, not empty")
	}
}

func TestUnmappedProductIsReportedAsSuch(t *testing.T) {
	if HasChartMapper("reporter", "documentdb") {
		t.Error("reporter has not been ported yet and must fall back to HCL")
	}
	if _, ok := MapChartValues("reporter", "documentdb", Facts{}); ok {
		t.Error("an unported product must not silently produce values")
	}
}

func TestProductAndEngineOf(t *testing.T) {
	unit := Unit{Name: "products/midaz/valkey"}
	if ProductOf(unit) != "midaz" || EngineOf(unit) != "valkey" {
		t.Errorf("got %q/%q", ProductOf(unit), EngineOf(unit))
	}
	if ProductOf(Unit{Name: "infra-base/vpc"}) != "" {
		t.Error("a non-product root has no product")
	}
}

func TestReadDatastoreMode(t *testing.T) {
	root := t.TempDir()
	unit := Unit{Dir: root, Name: "products/midaz/valkey"}
	if err := os.MkdirAll(filepath.Join(root, "envs"), 0o755); err != nil {
		t.Fatal(err)
	}

	// Absent file: dedicated, matching the templates' default. Redirection is only
	// ever an explicit opt-in.
	mode, err := readDatastoreMode(unit, "dev")
	if err != nil || mode != DedicatedMode {
		t.Errorf("missing tfvars: got %q, %v", mode, err)
	}

	for _, test := range []struct{ body, want string }{
		{"mode = \"shared\"\n", SharedMode},
		{"mode = \"dedicated\"\n", DedicatedMode},
		// The neighbouring key must not be mistaken for the switch.
		{"transit_encryption_mode = \"preferred\"\n", DedicatedMode},
		// Prose describing the other mode is not a choice.
		{"# with mode = \"shared\" nothing is created\nmode = \"dedicated\"\n", DedicatedMode},
	} {
		if err := os.WriteFile(filepath.Join(root, "envs", "dev.tfvars"), []byte(test.body), 0o644); err != nil {
			t.Fatal(err)
		}
		mode, err := readDatastoreMode(unit, "dev")
		if err != nil {
			t.Fatal(err)
		}
		if mode != test.want {
			t.Errorf("%q -> %q, want %q", strings.TrimSpace(test.body), mode, test.want)
		}
	}
}

// sharedCheckout lays out a product root in shared mode plus the tier that owns
// its datastore, and returns the Layout over them.
func sharedCheckout(t *testing.T, mode string) (Layout, Unit) {
	t.Helper()
	root := t.TempDir()
	layout := Layout{Root: root}

	product := Unit{
		Dir:  filepath.Join(layout.ProductsDir(), "midaz", "valkey"),
		Name: "products/midaz/valkey",
	}
	if err := os.MkdirAll(filepath.Join(product.Dir, "envs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(VarFile(product, "dev"), []byte("mode = \""+mode+"\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return layout, product
}

// The point of the whole exercise: in shared mode the product root creates nothing,
// so requiring an apply of it just to run `terraform output` was a cost with no
// purchase. The values now come from the root that owns the datastore.
func TestHelmValuesReadsTheOwnerInSharedMode(t *testing.T) {
	layout, product := sharedCheckout(t, SharedMode)

	terraform := newFakeTerraform()
	// Only the tier has state. The product root has none — that is the situation
	// this change exists to support.
	terraform.outputs["products/shared-resources/valkey"] = map[string]json.RawMessage{
		"endpoint": raw("master.shared-dev-valkey.cache.amazonaws.com"),
		"port":     raw(6379),
	}

	document, err := CollectHelmValuesFrom(context.Background(), terraform, layout,
		[]Unit{product}, Backend{}, "dev", Discard)
	if err != nil {
		t.Fatalf("CollectHelmValuesFrom: %v", err)
	}

	ledger := chartComponent(t, document.Values, "ledger")
	if got := ledger["REDIS_HOST"]; got != "master.shared-dev-valkey.cache.amazonaws.com:6379" {
		t.Errorf("REDIS_HOST = %v", got)
	}

	// The product root must not be read at all: it has no state, and touching it
	// is what used to force the empty apply.
	for _, call := range terraform.phase("output") {
		if call == "products/midaz/valkey" {
			t.Error("the product root was read; shared mode must go to the owner")
		}
	}
	if len(terraform.phase("output")) != 1 ||
		terraform.phase("output")[0] != "products/shared-resources/valkey" {
		t.Errorf("expected exactly one read, of the tier: %v", terraform.phase("output"))
	}
}

// Dedicated mode is unchanged: the product owns the datastore, so its own root is
// the source, and its committed helm_values output is what gets read.
func TestHelmValuesReadsTheProductInDedicatedMode(t *testing.T) {
	layout, product := sharedCheckout(t, DedicatedMode)

	terraform := newFakeTerraform()
	terraform.outputs["products/midaz/valkey"] = map[string]json.RawMessage{
		"helm_values": raw(map[string]any{
			"ledger": map[string]string{"REDIS_HOST": "own.cache.amazonaws.com:6379"},
		}),
	}

	document, err := CollectHelmValuesFrom(context.Background(), terraform, layout,
		[]Unit{product}, Backend{}, "dev", Discard)
	if err != nil {
		t.Fatalf("CollectHelmValuesFrom: %v", err)
	}
	ledger := chartComponent(t, document.Values, "ledger")
	if got := ledger["REDIS_HOST"]; got != "own.cache.amazonaws.com:6379" {
		t.Errorf("REDIS_HOST = %v", got)
	}
	if len(terraform.phase("output")) != 1 ||
		terraform.phase("output")[0] != "products/midaz/valkey" {
		t.Errorf("dedicated mode must read the product root: %v", terraform.phase("output"))
	}
}

// A zero Layout turns the redirection off, so the original entry point and any
// caller without a Layout keeps its old behaviour.
func TestHelmValuesWithoutALayoutNeverRedirects(t *testing.T) {
	_, product := sharedCheckout(t, SharedMode)

	terraform := newFakeTerraform()
	terraform.outputs["products/midaz/valkey"] = map[string]json.RawMessage{
		"helm_values": raw(map[string]string{"REDIS_HOST": "from-hcl:6379"}),
	}

	document, err := CollectHelmValues(context.Background(), terraform,
		[]Unit{product}, Backend{}, "dev", Discard)
	if err != nil {
		t.Fatalf("CollectHelmValues: %v", err)
	}
	if got := document.Values["REDIS_HOST"]; got != "from-hcl:6379" {
		t.Errorf("REDIS_HOST = %v", got)
	}
}

// THIS IS THE REGRESSION THE NESTING EXISTS TO PREVENT.
//
// The Document reaches its consumer by two different paths — the Go mapping in
// shared mode, the root's own helm_values output in dedicated mode — and before
// this test nothing held them to the same shape. A flat Go mapper next to a nested
// HCL output would make the SAME product answer differently depending on a tfvars
// line, and a consumer cannot branch on something it cannot see.
//
// The assertion is on shape, not on values: the two modes legitimately point at
// different hosts. What must match is the set of components and the set of keys in
// each.
func TestMidazShapeIsTheSameInBothModes(t *testing.T) {
	facts := Facts{
		Endpoint: "docdb.cluster.amazonaws.com", Port: "27017", Username: "docdbadmin",
	}
	// documentdb is the engine that carries two components, so it is the one where a
	// flattening regression is visible.
	built, ok := MapChartValues("midaz", "documentdb", facts)
	if !ok {
		t.Fatal("midaz/documentdb should have a Go mapping")
	}

	// The dedicated side, as products/midaz/documentdb/outputs.tf now emits it.
	fromHCL := map[string]any{
		"ledger": map[string]any{
			"MONGO_ONBOARDING_URI":         "mongodb",
			"MONGO_ONBOARDING_HOST":        "own.docdb.amazonaws.com",
			"MONGO_ONBOARDING_PORT":        "27017",
			"MONGO_ONBOARDING_PARAMETERS":  "retryWrites=false",
			"MONGO_TRANSACTION_URI":        "mongodb",
			"MONGO_TRANSACTION_HOST":       "own.docdb.amazonaws.com",
			"MONGO_TRANSACTION_PORT":       "27017",
			"MONGO_TRANSACTION_PARAMETERS": "retryWrites=false",
		},
		"crm": map[string]any{
			"MONGO_URI":        "mongodb",
			"MONGO_HOST":       "own.docdb.amazonaws.com",
			"MONGO_PORT":       "27017",
			"MONGO_PARAMETERS": "retryWrites=false",
		},
	}

	assertSameShape(t, "", fromHCL, built)
}

// assertSameShape compares two documents by structure alone: same components, same
// keys, same nesting. Values are ignored on purpose — the two modes point at
// different infrastructure.
func assertSameShape(t *testing.T, path string, want, got map[string]any) {
	t.Helper()

	for key, wantValue := range want {
		here := key
		if path != "" {
			here = path + "." + key
		}
		gotValue, present := got[key]
		if !present {
			t.Errorf("%s is emitted by the HCL path and missing from the Go path", here)
			continue
		}
		wantObject, wantIsObject := wantValue.(map[string]any)
		gotObject, gotIsObject := gotValue.(map[string]any)
		switch {
		case wantIsObject && gotIsObject:
			assertSameShape(t, here, wantObject, gotObject)
		case wantIsObject != gotIsObject:
			t.Errorf("%s is a component on one path and a plain key on the other", here)
		}
	}
	for key := range got {
		if _, present := want[key]; !present {
			here := key
			if path != "" {
				here = path + "." + key
			}
			t.Errorf("%s is emitted by the Go path and missing from the HCL path", here)
		}
	}
}

// All four midaz roots write to the same component, so collecting a whole product
// has to MERGE them into one "ledger" rather than treat the second arrival as a
// conflict. This is what forces the inner maps to be map[string]any: mergeInto only
// recurses when both sides assert to that type.
func TestMidazServicesMergeIntoOneLedger(t *testing.T) {
	document := Document{Values: map[string]any{}}

	for _, engine := range []struct {
		name  string
		facts Facts
	}{
		{"postgres", Facts{Endpoint: "pg", Port: "5432", Username: "postgres"}},
		{"valkey", Facts{Endpoint: "valkey", Port: "6379"}},
		{"rabbitmq", Facts{Endpoint: "mq", Port: "5671", Username: "admin"}},
		{"documentdb", Facts{Endpoint: "docdb", Port: "27017", Username: "docdbadmin"}},
	} {
		values, ok := MapChartValues("midaz", engine.name, engine.facts)
		if !ok {
			t.Fatalf("no mapping for midaz/%s", engine.name)
		}
		if err := mergeInto(document.Values, values, nil); err != nil {
			t.Fatalf("merging midaz/%s: %v", engine.name, err)
		}
	}

	// One ledger holding every engine's keys, plus the separate crm component.
	if len(document.Values) != 2 {
		t.Errorf("expected exactly ledger and crm, got %v keys", len(document.Values))
	}
	ledger := chartComponent(t, document.Values, "ledger")
	for _, key := range []string{
		"DB_ONBOARDING_HOST", "REDIS_HOST", "RABBITMQ_HOST", "MONGO_ONBOARDING_HOST",
	} {
		if _, present := ledger[key]; !present {
			t.Errorf("%s was lost in the merge", key)
		}
	}
	crm := chartComponent(t, document.Values, "crm")
	if crm["MONGO_HOST"] != "docdb" {
		t.Errorf("crm.MONGO_HOST = %v", crm["MONGO_HOST"])
	}
}

// The payload shapes differ between engines and nothing in the outputs says so, which
// is why this is encoded here rather than left to the consumer: postgres-rds stores
// a JSON document because that is what RDS publishes, and the other three modules
// store the password as a bare string. Reading one as the other fails at connect
// time with a message that names neither.
func TestSecretRefKnowsWhichPayloadsAreJSON(t *testing.T) {
	for _, test := range []struct{ engine, wantProperty string }{
		{"postgres", "password"},
		{"documentdb", ""},
		{"valkey", ""},
		{"rabbitmq", ""},
	} {
		ref, ok := SecretRefFor(test.engine, Facts{SecretName: "shared-dev-" + test.engine + "/password"})
		if !ok {
			t.Fatalf("%s: a root that reports a secret must produce a reference", test.engine)
		}
		if ref.Property != test.wantProperty {
			t.Errorf("%s: Property = %q, want %q", test.engine, ref.Property, test.wantProperty)
		}
	}
}

// A stack that provisions no credential produces no reference, rather than one with
// empty fields that a consumer would try to read.
func TestSecretRefIsAbsentWithoutASecret(t *testing.T) {
	if _, ok := SecretRefFor("valkey", Facts{Endpoint: "h", Port: "6379"}); ok {
		t.Error("no secret was reported, so there is nothing to reference")
	}
}

// The reference carries the ADMIN identity, and the document must never carry a
// credential: this is the property that lets a consumer print the whole handoff.
func TestSecretRefCarriesTheAdminIdentityAndNoCredential(t *testing.T) {
	ref, _ := SecretRefFor("postgres", Facts{
		Endpoint: "db.rds.amazonaws.com", Port: "5432", Username: "postgres",
		SecretName: "shared-dev-postgres/password",
		SecretARN:  "arn:aws:secretsmanager:us-east-2:1:secret:shared-dev-postgres/password-ab",
	})
	if ref.AdminUsername != "postgres" {
		t.Errorf("AdminUsername = %q", ref.AdminUsername)
	}
	// Host and Port are repeated here because the bootstrap Jobs read them from
	// global.external*Definitions.connection, whose defaults are in-cluster names.
	if ref.Host != "db.rds.amazonaws.com" || ref.Port != "5432" {
		t.Errorf("the Job needs the connection too: %+v", ref)
	}

	document := Document{SecretRefs: []SecretRef{ref}}
	rendered, err := document.JSON()
	if err != nil {
		t.Fatal(err)
	}
	// Facts has no password field at all, so this asserts the shape stays that way.
	for _, forbidden := range []string{"password\":", "PASSWORD"} {
		if strings.Contains(string(rendered), forbidden) &&
			!strings.Contains(string(rendered), "shared-dev-postgres/password") {
			t.Errorf("the document must carry references, never credentials:\n%s", rendered)
		}
	}
	if !strings.Contains(string(rendered), "secret_refs") {
		t.Errorf("secret_refs missing from the envelope:\n%s", rendered)
	}
}

// Shared mode names the TIER's secret, and that is the whole point: the caller asks
// for midaz and gets the credential of whichever root actually owns the datastore.
func TestSecretRefFollowsTheOwnerInSharedMode(t *testing.T) {
	layout, product := sharedCheckout(t, SharedMode)

	terraform := newFakeTerraform()
	terraform.outputs["products/shared-resources/valkey"] = map[string]json.RawMessage{
		"endpoint":    raw("master.shared-dev-valkey.cache.amazonaws.com"),
		"port":        raw(6379),
		"secret_name": raw("shared-dev-valkey/auth-token"),
	}

	document, err := CollectHelmValuesFrom(context.Background(), terraform, layout,
		[]Unit{product}, Backend{}, "dev", Discard)
	if err != nil {
		t.Fatalf("CollectHelmValuesFrom: %v", err)
	}
	if len(document.SecretRefs) != 1 {
		t.Fatalf("expected one reference, got %+v", document.SecretRefs)
	}
	ref := document.SecretRefs[0]
	if ref.SecretName != "shared-dev-valkey/auth-token" {
		t.Errorf("SecretName = %q, want the tier's", ref.SecretName)
	}
	// Valkey authenticates with a token and no user, so there is no admin identity to
	// report — and an empty string here must not be rendered as a nameless user.
	if ref.AdminUsername != "" {
		t.Errorf("valkey has no admin username: %q", ref.AdminUsername)
	}
	if strings.Contains(string(mustJSON(t, document)), "admin_username") {
		t.Error("an empty admin_username must be omitted, not rendered blank")
	}
}

func mustJSON(t *testing.T, d Document) []byte {
	t.Helper()
	b, err := d.JSON()
	if err != nil {
		t.Fatal(err)
	}
	return b
}
