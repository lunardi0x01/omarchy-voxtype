# whisper-server-vulkan

A local Arch package for whisper.cpp's `whisper-server`, built with Vulkan, so
an AMD (or any Vulkan) GPU can serve Voxtype in remote mode. No package in the
Arch repos or the AUR ships `whisper-server`, hence this recipe.

- Build and install: `makepkg -si` (make-deps: `cmake ninja git vulkan-headers
  spirv-headers shaderc`).
- Update: bump `pkgver` to the new whisper.cpp tag and run `makepkg -si` again.
- It builds one self-contained `/usr/bin/whisper-server` (static whisper and
  ggml; only the system Vulkan loader is needed) and its licence file.
- Run it with `../systemd/whisper-server.service`; see `../README.md`.
