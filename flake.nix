{
  description = "shyfoss: blur the screen when AirPods head tracking says you looked away";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          shyfoss = pkgs.stdenvNoCC.mkDerivation {
            pname = "shyfoss";
            version = "0.3.1";
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [ ./main.swift ./Info.plist ];
            };
            # ponytail: shells out to the system Xcode CLT swiftc, nixpkgs
            # carries no darwin AppKit/CoreMotion SDK to compile against
            buildPhase = ''
              app=Contents
              mkdir -p "$app/MacOS"
              /usr/bin/xcrun swiftc -O -o "$app/MacOS/ShyFoss" main.swift
              cp Info.plist "$app/Info.plist"
            '';
            doCheck = true;
            checkPhase = ''
              Contents/MacOS/ShyFoss --selftest
            '';
            installPhase = ''
              mkdir -p "$out/Applications/ShyFoss.app"
              cp -r Contents "$out/Applications/ShyFoss.app/Contents"
              /usr/bin/codesign -s - -f "$out/Applications/ShyFoss.app"
            '';
            meta = {
              description = "Blur your Mac when you look away, using AirPods head tracking";
              mainProgram = "ShyFoss";
              platforms = lib.platforms.darwin;
            };
          };
        in
        {
          inherit shyfoss;
          default = shyfoss;
        });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/Applications/ShyFoss.app/Contents/MacOS/ShyFoss";
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
