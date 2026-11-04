{
  description = "OneDrive rclone menu-bar app for nix-darwin, installed from immutable GitHub releases";

  outputs =
    { self }:
    {
      # Set programs.onedrive-rclone-menubar.{enable,version,hash} after importing it.
      darwinModules.default = import ./nix/darwin-module.nix;
    };
}
