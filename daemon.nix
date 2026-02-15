{ lib, python3Packages, makeWrapper, tmux, git }:

python3Packages.buildPythonApplication {
  pname = "nuketown-daemon";
  version = "0.1.0";

  src = ./daemon;
  pyproject = true;

  build-system = [ python3Packages.setuptools ];

  propagatedBuildInputs = [ python3Packages.slixmpp ];

  nativeBuildInputs = [ makeWrapper ];

  postFixup = ''
    wrapProgram $out/bin/nuketown-daemon \
      --prefix PATH : ${lib.makeBinPath [ tmux git ]}
  '';

  meta = {
    description = "Task daemon for nuketown agents";
    license = lib.licenses.mit;
    mainProgram = "nuketown-daemon";
  };
}
