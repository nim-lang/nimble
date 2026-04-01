import fileurlfeaturelib

when defined(features.fileurlfeaturelib.extra):
  echo "consumer sees extra enabled"
else:
  echo "consumer sees extra disabled"

echo "done"
