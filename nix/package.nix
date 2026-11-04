# The prebuilt app from an immutable GitHub release. Each release's notes give
# its version and the SRI hash of its zip.
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
  version,
  hash,
}:

stdenvNoCC.mkDerivation {
  pname = "onedrive-rclone-menubar";
  inherit version;

  src = fetchurl {
    url = "https://github.com/craigjperry2/onedrive-rclone-mac-menubar/releases/download/v${version}/OneDriveRcloneMenubar-${version}.zip";
    inherit hash;
  };

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    cp -R OneDriveRcloneMenubar.app $out/Applications/
    runHook postInstall
  '';

  # Stripping or patching would invalidate the bundle's code signature.
  dontFixup = true;

  meta = {
    description = "macOS menu-bar app for a locally configured OneDrive rclone bisync mirror";
    homepage = "https://github.com/craigjperry2/onedrive-rclone-mac-menubar";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
