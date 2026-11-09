{
  description = "Checks that the nix-darwin module evaluates the way the README tells users to configure it";

  # Kept out of the top-level flake so that users' lock files gain no inputs.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, nix-darwin, ... }:
    let
      inherit (nixpkgs) lib;
      # Exactly what users import: the top-level flake's module.
      module = ((import ../../flake.nix).outputs { self = null; }).darwinModules.default;
      version = "1.2.3";
      hash = lib.fakeHash;

      darwinSystem =
        settings:
        nix-darwin.lib.darwinSystem {
          modules = [
            module
            {
              nixpkgs.hostPlatform = "aarch64-darwin";
              system.stateVersion = 6;
              programs.onedrive-rclone-menubar = settings;
            }
          ];
        };

      enabled = (darwinSystem { enable = true; inherit version hash; }).config;
      disabled = (darwinSystem { enable = false; }).config;
      appPackages = config: builtins.filter (p: (p.pname or "") == "onedrive-rclone-menubar") config.environment.systemPackages;
      app = builtins.head (appPackages enabled);

      check = description: holds: if holds then description else throw "nix-darwin module check failed: ${description}";
    in
    {
      # nix eval ./nix/tests#moduleChecks evaluates every check, on Linux or macOS,
      # without building anything.
      moduleChecks = [
        (check "the enabled module installs one app package" (builtins.length (appPackages enabled) == 1))
        (check "it installs the configured version" (app.version == version))
        (check "it downloads the zip that CI attaches to the release" (
          app.src.urls == [ "https://github.com/craigjperry2/onedrive-rclone-mac-menubar/releases/download/v${version}/OneDriveRcloneMenubar-${version}.zip" ]
        ))
        (check "it checks the download against the configured hash" (app.src.outputHash == hash))
        (check "it is a macOS-only package" (app.meta.platforms == lib.platforms.darwin))
        (check "it keeps the release's code signature intact" (app.dontFixup or false))
        (check "the whole system, including /Applications/Nix Apps, evaluates" (
          lib.hasSuffix ".drv" enabled.system.build.toplevel.drvPath
          && lib.hasSuffix ".drv" enabled.system.build.applications.drvPath
        ))
        (check "a disabled module installs nothing" (appPackages disabled == [ ]))
      ];
    };
}
