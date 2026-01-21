{
  description = "A Nix Flake for hyperscale-rs development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        rust = pkgs.rust-bin.stable.latest.default;

        # Create a source that includes the submodule content
        src = pkgs.runCommand "source" { } ''
          cp -r ${self} $out
          chmod -R +w $out
          mkdir -p $out/vendor/radixdlt-scrypto
          cp -r ${radixdlt-scrypto}/* $out/vendor/radixdlt-scrypto/
        '';

        nativeBuildInputs = [
          rust
          pkgs.pkg-config
          pkgs.protobuf
          pkgs.cmake
          pkgs.llvmPackages.libclang
          pkgs.llvmPackages.bintools
        ];

        buildInputs = [
          pkgs.openssl
          pkgs.libiconv
        ];
        envVars = {
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          PROTOC = "${pkgs.protobuf}/bin/protoc";
        };

        rustPlatform = pkgs.makeRustPlatform {
          cargo = rust;
          rustc = rust;
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

          doCheck = false; # Skip tests by default for faster builds

          meta = with pkgs.lib; {
            description = "Rust implementation of Hyperscale consensus protocol";
            homepage = "https://github.com/hyperscalers/hyperscale-rs";
            license = licenses.mit;
          };
        };

        devShells.default = devshell.legacyPackages.${system}.mkShell {
          name = "hyperscale-rs-dev-shell";
          packages = nativeBuildInputs ++ buildInputs ++ [
            pkgs.llvmPackages.libcxx
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
          ];

          commands = [
            {
              name = "tests";
              category = "testing";
              help = "Run tests";
              command = "cargo test";
            }
            {
              name = "tests-workspace";
              category = "testing";
              help = "Run tests in workspace";
              command = "cargo test --workspace";
            }
            {
              name = "tests-all";
              category = "testing";
              help = "Run tests with all targets and all features";
              command = "cargo test --all-targets --all-features";
            }
          ];
        };
      });
}
