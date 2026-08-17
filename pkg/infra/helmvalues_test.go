package infra

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func outputs(pairs map[string]string) map[string]json.RawMessage {
	raw := make(map[string]json.RawMessage, len(pairs))
	for name, value := range pairs {
		raw[name] = json.RawMessage(value)
	}
	return raw
}

// The flat shape: most products emit one map of chart environment variables per
// service, and the product's document is their union.
func TestCollectHelmValuesMergesTheServicesOfAProduct(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.outputs["products/midaz/postgres"] = outputs(map[string]string{
		"helm_values": `{"DB_ONBOARDING_HOST":"pg.internal","DB_ONBOARDING_PORT":"5432"}`,
	})
	terraform.outputs["products/midaz/valkey"] = outputs(map[string]string{
		"helm_values": `{"REDIS_HOST":"valkey.internal:6379","REDIS_TLS":"true"}`,
	})

	document, err := CollectHelmValues(context.Background(), terraform,
		units("products/midaz/postgres", "products/midaz/valkey"), Backend{}, "dev", nil)
	if err != nil {
		t.Fatalf("CollectHelmValues: %v", err)
	}

	want := map[string]string{
		"DB_ONBOARDING_HOST": "pg.internal",
		"DB_ONBOARDING_PORT": "5432",
		"REDIS_HOST":         "valkey.internal:6379",
		"REDIS_TLS":          "true",
	}
	for key, value := range want {
		if got := document.Values[key]; got != value {
			t.Errorf("Values[%q] = %v, want %q", key, got, value)
		}
	}
	if len(document.Values) != len(want) {
		t.Errorf("got %d keys, want %d: %v", len(document.Values), len(want), document.Values)
	}
}

// The nested shape: plugin-br-pix-indirect-btg keys its handoff by chart
// component, and each entry belongs to that component's own configmap. Flattening
// it would put a Mongo host in the wrong deployment.
func TestCollectHelmValuesPreservesTheComponentNesting(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.outputs["products/plugin-br-pix-indirect-btg/postgres"] = outputs(map[string]string{
		"helm_values": `{
			"pix":     {"DB_HOST":"pg.internal","DB_PORT":"5432"},
			"inbound": {"DB_HOST":"pg.internal","DB_PORT":"5432"}
		}`,
	})
	terraform.outputs["products/plugin-br-pix-indirect-btg/valkey"] = outputs(map[string]string{
		// The same chart wants two different REDIS_HOST shapes: pix takes a bare host
		// with its own REDIS_PORT, reconciliation folds the port into the host.
		"helm_values": `{
			"pix":            {"REDIS_HOST":"valkey.internal","REDIS_PORT":"6379"},
			"reconciliation": {"REDIS_HOST":"valkey.internal:6379"}
		}`,
	})

	document, err := CollectHelmValues(context.Background(), terraform,
		units("products/plugin-br-pix-indirect-btg/postgres",
			"products/plugin-br-pix-indirect-btg/valkey"), Backend{}, "dev", nil)
	if err != nil {
		t.Fatalf("CollectHelmValues: %v", err)
	}

	pix, ok := document.Values["pix"].(map[string]any)
	if !ok {
		t.Fatalf("Values[pix] = %#v, want a nested object", document.Values["pix"])
	}
	if pix["DB_HOST"] != "pg.internal" || pix["REDIS_HOST"] != "valkey.internal" {
		t.Errorf("pix = %v, want the postgres and valkey keys merged into one component", pix)
	}

	reconciliation, ok := document.Values["reconciliation"].(map[string]any)
	if !ok {
		t.Fatalf("Values[reconciliation] = %#v, want a nested object", document.Values["reconciliation"])
	}
	if reconciliation["REDIS_HOST"] != "valkey.internal:6379" {
		t.Errorf("reconciliation REDIS_HOST = %v, want the host:port form; the two components "+
			"take deliberately different shapes", reconciliation["REDIS_HOST"])
	}
	if _, hasPort := reconciliation["REDIS_PORT"]; hasPort {
		t.Error("reconciliation gained a REDIS_PORT it must not have")
	}
}

