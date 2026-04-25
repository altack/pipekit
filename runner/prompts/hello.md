# Pipekit task: hello

You are running a smoke test of the Pipekit agent contract. Do exactly what is described below and nothing more.

## Procedure

1. Read `${PIPEKIT_WORKSPACE}/inputs.json`. The schema is `{ "name"?: string, "fail"?: boolean }`. Either field may be absent.
2. If `inputs.fail === true`, write the **fail** result below and exit.
3. Otherwise, write the **pass** result, substituting `<name>` with `inputs.name` (or `"world"` if absent).

## Pass result

Write to `${PIPEKIT_WORKSPACE}/result.json`:

```json
{
  "status": "pass",
  "summary": "Hello, <name>",
  "outputs": {
    "greeting": "Hello, <name>",
    "input_name": "<name as read from inputs, or null if absent>"
  }
}
```

## Fail result (when `inputs.fail === true`)

```json
{
  "status": "fail",
  "summary": "Smoke test asked to fail",
  "outputs": {}
}
```

## Constraints

- Use only the Bash and Write tools. Do not call WebFetch, do not start a browser, do not install anything.
- Finish in fewer than 5 turns. This is a smoke test, not a real task.
- Do not produce findings.
- Do not author additional fields. Match the schemas exactly.
