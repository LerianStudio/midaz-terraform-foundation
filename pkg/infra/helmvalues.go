package infra

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"regexp"
	"sort"
	"strings"
)

// helmValuesOutput and helmSecretValuesOutput are the two outputs a service root
// exposes for the Helm handoff. The second exists because a few charts route a
// non-credential key — REDIS_TLS, RABBITMQ_DEFAULT_USER — through .Values.secrets
// rather than .Values.config.
const (
	helmValuesOutput       = "helm_values"
	helmSecretValuesOutput = "helm_secret_values"
)

// ErrValuesConflict is returned when two services of the same product emit the
// same chart key with different values.
var ErrValuesConflict = errors.New("infra: conflicting helm value")

// Document is the merged Helm handoff of one product.
type Document struct {
	// Values is the merge of every service's helm_values.
	Values map[string]any
	// SecretValues is the merge of every service's helm_secret_values, and is nil
	// when no service of the product exposes one.
	SecretValues map[string]any
}

// CollectHelmValues reads the Helm handoff of every unit and merges it.
//
// A product's outputs live in one state file per service, so this is what turns N
// states back into the one document a chart is installed with. The merge is deep,
// which is what makes both shapes in the repository work through the same code: a
// flat map of environment variables, and a map keyed by chart component whose
// entries merge into that component's own configmap block. Keys that happen to
// contain dots — the dotted Helm value paths a third shape emits — are opaque
// here and stay whole.
//
// A key emitted twice with two different values is a hard error naming the path,
// never a silent last-one-wins: a chart pointed at the wrong host fails in
// production, not here.
func CollectHelmValues(
	ctx context.Context,
	terraform Terraform,
	units []Unit,
	backend Backend,
	env string,
	progress Progress,
) (Document, error) {
	report := progressOr(progress)

	names := make([]string, 0, len(units))
	for _, unit := range units {
		names = append(names, unit.Name)
	}
	report.Start(names)

	document := Document{Values: map[string]any{}}
	secrets := map[string]any{}

	for _, unit := range units {
		report.Update(unit.Name, StatusRunning, "lendo os outputs...", "")

		// Read-only, but still an init: the state lives in S3 and the working
		// directory may hold another environment's backend.
		if err := terraform.Init(ctx, unit, initOptionsFor(unit, backend, env)); err != nil {
			report.Update(unit.Name, StatusFail, err.Error(),
				"Confirme que este stack já foi aplicado neste ambiente.")
			report.Finish(true)
			return Document{}, err
		}

		outputs, err := terraform.Output(ctx, unit)
		if err != nil {
			report.Update(unit.Name, StatusFail, err.Error(),
				"Confirme que este stack já foi aplicado neste ambiente.")
			report.Finish(true)
			return Document{}, err
		}

		values, hasValues, err := decodeObject(unit, helmValuesOutput, outputs)
		if err != nil {
			report.Update(unit.Name, StatusFail, err.Error(), "")
			report.Finish(true)
			return Document{}, err
		}
		if !hasValues {
			report.Update(unit.Name, StatusWarn,
				fmt.Sprintf("%s não expõe o output %s — ignorado.", unit.Name, helmValuesOutput),
				"Se este serviço deveria contribuir com chaves do chart, adicione o output ao root.")
		} else if err := mergeInto(document.Values, values, nil); err != nil {
			wrapped := conflictError(unit, helmValuesOutput, err)
			report.Update(unit.Name, StatusFail, wrapped.Error(),
				"Corrija os outputs, ou agregue os serviços separadamente.")
			report.Finish(true)
			return Document{}, wrapped
		}

		secretValues, hasSecrets, err := decodeObject(unit, helmSecretValuesOutput, outputs)
		if err != nil {
			report.Update(unit.Name, StatusFail, err.Error(), "")
			report.Finish(true)
			return Document{}, err
		}
		if hasSecrets {
			if err := mergeInto(secrets, secretValues, nil); err != nil {
				wrapped := conflictError(unit, helmSecretValuesOutput, err)
				report.Update(unit.Name, StatusFail, wrapped.Error(), "")
				report.Finish(true)
				return Document{}, wrapped
			}
		}

		if hasValues {
			report.Update(unit.Name, StatusOK,
				fmt.Sprintf("%d chave(s).", len(values)), "")
		}
	}

	if len(secrets) > 0 {
		document.SecretValues = secrets
	}
	report.Finish(false)
	return document, nil
}

func conflictError(unit Unit, output string, err error) error {
	return fmt.Errorf("%w: %s from %s conflicts with a sibling service\n%s\n\n"+
		"Two services of this product emit the same chart key with different values.\n"+
		"Merging them silently would point the release at one of the two at random.\n"+
		"Fix the outputs, or aggregate the services separately.",
		ErrValuesConflict, output, unit.Name, err)
}

