# Standalone systemd service module for hyperscale-validator
# Can be used without containers for bare-metal deployments

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.hyperscale-validator;

in {
  options.services.hyperscale-validator = {
    enable = mkEnableOption "Hyperscale validator service";

    validatorId = mkOption {
      type = types.int;
      description = "Validator ID";
    };

    shard = mkOption {
      type = types.int;
      description = "Shard ID";
    };

    numShards = mkOption {
      type = types.int;
      default = 1;
      description = "Total number of shards";
    };

    configPath = mkOption {
      type = types.path;
      description = "Path to validator config.toml file";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/hyperscale/validator-${toString cfg.validatorId}";
      description = "Directory for validator data";
    };

    keyPath = mkOption {
      type = types.path;
      description = "Path to signing.key file";
    };

    p2pPort = mkOption {
      type = types.int;
      default = 9000 + cfg.validatorId;
      description = "P2P port for libp2p communication";
    };

    rpcPort = mkOption {
      type = types.int;
      default = 8080 + cfg.validatorId;
      description = "RPC/metrics port";
    };

    logLevel = mkOption {
      type = types.str;
      default = "info";
      description = "Log level (trace, debug, info, warn, error)";
    };

    user = mkOption {
      type = types.str;
      default = "hyperscalers";
      description = "User to run validator as";
    };

    group = mkOption {
      type = types.str;
      default = "hyperscalers";
      description = "Group to run validator as";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.hyperscale-validator;
      description = "Package containing hyperscale-validator binary";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional command-line arguments";
    };

    memoryLimit = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "1G";
      description = "Memory limit (systemd MemoryMax format)";
    };

    cpuQuota = mkOption {
      type = types.nullOr types.int;
      default = null;
      example = 100;
      description = "CPU quota percentage (e.g., 100 = 1 core)";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to open firewall ports";
    };
  };

  config = mkIf cfg.enable {
    # Create user and group
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
      uid = 1001;
    };

    users.groups.${cfg.group} = {
      gid = 1001;
    };

    # Create data directory
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    # Systemd service
    systemd.services."hyperscale-validator-${toString cfg.validatorId}" = {
      description = "Hyperscale Validator ${toString cfg.validatorId} (Shard ${toString cfg.shard})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # Wait for validator 0 to be healthy before starting others
      ${if cfg.validatorId > 0 then ''
        after = [ "hyperscale-validator-0.service" ];
        requires = [ "hyperscale-validator-0.service" ];
      '' else ""}

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;

        ExecStart = concatStringsSep " " ([
          "${cfg.package}/bin/hyperscale-validator"
          "--config ${cfg.configPath}"
        ] ++ cfg.extraArgs);

        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "60s";
        TimeoutStopSec = "30s";

        # Resource limits
        ${optionalString (cfg.memoryLimit != null) "MemoryMax = ${cfg.memoryLimit};"}
        ${optionalString (cfg.cpuQuota != null) "CPUQuota = ${toString cfg.cpuQuota}%;"}

        # Security hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        CapabilityBoundingSet = "";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        PrivateDevices = true;
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
      };

      environment = {
        RUST_LOG = "warn,hyperscale=${cfg.logLevel},hyperscale_production=${cfg.logLevel},libp2p_gossipsub=error";
        RUST_BACKTRACE = "1";
      };
    };

    # Healthcheck service
    systemd.services."hyperscale-validator-${toString cfg.validatorId}-healthcheck" = {
      description = "Healthcheck for Hyperscale Validator ${toString cfg.validatorId}";
      after = [ "hyperscale-validator-${toString cfg.validatorId}.service" ];
      wants = [ "hyperscale-validator-${toString cfg.validatorId}.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "healthcheck" ''
          for i in {1..20}; do
            if ${pkgs.curl}/bin/curl -f http://127.0.0.1:${toString cfg.rpcPort}/metrics >/dev/null 2>&1; then
              echo "Validator ${toString cfg.validatorId} is healthy"
              exit 0
            fi
            sleep 5
          done
          echo "Validator ${toString cfg.validatorId} healthcheck failed after 100 seconds"
          exit 1
        '';
      };
    };

    # Open firewall ports
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.p2pPort cfg.rpcPort ];
      allowedUDPPorts = [ cfg.p2pPort ];
    };
  };
}
