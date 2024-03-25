import std/[os, strformat]

const
  binDir = when defined(windows): "Scripts" else: "bin"
  python = toExe("python")
  pip = ".venv" / binDir / toExe("pip")
  mkdocs = ".venv" / binDir / toExe("mkdocs")

task bootstrap, "set up mkdocs":
  exec fmt"{python} -m venv .venv"
  exec fmt"{pip} install -r requirements.txt"

proc ensureMkdocs() =
  if not fileExists mkdocs:
    echo "no mkdocs found, generating local venv"
    bootstrapTask()

task serve, "serve guide w/mkdocs":
  ensureMkdocs()
  exec fmt"{mkdocs} serve"

task build, "build guide w/mkdocs":
  ensureMkdocs()
  exec fmt"{mkdocs} build"