// The third shape: dotted Helm value paths. They are opaque keys, not a nesting
// instruction — splitting them would build the wrong document.
func TestCollectHelmValuesKeepsDottedPathsWhole(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.outputs["products/plugin-br-pix-switch/postgres"] = outputs(map[string]string{
		"helm_values": `{"global.externalPostgresDefinitions.connection.host":"pg.internal"}`,
	})

	document, err := CollectHelmValues(context.Background(), terraform,
		units("products/plugin-br-pix-switch/postgres"), Backend{}, "dev", nil)
	if err != nil {
		t.Fatalf("CollectHelmValues: %v", err)
	}
	if document.Values["global.externalPostgresDefinitions.connection.host"] != "pg.internal" {
		t.Errorf("Values = %v, want the dotted key intact", document.Values)
	}
}

// A conflict is the case the whole merge exists for: two services claiming the
// same chart key with different values means one of them is wrong, and picking
// either at random ships a release pointed at the wrong host.
func TestCollectHelmValuesRefusesToResolveAConflict(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.outputs["products/midaz/postgres"] = outputs(map[string]string{
		"helm_values": `{"pix":{"DB_HOST":"pg-a.internal"}}`,
	})
	terraform.outputs["products/midaz/valkey"] = outputs(map[string]string{
		"helm_values": `{"pix":{"DB_HOST":"pg-b.internal"}}`,
	})

	_, err := CollectHelmValues(context.Background(), terraform,
		units("products/midaz/postgres", "products/midaz/valkey"), Backend{}, "dev", nil)
	if !errors.Is(err, ErrValuesConflict) {
		t.Fatalf("error = %v, want ErrValuesConflict", err)
	}
	// The path is what makes the error actionable: the operator has to know which
	// key, not just that something clashed.
	for _, want := range []string{"pix.DB_HOST", "pg-a.internal", "pg-b.internal"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error is missing %q:\n%s", want, err)
		}
	}
}

func TestCollectHelmValuesAcceptsTheSameKeyWithTheSameValue(t *testing.T) {
	// Two services of a product legitimately emit the same key: the RDS endpoint
	// shows up in every component that talks to it.
	terraform := newFakeTerraform()
	terraform.outputs["products/midaz/postgres"] = outputs(map[string]string{
		"helm_values": `{"DB_HOST":"pg.internal"}`,
	})
	terraform.outputs["products/midaz/documentdb"] = outputs(map[string]string{
		"helm_values": `{"DB_HOST":"pg.internal","MONGO_HOST":"docdb.internal"}`,
	})

	document, err := CollectHelmValues(context.Background(), terraform,
		units("products/midaz/postgres", "products/midaz/documentdb"), Backend{}, "dev", nil)
	if err != nil {
		t.Fatalf("CollectHelmValues: %v", err)
	}
	if document.Values["MONGO_HOST"] != "docdb.internal" {
		t.Errorf("Values = %v", document.Values)
	}
}

func TestCollectHelmValuesSeparatesTheSecretValues(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.outputs["products/notifications/valkey"] = outputs(map[string]string{
		"helm_values":        `{"REDIS_HOST":"valkey.internal"}`,
		"helm_secret_values": `{"REDIS_TLS":"true"}`,
	})

	document, err := CollectHelmValues(context.Background(), terraform,
		units("products/notifications/valkey"), Backend{}, "dev", nil)
	if err != nil {
		t.Fatalf("CollectHelmValues: %v", err)
	}
	if document.SecretValues["REDIS_TLS"] != "true" {
		t.Errorf("SecretValues = %v, want REDIS_TLS", document.SecretValues)
	}
	if _, leaked := document.Values["REDIS_TLS"]; leaked {
		t.Error("a helm_secret_values key ended up in helm_values")
	}
}

// Thirteen roots emit an empty helm_values on purpose, and some emit none at all.
// Neither is a failure: the product still deploys with what its siblings produced.
func TestCollectHelmValuesWarnsRatherThanFailingOnARootWithoutTheOutput(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.outputs["products/matcher/postgres"] = outputs(map[string]string{
		"endpoint": `"pg.internal"`,
	})
	terraform.outputs["products/matcher/valkey"] = outputs(map[string]string{
		"helm_values": `{"REDIS_HOST":"valkey.internal"}`,
	})
	progress := &recordingProgress{}

	document, err := CollectHelmValues(context.Background(), terraform,
		units("products/matcher/postgres", "products/matcher/valkey"), Backend{}, "dev", progress)
	if err != nil {
		t.Fatalf("CollectHelmValues: %v", err)
	}
	if document.Values["REDIS_HOST"] != "valkey.internal" {
		t.Errorf("Values = %v", document.Values)
	}
	if !progress.sawStatus("products/matcher/postgres", StatusWarn) {
		t.Errorf("the root without helm_values was not reported as a warning: %v", progress.updates)
	}
	if progress.failed {
		t.Error("the run was marked failed over a missing output")
	}
}

