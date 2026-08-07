---
name: docker-test
description: Test Nimble in Docker. Use when running tests in Linux, reproducing issues in clean environments, or testing in isolated Docker containers.
allowed-tools: Bash, Read, Glob
---

# Testing Nimble in Docker

Build and run tests:
```bash
docker build -f tests/Dockerfile.debug -t nimble-debug . && docker run --rm nimble-debug
```

## Run specific tests

Edit `tests/Dockerfile.debug` CMD line:
- Full suite: `CMD ["./src/nimble", "test"]`
- Specific test: `CMD ["./src/nimble", "test", "lock file::"]`
- Issue test: `CMD ["./src/nimble", "test", "issues::issue #1251"]`

## Compare with master

1. Stash changes: `git stash`
2. Checkout master: `git checkout master`
3. Build: `docker build -f tests/Dockerfile.debug -t nimble-master .`
4. Run: `docker run --rm nimble-master`
5. Return: `git checkout nim_lock && git stash pop`

## Force clean rebuild

```bash
docker build --no-cache -f tests/Dockerfile.debug -t nimble-debug .
```

## Interactive debugging

```bash
docker run -it --rm nimble-debug bash
```
