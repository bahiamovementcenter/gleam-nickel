{
  description = "Gleam bindings to the Nickel configuration language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # The native backend's library (nickel-embed-nif).
    rust-nickel = {
      url = "github:bahiamovementcenter/rust-nickel/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-nickel,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The native library, where rust-nickel builds it (not x86_64-darwin).
      nativeLibrary =
        pkgs:
        let
          packages = rust-nickel.packages.${pkgs.stdenv.hostPlatform.system} or { };
        in
        if packages ? nickel-embed-nif then
          "${packages.nickel-embed-nif}/lib/libnickel_embed_nif"
        else
          null;

      # Everything needed to build and test the library.
      toolchain = pkgs: [
        pkgs.gleam
        pkgs.beam_minimal.interpreters.erlang_27
        pkgs.nickel
      ];

      # Hex dependencies pinned by manifest.toml, fetched by Nix so that the
      # checks can run in the sandbox without network access. Laid out the
      # way `gleam deps download` leaves them in build/packages.
      hexPackages =
        pkgs:
        let
          manifest = builtins.fromTOML (builtins.readFile ./manifest.toml);
          fetch =
            p:
            pkgs.fetchurl {
              url = "https://repo.hex.pm/tarballs/${p.name}-${p.version}.tar";
              sha256 = nixpkgs.lib.toLower p.outer_checksum;
            };
          unpack = p: ''
            mkdir -p $out/${p.name} tmp-${p.name}
            tar -xf ${fetch p} -C tmp-${p.name}
            tar -xzf tmp-${p.name}/contents.tar.gz -C $out/${p.name}
          '';
          packagesToml = pkgs.writeText "packages.toml" (
            "[packages]\n"
            + nixpkgs.lib.concatMapStrings (p: ''
              ${p.name} = "${p.version}"
            '') manifest.packages
          );
        in
        pkgs.runCommand "gleam-hex-packages" { } ''
          mkdir -p $out
          ${nixpkgs.lib.concatMapStrings unpack manifest.packages}
          cp ${packagesToml} $out/packages.toml
        '';

      source = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./gleam.toml
          ./manifest.toml
          ./src
          ./test
        ];
      };
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs;
          # Lets `gleam test` exercise the native backend too.
          env = nixpkgs.lib.optionalAttrs (nativeLibrary pkgs != null) {
            NICKEL_EMBED_NIF = nativeLibrary pkgs;
          };
        };
      });

      checks = forAllSystems (
        pkgs:
        let
          gleamTest =
            name: env:
            pkgs.runCommand name ({ nativeBuildInputs = toolchain pkgs; } // env) ''
              cp -r ${source} source
              chmod -R u+w source
              cd source
              mkdir -p build
              cp -r ${hexPackages pkgs} build/packages
              chmod -R u+w build
              export HOME=$TMPDIR
              gleam test
              touch $out
            '';
        in
        {
          # Runs the test suite against the Nickel version from nixpkgs.
          test = gleamTest "gleam-nickel-test" { };

          format = pkgs.runCommand "gleam-nickel-format" { nativeBuildInputs = [ pkgs.gleam ]; } ''
            cd ${source}
            gleam format --check src test
            touch $out
          '';
        }
        // nixpkgs.lib.optionalAttrs (nativeLibrary pkgs != null) {
          # The same suite on the native backend, plus the native-only tests.
          test-native = gleamTest "gleam-nickel-test-native" {
            NICKEL_EMBED_NIF = nativeLibrary pkgs;
            NICKEL_TEST_BACKEND = "native";
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
