## Binary for issue1650dep package.
## If the parent project's config.nims leaks into this build,
## `issue1650_config_leaked` will be defined and compilation will fail.

when defined(issue1650_config_leaked):
  {.error: "Parent project config.nims leaked into dependency build! (issue #1650)".}

echo "issue1650dep built successfully"
