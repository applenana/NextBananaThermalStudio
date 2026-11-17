Portable CB360 core copied without algorithm changes from RP2040-CB360 commit d076c06f206561a33a9f18db10f7d0722863c68a.

The C ABI wrapper accepts already NUC-corrected Y16. Never apply NUC again.
Keep core sources and golden fixtures in sync when updating firmware algorithms.

`cb360_temperature_lut` evaluates the same `photoTemperature` function for every
signed 16-bit input. Its 65536 centi-C entries are indexed by Y16 + 32768 and used
by the streaming worker. Display enhancement does not replace the source data.
