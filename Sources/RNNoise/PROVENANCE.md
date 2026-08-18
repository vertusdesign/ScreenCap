# RNNoise provenance

- Upstream project: https://github.com/xiph/rnnoise
- Upstream commit: `70f1d256acd4b34a572f999a05c87bf00b67730d`
- Model variant: `rnnoise_data_little.c`
- Model SHA-256: `0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37`
- License: BSD-3-Clause-style license in `LICENSE`.

The model is compiled into the application. The recorder does not download a
model or contact the network at runtime.

The universal macOS build intentionally uses RNNoise's portable x86 path. The
upstream source emits a compile-time warning when SSSE3/AVX dispatch is not
enabled; this is a performance advisory only, so the warning directive is
replaced by a source comment without changing the generated processing path.
