# Package

version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["features_deps"]


# Dependencies

requires "nim"

feature "ver1":
  requires "https://github.com/jmgomez/FeatureActivation == 1.0.1" #activates Feature1 in FeatureTest via FeaturesActivation's require

feature "ver2":
  requires "https://github.com/jmgomez/FeatureActivation >= 2.0.2" #doesnt activate Feature1 in FeatureTest
