# This is just an example to get you started. A typical library package
# exports the main API in this file. Note that you cannot rename this file
# but you can remove it if you wish.

proc add*(x, y: int): int =
  ## Adds two numbers together.
  return x + y



when defined(features.features.feature1):
  echo "feature1 is enabled"
  import stew/byteutils #we should be able to import stew here as is its part of the feature1
  
else:
  echo "feature1 is disabled"



when defined(features.result.resultfeature):
 echo "resultfeature is enabled"
else:
 echo "resultfeature is disabled"


when defined(features.features.dev):
  echo "dev is enabled"
  import unittest
else:
  echo "dev is disabled"



echo ""
