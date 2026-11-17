# Toolchain para compilar el motor de Kalamar (Splatoon 3 nativo) en esta PC.
#
# Kalamar publica solo Windows, pero su rama Linux (engine/docs/building.md,
# "Linux (in progress)") compila con el clang, lld y ninja que encuentre en el
# PATH y enlaza contra las bibliotecas del sistema: Vulkan, SDL3, Opus, libvpx y
# zstd. El traductor de shaders (`totk_xlate`) se publica con NativeAOT y exige
# el SDK de .NET 10; hactool se compila con `cc` + make.
#
# En NixOS no existen /usr/include ni /usr/lib, que es donde build_game.py los
# busca, así que además de los paquetes el módulo publica `kalamar-engine`: una
# shell con CPATH, LIBRARY_PATH y LD_LIBRARY_PATH apuntando a los outputs de
# nixpkgs. El build manual se lanza dentro de esa shell.
#
# Es una capacidad de este host y no del módulo compartido: la laptop no compila
# el motor. Sin pins: todo sale de nixpkgs y lo avanza `rebuild update`; las
# versiones de los entornos de Python las fija el propio proyecto en
# engine/tools/requirements*.txt. Nada de esto deriva del juego.
{ config, pkgs, lib, ... }:

let
  # Dependencias del motor: build_game.py enlaza -lvulkan -lSDL3 -lopus -lvpx
  # -lzstd, y el runtime importa libvulkan.so.1 / libSDL3.so.0.
  engineDeps = with pkgs; [
    vulkan-headers # include/vulkan
    vulkan-loader # libvulkan.so y .so.1
    vulkan-memory-allocator # include/vk_mem_alloc.h, que build_game.py busca en /usr/include
    vulkan-validation-layers
    sdl3 # include/SDL3 y libSDL3.so
    opus
    libvpx
    zstd
    shaderc
    spirv-tools
  ];

  # Directorios de headers (los `.dev` cuando existen) y de bibliotecas.
  includeDirs = lib.concatMapStringsSep ":" (p: "${lib.getDev p}/include") engineDeps;
  libDirs = lib.concatMapStringsSep ":" (p: "${lib.getLib p}/lib") engineDeps;
in
{
  environment.systemPackages = with pkgs; [
    # Compilador del código generado y del runtime (-march=x86-64-v3, que este
    # Ryzen 5700X soporta: AVX2 y FMA) y enlazador lld (-fuse-ld=lld, -no-pie,
    # rpath $ORIGIN). gcc viene de base y compila hactool con gnumake.
    llvmPackages_latest.clang
    llvmPackages_latest.lld
    binutils
    ninja
    gnumake
    pkg-config

    # Traductor de shaders (tools/build_xlate.py): NativeAOT publica con el SDK
    # de .NET 10 y enlaza con el clang del PATH.
    dotnet-sdk_10

    vulkan-tools # vulkaninfo: comprobar 1.3 + VK_EXT_external_memory_host
    uv # los dos entornos de Python del proyecto (el intérprete lo trae uv)

    # Perfilado del runtime nativo: el perf del mismo kernelPackages que corre
    # el sistema, para que los símbolos casen. Más gdb para depurar el ELF.
    config.boot.kernelPackages.perf
    gdb
  ]
  ++ engineDeps
  ++ [
    # Shell con el entorno que el build espera encontrar en el sistema. Uso:
    #   kalamar-engine            # bash con todo exportado
    #   kalamar-engine -- comando # un solo comando, con el mismo entorno
    (writeShellApplication {
      name = "kalamar-engine";
      runtimeInputs = [ bashInteractive ];
      text = ''
        # clang lee CPATH y LIBRARY_PATH nativamente: equivalen a -I y -L sin
        # tener que tocar las flags del proyecto.
        export CPATH="${includeDirs}"
        export LIBRARY_PATH="${libDirs}"
        export LD_LIBRARY_PATH="${libDirs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export C_INCLUDE_PATH="$CPATH"
        export CPLUS_INCLUDE_PATH="$CPATH"

        if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
          shift
          exec "$@"
        fi
        exec bash -i
      '';
    })
  ];

  # Perfilar procesos propios sin ser root.
  boot.kernel.sysctl."kernel.perf_event_paranoid" = 1;
}
