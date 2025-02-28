# This is just an example to get you started. A typical binary package
# uses this file as the main entry point of the application.

when isMainModule:
  echo("Hello, World!")


when defined(features.features_deps.ver1):
  echo "Feature ver1 activated"

when defined(features.features_deps.ver2):
  echo "Feature ver2 activated"

when defined(features.featurestest.feature1):
  echo "Feature1 activated"
else:
  echo "Feature1 deactivated"

echo ""