func TestDocumentYAMLQuotesEveryLeaf(t *testing.T) {
	document := Document{Values: map[string]any{
		"DB_PORT":    "5432",
		"REDIS_TLS":  "true",
		"pix":        map[string]any{"MONGO_HOST": "docdb.internal"},
		"global.a.b": "dotted",
	}}

	rendered, err := document.YAML()
	if err != nil {
		t.Fatalf("YAML: %v", err)
	}
	got := string(rendered)

	// A ConfigMap value that reaches Helm as an int or a bool fails the template,
	// so a port and a flag are quoted like everything else.
	for _, want := range []string{
		"  DB_PORT: \"5432\"",
		"  REDIS_TLS: \"true\"",
		"  global.a.b: \"dotted\"", // a dotted key needs no quoting of its own
		"  pix:\n    MONGO_HOST: \"docdb.internal\"",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("YAML is missing:\n%s\ngot:\n%s", want, got)
		}
	}
	if !strings.HasPrefix(got, "helm_values:\n") {
		t.Errorf("YAML should open with the helm_values envelope, got:\n%s", got)
	}
}

func TestDocumentOmitsHelmSecretValuesWhenThereAreNone(t *testing.T) {
	document := Document{Values: map[string]any{"DB_HOST": "pg.internal"}}

	rendered, err := document.JSON()
	if err != nil {
		t.Fatalf("JSON: %v", err)
	}
	if strings.Contains(string(rendered), helmSecretValuesOutput) {
		t.Errorf("JSON carries an empty helm_secret_values:\n%s", rendered)
	}
}

func TestDocumentRendersDeterministically(t *testing.T) {
	// Go map iteration is random; two runs of the same product must still produce
	// the same file, or every regeneration looks like a change.
	document := Document{Values: map[string]any{
		"Z": "1", "A": "2", "M": map[string]any{"c": "3", "a": "4"},
	}}

	first, err := document.YAML()
	if err != nil {
		t.Fatalf("YAML: %v", err)
	}
	for i := 0; i < 20; i++ {
		again, err := document.YAML()
		if err != nil {
			t.Fatalf("YAML: %v", err)
		}
		if string(again) != string(first) {
			t.Fatalf("render %d differs:\n%s\nvs\n%s", i, again, first)
		}
	}
}

func TestCollectHelmValuesReportsAStackThatWasNeverApplied(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.failures["init products/midaz/postgres"] = errors.New("Backend configuration changed")
	progress := &recordingProgress{}

	_, err := CollectHelmValues(context.Background(), terraform,
		units("products/midaz/postgres"), Backend{}, "dev", progress)
	if err == nil {
		t.Fatal("CollectHelmValues succeeded over a failing init")
	}
	if !progress.failed {
		t.Error("the run was not marked failed")
	}
}

func TestCollectHelmValuesRejectsAnOutputThatIsNotAnObject(t *testing.T) {
	// A root that emits helm_values as a string or a list would silently produce a
	// document the chart cannot consume.
	terraform := newFakeTerraform()
	terraform.outputs["products/midaz/postgres"] = outputs(map[string]string{
		"helm_values": `"pg.internal"`,
	})

	_, err := CollectHelmValues(context.Background(), terraform,
		units("products/midaz/postgres"), Backend{}, "dev", nil)
	if err == nil {
		t.Fatal("CollectHelmValues accepted a scalar helm_values")
	}
	if !strings.Contains(err.Error(), "is not an object") {
		t.Errorf("error = %q", err)
	}
}

func TestCollectHelmValuesIgnoresANullOutput(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.outputs["products/midaz/postgres"] = outputs(map[string]string{
		"helm_values":        `{"DB_HOST":"pg.internal"}`,
		"helm_secret_values": `null`,
	})

	document, err := CollectHelmValues(context.Background(), terraform,
		units("products/midaz/postgres"), Backend{}, "dev", nil)
	if err != nil {
		t.Fatalf("CollectHelmValues: %v", err)
	}
	if document.SecretValues != nil {
		t.Errorf("SecretValues = %v, want nil", document.SecretValues)
	}
}
