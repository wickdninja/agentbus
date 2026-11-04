"""A small JSON Schema subset validator for the tests (standard library only), so they need no third-party package.

The subset is what `agentbus schema --json` uses: type (a name or a list of names), required, properties, items,
enum, anyOf, allOf, minimum, $ref of the form "#/objects/NAME" resolved against the schema document's `objects`, and
description (ignored). Extra object keys are allowed: JSON changes are additive within contract version 1.

    from schema_check import validate, check_schema
    errors = validate(instance, schema, objects)      # [] when valid, else strings that say where
    problems = check_schema(schema, objects)          # [] when the schema itself uses only the subset
"""
TYPES = ("string", "integer", "number", "boolean", "null", "object", "array")
KEYWORDS = {"type", "required", "properties", "items", "enum", "anyOf", "allOf", "minimum", "$ref", "description"}


def _is(value, name):
    if name == "string":
        return isinstance(value, str)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "null":
        return value is None
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    return False


def _resolve(ref, objects):
    prefix = "#/objects/"
    if not ref.startswith(prefix) or ref[len(prefix):] not in objects:
        return None
    return objects[ref[len(prefix):]]


def validate(instance, schema, objects, path="$"):
    """Errors (strings) for instance against schema; [] when it is valid."""
    errors = []
    if "$ref" in schema:
        target = _resolve(schema["$ref"], objects)
        if target is None:
            return ["%s: unknown $ref %s" % (path, schema["$ref"])]
        return validate(instance, target, objects, path)
    if "anyOf" in schema:
        branches = [validate(instance, s, objects, path) for s in schema["anyOf"]]
        if not any(not b for b in branches):
            return ["%s: matches none of the anyOf branches (%s)" % (path, "; ".join(b[0] for b in branches if b))]
    if "allOf" in schema:  # every branch must hold (a shared object plus the keys every result adds)
        for s in schema["allOf"]:
            errors += validate(instance, s, objects, path)
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is(instance, n) for n in names):
            return ["%s: %s is not of type %s" % (path, type(instance).__name__, "|".join(names))]
    if "enum" in schema and instance not in schema["enum"]:
        errors.append("%s: %r is not one of %r" % (path, instance, schema["enum"]))
    if "minimum" in schema and _is(instance, "number") and instance < schema["minimum"]:
        errors.append("%s: %r is below the minimum %r" % (path, instance, schema["minimum"]))
    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append("%s: missing required key %r" % (path, key))
        for key, sub in schema.get("properties", {}).items():
            if key in instance:
                errors += validate(instance[key], sub, objects, "%s.%s" % (path, key))
    if isinstance(instance, list) and "items" in schema:
        for i, item in enumerate(instance):
            errors += validate(item, schema["items"], objects, "%s[%d]" % (path, i))
    return errors


def check_schema(schema, objects, path="$"):
    """Problems (strings) with the schema itself: a keyword outside the subset, an unknown type or $ref."""
    problems = []
    if not isinstance(schema, dict):
        return ["%s: a schema must be an object" % path]
    for key in schema:
        if key not in KEYWORDS:
            problems.append("%s: keyword %r is outside the supported subset" % (path, key))
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        problems += ["%s: unknown type %r" % (path, n) for n in names if n not in TYPES]
    if "$ref" in schema and _resolve(schema["$ref"], objects) is None:
        problems.append("%s: unknown $ref %s" % (path, schema["$ref"]))
    for key, sub in schema.get("properties", {}).items():
        problems += check_schema(sub, objects, "%s.%s" % (path, key))
    for key in schema.get("required", []):
        if key not in schema.get("properties", {}):
            problems.append("%s: required key %r has no property schema" % (path, key))
    if "items" in schema:
        problems += check_schema(schema["items"], objects, path + "[]")
    for i, sub in enumerate(schema.get("anyOf", [])):
        problems += check_schema(sub, objects, "%s|%d" % (path, i))
    for i, sub in enumerate(schema.get("allOf", [])):
        problems += check_schema(sub, objects, "%s&%d" % (path, i))
    return problems
