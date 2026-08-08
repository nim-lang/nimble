---
name: docker-test
description: Run Nimble tests in Docker. Use when testing in Linux, reproducing issues in clean environments, or verifying changes work cross-platform.
tools: Bash, Read, Glob
model: openai/gpt-5.4
---

# Docker Test Runner

Run the Nimble test suite in a clean Linux Docker environment.

## Build and Run Tests

```bash
docker build -f tests/Dockerfile.debug -t nimble-debug . && docker run --rm nimble-debug
```

## What to Report

After tests complete, provide:

1. **Summary**: Total passed/failed count
2. **Failed Tests**: List any failures with their names
3. **Relevant Output**: Key error messages for failures

## Running Specific Tests

If asked to run specific tests, edit `tests/Dockerfile.debug` CMD line first:
- Full suite: `CMD ["./src/nimble", "test"]`
- Specific suite: `CMD ["./src/nimble", "test", "lock file::"]`
- Specific test: `CMD ["./src/nimble", "test", "issues::issue #1251"]`

## Parsing Results

Look for these patterns in output:
- `[OK]` - Test passed
- `[FAILED]` - Test failed
- `[Suite]` - Test suite name

Count results:
```bash
grep -c "^\s\+\[OK\]" output.txt      # Passed count
grep -c "^\s\+\[FAILED\]" output.txt  # Failed count
grep "^\s\+\[FAILED\]" output.txt     # List failures
```

## Force Clean Rebuild

If caching issues suspected:
```bash
docker build --no-cache -f tests/Dockerfile.debug -t nimble-debug .
```