func decodeObject(unit Unit, name string, outputs map[string]json.RawMessage) (map[string]any, bool, error) {
	raw, ok := outputs[name]
	if !ok || len(raw) == 0 || string(raw) == "null" {
		return nil, false, nil
	}
	var object map[string]any
	if err := json.Unmarshal(raw, &object); err != nil {
		return nil, false, fmt.Errorf("infra: output %s of %s is not an object: %w", name, unit.Name, err)
	}
	return object, true, nil
}

// mergeInto deep-merges source into destination. path is the key trail used to
// name a conflict, and is nil at the top level.
func mergeInto(destination, source map[string]any, path []string) error {
	keys := make([]string, 0, len(source))
	for key := range source {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		incoming := source[key]
		existing, seen := destination[key]
		if !seen {
			destination[key] = incoming
			continue
		}

		// A fresh slice rather than append(path, key): the appended trail outlives
		// this iteration in the error message, and reusing the caller's backing
		// array would let the next sibling overwrite the key being reported.
		trail := make([]string, 0, len(path)+1)
		trail = append(trail, path...)
		trail = append(trail, key)

		existingObject, existingIsObject := existing.(map[string]any)
		incomingObject, incomingIsObject := incoming.(map[string]any)
		if existingIsObject && incomingIsObject {
			if err := mergeInto(existingObject, incomingObject, trail); err != nil {
				return err
			}
			continue
		}

		if reflect.DeepEqual(existing, incoming) {
			continue
		}
		return fmt.Errorf("CONFLICT at %s: %s vs %s",
			strings.Join(trail, "."), scalar(existing), scalar(incoming))
	}
	return nil
}

// JSON renders the document the way --format json does: helm_values, and
// helm_secret_values only when some service produced one.
func (d Document) JSON() ([]byte, error) {
	buffer := &bytes.Buffer{}
	encoder := json.NewEncoder(buffer)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(d.envelope()); err != nil {
		return nil, fmt.Errorf("infra: cannot render the helm values as JSON: %w", err)
	}
	return buffer.Bytes(), nil
}

func (d Document) envelope() map[string]any {
	values := d.Values
	if values == nil {
		values = map[string]any{}
	}
	envelope := map[string]any{helmValuesOutput: values}
	if len(d.SecretValues) > 0 {
		envelope[helmSecretValuesOutput] = d.SecretValues
	}
	return envelope
}

// bareYAMLKey matches the keys that need no quoting. Dots are in the set on
// purpose: one of the output shapes is a dotted Helm value path, and quoting it
// would be noise.
var bareYAMLKey = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_.-]*$`)

// YAML renders the document for `--format yaml`.
//
// Every leaf is emitted as a double-quoted string, including numbers and booleans.
// That is not cosmetic: these values are destined for a ConfigMap, and an unquoted
// 5432 or true reaches Helm as an int or a bool and fails the template.
//
// Keys are sorted. The shell version emitted them in whatever order jq parsed
// them, which made two runs of the same product produce two different files.
func (d Document) YAML() ([]byte, error) {
	buffer := &bytes.Buffer{}
	if err := writeYAML(buffer, d.envelope(), ""); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

func writeYAML(buffer *bytes.Buffer, object map[string]any, indent string) error {
	keys := make([]string, 0, len(object))
	for key := range object {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		rendered := key
		if !bareYAMLKey.MatchString(key) {
			quoted, err := json.Marshal(key)
			if err != nil {
				return fmt.Errorf("infra: cannot render the key %q: %w", key, err)
			}
			rendered = string(quoted)
		}
		if nested, ok := object[key].(map[string]any); ok {
			buffer.WriteString(indent + rendered + ":\n")
			if err := writeYAML(buffer, nested, indent+"  "); err != nil {
				return err
			}
			continue
		}
		quoted, err := json.Marshal(scalar(object[key]))
		if err != nil {
			return fmt.Errorf("infra: cannot render the value of %q: %w", key, err)
		}
		buffer.WriteString(indent + rendered + ": " + string(quoted) + "\n")
	}
	return nil
}

// scalar is the string form of a leaf. Terraform emits every one of these as a
// string already; the other cases exist so a root that forgets a tostring() still
// produces a usable document instead of a panic.
func scalar(value any) string {
	switch typed := value.(type) {
	case nil:
		return "null"
	case string:
		return typed
	case bool:
		if typed {
			return "true"
		}
		return "false"
	case float64:
		return strings.TrimSuffix(strings.TrimRight(fmt.Sprintf("%f", typed), "0"), ".")
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return fmt.Sprintf("%v", typed)
		}
		return string(encoded)
	}
}
