# nix/django-app.nix
#
# Packages the Django project under ./src into:
#   - app       : a bin/webapp-server that runs Django under uWSGI (uwsgi proto)
#   - pythonEnv : runtime python env (Django only)
#   - testEnv   : python env with pytest + pytest-django (checks + dev shell)
#   - uwsgi     : uWSGI built with the python3 plugin
#
{
  pkgs,
  lib,
  constants,
  src,
}:

let
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.django ]);

  testEnv = pkgs.python3.withPackages (ps: [
    ps.django
    ps.pytest
    ps.pytest-django
  ]);

  # uWSGI with the embedded python3 plugin. Built against the same interpreter
  # as pythonEnv, so pythonEnv's site-packages (Django) are import-compatible.
  uwsgi = pkgs.uwsgi.override { plugins = [ "python3" ]; };

  # The project source tree, isolated to ./src (not the whole flake).
  appSrc = pkgs.runCommand "df-webapp-src" { } ''
    mkdir -p $out/app
    cp -r ${src}/src/. $out/app/
  '';

  webappServer = pkgs.writeShellApplication {
    name = "webapp-server";
    runtimeInputs = [
      uwsgi
      pythonEnv
      pkgs.coreutils # provides `df` for the view
    ];
    text = ''
      # Django + the app package must be importable by uWSGI's python plugin.
      export PYTHONPATH="${pythonEnv}/${pkgs.python3.sitePackages}:${appSrc}/app''${PYTHONPATH:+:$PYTHONPATH}"
      export DJANGO_SETTINGS_MODULE="dfproject.settings"
      export SLEEP_MS="''${SLEEP_MS:-${toString constants.sleepMs}}"

      socket="''${UWSGI_SOCKET:-${constants.uwsgiSocket}}"
      mkdir -p "$(dirname "$socket")"

      exec uwsgi \
        --plugins python3 \
        --plugins-dir "${uwsgi}/lib/uwsgi" \
        --socket "$socket" \
        --chmod-socket=666 \
        --chdir "${appSrc}/app" \
        --module dfproject.wsgi:application \
        --processes 2 \
        --master \
        --need-app \
        --die-on-term
    '';
  };
in
{
  app = webappServer;
  inherit
    pythonEnv
    testEnv
    uwsgi
    appSrc
    ;
}
