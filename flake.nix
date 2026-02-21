{
  description = "A Nix Flake for hyperscale-rs development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    devshell.url = "github:numtide/devshell";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
    radixdlt-scrypto = {
      # Update the git submodule's version when it changes (purest way to do it without making a Flake update script)
      url = "github:radixdlt/radixdlt-scrypto?rev=de0b867c8fef6c806820885d9f8ec7e0d5881678&submodules=1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, devshell, rust-overlay, flake-utils, radixdlt-scrypto }:
    {
      # NixOS modules for systemd-nspawn containers
      nixosModules = {
        hyperscale-containers = import ./nix/containers.nix;
        hyperscale-validator = import ./nix/validator-service.nix;
        hyperscale-monitoring = import ./nix/monitoring.nix;
        default = import ./nix/containers.nix;
      };
    } // flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        # Define your project's Rust version here - change as needed
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        # Create a source that includes the submodule content
        src = pkgs.runCommand "source" { } ''
          cp -r ${self} $out
          chmod -R +w $out
          mkdir -p $out/vendor/radixdlt-scrypto
          cp -r ${radixdlt-scrypto}/* $out/vendor/radixdlt-scrypto/
        '';

        # Use clang instead of gcc for building on Linux to avoid header mismatches
        stdenv = pkgs.stdenv;

        nativeBuildInputs = [
          rustToolchain
          pkgs.pkg-config
          pkgs.protobuf
          pkgs.cmake
          pkgs.gnumake
          pkgs.llvmPackages.libclang
        ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
          # We omit llvmPackages.bintools here to avoid conflicts with stdenv.cc in the devShell
        ];

        buildInputs = [
          pkgs.openssl
          pkgs.libiconv
          pkgs.zlib
          pkgs.bzip2
          pkgs.lz4
          pkgs.zstd
          pkgs.snappy
        ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
          pkgs.stdenv.cc.cc.lib
        ];

        envVars = {
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          PROTOC = "${pkgs.protobuf}/bin/protoc";
          BINDGEN_EXTRA_CLANG_ARGS =
            if pkgs.stdenv.isLinux then
              pkgs.lib.concatStringsSep " " [
                "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${pkgs.lib.versions.major (pkgs.lib.getVersion pkgs.clang)}/include"
                "-isystem ${pkgs.glibc.dev}/include"
                "-isystem /usr/include"
              ]
            else if pkgs.stdenv.isDarwin then
              "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${pkgs.lib.versions.major (pkgs.lib.getVersion pkgs.clang)}/include"
            else "";
        };

        rustPlatform = pkgs.makeRustPlatform {
          cargo = rustToolchain;
          rustc = rustToolchain;
        };
      in
      {
        packages.default = rustPlatform.buildRustPackage {
          pname = "hyperscale-rs";
          version = "0.0.6";

          inherit src;

          cargoLock = {
            lockFile = ./Cargo.lock;
          };

          nativeBuildInputs = nativeBuildInputs;
          buildInputs = buildInputs;

          LIBCLANG_PATH = envVars.LIBCLANG_PATH;
          PROTOC = envVars.PROTOC;
          BINDGEN_EXTRA_CLANG_ARGS = envVars.BINDGEN_EXTRA_CLANG_ARGS;

          # Enable tests and enforce offline/locked builds
          doCheck = true;

          # Ensure Cargo uses --locked (--offline is already added by buildRustPackage)
          cargoBuildFlags = [ "--locked" ];
          cargoTestFlags = [ "--locked" ];

          # Prevent any network access during build
          __darwinAllowLocalNetworking = false;

          meta = with pkgs.lib; {
            description = "Rust implementation of Hyperscale consensus protocol";
            homepage = "https://github.com/hyperscalers/hyperscale-rs";
            license = licenses.mit;
          };
        };

        devShells.default = devshell.legacyPackages.${system}.mkShell {
          name = "hyperscale-rs-dev-shell";
          packages = nativeBuildInputs ++ buildInputs ++ [
            pkgs.bashInteractive
            pkgs.jq
            pkgs.llvmPackages.libcxx
            pkgs.sccache
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.gcc
            # Profiling and benchmarking tools
            pkgs.hyperfine
            pkgs.strace
            pkgs.linuxPackages.perf
            pkgs.sysstat
            pkgs.bc
            pkgs.time
            pkgs.lsof
            pkgs.nftables
          ];

          env = [
            {
              name = "LIBCLANG_PATH";
              value = envVars.LIBCLANG_PATH;
            }
            {
              name = "PROTOC";
              value = envVars.PROTOC;
            }
            {
              name = "BINDGEN_EXTRA_CLANG_ARGS";
              value = envVars.BINDGEN_EXTRA_CLANG_ARGS;
            }
            {
              name = "CARGO_HOME";
              eval = "$PRJ_ROOT/.nix/cargo/${system}";
            }
            {
              name = "RUSTC_WRAPPER";
              value = "${pkgs.sccache}/bin/sccache";
            }
            {
              name = "SCCACHE_DIR";
              eval = "$PRJ_ROOT/.nix/sccache";
            }
          ];

          devshell.startup.create-nix-directory = {
            text = ''
              # Create .nix directory for toolchain symlinks, cargo cache, and sccache
              mkdir -p .nix/sccache
            '';
          };

          devshell.startup.rust-toolchain-symlink = {
            deps = [ "create-nix-directory" ];
            text = ''
              # Create stable symlink to Rust toolchain for IDE
              rm -f .nix/rust-toolchain
              ln -sf ${rustToolchain} .nix/rust-toolchain
              echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
              echo "✓ Rust toolchain: $(${rustToolchain}/bin/rustc --version)"
              echo "✓ Symlink: .nix/rust-toolchain → ${rustToolchain}"
              echo "✓ sccache: enabled (cache dir: .nix/sccache)"
              echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            '';
          };

          commands = [
            # Category: cluster
            {
              name = "cluster-docker-start";
              category = "cluster";
              help = "Start hyperscale Docker Compose cluster";
              command = "${pkgs.bash}/bin/bash ./scripts/launch-docker-compose.sh";
            }
            {
              name = "cluster-docker-stop";
              category = "cluster";
              help = "Stop hyperscale Docker Compose cluster";
              command = "${pkgs.bash}/bin/bash ./scripts/stop-docker-compose.sh";
            }
            {
              name = "cluster-systemd-start";
              category = "cluster";
              help = "Start hyperscale Nix systemd-nspawn cluster";
              command = "${pkgs.bash}/bin/bash ./scripts/launch-systemd-containers.sh";
            }
            {
              name = "cluster-systemd-stop";
              category = "cluster";
              help = "Stop hyperscale Nix systemd-nspawn cluster";
              command = "${pkgs.bash}/bin/bash ./scripts/stop-systemd-containers.sh";
            }
            {
              name = "cluster-process-start";
              category = "cluster";
              help = "Start hyperscale process cluster";
              command = "${pkgs.bash}/bin/bash ./scripts/launch-cluster.sh";
            }
            {
              name = "cluster-process-stop";
              category = "cluster";
              help = "Stop hyperscale process cluster";
              command = "${pkgs.bash}/bin/bash ./scripts/stop-cluster.sh";
            }
            # Category: testing
            {
              name = "tests";
              category = "testing";
              help = "Run tests";
              command = "cargo test --no-fail-fast";
            }
            {
              name = "tests-all";
              category = "testing";
              help = "Run tests with all targets and all features";
              command = "cargo test --no-fail-fast --all-targets --all-features";
            }
            {
              name = "tests-workspace";
              category = "testing";
              help = "Run tests in workspace";
              command = "cargo test --no-fail-fast --workspace";
            }
          ];
        };
      });
}
