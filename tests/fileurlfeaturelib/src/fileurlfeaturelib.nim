when defined(features.fileurlfeaturelib.extra):
  echo "extra is enabled"
  import stew/byteutils
else:
  echo "extra is disabled"
