{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.onedrive-rclone-menubar;
in
{
  options.programs.onedrive-rclone-menubar = {
    enable = lib.mkEnableOption "the OneDrive rclone menu-bar app, installed in /Applications/Nix Apps";

    version = lib.mkOption {
      type = lib.types.str;
      example = "0.1.0";
      description = "Release to install, without the leading v.";
    };

    hash = lib.mkOption {
      type = lib.types.str;
      example = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      description = "SRI hash of the release zip, as given in the release notes.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { inherit (cfg) version hash; };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { inherit (cfg) version hash; }";
      description = "The app package. Defaults to the release named by `version` and `hash`.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
