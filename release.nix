{ nix ? builtins.fetchGit ./.
, nixpkgs ? builtins.fetchGit { url = https://github.com/NixOS/nixpkgs-channels.git; ref = "nixos-18.03"; }
, officialRelease ? false
, systems ? [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" ]
}:

let

  pkgs = import nixpkgs { system = builtins.currentSystem or "x86_64-linux"; };

  jobs = rec {


    tarball =
      with pkgs;

      with import ./release-common.nix { inherit pkgs; };

      releaseTools.sourceTarball {
        name = "nix-tarball";
        version = builtins.readFile ./version;
        versionSuffix = if officialRelease then "" else "pre${toString nix.revCount}_${nix.shortRev}";
        src = nix;
        inherit officialRelease;

        buildInputs = tarballDeps ++ buildDeps;

        configureFlags = "--enable-gc";

        postUnpack = ''
          (cd source && find . -type f) | cut -c3- > source/.dist-files
          cat source/.dist-files
        '';

        preConfigure = ''
          (cd perl ; autoreconf --install --force --verbose)
          # TeX needs a writable font cache.
          export VARTEXFONTS=$TMPDIR/texfonts
        '';

        distPhase =
          ''
            runHook preDist
            make dist
            mkdir -p $out/tarballs
            cp *.tar.* $out/tarballs
          '';

        preDist = ''
          make install docdir=$out/share/doc/nix makefiles=doc/manual/local.mk
          echo "doc manual $out/share/doc/nix/manual" >> $out/nix-support/hydra-build-products
        '';
      };


    build = pkgs.lib.genAttrs systems (system:

      let pkgs = import nixpkgs { inherit system; }; in

      with pkgs;

      with import ./release-common.nix { inherit pkgs; };

      releaseTools.nixBuild {
        name = "nix";
        src = tarball;

        buildInputs = buildDeps;

        configureFlags = configureFlags ++
          [ "--sysconfdir=/etc" ];

        enableParallelBuilding = true;

        makeFlags = "profiledir=$(out)/etc/profile.d";

        preBuild = "unset NIX_INDENT_MAKE";

        installFlags = "sysconfdir=$(out)/etc";

        doInstallCheck = true;
        installCheckFlags = "sysconfdir=$(out)/etc";
      });


    perlBindings = pkgs.lib.genAttrs systems (system:

      let pkgs = import nixpkgs { inherit system; }; in with pkgs;

      releaseTools.nixBuild {
        name = "nix-perl";
        src = tarball;

        buildInputs =
          [ (builtins.getAttr system jobs.build) curl bzip2 xz pkgconfig pkgs.perl ]
          ++ lib.optional (stdenv.isLinux || stdenv.isDarwin) libsodium;

        configureFlags = ''
          --with-dbi=${perlPackages.DBI}/${pkgs.perl.libPrefix}
          --with-dbd-sqlite=${perlPackages.DBDSQLite}/${pkgs.perl.libPrefix}
        '';

        enableParallelBuilding = true;

        postUnpack = "sourceRoot=$sourceRoot/perl";

        preBuild = "unset NIX_INDENT_MAKE";
      });


    binaryTarball = pkgs.lib.genAttrs systems (system:

      with import nixpkgs { inherit system; };

      let
        toplevel = builtins.getAttr system jobs.build;
        version = toplevel.src.version;
      in

      runCommand "nix-binary-tarball-${version}"
        { exportReferencesGraph = [ "closure1" toplevel "closure2" cacert ];
          buildInputs = [ perl ] ++ lib.optional (system != "aarch64-linux") shellcheck;
          meta.description = "Distribution-independent Nix bootstrap binaries for ${system}";
        }
        ''
          storePaths=$(perl ${pathsFromGraph} ./closure1 ./closure2)
          printRegistration=1 perl ${pathsFromGraph} ./closure1 ./closure2 > $TMPDIR/reginfo
          substitute ${./scripts/install-nix-from-closure.sh} $TMPDIR/install \
            --subst-var-by nix ${toplevel} \
            --subst-var-by cacert ${cacert}
          substitute ${./scripts/install-darwin-multi-user.sh} $TMPDIR/install-darwin-multi-user \
            --subst-var-by nix ${toplevel} \
            --subst-var-by cacert ${cacert}

          if type -p shellcheck; then
            shellcheck -e SC1090 $TMPDIR/install
            shellcheck -e SC1091,SC2002 $TMPDIR/install-darwin-multi-user
          fi

          chmod +x $TMPDIR/install
          chmod +x $TMPDIR/install-darwin-multi-user
          dir=nix-${version}-${system}
          fn=$out/$dir.tar.bz2
          mkdir -p $out/nix-support
          echo "file binary-dist $fn" >> $out/nix-support/hydra-build-products
          tar cvfj $fn \
            --owner=0 --group=0 --mode=u+rw,uga+r \
            --absolute-names \
            --hard-dereference \
            --transform "s,$TMPDIR/install,$dir/install," \
            --transform "s,$TMPDIR/reginfo,$dir/.reginfo," \
            --transform "s,$NIX_STORE,$dir/store,S" \
            $TMPDIR/install $TMPDIR/install-darwin-multi-user $TMPDIR/reginfo $storePaths
        '');


    coverage =
      with pkgs;

      with import ./release-common.nix { inherit pkgs; };

      releaseTools.coverageAnalysis {
        name = "nix-build";
        src = tarball;

        buildInputs = buildDeps;

        configureFlags = ''
          --disable-init-state
        '';

        dontInstall = false;

        doInstallCheck = true;

        lcovFilter = [ "*/boost/*" "*-tab.*" "*/nlohmann/*" "*/linenoise/*" ];

        # We call `dot', and even though we just use it to
        # syntax-check generated dot files, it still requires some
        # fonts.  So provide those.
        FONTCONFIG_FILE = texFunctions.fontsConf;
      };


    rpm_fedora25i386 = makeRPM_i686 (diskImageFuns: diskImageFuns.fedora25i386) [ "libsodium-devel" ];
    rpm_fedora25x86_64 = makeRPM_x86_64 (diskImageFunsFun: diskImageFunsFun.fedora25x86_64) [ "libsodium-devel" ];


    #deb_debian8i386 = makeDeb_i686 (diskImageFuns: diskImageFuns.debian8i386) [ "libsodium-dev" ] [ "libsodium13" ];
    #deb_debian8x86_64 = makeDeb_x86_64 (diskImageFunsFun: diskImageFunsFun.debian8x86_64) [ "libsodium-dev" ] [ "libsodium13" ];

    deb_ubuntu1604i386 = makeDeb_i686 (diskImageFuns: diskImageFuns.ubuntu1604i386) [ "libsodium-dev" ] [ "libsodium18" ];
    deb_ubuntu1604x86_64 = makeDeb_x86_64 (diskImageFuns: diskImageFuns.ubuntu1604x86_64) [ "libsodium-dev" ] [ "libsodium18" ];
    deb_ubuntu1610i386 = makeDeb_i686 (diskImageFuns: diskImageFuns.ubuntu1610i386) [ "libsodium-dev" ] [ "libsodium18" ];
    deb_ubuntu1610x86_64 = makeDeb_x86_64 (diskImageFuns: diskImageFuns.ubuntu1610x86_64) [ "libsodium-dev" ] [ "libsodium18" ];


    # System tests.
    tests.remoteBuilds = (import ./tests/remote-builds.nix rec {
      inherit nixpkgs;
      nix = build.x86_64-linux; system = "x86_64-linux";
    });

    tests.nix-copy-closure = (import ./tests/nix-copy-closure.nix rec {
      inherit nixpkgs;
      nix = build.x86_64-linux; system = "x86_64-linux";
    });

    tests.setuid = pkgs.lib.genAttrs
      ["i686-linux" "x86_64-linux"]
      (system:
        import ./tests/setuid.nix rec {
          inherit nixpkgs;
          nix = build.${system}; inherit system;
        });

    tests.binaryTarball =
      with import nixpkgs { system = "x86_64-linux"; };
      vmTools.runInLinuxImage (runCommand "nix-binary-tarball-test"
        { diskImage = vmTools.diskImages.ubuntu1204x86_64;
        }
        ''
          useradd -m alice
          su - alice -c 'tar xf ${binaryTarball.x86_64-linux}/*.tar.*'
          mkdir /dest-nix
          mount -o bind /dest-nix /nix # Provide a writable /nix.
          chown alice /nix
          su - alice -c '_NIX_INSTALLER_TEST=1 ./nix-*/install'
          su - alice -c 'nix-store --verify'
          su - alice -c 'PAGER= nix-store -qR ${build.x86_64-linux}'
          mkdir -p $out/nix-support
          touch $out/nix-support/hydra-build-products
          umount /nix
        ''); # */

    tests.evalNixpkgs =
      import (nixpkgs + "/pkgs/top-level/make-tarball.nix") {
        inherit nixpkgs;
        inherit pkgs;
        nix = build.x86_64-linux;
        officialRelease = false;
      };

    tests.evalNixOS =
      pkgs.runCommand "eval-nixos" { buildInputs = [ build.x86_64-linux ]; }
        ''
          export NIX_STATE_DIR=$TMPDIR
          nix-store --init

          nix-instantiate ${nixpkgs}/nixos/release-combined.nix -A tested --dry-run

          touch $out
        '';


    # Aggregate job containing the release-critical jobs.
    release = pkgs.releaseTools.aggregate {
      name = "nix-${tarball.version}";
      meta.description = "Release-critical builds";
      constituents =
        [ tarball
          build.i686-linux
          build.x86_64-darwin
          build.x86_64-linux
          binaryTarball.i686-linux
          binaryTarball.x86_64-darwin
          binaryTarball.x86_64-linux
          #deb_debian8i386
          #deb_debian8x86_64
          deb_ubuntu1604i386
          deb_ubuntu1604x86_64
          rpm_fedora25i386
          rpm_fedora25x86_64
          tests.remoteBuilds
          tests.nix-copy-closure
          tests.binaryTarball
          tests.evalNixpkgs
          tests.evalNixOS
        ];
    };

  };


  makeRPM_i686 = makeRPM "i686-linux";
  makeRPM_x86_64 = makeRPM "x86_64-linux";

  makeRPM =
    system: diskImageFun: extraPackages:

    with import nixpkgs { inherit system; };

    releaseTools.rpmBuild rec {
      name = "nix-rpm";
      src = jobs.tarball;
      diskImage = (diskImageFun vmTools.diskImageFuns)
        { extraPackages =
            [ "sqlite" "sqlite-devel" "bzip2-devel" "libcurl-devel" "openssl-devel" "xz-devel" "libseccomp-devel" ]
            ++ extraPackages; };
      # At most 2047MB can be simulated in qemu-system-i386
      memSize = 2047;
      meta.schedulingPriority = 50;
      postRPMInstall = "cd /tmp/rpmout/BUILD/nix-* && make installcheck";
      #enableParallelBuilding = true;
    };


  makeDeb_i686 = makeDeb "i686-linux";
  makeDeb_x86_64 = makeDeb "x86_64-linux";

  makeDeb =
    system: diskImageFun: extraPackages: extraDebPackages:

    with import nixpkgs { inherit system; };

    releaseTools.debBuild {
      name = "nix-deb";
      src = jobs.tarball;
      diskImage = (diskImageFun vmTools.diskImageFuns)
        { extraPackages =
            [ "libsqlite3-dev" "libbz2-dev" "libcurl-dev" "libcurl3-nss" "libssl-dev" "liblzma-dev" "libseccomp-dev" ]
            ++ extraPackages; };
      memSize = 1024;
      meta.schedulingPriority = 50;
      postInstall = "make installcheck";
      configureFlags = "--sysconfdir=/etc";
      debRequires =
        [ "curl" "libsqlite3-0" "libbz2-1.0" "bzip2" "xz-utils" "libssl1.0.0" "liblzma5" "libseccomp2" ]
        ++ extraDebPackages;
      debMaintainer = "Eelco Dolstra <eelco.dolstra@logicblox.com>";
      doInstallCheck = true;
      #enableParallelBuilding = true;
    };


in jobs
