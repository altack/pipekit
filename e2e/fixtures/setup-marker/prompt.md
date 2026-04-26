# Pipekit task: setup-marker

You are running an e2e test that verifies the recipe's `setup.shell` ran successfully before you started.

## Procedure

1. Read `/tmp/pipekit-marker` using the Bash tool. It must contain the string `marker-from-setup`.
2. Write `${PIPEKIT_WORKSPACE}/result.json`:
   - If the file exists and contains the expected string:
     ```json
     { "status": "pass",
       "summary": "setup.shell ran; marker found",
       "outputs": { "marker": "marker-from-setup" } }
     ```
   - Otherwise:
     ```json
     { "status": "fail",
       "summary": "setup marker missing or wrong contents",
       "outputs": {} }
     ```
3. Exit.

## Constraints

- Use only Bash and Write tools.
- Finish in fewer than 5 turns.
- Do not produce findings.
