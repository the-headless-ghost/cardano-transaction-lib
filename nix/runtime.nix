{ inputs, ... }:
rec {
  defaultConfig = final: with final; {
    inherit (inputs) cardano-configurations;
    network = {
      name = "preprod";
      magic = 1; # use `null` for mainnet
    };
    node = {
      port = 3001;
      # the version of the node to use, corresponds to the image version tag,
      # i.e. `"inputoutput/cardano-node:${tag}"`
      tag = "1.35.3";
    };
    ogmios = { port = 1337; };
    ctlServer = {
      enable = true;
      port = 8081;
    };
    postgres = {
      # User-facing port on host machine.
      # Can be set to null in order to not bind postgres port to host.
      # Postgres will always be accessible via `postgres:5432` from
      # containers.
      port = 5432;
      user = "ctxlib";
      password = "ctxlib";
      db = "ctxlib";
    };
    datumCache = {
      port = 9999;
      controlApiToken = "";
      blockFetcher = {
        firstBlock = {
          slot = 5854109;
          id = "85366c607a9777b887733de621aa2008aec9db4f3e6a114fb90ec2909bc06f14";
        };
        autoStart = true;
        startFromLast = false;
        filter = builtins.toJSON { const = true; };
      };
    };
    # Additional config that will be included in Arion's `docker-compose.raw`. This
    # corresponds directly to YAML that would be written in a `docker-compose` file,
    # e.g. volumes
    extraDockerCompose = { };
    # Additional services to include in the `docker-compose` config that Arion
    # produces.
    #
    # For a docker image:
    #
    # ```
    #   foo = {
    #     service = {
    #       image = "bar:foo";
    #       command = [
    #         "baz"
    #         "--quux"
    #       ];
    #     };
    #   };
    # ```
    #
    # For a Nix package:
    #
    # ```
    #   foo = {
    #     service = {
    #       useHostStore = true;
    #       command = [
    #         "${pkgs.baz}/bin/baz"
    #         "--quux"
    #       ];
    #     };
    #   };
    #
    # ```
    extraServices = { };
  };

  buildCtlRuntime = pkgs: extraConfig: { ... }:
    let
      inherit (builtins) toString;
      config = with pkgs.lib;
        fix (final:
          recursiveUpdate
            (defaultConfig final)
            (
              if isFunction extraConfig
              then extraConfig final
              else extraConfig
            )
        );
      nodeDbVol = "node-${config.network.name}-db";
      nodeIpcVol = "node-${config.network.name}-ipc";
      nodeSocketPath = "/ipc/node.socket";
      bindPort = port: "${toString port}:${toString port}";
      defaultServices = with config; {
        cardano-node = {
          service = {
            image = "inputoutput/cardano-node:${node.tag}";
            ports = [ (bindPort node.port) ];
            volumes = [
              "${config.cardano-configurations}/network/${config.network.name}/cardano-node:/config"
              "${config.cardano-configurations}/network/${config.network.name}/genesis:/genesis"
              "${nodeDbVol}:/data"
              "${nodeIpcVol}:/ipc"
            ];
            command = [
              "run"
              "--config"
              "/config/config.json"
              "--database-path"
              "/data/db"
              "--socket-path"
              "${nodeSocketPath}"
              "--topology"
              "/config/topology.json"
            ];
          };
        };
        ogmios = {
          service = {
            useHostStore = true;
            ports = [ (bindPort ogmios.port) ];
            volumes = [
              "${config.cardano-configurations}/network/${config.network.name}:/config"
              "${nodeIpcVol}:/ipc"
            ];
            command = [
              "${pkgs.bash}/bin/sh"
              "-c"
              ''
                ${pkgs.ogmios}/bin/ogmios \
                  --host ogmios \
                  --port ${toString ogmios.port} \
                  --node-socket /ipc/node.socket \
                  --node-config /config/cardano-node/config.json
              ''
            ];
          };
        };
        postgres = {
          service = {
            image = "postgres:13";
            ports =
              if postgres.port == null
              then [ ]
              else [ "${toString postgres.port}:5432" ];
            environment = {
              POSTGRES_USER = "${postgres.user}";
              POSTGRES_PASSWORD = "${postgres.password}";
              POSTGRES_DB = "${postgres.db}";
            };
          };
        };
        ogmios-datum-cache =
          let
            filter = inputs.nixpkgs.lib.strings.replaceStrings
              [ "\"" "\\" ] [ "\\\"" "\\\\" ]
              datumCache.blockFetcher.filter;
          in
          {
            service = {
              useHostStore = true;
              ports = [ (bindPort datumCache.port) ];
              restart = "on-failure";
              depends_on = [ "postgres" "ogmios" ];
              command = [
                "${pkgs.bash}/bin/sh"
                "-c"
                ''
                  ${pkgs.ogmios-datum-cache}/bin/ogmios-datum-cache \
                    --log-level warn \
                    --use-latest \
                    --server-api "${toString datumCache.controlApiToken}" \
                    --server-port ${toString datumCache.port} \
                    --ogmios-address ogmios \
                    --ogmios-port ${toString ogmios.port} \
                    --db-port 5432 \
                    --db-host postgres \
                    --db-user "${postgres.user}" \
                    --db-name "${postgres.db}" \
                    --db-password "${postgres.password}" \
                    --block-slot ${toString datumCache.blockFetcher.firstBlock.slot} \
                    --block-hash "${datumCache.blockFetcher.firstBlock.id}" \
                    --block-filter "${filter}"
                ''
              ];
            };
          };
      } // pkgs.lib.optionalAttrs ctlServer.enable {
        ctl-server = {
          service = {
            useHostStore = true;
            ports = [ (bindPort ctlServer.port) ];
            command = [
              "${pkgs.bash}/bin/sh"
              "-c"
              ''
                ${pkgs.ctl-server}/bin/ctl-server --port ${toString ctlServer.port}
              ''
            ];
          };
        };
      };
    in
    {
      docker-compose.raw = pkgs.lib.recursiveUpdate
        {
          volumes = {
            "${nodeDbVol}" = { };
            "${nodeIpcVol}" = { };
          };
        }
        config.extraDockerCompose;
      services = pkgs.lib.recursiveUpdate defaultServices config.extraServices;
    };

  # Makes a set compatible with flake `apps` to launch all runtime services
  launchCtlRuntime = pkgs: config:
    let
      binPath = "ctl-runtime";
      prebuilt = (pkgs.arion.build {
        inherit pkgs;
        modules = [ (buildCtlRuntime pkgs config) ];
      }).outPath;
      script = pkgs.writeShellApplication {
        name = binPath;
        runtimeInputs = [ pkgs.arion pkgs.docker ];
        text =
          ''
            ${pkgs.arion}/bin/arion --prebuilt-file ${prebuilt} up
          '';
      };
    in
    {
      type = "app";
      program = "${script}/bin/${binPath}";
    };

}
