{
  config,
  lib,
  dream2nix,
  ...
}: let
  l = lib // builtins;
  cfg = config.pip;
  python = config.deps.python;
  metadata = config.lock.content.fetchPipMetadata;

  # filter out ignored dependencies
  targets = cfg.targets;
  isRootDrv = drv: cfg.rootDependencies.${drv.name} or false;
  isBuildInput = drv: cfg.buildDependencies.${drv.name} or false;

  writers = import ../../../pkgs/writers {
    inherit lib;
    inherit
      (config.deps)
      bash
      coreutils
      gawk
      path
      writeScript
      writeScriptBin
      ;
  };

  drvs =
    l.mapAttrs (
      name: info: {
        imports = [
          commonModule
          dependencyModule
          # include community overrides
          (dream2nix.overrides.python.${name} or {})
        ];
        config = {
          inherit name;
          inherit (info) version;
        };
      }
    )
    metadata.sources;

  dependencyModule = depConfig: let
    cfg = depConfig.config;
    setuptools =
      if cfg.name == "setuptools"
      then config.deps.python.pkgs.setuptools
      else config.pip.drvs.setuptools.public or config.deps.python.pkgs.setuptools;
  in {
    # deps.python cannot be defined in commonModule as this would trigger an
    #   infinite recursion.
    deps = {inherit python;};
    buildPythonPackage.format = l.mkDefault (
      if l.hasSuffix ".whl" cfg.mkDerivation.src
      then "wheel"
      else "pyproject"
    );
    mkDerivation.buildInputs =
      lib.optionals
      (! lib.hasSuffix ".whl" cfg.mkDerivation.src)
      [setuptools];
  };

  fetchers = {
    url = info: config.deps.fetchurl {inherit (info) url sha256;};
    git = info: config.deps.fetchgit {inherit (info) url sha256 rev;};
    local = info: "${config.paths.projectRoot}/${info.path}";
  };

  commonModule = {config, ...}: {
    imports = [
      dream2nix.modules.dream2nix.mkDerivation
      ../buildPythonPackage
    ];
    config = {
      deps = {nixpkgs, ...}:
        l.mapAttrs (_: l.mkOverride 1001) {
          inherit
            (nixpkgs)
            autoPatchelfHook
            bash
            coreutils
            gawk
            gitMinimal
            mkShell
            path
            stdenv
            unzip
            writeScript
            writeScriptBin
            ;
          inherit (nixpkgs.pythonManylinuxPackages) manylinux1;
        };
      mkDerivation = {
        src = l.mkDefault (fetchers.${metadata.sources.${config.name}.type} metadata.sources.${config.name});
        doCheck = l.mkDefault false;
        dontStrip = l.mkDefault true;

        nativeBuildInputs =
          [config.deps.unzip]
          ++ (l.optionals config.deps.stdenv.isLinux [config.deps.autoPatchelfHook]);
        buildInputs =
          l.optionals config.deps.stdenv.isLinux [config.deps.manylinux1];
        # This is required for autoPatchelfHook to find .so files from other
        # python dependencies, like for example libcublas.so.11 from nvidia-cublas-cu11.
        preFixup = lib.optionalString config.deps.stdenv.isLinux ''
          addAutoPatchelfSearchPath $propagatedBuildInputs
        '';
        propagatedBuildInputs = let
          depsByExtra = extra: targets.${extra}.${config.name} or [];
          defaultDeps = targets.default.${config.name} or [];
          deps = defaultDeps ++ (l.concatLists (l.map depsByExtra cfg.buildExtras));
        in
          l.map (name: cfg.drvs.${name}.public.out) deps;
      };
    };
  };
in {
  imports = [
    commonModule
    ./interface.nix
    ./pip-hotfixes
  ];

  deps = {nixpkgs, ...}:
    l.mapAttrs (_: l.mkOverride 1002) {
      # This is imported directly instead of depending on dream2nix.packages
      # with the intention to keep modules independent.
      fetchPipMetadataScript = import ../../../pkgs/fetchPipMetadata/script.nix {
        inherit lib;
        inherit (cfg) env pypiSnapshotDate pipFlags pipVersion requirementsList requirementsFiles nativeBuildInputs;
        inherit (config.deps) writePureShellScript nix;
        inherit (config.paths) findRoot;
        inherit (nixpkgs) fetchFromGitHub fetchurl gitMinimal nix-prefetch-scripts openssh python3 rustPlatform writeText;
        pythonInterpreter = "${python}/bin/python";
      };
      setuptools = config.deps.python.pkgs.setuptools;
      inherit (nixpkgs) nix fetchgit fetchurl;
      inherit (writers) writePureShellScript;
    };

  # Keep package metadata fetched by Pip in our lockfile
  lock.fields.fetchPipMetadata = {
    script = config.deps.fetchPipMetadataScript;
  };

  # if any of the invalidationData changes, the lock file will be invalidated
  #   and the user will be promted to re-generate it.
  lock.invalidationData = {
    pip =
      {
        inherit
          (config.pip)
          pypiSnapshotDate
          pipFlags
          pipVersion
          requirementsList
          requirementsFiles
          ;
        # don't invalidate on bugfix version changes
        pythonVersion = lib.init (lib.splitVersion config.deps.python.version);
      }
      # including env conditionally to not invalidate all existing lockfiles
      # TODO: refactor once compat is broken through something else
      // (lib.optionalAttrs (config.pip.env != {}) config.pip.env);
  };

  pip = {
    drvs = drvs;
    rootDependencies =
      l.genAttrs (targets.default.${config.name} or []) (_: true);
  };

  mkDerivation = {
    buildInputs = let
      rootDeps =
        lib.filterAttrs
        (name: value: isRootDrv value && isBuildInput value)
        cfg.drvs;
    in
      l.map (drv: drv.public.out) (l.attrValues rootDeps);

    propagatedBuildInputs = let
      rootDeps =
        lib.filterAttrs
        (name: value: isRootDrv value && !isBuildInput value)
        cfg.drvs;
    in
      l.map (drv: drv.public.out) (l.attrValues rootDeps);
  };

  public.pyEnv = let
    pyEnv' = config.deps.python.withPackages (ps: config.mkDerivation.propagatedBuildInputs);
  in
    pyEnv'.override (old: {
      # namespaced packages are triggering a collision error, but this can be
      # safely ignored. They are still set up correctly and can be imported.
      ignoreCollisions = true;
    });

  public.devShell = config.public.pyEnv.env;
}
