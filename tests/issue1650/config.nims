# This config.nims simulates a project (like libp2p) that sets strict options.
# It should NOT leak into dependency builds during `nimble install`.
switch("define", "issue1650_config_leaked")
