# NixOS module for creating systemd-nspawn containers for hyperscale validators
# This replaces Docker containers with native systemd-nspawn containers

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.hyperscale-containers;

  # Helper function to create a validator container configuration
  mkValidatorContainer = { validatorId, shard, ip, p2pPort, rpcPort, configPath, dataPath, ... }: {
    name = "hyperscale-validator-${toString validatorId}";
    value = {
      autoStart = true;
      privateNetwork = false; # Use host network with macvlan

      # Bind mounts for configuration and data
      bindMounts = {
        "/home/hyperscalers/config.toml" = {
          hostPath = configPath;
          isReadOnly = true;
        };
        "/home/hyperscalers/data" = {
          hostPath = dataPath;
          isReadOnly = false;
        };
        "/home/hyperscalers/signing.key" = {
          hostPath = "${builtins.dirOf configPath}/signing.key";
          isReadOnly = true;
        };
      };

      # Network configuration - use macvlan for static IPs
      extraVeths = {
        "ve-val${toString validatorId}" = {
          localAddress = ip;
          hostBridge = cfg.bridgeName;
        };
      };

      config = { config, pkgs, ... }: {
        system.stateVersion = "24.05";

        # Install required packages in container
        environment.systemPackages = with pkgs; [
          hyperscale-validator
          curl
          iproute2
        ];

        # Create hyperscalers user
        users.users.hyperscalers = {
          isNormalUser = true;
          uid = 1001;
          group = "hyperscalers";
          home = "/home/hyperscalers";
        };
        users.groups.hyperscalers = {
          gid = 1001;
        };

        # Systemd service for the validator
        systemd.services.hyperscale-validator = {
          description = "Hyperscale Validator ${toString validatorId} (Shard ${toString shard})";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          serviceConfig = {
            Type = "simple";
            User = "hyperscalers";
            Group = "hyperscalers";
            WorkingDirectory = "/home/hyperscalers";
            ExecStart = "${pkgs.hyperscale-validator}/bin/hyperscale-validator --config /home/hyperscalers/config.toml";
            Restart = "unless-stopped";
            RestartSec = "5s";

            # Resource limits (optional)
          }
          // optionalAttrs (cfg.memoryLimit != null) { MemoryMax = cfg.memoryLimit; }
          // optionalAttrs (cfg.cpuQuota != null) { CPUQuota = "${toString cfg.cpuQuota}%"; }
          // {

            # Security hardening
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadWritePaths = [ "/home/hyperscalers/data" ];
          };

          # Healthcheck
          serviceConfig.ExecStartPost = pkgs.writeShellScript "healthcheck" ''
            for i in {1..10}; do
              if ${pkgs.curl}/bin/curl -f http://127.0.0.1:${toString rpcPort}/metrics >/dev/null 2>&1; then
                exit 0
              fi
              sleep 5
            done
            exit 1
          '';

          environment = {
            RUST_LOG = "warn,hyperscale=${cfg.logLevel},libp2p_gossipsub=error";
          };
        };

        # Open required ports
        networking.firewall.allowedTCPPorts = [ rpcPort p2pPort ];
        networking.firewall.allowedUDPPorts = [ p2pPort ];
      };
    };
  };

in
{
  options.services.hyperscale-containers = {
    enable = mkEnableOption "Hyperscale validator containers";

    numShards = mkOption {
      type = types.int;
      default = 1;
      description = "Number of shards";
    };

    validatorsPerShard = mkOption {
      type = types.int;
      default = 8;
      description = "Number of validators per shard";
    };

    bridgeName = mkOption {
      type = types.str;
      default = "br-hyperscale";
      description = "Network bridge name for containers";
    };

    subnet = mkOption {
      type = types.str;
      default = "172.99.0.0/16";
      description = "Subnet for container network";
    };

    gateway = mkOption {
      type = types.str;
      default = "172.99.0.1";
      description = "Gateway IP for container network";
    };

    baseP2PPort = mkOption {
      type = types.int;
      default = 9000;
      description = "Base port for P2P communication";
    };

    baseRPCPort = mkOption {
      type = types.int;
      default = 18080;
      description = "Base port for RPC/metrics";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/hyperscale/cluster-data";
      description = "Directory for validator data";
    };

    logLevel = mkOption {
      type = types.str;
      default = "info";
      description = "Log level (trace, debug, info, warn, error)";
    };

    memoryLimit = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "512M";
      description = "Memory limit per validator (systemd MemoryMax format)";
    };

    cpuQuota = mkOption {
      type = types.nullOr types.int;
      default = null;
      example = 50;
      description = "CPU quota percentage per validator (e.g., 50 = 0.5 cores)";
    };

    latency = mkOption {
      type = types.int;
      default = 0;
      description = "Artificial network latency in milliseconds";
    };

    latencyNodes = mkOption {
      type = types.int;
      default = 1;
      description = "Number of nodes to apply latency to";
    };
  };

  config = mkIf cfg.enable {
    # Create network bridge
    systemd.network.networks."10-hyperscale-bridge" = {
      matchConfig.Name = cfg.bridgeName;
      networkConfig = {
        Address = cfg.gateway;
        IPForward = true;
        IPMasquerade = true;
      };
    };

    systemd.network.netdevs."10-hyperscale-bridge" = {
      netdevConfig = {
        Name = cfg.bridgeName;
        Kind = "bridge";
      };
    };

    # Generate validator containers
    containers = listToAttrs (
      map
        (i:
          let
            shard = i / cfg.validatorsPerShard;
            ip = "172.99.0.${toString (10 + i)}";
            p2pPort = cfg.baseP2PPort + i;
            rpcPort = cfg.baseRPCPort + i;
            configPath = "${cfg.dataDir}/validator-${toString i}/config.toml";
            dataPath = "${cfg.dataDir}/validator-${toString i}/data";
          in
          mkValidatorContainer {
            validatorId = i;
            inherit shard ip p2pPort rpcPort configPath dataPath;
          }
        )
        (range 0 (cfg.numShards * cfg.validatorsPerShard - 1))
    );

    # Apply network conditions if configured
    systemd.services.hyperscale-network-conditions = mkIf (cfg.latency > 0) {
      description = "Apply network latency to hyperscale validators";
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "apply-latency" ''
          ${pkgs.iproute2}/bin/tc qdisc add dev lo root netem delay ${toString cfg.latency}ms
        '';
        ExecStop = pkgs.writeShellScript "remove-latency" ''
          ${pkgs.iproute2}/bin/tc qdisc del dev lo root 2>/dev/null || true
        '';
      };
    };
  };
}
