# nuketown-prompter: the default sudo approval card (GTK 4, X11 and
# Wayland). approval-daemon.nix runs it as the broker's prompter; see
# nuketown_prompter.py for the contract. The text model's tests run at
# build time; the card itself is covered by vm-approval-prompter.
{ lib, stdenvNoCC, python3, gtk4, gobject-introspection, wrapGAppsHook4, makeWrapper }:

let
  python = python3.withPackages (p: [ p.pygobject3 ]);
in
stdenvNoCC.mkDerivation {
  pname = "nuketown-prompter";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./nuketown_prompter.py ./test_prompter.py ];
  };

  nativeBuildInputs = [ wrapGAppsHook4 gobject-introspection makeWrapper ];
  buildInputs = [ gtk4 ];
  dontBuild = true;
  doCheck = true;
  dontWrapGApps = true;   # one wrapper, made below

  checkPhase = ''
    runHook preCheck
    ${python.interpreter} -I test_prompter.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib/nuketown-prompter
    cp nuketown_prompter.py $out/lib/nuketown-prompter/
    ${python.interpreter} -I -m py_compile $out/lib/nuketown-prompter/nuketown_prompter.py
    runHook postInstall
  '';

  postFixup = ''
    makeWrapper ${python.interpreter} $out/bin/nuketown-prompter \
      --add-flags "-I $out/lib/nuketown-prompter/nuketown_prompter.py" \
      --set-default GSK_RENDERER cairo \
      "''${gappsWrapperArgs[@]}"
  '';

  meta = {
    description = "nuketown's sudo approval card";
    mainProgram = "nuketown-prompter";
    license = lib.licenses.mit;
  };
}
